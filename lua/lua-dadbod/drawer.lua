local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local history = require("lua-dadbod.history")
local query = require("lua-dadbod.query")
local ui = require("lua-dadbod.ui")
local util = require("lua-dadbod.util")

local M = {
    rows = {},
    show_details = false,
    scratchpads_expanded = false,
    history_expanded = false,
}

local keymaps = {
    { "<CR>", function() M.select("edit") end, "preview/open" },
    { "o", function() M.select("edit") end, "preview/open" },
    { "S", function() M.select("vsplit") end, "open in vsplit" },
    { "n", function() M.new_scratchpad() end, "new scratchpad" },
    { "e", function() M.edit() end, "edit table query" },
    { "C", function() M.columns() end, "columns" },
    { "A", function() M.add_connection() end, "add connection" },
    { "r", function() M.rename() end, "rename" },
    { "d", function() M.delete() end, "delete" },
    { "R", function() M.refresh() end, "refresh" },
    { "H", function() M.toggle_details() end, "details" },
    { "q", function() M.close() end, "close" },
    { "?", function() M.help() end, "help" },
}

local highlight_ns = vim.api.nvim_create_namespace("lua_dadbod_drawer")
local highlights_ready = false

local function setup_highlights()
    if highlights_ready then
        return
    end
    highlights_ready = true

    local groups = {
        LuaDadbodChevron = "Comment",
        LuaDadbodDb = "Normal",
        LuaDadbodTable = "Function",
        LuaDadbodSchema = "Type",
        LuaDadbodScratchpads = "WarningMsg",
        LuaDadbodScratchpad = "Normal",
        LuaDadbodHistory = "DiagnosticOk",
        LuaDadbodHistoryEntry = "Comment",
        LuaDadbodHelp = "Comment",
        LuaDadbodCount = "Comment",
        LuaDadbodActive = "DiagnosticOk",
    }
    for name, link in pairs(groups) do
        vim.api.nvim_set_hl(0, name, { link = link, default = true })
    end
end

local function clean_text(value)
    local text = tostring(value or ""):gsub("\r", ""):gsub("\n", " ")
    if vim.fn.strchars(text) > 300 then
        text = vim.fn.strcharpart(text, 0, 297) .. "..."
    end
    return text
end

local function row_display(row)
    local prefix = string.rep("  ", row.level)
    local label = clean_text(row.label)
    local suffix = clean_text(row.suffix)
    local marker = clean_text(row.marker)
    local expand_icon = row.icon or ""
    local type_icon = row.type_icon or ""
    local highlights = {}

    local text = prefix
    if expand_icon ~= "" then
        local start = #text
        text = text .. expand_icon
        highlights[#highlights + 1] = { start, #text, "LuaDadbodChevron" }
        text = text .. " "
    end

    if type_icon ~= "" then
        local start = #text
        text = text .. type_icon
        highlights[#highlights + 1] = { start, #text, row.icon_hl or "LuaDadbodChevron" }
        text = text .. " "
    end

    local label_start = #text
    text = text .. label
    if row.label_hl and label ~= "" then
        highlights[#highlights + 1] = { label_start, #text, row.label_hl }
    end

    if suffix ~= "" then
        local start = #text + 1
        text = text .. " " .. suffix
        highlights[#highlights + 1] = { start, #text, "LuaDadbodCount" }
    end

    if marker ~= "" then
        local start = #text + 1
        text = text .. " " .. marker
        highlights[#highlights + 1] = { start, #text, "LuaDadbodActive" }
    end

    return text, highlights
end

function M.find_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].lua_dadbod_drawer then
            return win, buf
        end
    end
    return nil, nil
end

function M.is_open()
    local win = M.find_win()
    return win ~= nil
end

local function drawer_windows()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].lua_dadbod_drawer then
            wins[#wins + 1] = win
        end
    end
    return wins
end

local function close_duplicates(win)
    for _, other in ipairs(drawer_windows()) do
        if other ~= win then
            pcall(vim.api.nvim_win_close, other, true)
        end
    end
end

function M.open()
    setup_highlights()
    local win, buf = M.find_win()
    if win then
        M.render()
        vim.api.nvim_set_current_win(win)
        return buf
    end

    local position = config.get().win.position
    vim.cmd(position == "left" and "vertical topleft new" or "vertical botright new")
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_get_current_buf()

    vim.b[buf].lua_dadbod_drawer = true
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "lua_dadbod"

    vim.wo[win].winfixwidth = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].cursorlineopt = "line"

    pcall(vim.cmd, "vertical resize " .. config.get().win.width)
    M.setup_keymaps(buf)
    M.render()
    return buf
end

function M.close()
    for _, win in ipairs(drawer_windows()) do
        pcall(vim.api.nvim_win_close, win, true)
    end
end

function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

function M.setup_keymaps(buf)
    if not config.mappings_enabled("drawer") then
        return
    end

    for _, item in ipairs(keymaps) do
        vim.keymap.set("n", item[1], item[2], {
            buffer = buf,
            silent = true,
            nowait = true,
            desc = "lua-dadbod: " .. item[3],
        })
    end
end

local function add_section(add, opts)
    local icons = opts.icons or {}
    local expanded = icons.expanded or ""
    local collapsed = icons.collapsed or ""

    add({
        kind = "section",
        section = opts.section,
        level = opts.level,
        icon = opts.expanded and expanded or collapsed,
        type_icon = opts.type_icon,
        icon_hl = opts.icon_hl,
        label = opts.label,
        suffix = opts.suffix,
        key = opts.key,
        schema = opts.schema,
    })

    if opts.expanded and opts.body then
        opts.body()
    end
end

local function add_list_section(add, opts)
    add_section(add, {
        section = opts.section,
        level = opts.level,
        expanded = opts.expanded,
        icons = opts.icons,
        type_icon = opts.type_icon,
        icon_hl = opts.icon_hl,
        label = opts.label,
        suffix = opts.suffix,
        body = function()
            if #opts.items == 0 then
                add({ kind = "help", level = opts.level + 1, label = opts.empty, label_hl = "LuaDadbodHelp" })
                return
            end
            for _, item in ipairs(opts.items) do
                add(opts.row(item))
            end
        end,
    })
end

local function schema_state(entry, schema)
    local state = entry.schema_state[schema]
    if not state then
        state = {
            tables = {},
            expanded = false,
            tables_expanded = false,
            loading = false,
            loaded = false,
        }
        entry.schema_state[schema] = state
    end
    return state
end

local function add_table_section(add, entry, icons, level, schema, state)
    local tables = state.tables or {}
    add_section(add, {
        section = "tables",
        level = level,
        schema = schema,
        expanded = state.tables_expanded,
        icons = icons,
        type_icon = icons.table,
        icon_hl = "LuaDadbodTable",
        label = "Tables",
        suffix = state.loading and "(loading...)" or ("(" .. #tables .. ")"),
        key = entry.key,
        body = function()
            if state.loading then
                add({
                    kind = "help",
                    level = level + 1,
                    label = "loading...",
                    label_hl = "LuaDadbodHelp",
                    key = entry.key,
                })
            elseif #tables == 0 then
                add({
                    kind = "help",
                    level = level + 1,
                    label = "(no tables)",
                    label_hl = "LuaDadbodHelp",
                    key = entry.key,
                })
            else
                for _, table_name in ipairs(tables) do
                    add({
                        kind = "table",
                        level = level + 1,
                        type_icon = icons.table,
                        icon_hl = "LuaDadbodTable",
                        label = table_name,
                        table = table_name,
                        schema = schema,
                        key = entry.key,
                    })
                end
            end
        end,
    })
end

local function add_connection_rows(add, entry, icons)
    local expanded = icons.expanded or ""
    local collapsed = icons.collapsed or ""
    local suffix = {}
    if M.show_details then
        local detail = entry.source
        if not ui.has_multiple_dbms() then
            detail = (entry.dbms or "?") .. " - " .. detail
        end
        suffix[#suffix + 1] = "(" .. detail .. ")"
    end
    if entry.error then
        suffix[#suffix + 1] = "✕"
    elseif entry.loading then
        suffix[#suffix + 1] = "…"
    end

    add({
        kind = "conn",
        level = 0,
        icon = entry.expanded and expanded or collapsed,
        type_icon = icons.db,
        icon_hl = "LuaDadbodDb",
        label = ui.connection_label(entry.dbms, entry.name),
        suffix = table.concat(suffix, " "),
        marker = ui.is_activated(entry.key) and icons.active or "",
        key = entry.key,
    })

    if not entry.expanded then
        return
    end

    if not entry.schemas_supported then
        add_table_section(add, entry, icons, 1, nil, entry)
        return
    end

    local schemas = entry.schemas or {}
    add_section(add, {
        section = "schemas",
        level = 1,
        expanded = entry.schemas_expanded,
        icons = icons,
        type_icon = icons.schema,
        icon_hl = "LuaDadbodSchema",
        label = "Schemas",
        suffix = entry.schemas_loading and "(loading...)" or ("(" .. #schemas .. ")"),
        key = entry.key,
        body = function()
            if entry.schemas_loading then
                add({ kind = "help", level = 2, label = "loading...", label_hl = "LuaDadbodHelp", key = entry.key })
                return
            end
            if #schemas == 0 then
                add({ kind = "help", level = 2, label = "(no schemas)", label_hl = "LuaDadbodHelp", key = entry.key })
                return
            end
            for _, schema in ipairs(schemas) do
                local state = schema_state(entry, schema)
                add({
                    kind = "schema",
                    level = 2,
                    icon = state.expanded and expanded or collapsed,
                    type_icon = icons.schema,
                    icon_hl = "LuaDadbodSchema",
                    label = schema,
                    key = entry.key,
                    schema = schema,
                })
                if state.expanded then
                    add_table_section(add, entry, icons, 3, schema, state)
                end
            end
        end,
    })
end

function M.render()
    setup_highlights()
    local win, buf = M.find_win()
    if not win or not buf then
        return
    end
    close_duplicates(win)

    local entries = ui.connections()
    local icons = config.get().icons or {}
    local rows = {}
    local function add(row)
        rows[#rows + 1] = row
    end

    if #entries == 0 then
        add({
            kind = "help",
            level = 0,
            label = "No connections. Press A to add one.",
            label_hl = "LuaDadbodHelp",
        })
    end

    for _, entry in ipairs(entries) do
        add_connection_rows(add, entry, icons)
    end

    local scratchpads = ui.scratchpads()
    add_list_section(add, {
        section = "scratchpads",
        level = 0,
        expanded = M.scratchpads_expanded,
        icons = icons,
        type_icon = icons.scratchpads,
        icon_hl = "LuaDadbodScratchpads",
        label = "Scratchpads",
        suffix = "(" .. #scratchpads .. ")",
        items = scratchpads,
        empty = #entries == 0 and "No scratchpads." or "No scratchpads. Press n to create one.",
        row = function(item)
            local mark = (item.unsaved or item.modified) and " *" or ""
            return {
                kind = "scratch",
                level = 1,
                type_icon = icons.scratchpad,
                icon_hl = "LuaDadbodScratchpad",
                label = item.label,
                suffix = "(" .. item.conn_label .. ")" .. mark,
                item = item,
            }
        end,
    })

    local history_entries = history.list()
    add_list_section(add, {
        section = "history",
        level = 0,
        expanded = M.history_expanded,
        icons = icons,
        type_icon = icons.history,
        icon_hl = "LuaDadbodHistory",
        label = "History",
        suffix = "(" .. #history_entries .. ")",
        items = history_entries,
        empty = "No history yet.",
        row = function(entry)
            local conn_label = ui.connection_label(entry.dbms, entry.name)
            return {
                kind = "history",
                level = 1,
                type_icon = icons.history_entry or "·",
                icon_hl = "LuaDadbodHistoryEntry",
                label = history.preview_text(entry),
                suffix = "(" .. conn_label .. ", " .. os.date("%H:%M", entry.time or os.time()) .. ")",
                entry = entry,
            }
        end,
    })

    local lines = {}
    local highlights = {}
    for index, row in ipairs(rows) do
        local text, row_highlights = row_display(row)
        lines[index] = text
        highlights[index] = row_highlights
    end
    if #lines == 0 then
        lines = { "" }
    end

    local view = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview()
    end)

    vim.api.nvim_buf_clear_namespace(buf, highlight_ns, 0, -1)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    for index, row_highlights in ipairs(highlights) do
        for _, highlight in ipairs(row_highlights) do
            vim.api.nvim_buf_add_highlight(buf, highlight_ns, highlight[3], index - 1, highlight[1], highlight[2])
        end
    end

    local target = math.max(1, math.min(view.lnum or 1, #lines))
    vim.api.nvim_win_set_cursor(win, { target, 0 })
    M.rows = rows
end

function M.row()
    return M.rows[vim.fn.line(".")]
end

function M.fetch_schemas(entry)
    if entry.loading or entry.schemas_loading then
        return
    end
    entry.loading = true
    entry.schemas_loading = true
    entry.error = nil
    local key = entry.key
    M.render()

    db.fetch_schemas(entry.url, function(schemas, err)
        local current = ui.get(key)
        if not current then
            return
        end
        current.loading = false
        current.schemas_loading = false
        current.loaded = true
        current.schemas_loaded = err == nil
        if err then
            current.error = err
            current.schemas = {}
            current.schema_state = {}
            current.expanded = false
            ui.deactivate(key)
            util.error(current.name .. ": " .. err)
        else
            current.error = nil
            current.schemas = schemas or {}
            local states = {}
            for _, schema in ipairs(current.schemas) do
                states[schema] = current.schema_state[schema] or {
                    tables = {},
                    expanded = false,
                    tables_expanded = false,
                    loading = false,
                    loaded = false,
                }
            end
            current.schema_state = states
        end
        if M.is_open() then
            M.render()
        end
    end)
end

function M.fetch_schema_tables(entry, schema)
    local state = schema_state(entry, schema)
    if state.loading then
        return
    end
    state.loading = true
    local key = entry.key
    M.render()

    db.fetch_tables(entry.url, schema, function(tables, err)
        local current = ui.get(key)
        if not current then
            return
        end
        local current_state = current.schema_state[schema]
        if not current_state then
            return
        end
        current_state.loading = false
        if err then
            current_state.tables = {}
            current_state.loaded = false
            current_state.expanded = false
            util.error(current.name .. "/" .. schema .. ": " .. err)
        else
            current_state.tables = tables or {}
            current_state.loaded = true
        end
        if M.is_open() then
            M.render()
        end
    end)
end

function M.fetch(entry)
    if entry.schemas_supported then
        M.fetch_schemas(entry)
    else
        if entry.loading then
            return
        end
        entry.loading = true
        entry.error = nil
        local key = entry.key
        M.render()

        db.fetch_tables(entry.url, function(tables, err)
            local current = ui.get(key)
            if not current then
                return
            end
            current.loading = false
            current.loaded = true
            if err then
                current.error = err
                current.tables = {}
                current.expanded = false
                current.tables_expanded = false
                ui.deactivate(key)
                util.error(current.name .. ": " .. err)
            else
                current.tables = tables or {}
            end
            if M.is_open() then
                M.render()
            end
        end)
    end
end

function M.open_table(entry, table_name, helper, mode, schema, opts)
    opts = opts or {}
    local bufnr, err = query.open(entry, vim.tbl_extend("force", {
        table = table_name,
        schema = schema,
        helper = helper,
        split = mode == "vsplit" and "vsplit" or nil,
    }, opts))
    if not bufnr then
        util.error(err)
        return
    end
    if M.is_open() then
        M.render()
    end
end

function M.preview_table(entry, table_name, helper, schema)
    ui.set_active(entry.key)
    local sql, err = query.helper_sql(entry.url, {
        table = table_name,
        schema = schema,
        helper = helper,
    })
    if not sql then
        util.error(err or "no table helper available")
        return
    end

    local result_buf, run_err = require("lua-dadbod.execute").run(sql, {
        conn = entry.url,
        conn_key = entry.key,
        name = entry.name,
    })
    if not result_buf then
        util.error(run_err)
    end
end

function M.edit()
    local row = M.row()
    if not row or row.kind ~= "table" then
        util.warn("select a table first")
        return
    end

    local entry = ui.get(row.key)
    if not entry then
        return
    end
    ui.set_active(entry.key)
    M.open_table(entry, row.table, "List", "edit", row.schema, {
        auto_execute = false,
    })
end

function M.select(mode)
    local row = M.row()
    if not row then
        return
    end

    if row.kind == "conn" then
        local entry = ui.get(row.key)
        if not entry then
            return
        end
        if entry.error then
            util.error(entry.name .. ": " .. entry.error)
            return
        end
        ui.set_active(entry.key)
        entry.expanded = not entry.expanded
        if entry.expanded and not entry.loaded and not entry.loading then
            M.fetch(entry)
        end
        M.render()
        return
    end

    if row.kind == "schema" then
        local entry = ui.get(row.key)
        if not entry then
            return
        end
        local state = schema_state(entry, row.schema)
        ui.set_active(entry.key)
        state.expanded = not state.expanded
        if state.expanded and not state.loaded and not state.loading then
            M.fetch_schema_tables(entry, row.schema)
        end
        M.render()
        return
    end

    if row.kind == "section" then
        if row.section == "tables" then
            local entry = ui.get(row.key)
            if entry and row.schema then
                local state = schema_state(entry, row.schema)
                state.tables_expanded = not state.tables_expanded
            elseif entry then
                entry.tables_expanded = not entry.tables_expanded
            end
        elseif row.section == "schemas" then
            local entry = ui.get(row.key)
            if entry then
                entry.schemas_expanded = not entry.schemas_expanded
            end
        elseif row.section == "scratchpads" then
            M.scratchpads_expanded = not M.scratchpads_expanded
        elseif row.section == "history" then
            M.history_expanded = not M.history_expanded
        end
        M.render()
        return
    end

    if row.kind == "table" then
        local entry = ui.get(row.key)
        if not entry then
            return
        end
        ui.set_active(entry.key)
        if mode == "vsplit" then
            M.open_table(entry, row.table, "List", "vsplit", row.schema)
        else
            M.preview_table(entry, row.table, "List", row.schema)
        end
        return
    end

    if row.kind == "scratch" then
        M.open_scratch(row.item, mode)
        return
    end

    if row.kind == "history" then
        if row.entry.key then
            ui.set_active(row.entry.key)
        end
        history.preview_entry(row.entry)
        return
    end

end

function M.open_scratch(item, mode)
    if not item then
        return
    end

    local split = mode == "vsplit" and "vsplit" or nil
    if item.kind == "buffer" then
        if item.conn_key and ui.get(item.conn_key) then
            ui.set_active(item.conn_key)
        end
        local bufnr, err = query.focus(item.bufnr, {
            split = split,
            force_split = mode == "vsplit",
        })
        if not bufnr then
            util.error(err)
        end
        return
    end

    local entry = item.conn_key and ui.get(item.conn_key) or ui.find_by_url(item.conn)
    if not entry then
        util.error("connection for this scratchpad is no longer available")
        return
    end
    ui.set_active(entry.key)
    local bufnr, err = query.open_path(item.path, entry, { split = split })
    if not bufnr then
        util.error(err)
        return
    end
    if M.is_open() then
        M.render()
    end
end

local function row_connection(row)
    if not row then
        return nil
    end
    if row.key then
        return ui.get(row.key)
    end
    if row.kind == "scratch" and row.item then
        if row.item.conn_key then
            return ui.get(row.item.conn_key)
        end
        if row.item.conn then
            return ui.find_by_url(row.item.conn)
        end
    end
    if row.kind == "history" and row.entry then
        if row.entry.key then
            return ui.get(row.entry.key)
        end
        if row.entry.conn then
            return ui.find_by_url(row.entry.conn)
        end
    end
    return nil
end

function M.new_scratchpad()
    local entry = row_connection(M.row())
    if not entry then
        local active = ui.active()
        if active then
            entry = ui.get(active)
        end
    end

    if not entry then
        local connections = ui.connections()
        if #connections == 0 then
            util.warn("no connections configured")
            return
        end
        if #connections == 1 then
            entry = connections[1]
        else
            ui.pick("New scratchpad connection", function(selected)
                M.open_new_scratchpad(selected)
            end)
            return
        end
    end

    M.open_new_scratchpad(entry)
end

function M.open_new_scratchpad(entry)
    if entry.error then
        util.error(entry.name .. ": " .. entry.error)
        return
    end
    ui.set_active(entry.key)
    local bufnr, err = query.open(entry, {})
    if not bufnr then
        util.error(err)
        return
    end
    if M.is_open() then
        M.render()
    end
end

function M.columns()
    local row = M.row()
    if not row or row.kind ~= "table" then
        util.warn("select a table first")
        return
    end

    local entry = ui.get(row.key)
    if not entry then
        return
    end
    ui.set_active(entry.key)

    local names = query.helper_names(entry.url)
    local choices = {}
    local has_columns = false
    for _, name in ipairs(names) do
        if name == "Columns" then
            has_columns = true
        end
    end
    if has_columns then
        choices[#choices + 1] = "Columns"
    end
    for _, name in ipairs(names) do
        if name ~= "Columns" then
            choices[#choices + 1] = name
        end
    end

    if #choices == 0 then
        util.warn("no table helpers configured")
        return
    end
    if #choices == 1 then
        M.preview_table(entry, row.table, choices[1], row.schema)
        return
    end

    vim.ui.select(choices, { prompt = "Table helper" }, function(choice)
        if choice then
            M.preview_table(entry, row.table, choice, row.schema)
        end
    end)
end

function M.refresh()
    local row = M.row()
    local entry = row and row.key and ui.get(row.key) or nil

    if entry then
        local had_error = entry.error ~= nil
        entry.loaded = false
        entry.error = nil
        entry.tables = {}
        entry.schemas = {}
        entry.schemas_loaded = false
        entry.schemas_loading = false
        entry.schema_state = {}
        db.clear_meta(entry.url)
        if entry.expanded or had_error then
            M.fetch(entry)
        end
    else
        db.clear_meta()
        ui.refresh()
        for _, item in ipairs(ui.connections()) do
            item.loaded = false
            item.error = nil
            item.tables = {}
            item.schemas = {}
            item.schemas_loaded = false
            item.schemas_loading = false
            item.schema_state = {}
            if item.expanded then
                M.fetch(item)
            end
        end
    end

    M.render()
end

function M.add_connection()
    require("lua-dadbod").add_connection()
end

function M.rename()
    local row = M.row()
    if not row or row.kind ~= "scratch" then
        util.warn("select a scratchpad to rename")
        return
    end

    local item = row.item
    if item.unsaved then
        util.warn("save the scratchpad before renaming it")
        return
    end

    local default = vim.fn.fnamemodify(item.path, ":t:r")
    util.input("Rename scratchpad: ", default, function(name)
        local new_path, err = query.rename_file(item.path, name)
        if not new_path then
            util.error(err)
            return
        end
        M.render()
    end)
end

function M.delete()
    local row = M.row()
    if not row then
        return
    end

    if row.kind == "scratch" then
        local item = row.item
        local choice = vim.fn.confirm("Delete scratchpad " .. item.label .. "?", "&Yes\n&No", 2)
        if choice ~= 1 then
            return
        end

        local ok, err = query.delete_scratchpad(item)
        if not ok then
            util.error(err)
            return
        end
        M.render()
        return
    end

    if row.kind == "history" then
        history.remove(row.entry)
        M.render()
        return
    end

    if row.kind == "conn" then
        local entry = ui.get(row.key)
        if not entry then
            return
        end
        if entry.source ~= "file" then
            util.warn("only connections from connections.json can be deleted")
            return
        end
        local choice = vim.fn.confirm("Delete connection " .. entry.name .. "?", "&Yes\n&No", 2)
        if choice ~= 1 then
            return
        end
        local ok, err = ui.delete_connection(entry)
        if not ok then
            util.error(err)
            return
        end
        M.render()
        return
    end

    util.warn("select a scratchpad, history entry, or file connection to delete")
end

function M.toggle_details()
    M.show_details = not M.show_details
    M.render()
end

function M.help()
    local parts = {}
    for _, item in ipairs(keymaps) do
        parts[#parts + 1] = item[1] .. " " .. item[3]
    end
    util.notify(table.concat(parts, ", "))
end

return M

local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local sql = require("lua-dadbod.sql")
local statement = require("lua-dadbod.statement")
local url = require("lua-dadbod.url")
local util = require("lua-dadbod.util")

local M = {}

local function connection_parts(connection)
    if type(connection) == "string" then
        return connection, nil
    end
    if type(connection) == "table" then
        return connection.url or connection.conn, connection.name
    end
    return nil, nil
end

local function effective_helpers(adapter)
    local helpers = {}
    for name, template in pairs(adapter.helpers or {}) do
        if template ~= "" then
            helpers[name] = template
        end
    end

    local custom = config.get().table_helpers[adapter.name]
    if type(custom) ~= "table" then
        custom = {}
    end
    for name, template in pairs(custom) do
        if template == "" then
            helpers[name] = nil
        else
            helpers[name] = template
        end
    end

    if helpers.List == nil and custom.List == nil then
        helpers.List = config.get().default_query
    end

    return helpers
end

local function query_name(name)
    name = util.trim(name or "")
    if name == "" then
        return nil, "a query name is required"
    end
    name = name:gsub("[/\\]", "_")
    if name:sub(-4):lower() ~= ".sql" then
        name = name .. ".sql"
    end
    return name
end

local function helper_sql(connection, opts)
    local parsed, adapter = db.parse(connection)
    if not parsed or not adapter then
        return nil, adapter or "invalid connection URL"
    end

    local helper = opts.helper or "List"
    local template = effective_helpers(adapter)[helper]
    if not template then
        return nil, "no helper " .. helper .. " for " .. adapter.name
    end

    local quote = adapter.quote
    local function ident(value)
        if not value or value == "" then
            return ""
        end
        if quote then
            return sql.ident(value, quote[1], quote[2])
        end
        return value
    end

    local function literal(value)
        return sql.literal(value or "")
    end

    local schema = opts.schema or ""
    local table_name = opts.table or ""
    local dbname = opts.dbname or schema

    local optional_schema = ""
    if schema ~= "" and schema ~= (adapter.default_schema or "") then
        optional_schema = ident(schema) .. "."
    end

    local replacements = {
        ["{table}"] = ident(table_name),
        ["{schema}"] = ident(schema),
        ["{optional_schema}"] = optional_schema,
        ["{dbname}"] = ident(dbname),
        ["{table_lit}"] = literal(table_name),
        ["{schema_lit}"] = literal(schema),
        ["{dbname_lit}"] = literal(dbname),
    }

    local content = template
    for placeholder, value in pairs(replacements) do
        content = content:gsub(placeholder, function()
            return value
        end)
    end

    return content, adapter, parsed
end

function M.quote_value(value)
    local trimmed = util.trim(value)
    if trimmed == "" then
        return value
    end
    if trimmed:match("^'.*'$")
        or trimmed:match("^%-?%d+%.?%d*$")
        or trimmed:lower() == "true"
        or trimmed:lower() == "false"
        or trimmed:lower() == "null"
    then
        return trimmed
    end
    return "'" .. trimmed:gsub("'", "''") .. "'"
end

function M.find_params(text)
    local pattern = config.get().bind_param_pattern
    local ordered = {}
    local seen = {}

    for line in tostring(text or ""):gmatch("[^\n]*") do
        local clean = line:gsub("'[^']*'", "")
        local init = 1
        while true do
            local start, finish = clean:find(pattern, init)
            if not start then
                break
            end
            local name = clean:sub(start, finish)
            local before = start > 1 and clean:sub(start - 1, start - 1) or ""
            if not before:match("[:%w_]") and not seen[name] then
                seen[name] = true
                ordered[#ordered + 1] = name
            end
            init = finish + 1
        end
    end

    return ordered
end

function M.substitute(text, bind)
    local names = vim.tbl_keys(bind or {})
    table.sort(names, function(a, b)
        return #a > #b
    end)

    local result = text
    for _, name in ipairs(names) do
        local value = bind[name]
        if value ~= nil and util.trim(value) ~= "" then
            result = result:gsub(vim.pesc(name), function()
                return M.quote_value(value)
            end)
        end
    end
    return result
end

function M.resolve_binds(text, bind, callback)
    bind = bind or {}
    local params = M.find_params(text)
    local index = 1

    local function next_param()
        while index <= #params and bind[params[index]] ~= nil do
            index = index + 1
        end
        if index > #params then
            callback(M.substitute(text, bind), bind)
            return
        end

        local name = params[index]
        index = index + 1
        vim.ui.input({ prompt = "Value for " .. name .. ": " }, function(value)
            if value == nil then
                return
            end
            bind[name] = value
            next_param()
        end)
    end

    next_param()
end

local function resolve_connection(connection)
    local raw_url, explicit_name = connection_parts(connection)
    if not raw_url or raw_url == "" then
        return nil, "connection URL is required"
    end

    local parsed, adapter = db.parse(raw_url)
    if not parsed or not adapter then
        return nil, adapter or "invalid connection URL"
    end

    local name = explicit_name or url.display_name(parsed, adapter.name)
    return {
        url = url.format(parsed),
        input = raw_url,
        name = name,
        key = (type(connection) == "table" and connection.key) or name,
        adapter = adapter,
        parsed = parsed,
    }
end

local function apply_connection_meta(bufnr, ctx, opts)
    opts = opts or {}
    local meta = vim.b[bufnr].lua_dadbod
    if type(meta) ~= "table" then
        meta = {}
    end
    meta.conn = ctx.url
    meta.url = ctx.input
    meta.conn_name = ctx.name
    meta.conn_key = ctx.key
    meta.dbms = ctx.adapter.name
    meta.bind = meta.bind or {}
    if opts.source then
        meta.source = opts.source
    end
    if opts.path then
        meta.path = opts.path
    end
    vim.b[bufnr].lua_dadbod = meta
    return meta
end

local function refresh_drawer()
    vim.schedule(function()
        local drawer = package.loaded["lua-dadbod.drawer"]
        if drawer and drawer.is_open() then
            pcall(drawer.render)
        end
    end)
end

local function remove_broken_sql_maps(bufnr)
    if vim.g.loaded_sql_completion == nil then
        return
    end
    if vim.fn.exists("*sqlcomplete#DrillIntoTable") == 1 then
        return
    end
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
        if map.rhs and map.rhs:find("sqlcomplete#", 1, true) then
            pcall(vim.keymap.del, "i", map.lhs, { buffer = bufnr })
        end
    end
end

local function setup_buffer(bufnr, adapter)
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].buflisted = true
    vim.bo[bufnr].filetype = adapter.filetype or "sql"
    remove_broken_sql_maps(bufnr)

    if config.mappings_enabled("query") then
        vim.keymap.set("n", "<Leader>S", function()
            M.run(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Run lua-dadbod query" })
        vim.keymap.set("v", "<Leader>S", function()
            M.run_visual(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Run lua-dadbod selection" })
        vim.keymap.set("n", "<CR>", function()
            M.run_statement(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Run lua-dadbod statement" })
        vim.keymap.set("x", "<CR>", function()
            M.run_visual(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Run lua-dadbod selection" })
        vim.keymap.set("n", "<Leader>W", function()
            M.save(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Save lua-dadbod query as" })
        vim.keymap.set("n", "<Leader>E", function()
            M.edit_bind(bufnr)
        end, { buffer = bufnr, silent = true, desc = "Edit lua-dadbod bind parameters" })
    end

    local group = vim.api.nvim_create_augroup("lua_dadbod_query_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        buffer = bufnr,
        callback = function()
            if config.get().execute_on_save then
                M.run(bufnr)
            end
            refresh_drawer()
        end,
    })
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        buffer = bufnr,
        callback = refresh_drawer,
    })
end

function M.open(connection, opts)
    opts = opts or {}
    local ctx, err = resolve_connection(connection)
    if not ctx then
        return nil, err
    end

    local dbname = opts.dbname or opts.schema or (ctx.parsed.path and ctx.parsed.path:gsub("^/", "")) or ctx.name
    local directory = vim.fn.expand(config.get().tmp_location)
    util.ensure_dir(directory)

    local base = util.slug(ctx.name)
    if opts.table and opts.table ~= "" then
        base = base .. "-" .. util.slug(opts.table) .. "-" .. util.slug(opts.helper or "List")
    else
        base = base .. "-query"
    end

    local stamp = os.date("%Y%m%d-%H%M%S")
    local path = directory .. "/" .. base .. "-" .. stamp .. ".sql"
    local suffix = 1
    while vim.fn.filereadable(path) == 1 or vim.fn.bufnr(path) ~= -1 do
        suffix = suffix + 1
        path = directory .. "/" .. base .. "-" .. stamp .. "-" .. suffix .. ".sql"
    end

    util.open_split({ split = opts.split, reuse = true })
    local previous = vim.api.nvim_win_get_buf(0)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, bufnr)
    util.drop_empty_buffer(previous)
    vim.api.nvim_buf_set_name(bufnr, path)
    setup_buffer(bufnr, ctx.adapter)

    local meta = apply_connection_meta(bufnr, ctx, { source = "scratch" })
    meta.schema = opts.schema or ""
    meta.table = opts.table or ""
    meta.helper = opts.helper or ""
    meta.result_buf = nil
    vim.b[bufnr].lua_dadbod = meta

    local content = opts.sql
    if not content and opts.table and opts.table ~= "" then
        local helper_err
        content, helper_err = helper_sql(ctx.url, {
            table = opts.table,
            schema = opts.schema,
            helper = opts.helper,
            dbname = dbname,
        })
        if not content then
            return nil, helper_err
        end
    end

    if content and content ~= "" then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
    end

    local auto_execute = opts.auto_execute
    if auto_execute == nil then
        auto_execute = config.get().auto_execute_helpers and content ~= nil and content ~= ""
    end
    if auto_execute then
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                M.run(bufnr)
            end
        end)
    end

    return bufnr
end

function M.open_path(path, connection, opts)
    opts = opts or {}
    path = vim.fn.fnamemodify(path, ":p")
    if vim.fn.filereadable(path) == 0 then
        return nil, "query file not found: " .. path
    end

    local ctx, err = resolve_connection(connection)
    if not ctx then
        return nil, err
    end

    util.open_split({ split = opts.split, reuse = true })
    local previous = vim.api.nvim_win_get_buf(0)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_win_set_buf(0, bufnr)
    util.drop_empty_buffer(previous)

    apply_connection_meta(bufnr, ctx, {
        source = "saved",
        path = vim.api.nvim_buf_get_name(bufnr),
    })
    setup_buffer(bufnr, ctx.adapter)
    return bufnr
end

function M.focus(bufnr, opts)
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid buffer"
    end

    if not opts.force_split then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == bufnr then
                vim.api.nvim_set_current_win(win)
                return bufnr
            end
        end
    end

    util.open_split({ split = opts.split, reuse = true })
    local previous = vim.api.nvim_win_get_buf(0)
    vim.api.nvim_win_set_buf(0, bufnr)
    util.drop_empty_buffer(previous)
    return bufnr
end

function M.attach(connection, bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid buffer"
    end

    local ctx, err = resolve_connection(connection)
    if not ctx then
        return nil, err
    end

    local current = vim.b[bufnr].lua_dadbod
    local source = opts.source or (type(current) == "table" and current.source) or "attached"
    apply_connection_meta(bufnr, ctx, { source = source, path = opts.path })
    setup_buffer(bufnr, ctx.adapter)
    return bufnr
end

function M.helper_names(connection)
    local parsed, adapter = db.parse(connection)
    if not parsed or not adapter then
        return {}
    end

    local helpers = effective_helpers(adapter)
    local names = {}
    for name in pairs(helpers) do
        if name ~= "List" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function M.run(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    return require("lua-dadbod.execute").run_buffer({ bufnr = bufnr })
end

function M.run_statement(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    local meta = vim.b[bufnr].lua_dadbod or {}
    local chunk = statement.find(lines, cursor, statement.dialect(meta.dbms))
    if not chunk then
        util.warn("no SQL statement under cursor")
        return
    end

    return require("lua-dadbod.execute").run_buffer({
        bufnr = bufnr,
        line1 = chunk.line1,
        line2 = chunk.line2,
    })
end

function M.run_visual(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
        -- Visual mappings run before Vim records the selection, so '< and '>
        -- are still 0 here. Leaving visual mode sets them.
        pcall(function()
            vim.cmd("normal! \27")
        end)
    end
    local start = vim.fn.line("'<")
    local finish = vim.fn.line("'>")
    if start == 0 or finish == 0 then
        util.warn("no visual selection")
        return
    end
    if start > finish then
        start, finish = finish, start
    end
    return require("lua-dadbod.execute").run_buffer({
        bufnr = bufnr,
        line1 = start,
        line2 = finish,
    })
end

function M.save_as(bufnr, name)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid buffer"
    end

    local meta = vim.b[bufnr].lua_dadbod
    if type(meta) ~= "table" or not meta.conn then
        return nil, "buffer is not attached to a connection"
    end

    local filename, name_err = query_name(name)
    if not filename then
        return nil, name_err
    end

    local connection_key = meta.conn_key or meta.conn_name or "db"
    local ui = require("lua-dadbod.ui")
    local entry = ui.get(meta.conn_key)
    local folder = entry and ui.saved_folder(entry) or ui.saved_folder(connection_key)
    local directory = vim.fn.expand(config.get().save_location) .. "/queries/" .. folder
    util.ensure_dir(directory)

    local path = directory .. "/" .. filename
    if vim.fn.filereadable(path) == 1 then
        return nil, "a query with that name already exists"
    end

    local ok, err = pcall(function()
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent noautocmd saveas " .. vim.fn.fnameescape(path))
        end)
    end)
    if not ok then
        return nil, "cannot save query: " .. tostring(err)
    end

    meta.source = "saved"
    meta.path = vim.api.nvim_buf_get_name(bufnr)
    vim.b[bufnr].lua_dadbod = meta

    local drawer = package.loaded["lua-dadbod.drawer"]
    if drawer and drawer.is_open() then
        pcall(drawer.render)
    end

    return meta.path
end

function M.rename_file(old_path, new_name)
    old_path = vim.fn.fnamemodify(old_path, ":p")
    if vim.fn.filereadable(old_path) == 0 then
        return nil, "query file not found: " .. old_path
    end

    local name, name_err = query_name(new_name)
    if not name then
        return nil, name_err
    end

    local new_path = vim.fs.dirname(old_path) .. "/" .. name
    if new_path == old_path then
        return old_path
    end
    if vim.fn.filereadable(new_path) == 1 then
        return nil, "a query with that name already exists"
    end

    local ok, result = pcall(vim.fn.rename, old_path, new_path)
    if not ok or result ~= 0 then
        return nil, "cannot rename query: " .. tostring(result)
    end

    local bufnr = vim.fn.bufnr(old_path)
    if bufnr == -1 then
        bufnr = vim.fn.bufnr(vim.fn.resolve(old_path))
    end
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_name(bufnr, new_path)
        local buffer_path = vim.api.nvim_buf_get_name(bufnr)
        local meta = vim.b[bufnr].lua_dadbod
        if type(meta) == "table" then
            meta.path = buffer_path
            vim.b[bufnr].lua_dadbod = meta
        end
        return buffer_path
    end

    return new_path
end

function M.delete_scratchpad(item)
    if not item then
        return nil, "scratchpad not found"
    end

    local bufnr = item.kind == "buffer" and item.bufnr or nil
    if item.kind == "file" then
        if not item.path or vim.fn.delete(item.path) ~= 0 then
            return nil, "cannot delete " .. tostring(item.path)
        end
        local existing = vim.fn.bufnr(item.path)
        if existing == -1 then
            existing = vim.fn.bufnr(vim.fn.resolve(item.path))
        end
        bufnr = existing ~= -1 and existing or nil
    elseif item.unsaved and item.path then
        local tmp = vim.fn.resolve(vim.fn.fnamemodify(config.get().tmp_location, ":p"))
        local path = vim.fn.resolve(vim.fn.fnamemodify(item.path, ":p"))
        if vim.startswith(path, tmp) then
            vim.fn.delete(path)
        end
    elseif item.kind == "buffer" and item.path then
        if vim.fn.delete(item.path) ~= 0 then
            return nil, "cannot delete " .. item.path
        end
    end

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    return true
end

function M.save(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local meta = vim.b[bufnr].lua_dadbod
    local default = type(meta) == "table" and meta.table or "query"
    if default == nil or default == "" then
        default = "query"
    end
    util.input("Save query as: ", default, function(name)
        local path, err = M.save_as(bufnr, name)
        if not path then
            util.error(err)
            return
        end
        util.notify("saved " .. path)
    end)
end

function M.edit_bind(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local meta = vim.b[bufnr].lua_dadbod
    if type(meta) ~= "table" then
        util.warn("buffer is not attached to a connection")
        return
    end

    local bind = meta.bind or {}
    local keys = vim.tbl_keys(bind)
    if #keys == 0 then
        util.notify("no bind parameters to edit")
        return
    end
    table.sort(keys)

    local choices = {}
    for _, key in ipairs(keys) do
        local value = tostring(bind[key]):gsub("\n", "\\n")
        choices[#choices + 1] = key .. " = " .. value
    end
    choices[#choices + 1] = "Clear all"

    vim.ui.select(choices, { prompt = "Bind parameters" }, function(_, index)
        if not index then
            return
        end
        if index == #choices then
            meta.bind = {}
            vim.b[bufnr].lua_dadbod = meta
            util.notify("cleared bind parameters")
            return
        end

        local key = keys[index]
        vim.ui.input({ prompt = "Value for " .. key .. ": ", default = bind[key] or "" }, function(value)
            if value == nil then
                return
            end
            if util.trim(value) == "" then
                bind[key] = nil
            else
                bind[key] = value
            end
            meta.bind = bind
            vim.b[bufnr].lua_dadbod = meta
            util.notify("updated " .. key)
        end)
    end)
end

M.helper_sql = helper_sql

return M

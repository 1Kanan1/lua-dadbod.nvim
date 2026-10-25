local db = require("lua-dadbod.db")
local util = require("lua-dadbod.util")
local url = require("lua-dadbod.url")

local M = {
    win = nil,
    buf = nil,
    state = nil,
    rows = {},
    on_save = nil,
}

local adapters = {
    { name = "postgresql", label = "PostgreSQL", port = "5432" },
    { name = "mysql", label = "MySQL", port = "3306" },
    { name = "sqlite", label = "SQLite", port = "" },
}

local function adapter_info(name)
    for _, item in ipairs(adapters) do
        if item.name == name then
            return item
        end
    end
    return adapters[1]
end

local function fields(state)
    local list = {
        { key = "adapter", label = "Type" },
        { key = "name", label = "Name" },
    }
    if state.adapter == "sqlite" then
        list[#list + 1] = { key = "file", label = "File" }
    else
        for _, field in ipairs({
            { key = "host", label = "Host" },
            { key = "port", label = "Port" },
            { key = "user", label = "User" },
            { key = "password", label = "Password" },
            { key = "database", label = "Database" },
        }) do
            list[#list + 1] = field
        end
    end
    list[#list + 1] = { key = "url", label = "URL" }
    return list
end

function M.build_url(state)
    if state.raw_url and state.raw_url ~= "" then
        return state.raw_url
    end
    if state.adapter == "sqlite" then
        if state.file == "" then
            return nil, "SQLite file is required"
        end
        return url.format({ scheme = "sqlite", opaque = state.file })
    end
    if state.database == "" then
        return nil, "database is required"
    end
    if state.password ~= "" and state.user == "" then
        return nil, "user is required when a password is set"
    end

    local parsed = {
        scheme = state.adapter,
        path = "/" .. state.database,
    }
    if state.host ~= "" then
        parsed.host = state.host
    end
    if state.port ~= "" then
        parsed.port = state.port
    end
    if state.user ~= "" then
        parsed.user = state.user
    end
    if state.password ~= "" then
        parsed.password = state.password
    end
    return url.format(parsed)
end

function M.default_name(state)
    if state.adapter == "sqlite" then
        if state.file == ":memory:" then
            return "memory"
        end
        local name = vim.fn.fnamemodify(state.file, ":t:r")
        return name ~= "" and name or "db"
    end
    if state.database ~= "" then
        return state.database
    end
    if state.host ~= "" then
        return state.host
    end
    return "db"
end

local function display_value(state, field, raw)
    if field.key == "adapter" then
        return adapter_info(state.adapter).label
    end
    if field.key == "password" then
        return state.password ~= "" and "••••••" or ""
    end
    if field.key == "url" then
        return url.safe_format(raw or "")
    end
    return state[field.key] or ""
end

local function close()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
    end
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
    end
    M.win = nil
    M.buf = nil
    M.state = nil
    M.rows = {}
    M.on_save = nil
end

function M.close()
    close()
end

local function cursor(line)
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end
    local count = vim.api.nvim_buf_line_count(M.buf)
    vim.api.nvim_win_set_cursor(M.win, { math.max(1, math.min(line, count)), 0 })
end

local function focus_row(key)
    for index, field in ipairs(M.rows) do
        if field.key == key then
            cursor(index)
            return
        end
    end
end

local function render()
    if not M.win or not vim.api.nvim_win_is_valid(M.win) then
        return
    end

    local state = M.state
    local raw = M.build_url(state)
    local list = fields(state)
    local label_width = 0
    for _, field in ipairs(list) do
        label_width = math.max(label_width, #field.label)
    end

    local lines = {}
    local rows = {}
    local highlights = {}
    local width = 0

    for _, field in ipairs(list) do
        local line = string.format("%-" .. label_width .. "s  %s", field.label, display_value(state, field, raw))
        lines[#lines + 1] = line
        rows[#lines] = field
        width = math.max(width, vim.fn.strdisplaywidth(line))

        highlights[#highlights + 1] = { #lines, 0, label_width, "Comment" }
        local value_start = label_width + 2
        if field.key == "password" or field.key == "url" then
            highlights[#highlights + 1] = { #lines, value_start, #line, "Comment" }
        end
    end

    lines[#lines + 1] = ""
    local help = "<CR> edit  Tab next  <C-s>/S save  <Esc> cancel"
    lines[#lines + 1] = help
    highlights[#highlights + 1] = { #lines, 0, #help, "Comment" }

    width = math.min(math.max(width + 2, #help), math.max(20, vim.o.columns - 8))
    local height = #lines
    local config = {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = " Add connection ",
        title_pos = "center",
    }
    vim.api.nvim_win_set_config(M.win, config)

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(M.buf, -1, 0, -1)
    local namespace = vim.api.nvim_create_namespace("lua_dadbod_form")
    for _, item in ipairs(highlights) do
        vim.api.nvim_buf_set_extmark(M.buf, namespace, item[1] - 1, item[2], {
            end_col = item[3],
            hl_group = item[4],
        })
    end

    M.rows = rows
    vim.wo[M.win].wrap = false
    vim.wo[M.win].number = false
    vim.wo[M.win].relativenumber = false
    vim.wo[M.win].cursorline = false
    cursor(vim.fn.line("."))
end

local function save()
    local state = M.state
    if state.port ~= "" and not state.port:match("^%d+$") then
        util.error("port must be a number")
        return
    end

    local raw, err = M.build_url(state)
    if not raw then
        util.error(err)
        return
    end

    local parsed, adapter = db.parse(raw)
    if not parsed then
        util.error(adapter or "invalid connection URL")
        return
    end

    local name = util.trim(state.name)
    if name == "" then
        name = state.raw_url and url.display_name(parsed, "db") or M.default_name(state)
    end

    local ok = M.on_save and M.on_save(url.format(parsed), name)
    if ok == false then
        return
    end
    close()
end

function M.save()
    save()
end

local function edit()
    local field = M.rows[vim.fn.line(".")]
    if not field then
        return
    end

    local state = M.state
    local win = M.win

    if field.key == "adapter" then
        local labels = {}
        for _, item in ipairs(adapters) do
            labels[#labels + 1] = item.label
        end
        vim.ui.select(labels, { prompt = "Connection type" }, function(_, index)
            if not index or M.win ~= win then
                return
            end
            local previous = adapter_info(state.adapter)
            local chosen = adapters[index]
            state.adapter = chosen.name
            if state.port == "" or state.port == previous.port then
                state.port = chosen.port
            end
            state.raw_url = nil
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
            end
            render()
            cursor(1)
        end)
        return
    end

    if field.key == "url" then
        local current = state.raw_url or M.build_url(state) or ""
        util.input("Raw URL: ", current, function(value)
            if value == nil or M.win ~= win then
                return
            end
            value = util.trim(value)
            state.raw_url = value ~= "" and value or nil
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_set_current_win(win)
            end
            render()
            focus_row(field.key)
        end)
        return
    end

    if field.key == "password" then
        local value = vim.fn.inputsecret(field.label .. ": ")
        state.password = value
        state.raw_url = nil
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
        end
        render()
        focus_row(field.key)
        return
    end

    util.input(field.label .. ": ", state[field.key] or "", function(value)
        if value == nil or M.win ~= win then
            return
        end
        state[field.key] = util.trim(value)
        state.raw_url = nil
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
        end
        render()
        focus_row(field.key)
    end)
end

function M.open(opts, on_save)
    if type(opts) == "function" then
        on_save, opts = opts, {}
    end
    opts = opts or {}
    close()

    local state = {
        adapter = opts.adapter or "postgresql",
        name = opts.name or "",
        host = opts.host or "localhost",
        port = opts.port or adapter_info(opts.adapter).port,
        user = opts.user or "",
        password = opts.password or "",
        database = opts.database or "",
        file = opts.file or "",
        raw_url = opts.url,
    }
    if state.adapter ~= "sqlite" and state.port == "" then
        state.port = adapter_info(state.adapter).port
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "lua_dadbod_form"

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 20,
        height = 5,
        style = "minimal",
        border = "rounded",
        title = " Add connection ",
        title_pos = "center",
    })

    M.win = win
    M.buf = buf
    M.state = state
    M.on_save = on_save
    M.rows = {}

    vim.keymap.set("n", "<CR>", edit, { buffer = buf, silent = true, nowait = true, desc = "Edit field" })
    vim.keymap.set("n", "<C-s>", save, { buffer = buf, silent = true, nowait = true, desc = "Save connection" })
    vim.keymap.set("n", "S", save, { buffer = buf, silent = true, nowait = true, desc = "Save connection" })
    vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true, desc = "Cancel" })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true, desc = "Cancel" })
    vim.keymap.set("n", "<Tab>", function()
        cursor((vim.fn.line(".") % #M.rows) + 1)
    end, { buffer = buf, silent = true, nowait = true, desc = "Next field" })
    vim.keymap.set("n", "<S-Tab>", function()
        cursor(((vim.fn.line(".") - 2) % #M.rows) + 1)
    end, { buffer = buf, silent = true, nowait = true, desc = "Previous field" })

    render()
    cursor(1)
    return win
end

return M

local config = require("lua-dadbod.config")
local job = require("lua-dadbod.job")
local result_table = require("lua-dadbod.result_table")
local util = require("lua-dadbod.util")

local M = {}
local next_id = 1
local jobs = {}
local highlight_ns = vim.api.nvim_create_namespace("lua_dadbod_result")

vim.api.nvim_set_hl(0, "LuaDadbodResultHeader", { link = "Title", default = true })

local function set_lines(bufnr, lines)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

local function get_meta(bufnr)
    return vim.b[bufnr].lua_dadbod_result
end

local function set_meta(bufnr, meta)
    vim.b[bufnr].lua_dadbod_result = meta
end

local function find_window(bufnr)
    local windows = vim.fn.win_findbuf(bufnr)
    return windows and windows[1] or nil
end

local function find_result_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.b[buf].lua_dadbod_result then
            return win
        end
    end
end

local function style_window(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
end

local function show(bufnr)
    local win = find_window(bufnr)
    if win then
        style_window(win)
        return
    end
    local target = find_result_window()
    if target then
        vim.api.nvim_win_set_buf(target, bufnr)
        style_window(target)
        return
    end
    target = util.open_split({
        bufnr = bufnr,
        restore = true,
        height = config.get().result.height,
    })
    if target then
        style_window(target)
    end
end

local function header(bufnr)
    local meta = get_meta(bufnr) or {}
    local name = meta.name or "result"
    if meta.status == "running" then
        return string.format("-- lua-dadbod: %s | running...", name)
    end
    local elapsed = meta.elapsed and string.format("%.3fs", meta.elapsed) or "-"
    local code = meta.code ~= nil and tostring(meta.code) or "-"
    if meta.rows ~= nil then
        return string.format(
            "-- lua-dadbod: %s | %s | %d rows | %s | exit %s",
            name,
            meta.status or "unknown",
            meta.rows,
            elapsed,
            code
        )
    end
    return string.format("-- lua-dadbod: %s | %s | %s | exit %s", name, meta.status or "unknown", elapsed, code)
end

local function parse_table(meta, stdout)
    if not meta or not meta.format or not meta.returns_rows then
        return nil
    end
    local columns, rows = result_table.table(stdout, meta.format)
    if not columns then
        return nil
    end
    return { columns = columns, rows = rows }
end

local function result_lines(bufnr, result, parsed)
    local lines = { header(bufnr) }
    local max_lines = config.get().result.max_lines or 10000
    if not parsed then
        parsed = parse_table(get_meta(bufnr), result.stdout)
    end

    local function append(title, text)
        if #lines >= max_lines then
            return
        end
        local body = util.split_lines(text or "")
        if #body == 0 then
            return
        end
        if title then
            lines[#lines + 1] = ""
            lines[#lines + 1] = title
        end
        for _, line in ipairs(body) do
            if #lines >= max_lines then
                break
            end
            lines[#lines + 1] = line
        end
    end

    if parsed then
        append(nil, table.concat(result_table.render(parsed.columns, parsed.rows), "\n"))
    else
        append(nil, result.stdout)
    end
    append("-- stderr", result.stderr)

    if #lines == 1 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "(no output)"
    end

    if #lines >= max_lines then
        lines[#lines + 1] = string.format("-- output truncated at %d lines", max_lines)
    end

    return lines
end

function M.open(opts)
    opts = opts or {}

    local id = next_id
    local bufnr
    while true do
        local name = "lua-dadbod://result/" .. id
        if vim.fn.bufnr(name) == -1 then
            bufnr = vim.api.nvim_create_buf(false, true)
            pcall(vim.api.nvim_buf_set_name, bufnr, name)
            break
        end
        id = id + 1
    end
    next_id = id + 1

    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "lua_dadbod_result"

    jobs[bufnr] = nil
    set_meta(bufnr, {
        source_buf = opts.source_buf,
        conn = opts.conn,
        conn_key = opts.conn_key,
        name = opts.name,
        sql = opts.sql,
        format = opts.format,
        returns_rows = opts.returns_rows == true,
        status = "running",
        started = util.now_ns(),
        generation = 1,
    })
    set_lines(bufnr, { header(bufnr) })
    M.keymaps(bufnr)

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            M.cancel(bufnr)
        end,
    })

    show(bufnr)
    return bufnr
end

function M.reset(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if jobs[bufnr] then
        job.cancel(jobs[bufnr])
        jobs[bufnr] = nil
    end
    opts = opts or {}
    local meta = get_meta(bufnr) or {}
    meta.source_buf = opts.source_buf or meta.source_buf
    meta.conn = opts.conn
    meta.conn_key = opts.conn_key or meta.conn_key
    meta.name = opts.name
    meta.sql = opts.sql
    meta.format = opts.format or meta.format
    meta.returns_rows = opts.returns_rows == true
    meta.status = "running"
    meta.started = util.now_ns()
    meta.code = nil
    meta.elapsed = nil
    meta.rows = nil
    meta.generation = (meta.generation or 0) + 1
    set_meta(bufnr, meta)
    set_lines(bufnr, { header(bufnr) })
    show(bufnr)
    return true
end

function M.update(bufnr, result)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    jobs[bufnr] = nil
    local meta = get_meta(bufnr) or {}
    meta.code = result.code
    meta.elapsed = result.elapsed
    meta.timed_out = result.timed_out
    if result.timed_out or (result.signal and result.signal ~= 0) then
        meta.status = "aborted"
    elseif result.code == 0 then
        meta.status = "done"
    else
        meta.status = "error"
    end

    local parsed = parse_table(meta, result.stdout)
    meta.rows = parsed and #parsed.rows or nil
    set_meta(bufnr, meta)
    set_lines(bufnr, result_lines(bufnr, result, parsed))
    if parsed then
        vim.api.nvim_buf_add_highlight(bufnr, highlight_ns, "LuaDadbodResultHeader", 1, 0, -1)
    end
end

function M.set_job(bufnr, handle)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        job.cancel(handle)
        return false
    end
    jobs[bufnr] = handle
    return true
end

function M.cancel(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local handle = jobs[bufnr]
    if handle then
        job.cancel(handle)
        jobs[bufnr] = nil
        local meta = get_meta(bufnr)
        if meta then
            meta.status = "aborted"
            set_meta(bufnr, meta)
        end
    end
end

function M.close(bufnr)
    local wins = vim.fn.win_findbuf(bufnr)
    for _, win in ipairs(wins) do
        if #vim.api.nvim_list_wins() > 1 or #vim.api.nvim_list_tabpages() > 1 then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.cmd, "bdelete " .. bufnr)
    end
end

function M.rerun(bufnr)
    local meta = get_meta(bufnr)
    if not meta or not meta.sql or meta.sql == "" then
        util.warn("nothing to rerun")
        return
    end
    local _, err = require("lua-dadbod.execute").run(meta.sql, {
        bufnr = meta.source_buf,
        conn = meta.conn,
        conn_key = meta.conn_key,
        name = meta.name,
    })
    if err then
        util.error(err)
    end
end

function M.keymaps(bufnr)
    if not config.mappings_enabled("result") then
        return
    end

    vim.keymap.set("n", "q", function()
        M.close(bufnr)
    end, { buffer = bufnr, silent = true, nowait = true, desc = "Close lua-dadbod result" })

    vim.keymap.set("n", "R", function()
        M.rerun(bufnr)
    end, { buffer = bufnr, silent = true, nowait = true, desc = "Rerun lua-dadbod query" })

    vim.keymap.set("n", "<C-c>", function()
        M.cancel(bufnr)
    end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel lua-dadbod query" })
end

function M.header(bufnr)
    return header(bufnr)
end

function M.lines(bufnr, result)
    return result_lines(bufnr, result)
end

return M

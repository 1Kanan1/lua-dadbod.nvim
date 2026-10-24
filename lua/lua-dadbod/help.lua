local M = {
    win = nil,
    buf = nil,
}

function M.close()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
    end
    if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
        pcall(vim.api.nvim_buf_delete, M.buf, { force = true })
    end
    M.win = nil
    M.buf = nil
end

function M.open(title, entries)
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        M.close()
        return
    end

    local key_width = 0
    for _, entry in ipairs(entries) do
        if not entry.section then
            key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
        end
    end

    local lines = {}
    local keys = {}
    local sections = {}
    local width = vim.fn.strdisplaywidth(title or "")

    for _, entry in ipairs(entries) do
        if entry.section then
            if #lines > 0 then
                lines[#lines + 1] = ""
            end
            lines[#lines + 1] = entry.section
            sections[#lines] = true
            width = math.max(width, vim.fn.strdisplaywidth(entry.section))
        else
            local line = string.format("%-" .. key_width .. "s  %s", entry[1], entry[2])
            lines[#lines + 1] = line
            keys[#lines] = entry[1]
            width = math.max(width, vim.fn.strdisplaywidth(line))
        end
    end

    width = math.min(width + 2, math.max(20, vim.o.columns - 8))
    local height = math.min(#lines, math.max(5, vim.o.lines - 5))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "lua_dadbod_help"

    vim.api.nvim_set_hl(0, "LuaDadbodHelpKey", { link = "Identifier", default = true })
    vim.api.nvim_set_hl(0, "LuaDadbodHelpDesc", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "LuaDadbodHelpSection", { link = "Title", default = true })

    local namespace = vim.api.nvim_create_namespace("lua_dadbod_help")
    for index, key in pairs(keys) do
        vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, {
            end_col = #key,
            hl_group = "LuaDadbodHelpKey",
        })
        vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, key_width + 2, {
            end_col = #lines[index],
            hl_group = "LuaDadbodHelpDesc",
        })
    end
    for index in pairs(sections) do
        vim.api.nvim_buf_set_extmark(buf, namespace, index - 1, 0, {
            end_col = #lines[index],
            hl_group = "LuaDadbodHelpSection",
        })
    end

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " " .. (title or "help") .. " ",
        title_pos = "center",
    })

    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false

    local function close()
        M.close()
    end
    for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
        vim.keymap.set("n", lhs, close, {
            buffer = buf,
            silent = true,
            nowait = true,
            desc = "Close lua-dadbod help",
        })
    end

    M.win = win
    M.buf = buf
    return win
end

return M

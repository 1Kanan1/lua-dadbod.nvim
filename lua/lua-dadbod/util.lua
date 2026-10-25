local M = {}

function M.trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.ellipsis(value, max)
    local text = tostring(value or "")
    if max <= 0 then
        return ""
    end
    if vim.fn.strdisplaywidth(text) <= max then
        return text
    end

    local out = text
    while out ~= "" and vim.fn.strdisplaywidth(out .. "…") > max do
        out = vim.fn.strcharpart(out, 0, math.max(0, vim.fn.strchars(out) - 1))
    end
    return out .. "…"
end

function M.slug(value)
    local slug = tostring(value or ""):gsub("[^%w_-]", "_")
    slug = slug:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if slug == "" then
        return "db"
    end
    return slug
end

function M.ensure_dir(path)
    if path and path ~= "" and vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, "p")
    end
end

function M.read_file(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return nil, "cannot read " .. tostring(path) .. ": " .. tostring(lines)
    end
    return lines
end

function M.write_file(path, lines)
    M.ensure_dir(vim.fs.dirname(path))
    local ok, err = pcall(vim.fn.writefile, lines, path)
    if not ok then
        return nil, "cannot write " .. tostring(path) .. ": " .. tostring(err)
    end
    return true
end

function M.read_json(path)
    local lines, err = M.read_file(path)
    if not lines then
        return nil, err
    end
    local text = table.concat(lines, "\n")
    if M.trim(text) == "" then
        return nil, "empty JSON file: " .. tostring(path)
    end
    local ok, data = pcall(vim.json.decode, text)
    if not ok then
        return nil, "invalid JSON in " .. tostring(path) .. ": " .. tostring(data)
    end
    return data
end

function M.write_json(path, data)
    local ok, encoded = pcall(vim.json.encode, data)
    if not ok then
        return nil, "cannot encode JSON: " .. tostring(encoded)
    end
    return M.write_file(path, { encoded })
end

function M.notify(message, level)
    vim.notify("[lua-dadbod] " .. tostring(message), level or vim.log.levels.INFO)
end

function M.warn(message)
    M.notify(message, vim.log.levels.WARN)
end

function M.error(message)
    M.notify(message, vim.log.levels.ERROR)
end

function M.is_executable(binary)
    return type(binary) == "string" and binary ~= "" and vim.fn.executable(binary) == 1
end

function M.now_ns()
    return vim.uv.hrtime()
end

function M.elapsed_ms(start_ns)
    return (vim.uv.hrtime() - start_ns) / 1e6
end

function M.split_lines(text)
    local normalized = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = vim.split(normalized, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

local function is_normal(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.api.nvim_win_get_config(win).relative == "" and not vim.b[buf].lua_dadbod_drawer
end

local function normal_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if is_normal(win) then
            return win
        end
    end
end

local function window_to_the_right()
    local winnr = vim.fn.winnr("l")
    if winnr == 0 then
        return nil
    end
    local win = vim.fn.win_getid(winnr)
    if win == 0 or not is_normal(win) then
        return nil
    end
    return win
end

function M.drop_empty_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if #vim.fn.win_findbuf(bufnr) > 0 then
        return
    end
    if vim.api.nvim_buf_get_name(bufnr) ~= "" then
        return
    end
    if not vim.api.nvim_get_option_value("buflisted", { buf = bufnr }) then
        return
    end
    if vim.api.nvim_get_option_value("modified", { buf = bufnr }) then
        return
    end
    if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
        return
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.open_split(opts)
    opts = opts or {}
    local current = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current)
    local current_drawer = vim.b[current_buf].lua_dadbod_drawer == true
    local current_float = vim.api.nvim_win_get_config(current).relative ~= ""
    local target

    if current_drawer then
        target = window_to_the_right()
    elseif current_float then
        target = normal_window()
    elseif opts.reuse then
        target = current
    end

    if opts.reuse and not opts.split and target then
        if opts.bufnr then
            vim.api.nvim_win_set_buf(target, opts.bufnr)
        end
        vim.api.nvim_set_current_win(target)
        return target
    end

    if target then
        vim.api.nvim_set_current_win(target)
    end

    local command
    if opts.split == "vsplit" or (current_drawer and not target) then
        command = "botright vsplit"
    else
        command = "botright split"
    end
    local parent_height = vim.api.nvim_win_get_height(0)
    if not pcall(vim.cmd, command) then
        if not pcall(vim.cmd, "tabnew") then
            return nil
        end
    end
    local win = vim.api.nvim_get_current_win()
    if opts.bufnr then
        vim.api.nvim_win_set_buf(win, opts.bufnr)
    end
    if opts.height and opts.height > 0 and command == "botright split" then
        local height = math.floor(parent_height * opts.height)
        height = math.max(1, math.min(height, parent_height - 1))
        pcall(vim.api.nvim_win_set_height, win, height)
    end
    if opts.restore then
        vim.api.nvim_set_current_win(current)
    end
    return win
end

function M.input(prompt, default, callback)
    vim.ui.input({ prompt = prompt, default = default }, function(value)
        if value ~= nil then
            callback(value)
        end
    end)
end

function M.select(items, prompt, callback)
    vim.ui.select(items, { prompt = prompt }, function(item)
        if item ~= nil then
            callback(item)
        end
    end)
end

return M

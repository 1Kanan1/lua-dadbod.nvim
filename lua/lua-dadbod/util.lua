local M = {}

function M.trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
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

function M.open_split(opts)
	opts = opts or {}
	local current = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_win_get_buf(current)
	if vim.api.nvim_win_get_config(current).relative ~= "" or vim.b[current_buf].lua_dadbod_drawer then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.api.nvim_win_get_config(win).relative == "" and not vim.b[buf].lua_dadbod_drawer then
				vim.api.nvim_set_current_win(win)
				break
			end
		end
	end

	local command = opts.split == "vsplit" and "botright vsplit" or "botright split"
	if not pcall(vim.cmd, command) then
		if not pcall(vim.cmd, "tabnew") then
			return nil
		end
	end
	local target = vim.api.nvim_get_current_win()
	if opts.bufnr then
		vim.api.nvim_win_set_buf(target, opts.bufnr)
	end
	if opts.restore then
		vim.api.nvim_set_current_win(current)
	end
	return target
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

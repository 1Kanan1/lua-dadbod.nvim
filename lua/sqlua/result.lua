local config = require("sqlua.config")
local job = require("sqlua.job")
local util = require("sqlua.util")

local M = {}
local next_id = 1
local jobs = {}

local function set_lines(bufnr, lines)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

local function get_meta(bufnr)
	return vim.b[bufnr].sqlua_result
end

local function set_meta(bufnr, meta)
	vim.b[bufnr].sqlua_result = meta
end

local function find_window(bufnr)
	local windows = vim.fn.win_findbuf(bufnr)
	return windows and windows[1] or nil
end

local function show(bufnr)
	if find_window(bufnr) then
		return
	end
	util.open_split({ bufnr = bufnr, restore = true })
end

local function header(bufnr)
	local meta = get_meta(bufnr) or {}
	local name = meta.name or "result"
	if meta.status == "running" then
		return string.format("-- sqlua: %s | running...", name)
	end
	local elapsed = meta.elapsed and string.format("%.3fs", meta.elapsed) or "-"
	local code = meta.code ~= nil and tostring(meta.code) or "-"
	return string.format("-- sqlua: %s | %s | %s | exit %s", name, meta.status or "unknown", elapsed, code)
end

local function result_lines(bufnr, result)
	local lines = { header(bufnr) }
	local max_lines = config.get().result.max_lines or 10000

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

	append(nil, result.stdout)
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
		local name = "sqlua://result/" .. id
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
	vim.bo[bufnr].filetype = "sqlua_result"

	jobs[bufnr] = nil
	set_meta(bufnr, {
		source_buf = opts.source_buf,
		conn = opts.conn,
		conn_key = opts.conn_key,
		name = opts.name,
		sql = opts.sql,
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
	meta.status = "running"
	meta.started = util.now_ns()
	meta.code = nil
	meta.elapsed = nil
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
	set_meta(bufnr, meta)
	set_lines(bufnr, result_lines(bufnr, result))
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
	local _, err = require("sqlua.execute").run(meta.sql, {
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
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Close sqlua result" })

	vim.keymap.set("n", "R", function()
		M.rerun(bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Rerun sqlua query" })

	vim.keymap.set("n", "<C-c>", function()
		M.cancel(bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Cancel sqlua query" })
end

function M.header(bufnr)
	return header(bufnr)
end

function M.lines(bufnr, result)
	return result_lines(bufnr, result)
end

return M

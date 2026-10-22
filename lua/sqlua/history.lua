local util = require("sqlua.util")

local M = {
	entries = {},
	max = 50,
	preview = {},
}

local function status_for(entry)
	if entry.status then
		return entry.status
	end
	if entry.timed_out or (entry.signal and entry.signal ~= 0) then
		return "aborted"
	end
	if entry.code == 0 then
		return "ok"
	end
	return "error"
end

function M.add(entry)
	if type(entry) ~= "table" or type(entry.sql) ~= "string" or util.trim(entry.sql) == "" then
		return
	end

	entry.time = entry.time or os.time()
	entry.status = status_for(entry)

	for index = #M.entries, 1, -1 do
		local existing = M.entries[index]
		if existing.conn == entry.conn and existing.sql == entry.sql then
			table.remove(M.entries, index)
		end
	end

	table.insert(M.entries, 1, entry)
	while #M.entries > M.max do
		table.remove(M.entries)
	end

	local drawer = package.loaded["sqlua.drawer"]
	if drawer and drawer.is_open() then
		pcall(drawer.render)
	end
end

function M.list()
	return M.entries
end

function M.remove(entry)
	for index = #M.entries, 1, -1 do
		if M.entries[index] == entry then
			table.remove(M.entries, index)
			break
		end
	end
	if M.preview.entry == entry then
		M.close_preview()
	end
end

function M.clear()
	M.entries = {}
	M.close_preview()
end

function M.preview_text(entry)
	local text = tostring(entry.sql or ""):gsub("%s+", " ")
	text = util.trim(text)
	if vim.fn.strchars(text) > 80 then
		text = vim.fn.strcharpart(text, 0, 77) .. "..."
	end
	return text
end

local function preview_lines(entry)
	local ui = require("sqlua.ui")
	local label = ui.connection_label(entry.dbms, entry.name)
	local header = string.format(
		"-- %s | %s | %s | %.3fs",
		label,
		os.date("%H:%M:%S", entry.time or os.time()),
		status_for(entry),
		entry.elapsed or 0
	)

	local lines = { header, "" }
	local sql_lines = util.split_lines(entry.sql)
	if #sql_lines == 0 then
		lines[#lines + 1] = "(empty query)"
	else
		for _, line in ipairs(sql_lines) do
			lines[#lines + 1] = line
		end
	end
	return lines
end

local function geometry()
	local columns = vim.o.columns
	local rows = vim.o.lines
	local width = math.min(100, math.max(40, math.floor(columns * 0.6)))
	local height = math.min(20, math.max(8, math.floor(rows * 0.5)))
	local row = math.max(0, math.floor((rows - height) / 2) - 1)
	local col = math.max(0, math.floor((columns - width) / 2))
	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " sqlua history ",
		title_pos = "center",
	}
end

local function resize_preview()
	if M.preview.win and vim.api.nvim_win_is_valid(M.preview.win) then
		pcall(vim.api.nvim_win_set_config, M.preview.win, geometry())
	end
end

local function create_preview_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	local name = "sqlua://history"
	if vim.fn.bufnr(name) ~= -1 then
		name = "sqlua://history/" .. tostring(vim.uv.hrtime())
	end
	pcall(vim.api.nvim_buf_set_name, bufnr, name)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "sql"
	vim.bo[bufnr].modifiable = false

	vim.keymap.set("n", "q", function()
		M.close_preview()
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Close sqlua history preview" })
	vim.keymap.set("n", "<Esc>", function()
		M.close_preview()
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Close sqlua history preview" })
	vim.keymap.set("n", "R", function()
		M.rerun(M.preview.entry)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Rerun sqlua history query" })

	return bufnr
end

function M.preview_entry(entry)
	if not entry then
		return
	end

	local ui = require("sqlua.ui")
	local lines = preview_lines(entry)

	local bufnr = M.preview.buf
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		bufnr = create_preview_buffer()
		M.preview.buf = bufnr
	end

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	local win = M.preview.win
	if not win or not vim.api.nvim_win_is_valid(win) then
		win = vim.api.nvim_open_win(bufnr, true, geometry())
		M.preview.win = win
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true
		vim.wo[win].cursorline = true
		vim.wo[win].number = true
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
	else
		vim.api.nvim_win_set_buf(win, bufnr)
		vim.api.nvim_win_set_config(win, geometry())
		vim.api.nvim_set_current_win(win)
	end

	if not M.preview.augroup then
		M.preview.augroup = vim.api.nvim_create_augroup("sqlua_history_preview", { clear = true })
		vim.api.nvim_create_autocmd("VimResized", {
			group = M.preview.augroup,
			callback = resize_preview,
		})
	end

	M.preview.entry = entry
	M.preview.label = ui.connection_label(entry.dbms, entry.name)
end

function M.close_preview()
	local win = M.preview.win
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	local bufnr = M.preview.buf
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
	M.preview.win = nil
	M.preview.buf = nil
	M.preview.entry = nil
	M.preview.label = nil
end

function M.rerun(entry)
	if not entry then
		return
	end
	local result_buf, err = require("sqlua.execute").run(entry.sql, {
		conn = entry.conn,
		name = entry.name,
		conn_key = entry.key,
	})
	if not result_buf then
		util.error(err or "could not rerun query")
		return nil, err
	end
	M.close_preview()
	return result_buf
end

return M

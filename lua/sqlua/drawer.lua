local config = require("sqlua.config")
local db = require("sqlua.db")
local history = require("sqlua.history")
local query = require("sqlua.query")
local ui = require("sqlua.ui")
local util = require("sqlua.util")

local M = {
	rows = {},
	show_details = false,
	scratchpads_expanded = false,
	history_expanded = false,
}

local highlight_ns = vim.api.nvim_create_namespace("sqlua_drawer")
local highlights_ready = false

local function setup_highlights()
	if highlights_ready then
		return
	end
	highlights_ready = true

	local groups = {
		SqluaChevron = "Comment",
		SqluaDb = "DiagnosticOk",
		SqluaTable = "Function",
		SqluaSchema = "Type",
		SqluaScratchpads = "WarningMsg",
		SqluaScratchpad = "Normal",
		SqluaHistory = "DiagnosticOk",
		SqluaHistoryEntry = "Comment",
		SqluaHelp = "Comment",
		SqluaCount = "Comment",
		SqluaActive = "DiagnosticOk",
	}
	for name, link in pairs(groups) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

local function mappings_enabled()
	local mappings = config.get().mappings
	if mappings == false then
		return false
	end
	if not mappings then
		return true
	end
	if mappings.enabled == false then
		return false
	end
	return mappings.drawer ~= false
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
		highlights[#highlights + 1] = { start, #text, "SqluaChevron" }
		text = text .. " "
	end

	if type_icon ~= "" then
		local start = #text
		text = text .. type_icon
		highlights[#highlights + 1] = { start, #text, row.icon_hl or "SqluaChevron" }
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
		highlights[#highlights + 1] = { start, #text, "SqluaCount" }
	end

	if marker ~= "" then
		local start = #text + 1
		text = text .. " " .. marker
		highlights[#highlights + 1] = { start, #text, "SqluaActive" }
	end

	return text, highlights
end

function M.find_win()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.b[buf].sqlua_drawer then
			return win, buf
		end
	end
	return nil, nil
end

function M.is_open()
	local win = M.find_win()
	return win ~= nil
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

	vim.b[buf].sqlua_drawer = true
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "sqlua"

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
	local win = M.find_win()
	if win then
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
	if not mappings_enabled() then
		return
	end

	local function map(lhs, callback, desc)
		vim.keymap.set("n", lhs, callback, {
			buffer = buf,
			silent = true,
			nowait = true,
			desc = desc,
		})
	end

	map("<CR>", function()
		M.select("edit")
	end, "Open sqlua drawer item")
	map("o", function()
		M.select("edit")
	end, "Open sqlua drawer item")
	map("S", function()
		M.select("vsplit")
	end, "Open sqlua drawer item in a vertical split")
	map("n", function()
		M.new_scratchpad()
	end, "New sqlua scratchpad")
	map("C", function()
		M.columns()
	end, "Show sqlua table columns")
	map("A", function()
		M.add_connection()
	end, "Add sqlua connection")
	map("r", function()
		M.rename()
	end, "Rename sqlua scratchpad")
	map("d", function()
		M.delete()
	end, "Delete sqlua item")
	map("R", function()
		M.refresh()
	end, "Refresh sqlua connections")
	map("H", function()
		M.toggle_details()
	end, "Toggle sqlua connection details")
	map("q", function()
		M.close()
	end, "Close sqlua drawer")
	map("?", function()
		M.help()
	end, "Show sqlua drawer help")
end

function M.render()
	setup_highlights()
	local win, buf = M.find_win()
	if not win or not buf then
		return
	end

	local entries = ui.connections()
	local icons = config.get().icons or {}
	local expanded = icons.expanded or ""
	local collapsed = icons.collapsed or ""
	local active = ui.active()

	local rows = {}
	local function add(row)
		rows[#rows + 1] = row
	end

	if #entries == 0 then
		add({
			kind = "help",
			level = 0,
			label = "No connections. Press A to add one.",
			label_hl = "SqluaHelp",
		})
	end

	for _, entry in ipairs(entries) do
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
			icon_hl = "SqluaDb",
			label = ui.connection_label(entry.dbms, entry.name),
			suffix = table.concat(suffix, " "),
			marker = active == entry.key and icons.active or "",
			key = entry.key,
		})

		if entry.expanded then
			local tables = entry.tables or {}
			add({
				kind = "section",
				section = "tables",
				level = 1,
				icon = entry.tables_expanded and expanded or collapsed,
				type_icon = icons.table,
				icon_hl = "SqluaTable",
				label = "Tables",
				suffix = entry.loading and "(loading...)" or ("(" .. #tables .. ")"),
				key = entry.key,
			})

			if entry.tables_expanded then
				if entry.error then
					add({
						kind = "help",
						level = 2,
						icon = "!",
						label = entry.error,
						label_hl = "DiagnosticError",
						key = entry.key,
					})
				elseif entry.loading then
					add({
						kind = "help",
						level = 2,
						label = "loading...",
						label_hl = "SqluaHelp",
						key = entry.key,
					})
				elseif #tables == 0 then
					add({
						kind = "help",
						level = 2,
						label = "(no tables)",
						label_hl = "SqluaHelp",
						key = entry.key,
					})
				else
					for _, table_name in ipairs(tables) do
						add({
							kind = "table",
							level = 2,
							type_icon = icons.table,
							icon_hl = "SqluaTable",
							label = table_name,
							table = table_name,
							key = entry.key,
						})
					end
				end
			end
		end
	end

	add({ kind = "spacer", level = 0, label = "" })

	local scratchpads = ui.scratchpads()
	add({
		kind = "section",
		section = "scratchpads",
		level = 0,
		icon = M.scratchpads_expanded and expanded or collapsed,
		type_icon = icons.scratchpads,
		icon_hl = "SqluaScratchpads",
		label = "Scratchpads",
		suffix = "(" .. #scratchpads .. ")",
	})
	if M.scratchpads_expanded then
		if #scratchpads == 0 then
			local hint = #entries == 0 and "No scratchpads." or "No scratchpads. Press n to create one."
			add({ kind = "help", level = 1, label = hint, label_hl = "SqluaHelp" })
		else
			for _, item in ipairs(scratchpads) do
				local mark = (item.unsaved or item.modified) and " *" or ""
				add({
					kind = "scratch",
					level = 1,
					type_icon = icons.scratchpad,
					icon_hl = "SqluaScratchpad",
					label = item.label,
					suffix = "(" .. item.conn_label .. ")" .. mark,
					item = item,
				})
			end
		end
	end

	add({ kind = "spacer", level = 0, label = "" })

	local history_entries = history.list()
	add({
		kind = "section",
		section = "history",
		level = 0,
		icon = M.history_expanded and expanded or collapsed,
		type_icon = icons.history,
		icon_hl = "SqluaHistory",
		label = "History",
		suffix = "(" .. #history_entries .. ")",
	})
	if M.history_expanded then
		if #history_entries == 0 then
			add({ kind = "help", level = 1, label = "No history yet.", label_hl = "SqluaHelp" })
		else
			for _, entry in ipairs(history_entries) do
				local conn_label = ui.connection_label(entry.dbms, entry.name)
				add({
					kind = "history",
					level = 1,
					type_icon = icons.history_entry or "·",
					icon_hl = "SqluaHistoryEntry",
					label = history.preview_text(entry),
					suffix = "("
						.. conn_label
						.. ", "
						.. os.date("%H:%M", entry.time or os.time())
						.. ")",
					entry = entry,
				})
			end
		end
	end

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

function M.fetch(entry)
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
		else
			current.tables = tables or {}
		end
		if M.is_open() then
			M.render()
		end
	end)
end

function M.open_table(entry, table_name, helper, mode, schema)
	local bufnr, err = query.open(entry, {
		table = table_name,
		schema = schema,
		helper = helper,
		split = mode == "vsplit" and "vsplit" or nil,
	})
	if not bufnr then
		util.error(err)
		return
	end
	if M.is_open() then
		M.render()
	end
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
		ui.set_active(entry.key)
		entry.expanded = not entry.expanded
		if entry.expanded and not entry.loaded and not entry.loading then
			M.fetch(entry)
		end
		M.render()
		return
	end

	if row.kind == "section" then
		if row.section == "tables" then
			local entry = ui.get(row.key)
			if entry then
				entry.tables_expanded = not entry.tables_expanded
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
		M.open_table(entry, row.table, "List", mode, row.schema)
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
				ui.set_active(selected.key)
				M.open_new_scratchpad(selected)
			end)
			return
		end
	end

	ui.set_active(entry.key)
	M.open_new_scratchpad(entry)
end

function M.open_new_scratchpad(entry)
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
		M.open_table(entry, row.table, choices[1], "edit", row.schema)
		return
	end

	vim.ui.select(choices, { prompt = "Table helper" }, function(choice)
		if choice then
			M.open_table(entry, row.table, choice, "edit", row.schema)
		end
	end)
end

function M.refresh()
	local row = M.row()
	local entry = row and row.key and ui.get(row.key) or nil

	if entry then
		entry.loaded = false
		entry.error = nil
		entry.tables = {}
		db.clear_meta(entry.url)
		if entry.expanded then
			M.fetch(entry)
		end
	else
		db.clear_meta()
		ui.refresh()
		for _, item in ipairs(ui.connections()) do
			item.loaded = false
			item.error = nil
			item.tables = {}
			if item.expanded then
				M.fetch(item)
			end
		end
	end

	M.render()
end

function M.add_connection()
	ui.add_connection(nil, function()
		if M.is_open() then
			M.render()
		end
	end)
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

		local bufnr = item.kind == "buffer" and item.bufnr or nil
		if item.kind == "file" then
			if vim.fn.delete(item.path) ~= 0 then
				util.error("cannot delete " .. item.path)
				return
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
				util.error("cannot delete " .. item.path)
				return
			end
		end

		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
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
	util.notify(
		"Enter/o open, S vsplit, n new scratchpad, C columns, A add, r rename, d delete, R refresh, H details, q close"
	)
end

return M

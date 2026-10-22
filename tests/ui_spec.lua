local h = require("tests.harness")
local config = require("sqlua.config")
local db = require("sqlua.db")
local query = require("sqlua.query")
local ui = require("sqlua.ui")
local util = require("sqlua.util")

local function restore_globals(previous, directory)
	vim.g.db = previous.db
	vim.g.dbs = previous.dbs
	vim.env.SQLUA_URL = previous.url
	vim.env.SQLUA_NAME = previous.name
	config.setup({
		save_location = previous.save,
		tmp_location = previous.tmp,
	})
	ui.reset()
	if directory then
		vim.fn.delete(directory, "rf")
	end
end

h.test("ui discovers all connection sources", function()
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({
		save_location = directory .. "/sqlua",
		tmp_location = directory .. "/queries",
	})
	util.write_json(directory .. "/sqlua/connections.json", {
		{ name = "filedb", url = "sqlite::memory:" },
	})

	vim.g.db = "sqlite::memory:"
	vim.g.dbs = {
		dev = "sqlite::memory:",
		file = function()
			return "sqlite::memory:"
		end,
	}
	vim.env.SQLUA_URL = "sqlite::memory:"
	vim.env.SQLUA_NAME = "envdb"

	ui.reset()
	local list = ui.refresh()
	local by_key = {}
	for _, entry in ipairs(list) do
		by_key[entry.key] = entry
	end

	h.eq(by_key["default_g:db"].source, "g:db")
	h.eq(by_key["dev_g:dbs"].source, "g:dbs")
	h.eq(by_key["file_g:dbs"].source, "g:dbs")
	h.eq(by_key["envdb_env"].source, "env")
	h.eq(by_key["filedb_file"].source, "file")

	restore_globals(previous, directory)
end)

h.test("db metadata cache fetches tables", function()
	local path = vim.fn.tempname() .. ".db"
	local created = false
	db.run("sqlite:" .. path, "create table users(id integer, name text);", {}, function()
		created = true
	end)
	h.ok(vim.wait(5000, function()
		return created
	end), "could not create test database")

	local tables, err
	db.fetch_tables("sqlite:" .. path, function(value, fetch_err)
		tables = value
		err = fetch_err
	end)
	h.ok(vim.wait(5000, function()
		return tables ~= nil or err ~= nil
	end), "table metadata timed out")
	h.is_nil(err)
	h.ok(vim.tbl_contains(tables, "users"))

	local cached
	db.fetch_tables("sqlite:" .. path, function(value)
		cached = value
	end)
	h.ok(cached, "cached metadata callback did not run")
	h.ok(vim.tbl_contains(cached, "users"))

	vim.fn.delete(path)
end)

h.test("ui adds and deletes file connections", function()
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({ save_location = directory .. "/sqlua" })
	ui.reset()

	ui.add_connection({ name = "added", url = "sqlite::memory:" })
	local entry = ui.get("added_file")
	h.ok(entry)
	h.eq(entry.source, "file")
	h.eq(vim.fn.filereadable(directory .. "/sqlua/connections.json"), 1)

	local ok, err = ui.delete_connection(entry)
	h.ok(ok, err)
	h.is_nil(ui.get("added_file"))

	restore_globals(previous, directory)
end)

h.test(":SqluaFindBuffer attaches the current buffer", function()
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({
		save_location = directory .. "/sqlua",
		tmp_location = directory .. "/queries",
	})
	vim.g.dbs = { only = "sqlite::memory:" }
	ui.reset()

	local bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(bufnr)
	vim.cmd("SqluaFindBuffer")

	h.matches(vim.b[bufnr].sqlua.conn, "sqlite::memory:")
	h.eq(vim.b[bufnr].sqlua.conn_name, "only")

	restore_globals(previous, directory)
end)

h.test("connection labels add the dbms only for multiple dbms", function()
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({ save_location = directory .. "/sqlua" })

	vim.g.dbs = { test = "sqlite::memory:" }
	ui.reset()
	local sqlite = ui.get("test_g:dbs")
	h.eq(ui.connection_label(sqlite.dbms, sqlite.name), "test")

	vim.g.dbs = {
		test = "sqlite::memory:",
		prod = "postgresql://host/database",
	}
	ui.reset()
	sqlite = ui.get("test_g:dbs")
	local postgres = ui.get("prod_g:dbs")
	h.eq(ui.connection_label(sqlite.dbms, sqlite.name), "sqlite/test")
	h.eq(ui.connection_label(postgres.dbms, postgres.name), "postgres/prod")

	restore_globals(previous, directory)
end)

h.test("scratchpads include saved files and open buffers", function()
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({
		save_location = directory .. "/sqlua",
		tmp_location = directory .. "/queries",
	})

	vim.g.dbs = { test = "sqlite::memory:" }
	ui.reset()

	local saved_dir = ui.saved_dir(ui.get("test_g:dbs"))
	util.ensure_dir(saved_dir)
	vim.fn.writefile({ "select 1;" }, saved_dir .. "/saved.sql")

	local bufnr = h.ok(query.open("sqlite::memory:", {
		table = "scratch_users",
		helper = "List",
		auto_execute = false,
	}))

	local scratchpads = ui.scratchpads()
	local by_label = {}
	for _, item in ipairs(scratchpads) do
		by_label[item.label] = item
	end
	h.ok(by_label.saved, "saved scratchpad not found")
	h.eq(by_label.saved.kind, "file")
	h.ok(by_label.scratch_users, "open scratchpad not found")
	h.eq(by_label.scratch_users.kind, "buffer")
	h.eq(by_label.scratch_users.unsaved, true)

	vim.api.nvim_buf_delete(bufnr, { force = true })
	pcall(vim.cmd, "silent! only")
	restore_globals(previous, directory)
end)

h.test("n creates a scratchpad for the active connection", function()
	pcall(vim.cmd, "silent! only")
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	config.setup({
		save_location = directory .. "/sqlua",
		tmp_location = directory .. "/queries",
	})
	vim.g.dbs = { test = "sqlite::memory:" }
	ui.reset()

	local drawer = require("sqlua.drawer")
	drawer.open()
	h.is_nil(ui.active())
	drawer.new_scratchpad()
	h.eq(ui.active(), "test_g:dbs")

	local query_buf = vim.api.nvim_get_current_buf()
	local meta = vim.b[query_buf].sqlua
	h.eq(meta.conn_name, "test")
	h.eq(meta.dbms, "sqlite")
	h.eq(meta.source, "scratch")

	vim.api.nvim_buf_delete(query_buf, { force = true })
	drawer.close()
	h.eq(drawer.is_open(), false)
	pcall(vim.cmd, "silent! only")
	restore_globals(previous, directory)
end)

h.test("drawer expands a connection and opens a table", function()
	pcall(vim.cmd, "silent! only")
	local previous = {
		db = vim.g.db,
		dbs = vim.g.dbs,
		url = vim.env.SQLUA_URL,
		name = vim.env.SQLUA_NAME,
		save = config.get().save_location,
		tmp = config.get().tmp_location,
	}
	local directory = vim.fn.tempname()
	util.ensure_dir(directory)
	config.setup({
		save_location = directory .. "/sqlua",
		tmp_location = directory .. "/queries",
	})

	local path = directory .. "/drawer.db"
	local created = false
	db.run("sqlite:" .. path, "create table users(id integer); insert into users values (1);", {}, function()
		created = true
	end)
	h.ok(vim.wait(5000, function()
		return created
	end), "could not create drawer database")

	vim.g.dbs = { test = "sqlite:" .. path }
	ui.reset()

	local drawer = require("sqlua.drawer")
	h.eq(drawer.scratchpads_expanded, false)
	h.eq(drawer.history_expanded, false)
	drawer.open()
	local drawer_buf = vim.api.nvim_get_current_buf()
	h.eq(vim.b[drawer_buf].sqlua_drawer, true)

	local lines = vim.api.nvim_buf_get_lines(drawer_buf, 0, -1, false)
	local initial_text = table.concat(lines, "\n")
	h.matches(initial_text, "test")
	h.eq(initial_text:find("Add connection", 1, true), nil)
	h.eq(initial_text:find("No scratchpads", 1, true), nil)
	h.eq(initial_text:find("No history yet", 1, true), nil)
	h.eq(vim.fn.hlexists("SqluaDb"), 1)
	h.eq(vim.fn.hlexists("SqluaTable"), 1)
	h.eq(vim.fn.hlexists("SqluaScratchpads"), 1)
	h.eq(vim.fn.hlexists("SqluaHistory"), 1)

	h.eq(ui.is_activated("test_g:dbs"), false)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })
	drawer.select("edit")
	h.eq(ui.is_activated("test_g:dbs"), true)

	local entry = ui.get("test_g:dbs")
	h.ok(vim.wait(5000, function()
		return entry and entry.loaded
	end), "table metadata did not load")

	local visible_table = false
	for _, row in ipairs(drawer.rows) do
		if row.kind == "table" then
			visible_table = true
		end
	end
	h.eq(visible_table, false)

	local tables_line
	for index, row in ipairs(drawer.rows) do
		if row.kind == "section" and row.section == "tables" then
			tables_line = index
			break
		end
	end
	h.ok(tables_line, "Tables section not found")
	vim.api.nvim_win_set_cursor(0, { tables_line, 0 })
	drawer.select("edit")

	lines = vim.api.nvim_buf_get_lines(drawer_buf, 0, -1, false)
	local text = table.concat(lines, "\n")
	h.matches(text, "Tables %(1%)")
	h.matches(text, "users")
	h.matches(text, "Scratchpads")
	h.matches(text, "History")
	h.eq(text:find("New query", 1, true), nil)
	h.eq(text:find("Saved queries", 1, true), nil)

	local table_line
	for index, row in ipairs(drawer.rows) do
		if row.kind == "table" and row.table == "users" then
			table_line = index
			break
		end
	end
	h.ok(table_line, "table row not found")

	vim.api.nvim_win_set_cursor(0, { table_line, 0 })
	drawer.select("edit")
	h.eq(vim.api.nvim_get_current_buf(), drawer_buf)

	h.ok(vim.wait(5000, function()
		return vim.b[drawer_buf].sqlua_result_buf ~= nil
	end), "preview did not start")
	local result_buf = vim.b[drawer_buf].sqlua_result_buf
	h.ok(vim.wait(5000, function()
		local result_meta = vim.b[result_buf].sqlua_result
		return result_meta and result_meta.status ~= "running"
	end), "preview did not finish")
	local result_text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
	h.matches(result_text, "id")

	local drawer_win = drawer.find_win()
	h.ok(drawer_win, "drawer window disappeared")
	vim.api.nvim_set_current_win(drawer_win)
	vim.api.nvim_win_set_cursor(drawer_win, { table_line, 0 })
	drawer.columns()
	h.eq(vim.api.nvim_get_current_buf(), drawer_buf)

	h.ok(vim.wait(5000, function()
		local result_meta = vim.b[result_buf].sqlua_result
		return result_meta and result_meta.status ~= "running"
	end), "columns preview did not finish")
	result_text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
	h.matches(result_text, "name")

	vim.api.nvim_set_current_win(drawer_win)
	vim.api.nvim_win_set_cursor(drawer_win, { table_line, 0 })
	drawer.edit()
	local query_buf = vim.api.nvim_get_current_buf()
	local meta = vim.b[query_buf].sqlua
	h.eq(meta.table, "users")
	h.matches(table.concat(vim.api.nvim_buf_get_lines(query_buf, 0, -1, false), "\n"), "limit 50")
	vim.api.nvim_buf_delete(query_buf, { force = true })

	drawer.close()
	h.eq(drawer.is_open(), false)

	pcall(vim.cmd, "silent! only")
	restore_globals(previous, directory)
end)

h.test("global mappings follow setup", function()
	local sqlua = require("sqlua")
	sqlua.setup({ mappings = { global = true } })
	h.eq(vim.fn.maparg("<leader>Do", "n") ~= "", true)

	sqlua.setup({ mappings = { global = false } })
	h.eq(vim.fn.maparg("<leader>Do", "n"), "")

	sqlua.setup()
end)

h.test("sqlua commands exist", function()
	for _, name in ipairs({
		"Sqlua",
		"SqluaToggle",
		"SqluaClose",
		"SqluaAddConnection",
		"SqluaFindBuffer",
		"SqluaRenameBuffer",
		"SqluaClearCache",
		"SqluaRefresh",
	}) do
		h.eq(vim.fn.exists(":" .. name), 2, name .. " is not registered")
	end
end)

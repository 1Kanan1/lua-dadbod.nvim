local h = require("tests.harness")
local db = require("sqlua.db")
local execute = require("sqlua.execute")

local function wait_for(predicate)
	return vim.wait(5000, predicate, 10)
end

local function result_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

h.test("db.run executes SQL", function()
	local done = false
	local result
	local handle, err = db.run("sqlite::memory:", "select 1 as x;", {}, function(value)
		result = value
		done = true
	end)
	h.ok(handle, err)
	h.ok(wait_for(function()
		return done
	end), "query timed out")
	h.eq(result.code, 0)
	h.matches(result.stdout, "1")
	h.eq(result.timed_out, false)
end)

h.test("execute.run creates a result buffer", function()
	local source = vim.api.nvim_get_current_buf()
	local result_buf, err = execute.run("select 1 as x;", { conn = "sqlite::memory:" })
	h.ok(result_buf, err)
	h.ok(wait_for(function()
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status ~= "running"
	end), "result did not finish")
	local meta = vim.b[result_buf].sqlua_result
	h.eq(meta.status, "done")
	h.eq(meta.code, 0)
	h.matches(result_text(result_buf), "1")
	h.eq(vim.b[source].sqlua_result_buf, result_buf)
end)

h.test(":DB runs a query", function()
	local source = vim.api.nvim_get_current_buf()
	vim.cmd("DB sqlite::memory: select 42 as answer")
	h.ok(wait_for(function()
		local result_buf = vim.b[source].sqlua_result_buf
		if not result_buf or not vim.api.nvim_buf_is_valid(result_buf) then
			return false
		end
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status ~= "running"
	end), "DB command did not finish")
	h.matches(result_text(vim.b[source].sqlua_result_buf), "42")
end)

h.test(":DB runs a range", function()
	local source = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 7 as seven;" })
	vim.cmd("%DB sqlite::memory:")
	h.ok(wait_for(function()
		local result_buf = vim.b[source].sqlua_result_buf
		if not result_buf or not vim.api.nvim_buf_is_valid(result_buf) then
			return false
		end
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status ~= "running"
	end), "range DB command did not finish")
	h.matches(result_text(vim.b[source].sqlua_result_buf), "7")
end)

h.test("result reruns the stored query", function()
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	local result_buf, err = execute.run("select 5 as five;", { conn = "sqlite::memory:" })
	h.ok(result_buf, err)
	h.ok(wait_for(function()
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status == "done"
	end), "first run did not finish")
	h.matches(result_text(result_buf), "5")

	require("sqlua.result").rerun(result_buf)
	h.ok(wait_for(function()
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status == "done"
	end), "rerun did not finish")
	h.matches(result_text(result_buf), "5")
end)

h.test("result cancels a running query", function()
	local source = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_set_current_buf(source)
	local result_buf, err = execute.run(
		"with recursive cnt(x) as (select 1 union all select x + 1 from cnt where x < 1000000000) select max(x) from cnt;",
		{ conn = "sqlite::memory:" }
	)
	h.ok(result_buf, err)
	vim.wait(100)
	require("sqlua.result").cancel(result_buf)
	h.ok(wait_for(function()
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status ~= "running"
	end), "cancel did not finish")
	h.eq(vim.b[result_buf].sqlua_result.status, "aborted")
end)

h.test("query buffer builds helper SQL", function()
	local query = require("sqlua.query")
	local bufnr, err = query.open("sqlite::memory:", {
		table = "users",
		helper = "List",
		auto_execute = false,
	})
	bufnr = h.ok(bufnr, err)
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	h.matches(text, 'select %* from "users" limit 200')
end)

h.test("execute.parse_args", function()
	local connection, statement = execute.parse_args("sqlite::memory: select 1")
	h.eq(connection, "sqlite::memory:")
	h.eq(statement, "select 1")

	connection, statement = execute.parse_args("select 1")
	h.is_nil(connection)
	h.eq(statement, "select 1")

	local file
	connection, statement, file = execute.parse_args("< /tmp/query.sql")
	h.is_nil(connection)
	h.is_nil(statement)
	h.eq(file, "/tmp/query.sql")
end)

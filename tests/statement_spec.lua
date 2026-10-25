local h = require("tests.harness")
local statement = require("lua-dadbod.statement")

local postgres = statement.dialect("postgresql")

h.test("detect metadata changes", function()
    local postgres = statement.dialect("postgresql")
    local mysql = statement.dialect("mysql")

    h.eq(statement.is_metadata_change("create table t (id int);"), true)
    h.eq(statement.is_metadata_change("alter table t add column x int;"), true)
    h.eq(statement.is_metadata_change("drop schema public;"), true)
    h.eq(statement.is_metadata_change("rename table a to b;"), true)
    h.eq(statement.is_metadata_change("select 1; create table t;"), true)
    h.eq(statement.is_metadata_change("/* note */ drop table t;"), true)
    h.eq(statement.is_metadata_change("-- note\ncreate view v as select 1;"), true)

    h.eq(statement.is_metadata_change("select 'create table t';"), false)
    h.eq(statement.is_metadata_change('select "drop" from t;'), false)
    h.eq(statement.is_metadata_change("select 1 -- drop table t\n;"), false)
    h.eq(statement.is_metadata_change("insert into t values (1);"), false)
    h.eq(statement.is_metadata_change("with x as (select 1) select * from x;"), false)
    h.eq(statement.is_metadata_change("do $$ begin create table t; end $$;", postgres), false)

    h.eq(statement.is_metadata_change("# note\nselect 1;", mysql), false)
    h.eq(statement.is_metadata_change("# note\ncreate table t;", mysql), true)
end)

h.test("find the statement under the cursor", function()
    local lines = { "select 1;", "", "select 2;", "select 3;" }
    h.eq(statement.find(lines, 1), { line1 = 1, line2 = 1, code = true })
    h.eq(statement.find(lines, 3), { line1 = 3, line2 = 3, code = true })
    h.eq(statement.find(lines, 4), { line1 = 4, line2 = 4, code = true })
end)

h.test("keep a multi-line statement together", function()
    local lines = {
        "select",
        "  a,",
        "  b",
        "from t;",
        "select 2;",
    }
    h.eq(statement.find(lines, 2), { line1 = 1, line2 = 4, code = true })
end)

h.test("ignore semicolons in strings", function()
    local lines = { "select ';', \";\", 'it''s';", "select 2;" }
    h.eq(statement.find(lines, 1), { line1 = 1, line2 = 1, code = true })
    h.eq(statement.find(lines, 2), { line1 = 2, line2 = 2, code = true })
end)

h.test("ignore semicolons in comments", function()
    local lines = {
        "select 1 -- trailing; comment",
        "/* block;",
        "   still; */ ;",
        "select 2;",
    }
    h.eq(statement.find(lines, 2), { line1 = 1, line2 = 3, code = true })
    h.eq(statement.find(lines, 4), { line1 = 4, line2 = 4, code = true })
end)

h.test("ignore semicolons in dollar quotes", function()
    local lines = {
        "create function f() returns int as $$",
        "begin",
        "  return 1;",
        "end;",
        "$$ language plpgsql;",
        "select 2;",
    }
    h.eq(statement.find(lines, 3, postgres), { line1 = 1, line2 = 5, code = true })
    h.eq(statement.find(lines, 6, postgres), { line1 = 6, line2 = 6, code = true })
end)

h.test("handle backslash escapes only for MySQL", function()
    local lines = { "select 'it\\'s; still';", "select 2;" }
    local mysql = statement.dialect("mysql")
    h.eq(statement.find(lines, 1, mysql), { line1 = 1, line2 = 1, code = true })
    h.eq(statement.find(lines, 2, mysql), { line1 = 2, line2 = 2, code = true })
end)

h.test("fall back to the previous statement on a blank line", function()
    local lines = { "select 1;", "", "", "select 2;" }
    h.eq(statement.find(lines, 2), { line1 = 1, line2 = 1, code = true })
end)

h.test("fall back to the next statement before the first one", function()
    local lines = { "", "", "select 1;" }
    h.eq(statement.find(lines, 1), { line1 = 3, line2 = 3, code = true })
end)

h.test("keep a leading comment with its statement", function()
    local lines = { "-- totals", "select count(*) from t;" }
    h.eq(statement.find(lines, 1), { line1 = 1, line2 = 2, code = true })
end)

h.test("skip a trailing comment-only chunk", function()
    local lines = { "select 1;", "", "-- just a note" }
    h.eq(statement.find(lines, 3), { line1 = 1, line2 = 1, code = true })
end)

h.test("return nil without any statement", function()
    h.is_nil(statement.find({}, 1))
    h.is_nil(statement.find({ "", "  ", "-- nothing" }, 2))
end)

h.test("detect statements that return rows", function()
    h.eq(statement.returns_rows("select 1"), true)
    h.eq(statement.returns_rows("-- note\nwith x as (select 1) select * from x"), true)
    h.eq(statement.returns_rows("insert into t values (1) returning id"), true)
    h.eq(statement.returns_rows("insert into t values (1)"), false)
    h.eq(statement.returns_rows("create table t (id int)"), false)
    h.eq(statement.returns_rows("create table t (id int); drop table t;"), false)
    h.eq(statement.returns_rows("create table t (id int); select * from t;"), false)
    h.eq(statement.returns_rows("select 1; select 2;"), true)
    h.eq(statement.returns_rows("(select 1) union (select 2)"), true)
    h.eq(statement.returns_rows("create table t (note text default 'returning')"), false)
    h.eq(statement.returns_rows(""), false)
end)

h.test("execute the last statement without a semicolon", function()
    local lines = { "select 1;", "select 2" }
    h.eq(statement.find(lines, 2), { line1 = 2, line2 = 2, code = true })
end)

h.test("make Enter run the statement in query buffers", function()
    local config = require("lua-dadbod.config")
    local query = require("lua-dadbod.query")
    config.setup({ mappings = { enabled = true, query = true } })

    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    h.matches(vim.fn.maparg("<CR>", "n", false, true).desc or "", "statement")
    h.matches(vim.fn.maparg("<CR>", "x", false, true).desc or "", "selection")
    vim.api.nvim_buf_delete(bufnr, { force = true })
    config.setup()
end)

h.test("run only the statement under the cursor", function()
    local config = require("lua-dadbod.config")
    local query = require("lua-dadbod.query")
    local save_location = vim.fn.tempname() .. "/lua-dadbod"
    config.setup({ save_location = save_location })

    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "select 1 as first;",
        "select 2 as second;",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    query.run_statement(bufnr)

    local result_buf = vim.b[bufnr].lua_dadbod_result_buf
    h.ok(result_buf, "result buffer was not created")
    h.ok(vim.wait(5000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
        return text:find("second", 1, true) ~= nil
    end), "statement did not finish")

    local text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
    h.matches(text, "second")
    h.eq(text:find("first", 1, true), nil)

    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(vim.cmd, "silent! only")
    vim.fn.delete(save_location, "rf")
    config.setup()
end)

h.test("run only the visual selection", function()
    local config = require("lua-dadbod.config")
    local query = require("lua-dadbod.query")
    local save_location = vim.fn.tempname() .. "/lua-dadbod"
    config.setup({ save_location = save_location, mappings = { enabled = true, query = true } })

    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "select 1 as first;",
        "select 2 as second;",
        "select 3 as third;",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vj<CR>", true, false, true), "x", false)
    h.eq(vim.fn.mode(), "n", "visual mode should end after running a selection")

    local result_buf = vim.b[bufnr].lua_dadbod_result_buf
    h.ok(result_buf, "result buffer was not created")
    h.ok(vim.wait(5000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
        return text:find("second", 1, true) ~= nil
    end), "selection did not finish")

    local text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
    h.matches(text, "second")
    h.eq(text:find("third", 1, true), nil)

    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(vim.cmd, "silent! only")
    vim.fn.delete(save_location, "rf")
    config.setup()
end)

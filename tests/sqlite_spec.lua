local h = require("tests.harness")
local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local execute = require("lua-dadbod.execute")
local query = require("lua-dadbod.query")

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

h.test("db.run warns before creating a missing SQLite file", function()
    local previous = vim.notify
    local notices = {}
    vim.notify = function(message, level)
        notices[#notices + 1] = { message, level }
    end
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local path = directory .. "/new.db"
    local done = false
    local handle, err = db.run("sqlite:" .. path, "select 1;", {}, function()
        done = true
    end)
    local finished = handle ~= nil and wait_for(function()
        return done
    end)
    vim.notify = previous

    h.ok(handle, err)
    h.ok(finished, "query did not finish")
    h.eq(vim.fn.filereadable(path), 1)
    local warned = false
    for _, notice in ipairs(notices) do
        if notice[2] == vim.log.levels.WARN and notice[1]:find("creating an empty database", 1, true) then
            warned = true
        end
    end
    h.eq(warned, true)
    vim.fn.delete(directory, "rf")
end)

h.test("execute.run creates a result buffer", function()
    local source = vim.api.nvim_get_current_buf()
    local result_buf, err = execute.run("select 1 as x;", { conn = "sqlite::memory:" })
    h.ok(result_buf, err)
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "result did not finish")
    local meta = vim.b[result_buf].lua_dadbod_result
    h.eq(meta.status, "done")
    h.eq(meta.code, 0)
    h.matches(result_text(result_buf), "1")
    h.eq(vim.b[source].lua_dadbod_result_buf, result_buf)
    local result_win = vim.fn.win_findbuf(result_buf)[1]
    h.ok(result_win, "result window not found")
    h.eq(vim.wo[result_win].number, false)
    h.eq(vim.wo[result_win].relativenumber, false)
end)

h.test("q closes a result window and its tab", function()
    pcall(vim.cmd, "silent! tabonly")
    vim.cmd("tabnew")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "lua_dadbod_result"
    vim.api.nvim_win_set_buf(0, bufnr)
    require("lua-dadbod.result").keymaps(bufnr)

    vim.cmd("normal q")

    h.eq(vim.api.nvim_buf_is_valid(bufnr), false)
    h.eq(#vim.api.nvim_list_tabpages(), 1)
end)

h.test("result buffers render a table", function()
    local result_buf, err = execute.run(
        "select 1 as id, 'Alice' as name union all select 2, 'Bob';",
        { conn = "sqlite::memory:" }
    )
    h.ok(result_buf, err)
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "table query did not finish")

    local text = result_text(result_buf)
    h.matches(text, "2 rows")
    h.matches(text, "id  name")
    h.matches(text, "Alice")
    h.matches(text, "Bob")
end)

h.test(":DB runs a query", function()
    local source = vim.api.nvim_get_current_buf()
    vim.cmd("DB sqlite::memory: select 42 as answer")
    h.ok(wait_for(function()
        local result_buf = vim.b[source].lua_dadbod_result_buf
        if not result_buf or not vim.api.nvim_buf_is_valid(result_buf) then
            return false
        end
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "DB command did not finish")
    h.matches(result_text(vim.b[source].lua_dadbod_result_buf), "42")
end)

h.test(":DB runs a range", function()
    local source = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "select 7 as seven;" })
    vim.cmd("%DB sqlite::memory:")
    h.ok(wait_for(function()
        local result_buf = vim.b[source].lua_dadbod_result_buf
        if not result_buf or not vim.api.nvim_buf_is_valid(result_buf) then
            return false
        end
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "range DB command did not finish")
    h.matches(result_text(vim.b[source].lua_dadbod_result_buf), "7")
end)

h.test("result reruns the stored query", function()
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(source)
    local result_buf, err = execute.run("select 5 as five;", { conn = "sqlite::memory:" })
    h.ok(result_buf, err)
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status == "done"
    end), "first run did not finish")
    h.matches(result_text(result_buf), "5")

    require("lua-dadbod.result").rerun(result_buf)
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
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
    require("lua-dadbod.result").cancel(result_buf)
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "cancel did not finish")
    h.eq(vim.b[result_buf].lua_dadbod_result.status, "aborted")
end)

h.test("query buffer builds helper SQL", function()
    local query = require("lua-dadbod.query")
    local bufnr, err = query.open("sqlite::memory:", {
        table = "users",
        helper = "List",
        auto_execute = false,
    })
    bufnr = h.ok(bufnr, err)
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    h.matches(text, 'select %* from "users" limit 50')
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

h.test("execute on save follows the config", function()
    local previous = {
        save = config.get().save_location,
        tmp = config.get().tmp_location,
        execute = config.get().execute_on_save,
    }
    local directory = vim.fn.tempname()
    local function setup(execute_on_save)
        config.setup({
            save_location = directory .. "/lua-dadbod",
            tmp_location = directory .. "/queries",
            execute_on_save = execute_on_save,
        })
    end

    setup(true)
    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select 7 as saved;" })
    vim.cmd("silent write")

    h.ok(wait_for(function()
        return vim.b[bufnr].lua_dadbod_result_buf ~= nil
    end), "execute_on_save did not start a query")
    local result_buf = vim.b[bufnr].lua_dadbod_result_buf
    h.ok(wait_for(function()
        return result_text(result_buf):find("saved", 1, true) ~= nil
    end), "saved query did not finish")
    h.matches(result_text(result_buf), "saved")

    setup(false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select 8 as skipped;" })
    vim.cmd("silent write")
    vim.wait(300)
    h.eq(vim.b[bufnr].lua_dadbod_result_buf, result_buf, "execute_on_save=false still ran the query")

    pcall(vim.api.nvim_buf_delete, result_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(vim.cmd, "silent! only")
    vim.fn.delete(directory, "rf")
    config.setup({
        save_location = previous.save,
        tmp_location = previous.tmp,
        execute_on_save = previous.execute,
    })
end)

h.test("DDL invalidates the metadata cache", function()
    local ui = require("lua-dadbod.ui")
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local path = directory .. "/meta.db"
    vim.fn.writefile({}, path)
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite:" .. path }
    ui.reset()

    local entry = ui.get("test_g:dbs")
    h.ok(entry)
    entry.loaded = true
    entry.tables = { "old" }

    local result_buf = h.ok(execute.run("create table t (id integer);", { conn = entry.url }))
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "DDL did not finish")
    h.eq(entry.loaded, false)
    h.eq(#entry.tables, 0)

    entry.loaded = true
    entry.tables = { "t" }
    result_buf = h.ok(execute.run("select 1;", { conn = entry.url }))
    h.ok(wait_for(function()
        local meta = vim.b[result_buf].lua_dadbod_result
        return meta and meta.status ~= "running"
    end), "select did not finish")
    h.eq(entry.loaded, true)
    h.eq(entry.tables[1], "t")

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buf].lua_dadbod_result then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    pcall(vim.cmd, "silent! only")
    vim.fn.delete(directory, "rf")
    vim.g.db = previous.db
    vim.g.dbs = previous.dbs
    vim.env.LUA_DADBOD_URL = previous.url
    vim.env.LUA_DADBOD_NAME = previous.name
    config.setup({ save_location = previous.save, tmp_location = previous.tmp })
end)

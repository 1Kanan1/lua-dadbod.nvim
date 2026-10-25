local h = require("tests.harness")
local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local query = require("lua-dadbod.query")
local ui = require("lua-dadbod.ui")
local util = require("lua-dadbod.util")

local function restore_globals(previous, directory)
    vim.g.db = previous.db
    vim.g.dbs = previous.dbs
    vim.env.LUA_DADBOD_URL = previous.url
    vim.env.LUA_DADBOD_NAME = previous.name
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
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    util.write_json(directory .. "/lua-dadbod/connections.json", {
        { name = "filedb", url = "sqlite::memory:" },
    })

    vim.g.db = "sqlite::memory:"
    vim.g.dbs = {
        dev = "sqlite::memory:",
        file = function()
            return "sqlite::memory:"
        end,
    }
    vim.env.LUA_DADBOD_URL = "sqlite::memory:"
    vim.env.LUA_DADBOD_NAME = "envdb"

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
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({ save_location = directory .. "/lua-dadbod" })
    ui.reset()

    ui.add_connection({ name = "added", url = "sqlite::memory:" })
    local entry = ui.get("added_file")
    h.ok(entry)
    h.eq(entry.source, "file")
    h.eq(vim.fn.filereadable(directory .. "/lua-dadbod/connections.json"), 1)

    local ok, err = ui.delete_connection(entry)
    h.ok(ok, err)
    h.is_nil(ui.get("added_file"))

    restore_globals(previous, directory)
end)

h.test(":LuaDadbodFindBuffer attaches the current buffer", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { only = "sqlite::memory:" }
    ui.reset()

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("LuaDadbodFindBuffer")

    local meta = vim.b[bufnr].lua_dadbod
    h.matches(meta.conn, "sqlite::memory:")
    h.eq(meta.conn_name, "only")
    h.eq(meta.conn_key, "only_g:dbs")
    h.eq(meta.dbms, "sqlite")
    h.eq(meta.source, "attached")

    restore_globals(previous, directory)
end)

h.test("connection labels add the dbms only for multiple dbms", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({ save_location = directory .. "/lua-dadbod" })

    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()
    local sqlite = ui.get("test_g:dbs")
    h.eq(ui.has_multiple_dbms(), false)
    h.eq(ui.connection_label(sqlite.dbms, sqlite.name), "test")

    vim.g.dbs = {
        test = "sqlite::memory:",
        prod = "postgresql://host/database",
    }
    ui.reset()
    sqlite = ui.get("test_g:dbs")
    local postgres = ui.get("prod_g:dbs")
    h.eq(ui.has_multiple_dbms(), true)
    h.eq(ui.connection_label(sqlite.dbms, sqlite.name), "sqlite/test")
    h.eq(ui.connection_label(postgres.dbms, postgres.name), "postgres/prod")

    restore_globals(previous, directory)
end)

h.test("saved query folders use the connection name", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({ save_location = directory .. "/lua-dadbod" })

    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()
    h.matches(ui.saved_dir(ui.get("test_g:dbs")), "/queries/test$")

    util.write_json(directory .. "/lua-dadbod/connections.json", {
        { name = "test", url = "sqlite::memory:" },
    })
    ui.reset()
    local folders = {}
    for _, entry in ipairs(ui.connections()) do
        if entry.name == "test" then
            folders[#folders + 1] = ui.saved_folder(entry)
        end
    end
    h.eq(#folders, 2)
    h.eq(folders[1] ~= folders[2], true, "same-named connections shared a folder")

    restore_globals(previous, directory)
end)

h.test("invalidate resets connection metadata", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()

    local entry = ui.get("test_g:dbs")
    entry.loaded = true
    entry.error = "boom"
    entry.tables = { "users" }
    entry.schemas = { "public" }
    entry.schemas_loaded = true
    entry.schema_state = { public = { loaded = true, expanded = true, tables_expanded = true } }

    local result = ui.invalidate(entry.url)
    h.eq(result.key, entry.key)
    h.eq(entry.loaded, false)
    h.eq(entry.error, nil)
    h.eq(entry.tables[1], "users")
    h.eq(entry.schemas[1], "public")
    h.eq(entry.schemas_loaded, false)
    h.eq(entry.schema_state.public.loaded, false)
    h.eq(entry.schema_state.public.expanded, true)
    h.eq(entry.schema_state.public.tables_expanded, true)

    restore_globals(previous, directory)
end)

h.test("scratchpads include saved files and open buffers", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
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

h.test("query deletes a saved scratchpad", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()

    local saved_dir = ui.saved_dir(ui.get("test_g:dbs"))
    util.ensure_dir(saved_dir)
    local path = saved_dir .. "/saved.sql"
    vim.fn.writefile({ "select 1;" }, path)

    local ok, err = query.delete_scratchpad({ kind = "file", path = path })
    h.ok(ok, err)
    h.eq(vim.fn.filereadable(path), 0)

    restore_globals(previous, directory)
end)

h.test("opening a saved query attaches its connection", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()

    local saved_dir = ui.saved_dir(ui.get("test_g:dbs"))
    util.ensure_dir(saved_dir)
    local path = saved_dir .. "/saved.sql"
    vim.fn.writefile({ "select 1;" }, path)

    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    local meta = vim.b[bufnr].lua_dadbod
    h.ok(meta, "saved query was not attached")
    h.eq(meta.conn, "sqlite::memory:")
    h.eq(meta.conn_key, "test_g:dbs")
    h.eq(meta.conn_name, "test")
    h.eq(meta.dbms, "sqlite")
    h.eq(meta.source, "saved")
    h.eq(meta.path, vim.api.nvim_buf_get_name(bufnr))
    h.eq(ui.active(), "test_g:dbs")

    vim.api.nvim_buf_delete(bufnr, { force = true })
    restore_globals(previous, directory)
end)

h.test("reopen a saved query in a new process", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h")
    local directory = vim.fn.tempname()
    local path = directory .. "/lua-dadbod/queries/" .. util.slug("test") .. "/saved.sql"
    util.ensure_dir(vim.fs.dirname(path))
    vim.fn.writefile({ "select 1;" }, path)

    local out = vim.fn.system({
        "nvim",
        "--headless",
        "-u",
        "NONE",
        "--cmd",
        "set rtp+=" .. vim.fn.fnameescape(root),
        "-c",
        "runtime plugin/lua-dadbod.lua",
        "-c",
        "lua require('lua-dadbod').setup({ save_location = " .. string.format("%q", directory .. "/lua-dadbod") .. " })",
        "-c",
        "let g:dbs = {'test': 'sqlite::memory:'}",
        "-c",
        "edit " .. vim.fn.fnameescape(path),
        "-c",
        "lua print('CONN=' .. tostring(vim.b.lua_dadbod and vim.b.lua_dadbod.conn_key))",
        "-c",
        "lua print('SOURCE=' .. tostring(vim.b.lua_dadbod and vim.b.lua_dadbod.source))",
        "-c",
        "qa!",
    })
    h.eq(vim.v.shell_error, 0)
    h.matches(out, "CONN=test_g:dbs")
    h.matches(out, "SOURCE=saved")

    vim.fn.delete(directory, "rf")
end)

h.test("statusline reports the query context", function()
    local api = require("lua-dadbod")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.b[bufnr].lua_dadbod = { conn_name = "test", schema = "public", table = "users" }

    h.eq(api.statusline(), "DB: test > public > users")
    h.eq(api.statusline({ prefix = "", separator = ".", show = { "table", "db_name" } }), "users.test")
    h.eq(api.statusline({ show = { "schema" } }), "DB: public")

    vim.b[bufnr].lua_dadbod = nil
    h.eq(api.statusline(), "")

    vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("remove broken sqlcomplete insert maps", function()
    vim.g.loaded_sql_completion = true
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.keymap.set("i", "<Right>", "<C-R>=sqlcomplete#DrillIntoTable()<CR>", { buffer = bufnr })
    vim.keymap.set("i", "<C-C>a", "<Cmd>echo 1<CR>", { buffer = bufnr })

    h.ok(query.attach("sqlite::memory:", bufnr, {}))
    h.eq(vim.fn.maparg("<Right>", "i"), "")
    h.eq(vim.fn.maparg("<C-C>a", "i") ~= "", true)

    vim.g.loaded_sql_completion = nil
    vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("keep sqlcomplete maps when the engine is loaded", function()
    vim.cmd("runtime autoload/sqlcomplete.vim")
    h.eq(vim.fn.exists("*sqlcomplete#DrillIntoTable"), 1)

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.keymap.set("i", "<Right>", "<C-R>=sqlcomplete#DrillIntoTable()<CR>", { buffer = bufnr })
    h.ok(query.attach("sqlite::memory:", bufnr, {}))
    h.eq(vim.fn.maparg("<Right>", "i") ~= "", true, "working sqlcomplete map was removed")

    vim.g.loaded_sql_completion = nil
    vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("n creates a scratchpad for the active connection", function()
    pcall(vim.cmd, "silent! only")
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()

    local drawer = require("lua-dadbod.drawer")
    drawer.open()
    h.is_nil(ui.active())

    local function drawer_window_count()
        local count = 0
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.b[vim.api.nvim_win_get_buf(win)].lua_dadbod_drawer then
                count = count + 1
            end
        end
        return count
    end

    vim.cmd("split")
    h.eq(drawer_window_count(), 2)
    drawer.open()
    h.eq(drawer_window_count(), 1, "drawer.open kept a duplicate drawer window")

    local window_count = #vim.api.nvim_list_wins()

    local drawer_buf = select(2, drawer.find_win())
    local function drawer_text()
        return table.concat(vim.api.nvim_buf_get_lines(drawer_buf, 0, -1, false), "\n")
    end
    local function scratchpad_count()
        return tonumber(drawer_text():match("Scratchpads %((%d+)%)") or 0)
    end
    local base_count = scratchpad_count()

    drawer.new_scratchpad()
    h.eq(ui.active(), "test_g:dbs")
    h.eq(#vim.api.nvim_list_wins(), window_count, "scratchpad opened a new split")
    h.eq(scratchpad_count(), base_count + 1)

    local query_buf = vim.api.nvim_get_current_buf()
    local meta = vim.b[query_buf].lua_dadbod
    h.eq(meta.conn_name, "test")
    h.eq(meta.dbms, "sqlite")
    h.eq(meta.source, "scratch")

    local drawer_win = drawer.find_win()
    vim.api.nvim_set_current_win(drawer_win)
    drawer.new_scratchpad()
    h.eq(#vim.api.nvim_list_wins(), window_count, "second scratchpad opened a new split")
    h.eq(scratchpad_count(), base_count + 2)
    local second_buf = vim.api.nvim_get_current_buf()
    h.eq(second_buf ~= query_buf, true, "second scratchpad did not replace the first")

    vim.api.nvim_buf_delete(query_buf, { force = true })
    h.ok(vim.wait(1000, function()
        return scratchpad_count() == base_count + 1
    end), "drawer did not refresh after deleting a scratchpad")

    drawer.close()
    h.eq(drawer.is_open(), false)
    vim.api.nvim_buf_delete(second_buf, { force = true })
    pcall(vim.cmd, "silent! only")
    restore_globals(previous, directory)
end)

h.test("drawer expands a connection and opens a table", function()
    pcall(vim.cmd, "silent! only")
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    util.ensure_dir(directory)
    config.setup({
        save_location = directory .. "/lua-dadbod",
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

    local drawer = require("lua-dadbod.drawer")
    h.eq(drawer.scratchpads_expanded, false)
    h.eq(drawer.history_expanded, false)
    drawer.open()
    local drawer_buf = vim.api.nvim_get_current_buf()
    h.eq(vim.b[drawer_buf].lua_dadbod_drawer, true)

    local lines = vim.api.nvim_buf_get_lines(drawer_buf, 0, -1, false)
    local initial_text = table.concat(lines, "\n")
    h.matches(initial_text, "test")
    h.eq(initial_text:find("Add connection", 1, true), nil)
    h.eq(initial_text:find("No scratchpads", 1, true), nil)
    h.eq(initial_text:find("No history yet", 1, true), nil)
    h.eq(vim.fn.hlexists("LuaDadbodDb"), 1)
    h.eq(vim.fn.hlexists("LuaDadbodTable"), 1)
    h.eq(vim.fn.hlexists("LuaDadbodScratchpads"), 1)
    h.eq(vim.fn.hlexists("LuaDadbodHistory"), 1)

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
        return vim.b[drawer_buf].lua_dadbod_result_buf ~= nil
    end), "preview did not start")
    local result_buf = vim.b[drawer_buf].lua_dadbod_result_buf
    h.ok(vim.wait(5000, function()
        local result_meta = vim.b[result_buf].lua_dadbod_result
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
        local result_meta = vim.b[result_buf].lua_dadbod_result
        return result_meta and result_meta.status ~= "running"
    end), "columns preview did not finish")
    result_text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
    h.matches(result_text, "name")

    vim.api.nvim_set_current_win(drawer_win)
    vim.api.nvim_win_set_cursor(drawer_win, { table_line, 0 })
    drawer.edit()
    local query_buf = vim.api.nvim_get_current_buf()
    local meta = vim.b[query_buf].lua_dadbod
    h.eq(meta.table, "users")
    h.matches(table.concat(vim.api.nvim_buf_get_lines(query_buf, 0, -1, false), "\n"), "limit 50")
    drawer.close()
    h.eq(drawer.is_open(), false)
    vim.api.nvim_buf_delete(query_buf, { force = true })

    pcall(vim.cmd, "silent! only")
    restore_globals(previous, directory)
end)

h.test("drawer loads schemas and schema tables", function()
    local adapter = {
        name = "uitestmeta",
        binary = "sqlite3",
        quote = { '"', '"' },
        filetype = "sql",
        argv = function()
            return { "sqlite3", ":memory:" }
        end,
        schemas_sql = function()
            return "select 'public' union all select 'other' order by 1"
        end,
        tables_sql = function(ctx)
            if ctx.schema == "public" then
                return "select 'users' union all select 'orders' order by 1"
            end
            return "select 'other_table'"
        end,
    }
    require("lua-dadbod.adapters").register(adapter)

    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { meta = "uitestmeta:" }
    ui.reset()

    local drawer = require("lua-dadbod.drawer")
    drawer.open()
    local conn_line
    for index, row in ipairs(drawer.rows) do
        if row.kind == "conn" then
            conn_line = index
        end
    end
    vim.api.nvim_win_set_cursor(0, { conn_line, 0 })
    drawer.select("edit")

    local entry = ui.get("meta_g:dbs")
    h.ok(vim.wait(5000, function()
        return entry.schemas_loaded
    end), "schemas did not load")
    h.eq(entry.schemas, { "other", "public" })

    local schema_line
    for index, row in ipairs(drawer.rows) do
        if row.kind == "schema" and row.schema == "public" then
            schema_line = index
        end
    end
    h.ok(schema_line, "public schema row not found")
    vim.api.nvim_win_set_cursor(0, { schema_line, 0 })
    drawer.select("edit")

    local state = entry.schema_state.public
    h.ok(vim.wait(5000, function()
        return state.loaded
    end), "schema tables did not load")
    h.eq(state.tables, { "orders", "users" })

    local tables_line
    for index, row in ipairs(drawer.rows) do
        if row.kind == "section" and row.section == "tables" and row.schema == "public" then
            tables_line = index
        end
    end
    h.ok(tables_line, "schema Tables section not found")
    vim.api.nvim_win_set_cursor(0, { tables_line, 0 })
    drawer.select("edit")

    local table_rows = {}
    for _, row in ipairs(drawer.rows) do
        if row.kind == "table" then
            table_rows[#table_rows + 1] = row
        end
    end
    h.eq(#table_rows, 2)
    h.eq(table_rows[1].table, "orders")
    h.eq(table_rows[2].table, "users")
    h.eq(table_rows[1].schema, "public")
    h.eq(table_rows[1].level, 4)

    ui.invalidate(entry.url)
    h.eq(entry.schemas_loaded, false)
    h.eq(state.expanded, true)
    h.eq(state.tables_expanded, true)

    drawer.refetch(entry)
    h.ok(vim.wait(5000, function()
        return entry.schemas_loaded and state.loaded and not state.loading
    end), "refetch did not finish")
    h.eq(state.expanded, true, "schema collapsed after refetch")
    h.eq(state.tables_expanded, true, "Tables collapsed after refetch")
    local visible = false
    for _, row in ipairs(drawer.rows) do
        if row.kind == "table" and row.table == "users" then
            visible = true
        end
    end
    h.eq(visible, true, "table rows disappeared after refetch")

    adapter.tables_sql = function()
        return "select * from definitely_missing_table"
    end
    drawer.fetch_schema_tables(entry, "public")
    h.ok(vim.wait(5000, function()
        return not state.loading
    end), "failed table fetch did not finish")
    h.eq(state.expanded, true, "schema collapsed on a table metadata error")
    h.eq(#state.tables, 2, "tables were cleared on a metadata error")

    adapter.schemas_sql = function()
        return "select * from definitely_missing_table"
    end
    drawer.fetch_schemas(entry)
    h.ok(vim.wait(5000, function()
        return not entry.schemas_loading
    end), "failed schema fetch did not finish")
    h.eq(entry.expanded, true, "connection collapsed on a schema metadata error")
    h.eq(#entry.schemas, 2, "schemas were cleared on a metadata error")

    drawer.close()
    pcall(vim.cmd, "silent! only")
    restore_globals(previous, directory)
end)

h.test("failed connections collapse and stay inactive", function()
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { broken = "sqlite:" .. directory .. "/missing/test.db" }
    ui.reset()

    local notices = {}
    local previous_notify = vim.notify
    vim.notify = function(message, level)
        notices[#notices + 1] = { message, level }
    end

    local drawer = require("lua-dadbod.drawer")
    drawer.open()
    local conn_line
    for index, row in ipairs(drawer.rows) do
        if row.kind == "conn" then
            conn_line = index
        end
    end
    vim.api.nvim_win_set_cursor(0, { conn_line, 0 })
    drawer.select("edit")

    local entry = ui.get("broken_g:dbs")
    local loaded = vim.wait(5000, function()
        return entry.loaded
    end)

    local drawer_win = drawer.find_win()
    vim.api.nvim_set_current_win(drawer_win)
    vim.api.nvim_win_set_cursor(0, { conn_line, 0 })
    drawer.select("edit")
    vim.notify = previous_notify

    h.ok(loaded, "metadata did not finish")
    h.ok(entry.error)
    h.eq(entry.expanded, false)
    h.eq(ui.is_activated(entry.key), false)
    h.eq(ui.active(), nil)

    local notified = false
    for _, notice in ipairs(notices) do
        if notice[2] == vim.log.levels.ERROR and notice[1]:find(entry.error, 1, true) then
            notified = true
        end
    end
    h.eq(notified, true)

    drawer.close()
    pcall(vim.cmd, "silent! only")
    restore_globals(previous, directory)
end)

h.test("open_split from a float splits the window below it", function()
    pcall(vim.cmd, "silent! only")
    local base_win = vim.api.nvim_get_current_win()
    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, true, {
        relative = "editor",
        row = 2,
        col = 2,
        width = 20,
        height = 5,
    })
    local new_buf = vim.api.nvim_create_buf(false, true)

    local target = util.open_split({ bufnr = new_buf, restore = true })
    h.ok(target, "no window was opened")
    h.eq(vim.api.nvim_win_get_buf(target), new_buf)
    h.eq(vim.api.nvim_get_current_win(), float_win)

    local base_pos = vim.api.nvim_win_get_position(base_win)
    local target_pos = vim.api.nvim_win_get_position(target)
    h.eq(target_pos[2], base_pos[2], "result opened beside the window, not below")
    h.eq(target_pos[1] > base_pos[1], true, "result opened above the window")
    h.eq(vim.api.nvim_win_get_width(target), vim.api.nvim_win_get_width(base_win))

    pcall(vim.api.nvim_win_close, float_win, true)
    pcall(vim.api.nvim_buf_delete, new_buf, { force = true })
    pcall(vim.cmd, "silent! only")
end)

h.test("a window falling back to the drawer buffer is detached", function()
    pcall(vim.cmd, "silent! only")
    local previous = {
        db = vim.g.db,
        dbs = vim.g.dbs,
        url = vim.env.LUA_DADBOD_URL,
        name = vim.env.LUA_DADBOD_NAME,
        save = config.get().save_location,
        tmp = config.get().tmp_location,
    }
    local directory = vim.fn.tempname()
    config.setup({
        save_location = directory .. "/lua-dadbod",
        tmp_location = directory .. "/queries",
    })
    vim.g.dbs = { test = "sqlite::memory:" }
    ui.reset()

    local drawer = require("lua-dadbod.drawer")
    drawer.open()
    local drawer_win, drawer_buf = drawer.find_win()
    local other_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= drawer_win then
            other_win = win
        end
    end
    h.ok(other_win, "no window next to the drawer")

    vim.api.nvim_win_set_buf(other_win, drawer_buf)
    h.eq(vim.api.nvim_win_get_buf(other_win) ~= drawer_buf, true, "duplicate drawer window remained")
    h.eq(#vim.fn.win_findbuf(drawer_buf), 1)
    h.eq(drawer.is_open(), true)

    drawer.close()
    pcall(vim.cmd, "silent! only")
    restore_globals(previous, directory)
end)

h.test("help opens a floating key guide", function()
    local help = require("lua-dadbod.help")
    local win = help.open("test keys", {
        { section = "First" },
        { "a", "first action" },
        { section = "Second" },
        { "<CR>", "second action" },
    })
    h.ok(win, "no help window")
    h.eq(vim.api.nvim_win_get_config(win).relative, "editor")
    h.eq(vim.api.nvim_win_get_buf(win), help.buf)
    local text = table.concat(vim.api.nvim_buf_get_lines(help.buf, 0, -1, false), "\n")
    h.matches(text, "First")
    h.matches(text, "first action")
    h.matches(text, "Second")
    h.matches(text, "second action")

    help.close()
    h.is_nil(help.win)
    h.is_nil(help.buf)
end)

h.test("drawer help lists its keymaps", function()
    local help = require("lua-dadbod.help")
    require("lua-dadbod.drawer").help()
    h.ok(help.win, "help window did not open")
    local text = table.concat(vim.api.nvim_buf_get_lines(help.buf, 0, -1, false), "\n")
    h.matches(text, "Drawer")
    h.matches(text, "new scratchpad")
    h.matches(text, "open row %(table: preview%)")
    h.matches(text, "Query buffer")
    h.matches(text, "run statement under cursor")
    help.close()
end)

h.test("open_split applies a height fraction", function()
    pcall(vim.cmd, "silent! only")
    local parent = vim.api.nvim_get_current_win()
    local parent_height = vim.api.nvim_win_get_height(parent)
    local buf = vim.api.nvim_create_buf(false, true)

    local target = util.open_split({ bufnr = buf, restore = true, height = 0.4 })
    h.ok(target, "no window was opened")
    local expected = math.max(1, math.min(math.floor(parent_height * 0.4), parent_height - 1))
    h.eq(vim.api.nvim_win_get_height(target), expected)
    h.eq(vim.api.nvim_get_current_win(), parent)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    pcall(vim.cmd, "silent! only")
end)

h.test("global mappings follow setup", function()
    local lua_dadbod = require("lua-dadbod")
    lua_dadbod.setup({ mappings = { global = true } })
    h.eq(vim.fn.maparg("<leader>Do", "n") ~= "", true)

    lua_dadbod.setup({ mappings = { global = false } })
    h.eq(vim.fn.maparg("<leader>Do", "n"), "")

    lua_dadbod.setup()
end)

h.test("lua-dadbod commands exist", function()
    for _, name in ipairs({
        "LuaDadbod",
        "LuaDadbodToggle",
        "LuaDadbodClose",
        "LuaDadbodAddConnection",
        "LuaDadbodFindBuffer",
        "LuaDadbodRenameBuffer",
        "LuaDadbodClearCache",
        "LuaDadbodRefresh",
    }) do
        h.eq(vim.fn.exists(":" .. name), 2, name .. " is not registered")
    end
end)

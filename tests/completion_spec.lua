local h = require("tests.harness")
local completion = require("lua-dadbod.completion")
local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local statement = require("lua-dadbod.statement")

local function wait_for(predicate)
    return vim.wait(5000, predicate, 10)
end

local function make_buffer(url, lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = "sql"
    vim.b[bufnr].db = url
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

local function make_database()
    local path = vim.fn.tempname() .. ".db"
    local url = "sqlite:" .. path
    local done = false
    local failure

    db.run(url, "create table users (id integer, full_name text);", {}, function(result)
        if result.code ~= 0 then
            failure = result.stderr
        end
        done = true
    end)

    h.ok(wait_for(function()
        return done
    end), "database setup timed out")
    h.ok(not failure, failure)
    return url, path
end

local function load_columns(url)
    local columns
    local failure

    db.fetch_columns(url, { table = "users" }, function(value, err)
        columns = value
        failure = err
    end)

    h.ok(wait_for(function()
        return columns ~= nil
    end), failure or "column metadata timed out")
    return columns
end

local function load_tables(url)
    local tables
    local failure

    db.fetch_tables(url, nil, function(value, err)
        tables = value
        failure = err
    end)

    h.ok(wait_for(function()
        return tables ~= nil
    end), failure or "table metadata timed out")
    return tables
end

local function cleanup(url, path, buffers)
    for _, bufnr in ipairs(buffers or {}) do
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    db.clear_meta(url)
    if path then
        vim.fn.delete(path)
    end
    completion.reset()
end

h.test("parse completion prefixes", function()
    h.eq(completion.prefix("select * from us"), { kind = "bare", prefix = "us" })
    h.eq(completion.prefix("select u.na"), { kind = "qualified", qualifier = "u", prefix = "na" })
    h.eq(completion.prefix("select u."), { kind = "qualified", qualifier = "u", prefix = "" })
    h.eq(completion.prefix("select :na"), { kind = "binds", prefix = "na" })
    h.eq(completion.prefix("select x::te"), { kind = "bare", prefix = "te" })
end)

h.test("parse table references and aliases", function()
    local dialect = statement.dialect("postgresql")
    local sql = table.concat({
        "select * from public.users u",
        "join orders as o on o.id = u.id",
        'left join "my table" mt on true',
        "where note = 'from hidden h' -- from commented c",
    }, "\n")

    local map = completion.aliases(sql, dialect)
    h.eq(map.u, { schema = "public", table = "users" })
    h.eq(map.users, { schema = "public", table = "users" })
    h.eq(map.o, { schema = nil, table = "orders" })
    h.eq(map.mt, { schema = nil, table = "my table" })
    h.is_nil(map.h)
    h.is_nil(map.c)

    local refs = completion.references(sql, dialect)
    h.eq(#refs, 3)

    local updates = completion.aliases("update users set name = 'x'", dialect)
    h.eq(updates.users, { schema = nil, table = "users" })

    local inserts = completion.aliases("insert into logs l values (1)", dialect)
    h.eq(inserts.l, { schema = nil, table = "logs" })
    h.is_nil(inserts.set)
end)

h.test("ignore incomplete table references", function()
    local dialect = statement.dialect("postgresql")

    h.eq(#completion.references("select * from information_schema.", dialect), 0)
    h.eq(#completion.references("select * from information_schema.\nwhere true", dialect), 0)
    h.eq(completion.aliases("select * from information_schema.", dialect), {})

    local refs = completion.references("select * from information_schema.tables", dialect)
    h.eq(#refs, 1)
    h.eq(refs[1].schema, "information_schema")
    h.eq(refs[1].table, "tables")

    local map = completion.aliases("select * from information_schema.tables t", dialect)
    h.eq(map.tables, { schema = "information_schema", table = "tables" })
    h.eq(map.t, { schema = "information_schema", table = "tables" })

    local reserved_table = completion.aliases("select * from public.order", dialect)
    h.eq(reserved_table.order, { schema = "public", table = "order" })
end)

h.test("detect table positions", function()
    h.eq(completion.table_position("select * from "), true)
    h.eq(completion.table_position("select * from or"), true)
    h.eq(completion.table_position("delete from "), true)
    h.eq(completion.table_position("insert into "), true)
    h.eq(completion.table_position("update "), true)
    h.eq(completion.table_position("create table "), true)
    h.eq(completion.table_position("select * from orders o left join "), true)
    h.eq(completion.table_position("select * from orders o, cust"), true)

    h.eq(completion.table_position("select "), false)
    h.eq(completion.table_position("select a, "), false)
    h.eq(completion.table_position("select * from orders o where o."), false)
    h.eq(completion.table_position("select * from orders o on "), false)
    h.eq(completion.table_position("select * from public."), false)
    h.eq(completion.table_position("select * from user_table "), false)
    h.eq(completion.table_position("insert into users (name, "), false)
end)

h.test("allow an empty keyword in table positions", function()
    h.eq(completion.min_keyword_length({ trigger = { initial_kind = "trigger_character" } }), 0)
    h.eq(
        completion.min_keyword_length({
            trigger = { initial_kind = "manual" },
            line = "select * from ",
            cursor = { 1, #"select * from " },
        }),
        0
    )
    h.eq(
        completion.min_keyword_length({
            trigger = { initial_kind = "manual" },
            line = "select ",
            cursor = { 1, #"select " },
        }),
        1
    )
    h.eq(
        completion.min_keyword_length({
            trigger = { initial_kind = "keyword" },
            line = "select * from ",
            cursor = { 1, #"select * from " },
        }),
        1
    )
end)

h.test("completion reads the statement around the cursor", function()
    local bufnr = make_buffer("sqlite::memory:", {
        "select * from first_table f;",
        "",
        "select f.id from second_table f;",
    })

    local context = h.ok(completion.analysis(bufnr, 3, #"select f."))
    h.eq(context.kind, "columns")
    h.eq(context.target.table, "second_table")
    h.eq(context.sql:find("first_table", 1, true), nil)
    h.eq(context.prefix.qualifier, "f")

    cleanup(nil, nil, { bufnr })
end)

h.test("treat an unfinished qualifier as a schema", function()
    local bufnr = make_buffer("sqlite::memory:", { "select * from information_schema." })

    local context = h.ok(completion.analysis(bufnr, 1, #"select * from information_schema."))
    h.eq(context.kind, "tables")
    h.eq(context.schema, "information_schema")
    h.is_nil(context.target)

    cleanup(nil, nil, { bufnr })
end)

h.test("table positions list tables only", function()
    local url, path = make_database()
    load_tables(url)

    local bufnr = make_buffer(url, { "select * from " })
    local items = completion.items(bufnr, 1, #"select * from ")
    h.eq(#items, 1)
    h.eq(items[1].label, "users")
    h.eq(items[1].kind, 9)
    h.eq(items[1].detail, "table")
    h.eq(items[1].score_offset, 10)

    cleanup(url, path, { bufnr })
end)

h.test("bare completion boosts tables", function()
    local url, path = make_database()
    load_tables(url)

    local bufnr = make_buffer(url, { "select us" })
    local items = completion.items(bufnr, 1, #"select us")
    h.eq(items[1].label, "users")
    h.eq(items[1].score_offset, 10)

    cleanup(url, path, { bufnr })
end)

h.test("cache column metadata per connection", function()
    local url, path = make_database()
    local columns = load_columns(url)

    h.eq(#columns, 2)
    h.eq(columns[1].name, "id")
    h.eq(columns[1].type, "INTEGER")
    h.eq(columns[2].name, "full_name")
    h.eq(columns[2].type, "TEXT")

    local cached = h.ok(db.cached_columns(url, nil, "users"))
    h.eq(cached[2].name, "full_name")

    db.clear_meta(url)
    h.is_nil(db.cached_columns(url, nil, "users"))

    cleanup(url, path)
end)

h.test("coalesce concurrent column fetches", function()
    local url, path = make_database()
    local calls = 0
    local original = db.run

    db.run = function(...)
        calls = calls + 1
        return original(...)
    end

    local first
    local second
    db.fetch_columns(url, { table = "users" }, function(value)
        first = value
    end)
    db.fetch_columns(url, { table = "users" }, function(value)
        second = value
    end)

    h.ok(wait_for(function()
        return first ~= nil and second ~= nil
    end), "column fetches timed out")

    db.run = original
    h.eq(calls, 1)
    h.eq(#first, 2)
    h.eq(#second, 2)

    cleanup(url, path)
end)

h.test("build completion items from the cache", function()
    local url, path = make_database()
    load_columns(url)
    local bufnr = make_buffer(url, { "select u. from users u" })

    local calls = 0
    local original = db.run
    db.run = function(...)
        calls = calls + 1
        return original(...)
    end

    local items = completion.items(bufnr, 1, #"select u.")

    db.run = original
    h.eq(calls, 0, "completion spawned a process on a cache hit")
    h.eq(#items, 2)
    h.eq(items[1].label, "id")
    h.eq(items[1].detail, "INTEGER")
    h.eq(items[2].label, "full_name")
    h.eq(items[2].detail, "TEXT")
    h.eq(items[2].insertText, "full_name")

    cleanup(url, path, { bufnr })
end)

h.test("blink source answers synchronously", function()
    local url, path = make_database()
    load_columns(url)
    local bufnr = make_buffer(url, { "select u. from users u" })
    local source = require("lua-dadbod.completion_blink").new({})

    local called = false
    local response
    source:get_completions({ bufnr = bufnr, cursor = { 1, #"select u." } }, function(value)
        called = true
        response = value
    end)

    h.eq(called, true)
    h.eq(#response.items, 2)
    h.eq(response.is_incomplete_forward, true)

    cleanup(url, path, { bufnr })
end)

h.test("omni completion finds the word start and filters", function()
    local url, path = make_database()
    load_columns(url)
    local bufnr = make_buffer(url, { "select u. from users u" })
    local previous = vim.api.nvim_get_current_buf()

    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 1, #"select u." })

    h.eq(completion.omnifunc(1, ""), #"select u.")

    local matches = completion.omnifunc(0, "ful")
    h.eq(#matches, 1)
    h.eq(matches[1].word, "full_name")
    h.eq(matches[1].abbr, "full_name")

    vim.api.nvim_set_current_buf(previous)
    cleanup(url, path, { bufnr })
end)

h.test("prefetch warms columns for tables in the buffer", function()
    local url, path = make_database()
    local bufnr = make_buffer(url, { "select * from users;" })

    completion.reset()
    completion.schedule_prefetch(bufnr)

    h.ok(wait_for(function()
        return db.cached_columns(url, nil, "users") ~= nil
    end), "prefetch did not load columns")

    cleanup(url, path, { bufnr })
end)

h.test("completion defaults", function()
    local defaults = config.defaults().completion
    h.eq(defaults.enabled, true)
    h.eq(defaults.omnifunc, false)
    h.eq(defaults.prefetch, true)
    h.eq(defaults.max_items, 200)
end)

h.test("completion only runs in attached sql buffers", function()
    local bufnr = make_buffer("sqlite::memory:", { "" })
    local previous_buf = vim.api.nvim_get_current_buf()
    local previous_db = vim.g.db
    local previous_env = vim.env.DATABASE_URL

    vim.g.db = nil
    vim.env.DATABASE_URL = nil
    vim.api.nvim_set_current_buf(bufnr)

    h.eq(completion.enabled(), true)

    vim.bo[bufnr].filetype = "lua"
    h.eq(completion.enabled(), false)

    vim.bo[bufnr].filetype = "sql"
    vim.b[bufnr].db = nil
    h.eq(completion.enabled(), false)

    vim.api.nvim_set_current_buf(previous_buf)
    vim.g.db = previous_db
    vim.env.DATABASE_URL = previous_env
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    completion.reset()
end)

h.test("attach sets omnifunc when enabled", function()
    local query = require("lua-dadbod.query")
    local bufnr = vim.api.nvim_create_buf(false, true)

    config.setup({ completion = { omnifunc = true } })
    h.ok(query.attach("sqlite::memory:", bufnr))
    h.eq(vim.bo[bufnr].omnifunc, "v:lua.lua_dadbod_omnifunc")

    config.setup()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    completion.reset()
end)

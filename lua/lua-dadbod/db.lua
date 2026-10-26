local adapters = require("lua-dadbod.adapters")
local job = require("lua-dadbod.job")
local url = require("lua-dadbod.url")
local util = require("lua-dadbod.util")

local M = {}

local function empty_cache()
    return {
        schemas = {},
        tables = {},
        columns = {},
        loading = { schemas = {}, tables = {}, columns = {} },
    }
end

local meta_cache = empty_cache()

local function parse_input(input)
    if type(input) == "table" then
        return vim.deepcopy(input)
    end
    if type(input) ~= "string" then
        return nil, "connection URL must be a string"
    end

    local resolved = url.resolve(input)
    if resolved == "" then
        return nil, "connection URL is empty"
    end

    local parsed, err = url.parse(resolved)
    if not parsed then
        return nil, err
    end
    return parsed
end

function M.parse(input)
    local parsed, err = parse_input(input)
    if not parsed then
        return nil, err
    end

    local adapter, result = adapters.canonicalize(parsed)
    if not adapter then
        return nil, result
    end

    return result, adapter
end

function M.resolve(input)
    local parsed, adapter = M.parse(input)
    if not parsed then
        return nil, adapter
    end
    return url.format(parsed), adapter
end

function M.argv(input, opts)
    local parsed, adapter = M.parse(input)
    if not parsed or not adapter then
        return nil, nil, adapter or "invalid connection URL"
    end

    local argv, env = adapter.argv(parsed, opts or {})
    if type(argv) ~= "table" or #argv == 0 then
        return nil, nil, "adapter returned an empty command: " .. adapter.name
    end

    return argv, env, adapter
end

function M.binary(input)
    local parsed, adapter = M.parse(input)
    if not parsed or not adapter then
        return nil, adapter or "invalid connection URL"
    end

    local binary = type(adapter.binary) == "function" and adapter.binary(parsed) or adapter.binary
    if type(binary) ~= "string" or binary == "" then
        return nil, "adapter has no binary: " .. adapter.name
    end

    return binary, adapter
end

function M.check_binary(input)
    local binary, adapter = M.binary(input)
    if not binary then
        return false, adapter
    end
    if not util.is_executable(binary) then
        return false, "'" .. binary .. "' executable not found"
    end
    return true
end

function M.file_path(input)
    local parsed, adapter = M.parse(input)
    if not parsed or not adapter then
        return nil, adapter or "invalid connection URL"
    end
    return url.file_path(parsed)
end

function M.adapters()
    return adapters
end

function M.resolve_buffer(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid buffer"
    end

    local meta = vim.b[bufnr].lua_dadbod
    if type(meta) == "table" then
        local value = meta.conn or meta.url
        if type(value) == "string" and value ~= "" then
            return value
        end
    end

    local buffer_db = vim.b[bufnr].db
    if type(buffer_db) == "string" and buffer_db ~= "" then
        return buffer_db
    end

    local global_db = vim.g.db
    if type(global_db) == "string" and global_db ~= "" then
        return global_db
    end

    local env_db = vim.env.DATABASE_URL
    if type(env_db) == "string" and env_db ~= "" then
        return env_db
    end

    return nil, "no connection for this buffer; pass a URL or set b:db or g:db"
end

local function finish_loading(kind, key, items, err)
    local callbacks = meta_cache.loading[kind][key] or {}
    meta_cache.loading[kind][key] = nil
    for _, callback in ipairs(callbacks) do
        callback(items and vim.deepcopy(items) or nil, err)
    end
end

local function metadata_error(result, label)
    local message = util.trim(result.stderr)
    if message == "" then
        message = label .. " metadata query failed with exit " .. tostring(result.code)
    end
    return message
end

local function parse_lines(text)
    local items = {}
    for _, line in ipairs(util.split_lines(text)) do
        local value = util.trim(line)
        if value ~= "" then
            items[#items + 1] = value
        end
    end
    return items
end

local function parse_rows(text)
    local rows = {}
    for _, line in ipairs(util.split_lines(text)) do
        if util.trim(line) ~= "" then
            rows[#rows + 1] = vim.split(line, "\t", { plain = true })
        end
    end
    return rows
end

local function column_key(key, schema, table)
    return key .. "\0" .. (schema or "") .. "\0" .. (table or "")
end

-- Canonical connection context shared by the metadata cache.
local function metadata_target(input)
    local parsed, adapter = M.parse(input)
    if not parsed or not adapter then
        return nil, adapter or "invalid connection URL"
    end
    return { parsed = parsed, key = url.format(parsed), adapter = adapter }
end

local function database_name(parsed)
    return parsed.path and parsed.path:gsub("^/", "") or nil
end

local function check_callback(name, callback)
    if type(callback) ~= "function" then
        error("lua-dadbod.db." .. name .. ": callback must be a function")
    end
end

local function adapter_query(adapter, field, ctx)
    local ok, statement = pcall(adapter[field], ctx)
    if not ok or type(statement) ~= "string" or util.trim(statement) == "" then
        return nil
    end
    return statement
end

local function decode_columns(text)
    local columns = {}
    for _, row in ipairs(parse_rows(text)) do
        if type(row[1]) == "string" and row[1] ~= "" then
            columns[#columns + 1] = { name = row[1], type = row[2] or "" }
        end
    end
    return columns
end

-- Cache lookup, coalescing, and error handling shared by every metadata kind.
-- spec.build returns the adapter query for a connection context and spec.decode
-- turns stdout into the cached value.
local function read_metadata(ctx, spec, callback)
    local cache = meta_cache[spec.kind]
    local loading = meta_cache.loading[spec.kind]
    local cache_key = spec.cache_key or ctx.key

    if cache[cache_key] then
        callback(vim.deepcopy(cache[cache_key]), nil)
        return
    end
    if loading[cache_key] then
        table.insert(loading[cache_key], callback)
        return
    end
    if not ctx.adapter[spec.field] then
        callback(nil, "adapter has no " .. spec.label .. " metadata: " .. ctx.adapter.name)
        return
    end

    local statement = spec.build(ctx)
    if not statement then
        callback(nil, "adapter returned no " .. spec.label .. " metadata query: " .. ctx.adapter.name)
        return
    end

    loading[cache_key] = { callback }

    local handle, err = M.run(ctx.key, statement, { meta = true }, function(result)
        if result.code ~= 0 then
            finish_loading(spec.kind, cache_key, nil, metadata_error(result, spec.label))
            return
        end
        local items = spec.decode(result.stdout)
        cache[cache_key] = items
        finish_loading(spec.kind, cache_key, items, nil)
    end)

    if not handle then
        finish_loading(spec.kind, cache_key, nil, err)
    end
end

function M.fetch_schemas(input, callback)
    check_callback("fetch_schemas", callback)
    local ctx, err = metadata_target(input)
    if not ctx then
        callback(nil, err)
        return
    end

    read_metadata(ctx, {
        kind = "schemas",
        label = "schema",
        field = "schemas_sql",
        build = function(target)
            return adapter_query(target.adapter, "schemas_sql", {
                schema = target.adapter.default_schema,
                db = database_name(target.parsed),
            })
        end,
        decode = parse_lines,
    }, callback)
end

function M.fetch_tables(input, schema, callback)
    if type(schema) == "function" then
        callback = schema
        schema = nil
    end
    check_callback("fetch_tables", callback)
    local ctx, err = metadata_target(input)
    if not ctx then
        callback(nil, err)
        return
    end

    read_metadata(ctx, {
        kind = "tables",
        label = "table",
        field = "tables_sql",
        cache_key = ctx.key .. "\0" .. (schema or ""),
        build = function(target)
            return adapter_query(target.adapter, "tables_sql", {
                schema = schema or target.adapter.default_schema,
                db = database_name(target.parsed),
            })
        end,
        decode = parse_lines,
    }, callback)
end

-- Cache readers used by completion. They return the live cache entry instead
-- of a copy, so callers must treat the result as read-only.
function M.cached_schemas(input)
    local ctx = metadata_target(input)
    if not ctx then
        return nil
    end
    return meta_cache.schemas[ctx.key]
end

function M.cached_tables(input, schema)
    local ctx = metadata_target(input)
    if not ctx then
        return nil
    end
    local cached = meta_cache.tables[ctx.key .. "\0" .. (schema or ctx.adapter.default_schema or "")]
    if not cached and schema == nil then
        cached = meta_cache.tables[ctx.key .. "\0"]
    end
    return cached
end

function M.cached_columns(input, schema, table)
    local ctx = metadata_target(input)
    if not ctx then
        return nil
    end
    if schema == "" then
        schema = nil
    end
    return meta_cache.columns[column_key(ctx.key, schema or ctx.adapter.default_schema, table)]
end

function M.fetch_columns(input, target, callback)
    target = target or {}
    check_callback("fetch_columns", callback)
    local ctx, err = metadata_target(input)
    if not ctx then
        callback(nil, err)
        return
    end

    local table_name = target.table
    if type(table_name) ~= "string" or table_name == "" then
        callback(nil, "a table name is required for column metadata")
        return
    end

    local schema = target.schema
    if schema == "" then
        schema = nil
    end
    schema = schema or ctx.adapter.default_schema

    read_metadata(ctx, {
        kind = "columns",
        label = "column",
        field = "columns_sql",
        cache_key = column_key(ctx.key, schema, table_name),
        build = function(conn)
            return adapter_query(conn.adapter, "columns_sql", {
                schema = schema,
                db = database_name(conn.parsed),
                table = table_name,
            })
        end,
        decode = decode_columns,
    }, callback)
end

local function clear_prefix(cache, prefix)
    for cache_key in pairs(cache) do
        if cache_key:sub(1, #prefix) == prefix then
            cache[cache_key] = nil
        end
    end
end

function M.clear_meta(input)
    if not input then
        meta_cache = empty_cache()
        return
    end

    local ctx = metadata_target(input)
    if not ctx then
        return
    end

    meta_cache.schemas[ctx.key] = nil
    meta_cache.loading.schemas[ctx.key] = nil
    local prefix = ctx.key .. "\0"
    clear_prefix(meta_cache.tables, prefix)
    clear_prefix(meta_cache.loading.tables, prefix)
    clear_prefix(meta_cache.columns, prefix)
    clear_prefix(meta_cache.loading.columns, prefix)
end

function M.run(input, sql, opts, callback)
    opts = opts or {}
    if type(sql) ~= "string" then
        return nil, "SQL must be a string"
    end
    if sql ~= "" and not sql:match("\n$") then
        sql = sql .. "\n"
    end

    local ok, err = M.check_binary(input)
    if not ok then
        return nil, err
    end

    local parsed, parsed_adapter = M.parse(input)
    if parsed and parsed_adapter and parsed_adapter.missing_warning then
        local warning = parsed_adapter.missing_warning(parsed)
        if warning then
            util.warn(warning)
        end
    end

    local argv, env, adapter = M.argv(input, opts)
    if not argv then
        return nil, adapter
    end

    local handle = job.run(argv, {
        stdin = sql,
        env = env,
        cwd = opts.cwd,
        timeout = opts.timeout,
    }, callback)

    return handle, nil, adapter
end

return M

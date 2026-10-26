local sql = require("lua-dadbod.sql")

local M = {
    name = "mysql",
    aliases = { mariadb = true },
    binary = "mysql",
    quote = { "`", "`" },
    filetype = "sql",
    result_format = "tsv",
    helpers = {
        Columns = "select column_name, column_type, is_nullable, column_default, column_key from information_schema.columns where table_schema = coalesce(nullif({schema_lit}, ''), database()) and table_name = {table_lit} order by ordinal_position",
    },
}

local function connection_args(parsed)
    local args = {}
    if parsed.host and parsed.host ~= "" then
        args[#args + 1] = "--host=" .. parsed.host
    end
    if parsed.port and parsed.port ~= "" then
        args[#args + 1] = "--port=" .. parsed.port
    end
    if parsed.user and parsed.user ~= "" then
        args[#args + 1] = "--user=" .. parsed.user
    end
    local dbname = parsed.path and parsed.path:gsub("^/", "") or ""
    if dbname ~= "" then
        args[#args + 1] = "--database=" .. dbname
    end
    return args
end

local function password_env(parsed)
    if parsed.password ~= nil then
        return { MYSQL_PWD = parsed.password }
    end
end

function M.argv(parsed, opts)
    local args = { M.binary, "--batch" }
    if opts and opts.meta then
        args[#args + 1] = "--skip-column-names"
    end
    vim.list_extend(args, connection_args(parsed))
    return args, password_env(parsed)
end

function M.interactive(parsed)
    local args = { M.binary }
    vim.list_extend(args, connection_args(parsed))
    return args, password_env(parsed)
end

function M.tables_sql(ctx)
    local dbname = ctx and (ctx.schema or ctx.db) or ""
    local schema = dbname ~= "" and sql.literal(dbname) or "database()"
    return "select table_name from information_schema.tables where table_schema = "
        .. schema
        .. " and table_type in ('BASE TABLE','VIEW') order by table_name"
end

function M.schemas_sql()
    return "select schema_name from information_schema.schemata order by schema_name"
end

function M.columns_sql(ctx)
    ctx = ctx or {}
    local dbname = ctx.schema or ctx.db or ""
    local schema = dbname ~= "" and sql.literal(dbname) or "database()"
    return "select column_name, column_type, is_nullable, column_default, column_key from information_schema.columns where table_schema = "
        .. schema
        .. " and table_name = "
        .. sql.literal(ctx.table)
        .. " order by ordinal_position"
end

return M

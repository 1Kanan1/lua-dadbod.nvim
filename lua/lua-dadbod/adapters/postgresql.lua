local sql = require("lua-dadbod.sql")
local url = require("lua-dadbod.url")

local M = {
    name = "postgresql",
    aliases = { postgres = true },
    binary = "psql",
    quote = { '"', '"' },
    default_schema = "public",
    filetype = "sql",
    result_format = "csv",
    helpers = {
        Columns = "select column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = coalesce(nullif({schema_lit}, ''), current_schema()) and table_name = {table_lit} order by ordinal_position",
    },
}

function M.argv(parsed, opts)
    local args = { M.binary, "-X", "-v", "ON_ERROR_STOP=1" }
    if opts and opts.meta then
        vim.list_extend(args, { "-t", "-A", "-F", "\t" })
    else
        vim.list_extend(args, { "--csv", "-P", "null=NULL" })
    end
    vim.list_extend(args, { "-P", "footer=off", "-P", "pager=off" })
    args[#args + 1] = url.format(parsed)
    return args
end

function M.interactive(parsed)
    return { M.binary, url.format(parsed) }
end

function M.tables_sql(ctx)
    local schema = ctx and ctx.schema or M.default_schema
    return "select table_name from information_schema.tables where table_schema = "
        .. sql.literal(schema)
        .. " and table_type in ('BASE TABLE','VIEW') order by table_name"
end

function M.schemas_sql()
    return "select schema_name from information_schema.schemata where schema_name = 'pg_catalog' or schema_name not like 'pg_%' order by schema_name"
end

function M.columns_sql(ctx)
    ctx = ctx or {}
    local schema = ctx.schema and ctx.schema ~= "" and sql.literal(ctx.schema) or "current_schema()"
    return "select column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = "
        .. schema
        .. " and table_name = "
        .. sql.literal(ctx.table)
        .. " order by ordinal_position"
end

function M.supports_schemas()
    return true
end

return M

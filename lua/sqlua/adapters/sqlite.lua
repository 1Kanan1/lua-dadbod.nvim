local url = require("sqlua.url")
local sql = require("sqlua.sql")

local M = {
	name = "sqlite",
	aliases = { sqlite3 = true },
	binary = "sqlite3",
	quote = { '"', '"' },
	filetype = "sql",
	helpers = {
		Columns = 'select name, type, "notnull", dflt_value, pk from pragma_table_info({table_lit})',
	},
}

function M.canonicalize(parsed)
	return url.canonicalize_file(parsed)
end

function M.argv(parsed, opts)
	local args = { M.binary }
	if opts and opts.meta then
		args[#args + 1] = "-noheader"
	else
		args[#args + 1] = "-header"
		args[#args + 1] = "-column"
	end
	args[#args + 1] = "-separator"
	args[#args + 1] = "\t"
	args[#args + 1] = url.file_path(parsed)
	return args
end

function M.interactive(parsed)
	return { M.binary, url.file_path(parsed) }
end

function M.tables_sql()
	return "select name from sqlite_schema where type in ('table','view') and name not like 'sqlite_%' order by name"
end

function M.columns_sql(ctx)
	return 'select name, type, "notnull", dflt_value, pk from pragma_table_info(' .. sql.literal(ctx.table) .. ")"
end

return M

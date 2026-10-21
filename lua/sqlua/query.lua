local config = require("sqlua.config")
local db = require("sqlua.db")
local sql = require("sqlua.sql")
local util = require("sqlua.util")

local M = {}

local function mappings_enabled(section)
	local mappings = config.get().mappings
	if mappings == false then
		return false
	end
	if not mappings then
		return true
	end
	if mappings.enabled == false then
		return false
	end
	return mappings[section] ~= false
end

local function connection_parts(connection)
	if type(connection) == "string" then
		return connection, nil
	end
	if type(connection) == "table" then
		return connection.url or connection.conn, connection.name
	end
	return nil, nil
end

local function helper_sql(connection, opts)
	local parsed, adapter = db.parse(connection)
	if not parsed or not adapter then
		return nil, adapter or "invalid connection URL"
	end

	local helper = opts.helper or "List"
	local template = adapter.helpers and adapter.helpers[helper]
	if not template then
		return nil, "no helper " .. helper .. " for " .. adapter.name
	end
	if template == "" then
		return nil, "helper " .. helper .. " is disabled"
	end

	local quote = adapter.quote
	local function ident(value)
		if not value or value == "" then
			return ""
		end
		if quote then
			return sql.ident(value, quote[1], quote[2])
		end
		return value
	end

	local function literal(value)
		return sql.literal(value or "")
	end

	local schema = opts.schema or ""
	local table_name = opts.table or ""
	local dbname = opts.dbname or schema

	local optional_schema = ""
	if schema ~= "" and schema ~= (adapter.default_schema or "") then
		optional_schema = ident(schema) .. "."
	end

	local replacements = {
		["{table}"] = ident(table_name),
		["{schema}"] = ident(schema),
		["{optional_schema}"] = optional_schema,
		["{dbname}"] = ident(dbname),
		["{table_lit}"] = literal(table_name),
		["{schema_lit}"] = literal(schema),
		["{dbname_lit}"] = literal(dbname),
	}

	local content = template
	for placeholder, value in pairs(replacements) do
		content = content:gsub(placeholder, function()
			return value
		end)
	end

	return content, adapter, parsed
end

function M.quote_value(value)
	local trimmed = util.trim(value)
	if trimmed == "" then
		return value
	end
	if trimmed:match("^'.*'$")
		or trimmed:match("^%-?%d+%.?%d*$")
		or trimmed:lower() == "true"
		or trimmed:lower() == "false"
		or trimmed:lower() == "null"
	then
		return trimmed
	end
	return "'" .. trimmed:gsub("'", "''") .. "'"
end

function M.find_params(text)
	local pattern = config.get().bind_param_pattern
	local ordered = {}
	local seen = {}

	for line in tostring(text or ""):gmatch("[^\n]*") do
		local clean = line:gsub("'[^']*'", "")
		local init = 1
		while true do
			local start, finish = clean:find(pattern, init)
			if not start then
				break
			end
			local name = clean:sub(start, finish)
			local before = start > 1 and clean:sub(start - 1, start - 1) or ""
			if not before:match("[:%w_]") and not seen[name] then
				seen[name] = true
				ordered[#ordered + 1] = name
			end
			init = finish + 1
		end
	end

	return ordered
end

function M.substitute(text, bind)
	local names = vim.tbl_keys(bind or {})
	table.sort(names, function(a, b)
		return #a > #b
	end)

	local result = text
	for _, name in ipairs(names) do
		local value = bind[name]
		if value ~= nil and util.trim(value) ~= "" then
			result = result:gsub(vim.pesc(name), function()
				return M.quote_value(value)
			end)
		end
	end
	return result
end

function M.resolve_binds(text, bind, callback)
	bind = bind or {}
	local params = M.find_params(text)
	local index = 1

	local function next_param()
		while index <= #params and bind[params[index]] ~= nil do
			index = index + 1
		end
		if index > #params then
			callback(M.substitute(text, bind), bind)
			return
		end

		local name = params[index]
		index = index + 1
		vim.ui.input({ prompt = "Value for " .. name .. ": " }, function(value)
			if value == nil then
				return
			end
			bind[name] = value
			next_param()
		end)
	end

	next_param()
end

function M.open(connection, opts)
	opts = opts or {}
	local connection_url, connection_name = connection_parts(connection)
	if not connection_url or connection_url == "" then
		return nil, "connection URL is required"
	end

	local canonical, err = db.resolve(connection_url)
	if not canonical then
		return nil, err
	end

	local parsed, adapter = db.parse(canonical)
	if not parsed or not adapter then
		return nil, adapter or "invalid connection URL"
	end

	connection_name = connection_name
		or (parsed.opaque and parsed.opaque ~= ":memory:" and parsed.opaque)
		or (parsed.path and parsed.path:gsub("^/", ""))
		or adapter.name

	local dbname = opts.dbname or opts.schema or (parsed.path and parsed.path:gsub("^/", "")) or connection_name
	local directory = vim.fn.expand(config.get().tmp_location)
	util.ensure_dir(directory)

	local base = util.slug(connection_name)
	if opts.table and opts.table ~= "" then
		base = base .. "-" .. util.slug(opts.table) .. "-" .. util.slug(opts.helper or "List")
	else
		base = base .. "-query"
	end

	local stamp = os.date("%Y%m%d-%H%M%S")
	local path = directory .. "/" .. base .. "-" .. stamp .. ".sql"
	local suffix = 1
	while vim.fn.filereadable(path) == 1 or vim.fn.bufnr(path) ~= -1 do
		suffix = suffix + 1
		path = directory .. "/" .. base .. "-" .. stamp .. "-" .. suffix .. ".sql"
	end

	local ok, write_err = util.write_file(path, {})
	if not ok then
		return nil, write_err
	end

	vim.cmd("botright split")
	local bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(0, bufnr)
	vim.api.nvim_buf_set_name(bufnr, path)
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = adapter.filetype or "sql"

	local meta = {
		conn = canonical,
		url = connection_url,
		conn_name = connection_name,
		conn_key = (type(connection) == "table" and connection.key) or connection_name,
		source = "scratch",
		schema = opts.schema or "",
		table = opts.table or "",
		helper = opts.helper or "",
		bind = {},
		result_buf = nil,
	}
	vim.b[bufnr].sqlua = meta

	if mappings_enabled("query") then
		vim.keymap.set("n", "<Leader>S", function()
			M.run(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Run sqlua query" })
		vim.keymap.set("v", "<Leader>S", function()
			M.run_visual(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Run sqlua selection" })
		vim.keymap.set("n", "<Leader>W", function()
			M.save(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Save sqlua query" })
		vim.keymap.set("n", "<Leader>E", function()
			M.edit_bind(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Edit sqlua bind parameters" })
	end

	vim.api.nvim_create_autocmd("BufWritePost", {
		buffer = bufnr,
		callback = function()
			if config.get().execute_on_save then
				M.run(bufnr)
			end
		end,
	})

	local content = opts.sql
	if not content and opts.table and opts.table ~= "" then
		local helper_err
		content, helper_err = helper_sql(canonical, {
			table = opts.table,
			schema = opts.schema,
			helper = opts.helper,
			dbname = dbname,
		})
		if not content then
			return nil, helper_err
		end
	end

	if content and content ~= "" then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
	end

	local auto_execute = opts.auto_execute
	if auto_execute == nil then
		auto_execute = config.get().auto_execute_helpers and content ~= nil and content ~= ""
	end
	if auto_execute then
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				M.run(bufnr)
			end
		end)
	end

	return bufnr
end

function M.run(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return require("sqlua.execute").run_buffer({ bufnr = bufnr })
end

function M.run_visual(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local start = vim.fn.line("'<")
	local finish = vim.fn.line("'>")
	if start == 0 or finish == 0 then
		util.warn("no visual selection")
		return
	end
	if start > finish then
		start, finish = finish, start
	end
	return require("sqlua.execute").run_buffer({
		bufnr = bufnr,
		line1 = start,
		line2 = finish,
	})
end

function M.save_as(bufnr, name)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "invalid buffer"
	end

	local meta = vim.b[bufnr].sqlua
	if type(meta) ~= "table" or not meta.conn then
		return nil, "buffer is not attached to a connection"
	end

	name = util.trim(name or "")
	if name == "" then
		return nil, "a query name is required"
	end
	name = name:gsub("[/\\]", "_")
	if name:sub(-4):lower() ~= ".sql" then
		name = name .. ".sql"
	end

	local connection_name = meta.conn_name or meta.conn_key or "db"
	local directory = vim.fn.expand(config.get().save_location) .. "/queries/" .. util.slug(connection_name)
	util.ensure_dir(directory)

	local path = directory .. "/" .. name
	if vim.fn.filereadable(path) == 1 then
		return nil, "a query with that name already exists"
	end

	local ok, err = pcall(function()
		vim.api.nvim_buf_call(bufnr, function()
			vim.cmd("silent noautocmd saveas " .. vim.fn.fnameescape(path))
		end)
	end)
	if not ok then
		return nil, "cannot save query: " .. tostring(err)
	end

	meta.source = "saved"
	meta.path = path
	vim.b[bufnr].sqlua = meta
	return path
end

function M.save(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local default = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
	if default == "" then
		default = "query"
	end
	util.input("Save query as: ", default, function(name)
		local path, err = M.save_as(bufnr, name)
		if not path then
			util.error(err)
			return
		end
		util.notify("saved " .. path)
	end)
end

function M.edit_bind(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sqlua
	if type(meta) ~= "table" then
		util.warn("buffer is not attached to a connection")
		return
	end

	local bind = meta.bind or {}
	local keys = vim.tbl_keys(bind)
	if #keys == 0 then
		util.notify("no bind parameters to edit")
		return
	end
	table.sort(keys)

	local choices = {}
	for _, key in ipairs(keys) do
		local value = tostring(bind[key]):gsub("\n", "\\n")
		choices[#choices + 1] = key .. " = " .. value
	end
	choices[#choices + 1] = "Clear all"

	vim.ui.select(choices, { prompt = "Bind parameters" }, function(_, index)
		if not index then
			return
		end
		if index == #choices then
			meta.bind = {}
			vim.b[bufnr].sqlua = meta
			util.notify("cleared bind parameters")
			return
		end

		local key = keys[index]
		vim.ui.input({ prompt = "Value for " .. key .. ": ", default = bind[key] or "" }, function(value)
			if value == nil then
				return
			end
			if util.trim(value) == "" then
				bind[key] = nil
			else
				bind[key] = value
			end
			meta.bind = bind
			vim.b[bufnr].sqlua = meta
			util.notify("updated " .. key)
		end)
	end)
end

M.helper_sql = helper_sql

return M

local adapters = require("lua-dadbod.adapters")
local job = require("lua-dadbod.job")
local url = require("lua-dadbod.url")
local util = require("lua-dadbod.util")

local M = {}

local meta_cache = {
	schemas = {},
	tables = {},
	loading = { schemas = {}, tables = {} },
}

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

function M.fetch_schemas(input, callback)
	if type(callback) ~= "function" then
		error("lua-dadbod.db.fetch_schemas: callback must be a function")
	end

	local parsed, adapter = M.parse(input)
	if not parsed or not adapter then
		callback(nil, adapter or "invalid connection URL")
		return
	end

	local key = url.format(parsed)
	if meta_cache.schemas[key] then
		callback(vim.deepcopy(meta_cache.schemas[key]), nil)
		return
	end
	if meta_cache.loading.schemas[key] then
		table.insert(meta_cache.loading.schemas[key], callback)
		return
	end
	if not adapter.schemas_sql then
		callback(nil, "adapter has no schema metadata: " .. adapter.name)
		return
	end

	local ctx = {
		schema = adapter.default_schema,
		db = parsed.path and parsed.path:gsub("^/", "") or nil,
	}
	local ok, statement = pcall(adapter.schemas_sql, ctx)
	if not ok or type(statement) ~= "string" or util.trim(statement) == "" then
		callback(nil, "adapter returned no schema metadata query: " .. adapter.name)
		return
	end

	meta_cache.loading.schemas[key] = { callback }

	local handle, err = M.run(key, statement, { meta = true }, function(result)
		if result.code ~= 0 then
			finish_loading("schemas", key, nil, metadata_error(result, "schema"))
			return
		end

		local schemas = parse_lines(result.stdout)
		meta_cache.schemas[key] = schemas
		finish_loading("schemas", key, schemas, nil)
	end)

	if not handle then
		finish_loading("schemas", key, nil, err)
	end
end

function M.fetch_tables(input, schema, callback)
	if type(schema) == "function" then
		callback = schema
		schema = nil
	end
	if type(callback) ~= "function" then
		error("lua-dadbod.db.fetch_tables: callback must be a function")
	end

	local parsed, adapter = M.parse(input)
	if not parsed or not adapter then
		callback(nil, adapter or "invalid connection URL")
		return
	end

	local key = url.format(parsed)
	local cache_key = key .. "\0" .. (schema or "")
	if meta_cache.tables[cache_key] then
		callback(vim.deepcopy(meta_cache.tables[cache_key]), nil)
		return
	end
	if meta_cache.loading.tables[cache_key] then
		table.insert(meta_cache.loading.tables[cache_key], callback)
		return
	end
	if not adapter.tables_sql then
		callback(nil, "adapter has no table metadata: " .. adapter.name)
		return
	end

	local ctx = {
		schema = schema or adapter.default_schema,
		db = parsed.path and parsed.path:gsub("^/", "") or nil,
	}
	local ok, statement = pcall(adapter.tables_sql, ctx)
	if not ok or type(statement) ~= "string" or util.trim(statement) == "" then
		callback(nil, "adapter returned no table metadata query: " .. adapter.name)
		return
	end

	meta_cache.loading.tables[cache_key] = { callback }

	local handle, err = M.run(key, statement, { meta = true }, function(result)
		if result.code ~= 0 then
			finish_loading("tables", cache_key, nil, metadata_error(result, "table"))
			return
		end

		local tables = parse_lines(result.stdout)
		meta_cache.tables[cache_key] = tables
		finish_loading("tables", cache_key, tables, nil)
	end)

	if not handle then
		finish_loading("tables", cache_key, nil, err)
	end
end

function M.clear_meta(input)
	if input then
		local parsed = M.parse(input)
		if parsed then
			local key = url.format(parsed)
			meta_cache.schemas[key] = nil
			meta_cache.loading.schemas[key] = nil

			local prefix = key .. "\0"
			for cache_key in pairs(meta_cache.tables) do
				if cache_key:sub(1, #prefix) == prefix then
					meta_cache.tables[cache_key] = nil
				end
			end
			for cache_key in pairs(meta_cache.loading.tables) do
				if cache_key:sub(1, #prefix) == prefix then
					meta_cache.loading.tables[cache_key] = nil
				end
			end
		end
		return
	end

	meta_cache.schemas = {}
	meta_cache.tables = {}
	meta_cache.loading = { schemas = {}, tables = {} }
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

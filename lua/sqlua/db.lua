local adapters = require("sqlua.adapters")
local job = require("sqlua.job")
local url = require("sqlua.url")
local util = require("sqlua.util")

local M = {}

local meta_cache = {
	tables = {},
	loading = {},
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

	local meta = vim.b[bufnr].sqlua
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

local function finish_loading(key, tables, err)
	local callbacks = meta_cache.loading[key] or {}
	meta_cache.loading[key] = nil
	for _, callback in ipairs(callbacks) do
		callback(tables and vim.deepcopy(tables) or nil, err)
	end
end

function M.fetch_tables(input, callback)
	if type(callback) ~= "function" then
		error("sqlua.db.fetch_tables: callback must be a function")
	end

	local parsed, adapter = M.parse(input)
	if not parsed or not adapter then
		callback(nil, adapter or "invalid connection URL")
		return
	end

	local key = url.format(parsed)
	if meta_cache.tables[key] then
		callback(vim.deepcopy(meta_cache.tables[key]), nil)
		return
	end
	if meta_cache.loading[key] then
		table.insert(meta_cache.loading[key], callback)
		return
	end
	if not adapter.tables_sql then
		callback(nil, "adapter has no table metadata: " .. adapter.name)
		return
	end

	local ok, statement = pcall(adapter.tables_sql, {})
	if not ok or type(statement) ~= "string" or util.trim(statement) == "" then
		callback(nil, "adapter returned no table metadata query: " .. adapter.name)
		return
	end

	meta_cache.loading[key] = { callback }

	local handle, err = M.run(key, statement, { meta = true }, function(result)
		if result.code ~= 0 then
			local message = util.trim(result.stderr)
			if message == "" then
				message = "table metadata query failed with exit " .. tostring(result.code)
			end
			finish_loading(key, nil, message)
			return
		end

		local tables = {}
		for _, line in ipairs(util.split_lines(result.stdout)) do
			local value = util.trim(line)
			if value ~= "" then
				tables[#tables + 1] = value
			end
		end
		meta_cache.tables[key] = tables
		finish_loading(key, tables, nil)
	end)

	if not handle then
		finish_loading(key, nil, err)
	end
end

function M.clear_meta(input)
	if input then
		local parsed = M.parse(input)
		if parsed then
			meta_cache.tables[url.format(parsed)] = nil
		end
		return
	end
	meta_cache.tables = {}
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

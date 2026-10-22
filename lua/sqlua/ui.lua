local config = require("sqlua.config")
local db = require("sqlua.db")
local url = require("sqlua.url")
local util = require("sqlua.util")

local M = {}

local state = {
	initialized = false,
	list = {},
	by_key = {},
	warned = {},
	active = nil,
}

local function connection_file()
	return vim.fn.expand(config.get().save_location) .. "/connections.json"
end

local function url_name(raw)
	local parsed = url.parse(raw)
	if parsed then
		if parsed.opaque == ":memory:" then
			return "memory"
		end
		local value = parsed.opaque
			or (parsed.path and parsed.path:gsub("^/", ""))
		if value and value ~= "" then
			return vim.fs.basename(value)
		end
		if parsed.host and parsed.host ~= "" then
			return parsed.host
		end
	end
	return "default"
end

local function add_entry(list, seen, name, raw, source)
	if type(raw) ~= "string" then
		return
	end
	raw = util.trim(raw)
	if raw == "" then
		return
	end

	name = util.trim(name or "")
	if name == "" then
		name = url_name(raw)
	end

	local dedupe = source .. "\0" .. name:lower()
	if seen[dedupe] then
		if not state.warned[dedupe] then
			state.warned[dedupe] = true
			util.warn(string.format('duplicate connection "%s" in "%s"; keeping the first', name, source))
		end
		return
	end
	seen[dedupe] = true

	list[#list + 1] = {
		name = name,
		url = raw,
		source = source,
		key = name .. "_" .. source,
	}
end

local function resolve_value(value)
	if type(value) == "string" then
		return value
	end
	if type(value) == "function" then
		local ok, result = pcall(value)
		if not ok or type(result) ~= "string" then
			util.warn("g:dbs function did not return a string")
			return nil
		end
		return result
	end
	return nil
end

local function add_from_gdbs(list, seen, value, source)
	if type(value) ~= "table" then
		return
	end

	if #value > 0 then
		for _, item in ipairs(value) do
			if type(item) == "table" then
				add_entry(list, seen, item.name, resolve_value(item.url), source)
			end
		end
		return
	end

	local names = vim.tbl_keys(value)
	table.sort(names)
	for _, name in ipairs(names) do
		add_entry(list, seen, name, resolve_value(value[name]), source)
	end
end

local function add_sources(list, seen)
	local env_url = vim.env.SQLUA_URL
	if type(env_url) == "string" and env_url ~= "" then
		add_entry(list, seen, vim.env.SQLUA_NAME or "", env_url, "env")
	end

	local global_db = vim.g.db
	if type(global_db) == "string" and global_db ~= "" then
		add_entry(list, seen, "default", global_db, "g:db")
	end

	if type(vim.g.dbs) == "table" then
		add_from_gdbs(list, seen, vim.g.dbs, "g:dbs")
	end
	if type(config.get().dbs) == "table" then
		add_from_gdbs(list, seen, config.get().dbs, "config")
	end

	local file = connection_file()
	if vim.fn.filereadable(file) == 0 or vim.fn.getfsize(file) <= 0 then
		return
	end
	local data, err = util.read_json(file)
	if not data then
		util.warn(err)
		return
	end
	if type(data) ~= "table" or (#data == 0 and next(data) ~= nil) then
		util.warn("connections.json must contain an array")
		return
	end
	for _, item in ipairs(data) do
		if type(item) == "table" and type(item.url) == "string" then
			add_entry(list, seen, item.name, item.url, "file")
		end
	end
end

function M.refresh()
	local previous = state.by_key
	local list = {}
	local seen = {}

	add_sources(list, seen)

	local by_key = {}
	for _, entry in ipairs(list) do
		local old = previous[entry.key]
		if old and old.url == entry.url then
			entry.expanded = old.expanded
			entry.loading = old.loading
			entry.loaded = old.loaded
			entry.error = old.error
			entry.tables = old.tables
			entry.tables_expanded = old.tables_expanded
			entry.saved_expanded = old.saved_expanded
			entry.scheme = old.scheme
		else
			entry.tables_expanded = true
		end
		entry.tables = entry.tables or {}
		local parsed, adapter = db.parse(entry.url)
		if parsed and adapter then
			entry.dbms = adapter.name
		else
			local raw = url.parse(entry.url)
			entry.dbms = raw and raw.scheme or nil
		end
		by_key[entry.key] = entry
	end

	state.list = list
	state.by_key = by_key
	state.initialized = true

	if state.active and not by_key[state.active] then
		state.active = nil
	end
	if not state.active and #list == 1 then
		state.active = list[1].key
	end

	return list
end

function M.connections()
	if not state.initialized then
		M.refresh()
	end
	return state.list
end

function M.get(key)
	if not state.initialized then
		M.refresh()
	end
	return state.by_key[key]
end

function M.active()
	return state.active
end

function M.set_active(key)
	if key and state.by_key[key] then
		state.active = key
	end
end

local function path_key(path)
	if not path or path == "" then
		return nil
	end
	return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

local function meta_dbms(meta)
	if meta.dbms then
		return meta.dbms
	end
	if meta.conn then
		local parsed, adapter = db.parse(meta.conn)
		if parsed and adapter then
			return adapter.name
		end
	end
	return nil
end

function M.dbms_name(dbms)
	local names = {
		postgresql = "postgres",
	}
	return names[dbms] or dbms
end

function M.has_multiple_dbms()
	local seen = {}
	local count = 0
	for _, entry in ipairs(M.connections()) do
		if entry.dbms and not seen[entry.dbms] then
			seen[entry.dbms] = true
			count = count + 1
		end
	end
	return count > 1
end

function M.connection_label(dbms, name)
	name = name or "default"
	if dbms and M.has_multiple_dbms() then
		return M.dbms_name(dbms) .. "/" .. name
	end
	return name
end

function M.find_by_url(connection)
	local canonical = db.resolve(connection)
	if not canonical then
		return nil
	end
	for _, entry in ipairs(M.connections()) do
		local resolved = db.resolve(entry.url)
		if resolved == canonical then
			return entry
		end
	end
	return nil
end

function M.scratchpad_label(meta, bufnr)
	local label
	if meta.table and meta.table ~= "" then
		label = meta.table
		if meta.helper and meta.helper ~= "" and meta.helper ~= "List" then
			label = label .. " " .. meta.helper
		end
	elseif meta.path and meta.path ~= "" then
		label = vim.fs.basename(meta.path):gsub("%.sql$", "")
	else
		local name = vim.api.nvim_buf_get_name(bufnr)
		if name ~= "" and meta.source ~= "scratch" then
			label = vim.fs.basename(name):gsub("%.sql$", "")
		else
			label = "query"
		end
	end

	local connection = M.connection_label(meta_dbms(meta), meta.conn_name or meta.conn_key or "default")
	return label, connection
end

function M.scratchpads()
	local result = {}
	local seen = {}

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_option_value("buflisted", { buf = bufnr }) then
			local meta = vim.b[bufnr].sqlua
			if type(meta) == "table" then
				local path = meta.path
				if not path or path == "" then
					local name = vim.api.nvim_buf_get_name(bufnr)
					if name ~= "" then
						path = name
					end
				end

				local key = path_key(path)
				if key then
					seen[key] = true
				end

				local label, connection = M.scratchpad_label(meta, bufnr)
				result[#result + 1] = {
					kind = "buffer",
					bufnr = bufnr,
					path = path,
					conn = meta.conn,
					conn_key = meta.conn_key,
					label = label,
					conn_label = connection,
					modified = vim.api.nvim_get_option_value("modified", { buf = bufnr }),
					unsaved = meta.source == "scratch" or not meta.path,
				}
			end
		end
	end

	for _, entry in ipairs(M.connections()) do
		for _, path in ipairs(M.saved_queries(entry)) do
			local key = path_key(path)
			if key and not seen[key] then
				seen[key] = true
				result[#result + 1] = {
					kind = "file",
					path = path,
					conn = entry.url,
					conn_key = entry.key,
					label = vim.fs.basename(path):gsub("%.sql$", ""),
					conn_label = M.connection_label(entry.dbms, entry.name),
					modified = false,
					unsaved = false,
				}
			end
		end
	end

	table.sort(result, function(a, b)
		local left = (a.label .. "\0" .. a.conn_label):lower()
		local right = (b.label .. "\0" .. b.conn_label):lower()
		return left < right
	end)

	return result
end

function M.reset()
	state = {
		initialized = false,
		list = {},
		by_key = {},
		warned = {},
		active = nil,
	}
	db.clear_meta()
end

function M.clear_meta()
	db.clear_meta()
	for _, entry in ipairs(state.list) do
		entry.loaded = false
		entry.error = nil
		entry.tables = {}
	end
end

function M.scheme(entry)
	local parsed, adapter = db.parse(entry.url)
	if parsed and adapter then
		entry.scheme = adapter.name
	else
		entry.scheme = nil
	end
	return entry.scheme
end

function M.saved_dir(entry)
	return vim.fn.expand(config.get().save_location) .. "/queries/" .. util.slug(entry.key)
end

function M.saved_queries(entry)
	local directory = M.saved_dir(entry)
	if vim.fn.isdirectory(directory) == 0 then
		return {}
	end
	local files = vim.fn.globpath(directory, "*.sql", false, true)
	table.sort(files)
	return files
end

local function save_connection(raw, name, callback)
	name = util.trim(name or "")
	if name == "" then
		name = url_name(raw)
	end

	local file = connection_file()
	local data = {}
	if vim.fn.filereadable(file) == 1 and vim.fn.getfsize(file) > 0 then
		local decoded, err = util.read_json(file)
		if not decoded then
			util.error(err)
			return
		end
		if type(decoded) ~= "table" or (#decoded == 0 and next(decoded) ~= nil) then
			util.error("connections.json must contain an array")
			return
		end
		data = decoded
	end

	for _, item in ipairs(data) do
		if type(item) == "table" and item.name == name then
			util.error("a connection with that name already exists")
			return
		end
	end

	data[#data + 1] = { name = name, url = raw }
	local ok, err = util.write_json(file, data)
	if not ok then
		util.error(err)
		return
	end

	M.refresh()
	if callback then
		callback()
	end
	util.notify("added connection " .. name)
end

function M.add_connection(opts, callback)
	opts = opts or {}
	local raw = util.trim(opts.url or "")
	local name = util.trim(opts.name or "")

	local function finish(url_value, name_value)
		local parsed, err = db.parse(url_value)
		if not parsed then
			util.error(err)
			return
		end
		if name_value == "" then
			util.input("Connection name: ", url_name(url_value), function(input)
				if input ~= nil then
					save_connection(url_value, input, callback)
				end
			end)
			return
		end
		save_connection(url_value, name_value, callback)
	end

	if raw == "" then
		util.input("Connection URL: ", "", function(input)
			if input == nil then
				return
			end
			input = util.trim(input)
			if input == "" then
				util.warn("connection URL is required")
				return
			end
			finish(input, name)
		end)
		return
	end

	finish(raw, name)
end

function M.delete_connection(entry, callback)
	if entry.source ~= "file" then
		return nil, "only connections from connections.json can be deleted"
	end

	local file = connection_file()
	local data, err = util.read_json(file)
	if not data then
		return nil, err
	end

	local filtered = {}
	local removed = false
	for _, item in ipairs(data) do
		if type(item) == "table" and item.name == entry.name and item.url == entry.url then
			removed = true
		else
			filtered[#filtered + 1] = item
		end
	end

	if not removed then
		return nil, "connection not found in connections.json"
	end

	local ok, write_err = util.write_json(file, filtered)
	if not ok then
		return nil, write_err
	end

	M.refresh()
	if callback then
		callback()
	end
	return true
end

function M.pick(prompt, callback)
	local list = M.connections()
	if #list == 0 then
		return nil, "no connections"
	end

	local labels = {}
	for _, entry in ipairs(list) do
		labels[#labels + 1] = entry.name .. " (" .. entry.source .. ")"
	end

	vim.ui.select(labels, { prompt = prompt or "Select connection" }, function(_, index)
		if index then
			callback(list[index])
		end
	end)
	return true
end

M.connection_file = connection_file
M.url_name = url_name

return M

local M = {}

local by_name = {}
local alias_to_name = {}

function M.register(adapter)
	assert(type(adapter) == "table", "sqlua.adapters: adapter must be a table")
	assert(type(adapter.name) == "string" and adapter.name ~= "", "sqlua.adapters: adapter.name is required")
	assert(type(adapter.argv) == "function", "sqlua.adapters: adapter.argv is required for " .. adapter.name)

	by_name[adapter.name] = adapter
	for alias in pairs(adapter.aliases or {}) do
		alias_to_name[alias] = adapter.name
	end
	return adapter
end

function M.get(scheme)
	if type(scheme) ~= "string" or scheme == "" then
		return nil, "invalid URL scheme"
	end
	local name = alias_to_name[scheme:lower()] or scheme:lower()
	local adapter = by_name[name]
	if not adapter then
		return nil, "no adapter for " .. scheme
	end
	return adapter, name
end

function M.canonicalize(parsed)
	local seen = {}
	for _ = 1, 10 do
		local adapter, name = M.get(parsed.scheme)
		if not adapter then
			return nil, name
		end

		if seen[name] then
			return adapter, parsed
		end
		seen[name] = true
		parsed.scheme = name

		if adapter.canonicalize then
			local next_parsed, err = adapter.canonicalize(parsed)
			if err then
				return nil, err
			end
			if next_parsed then
				parsed = next_parsed
			end
		end

		if parsed.scheme == name then
			return adapter, parsed
		end
	end

	return nil, "infinite loop resolving URL"
end

function M.list()
	local names = vim.tbl_keys(by_name)
	table.sort(names)
	return names
end

function M.aliases()
	return vim.deepcopy(alias_to_name)
end

M.register(require("sqlua.adapters.sqlite"))
M.register(require("sqlua.adapters.postgresql"))
M.register(require("sqlua.adapters.mysql"))

return M

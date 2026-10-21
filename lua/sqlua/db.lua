local adapters = require("sqlua.adapters")
local url = require("sqlua.url")
local util = require("sqlua.util")

local M = {}

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
	if not parsed then
		return nil, nil, adapter
	end

	local argv, env = adapter.argv(parsed, opts or {})
	if type(argv) ~= "table" or #argv == 0 then
		return nil, nil, "adapter returned an empty command: " .. adapter.name
	end

	return argv, env, adapter
end

function M.binary(input)
	local parsed, adapter = M.parse(input)
	if not parsed then
		return nil, adapter
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

function M.safe_format(input)
	local parsed = M.parse(input)
	if not parsed then
		return ""
	end
	return url.safe_format(parsed)
end

function M.file_path(input)
	local parsed, adapter = M.parse(input)
	if not parsed then
		return nil, adapter
	end
	return url.file_path(parsed)
end

function M.adapters()
	return adapters
end

return M

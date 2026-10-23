local M = {}

function M.literal(value)
	return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

function M.ident(value, open, close)
	open = open or '"'
	close = close or open
	local escaped = tostring(value or ""):gsub(close, close .. close)
	return open .. escaped .. close
end

return M

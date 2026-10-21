local M = {}

function M.setup(opts)
	require("sqlua.config").setup(opts)
	return M
end

M.url = require("sqlua.url")
M.db = require("sqlua.db")
M.adapters = require("sqlua.adapters")

return M

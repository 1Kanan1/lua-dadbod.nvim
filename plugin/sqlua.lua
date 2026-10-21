if vim.g.loaded_sqlua == 1 then
	return
end

vim.g.loaded_sqlua = 1

vim.api.nvim_create_user_command("DB", function(opts)
	local util = require("sqlua.util")
	local ok, err = pcall(function()
		local _, command_err = require("sqlua.execute").db_command(opts)
		if command_err then
			error(command_err, 0)
		end
	end)
	if not ok then
		util.error(err)
	end
end, {
	range = true,
	bang = true,
	nargs = "*",
	desc = "Run a database query or open a console",
})

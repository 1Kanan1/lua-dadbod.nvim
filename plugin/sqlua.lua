if vim.g.loaded_sqlua == 1 then
	return
end

vim.g.loaded_sqlua = 1

local function command(name, callback, opts)
	vim.api.nvim_create_user_command(name, function(args)
		local ok, err = pcall(callback, args)
		if not ok then
			require("sqlua.util").error(err)
		end
	end, opts or {})
end

local function refresh_expanded()
	local ui = require("sqlua.ui")
	local drawer = require("sqlua.drawer")
	for _, entry in ipairs(ui.connections()) do
		if entry.expanded then
			drawer.fetch(entry)
		end
	end
end

command("DB", function(opts)
	local _, err = require("sqlua.execute").db_command(opts)
	if err then
		error(err, 0)
	end
end, {
	force = true,
	range = true,
	bang = true,
	nargs = "*",
	desc = "Run a database query or open a console",
})

command("Sqlua", function()
	require("sqlua.drawer").open()
end, {
	desc = "Open the sqlua drawer",
})

command("SqluaToggle", function()
	require("sqlua.drawer").toggle()
end, {
	desc = "Toggle the sqlua drawer",
})

command("SqluaClose", function()
	require("sqlua.drawer").close()
end, {
	desc = "Close the sqlua drawer",
})

command("SqluaAddConnection", function()
	local ui = require("sqlua.ui")
	ui.add_connection(nil, function()
		local drawer = require("sqlua.drawer")
		if drawer.is_open() then
			drawer.render()
		end
	end)
end, {
	desc = "Add a sqlua connection",
})

command("SqluaFindBuffer", function()
	local ui = require("sqlua.ui")
	local query = require("sqlua.query")
	local util = require("sqlua.util")
	local bufnr = vim.api.nvim_get_current_buf()
	local connections = ui.connections()

	if #connections == 0 then
		error("no connections configured", 0)
	end
	if #connections == 1 then
		local entry = connections[1]
		ui.set_active(entry.key)
		local attached, err = query.attach(entry, bufnr)
		if not attached then
			error(err, 0)
		end
		util.notify("attached buffer to " .. entry.name)
		return
	end

	ui.pick("Attach buffer to connection", function(entry)
		ui.set_active(entry.key)
		local attached, err = query.attach(entry, bufnr)
		if not attached then
			util.error(err)
			return
		end
		util.notify("attached buffer to " .. entry.name)
	end)
end, {
	desc = "Attach the current buffer to a sqlua connection",
})

command("SqluaRenameBuffer", function()
	local util = require("sqlua.util")
	local query = require("sqlua.query")
	local drawer = require("sqlua.drawer")
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sqlua

	if type(meta) ~= "table" or not meta.path then
		error("current buffer is not a saved query", 0)
	end

	local default = vim.fn.fnamemodify(meta.path, ":t:r")
	util.input("Rename query: ", default, function(name)
		local new_path, err = query.rename_file(meta.path, name)
		if not new_path then
			util.error(err)
			return
		end
		if drawer.is_open() then
			drawer.render()
		end
	end)
end, {
	desc = "Rename the current sqlua saved query",
})

command("SqluaClearCache", function()
	local ui = require("sqlua.ui")
	local drawer = require("sqlua.drawer")
	ui.clear_meta()
	refresh_expanded()
	if drawer.is_open() then
		drawer.render()
	end
	require("sqlua.util").notify("cache cleared")
end, {
	desc = "Clear sqlua metadata and completion caches",
})

command("SqluaRefresh", function()
	local ui = require("sqlua.ui")
	local drawer = require("sqlua.drawer")
	ui.clear_meta()
	ui.refresh()
	refresh_expanded()
	if drawer.is_open() then
		drawer.render()
	end
end, {
	desc = "Refresh sqlua connections",
})

if vim.g.loaded_lua_dadbod == 1 then
	return
end

vim.g.loaded_lua_dadbod = 1

local function command(name, callback, opts)
	vim.api.nvim_create_user_command(name, function(args)
		local ok, err = pcall(callback, args)
		if not ok then
			require("lua-dadbod.util").error(err)
		end
	end, opts or {})
end

local function refresh_expanded()
	local ui = require("lua-dadbod.ui")
	local drawer = require("lua-dadbod.drawer")
	for _, entry in ipairs(ui.connections()) do
		if entry.expanded then
			drawer.fetch(entry)
		end
	end
end

vim.api.nvim_create_autocmd("BufReadPost", {
	group = vim.api.nvim_create_augroup("lua_dadbod_saved_queries", { clear = true }),
	pattern = "*.sql",
	callback = function(args)
		local name = vim.api.nvim_buf_get_name(args.buf)
		if name == "" then
			return
		end
		local ui = require("lua-dadbod.ui")
		local entry = ui.find_saved_connection(name)
		if not entry then
			return
		end
		local attached, err = require("lua-dadbod.query").attach(entry, args.buf, {
			source = "saved",
			path = name,
		})
		if not attached then
			require("lua-dadbod.util").error(err)
			return
		end
		ui.set_active(entry.key)
	end,
})

command("DB", function(opts)
	local _, err = require("lua-dadbod.execute").db_command(opts)
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

command("LuaDadbod", function()
	require("lua-dadbod.drawer").open()
end, {
	desc = "Open the lua-dadbod drawer",
})

command("LuaDadbodToggle", function()
	require("lua-dadbod.drawer").toggle()
end, {
	desc = "Toggle the lua-dadbod drawer",
})

command("LuaDadbodClose", function()
	require("lua-dadbod.drawer").close()
end, {
	desc = "Close the lua-dadbod drawer",
})

command("LuaDadbodAddConnection", function()
	require("lua-dadbod").add_connection()
end, {
	desc = "Add a lua-dadbod connection",
})

command("LuaDadbodFindBuffer", function()
	require("lua-dadbod").attach()
end, {
	desc = "Attach the current buffer to a lua-dadbod connection",
})

command("LuaDadbodRenameBuffer", function()
	local util = require("lua-dadbod.util")
	local query = require("lua-dadbod.query")
	local drawer = require("lua-dadbod.drawer")
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].lua_dadbod

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
	desc = "Rename the current lua-dadbod saved query",
})

command("LuaDadbodClearCache", function()
	local ui = require("lua-dadbod.ui")
	local drawer = require("lua-dadbod.drawer")
	ui.clear_meta()
	refresh_expanded()
	if drawer.is_open() then
		drawer.render()
	end
	require("lua-dadbod.util").notify("cache cleared")
end, {
	desc = "Clear lua-dadbod metadata and completion caches",
})

command("LuaDadbodRefresh", function()
	local ui = require("lua-dadbod.ui")
	local drawer = require("lua-dadbod.drawer")
	ui.clear_meta()
	ui.refresh()
	refresh_expanded()
	if drawer.is_open() then
		drawer.render()
	end
end, {
	desc = "Refresh lua-dadbod connections",
})

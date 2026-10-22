local M = {}

local global_keys = {
	"<leader>Do",
	"<leader>Dt",
	"<leader>Dc",
	"<leader>Da",
	"<leader>Df",
	"<leader>Dx",
}

local function remove_global_mappings()
	for _, lhs in ipairs(global_keys) do
		pcall(vim.keymap.del, "n", lhs)
	end
end

function M.setup_mappings()
	local mappings = require("sqlua.config").get().mappings
	if
		mappings == false
		or (type(mappings) == "table" and (mappings.enabled == false or mappings.global == false))
	then
		remove_global_mappings()
		return
	end

	local function map(lhs, callback, desc)
		vim.keymap.set("n", lhs, callback, { desc = desc })
	end

	map("<leader>Do", function()
		require("sqlua.drawer").open()
	end, "sqlua: open drawer")
	map("<leader>Dt", function()
		require("sqlua.drawer").toggle()
	end, "sqlua: toggle drawer")
	map("<leader>Dc", function()
		require("sqlua.drawer").close()
	end, "sqlua: close drawer")
	map("<leader>Da", function()
		M.add_connection()
	end, "sqlua: add connection")
	map("<leader>Df", function()
		M.attach()
	end, "sqlua: attach buffer")
	map("<leader>Dx", function()
		M.clear_cache()
	end, "sqlua: clear cache")

	local ok, which_key = pcall(require, "which-key")
	if ok and type(which_key.add) == "function" then
		pcall(which_key.add, {
			{ "<leader>D", group = "sqlua" },
		})
	end
end

function M.setup(opts)
	require("sqlua.config").setup(opts)
	M.setup_mappings()
	return M
end

function M.open()
	return require("sqlua.drawer").open()
end

function M.toggle()
	return require("sqlua.drawer").toggle()
end

function M.close()
	return require("sqlua.drawer").close()
end

function M.add_connection(opts, callback)
	return require("sqlua.ui").add_connection(opts, callback)
end

function M.attach(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ui = require("sqlua.ui")
	local query = require("sqlua.query")
	local util = require("sqlua.util")
	local connections = ui.connections()

	if #connections == 0 then
		util.warn("no connections configured")
		return
	end
	if #connections == 1 then
		local entry = connections[1]
		ui.set_active(entry.key)
		local attached, err = query.attach(entry, bufnr)
		if not attached then
			util.error(err)
			return
		end
		util.notify("attached buffer to " .. entry.name)
		return
	end

	local picked, pick_err = ui.pick("Attach buffer to connection", function(entry)
		ui.set_active(entry.key)
		local attached, err = query.attach(entry, bufnr)
		if not attached then
			util.error(err)
			return
		end
		util.notify("attached buffer to " .. entry.name)
	end)
	if not picked then
		util.warn(pick_err)
	end
end

function M.connections()
	return require("sqlua.ui").connections()
end

function M.get_connection(key)
	return require("sqlua.ui").get(key)
end

function M.run(sql, opts, callback)
	return require("sqlua.execute").run(sql, opts, callback)
end

function M.statusline(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sqlua
	if type(meta) ~= "table" then
		return ""
	end

	local data = {
		db_name = meta.conn_name or meta.conn_key or "",
		schema = meta.schema or "",
		table = meta.table or "",
	}
	local prefix = opts.prefix or "DB: "
	local separator = opts.separator or " > "
	local show = opts.show or { "db_name", "schema", "table" }

	local parts = {}
	for _, key in ipairs(show) do
		local value = data[key]
		if value and value ~= "" then
			parts[#parts + 1] = value
		end
	end
	if #parts == 0 then
		return ""
	end
	return prefix .. table.concat(parts, separator)
end

function M.clear_cache()
	require("sqlua.ui").clear_meta()
	local drawer = require("sqlua.drawer")
	if drawer.is_open() then
		drawer.render()
	end
end

function M.refresh()
	local ui = require("sqlua.ui")
	ui.clear_meta()
	ui.refresh()
	local drawer = require("sqlua.drawer")
	if drawer.is_open() then
		drawer.render()
	end
end

M.url = require("sqlua.url")
M.db = require("sqlua.db")
M.adapters = require("sqlua.adapters")

return M

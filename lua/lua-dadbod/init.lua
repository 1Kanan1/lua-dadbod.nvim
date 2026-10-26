local M = {}

local global_mappings = {
    { "<leader>Do", "lua-dadbod: open drawer", function() require("lua-dadbod.drawer").open() end },
    { "<leader>Dt", "lua-dadbod: toggle drawer", function() require("lua-dadbod.drawer").toggle() end },
    { "<leader>Dc", "lua-dadbod: close drawer", function() require("lua-dadbod.drawer").close() end },
    { "<leader>Da", "lua-dadbod: add connection", function() M.add_connection() end },
    { "<leader>Df", "lua-dadbod: attach buffer", function() M.attach() end },
    { "<leader>Dx", "lua-dadbod: clear cache", function() M.clear_cache() end },
}

local function remove_global_mappings()
    for _, item in ipairs(global_mappings) do
        pcall(vim.keymap.del, "n", item[1])
    end
end

function M.setup_mappings()
    if not require("lua-dadbod.config").mappings_enabled("global") then
        remove_global_mappings()
        return
    end

    for _, item in ipairs(global_mappings) do
        vim.keymap.set("n", item[1], item[3], { desc = item[2] })
    end

    local ok, which_key = pcall(require, "which-key")
    if ok and type(which_key.add) == "function" then
        pcall(which_key.add, {
            { "<leader>D", group = "lua-dadbod" },
        })
    end
end

function M.setup(opts)
    require("lua-dadbod.config").setup(opts)
    M.setup_mappings()
    return M
end

function M.open()
    return require("lua-dadbod.drawer").open()
end

function M.toggle()
    return require("lua-dadbod.drawer").toggle()
end

function M.close()
    return require("lua-dadbod.drawer").close()
end

function M.add_connection(opts, callback)
    return require("lua-dadbod.ui").add_connection(opts, function()
        require("lua-dadbod.util").redraw_drawer()
        if callback then
            callback()
        end
    end)
end

function M.attach(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local ui = require("lua-dadbod.ui")
    local query = require("lua-dadbod.query")
    local util = require("lua-dadbod.util")
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
    return require("lua-dadbod.ui").connections()
end

function M.get_connection(key)
    return require("lua-dadbod.ui").get(key)
end

function M.run(sql, opts, callback)
    return require("lua-dadbod.execute").run(sql, opts, callback)
end

function M.statusline(opts)
    opts = opts or {}
    local bufnr = vim.api.nvim_get_current_buf()
    local meta = vim.b[bufnr].lua_dadbod
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
    require("lua-dadbod.ui").clear_meta()
    require("lua-dadbod.util").redraw_drawer()
end

function M.refresh()
    local ui = require("lua-dadbod.ui")
    ui.clear_meta()
    ui.refresh()
    require("lua-dadbod.util").redraw_drawer()
end

M.url = require("lua-dadbod.url")
M.db = require("lua-dadbod.db")
M.adapters = require("lua-dadbod.adapters")

return M

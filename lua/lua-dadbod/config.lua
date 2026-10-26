local M = {}

local defaults = {
    save_location = vim.fn.stdpath("data") .. "/lua-dadbod",
    tmp_location = vim.fn.stdpath("cache") .. "/lua-dadbod/queries",
    win = {
        width = 40,
        position = "left",
    },
    default_query = "select * from {optional_schema}{table} limit 50;",
    execute_on_save = false,
    auto_execute_helpers = true,
    bind_param_pattern = ":%w+",
    table_helpers = {},
    completion = {
        enabled = true,
        omnifunc = false,
        prefetch = true,
        max_items = 200,
    },
    icons = {
        expanded = "",
        collapsed = "",
        db = "󰆼",
        table = "󰓫",
        schema = "󰙅",
        scratchpads = "󰉋",
        scratchpad = "",
        history = "󰋚",
        history_entry = "󰓫",
        active = "●",
    },
    result = {
        max_lines = 10000,
        height = 0.4,
    },
    mappings = {
        enabled = true,
        global = true,
        drawer = true,
        query = true,
        result = true,
    },
    dbs = nil,
}

local current = vim.deepcopy(defaults)

local function validate(opts)
    assert(type(opts) == "table", "lua-dadbod.setup: opts must be a table")

    if opts.save_location ~= nil then
        assert(
            type(opts.save_location) == "string" and opts.save_location ~= "",
            "lua-dadbod.setup: save_location must be a non-empty string"
        )
    end
    if opts.tmp_location ~= nil then
        assert(
            type(opts.tmp_location) == "string" and opts.tmp_location ~= "",
            "lua-dadbod.setup: tmp_location must be a non-empty string"
        )
    end
    if opts.default_query ~= nil then
        assert(type(opts.default_query) == "string", "lua-dadbod.setup: default_query must be a string")
    end
    if opts.execute_on_save ~= nil then
        assert(type(opts.execute_on_save) == "boolean", "lua-dadbod.setup: execute_on_save must be a boolean")
    end
    if opts.auto_execute_helpers ~= nil then
        assert(type(opts.auto_execute_helpers) == "boolean", "lua-dadbod.setup: auto_execute_helpers must be a boolean")
    end
    if opts.bind_param_pattern ~= nil then
        assert(
            type(opts.bind_param_pattern) == "string" and opts.bind_param_pattern ~= "",
            "lua-dadbod.setup: bind_param_pattern must be a non-empty string"
        )
    end
    if opts.table_helpers ~= nil then
        assert(type(opts.table_helpers) == "table", "lua-dadbod.setup: table_helpers must be a table")
    end
    if opts.completion ~= nil then
        assert(type(opts.completion) == "table", "lua-dadbod.setup: completion must be a table")
        for _, key in ipairs({ "enabled", "omnifunc", "prefetch" }) do
            if opts.completion[key] ~= nil then
                assert(
                    type(opts.completion[key]) == "boolean",
                    "lua-dadbod.setup: completion." .. key .. " must be a boolean"
                )
            end
        end
        if opts.completion.max_items ~= nil then
            assert(
                type(opts.completion.max_items) == "number" and opts.completion.max_items > 0,
                "lua-dadbod.setup: completion.max_items must be a positive number"
            )
        end
    end
    if opts.dbs ~= nil then
        assert(type(opts.dbs) == "table", "lua-dadbod.setup: dbs must be a table")
    end

    if opts.win ~= nil then
        assert(type(opts.win) == "table", "lua-dadbod.setup: win must be a table")
        if opts.win.width ~= nil then
            assert(
                type(opts.win.width) == "number" and opts.win.width > 0,
                "lua-dadbod.setup: win.width must be a positive number"
            )
        end
        if opts.win.position ~= nil then
            assert(
                opts.win.position == "left" or opts.win.position == "right",
                "lua-dadbod.setup: win.position must be 'left' or 'right'"
            )
        end
    end

    if opts.result ~= nil then
        assert(type(opts.result) == "table", "lua-dadbod.setup: result must be a table")
        if opts.result.max_lines ~= nil then
            assert(
                type(opts.result.max_lines) == "number" and opts.result.max_lines > 0,
                "lua-dadbod.setup: result.max_lines must be a positive number"
            )
        end
        if opts.result.height ~= nil then
            assert(
                type(opts.result.height) == "number" and opts.result.height > 0 and opts.result.height <= 1,
                "lua-dadbod.setup: result.height must be a fraction between 0 and 1"
            )
        end
    end

    if opts.mappings ~= nil then
        assert(
            opts.mappings == false or type(opts.mappings) == "table",
            "lua-dadbod.setup: mappings must be a table or false"
        )
        if type(opts.mappings) == "table" then
            if opts.mappings.enabled ~= nil then
                assert(type(opts.mappings.enabled) == "boolean", "lua-dadbod.setup: mappings.enabled must be a boolean")
            end
            for _, key in ipairs({ "global", "drawer", "query", "result" }) do
                if opts.mappings[key] ~= nil then
                    assert(
                        type(opts.mappings[key]) == "boolean",
                        "lua-dadbod.setup: mappings." .. key .. " must be a boolean"
                    )
                end
            end
        end
    end
end

function M.setup(opts)
    opts = opts or {}
    validate(opts)
    current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
    return current
end

function M.get()
    return current
end

function M.mappings_enabled(section)
    local mappings = current.mappings
    if mappings == false then
        return false
    end
    if not mappings then
        return true
    end
    if mappings.enabled == false then
        return false
    end
    return mappings[section] ~= false
end

function M.defaults()
    return vim.deepcopy(defaults)
end

function M.reset()
    current = vim.deepcopy(defaults)
    return current
end

return M

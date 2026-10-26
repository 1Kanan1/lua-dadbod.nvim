local completion = require("lua-dadbod.completion")

local source = {}

function source.new(opts)
    local self = setmetatable({}, { __index = source })
    self.opts = opts or {}
    return self
end

function source:enabled()
    return completion.enabled()
end

function source:get_trigger_characters()
    return { "." }
end

-- Always answers from the cache, never waits for a process. Missing metadata is
-- requested in the background; the next keystroke picks it up.
function source:get_completions(ctx, callback)
    local cursor = ctx.cursor or { 1, 0 }
    local items = completion.items(ctx.bufnr, cursor[1], cursor[2])
    callback({
        items = items,
        is_incomplete_forward = true,
        is_incomplete_backward = true,
    })
    return function() end
end

return source

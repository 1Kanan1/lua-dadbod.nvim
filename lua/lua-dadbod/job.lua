local M = {}

local function merge_env(env)
    if not env or next(env) == nil then
        return nil
    end
    local result = vim.fn.environ()
    for key, value in pairs(env) do
        result[key] = tostring(value)
    end
    return result
end

function M.run(argv, opts, callback)
    opts = opts or {}
    if type(argv) ~= "table" or #argv == 0 then
        error("lua-dadbod.job: argv must be a non-empty table")
    end
    if type(callback) ~= "function" then
        error("lua-dadbod.job: callback must be a function")
    end

    local start = vim.uv.hrtime()
    local handle = {
        argv = argv,
        done = false,
        timed_out = false,
    }

    local function finish(obj)
        if handle.done then
            return
        end
        handle.done = true

        if handle.timer then
            handle.timer:stop()
            if not handle.timer:is_closing() then
                handle.timer:close()
            end
            handle.timer = nil
        end

        local result = {
            code = obj and obj.code or 1,
            signal = obj and obj.signal or 0,
            stdout = (obj and obj.stdout) or "",
            stderr = (obj and obj.stderr) or "",
            elapsed = (vim.uv.hrtime() - start) / 1e9,
            timed_out = handle.timed_out,
        }

        vim.schedule(function()
            callback(result)
        end)
    end

    local ok, obj = pcall(vim.system, argv, {
        text = true,
        stdin = opts.stdin,
        cwd = opts.cwd,
        env = merge_env(opts.env),
    }, finish)

    if not ok then
        handle.done = true
        vim.schedule(function()
            callback({
                code = 127,
                signal = 0,
                stdout = "",
                stderr = tostring(obj),
                elapsed = (vim.uv.hrtime() - start) / 1e9,
                timed_out = false,
            })
        end)
        return handle
    end

    handle.obj = obj

    if opts.timeout and opts.timeout > 0 then
        handle.timer = vim.uv.new_timer()
        handle.timer:start(opts.timeout, 0, vim.schedule_wrap(function()
            if handle.done then
                return
            end
            handle.timed_out = true
            pcall(function()
                obj:kill(15)
            end)
        end))
    end

    return handle
end

function M.cancel(handle)
    if not handle or handle.done or not handle.obj then
        return false
    end
    local ok = pcall(function()
        handle.obj:kill(15)
    end)
    return ok
end

function M.wait(handle, timeout)
    if not handle or not handle.obj then
        return nil
    end
    return handle.obj:wait(timeout)
end

return M

local h = require("tests.harness")
local job = require("lua-dadbod.job")

local function wait_for(predicate)
    return vim.wait(5000, predicate, 10)
end

h.test("job captures stdout", function()
    local done = false
    local result
    job.run({ "sh", "-c", "printf hello" }, {}, function(value)
        result = value
        done = true
    end)
    h.ok(wait_for(function()
        return done
    end), "job timed out")
    h.eq(result.code, 0)
    h.eq(result.stdout, "hello")
    h.eq(result.stderr, "")
    h.eq(result.timed_out, false)
end)

h.test("job sends stdin", function()
    local done = false
    local result
    job.run({ "sh", "-c", "cat" }, { stdin = "hello" }, function(value)
        result = value
        done = true
    end)
    h.ok(wait_for(function()
        return done
    end), "job timed out")
    h.eq(result.code, 0)
    h.eq(result.stdout, "hello")
end)

h.test("job timeout kills the process", function()
    local done = false
    local result
    job.run({ "sh", "-c", "sleep 2" }, { timeout = 50 }, function(value)
        result = value
        done = true
    end)
    h.ok(wait_for(function()
        return done
    end), "job timed out")
    h.eq(result.timed_out, true)
end)

local h = require("tests.harness")
local result = require("lua-dadbod.result")

local function finish(bufnr, stdout)
    result.update(bufnr, {
        code = 0,
        signal = 0,
        stdout = stdout,
        stderr = "",
        elapsed = 0.01,
        timed_out = false,
    })
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

h.test("render a result set as a table", function()
    local bufnr = h.ok(result.open({ name = "test", format = "csv", returns_rows = true }))
    local lines = finish(bufnr, "id,name\n1,ada\n")
    h.matches(lines[1], "%d+ rows")
    h.matches(lines[2], "id")
    h.matches(lines[2], "name")
    h.matches(lines[3], "ada")
    result.close(bufnr)
    pcall(vim.cmd, "silent! only")
end)

h.test("render command tags as plain output", function()
    local bufnr = h.ok(result.open({ name = "test", format = "csv", returns_rows = false }))
    local lines = finish(bufnr, "CREATE TABLE\nDROP TABLE\n")
    h.eq(lines[1]:find("rows"), nil)
    h.eq(lines[2], "CREATE TABLE")
    h.eq(lines[3], "DROP TABLE")
    result.close(bufnr)
    pcall(vim.cmd, "silent! only")
end)

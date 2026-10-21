local M = {
	tests = {},
	passed = 0,
	failed = 0,
	failures = {},
}

function M.test(name, fn)
	table.insert(M.tests, { name = name, fn = fn })
end

local function fail(message)
	error(message, 3)
end

function M.ok(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
	return value
end

function M.eq(actual, expected, message)
	if not vim.deep_equal(actual, expected) then
		fail((message or "values differ")
			.. "\n  expected: "
			.. vim.inspect(expected)
			.. "\n  actual:   "
			.. vim.inspect(actual))
	end
	return actual
end

function M.is_nil(value, message)
	if value ~= nil then
		fail((message or "expected nil") .. "\n  actual: " .. vim.inspect(value))
	end
end

function M.matches(value, pattern, message)
	if type(value) ~= "string" or not value:match(pattern) then
		fail((message or "string did not match")
			.. "\n  pattern: "
			.. pattern
			.. "\n  value:   "
			.. vim.inspect(value))
	end
	return value
end

function M.run()
	for _, test in ipairs(M.tests) do
		local ok, err = pcall(test.fn)
		if ok then
			M.passed = M.passed + 1
			io.write("ok   " .. test.name .. "\n")
		else
			M.failed = M.failed + 1
			table.insert(M.failures, { name = test.name, err = err })
			io.write("FAIL " .. test.name .. "\n     " .. tostring(err):gsub("\n", "\n     ") .. "\n")
		end
	end

	io.write(string.format("\n%d passed, %d failed\n", M.passed, M.failed))
	io.flush()

	if M.failed > 0 then
		vim.cmd("cquit 1")
	end
end

return M

local h = require("tests.harness")
local result_table = require("lua-dadbod.result_table")

h.test("parse CSV with quoting and newlines", function()
	local rows = result_table.parse('a,b,c\n"x,y","line1\nline2","he said ""hi"""\n', "csv")
	h.eq(rows[1], { "a", "b", "c" })
	h.eq(rows[2][1], "x,y")
	h.eq(rows[2][2], "line1\nline2")
	h.eq(rows[2][3], 'he said "hi"')
end)

h.test("parse MySQL TSV escapes", function()
	local rows = result_table.parse("a\tb\n1\tx\\ty\nNULL\t\n", "tsv")
	h.eq(rows[1], { "a", "b" })
	h.eq(rows[2], { "1", "x\ty" })
	h.eq(rows[3], { "NULL", "" })
end)

h.test("reject multiple result sets and malformed rows", function()
	h.is_nil(result_table.table("a\n1\na\n2\n", "csv"))
	h.is_nil(result_table.table("a,b\n1\n", "csv"))
end)

h.test("render aligned table and NULL", function()
	local lines = result_table.render({ "id", "name" }, {
		{ "1", "Alice" },
		{ "22", "Bob" },
		{ "NULL", "Carol" },
	})
	h.matches(lines[1], "id")
	h.matches(lines[2], "Alice")
	h.matches(lines[3], "Bob")
	h.matches(lines[4], "NULL")
end)

h.test("trim long cells with an ellipsis", function()
	local lines = result_table.render({ "value" }, { { string.rep("x", 80) } })
	h.eq(vim.fn.strchars(lines[2]), 60)
	h.matches(lines[2], "…$")
end)

h.test("trim trailing padding", function()
	local lines = result_table.render({ "id", "ordered_at" }, {
		{ "1", "2026-10-20 18:22:24.091027+04" },
	})
	h.eq(lines[1]:find(" +$") ~= nil, false)
	h.eq(lines[2]:find(" +$") ~= nil, false)
end)

h.test("render a header-only result", function()
	local lines = result_table.render({ "id" }, {})
	h.eq(lines[1], "id")
	h.eq(lines[2], "(no rows)")
end)

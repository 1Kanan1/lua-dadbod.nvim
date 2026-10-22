local h = require("tests.harness")
local history = require("sqlua.history")

h.test("history deduplicates and caps entries", function()
	history.clear()

	for index = 1, 60 do
		history.add({
			conn = "sqlite::memory:",
			dbms = "sqlite",
			name = "test",
			sql = "select " .. index,
			code = 0,
			elapsed = 0.01,
		})
	end

	h.eq(#history.list(), 50)
	h.eq(history.list()[1].sql, "select 60")

	history.add({
		conn = "sqlite::memory:",
		dbms = "sqlite",
		name = "test",
		sql = "select 60",
		code = 1,
		elapsed = 0.02,
	})
	h.eq(#history.list(), 50)
	h.eq(history.list()[1].status, "error")
	h.eq(history.list()[1].sql, "select 60")

	history.clear()
end)

h.test("history preview shows the full query", function()
	history.clear()
	local entry = {
		conn = "sqlite::memory:",
		dbms = "sqlite",
		name = "test",
		sql = "select 1 as x;\nselect 2 as y;",
		code = 0,
		elapsed = 0.01,
		time = os.time(),
	}
	history.add(entry)

	history.preview_entry(history.list()[1])
	h.ok(history.preview.win and vim.api.nvim_win_is_valid(history.preview.win))
	h.eq(vim.wo[history.preview.win].number, true)
	h.eq(vim.wo[history.preview.win].relativenumber, false)
	local text = table.concat(vim.api.nvim_buf_get_lines(history.preview.buf, 0, -1, false), "\n")
	h.matches(text, "test")
	h.matches(text, "select 1 as x")
	h.matches(text, "select 2 as y")

	history.close_preview()
	h.is_nil(history.preview.win)
	history.clear()
end)

h.test("history reruns without a scratchpad", function()
	history.clear()
	local entry = {
		conn = "sqlite::memory:",
		dbms = "sqlite",
		name = "test",
		sql = "select 9 as nine;",
		code = 0,
		elapsed = 0.01,
		time = os.time(),
	}
	history.add(entry)

	history.preview_entry(history.list()[1])
	local result_buf, err = history.rerun(history.list()[1])
	h.ok(result_buf, err)
	h.ok(vim.wait(5000, function()
		local meta = vim.b[result_buf].sqlua_result
		return meta and meta.status ~= "running"
	end), "history rerun did not finish")
	h.eq(history.preview.win, nil)

	vim.api.nvim_buf_delete(result_buf, { force = true })
	pcall(vim.cmd, "silent! only")

	local matches = 0
	for _, item in ipairs(history.list()) do
		if item.sql == "select 9 as nine;" then
			matches = matches + 1
		end
	end
	h.eq(matches, 1)
	history.clear()
end)

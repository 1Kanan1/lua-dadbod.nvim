local h = require("tests.harness")
local form = require("lua-dadbod.form")

h.test("build connection URLs", function()
    h.eq(form.build_url({
        adapter = "postgresql",
        host = "localhost",
        port = "5432",
        user = "postgres",
        password = "p@ss",
        database = "my db",
    }), "postgresql://postgres:p%40ss@localhost:5432/my%20db")

    h.eq(form.build_url({
        adapter = "mysql",
        host = "127.0.0.1",
        port = "3306",
        user = "root",
        password = "",
        database = "app",
    }), "mysql://root@127.0.0.1:3306/app")

    h.eq(form.build_url({ adapter = "sqlite", file = "/tmp/test.db" }), "sqlite:/tmp/test.db")
    h.eq(form.build_url({ adapter = "sqlite", file = ":memory:" }), "sqlite::memory:")
    h.eq(form.build_url({ adapter = "postgresql", raw_url = "postgres://x/y" }), "postgres://x/y")

    local raw, err = form.build_url({ adapter = "sqlite", file = "" })
    h.is_nil(raw)
    h.matches(err, "file")

    raw, err = form.build_url({ adapter = "postgresql", host = "localhost", user = "", password = "p", database = "app" })
    h.is_nil(raw)
    h.matches(err, "user")
end)

h.test("derive a default connection name", function()
    h.eq(form.default_name({ adapter = "sqlite", file = "/tmp/app.db" }), "app")
    h.eq(form.default_name({ adapter = "sqlite", file = ":memory:" }), "memory")
    h.eq(form.default_name({ adapter = "postgresql", database = "shop", host = "localhost" }), "shop")
    h.eq(form.default_name({ adapter = "postgresql", database = "", host = "localhost" }), "localhost")
end)

h.test("the form renders and saves a built URL", function()
    local saved
    local win = form.open({ adapter = "sqlite", file = "/tmp/lua-dadbod-form.db", name = "formdb" }, function(raw, name)
        saved = { raw = raw, name = name }
        return true
    end)
    h.ok(win, "form did not open")
    h.eq(vim.api.nvim_win_get_config(win).relative, "editor")

    local text = table.concat(vim.api.nvim_buf_get_lines(form.buf, 0, -1, false), "\n")
    h.matches(text, "Type")
    h.matches(text, "File")
    h.matches(text, "SQLite")

    form.save()
    h.ok(saved, "form did not call on_save")
    h.eq(saved.name, "formdb")
    h.eq(saved.raw, "sqlite:/tmp/lua-dadbod-form.db")
    h.is_nil(form.win)
end)

h.test("the form stays open when saving fails", function()
    form.open({ adapter = "sqlite", file = "/tmp/kept.db", name = "kept" }, function()
        return false
    end)
    h.ok(form.win)
    form.save()
    h.ok(form.win, "form closed after a failed save")
    form.close()
end)

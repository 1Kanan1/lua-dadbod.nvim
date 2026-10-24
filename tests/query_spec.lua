local h = require("tests.harness")
local query = require("lua-dadbod.query")

h.test("find bind parameters", function()
    h.eq(query.find_params("select * from t where id = :id and name = ':ignored'"), { ":id" })
end)

h.test("skip casts and words in bind parameters", function()
    h.eq(query.find_params("select 'x'::text, foo:bar where id = :id"), { ":id" })
end)

h.test("substitute bind values", function()
    local text = query.substitute("select :id, :name, :id2", {
        [":id"] = "1",
        [":name"] = "O'Reilly",
        [":id2"] = "2",
    })
    h.eq(text, "select 1, 'O''Reilly', 2")
end)

h.test("quote bind values", function()
    h.eq(query.quote_value("42"), "42")
    h.eq(query.quote_value("-1.5"), "-1.5")
    h.eq(query.quote_value("true"), "true")
    h.eq(query.quote_value("'already'"), "'already'")
    h.eq(query.quote_value("text"), "'text'")
end)

h.test("helper SQL uses identifiers and literals", function()
    local columns = h.ok(query.helper_sql("sqlite::memory:", { table = "users", helper = "Columns" }))
    h.matches(columns, "pragma_table_info%('users'%)")

    local list = h.ok(query.helper_sql("sqlite::memory:", { table = "users", helper = "List" }))
    h.matches(list, 'from "users" limit 50')
end)

h.test("resolve bind values without prompting", function()
    local done = false
    local text
    query.resolve_binds("select :id", { [":id"] = "1" }, function(resolved)
        text = resolved
        done = true
    end)
    h.ok(done, "callback did not run")
    h.eq(text, "select 1")
end)

h.test("opening a query drops an empty placeholder", function()
    local placeholder = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(placeholder)
    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    h.eq(vim.api.nvim_buf_is_valid(placeholder), false, "placeholder buffer was not dropped")
    h.eq(vim.api.nvim_get_current_buf(), bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
end)

h.test("save a query to disk", function()
    local config = require("lua-dadbod.config")
    local previous = config.get().save_location
    local save_location = vim.fn.tempname() .. "/lua-dadbod"
    config.setup({ save_location = save_location })

    local bufnr = h.ok(query.open("sqlite::memory:", { auto_execute = false }))
    local meta = vim.b[bufnr].lua_dadbod
    h.eq(meta.conn, "sqlite::memory:")
    h.eq(meta.conn_name, "memory")
    h.eq(meta.conn_key, "memory")
    h.eq(meta.dbms, "sqlite")
    local path, err = query.save_as(bufnr, "my query")
    path = h.ok(path, err)
    h.eq(vim.fn.filereadable(path), 1)
    h.matches(path, "my query%.sql$")

    local renamed, rename_err = query.rename_file(path, "renamed query")
    renamed = h.ok(renamed, rename_err)
    h.eq(vim.fn.filereadable(path), 0)
    h.eq(vim.fn.filereadable(renamed), 1)
    h.eq(vim.api.nvim_buf_get_name(bufnr), renamed)

    vim.fn.delete(save_location, "rf")
    config.setup({ save_location = previous })
end)

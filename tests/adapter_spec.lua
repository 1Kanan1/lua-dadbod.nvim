local h = require("tests.harness")
local adapters = require("sqlua.adapters")
local db = require("sqlua.db")

h.test("sqlite3 is an alias for sqlite", function()
	local adapter = h.ok(adapters.get("sqlite3"))
	h.eq(adapter.name, "sqlite")
	h.eq(adapters.aliases().sqlite3, "sqlite")
end)

h.test("postgres and mariadb aliases", function()
	h.eq(h.ok(adapters.get("postgres")).name, "postgresql")
	h.eq(h.ok(adapters.get("mariadb")).name, "mysql")
	h.eq(h.ok(db.resolve("postgres://host/db")), "postgresql://host/db")
	h.eq(h.ok(db.resolve("mariadb://host/db")), "mysql://host/db")
end)

h.test("unknown adapters are rejected", function()
	local adapter, err = adapters.get("oracle")
	h.is_nil(adapter)
	h.matches(err, "no adapter")

	local resolved, resolve_err = db.resolve("oracle://host/db")
	h.is_nil(resolved)
	h.matches(resolve_err, "no adapter")
end)

h.test("sqlite canonicalizes to an absolute path", function()
	local resolved = h.ok(db.resolve("sqlite:relative.db"))
	h.matches(resolved, "^sqlite:/")
	h.matches(resolved, "relative%.db$")
end)

h.test("sqlite defaults to memory", function()
	h.eq(h.ok(db.resolve("sqlite:")), "sqlite::memory:")
	h.eq(h.ok(db.resolve("sqlite::memory:")), "sqlite::memory:")
end)

h.test("sqlite metadata argv", function()
	local argv = h.ok(db.argv("sqlite::memory:", { meta = true }))
	h.eq(argv[1], "sqlite3")
	h.eq(vim.tbl_contains(argv, "-noheader"), true)
	h.eq(vim.tbl_contains(argv, "-header"), false)
	h.eq(vim.tbl_contains(argv, "-separator"), true)
	h.eq(argv[#argv], ":memory:")
end)

h.test("sqlite result argv", function()
	local argv = h.ok(db.argv("sqlite::memory:"))
	h.eq(argv[1], "sqlite3")
	h.eq(vim.tbl_contains(argv, "-header"), true)
	h.eq(vim.tbl_contains(argv, "-column"), true)
	h.eq(vim.tbl_contains(argv, "-noheader"), false)
	h.eq(argv[#argv], ":memory:")
end)

h.test("sqlite interactive argv", function()
	local parsed, adapter = db.parse("sqlite::memory:")
	parsed = h.ok(parsed)
	adapter = h.ok(adapter)
	local argv = adapter.interactive(parsed)
	h.eq(argv, { "sqlite3", ":memory:" })
end)

h.test("sqlite helpers", function()
	local adapter = h.ok(adapters.get("sqlite"))
	h.matches(adapter.helpers.Columns, "pragma_table_info")
end)

h.test("sqlite warns before creating a missing database", function()
	local adapter = h.ok(adapters.get("sqlite"))
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")

	local path = directory .. "/new.db"
	h.matches(adapter.missing_warning(h.ok(db.parse("sqlite:" .. path))), "creating an empty database")

	vim.fn.writefile({}, path)
	h.is_nil(adapter.missing_warning(h.ok(db.parse("sqlite:" .. path))))
	h.is_nil(adapter.missing_warning(h.ok(db.parse("sqlite::memory:"))))

	h.matches(adapter.missing_warning(h.ok(db.parse("sqlite:" .. directory))), "is a directory")
	h.matches(
		adapter.missing_warning(h.ok(db.parse("sqlite:" .. directory .. "/missing/new.db"))),
		"directory does not exist"
	)

	vim.fn.delete(directory, "rf")
end)

h.test("sqlite binary lookup", function()
	local binary = h.ok(db.binary("sqlite::memory:"))
	h.eq(binary, "sqlite3")

	local ok, err = db.check_binary("sqlite::memory:")
	h.eq(ok, vim.fn.executable("sqlite3") == 1)
	if ok then
		h.is_nil(err)
	end
end)

h.test("postgresql argv", function()
	local argv = h.ok(db.argv("postgresql://user:secret@host:5432/app"))
	h.eq(argv[1], "psql")
	h.eq(vim.tbl_contains(argv, "-X"), true)
	h.eq(vim.tbl_contains(argv, "-A"), true)
	h.eq(vim.tbl_contains(argv, "-t"), false)
	h.eq(argv[#argv], "postgresql://user:secret@host:5432/app")

	local meta = h.ok(db.argv("postgresql://user:secret@host:5432/app", { meta = true }))
	h.eq(vim.tbl_contains(meta, "-t"), true)
end)

h.test("postgresql metadata and helpers", function()
	local adapter = h.ok(adapters.get("postgresql"))
	h.eq(adapter.default_schema, "public")
	h.matches(adapter.tables_sql({}), "table_schema = 'public'")
	h.matches(adapter.schemas_sql({}), "information_schema%.schemata")
	h.matches(adapter.columns_sql({ table = "users" }), "current_schema%(%)")
	h.matches(adapter.helpers.Columns, "information_schema%.columns")
end)

h.test("mysql argv", function()
	local argv, env = db.argv("mysql://user:secret@host:3306/app")
	h.eq(argv[1], "mysql")
	h.eq(vim.tbl_contains(argv, "--batch"), true)
	h.eq(vim.tbl_contains(argv, "--host=host"), true)
	h.eq(vim.tbl_contains(argv, "--port=3306"), true)
	h.eq(vim.tbl_contains(argv, "--user=user"), true)
	h.eq(vim.tbl_contains(argv, "--database=app"), true)
	h.eq(env.MYSQL_PWD, "secret")

	local meta = h.ok(db.argv("mysql://host/app", { meta = true }))
	h.eq(vim.tbl_contains(meta, "--skip-column-names"), true)
end)

h.test("mysql interactive and helpers", function()
	local parsed, adapter = db.parse("mysql://user:secret@host/app")
	local argv, env = adapter.interactive(h.ok(parsed))
	h.eq(argv, { "mysql", "--host=host", "--user=user", "--database=app" })
	h.eq(env.MYSQL_PWD, "secret")

	h.matches(adapter.tables_sql({ db = "app" }), "table_schema = 'app'")
	h.matches(adapter.tables_sql({}), "database%(%)")
	h.matches(adapter.columns_sql({ table = "users" }), "database%(%)")
	h.matches(adapter.helpers.Columns, "information_schema%.columns")
end)

h.test("list adapters", function()
	h.eq(adapters.list(), { "mysql", "postgresql", "sqlite" })
end)

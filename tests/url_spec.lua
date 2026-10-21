local h = require("tests.harness")
local url = require("sqlua.url")

h.test("parse and format a network URL", function()
	local parsed = h.ok(url.parse("postgresql://user:p%40ss@localhost:5432/my%20db?sslmode=require&flag#frag"))
	h.eq(parsed.scheme, "postgresql")
	h.eq(parsed.user, "user")
	h.eq(parsed.password, "p@ss")
	h.eq(parsed.host, "localhost")
	h.eq(parsed.port, "5432")
	h.eq(parsed.path, "/my db")
	h.eq(parsed.params.sslmode, "require")
	h.eq(parsed.params.flag, true)
	h.eq(parsed.fragment, "frag")
	h.eq(url.format(parsed), "postgresql://user:p%40ss@localhost:5432/my%20db?flag&sslmode=require#frag")
end)

h.test("parse an empty authority", function()
	local parsed = h.ok(url.parse("postgresql:///db"))
	h.eq(parsed.host, "")
	h.eq(parsed.path, "/db")
	h.eq(url.format(parsed), "postgresql:///db")
end)

h.test("parse and format an IPv6 host", function()
	local parsed = h.ok(url.parse("postgresql://[::1]:5432/db"))
	h.eq(parsed.host, "::1")
	h.eq(parsed.port, "5432")
	h.eq(parsed.path, "/db")
	h.eq(url.format(parsed), "postgresql://[::1]:5432/db")
end)

h.test("parse and format an opaque URL", function()
	local parsed = h.ok(url.parse("sqlite:/tmp/a%20b.db"))
	h.eq(parsed.opaque, "/tmp/a b.db")
	h.is_nil(parsed.path)
	h.eq(url.format(parsed), "sqlite:/tmp/a%20b.db")
end)

h.test("parse an in-memory SQLite URL", function()
	local parsed = h.ok(url.parse("sqlite::memory:"))
	h.eq(parsed.opaque, ":memory:")
	h.eq(url.format(parsed), "sqlite::memory:")
end)

h.test("decode query parameters", function()
	local parsed = h.ok(url.parse("postgresql://host/db?a=1&a=2&b=two+words&c=%2F&flag"))
	h.eq(parsed.params.a, "2")
	h.eq(parsed.params.b, "two words")
	h.eq(parsed.params.c, "/")
	h.eq(parsed.params.flag, true)
	h.eq(url.format(parsed), "postgresql://host/db?a=2&b=two+words&c=%2F&flag")
end)

h.test("preserve an empty fragment", function()
	local parsed = h.ok(url.parse("postgresql://host/db#"))
	h.eq(parsed.fragment, "")
	h.eq(url.format(parsed), "postgresql://host/db#")
end)

h.test("hide the password in safe output", function()
	local safe = url.safe_format(url.parse("postgresql://user:secret@host/db"))
	h.eq(safe, "postgresql://user@host/db")
end)

h.test("absorb connection parameters", function()
	local parsed = h.ok(url.parse("postgresql:///db?host=localhost&port=5432&dbname=real&sslmode=require"))
	url.absorb(parsed, {
		host = "host",
		port = "port",
		dbname = "path",
	})
	h.eq(parsed.host, "localhost")
	h.eq(parsed.port, "5432")
	h.eq(parsed.path, "/real")
	h.eq(parsed.params.sslmode, "require")
	h.eq(parsed.params.dbname, nil)
end)

h.test("canonicalize a file path", function()
	local parsed = h.ok(url.parse("sqlite:relative.db"))
	url.canonicalize_file(parsed)
	h.eq(parsed.path, nil)
	h.matches(parsed.opaque, "^/")
	h.matches(parsed.opaque, "relative%.db$")
end)

h.test("read a file path from a URL", function()
	h.eq(url.file_path(url.parse("sqlite:/tmp/a%20b.db")), "/tmp/a b.db")
	h.eq(url.file_path(url.parse("sqlite:")), ":memory:")
end)

h.test("resolve environment variables", function()
	local previous = vim.env.SQLUA_TEST_URL
	vim.env.SQLUA_TEST_URL = "sqlite:/tmp/x.db"
	h.eq(url.resolve("$SQLUA_TEST_URL"), "sqlite:/tmp/x.db")
	h.eq(url.resolve("${SQLUA_TEST_URL}"), "sqlite:/tmp/x.db")
	h.eq(url.resolve("$SQLUA_MISSING_FOR_TEST"), "")
	vim.env.SQLUA_TEST_URL = previous
end)

h.test("reject malformed URLs", function()
	local parsed, err = url.parse("nonsense")
	h.is_nil(parsed)
	h.matches(err, "missing scheme")

	parsed, err = url.parse("postgresql://host:abc/db")
	h.is_nil(parsed)
	h.matches(err, "invalid port")

	parsed, err = url.parse("postgresql://[::1/db")
	h.is_nil(parsed)
	h.matches(err, "invalid IPv6")
end)

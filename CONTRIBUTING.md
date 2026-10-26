# Contributing to lua-dadbod

## Local setup

Clone the repository and point lazy.nvim at the checkout:

```lua
{
  dir = "~/dev/lua-dadbod",
  name = "lua-dadbod",
  opts = {},
}
```

`name` keeps lazy.nvim from deriving the module from the folder name; the module
is `lua-dadbod`. Leave the plugin loading at startup: the saved-query
autocommands must exist before the first SQL buffer is read, so do not add
`event` or `ft` keys.

lazy.nvim only generates help tags for installed plugins. Run this once:

```vim
:helptags ~/dev/lua-dadbod/doc
```

## Tests

The suite runs headless and needs `sqlite3` on `PATH`. No database server is
required.

```sh
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Add a test for new behaviour. `tests/harness.lua` provides `test`, `ok`, `eq`,
`is_nil`, and `matches`; each spec lives next to the module it covers. SQLite is
the adapter used for integration tests, so most features can be tested without
an external server.

## Lint

The code is checked with lua-language-server at Warning level. `.luarc.json`
pins the LuaJIT runtime and keeps `tests/` out of the workspace. Use a LuaLS
setup that knows the `vim` API, for example by adding the Neovim runtime
directory to `workspace.library`.

There is no formatter config. Match the surrounding style: four spaces, double
quotes, trailing commas in multiline tables.

## Style

- LuaJIT and Neovim built-ins only. Do not add a runtime dependency without
  discussing it first.
- Keep modules small and in `lua/lua-dadbod/`. Prefer extending an existing
  module over adding an abstraction layer.
- Buffer state lives in `b:lua_dadbod`; connection and UI state lives in the
  module that owns it. Do not spawn a process on a keystroke path; fetch in the
  background and answer from the cache.
- Any new user-facing option needs a default in `config.lua`, validation in
  `config.validate`, and documentation in README and `doc/lua-dadbod.txt`.

## Documentation

Update `doc/lua-dadbod.txt` for commands, keys, options, events, or completion
changes, and keep the README tables in sync. Check the tags and render before
committing:

```vim
:helptags doc
:help lua-dadbod
```

`doc/tags` is generated and gitignored.

## Scope and adapters

`PLAN.md` records the product scope, deferred features, and the reasoning behind
them. Read it before adding surface area.

Adapters live in `lua/lua-dadbod/adapters/`. An adapter is a table with `name`,
`aliases`, `binary`, `quote`, optional `default_schema`, `filetype`,
`result_format`, and `helpers`, plus functions for `argv`, `interactive`,
`schemas_sql`, `tables_sql`, `columns_sql`, and `missing_warning`. Register it in
`adapters/init.lua`, cover its argv in `tests/adapter_spec.lua`, and document any
adapter-specific behaviour.

## Commits

Use conventional prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`), one
topic per commit, and explain why in the body when the change is not obvious.

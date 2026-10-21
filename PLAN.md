# sqlua: implementation plan

`sqlua` is one Neovim plugin that replaces `vim-dadbod`, `vim-dadbod-ui`, and
`vim-dadbod-completion`. It keeps the loop those plugins exist for:

```
connect -> browse -> write query -> run -> inspect -> save -> complete
```

It talks to database CLIs. It does not link client libraries.

Target: Neovim 0.10+, Lua only, roughly 1,800 to 2,200 lines including tests.
That is about a third of the Vim script being replaced.

## 1. Scope

### Keep

- Adapters: SQLite, PostgreSQL, MySQL, MariaDB. MariaDB uses the MySQL
  adapter with the `mariadb` binary.
- Connections from `SQLUA_URL` / `SQLUA_NAME`, `g:db`, `g:dbs`, and
  `connections.json`.
- A drawer with connections, schemas/tables, saved queries, and new query.
- Query buffers that run on write, run a selection, save, rename, delete, and
  bind parameters.
- Async query execution with cancel, rerun, elapsed time, and stderr.
- Completion of schemas, tables, columns after `table.` or `alias.`, and bind
  parameters.
- A small public API, user events, and a statusline helper.
- Headless tests with a SQLite integration test.

### Defer

These are useful but not needed for the first working version:

- SQL Server until a test server is available.
- DuckDB, MongoDB, Redis, Oracle, BigQuery, ClickHouse, Snowflake,
  Presto/Trino, Impala, osquery, jq.
- Interactive password prompt.
- Result cell parsing, folds, foreign-key jump, layout toggle.
- Query result history in the drawer.

### Non-goals

- Vim 8 support.
- DBeXT compatibility or `dbext:` URLs.
- JDBC URL parsing.
- Schema editing, DDL UI, import/export, explain plans, connection pooling.
- A custom notification system, progress float, or icon theme.

## 2. Recommended decisions

| Area | Decision |
|---|---|
| Runtime | Neovim 0.10+ only, `vim.system()` for processes |
| Command | Keep `:DB` for query and console use |
| UI commands | `:Sqlua`, `:SqluaToggle`, `:SqluaClose`, `:SqluaAddConnection`, `:SqluaFindBuffer`, `:SqluaRenameBuffer`, `:SqluaClearCache` |
| Filetypes | `sqlua` for the drawer, `sqlua_result` for results, normal `sql` for query buffers |
| Config | `require("sqlua").setup(opts)` only, no `g:db_ui_*` |
| Connections | `SQLUA_*`, `g:db`, `g:dbs`, `connections.json` |
| Adapters | SQLite, PostgreSQL, MySQL/MariaDB; one file per adapter, one registry |
| Execution | SQL goes to the CLI on stdin, output goes into a scratch buffer |
| Results | Native CLI output, no parsing in v1 |
| Query files | Real temp files so `:w` works, metadata in `b:sqlua` |
| Completion | Omni plus Blink, cached per connection, scoped columns only |
| Tests | Plain Lua asserts, run through `nvim --headless` |

## 3. Layout

```
plugin/sqlua.lua                    command registration, load guard
ftplugin/sqlua.lua                  drawer mappings
ftplugin/sqlua_result.lua           result mappings
lua/sqlua/init.lua                  public API
lua/sqlua/config.lua                defaults and merge
lua/sqlua/util.lua                  paths, slugs, files, prompts, notify
lua/sqlua/url.lua                   parse, format, resolve, canonicalize
lua/sqlua/sql.lua                   SQL literal and identifier quoting
lua/sqlua/job.lua                   vim.system wrapper, cancel, timeout
lua/sqlua/db.lua                    connection resolution, adapters, metadata
lua/sqlua/execute.lua               :DB, running SQL, events
lua/sqlua/result.lua                result scratch buffers
lua/sqlua/query.lua                 query files, bind params, save/rename
lua/sqlua/ui.lua                    connection discovery, state, JSON
lua/sqlua/drawer.lua                drawer rendering and actions
lua/sqlua/completion.lua            cache, prefix logic, omni
lua/sqlua/completion_blink.lua      Blink source
lua/sqlua/adapters/init.lua         registry and aliases
lua/sqlua/adapters/sqlite.lua
lua/sqlua/adapters/postgresql.lua
lua/sqlua/adapters/mysql.lua
tests/run.lua
tests/url_spec.lua
tests/adapter_spec.lua
tests/job_spec.lua
tests/query_spec.lua
tests/config_spec.lua
tests/completion_spec.lua
tests/sqlite_spec.lua
doc/sqlua.txt
README.md
```

Rough size:

| Area | Lines |
|---|---|
| config, util, url, sql, job | 450 |
| adapters | 200 to 250 |
| db, execute, result | 500 |
| ui, drawer | 500 |
| query, completion | 400 |
| commands, ftplugins, tests | 500 |

## 4. Core design

### URL model

One parser for the shapes we actually use:

```
scheme://[user[:password]@][host][:port][/path][?params][#fragment]
scheme:opaque
```

- Percent decoding and encoding, IPv4, IPv6, empty paths, fragments.
- Query parameters split on `&` and `;`. Repeated keys keep the last value.
- `$VAR` is resolved only when the whole URL is `$VAR`.
- `~` and relative paths are resolved for file adapters.
- Adapter aliases are resolved until stable (`postgres` -> `postgresql`,
  `sqlite3` -> `sqlite`, `mariadb` handled by the MySQL adapter).
- A small `url.absorb(parsed, mapping)` helper moves params such as `user`,
  `password`, `host`, `port`, and `dbname` into fields when an adapter asks.
- No JDBC, no DBeXT, no `\f` multi-value encoding, no shell string building.

### Connections

Sources, in order:

1. `SQLUA_URL` / `SQLUA_NAME`.
2. `g:db`.
3. `g:dbs` as a map or ordered list. String or function values, called with
   `pcall`.
4. `connections.json` under `save_location`.

Each entry has `name`, `url`, `source`, and `key = name .. "_" .. source`.
Duplicate names from different sources are allowed. Duplicates from the same
source keep the first and produce one warning.

`connections.json` is an array of `{ name, url }`. Invalid JSON produces one
warning and is ignored.

For a buffer, connection resolution is:

1. `b:sqlua.conn_key`, then `b:sqlua.url`.
2. `b:db`.
3. `g:db`.
4. `$DATABASE_URL`.
5. The only configured connection, if exactly one exists.

`DATABASE_URL` is a fallback, not a drawer entry.

### Adapter contract

Each adapter is a table:

```lua
---@class SqluaAdapter
---@field name string
---@field aliases? table<string, true>
---@field binary string
---@field quote? { string, string }       -- nil means no identifier quoting
---@field default_schema? string
---@field supports_schemas? fun(url): boolean
---@field filetype? string                -- defaults to "sql"
---@field argv fun(url, opts): string[], table|nil
---@field interactive? fun(url): string[]
---@field helpers? table<string, string>
---@field schemas_sql? fun(ctx): string
---@field tables_sql? fun(ctx): string
---@field columns_sql? fun(ctx): string
```

- `argv(url, opts)` returns the command and an optional environment table.
  `opts.meta = true` means machine-readable output with no header.
- `interactive(url)` returns the command for a terminal console.
- `ctx` carries `{ schema, table, db }` and helpers for quoting.
- `helpers` holds the table helpers. `List` is the default query and is what
  `Enter` runs. `Columns` is built in for all core adapters. Indexes, foreign
  keys, primary keys, constraints, and describe are docs snippets, not core
  helpers.
- Helper placeholders: `{table}`, `{schema}`, `{optional_schema}`, and
  `{dbname}` expand to quoted identifiers. `{table_lit}`, `{schema_lit}`, and
  `{dbname_lit}` expand to escaped SQL string literals.
- Adapters may omit metadata. The UI then shows tables only or no tree, and
  completion degrades to whatever is available.
- Registration is `require("sqlua.adapters").register(def)`, so a user adapter
  is one file and one call.

Metadata is fetched with the same CLI, `opts.meta = true`, and split on tabs
and newlines. No pretty-table parsing.

Example queries:

- PostgreSQL schemas: `information_schema.schemata`, excluding `pg_*`.
- PostgreSQL tables: `information_schema.tables` for one schema.
- PostgreSQL columns: `information_schema.columns` ordered by position.
- MySQL: `show databases` when no database is in the URL, otherwise
  `information_schema.tables`.
- SQLite: `sqlite_schema`, `pragma_table_info`.

### Jobs

`job.run(argv, opts, cb)` is the only process path.

```lua
job.run(argv, {
  stdin = sql,
  env = env,
  timeout = 0,
  cwd = nil,
}, function(result)
  -- result = { code, signal, stdout, stderr, elapsed }
end)
```

- `vim.system()` with `text = true`, callback wrapped in `vim.schedule`.
- `job.cancel(handle)` sends SIGTERM.
- No `jobwait` loops except one synchronous metadata helper for completion.
- Missing binary is reported before spawning.
- stderr is captured separately and shown with the result.

### Metadata cache

One table keyed by resolved connection URL:

```
{
  schemas = { list = {}, loaded = false },
  tables = { [schema] = { list = {}, loaded = false } },
  columns = { [schema .. "." .. table] = { list = {}, loaded = false } },
}
```

- The drawer warms this cache asynchronously when a connection expands.
- Completion uses the cache. If a value is missing, it fetches once with a
  short timeout (default 3s), then caches it.
- Opening a query from the drawer means the cache is already warm, so the
  first completion does not block.
- `:SqluaClearCache` and drawer refresh clear it.
- Keys include the schema, fixing the column collision in the old completion
  plugin.

## 5. Behavior

### Commands

```
:DB [url] [query]        run query text; no query opens an interactive console
:%DB [url]               run the whole buffer
:'<,'>DB [url]           run the selected range
:DB [url] < file.sql     run a file
:DB! ...                 allow a second job in the same buffer
```

- No `:DB g:x = url`, no `:DB url :command`, no operator mapping.
- Command completion covers schemes, connection names, and files after `<`.
- `:Sqlua` opens the drawer, `:SqluaToggle` toggles, `:SqluaClose` closes.
- `:SqluaAddConnection` prompts for URL and name, validates the URL, appends to
  `connections.json`, and refreshes the drawer.
- `:SqluaFindBuffer` attaches the current buffer to a connection.
- `:SqluaRenameBuffer` renames a saved query.
- `:SqluaClearCache` clears metadata and completion caches.
- All commands catch errors and report them through `vim.notify`.

### Drawer

One text buffer, one row list, rendered from scratch on each change.

```
▾ local
    New query
    Saved queries (3)
    Tables (12)
      users
      orders
```

With schema support:

```
▾ production
    New query
    Saved queries (0)
    Schemas (2)
      public (12)
        users
        orders
      audit (3)
```

- `<CR>` / `o`: open or toggle.
- `S`: open in a vertical split.
- `C`: run the `Columns` query on a table row. If user helpers are configured,
  open `vim.ui.select` with `Columns` plus those helpers first.
- `A`: add connection.
- `r`: rename a saved query, or a connection from `connections.json`.
- `d`: delete a saved query, or a connection from `connections.json`.
- `R`: refresh the selected connection; at the root, refresh all.
- `H`: show scheme, source, and database in the connection label.
- `q`: close.
- `?`: print a short key reminder through `vim.notify`.

- Connection rows show a loading marker while metadata is fetching.
- `Enter` on a table opens a query buffer with the `List` SQL and runs it
  immediately. `C` does the same with the `Columns` SQL. If user helpers are
  configured, `C` opens `vim.ui.select` first and runs the chosen helper after
  selection.
- Both auto-run paths are controlled by `auto_execute_helpers = true`. Set it
  to `false` to only open the SQL and wait for `:w` or `<Leader>S`.
- No helper submenu, no buffers section, and no `:SqluaBuffers` picker. Scratch
  queries are normal listed buffers and appear in the user's bufferline.
- No sibling navigation, help pane, result list, or progress animation.

### Query buffers

- Created as real files under `tmp_location`, so `:w` works and
  `BufWritePost` can run the query.
- Name: `<slug(conn)>-<table>-<helper>-<timestamp>.sql`.
- `b:sqlua = { conn_key, url, source, schema, table, helper, bind, result_buf }`.
- The buffer keeps `filetype=sql`, so Treesitter and LSP keep working.
- `BufWritePost` runs the whole buffer when `execute_on_save = true`.
- `<Leader>S` runs the whole buffer; in visual mode it runs the selection.
- `<Leader>W` saves a copy under
  `<save_location>/queries/<slug(conn)>/<name>.sql` using `:noautocmd saveas`,
  then marks the buffer as saved.
- `<Leader>E` edits bind parameters through `vim.ui.select`: choose a
  parameter, enter a new value, or clear all.
- Bind parameters are detected with `bind_param_pattern` (default `:%w+`),
  ignoring matches inside single quotes, prompted once, cached in
  `b:sqlua.bind`, and substituted with quoting for numeric, boolean, already
  quoted, and string values.
- Opening a file under `queries/<slug>/` sets the connection from the folder
  and marks it saved. No filename guessing beyond that.
- Saved queries can be renamed or deleted from the drawer. Open buffers follow
  the rename or are wiped on delete.

### Results

- Scratch buffer named `sqlua://result/<n>`, `buftype=nofile`,
  `bufhidden=wipe`, `filetype=sqlua_result`.
- Header: connection name, elapsed time, exit code, and the first line of the
  query.
- Then stdout, then stderr if non-empty.
- Opened in a split without stealing focus. Reused for the same query buffer
  when possible.
- `R` reruns the stored SQL, `<C-c>` cancels, `q` closes.
- Leaving the buffer cancels a running job.
- Output is capped at `result.max_lines` (default 10000) with a notice.
- No folds, cell yank, header yank, foreign-key jump, or layout toggle.
  Normal Vim search and yank still work on the output.
- Events:
  - `User SqluaQueryPre`
  - `User SqluaQueryPost`
  - payload: `{ conn, sql, code, elapsed }`

### Completion

- Cache per resolved connection, not per buffer.
- Context from `b:sqlua`, then `b:db`, then `g:db`, then `$DATABASE_URL`.
- Prefix cases:
  - `schema.` -> tables in that schema.
  - `table.` or `alias.` -> columns of that table.
  - unqualified -> tables and schemas.
  - `:name` -> cached bind parameters.
- Alias parsing keeps `from table t`, `join table as t`, and quoted
  identifiers. It is a small line regex, not a SQL parser.
- Unqualified column completion is dropped. That removes the column count
  query, the 10k threshold, and the huge global column fetch.
- No functions, reserved words, or per-client refresh hacks.
- Identifier quoting comes from the adapter; quoting is applied when the name
  contains spaces, non-word characters, mixed case, or a reserved word from a
  short shared list.
- Sources:
  - `omnifunc`, opt-in through `completion.omnifunc = true`.
  - `require("sqlua.completion_blink")`.
- `nvim-cmp` support is dropped. If it is ever needed, it is a small adapter
  around the same completion function.

## 6. Configuration

```lua
require("sqlua").setup({
  save_location = vim.fn.stdpath("data") .. "/sqlua",
  tmp_location = vim.fn.stdpath("cache") .. "/sqlua/queries",
  win = { width = 40, position = "left" },
  default_query = "select * from {optional_schema}{table} limit 200;",
  execute_on_save = true,
  auto_execute_helpers = true,
  bind_param_pattern = ":%w+",
  hide_schemas = {},
  table_helpers = {},
  icons = { expanded = "▾", collapsed = "▸" },
  result = { max_lines = 10000 },
  completion = {
    enabled = true,
    filetypes = { "sql", "mysql", "plsql" },
    mark = "[DB]",
    limit = 200,
    timeout = 3000,
    omnifunc = false,
  },
  mappings = {
    enabled = true,
    drawer = true,
    query = true,
    result = true,
  },
  dbs = nil,
})
```

`table_helpers` merges over adapter defaults. An empty string removes a helper.
`mappings = false` disables all built-in maps.

Public API:

```lua
local sqlua = require("sqlua")

sqlua.setup(opts)
sqlua.open(mods)
sqlua.toggle()
sqlua.close()
sqlua.add_connection(opts?)          -- nil opens prompts
sqlua.attach(bufnr?)                 -- nil means current buffer
sqlua.connections()                  -- copy of the connection list
sqlua.get_connection(key)
sqlua.run(sql, opts, cb)             -- one low-level job
sqlua.statusline(opts)
sqlua.clear_cache()
sqlua.refresh()
```

## 7. What we drop, and why

### From vim-dadbod

| Drop | Why |
|---|---|
| Vim 8 branches and job code | `vim.system()` replaces several hundred lines of `job_start`, `ch_*`, and `jobwait` handling |
| `dbext:` adapter and `g:dbext_*` | DBeXT interop is legacy and drags in profile parsing |
| JDBC parsing | We run CLIs, not Java drivers |
| `g:db_adapter_*` autoload discovery | A Lua registry is smaller and explicit |
| Path and file-type sniffing | Requiring an explicit scheme is clearer and avoids scanning parent directories |
| Temp input and output files | SQL goes to stdin; output goes to a scratch buffer |
| `BufReadPost`/`:pedit`/`:edit!` reload dance | Replaced by updating the result buffer directly |
| Per-tab query lock | A job per buffer is simpler and allows parallel queries |
| `:DB g:x = url` | Connection files and `g:dbs` cover this |
| `:DB url :command` | Rare, and it needs temporary global state |
| Operator mapping (`g@`) | Visual range covers the same use case |
| URL and table command completion | Scheme, connection, and file completion is enough |
| Statusline string substitution | A `statusline()` helper is explicit |
| Non-SQL adapters for v1 | Each one adds CLI quirks and metadata code for little shared value |

### From vim-dadbod-ui

| Drop | Why |
|---|---|
| Custom notification system | `vim.notify` and the user's notification plugin already solve it |
| Progress float and timers | The result buffer can show a running state |
| Nerd font icon set and syntax file | Simple expand/collapse markers are enough |
| Help pane and sibling navigation | Normal `j`/`k` and a one-line help notification |
| Buffers section | Scratch queries are already normal buffers |
| Result list in the drawer | Results are one split away and not a navigation target |
| Folds, layout toggle, foreign-key jump | Expensive adapter-specific result parsing for occasional use |
| Cell and header yank | Same reason; can be added later on top of a normalized result format |
| Indexes, FKs, PKs, Constraints, Describe helpers | Fragile copied SQL; `List` and `Columns` stay, the rest move to docs snippets |
| Dotenv environment scan | Hidden global behavior; `g:dbs` or the connection file is explicit |
| Filename-based database inference | `b:sqlua` and the saved-query folder are reliable |
| Buffer name generator and table sorter callbacks | Configuration surface without a clear need |
| Connection rename | Delete and add is enough |
| Legacy `g:db_ui_*` options and `:DBUI*` commands | Clean break for a new plugin |
| `dbui` and `dbout` filetypes | Renamed to `sqlua` and `sqlua_result` |
| Bind parameter edit menu | Keep edit and clear, drop the multi-step confirm flow |

### From vim-dadbod-completion

| Drop | Why |
|---|---|
| Reserved word completion | 1,500 words on every keystroke is noise; keep only a short list for quoting |
| Function completion | Only one adapter implemented it |
| Global unqualified column completion | Needs a count query and a full column fetch; scoped completion is enough |
| 10k column threshold and `fetch_columns_by_table` | Gone with global columns |
| Per-buffer cache | Connection-keyed cache has no leak and is shared by all query buffers |
| Async refresh hacks (`coc#refresh`, `compe#complete`, `feedkeys`, deoplete flag) | Replaced by a cache that is warm before completion, or one short sync fetch |
| coc, deoplete, nvim-compe, ddc, completion-nvim, denops, Python, JS bridges | One Omni source and one Blink source |
| nvim-cmp source | Dropped; Blink and opt-in Omni cover the current setup |
| `:DBCompletionClearCache` | `:SqluaClearCache` |

## 8. Bugs and rough edges we fix

- Query lock is per tab in dadbod, so unrelated buffers block each other. Fix:
  one job per buffer, `:DB!` to override.
- Result output is a temp file opened with `:pedit` and reloaded on
  `BufReadPost`. Fix: scratch buffer updated in place.
- The first column completion is always empty because metadata is fetched
  asynchronously and the old code relies on client-specific refresh calls.
  Fix: warm the cache when a query buffer is created, short sync fetch
  otherwise.
- Completion cache is keyed by buffer number and never removed. Fix:
  connection-keyed cache.
- Columns are cached by table name only, so same-named tables in different
  schemas collide. Fix: schema-qualified keys.
- Saved queries infer their connection from a path transform. Fix: metadata in
  `b:sqlua`, plus a folder-to-connection lookup for files opened directly.
- Dotenv discovery matches the prefix anywhere in the variable name. Fix:
  removed.
- SQLite table names with spaces need a UI workaround because `.tables` output
  is parsed as text. Fix: metadata queries use tab-separated output.
- Drawer metadata runs synchronously and blocks the UI. Fix: async fetch with
  a loading row.
- Multiple notification implementations, colors, and timers. Fix:
  `vim.notify`.

## 9. Phases

### Phase 1: skeleton and URL

- `config`, `util`, `url`, `job`, adapter registry, SQLite adapter.
- Public `setup` and connection resolution.
- Tests for URL round-trips and adapter argv.

Checkpoint: headless tests pass. `:lua` can parse and format a URL.

### Phase 2: execution

- `db.run`, result buffers, `:DB`, events, cancel, rerun.
- Query buffer creation and bind parameters.
- SQLite integration test.

Checkpoint: `:DB sqlite:test.db select 1` shows a result; `:%DB` works;
a long query can be cancelled; a rerun replaces the previous output.

### Phase 3: connections and drawer

- Connection sources, `connections.json`, state.
- Drawer rendering, expand/collapse, add, delete, rename, refresh.
- Async metadata.

Checkpoint: the drawer lists env, `g:dbs`, and file connections; expanding
shows tables; opening a table creates a query buffer.

### Phase 4: query lifecycle

- Save, rename, delete, attach, execute on save, statusline.
- Folder-based saved-query connection detection.

Checkpoint: the full loop works with SQLite, including saving and reopening a
query in a new session.

### Phase 5: completion

- Cache, prefix parsing, alias parser, quoting.
- Omni and Blink sources.
- Clear-cache path.

Checkpoint: tables, schema tables, and `table.`/`alias.` columns complete
without duplicates, and the cache survives multiple buffers.

### Phase 6: adapters and docs

- PostgreSQL and MySQL/MariaDB.
- README, `doc/sqlua.txt`, migration table, manual test matrix.

Checkpoint: each adapter runs a simple query and lists metadata against a real
server, or is documented as untested when no server is available.

## 10. Testing

`nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c q`

- URL: network URLs, opaque URLs, IPv6, params, fragments, percent encoding,
  passwords, `$VAR`, relative and `~` paths.
- Adapters: sample URL to argv, metadata flag handling, environment values,
  aliases, missing binary.
- Placeholders: `{table}`, `{schema}`, `{optional_schema}`, `{dbname}`,
  quoting, helper override and removal.
- Alias parser: `from t x`, `join t as x`, quoted identifiers, reserved words.
- Prefix parser: `schema.`, `table.`, `alias.`, `:bind`, unqualified.
- SQLite integration: create a temp database, list tables and columns, run a
  query, verify output.
- Manual matrix: connect, browse, run, cancel, rerun, save, reopen, bind,
  complete.

## 11. Migration

| Old | New |
|---|---|
| `:DBUI` | `:Sqlua` |
| `:DBUIToggle` | `:SqluaToggle` |
| `:DBUIClose` | `:SqluaClose` |
| `:DBUIAddConnection` | `:SqluaAddConnection` |
| `:DBUIFindBuffer` | `:SqluaFindBuffer` |
| `:DBUIRenameBuffer` | `:SqluaRenameBuffer` |
| `:DBCompletionClearCache` | `:SqluaClearCache` |
| `g:db_ui_*` | `setup(opts)` |
| `g:dbs`, `g:db` | unchanged |
| `DBUI_URL` / `DBUI_NAME` | `SQLUA_URL` / `SQLUA_NAME` |
| `~/.local/share/db_ui` | `stdpath("data") .. "/sqlua"` |
| `dbui` / `dbout` filetypes | `sqlua` / `sqlua_result` |
| `<Plug>(DBUI_*)` | buffer mappings from config |

`:DB` keeps its familiar forms. Saved queries are not migrated automatically.
Copy them into `queries/<connection-slug>/` or keep using the old folder as
`save_location` until the move is done.

## 12. Decisions

1. Adapters: SQLite, PostgreSQL, MySQL/MariaDB. SQL Server is deferred because
   there is no test server. DuckDB, MongoDB, Redis, Oracle, BigQuery,
   ClickHouse, Snowflake, Presto/Trino, Impala, osquery, and jq are deferred.
2. Results: native CLI output. No cell yank, folds, foreign-key jump, or layout
   toggle in v1.
3. Keep `:DB` alongside the `:Sqlua*` commands.
4. Completion: Blink plus opt-in Omni. No `nvim-cmp`.
5. Drawer: no buffers section, no helper submenu, no `:SqluaBuffers` picker.
   Table `Enter` runs `List`; `C` runs `Columns`. Both run immediately by
   default. If user helpers are configured, `C` opens a picker first.
6. Table helpers: `List` plus `Columns` for all core adapters. Indexes, foreign
   keys, primary keys, constraints, and describe live in the docs as
   `table_helpers` snippets.
7. Password prompt: deferred. Use URL passwords, environment variables, and
   CLI credential files.

## Phase 1 checkpoint

Implemented:

- `config.lua`, `util.lua`, `url.lua`, `sql.lua`, `job.lua`, `db.lua`.
- Adapter registry and the SQLite adapter.
- `init.lua` with `setup`, and the `plugin/sqlua.lua` load guard.
- Tests for URL parsing, adapter argv, jobs, and config.

Verification:

```
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Result: 30 passed, 0 failed. A direct SQLite smoke test also returns
`code=0` and `stdout="1\n"`.

Not started: connections, drawer, completion.

## Phase 2 checkpoint

Implemented:

- `db.run` and `db.resolve_buffer`.
- `execute.run`, `run_buffer`, `db_command`, and `console`.
- Result scratch buffers with header, stderr, rerun, cancel, generation guard,
  and output cap.
- Query buffers under `tmp_location`, split opening, helper SQL, execute on
  save, bind parameters, save-as, and the query mappings.
- `:DB` with query text, range, file input, and interactive console forms.
- User events `SqluaQueryPre` and `SqluaQueryPost`.

Verification:

```
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Result: 45 passed, 0 failed. A direct `:DB sqlite::memory: select 1 as x`
prints the expected header and result.

Not started: connections, drawer, attach/find buffer, completion.

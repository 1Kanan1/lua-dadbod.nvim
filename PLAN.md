# lua-dadbod: implementation plan

`lua-dadbod` is one Neovim plugin that replaces `vim-dadbod`, `vim-dadbod-ui`, and
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
- Connections from `LUA_DADBOD_URL` / `LUA_DADBOD_NAME`, `g:db`, `g:dbs`, and
  `connections.json`.
- A drawer with connection trees, schemas/tables, global Scratchpads, and
  global session History.
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
| UI commands | `:LuaDadbod`, `:LuaDadbodToggle`, `:LuaDadbodClose`, `:LuaDadbodAddConnection`, `:LuaDadbodFindBuffer`, `:LuaDadbodRenameBuffer`, `:LuaDadbodClearCache`, `:LuaDadbodRefresh` |
| Filetypes | `lua_dadbod` for the drawer, `lua_dadbod_result` for results, normal `sql` for query buffers |
| Config | `require("lua-dadbod").setup(opts)` only, no `g:db_ui_*` |
| Connections | `LUA_DADBOD_*`, `g:db`, `g:dbs`, `connections.json` |
| Adapters | SQLite, PostgreSQL, MySQL/MariaDB; one file per adapter, one registry |
| Execution | SQL goes to the CLI on stdin, output goes into a scratch buffer |
| Results | CSV/TSV from the CLI, rendered as an aligned table |
| Query files | Real temp files so `:w` works, metadata in `b:lua_dadbod` |
| Completion | Omni plus Blink, cached per connection, scoped columns only |
| Tests | Plain Lua asserts, run through `nvim --headless` |

## 3. Layout

```
plugin/lua-dadbod.lua                    command registration, load guard
lua/lua-dadbod/init.lua                  public API
lua/lua-dadbod/config.lua                defaults and merge
lua/lua-dadbod/util.lua                  paths, slugs, files, prompts, notify
lua/lua-dadbod/url.lua                   parse, format, resolve, canonicalize
lua/lua-dadbod/sql.lua                   SQL literal and identifier quoting
lua/lua-dadbod/job.lua                   vim.system wrapper, cancel, timeout
lua/lua-dadbod/db.lua                    connection resolution, adapters, metadata
lua/lua-dadbod/execute.lua               :DB, running SQL, events
lua/lua-dadbod/result.lua                result scratch buffers
lua/lua-dadbod/history.lua               session history and history preview
lua/lua-dadbod/query.lua                 query files, bind params, save/rename
lua/lua-dadbod/ui.lua                    connection discovery, state, JSON
lua/lua-dadbod/drawer.lua                drawer rendering and actions
lua/lua-dadbod/completion.lua            cache, prefix logic, omni
lua/lua-dadbod/completion_blink.lua      Blink source
lua/lua-dadbod/adapters/init.lua         registry and aliases
lua/lua-dadbod/adapters/sqlite.lua
lua/lua-dadbod/adapters/postgresql.lua
lua/lua-dadbod/adapters/mysql.lua
tests/run.lua
tests/url_spec.lua
tests/adapter_spec.lua
tests/job_spec.lua
tests/query_spec.lua
tests/config_spec.lua
tests/history_spec.lua
tests/ui_spec.lua
tests/completion_spec.lua
tests/sqlite_spec.lua
doc/lua-dadbod.txt
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
| commands, tests | 500 |

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

1. `LUA_DADBOD_URL` / `LUA_DADBOD_NAME`.
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

1. `b:lua_dadbod.conn_key`, then `b:lua_dadbod.url`.
2. `b:db`.
3. `g:db`.
4. `$DATABASE_URL`.
5. The only configured connection, if exactly one exists.

`DATABASE_URL` is a fallback, not a drawer entry.

### Adapter contract

Each adapter is a table:

```lua
---@class LuaDadbodAdapter
---@field name string
---@field aliases? table<string, true>
---@field binary string
---@field quote? { string, string }       -- nil means no identifier quoting
---@field default_schema? string
---@field supports_schemas? fun(url): boolean
---@field filetype? string                -- defaults to "sql"
---@field argv fun(url, opts): string[], table|nil
---@field interactive? fun(url): string[], table|nil
---@field helpers? table<string, string>
---@field schemas_sql? fun(ctx): string
---@field tables_sql? fun(ctx): string
---@field columns_sql? fun(ctx): string
```

- `argv(url, opts)` returns the command and an optional environment table.
  `opts.meta = true` means machine-readable output with no header.
- `interactive(url)` returns the command and optional environment for a
  terminal console.
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
- Registration is `require("lua-dadbod.adapters").register(def)`, so a user adapter
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
- `:LuaDadbodClearCache` and drawer refresh clear it.
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
- Command completion is deferred until the core UI is stable.
- `:LuaDadbod` opens the drawer, `:LuaDadbodToggle` toggles, `:LuaDadbodClose` closes.
- `:LuaDadbodAddConnection` prompts for URL and name, validates the URL, appends to
  `connections.json`, and refreshes the drawer.
- `:LuaDadbodFindBuffer` attaches the current buffer to a connection.
- `:LuaDadbodRenameBuffer` renames a saved query.
- `:LuaDadbodClearCache` clears metadata and completion caches.
- `:LuaDadbodRefresh` rebuilds the connection list and clears metadata.
- All commands catch errors and report them through `vim.notify`.

### Drawer

One text buffer, one row list, rendered from scratch on each change. Expanded state:

```
 󰆼 sqlite/test ●
   󰓫 Tables (1)
    󰓫 users
 󰆼 postgres/prod
   󰙅 Schemas (3)
     󰙅 public
       󰓫 Tables (1)
        󰓫 users
     󰙅 pg_catalog
     󰙅 information_schema
 󰉋 Scratchpads (1)
   daily-report (sqlite/test)
 󰋚 History (1)
  · select * from users (sqlite/test, 14:32)
```

- `●` marks activated connections. A connection starts inactive. Entering a
  connection or one of its tables, or pressing `n` on it, activates it. It stays
  activated and keeps its marker for the session. The last activated connection
  is the target for new scratchpads. No connection is active on first open, even
  when only one exists.
- `dbms/db` is used only when more than one DBMS is configured. With a single
  DBMS, labels are just `test` or `prod`.
- Icons: `󰆼` connection, `󰓫` Tables and table rows, `󰙅` Schemas and schema rows,
  `󰉋` Scratchpads, `` scratchpad rows, `󰋚` History, `·` history rows.
- Table rows are one level deeper than the Tables header.
- Connections start collapsed. When a connection is expanded, Tables starts
  collapsed too. The example shows both expanded.
- SQLite goes straight to Tables. PostgreSQL adds a Schemas level; the example
  shows `public` expanded and `pg_catalog` / `information_schema` collapsed.
- Scratchpads is global. It lists saved query files from every connection
  folder plus open query buffers. Labels show the connection in parentheses.
  Unsaved or modified scratchpads are marked `*`. A saved file that is open in
  a buffer appears once. Deleting a query buffer or saving it refreshes the
  list and the `*` marker without collapsing the section.
- The drawer is always one window. Rendering closes any extra window that shows
  the drawer buffer.
- History is global and session-only. It records every query that finishes,
  newest first, capped at 50, and deduplicates by connection plus SQL.
- `Enter` on a history row opens a floating preview with the full SQL.
  `R` reruns directly from the stored history entry, closes the preview, and
  shows the result. `q` or `<Esc>` closes without running.
- There is no `+ New scratchpad` row. `n` creates a scratchpad:
  on a connection, table, scratchpad, or history row it uses that row's
  connection; on a section it uses the last activated connection. If none is
  active it uses the only configured connection or prompts.
- Empty states: `No scratchpads. Press n to create one.` and `No history yet.`
- Scratchpads and History start collapsed on the first drawer open. Their counts
  stay visible while collapsed.
- Connections, Scratchpads, and History are adjacent, with no blank lines
  between them.
- There is no `+ Add connection` row. With no connections, the drawer shows
  `No connections. Press A to add one.`
- Drawer colors come from highlight groups linked to the active colorscheme:
  `LuaDadbodDb`, `LuaDadbodTable`, `LuaDadbodSchema`, `LuaDadbodScratchpads`, `LuaDadbodScratchpad`,
  `LuaDadbodHistory`, `LuaDadbodHistoryEntry`, `LuaDadbodChevron`, `LuaDadbodCount`,
  `LuaDadbodActive`, and `LuaDadbodHelp`. Users can override any of them.

- `<CR>` / `o`: preview a table result, or open/toggle other rows.
- Opening a query, table, or saved scratchpad replaces the buffer in the normal
  window right of the drawer instead of adding another split. `S` always splits.
- `e`: open an editable `List` query for the selected table without running it.
- `S`: open an editable query in a vertical split.
- `n`: new scratchpad.
- `C`: preview the `Columns` result on a table row. If user helpers are
  configured, open `vim.ui.select` with `Columns` plus those helpers first.
- `A`: add connection.
- `r`: rename a saved scratchpad. Unsaved scratchpads must be saved first.
- `d`: delete a saved scratchpad or file connection, wipe an unsaved scratchpad,
  or remove a history entry.
- `R`: refresh the selected connection; at the root, refresh all.
- `H`: show the scheme and source in the connection label.
- `q`: close.
- `?`: print a short key reminder through `vim.notify`.

- Connection rows show a loading marker while metadata is fetching.
- `Enter` on a table runs `List` and opens only the result buffer, with no query
  buffer. `C` does the same for `Columns`. `e` opens the SQL when you want to
  edit it.
- `S` uses `auto_execute_helpers`; `e` always opens the SQL without running.
  Enter and `C` are always result-only previews.
- `List` defaults to 50 rows through `default_query`.
- No helper submenu, no per-connection query section, and no `:LuaDadbodBuffers`
  picker.
- No sibling navigation, help pane, result list, or progress animation.

Default global maps, installed by `setup()`:
- `<leader>Do` open drawer
- `<leader>Dt` toggle drawer
- `<leader>Dc` close drawer
- `<leader>Da` add connection
- `<leader>Df` attach current buffer
- `<leader>Dx` clear cache

### Query buffers

- Named after a real path under `tmp_location`; the file is created on the
  first `:w`, so a new scratchpad writes normally instead of failing with E13.
- Name: `<slug(conn)>-<table>-<helper>-<timestamp>.sql`.
- `b:lua_dadbod = { conn, conn_key, conn_name, dbms, url, source, schema, table, helper, bind, path }`.
- The buffer keeps `filetype=sql`, so Treesitter and LSP keep working.
- Insert-mode mappings that reference `sqlcomplete#` are removed when
  `g:loaded_sql_completion` is set, because Neovim's `autoload/sqlcomplete.vim`
  exits early in that case and the functions do not exist.
- `BufWritePost` runs the whole buffer when `execute_on_save = true`
  (default `false`).
- `<Leader>S` runs the whole buffer; in visual mode it runs the selection.
- `<CR>` in normal mode runs the statement under the cursor; in visual mode it
  runs the selection. Boundaries are top-level semicolons, ignoring semicolons in
  strings, quoted identifiers, comments, and PostgreSQL dollar quotes. Cursor on a
  blank or comment-only line runs the previous statement, then the next.
- `<Leader>W` saves a copy under
  `<save_location>/queries/<folder>/<name>.sql` using
  `:noautocmd saveas`,
  then marks the buffer as saved.
- `<Leader>E` edits bind parameters through `vim.ui.select`: choose a
  parameter, enter a new value, or clear all.
- Bind parameters are detected with `bind_param_pattern` (default `:%w+`),
  ignoring matches inside single quotes, prompted once, cached in
  `b:lua_dadbod.bind`, and substituted with quoting for numeric, boolean, already
  quoted, and string values.
- Opening a file under `queries/<folder>/` sets the connection from the folder
  and marks it saved. No filename guessing beyond that.
- Saved queries can be renamed or deleted from the drawer. Open buffers follow
  the rename or are wiped on delete.

### Results

- Scratch buffer named `lua-dadbod://result/<n>`, `buftype=nofile`,
  `bufhidden=wipe`, `filetype=lua_dadbod_result`.
- Header: connection name, status, row count, elapsed time, exit code.
- Results are parsed from adapter output: PostgreSQL/SQLite CSV, MySQL TSV.
- Cells are padded, numeric columns right-aligned, NULL shown as `NULL`, and
  cells longer than 60 display columns are trimmed with `…`.
- Parse failures, multiple result sets, and non-tabular output fall back to raw
  stdout. Stderr follows if non-empty.
- Opened in a split without stealing focus. Reused for the same query buffer
  when possible.
- `R` reruns the stored SQL, `<C-c>` cancels, `q` closes.
- Leaving the buffer cancels a running job.
- Output is capped at `result.max_lines` (default 10000) with a notice.
- No folds, cell yank, header yank, foreign-key jump, or layout toggle.
  Normal Vim search and yank still work on the output.
- Events:
  - `User LuaDadbodQueryPre`
  - `User LuaDadbodQueryPost`
  - payload: `{ conn, sql, code, elapsed }`

### Completion

- Cache per resolved connection, not per buffer.
- Context from `b:lua_dadbod`, then `b:db`, then `g:db`, then `$DATABASE_URL`.
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
  - `require("lua-dadbod.completion_blink")`.
- `nvim-cmp` support is dropped. If it is ever needed, it is a small adapter
  around the same completion function.

## 6. Configuration

```lua
require("lua-dadbod").setup({
  save_location = vim.fn.stdpath("data") .. "/lua-dadbod",
  tmp_location = vim.fn.stdpath("cache") .. "/lua-dadbod/queries",
  win = { width = 40, position = "left" },
  default_query = "select * from {optional_schema}{table} limit 50;",
  execute_on_save = false,
  auto_execute_helpers = true,
  bind_param_pattern = ":%w+",
  table_helpers = {},
  icons = {
    expanded = "",
    collapsed = "",
    db = "󰆼",
    table = "󰓫",
    schema = "󰙅",
    scratchpads = "󰉋",
    scratchpad = "",
    history = "󰋚",
    history_entry = "·",
    active = "●",
  },
  result = { max_lines = 10000 },
  mappings = {
    enabled = true,
    global = true,
    drawer = true,
    query = true,
    result = true,
  },
  dbs = nil,
})
```

`completion` remains absent until Phase 5. `hide_schemas` is still absent;
schemas are always listed for now.
`table_helpers` merges over adapter defaults. An empty string removes a helper.
`mappings = false` disables all built-in maps. `icons = false` disables type
icons while keeping the expand/collapse markers. Drawer colors are controlled
by the `LuaDadbod*` highlight groups listed above, not by hardcoded colors.

Public API:

```lua
local lua_dadbod = require("lua-dadbod")

lua_dadbod.setup(opts)
lua_dadbod.open()
lua_dadbod.toggle()
lua_dadbod.close()
lua_dadbod.add_connection(opts?)          -- nil opens prompts
lua_dadbod.attach(bufnr?)                 -- nil means current buffer
lua_dadbod.connections()                  -- copy of the connection list
lua_dadbod.get_connection(key)
lua_dadbod.run(sql, opts, cb)             -- one low-level job
lua_dadbod.statusline(opts)
lua_dadbod.clear_cache()
lua_dadbod.refresh()
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
| Per-connection buffers section | Scratchpads scans open query buffers at render time, so there is no persistent buffer list to keep in sync |
| Result list in the drawer | Results are one split away and not a navigation target |
| Folds, layout toggle, foreign-key jump | Expensive adapter-specific result parsing for occasional use |
| Cell and header yank | Same reason; can be added later on top of a normalized result format |
| Indexes, FKs, PKs, Constraints, Describe helpers | Fragile copied SQL; `List` and `Columns` stay, the rest move to docs snippets |
| Dotenv environment scan | Hidden global behavior; `g:dbs` or the connection file is explicit |
| Filename-based database inference | `b:lua_dadbod` and the saved-query folder are reliable |
| Buffer name generator and table sorter callbacks | Configuration surface without a clear need |
| Connection rename | Delete and add is enough |
| Legacy `g:db_ui_*` options and `:DBUI*` commands | Clean break for a new plugin |
| `dbui` and `dbout` filetypes | Renamed to `lua_dadbod` and `lua_dadbod_result` |
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
| `:DBCompletionClearCache` | `:LuaDadbodClearCache` |

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
  `b:lua_dadbod`, plus a folder-to-connection lookup for files opened directly.
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
- README, `doc/lua-dadbod.txt`, migration table, manual test matrix.

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
| `:DBUI` | `:LuaDadbod` |
| `:DBUIToggle` | `:LuaDadbodToggle` |
| `:DBUIClose` | `:LuaDadbodClose` |
| `:DBUIAddConnection` | `:LuaDadbodAddConnection` |
| `:DBUIFindBuffer` | `:LuaDadbodFindBuffer` |
| `:DBUIRenameBuffer` | `:LuaDadbodRenameBuffer` |
| `:DBCompletionClearCache` | `:LuaDadbodClearCache` |
| `g:db_ui_*` | `setup(opts)` |
| `g:dbs`, `g:db` | unchanged |
| `DBUI_URL` / `DBUI_NAME` | `LUA_DADBOD_URL` / `LUA_DADBOD_NAME` |
| `~/.local/share/db_ui` | `stdpath("data") .. "/lua-dadbod"` |
| `dbui` / `dbout` filetypes | `lua_dadbod` / `lua_dadbod_result` |
| `<Plug>(DBUI_*)` | buffer mappings from config |

`:DB` keeps its familiar forms. Saved queries are not migrated automatically.
Copy them into `queries/<connection-key-slug>/` or keep using the old folder as
`save_location` until the move is done.

## 12. Decisions

1. Adapters: SQLite, PostgreSQL, MySQL/MariaDB. SQL Server is deferred because
   there is no test server. DuckDB, MongoDB, Redis, Oracle, BigQuery,
   ClickHouse, Snowflake, Presto/Trino, Impala, osquery, and jq are deferred.
2. Results: structured CLI output rendered as an aligned table, with raw
   fallback. No cell yank, folds, foreign-key jump, or layout toggle in v1.
3. Keep `:DB` alongside the `:LuaDadbod*` commands.
4. Completion: Blink plus opt-in Omni. No `nvim-cmp`.
5. Drawer: connection trees plus global Scratchpads and History. No
   per-connection query rows, helper submenu, `:LuaDadbodBuffers` picker, or
   `+ Add connection` row. Scratchpads and History default to collapsed.
   A blank line separates connections from Scratchpads; Scratchpads and History
   are adjacent. `A` adds a connection.
   Table `Enter` previews `List` as a result only. `e` opens the editable SQL.
   `C` previews `Columns` as a result only, or opens a helper picker first.
6. Table helpers: `List` plus `Columns` for all core adapters. Indexes, foreign
   keys, primary keys, constraints, and describe live in the docs as
   `table_helpers` snippets.
7. Password prompt: deferred. Use URL passwords, environment variables, and
   CLI credential files.
8. Scratchpads: saved files plus open query buffers, listed globally with the
   connection in parentheses. `*` marks unsaved or modified. `n` creates one;
   there is no `+ New scratchpad` row.
9. Active connection: connections start inactive, even when only one exists.
   Entering a connection or table, or pressing `n` on it, activates it. Every
   activated connection keeps its `●` for the session. The last activated one
   is the target for new scratchpads. If none is active, `n` uses the only
   connection or prompts.
10. History: session-only, newest first, capped at 50, deduplicated by
    connection plus SQL. `Enter` opens a floating preview; `R` reruns directly
    from the stored entry and closes the preview; `d` removes an entry.
11. Display: `dbms/db` only when more than one DBMS is configured. Otherwise
    use just the database name. This applies to connections, scratchpads, and
    history.
12. Icons and colors: Nerd Font glyphs from the config, with `icons = false`
    disabling type icons. Colors use `LuaDadbod*` highlight groups linked to the
    colorscheme, so no palette is hardcoded. The database icon uses `Normal`
    so it is white/silver, not green.
13. Default global maps installed by `setup()`: `<leader>Do` open,
    `<leader>Dt` toggle, `<leader>Dc` close, `<leader>Da` add connection,
    `<leader>Df` attach buffer, `<leader>Dx` clear cache.

## Phase 1 checkpoint

Implemented:

- `config.lua`, `util.lua`, `url.lua`, `sql.lua`, `job.lua`, `db.lua`.
- Adapter registry and the SQLite adapter.
- `init.lua` with `setup`, and the `plugin/lua-dadbod.lua` load guard.
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
- User events `LuaDadbodQueryPre` and `LuaDadbodQueryPost`.

Verification:

```
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Result: 45 passed, 0 failed. A direct `:DB sqlite::memory: select 1 as x`
prints the expected header and result.

Not started: connections, drawer, attach/find buffer, completion.

## Phase 3 checkpoint

Implemented:

- Connection discovery from `LUA_DADBOD_URL` / `LUA_DADBOD_NAME`, `g:db`, `g:dbs`
  (mapping or ordered list, string or function values), and
  `connections.json`.
- Connection state, duplicate handling, saved query folders, active connection,
  and selection.
- `db.fetch_tables` with a per-connection metadata cache and concurrent request
  coalescing.
- The drawer with connection expand/collapse, tables, global Scratchpads,
  global History, async loading, errors, details, icons, empty states, section
  spacing, colors, and collapsed Scratchpads/History by default.
- `dbms/db` labels only when more than one DBMS is configured.
- Scratchpads aggregate saved files from every connection and open query
  buffers, with unsaved or modified entries marked `*`.
- History is session-only, deduplicated by connection plus SQL, capped at 50,
  with a floating full-query preview and direct rerun.
- Drawer actions: `Enter`/`o`, `S`, `n`, `C`, `A`, `r`, `d`, `R`, `H`, `q`, `?`.
- Commands: `:LuaDadbod`, `:LuaDadbodToggle`, `:LuaDadbodClose`, `:LuaDadbodAddConnection`,
  `:LuaDadbodFindBuffer`, `:LuaDadbodRenameBuffer`, `:LuaDadbodClearCache`, and
  `:LuaDadbodRefresh`.
- Public API: `open`, `toggle`, `close`, `add_connection`, `attach`,
  `connections`, `get_connection`, `run`, `statusline`, `clear_cache`, and
  `refresh`.
- Query buffers can be opened from saved files, focused as open scratchpads,
  attached to arbitrary buffers, and opened in a vertical split.

Verification:

```
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Result: 58 passed, 0 failed. The drawer test discovers a `g:dbs` connection,
expands it, loads tables asynchronously, previews a table result, opens the
`Columns` preview, and opens the editable query. Separate tests cover active
connections, `dbms/db` labels, scratchpads, history preview plus rerun, and the
global mappings.

## Phase 4 checkpoint

Implemented:

- Save-as prompts for a name and writes under
  `<save_location>/queries/<folder>/<name>.sql`. Saving under a
  connection folder is what marks the file as a saved query; reopening it
  attaches the connection from the folder.
- Rename updates the file, the buffer name, and `meta.path`. Delete removes the
  file and wipes the buffer. Both keep open buffers in sync.
- Attach via `:LuaDadbodFindBuffer` gives an existing buffer the query
  mappings, connection metadata, and execute-on-save behavior.
- `BufWritePost` runs the whole buffer when `execute_on_save` is true and does
  nothing when false. The default is false. Scratchpads refresh after save and
  after `BufDelete` or `BufWipeout`.
- Insert-mode `sqlcomplete#` mappings are removed from query buffers when
  `g:loaded_sql_completion` is set, so `<Right>` and `<Left>` move the cursor
  instead of calling functions Neovim did not load.
- `statusline(opts)` returns `<prefix><name> > <schema> > <table>` for attached
  buffers, honors `prefix`, `separator`, and `show`, and returns `""` for other
  buffers.
- Scratchpads are named buffers without a pre-created file, so the first `:w`
  creates it. Pre-creating it made the first `:w` fail with `E13: File exists`.

Verification:

```
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

Result: 99 passed, 0 failed. Tests cover save/rename/delete, execute on save
enabled and disabled, statusline formatting, and reopening a saved query in a
separate `nvim --headless` process with `g:dbs` configured.

Not started: completion.

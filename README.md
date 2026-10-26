# lua-dadbod

Early test build of a Neovim SQL client. It replaces `vim-dadbod`,
`vim-dadbod-ui`, and `vim-dadbod-completion`.

Not stable yet. SQLite, PostgreSQL, and MySQL/MariaDB are supported.

Full reference: `:help lua-dadbod`.

## Requirements

- Neovim 0.10 or newer
- `sqlite3` on `PATH` for SQLite
- `psql` on `PATH` for PostgreSQL
- `mysql` on `PATH` for MySQL and MariaDB

## Install with lazy.nvim

Clone the repo:

```sh
git clone https://github.com/1Kanan1/lua-dadbod.nvim.git ~/dev/lua-dadbod
```

Add this to your lazy.nvim plugins. Change `dir` if you cloned it elsewhere:

```lua
{
  dir = "~/dev/lua-dadbod",
  name = "lua-dadbod",
  config = function()
    require("lua-dadbod").setup()
  end,
}
```

The `name = "lua-dadbod"` field keeps lazy.nvim from using the repo folder name. The
plugin is not published yet, so `dir` is expected.

Restart Neovim after adding it.

## First run

Open the drawer:

```vim
:LuaDadbod
```

or press `<leader>Do`. Press `A` to add a connection. Connection URLs look like:

```text
sqlite:/absolute/path/to/file.db
sqlite::memory:
postgresql://user:password@host:5432/database
mysql://user:password@host:3306/database
```

SQLite goes straight to tables. PostgreSQL shows schemas, and MySQL/MariaDB
shows databases as schemas.

Enter on a connection or table to activate it. Enter on a table previews the
first 50 rows. `e` opens the same query in an editable buffer, and `C` shows the
table columns.

## Commands

| Command | Action |
| --- | --- |
| `:DB [url] [query]` | Run SQL or open a console (forms below) |
| `:LuaDadbod` | Open the drawer |
| `:LuaDadbodToggle` | Toggle the drawer |
| `:LuaDadbodClose` | Close the drawer |
| `:LuaDadbodAddConnection` | Add a connection |
| `:LuaDadbodFindBuffer` | Attach the current buffer to a connection |
| `:LuaDadbodRenameBuffer` | Rename the current saved query |
| `:LuaDadbodClearCache` | Clear metadata and completion caches |
| `:LuaDadbodRefresh` | Reload connections and expanded metadata |

`:DB` forms:

```text
:DB                     console for the current buffer
:DB {url}               console for {url}
:DB {url} {query}       run a query
:DB {query}             run against the current buffer
:'<,'>DB [{url}]        run the selected lines
:DB < {file}            run the contents of a file
:DB! ...                start a new result buffer instead of reusing one
```

## Keys

Drawer:

| Key | Action |
| --- | --- |
| `<CR>`, `o` | Activate the row; on a table, preview rows |
| `S` | Open in a vertical split |
| `n` | New scratchpad |
| `e` | Edit the table's List query |
| `C` | Preview the table's Columns helper |
| `A` | Add a connection |
| `r` | Rename the scratchpad |
| `d` | Delete a scratchpad, history entry, or file connection |
| `R` | Refetch metadata |
| `H` | Toggle source details |
| `q` | Close the drawer |
| `?` | Toggle key help |

Query buffers: `<CR>` runs the statement under the cursor (visual: selection),
`<leader>S` runs the whole buffer (visual: selection), `<leader>W` saves the
query, `<leader>E` edits bind parameters.

Results: `R` reruns, `<C-c>` cancels, `q` closes.

The full reference is in `:help lua-dadbod`.

## Completion

Completion is cache-only on the keystroke path: it never starts a process. A
cold cache returns what is known and fetches the rest in the background, so the
first completion after opening a buffer may be empty and the next keystroke
shows it.

### Blink

Add the provider to your Blink setup:

```lua
{
  "saghen/blink.cmp",
  opts = {
    sources = {
      per_filetype = { sql = { inherit_defaults = true, "dadbod" } },
      providers = {
        dadbod = {
          name = "LuaDadbod",
          module = "lua-dadbod.completion_blink",
          min_keyword_length = function(ctx)
            -- Allow `alias.`, `schema.`, and an empty keyword right after
            -- FROM/JOIN so <C-space> can list tables there.
            return require("lua-dadbod.completion").min_keyword_length(ctx)
          end,
        },
      },
    },
  },
}
```

Then `alias.`, `table.`, `schema.`, bare table names, and `:bind` parameters
complete.

### Tables after FROM

Completion knows when the cursor is waiting for a table name: after `FROM`,
`JOIN`, `INTO`, `UPDATE`, `TABLE`, or a comma inside a `FROM`/`JOIN` list. It
returns tables and schemas only there, with tables first.

Anywhere else a bare word returns nothing. Columns require `alias.` or
`table.`, and bind parameters require `:name`. This keeps tables out of
`SELECT` lists, `WHERE` clauses, and empty buffers.

Blink does not open completion on whitespace, so nothing pops up immediately
after typing `FROM `. Type the first letter of the table, or press `<C-space>`
right after `FROM ` (the `min_keyword_length` function above allows an empty
keyword in that position).

System schemas are listed with the other schemas. `information_schema.` lists
its tables and `pg_catalog.` does the same, but those tables are not mixed into
the unqualified list.

Completion covers schemas, tables, columns, and bind parameters. It does not
suggest SQL keywords. Schema and table entries use the drawer's
`icons.schema` and `icons.table` glyphs as their Blink menu icons.

### Omni

Opt in through setup:

```lua
require("lua-dadbod").setup({
  completion = { omnifunc = true },
})
```

Then use `<C-x><C-o>` where you want completion. Omni reads the cache only and
returns nothing when the cache is cold.

## Configuration

`setup()` merges the options you pass over the defaults. Only the keys you pass
are validated.

| Option | Default | Purpose |
| --- | --- | --- |
| `save_location` | `stdpath("data") .. "/lua-dadbod"` | `connections.json` and saved queries |
| `tmp_location` | `stdpath("cache") .. "/lua-dadbod/queries"` | Scratch query buffers |
| `win.width`, `win.position` | `40`, `"left"` | Drawer window |
| `default_query` | `select * from {optional_schema}{table} limit 50;` | `List` helper |
| `execute_on_save` | `false` | Run a query buffer on `:w` |
| `auto_execute_helpers` | `true` | Run a helper query when it opens |
| `bind_param_pattern` | `:%w+` | Bind parameter syntax |
| `table_helpers` | `{}` | Per-adapter SQL overrides |
| `dbs` | `nil` | Extra connections, same shape as `g:dbs` |
| `completion.enabled` | `true` | Turn completion off |
| `completion.omnifunc` | `false` | Opt-in Omni function |
| `completion.prefetch` | `true` | Warm columns for up to 3 tables |
| `completion.max_items` | `200` | Cap on returned items |
| `result.max_lines` | `10000` | Output cap |
| `result.height` | `0.4` | Result split height, as a fraction |
| `icons` | Nerd Font glyphs | `false` disables icons |
| `mappings` | all sections on | `false` installs no maps |

`mappings` also takes a table with `enabled`, `global`, `drawer`, `query`, and
`result` booleans. `table_helpers` replaces or removes the `List` and `Columns`
templates per adapter; placeholders are `{table}`, `{schema}`,
`{optional_schema}`, `{dbname}`, and the `_lit` variants.

`:LuaDadbodClearCache` clears columns together with the rest of the metadata.

## Migration from vim-dadbod

Both plugins define `:DB`, so disable `vim-dadbod`, `vim-dadbod-ui`, and
`vim-dadbod-completion` while using lua-dadbod.

| Old | New |
| --- | --- |
| `:DBUI` | `:LuaDadbod` |
| `:DBUIToggle` | `:LuaDadbodToggle` |
| `:DBUIClose` | `:LuaDadbodClose` |
| `:DBUIAddConnection` | `:LuaDadbodAddConnection` |
| `:DBUIFindBuffer` | `:LuaDadbodFindBuffer` |
| `:DBUIRenameBuffer` | `:LuaDadbodRenameBuffer` |
| `:DBCompletionClearCache` | `:LuaDadbodClearCache` |
| `g:db_ui_*` | `setup(opts)` |
| `g:dbs`, `g:db` | Unchanged |
| `DBUI_URL` / `DBUI_NAME` | `LUA_DADBOD_URL` / `LUA_DADBOD_NAME` |
| `~/.local/share/db_ui` | `stdpath("data")/lua-dadbod` |
| `dbui` / `dbout` filetypes | `lua_dadbod` / `lua_dadbod_result` |
| `<Plug>(DBUI_*)` | Buffer mappings from configuration |

`:DB` keeps its familiar forms. Saved queries are not migrated automatically;
copy them into `queries/<folder>/` under the new data directory.

## Status

SQLite is covered by the automated suite. PostgreSQL is verified against a local
server. MySQL/MariaDB has argv and helper unit tests only; this repository has no
server to test against. The manual checklist lives in
`:help lua-dadbod-manual-checks`.

## Tests

```sh
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

The suite needs `sqlite3` on `PATH`; no database server is required.

## License

MIT. See [LICENSE](LICENSE).

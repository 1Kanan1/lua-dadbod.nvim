# lua-dadbod

Early test build of a Neovim SQL client. It replaces `vim-dadbod`,
`vim-dadbod-ui`, and `vim-dadbod-completion`.

Not stable yet. SQLite, PostgreSQL, and MySQL/MariaDB are supported.

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
            -- Allow `alias.` and `schema.` with nothing typed after the dot.
            return ctx.trigger.initial_kind == "trigger_character" and 0 or 1
          end,
        },
      },
    },
  },
}
```

Then `alias.`, `table.`, `schema.`, bare table names, and `:bind` parameters
complete.

### Omni

Opt in through setup:

```lua
require("lua-dadbod").setup({
  completion = { omnifunc = true },
})
```

Then use `<C-x><C-o>` where you want completion. Omni reads the cache only and
returns nothing when the cache is cold.

### Tuning

```lua
completion = {
  enabled = true,   -- false turns completion off
  omnifunc = false, -- opt-in Omni function
  prefetch = true,  -- warm up to 3 tables after opening a buffer
  max_items = 200,  -- cap on returned items
}
```

`:LuaDadbodClearCache` clears columns together with the rest of the metadata.

## Conflict with vim-dadbod

Both plugins define `:DB`. Disable `vim-dadbod`, `vim-dadbod-ui`, and
`vim-dadbod-completion` while testing lua-dadbod.

## Tests

```sh
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

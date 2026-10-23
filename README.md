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

## Conflict with vim-dadbod

Both plugins define `:DB`. Disable `vim-dadbod`, `vim-dadbod-ui`, and
`vim-dadbod-completion` while testing lua-dadbod.

## Tests

```sh
nvim --headless -u NONE -c "lua dofile('tests/run.lua')" -c "qa!"
```

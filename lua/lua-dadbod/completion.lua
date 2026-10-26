local config = require("lua-dadbod.config")
local db = require("lua-dadbod.db")
local statement = require("lua-dadbod.statement")
local url = require("lua-dadbod.url")

local M = {}

local SLICE = 150
local PREFETCH_LIMIT = 3
local KIND_TEXT = 1
local KIND_FIELD = 5
local KIND_MODULE = 9

local reserved = {
    all = true,
    alter = true,
    ["and"] = true,
    as = true,
    by = true,
    case = true,
    check = true,
    column = true,
    constraint = true,
    create = true,
    default = true,
    delete = true,
    drop = true,
    ["else"] = true,
    ["end"] = true,
    from = true,
    ["function"] = true,
    group = true,
    index = true,
    insert = true,
    into = true,
    join = true,
    key = true,
    limit = true,
    ["not"] = true,
    null = true,
    offset = true,
    on = true,
    ["or"] = true,
    order = true,
    primary = true,
    procedure = true,
    schema = true,
    select = true,
    table = true,
    ["then"] = true,
    trigger = true,
    union = true,
    update = true,
    user = true,
    using = true,
    values = true,
    view = true,
    when = true,
    where = true,
}

local reference_keywords = {
    from = true,
    join = true,
    update = true,
    into = true,
}

local stop_words = {
    as = true,
    cross = true,
    except = true,
    fetch = true,
    ["for"] = true,
    full = true,
    group = true,
    having = true,
    inner = true,
    intersect = true,
    into = true,
    join = true,
    lateral = true,
    left = true,
    limit = true,
    natural = true,
    offset = true,
    on = true,
    order = true,
    outer = true,
    returning = true,
    right = true,
    set = true,
    union = true,
    using = true,
    values = true,
    where = true,
    window = true,
    with = true,
}

local memo = {}
local prefetch_timers = {}

local function noop() end

local function lower(value)
    return tostring(value or ""):lower()
end

local function unquote(value)
    if type(value) ~= "string" or #value < 2 then
        return value
    end
    local first = value:sub(1, 1)
    if first == '"' and value:sub(-1) == '"' then
        return (value:sub(2, -2):gsub('""', '"'))
    end
    if first == "`" and value:sub(-1) == "`" then
        return (value:sub(2, -2):gsub("``", "`"))
    end
    return value
end

local function next_ident(text, pos)
    local start = text:find("%S", pos)
    if not start then
        return nil
    end

    local char = text:sub(start, start)
    if char == '"' or char == "`" then
        local close = text:find(char, start + 1, true)
        if not close then
            return nil
        end
        return text:sub(start, close), close + 1
    end

    local word = text:match("^([%w_$]+)", start)
    if not word then
        return nil
    end
    return word, start + #word
end

local function parse_qualified(text, pos)
    local first, after = next_ident(text, pos)
    if not first then
        return nil
    end

    local schema, name = nil, unquote(first)
    local dot = text:find("%S", after)
    if dot and text:sub(dot, dot) == "." then
        local second, after_second = next_ident(text, dot + 1)
        if second then
            schema, name, after = unquote(first), unquote(second), after_second
        end
    end
    return schema, name, after
end

local function scan(sql, dialect)
    local text = statement.sanitize(sql, vim.tbl_extend("force", dialect or {}, { identifiers = true }))
    local refs = {}

    for pos, word in text:gmatch("()(%a+)") do
        if reference_keywords[word:lower()] then
            local schema, name, after = parse_qualified(text, pos + #word)
            if name then
                local alias
                local next_pos = text:find("%S", after)
                if next_pos then
                    local candidate, candidate_end = next_ident(text, next_pos)
                    if candidate then
                        local value = unquote(candidate)
                        if lower(value) == "as" then
                            local alias_word = next_ident(text, candidate_end)
                            alias = alias_word and unquote(alias_word) or nil
                        elseif not stop_words[lower(value)] then
                            alias = value
                        end
                    end
                end
                refs[#refs + 1] = { schema = schema, table = name, alias = alias }
            end
        end
    end

    return refs
end

-- Table references in one statement, deduplicated by schema and table.
function M.references(sql, dialect)
    local seen = {}
    local out = {}
    for _, ref in ipairs(scan(sql, dialect)) do
        local key = lower(ref.schema) .. "\0" .. lower(ref.table)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = ref
        end
    end
    return out
end

-- Alias and table name to { schema, table } for the current statement.
function M.aliases(sql, dialect)
    local map = {}
    for _, ref in ipairs(scan(sql, dialect)) do
        local entry = { schema = ref.schema, table = ref.table }
        map[lower(ref.table)] = entry
        if ref.alias and ref.alias ~= "" then
            map[lower(ref.alias)] = entry
        end
    end
    return map
end

local function bind_prefix(before)
    local match = before:match(":[%w_]*$")
    if not match then
        return nil
    end
    local colon = #before - #match + 1
    if colon > 1 and before:sub(colon - 1, colon - 1) == ":" then
        return nil -- a cast, not a bind parameter
    end
    return match
end

function M.prefix(before)
    local bind = bind_prefix(before)
    if bind then
        return { kind = "binds", prefix = bind:sub(2) }
    end

    local qualifier, word = before:match("([%w_]+)%.([%w_]*)$")
    if qualifier then
        return { kind = "qualified", qualifier = qualifier, prefix = word }
    end

    return { kind = "bare", prefix = before:match("[%w_]*$") or "" }
end

local function statement_text(bufnr, row, dialect)
    local count = vim.api.nvim_buf_line_count(bufnr)
    local first = math.max(1, row - SLICE)
    local last = math.min(count, row + SLICE)
    local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local chunk = statement.find(lines, row - first + 1, dialect)
    if not chunk then
        return table.concat(lines, "\n")
    end
    return table.concat(lines, "\n", chunk.line1, chunk.line2)
end

local function remember(bufnr, row, col, input, value)
    memo = {
        bufnr = bufnr,
        tick = vim.api.nvim_buf_get_changedtick(bufnr),
        row = row,
        col = col,
        input = input,
        value = value,
    }
end

local function recall(bufnr, row, col, input)
    if memo.bufnr ~= bufnr or memo.row ~= row or memo.col ~= col or memo.input ~= input then
        return nil
    end
    if memo.tick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
        return nil
    end
    return memo.value
end

function M.analysis(bufnr, row, col)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end
    row = row or vim.api.nvim_win_get_cursor(0)[1]
    col = col or 0

    local input = db.resolve_buffer(bufnr)
    if not input then
        return nil
    end

    local cached = recall(bufnr, row, col, input)
    if cached then
        return cached
    end

    local parsed, adapter = db.parse(input)
    if not parsed or not adapter then
        return nil
    end

    local key = url.format(parsed)
    if not key then
        return nil
    end

    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local prefix = M.prefix(line:sub(1, col))
    local dialect = statement.dialect(adapter.name)
    local sql = statement_text(bufnr, row, dialect)

    local value = {
        bufnr = bufnr,
        row = row,
        col = col,
        input = input,
        url = key,
        parsed = parsed,
        adapter = adapter,
        dialect = dialect,
        prefix = prefix,
        aliases = M.aliases(sql, dialect),
        sql = sql,
    }

    if prefix.kind == "qualified" then
        local target = value.aliases[lower(prefix.qualifier)]
        if target then
            value.kind = "columns"
            value.target = target
        else
            value.kind = "tables"
            value.schema = prefix.qualifier
        end
    else
        value.kind = prefix.kind
    end

    remember(bufnr, row, col, input, value)
    return value
end

local function needs_quote(adapter, name)
    if not adapter.quote then
        return false
    end
    if name:find("[^%w_$]") then
        return true
    end
    if name:match("^%d") then
        return true
    end
    if name ~= name:lower() then
        return true
    end
    return reserved[name:lower()] == true
end

local function quote_ident(adapter, name)
    if not needs_quote(adapter, name) then
        return name
    end
    local open, close = adapter.quote[1], adapter.quote[2]
    return open .. name:gsub(close, close .. close) .. close
end

local function push(items, max, adapter, name, kind, detail)
    if #items >= max or type(name) ~= "string" or name == "" then
        return
    end
    items[#items + 1] = {
        label = name,
        kind = kind,
        detail = detail,
        insertText = quote_ident(adapter, name),
    }
end

function M.items_for(context)
    local max = config.get().completion.max_items or 200
    local items = {}
    local adapter = context.adapter

    if context.kind == "binds" then
        local meta = vim.b[context.bufnr].lua_dadbod
        local bind = type(meta) == "table" and meta.bind or nil
        local names = vim.tbl_keys(bind or {})
        table.sort(names)
        for _, name in ipairs(names) do
            push(items, max, adapter, (name:gsub("^:", "")), KIND_TEXT, "bind parameter")
        end
    elseif context.kind == "columns" then
        local target = context.target
        local columns = db.cached_columns(context.url, target.schema, target.table)
        if not columns then
            db.fetch_columns(context.url, target, noop)
        end
        for _, column in ipairs(columns or {}) do
            local detail = column.type ~= "" and column.type or target.table
            push(items, max, adapter, column.name, KIND_FIELD, detail)
        end
    elseif context.kind == "tables" then
        local tables = db.cached_tables(context.url, context.schema)
        if not tables then
            db.fetch_tables(context.url, context.schema, noop)
        end
        for _, name in ipairs(tables or {}) do
            push(items, max, adapter, name, KIND_MODULE, context.schema or "table")
        end
    else
        local schemas = db.cached_schemas(context.url)
        if not schemas then
            db.fetch_schemas(context.url, noop)
        end
        for _, name in ipairs(schemas or {}) do
            push(items, max, adapter, name, KIND_TEXT, "schema")
        end

        local tables = db.cached_tables(context.url, nil)
        if not tables then
            db.fetch_tables(context.url, nil, noop)
        end
        for _, name in ipairs(tables or {}) do
            push(items, max, adapter, name, KIND_MODULE, "table")
        end
    end

    return items
end

function M.items(bufnr, row, col)
    local context = M.analysis(bufnr, row, col)
    if not context then
        return {}
    end
    return M.items_for(context)
end

function M.enabled()
    if not config.get().completion.enabled then
        return false
    end
    if vim.bo.filetype ~= "sql" then
        return false
    end

    local meta = vim.b.lua_dadbod
    if type(meta) == "table" and (meta.conn or meta.url) then
        return true
    end
    if vim.b.db and vim.b.db ~= "" then
        return true
    end
    if vim.g.db and vim.g.db ~= "" then
        return true
    end
    return vim.env.DATABASE_URL ~= nil and vim.env.DATABASE_URL ~= ""
end

local function omni_kind(kind)
    if kind == KIND_FIELD then
        return "f"
    end
    if kind == KIND_MODULE then
        return "t"
    end
    return "s"
end

function M.omnifunc(findstart, base)
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local col = vim.fn.col(".") - 1

    if findstart == 1 then
        local before = (vim.api.nvim_get_current_line()):sub(1, col)
        local bind = bind_prefix(before)
        if bind then
            return #before - #bind + 1
        end
        local qualifier, word = before:match("([%w_]+)%.([%w_]*)$")
        if qualifier then
            return #before - #word
        end
        local bare = before:match("[%w_]*$") or ""
        return #before - #bare
    end

    local wanted = lower(base)
    local out = {}
    for _, item in ipairs(M.items(bufnr, row, col)) do
        if wanted == "" or lower(item.label):sub(1, #wanted) == wanted then
            out[#out + 1] = {
                word = item.insertText,
                abbr = item.label,
                menu = item.detail or "",
                kind = omni_kind(item.kind),
            }
        end
    end
    return out
end

function M.schedule_prefetch(bufnr)
    local completion = config.get().completion
    if not completion.enabled or not completion.prefetch then
        return
    end
    if prefetch_timers[bufnr] then
        return
    end

    prefetch_timers[bufnr] = vim.defer_fn(function()
        prefetch_timers[bufnr] = nil
        M.prefetch(bufnr)
    end, 300)
end

function M.prefetch(bufnr)
    local completion = config.get().completion
    if not completion.enabled or not completion.prefetch then
        return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local input = db.resolve_buffer(bufnr)
    if not input then
        return
    end

    local parsed, adapter = db.parse(input)
    if not parsed or not adapter then
        return
    end

    local key = url.format(parsed)
    if not key then
        return
    end

    local count = vim.api.nvim_buf_line_count(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(count, 300), false)
    local refs = M.references(table.concat(lines, "\n"), statement.dialect(adapter.name))

    local started = 0
    for _, ref in ipairs(refs) do
        if started >= PREFETCH_LIMIT then
            break
        end
        local schema = ref.schema or adapter.default_schema
        if not db.cached_columns(key, schema, ref.table) then
            db.fetch_columns(key, { schema = schema, table = ref.table }, noop)
            started = started + 1
        end
    end
end

function M.reset()
    memo = {}
    for _, timer in pairs(prefetch_timers) do
        pcall(function()
            timer:stop()
        end)
    end
    prefetch_timers = {}
end

_G.lua_dadbod_omnifunc = function(findstart, base)
    return M.omnifunc(findstart, base)
end

return M

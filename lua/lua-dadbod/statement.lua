local M = {}

function M.dialect(dbms)
    local mysql = dbms == "mysql" or dbms == "mariadb"
    local postgres = dbms == "postgresql" or dbms == "postgres"
    return {
        backslash_escapes = mysql,
        backslash_escapes_e = postgres,
        hash_comments = mysql,
        dollar_quotes = postgres,
        nested_comments = postgres,
    }
end

local function scan(lines, opts)
    local chunks = {}
    local state = "code"
    local block_depth = 0
    local dollar_tag = nil
    local quote_char = nil
    local escapes = false
    local start_line, end_line, has_code, pending_end

    local function flush()
        if start_line and end_line then
            chunks[#chunks + 1] = {
                line1 = start_line,
                line2 = end_line,
                code = has_code == true,
            }
        end
        start_line, end_line, has_code, pending_end = nil, nil, false, false
    end

    for lineno, line in ipairs(lines) do
        if line:find("%S") then
            start_line = start_line or lineno
            end_line = lineno
        end

        local i = 1
        while i <= #line do
            local c = line:sub(i, i)
            local nextc = line:sub(i + 1, i + 1)

            if state == "quote" then
                if c == quote_char then
                    if nextc == quote_char then
                        i = i + 2
                    else
                        state = "code"
                        quote_char = nil
                        i = i + 1
                    end
                elseif escapes and c == "\\" then
                    i = i + 2
                else
                    i = i + 1
                end
            elseif state == "line" then
                break
            elseif state == "block" then
                if c == "*" and nextc == "/" then
                    block_depth = block_depth - 1
                    if block_depth == 0 then
                        state = "code"
                    end
                    i = i + 2
                elseif opts.nested_comments and c == "/" and nextc == "*" then
                    block_depth = block_depth + 1
                    i = i + 2
                else
                    i = i + 1
                end
            elseif state == "dollar" then
                if line:sub(i, i + #dollar_tag - 1) == dollar_tag then
                    i = i + #dollar_tag
                    state = "code"
                    dollar_tag = nil
                else
                    i = i + 1
                end
            elseif c == "-" and nextc == "-" then
                state = "line"
                i = #line + 1
            elseif opts.hash_comments and c == "#" then
                state = "line"
                i = #line + 1
            elseif c == "/" and nextc == "*" then
                state = "block"
                block_depth = 1
                i = i + 2
            elseif c == "'" or c == '"' or c == "`" then
                has_code = true
                state = "quote"
                quote_char = c
                local previous = i > 1 and line:sub(i - 1, i - 1):lower() or ""
                escapes = opts.backslash_escapes or (opts.backslash_escapes_e and previous == "e")
                i = i + 1
            elseif c == "$" and opts.dollar_quotes then
                local tag = line:match("^%$%$", i) or line:match("^%$[%a_][%w_]*%$", i)
                if tag then
                    has_code = true
                    state = "dollar"
                    dollar_tag = tag
                    i = i + #tag
                else
                    i = i + 1
                end
            elseif c == ";" then
                has_code = true
                pending_end = true
                i = i + 1
            else
                if c:find("%S") then
                    has_code = true
                end
                i = i + 1
            end
        end

        if state == "line" then
            state = "code"
        end
        if pending_end then
            flush()
        end
    end

    flush()
    return chunks
end

function M.find(lines, cursor, opts)
    cursor = math.max(1, math.min(cursor or 1, #lines))
    local previous, following

    for _, chunk in ipairs(scan(lines, opts or {})) do
        if chunk.code then
            if cursor >= chunk.line1 and cursor <= chunk.line2 then
                return chunk
            elseif chunk.line2 < cursor then
                previous = chunk
            elseif chunk.line1 > cursor and not following then
                following = chunk
            end
        end
    end

    return previous or following
end

return M

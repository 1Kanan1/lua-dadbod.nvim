local M = {}

local MAX_CELL_WIDTH = 60
local SEPARATOR = "  "

local function display_width(value)
    return vim.fn.strdisplaywidth(value)
end

local function truncate(value, width)
    if display_width(value) <= width then
        return value
    end
    local limit = width - 1
    local used = 0
    local chars = {}
    for index = 0, vim.fn.strchars(value) - 1 do
        local char = vim.fn.strcharpart(value, index, 1)
        local char_width = display_width(char)
        if used + char_width > limit then
            break
        end
        chars[#chars + 1] = char
        used = used + char_width
    end
    return table.concat(chars) .. "…"
end

local function pad(value, width, align)
    local gap = width - display_width(value)
    if gap <= 0 then
        return value
    end
    if align == "right" then
        return string.rep(" ", gap) .. value
    end
    return value .. string.rep(" ", gap)
end

local function clean_cell(value)
    return tostring(value or "")
        :gsub("\r\n", "\\n")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
end

local function trim_end(value)
    return (value:gsub("%s+$", ""))
end

local function parse_csv(text)
    local rows = {}
    local row = {}
    local field = {}
    local quoted = false
    local index = 1
    local length = #text

    while index <= length do
        local char = text:sub(index, index)
        if quoted then
            if char == '"' then
                if text:sub(index + 1, index + 1) == '"' then
                    field[#field + 1] = '"'
                    index = index + 1
                else
                    quoted = false
                end
            else
                field[#field + 1] = char
            end
        elseif char == '"' then
            quoted = true
        elseif char == "," then
            row[#row + 1] = table.concat(field)
            field = {}
        elseif char == "\n" then
            row[#row + 1] = table.concat(field)
            field = {}
            rows[#rows + 1] = row
            row = {}
        elseif char ~= "\r" then
            field[#field + 1] = char
        end
        index = index + 1
    end

    if #field > 0 or #row > 0 then
        row[#row + 1] = table.concat(field)
        rows[#rows + 1] = row
    end
    return rows
end

local function unescape_tsv(value)
    local escapes = {
        n = "\n",
        t = "\t",
        r = "\r",
        ["0"] = "\0",
        Z = "\26",
        b = "\b",
        ["\\"] = "\\",
    }
    return (value:gsub("\\(.)", function(char)
        return escapes[char] or char
    end))
end

local function parse_tsv(text)
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = vim.split(normalized, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end

    local rows = {}
    for _, line in ipairs(lines) do
        local fields = {}
        for field in (line .. "\t"):gmatch("(.-)\t") do
            fields[#fields + 1] = unescape_tsv(field)
        end
        rows[#rows + 1] = fields
    end
    return rows
end

function M.parse(text, format)
    if format == "csv" then
        return parse_csv(text)
    end
    if format == "tsv" then
        return parse_tsv(text)
    end
    return nil
end

function M.table(text, format)
    local rows = M.parse(text, format)
    if not rows or #rows == 0 then
        return nil
    end

    local columns = rows[1]
    if #columns == 0 then
        return nil
    end

    local data = {}
    for index = 2, #rows do
        local row = rows[index]
        if #row ~= #columns then
            return nil
        end
        local repeated = true
        for column = 1, #columns do
            if row[column] ~= columns[column] then
                repeated = false
                break
            end
        end
        if repeated then
            return nil
        end
        data[#data + 1] = row
    end
    return columns, data
end

function M.render(columns, rows)
    local widths = {}
    local numeric = {}

    for index, column in ipairs(columns) do
        widths[index] = math.min(MAX_CELL_WIDTH, display_width(clean_cell(column)))
        numeric[index] = true
    end

    for _, row in ipairs(rows) do
        for index = 1, #columns do
            local value = clean_cell(row[index])
            widths[index] = math.max(widths[index], math.min(MAX_CELL_WIDTH, display_width(value)))
            if value ~= "" and value ~= "NULL" and tonumber(value) == nil then
                numeric[index] = false
            end
        end
    end

    local lines = {}
    local header = {}
    for index, column in ipairs(columns) do
        header[index] = pad(truncate(clean_cell(column), widths[index]), widths[index], "left")
    end
    lines[1] = trim_end(table.concat(header, SEPARATOR))

    if #rows == 0 then
        lines[2] = "(no rows)"
        return lines
    end

    for _, row in ipairs(rows) do
        local cells = {}
        for index = 1, #columns do
            local value = truncate(clean_cell(row[index]), widths[index])
            cells[index] = pad(value, widths[index], numeric[index] and "right" or "left")
        end
        lines[#lines + 1] = trim_end(table.concat(cells, SEPARATOR))
    end
    return lines
end

return M

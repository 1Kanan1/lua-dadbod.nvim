local M = {}

local function decode_component(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function encode_with_safe(value, safe)
    return (tostring(value or ""):gsub("[^%w%-%._~]", function(char)
        if safe and safe:find(char, 1, true) then
            return char
        end
        return string.format("%%%02X", string.byte(char))
    end))
end

function M.decode(value)
    return decode_component(value)
end

function M.decode_query(value)
    return decode_component((tostring(value or ""):gsub("%+", " ")))
end

function M.encode(value)
    return encode_with_safe(value, "")
end

function M.path_encode(value)
    return encode_with_safe(value, "/:@!$&'()*+,;=")
end

function M.fragment_encode(value)
    return encode_with_safe(value, "/?:@!$&'()*+,;=")
end

function M.query_encode(value)
    return (encode_with_safe(value, ""):gsub("%%20", "+"))
end

local function parse_query(query)
    local params = {}
    for item in tostring(query or ""):gmatch("[^&;]+") do
        local key, value = item:match("^([^=]*)=(.*)$")
        if key then
            params[M.decode_query(key)] = M.decode_query(value)
        else
            params[M.decode_query(item)] = true
        end
    end
    return params
end

local function parse_authority(authority, parsed)
    local userinfo, hostport = authority:match("^(.*)@(.*)$")
    if userinfo then
        local user, password = userinfo:match("^([^:]*):(.*)$")
        if user then
            parsed.user = decode_component(user)
            parsed.password = decode_component(password)
        else
            parsed.user = decode_component(userinfo)
        end
    else
        hostport = authority
    end

    if hostport == "" then
        parsed.host = ""
        return true
    end

    if hostport:sub(1, 1) == "[" then
        local host, rest = hostport:match("^%[([^%]]*)%](.*)$")
        if not host then
            return nil, "invalid IPv6 host"
        end
        parsed.host = host
        if rest ~= "" then
            local port = rest:match("^:(%d+)$")
            if not port then
                return nil, "invalid port"
            end
            parsed.port = port
        end
        return true
    end

    local _, colon_count = hostport:gsub(":", "")
    if colon_count > 1 then
        parsed.host = decode_component(hostport)
        return true
    end

    if colon_count == 1 then
        local host, port = hostport:match("^(.-):(.*)$")
        if not port:match("^%d+$") then
            return nil, "invalid port"
        end
        parsed.host = decode_component(host)
        parsed.port = port
        return true
    end

    parsed.host = decode_component(hostport)
    return true
end

function M.parse(value)
    if type(value) ~= "string" then
        return nil, "URL must be a string"
    end
    if value == "" then
        return nil, "URL is empty"
    end

    local fragment
    local hash = value:find("#", 1, true)
    if hash then
        fragment = value:sub(hash + 1)
        value = value:sub(1, hash - 1)
    end

    local query
    local question = value:find("?", 1, true)
    if question then
        query = value:sub(question + 1)
        value = value:sub(1, question - 1)
    end

    local scheme, rest = value:match("^([%a][%w%+%-%.]*):(.*)$")
    if not scheme then
        return nil, "invalid URL: missing scheme"
    end

    local parsed = {
        scheme = scheme:lower(),
    }

    if query ~= nil then
        parsed.params = parse_query(query)
    end
    if fragment ~= nil then
        parsed.fragment = fragment
    end

    if rest:sub(1, 2) == "//" then
        rest = rest:sub(3)
        local authority, path = rest:match("^([^/]*)(.*)$")
        if not authority then
            authority = rest
            path = ""
        end
        local ok, err = parse_authority(authority, parsed)
        if not ok then
            return nil, err
        end
        parsed.path = decode_component(path)
    else
        parsed.opaque = decode_component(rest)
    end

    return parsed
end

function M.format(parsed)
    if type(parsed) == "string" then
        return parsed
    end
    if type(parsed) ~= "table" or type(parsed.scheme) ~= "string" or parsed.scheme == "" then
        return nil, "invalid URL table"
    end

    local parts = { parsed.scheme, ":" }

    if parsed.path ~= nil then
        parts[#parts + 1] = "//"

        if parsed.user ~= nil or parsed.password ~= nil then
            if parsed.user ~= nil then
                parts[#parts + 1] = encode_with_safe(parsed.user, "")
            end
            if parsed.password ~= nil then
                parts[#parts + 1] = ":"
                parts[#parts + 1] = encode_with_safe(parsed.password, "")
            end
            parts[#parts + 1] = "@"
        end

        local host = parsed.host or ""
        if host:find(":", 1, true) then
            parts[#parts + 1] = "[" .. host .. "]"
        else
            parts[#parts + 1] = encode_with_safe(host, ".-_~")
        end

        if parsed.port ~= nil and parsed.port ~= "" then
            parts[#parts + 1] = ":" .. tostring(parsed.port)
        end

        parts[#parts + 1] = M.path_encode(parsed.path)
    else
        parts[#parts + 1] = M.path_encode(parsed.opaque or "")
    end

    if parsed.params and next(parsed.params) then
        local encoded = {}
        local keys = vim.tbl_keys(parsed.params)
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = parsed.params[key]
            if value == true then
                encoded[#encoded + 1] = M.query_encode(key)
            else
                encoded[#encoded + 1] = M.query_encode(key) .. "=" .. M.query_encode(value)
            end
        end
        parts[#parts + 1] = "?" .. table.concat(encoded, "&")
    end

    if parsed.fragment ~= nil then
        parts[#parts + 1] = "#" .. M.fragment_encode(parsed.fragment)
    end

    return table.concat(parts)
end

function M.resolve(value)
    if type(value) ~= "string" then
        return value
    end
    local name = value:match("^%$([%w_]+)$") or value:match("^%${([%w_]+)}$")
    if name then
        return vim.env[name] or ""
    end
    return value
end

function M.canonicalize_file(parsed)
    local raw = parsed.opaque
    if raw == nil then
        raw = parsed.path or ""
    end

    if raw == "" then
        raw = ":memory:"
    end

    if raw ~= ":memory:" then
        raw = vim.fn.expand(raw)
        if raw:sub(1, 1) ~= "/" and not raw:match("^%a:[/\\]") then
            raw = vim.fn.fnamemodify(raw, ":p")
        end
        raw = vim.fs.normalize(raw)
    end

    parsed.opaque = raw
    parsed.path = nil
    parsed.host = nil
    parsed.port = nil
    parsed.user = nil
    parsed.password = nil
    return parsed
end

function M.file_path(parsed)
    local raw = parsed.opaque
    if raw == nil then
        raw = parsed.path or ""
    end
    if raw == "" then
        return ":memory:"
    end
    if raw == ":memory:" then
        return raw
    end

    raw = vim.fn.expand(raw)
    if raw:sub(1, 1) ~= "/" and not raw:match("^%a:[/\\]") then
        raw = vim.fn.fnamemodify(raw, ":p")
    end
    return vim.fs.normalize(raw)
end

function M.display_name(parsed, fallback)
    if type(parsed) ~= "table" then
        return fallback or "default"
    end
    if parsed.opaque == ":memory:" then
        return "memory"
    end
    local value = parsed.opaque or parsed.path
    if value and value ~= "" and value ~= "/" then
        return vim.fs.basename(value)
    end
    if parsed.host and parsed.host ~= "" then
        return parsed.host
    end
    return fallback or "default"
end

function M.absorb(parsed, mapping)
    if not parsed.params then
        return parsed
    end

    for key, field in pairs(mapping) do
        local value = parsed.params[key]
        if value ~= nil then
            parsed.params[key] = nil
            if value == true then
                value = "true"
            end
            if field == "path" then
                parsed.path = "/" .. tostring(value):gsub("^/", "")
                parsed.opaque = nil
            else
                parsed[field] = tostring(value)
            end
        end
    end

    if next(parsed.params) == nil then
        parsed.params = nil
    end

    return parsed
end

function M.safe_format(value)
    if type(value) == "string" then
        value = M.parse(value)
    end
    if type(value) ~= "table" then
        return ""
    end
    local copy = vim.deepcopy(value)
    copy.password = nil
    return M.format(copy)
end

return M

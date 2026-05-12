-- AP/APConfig.lua
-- Loads ap_config.json from the mod directory.
-- Includes a minimal JSON decoder/encoder (no external dependencies).

local APConfig = {}

local DEFAULTS = {
    server = "localhost:38281",
    slot = "",
    password = "",
    game = "Librarian Tidy Up the Arcane Library",
    uuid = "",
    tags = { "AP" },
    items_handling = 7,  -- receive own + others' + starting
}

-- ---------------------------------------------------------------
-- Minimal JSON decoder
-- ---------------------------------------------------------------
local function skip_ws(s, i)
    return s:match("^%s*()", i)
end

local function decode_string(s, i)
    i = i + 1
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1
            local esc = s:sub(i, i)
            if esc == '"' or esc == '\\' or esc == '/' then
                parts[#parts + 1] = esc
            elseif esc == 'n' then parts[#parts + 1] = '\n'
            elseif esc == 't' then parts[#parts + 1] = '\t'
            elseif esc == 'r' then parts[#parts + 1] = '\r'
            else parts[#parts + 1] = esc
            end
        else
            parts[#parts + 1] = c
        end
        i = i + 1
    end
    error("unterminated string")
end

local decode_value

local function decode_array(s, i)
    i = i + 1
    i = skip_ws(s, i)
    local arr = {}
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        local val
        val, i = decode_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then return arr, i + 1 end
        if c == ',' then i = skip_ws(s, i + 1) end
    end
end

local function decode_object(s, i)
    i = i + 1
    i = skip_ws(s, i)
    local obj = {}
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then error("expected string key at " .. i) end
        local key
        key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error("expected ':' at " .. i) end
        i = skip_ws(s, i + 1)
        local val
        val, i = decode_value(s, i)
        obj[key] = val
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then return obj, i + 1 end
        if c == ',' then i = skip_ws(s, i + 1) end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i)
    elseif c == '{' then return decode_object(s, i)
    elseif c == '[' then return decode_array(s, i)
    elseif c == 't' then return true, i + 4
    elseif c == 'f' then return false, i + 5
    elseif c == 'n' then return nil, i + 4
    else
        local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num_str then return tonumber(num_str), i + #num_str end
        error("unexpected character '" .. c .. "' at position " .. i)
    end
end

local function json_decode(s)
    local val, _ = decode_value(s, 1)
    return val
end

-- Exposed for use by other AP modules (e.g., ItemApply loading asset_idx_to_series.json)
APConfig.decode = json_decode

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- ---------------------------------------------------------------
-- Minimal JSON encoder (for save())
-- ---------------------------------------------------------------
local function json_encode_value(val, indent, level)
    local t = type(val)
    if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        level = level or 0
        local pad = indent and string.rep("  ", level + 1) or ""
        local pad_close = indent and string.rep("  ", level) or ""
        local sep = indent and ",\n" or ", "
        local nl = indent and "\n" or ""
        if #val > 0 or next(val) == nil then
            local items = {}
            for _, v in ipairs(val) do
                items[#items + 1] = pad .. json_encode_value(v, indent, level + 1)
            end
            if #items == 0 then return "[]" end
            return "[" .. nl .. table.concat(items, sep) .. nl .. pad_close .. "]"
        else
            local items = {}
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                items[#items + 1] = pad .. '"' .. tostring(k) .. '": ' .. json_encode_value(val[k], indent, level + 1)
            end
            return "{" .. nl .. table.concat(items, sep) .. nl .. pad_close .. "}"
        end
    end
    return "null"
end

local function json_encode(val)
    return json_encode_value(val, true, 0)
end

--- Load config from a JSON file. Falls back to defaults for missing keys.
function APConfig.load(path)
    local config = {}
    local raw = read_file(path)
    if raw and raw ~= "" then
        local ok, parsed = pcall(json_decode, raw)
        if ok and type(parsed) == "table" then
            config = parsed
        else
            print("[APConfig] WARNING: Failed to parse " .. tostring(path) .. ": " .. tostring(parsed))
        end
    else
        print("[APConfig] WARNING: Config not found at " .. tostring(path) .. ", using defaults")
    end
    for k, v in pairs(DEFAULTS) do
        if config[k] == nil then config[k] = v end
    end
    return config
end

--- Persist (server, slot, password) back to ap_config.json.
function APConfig.save(path, server, slot, password)
    local config = {}
    local raw = read_file(path)
    if raw and raw ~= "" then
        local ok, parsed = pcall(json_decode, raw)
        if ok and type(parsed) == "table" then config = parsed end
    end
    config.server = server or config.server or DEFAULTS.server
    config.slot = slot or config.slot or DEFAULTS.slot
    config.password = password or config.password or DEFAULTS.password
    for k, v in pairs(DEFAULTS) do
        if config[k] == nil then config[k] = v end
    end
    local f = io.open(path, "wb")
    if f then
        f:write(json_encode(config) .. "\n")
        f:close()
    else
        print("[APConfig] WARNING: Could not write to " .. tostring(path))
    end
end

return APConfig

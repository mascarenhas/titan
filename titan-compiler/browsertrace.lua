local staticmetadata = require "titan-compiler.staticmetadata"
local incremental = require "titan-compiler.incremental"
local M = {}
local NULL, ARRAY = {}, {}
local LITERALS = { ["null"] = NULL, ["true"] = true, ["false"] = false }
local U32 = 0xffffffff

local function reject(message) error({ browsertrace = message }, 0) end
local function require_value(condition, message)
    if not condition then reject(message) end
end

-- Private source-map JSON reader. Keep the original payload for publication,
-- including unknown extensions; decoded values are used only for validation.
local function json(bytes)
    require_value(type(bytes) == "string", "source map is not a byte string")
    local pos, close = 1
    local function space()
        local _, finish = bytes:find("^[ \t\r\n]*", pos)
        pos = finish + 1
    end
    local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
        b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
    local function string_value()
        pos = pos + 1
        local parts = {}
        while true do
            local start = pos
            pos = bytes:find('["\\%z\1-\31]', pos) or #bytes + 1
            parts[#parts + 1] = bytes:sub(start, pos - 1)
            local char = bytes:sub(pos, pos)
            if char == '"' then
                pos = pos + 1
                local value = table.concat(parts)
                require_value(utf8.len(value), "invalid UTF-8 source-map string")
                return value
            end
            require_value(char == "\\", "unterminated or invalid source-map string")
            local code = bytes:sub(pos + 1, pos + 1)
            if code == "u" then
                local digits = bytes:sub(pos + 2, pos + 5)
                local point = digits:match("^%x%x%x%x$") and tonumber(digits, 16)
                require_value(point, "invalid JSON Unicode escape")
                pos = pos + 6
                if point >= 0xd800 and point <= 0xdbff then
                    local low = bytes:sub(pos, pos + 5):match("^\\u(%x%x%x%x)$")
                    low = low and tonumber(low, 16)
                    require_value(low and low >= 0xdc00 and low <= 0xdfff, "unpaired JSON surrogate")
                    point, pos = 0x10000 + (point - 0xd800) * 1024 + low - 0xdc00, pos + 6
                else
                    require_value(point < 0xdc00 or point > 0xdfff, "unpaired JSON surrogate")
                end
                parts[#parts + 1] = utf8.char(point)
            else
                require_value(escapes[code], "invalid JSON string escape")
                parts[#parts + 1], pos = escapes[code], pos + 2
            end
        end
    end
    local value
    function value(depth)
        require_value(depth <= 256, "source-map JSON nesting is too deep")
        space()
        local char = bytes:sub(pos, pos)
        if char == '"' then return string_value() end
        if char == "{" or char == "[" then
            local object = char == "{"
            local out = object and {} or setmetatable({}, ARRAY)
            local stop = object and "}" or "]"
            pos = pos + 1
            space()
            if bytes:sub(pos, pos) ~= stop then
                while true do
                    local key = #out + 1
                    if object then
                        require_value(bytes:sub(pos, pos) == '"', "expected JSON object key")
                        key = string_value()
                        require_value(out[key] == nil, "duplicate source-map key " .. key)
                        space()
                        require_value(bytes:sub(pos, pos) == ":", "expected JSON ':'")
                        pos = pos + 1
                    end
                    out[key] = value(depth + 1)
                    space()
                    local separator = bytes:sub(pos, pos)
                    if separator == stop then break end
                    require_value(separator == ",", "expected JSON separator")
                    pos = pos + 1
                    space()
                end
            end
            if depth == 0 then close = pos end
            pos = pos + 1
            return out
        end
        for word, result in pairs(LITERALS) do
            if bytes:sub(pos, pos + #word - 1) == word then pos = pos + #word; return result end
        end
        local token = bytes:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        require_value(token and token:match("^%-?%d"), "invalid JSON value")
        local integer, fraction, exponent = token:match("^(%-?%d+)(%.?%d*)([eE]?[+-]?%d*)$")
        require_value(integer and not integer:match("^%-?0%d") and
            (fraction == "" or fraction:match("^%.%d+$")) and
            (exponent == "" or exponent:match("^[eE][+-]?%d+$")), "invalid JSON number")
        local number = tonumber(token)
        require_value(number and number ~= math.huge and number ~= -math.huge, "invalid JSON number")
        pos = pos + #token
        return number
    end
    local root = value(0)
    space()
    require_value(pos == #bytes + 1, "trailing source-map JSON bytes")
    require_value(type(root) == "table" and getmetatable(root) == nil and root ~= NULL,
        "source map must be a JSON object")
    return root, close
end

local base64 = {}
for index = 1, 64 do
    base64[("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):byte(index)] = index - 1
end
local function mappings(map, range)
    local bytes, pos = map.mappings, 1
    local source, line, column, name, generated = 0, 0, 0, 0, 0
    local first
    local function vlq()
        local result, scale = 0, 1
        for _ = 1, 7 do
            local digit = base64[bytes:byte(pos)]
            require_value(digit, "invalid source-map VLQ")
            pos = pos + 1
            result = result + (digit & 31) * scale
            require_value(result <= 2 * U32 + 1, "source-map VLQ overflows")
            if digit < 32 then
                local magnitude = result // 2
                return result % 2 == 0 and magnitude or -magnitude
            end
            scale = scale * 32
        end
        reject("source-map VLQ is too long")
    end
    while pos <= #bytes do
        if bytes:sub(pos, pos) == ";" then
            require_value(not bytes:find("[^;]", pos), "invalid generated source-map line")
            break
        else
            local delta = vlq()
            require_value(delta >= 0 and generated <= U32 - delta, "nonmonotonic or overflowing generated offset")
            generated = generated + delta
            local count, ds, dl, dc, dn = 0
            local next_byte = bytes:byte(pos)
            while next_byte and next_byte ~= 44 and next_byte ~= 59 do
                count = count + 1
                local field = vlq()
                if count == 1 then ds = field
                elseif count == 2 then dl = field
                elseif count == 3 then dc = field
                elseif count == 4 then dn = field
                else reject("invalid source-map segment arity") end
                next_byte = bytes:byte(pos)
            end
            require_value(count == 0 or count == 3 or count == 4, "invalid source-map segment arity")
            if count > 0 then
                source, line, column = source + ds, line + dl, column + dc
                require_value(source >= 0 and source < #map.sources, "source-map source index is out of range")
                require_value(line >= 0 and line < U32 and column >= 0 and column <= U32,
                    "source-map original location is out of range")
                if count == 4 then
                    name = name + dn
                    require_value(name >= 0 and name < #map.names, "source-map name index is out of range")
                end
            end
            if range and generated >= range[1] and generated < range[2] and
                    (not first or generated == first.generated) then
                first = count > 0 and { source = source, line = line, column = column,
                    generated = generated } or nil
            end
            if bytes:sub(pos, pos) == "," then
                pos = pos + 1
                require_value(pos <= #bytes and not bytes:sub(pos, pos):find("[,;]"), "empty source-map segment")
            end
        end
    end
    return first
end

local function validate_map(map, range)
    require_value(map.version == 3, "source-map version must be 3")
    require_value(map.sections == nil, "indexed source maps are unsupported")
    for _, key in ipairs({ "sources", "names" }) do
        require_value(type(map[key]) == "table" and getmetatable(map[key]) == ARRAY,
            "source-map " .. key .. " must be an array")
        for _, text in ipairs(map[key]) do require_value(type(text) == "string", "invalid source-map " .. key .. " entry") end
    end
    require_value(type(map.mappings) == "string", "source-map mappings must be a string")
    for _, key in ipairs({ "file", "sourceRoot" }) do
        require_value(map[key] == nil or type(map[key]) == "string", "invalid source-map " .. key)
    end
    if map.sourcesContent ~= nil then
        require_value(type(map.sourcesContent) == "table" and getmetatable(map.sourcesContent) == ARRAY and
            (#map.sourcesContent == 0 or #map.sourcesContent == #map.sources), "invalid source-map sourcesContent")
        for _, text in ipairs(map.sourcesContent) do
            require_value(text == NULL or type(text) == "string", "invalid source-map sourcesContent entry")
        end
    end
    for _, key in ipairs({ "x_titan_image", "x_titan_function_imports", "x_titan_function_ranges", "x_titan_function_names" }) do
        require_value(map[key] == nil, "source map already contains " .. key)
    end
    return mappings(map, range)
end

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

-- Error-path attribution uses the same validated mapping walk as publication.
-- Select only within this body: a preceding function's mapping is not evidence.
function M.function_source(bytes, range)
    local ok, result = pcall(function()
        local map = json(bytes)
        local first = validate_map(map, range)
        require_value(first, "no mapped source within function body")
        require_value(map.sources[first.source + 1] ~= "", "mapped source filename is empty")
        local location = string.format("%q:%d:%d",
            map.sources[first.source + 1], first.line + 1, first.column + 1)
        if map.sourceRoot and map.sourceRoot ~= "" then
            location = location .. string.format(" (sourceRoot %q)", map.sourceRoot)
        end
        return location
    end)
    if not ok then
        return nil, type(result) == "table" and result.browsertrace or tostring(result)
    end
    return result
end

function M.rewrite(wasm, bytes, identity, origin)
    local ok, result = pcall(function()
        require_value(type(identity) == "string" and #identity == 64 and not identity:find("[^0-9a-f]"),
            "invalid browser trace image identity")
        local image, err = staticmetadata.browser_trace_image(wasm, origin)
        require_value(image, err)
        local map, close = json(bytes)
        validate_map(map)
        local ranges, names = {}, {}
        for index, range in ipairs(image.function_ranges) do
            ranges[index] = "[" .. range[1] .. "," .. range[2] .. "]"
        end
        for index = 1, image.function_count do
            local name = image.function_names[index]
            names[index] = name and quote(name) or "null"
        end
        local fields = '\n"x_titan_image":' .. quote(identity) ..
            ',"x_titan_function_imports":' .. image.function_imports ..
            ',"x_titan_function_ranges":[' .. table.concat(ranges, ",") ..
            '],"x_titan_function_names":[' .. table.concat(names, ",") .. ']\n'
        return bytes:sub(1, close - 1) .. "," .. fields .. bytes:sub(close)
    end)
    if not ok then
        return nil, (origin or "browser trace") .. ": " ..
            (type(result) == "table" and result.browsertrace or tostring(result))
    end
    return result
end

-- The recipe never contains staging paths or the injected identity itself.
function M.identity(context, contents, compile_flags, link_flags, groups)
    local inputs = {}
    for _, group in ipairs(groups) do
        local files = {}
        for _, filename in ipairs(group) do
            files[#files + 1] = { path = require("titan-compiler.linkcertificate").canonical_path(context, filename),
                digest = incremental.file_digest(context, filename) }
        end
        inputs[#inputs + 1] = files
    end
    return incremental.digest(context, "browser-trace-image", {
        entrypoint = contents, target = context.target_descriptor.identity,
        toolchain = require("titan-compiler.browsertarget").export(context.target_descriptor).tools,
        compile_flags = compile_flags, link_flags = link_flags, inputs = inputs,
    })
end

function M.declaration(identity)
    return '\nstatic const char titan_browser_trace_image_id[] = "' .. identity .. '";\n' ..
        'const char *titan_browser_trace_identity(void) {\n' ..
        '    return titan_browser_trace_image_id;\n}\n'
end

return M

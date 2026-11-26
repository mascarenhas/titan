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

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64 = {}
for index = 1, 64 do base64[BASE64:byte(index)] = index - 1 end
-- Validates every segment; `visit(generated, source, line)` sees each one in
-- order, with a nil source for an unmapped segment (0-based indexes).
local function mappings(map, range, visit)
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
            if visit then visit(generated, count > 0 and source or nil, line) end
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

local EXTENSIONS = { "x_titan_image", "x_titan_function_imports", "x_titan_function_ranges",
    "x_titan_function_names" }

-- A standard map, optionally already carrying Titan's extensions.
local function check_map(map, extended)
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
    if not extended then
        for _, key in ipairs(EXTENSIONS) do
            require_value(map[key] == nil, "source map already contains " .. key)
        end
    end
end

local function validate_map(map, range)
    check_map(map)
    return mappings(map, range)
end

-- The runtime trace table, `<stem>.wasm.trace`. A row starts where the
-- location of a defined body's code changes: to a `.titan` source line, or to
-- a gap (an unmapped or non-`.titan` segment, such as inlined C). Each body
-- starts in a gap, the last of several segments at one offset wins, and rows
-- never cross a body boundary, so a lookup that takes the last row at or
-- before an offset in its body sees exactly what the map's segments say there.
-- Implementation notes: doc/implementation/browser-target.md#the-trace-table
local TABLE_MAGIC, TABLE_VERSION, TABLE_BASES, CHUNK = "TTRC", 1, 32767, 4096

-- A little-endian array packed in chunks, so a large image never holds one
-- Lua value per row.
local function packed(format)
    local parts, values, count = {}, {}, 0
    local chunk = "<" .. string.rep(format, CHUNK)
    local array = {}
    function array.add(value)
        count = count + 1
        values[#values + 1] = value
        if #values == CHUNK then
            parts[#parts + 1] = string.pack(chunk, table.unpack(values))
            values = {}
        end
    end
    function array.count() return count end
    function array.bytes()
        parts[#parts + 1] = string.pack("<" .. string.rep(format, #values), table.unpack(values))
        return table.concat(parts)
    end
    return array
end

local function pack(format, values)
    local array = packed(format)
    for _, value in ipairs(values) do array.add(value) end
    return array.bytes()
end

-- `ranges` are the defined bodies, ordered and disjoint; returns the segment
-- visitor and the encoder that completes the table.
local function trace_table(map, ranges)
    local base_index, bases, titan = {}, {}, {}
    for index, path in ipairs(map.sources) do
        titan[index - 1] = path:sub(-6) == ".titan" and path:match("[^/\\]*$")
    end
    -- The basename index of a `.titan` source a body uses, or -1.
    local function base_of(source)
        local name = source and titan[source]
        if not name then return -1 end
        local index = base_index[name]
        if not index then
            require_value(#bases < TABLE_BASES, "too many Titan source names for the trace table")
            bases[#bases + 1] = name
            index = #bases - 1
            base_index[name] = index
        end
        return index
    end
    local pc_deltas, line_deltas, sources = packed("I4"), packed("I4"), packed("i2")
    local first = {}
    for body = 1, #ranges do first[body] = -1 end
    local body, last_pc, last_line = 1, 0, 0
    local state_source, state_line = -1, 0
    -- The last segment seen at `pending_pc`; a later one at the same offset
    -- replaces it before it can name a basename, a row or a declaring file.
    local pending_pc, pending_source, pending_line
    local function flush()
        if not pending_pc then return end
        local base = base_of(pending_source)
        local line = base >= 0 and pending_line + 1 or 0
        if base >= 0 and first[body] < 0 then first[body] = base end
        if base ~= state_source or (base >= 0 and line ~= state_line) then
            -- A gap repeats the previous line, so its delta is zero.
            local row_line = base >= 0 and line or last_line
            pc_deltas.add(pending_pc - last_pc)
            line_deltas.add((row_line - last_line) & U32)
            sources.add(base)
            last_pc, last_line = pending_pc, row_line
            state_source, state_line = base, line
        end
        pending_pc = nil
    end
    local function visit(generated, source, line)
        if pending_pc and generated ~= pending_pc then flush() end
        while ranges[body] and generated >= ranges[body][2] do
            body, state_source, state_line = body + 1, -1, 0
        end
        local range = ranges[body]
        if not range or generated < range[1] then return end
        pending_pc, pending_source, pending_line = generated, source, line
    end
    -- `names[index]` is function `index - 1`'s name, or nil or NULL when it
    -- has none, for `count` functions; both callers read names as UTF-8.
    local function encode(identity, imports, names, count)
        flush()
        require_value(count == imports + #ranges, "trace names do not match the image's functions")
        local strings, offsets, size = {}, {}, 0
        local function add(text)
            offsets[#offsets + 1] = size
            strings[#strings + 1] = text
            size = size + #text
        end
        for _, base in ipairs(bases) do add(base) end
        for index = 1, count do
            local name = names[index]
            add(type(name) == "string" and name or "")
        end
        offsets[#offsets + 1] = size
        local gaps, lengths, previous = {}, {}, 0
        for index, range in ipairs(ranges) do
            gaps[index], lengths[index], previous = range[1] - previous, range[2] - range[1], range[2]
        end
        return TABLE_MAGIC .. string.pack("<I4", TABLE_VERSION) .. identity ..
            string.pack("<I4I4I4I4I4", imports, #ranges, sources.count(), #bases, size) ..
            pack("I4", gaps) .. pack("I4", lengths) .. pc_deltas.bytes() .. line_deltas.bytes() ..
            pack("I4", offsets) .. sources.bytes() .. pack("i2", first) .. table.concat(strings)
    end
    return visit, encode
end

local function valid_identity(identity)
    return type(identity) == "string" and #identity == 64 and not identity:find("[^0-9a-f]")
end

local function quote(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return string.format("\\u%04x", char:byte())
    end) .. '"'
end

-- The final image's `.debug_line` (DWARF v4, from `-gdwarf-4
-- -gline-tables-only` objects that `wasm-opt --debuginfo` kept in step with
-- its code) becomes the standard map; every `.debug_*` section is then cut
-- out byte for byte, so the code keeps the offsets its rows name. A row's
-- address is an offset in the code section's payload. Sequences outside the
-- function bodies are dead functions the linker tombstoned and are dropped.
-- A line 0 row has no source, and a sequence ends just past its last
-- instruction; both become unmapped segments, so neither the map nor the
-- trace table carries the previous line past them.
local WASM_HEADER = "\0asm\1\0\0\0"

local function leb(bytes, pos, limit, signed)
    local value, shift, digit = 0, 0, nil
    repeat
        require_value(pos <= limit, "truncated LEB128 value")
        require_value(shift < 64, "LEB128 value is too long")
        digit = bytes:byte(pos)
        value = value | ((digit & 0x7f) << shift)
        pos, shift = pos + 1, shift + 7
    until digit < 0x80
    if signed and shift < 64 and digit & 0x40 ~= 0 then value = value | (-1 << shift) end
    return value, pos
end

local function fixed(bytes, pos, size, limit)
    require_value(pos + size - 1 <= limit, "truncated .debug_line value")
    return string.unpack("<I" .. size, bytes, pos)
end

local function c_string(bytes, pos, limit)
    local stop = bytes:find("\0", pos, true)
    require_value(stop and stop <= limit, "unterminated .debug_line string")
    return bytes:sub(pos, stop - 1), stop + 1
end

-- The live sequences of `bytes[pos, limit]`, each a flat array of
-- (address, path, line, column) rows, ending in its end address; an unmapped
-- row's path is false. `live` bounds the body addresses. A sequence whose
-- addresses go backwards is not a DWARF sequence and describes nothing.
local function line_sequences(bytes, pos, limit, live)
    local sequences = {}
    while pos <= limit do
        local length, version, header_length
        length, pos = fixed(bytes, pos, 4, limit)
        require_value(length < 0xfffffff0, "64-bit DWARF .debug_line is unsupported")
        local stop = pos + length - 1
        require_value(stop <= limit, "truncated .debug_line unit")
        version, pos = fixed(bytes, pos, 2, stop)
        require_value(version == 4, "expected DWARF v4 .debug_line, found version " .. version)
        header_length, pos = fixed(bytes, pos, 4, stop)
        local program = pos + header_length
        require_value(program - 1 <= stop and pos + 5 < program, "truncated .debug_line header")
        local min_length, max_ops, _, line_base, line_range, opcode_base =
            string.unpack("<BBBbBB", bytes, pos)
        require_value(max_ops == 1 and line_range > 0 and opcode_base > 0 and pos + 5 + opcode_base <= program,
            "unsupported .debug_line header")
        local lengths = { bytes:byte(pos + 6, pos + 4 + opcode_base) }
        pos = pos + 5 + opcode_base
        local directories, files = { [0] = "" }, {}
        while true do
            local directory
            directory, pos = c_string(bytes, pos, program - 1)
            if directory == "" then break end
            directories[#directories + 1] = directory
        end
        local function entry(name, at, finish)
            local index
            index, at = leb(bytes, at, finish)
            local directory = directories[index]
            require_value(directory, "invalid .debug_line directory index")
            at = select(2, leb(bytes, select(2, leb(bytes, at, finish)), finish))
            if directory ~= "" and not name:match("^[/\\]") and not name:match("^%a:[/\\]") then
                name = directory .. "/" .. name
            end
            files[#files + 1] = name
            return at
        end
        while true do
            local name
            name, pos = c_string(bytes, pos, program - 1)
            if name == "" then break end
            pos = entry(name, pos, program - 1)
        end
        pos = program
        local address, file, line, column, rows, backwards = 0, 1, 1, 0, {}, false
        local function row()
            local path = line > 0 and files[file]
            require_value(path or line <= 0, "a .debug_line row names an undefined file")
            backwards = backwards or #rows > 0 and address < rows[#rows - 3]
            rows[#rows + 1], rows[#rows + 2], rows[#rows + 3], rows[#rows + 4] = address, path, line, column
        end
        while pos <= stop do
            local op = bytes:byte(pos)
            pos = pos + 1
            if op >= opcode_base then
                local adjusted = op - opcode_base
                address = address + adjusted // line_range * min_length
                line = line + line_base + adjusted % line_range
                row()
            elseif op == 0 then
                local size
                size, pos = leb(bytes, pos, stop)
                local finish = pos + size - 1
                require_value(size > 0 and finish <= stop, "truncated .debug_line extended opcode")
                local sub = bytes:byte(pos)
                if sub == 1 then
                    if #rows > 0 and rows[1] >= live[1] and address <= live[2] then
                        line = 0
                        row()
                        if not backwards then sequences[#sequences + 1] = rows end
                    end
                    address, file, line, column, rows, backwards = 0, 1, 1, 0, {}, false
                elseif sub == 2 then
                    require_value(size <= 9, "invalid .debug_line address size")
                    address = fixed(bytes, pos + 1, size - 1, finish)
                elseif sub == 3 then
                    local name, at = c_string(bytes, pos + 1, finish)
                    entry(name, at, finish)
                end
                pos = finish + 1
            elseif op == 1 then
                row()
            elseif op == 2 then
                local delta
                delta, pos = leb(bytes, pos, stop)
                address = address + delta * min_length
            elseif op == 3 then
                local delta
                delta, pos = leb(bytes, pos, stop, true)
                line = line + delta
            elseif op == 4 then
                file, pos = leb(bytes, pos, stop)
            elseif op == 5 then
                column, pos = leb(bytes, pos, stop)
            elseif op == 8 then
                address = address + (255 - opcode_base) // line_range * min_length
            elseif op == 9 then
                local delta
                delta, pos = fixed(bytes, pos, 2, stop)
                address = address + delta
            else
                -- Flag opcodes take no operands; others declare their ULEB operands.
                for _ = 1, lengths[op] do pos = select(2, leb(bytes, pos, stop)) end
            end
        end
        require_value(#rows == 0, "unterminated .debug_line sequence")
    end
    return sequences
end

local function vlq(value)
    value = value < 0 and (-value << 1 | 1) or value << 1
    local digits = {}
    repeat
        local digit = value & 31
        value = value >> 5
        if value > 0 then digit = digit | 32 end
        digits[#digits + 1] = BASE64:sub(digit + 1, digit + 1)
    until value == 0
    return table.concat(digits)
end

local function uleb(value)
    local digits = {}
    repeat
        local digit = value & 0x7f
        value = value >> 7
        digits[#digits + 1] = string.char(value > 0 and digit | 0x80 or digit)
    until value == 0
    return table.concat(digits)
end

-- Sequences in address order, without any two that overlap. wasm-ld's
-- `--wrap` resolves the wrapped definition's own line-table relocation to
-- the wrapper, so that sequence lands inside the wrapper's body on top of
-- the wrapper's own one. A body's own sequence ends exactly at the body's
-- end; where sequences overlap, only such an owner survives, and only when
-- it is the one owner of its body. The rest of an overlap cannot be
-- attributed and stays unmapped. A sequence that overlaps nothing is kept
-- even when it ends inside its body (optimized images have those).
local function disjoint(sequences, bodies)
    local function finish(rows) return rows[#rows - 3] end
    table.sort(sequences, function(left, right)
        return left[1] < right[1] or left[1] == right[1] and finish(left) < finish(right)
    end)
    local function owned(rows)
        local first, last = 1, #bodies
        while first <= last do
            local middle = (first + last) // 2
            local body = bodies[middle]
            if rows[1] < body[1] then last = middle - 1
            elseif rows[1] >= body[2] then first = middle + 1
            else return finish(rows) == body[2] and middle or nil end
        end
    end
    local kept, index = {}, 1
    while index <= #sequences do
        local stop, reach = index, finish(sequences[index])
        while sequences[stop + 1] and sequences[stop + 1][1] < reach do
            stop = stop + 1
            reach = math.max(reach, finish(sequences[stop]))
        end
        if stop == index then
            kept[#kept + 1] = sequences[index]
        else
            local owners, count = {}, {}
            for at = index, stop do
                local body = owned(sequences[at])
                if body then
                    owners[#owners + 1] = { sequences[at], body }
                    count[body] = (count[body] or 0) + 1
                end
            end
            for _, owner in ipairs(owners) do
                if count[owner[2]] == 1 then kept[#kept + 1] = owner[1] end
            end
        end
        index = stop + 1
    end
    return kept
end

-- Returns the image without its `.debug_*` sections, ending in a
-- `sourceMappingURL` section that names `map_name` (relative to the image),
-- and the source map of its line table, with offsets in that image.
function M.dwarf_map(wasm, map_name, origin)
    local ok, image, map = pcall(function()
        require_value(type(wasm) == "string" and wasm:sub(1, 8) == WASM_HEADER, "invalid Wasm header")
        local kept, removed, limit, pos = { WASM_HEADER }, 0, #wasm, 9
        local code_offset, live, bodies, line_start, line_limit
        while pos <= limit do
            local id = wasm:byte(pos)
            local size, start = leb(wasm, pos + 1, limit)
            local finish = start + size - 1
            require_value(finish <= limit, "truncated Wasm section")
            local name, payload
            if id == 0 then
                local length
                length, payload = leb(wasm, start, finish)
                require_value(payload + length - 1 <= finish, "truncated Wasm custom section name")
                name = wasm:sub(payload, payload + length - 1)
                payload = payload + length
            end
            if name and (name:sub(1, 7) == ".debug_" or name == "sourceMappingURL") then
                if name == ".debug_line" then
                    require_value(not line_start, "duplicate .debug_line section")
                    line_start, line_limit = payload, finish
                end
                removed = removed + finish - pos + 1
            else
                if id == 10 then
                    -- Body bounds in .debug_line addresses: offsets from the
                    -- code section's payload.
                    code_offset = start - 1 - removed
                    local count, at = leb(wasm, start, finish)
                    bodies = {}
                    for index = 1, count do
                        local length
                        length, at = leb(wasm, at, finish)
                        require_value(at + length - 1 <= finish, "truncated Wasm function body")
                        bodies[index] = { at - start, at - start + length }
                        at = at + length
                    end
                    live = { bodies[1] and bodies[1][1] or size, size }
                end
                kept[#kept + 1] = wasm:sub(pos, finish)
            end
            pos = finish + 1
        end
        require_value(code_offset, "Wasm image has no code section")
        require_value(line_start, "Wasm image has no .debug_line section")
        local sequences = disjoint(line_sequences(wasm, line_start, line_limit, live), bodies)
        local sources, indexes, segments = {}, {}, {}
        local generated, source, line, column = 0, 0, 0, 0
        for _, rows in ipairs(sequences) do
            for index = 1, #rows, 4 do
                local path = rows[index + 1]
                local next_generated = code_offset + rows[index]
                local segment = vlq(next_generated - generated)
                if path then
                    local next_source = indexes[path]
                    if not next_source then
                        sources[#sources + 1] = quote(path)
                        next_source = #sources - 1
                        indexes[path] = next_source
                    end
                    local next_line, next_column = rows[index + 2] - 1, math.max(rows[index + 3], 1) - 1
                    segment = segment .. vlq(next_source - source) .. vlq(next_line - line) ..
                        vlq(next_column - column)
                    source, line, column = next_source, next_line, next_column
                end
                segments[#segments + 1] = segment
                generated = next_generated
            end
        end
        local url = uleb(#"sourceMappingURL") .. "sourceMappingURL" .. uleb(#map_name) .. map_name
        kept[#kept + 1] = "\0" .. uleb(#url) .. url
        return table.concat(kept), '{"version":3,"sources":[' .. table.concat(sources, ",") ..
            '],"names":[],"mappings":"' .. table.concat(segments, ",") .. '"}'
    end)
    if not ok then
        return nil, (origin or "browser trace") .. ": " ..
            (type(image) == "table" and image.browsertrace or tostring(image))
    end
    return image, map
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

-- Returns the final map, with the Titan extensions that bind it to `wasm`,
-- and the runtime trace table derived from the same segment walk.
function M.rewrite(wasm, bytes, identity, origin)
    local ok, result, trace = pcall(function()
        require_value(valid_identity(identity), "invalid browser trace image identity")
        local image, err = staticmetadata.browser_trace_image(wasm, origin)
        require_value(image, err)
        local map, close = json(bytes)
        check_map(map)
        local visit, encode = trace_table(map, image.function_ranges)
        mappings(map, nil, visit)
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
        return bytes:sub(1, close - 1) .. "," .. fields .. bytes:sub(close),
            encode(identity, image.function_imports, image.function_names, image.function_count)
    end)
    if not ok then
        return nil, (origin or "browser trace") .. ": " ..
            (type(result) == "table" and result.browsertrace or tostring(result))
    end
    return result, trace
end

-- The trace table of a final map that already carries the Titan extensions,
-- as `rewrite` produced it.
function M.trace_table(bytes)
    local ok, result = pcall(function()
        local map = json(bytes)
        check_map(map, true)
        local identity, imports = map.x_titan_image, map.x_titan_function_imports
        local ranges, names = map.x_titan_function_ranges, map.x_titan_function_names
        require_value(valid_identity(identity), "invalid x_titan_image")
        require_value(math.type(imports) == "integer" and imports >= 0 and imports <= U32,
            "invalid x_titan_function_imports")
        require_value(type(ranges) == "table" and getmetatable(ranges) == ARRAY, "invalid x_titan_function_ranges")
        local previous = 0
        for _, range in ipairs(ranges) do
            require_value(type(range) == "table" and getmetatable(range) == ARRAY and #range == 2 and
                math.type(range[1]) == "integer" and math.type(range[2]) == "integer" and
                range[1] >= previous and range[1] < range[2] and range[2] <= U32,
                "invalid x_titan_function_ranges entry")
            previous = range[2]
        end
        require_value(type(names) == "table" and getmetatable(names) == ARRAY, "invalid x_titan_function_names")
        local count = #names
        for index = 1, count do
            require_value(names[index] == NULL or type(names[index]) == "string", "invalid x_titan_function_names entry")
        end
        local visit, encode = trace_table(map, ranges)
        mappings(map, nil, visit)
        return encode(identity, imports, names, count)
    end)
    if not ok then return nil, type(result) == "table" and result.browsertrace or tostring(result) end
    return result
end

-- The recipe never contains staging paths or the injected identity itself.
-- The compiler, linker and optimizer that make the image count by their
-- bytes, not only by their paths and version banners.
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
    local tools = require("titan-compiler.browsertarget").export(context.target_descriptor).tools
    return incremental.digest(context, "browser-trace-image", {
        entrypoint = contents, target = context.target_descriptor.identity, toolchain = tools,
        executables = { incremental.file_digest(context, tools.cc[1]),
            incremental.file_digest(context, tools.ld[1]),
            (incremental.file_digest(context, tools.optimizer.argv[1])) },
        compile_flags = compile_flags, link_flags = link_flags, inputs = inputs,
    })
end

function M.declaration(identity)
    return '\nstatic const char titan_browser_trace_image_id[] = "' .. identity .. '";\n' ..
        'TITAN_WASM_EXPORT("titan_browser_trace_identity")\n' ..
        'const char *titan_browser_trace_identity(void) {\n' ..
        '    return titan_browser_trace_image_id;\n}\n'
end

return M

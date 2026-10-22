-- Coverage source ownership is carried through C formatting as reserved line
-- comments. Only this final pass turns it into preprocessor line controls.
-- util.render deliberately knows nothing about C locations.
local coverage_lines = {}

local PREFIX = "// TITAN_COVERAGE_"
coverage_lines.comment_pragma = "^ TITAN_COVERAGE_"
local TRIGRAPHS = { ["="] = "#", ["/"] = "\\", ["'"] = "^",
    ["("] = "[", [")"] = "]", ["!"] = "|", ["<"] = "{",
    [">"] = "}", ["-"] = "~" }

local function valid_line(line)
    return type(line) == "number" and line % 1 == 0
        and line > 0 and line <= 2147483647
end

local function hex_encode(value)
    return (value:gsub(".", function(byte)
        return string.format("%02x", string.byte(byte))
    end))
end

local function hex_decode(value)
    if value == "" or #value % 2 ~= 0 or value:find("[^0-9a-f]") then
        return nil
    end
    return (value:gsub("..", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

local function valid_filename(filename)
    return type(filename) == "string" and filename ~= ""
        and not filename:find("[%z\r\n]")
end

-- Filenames need C preprocessing string escaping, without util.render's
-- special treatment of dollar signs. Fixed-width octal keeps arbitrary bytes
-- independent of the C source encoding.
local function quoted_filename(filename)
    return '"' .. filename:gsub(".", function(byte)
        if byte == "\\" then return "\\\\" end
        if byte == '"' then return '\\"' end
        if byte == "?" then return "\\077" end
        local number = string.byte(byte)
        if number < 32 or number >= 127 then
            return string.format("\\%03o", number)
        end
        return byte
    end) .. '"'
end

function coverage_lines.begin(kind, filename, line)
    assert(kind == "source" or kind == "authored" or kind == "generated",
        "invalid coverage region kind")
    if kind == "generated" then return PREFIX .. "BEGIN generated\n" end
    assert(valid_filename(filename), "invalid coverage source filename")
    assert(valid_line(line), "invalid coverage source line")
    return PREFIX .. "BEGIN " .. kind .. " " .. tostring(line)
        .. " " .. hex_encode(filename) .. "\n"
end

function coverage_lines.finish()
    return PREFIX .. "END\n"
end

function coverage_lines.region(code, kind, filename, line)
    if code == "" then return code end
    -- Leading/trailing newlines guarantee standalone marker comments even
    -- when the enclosing renderer substitutes this fragment after other text.
    return "\n" .. coverage_lines.begin(kind, filename, line) .. code
        .. "\n" .. coverage_lines.finish()
end

local function parse_marker(line)
    local marker = line:match("^[ \t]*// (TITAN_COVERAGE_[^\r\n]*)[ \t]*\r?$")
    if not marker then return nil end
    marker = marker:gsub("[ \t]+$", "")
    if marker == "TITAN_COVERAGE_END" then return { ending = true } end
    if marker == "TITAN_COVERAGE_BEGIN generated" then
        return { kind = "generated" }
    end
    local kind, number, encoded = marker:match(
        "^TITAN_COVERAGE_BEGIN (%a+) (%d+) ([0-9a-f]+)$")
    local filename = encoded and hex_decode(encoded)
    local anchor = tonumber(number)
    if (kind ~= "source" and kind ~= "authored")
        or not valid_line(anchor) or not valid_filename(filename) then
        return false
    end
    return { kind = kind, filename = filename, line = anchor }
end

-- Inspect one physical line after phase-2 backslash/newline splicing. State
-- survives physical newlines inside block comments and continued literals;
-- a line comment survives only a splice. Directives/macros are logical lines,
-- so no line control can be inserted in one of their continued pieces.
local function scan_line(line, state)
    local limit = #line
    local i = 1
    while i <= limit do
        local byte, next_byte = line:sub(i, i), line:sub(i + 1, i + 1)
        if state.mode == "block" then
            if byte == "*" and next_byte == "/" then
                state.mode = nil
                i = i + 2
            else
                i = i + 1
            end
        elseif state.mode == "line" then
            break
        elseif state.mode == '"' or state.mode == "'" then
            if state.escape then
                state.escape = false
            elseif byte == "\\" then
                state.escape = true
            elseif byte == state.mode then
                state.mode = nil
            end
            i = i + 1
        elseif byte == "/" and next_byte == "*" then
            state.mode = "block"
            i = i + 2
        elseif byte == "/" and next_byte == "/" then
            state.mode = "line"
            break
        elseif byte == '"' or byte == "'" then
            state.mode = byte
            state.escape = false
            i = i + 1
        else
            i = i + 1
        end
    end
    if state.mode == "line" then state.mode = nil end
    if state.mode == '"' or state.mode == "'" then
        return nil, "unescaped newline in C literal"
    end
    state.escape = false
    return true
end

local function authored_directive(line, region)
    line = line:gsub("^([ \t]*)%%:", "%1#")
    local number, tail = line:match("^[ \t]*#[ \t]*line[ \t]+(%d+)(.*)$")
    if not number then
        number, tail = line:match("^[ \t]*#[ \t]*(%d+)(.*)$")
    end
    if not number or not valid_line(tonumber(number)) then return end
    local quoted = tail:match('^[ \t]+(".*")[ \t]*$')
    if quoted then
        local bytes, offset = {}, 2
        while offset < #quoted do
            local byte = quoted:sub(offset, offset)
            if byte == "\\" then
                local octal = quoted:sub(offset + 1):match("^([0-7][0-7]?[0-7]?)")
                if octal then
                    bytes[#bytes + 1] = string.char(tonumber(octal, 8))
                    offset = offset + 1 + #octal
                else
                    bytes[#bytes + 1] = quoted:sub(offset + 1, offset + 1)
                    offset = offset + 2
                end
            elseif byte == '"' then
                return
            else
                bytes[#bytes + 1] = byte
                offset = offset + 1
            end
        end
        local filename = table.concat(bytes)
        if not valid_filename(filename) then return end
        region.filename = filename
    elseif not tail:match("^[ \t]*$") then
        return
    end
    region.line = tonumber(number)
    return true
end

local function directive_prefix(line, initial_mode)
    local offset, in_comment = 1, initial_mode == "block"
    while offset <= #line do
        if in_comment then
            local close = line:find("*/", offset, true)
            if not close then return nil end
            offset, in_comment = close + 2, false
        else
            local _, whitespace = line:find("^[ \t]*", offset)
            offset = (whitespace or offset - 1) + 1
            if line:sub(offset, offset + 1) == "/*" then
                offset, in_comment = offset + 2, true
            else
                local remainder = line:sub(offset)
                if remainder:match("^#") or remainder:match("^%%:") then
                    return remainder
                end
                return nil
            end
        end
    end
end

-- Implementation notes: doc/implementation/native-coverage.md#source-attribution
-- A pass over physical lines, with lexical state across them. Source regions
-- freeze one Titan anchor; authored C regions advance by their original
-- physical lines. The initial/generated region always names the final C file.
-- Marker lines are metadata, not authored lines. Nested regions suspend their
-- parent and restore it on END, including its authored-line cursor.
function coverage_lines.convert(contents, generated_filename)
    if type(contents) ~= "string" or not valid_filename(generated_filename) then
        return nil, "invalid coverage conversion input"
    end
    local output, output_lines, anchors = {}, 0, {}
    local state = { mode = nil, continued = false, escape = false, pending = "" }
    local stack = { { kind = "generated" } }
    local physical_line, offset = 0, 1
    local function append(text)
        output[#output + 1] = text
        local _, count = text:gsub("\n", "")
        output_lines = output_lines + count
    end
    local function failure(message)
        return nil, "coverage source regions at C line "
            .. tostring(physical_line) .. ": " .. message
    end
    while offset <= #contents do
        physical_line = physical_line + 1
        local newline = contents:find("\n", offset, true)
        local last = newline and newline - 1 or #contents
        local line = contents:sub(offset, last)
        local lexical_line = line:gsub("\r$", "")
        -- C99 phase 1 precedes escaped-newline splicing. Generated literals
        -- escape question marks; authored C can still use these spellings.
        local logical_line = lexical_line:gsub("%?%?([=/'()!<>%-])", TRIGRAPHS)
        local safe = state.mode == nil and not state.continued
        local marker
        if safe then marker = parse_marker(line) end
        if marker == false then return failure("malformed reserved marker") end
        if marker then
            if marker.ending then
                if #stack == 1 then return failure("unmatched region end") end
                stack[#stack] = nil
            else
                stack[#stack + 1] = marker
                if marker.kind == "source" then
                    anchors[marker.filename] = anchors[marker.filename] or {}
                    anchors[marker.filename][marker.line] = true
                end
            end
        else
            local region = stack[#stack]
            local directive = safe and directive_prefix(logical_line, state.mode)
            local suffix_at
            -- A block comment may finish before executable C on this physical
            -- line. Split only after its closing token, never inside it, so
            -- comment length cannot advance that executable code's anchor.
            if state.mode == "block" and not state.continued then
                local close = lexical_line:find("*/", 1, true)
                if close and lexical_line:sub(close + 2):find("[^ \t]") then
                    suffix_at = close + 2
                end
            end
            if suffix_at then
                append(line:sub(1, suffix_at - 1) .. "\n")
                local filename = region.filename or generated_filename
                local anchor = region.kind == "generated"
                    and output_lines + 2 or region.line
                append("#line " .. tostring(anchor) .. " "
                    .. quoted_filename(filename) .. "\n")
                append(line:sub(suffix_at) .. (newline and "\n" or ""))
            else
                if safe and not directive and lexical_line:find("[^ \t]") then
                    local filename = region.filename or generated_filename
                    local anchor = region.kind == "generated"
                        and output_lines + 2 or region.line
                    append("#line " .. tostring(anchor) .. " "
                        .. quoted_filename(filename) .. "\n")
                end
                append(line .. (newline and "\n" or ""))
            end
            local spliced = newline ~= nil and logical_line:sub(-1) == "\\"
            local authored_control = not spliced
                and directive_prefix(state.pending .. logical_line, state.mode)
            if region.kind == "authored" and not
                (authored_control and authored_directive(authored_control, region)) then
                region.line = region.line + 1
            end
            if spliced then
                state.pending = state.pending .. logical_line:sub(1, -2)
            else
                local scanned, err = scan_line(state.pending .. logical_line, state)
                state.pending = ""
                if not scanned then return failure(err) end
            end
            state.continued = spliced
        end
        offset = newline and newline + 1 or #contents + 1
    end
    if #stack ~= 1 then return failure("unterminated source region") end
    if state.mode == "block" then return failure("unterminated C comment") end
    if state.mode == '"' or state.mode == "'" then
        return failure("unterminated C literal")
    end
    if state.continued then return failure("unterminated continued C line") end
    return table.concat(output), nil, anchors
end

return coverage_lines

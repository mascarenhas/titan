local assert = require "luassert"
local trace = require "titan-compiler.browsertrace"
local metadata = require "titan-compiler.staticmetadata"
local browserlink = require "titan-compiler.browserlink"
local compiler_io = require "titan-compiler.io"
local paths = require "titan-compiler.path"
local fixtures = require "spec.support.browser_fixtures"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local ID = string.rep("a", 64)
local HEADER = "\0asm\1\0\0\0"
local MAP = '{"version":3,"sources":["selected.browser.titan"],"names":["run"],"mappings":"AAAAA,E","x_other":{"keep":[null,true,false,1.25e+2]}}\n'
local function leb(value)
    local out = {}
    repeat
        local digit = value & 127; value = value >> 7
        out[#out + 1] = string.char(digit | (value > 0 and 128 or 0))
    until value == 0
    return table.concat(out)
end
local function text(value) return leb(#value) .. value end
local function section(id, value) return string.char(id) .. leb(#value) .. value end
local FUNCTIONS = section(3, "\2\0\0")
local CODE = section(10, "\2\2\0\11\3\0\1\11")
local function names(payload) return section(0, text("name") .. section(1, payload)) end
local function image(extra)
    return HEADER .. FUNCTIONS .. CODE .. (extra or "")
end
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function vlq(value)
    value = value < 0 and -value * 2 + 1 or value * 2
    local out = {}
    repeat
        local digit = value & 31
        value = value >> 5
        if value > 0 then digit = digit | 32 end
        out[#out + 1] = alphabet:sub(digit + 1, digit + 1)
    until value == 0
    return table.concat(out)
end
local function rejected(wasm, map, fragment, id)
    local result, err = trace.rewrite(wasm, map, id or ID, "fixture.wasm.map")
    assert.is_nil(result)
    assert.is_string(err)
    assert.truthy(err:find(fragment, 1, true), err)
end

describe("browser final trace map", function()
    it("preserves the complete standard map and optional extensions while adding final body bounds", function()
        local wasm = image(names("\2\0" .. text("module_ℳ_run_titan") .. "\1" .. text('quoted"name')))
        local result = assert(trace.rewrite(wasm, MAP, ID))
        assert.equal(MAP:sub(1, -3), result:sub(1, #MAP - 2))
        local start = #HEADER + #FUNCTIONS + 4
        assert.truthy(result:find('"x_titan_image":"' .. ID .. '"', 1, true))
        assert.truthy(result:find('"x_titan_function_imports":0', 1, true))
        assert.truthy(result:find('"x_titan_function_ranges":[[' .. start .. ',' .. start + 2 .. '],[' .. start + 3 .. ',' .. start + 6 .. ']]', 1, true))
        assert.truthy(result:find('"x_titan_function_names":["module_ℳ_run_titan","quoted\\u0022name"]', 1, true))
        rejected(wasm, result, "already contains x_titan_image")
    end)

    it("counts only function imports, indexes names imports-first and records import signatures", function()
        local types = section(1, "\2\96\0\0\96\2\127\126\1\124")
        local imports = section(2, "\6" .. text("env") .. text("left") .. "\0\1" ..
            text("env") .. text("memory") .. "\2\1\1\2" ..
            text("env") .. text("table") .. "\1\112\0\1" ..
            text("env") .. text("global") .. "\3\127\0" ..
            text("env") .. text("tag") .. "\4\0\0" ..
            text("env") .. text("right") .. "\0\0")
        local wasm = HEADER .. types .. imports .. FUNCTIONS .. CODE .. names("\2\1" .. text("imported") .. "\3" .. text("defined"))
        local parsed = assert(metadata.browser_trace_image(wasm))
        assert.equal(2, parsed.function_imports)
        assert.equal(4, parsed.function_count)
        assert.equal(6, #parsed.imports)
        local signatures = {}
        for index, import in ipairs(parsed.imports) do signatures[index] = import.signature or false end
        assert.same({ "(i32,i64)->(f64)", false, false, false, "()->()", "()->()" }, signatures)
        assert.equal("imported", parsed.function_names[2])
        assert.equal("defined", parsed.function_names[4])
        local result = assert(trace.rewrite(wasm, MAP, ID))
        assert.truthy(result:find('"x_titan_function_names":[null,"imported",null,"defined"]', 1, true))
    end)

    it("accepts bounded padded LEBs and skips optional sections and name subsections", function()
        local padded = HEADER .. "\3\135\128\128\128\0\130\128\128\128\0\0\0" .. CODE ..
            section(0, text("optional") .. "opaque") ..
            section(0, text("name") .. section(9, "opaque") .. section(1, "\0"))
        assert(trace.rewrite(padded, MAP, ID))
        assert(trace.rewrite(HEADER, '{"version":3,"sources":[],"names":[],"mappings":""}', ID))
    end)

    it("reads exports through the same bounded final-image walk", function()
        local wasm = HEADER .. section(1, "\1\96\7\127\126\125\124\123\112\111\0") ..
            section(2, "\1" .. text("env") .. text("input") .. "\0\0") ..
            section(7, "\1" .. text("exported") .. "\0\0")
        local parsed = assert(metadata.browser_trace_image(wasm))
        assert.same({ { module = "env", name = "input", kind = 0,
            signature = "(i32,i64,f32,f64,v128,funcref,externref)->()" } }, parsed.imports)
        assert.same({ { name = "exported", kind = 0, index = 0 } }, parsed.exports)
    end)

    local bad_wasm = {
        { "header", "other", "Wasm header" },
        { "version", "\0asm\2\0\0\0", "header" },
        { "section body", HEADER .. "\3\5\0", "outside the input" },
        { "LEB truncation", HEADER .. "\3\128", "truncated Wasm u32" },
        { "LEB overflow", HEADER .. "\3\255\255\255\255\16", "overflows" },
        { "LEB too long", HEADER .. "\3\128\128\128\128\128\0", "exceeds 5 bytes" },
        { "duplicate section", image() .. CODE, "duplicate" },
        { "section ordering", HEADER .. CODE .. FUNCTIONS, "out-of-order" },
        { "unknown section", HEADER .. section(14, ""), "unsupported" },
        { "code count mismatch", HEADER .. FUNCTIONS, "counts disagree" },
        { "function count mismatch", HEADER .. section(3, "\1\0") .. CODE, "counts disagree" },
        { "empty body", HEADER .. section(3, "\1\0") .. section(10, "\1\0"), "body range" },
        { "body overrun", HEADER .. section(3, "\1\0") .. section(10, "\1\5\0"), "body range" },
        { "section count", HEADER .. section(3, "\127"), "section count" },
        { "trailing function bytes", HEADER .. section(3, "\0\0"), "trailing" },
        { "duplicate names", image(names("\0") .. names("\0")), "duplicate Wasm name" },
        { "duplicate name subsection", image(section(0, text("name") .. section(1, "\0") .. section(1, "\0"))), "duplicate Wasm function name subsection" },
        { "name index", image(names("\1\2" .. text("outside"))), "out of range" },
        { "duplicate name index", image(names("\2\0" .. text("first") .. "\0" .. text("second"))), "duplicate Wasm function name index" },
        { "name UTF8", image(names("\1\0" .. text("\255"))), "UTF-8" },
        { "name overrun", image(names("\1\0\127x")), "outside its section" },
        { "name count", image(names("\127")), "name count" },
        { "name trailing bytes", image(names("\0\0")), "trailing Wasm function name" },
        { "subsection overrun", image(section(0, text("name") .. "\1\127")), "subsection is outside" },
        { "import kind", HEADER .. section(2, "\1" .. text("env") .. text("x") .. "\9"), "import kind" },
        { "missing import kind", HEADER .. section(2, "\1" .. text("env") .. text("x")), "truncated Wasm import kind" },
        { "missing import type", HEADER .. section(2, "\1" .. text("env") .. text("x") .. "\1"), "truncated Wasm import type" },
        { "memory limits", HEADER .. section(2, "\1" .. text("env") .. text("x") .. "\2\4\1"), "limits" },
        { "global mutability", HEADER .. section(2, "\1" .. text("env") .. text("x") .. "\3\127\2"), "mutability" },
        { "type form", HEADER .. section(1, "\1\94\0\0"), "unsupported final Wasm type form" },
        { "value type", HEADER .. section(1, "\1\96\1\99\0"), "unsupported final Wasm value type 0x63" },
        { "type length", HEADER .. section(1, "\1\96\9"), "invalid final Wasm type length" },
        { "import type index", HEADER .. section(1, "\1\96\0\0") ..
            section(2, "\1" .. text("env") .. text("x") .. "\0\1"), "type index is out of range" },
        { "missing tag attribute", HEADER .. section(2, "\1" .. text("env") .. text("x") .. "\4"), "truncated Wasm import type" },
        { "tag type index", HEADER .. section(1, "\1\96\0\0") ..
            section(2, "\1" .. text("env") .. text("t") .. "\4\0\1"), "type index is out of range" },
        { "export kind", HEADER .. section(7, "\1" .. text("x") .. "\9\0"), "export kind" },
        { "missing export kind", HEADER .. section(7, "\1" .. text("x")), "export kind" },
        { "duplicate export", HEADER .. section(7, "\2" .. text("x") .. "\0\0" .. text("x") .. "\0\0"), "duplicate Wasm export" },
    }
    for _, case in ipairs(bad_wasm) do
        it("rejects malformed final Wasm: " .. case[1], function() rejected(case[2], MAP, case[3]) end)
    end

    local bad_map = {
        { "empty", "", "invalid JSON value" }, { "root", "[]", "JSON object" },
        { "trailing bytes", MAP .. "x", "trailing" },
        { "duplicate key", '{"version":3,"version":3}', "duplicate source-map key" },
        { "unquoted key", '{version:3}', "object key" },
        { "colon", '{"version" 3}', "JSON ':'" },
        { "separator", '{"version":3 "sources":[]}', "separator" },
        { "trailing comma", '{"version":3,}', "object key" },
        { "string", '{"version":"unterminated}', "unterminated" },
        { "escape", '{"version":"\\x"}', "escape" },
        { "Unicode digits", '{"version":"\\u00xx"}', "Unicode" },
        { "high surrogate", '{"version":"\\ud800"}', "surrogate" },
        { "low surrogate", '{"version":"\\udfff"}', "surrogate" },
        { "UTF8", '{"version":"\255"}', "UTF-8" },
        { "leading zero", '{"version":03}', "number" },
        { "fraction", '{"version":3.}', "number" },
        { "exponent", '{"version":3e+}', "number" },
        { "infinity", '{"version":3e999}', "number" },
        { "version", MAP:gsub('"version":3', '"version":2'), "version must be 3" },
        { "indexed", MAP:gsub('"version":3', '"version":3,"sections":[]'), "indexed" },
        { "sources object", MAP:gsub('%["selected.browser.titan"%]', '{}'), "sources must be an array" },
        { "names entry", MAP:gsub('%["run"%]', '[null]'), "names entry" },
        { "mappings type", MAP:gsub('"mappings":"[^"]*"', '"mappings":null'), "mappings must be a string" },
        { "file type", MAP:gsub('"version":3', '"version":3,"file":false'), "file" },
        { "content count", MAP:gsub('"version":3', '"version":3,"sourcesContent":[null,null]'), "sourcesContent" },
        { "content entry", MAP:gsub('"version":3', '"version":3,"sourcesContent":[3]'), "sourcesContent entry" },
        { "nesting", '{"extra":' .. string.rep('[', 257) .. '0' .. string.rep(']', 257) .. '}', "nesting" },
    }
    for _, case in ipairs(bad_map) do
        it("rejects malformed standard maps: " .. case[1], function() rejected(image(), case[2], case[3]) end)
    end
    for _, case in ipairs({
        { "character", "!", "VLQ" }, { "incomplete VLQ", "g", "VLQ" },
        { "VLQ overflow", "///////", "overflows" }, { "VLQ length", "gggggggg", "too long" },
        { "negative generated", "D", "nonmonotonic" }, { "generated overflow", "+/////H,+/////H", "overflowing generated" },
        { "two fields", "AA", "arity" }, { "three fields", "AAA", "arity" },
        { "six fields", "AAAAAA", "arity" }, { "source index", "ACAA", "source index" },
        { "negative source", "ADAA", "source index" }, { "negative line", "AADA", "location" },
        { "negative column", "AAAD", "location" }, { "name index", "AAAAC", "name index" },
        { "trailing comma", "AAAA,", "empty" }, { "empty segment", "AAAA,,AAAA", "empty" },
        { "empty before line", "AAAA,;", "empty" },
        { "second generated line", "AAAA;AAAA", "generated source-map line" },
        { "leading empty generated line", ";AAAA", "generated source-map line" },
    }) do
        it("rejects malformed mappings: " .. case[1], function()
            rejected(image(), MAP:gsub('"mappings":"[^"]*"', '"mappings":"' .. case[2] .. '"'), case[3])
        end)
    end
    it("accepts empty trailing generated lines", function()
        assert(trace.rewrite(image(), MAP:gsub('"mappings":"[^"]*"', '"mappings":"AAAA;;"'), ID))
    end)
    it("accepts JSON escapes, paired surrogates and null or string source contents", function()
        for _, content in ipairs({ '', 'null', '"source\\ntext"' }) do
            local map = '{"version":3,"sources":["\\ud835\\udc00\\/\\\\\\b\\f\\n\\r\\t\\\""],"names":[],"mappings":"AAAA,EAAA","sourcesContent":[' .. content .. ']}'
            assert(trace.rewrite(image(), map, ID))
        end
        rejected(image(), MAP, "identity", "UPPER")
    end)
end)

describe("browser trace table", function()
    -- Decodes `<stem>.wasm.trace` independently of the runtime reader.
    local function decode(bytes)
        assert.equal("TTRC", bytes:sub(1, 4))
        assert.equal(1, (string.unpack("<I4", bytes, 5)))
        local identity = bytes:sub(9, 72)
        local imports, count, rows, bases, text, pos = string.unpack("<I4I4I4I4I4", bytes, 73)
        local function array(format, length)
            local values = {}
            for index = 1, length do values[index], pos = string.unpack("<" .. format, bytes, pos) end
            return values
        end
        local gaps, lengths = array("I4", count), array("I4", count)
        local pc_deltas, line_deltas = array("I4", rows), array("I4", rows)
        local offsets = array("I4", bases + imports + count + 1)
        local sources, first = array("i2", rows), array("i2", count)
        assert.equal(#bytes, pos + text - 1)
        local function string_at(index) return bytes:sub(pos + offsets[index], pos + offsets[index + 1] - 1) end
        local result = { identity = identity, imports = imports, bodies = {}, rows = {}, bases = {}, names = {} }
        for index = 1, bases do result.bases[index] = string_at(index) end
        for index = 1, imports + count do result.names[index] = string_at(bases + index) end
        local finish = 0
        for index = 1, count do
            local start = finish + gaps[index]
            finish = start + lengths[index]
            result.bodies[index] = { start, finish, first[index] >= 0 and result.bases[first[index] + 1] or "?" }
        end
        local pc, line = 0, 0
        for index = 1, rows do
            pc, line = pc + pc_deltas[index], (line + line_deltas[index]) & 0xffffffff
            result.rows[index] = { pc, sources[index] >= 0 and result.bases[sources[index] + 1] or false, line }
        end
        return result
    end
    -- The runtime's lookup for a PC in a body: the last row at or before it,
    -- inside the body, locates it; otherwise the body's declaring file.
    local function locate(table_, pc)
        for _, body in ipairs(table_.bodies) do
            if pc >= body[1] and pc < body[2] then
                local found
                for _, row in ipairs(table_.rows) do
                    if row[1] <= pc then found = row else break end
                end
                if found and found[1] >= body[1] and found[2] then return found[2], found[3] end
                return body[3], 0
            end
        end
    end
    -- The same answer straight from the segments: the last segment at an
    -- offset replaces the others there, a body declares the first `.titan`
    -- source that remains, and the last remaining segment at or before the
    -- PC inside the body locates it when its source is `.titan`.
    local function oracle(segments, sources, ranges, pc)
        local function titan(index) return index and sources[index + 1]:match("%.titan$") and
            sources[index + 1]:match("[^/\\]*$") end
        for _, range in ipairs(ranges) do
            if pc >= range[1] and pc < range[2] then
                local declared, found = "?", nil
                for index, segment in ipairs(segments) do
                    local final = not segments[index + 1] or segments[index + 1][1] ~= segment[1]
                    if final and segment[1] >= range[1] and segment[1] < range[2] and titan(segment[2]) and
                            declared == "?" then
                        declared = titan(segment[2])
                    end
                    if segment[1] <= pc then found = segment end
                end
                if found and found[1] >= range[1] and titan(found[2]) then return titan(found[2]), found[3] + 1 end
                return declared, 0
            end
        end
    end
    local function extended(sources, segments, ranges, names, imports, id)
        local mappings, previous = {}, { 0, 0, 0 }
        for index, segment in ipairs(segments) do
            local text = vlq(segment[1] - previous[1])
            if segment[2] then
                text = text .. vlq(segment[2] - previous[2]) .. vlq(segment[3] - previous[3]) .. "A"
                previous[2], previous[3] = segment[2], segment[3]
            end
            previous[1] = segment[1]
            mappings[index] = text
        end
        local quoted, encoded = {}, {}
        for index, source in ipairs(sources) do quoted[index] = string.format("%q", source) end
        for index, range in ipairs(ranges) do encoded[index] = "[" .. range[1] .. "," .. range[2] .. "]" end
        local listed = {}
        for index = 1, (imports or 0) + #ranges do
            listed[index] = names and names[index] and string.format("%q", names[index]) or "null"
        end
        return '{"version":3,"sources":[' .. table.concat(quoted, ",") .. '],"names":[],"mappings":"' ..
            table.concat(mappings, ",") .. '","x_titan_image":"' .. (id or ID) ..
            '","x_titan_function_imports":' .. (imports or 0) ..
            ',"x_titan_function_ranges":[' .. table.concat(encoded, ",") ..
            '],"x_titan_function_names":[' .. table.concat(listed, ",") .. ']}'
    end

    it("locates C inlined into a body as a gap and Titan code inlined from another file as its own", function()
        -- Body 1: C inlined before the first statement, the body's own line,
        -- then inlined C again. Body 2: its own line, then Titan code inlined
        -- from another file. Body 3: C only. Body 4: wholly unmapped.
        local sources = { "path/coroutine.titan", "runtime/minicoro.c", "C:\\path\\other.titan" }
        local segments = { { 100, 1, 65 }, { 105, 0, 43 }, { 110, 1, 65 }, { 120, 0, 9 }, { 125, 2, 4 },
            { 140, 1, 0 }, { 150, nil } }
        local ranges = { { 100, 120 }, { 120, 130 }, { 140, 150 }, { 150, 160 } }
        local result = decode(assert(trace.trace_table(extended(sources, segments, ranges,
            { "import", "trampoline_titan", "caller_titan", nil, "unnamed_c" }, 1))))
        assert.same({ "coroutine.titan", "other.titan" }, result.bases)
        assert.same({ { 100, 120, "coroutine.titan" }, { 120, 130, "coroutine.titan" }, { 140, 150, "?" },
            { 150, 160, "?" } }, result.bodies)
        assert.same({ "import", "trampoline_titan", "caller_titan", "", "unnamed_c" }, result.names)
        -- The leading C needs no row: each body starts in a gap. A gap repeats
        -- the previous line, so its line delta is zero.
        assert.same({ { 105, "coroutine.titan", 44 }, { 110, false, 44 }, { 120, "coroutine.titan", 10 },
            { 125, "other.titan", 5 } }, result.rows)
        for pc = 95, 165 do
            assert.same({ oracle(segments, sources, ranges, pc) }, { locate(result, pc) }, "pc " .. pc)
        end
    end)

    it("coalesces repeated locations, keeps the last of several segments at one offset and drops segments outside bodies", function()
        local sources = { "a/one.titan", "b/one.titan", "helper.c" }
        local segments = { { 4, 0, 1 }, { 10, 0, 2 }, { 12, 0, 2 }, { 12, 1, 2 }, { 14, nil }, { 14, 0, 2 },
            { 16, 0, 3 }, { 16, 2, 7 }, { 18, 0, 3 }, { 30, 0, 9 }, { 31, 0, 9 } }
        local ranges = { { 10, 20 }, { 25, 30 }, { 30, 40 } }
        local result = decode(assert(trace.trace_table(extended(sources, segments, ranges))))
        -- One basename for both directories; the segment at 4 lies before
        -- every body; 12 and 14 end where they started; 16's C wins.
        assert.same({ "one.titan" }, result.bases)
        assert.same({ { 10, "one.titan", 3 }, { 16, false, 3 }, { 18, "one.titan", 4 }, { 30, "one.titan", 10 } },
            result.rows)
        for pc = 0, 42 do
            assert.same({ oracle(segments, sources, ranges, pc) }, { locate(result, pc) }, "pc " .. pc)
        end
    end)

    it("names only what replaces a segment at a body's start", function()
        -- Body 1 starts with a `.titan` segment that another file replaces;
        -- body 2 with one that C replaces, so it starts in its usual gap.
        local sources = { "stale.titan", "actual.titan", "inlined.c", "own.titan" }
        local segments = { { 100, 0, 98 }, { 100, 1, 0 }, { 104, 1, 1 }, { 110, 0, 5 }, { 110, 2, 7 },
            { 114, 3, 2 } }
        local ranges = { { 100, 110 }, { 110, 120 } }
        local result = decode(assert(trace.trace_table(extended(sources, segments, ranges))))
        assert.same({ "actual.titan", "own.titan" }, result.bases)
        assert.same({ { 100, 110, "actual.titan" }, { 110, 120, "own.titan" } }, result.bodies)
        assert.same({ { 100, "actual.titan", 1 }, { 104, "actual.titan", 2 }, { 114, "own.titan", 3 } },
            result.rows)
        for pc = 98, 122 do
            assert.same({ oracle(segments, sources, ranges, pc) }, { locate(result, pc) }, "pc " .. pc)
        end
    end)

    it("answers every offset of a generated map exactly as its segments do", function()
        local seed = 12345
        local function random(limit)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed % limit
        end
        local sources = { "src/a.titan", "lib/b.titan", "src/c.c", "lua/lvm.c", "other/a.titan" }
        local segments, ranges, pc, start = {}, {}, 0, 3
        for _ = 1, 600 do
            pc = pc + random(3)
            local source = random(6)
            segments[#segments + 1] = source == 5 and { pc } or { pc, source, random(4) }
        end
        while start < pc do
            local length = 1 + random(40)
            ranges[#ranges + 1] = { start, start + length }
            start = start + length + random(3)
        end
        local result = decode(assert(trace.trace_table(extended(sources, segments, ranges))))
        assert.truthy(#result.rows < #segments)
        for at = 0, pc + 2 do
            assert.same({ oracle(segments, sources, ranges, at) }, { locate(result, at) }, "pc " .. at)
        end
    end)

    it("binds the table to the image and derives the same table from the final map", function()
        local wasm = image(names("\2\0" .. text("module_ℳ_run_titan") .. "\1" .. text('quoted"name')))
        local map, table_bytes = trace.rewrite(wasm, MAP, ID)
        local result = decode(table_bytes)
        local start = #HEADER + #FUNCTIONS + 4
        assert.equal(ID, result.identity)
        assert.same({ { start, start + 2, "?" }, { start + 3, start + 6, "?" } }, result.bodies)
        assert.same({ "module_ℳ_run_titan", 'quoted"name' }, result.names)
        assert.equal(table_bytes, trace.trace_table(map))
        local layout = 92 + 4 * (2 * 2 + 0 + 0 + 2 + 1) + 2 * (0 + 2) + #'module_ℳ_run_titanquoted"name'
        assert.equal(layout, #table_bytes)
    end)

    it("rejects a final map whose extensions cannot describe an image", function()
        local sources, segments, ranges = { "one.titan" }, { { 10, 0, 1 } }, { { 10, 20 } }
        local valid = extended(sources, segments, ranges)
        for _, case in ipairs({
            { valid:gsub('"x_titan_image":"a+"', '"x_titan_image":"A"'), "invalid x_titan_image" },
            { valid:gsub('"x_titan_function_imports":0', '"x_titan_function_imports":-1'), "invalid x_titan_function_imports" },
            { valid:gsub('"x_titan_function_imports":0', '"x_titan_function_imports":1.5'), "invalid x_titan_function_imports" },
            { valid:gsub('%[%[10,20%]%]', '[[20,10]]'), "invalid x_titan_function_ranges entry" },
            { valid:gsub('%[%[10,20%]%]', '[[10,20],[15,30]]'), "invalid x_titan_function_ranges entry" },
            { valid:gsub('"x_titan_function_names":%[null%]', '"x_titan_function_names":[1]'), "invalid x_titan_function_names entry" },
            { valid:gsub('"x_titan_function_names":%[null%]', '"x_titan_function_names":[]'), "trace names do not match the image's functions" },
            { valid:gsub(',"x_titan_function_ranges":%[%[10,20%]%]', ""), "invalid x_titan_function_ranges" },
            { valid:gsub('"mappings":"[^"]*"', '"mappings":"AA"'), "arity" },
        }) do
            local result, err = trace.trace_table(case[1])
            assert.is_nil(result)
            assert.truthy(err:find(case[2], 1, true), err)
        end
        -- Only sources a body uses count toward the limit.
        local many, used = {}, {}
        for index = 1, 32768 do many[index], used[index] = "s" .. index .. ".titan", { index, index - 1, 0 } end
        assert(trace.trace_table(extended(many, {}, {})))
        local result, err = trace.trace_table(extended(many, used, { { 1, 32769 } }))
        assert.is_nil(result)
        assert.equal("too many Titan source names for the trace table", err)
    end)
end)

describe("browser image byte limits", function()
    local BODY, IMAGE = 7654321, 1073741824
    local function module(sizes, labels, imports, padded)
        local functions, code, label_entries = {}, {}, {}
        for index, size in ipairs(sizes) do
            functions[index] = "\0"
            local length = leb(size)
            if padded then
                length = length:sub(1, -2) .. string.char(length:byte(-1) | 128) .. "\0"
            end
            -- One declared i32 local: all four vector/expression-boundary
            -- bytes count, but the preceding length LEB does not.
            code[index] = length .. "\1\1\127" .. string.rep("\1", size - 4) .. "\11"
        end
        for _, label in ipairs(labels or {}) do
            label_entries[#label_entries + 1] = leb(label[1]) .. text(label[2])
        end
        return HEADER .. section(1, "\1\96\0\0") .. (imports or "") ..
            section(3, leb(#sizes) .. table.concat(functions)) ..
            section(10, leb(#sizes) .. table.concat(code)) ..
            names(leb(#label_entries) .. table.concat(label_entries))
    end
    it("accepts image byte equality and rejects above it without allocating an image", function()
        assert(browserlink.check_image_size(IMAGE - 1))
        assert(browserlink.check_image_size(IMAGE))
        local accepted, err = browserlink.check_image_size(IMAGE + 1)
        assert.is_nil(accepted)
        assert.equal("browser image is 1073741825 bytes, exceeds maximum of 1073741824 bytes", err)
    end)
    for _, size in ipairs({ BODY - 1, BODY }) do
        it("accepts a body of " .. size .. " bytes including its local vector", function()
            local inventory = assert(browserlink.image_inventory(module({ size }, nil, nil, true)))
            assert.same({ imports = {}, exports = {} }, inventory)
        end)
    end
    it("rejects the first oversize body with imports-first indexing and a quoted name", function()
        local imports = section(2, "\6" .. text("env") .. text("left") .. "\0\0" ..
            text("env") .. text("memory") .. "\2\1\1\2" ..
            text("env") .. text("table") .. "\1\112\0\1" ..
            text("env") .. text("global") .. "\3\127\0" ..
            text("env") .. text("tag") .. "\4\0\0" ..
            text("env") .. text("right") .. "\0\0")
        local wasm = module({ BODY + 1, BODY + 2 },
            { { 1, "wrong-import" }, { 2, 'z-first"body' }, { 3, "a-second-body" } }, imports)
        local accepted, err, range = browserlink.image_inventory(wasm)
        assert.is_nil(accepted)
        assert.equal(string.format("browser image function %q (Wasm index 2) body is 7654322 bytes, exceeds maximum of 7654321 bytes",
            'z-first"body'), err)
        assert.equal(BODY + 1, range[2] - range[1])
    end)
    for _, labels in ipairs({ {}, { { 0, "" } } }) do
        it("identifies an oversize unnamed body by its Wasm index", function()
            local accepted, err = browserlink.image_inventory(module({ BODY + 1 }, labels))
            assert.is_nil(accepted)
            assert.equal("browser image function at Wasm index 0 body is 7654322 bytes, exceeds maximum of 7654321 bytes", err)
        end)
    end
    it("preserves bounded-parser failures", function()
        local accepted, err, range = browserlink.image_inventory("not Wasm")
        assert.is_nil(accepted)
        assert.matches("invalid final Wasm header", err, 1, true)
        assert.is_nil(range)
    end)
end)

describe("browser rejected-body source attribution", function()
    local function map(mappings, extra)
        return '{"version":3,"sources":["previous.c","actual.browser.titan"],"names":[],"mappings":"' ..
            mappings .. '"' .. (extra or "") .. '}'
    end
    it("uses the first mapped instruction inside the body, never a preceding function", function()
        local mappings = vlq(9) .. "AAA," .. vlq(2) .. vlq(1) .. vlq(41) .. vlq(6)
        assert.equal('"actual.browser.titan":42:7',
            assert(trace.function_source(map(mappings), { 10, 20 })))
        assert.equal('"actual.browser.titan":42:7 (sourceRoot \"https://example.test/src/\")',
            assert(trace.function_source(map(mappings, ',"sourceRoot":"https://example.test/src/"'), { 10, 20 })))
    end)
    it("handles unmapped same-offset replacements and the half-open end boundary", function()
        local mappings = vlq(10) .. "AAA,A," .. vlq(2) .. vlq(1) .. vlq(4) .. vlq(2)
        assert.equal('"actual.browser.titan":5:3',
            assert(trace.function_source(map(mappings), { 10, 20 })))
        local location, err = trace.function_source(map(vlq(20) .. "AAA"), { 10, 20 })
        assert.is_nil(location)
        assert.equal("no mapped source within function body", err)
    end)
    it("reports unavailable attribution for wholly unmapped, missing and empty source metadata", function()
        for _, mappings in ipairs({ "", "AAAA", vlq(10) }) do
            local location, err = trace.function_source(map(mappings), { 10, 20 })
            assert.is_nil(location)
            assert.equal("no mapped source within function body", err)
        end
        local location, err = trace.function_source(nil, { 10, 20 })
        assert.is_nil(location)
        assert.equal("source map is not a byte string", err)
        location, err = trace.function_source('{"version":3,"sources":[""],"names":[],"mappings":"UAAA"}', { 10, 20 })
        assert.is_nil(location)
        assert.equal("mapped source filename is empty", err)
    end)
    it("validates the complete map before trusting a mapped location", function()
        local location, err = trace.function_source(map(vlq(10) .. "AAA,!"), { 10, 20 })
        assert.is_nil(location)
        assert.equal("invalid source-map VLQ", err)
        location, err = trace.function_source(map("AAAA", ',"sourceRoot":7'), { 0, 20 })
        assert.is_nil(location)
        assert.equal("invalid source-map sourceRoot", err)
    end)
end)

describe("browser content-derived image identity", function()
    it("changes for entry, target, toolchain, flags, file contents, paths and order but not timestamps", function()
        local root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
        local cleanup <close> = setmetatable({}, { __close = function() files.remove(root) end })
        local left, right = root .. "/left.o", root .. "/right.o"
        files.write(left, "left"); files.write(right, "right")
        local descriptor = fixtures.descriptor()
        local function identity(contents, compile, link, groups, target)
            return trace.identity({ io = compiler_io.new_sync(), target_descriptor = target or descriptor },
                contents or "entry", compile or { "-O1" }, link or { "-g2" }, groups or { { left, right } })
        end
        local original = identity()
        assert.matches("^[0-9a-f]+$", original); assert.equal(64, #original)
        assert.equal(original, identity())
        assert(require("lfs").touch(left, 100, 100))
        assert.equal(original, identity())
        assert.not_equal(original, identity("entry changed"))
        assert.not_equal(original, identity(nil, { "-O2" }))
        assert.not_equal(original, identity(nil, nil, { "-gsource-map" }))
        assert.not_equal(original, identity(nil, nil, nil, { { right, left } }))
        files.write(left, "changed")
        assert.not_equal(original, identity())
        files.write(left, "left")
        local other = fixtures.descriptor(); other.identity = "other"
        assert.not_equal(original, identity(nil, nil, nil, nil, other))
        other = fixtures.descriptor(); other.tools.version_output = "other toolchain"
        assert.not_equal(original, identity(nil, nil, nil, nil, other))
        local copy = root .. "/copy.o"; files.write(copy, "left")
        assert.not_equal(original, identity(nil, nil, nil, { { copy, right } }))
        assert.truthy(trace.declaration(original):find('"' .. original .. '"', 1, true))
        assert.has_error(function() identity(nil, nil, nil, { { root .. "/missing.o" } }) end)
    end)
    it("resolves user static library flags through the existing certificate resolver", function()
        local root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
        local cleanup <close> = setmetatable({}, { __close = function() files.remove(root) end })
        local library = root .. "/libnamed.a"
        files.write(library, "!<arch>\n")
        local context = { io = compiler_io.new_sync(), target_descriptor = fixtures.descriptor() }
        local certificate = require "titan-compiler.linkcertificate"
        local resolved = assert(certificate.browser_trace_libraries(context, { "unused-compiler" },
            { "-sWASM_BIGINT=1", "-L", root, "-l", "named", "-Wl,-L," .. root .. ",-lnamed" }))
        for index, filename in ipairs(resolved) do resolved[index] = paths.to_slash(filename) end
        assert.same({ paths.to_slash(library), paths.to_slash(library) }, resolved)
        assert.same({}, assert(certificate.browser_trace_libraries(context, nil, { "-g2" })))
        function context.io:run() return { started = true, ok = true, output = "libabsent.a\n" } end
        local missing, why = certificate.browser_trace_libraries(context, { "unused-compiler" }, { "-labsent" })
        assert.is_nil(missing)
        assert.equal("cannot resolve native library: absent", why)
        missing, why = certificate.browser_trace_libraries(context, { "unused-compiler" }, { "-l" })
        assert.is_nil(missing)
        assert.equal("incomplete native library option", why)
    end)
end)

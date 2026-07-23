local staticmetadata = require "titan-compiler.staticmetadata"

local function uint(value, width, endian)
    local bytes = {}
    for index = 1, width do
        bytes[index] = string.char(value & 0xff)
        value = value >> 8
    end
    if endian == "big" then
        local reversed = {}
        for index = width, 1, -1 do
            reversed[#reversed + 1] = bytes[index]
        end
        return table.concat(reversed)
    end
    return table.concat(bytes)
end

local function zeros(count)
    return string.rep("\0", count)
end

local function fixed(text, width)
    assert(#text <= width)
    return text .. zeros(width - #text)
end

local function place(parts, offset, text)
    parts[#parts + 1] = { offset = offset, text = text }
end

local function assemble(size, parts)
    table.sort(parts, function(a, b) return a.offset < b.offset end)
    local output = {}
    local offset = 0
    for _, part in ipairs(parts) do
        assert(part.offset >= offset)
        output[#output + 1] = zeros(part.offset - offset)
        output[#output + 1] = part.text
        offset = part.offset + #part.text
    end
    assert(offset <= size)
    output[#output + 1] = zeros(size - offset)
    return table.concat(output)
end

local function elf_section(word_size, endian, values)
    values = values or {}
    local u4 = function(value) return uint(value or 0, 4, endian) end
    local u8 = function(value) return uint(value or 0, 8, endian) end
    if word_size == 32 then
        return table.concat({
            u4(values.name), u4(values.type), u4(values.flags),
            u4(values.address), u4(values.offset), u4(values.size),
            u4(values.link), u4(values.info), u4(values.align),
            u4(values.entry_size),
        })
    end
    return table.concat({
        u4(values.name), u4(values.type), u8(values.flags),
        u8(values.address), u8(values.offset), u8(values.size),
        u4(values.link), u4(values.info), u8(values.align),
        u8(values.entry_size),
    })
end

local function elf_object(payload, options)
    options = options or {}
    local word_size = options.word_size or 64
    local endian = options.endian or "little"
    local header_size = word_size == 32 and 52 or 64
    local section_size = word_size == 32 and 40 or 64
    local metadata_section_name = options.section_name or ".titan.meta"
    local names = "\0.shstrtab\0" .. metadata_section_name .. "\0.reloc\0"
    local shstr_name = 1
    local metadata_name = 11
    local relocation_name = metadata_name + #metadata_section_name + 1
    local names_offset = header_size
    local payload_offset = names_offset + #names
    local duplicate = options.duplicate and 1 or 0
    local relocation = options.relocation and 1 or 0
    local section_count = 3 + duplicate + relocation
    local section_offset = payload_offset + #payload
    local file_size = section_offset + section_count * section_size
    local parts = {}

    local ident = "\127ELF" ..
        string.char(word_size == 32 and 1 or 2) ..
        string.char(endian == "little" and 1 or 2) ..
        "\1" .. zeros(9)
    local header
    if word_size == 32 then
        header = table.concat({
            ident,
            uint(options.file_type or 1, 2, endian),
            uint(options.machine == nil and 62 or options.machine, 2, endian),
            uint(1, 4, endian), uint(0, 4, endian), uint(0, 4, endian),
            uint(section_offset, 4, endian),
            uint(options.flags or 0, 4, endian),
            uint(header_size, 2, endian), uint(0, 2, endian),
            uint(0, 2, endian), uint(section_size, 2, endian),
            uint(options.extended and 0 or section_count, 2, endian),
            uint(options.extended and 0xffff or 1, 2, endian),
        })
    else
        header = table.concat({
            ident,
            uint(options.file_type or 1, 2, endian),
            uint(options.machine == nil and 62 or options.machine, 2, endian),
            uint(1, 4, endian), uint(0, 8, endian), uint(0, 8, endian),
            uint(section_offset, 8, endian),
            uint(options.flags or 0, 4, endian),
            uint(header_size, 2, endian), uint(0, 2, endian),
            uint(0, 2, endian), uint(section_size, 2, endian),
            uint(options.extended and 0 or section_count, 2, endian),
            uint(options.extended and 0xffff or 1, 2, endian),
        })
    end
    place(parts, 0, header)
    place(parts, names_offset, names)
    place(parts, payload_offset, payload)

    local section_zero = elf_section(word_size, endian, options.extended and {
        size = section_count,
        link = 1,
    } or {})
    local shstr = elf_section(word_size, endian, {
        name = shstr_name,
        type = 3,
        offset = names_offset,
        size = #names,
        align = 1,
    })
    local metadata = elf_section(word_size, endian, {
        name = metadata_name,
        type = options.metadata_type or 1,
        flags = options.metadata_flags or 0,
        offset = options.metadata_offset or payload_offset,
        size = #payload,
        align = 1,
    })
    local sections = { section_zero, shstr, metadata }
    if options.duplicate then sections[#sections + 1] = metadata end
    if options.relocation then
        sections[#sections + 1] = elf_section(word_size, endian, {
            name = relocation_name,
            type = options.relocation_type or 9,
            info = 2,
            offset = payload_offset,
            size = 0,
        })
    end
    place(parts, section_offset, table.concat(sections))
    return assemble(file_size, parts)
end

local MACH_MAGIC = {
    ["32:little"] = "\206\250\237\254",
    ["32:big"] = "\254\237\250\206",
    ["64:little"] = "\207\250\237\254",
    ["64:big"] = "\254\237\250\207",
}

local function macho_section(word_size, endian, values)
    local u4 = function(value) return uint(value or 0, 4, endian) end
    local u8 = function(value) return uint(value or 0, 8, endian) end
    if word_size == 32 then
        return table.concat({
            fixed(values.sectname, 16), fixed(values.segname, 16),
            u4(values.address), u4(values.size), u4(values.offset),
            u4(values.align), u4(values.relocation_offset),
            u4(values.relocation_count), u4(values.flags),
            u4(values.reserved1), u4(values.reserved2),
        })
    end
    return table.concat({
        fixed(values.sectname, 16), fixed(values.segname, 16),
        u8(values.address), u8(values.size), u4(values.offset),
        u4(values.align), u4(values.relocation_offset),
        u4(values.relocation_count), u4(values.flags),
        u4(values.reserved1), u4(values.reserved2), u4(values.reserved3),
    })
end

local function macho_object(payload, options)
    options = options or {}
    local word_size = options.word_size or 64
    local endian = options.endian or "little"
    local cputype = options.cputype or
        (word_size == 64 and 0x01000007 or 7)
    local cpusubtype = options.cpusubtype or 3
    local header_size = word_size == 32 and 28 or 32
    local segment_size = word_size == 32 and 56 or 72
    local section_size = word_size == 32 and 68 or 80
    local section_count = options.duplicate and 2 or 1
    local command_size = segment_size + section_count * section_size
    local payload_offset = header_size + command_size
    local relocation_offset = payload_offset + #payload
    local relocation_count = options.relocations or 0
    local file_size = relocation_offset + relocation_count * 8
    if options.data_offset then file_size = math.max(file_size, payload_offset + #payload) end

    local header = MACH_MAGIC[tostring(word_size) .. ":" .. endian] ..
        uint(cputype, 4, endian) ..
        uint(cpusubtype, 4, endian) ..
        uint(options.file_type or 1, 4, endian) ..
        uint(1, 4, endian) ..
        uint(command_size, 4, endian) ..
        uint(0, 4, endian) ..
        (word_size == 64 and uint(0, 4, endian) or "")
    local command = uint(word_size == 32 and 1 or 0x19, 4, endian) ..
        uint(command_size, 4, endian) ..
        fixed("__TEXT", 16)
    if word_size == 32 then
        command = command ..
            uint(0, 4, endian) .. uint(0, 4, endian) ..
            uint(0, 4, endian) .. uint(0, 4, endian) ..
            uint(0, 4, endian) .. uint(0, 4, endian) ..
            uint(section_count, 4, endian) .. uint(0, 4, endian)
    else
        command = command ..
            uint(0, 8, endian) .. uint(0, 8, endian) ..
            uint(0, 8, endian) .. uint(0, 8, endian) ..
            uint(0, 4, endian) .. uint(0, 4, endian) ..
            uint(section_count, 4, endian) .. uint(0, 4, endian)
    end
    local section = macho_section(word_size, endian, {
        sectname = options.sectname or "__titanmeta",
        segname = options.segname or "__TEXT",
        size = #payload,
        offset = options.data_offset or payload_offset,
        relocation_offset = options.relocation_offset or relocation_offset,
        relocation_count = relocation_count,
        flags = options.section_type or 0,
    })
    command = command .. section
    if options.duplicate then command = command .. section end
    local parts = {}
    place(parts, 0, header .. command)
    place(parts, payload_offset, payload)
    if relocation_count ~= 0 and
       (options.relocation_offset or relocation_offset) == relocation_offset then
        place(parts, relocation_offset, zeros(relocation_count * 8))
    end
    return assemble(file_size, parts)
end

local function ar_field(value, width)
    local text = tostring(value)
    assert(#text <= width)
    return text .. string.rep(" ", width - #text)
end

local function ar_member(name, data, options)
    options = options or {}
    local size = options.size or #data
    local header = ar_field(name, 16) ..
        ar_field(0, 12) .. ar_field(0, 6) .. ar_field(0, 6) ..
        ar_field(100644, 8) ..
        (options.bad_size or ar_field(size, 10)) ..
        (options.bad_trailer and "xx" or "`\n")
    return header .. data ..
        (size % 2 == 1 and (options.bad_padding and "x" or "\n") or "")
end

local function archive(members)
    return "!<arch>\n" .. table.concat(members)
end

local FAT_MAGIC = {
    ["32:big"] = "\202\254\186\190",
    ["32:little"] = "\190\186\254\202",
    ["64:big"] = "\202\254\186\191",
    ["64:little"] = "\191\186\254\202",
}

local function round_up(value, alignment)
    return value + ((alignment - value % alignment) % alignment)
end

local function fat_container(slice_specs, options)
    options = options or {}
    local word_size = options.word_size or 32
    local endian = options.endian or "big"
    local entry_size = word_size == 32 and 20 or 32
    local table_end = 8 + #slice_specs * entry_size
    local entries = {}
    local parts = {}
    local offset = table_end
    for index, spec in ipairs(slice_specs) do
        local exponent = spec.align_exponent or 0
        local alignment = 1 << exponent
        offset = round_up(offset, alignment)
        if spec.offset then offset = spec.offset end
        local entry = uint(spec.cputype, 4, endian) ..
            uint(spec.cpusubtype, 4, endian)
        if word_size == 32 then
            entry = entry .. uint(offset, 4, endian) ..
                uint(spec.size or #spec.bytes, 4, endian) ..
                uint(exponent, 4, endian)
        else
            entry = entry .. uint(offset, 8, endian) ..
                uint(spec.size or #spec.bytes, 8, endian) ..
                uint(exponent, 4, endian) .. uint(spec.reserved or 0, 4, endian)
        end
        entries[#entries + 1] = entry
        place(parts, offset, spec.bytes)
        offset = offset + #spec.bytes
    end
    place(parts, 0, FAT_MAGIC[tostring(word_size) .. ":" .. endian] ..
        uint(#slice_specs, 4, endian) .. table.concat(entries))
    return assemble(offset, parts)
end

local ABI = "0.17"
local TYPES = "Module(\"pkg.mod\",{}, {})"
local PAYLOAD = assert(staticmetadata.render("pkg.mod", ABI, TYPES))

local function scan(bytes, options)
    options = options or {}
    options.expected_abi = options.expected_abi or ABI
    return staticmetadata.scan_bytes(bytes, "fixture with spaces", options)
end

describe("static compiled-module metadata", function()
    describe("canonical Lua payload", function()
        it("renders exact stable bytes and a numeric C initializer", function()
            assert.equal([[
-- Titan archive module metadata v1
return {
    ["pkg.mod"] = {
        abi = "0.17",
        types = "Module(\"pkg.mod\",{}, {})",
    },
}
]], PAYLOAD)
            assert.equal("{\n    0, 65, 255,\n}",
                assert(staticmetadata.c_initializer("\0A\255")))
            local entry = assert(staticmetadata.validate(
                PAYLOAD, "canonical", { expected_abi = ABI }))
            assert.equal("pkg.mod", entry.module)
            assert.equal(TYPES, entry.types)
        end)

        it("rejects canonical whitespace, ordering, and quoting variations", function()
            local variants = {
                (PAYLOAD:gsub("return {", "return  {", 1)),
                (PAYLOAD:gsub(
                    '        abi = "0.17",\n        types = ([^\n]+)',
                    "        types = %1\n        abi = \"0.17\",", 1)),
                (PAYLOAD:gsub('%["pkg.mod"%]', "['pkg.mod']", 1)),
            }
            for _, payload in ipairs(variants) do
                local entry, err = staticmetadata.validate(
                    payload, "variation", { expected_abi = ABI })
                assert.falsy(entry)
                assert.match("not in canonical form", err, 1, true)
            end
        end)

        it("uses an empty environment and checks runtime/result arity", function()
            local cases = {
                {
                    staticmetadata.BANNER ..
                        "return setmetatable({}, {})\n",
                    "metadata chunk failed",
                },
                {
                    staticmetadata.BANNER .. "error('no')\n",
                    "metadata chunk failed",
                },
                {
                    staticmetadata.BANNER .. "return\n",
                    "exactly one result",
                },
                {
                    staticmetadata.BANNER ..
                        "local t = {}; return t, nil\n",
                    "exactly one result",
                },
            }
            for _, case in ipairs(cases) do
                local entry, err = staticmetadata.validate(
                    case[1], "arity", { expected_abi = ABI })
                assert.falsy(entry)
                assert.match(case[2], err, 1, true)
            end
        end)

        it("rejects syntax, shape, fields, keys, ABI, and type metadata", function()
            local malformed = {
                { "not Lua", "missing exact" },
                {
                    staticmetadata.BANNER .. "return {\n",
                    "cannot load metadata chunk",
                },
                {
                    staticmetadata.BANNER .. "return 1\n",
                    "plain table",
                },
                {
                    staticmetadata.BANNER .. "return {}\n",
                    "exactly one logical module key",
                },
                {
                    staticmetadata.BANNER ..
                        "return { ['bad..name'] = { abi='0.17', types='x' } }\n",
                    "invalid logical Titan module key",
                },
                {
                    staticmetadata.BANNER ..
                        "return { [{}] = { abi='0.17', types='x' } }\n",
                    "invalid logical Titan module key",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { abi='0.17', types='x', extra=true } }\n",
                    "unknown field",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { [1]='0.17', types='x' } }\n",
                    "unknown field",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { abi='0.17', types='x', [{}]=true } }\n",
                    "unknown field",
                },
            }
            for _, case in ipairs(malformed) do
                local entry, err = staticmetadata.validate(
                    case[1], "schema", { expected_abi = ABI })
                assert.falsy(entry)
                assert.match(case[2], err, 1, true)
            end

            local old_abi = assert(staticmetadata.render(
                "pkg.mod", "0.16", TYPES))
            local entry, err = staticmetadata.validate(
                old_abi, "abi", { expected_abi = ABI })
            assert.falsy(entry)
            assert.match("ABI mismatch", err, 1, true)

            entry, err = staticmetadata.validate(PAYLOAD, "types", {
                expected_abi = ABI,
                validate_types = function()
                    return nil, "not a Type.Module"
                end,
            })
            assert.falsy(entry)
            assert.match("not a Type.Module", err, 1, true)
        end)
    end)

    describe("ELF relocatable objects", function()
        for _, word_size in ipairs({ 32, 64 }) do
            for _, endian in ipairs({ "little", "big" }) do
                it("reads ELF" .. word_size .. " " .. endian .. " metadata", function()
                    local object = assert(scan(elf_object(PAYLOAD, {
                        word_size = word_size,
                        endian = endian,
                    })))
                    assert.equal("object", object.kind)
                    assert.equal("elf", object.format)
                    assert.equal(word_size, object.fingerprint.class)
                    assert.equal(endian, object.fingerprint.endian)
                    assert.equal("pkg.mod", object.metadata.module)
                end)
            end
        end

        it("supports extended section count and string-table index", function()
            local object = assert(scan(elf_object(PAYLOAD, {
                extended = true,
            })))
            assert.equal("pkg.mod", object.metadata.module)
        end)

        it("rejects wrong type/machine and malformed metadata sections", function()
            local cases = {
                { { file_type = 3 }, "not a relocatable" },
                { { machine = 0 }, "no machine" },
                { { duplicate = true }, "more than one" },
                { { metadata_type = 8 }, "not SHT_PROGBITS" },
                { { metadata_flags = 0x800 }, "compressed" },
                { { metadata_offset = 0xffff }, "outside the input" },
                { { relocation = true }, "targeted by relocation" },
                {
                    { relocation = true, relocation_type = 4 },
                    "targeted by relocation",
                },
            }
            for _, case in ipairs(cases) do
                local object, err = scan(elf_object(PAYLOAD, case[1]))
                assert.falsy(object)
                assert.match(case[2], err, 1, true)
                assert.match("fixture with spaces", err, 1, true)
            end
        end)

        it("checks an authoritative object target fingerprint", function()
            local object = assert(scan(elf_object(PAYLOAD)))
            local mismatch, err = scan(elf_object(PAYLOAD, { flags = 1 }), {
                target = object.fingerprint,
            })
            assert.falsy(mismatch)
            assert.match("target mismatch", err, 1, true)
            assert.match("flags", err, 1, true)
        end)
    end)

    describe("Mach-O relocatable objects", function()
        for _, word_size in ipairs({ 32, 64 }) do
            for _, endian in ipairs({ "little", "big" }) do
                it("reads Mach-O" .. word_size .. " " .. endian ..
                   " metadata", function()
                    local object = assert(scan(macho_object(PAYLOAD, {
                        word_size = word_size,
                        endian = endian,
                    })))
                    assert.equal("macho", object.format)
                    assert.equal(word_size, object.fingerprint.word_size)
                    assert.equal(endian, object.fingerprint.endian)
                    assert.equal("pkg.mod", object.metadata.module)
                end)
            end
        end

        it("rejects non-objects and malformed metadata sections", function()
            local cases = {
                { { file_type = 2 }, "not a relocatable" },
                { { file_type = 6 }, "not a relocatable" },
                { { file_type = 8 }, "not a relocatable" },
                { { duplicate = true }, "more than one" },
                { { section_type = 1 }, "not S_REGULAR" },
                { { data_offset = 0xffff }, "outside the input" },
                { { relocations = 1 }, "has relocations" },
                {
                    { relocations = 1, relocation_offset = 0xffff },
                    "relocation table",
                },
            }
            for _, case in ipairs(cases) do
                local object, err = scan(macho_object(PAYLOAD, case[1]))
                assert.falsy(object)
                assert.match(case[2], err, 1, true)
            end
        end)
    end)

    describe("regular archives", function()
        local native_object = elf_object("", { section_name = ".text" })

        it("reads short, GNU long, and BSD extended member names", function()
            local long_table = "path/to/very-long-object-name.o/\n"
            local bsd_name = "another long object.o\0\0"
            local bytes = archive({
                ar_member("//", long_table),
                ar_member("short.o/", native_object),
                ar_member("/0", native_object),
                ar_member("#1/" .. tostring(#bsd_name),
                    bsd_name .. native_object),
            })
            local result = assert(scan(bytes))
            assert.equal(3, #result.members)
            assert.equal("short.o", result.members[1].display_name)
            assert.equal("path/to/very-long-object-name.o",
                result.members[2].display_name)
            assert.equal("another long object.o",
                result.members[3].display_name)
            assert.equal(result.members[3].recorded_size - #bsd_name,
                result.members[3].data_size)
        end)

        it("skips GNU and every 32/64-bit Darwin index name", function()
            local members = {
                ar_member("/", "index"),
                ar_member("/SYM64/", "index"),
            }
            for _, name in ipairs({
                "__.SYMDEF",
                "__.SYMDEF SORTED",
                "__.SYMDEF_64",
                "__.SYMDEF_64 SORTED",
            }) do
                local attached = name .. "\0"
                members[#members + 1] = ar_member(
                    "#1/" .. tostring(#attached), attached .. "index")
            end
            members[#members + 1] = ar_member("object.o/", native_object)
            local result = assert(scan(archive(members)))
            assert.equal(1, #result.members)
            assert.equal(7, #result.records)
        end)

        it("keeps duplicate leaf names and ordered physical records", function()
            local result = assert(scan(archive({
                ar_member("same.o/", native_object),
                ar_member("same.o/", native_object),
            })))
            assert.equal(2, #result.members)
            assert.equal("same.o", result.members[1].display_name)
            assert.equal("same.o", result.members[2].display_name)
            assert.is_true(result.members[1].header_offset <
                result.members[2].header_offset)
            assert.equal(native_object, result.members[1].bytes)
            assert.equal("elf", result.members[1].fingerprint.format)
        end)

        it("rejects duplicate logical keys with both object origins", function()
            local object = elf_object(PAYLOAD)
            local result, err = scan(archive({
                ar_member("same.o/", object),
                ar_member("same.o/", object),
            }))
            assert.falsy(result)
            assert.match("duplicate logical metadata key", err, 1, true)
            assert.match("member #1", err, 1, true)
            assert.match("member #2", err, 1, true)
        end)

        it("rejects thin, nested, raw, truncated, and malformed archives", function()
            local cases = {
                { "!<thin>\n", "thin archives" },
                {
                    archive({ ar_member("nested.a/", archive({})) }),
                    "nested archive",
                },
                {
                    archive({ ar_member("raw.txt/", "raw") }),
                    "unsupported native object",
                },
                { "!<arch>\nshort", "truncated archive member header" },
                {
                    "!<arch>\n" .. ar_member(
                        "short.o/", native_object,
                        { size = #native_object + 100 }),
                    "outside the input",
                },
                {
                    "!<arch>\n" .. ar_member(
                        "bad.o/", native_object, { bad_size = "bad       " }),
                    "invalid decimal",
                },
                {
                    archive({
                        ar_member("bad.o/", native_object,
                            { bad_trailer = true }),
                    }),
                    "header trailer",
                },
                {
                    archive({
                        ar_member("odd.o/", "x", { bad_padding = true }),
                    }),
                    "padding",
                },
                {
                    archive({
                        ar_member("#1/99", "short"),
                    }),
                    "extended archive name exceeds",
                },
                {
                    archive({
                        ar_member("//", "name/\n"),
                        ar_member("/3", native_object),
                    }),
                    "invalid GNU long-name offset",
                },
            }
            for _, case in ipairs(cases) do
                local result, err = scan(case[1])
                assert.falsy(result)
                assert.match(case[2], err, 1, true)
            end
        end)

        it("invalidates the whole provider when an unused entry is malformed", function()
            local malformed = PAYLOAD:gsub("0.17", "0.16", 1)
            local result, err = scan(archive({
                ar_member("wanted.o/", elf_object(PAYLOAD)),
                ar_member("unused.o/", elf_object(malformed)),
            }))
            assert.falsy(result)
            assert.match("ABI mismatch", err, 1, true)
            assert.match("unused.o", err, 1, true)
        end)
    end)

    describe("streaming regular-archive manifest verification", function()
        local temporary_paths

        before_each(function()
            temporary_paths = {}
        end)

        after_each(function()
            for _, path in ipairs(temporary_paths) do os.remove(path) end
        end)

        local function temporary_file(contents)
            local path = os.tmpname()
            temporary_paths[#temporary_paths + 1] = path
            local file = assert(io.open(path, "wb"))
            assert(file:write(contents))
            assert(file:close())
            return path
        end

        local function manifest_entry(contents, origin)
            return {
                staged_file = temporary_file(contents),
                byte_length = #contents,
                origin = origin,
            }
        end

        it("compares the ordered non-index sequence in bounded chunks",
           function()
            local first = string.rep("0123456789abcdef", 5000) .. "tail"
            local second = "metadata-free payload"
            local darwin_index_name = "__.SYMDEF_64 SORTED\0\0"
            local bsd_object_name = "same long object.o\0"
            local archive_path = temporary_file(archive({
                ar_member("/", "GNU index"),
                ar_member("//", "long-object-name.o/\n"),
                ar_member("#1/" .. tostring(#darwin_index_name),
                    darwin_index_name .. "Darwin index"),
                ar_member("same.o/", first),
                ar_member("#1/" .. tostring(#bsd_object_name),
                    bsd_object_name .. second),
            }))
            local result = assert(
                staticmetadata.verify_regular_archive_manifest(
                    archive_path, {
                        manifest_entry(first, "first staged input"),
                        manifest_entry(second, "second staged input"),
                    }))
            assert.equal(2, result.member_count)
            assert.equal(64 * 1024, result.chunk_size)
            assert.is_nil(result.members)
        end)

        it("rejects reordered, changed, extra, and missing object members",
           function()
            local first = "first-object!"
            local second = "second-object"
            local expected = {
                manifest_entry(first, "first staged input"),
                manifest_entry(second, "second staged input"),
            }
            local cases = {
                {
                    archive({
                        ar_member("second.o/", second),
                        ar_member("first.o/", first),
                    }),
                    "differs byte-for-byte",
                },
                {
                    archive({
                        ar_member("first.o/", first),
                        ar_member("second.o/", second .. "!"),
                    }),
                    "byte length",
                },
                {
                    archive({
                        ar_member("first.o/", first),
                        ar_member("second.o/", second),
                        ar_member("extra.o/", "extra"),
                    }),
                    "member count differs",
                },
                {
                    archive({
                        ar_member("first.o/", first),
                    }),
                    "member count differs",
                },
            }
            for _, case in ipairs(cases) do
                local archive_path = temporary_file(case[1])
                local result, err =
                    staticmetadata.verify_regular_archive_manifest(
                        archive_path, expected)
                assert.falsy(result)
                assert.match(case[2], err, 1, true)
            end
        end)

        it("rejects a staged file that changes after manifest creation",
           function()
            local staged = manifest_entry("expected", "mutable staged input")
            local file = assert(io.open(staged.staged_file, "ab"))
            assert(file:write("!"))
            assert(file:close())
            local archive_path = temporary_file(archive({
                ar_member("object.o/", "expected"),
            }))
            local result, err =
                staticmetadata.verify_regular_archive_manifest(
                    archive_path, { staged })
            assert.falsy(result)
            assert.match("changed size", err, 1, true)
        end)
    end)

    describe("universal Mach-O containers", function()
        local function universal_slices(payload)
            local x86 = macho_object(payload, {
                cputype = 0x01000007,
                cpusubtype = 3,
            })
            local arm = macho_object(payload, {
                cputype = 0x0100000c,
                cpusubtype = 0,
            })
            return {
                {
                    cputype = 0x01000007,
                    cpusubtype = 3,
                    bytes = archive({ ar_member("module.o/", x86) }),
                },
                {
                    cputype = 0x0100000c,
                    cpusubtype = 0,
                    bytes = archive({ ar_member("module.o/", arm) }),
                },
            }
        end

        for _, word_size in ipairs({ 32, 64 }) do
            for _, endian in ipairs({ "little", "big" }) do
                it("reads fat" .. word_size .. " " .. endian ..
                   " archive headers", function()
                    local result = assert(scan(fat_container(
                        { universal_slices(PAYLOAD)[1] },
                        { word_size = word_size, endian = endian })))
                    assert.equal("fat_archive", result.kind)
                    assert.equal(word_size, result.fat_word_size)
                    assert.equal(endian, result.endian)
                    assert.equal("pkg.mod", result.entries["pkg.mod"].module)
                end)
            end
        end

        it("requires exact cross-slice key and payload agreement", function()
            local result = assert(scan(fat_container(
                universal_slices(PAYLOAD))))
            assert.equal(2, #result.slices)
            assert.equal(1, #result.slices[1].members)
            assert.equal(result.slices[2].offset +
                result.slices[2].members[1].header_offset,
                result.slices[2].members[1].absolute_header_offset)

            local other_payload = assert(staticmetadata.render(
                "pkg.other", ABI, 'Module("pkg.other",{}, {})'))
            local slices = universal_slices(PAYLOAD)
            slices[2].bytes = archive({ ar_member("module.o/",
                macho_object(other_payload, {
                    cputype = 0x0100000c,
                    cpusubtype = 0,
                })) })
            result, err = scan(fat_container(slices))
            assert.falsy(result)
            assert.match("key set differs", err, 1, true)

            local different = assert(staticmetadata.render(
                "pkg.mod", ABI, TYPES .. " "))
            slices = universal_slices(PAYLOAD)
            slices[2].bytes = archive({ ar_member("module.o/",
                macho_object(different, {
                    cputype = 0x0100000c,
                    cpusubtype = 0,
                })) })
            result, err = scan(fat_container(slices))
            assert.falsy(result)
            assert.match("payload", err, 1, true)
        end)

        it("selects the slice matching a generated target", function()
            local result = assert(scan(fat_container(
                universal_slices(PAYLOAD))))
            local target = result.slices[2].members[1].fingerprint
            local selected = assert(staticmetadata.select_fat_slice(
                result, target))
            assert.equal(0x0100000c, selected.cputype)
            local selected_during_scan = assert(scan(
                fat_container(universal_slices(PAYLOAD)),
                { target = target }))
            assert.equal(selected_during_scan.slices[2],
                selected_during_scan.selected_slice)
        end)

        it("classifies and selects direct top-level fat objects", function()
            local x86 = macho_object("", {
                cputype = 0x01000007,
                cpusubtype = 3,
                sectname = "__text",
            })
            local arm = macho_object("", {
                cputype = 0x0100000c,
                cpusubtype = 0,
                sectname = "__text",
            })
            local result = assert(scan(fat_container({
                {
                    cputype = 0x01000007,
                    cpusubtype = 3,
                    bytes = x86,
                },
                {
                    cputype = 0x0100000c,
                    cpusubtype = 0,
                    bytes = arm,
                },
            })))
            assert.equal("fat_object", result.kind)
            local selected = assert(staticmetadata.select_fat_slice(
                result, result.slices[1].object.fingerprint))
            assert.equal(0x01000007, selected.cputype)
        end)

        it("rejects fat objects inside regular archives", function()
            local fat_object = fat_container({
                {
                    cputype = 0x01000007,
                    cpusubtype = 3,
                    bytes = macho_object("", {
                        cputype = 0x01000007,
                        cpusubtype = 3,
                        sectname = "__text",
                    }),
                },
            })
            local result, err = scan(archive({
                ar_member("fat.o/", fat_object),
            }))
            assert.falsy(result)
            assert.match("fat object inside a regular archive", err, 1, true)
        end)

        it("rejects duplicate architectures, alignment, bounds, and overlap", function()
            local one = universal_slices(PAYLOAD)[1]
            local overlap_offset = 48
            local overlap = FAT_MAGIC["32:big"] .. uint(2, 4, "big") ..
                uint(0x01000007, 4, "big") .. uint(3, 4, "big") ..
                uint(overlap_offset, 4, "big") ..
                uint(#one.bytes, 4, "big") .. uint(0, 4, "big") ..
                uint(0x0100000c, 4, "big") .. uint(0, 4, "big") ..
                uint(overlap_offset, 4, "big") ..
                uint(#one.bytes, 4, "big") .. uint(0, 4, "big") ..
                one.bytes
            local cases = {
                {
                    fat_container({ one, one }),
                    "repeats architecture",
                },
                {
                    fat_container({
                        {
                            cputype = one.cputype,
                            cpusubtype = one.cpusubtype,
                            bytes = one.bytes,
                            align_exponent = 2,
                            offset = 29,
                        },
                    }),
                    "not aligned",
                },
                {
                    fat_container({
                        {
                            cputype = one.cputype,
                            cpusubtype = one.cpusubtype,
                            bytes = one.bytes,
                            size = #one.bytes + 100,
                        },
                    }),
                    "outside the input",
                },
                { overlap, "overlap" },
            }
            for _, case in ipairs(cases) do
                local result, err = scan(case[1])
                assert.falsy(result)
                assert.match(case[2], err, 1, true)
            end
        end)

        it("does not invoke subprocesses while scanning", function()
            local old_execute = os.execute
            local old_popen = io.popen
            os.execute = function() error("subprocess invoked") end
            io.popen = function() error("subprocess invoked") end
            local ok, result = pcall(function()
                return assert(scan(fat_container(
                    universal_slices(PAYLOAD))))
            end)
            os.execute = old_execute
            io.popen = old_popen
            assert.is_true(ok)
            assert.equal("fat_archive", result.kind)
        end)
    end)
end)

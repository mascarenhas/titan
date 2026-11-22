local temporary = require "spec.support.temporary"
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local types = require "titan-compiler.types"
local version = require "titan-compiler.version"

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

local function coff_object(payload, options)
    options = options or {}
    local count = options.duplicate and 2 or 1
    local name = options.section_name or ".titan.meta"
    local long_name = #name > 8
    local data_offset = 20 + count * 40
    local relocations = options.relocations or 0
    local relocation_data = options.relocation_data or zeros(relocations * 10)
    local relocation_offset = data_offset + count * #payload
    local symbol_offset = relocation_offset + #relocation_data
    local strings = long_name and name .. "\0" or ""
    strings = uint(#strings + 4, 4) .. strings
    if options.strings then strings = options.strings end
    local header = uint(options.machine or 0x8664, 2) ..
        uint(options.section_count or count, 2) .. zeros(4) ..
        uint(options.symbol_offset or symbol_offset, 4) ..
        uint(options.symbol_count or 0, 4) ..
        uint(options.optional_size or 0, 2) .. uint(options.flags or 0, 2)
    local parts = { header }
    for index = 1, count do
        parts[#parts + 1] = fixed(options.raw_name or (long_name and "/4" or name), 8) ..
            zeros(8) .. uint(options.data_size or #payload, 4) ..
            uint(options.data_offset or data_offset + (index - 1) * #payload, 4) ..
            uint(options.relocation_offset or (relocations > 0 and relocation_offset or 0), 4) ..
            uint(options.line_offset or 0, 4) .. uint(relocations, 2) ..
            uint(options.line_count or 0, 2) .. uint(options.section_flags or 0x40100040, 4)
    end
    parts[#parts + 1] = payload:rep(count)
    parts[#parts + 1] = relocation_data
    parts[#parts + 1] = strings
    return table.concat(parts)
end

local function uleb(value, width)
    local bytes = {}
    repeat
        local digit = value & 0x7f
        value = value >> 7
        local more = value ~= 0 or (width ~= nil and #bytes + 1 < width)
        if more then digit = digit | 0x80 end
        bytes[#bytes + 1] = string.char(digit)
    until not more
    return table.concat(bytes)
end

local function sleb(value, width)
    local bytes = {}
    while true do
        local digit = value & 0x7f
        value = value // 128
        local sign = (digit & 0x40) ~= 0
        local done = ((value == 0 and not sign) or (value == -1 and sign)) and
            (width == nil or #bytes + 1 >= width)
        if not done then digit = digit | 0x80 end
        bytes[#bytes + 1] = string.char(digit)
        if done then break end
    end
    return table.concat(bytes)
end

local function wasm_str(text, width)
    return uleb(#text, width) .. text
end

local function wasm_sec(id, body, width)
    return string.char(id) .. uleb(#body, width) .. body
end

local function wasm_custom(name, body, width)
    return wasm_sec(0, wasm_str(name, width) .. body, width)
end

local function wasm_object(payload, options)
    options = options or {}
    local pad = options.pad and 5 or nil
    local out = {
        (options.magic or "\0asm") .. uint(options.version or 1, 4, "little"),
    }
    local section_count = 0
    local data_section_index
    local function emit(bytes)
        out[#out + 1] = bytes
        section_count = section_count + 1
        return section_count - 1
    end

    if options.dylink then
        emit(wasm_custom(options.dylink == true and "dylink.0" or options.dylink, "\0", pad))
    end
    if options.type_section then
        emit(wasm_sec(1, options.type_section, pad))
    end
    if options.imports ~= false then
        local imports = options.imports or {
            {
                module = "env",
                name = "__linear_memory",
                kind = 2,
                flags = options.memory_flags or 0,
                initial = 1,
                maximum = options.memory_max,
            },
        }
        local items = { uleb(#imports, pad) }
        for _, imp in ipairs(imports) do
            items[#items + 1] = wasm_str(imp.module, pad) ..
                wasm_str(imp.name, pad) .. string.char(imp.kind)
            if imp.kind == 0 then
                items[#items + 1] = uleb(imp.type_index or 0, pad)
            elseif imp.kind == 1 then
                items[#items + 1] = string.char(imp.elem_type or 0x70) ..
                    uleb(imp.flags or 0, pad) .. uleb(imp.initial or 1, pad) ..
                    ((imp.flags or 0) & 1 ~= 0 and uleb(imp.maximum or 1, pad) or "")
            elseif imp.kind == 2 then
                items[#items + 1] = uleb(imp.flags or 0, pad) ..
                    uleb(imp.initial or 1, pad) ..
                    ((imp.flags or 0) & 1 ~= 0 and uleb(imp.maximum or 1, pad) or "")
            elseif imp.kind == 3 then
                items[#items + 1] = string.char(imp.valtype or 0x7f) ..
                    string.char(imp.mutable or 1)
            elseif imp.kind == 4 then
                items[#items + 1] = string.char(imp.attribute or 0) ..
                    uleb(imp.type_index or 0, pad)
            end
        end
        emit(wasm_sec(2, table.concat(items), pad))
    end
    if options.memory_section_flags ~= nil then
        emit(wasm_sec(5, uleb(1, pad) .. uleb(options.memory_section_flags, pad) .. uleb(1, pad), pad))
    end
    for _, raw in ipairs(options.extra_sections_before_data or {}) do
        emit(raw)
    end

    local segments = options.segments
    if not segments then
        segments = {}
        if payload ~= nil then
            local seg = {
                name = options.section_name or ".titan.meta",
                payload = payload,
                mode = options.segment_mode or 0,
                memory_index = options.segment_memory or 0,
                offset = options.segment_offset or 0,
                opcode = options.segment_opcode or 0x41,
                align_exp = options.align_exp or 0,
                flags = options.segment_flags or 0,
            }
            segments[1] = seg
            if options.duplicate then segments[2] = seg end
        end
    end

    if options.datacount ~= nil or options.include_datacount then
        emit(wasm_sec(12, uleb(options.datacount or #segments, pad), pad))
    end
    if options.include_code then
        emit(wasm_sec(10, uleb(0, pad), pad))
    end

    local first_payload_body_offset = 0
    if #segments > 0 and not options.no_data_section then
        local data_items = { uleb(#segments, pad) }
        local current_len = #data_items[1]
        for index, seg in ipairs(segments) do
            local mode = seg.mode or 0
            local header = uleb(mode, pad)
            if mode == 0 or mode == 2 then
                if mode == 2 then
                    header = header .. uleb(seg.memory_index or 0, pad)
                end
                header = header .. string.char(seg.opcode or 0x41) ..
                    sleb(seg.offset or 0, pad) .. "\x0b"
            end
            local size_leb = uleb(#seg.payload, pad)
            if index == 1 then
                first_payload_body_offset = current_len + #header + #size_leb
            end
            local entry = header .. size_leb .. seg.payload
            data_items[#data_items + 1] = entry
            current_len = current_len + #entry
        end
        data_section_index = emit(wasm_sec(11, table.concat(data_items), pad))
    end

    for _, raw in ipairs(options.extra_sections_before_linking or {}) do
        emit(raw)
    end

    if not options.no_linking then
        local linking_parts = { uleb(options.linking_version or 2, pad) }
        if not options.no_segment_info and (#segments > 0 or options.segment_info_count ~= nil) then
            local info_count = options.segment_info_count or #segments
            local seg_items = { uleb(info_count, pad) }
            for index = 1, info_count do
                local seg = segments[index] or { name = ".data", align_exp = 0, flags = 0 }
                seg_items[#seg_items + 1] = wasm_str(seg.name or ".titan.meta", pad) ..
                    uleb(seg.align_exp or 0, pad) .. uleb(seg.flags or 0, pad)
            end
            local sub_body = table.concat(seg_items)
            linking_parts[#linking_parts + 1] = "\5" .. uleb(#sub_body, pad) .. sub_body
        end
        if options.init_funcs then
            local items = { uleb(#options.init_funcs, pad) }
            for _, fn in ipairs(options.init_funcs) do
                items[#items + 1] = uleb(fn.priority or 65535, pad) .. uleb(fn.symbol or 0, pad)
            end
            local sub_body = table.concat(items)
            linking_parts[#linking_parts + 1] = "\6" .. uleb(#sub_body, pad) .. sub_body
        end
        if options.comdats then
            local items = { uleb(#options.comdats, pad) }
            for _, comdat in ipairs(options.comdats) do
                local entries = { wasm_str(comdat.name or "grp", pad), uleb(comdat.flags or 0, pad),
                    uleb(#(comdat.entries or {}), pad) }
                for _, entry in ipairs(comdat.entries or {}) do
                    entries[#entries + 1] = string.char(entry.kind or 0) .. uleb(entry.index or 0, pad)
                end
                items[#items + 1] = table.concat(entries)
            end
            local sub_body = table.concat(items)
            linking_parts[#linking_parts + 1] = "\7" .. uleb(#sub_body, pad) .. sub_body
        end
        if options.symbols then
            local items = { uleb(#options.symbols, pad) }
            for _, sym in ipairs(options.symbols) do
                local flags = sym.flags or 0
                local defined = (flags & 0x10) == 0
                local explicit_name = (flags & 0x40) ~= 0
                local part = string.char(sym.kind) .. uleb(flags, pad)
                if sym.kind == 0 or sym.kind == 2 or sym.kind == 4 or sym.kind == 5 then
                    part = part .. uleb(sym.index or 0, pad)
                    if defined or explicit_name then
                        part = part .. wasm_str(sym.name or "sym", pad)
                    end
                elseif sym.kind == 1 then
                    part = part .. wasm_str(sym.name or "data_sym", pad)
                    if defined then
                        if (flags & 0x200) == 0 then
                            part = part .. uleb(sym.index or 0, pad)
                        end
                        part = part .. uleb(sym.offset or 0, pad) .. uleb(sym.size or 0, pad)
                    end
                elseif sym.kind == 3 then
                    part = part .. uleb(sym.index or 0, pad)
                end
                items[#items + 1] = part
            end
            local sub_body = table.concat(items)
            linking_parts[#linking_parts + 1] = "\8" .. uleb(#sub_body, pad) .. sub_body
        end
        for _, sub_raw in ipairs(options.extra_linking_subsections or {}) do
            linking_parts[#linking_parts + 1] = sub_raw
        end
        emit(wasm_custom("linking", table.concat(linking_parts), pad))
    end

    if options.relocation or options.relocations then
        local relocs = options.relocations or {
            {
                name = "reloc.DATA",
                target = options.relocation_target or data_section_index or 0,
                entries = {
                    {
                        type = options.relocation_type or 5,
                        offset = options.relocation_offset or first_payload_body_offset,
                        symbol = 0,
                        addend = 0,
                    },
                },
            },
        }
        for _, reloc in ipairs(relocs) do
            local rparts = {
                uleb(reloc.target, pad),
                uleb(#reloc.entries, pad),
            }
            for _, entry in ipairs(reloc.entries) do
                local addend_bytes = entry.raw_addend or
                    (entry.addend ~= nil and
                        sleb(entry.addend, entry.addend_width or pad) or "")
                rparts[#rparts + 1] = string.char(entry.type) ..
                    uleb(entry.offset or 0, pad) .. uleb(entry.symbol or 0, pad) ..
                    addend_bytes
            end
            emit(wasm_custom(reloc.name or "reloc.DATA", table.concat(rparts), pad))
        end
    end

    if options.features ~= false then
        local features = options.features or {
            { "+", "bulk-memory" },
            { "+", "sign-ext" },
        }
        local fparts = { uleb(#features, pad) }
        for _, feat in ipairs(features) do
            fparts[#fparts + 1] = feat[1] .. wasm_str(feat[2], pad)
        end
        emit(wasm_custom("target_features", table.concat(fparts), pad))
    end

    for _, raw in ipairs(options.extra_sections_after_linking or {}) do
        emit(raw)
    end
    return table.concat(out)
end

describe("bounded raw object sections", function()
    local names = { elf = ".titan.cprobe", macho_segment = "__DATA",
        macho_section = "__titancprobe", coff = ".titan.cprobe", wasm = ".titan.cprobe" }
    local payload = "TITENUM\0\1\12\1\6"
    local function extract(bytes, limit)
        return staticmetadata.read_object_section(bytes, "query.o", names, limit or 12)
    end
    local function elf(options)
        options = options or {}
        options.section_name = names.elf
        return elf_object(payload, options)
    end
    local function macho(options)
        options = options or {}
        options.segname, options.sectname = names.macho_segment, names.macho_section
        return macho_object(payload, options)
    end
    local function coff(options)
        options = options or {}
        options.section_name = names.coff
        return coff_object(payload, options)
    end
    local function wasm(options)
        options = options or {}
        options.section_name = names.wasm
        return wasm_object(payload, options)
    end

    it("extracts exact COFF bytes using long section names", function()
        assert.equal(payload, assert(extract(coff())))
        local short_names = { elf = ".probe", macho_segment = "__DATA",
            macho_section = "__probe", coff = ".probe", wasm = ".probe" }
        assert.equal(payload, assert(staticmetadata.read_object_section(
            coff_object(payload, { section_name = ".probe", symbol_offset = 0 }),
            "short.o", short_names, 12)))
        assert.equal(payload, assert(staticmetadata.read_object_section(
            wasm_object(payload, { section_name = ".probe", pad = true }),
            "short.wasm.o", short_names, 12)))
    end)

    it("extracts exact bytes from ELF and Mach-O in either width and byte order", function()
        for _, build in ipairs({ elf, macho }) do
            for _, width in ipairs({ 32, 64 }) do
                for _, endian in ipairs({ "little", "big" }) do
                    assert.equal(payload, assert(extract(build({
                        word_size = width, endian = endian }))))
                end
            end
        end
    end)

    it("rejects missing, duplicate, oversized and relocated result sections", function()
        for _, build in ipairs({ elf, macho, coff, wasm }) do
            assert.is_nil(extract(build(), 11))
            assert.is_nil(extract(build({ duplicate = true })))
            assert.is_nil(extract(build():sub(1, 20)))
        end
        assert.is_nil(extract(elf({ relocation = true })))
        assert.is_nil(extract(macho({ relocations = 1 })))
        assert.is_nil(extract(coff({ relocations = 1 })))
        assert.is_nil(extract(wasm({ relocation = true })))
        assert.is_nil(extract(wasm({ segment_mode = 1 })))
        assert.is_nil(extract(wasm({ segment_flags = 2 })))
        assert.is_nil(extract(wasm({ align_exp = 2 })))
        assert.is_nil(extract(elf_object(payload, { section_name = ".other" })))
        assert.is_nil(extract(macho_object(payload, { sectname = "__other" })))
        assert.is_nil(extract(elf({ metadata_type = 8 })))
        assert.is_nil(extract(elf({ metadata_flags = 0x800 })))
        assert.is_nil(extract(macho({ section_type = 1 })))
        assert.is_nil(extract(coff({ section_flags = 0x80 })))
        assert.is_nil(extract(coff({ section_flags = 0x20 })))
        assert.is_nil(extract(coff_object(payload, { section_name = ".other" })))
        assert.is_nil(extract(wasm_object(payload, { section_name = ".other" })))
        assert.is_nil(extract("!<arch>\n"))
        assert.is_nil(extract("not an object"))
    end)
end)

describe("trusted object source metadata", function()
    local function source_entry()
        local name = "cache.producer"
        local scope = types.GenericScope(name, nil, "identity", "function", "function")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local scheme = types.FunctionScheme(scope, { types.TypeParameter("T", nil) },
            types.Function({ parameter }, { parameter }, false, nil, nil))
        local public = types.ModuleMember(name, "identity", scheme, { "item" })
        local private = types.ModuleMember(name, "secret", scheme, { "item" })
        private.islocal = true
        local structure = types.CStruct(nil, "Node", nil, {}, true, false)
        local pointer = types.CPointer(structure, {})
        local field = types.CField(structure, "next", pointer, nil, false)
        structure.fields[1], structure.fields.next = field, field
        local head = types.ModuleVariable(name, "head", pointer, false)
        head.islocal = true
        local owner = types.Record(name .. ".Hidden", {}, {}, {}, 0, nil, {})
        owner.islocal, owner._source_complete = true, true
        local module = types.Module(name, { public }, {})
        module._source = true
        module.source_members = { private, head, secret = private, head = head }
        module.source_type_members = { Hidden = owner }
        -- Checked-body annotations must not leak into a persistent declaration.
        private._decl = { _tag = "Ast.TopLevelFunc", body = {} }
        return {
            kind = "source", type = module, filename = "cache/producer.titan",
            source_files = { "cache/producer.titan" }, deps = {},
            declared_registry = { [owner.name] = owner },
        }
    end

    it("restores shared generic declarations, private owners, C cycles and inline headers", function()
        local entry = source_entry()
        local native = {
            native_output = "cache/producer.titan", has_main = false,
            imports = { { module = "external", binding = "dynamic" } },
            headers = { foreign = "static inline int answer(void) { return 42; }\n" },
        }
        local payload = assert(objectmetadata.encode(entry, native))
        local restored = assert(objectmetadata.decode(payload))
        assert.is_nil(restored.ast)
        assert.is_nil(restored._analysis_manifest)
        assert.is_nil(restored.source_manifest)
        assert.is_true(restored.type._source)
        assert.same(native, restored.object_metadata)
        assert.equal(restored.type.members.identity.type,
            restored.type.source_members.secret.type)
        local scheme = restored.type.members.identity.type
        assert.equal(scheme.scope, scheme.signature.params[1].scope)
        assert.equal(scheme.signature.params[1], scheme.signature.rettypes[1])
        local structure = restored.type.source_members.head.type.pointee
        assert.equal(structure, structure.fields.next.owner)
        assert.equal(structure, structure.fields.next.type.pointee)
        assert.equal(structure.fields[1], structure.fields.next)
        assert.equal(restored.type.source_type_members.Hidden,
            restored.declared_registry["cache.producer.Hidden"])
        assert.is_nil(restored.type.members.secret)
        assert.is_nil(restored.type.source_members.secret._decl)
        assert.is_not.equal(entry.type, restored.type)
        assert.equal(payload, assert(objectmetadata.encode(entry, native)))
    end)

    it("retains and validates independent nominal layout bytes", function()
        local layouts = require("titan-compiler.nominallayout")
        local entry = source_entry()
        local before = types.serialize(entry.type)
        local encoded = assert(layouts.encode(entry.type.name, {}))
        local payload = assert(objectmetadata.encode(entry, { layouts = encoded }))
        local restored = assert(objectmetadata.decode(payload))
        assert.equal(encoded, restored.object_metadata.layouts)
        assert.equal(entry.type.name, restored.layout_inventory.module)
        assert.same({}, restored.layout_inventory.layouts)
        assert.equal(before, types.serialize(restored.type))

        payload = assert(objectmetadata.encode(entry, { layouts = "invalid" }))
        local invalid, err = objectmetadata.decode(payload)
        assert.is_nil(invalid)
        assert.matches("invalid object nominal layout metadata", err, 1, true)
    end)

    it("reads source records without interpreting them as public metadata", function()
        local payload = assert(objectmetadata.encode(source_entry(), {}))
        local coff = assert(objectmetadata.read(coff_object(payload,
            { section_name = ".titan.source" }), "producer.obj"))
        assert.equal("cache.producer", coff.type.name)
        assert.equal("secret", coff.type.source_members[1].name)
        local wasm = assert(objectmetadata.read(wasm_object(payload,
            { section_name = ".titan.source", pad = true }), "producer.wasm.o"))
        assert.equal("cache.producer", wasm.type.name)
        assert.equal("secret", wasm.type.source_members[1].name)
        for _, width in ipairs({ 32, 64 }) do
            for _, endian in ipairs({ "little", "big" }) do
                for _, bytes in ipairs({
                    elf_object(payload, { word_size = width, endian = endian,
                        section_name = ".titan.source" }),
                    macho_object(payload, { word_size = width, endian = endian,
                        sectname = "__titansrc" }),
                }) do
                    local restored = assert(objectmetadata.read(bytes, "producer.o"))
                    assert.equal("cache.producer", restored.type.name)
                    assert.equal("secret", restored.type.source_members[1].name)
                end
            end
        end
    end)

    it("reads native compiler metadata sections with Linux fat LTO enabled", function()
        local cdriver = require "c-parser.cdriver"
        local strategy = require("titan-compiler.io").new_sync()
        local core = require "titan-compiler.coder.core"
        require "titan-compiler.coder.module"
        local util = require "titan-compiler.util"
        local platform = strategy:run({ "uname" })
        assert.is_true(platform.ok, platform.output or platform.diagnostic)
        local linux = platform.output:match("^Linux") ~= nil
        local entry = source_entry()
        local public = assert(staticmetadata.render(entry.type.name,
            version.TITAN_ABI_VERSION, types.serialize(entry.type)))
        local payload = assert(objectmetadata.encode(entry, {}))
        local code = util.render(core.coder.modmetadata, {
            METADATANAME = "native_public_metadata",
            METADATA = assert(staticmetadata.c_initializer(public)),
        }) .. assert(objectmetadata.render(payload, "native_source_metadata"))
        local stem = temporary.name()
        local source, output = stem .. ".c", stem .. ".o"
        local ok, failure = xpcall(function()
            assert(util.set_file_contents(source, code))
            local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
            for _, flag in ipairs({ "-std=c99", "-O3", "-fPIC" }) do
                argv[#argv + 1] = flag
            end
            if linux then
                argv[#argv + 1], argv[#argv + 2] = "-flto=auto", "-ffat-lto-objects"
            end
            for _, argument in ipairs({ "-c", source, "-o", output }) do
                argv[#argv + 1] = argument
            end
            local compiled = strategy:run(argv)
            assert.is_true(compiled.ok, compiled.output or compiled.diagnostic)
            local bytes = assert(util.get_file_contents(output, "rb"))
            local object = assert(staticmetadata.classify_object(bytes, output))
            assert.equal(public, object.metadata.payload)
            local restored = assert(objectmetadata.read(bytes, output))
            assert.equal(entry.type.name, restored.type.name)
            local structure = restored.type.source_members.head.type.pointee
            assert.equal(structure, structure.fields.next.owner)
            if linux then
                assert.equal("elf", object.format)
                local has_lto = false
                for _, section in ipairs(object.sections) do
                    if section.name == ".llvm.lto" or section.name:match("^%.gnu%.lto_") then
                        has_lto = true
                    end
                end
                assert.is_true(has_lto, "compiler did not emit a native fat LTO object")
            end
        end, debug.traceback)
        os.remove(source)
        os.remove(output)
        os.remove(stem)
        assert.is_true(ok, failure)
    end)

    it("reads real Clang Windows metadata and enum result objects without an SDK", function()
        local strategy = require("titan-compiler.io").new_sync()
        if not strategy:run({ "clang", "--version" }).ok then
            pending("Clang is required for the cross-target COFF probe")
            return
        end
        local core = require "titan-compiler.coder.core"
        require "titan-compiler.coder.module"
        local util = require "titan-compiler.util"
        local entry = source_entry()
        local public = assert(staticmetadata.render(entry.type.name,
            version.TITAN_ABI_VERSION, types.serialize(entry.type)))
        local source_record = assert(objectmetadata.encode(entry, {}))
        local code = util.render(core.coder.modmetadata, {
            METADATANAME = "native_public_metadata",
            METADATA = assert(staticmetadata.c_initializer(public)),
        }) .. assert(objectmetadata.render(source_record, "native_source_metadata")) .. [[
enum carrier { NEGATIVE = -1, POSITIVE = 1 };
extern enum carrier value;
__attribute__((used, aligned(1), section(".titan.cprobe")))
static const unsigned char result[] = {84,73,84,69,78,85,77,0,1,12,
    __builtin_types_compatible_p(__typeof__(&value), int *), 6};
]]
        local stem = temporary.name()
        local source, output = stem .. ".c", stem .. ".o"
        local ok, failure = xpcall(function()
            assert(util.set_file_contents(source, code))
            local compiled = strategy:run({ "clang", "--target=x86_64-w64-windows-gnu",
                "-std=c99", "-O0", "-fno-lto", "-Wall", "-Werror", "-c", source, "-o", output })
            assert.is_true(compiled.ok, compiled.output or compiled.diagnostic)
            local bytes = assert(util.get_file_contents(output, "rb"))
            local object = assert(staticmetadata.classify_object(bytes, output))
            assert.same({ format = "coff", machine = 0x8664, word_size = 64,
                endian = "little" }, object.fingerprint)
            assert.equal(public, object.metadata.payload)
            local restored = assert(objectmetadata.read(bytes, output))
            assert.equal(entry.type.name, restored.type.name)
            assert.equal(restored.type.source_members.head.type.pointee,
                restored.type.source_members.head.type.pointee.fields.next.owner)
            local result = assert(staticmetadata.read_object_section(bytes, output,
                { elf = ".titan.cprobe", coff = ".titan.cprobe",
                    macho_segment = "__DATA", macho_section = "__titancprobe" }, 12))
            assert.equal("TITENUM\0\1\12\1\6", result)
        end, debug.traceback)
        os.remove(source)
        os.remove(output)
        os.remove(stem)
        assert.is_true(ok, failure)
    end)

    it("treats absent sections, Lua failures and incompatible ABI as cache misses", function()
        local payload = assert(objectmetadata.encode(source_entry(), {}))
        assert.is_nil(objectmetadata.read(elf_object("", { section_name = ".other" })))
        assert.is_nil(objectmetadata.decode("return {"))
        assert.is_nil(objectmetadata.decode("return missing.field"))
        local restored, err = objectmetadata.decode(payload, "producer.o", "other-abi")
        assert.is_nil(restored)
        assert.matches("ABI mismatch", err, 1, true)
    end)

    it("rejects absent old and mismatched certification envelopes", function()
        local function payload(schema, digest, canonicalization)
            return "return {abi=" .. string.format("%q", version.TITAN_ABI_VERSION)
                .. ",schema=" .. (schema and string.format("%q", schema) or "nil")
                .. ",digest=" .. (digest and string.format("%q", digest) or "nil")
                .. ",canonicalization=" .. (canonicalization and string.format("%q", canonicalization) or "nil")
                .. ",entry={compiler_owned_extension=true}}"
        end
        for _, envelope in ipairs({
            { nil, nil, nil },
            { "old", version.CERTIFICATE_DIGEST, version.CERTIFICATE_CANONICALIZATION },
            { version.OBJECT_RECORD_SCHEMA, "other-digest", version.CERTIFICATE_CANONICALIZATION },
            { version.OBJECT_RECORD_SCHEMA, nil, version.CERTIFICATE_CANONICALIZATION },
            { version.OBJECT_RECORD_SCHEMA, version.CERTIFICATE_DIGEST, nil },
            { version.OBJECT_RECORD_SCHEMA, version.CERTIFICATE_DIGEST, "obsolete" },
        }) do
            local entry, err, reason = objectmetadata.decode(payload(envelope[1], envelope[2], envelope[3]))
            assert.is_nil(entry)
            assert.equal("record-schema", reason)
            assert.matches("expected schema=", err, 1, true)
        end
        local current = assert(objectmetadata.encode(source_entry(), {}))
        local envelope = assert(load(current, "metadata envelope", "t", {}))()
        assert.equal(version.OBJECT_RECORD_SCHEMA, envelope.schema)
        assert.equal(version.CERTIFICATE_DIGEST, envelope.digest)
        assert.equal(version.CERTIFICATE_CANONICALIZATION, envelope.canonicalization)
        assert.equal(version.TITAN_ABI_VERSION, envelope.abi)
    end)

    it("rejects malformed roots in embedded and C-origin generated header descriptors", function()
        local function payload(entry)
            return "return {abi=" .. string.format("%q", version.TITAN_ABI_VERSION)
                .. ",schema=" .. string.format("%q", version.OBJECT_RECORD_SCHEMA)
                .. ",digest=" .. string.format("%q", version.CERTIFICATE_DIGEST)
                .. ",canonicalization=" .. string.format("%q", version.CERTIFICATE_CANONICALIZATION)
                .. ",entry=" .. entry .. "}"
        end
        for _, entry in ipairs({
            "{ffi_header_descriptor={roots={sdk=1}}}",
            "{ffi_header_descriptor={roots={unknown='/sdk'}}}",
            "{ffi_header_descriptor={dependencies={{roots={sdk=''}}}}}",
            "{type={_tag='Type.CUnion',_c_origin_header={generated_header={roots='sdk'}}}}",
        }) do
            local restored, err, reason = objectmetadata.decode(payload(entry))
            assert.is_nil(restored)
            assert.equal("record-schema", reason)
            assert.matches("header relocation roots", err, 1, true)
        end
        assert.is_table(objectmetadata.decode(payload("{ffi_header_descriptor={dependencies={}}}")))
    end)

    it("loads compiler records without a second declaration schema validation", function()
        local payload = "return { abi=" .. string.format("%q", version.TITAN_ABI_VERSION)
            .. ", schema=" .. string.format("%q", version.OBJECT_RECORD_SCHEMA)
            .. ", digest=" .. string.format("%q", version.CERTIFICATE_DIGEST)
            .. ", canonicalization=" .. string.format("%q", version.CERTIFICATE_CANONICALIZATION)
            .. ", entry={compiler_owned_extension=true} }"
        assert.same({ compiler_owned_extension = true },
            assert(objectmetadata.decode(payload)))
    end)
end)

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

local ABI = "2"
local TYPES = "Module(\"pkg.mod\",{}, {})"
local PAYLOAD = assert(staticmetadata.render("pkg.mod", ABI, TYPES))

local function scan(bytes, options)
    options = options or {}
    options.expected_abi = options.expected_abi or ABI
    return staticmetadata.scan_bytes(bytes, "fixture with spaces", options)
end

describe("static compiled-module metadata", function()
    describe("strategy-backed archive reads", function()
        local function file_stat(size, modified_seconds)
            return {
                kind = "file",
                size = size,
                modified_seconds = modified_seconds or 1,
                modified_nanoseconds = 2,
            }
        end

        it("rejects non-files, oversized or short reads, and restat races",
        function()
            local cases = {
                {
                    name = "non-file",
                    stats = {{
                        kind = "directory",
                        size = 0,
                        modified_seconds = 1,
                        modified_nanoseconds = 2,
                    }},
                    contents = "",
                    expected = "input is not a regular file",
                },
                {
                    name = "oversized",
                    stats = { file_stat(2) },
                    contents = "ab",
                    max_input_size = 1,
                    expected = "input size 2 exceeds limit 1",
                },
                {
                    name = "short read",
                    stats = { file_stat(2) },
                    contents = "a",
                    expected = "short read (expected 2 bytes, found 1)",
                },
                {
                    name = "disappeared",
                    stats = { file_stat(2), false },
                    contents = "ab",
                    expected = "input disappeared while being read",
                },
                {
                    name = "changed",
                    stats = { file_stat(2), file_stat(2, 3) },
                    contents = "ab",
                    expected = "input changed while it was being read",
                },
            }

            for _, case in ipairs(cases) do
                local stat_calls = 0
                local strategy = {}
                function strategy:stat()
                    stat_calls = stat_calls + 1
                    local result = case.stats[stat_calls]
                    if result == false then return nil end
                    return result
                end
                function strategy:read_file()
                    return case.contents
                end

                local result, err = staticmetadata.scan_archive(
                    "virtual.a", {
                        io = strategy,
                        max_input_size = case.max_input_size,
                    })
                assert.is_nil(result, case.name)
                assert.matches(case.expected, err, 1, true, case.name)
            end
        end)
    end)

    describe("canonical Lua payload", function()
        it("validates canonical logical import inventories independently of types", function()
            local payload = assert(staticmetadata.render("pkg.mod", ABI, TYPES, nil,
                { "a.dep", "z.dep" }))
            local entry = assert(staticmetadata.validate(payload, "archive"))
            assert.same({ "a.dep", "z.dep" }, entry.imports)
            local empty = assert(staticmetadata.render("pkg.mod", ABI, TYPES, nil, {}))
            assert.same({}, assert(staticmetadata.validate(empty, "archive")).imports)
            assert.is_nil(assert(staticmetadata.validate(PAYLOAD, "legacy")).imports)

            for _, imports in ipairs({
                "not an array", { extra = "a.dep" }, { [2] = "a.dep" },
                { "a.dep", "a.dep" }, { "z.dep", "a.dep" }, { "pkg.mod" },
                { "a/dep.so" }, { false },
            }) do
                local invalid, err = staticmetadata.render("pkg.mod", ABI, TYPES, nil, imports)
                assert.is_nil(invalid, err)
            end
            local invalid, err = staticmetadata.validate(
                (payload:gsub('"z.dep"', '"a.dep"')), "archive")
            assert.is_nil(invalid)
            assert.matches("imports must be distinct", err, 1, true)
        end)

        it("keeps source requirements independent of written archive imports", function()
            local required = { "a.source", "z.source" }
            local payload = assert(staticmetadata.render("pkg.mod", ABI, TYPES, nil,
                { "pkg.helper" }, required))
            local entry = assert(staticmetadata.validate(payload, "archive"))
            assert.same({ "pkg.helper" }, entry.imports)
            assert.same(required, entry.source_requirements)
            assert.is_nil(assert(staticmetadata.validate(PAYLOAD, "legacy")).source_requirements)
            assert.same(required,
                assert(staticmetadata.decode_source_requirements("pkg.mod", "a.source\nz.source")))
            for _, malformed in ipairs({
                "", "\na.source", "a.source\n", "a.source\n\nz.source",
                "z.source\na.source", "a.source\na.source", "pkg.mod", "path/file.so",
            }) do
                assert.is_nil(staticmetadata.decode_source_requirements("pkg.mod", malformed))
            end
            assert.is_nil(staticmetadata.render("pkg.mod", ABI, TYPES, nil, nil, {}))
            assert.is_nil(staticmetadata.validate(
                (payload:gsub('"z.source"', '"a.source"')), "archive"))
        end)

        it("accepts only compiler-emittable relative dynamic carriers", function()
            for _, relative in ipairs({ "titan.so", "titan.dll", "dep.so", "other/api.so",
                    "pkg/titan.so", "a/b/c.dll" }) do
                assert.is_true(staticmetadata.valid_relative_provider(relative), relative)
            end
            for _, relative in ipairs({ "", ".so", "dep", "dep.a", "dep.so.1", "dep.SO",
                    "../dep.so", "./dep.so", "a/../dep.so", "a/./dep.so", "a.b.so",
                    "/dep.so", "dep/.so", "a//b.so", "a\\b.so", "C:/dep.so", "C:dep.so",
                    "//host/share/dep.so", "a b.so", "a\nb.so", false, 1 }) do
                assert.is_false(staticmetadata.valid_relative_provider(relative), tostring(relative))
            end
        end)

        it("keeps producer-proved dynamic carriers canonical and optional", function()
            local carriers = { ["titan.json"] = "titan.so", ["dep.owner"] = "other/api.so" }
            local encoded = "dep.owner\tother/api.so\ntitan.json\ttitan.so"
            assert.equal(encoded, staticmetadata.encode_dynamic_providers("pkg.mod", carriers))
            assert.same(carriers, staticmetadata.decode_dynamic_providers("pkg.mod", encoded))
            for _, malformed in ipairs({
                "", "\n", "titan.json\ttitan.so\ndep.owner\tother/api.so",
                "dep.owner\tother/api.so\n", "\ndep.owner\tother/api.so",
                "dep.owner\tother/api.so\ndep.owner\tother/api.so",
                "dep.owner other/api.so", "dep.owner\tother/api.so\tx",
                "pkg.mod\tpkg.so", "dep.owner\t../api.so", "bad name\tdep.so",
            }) do
                assert.is_nil(staticmetadata.decode_dynamic_providers("pkg.mod", malformed), malformed)
            end
            for _, invalid in ipairs({ {}, setmetatable({}, {}), { ["pkg.mod"] = "pkg.so" },
                    { ["dep.owner"] = "dep" }, "dep.owner\tdep.so" }) do
                assert.is_nil(staticmetadata.encode_dynamic_providers("pkg.mod", invalid))
            end

            local payload = assert(staticmetadata.render("pkg.mod", ABI, TYPES, nil,
                nil, { "a.source" }, carriers))
            local entry = assert(staticmetadata.validate(payload, "archive"))
            assert.same(carriers, entry.dynamic_providers)
            assert.same({ "a.source" }, entry.source_requirements)
            assert.is_nil(assert(staticmetadata.validate(PAYLOAD, "legacy")).dynamic_providers)
            assert.is_nil(staticmetadata.render("pkg.mod", ABI, TYPES, nil, nil, nil, {}))
            local invalid, err = staticmetadata.validate(
                (payload:gsub('"other/api.so"', '"../api.so"')), "archive")
            assert.is_nil(invalid)
            assert.matches("invalid relative provider in dynamic_providers", err, 1, true)
        end)

        it("keeps physical layouts independent from semantic-only readers", function()
            local payload = assert(staticmetadata.render("pkg.mod", ABI, TYPES, "layout-bytes"))
            local semantic = assert(staticmetadata.validate(payload, "analysis", {
                expected_abi = ABI,
                validate_types = function(name, serialized)
                    assert.equal("pkg.mod", name)
                    assert.equal(TYPES, serialized)
                    return { semantic = true }
                end,
            }))
            assert.same({ semantic = true }, semantic.decoded_types)
            assert.is_nil(semantic.decoded_layouts)
            assert.equal("layout-bytes", semantic.layouts)
            local physical = assert(staticmetadata.validate(payload, "native", {
                expected_abi = ABI, require_layouts = true,
                validate_layouts = function(name, serialized)
                    assert.equal("pkg.mod", name)
                    assert.equal("layout-bytes", serialized)
                    return { physical = true }
                end,
            }))
            assert.same({ physical = true }, physical.decoded_layouts)
            assert.is_nil(physical.decoded_types)
            assert(staticmetadata.validate(PAYLOAD, "legacy analysis"))
            local missing, err = staticmetadata.validate(PAYLOAD, "native", {
                require_layouts = true,
            })
            assert.is_nil(missing)
            assert.matches("missing nominal layout metadata", err, 1, true)
            local invalid
            invalid, err = staticmetadata.validate(payload, "native", {
                validate_layouts = function() return nil, "bad physical plan" end,
            })
            assert.is_nil(invalid)
            assert.matches("bad physical plan", err, 1, true)
            invalid, err = staticmetadata.render("pkg.mod", ABI, TYPES, {})
            assert.is_nil(invalid)
            assert.matches("layouts must be a string", err, 1, true)
        end)

        it("renders exact stable bytes and a numeric C initializer", function()
            assert.equal([[
-- Titan archive module metadata v1
return {
    ["pkg.mod"] = {
        abi = "2",
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

        it("requires portable logical module components", function()
            for _, name in ipairs({
                "pkg", "titan", "pkg.mod", "pkg.titan.child",
                "pkg-name._part2",
            }) do
                assert.truthy(staticmetadata.valid_module_name(name), name)
            end
            for _, name in ipairs({
                "", ".pkg", "pkg.", "pkg..mod", "1pkg", "-pkg",
                "pkg.$line", "pkg space", "pkg/mod", "pkg.titan",
            }) do
                assert.falsy(staticmetadata.valid_module_name(name), name)
                local payload, err = staticmetadata.render(name, ABI, TYPES)
                assert.falsy(payload)
                assert.match("invalid logical Titan module name", err, 1, true)
            end
        end)

        it("allows a reserved terminal component only in provider prefixes",
           function()
            for _, prefix in ipairs({
                "titan", "pkg.titan", "pkg.titan.child", "pkg-name._part2",
            }) do
                assert.truthy(
                    staticmetadata.valid_provider_prefix(prefix), prefix)
            end
            for _, prefix in ipairs({
                "", ".pkg", "pkg.", "pkg..titan", "1pkg",
                "pkg.$line", "pkg space", "pkg/titan",
            }) do
                assert.falsy(
                    staticmetadata.valid_provider_prefix(prefix), prefix)
            end
            assert.falsy(staticmetadata.valid_module_name("pkg.titan"))
        end)

        it("rejects canonical whitespace, ordering, and quoting variations", function()
            local variants = {
                (PAYLOAD:gsub("return {", "return  {", 1)),
                (PAYLOAD:gsub(
                    '        abi = "2",\n        types = ([^\n]+)',
                    "        types = %1\n        abi = \"2\",", 1)),
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
                        "return { ['bad..name'] = { abi='2', types='x' } }\n",
                    "invalid logical Titan module key",
                },
                {
                    staticmetadata.BANNER ..
                        "return { [{}] = { abi='2', types='x' } }\n",
                    "invalid logical Titan module key",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { abi='2', types='x', extra=true } }\n",
                    "unknown field",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { [1]='2', types='x' } }\n",
                    "unknown field",
                },
                {
                    staticmetadata.BANNER ..
                        "return { m = { abi='2', types='x', [{}]=true } }\n",
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
                "pkg.mod", "1", TYPES))
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

    describe("COFF relocatable objects", function()
        it("reads public metadata and distinguishes machine targets", function()
            local target = assert(scan(coff_object(PAYLOAD))).fingerprint
            for _, machine in ipairs({ 0x14c, 0x8664, 0xaa64 }) do
                local object = assert(scan(coff_object(PAYLOAD, { machine = machine })))
                assert.equal("object", object.kind)
                assert.equal("coff", object.format)
                assert.equal(machine, object.fingerprint.machine)
                assert.equal(machine == 0x14c and 32 or 64, object.fingerprint.word_size)
                assert.equal("little", object.fingerprint.endian)
                assert.equal("pkg.mod", object.metadata.module)
                if machine ~= target.machine then
                    local mismatch, err = scan(coff_object(PAYLOAD, { machine = machine }),
                        { target = target })
                    assert.is_nil(mismatch)
                    assert.matches("target mismatch", err, 1, true)
                end
            end
            assert.is_false(staticmetadata.fingerprint_matches(target,
                assert(scan(elf_object(PAYLOAD))).fingerprint))
        end)

        it("rejects malformed headers, section names, payloads and native tables", function()
            local cases = {
                { { optional_size = 1 }, "not a relocatable" },
                { { flags = 2 }, "not a relocatable" },
                { { flags = 0x2000 }, "not a relocatable" },
                { { flags = 0x80 }, "byte-reversed" },
                { { section_count = 0 }, "section table is empty" },
                { { section_count = 0xffff }, "COFF section table" },
                { { duplicate = true }, "more than one" },
                { { raw_name = "/bad" }, "long section name offset" },
                { { raw_name = "/3" }, "long section name offset" },
                { { raw_name = "/999999" }, "outside its string table" },
                { { symbol_offset = 0 }, "no string table" },
                { { symbol_offset = 0, symbol_count = 1 }, "has no offset" },
                { { symbol_offset = 0xffff }, "outside the input" },
                { { symbol_count = 0xffffffff }, "COFF symbol table" },
                { { strings = uint(3, 4) }, "less than 4" },
                { { strings = uint(1000, 4) }, "outside the input" },
                { { strings = uint(15, 4) .. ".titan.meta" }, "not NUL-terminated" },
                { { data_offset = 0xffff }, "outside the input" },
                { { data_size = 0xffffffff }, "outside the input" },
                { { section_flags = 0x80 }, "not initialized COFF data" },
                { { relocations = 1 }, "has relocations" },
                { { relocations = 1, relocation_offset = 0xffff }, "COFF relocation table" },
                { { section_flags = 0x01000040 }, "overflow count" },
                { { relocations = 0xffff, relocation_data = uint(10, 4),
                    section_flags = 0x01000040 }, "extended relocation count" },
                { { relocations = 0xffff, relocation_data = uint(0xffffffff, 4),
                    section_flags = 0x01000040 }, "COFF relocation table" },
                { { line_count = 1, line_offset = 0xffff }, "COFF line-number table" },
            }
            for _, case in ipairs(cases) do
                local object, err = scan(coff_object(PAYLOAD, case[1]))
                assert.is_nil(object)
                assert.matches(case[2], err, 1, true)
                assert.matches("fixture with spaces", err, 1, true)
            end
            local bytes = coff_object(PAYLOAD)
            for _, size in ipairs({ 2, 19, 59, #bytes - 1 }) do
                assert.is_nil(scan(bytes:sub(1, size)))
            end
        end)

        it("bounds relocation overflow tables in ordinary objects", function()
            local count = 0x10000
            local object = assert(scan(coff_object("code", {
                section_name = ".text", section_flags = 0x01000020,
                relocations = 0xffff,
                relocation_data = uint(count, 4) .. zeros(count * 10 - 4),
            })))
            assert.equal(count - 1, object.sections[1].relocation_count)
        end)

        it("rejects PE images, import objects and BigObj explicitly", function()
            local cases = {
                { "MZ" .. zeros(100), "PE image is not a relocatable object" },
                { "\0\0\255\255" .. zeros(16), "COFF import objects" },
                { "\0\0\255\255\2\0\100\134" .. zeros(4) ..
                    "\199\161\186\209\238\186\169\75\175\32\250\246\106\164\220\184" ..
                    zeros(28), "COFF BigObj objects" },
            }
            for _, case in ipairs(cases) do
                local object, err = scan(case[1])
                assert.is_nil(object)
                assert.matches(case[2], err, 1, true)
            end
        end)
    end)

    describe("Wasm relocatable objects", function()
        it("reads all three payloads, padded LEB128 fields, symbols and imports", function()
            local source_payload = "source-record-bytes"
            local probe_payload = "TITENUM\0\1\12\1\6"
            for _, pad in ipairs({ false, true }) do
                local bytes = wasm_object(nil, {
                    pad = pad,
                    include_datacount = true,
                    include_code = true,
                    imports = {
                        { module = "env", name = "__linear_memory", kind = 2, flags = 0, initial = 1 },
                        { module = "env", name = "imported_fn", kind = 0, type_index = 0 },
                        { module = "env", name = "__indirect_function_table", kind = 1, elem_type = 0x70, flags = 0, initial = 1 },
                        { module = "env", name = "__stack_pointer", kind = 3, valtype = 0x7f, mutable = 1 },
                        { module = "env", name = "c_longjmp", kind = 4, attribute = 0, type_index = 0 },
                    },
                    segments = {
                        { name = ".rodata.aligned", payload = "12345678", mode = 0, offset = 0, align_exp = 3, flags = 0 },
                        { name = ".tdata.local", payload = "tls!", mode = 0, offset = 8, align_exp = 2, flags = 2 },
                        { name = ".passive.seg", payload = "passive", mode = 1, align_exp = 0, flags = 0 },
                        { name = ".titan.meta", payload = PAYLOAD, mode = 0, offset = 16, align_exp = 0, flags = 0 },
                        { name = ".titan.source", payload = source_payload, mode = 0, offset = 32, align_exp = 0, flags = 0 },
                        { name = ".titan.cprobe", payload = probe_payload, mode = 0, offset = 64, align_exp = 0, flags = 0 },
                    },
                    init_funcs = { { priority = 100, symbol = 1 } },
                    comdats = { { name = "comdat_grp", flags = 0, entries = { { kind = 0, index = 0 } } } },
                    extra_linking_subsections = { "\99" .. uleb(3, pad and 5 or nil) .. "xyz" },
                    symbols = {
                        { kind = 0, flags = 0x10, index = 0 },
                        { kind = 0, flags = 0x00, index = 1, name = "pkg_mod_init" },
                        { kind = 0, flags = 0x01, index = 2, name = "weak_helper" },
                        { kind = 0, flags = 0x02, index = 3, name = "local_helper" },
                        { kind = 0, flags = 0x50, index = 0, name = "explicit_import_alias" },
                        { kind = 1, flags = 0x00, index = 0, name = "rodata_sym", offset = 0, size = 8 },
                        { kind = 1, flags = 0x10, name = "external_data" },
                        { kind = 2, flags = 0x10, index = 0 },
                        { kind = 3, flags = 0x02, index = 0 },
                        { kind = 4, flags = 0x10, index = 0 },
                        { kind = 5, flags = 0x10, index = 0 },
                    },
                    features = {
                        { "+", "sign-ext" },
                        { "-", "shared-mem" },
                        { "+", "bulk-memory" },
                        { "=", "atomics" },
                    },
                })
                local object = assert(scan(bytes))
                assert.equal("object", object.kind)
                assert.equal("wasm", object.format)
                assert.same({
                    format = "wasm",
                    word_size = 32,
                    linking_version = 2,
                    features = "+bulk-memory +sign-ext -shared-mem =atomics",
                }, object.fingerprint)
                assert.equal("pkg.mod", object.metadata.module)
                assert.equal(PAYLOAD, object.metadata_section.payload)
                assert.equal(3, object.metadata_section.index)
                assert.equal(1, object.metadata_section.alignment)
                assert.is_true(object.metadata_section.active)
                assert.is_false(object.metadata_section.tls)
                assert.equal(8, object.sections[1].alignment)
                assert.is_true(object.sections[2].tls)
                assert.is_false(object.sections[3].active)
                assert.same({
                    { module = "env", name = "__linear_memory", kind = "memory" },
                    { module = "env", name = "imported_fn", kind = "function" },
                    { module = "env", name = "__indirect_function_table", kind = "table" },
                    { module = "env", name = "__stack_pointer", kind = "global" },
                    { module = "env", name = "c_longjmp", kind = "tag" },
                }, object.imports)
                assert.same({
                    { kind = "function", name = "imported_fn", binding = "global", defined = false, index = 0 },
                    { kind = "function", name = "pkg_mod_init", binding = "global", defined = true, index = 1 },
                    { kind = "function", name = "weak_helper", binding = "weak", defined = true, index = 2 },
                    { kind = "function", name = "local_helper", binding = "local", defined = true, index = 3 },
                    { kind = "function", name = "explicit_import_alias", binding = "global", defined = false, index = 0 },
                    { kind = "data", name = "rodata_sym", binding = "global", defined = true, index = 0 },
                    { kind = "data", name = "external_data", binding = "global", defined = false, index = nil },
                    { kind = "global", name = "__stack_pointer", binding = "global", defined = false, index = 0 },
                    { kind = "section", name = nil, binding = "local", defined = true, index = 0 },
                    { kind = "tag", name = "c_longjmp", binding = "global", defined = false, index = 0 },
                    { kind = "table", name = "__indirect_function_table", binding = "global", defined = false, index = 0 },
                }, object.symbols)
                local selector = {
                    elf = ".unused", macho_segment = "__DATA",
                    macho_section = "__unused", coff = ".unused",
                    wasm = ".titan.source",
                }
                assert.equal(source_payload, assert(staticmetadata.read_object_section(
                    bytes, "combined.wasm.o", selector, #source_payload)))
                selector.wasm = ".titan.cprobe"
                assert.equal(probe_payload, assert(staticmetadata.read_object_section(
                    bytes, "combined.wasm.o", selector, #probe_payload)))
            end
        end)

        it("rejects every malformed Wasm object and bitcode input with exact diagnostics", function()
            local bad_classify, bad_classify_err =
                staticmetadata.classify_object("bad!", "fixture with spaces")
            assert.is_nil(bad_classify)
            assert.equal('"fixture with spaces": unsupported native object format', bad_classify_err)

            local bad_scan, bad_scan_err = scan("bad!")
            assert.is_nil(bad_scan)
            assert.equal('"fixture with spaces": unsupported native container format', bad_scan_err)

            local oversized_sec = "\0asm\1\0\0\0\1" .. uleb(100) .. "abc"
            local custom_cross = "\0asm\1\0\0\0\0\3\5ab"
            local six_byte_leb = "\0asm\1\0\0\0\1\x80\x80\x80\x80\x80\x00"
            local overflow_leb = "\0asm\1\0\0\0\1\x80\x80\x80\x80\x10"
            local truncated_leb = "\0asm\1\0\0\0\1\x80\x80"

            local cases = {
                { wasm_object(PAYLOAD, { version = 2 }),
                    '"fixture with spaces": unsupported Wasm version 2' },
                { oversized_sec,
                    '"fixture with spaces": Wasm section is outside the input (offset 10, size 100, input size 13)' },
                { six_byte_leb,
                    '"fixture with spaces": Wasm u32 LEB128 exceeds 5 bytes' },
                { overflow_leb,
                    '"fixture with spaces": Wasm u32 LEB128 overflows' },
                { truncated_leb,
                    '"fixture with spaces": truncated Wasm u32 LEB128' },
                { custom_cross,
                    '"fixture with spaces": Wasm custom section name is outside its section' },
                { wasm_object(PAYLOAD, {
                    extra_sections_before_data = { wasm_sec(3, "\0"), wasm_sec(2, "\0") },
                    imports = false,
                }), '"fixture with spaces": out-of-order Wasm section 2' },
                { wasm_object(PAYLOAD, {
                    extra_sections_before_data = { wasm_sec(10, "\0"), wasm_sec(12, "\1") },
                }), '"fixture with spaces": out-of-order Wasm section 12' },
                { wasm_object(PAYLOAD, {
                    no_data_section = true,
                    no_segment_info = true,
                    extra_sections_after_linking = { wasm_sec(11, "\0") },
                }), '"fixture with spaces": out-of-order Wasm section 11' },
                { wasm_object(PAYLOAD, {
                    extra_sections_before_linking = { wasm_custom("reloc.DATA", "\0\0") },
                }), '"fixture with spaces": out-of-order Wasm section 0' },
                { wasm_object(PAYLOAD, {
                    extra_sections_before_data = { wasm_sec(14, "\0") },
                }), '"fixture with spaces": unsupported Wasm section 14' },
                { wasm_object(PAYLOAD, {
                    extra_sections_before_data = { wasm_sec(3, "\0"), wasm_sec(3, "\0") },
                }), '"fixture with spaces": duplicate Wasm section 3' },
                { wasm_object(PAYLOAD, {
                    extra_sections_after_linking = { wasm_custom("linking", "\2") },
                }), '"fixture with spaces": duplicate Wasm section 0' },
                { wasm_object(PAYLOAD, { no_linking = true }),
                    '"fixture with spaces": Wasm object has no linking section' },
                { wasm_object(PAYLOAD, { linking_version = 1 }),
                    '"fixture with spaces": unsupported Wasm linking version 1' },
                { wasm_object(PAYLOAD, { dylink = true }),
                    '"fixture with spaces": Wasm dylink.0 side module is not supported' },
                { wasm_object(PAYLOAD, {
                    imports = { { module = "GOT.mem", name = "foo", kind = 3, valtype = 0x7f, mutable = 1 } },
                }), '"fixture with spaces": Wasm GOT import is not supported' },
                { wasm_object(PAYLOAD, {
                    imports = { { module = "GOT.func", name = "bar", kind = 3, valtype = 0x7f, mutable = 1 } },
                }), '"fixture with spaces": Wasm GOT import is not supported' },
                { wasm_object(PAYLOAD, { memory_flags = 0x04 }),
                    '"fixture with spaces": Wasm memory64 is not supported' },
                { wasm_object(PAYLOAD, { memory_section_flags = 0x04 }),
                    '"fixture with spaces": Wasm memory64 is not supported' },
                { wasm_object(PAYLOAD, { segment_opcode = 0x42 }),
                    '"fixture with spaces": Wasm memory64 is not supported' },
                { wasm_object(PAYLOAD, { memory_flags = 0x02 }),
                    '"fixture with spaces": Wasm shared memory is not supported' },
                { wasm_object(PAYLOAD, { memory_section_flags = 0x03, memory_max = 2 }),
                    '"fixture with spaces": Wasm shared memory is not supported' },
                { wasm_object(PAYLOAD, { segment_info_count = 2 }),
                    '"fixture with spaces": Wasm segment-info count does not match DATA segment count' },
                { wasm_object(PAYLOAD, { no_segment_info = true }),
                    '"fixture with spaces": Wasm segment-info count does not match DATA segment count' },
                { wasm_object(PAYLOAD, { datacount = 2 }),
                    '"fixture with spaces": Wasm DATACOUNT does not match DATA segment count' },
                { wasm_object(nil, { datacount = 1 }),
                    '"fixture with spaces": Wasm DATACOUNT does not match DATA segment count' },
                { wasm_object(PAYLOAD, { duplicate = true }),
                    '"fixture with spaces": duplicate Wasm payload segment ".titan.meta"' },
                { wasm_object(PAYLOAD, { segment_mode = 1 }),
                    '"fixture with spaces": Wasm payload segment ".titan.meta" is not active' },
                { wasm_object(PAYLOAD, { segment_mode = 2, segment_memory = 0 }),
                    '"fixture with spaces": Wasm payload segment ".titan.meta" is not active' },
                { wasm_object(PAYLOAD, { segment_flags = 0x02 }),
                    '"fixture with spaces": Wasm payload segment ".titan.meta" is TLS' },
                { wasm_object(PAYLOAD, { align_exp = 2 }),
                    '"fixture with spaces": Wasm payload segment ".titan.meta" alignment is not 1' },
                { wasm_object(PAYLOAD, { relocation = true }),
                    '"fixture with spaces": Wasm payload segment ".titan.meta" is targeted by a DATA relocation' },
                { wasm_object(PAYLOAD, { relocation = true, relocation_target = 99 }),
                    '"fixture with spaces": Wasm relocation targets missing section 99' },
                { wasm_object(PAYLOAD, { relocation = true, relocation_offset = #PAYLOAD + 20 }),
                    '"fixture with spaces": Wasm relocation is outside its target section' },
                { wasm_object(PAYLOAD, { relocation = true, relocation_type = 99 }),
                    '"fixture with spaces": unsupported Wasm relocation type 99' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "bulk-memory" }, { "-", "bulk-memory" } },
                }), '"fixture with spaces": conflicting Wasm target feature "bulk-memory"' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "bulk-memory" }, { "+", "bulk-memory" } },
                }), '"fixture with spaces": duplicate Wasm target feature "bulk-memory"' },
                { "BC\192\222bitcode",
                    '"fixture with spaces": LLVM bitcode (LTO) object is not supported' },
                { "\222\192\023\011bitcode",
                    '"fixture with spaces": LLVM bitcode (LTO) object is not supported' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "bulk-memory +sign-ext" } },
                }), '"fixture with spaces": invalid Wasm target feature name' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "a +a" } },
                }), '"fixture with spaces": invalid Wasm target feature name' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "a\0b" } },
                }), '"fixture with spaces": invalid Wasm target feature name' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "a\tb" } },
                }), '"fixture with spaces": invalid Wasm target feature name' },
                { wasm_object(PAYLOAD, {
                    features = { { "+", "a\127b" } },
                }), '"fixture with spaces": invalid Wasm target feature name' },
                { wasm_object(PAYLOAD, { segment_offset = -1 }),
                    '"fixture with spaces": malformed Wasm DATA offset expression' },
                { wasm_object(PAYLOAD, { segment_offset = -1, pad = true }),
                    '"fixture with spaces": malformed Wasm DATA offset expression' },
                { wasm_object(PAYLOAD, { segment_offset = -2147483648 }),
                    '"fixture with spaces": malformed Wasm DATA offset expression' },
                { wasm_object(PAYLOAD, { segment_offset = -2147483648, pad = true }),
                    '"fixture with spaces": malformed Wasm DATA offset expression' },
            }
            for index, case in ipairs(cases) do
                local object, err = scan(case[1])
                assert.is_nil(object, "case #" .. tostring(index))
                assert.equal(case[2], err, "case #" .. tostring(index))
            end

            local oversized, oversized_err = scan(wasm_object(PAYLOAD), {
                max_metadata_size = #PAYLOAD - 1,
            })
            assert.is_nil(oversized)
            assert.matches(
                "metadata section size " .. tostring(#PAYLOAD) ..
                " exceeds limit " .. tostring(#PAYLOAD - 1),
                oversized_err, 1, true)

            local section_oversized, section_err = staticmetadata.read_object_section(
                wasm_object("123456", { section_name = ".titan.cprobe" }),
                "probe.wasm.o",
                {
                    elf = ".titan.cprobe", macho_segment = "__DATA",
                    macho_section = "__titancprobe", coff = ".titan.cprobe",
                    wasm = ".titan.cprobe",
                }, 5)
            assert.is_nil(section_oversized)
            assert.equal('"probe.wasm.o": requested object section exceeds size limit', section_err)
            -- Signed i32 and i64 LEB128 boundaries and relocation addends.
            local max_i32_min = assert(scan(wasm_object(PAYLOAD, {
                segment_offset = 2147483647,
            })))
            local max_i32_pad = assert(scan(wasm_object(PAYLOAD, {
                segment_offset = 2147483647,
                pad = true,
            })))
            assert.equal("pkg.mod", max_i32_min.metadata.module)
            assert.equal("pkg.mod", max_i32_pad.metadata.module)

            -- Ordinary Wasm names (imports, custom sections, segments, COMDATs,
            -- and symbols) accept spaces and empty strings as legal length-prefixed
            -- names, while quoting any control bytes safely in diagnostics.
            local spaced = assert(scan(wasm_object(nil, {
                imports = {
                    { module = "env", name = "__linear_memory", kind = 2, flags = 0, initial = 1 },
                    { module = "env space", name = "foo bar", kind = 0, type_index = 0 },
                },
                segments = {
                    { name = ".data with space", payload = "ok", mode = 0, align_exp = 0, flags = 0 },
                    { name = ".titan.meta", payload = PAYLOAD, mode = 0, align_exp = 0, flags = 0 },
                },
                comdats = { { name = "comdat group", flags = 0, entries = {} } },
                symbols = {
                    { kind = 0, flags = 0x10, index = 0 },
                    { kind = 0, flags = 0x02, index = 1, name = "" },
                    { kind = 1, flags = 0x00, index = 0, name = "spaced data", offset = 0, size = 2 },
                },
                extra_sections_after_linking = { wasm_custom("custom section", "payload") },
            })))
            assert.equal("pkg.mod", spaced.metadata.module)
            assert.equal("foo bar", spaced.symbols[1].name)
            assert.equal("", spaced.symbols[2].name)
            assert.equal("spaced data", spaced.symbols[3].name)

            local ctrl_seg, ctrl_seg_err = staticmetadata.read_object_section(
                wasm_object("1234", {
                    segments = {
                        { name = "bad\n\0seg", payload = "1234", mode = 1, align_exp = 0, flags = 0 },
                    },
                }),
                "ctrl.wasm.o",
                {
                    elf = ".unused", macho_segment = "__DATA",
                    macho_section = "__unused", coff = ".unused",
                    wasm = "bad\n\0seg",
                }, 4)
            assert.is_nil(ctrl_seg)
            assert.is_nil(ctrl_seg_err:find("[\0\n]"))
            assert.matches('Wasm payload segment "bad\\n\\0seg" is not active', ctrl_seg_err, 1, true)

            local executed_32 = 0
            for _, addend_32 in ipairs({ 0, -1, -2147483648, 2147483647 }) do
                for _, width in ipairs({ false, 5 }) do
                    local obj32 = assert(scan(wasm_object(nil, {
                        segments = {
                            { name = ".data.x", payload = string.rep("\0", 16), mode = 0, align_exp = 0, flags = 0 },
                            { name = ".titan.meta", payload = PAYLOAD, mode = 0, align_exp = 0, flags = 0 },
                        },
                        relocations = {
                            {
                                name = "reloc.DATA",
                                target = 1,
                                entries = {
                                    { type = 5, offset = 6, symbol = 0, addend = addend_32, addend_width = width or nil },
                                },
                            },
                        },
                    })))
                    assert.equal("pkg.mod", obj32.metadata.module)
                    executed_32 = executed_32 + 1
                end
            end
            assert.equal(8, executed_32)

            local executed_64 = 0
            for _, rtype_64 in ipairs({ 14, 15, 16, 17, 22, 25 }) do
                for _, addend_64 in ipairs({
                    0, -1, 4294967296, -4294967296,
                    math.maxinteger, math.mininteger,
                }) do
                    for _, width in ipairs({ false, 10 }) do
                        local obj64 = assert(scan(wasm_object(nil, {
                            segments = {
                                { name = ".data.x", payload = string.rep("\0", 16), mode = 0, align_exp = 0, flags = 0 },
                                { name = ".titan.meta", payload = PAYLOAD, mode = 0, align_exp = 0, flags = 0 },
                            },
                            relocations = {
                                {
                                    name = "reloc.DATA",
                                    target = 1,
                                    entries = {
                                        { type = rtype_64, offset = 6, symbol = 0, addend = addend_64, addend_width = width or nil },
                                    },
                                },
                            },
                        })))
                        assert.equal("pkg.mod", obj64.metadata.module)
                        executed_64 = executed_64 + 1
                    end
                end
            end
            assert.equal(72, executed_64)

            local sleb_error_cases = {
                { 5, "\x80\x80\x80\x80\x08", '"fixture with spaces": Wasm i32 LEB128 overflows' },
                { 5, "\xff\xff\xff\xff\x77", '"fixture with spaces": Wasm i32 LEB128 overflows' },
                { 5, "\x80\x80\x80\x80\x80\x00", '"fixture with spaces": Wasm i32 LEB128 exceeds 5 bytes' },
                { 5, "\x80\x80", '"fixture with spaces": truncated Wasm i32 LEB128' },
                { 16, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", '"fixture with spaces": Wasm i64 LEB128 overflows' },
                { 16, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\x7e", '"fixture with spaces": Wasm i64 LEB128 overflows' },
                { 16, "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00", '"fixture with spaces": Wasm i64 LEB128 exceeds 10 bytes' },
                { 16, "\x80\x80", '"fixture with spaces": truncated Wasm i64 LEB128' },
            }
            for index, scase in ipairs(sleb_error_cases) do
                local bad_obj, bad_err = scan(wasm_object(nil, {
                    segments = {
                        { name = ".data.x", payload = string.rep("\0", 16), mode = 0, align_exp = 0, flags = 0 },
                    },
                    relocations = {
                        {
                            name = "reloc.DATA",
                            target = 1,
                            entries = {
                                { type = scase[1], offset = 6, symbol = 0, raw_addend = scase[2] },
                            },
                        },
                    },
                }))
                assert.is_nil(bad_obj, "sleb error case #" .. tostring(index))
                assert.equal(scase[3], bad_err, "sleb error case #" .. tostring(index))
            end

            -- OP328-M1: many DATA segments and DATA relocations must scan in
            -- O((relocs + segments) log segments) time rather than quadratically.
            local count = 16000
            local bulk_segments = {}
            local bulk_relocs = {}
            local running_offset = #uleb(count + 1)
            for i = 1, count do
                local body_offset = running_offset + 5
                bulk_segments[i] = {
                    name = ".data.g",
                    payload = "1234",
                    mode = 0,
                    offset = 0,
                    align_exp = 2,
                    flags = 0,
                }
                bulk_relocs[i] = {
                    type = 5,
                    offset = body_offset,
                    symbol = 0,
                    addend = 0,
                }
                running_offset = body_offset + 4
            end
            local meta_body_offset = running_offset + 4 + #uleb(#PAYLOAD)
            bulk_segments[count + 1] = {
                name = ".titan.meta",
                payload = PAYLOAD,
                mode = 0,
                offset = 0,
                align_exp = 0,
                flags = 0,
            }
            local bulk_valid = wasm_object(nil, {
                segments = bulk_segments,
                relocations = {
                    {
                        name = "reloc.DATA",
                        target = 1,
                        entries = bulk_relocs,
                    },
                },
            })
            local start_clock = os.clock()
            local bulk_obj = assert(scan(bulk_valid))
            local elapsed_valid = os.clock() - start_clock
            assert.equal("pkg.mod", bulk_obj.metadata.module)
            assert.equal(count + 1, #bulk_obj.sections)
            assert.is_true(elapsed_valid < 2.0,
                "expected sub-linear scan per relocation, took " .. tostring(elapsed_valid) .. "s")

            bulk_relocs[count + 1] = {
                type = 5,
                offset = meta_body_offset,
                symbol = 0,
                addend = 0,
            }
            local bulk_relocated = wasm_object(nil, {
                segments = bulk_segments,
                relocations = {
                    {
                        name = "reloc.DATA",
                        target = 1,
                        entries = bulk_relocs,
                    },
                },
            })
            start_clock = os.clock()
            local rejected_bulk, rejected_bulk_err = scan(bulk_relocated)
            local elapsed_rejected = os.clock() - start_clock
            assert.is_nil(rejected_bulk)
            assert.equal(
                '"fixture with spaces": Wasm payload segment ".titan.meta" is targeted by a DATA relocation',
                rejected_bulk_err)
            assert.is_true(elapsed_rejected < 2.0,
                "expected sub-linear rejection scan, took " .. tostring(elapsed_rejected) .. "s")
        end)

        it("reports Wasm fingerprint mismatches field by field and rejects mixed archives", function()
            local baseline = assert(scan(wasm_object(PAYLOAD))).fingerprint
            local ok, mismatch = staticmetadata.fingerprint_matches(
                { format = "elf", class = 64, endian = "little", machine = 62, flags = 0 },
                baseline)
            assert.is_false(ok)
            assert.equal("object format elf does not match target format wasm", mismatch)

            ok, mismatch = staticmetadata.fingerprint_matches(
                { format = "wasm", word_size = 64, linking_version = 1, features = "" },
                baseline)
            assert.is_false(ok)
            assert.equal("Wasm word_size 64 does not match target 32", mismatch)

            ok, mismatch = staticmetadata.fingerprint_matches(
                { format = "wasm", word_size = 32, linking_version = 1, features = "" },
                baseline)
            assert.is_false(ok)
            assert.equal("Wasm linking_version 1 does not match target 2", mismatch)

            ok, mismatch = staticmetadata.fingerprint_matches(
                { format = "wasm", word_size = 32, linking_version = 2, features = "+sign-ext" },
                baseline)
            assert.is_false(ok)
            assert.equal("Wasm features +sign-ext does not match target +bulk-memory +sign-ext", mismatch)

            local injected_bytes = wasm_object(PAYLOAD, {
                features = { { "+", "bulk-memory +sign-ext" } },
            })
            local injected_obj, injected_err = staticmetadata.classify_object(
                injected_bytes, "injected.o", baseline)
            assert.is_nil(injected_obj)
            assert.equal('"injected.o": invalid Wasm target feature name', injected_err)

            local injected_ar, injected_ar_err = scan(archive({
                ar_member("mod.o/", wasm_object(PAYLOAD)),
                ar_member("injected.o/", injected_bytes),
            }), { target = baseline })
            assert.is_nil(injected_ar)
            assert.matches('archive member #2 .* name "injected.o": invalid Wasm target feature name', injected_ar_err)

            local other_payload = assert(staticmetadata.render(
                "pkg.other", ABI, 'Module("pkg.other",{}, {})'))
            local valid_archive = assert(scan(archive({
                ar_member("mod.o/", wasm_object(PAYLOAD)),
                ar_member("other.o/", wasm_object(other_payload)),
                ar_member("helper.o/", wasm_object(nil, {
                    segments = { { name = ".rodata", payload = "ok", mode = 0, align_exp = 0, flags = 0 } },
                })),
            }), { target = baseline }))
            assert.equal("archive", valid_archive.kind)
            assert.equal(3, #valid_archive.members)
            assert.same({ "pkg.mod", "pkg.other" }, valid_archive.key_order)

            local mixed_elf, mixed_elf_err = scan(archive({
                ar_member("wasm.o/", wasm_object(PAYLOAD)),
                ar_member("elf.o/", elf_object(other_payload)),
            }))
            assert.is_nil(mixed_elf)
            assert.matches('archive member #2 .* name "elf.o": target mismatch: object format elf does not match target format wasm', mixed_elf_err)

            local mixed_wasm_second, mixed_wasm_second_err = scan(archive({
                ar_member("elf.o/", elf_object(PAYLOAD)),
                ar_member("wasm.o/", wasm_object(other_payload)),
            }))
            assert.is_nil(mixed_wasm_second)
            assert.matches('archive member #2 .* name "wasm.o": target mismatch: object format wasm does not match target format elf', mixed_wasm_second_err)

            local mixed_features, mixed_features_err = scan(archive({
                ar_member("first.o/", wasm_object(PAYLOAD)),
                ar_member("second.o/", wasm_object(other_payload, {
                    features = { { "+", "bulk-memory" } },
                })),
            }))
            assert.is_nil(mixed_features)
            assert.matches('archive member #2 .* name "second.o": target mismatch: Wasm features %+bulk%-memory does not match target %+bulk%-memory %+sign%-ext', mixed_features_err)

            local dup_keys, dup_keys_err = scan(archive({
                ar_member("first.o/", wasm_object(PAYLOAD)),
                ar_member("second.o/", wasm_object(PAYLOAD)),
            }))
            assert.is_nil(dup_keys)
            assert.matches('archive member #2 .* name "second.o".*duplicate logical metadata key "pkg.mod"; first declared at .*"first.o"', dup_keys_err)

            local bitcode_member, bitcode_member_err = scan(archive({
                ar_member("first.o/", wasm_object(PAYLOAD)),
                ar_member("lto.o/", "BC\192\222payload"),
            }))
            assert.is_nil(bitcode_member)
            assert.matches('archive member #2 .* name "lto.o": LLVM bitcode %(LTO%) object is not supported', bitcode_member_err)
        end)

        it("opts into independent archive members for content audits without weakening explicit targets or validation", function()
            local other_payload = assert(staticmetadata.render(
                "pkg.other", ABI, 'Module("pkg.other",{}, {})'))
            local full = wasm_object(PAYLOAD)
            local scalar = wasm_object(other_payload, { features = false })
            local bytes = archive({ ar_member("full.o/", full), ar_member("scalar.o/", scalar) })
            local rejected, err = scan(bytes)
            assert.is_nil(rejected)
            assert.matches('name "scalar.o": target mismatch: Wasm features', err)

            local audited = assert(scan(bytes, { independent_members = true }))
            assert.equal(2, #audited.members)
            assert.same({ "pkg.mod", "pkg.other" }, audited.key_order)
            assert.equal("+bulk-memory +sign-ext", audited.members[1].fingerprint.features)
            assert.equal("", audited.members[2].fingerprint.features)
            assert(scan(archive({ ar_member("scalar.o/", scalar), ar_member("full.o/", full) }),
                { independent_members = true }))
            local target = assert(scan(full)).fingerprint
            rejected, err = scan(bytes, { independent_members = true, target = target })
            assert.is_nil(rejected)
            assert.matches('name "scalar.o": target mismatch: Wasm features', err)

            for _, invalid in ipairs({
                { full, "duplicate logical metadata key" },
                { "BC\192\222payload", "LLVM bitcode" },
                { wasm_object(other_payload, { features = { { "+", "invalid feature" } } }),
                    "invalid Wasm target feature name" },
            }) do
                rejected, err = scan(archive({
                    ar_member("full.o/", full), ar_member("invalid.o/", invalid[1]),
                }), { independent_members = true })
                assert.is_nil(rejected)
                assert.matches(invalid[2], err)
            end
        end)

        it("permits standalone -shared-mem SjLj feature differences only in non-threaded comparisons", function()
            local function fp(features)
                return { format = "wasm", word_size = 32, linking_version = 2, features = features }
            end

            -- Both operand orders and marker-only/empty boundary succeed in non-threaded comparisons.
            for _, pair in ipairs({
                { "+bulk-memory +sign-ext -shared-mem", "+bulk-memory +sign-ext" },
                { "+bulk-memory +sign-ext", "+bulk-memory +sign-ext -shared-mem" },
                { "-shared-mem", "" },
                { "", "-shared-mem" },
                { "-shared-mem", "-shared-mem" },
            }) do
                local ok, err = staticmetadata.fingerprint_matches(fp(pair[1]), fp(pair[2]))
                assert.is_true(ok, err)
            end

            -- Lookalike feature names, duplicate/conflicting markers, threading/atomics tokens,
            -- and unrelated feature additions/removals/sign changes all fail.
            for _, pair in ipairs({
                { "-shared-mem+atomics", "+atomics" },
                { "+atomics", "-shared-mem+atomics" },
                { "+bulk-memory -shared-memory", "+bulk-memory" },
                { "+bulk-memory -shared-mem-ext", "+bulk-memory" },
                { "+bulk-memory -shared-mem -shared-mem", "+bulk-memory" },
                { "+bulk-memory +shared-mem -shared-mem", "+bulk-memory" },
                { "+bulk-memory =shared-mem -shared-mem", "+bulk-memory" },
                { "+atomics -shared-mem", "+atomics" },
                { "+atomics", "+atomics -shared-mem" },
                { "=atomics -shared-mem", "=atomics" },
                { "-atomics -shared-mem", "-atomics" },
                { "+shared-mem", "-shared-mem" },
                { "=shared-mem", "-shared-mem" },
                { "+bulk-memory -shared-mem", "+bulk-memory +sign-ext" },
                { "-bulk-memory -shared-mem", "+bulk-memory" },
                { " +bulk-memory -shared-mem", "+bulk-memory" },
                { "+bulk-memory  -shared-mem", "+bulk-memory" },
            }) do
                local ok, err = staticmetadata.fingerprint_matches(fp(pair[1]), fp(pair[2]))
                assert.is_false(ok, pair[1] .. " vs " .. pair[2])
                assert.equal("Wasm features " .. pair[1] .. " does not match target " .. pair[2], err)
            end

            -- Targeted and untargeted mixed archives with -shared-mem and non--shared-mem members
            -- retain raw per-member features while passing non-threaded compatibility checks.
            local other_payload = assert(staticmetadata.render(
                "pkg.other", ABI, 'Module("pkg.other",{}, {})'))
            local sjlj_obj = wasm_object(PAYLOAD, {
                features = {
                    { "+", "bulk-memory" },
                    { "+", "sign-ext" },
                    { "-", "shared-mem" },
                },
            })
            local plain_obj = wasm_object(other_payload, {
                features = {
                    { "+", "bulk-memory" },
                    { "+", "sign-ext" },
                },
            })
            local baseline = fp("+bulk-memory +sign-ext")
            for _, member_order in ipairs({
                { ar_member("sjlj.o/", sjlj_obj), ar_member("plain.o/", plain_obj) },
                { ar_member("plain.o/", plain_obj), ar_member("sjlj.o/", sjlj_obj) },
            }) do
                local untargeted = assert(scan(archive(member_order)))
                local targeted = assert(scan(archive(member_order), { target = baseline }))
                assert.equal(2, #untargeted.members)
                assert.equal(2, #targeted.members)
            end
            local parsed_mixed = assert(scan(archive({
                ar_member("sjlj.o/", sjlj_obj),
                ar_member("plain.o/", plain_obj),
            }), { target = baseline }))
            assert.equal("+bulk-memory +sign-ext -shared-mem", parsed_mixed.members[1].fingerprint.features)
            assert.equal("+bulk-memory +sign-ext", parsed_mixed.members[2].fingerprint.features)

            -- Mixed archive with +atomics and -shared-mem is rejected even untargeted.
            local threaded_sjlj = wasm_object(PAYLOAD, {
                features = {
                    { "+", "atomics" },
                    { "-", "shared-mem" },
                },
            })
            local threaded_plain = wasm_object(other_payload, {
                features = {
                    { "+", "atomics" },
                },
            })
            local rejected_ar, rejected_err = scan(archive({
                ar_member("t1.o/", threaded_sjlj),
                ar_member("t2.o/", threaded_plain),
            }))
            assert.is_nil(rejected_ar)
            assert.matches('archive member #2 .* name "t2.o": target mismatch: Wasm features %+atomics does not match target %+atomics %-shared%-mem', rejected_err)
        end)

        it("classifies Wasm objects and archives and persists Wasm part fingerprints", function()
            local incremental = require "titan-compiler.incremental"
            local wasm_part = wasm_object(nil, {
                pad = true,
                segments = { { name = ".rodata", payload = "part\n", mode = 0, align_exp = 0, flags = 0 } },
            })
            local wasm_ar = archive({ ar_member("part.o/", wasm_part) })
            local bitcode_ar = archive({
                ar_member("part.o/", wasm_part),
                ar_member("lto.o/", "BC\192\222payload"),
            })
            local linked_wasm = wasm_object(PAYLOAD, { no_linking = true })
            local side_wasm = wasm_object(PAYLOAD, { dylink = true })

            local strategy = require("titan-compiler.io").new_sync()
            local root = temporary.name("-wasm-inc")
            assert(strategy:mkdir(root))
            local obj_path = root .. "/part.o"
            local ar_path = root .. "/libpart.a"
            local bc_path = root .. "/lto.o"
            local bcar_path = root .. "/liblto.a"
            local linked_path = root .. "/linked.wasm"
            local side_path = root .. "/side.wasm"
            local ok, failure = xpcall(function()
                local util = require "titan-compiler.util"
                assert(util.set_file_contents(obj_path, wasm_part, "wb"))
                assert(util.set_file_contents(ar_path, wasm_ar, "wb"))
                assert(util.set_file_contents(bc_path, "BC\192\222payload\n", "wb"))
                assert(util.set_file_contents(bcar_path, bitcode_ar, "wb"))
                assert(util.set_file_contents(linked_path, linked_wasm, "wb"))
                assert(util.set_file_contents(side_path, side_wasm, "wb"))

                local ctx = { io = strategy }
                assert(incremental.load_digest_cache(ctx, root))

                local kind, err, lto = incremental.native_input_kind(ctx, obj_path)
                assert.equal("object", kind, err)
                assert.is_false(lto)

                kind, err, lto = incremental.native_input_kind(ctx, ar_path)
                assert.equal("archive", kind, err)
                assert.is_false(lto)

                kind, err, lto = incremental.native_input_kind(ctx, bc_path)
                assert.equal("object", kind, err)
                assert.is_true(lto)

                kind, err, lto = incremental.native_input_kind(ctx, bcar_path)
                assert.equal("archive", kind, err)
                assert.is_true(lto)

                kind, err = incremental.native_input_kind(ctx, linked_path)
                assert.is_nil(kind)
                assert.matches("not a recognized object, archive or shared library", err, 1, true)

                kind, err = incremental.native_input_kind(ctx, side_path)
                assert.is_nil(kind)
                assert.matches("not a recognized object, archive or shared library", err, 1, true)

                local fp = assert(incremental.part_fingerprint(ctx, obj_path))
                assert.same({
                    format = "wasm",
                    word_size = 32,
                    linking_version = 2,
                    features = "+bulk-memory +sign-ext",
                }, fp)
                assert(incremental.save_digest_cache(ctx))

                local warm = { io = strategy }
                assert(incremental.load_digest_cache(warm, root))
                local digest = incremental.file_digest(warm, obj_path)
                assert.same(fp, warm.incremental.persistent.objects[digest].fingerprint)
                assert.same(fp, assert(incremental.part_fingerprint(warm, obj_path)))

                for _, invalid_fp in ipairs({
                    { format = "wasm", word_size = 64, linking_version = 2, features = "+bulk-memory" },
                    { format = "wasm", word_size = 32, linking_version = 1, features = "+bulk-memory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = " +bulk-memory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+sign-ext +bulk-memory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+bulk-memory -bulk-memory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+bulk-memory", extra = true },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+bulk\tmemory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+bulk\0memory" },
                    { format = "wasm", word_size = 32, linking_version = 2, features = "+bulk\127memory" },
                }) do
                    local poisoned = { io = strategy }
                    assert(incremental.load_digest_cache(poisoned, root))
                    poisoned.incremental.persistent.objects[digest].fingerprint = invalid_fp
                    poisoned.incremental.persistent.dirty = true
                    assert(incremental.save_digest_cache(poisoned))

                    local reloaded = { io = strategy }
                    assert(incremental.load_digest_cache(reloaded, root))
                    assert.is_nil(reloaded.incremental.persistent.objects[digest])
                    assert.same(fp, assert(incremental.part_fingerprint(reloaded, obj_path)))
                    assert(incremental.save_digest_cache(reloaded))
                end
            end, debug.traceback)
            for _, file in ipairs({
                obj_path, ar_path, bc_path, bcar_path, linked_path, side_path,
                root .. "/.titan/digests",
            }) do
                os.remove(file)
            end
            strategy:rmdir(root .. "/.titan")
            strategy:rmdir(root)
            assert.is_true(ok, failure)
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

        it("inspects ordinary COFF members without accepting import objects", function()
            local result = assert(scan(archive({
                ar_member("module.o/", coff_object(PAYLOAD)),
                ar_member("native.o/", coff_object("native", { section_name = ".data" })),
            })))
            assert.equal(2, #result.members)
            assert.equal("coff", result.members[1].fingerprint.format)
            assert.equal("coff", result.members[2].fingerprint.format)
            assert.equal("pkg.mod", result.members[1].metadata.module)
            local invalid, err = scan(archive({
                ar_member("import.o/", "\0\0\255\255" .. zeros(16)),
            }))
            assert.is_nil(invalid)
            assert.matches("COFF import objects", err, 1, true)
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
            local malformed = PAYLOAD:gsub('abi = "2"', 'abi = "1"', 1)
            local result, err = scan(archive({
                ar_member("wanted.o/", elf_object(PAYLOAD)),
                ar_member("unused.o/", elf_object(malformed)),
            }))
            assert.falsy(result)
            assert.match("ABI mismatch", err, 1, true)
            assert.match("unused.o", err, 1, true)
        end)

        it("rebuilds data-only container metadata through the member validator", function()
            local other = assert(staticmetadata.render(
                "pkg.other", ABI, "Module(\"pkg.other\",{}, {})"))
            local scanned = assert(scan(archive({
                ar_member("module.o/", elf_object(PAYLOAD)),
                ar_member("other.o/", elf_object(other)),
            })))
            local data = staticmetadata.container_metadata(scanned)
            assert.same({
                ["pkg.mod"] = { payload = PAYLOAD,
                    origin = scanned.entries["pkg.mod"].origin },
                ["pkg.other"] = { payload = other,
                    origin = scanned.entries["pkg.other"].origin },
            }, data)
            local view = assert(staticmetadata.metadata_view(
                "fixture with spaces", data, { expected_abi = ABI }))
            assert.equal("metadata", view.kind)
            assert.is_nil(view.members)
            assert.same(scanned.key_order, view.key_order)
            assert.same(scanned.entries, view.entries)

            local cases = {
                { "not a table", "container metadata is not a table" },
                { { ["pkg.mod"] = { payload = PAYLOAD } }, "is malformed" },
                { { ["pkg.other"] = data["pkg.mod"] }, "carries module" },
                {
                    { ["pkg.mod"] = { payload = PAYLOAD .. "\n",
                        origin = data["pkg.mod"].origin } },
                    "not in canonical form",
                },
            }
            for _, case in ipairs(cases) do
                local rejected, err = staticmetadata.metadata_view(
                    "fixture with spaces", case[1], { expected_abi = ABI })
                assert.falsy(rejected)
                assert.match(case[2], err, 1, true)
            end
            local rejected, err = staticmetadata.metadata_view(
                "fixture with spaces", data, { expected_abi = "1" })
            assert.falsy(rejected)
            assert.match("ABI mismatch", err, 1, true)
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
            local path = temporary.name()
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

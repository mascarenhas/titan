local staticmetadata = {}

staticmetadata.BANNER = "-- Titan archive module metadata v1\n"

local byte = string.byte
local format = string.format
local getmetatable = getmetatable
local math_floor = math.floor
local math_maxinteger = math.maxinteger
local next = next
local pack = table.pack
local rawget = rawget
local sub = string.sub
local type = type

local ELF_MAGIC = "\127ELF"
local ARCHIVE_MAGIC = "!<arch>\n"
local THIN_ARCHIVE_MAGIC = "!<thin>\n"
local COFF_SPECIAL_MAGIC = "\0\0\255\255"
local WASM_MAGIC = "\0asm"
local BITCODE_MAGIC = "BC\192\222"
local BITCODE_WRAPPER_MAGIC = "\222\192\023\011"
local WASM_SECTION_ORDER = {
    [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [13] = 6,
    [6] = 7, [7] = 8, [8] = 9, [9] = 10, [12] = 11, [10] = 12, [11] = 13,
}
local WASM_IMPORT_KINDS = {
    [0] = "function", [1] = "table", [2] = "memory", [3] = "global", [4] = "tag",
}
-- Final-image value types: numeric, vector and the reference shorthands.
local WASM_VALUE_TYPES = {
    [0x7f] = "i32", [0x7e] = "i64", [0x7d] = "f32", [0x7c] = "f64",
    [0x7b] = "v128", [0x70] = "funcref", [0x6f] = "externref", [0x69] = "exnref",
}
local WASM_SYMBOL_KINDS = {
    [0] = "function", [1] = "data", [2] = "global",
    [3] = "section", [4] = "tag", [5] = "table",
}
local WASM_PAYLOAD_NAMES = {
    [".titan.meta"] = true, [".titan.source"] = true, [".titan.cprobe"] = true,
}
local WASM_RELOC_TYPES = {
    [0] = { width = 5 }, [1] = { width = 5 }, [2] = { width = 4 },
    [3] = { width = 5, addend = 32 }, [4] = { width = 5, addend = 32 },
    [5] = { width = 4, addend = 32 }, [6] = { width = 5 }, [7] = { width = 5 },
    [8] = { width = 4, addend = 32 }, [9] = { width = 4, addend = 32 },
    [10] = { width = 5 }, [11] = { width = 5, addend = 32 }, [12] = { width = 5 },
    [13] = { width = 4 }, [14] = { width = 10, addend = 64 },
    [15] = { width = 10, addend = 64 }, [16] = { width = 8, addend = 64 },
    [17] = { width = 10, addend = 64 }, [18] = { width = 10 }, [19] = { width = 8 },
    [20] = { width = 5 }, [21] = { width = 5, addend = 32 },
    [22] = { width = 8, addend = 64 }, [23] = { width = 4, addend = 32 },
    [24] = { width = 10 }, [25] = { width = 10, addend = 64 }, [26] = { width = 4 },
}
local COFF_BIGOBJ_UUID = "\199\161\186\209\238\186\169\75" ..
    "\175\32\250\246\106\164\220\184"
local COFF_MACHINES = {
    [0x14c] = 32, -- IMAGE_FILE_MACHINE_I386
    [0x8664] = 64, -- IMAGE_FILE_MACHINE_AMD64
    [0xaa64] = 64, -- IMAGE_FILE_MACHINE_ARM64
}
local COFF_INITIALIZED_DATA = 0x40
local COFF_UNINITIALIZED_DATA = 0x80
local COFF_RELOCATION_OVERFLOW = 0x01000000

local MACH_MAGICS = {
    ["\206\250\237\254"] = { word_size = 32, endian = "little" },
    ["\254\237\250\206"] = { word_size = 32, endian = "big" },
    ["\207\250\237\254"] = { word_size = 64, endian = "little" },
    ["\254\237\250\207"] = { word_size = 64, endian = "big" },
}

local FAT_MAGICS = {
    ["\202\254\186\190"] = { word_size = 32, endian = "big" },
    ["\190\186\254\202"] = { word_size = 32, endian = "little" },
    ["\202\254\186\191"] = { word_size = 64, endian = "big" },
    ["\191\186\254\202"] = { word_size = 64, endian = "little" },
}

local SHT_PROGBITS = 1
local SHT_STRTAB = 3
local SHT_RELA = 4
local SHT_NOBITS = 8
local SHT_REL = 9
local SHF_COMPRESSED = 0x800

local MH_OBJECT = 1
local LC_SEGMENT = 0x1
local LC_SEGMENT_64 = 0x19
local SECTION_TYPE = 0xff
local S_REGULAR = 0x0
local S_ZEROFILL = 0x1
local S_GB_ZEROFILL = 0xc
local S_THREAD_LOCAL_ZEROFILL = 0x12

local DARWIN_INDEX_NAMES = {
    ["__.SYMDEF"] = true,
    ["__.SYMDEF SORTED"] = true,
    ["__.SYMDEF_64"] = true,
    ["__.SYMDEF_64 SORTED"] = true,
}

local function bytewise_less(a, b)
    local limit = math.min(#a, #b)
    for index = 1, limit do
        local abyte = byte(a, index)
        local bbyte = byte(b, index)
        if abyte ~= bbyte then return abyte < bbyte end
    end
    return #a < #b
end

local function sorted_keys(map)
    local keys = {}
    for key in next, map do
        keys[#keys + 1] = key
    end
    table.sort(keys, bytewise_less)
    return keys
end

local function portable_dotted_components(modname)
    if type(modname) ~= "string" or modname == "" then return false end
    local components = {}
    for component in modname:gmatch("[^.]+") do
        components[#components + 1] = component
    end
    if #components == 0 or table.concat(components, ".") ~= modname then
        return false
    end
    for _, component in ipairs(components) do
        -- Logical components must map to portable C protocol symbols after
        -- the established dash-to-underscore mangling. In particular, never
        -- admit util.render's `$identifier` metacharacter as module data.
        if not component:match("^[A-Za-z_][A-Za-z0-9_-]*$") then
            return false
        end
    end
    return components
end

local function valid_module_name(modname)
    local components = portable_dotted_components(modname)
    if not components then return false end
    -- The terminal `.titan` spelling is reserved by import declarations as
    -- the explicit-source marker. The root logical module `titan` remains
    -- valid; only a dotted name whose final component is `titan` is
    -- ambiguous with that marker.
    return #components == 1 or components[#components] ~= "titan"
end

staticmetadata.valid_module_name = valid_module_name

-- A physical provider can be named from the common prefix of valid logical
-- modules such as `pkg.titan.left` and `pkg.titan.right`. Validate that
-- portable dotted prefix without treating it as an importable logical name.
function staticmetadata.valid_provider_prefix(prefix)
    return portable_dotted_components(prefix) ~= false
end

local function diagnostic_value(value)
    if type(value) == "string" then return format("%q", value) end
    return "<" .. type(value) .. ":" .. tostring(value) .. ">"
end

local function validate_module_list(modname, names, field)
    if type(names) ~= "table" or getmetatable(names) ~= nil then
        return nil, "metadata " .. field .. " must be a plain array"
    end
    local count, last = 0, 0
    for key in next, names do
        if math.type(key) ~= "integer" or key < 1 then
            return nil, "metadata " .. field .. " must be a dense array"
        end
        count, last = count + 1, math.max(last, key)
    end
    if last ~= count then return nil, "metadata " .. field .. " must be a dense array" end
    local previous
    for _, name in ipairs(names) do
        if not valid_module_name(name) or name == modname then
            return nil, "invalid Titan module name in " .. field .. ": " .. diagnostic_value(name)
        end
        if previous and not bytewise_less(previous, name) then
            return nil, "metadata " .. field .. " must be distinct and in bytewise order"
        end
        previous = name
    end
    return true
end

local function render_module_list(modname, names, field)
    local ok, err = validate_module_list(modname, names, field)
    if not ok then return nil, err end
    if field == "source_requirements" and #names == 0 then
        return nil, "metadata source_requirements must be omitted when empty"
    end
    local lines = { "        " .. field .. " = {\n" }
    for _, name in ipairs(names) do
        lines[#lines + 1] = "            " .. format("%q", name) .. ",\n"
    end
    lines[#lines + 1] = "        },\n"
    return table.concat(lines)
end

function staticmetadata.decode_source_requirements(modname, bytes)
    local names = {}
    for name in bytes:gmatch("[^\n]+") do names[#names + 1] = name end
    local valid, err = validate_module_list(modname, names, "source_requirements")
    if not valid then return nil, err end
    if #names == 0 or table.concat(names, "\n") ~= bytes then
        return nil, "source_requirements metadata must be a nonempty canonical list"
    end
    return names
end

-- Implementation notes: doc/implementation/static-compiled-modules.md#canonical-payload
-- A producer-proved dynamic carrier is a relative provider name the compiler
-- emits itself: a portable module prefix spelled with `/` plus `.so` or
-- `.dll`. Dot segments, backslashes, and absolute or drive paths never reach
-- a library loader.
function staticmetadata.valid_relative_provider(value)
    if type(value) ~= "string" then return false end
    local stem = value:match("^(.+)%.so$") or value:match("^(.+)%.dll$")
    if not stem or stem:find(".", 1, true) then return false end
    return portable_dotted_components((stem:gsub("/", "."))) ~= false
end

local function validate_dynamic_providers(modname, providers)
    if type(providers) ~= "table" or getmetatable(providers) ~= nil then
        return nil, "metadata dynamic_providers must be a plain table"
    end
    if next(providers) == nil then
        return nil, "metadata dynamic_providers must be omitted when empty"
    end
    for owner, provider in next, providers do
        if not valid_module_name(owner) or owner == modname then
            return nil, "invalid Titan module name in dynamic_providers: " ..
                diagnostic_value(owner)
        end
        if not staticmetadata.valid_relative_provider(provider) then
            return nil, "invalid relative provider in dynamic_providers for " ..
                format("%q", owner) .. ": " .. diagnostic_value(provider)
        end
    end
    return true
end

-- `owner<TAB>provider` lines in bytewise owner order.
function staticmetadata.encode_dynamic_providers(modname, providers)
    local valid, err = validate_dynamic_providers(modname, providers)
    if not valid then return nil, err end
    local lines = {}
    for _, owner in ipairs(sorted_keys(providers)) do
        lines[#lines + 1] = owner .. "\t" .. providers[owner]
    end
    return table.concat(lines, "\n")
end

function staticmetadata.decode_dynamic_providers(modname, bytes)
    local malformed = "dynamic_providers metadata must be a nonempty canonical owner/provider list"
    if type(bytes) ~= "string" then return nil, malformed end
    local providers = {}
    for line in bytes:gmatch("[^\n]+") do
        local owner, provider = line:match("^([^\t]+)\t([^\t]+)$")
        if not owner or providers[owner] ~= nil then return nil, malformed end
        providers[owner] = provider
    end
    if next(providers) == nil then return nil, malformed end
    local encoded, err = staticmetadata.encode_dynamic_providers(modname, providers)
    if not encoded then return nil, err end
    if encoded ~= bytes then return nil, malformed end
    return providers
end

local function render_dynamic_providers(modname, providers)
    local valid, err = validate_dynamic_providers(modname, providers)
    if not valid then return nil, err end
    local lines = { "        dynamic_providers = {\n" }
    for _, owner in ipairs(sorted_keys(providers)) do
        lines[#lines + 1] = "            [" .. format("%q", owner) .. "] = " ..
            format("%q", providers[owner]) .. ",\n"
    end
    lines[#lines + 1] = "        },\n"
    return table.concat(lines)
end

-- Implementation notes: doc/implementation/static-compiled-modules.md#canonical-payload
function staticmetadata.render(modname, abi, serialized_types, serialized_layouts, imports, requirements,
                               dynamic_providers)
    if not valid_module_name(modname) then
        return nil, "invalid logical Titan module name " ..
            diagnostic_value(modname)
    end
    if type(abi) ~= "string" then
        return nil, "metadata ABI must be a string"
    end
    if type(serialized_types) ~= "string" then
        return nil, "serialized module types must be a string"
    end
    if serialized_layouts ~= nil and type(serialized_layouts) ~= "string" then
        return nil, "serialized nominal layouts must be a string"
    end
    local serialized_imports = ""
    if imports ~= nil then
        local err
        serialized_imports, err = render_module_list(modname, imports, "imports")
        if not serialized_imports then return nil, err end
    end
    local serialized_requirements = ""
    if requirements ~= nil then
        local err
        serialized_requirements, err = render_module_list(modname, requirements, "source_requirements")
        if not serialized_requirements then return nil, err end
    end
    local serialized_dynamic_providers = ""
    if dynamic_providers ~= nil then
        local err
        serialized_dynamic_providers, err = render_dynamic_providers(modname, dynamic_providers)
        if not serialized_dynamic_providers then return nil, err end
    end
    return staticmetadata.BANNER ..
        "return {\n" ..
        "    [" .. format("%q", modname) .. "] = {\n" ..
        "        abi = " .. format("%q", abi) .. ",\n" ..
        "        types = " .. format("%q", serialized_types) .. ",\n" ..
        (serialized_layouts ~= nil and
            "        layouts = " .. format("%q", serialized_layouts) .. ",\n" or "") ..
        serialized_imports ..
        serialized_requirements ..
        serialized_dynamic_providers ..
        "    },\n" ..
        "}\n"
end

-- Return a complete C initializer, deliberately without an implicit or
-- explicit trailing NUL byte.
function staticmetadata.c_initializer(payload)
    if type(payload) ~= "string" then
        return nil, "metadata payload must be a string"
    end
    local lines = { "{" }
    local values = {}
    for index = 1, #payload do
        values[#values + 1] = tostring(byte(payload, index))
        if #values == 12 then
            lines[#lines + 1] = "    " .. table.concat(values, ", ") .. ","
            values = {}
        end
    end
    if #values ~= 0 then
        lines[#lines + 1] = "    " .. table.concat(values, ", ") .. ","
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

-- Source records are independent of the canonical public archive section.
-- Keep their bytes equally relocation-free and immune to Clang ASan global
-- redzones, which would otherwise become part of the serialized payload. As
-- with the archive metadata, a Wasm record is an unreferenced external
-- definition that wasm-ld drops from final images.
function staticmetadata.source_declaration(payload, symbol)
    local initializer, err = staticmetadata.c_initializer(payload)
    if not initializer then return nil, err end
    -- The compiler's private symbols spell their separator as a UCN.
    assert(type(symbol) == "string" and
        symbol:gsub("\\u2119", "_"):match("^[A-Za-z_][A-Za-z0-9_]*$"),
        "source metadata symbol must be a C identifier")
    return [[
#if defined(__APPLE__)
#define TITAN_SOURCE_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titansrc")))
#define TITAN_SOURCE_META_LINKAGE static
#elif defined(__wasm__)
#define TITAN_SOURCE_META_SECTION \
    __attribute__((aligned(1), section(".titan.source")))
#define TITAN_SOURCE_META_LINKAGE
#elif defined(__ELF__) || defined(_WIN32)
#define TITAN_SOURCE_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.source")))
#define TITAN_SOURCE_META_LINKAGE static
#else
#error unsupported object format for Titan source metadata
#endif

#if defined(__clang__)
#define TITAN_SOURCE_META_NO_ADDRESS_SANITIZE \
    __attribute__((no_sanitize("address")))
#else
#define TITAN_SOURCE_META_NO_ADDRESS_SANITIZE
#endif

TITAN_SOURCE_META_SECTION TITAN_SOURCE_META_NO_ADDRESS_SANITIZE
TITAN_SOURCE_META_LINKAGE const unsigned char ]] .. symbol .. "[] = " .. initializer .. ";\n"
end

local function public_origin(origin)
    if origin == nil then origin = "<memory>" end
    return format("%q", tostring(origin))
end

local function payload_error(origin, message)
    return nil, origin .. ": " .. message
end

-- validate_types, when supplied, is intentionally a driver-owned semantic
-- hook. It receives (module_name, serialized_types, origin) and returns a
-- non-nil decoded/canonical value, or nil/false plus an error. Physical layout
-- bytes are a separate optional field. Native consumers require/validate them;
-- semantic-only consumers do not need to load the layout codec.
function staticmetadata.validate(payload, origin, options)
    options = options or {}
    origin = origin or public_origin("<metadata>")
    if type(payload) ~= "string" then
        return payload_error(origin, "metadata section is not a byte string")
    end
    if payload:sub(1, #staticmetadata.BANNER) ~= staticmetadata.BANNER then
        return payload_error(origin, "missing exact Titan archive metadata v1 banner")
    end

    local chunk, load_error = load(payload, "@" .. origin, "t", {})
    if not chunk then
        return payload_error(origin, "cannot load metadata chunk: " ..
            tostring(load_error))
    end
    local results = pack(pcall(chunk))
    if not results[1] then
        return payload_error(origin, "metadata chunk failed: " ..
            tostring(results[2]))
    end
    if results.n ~= 2 then
        return payload_error(origin,
            "metadata chunk must return exactly one result")
    end

    local result = results[2]
    if type(result) ~= "table" or getmetatable(result) ~= nil then
        return payload_error(origin,
            "metadata chunk result must be a plain table")
    end

    local module_name
    local entry
    local count = 0
    for key, value in next, result do
        count = count + 1
        module_name = key
        entry = value
    end
    if count ~= 1 then
        return payload_error(origin,
            "metadata chunk must contain exactly one logical module key")
    end
    if not valid_module_name(module_name) then
        return payload_error(origin, "invalid logical Titan module key " ..
            diagnostic_value(module_name))
    end
    if type(entry) ~= "table" or getmetatable(entry) ~= nil then
        return payload_error(origin, "metadata entry for " ..
            format("%q", module_name) .. " must be a plain table")
    end

    for key in next, entry do
        if key ~= "abi" and key ~= "types" and key ~= "layouts" and key ~= "imports"
           and key ~= "source_requirements" and key ~= "dynamic_providers" then
            return payload_error(origin, "metadata entry for " ..
                format("%q", module_name) .. " has unknown field " ..
                diagnostic_value(key))
        end
    end
    local abi = rawget(entry, "abi")
    local serialized_types = rawget(entry, "types")
    local serialized_layouts = rawget(entry, "layouts")
    local imports = rawget(entry, "imports")
    local requirements = rawget(entry, "source_requirements")
    local dynamic_providers = rawget(entry, "dynamic_providers")
    if type(abi) ~= "string" or type(serialized_types) ~= "string" or
       (serialized_layouts ~= nil and type(serialized_layouts) ~= "string") then
        return payload_error(origin, "metadata entry for " ..
            format("%q", module_name) ..
            " must contain string fields 'abi' and 'types', and optional string 'layouts'")
    end
    if options.expected_abi ~= nil and abi ~= options.expected_abi then
        return payload_error(origin, "metadata ABI mismatch for " ..
            format("%q", module_name) .. ": expected " ..
            tostring(options.expected_abi) .. " but found " .. tostring(abi))
    end
    if options.require_layouts and serialized_layouts == nil then
        return payload_error(origin, "missing nominal layout metadata for " ..
            format("%q", module_name))
    end

    local canonical, render_error =
        staticmetadata.render(module_name, abi, serialized_types, serialized_layouts, imports, requirements,
            dynamic_providers)
    if not canonical then
        return payload_error(origin, render_error)
    end
    if canonical ~= payload then
        return payload_error(origin, "metadata chunk for " ..
            format("%q", module_name) .. " is not in canonical form")
    end

    local decoded_types
    if options.validate_types ~= nil then
        if type(options.validate_types) ~= "function" then
            return payload_error(origin, "validate_types option is not a function")
        end
        local decoded = pack(pcall(
            options.validate_types, module_name, serialized_types, origin))
        if not decoded[1] then
            return payload_error(origin, "invalid type metadata for " ..
                format("%q", module_name) .. ": " .. tostring(decoded[2]))
        end
        if decoded.n < 2 or not decoded[2] then
            return payload_error(origin, "invalid type metadata for " ..
                format("%q", module_name) .. ": " ..
                tostring(decoded[3] or "validator rejected it"))
        end
        decoded_types = decoded[2] == true and nil or decoded[2]
    end

    local decoded_layouts
    if serialized_layouts ~= nil and options.validate_layouts ~= nil then
        if type(options.validate_layouts) ~= "function" then
            return payload_error(origin, "validate_layouts option is not a function")
        end
        local decoded = pack(pcall(
            options.validate_layouts, module_name, serialized_layouts, origin))
        if not decoded[1] or decoded.n < 2 or not decoded[2] then
            return payload_error(origin, "invalid nominal layout metadata for " ..
                format("%q", module_name) .. ": " ..
                tostring(decoded[1] and (decoded[3] or "validator rejected it")
                    or decoded[2]))
        end
        decoded_layouts = decoded[2] == true and nil or decoded[2]
    end

    return {
        module = module_name,
        abi = abi,
        types = serialized_types,
        decoded_types = decoded_types,
        layouts = serialized_layouts,
        decoded_layouts = decoded_layouts,
        imports = imports,
        source_requirements = requirements,
        dynamic_providers = dynamic_providers,
        payload = payload,
        origin = origin,
    }
end

local function parser_failure(message)
    error({ _staticmetadata_error = true, message = message }, 0)
end

local function fail(origin, message)
    parser_failure(origin .. ": " .. message)
end

local function propagate(message)
    parser_failure(message)
end

local function guarded(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    if type(value) == "table" and value._staticmetadata_error then
        return nil, value.message
    end
    return nil, "static metadata parser failed: " .. tostring(value)
end

local Reader = {}
Reader.__index = Reader

function Reader.new(bytes, origin)
    if type(bytes) ~= "string" then
        fail(origin, "input is not a byte string")
    end
    return setmetatable({
        bytes = bytes,
        length = #bytes,
        origin = origin,
    }, Reader)
end

function Reader:range(offset, size, what)
    if type(offset) ~= "number" or type(size) ~= "number" or
       math.type(offset) ~= "integer" or math.type(size) ~= "integer" or
       offset < 0 or size < 0 or offset > self.length or
       size > self.length - offset then
        fail(self.origin, (what or "byte range") ..
            " is outside the input (offset " .. tostring(offset) ..
            ", size " .. tostring(size) .. ", input size " ..
            tostring(self.length) .. ")")
    end
end

function Reader:slice(offset, size, what)
    self:range(offset, size, what)
    return sub(self.bytes, offset + 1, offset + size)
end

function Reader:uint(offset, width, endian, what)
    self:range(offset, width, what)
    local value = 0
    local first, last, step
    if endian == "little" then
        first, last, step = offset + width - 1, offset, -1
    else
        first, last, step = offset, offset + width - 1, 1
    end
    for position = first, last, step do
        local digit = byte(self.bytes, position + 1)
        if value > math_floor((math_maxinteger - digit) / 256) then
            fail(self.origin, (what or "integer") ..
                " is too large for this Lua runtime")
        end
        value = value * 256 + digit
    end
    return value
end

local function checked_product(count, width, maximum, origin, what)
    if count < 0 or width < 0 or
       (width ~= 0 and count > math_floor(maximum / width)) then
        fail(origin, what .. " overflows its bounded input")
    end
    return count * width
end

local function c_string(data, offset, origin, what)
    if offset < 0 or offset >= #data then
        fail(origin, what .. " offset " .. tostring(offset) ..
            " is outside its string table")
    end
    local terminator = data:find("\0", offset + 1, true)
    if not terminator then
        fail(origin, what .. " is not NUL-terminated inside its string table")
    end
    return sub(data, offset + 1, terminator - 1)
end

local function fixed_name(data)
    local terminator = data:find("\0", 1, true)
    if terminator then return sub(data, 1, terminator - 1) end
    return data
end

local function metadata_limit(options)
    return options.max_metadata_size
end

local function validate_metadata_or_fail(payload, origin, options)
    local limit = metadata_limit(options)
    if limit ~= nil and #payload > limit then
        fail(origin, "metadata section size " .. tostring(#payload) ..
            " exceeds limit " .. tostring(limit))
    end
    local entry, validation_error =
        staticmetadata.validate(payload, origin, options)
    if not entry then propagate(validation_error) end
    return entry
end

local function normalize_fingerprint(value)
    if value and value.fingerprint then return value.fingerprint end
    return value
end

function staticmetadata.fingerprint_matches(actual, expected)
    actual = normalize_fingerprint(actual)
    expected = normalize_fingerprint(expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then
        return false, "missing object target fingerprint"
    end
    if actual.format ~= expected.format then
        return false, "object format " .. tostring(actual.format) ..
            " does not match target format " .. tostring(expected.format)
    end
    if actual.format == "elf" then
        for _, field in ipairs({ "class", "endian", "machine", "flags" }) do
            if actual[field] ~= expected[field] then
                return false, "ELF " .. field .. " " ..
                    tostring(actual[field]) .. " does not match target " ..
                    tostring(expected[field])
            end
        end
    elseif actual.format == "macho" then
        for _, field in ipairs({
            "word_size", "endian", "cputype", "cpusubtype"
        }) do
            if actual[field] ~= expected[field] then
                return false, "Mach-O " .. field .. " " ..
                    tostring(actual[field]) .. " does not match target " ..
                    tostring(expected[field])
            end
        end
    elseif actual.format == "coff" then
        for _, field in ipairs({ "word_size", "endian", "machine" }) do
            if actual[field] ~= expected[field] then
                return false, "COFF " .. field .. " " ..
                    tostring(actual[field]) .. " does not match target " ..
                    tostring(expected[field])
            end
        end
    elseif actual.format == "wasm" then
        for _, field in ipairs({ "word_size", "linking_version" }) do
            if actual[field] ~= expected[field] then
                return false, "Wasm " .. field .. " " ..
                    tostring(actual[field]) .. " does not match target " ..
                    tostring(expected[field])
            end
        end
        local function non_threaded_wasm_tokens(features)
            if type(features) ~= "string" then return nil end
            if features == "" then return {} end
            if features:sub(1, 1) == " " or features:sub(-1) == " " or
               features:find("  ", 1, true) then
                return nil
            end
            local tokens, seen, previous = {}, {}, nil
            for token in features:gmatch("[^ ]+") do
                local prefix = token:sub(1, 1)
                local fname = token:sub(2)
                if (prefix ~= "+" and prefix ~= "-" and prefix ~= "=") or
                   fname == "" or fname:find("[^!-\126]") then
                    return nil
                end
                if previous and not bytewise_less(previous, token) then
                    return nil
                end
                if seen[fname] then return nil end
                seen[fname] = true
                previous = token
                if token == "-shared-mem" then
                    -- Ignore at most one standalone -shared-mem SjLj marker.
                elseif fname == "shared-mem" or fname == "atomics" then
                    return nil
                else
                    tokens[#tokens + 1] = token
                end
            end
            return tokens
        end
        local function wasm_features_match(actual_features, expected_features)
            if type(actual_features) ~= "string" or type(expected_features) ~= "string" then
                return false
            end
            if actual_features == expected_features then return true end
            local actual_tokens = non_threaded_wasm_tokens(actual_features)
            local expected_tokens = non_threaded_wasm_tokens(expected_features)
            if not actual_tokens or not expected_tokens or
               #actual_tokens ~= #expected_tokens then
                return false
            end
            for index = 1, #actual_tokens do
                if actual_tokens[index] ~= expected_tokens[index] then
                    return false
                end
            end
            return true
        end
        if not wasm_features_match(actual.features, expected.features) then
            return false, "Wasm features " ..
                tostring(actual.features) .. " does not match target " ..
                tostring(expected.features)
        end
    else
        return false, "unsupported target fingerprint format " ..
            tostring(actual.format)
    end
    return true
end

local function check_target_or_fail(fingerprint, target, origin)
    if target == nil then return end
    local matches, mismatch =
        staticmetadata.fingerprint_matches(fingerprint, target)
    if not matches then fail(origin, "target mismatch: " .. mismatch) end
end

local function elf_section(reader, offset, word_size, endian)
    if word_size == 32 then
        return {
            name_offset = reader:uint(offset, 4, endian, "ELF section name"),
            type = reader:uint(offset + 4, 4, endian, "ELF section type"),
            flags = reader:uint(offset + 8, 4, endian, "ELF section flags"),
            offset = reader:uint(offset + 16, 4, endian, "ELF section offset"),
            size = reader:uint(offset + 20, 4, endian, "ELF section size"),
            link = reader:uint(offset + 24, 4, endian, "ELF section link"),
            info = reader:uint(offset + 28, 4, endian, "ELF section info"),
        }
    else
        return {
            name_offset = reader:uint(offset, 4, endian, "ELF section name"),
            type = reader:uint(offset + 4, 4, endian, "ELF section type"),
            flags = reader:uint(offset + 8, 8, endian, "ELF section flags"),
            offset = reader:uint(offset + 24, 8, endian, "ELF section offset"),
            size = reader:uint(offset + 32, 8, endian, "ELF section size"),
            link = reader:uint(offset + 40, 4, endian, "ELF section link"),
            info = reader:uint(offset + 44, 4, endian, "ELF section info"),
        }
    end
end

local function parse_elf(bytes, origin, target, options)
    local reader = Reader.new(bytes, origin)
    reader:range(0, 16, "ELF identification")
    if reader:slice(0, 4, "ELF magic") ~= ELF_MAGIC then
        fail(origin, "invalid ELF magic")
    end
    local class_byte = reader:uint(4, 1, "big", "ELF class")
    local data_byte = reader:uint(5, 1, "big", "ELF data encoding")
    local ident_version = reader:uint(6, 1, "big", "ELF identification version")
    local word_size = class_byte == 1 and 32 or class_byte == 2 and 64 or nil
    local endian = data_byte == 1 and "little" or
        data_byte == 2 and "big" or nil
    if not word_size then fail(origin, "unsupported ELF class " .. class_byte) end
    if not endian then
        fail(origin, "unsupported ELF data encoding " .. data_byte)
    end
    if ident_version ~= 1 then
        fail(origin, "unsupported ELF identification version " .. ident_version)
    end

    local header_size = word_size == 32 and 52 or 64
    local section_header_size = word_size == 32 and 40 or 64
    reader:range(0, header_size, "ELF header")
    local file_type = reader:uint(16, 2, endian, "ELF file type")
    local machine = reader:uint(18, 2, endian, "ELF machine")
    local version = reader:uint(20, 4, endian, "ELF version")
    if file_type ~= 1 then
        fail(origin, "ELF file is not a relocatable object (e_type=" ..
            tostring(file_type) .. ")")
    end
    if machine == 0 then fail(origin, "ELF object has no machine architecture") end
    if version ~= 1 then fail(origin, "unsupported ELF version " .. version) end

    local section_offset
    local flags
    local encoded_header_size
    local encoded_section_size
    local encoded_section_count
    local encoded_string_index
    if word_size == 32 then
        section_offset = reader:uint(32, 4, endian, "ELF section table offset")
        flags = reader:uint(36, 4, endian, "ELF flags")
        encoded_header_size = reader:uint(40, 2, endian, "ELF header size")
        encoded_section_size =
            reader:uint(46, 2, endian, "ELF section header size")
        encoded_section_count =
            reader:uint(48, 2, endian, "ELF section count")
        encoded_string_index =
            reader:uint(50, 2, endian, "ELF section-name table index")
    else
        section_offset = reader:uint(40, 8, endian, "ELF section table offset")
        flags = reader:uint(48, 4, endian, "ELF flags")
        encoded_header_size = reader:uint(52, 2, endian, "ELF header size")
        encoded_section_size =
            reader:uint(58, 2, endian, "ELF section header size")
        encoded_section_count =
            reader:uint(60, 2, endian, "ELF section count")
        encoded_string_index =
            reader:uint(62, 2, endian, "ELF section-name table index")
    end
    if encoded_header_size ~= header_size then
        fail(origin, "invalid ELF header size " .. encoded_header_size ..
            " (expected " .. header_size .. ")")
    end
    if encoded_section_size ~= section_header_size then
        fail(origin, "invalid ELF section header size " ..
            encoded_section_size .. " (expected " ..
            section_header_size .. ")")
    end
    if section_offset == 0 then fail(origin, "ELF object has no section table") end
    reader:range(section_offset, section_header_size, "ELF section zero")
    local section_zero =
        elf_section(reader, section_offset, word_size, endian)
    local section_count = encoded_section_count
    if section_count == 0 then section_count = section_zero.size end
    if section_count < 1 then fail(origin, "ELF section table is empty") end
    local table_size = checked_product(
        section_count, section_header_size, reader.length - section_offset,
        origin, "ELF section table")
    reader:range(section_offset, table_size, "ELF section table")

    local string_index = encoded_string_index
    if string_index == 0xffff then string_index = section_zero.link end
    if string_index == 0 or string_index >= section_count then
        fail(origin, "invalid ELF section-name table index " ..
            tostring(string_index))
    end

    local sections = {}
    for index = 0, section_count - 1 do
        sections[index + 1] = elf_section(
            reader, section_offset + index * section_header_size,
            word_size, endian)
        sections[index + 1].index = index
    end
    local string_section = sections[string_index + 1]
    if string_section.type ~= SHT_STRTAB then
        fail(origin, "ELF section-name table is not SHT_STRTAB")
    end
    local string_table = reader:slice(
        string_section.offset, string_section.size,
        "ELF section-name string table")

    local metadata_section
    for _, section in ipairs(sections) do
        section.name = c_string(
            string_table, section.name_offset, origin,
            "ELF section #" .. tostring(section.index) .. " name")
        if section.type ~= SHT_NOBITS and section.size ~= 0 then
            reader:range(section.offset, section.size,
                "ELF section #" .. tostring(section.index) ..
                " " .. format("%q", section.name) .. " data")
        end
        if section.name == ".titan.meta" then
            local section_origin = origin .. ": ELF section #" ..
                tostring(section.index) .. " " .. format("%q", section.name)
            if metadata_section then
                fail(section_origin,
                    "object contains more than one Titan metadata section")
            end
            if section.type ~= SHT_PROGBITS then
                fail(section_origin,
                    "Titan metadata section is not SHT_PROGBITS")
            end
            if (section.flags & SHF_COMPRESSED) ~= 0 then
                fail(section_origin, "Titan metadata section is compressed")
            end
            local payload = reader:slice(
                section.offset, section.size, "Titan metadata section")
            section.origin = section_origin
            section.payload = payload
            section.entry =
                validate_metadata_or_fail(payload, section_origin, options)
            metadata_section = section
        end
    end

    for _, section in ipairs(sections) do
        if section.type == SHT_REL or section.type == SHT_RELA then
            if section.info >= section_count then
                fail(origin, "ELF relocation section #" ..
                    tostring(section.index) ..
                    " has invalid target index " .. tostring(section.info))
            end
            if metadata_section and section.info == metadata_section.index then
                fail(metadata_section.origin,
                    "Titan metadata section is targeted by relocation " ..
                    "section #" .. tostring(section.index))
            end
        end
    end

    local fingerprint = {
        format = "elf",
        class = word_size,
        endian = endian,
        machine = machine,
        flags = flags,
    }
    check_target_or_fail(fingerprint, target, origin)
    return {
        kind = "object",
        format = "elf",
        bytes = bytes,
        origin = origin,
        fingerprint = fingerprint,
        sections = sections,
        metadata_section = metadata_section,
        metadata = metadata_section and metadata_section.entry or nil,
    }
end

local function parse_macho(bytes, origin, target, options)
    local magic = sub(bytes, 1, 4)
    local encoding = MACH_MAGICS[magic]
    if not encoding then fail(origin, "unsupported Mach-O magic") end
    local reader = Reader.new(bytes, origin)
    local word_size = encoding.word_size
    local endian = encoding.endian
    local header_size = word_size == 32 and 28 or 32
    reader:range(0, header_size, "Mach-O header")
    local cputype = reader:uint(4, 4, endian, "Mach-O CPU type")
    local cpusubtype = reader:uint(8, 4, endian, "Mach-O CPU subtype")
    local file_type = reader:uint(12, 4, endian, "Mach-O file type")
    local command_count = reader:uint(16, 4, endian, "Mach-O load-command count")
    local commands_size = reader:uint(20, 4, endian, "Mach-O load-command size")
    if file_type ~= MH_OBJECT then
        fail(origin, "Mach-O file is not a relocatable object (filetype=" ..
            tostring(file_type) .. ")")
    end
    if cputype == 0 then fail(origin, "Mach-O object has no CPU architecture") end
    reader:range(header_size, commands_size, "Mach-O load-command region")
    if command_count > math_floor(commands_size / 8) then
        fail(origin, "Mach-O load-command count exceeds command region")
    end

    local command_offset = header_size
    local command_end = header_size + commands_size
    local sections = {}
    local metadata_section
    for command_index = 1, command_count do
        reader:range(command_offset, 8, "Mach-O load command #" .. command_index)
        local command =
            reader:uint(command_offset, 4, endian, "Mach-O load command")
        local command_size =
            reader:uint(command_offset + 4, 4, endian, "Mach-O command size")
        local command_alignment = word_size == 64 and 8 or 4
        if command_size < 8 or command_size % command_alignment ~= 0 or
           command_size > command_end - command_offset then
            fail(origin, "malformed Mach-O load command #" ..
                tostring(command_index) .. " size " .. tostring(command_size))
        end

        if command == LC_SEGMENT or command == LC_SEGMENT_64 then
            local segment_word_size = command == LC_SEGMENT and 32 or 64
            if segment_word_size ~= word_size then
                fail(origin, "Mach-O segment command width does not match header")
            end
            local segment_size = word_size == 32 and 56 or 72
            local section_size = word_size == 32 and 68 or 80
            if command_size < segment_size then
                fail(origin, "truncated Mach-O segment command #" ..
                    tostring(command_index))
            end
            local section_count_offset =
                command_offset + (word_size == 32 and 48 or 64)
            local section_count = reader:uint(
                section_count_offset, 4, endian, "Mach-O section count")
            local required = segment_size + checked_product(
                section_count, section_size, command_size - segment_size,
                origin, "Mach-O section array")
            if required ~= command_size then
                fail(origin, "Mach-O segment command #" ..
                    tostring(command_index) ..
                    " size does not match its section count")
            end

            for local_index = 0, section_count - 1 do
                local section_offset =
                    command_offset + segment_size + local_index * section_size
                local section_index = #sections + 1
                local section = {
                    index = section_index,
                    sectname = fixed_name(reader:slice(
                        section_offset, 16, "Mach-O section name")),
                    segname = fixed_name(reader:slice(
                        section_offset + 16, 16,
                        "Mach-O section segment name")),
                }
                if word_size == 32 then
                    section.size = reader:uint(
                        section_offset + 36, 4, endian, "Mach-O section size")
                    section.offset = reader:uint(
                        section_offset + 40, 4, endian, "Mach-O section offset")
                    section.relocation_offset = reader:uint(
                        section_offset + 48, 4, endian,
                        "Mach-O relocation offset")
                    section.relocation_count = reader:uint(
                        section_offset + 52, 4, endian,
                        "Mach-O relocation count")
                    section.flags = reader:uint(
                        section_offset + 56, 4, endian, "Mach-O section flags")
                else
                    section.size = reader:uint(
                        section_offset + 40, 8, endian, "Mach-O section size")
                    section.offset = reader:uint(
                        section_offset + 48, 4, endian, "Mach-O section offset")
                    section.relocation_offset = reader:uint(
                        section_offset + 56, 4, endian,
                        "Mach-O relocation offset")
                    section.relocation_count = reader:uint(
                        section_offset + 60, 4, endian,
                        "Mach-O relocation count")
                    section.flags = reader:uint(
                        section_offset + 64, 4, endian, "Mach-O section flags")
                end
                section.section_type = section.flags & SECTION_TYPE
                local zero_fill =
                    section.section_type == S_ZEROFILL or
                    section.section_type == S_GB_ZEROFILL or
                    section.section_type == S_THREAD_LOCAL_ZEROFILL
                if not zero_fill and section.size ~= 0 then
                    reader:range(section.offset, section.size,
                        "Mach-O section #" .. tostring(section_index) ..
                        " data")
                end
                if section.relocation_count ~= 0 then
                    local relocation_size = checked_product(
                        section.relocation_count, 8,
                        reader.length - math.min(
                            section.relocation_offset, reader.length),
                        origin, "Mach-O relocation table")
                    reader:range(section.relocation_offset, relocation_size,
                        "Mach-O section #" .. tostring(section_index) ..
                        " relocation table")
                end
                sections[#sections + 1] = section

                if section.segname == "__TEXT" and
                   section.sectname == "__titanmeta" then
                    local section_origin = origin .. ": Mach-O section #" ..
                        tostring(section_index) .. " " ..
                        format("%q", "__TEXT,__titanmeta")
                    if metadata_section then
                        fail(section_origin,
                            "object contains more than one Titan metadata section")
                    end
                    if section.section_type ~= S_REGULAR then
                        fail(section_origin,
                            "Titan metadata section is not S_REGULAR")
                    end
                    if section.relocation_count ~= 0 then
                        fail(section_origin,
                            "Titan metadata section has relocations")
                    end
                    local payload = reader:slice(
                        section.offset, section.size,
                        "Titan metadata section")
                    section.origin = section_origin
                    section.payload = payload
                    section.entry =
                        validate_metadata_or_fail(payload, section_origin, options)
                    metadata_section = section
                end
            end
        end
        command_offset = command_offset + command_size
    end
    if command_offset ~= command_end then
        fail(origin, "Mach-O load commands do not fill sizeofcmds")
    end

    local fingerprint = {
        format = "macho",
        word_size = word_size,
        endian = endian,
        cputype = cputype,
        cpusubtype = cpusubtype,
    }
    check_target_or_fail(fingerprint, target, origin)
    return {
        kind = "object",
        format = "macho",
        bytes = bytes,
        origin = origin,
        fingerprint = fingerprint,
        sections = sections,
        metadata_section = metadata_section,
        metadata = metadata_section and metadata_section.entry or nil,
    }
end

local function check_coff_payload_section(section, origin, label)
    -- Code and zero-fill records are not serialized byte arrays.
    if (section.flags & 0xe0) ~= COFF_INITIALIZED_DATA then
        fail(origin, label .. " is not initialized COFF data")
    end
    if section.relocation_count ~= 0 then
        fail(origin, label .. " has relocations")
    end
end

local function parse_coff(bytes, origin, target, options)
    local reader = Reader.new(bytes, origin)
    reader:range(0, 20, "COFF header")
    local machine = reader:uint(0, 2, "little", "COFF machine")
    local word_size = COFF_MACHINES[machine]
    if not word_size then fail(origin, "unsupported COFF machine " .. machine) end
    local section_count = reader:uint(2, 2, "little", "COFF section count")
    local symbol_offset = reader:uint(8, 4, "little", "COFF symbol table offset")
    local symbol_count = reader:uint(12, 4, "little", "COFF symbol count")
    local optional_size = reader:uint(16, 2, "little", "COFF optional header size")
    local flags = reader:uint(18, 2, "little", "COFF characteristics")
    if optional_size ~= 0 or (flags & 0x2002) ~= 0 then
        fail(origin, "COFF file is not a relocatable object")
    end
    if (flags & 0x8080) ~= 0 then
        fail(origin, "byte-reversed COFF objects are not supported")
    end
    if section_count == 0 then fail(origin, "COFF section table is empty") end
    local table_size = checked_product(
        section_count, 40, reader.length - 20, origin, "COFF section table")
    reader:range(20, table_size, "COFF section table")

    local strings
    if symbol_offset == 0 then
        if symbol_count ~= 0 then fail(origin, "COFF symbol table has no offset") end
    else
        local symbol_size = checked_product(symbol_count, 18,
            reader.length - math.min(symbol_offset, reader.length),
            origin, "COFF symbol table")
        reader:range(symbol_offset, symbol_size, "COFF symbol table")
        local string_offset = symbol_offset + symbol_size
        local string_size = reader:uint(
            string_offset, 4, "little", "COFF string table size")
        if string_size < 4 then fail(origin, "COFF string table size is less than 4") end
        strings = reader:slice(string_offset, string_size, "COFF string table")
    end

    local sections, metadata_section = {}, nil
    for index = 1, section_count do
        local offset = 20 + (index - 1) * 40
        local name = fixed_name(reader:slice(offset, 8, "COFF section name"))
        if name:sub(1, 1) == "/" then
            local digits = name:match("^/(%d+)$")
            local name_offset = digits and tonumber(digits)
            if not name_offset or name_offset < 4 then
                fail(origin, "invalid COFF long section name offset")
            end
            if not strings then fail(origin, "COFF long section name has no string table") end
            name = c_string(strings, name_offset, origin, "COFF section name")
        end
        local section = {
            index = index,
            name = name,
            size = reader:uint(offset + 16, 4, "little", "COFF section size"),
            offset = reader:uint(offset + 20, 4, "little", "COFF section offset"),
            relocation_offset = reader:uint(offset + 24, 4, "little", "COFF relocation offset"),
            relocation_count = reader:uint(offset + 32, 2, "little", "COFF relocation count"),
            flags = reader:uint(offset + 36, 4, "little", "COFF section characteristics"),
        }
        if (section.flags & COFF_UNINITIALIZED_DATA) == 0 and section.size ~= 0 then
            reader:range(section.offset, section.size, "COFF section #" .. index .. " data")
        end
        local relocation_count = section.relocation_count
        if (section.flags & COFF_RELOCATION_OVERFLOW) ~= 0 then
            if relocation_count ~= 0xffff then
                fail(origin, "invalid COFF relocation overflow count")
            end
            relocation_count = reader:uint(section.relocation_offset, 4,
                "little", "COFF extended relocation count")
            if relocation_count <= 0xffff then
                fail(origin, "invalid COFF extended relocation count")
            end
            section.relocation_count = relocation_count - 1
        end
        if relocation_count ~= 0 then
            local size = checked_product(relocation_count, 10,
                reader.length - math.min(section.relocation_offset, reader.length),
                origin, "COFF relocation table")
            reader:range(section.relocation_offset, size, "COFF relocation table")
        end
        local line_offset = reader:uint(offset + 28, 4, "little", "COFF line-number offset")
        local line_count = reader:uint(offset + 34, 2, "little", "COFF line-number count")
        if line_count ~= 0 then
            local size = checked_product(line_count, 6,
                reader.length - math.min(line_offset, reader.length),
                origin, "COFF line-number table")
            reader:range(line_offset, size, "COFF line-number table")
        end
        sections[#sections + 1] = section
        if section.name == ".titan.meta" then
            local section_origin = origin .. ": COFF section #" .. index ..
                " " .. format("%q", section.name)
            if metadata_section then
                fail(section_origin, "object contains more than one Titan metadata section")
            end
            check_coff_payload_section(section, section_origin, "Titan metadata section")
            section.origin = section_origin
            section.payload = reader:slice(section.offset, section.size, "Titan metadata section")
            section.entry = validate_metadata_or_fail(section.payload, section_origin, options)
            metadata_section = section
        end
    end
    local fingerprint = {
        format = "coff", word_size = word_size, endian = "little", machine = machine,
    }
    check_target_or_fail(fingerprint, target, origin)
    return {
        kind = "object", format = "coff", bytes = bytes, origin = origin,
        fingerprint = fingerprint, sections = sections,
        metadata_section = metadata_section,
        metadata = metadata_section and metadata_section.entry or nil,
    }
end

local function wasm_u32_leb(reader, offset, limit, origin)
    local value, shift, count = 0, 1, 0
    while true do
        if offset >= limit then
            fail(origin, "truncated Wasm u32 LEB128")
        end
        local digit = byte(reader.bytes, offset + 1)
        offset = offset + 1
        count = count + 1
        if count == 5 then
            if digit >= 0x80 then
                if offset >= limit then
                    fail(origin, "truncated Wasm u32 LEB128")
                end
                fail(origin, "Wasm u32 LEB128 exceeds 5 bytes")
            end
            if digit > 0x0f then
                fail(origin, "Wasm u32 LEB128 overflows")
            end
        end
        value = value + (digit & 0x7f) * shift
        if digit < 0x80 then return value, offset end
        shift = shift * 128
    end
end

local function wasm_s32_leb(reader, offset, limit, origin)
    local value, shift, count = 0, 0, 0
    while true do
        if offset >= limit then
            fail(origin, "truncated Wasm i32 LEB128")
        end
        local digit = byte(reader.bytes, offset + 1)
        offset = offset + 1
        count = count + 1
        if count == 5 then
            if digit >= 0x80 then
                if offset >= limit then
                    fail(origin, "truncated Wasm i32 LEB128")
                end
                fail(origin, "Wasm i32 LEB128 exceeds 5 bytes")
            end
            if digit > 0x07 and digit < 0x78 then
                fail(origin, "Wasm i32 LEB128 overflows")
            end
            value = value | ((digit & 0x0f) << 28)
            if (digit & 0x08) ~= 0 then
                value = value - (1 << 32)
            end
            return value, offset
        end
        value = value | ((digit & 0x7f) << shift)
        shift = shift + 7
        if digit < 0x80 then
            if (digit & 0x40) ~= 0 then
                value = value - (1 << shift)
            end
            return value, offset
        end
    end
end

local function wasm_s64_leb(reader, offset, limit, origin)
    local value, shift, count = 0, 0, 0
    while true do
        if offset >= limit then
            fail(origin, "truncated Wasm i64 LEB128")
        end
        local digit = byte(reader.bytes, offset + 1)
        offset = offset + 1
        count = count + 1
        if count == 10 then
            if digit >= 0x80 then
                if offset >= limit then
                    fail(origin, "truncated Wasm i64 LEB128")
                end
                fail(origin, "Wasm i64 LEB128 exceeds 10 bytes")
            end
            if digit ~= 0x00 and digit ~= 0x7f then
                fail(origin, "Wasm i64 LEB128 overflows")
            end
            if digit == 0x7f then
                value = value | (1 << 63)
            end
            return value, offset
        end
        value = value | ((digit & 0x7f) << shift)
        shift = shift + 7
        if digit < 0x80 then
            if (digit & 0x40) ~= 0 then
                value = value | (-1 << shift)
            end
            return value, offset
        end
    end
end

local function wasm_quote(name)
    return (format("%q", name):gsub("\\\n", "\\n"))
end

local function wasm_name(reader, offset, limit, origin, outside_message)
    local length, next_offset = wasm_u32_leb(reader, offset, limit, origin)
    if length > limit - next_offset then
        fail(origin, outside_message)
    end
    return sub(reader.bytes, next_offset + 1, next_offset + length),
        next_offset + length
end

local function check_wasm_memory_limits(reader, offset, limit, origin)
    local flags, next_offset = wasm_u32_leb(reader, offset, limit, origin)
    if (flags & 0x04) ~= 0 then
        fail(origin, "Wasm memory64 is not supported")
    end
    if (flags & 0x02) ~= 0 then
        fail(origin, "Wasm shared memory is not supported")
    end
    if (flags & ~0x07) ~= 0 then
        fail(origin, "invalid Wasm memory limits flags")
    end
    local ignored
    ignored, next_offset = wasm_u32_leb(reader, next_offset, limit, origin)
    if (flags & 0x01) ~= 0 then
        ignored, next_offset = wasm_u32_leb(reader, next_offset, limit, origin)
    end
    return next_offset
end

local function check_wasm_payload_segment(segment, origin)
    if not segment.active then
        fail(origin, "Wasm payload segment " .. wasm_quote(segment.name) ..
            " is not active")
    end
    if segment.tls then
        fail(origin, "Wasm payload segment " .. wasm_quote(segment.name) ..
            " is TLS")
    end
    if segment.alignment ~= 1 then
        fail(origin, "Wasm payload segment " .. wasm_quote(segment.name) ..
            " alignment is not 1")
    end
    if segment.relocated then
        fail(origin, "Wasm payload segment " .. wasm_quote(segment.name) ..
            " is targeted by a DATA relocation")
    end
end

-- Final linked images have neither linking metadata nor relocations. Keep the
-- trace walk on the same bounded Reader/LEB primitives as object metadata.
function staticmetadata.browser_trace_image(bytes, origin)
    origin = origin or "browser Wasm image"
    return guarded(function()
        local reader = Reader.new(bytes, origin)
        if reader.length > 0xffffffff then fail(origin, "final Wasm image exceeds u32 offsets") end
        if reader:slice(0, 8, "Wasm header") ~= "\0asm\1\0\0\0" then
            fail(origin, "invalid final Wasm header")
        end
        local result = { imports = {}, exports = {}, function_imports = 0,
            function_ranges = {}, function_names = {} }
        -- Function signatures by type index, as "(i32,i64)->(f64)", and by
        -- function index (imports first) for function exports.
        local signatures, function_signatures = {}, {}
        local seen, last_order, function_count, code_count = {}, 0, 0, 0
        local names_seen, named = false, {}
        local function text(pos, limit)
            local value, next_pos = wasm_name(reader, pos, limit, origin,
                "Wasm name is outside its section")
            if not utf8.len(value) then fail(origin, "invalid UTF-8 Wasm name") end
            return value, next_pos
        end
        local function limits(pos, limit)
            local flags, next_pos = wasm_u32_leb(reader, pos, limit, origin)
            if flags > 1 then fail(origin, "unsupported final Wasm limits") end
            local ignored
            ignored, next_pos = wasm_u32_leb(reader, next_pos, limit, origin)
            if flags == 1 then
                ignored, next_pos = wasm_u32_leb(reader, next_pos, limit, origin)
            end
            return next_pos
        end
        local offset = 8
        while offset < reader.length do
            local id = byte(bytes, offset + 1)
            local size, pos = wasm_u32_leb(reader, offset + 1, reader.length, origin)
            reader:range(pos, size, "final Wasm section")
            local finish = pos + size
            if id ~= 0 then
                local order = WASM_SECTION_ORDER[id]
                if not order then fail(origin, "unsupported final Wasm section " .. id) end
                if seen[id] then fail(origin, "duplicate final Wasm section " .. id) end
                if order < last_order then fail(origin, "out-of-order final Wasm section " .. id) end
                seen[id], last_order = true, order
            end
            local relevant = id == 1 or id == 2 or id == 3 or id == 7 or id == 10
            if id == 0 then
                local name
                name, pos = text(pos, finish)
                if name == "name" then
                    if names_seen then fail(origin, "duplicate Wasm name section") end
                    names_seen = true
                    local function_names_seen = false
                    while pos < finish do
                        local subsection = reader:uint(pos, 1, "little", "Wasm name subsection")
                        local length
                        length, pos = wasm_u32_leb(reader, pos + 1, finish, origin)
                        if length > finish - pos then fail(origin, "Wasm name subsection is outside its section") end
                        local stop = pos + length
                        if subsection == 1 then
                            if function_names_seen then fail(origin, "duplicate Wasm function name subsection") end
                            function_names_seen = true
                            local count
                            count, pos = wasm_u32_leb(reader, pos, stop, origin)
                            if count > stop - pos then fail(origin, "invalid Wasm function name count") end
                            for _ = 1, count do
                                local index, value
                                index, pos = wasm_u32_leb(reader, pos, stop, origin)
                                value, pos = text(pos, stop)
                                if named[index] ~= nil then fail(origin, "duplicate Wasm function name index") end
                                named[index] = value
                            end
                            if pos ~= stop then fail(origin, "trailing Wasm function name bytes") end
                        end
                        pos = stop
                    end
                end
            elseif relevant then
                local count
                count, pos = wasm_u32_leb(reader, pos, finish, origin)
                if count > finish - pos then fail(origin, "invalid final Wasm section count") end
                if id == 1 then
                    for index = 1, count do
                        if pos >= finish or byte(bytes, pos + 1) ~= 0x60 then
                            fail(origin, "unsupported final Wasm type form")
                        end
                        pos = pos + 1
                        local lists = {}
                        for list = 1, 2 do
                            local length
                            length, pos = wasm_u32_leb(reader, pos, finish, origin)
                            if length > finish - pos then fail(origin, "invalid final Wasm type length") end
                            local names = {}
                            for position = 1, length do
                                local code = byte(bytes, pos + position)
                                names[position] = WASM_VALUE_TYPES[code] or
                                    fail(origin, string.format("unsupported final Wasm value type 0x%02x", code))
                            end
                            pos = pos + length
                            lists[list] = table.concat(names, ",")
                        end
                        signatures[index] = "(" .. lists[1] .. ")->(" .. lists[2] .. ")"
                    end
                elseif id == 2 then
                    for _ = 1, count do
                        local module, name
                        module, pos = text(pos, finish)
                        name, pos = text(pos, finish)
                        if pos >= finish then fail(origin, "truncated Wasm import kind") end
                        local kind = byte(bytes, pos + 1)
                        pos = pos + 1
                        local record = { module = module, name = name, kind = kind }
                        result.imports[#result.imports + 1] = record
                        if kind == 0 or kind == 4 then
                            if kind == 4 then
                                if pos >= finish then fail(origin, "truncated Wasm import type") end
                                pos = pos + 1
                            end
                            local type_index
                            type_index, pos = wasm_u32_leb(reader, pos, finish, origin)
                            record.signature = signatures[type_index + 1] or
                                fail(origin, "Wasm import type index is out of range")
                            if kind == 0 then
                                result.function_imports = result.function_imports + 1
                                function_signatures[result.function_imports] = record.signature
                            end
                        elseif kind == 1 or kind == 3 then
                            if pos >= finish then fail(origin, "truncated Wasm import type") end
                            pos = pos + 1
                            if kind == 1 then pos = limits(pos, finish)
                            else
                                if pos >= finish or byte(bytes, pos + 1) > 1 then
                                    fail(origin, "invalid Wasm global mutability")
                                end
                                pos = pos + 1
                            end
                        elseif kind == 2 then pos = limits(pos, finish)
                        else fail(origin, "invalid Wasm import kind") end
                    end
                elseif id == 3 then
                    function_count = count
                    for index = 1, count do
                        local type_index
                        type_index, pos = wasm_u32_leb(reader, pos, finish, origin)
                        function_signatures[result.function_imports + index] = signatures[type_index + 1]
                    end
                elseif id == 7 then
                    local exports = {}
                    for _ = 1, count do
                        local name, index
                        name, pos = text(pos, finish)
                        if exports[name] then fail(origin, "duplicate Wasm export name") end
                        exports[name] = true
                        if pos >= finish then fail(origin, "truncated Wasm export kind") end
                        local kind = byte(bytes, pos + 1)
                        if kind > 4 then fail(origin, "invalid Wasm export kind") end
                        index, pos = wasm_u32_leb(reader, pos + 1, finish, origin)
                        -- A function export also names its signature when its type is known.
                        result.exports[#result.exports + 1] = { name = name, kind = kind, index = index,
                            signature = kind == 0 and function_signatures[index + 1] or nil }
                    end
                else
                    code_count = count
                    for index = 1, count do
                        local length
                        length, pos = wasm_u32_leb(reader, pos, finish, origin)
                        if length == 0 or length > finish - pos then
                            fail(origin, "invalid final Wasm function body range")
                        end
                        result.function_ranges[index] = { pos, pos + length }
                        pos = pos + length
                    end
                end
                if pos ~= finish then fail(origin, "trailing final Wasm section bytes") end
            end
            offset = finish
        end
        if function_count ~= code_count then fail(origin, "Wasm function/code counts disagree") end
        local total = result.function_imports + code_count
        for index, name in pairs(named) do
            if index >= total then fail(origin, "Wasm function name index is out of range") end
            result.function_names[index + 1] = name
        end
        result.function_count = total
        return result
    end)
end

local function parse_wasm(bytes, origin, target, options)
    local reader = Reader.new(bytes, origin)
    reader:range(0, 8, "Wasm header")
    if reader:slice(0, 4, "Wasm magic") ~= WASM_MAGIC then
        fail(origin, "invalid Wasm magic")
    end
    local version = reader:uint(4, 4, "little", "Wasm version")
    if version ~= 1 then
        fail(origin, "unsupported Wasm version " .. tostring(version))
    end

    local raw_sections = {}
    local seen_known = {}
    local last_order = 0
    local has_linking = false
    local has_segment_info = false
    local has_symbol_table = false
    local has_target_features = false
    local linking_version = 2
    local features = ""
    local datacount_value
    local data_segments = {}
    local imports = {}
    local imported_by_kind = {
        ["function"] = {}, ["table"] = {}, ["memory"] = {},
        ["global"] = {}, ["tag"] = {},
    }
    local symbols = {}
    local offset = 8

    while offset < reader.length do
        local section_id = byte(bytes, offset + 1)
        local section_size, payload_offset =
            wasm_u32_leb(reader, offset + 1, reader.length, origin)
        reader:range(payload_offset, section_size, "Wasm section")
        local section_end = payload_offset + section_size
        local section_index = #raw_sections

        if section_id ~= 0 then
            local order = WASM_SECTION_ORDER[section_id]
            if not order then
                fail(origin, "unsupported Wasm section " .. tostring(section_id))
            end
            if seen_known[section_id] then
                fail(origin, "duplicate Wasm section " .. tostring(section_id))
            end
            if has_linking or order < last_order then
                fail(origin, "out-of-order Wasm section " .. tostring(section_id))
            end
            seen_known[section_id] = true
            last_order = order
            raw_sections[section_index + 1] = {
                index = section_index,
                id = section_id,
                offset = payload_offset,
                size = section_size,
                content_offset = payload_offset,
                content_size = section_size,
            }

            if section_id == 2 then
                local import_count, pos =
                    wasm_u32_leb(reader, payload_offset, section_end, origin)
                for _ = 1, import_count do
                    local mod_name, field_name, ignored
                    mod_name, pos = wasm_name(
                        reader, pos, section_end, origin,
                        "Wasm import module name is outside its section")
                    field_name, pos = wasm_name(
                        reader, pos, section_end, origin,
                        "Wasm import name is outside its section")
                    if mod_name == "GOT.mem" or mod_name == "GOT.func" then
                        fail(origin, "Wasm GOT import is not supported")
                    end
                    if pos >= section_end then
                        fail(origin, "truncated Wasm import descriptor")
                    end
                    local desc_byte = byte(bytes, pos + 1)
                    pos = pos + 1
                    local import_kind = WASM_IMPORT_KINDS[desc_byte]
                    if not import_kind then
                        fail(origin, "unsupported Wasm import kind " .. tostring(desc_byte))
                    end
                    if import_kind == "function" then
                        ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    elseif import_kind == "table" then
                        if pos >= section_end then
                            fail(origin, "truncated Wasm table import")
                        end
                        pos = pos + 1
                        local tflags
                        tflags, pos = wasm_u32_leb(reader, pos, section_end, origin)
                        if (tflags & 0x04) ~= 0 then
                            fail(origin, "Wasm memory64 is not supported")
                        end
                        ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                        if (tflags & 0x01) ~= 0 then
                            ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                        end
                    elseif import_kind == "memory" then
                        pos = check_wasm_memory_limits(reader, pos, section_end, origin)
                    elseif import_kind == "global" then
                        if pos + 2 > section_end then
                            fail(origin, "truncated Wasm global import")
                        end
                        local mut = byte(bytes, pos + 2)
                        if mut ~= 0 and mut ~= 1 then
                            fail(origin, "invalid Wasm global mutability")
                        end
                        pos = pos + 2
                    elseif import_kind == "tag" then
                        if pos >= section_end then
                            fail(origin, "truncated Wasm tag import")
                        end
                        pos = pos + 1
                        ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    end
                    local entry = {
                        module = mod_name,
                        name = field_name,
                        kind = import_kind,
                    }
                    imports[#imports + 1] = entry
                    local by_kind = imported_by_kind[import_kind]
                    by_kind[#by_kind + 1] = entry
                end
                if pos ~= section_end then
                    fail(origin, "malformed Wasm IMPORT section")
                end
            elseif section_id == 5 then
                local mem_count, pos =
                    wasm_u32_leb(reader, payload_offset, section_end, origin)
                for _ = 1, mem_count do
                    pos = check_wasm_memory_limits(reader, pos, section_end, origin)
                end
                if pos ~= section_end then
                    fail(origin, "malformed Wasm MEMORY section")
                end
            elseif section_id == 12 then
                local pos
                datacount_value, pos =
                    wasm_u32_leb(reader, payload_offset, section_end, origin)
                if pos ~= section_end then
                    fail(origin, "malformed Wasm DATACOUNT section")
                end
            elseif section_id == 11 then
                local data_count, pos =
                    wasm_u32_leb(reader, payload_offset, section_end, origin)
                for seg_index = 0, data_count - 1 do
                    local mode, ignored
                    mode, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    if mode == 0 or mode == 2 then
                        if mode == 2 then
                            ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                        end
                        if pos >= section_end then
                            fail(origin, "truncated Wasm DATA offset expression")
                        end
                        local opcode = byte(bytes, pos + 1)
                        pos = pos + 1
                        if opcode == 0x42 then
                            fail(origin, "Wasm memory64 is not supported")
                        end
                        if opcode ~= 0x41 then
                            fail(origin, "unsupported Wasm DATA offset expression")
                        end
                        local mem_offset
                        mem_offset, pos = wasm_s32_leb(reader, pos, section_end, origin)
                        if mem_offset < 0 or pos >= section_end or
                           byte(bytes, pos + 1) ~= 0x0b then
                            fail(origin, "malformed Wasm DATA offset expression")
                        end
                        pos = pos + 1
                    elseif mode ~= 1 then
                        fail(origin, "unsupported Wasm DATA segment mode " .. tostring(mode))
                    end
                    local seg_size
                    seg_size, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    if seg_size > section_end - pos then
                        fail(origin, "Wasm DATA segment is outside its section")
                    end
                    data_segments[seg_index + 1] = {
                        index = seg_index,
                        name = "",
                        offset = pos,
                        section_body_offset = pos - payload_offset,
                        size = seg_size,
                        active = mode == 0,
                        tls = false,
                        alignment = 1,
                        origin = origin,
                    }
                    pos = pos + seg_size
                end
                if pos ~= section_end then
                    fail(origin, "malformed Wasm DATA section")
                end
                if datacount_value ~= nil and datacount_value ~= #data_segments then
                    fail(origin, "Wasm DATACOUNT does not match DATA segment count")
                end
            end
        else
            if payload_offset >= section_end then
                fail(origin, "Wasm custom section name is outside its section")
            end
            local custom_name, content_offset = wasm_name(
                reader, payload_offset, section_end, origin,
                "Wasm custom section name is outside its section")
            local content_size = section_end - content_offset
            raw_sections[section_index + 1] = {
                index = section_index,
                id = 0,
                name = custom_name,
                offset = payload_offset,
                size = section_size,
                content_offset = content_offset,
                content_size = content_size,
            }

            if custom_name == "dylink.0" or custom_name == "dylink" then
                fail(origin, "Wasm dylink.0 side module is not supported")
            elseif custom_name == "linking" then
                if has_linking then
                    fail(origin, "duplicate Wasm section 0")
                end
                has_linking = true
                local pos
                linking_version, pos =
                    wasm_u32_leb(reader, content_offset, section_end, origin)
                if linking_version ~= 2 then
                    fail(origin, "unsupported Wasm linking version " ..
                        tostring(linking_version))
                end
                while pos < section_end do
                    local sub_type = byte(bytes, pos + 1)
                    local sub_len
                    sub_len, pos = wasm_u32_leb(reader, pos + 1, section_end, origin)
                    if sub_len > section_end - pos then
                        fail(origin, "Wasm linking subsection is outside its section")
                    end
                    local sub_end = pos + sub_len
                    if sub_type == 5 then
                        if has_segment_info then
                            fail(origin, "duplicate Wasm segment-info subsection")
                        end
                        has_segment_info = true
                        local seg_count, sp =
                            wasm_u32_leb(reader, pos, sub_end, origin)
                        if seg_count ~= #data_segments then
                            fail(origin,
                                "Wasm segment-info count does not match DATA segment count")
                        end
                        for seg_idx = 1, seg_count do
                            local sname
                            sname, sp = wasm_name(
                                reader, sp, sub_end, origin,
                                "Wasm segment name is outside its subsection")
                            local align_exp, sflags
                            align_exp, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            sflags, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            if align_exp > 62 then
                                fail(origin, "Wasm segment alignment exponent is too large")
                            end
                            local segment = data_segments[seg_idx]
                            segment.name = sname
                            segment.alignment = 1 << align_exp
                            segment.tls = (sflags & 0x02) ~= 0
                            segment.origin = origin .. ": Wasm segment #" ..
                                tostring(seg_idx - 1) .. " " .. wasm_quote(sname)
                        end
                        if sp ~= sub_end then
                            fail(origin, "malformed Wasm segment-info subsection")
                        end
                    elseif sub_type == 6 then
                        local init_count, sp =
                            wasm_u32_leb(reader, pos, sub_end, origin)
                        for _ = 1, init_count do
                            local ignored
                            ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                        end
                        if sp ~= sub_end then
                            fail(origin, "malformed Wasm init-functions subsection")
                        end
                    elseif sub_type == 7 then
                        local comdat_count, sp =
                            wasm_u32_leb(reader, pos, sub_end, origin)
                        for _ = 1, comdat_count do
                            local ignored
                            ignored, sp = wasm_name(
                                reader, sp, sub_end, origin,
                                "Wasm COMDAT name is outside its subsection")
                            ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            local entry_count
                            entry_count, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            for _ = 1, entry_count do
                                if sp >= sub_end then
                                    fail(origin, "truncated Wasm COMDAT entry")
                                end
                                local ekind = byte(bytes, sp + 1)
                                sp = sp + 1
                                if ekind > 5 then
                                    fail(origin, "unsupported Wasm COMDAT kind " .. tostring(ekind))
                                end
                                ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            end
                        end
                        if sp ~= sub_end then
                            fail(origin, "malformed Wasm COMDAT subsection")
                        end
                    elseif sub_type == 8 then
                        if has_symbol_table then
                            fail(origin, "duplicate Wasm symbol table subsection")
                        end
                        has_symbol_table = true
                        local sym_count, sp =
                            wasm_u32_leb(reader, pos, sub_end, origin)
                        for _ = 1, sym_count do
                            if sp >= sub_end then
                                fail(origin, "truncated Wasm symbol entry")
                            end
                            local skind_byte = byte(bytes, sp + 1)
                            sp = sp + 1
                            local skind = WASM_SYMBOL_KINDS[skind_byte]
                            if not skind then
                                fail(origin, "unsupported Wasm symbol kind " ..
                                    tostring(skind_byte))
                            end
                            local sflags
                            sflags, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            local binding_bits = sflags & 0x03
                            if binding_bits == 0x03 then
                                fail(origin, "invalid Wasm symbol binding flags")
                            end
                            local binding = binding_bits == 0x01 and "weak"
                                or binding_bits == 0x02 and "local" or "global"
                            local defined = (sflags & 0x10) == 0
                            local explicit_name = (sflags & 0x40) ~= 0
                            local sname, sym_index
                            if skind == "function" or skind == "global" or
                               skind == "tag" or skind == "table" then
                                sym_index, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                                if defined or explicit_name then
                                    sname, sp = wasm_name(
                                        reader, sp, sub_end, origin,
                                        "Wasm symbol name is outside its subsection")
                                else
                                    local imp = imported_by_kind[skind][sym_index + 1]
                                    if not imp then
                                        fail(origin,
                                            "Wasm undefined symbol references missing import " ..
                                            tostring(sym_index))
                                    end
                                    sname = imp.name
                                end
                            elseif skind == "data" then
                                local ignored
                                sname, sp = wasm_name(
                                    reader, sp, sub_end, origin,
                                    "Wasm symbol name is outside its subsection")
                                if defined then
                                    if (sflags & 0x200) == 0 then
                                        sym_index, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                                    end
                                    ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                                    ignored, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                                end
                            elseif skind == "section" then
                                sym_index, sp = wasm_u32_leb(reader, sp, sub_end, origin)
                            end
                            symbols[#symbols + 1] = {
                                kind = skind,
                                name = sname,
                                binding = binding,
                                defined = defined,
                                index = sym_index,
                            }
                        end
                        if sp ~= sub_end then
                            fail(origin, "malformed Wasm symbol table subsection")
                        end
                    end
                    pos = sub_end
                end
                if not has_segment_info and #data_segments > 0 then
                    fail(origin,
                        "Wasm segment-info count does not match DATA segment count")
                end
            elseif custom_name == "target_features" then
                if has_target_features then
                    fail(origin, "duplicate Wasm section 0")
                end
                has_target_features = true
                local feat_count, pos =
                    wasm_u32_leb(reader, content_offset, section_end, origin)
                local seen_features = {}
                local tokens = {}
                for _ = 1, feat_count do
                    if pos >= section_end then
                        fail(origin, "truncated Wasm target feature")
                    end
                    local prefix_byte = byte(bytes, pos + 1)
                    pos = pos + 1
                    local prefix = prefix_byte == 0x2b and "+"
                        or prefix_byte == 0x2d and "-"
                        or prefix_byte == 0x3d and "=" or nil
                    if not prefix then
                        fail(origin, "invalid Wasm target feature prefix")
                    end
                    local fname
                    fname, pos = wasm_name(
                        reader, pos, section_end, origin,
                        "Wasm target feature name is outside its section")
                    if fname == "" or fname:find("[^!-\126]") then
                        fail(origin, "invalid Wasm target feature name")
                    end
                    local previous = seen_features[fname]
                    if previous == prefix then
                        fail(origin, "duplicate Wasm target feature " ..
                            wasm_quote(fname))
                    elseif previous ~= nil then
                        fail(origin, "conflicting Wasm target feature " ..
                            wasm_quote(fname))
                    end
                    seen_features[fname] = prefix
                    tokens[#tokens + 1] = prefix .. fname
                end
                if pos ~= section_end then
                    fail(origin, "malformed Wasm target_features section")
                end
                table.sort(tokens, bytewise_less)
                features = table.concat(tokens, " ")
            elseif custom_name:sub(1, 6) == "reloc." then
                if not has_linking then
                    fail(origin, "out-of-order Wasm section 0")
                end
                local target_index, pos =
                    wasm_u32_leb(reader, content_offset, section_end, origin)
                local target_sec = raw_sections[target_index + 1]
                if not target_sec or target_sec.index == section_index then
                    fail(origin, "Wasm relocation targets missing section " ..
                        tostring(target_index))
                end
                local reloc_count
                reloc_count, pos = wasm_u32_leb(reader, pos, section_end, origin)
                for _ = 1, reloc_count do
                    if pos >= section_end then
                        fail(origin, "truncated Wasm relocation entry")
                    end
                    local rtype = byte(bytes, pos + 1)
                    pos = pos + 1
                    local spec = WASM_RELOC_TYPES[rtype]
                    if not spec then
                        fail(origin, "unsupported Wasm relocation type " ..
                            tostring(rtype))
                    end
                    local roffset, ignored
                    roffset, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    ignored, pos = wasm_u32_leb(reader, pos, section_end, origin)
                    if spec.addend == 64 then
                        ignored, pos = wasm_s64_leb(reader, pos, section_end, origin)
                    elseif spec.addend == 32 then
                        ignored, pos = wasm_s32_leb(reader, pos, section_end, origin)
                    end
                    if roffset > target_sec.content_size or
                       spec.width > target_sec.content_size - roffset then
                        fail(origin, "Wasm relocation is outside its target section")
                    end
                    if target_sec.id == 11 then
                        local lo, hi = 1, #data_segments + 1
                        while lo < hi do
                            local mid = (lo + hi) // 2
                            local seg = data_segments[mid]
                            if seg.section_body_offset + seg.size < roffset then
                                lo = mid + 1
                            else
                                hi = mid
                            end
                        end
                        for idx = lo, #data_segments do
                            local segment = data_segments[idx]
                            if segment.section_body_offset >= roffset + spec.width then
                                break
                            end
                            if (roffset < segment.section_body_offset + segment.size and
                                roffset + spec.width > segment.section_body_offset) or
                               (segment.size == 0 and
                                roffset == segment.section_body_offset) then
                                segment.relocated = true
                            end
                        end
                    end
                end
                if pos ~= section_end then
                    fail(origin, "malformed Wasm relocation section")
                end
            end
        end
        offset = section_end
    end

    if datacount_value ~= nil and datacount_value ~= #data_segments then
        fail(origin, "Wasm DATACOUNT does not match DATA segment count")
    end
    if not has_linking then
        fail(origin, "Wasm object has no linking section")
    end

    local seen_payloads = {}
    local metadata_section
    for _, segment in ipairs(data_segments) do
        if WASM_PAYLOAD_NAMES[segment.name] then
            if seen_payloads[segment.name] then
                fail(origin, "duplicate Wasm payload segment " ..
                    wasm_quote(segment.name))
            end
            seen_payloads[segment.name] = segment
            check_wasm_payload_segment(segment, origin)
            if segment.name == ".titan.meta" then
                segment.payload = reader:slice(
                    segment.offset, segment.size, "Titan metadata section")
                segment.entry = validate_metadata_or_fail(
                    segment.payload, segment.origin, options)
                metadata_section = segment
            end
        end
    end

    local fingerprint = {
        format = "wasm",
        word_size = 32,
        linking_version = linking_version,
        features = features,
    }
    check_target_or_fail(fingerprint, target, origin)
    return {
        kind = "object",
        format = "wasm",
        bytes = bytes,
        origin = origin,
        fingerprint = fingerprint,
        sections = data_segments,
        metadata_section = metadata_section,
        metadata = metadata_section and metadata_section.entry or nil,
        symbols = symbols,
        imports = imports,
    }
end

local function object_magic_kind(bytes)
    local magic = sub(bytes, 1, 4)
    if magic == ELF_MAGIC then return "elf" end
    if magic == WASM_MAGIC then return "wasm" end
    if magic == BITCODE_MAGIC or magic == BITCODE_WRAPPER_MAGIC then
        return "bitcode"
    end
    if MACH_MAGICS[magic] then return "macho" end
    if FAT_MAGICS[magic] then return "fat" end
    if sub(bytes, 1, #ARCHIVE_MAGIC) == ARCHIVE_MAGIC then return "archive" end
    if sub(bytes, 1, #THIN_ARCHIVE_MAGIC) == THIN_ARCHIVE_MAGIC then
        return "thin"
    end
    if magic == COFF_SPECIAL_MAGIC then
        return sub(bytes, 13, 28) == COFF_BIGOBJ_UUID and "coff_bigobj" or "coff_import"
    end
    if sub(bytes, 1, 2) == "MZ" then return "pe" end
    if #bytes >= 2 and COFF_MACHINES[byte(bytes, 1) + byte(bytes, 2) * 256] then
        return "coff"
    end
end

local function classify_object_internal(bytes, origin, target, options)
    local kind = object_magic_kind(bytes)
    if kind == "elf" then
        return parse_elf(bytes, origin, target, options)
    elseif kind == "macho" then
        return parse_macho(bytes, origin, target, options)
    elseif kind == "coff" then
        return parse_coff(bytes, origin, target, options)
    elseif kind == "wasm" then
        return parse_wasm(bytes, origin, target, options)
    elseif kind == "bitcode" then
        fail(origin, "LLVM bitcode (LTO) object is not supported")
    elseif kind == "coff_bigobj" then
        fail(origin, "COFF BigObj objects are not supported")
    elseif kind == "coff_import" then
        fail(origin, "COFF import objects are not supported")
    elseif kind == "pe" then
        fail(origin, "PE image is not a relocatable object")
    elseif kind == "archive" then
        fail(origin, "nested archive member is not supported")
    elseif kind == "thin" then
        fail(origin, "thin archive member is not supported")
    elseif kind == "fat" then
        fail(origin, "fat object inside a regular archive is not supported")
    else
        fail(origin, "unsupported native object format")
    end
end

function staticmetadata.classify_object(bytes, origin, target, options)
    options = options or {}
    origin = public_origin(origin)
    return guarded(function()
        return classify_object_internal(bytes, origin, target, options)
    end)
end

-- Read one initialized, relocation-free section without interpreting its
-- payload as Titan module metadata. The existing object parser bounds every
-- table and range before this accessor selects the requested bytes.
function staticmetadata.read_object_section(bytes, origin, names, max_bytes)
    origin = public_origin(origin)
    return guarded(function()
        if type(names) ~= "table" or type(names.elf) ~= "string" or
           type(names.macho_segment) ~= "string" or
           type(names.macho_section) ~= "string" or
           (names.coff ~= nil and type(names.coff) ~= "string") or
           (names.wasm ~= nil and type(names.wasm) ~= "string") or
           math.type(max_bytes) ~= "integer" or max_bytes < 0 then
            fail(origin, "invalid object section request")
        end
        local object = classify_object_internal(bytes, origin, nil, {})
        local selected
        for _, section in ipairs(object.sections) do
            local matches = object.format == "elf"
                and section.name == names.elf
                or object.format == "macho"
                and section.segname == names.macho_segment
                and section.sectname == names.macho_section
                or object.format == "coff" and section.name == names.coff
                or object.format == "wasm" and section.name == names.wasm
            if matches then
                if selected then
                    if object.format == "wasm" then
                        fail(origin, "duplicate Wasm payload segment " ..
                            wasm_quote(section.name))
                    end
                    fail(origin, "duplicate requested object section")
                end
                if object.format == "wasm" then
                    check_wasm_payload_segment(section, origin)
                end
                if section.size > max_bytes then
                    fail(origin, "requested object section exceeds size limit")
                end
                if object.format == "elf" then
                    if section.type ~= SHT_PROGBITS then
                        fail(origin, "requested object section is not SHT_PROGBITS")
                    end
                    if (section.flags & SHF_COMPRESSED) ~= 0 then
                        fail(origin, "requested object section is compressed")
                    end
                elseif object.format == "coff" then
                    check_coff_payload_section(section, origin, "requested object section")
                elseif object.format == "macho" then
                    if section.section_type ~= S_REGULAR then
                        fail(origin, "requested object section is not S_REGULAR")
                    end
                    if section.relocation_count ~= 0 then
                        fail(origin, "requested object section has relocations")
                    end
                end
                selected = section
            end
        end
        if not selected then fail(origin, "missing requested object section") end
        if object.format == "elf" then
            for _, section in ipairs(object.sections) do
                if (section.type == SHT_REL or section.type == SHT_RELA)
                   and section.info == selected.index then
                    fail(origin, "requested object section has relocations")
                end
            end
        end
        return Reader.new(bytes, origin):slice(
            selected.offset, selected.size, "requested object section")
    end)
end

local function decimal_field(field, origin, what)
    local digits = field:match("^ *(%d+) *$")
    if not digits then fail(origin, "invalid decimal " .. what) end
    local value = 0
    for index = 1, #digits do
        local digit = byte(digits, index) - 48
        if value > math_floor((math_maxinteger - digit) / 10) then
            fail(origin, what .. " is too large")
        end
        value = value * 10 + digit
    end
    return value
end

local function trim_archive_field(field)
    return (field:gsub(" +$", ""))
end

local function parse_gnu_name_table(bytes, origin)
    local names = {}
    local offset = 0
    while offset < #bytes do
        -- GNU ar rounds the `//` member's recorded size itself and fills the
        -- final byte with a newline, rather than representing that byte as
        -- ordinary archive-record padding.
        if sub(bytes, offset + 1):match("^\n+$") then break end
        local slash_newline = bytes:find("/\n", offset + 1, true)
        local nul = bytes:find("\0", offset + 1, true)
        local terminator
        local after
        if slash_newline and (not nul or slash_newline < nul) then
            terminator = slash_newline
            after = slash_newline + 1
        elseif nul then
            terminator = nul
            after = nul
        else
            fail(origin, "GNU archive long-name table has an unterminated name")
        end
        local name = sub(bytes, offset + 1, terminator - 1)
        if name == "" then
            fail(origin, "GNU archive long-name table has an empty name")
        end
        names[offset] = name
        offset = after
    end
    return names
end

local function index_kind(raw_name, display_name)
    if raw_name == "/" then return "gnu-symbol-index" end
    if raw_name == "/SYM64/" then return "gnu-symbol-index-64" end
    if raw_name == "//" then return "gnu-long-name-table" end
    if DARWIN_INDEX_NAMES[display_name] then return "darwin-symbol-index" end
end

local function add_metadata_entry(entries, entry)
    local previous = entries[entry.module]
    if previous then
        fail(entry.origin, "duplicate logical metadata key " ..
            format("%q", entry.module) .. "; first declared at " ..
            previous.origin)
    end
    entries[entry.module] = entry
end

local function archive_member_origin(origin, record)
    local absolute = record.absolute_header_offset or record.header_offset
    return origin .. ": archive member #" .. tostring(record.ordinal) ..
        " at byte " .. tostring(absolute) .. " name " ..
        format("%q", record.display_name)
end

local function parse_archive(bytes, origin, options, context)
    context = context or {}
    local reader = Reader.new(bytes, origin)
    if reader:slice(0, math.min(8, reader.length), "archive magic") ==
       THIN_ARCHIVE_MAGIC then
        fail(origin, "thin archives are not supported")
    end
    reader:range(0, 8, "archive magic")
    if reader:slice(0, 8, "archive magic") ~= ARCHIVE_MAGIC then
        fail(origin, "invalid regular archive magic")
    end

    local records = {}
    local offset = 8
    while offset < reader.length do
        if reader.length - offset < 60 then
            fail(origin, "truncated archive member header at byte " ..
                tostring((context.base_offset or 0) + offset))
        end
        local header = reader:slice(offset, 60, "archive member header")
        if sub(header, 59, 60) ~= "`\n" then
            fail(origin, "invalid archive member header trailer at byte " ..
                tostring((context.base_offset or 0) + offset))
        end
        local recorded_size = decimal_field(
            sub(header, 49, 58), origin,
            "archive member size at byte " ..
                tostring((context.base_offset or 0) + offset))
        local data_offset = offset + 60
        reader:range(data_offset, recorded_size, "archive member data")
        local padding = recorded_size % 2
        if padding ~= 0 then
            reader:range(data_offset + recorded_size, 1, "archive member padding")
            if reader:slice(data_offset + recorded_size, 1,
                    "archive member padding") ~= "\n" then
                fail(origin, "invalid archive member padding at byte " ..
                    tostring((context.base_offset or 0) +
                        data_offset + recorded_size))
            end
        end
        records[#records + 1] = {
            ordinal = #records + 1,
            header_offset = offset,
            absolute_header_offset = (context.base_offset or 0) + offset,
            raw_name = trim_archive_field(sub(header, 1, 16)),
            recorded_size = recorded_size,
            record_data_offset = data_offset,
            absolute_record_data_offset =
                (context.base_offset or 0) + data_offset,
            record_bytes =
                reader:slice(data_offset, recorded_size, "archive member data"),
            padding_size = padding,
        }
        offset = data_offset + recorded_size + padding
    end

    local gnu_name_table
    local gnu_name_origin
    for _, record in ipairs(records) do
        if record.raw_name == "//" then
            if gnu_name_table then
                fail(origin, "archive contains more than one GNU long-name table")
            end
            gnu_name_origin = origin .. ": archive member #" ..
                tostring(record.ordinal) .. " at byte " ..
                tostring(record.absolute_header_offset) ..
                " GNU long-name table"
            gnu_name_table =
                parse_gnu_name_table(record.record_bytes, gnu_name_origin)
        end
    end

    local members = {}
    local entries = {}
    for _, record in ipairs(records) do
        local raw_name = record.raw_name
        local display_name
        local object_offset = record.record_data_offset
        local object_size = record.recorded_size
        if raw_name:match("^#1/") then
            local name_length = decimal_field(
                raw_name:sub(4), origin, "BSD extended archive name length")
            if name_length > object_size then
                fail(origin, "BSD extended archive name exceeds member #" ..
                    tostring(record.ordinal) .. " data")
            end
            local attached = reader:slice(
                object_offset, name_length, "BSD extended archive name")
            display_name = attached:gsub("%z+$", "")
            object_offset = object_offset + name_length
            object_size = object_size - name_length
        elseif raw_name == "/" or raw_name == "/SYM64/" or raw_name == "//" then
            display_name = raw_name
        else
            local long_offset = raw_name:match("^/(%d+)$")
            if long_offset then
                if not gnu_name_table then
                    fail(origin, "GNU long-name reference in member #" ..
                        tostring(record.ordinal) ..
                        " has no long-name table")
                end
                local numeric_offset =
                    decimal_field(long_offset, origin, "GNU long-name offset")
                display_name = gnu_name_table[numeric_offset]
                if not display_name then
                    fail(origin, "invalid GNU long-name offset " ..
                        tostring(numeric_offset) .. " in member #" ..
                        tostring(record.ordinal))
                end
            else
                display_name = raw_name:gsub("/$", "")
            end
        end
        if display_name == "" then
            fail(origin, "archive member #" .. tostring(record.ordinal) ..
                " has an empty name")
        end
        record.display_name = display_name
        record.data_offset = object_offset
        record.absolute_data_offset =
            (context.base_offset or 0) + object_offset
        record.data_size = object_size
        record.bytes =
            reader:slice(object_offset, object_size, "archive object member")
        record.index_kind = index_kind(raw_name, display_name)

        if not record.index_kind then
            local member_origin = archive_member_origin(origin, record)
            local member_target = options.target or
                (not options.independent_members and members[1] and members[1].fingerprint.format == "wasm"
                    and members[1].fingerprint or nil)
            local object = classify_object_internal(
                record.bytes, member_origin, member_target, options)
            if not options.independent_members and not options.target and #members > 0 and
               object.format == "wasm" and
               members[1].fingerprint.format ~= "wasm" then
                check_target_or_fail(
                    object.fingerprint, members[1].fingerprint, member_origin)
            end
            if context.fat_arch then
                if object.format ~= "macho" then
                    fail(member_origin,
                        "universal Mach-O archive slice contains a non-Mach-O object")
                end
                if object.fingerprint.cputype ~= context.fat_arch.cputype or
                   object.fingerprint.cpusubtype ~=
                       context.fat_arch.cpusubtype then
                    fail(member_origin,
                        "Mach-O object architecture does not match its fat slice")
                end
            end
            record.origin = member_origin
            record.object = object
            record.fingerprint = object.fingerprint
            record.metadata = object.metadata
            members[#members + 1] = record
            if object.metadata then
                add_metadata_entry(entries, object.metadata)
            end
        end
    end

    return {
        kind = "archive",
        format = "archive",
        bytes = bytes,
        origin = origin,
        records = records,
        members = members,
        entries = entries,
        key_order = sorted_keys(entries),
    }
end

local function fat_slice_origin(origin, slice)
    return origin .. ": fat slice #" .. tostring(slice.ordinal) ..
        " (cputype=" .. tostring(slice.cputype) ..
        ", cpusubtype=" .. tostring(slice.cpusubtype) ..
        ") at byte " .. tostring(slice.offset)
end

local function maps_agree(first, other, first_origin, other_origin)
    local first_keys = sorted_keys(first)
    local other_keys = sorted_keys(other)
    if #first_keys ~= #other_keys then
        fail(other_origin, "universal slice logical metadata key set differs " ..
            "from " .. first_origin)
    end
    for index, key in ipairs(first_keys) do
        if other_keys[index] ~= key then
            fail(other_origin, "universal slice logical metadata key set differs " ..
                "from " .. first_origin)
        end
        local left = first[key]
        local right = other[key]
        if left.payload ~= right.payload then
            fail(right.origin, "universal metadata payload for " ..
                format("%q", key) .. " differs from " .. left.origin)
        end
        if left.abi ~= right.abi or left.types ~= right.types or
           left.layouts ~= right.layouts then
            fail(right.origin, "universal decoded metadata for " ..
                format("%q", key) .. " differs from " .. left.origin)
        end
    end
end

local function parse_fat(bytes, origin, options)
    local reader = Reader.new(bytes, origin)
    reader:range(0, 8, "fat Mach-O header")
    local encoding = FAT_MAGICS[reader:slice(0, 4, "fat Mach-O magic")]
    if not encoding then fail(origin, "unsupported fat Mach-O magic") end
    local endian = encoding.endian
    local arch_width = encoding.word_size == 32 and 20 or 32
    local arch_count =
        reader:uint(4, 4, endian, "fat Mach-O architecture count")
    if arch_count == 0 then fail(origin, "fat Mach-O container has no slices") end
    local table_size = checked_product(
        arch_count, arch_width, reader.length - 8,
        origin, "fat Mach-O architecture table")
    reader:range(8, table_size, "fat Mach-O architecture table")
    local table_end = 8 + table_size

    local slices = {}
    local architectures = {}
    for index = 0, arch_count - 1 do
        local entry_offset = 8 + index * arch_width
        local slice = {
            ordinal = index + 1,
            cputype = reader:uint(
                entry_offset, 4, endian, "fat Mach-O CPU type"),
            cpusubtype = reader:uint(
                entry_offset + 4, 4, endian, "fat Mach-O CPU subtype"),
        }
        if encoding.word_size == 32 then
            slice.offset = reader:uint(
                entry_offset + 8, 4, endian, "fat Mach-O slice offset")
            slice.size = reader:uint(
                entry_offset + 12, 4, endian, "fat Mach-O slice size")
            slice.align_exponent = reader:uint(
                entry_offset + 16, 4, endian,
                "fat Mach-O slice alignment")
        else
            slice.offset = reader:uint(
                entry_offset + 8, 8, endian, "fat Mach-O slice offset")
            slice.size = reader:uint(
                entry_offset + 16, 8, endian, "fat Mach-O slice size")
            slice.align_exponent = reader:uint(
                entry_offset + 24, 4, endian,
                "fat Mach-O slice alignment")
            local reserved = reader:uint(
                entry_offset + 28, 4, endian, "fat Mach-O reserved field")
            if reserved ~= 0 then
                fail(origin, "fat Mach-O 64-bit architecture entry has " ..
                    "nonzero reserved field")
            end
        end
        local arch_key = tostring(slice.cputype) .. ":" ..
            tostring(slice.cpusubtype)
        if architectures[arch_key] then
            fail(origin, "fat Mach-O container repeats architecture (" ..
                tostring(slice.cputype) .. ", " ..
                tostring(slice.cpusubtype) .. ")")
        end
        architectures[arch_key] = true
        if slice.align_exponent > 62 then
            fail(origin, "fat Mach-O slice #" .. tostring(slice.ordinal) ..
                " has unsupported alignment exponent " ..
                tostring(slice.align_exponent))
        end
        local alignment = 1 << slice.align_exponent
        if slice.offset % alignment ~= 0 then
            fail(origin, "fat Mach-O slice #" .. tostring(slice.ordinal) ..
                " is not aligned to " .. tostring(alignment) .. " bytes")
        end
        if slice.offset < table_end then
            fail(origin, "fat Mach-O slice #" .. tostring(slice.ordinal) ..
                " overlaps the architecture table")
        end
        reader:range(slice.offset, slice.size,
            "fat Mach-O slice #" .. tostring(slice.ordinal))
        if slice.size == 0 then
            fail(origin, "fat Mach-O slice #" .. tostring(slice.ordinal) ..
                " is empty")
        end
        slice.alignment = alignment
        slice.bytes = reader:slice(
            slice.offset, slice.size, "fat Mach-O slice")
        slice.origin = fat_slice_origin(origin, slice)
        slices[#slices + 1] = slice
    end

    local by_offset = {}
    for index, slice in ipairs(slices) do by_offset[index] = slice end
    table.sort(by_offset, function(a, b) return a.offset < b.offset end)
    for index = 2, #by_offset do
        local previous = by_offset[index - 1]
        local current = by_offset[index]
        if current.offset < previous.offset + previous.size then
            fail(origin, "fat Mach-O slices #" .. tostring(previous.ordinal) ..
                " and #" .. tostring(current.ordinal) .. " overlap")
        end
    end

    local container_kind
    for _, slice in ipairs(slices) do
        local kind = object_magic_kind(slice.bytes)
        local this_kind
        if kind == "archive" then
            this_kind = "fat_archive"
            local slice_options = {}
            for key, value in next, options do
                if key ~= "target" then slice_options[key] = value end
            end
            slice.archive = parse_archive(
                slice.bytes, slice.origin, slice_options, {
                    base_offset = slice.offset,
                    fat_arch = slice,
                })
            slice.members = slice.archive.members
            slice.entries = slice.archive.entries
        elseif kind == "macho" then
            this_kind = "fat_object"
            local slice_options = {}
            for key, value in next, options do
                if key ~= "target" then slice_options[key] = value end
            end
            slice.object = classify_object_internal(
                slice.bytes, slice.origin, nil, slice_options)
            if slice.object.fingerprint.cputype ~= slice.cputype or
               slice.object.fingerprint.cpusubtype ~= slice.cpusubtype then
                fail(slice.origin,
                    "Mach-O object architecture does not match its fat entry")
            end
            slice.entries = {}
            if slice.object.metadata then
                slice.entries[slice.object.metadata.module] =
                    slice.object.metadata
            end
        elseif kind == "fat" then
            fail(slice.origin, "nested fat Mach-O containers are not supported")
        elseif kind == "thin" then
            fail(slice.origin, "thin archive slice is not supported")
        else
            fail(slice.origin,
                "fat Mach-O slice is neither a regular archive nor a Mach-O object")
        end
        if container_kind and container_kind ~= this_kind then
            fail(origin, "fat Mach-O container mixes archive and object slices")
        end
        container_kind = this_kind
    end

    local entries = slices[1].entries
    for index = 2, #slices do
        maps_agree(entries, slices[index].entries,
            slices[1].origin, slices[index].origin)
    end
    local result = {
        kind = container_kind,
        format = "fat",
        fat_word_size = encoding.word_size,
        endian = endian,
        bytes = bytes,
        origin = origin,
        slices = slices,
        entries = entries,
        key_order = sorted_keys(entries),
    }
    if options.target then
        local selected, selection_error =
            staticmetadata.select_fat_slice(result, options.target)
        if not selected then propagate(origin .. ": " .. selection_error) end
        result.selected_slice = selected
    end
    return result
end

function staticmetadata.select_fat_slice(container, target)
    target = normalize_fingerprint(target)
    if type(container) ~= "table" or
       (container.kind ~= "fat_archive" and
        container.kind ~= "fat_object") then
        return nil, "input is not a parsed fat Mach-O container"
    end
    if type(target) ~= "table" or target.format ~= "macho" then
        return nil, "fat Mach-O selection requires a Mach-O target fingerprint"
    end
    local matches = {}
    for _, slice in ipairs(container.slices) do
        local arch_matches =
            slice.cputype == target.cputype and
            slice.cpusubtype == target.cpusubtype
        if arch_matches then
            local compatible = true
            if slice.object then
                compatible = staticmetadata.fingerprint_matches(
                    slice.object.fingerprint, target)
            else
                if #slice.members == 0 then compatible = false end
                for _, member in ipairs(slice.members) do
                    if not staticmetadata.fingerprint_matches(
                            member.fingerprint, target) then
                        compatible = false
                        break
                    end
                end
            end
            if compatible then matches[#matches + 1] = slice end
        end
    end
    if #matches == 0 then return nil, "no fat Mach-O slice matches the target" end
    if #matches ~= 1 then
        return nil, "more than one fat Mach-O slice matches the target"
    end
    return matches[1]
end

local function scan_bytes_internal(bytes, origin, options)
    local kind = object_magic_kind(bytes)
    if kind == "archive" then
        return parse_archive(bytes, origin, options)
    elseif kind == "thin" then
        fail(origin, "thin archives are not supported")
    elseif kind == "fat" then
        return parse_fat(bytes, origin, options)
    elseif kind == "elf" or kind == "macho" or kind == "coff" or
           kind == "wasm" or kind == "bitcode" or
           kind == "coff_bigobj" or kind == "coff_import" or kind == "pe" then
        return classify_object_internal(
            bytes, origin, options.target, options)
    else
        fail(origin, "unsupported native container format")
    end
end

-- Implementation notes: doc/implementation/static-compiled-modules.md#bounded-container-reader
function staticmetadata.scan_bytes(bytes, origin, options)
    options = options or {}
    origin = public_origin(origin)
    return guarded(function()
        return scan_bytes_internal(bytes, origin, options)
    end)
end

local function read_file_bounded(filename, options)
    if options.io then
        local before, stat_error = options.io:stat(filename)
        if not before then return nil, stat_error or "input does not exist" end
        if before.kind ~= "file" then
            return nil, "input is not a regular file"
        end
        if options.max_input_size ~= nil and
           before.size > options.max_input_size then
            return nil, "input size " .. tostring(before.size) ..
                " exceeds limit " .. tostring(options.max_input_size)
        end
        local bytes, read_error = options.io:read_file(filename)
        if not bytes then return nil, read_error end
        if #bytes ~= before.size then
            return nil, "short read (expected " .. tostring(before.size) ..
                " bytes, found " .. tostring(#bytes) .. ")"
        end
        local after, restat_error = options.io:stat(filename)
        if not after then
            return nil, restat_error or "input disappeared while being read"
        end
        if after.kind ~= before.kind or after.size ~= before.size or
           after.modified_seconds ~= before.modified_seconds or
           after.modified_nanoseconds ~= before.modified_nanoseconds then
            return nil, "input changed while it was being read"
        end
        return bytes
    end

    -- Publication/build callers which do not own a resolver context retain
    -- the historical seekable synchronous path. Language-server analysis
    -- always supplies options.io and therefore never reaches this branch.
    local file, open_error = io.open(filename, "rb")
    if not file then return nil, open_error end
    local size, seek_error = file:seek("end")
    if not size then
        file:close()
        return nil, seek_error
    end
    if options.max_input_size ~= nil and size > options.max_input_size then
        file:close()
        return nil, "input size " .. tostring(size) .. " exceeds limit " ..
            tostring(options.max_input_size)
    end
    local reset, reset_error = file:seek("set", 0)
    if not reset then
        file:close()
        return nil, reset_error
    end
    local bytes = file:read(size)
    if type(bytes) ~= "string" or #bytes ~= size then
        file:close()
        return nil, "short read (expected " .. tostring(size) ..
            " bytes, found " .. tostring(bytes and #bytes or 0) .. ")"
    end
    local extra = file:read(1)
    file:close()
    if extra and extra ~= "" then
        return nil, "input changed while it was being read"
    end
    return bytes
end

local ARCHIVE_STREAM_CHUNK_SIZE = 64 * 1024

local function stream_read_exact(file, size, origin, what)
    if size == 0 then return "" end
    local bytes, read_error = file:read(size)
    if type(bytes) ~= "string" or #bytes ~= size then
        fail(origin, "short read of " .. what .. " (expected " ..
            tostring(size) .. " bytes, found " ..
            tostring(bytes and #bytes or 0) ..
            (read_error and ": " .. tostring(read_error) or "") .. ")")
    end
    return bytes
end

local function stream_seek(file, whence, offset, origin, what)
    local position, seek_error = file:seek(whence, offset)
    if not position then
        fail(origin, "cannot seek " .. what .. ": " .. tostring(seek_error))
    end
    return position
end

local function stream_skip_exact(file, size, origin, what)
    local remaining = size
    while remaining ~= 0 do
        local amount = math.min(ARCHIVE_STREAM_CHUNK_SIZE, remaining)
        stream_read_exact(file, amount, origin, what)
        remaining = remaining - amount
    end
end

-- BSD/Darwin archive names are stored at the start of the record data. Keep
-- index recognition streaming too: compare the attached name against the
-- small fixed index-name set while accepting any trailing NUL padding.
local function stream_bsd_name_is_darwin_index(
        file, name_length, origin, ordinal)
    local candidates = {}
    for name in next, DARWIN_INDEX_NAMES do
        candidates[name] = true
    end
    local position = 0
    while position < name_length do
        local amount = math.min(
            ARCHIVE_STREAM_CHUNK_SIZE, name_length - position)
        local chunk = stream_read_exact(
            file, amount, origin,
            "BSD extended name for archive member #" .. tostring(ordinal))
        for candidate in next, candidates do
            for index = 1, #chunk do
                local absolute = position + index
                local expected = absolute <= #candidate and
                    byte(candidate, absolute) or 0
                if byte(chunk, index) ~= expected then
                    candidates[candidate] = nil
                    break
                end
            end
        end
        position = position + amount
    end
    for candidate in next, candidates do
        if name_length < #candidate then candidates[candidate] = nil end
    end
    return next(candidates) ~= nil
end

local function stream_compare_manifest_member(
        archive, object_size, wanted, member_index, origin)
    if type(wanted) ~= "table" then
        fail(origin, "produced archive member count differs: expected " ..
            tostring(member_index - 1) .. " but found at least " ..
            tostring(member_index))
    end
    if type(wanted.staged_file) ~= "string" then
        fail(origin, "manifest member #" .. tostring(member_index) ..
            " has no staged file")
    end
    if type(wanted.byte_length) ~= "number" or
       math.type(wanted.byte_length) ~= "integer" or
       wanted.byte_length < 0 then
        fail(origin, "manifest member #" .. tostring(member_index) ..
            " has an invalid byte length")
    end
    if object_size ~= wanted.byte_length then
        fail(origin, "produced archive member #" .. tostring(member_index) ..
            " has byte length " .. tostring(object_size) .. ", expected " ..
            tostring(wanted.byte_length) .. " from " ..
            tostring(wanted.origin))
    end

    local staged, open_error = io.open(wanted.staged_file, "rb")
    if not staged then
        fail(origin, "cannot open staged manifest member #" ..
            tostring(member_index) .. " " ..
            format("%q", wanted.staged_file) .. ": " .. tostring(open_error))
    end
    local ok, message = pcall(function()
        local staged_size = stream_seek(
            staged, "end", 0, origin,
            "staged manifest member #" .. tostring(member_index))
        if staged_size ~= wanted.byte_length then
            fail(origin, "staged manifest member #" .. tostring(member_index) ..
                " changed size: expected " .. tostring(wanted.byte_length) ..
                " bytes, found " .. tostring(staged_size))
        end
        stream_seek(staged, "set", 0, origin,
            "staged manifest member #" .. tostring(member_index))

        local remaining = object_size
        while remaining ~= 0 do
            local amount = math.min(ARCHIVE_STREAM_CHUNK_SIZE, remaining)
            local actual = stream_read_exact(
                archive, amount, origin,
                "produced archive member #" .. tostring(member_index))
            local expected = stream_read_exact(
                staged, amount, origin,
                "staged manifest member #" .. tostring(member_index))
            if actual ~= expected then
                fail(origin, "produced archive member #" ..
                    tostring(member_index) ..
                    " differs byte-for-byte from " ..
                    tostring(wanted.origin))
            end
            remaining = remaining - amount
        end
        local extra = staged:read(1)
        if extra and extra ~= "" then
            fail(origin, "staged manifest member #" ..
                tostring(member_index) ..
                " changed while it was being read")
        end
    end)
    local close_ok, close_error = staged:close()
    if not ok then error(message, 0) end
    if close_ok == nil then
        fail(origin, "cannot close staged manifest member #" ..
            tostring(member_index) .. ": " .. tostring(close_error))
    end
end

-- Verify a produced single-architecture regular archive against the exact
-- ordered staging manifest without materializing the archive or any member.
-- Metadata scanning remains a separate pass because object/section parsing
-- currently operates on bounded in-memory inputs.
function staticmetadata.verify_regular_archive_manifest(
        filename, manifest, options)
    options = options or {}
    local origin = public_origin(filename)
    local archive
    local result, verify_error = guarded(function()
        if type(manifest) ~= "table" then
            fail(origin, "archive manifest is not a table")
        end
        local open_error
        archive, open_error = io.open(filename, "rb")
        if not archive then
            fail(origin, "cannot open produced archive: " ..
                tostring(open_error))
        end
        local file_size = stream_seek(
            archive, "end", 0, origin, "produced archive")
        if options.max_input_size ~= nil and
           file_size > options.max_input_size then
            fail(origin, "input size " .. tostring(file_size) ..
                " exceeds limit " .. tostring(options.max_input_size))
        end
        stream_seek(archive, "set", 0, origin, "produced archive")

        local magic = stream_read_exact(
            archive, 8, origin, "archive magic")
        if magic == THIN_ARCHIVE_MAGIC then
            fail(origin, "thin archives are not supported")
        elseif magic ~= ARCHIVE_MAGIC then
            fail(origin, "invalid regular archive magic")
        end

        local offset = 8
        local record_ordinal = 0
        local member_count = 0
        while offset < file_size do
            if file_size - offset < 60 then
                fail(origin, "truncated archive member header at byte " ..
                    tostring(offset))
            end
            record_ordinal = record_ordinal + 1
            local header = stream_read_exact(
                archive, 60, origin, "archive member header")
            if sub(header, 59, 60) ~= "`\n" then
                fail(origin, "invalid archive member header trailer at byte " ..
                    tostring(offset))
            end
            local recorded_size = decimal_field(
                sub(header, 49, 58), origin,
                "archive member size at byte " .. tostring(offset))
            local data_offset = offset + 60
            if recorded_size > file_size - data_offset then
                fail(origin, "archive member data is outside the input " ..
                    "(offset " .. tostring(data_offset) .. ", size " ..
                    tostring(recorded_size) .. ", input size " ..
                    tostring(file_size) .. ")")
            end

            local raw_name = trim_archive_field(sub(header, 1, 16))
            local object_size = recorded_size
            local is_index
            local bsd_name_length
            if raw_name:match("^#1/") then
                bsd_name_length = decimal_field(
                    raw_name:sub(4), origin,
                    "BSD extended archive name length")
                if bsd_name_length > recorded_size then
                    fail(origin, "BSD extended archive name exceeds member #" ..
                        tostring(record_ordinal) .. " data")
                end
                is_index = stream_bsd_name_is_darwin_index(
                    archive, bsd_name_length, origin, record_ordinal)
                object_size = recorded_size - bsd_name_length
            else
                local display_name = raw_name:gsub("/$", "")
                is_index = index_kind(raw_name, display_name) ~= nil
            end

            if is_index then
                stream_skip_exact(
                    archive, object_size, origin,
                    "archive index member #" .. tostring(record_ordinal))
            else
                member_count = member_count + 1
                stream_compare_manifest_member(
                    archive, object_size, manifest[member_count],
                    member_count, origin)
            end

            local padding = recorded_size % 2
            if padding ~= 0 then
                local padding_byte = stream_read_exact(
                    archive, 1, origin, "archive member padding")
                if padding_byte ~= "\n" then
                    fail(origin, "invalid archive member padding at byte " ..
                        tostring(data_offset + recorded_size))
                end
            end
            offset = data_offset + recorded_size + padding
        end
        if member_count ~= #manifest then
            fail(origin, "produced archive member count differs: expected " ..
                tostring(#manifest) .. " but found " ..
                tostring(member_count))
        end
        local extra = archive:read(1)
        if extra and extra ~= "" then
            fail(origin, "archive changed while it was being read")
        end
        local close_ok, close_error = archive:close()
        archive = nil
        if close_ok == nil then
            fail(origin, "cannot close produced archive: " ..
                tostring(close_error))
        end
        return {
            member_count = member_count,
            byte_length = file_size,
            chunk_size = ARCHIVE_STREAM_CHUNK_SIZE,
        }
    end)
    if archive then archive:close() end
    return result, verify_error
end

function staticmetadata.scan_archive(filename, options)
    options = options or {}
    local bytes, read_error = read_file_bounded(filename, options)
    if not bytes then
        return nil, format("%q", filename) .. ": cannot read archive: " ..
            tostring(read_error)
    end
    local result, scan_error =
        staticmetadata.scan_bytes(bytes, filename, options)
    if not result then return nil, scan_error end
    if result.kind ~= "archive" and result.kind ~= "fat_archive" then
        return nil, format("%q", filename) ..
            ": input is not a regular or universal static archive"
    end
    result.filename = filename
    return result
end

-- The data-only metadata of a scanned container: per logical module, its
-- canonical payload and diagnostic origin. It carries no member bytes,
-- records, or decoded objects.
function staticmetadata.container_metadata(container)
    local modules = {}
    for name, entry in next, container.entries do
        modules[name] = { payload = entry.payload, origin = entry.origin }
    end
    return modules
end

-- Rebuild a container's entries from `container_metadata` data, validating
-- every payload exactly as an archive scan validates its members. The view
-- has no members, so it can select interfaces but can never be linked.
function staticmetadata.metadata_view(filename, modules, options)
    options = options or {}
    local origin = public_origin(filename)
    return guarded(function()
        if type(modules) ~= "table" then
            fail(origin, "container metadata is not a table")
        end
        local entries = {}
        for name, item in next, modules do
            if type(item) ~= "table" or type(item.payload) ~= "string" or
               type(item.origin) ~= "string" then
                fail(origin, "container metadata for " ..
                    diagnostic_value(name) .. " is malformed")
            end
            local entry = validate_metadata_or_fail(
                item.payload, item.origin, options)
            if entry.module ~= name then
                fail(item.origin, "container metadata key " ..
                    diagnostic_value(name) .. " carries module " ..
                    format("%q", entry.module))
            end
            entries[name] = entry
        end
        return {
            kind = "metadata",
            format = "metadata",
            origin = origin,
            filename = filename,
            entries = entries,
            key_order = sorted_keys(entries),
        }
    end)
end

return staticmetadata

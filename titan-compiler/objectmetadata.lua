-- Trusted compiler-produced source records travel with their native objects.
-- ABI, record schema and certificate policy are independent compatibility gates.
local projectcache = require "titan-compiler.projectcache"
local staticmetadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"
local version = require "titan-compiler.version"
local relocation = require "titan-compiler.relocation"
local declaration_schemas = require "titan-compiler.declarationschemas"

local objectmetadata = {}
local BANNER = "-- Titan object source metadata\n"
local SECTION = { elf = ".titan.source", coff = ".titan.source", wasm = ".titan.source",
    macho_segment = "__TEXT", macho_section = "__titansrc" }

local function serialize(record)
    local tables, indices, assignments = {}, {}, {}
    local function value(item)
        local kind = type(item)
        if kind == "table" then
            local index = indices[item]
            if not index then
                index = #tables + 1
                tables[index], indices[item] = item, index
            end
            return "t[" .. index .. "]"
        elseif kind == "nil" or kind == "boolean" then
            return tostring(item)
        elseif kind == "string" or kind == "number" then
            return string.format("%q", item)
        end
        error("cannot serialize object metadata value of type " .. kind, 0)
    end
    local root = value(record)
    local index = 1
    while tables[index] do
        local node, keys = tables[index], {}
        -- Declaration projections and native facts have scalar lookup keys.
        -- Sort them before allocating children so unchanged records have an
        -- unchanged byte representation regardless of Lua table hash order.
        for key in pairs(node) do
            local kind = type(key)
            assert(kind == "string" or kind == "number" or kind == "boolean",
                "object metadata requires scalar table keys")
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local left, right = type(a), type(b)
            if left ~= right then return left < right end
            if left == "string" then return util.bytewise_less(a, b) end
            if left == "boolean" then return not a and b end
            return a < b
        end)
        for _, key in ipairs(keys) do
            assignments[#assignments + 1] = "t[" .. index .. "][" .. value(key)
                .. "]=" .. value(node[key]) .. "\n"
        end
        index = index + 1
    end
    local output = { BANNER, "local t={}\n" }
    for i = 1, #tables do output[#output + 1] = "t[" .. i .. "]={}\n" end
    output[#output + 1] = table.concat(assignments)
    output[#output + 1] = "return " .. root .. "\n"
    return table.concat(output)
end

function objectmetadata.encode(entry, native)
    local projected, err = projectcache.project_declarations(entry)
    if not projected then return nil, err end
    projected.object_metadata = native
    local ok, payload = pcall(serialize, {
        abi = version.TITAN_ABI_VERSION,
        schema = version.OBJECT_RECORD_SCHEMA,
        digest = version.CERTIFICATE_DIGEST,
        canonicalization = version.CERTIFICATE_CANONICALIZATION,
        module = projected.type.name,
        entry = projected,
    })
    if not ok then return nil, tostring(payload) end
    return payload
end

function objectmetadata.validate_parts(native)
    if type(native) ~= "table" then
        return nil, "missing object metadata table"
    end
    if native.parts_version ~= 1 then
        return nil, "unsupported object part metadata version " ..
            tostring(native.parts_version)
    end
    local parts = native.parts
    if type(parts) ~= "table" or #parts < 1 then
        return nil, "object part list must be a nonempty array"
    end
    for key in pairs(parts) do
        if type(key) ~= "number" or key < 1 or key > #parts
           or key % 1 ~= 0 then
            return nil, "object part list must be a dense array"
        end
    end
    for i = 1, #parts do
        local part = parts[i]
        if type(part) ~= "table" then
            return nil, "object part entry #" .. tostring(i) .. " is not a table"
        end
        local index = i - 1
        local expected_c = index == 0 and ".c"
            or (".part" .. tostring(index) .. ".c")
        local expected_o = index == 0 and ".o"
            or (".part" .. tostring(index) .. ".o")
        if part.index ~= index or part.c_suffix ~= expected_c
           or part.object_suffix ~= expected_o then
            return nil, "object part entry #" .. tostring(i) ..
                " has invalid relative suffixes"
        end
        for key in pairs(part) do
            if key ~= "index" and key ~= "c_suffix"
               and key ~= "object_suffix" then
                return nil, "object part entry #" .. tostring(i) ..
                    " has unknown field " .. tostring(key)
            end
        end
    end
    if #parts == 1 then
        if native.private_header ~= nil then
            return nil, "unsplit object record cannot declare a private header"
        end
    else
        if native.private_header ~= ".priv.h" then
            return nil, "split object record requires private header suffix '.priv.h'"
        end
    end
    if native.c_parts ~= nil and (type(native.c_parts) ~= "number"
            or native.c_parts < 1 or native.c_parts % 1 ~= 0) then
        return nil, "invalid object c_parts policy"
    end
    if native.split_threshold ~= nil and (type(native.split_threshold) ~= "number"
            or native.split_threshold < 0 or native.split_threshold % 1 ~= 0) then
        return nil, "invalid object split_threshold policy"
    end
    return true
end

local function valid_descriptor_roots(entry)
    local visited, headers = {}, {}
    local function header(value)
        if type(value) ~= "table" or headers[value] then return true end
        headers[value] = true
        if not relocation.valid_roots(value.roots) then return false end
        for _, dependency in ipairs(value.dependencies or {}) do
            if not header(dependency) then return false end
        end
        return true
    end
    local function declarations(value)
        if type(value) ~= "table" or visited[value] then return true end
        visited[value] = true
        local schema = declaration_schemas[value._tag]
        if schema and schema._c_origin_header and type(value._c_origin_header) == "table"
            and not header(value._c_origin_header.generated_header) then return false end
        for _, child in pairs(value) do
            if not declarations(child) then return false end
        end
        return true
    end
    return header(entry.ffi_header_descriptor) and declarations(entry)
end

function objectmetadata.decode(payload, origin, expected_abi)
    origin = origin or "<object source metadata>"
    expected_abi = expected_abi or version.TITAN_ABI_VERSION
    local chunk, err = load(payload, "@" .. origin, "t", {})
    if not chunk then return nil, err, "record-unreadable" end
    -- A malformed or obsolete compiler record is a cache miss. Deliberately
    -- do not apply the persisted analysis graph's separate validation policy.
    local ok, entry, failure, reason = pcall(function()
        local record = chunk()
        if type(record) ~= "table" then
            return nil, "object source metadata envelope is not a table", "record-schema"
        end
        if record.schema ~= version.OBJECT_RECORD_SCHEMA
            or record.digest ~= version.CERTIFICATE_DIGEST
            or record.canonicalization ~= version.CERTIFICATE_CANONICALIZATION then
            return nil, "expected schema=" .. tostring(version.OBJECT_RECORD_SCHEMA)
                .. " digest=" .. tostring(version.CERTIFICATE_DIGEST)
                .. " canonicalization=" .. tostring(version.CERTIFICATE_CANONICALIZATION)
                .. "; found schema=" .. tostring(record.schema)
                .. " digest=" .. tostring(record.digest)
                .. " canonicalization=" .. tostring(record.canonicalization), "record-schema"
        end
        if record.abi ~= expected_abi then
            return nil, "object source metadata ABI mismatch: expected "
                .. tostring(expected_abi) .. " but found " .. tostring(record.abi),
                "record-schema"
        end
        if type(record.entry) ~= "table" then
            return nil, "object source metadata has no entry", "record-schema"
        end
        local native = record.entry and record.entry.object_metadata
        if native and (native.parts ~= nil or native.parts_version ~= nil
                or native.private_header ~= nil) then
            local valid_parts, parts_error = objectmetadata.validate_parts(native)
            if not valid_parts then
                return nil, "invalid object part metadata: " ..
                    tostring(parts_error), "parts"
            end
        end
        if native and native.layouts ~= nil then
            local inventory, layout_error =
                require("titan-compiler.nominallayout").decode(
                    native.layouts, record.module)
            if not inventory then
                return nil, "invalid object nominal layout metadata: " ..
                    tostring(layout_error)
            end
            record.entry.layout_inventory = inventory
        end
        if not valid_descriptor_roots(record.entry) then
            return nil, "invalid object header relocation roots", "record-schema"
        end
        return record.entry
    end)
    if not ok then return nil, tostring(entry), "record-unreadable" end
    return entry, failure, reason or (failure and "record-unreadable" or nil)
end

function objectmetadata.render(payload, symbol)
    return staticmetadata.source_declaration(payload, symbol)
end

-- Implementation notes: doc/implementation/incremental-compilation.md#trusted-source-record
function objectmetadata.read(bytes, origin, expected_abi)
    local payload, err = staticmetadata.read_object_section(
        bytes, origin, SECTION, #bytes)
    if not payload then return nil, err end
    return objectmetadata.decode(payload, origin, expected_abi)
end

return objectmetadata

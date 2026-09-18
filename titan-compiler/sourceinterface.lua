local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local cdeclarator = require "titan-compiler.cdeclarator"

local sourceinterface = {}

local FORMAT = "titan-source-interface-v1"

local function frame(value)
    return tostring(#value) .. ":" .. value
end

local function tuple(kind, ...)
    local values = table.pack(...)
    local out = { kind }
    for index = 1, values.n do out[#out + 1] = frame(values[index]) end
    return table.concat(out)
end

local function fail(message)
    error("cannot serialize source interface: " .. message, 0)
end

local function atom(value, label)
    local kind = type(value)
    if value == nil then
        return "n"
    elseif value == false then
        return "f"
    elseif value == true then
        return "t"
    elseif kind == "string" then
        return tuple("s", value)
    elseif kind == "number" and value == value
       and value ~= math.huge and value ~= -math.huge
       and value % 1 == 0 then
        return tuple("i", string.format("%.0f", value))
    end
    fail((label or "value") .. " is not a scalar source-interface value")
end

local function dense_length(value, label, allow_string_keys)
    if type(value) ~= "table" then fail(label .. " must be a dense array") end
    local count, maximum = 0, 0
    for key in pairs(value) do
        if type(key) == "number" then
            if key < 1 or key % 1 ~= 0 then
                fail(label .. " has an invalid array index")
            end
            count = count + 1
            maximum = math.max(maximum, key)
        elseif not allow_string_keys or type(key) ~= "string" then
            fail(label .. " has a non-array key")
        end
    end
    if count ~= maximum then fail(label .. " is not dense") end
    return maximum
end

-- Every field below belongs to the source-import type contract. New Type tags
-- or semantic fields must be added deliberately instead of being picked up by
-- a generic table dump (which would also capture ASTs, locations, and caches).
local SCHEMAS = {
    ["Type.Invalid"] = {}, ["Type.Nil"] = {}, ["Type.Void"] = {},
    ["Type.Boolean"] = {}, ["Type.Integer"] = {}, ["Type.Float"] = {},
    ["Type.String"] = {}, ["Type.Value"] = {}, ["Type.CVoid"] = {
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
    ["Type.GenericScope"] = {
        { "modname", "atom" }, { "owner_fqtn", "atom" },
        { "callable_name", "atom" }, { "role", "atom" },
        { "declaration_kind", "atom" },
    },
    ["Type.TypeParameter"] = {
        { "name", "atom" }, { "constraint", "maybe_type" },
    },
    ["Type.Parameter"] = {
        { "scope", "type" }, { "index", "atom" },
        { "diagnostic_name", "atom" },
        { "erased_constraint", "maybe_type" },
    },
    ["Type.FunctionScheme"] = {
        { "scope", "type" }, { "typeparams", "type_list" },
        { "signature", "type" },
    },
    ["Type.GenericAlias"] = {
        { "module", "atom" }, { "name", "atom" },
        { "locality", "atom" }, { "target_owner_fqtn", "atom" },
        { "target_alias_fqtn", "atom" }, { "target_scope", "type" },
        { "typeparams", "type_list" },
    },
    ["Type.Function"] = {
        { "params", "type_list" }, { "rettypes", "type_list" },
        { "vararg", "atom" }, { "varargtype", "maybe_type" },
        { "flexrettype", "maybe_type" },
    },
    ["Type.Array"] = {
        { "elem", "type" }, { "isconst", "atom" },
    },
    ["Type.Map"] = {
        { "keys", "type" }, { "values", "type" },
    },
    ["Type.Nominal"] = {
        { "fqtn", "atom" }, { "args", "type_list_default" },
    },
    ["Type.Option"] = { { "base", "type" } },
    ["Type.Field"] = {
        { "fqtn", "atom" }, { "name", "atom" }, { "type", "type" },
        { "index", "atom" }, { "isconst", "atom" },
        { "islocal", "flag" },
    },
    ["Type.Variant"] = {
        { "fqtn", "atom" }, { "name", "atom" },
        { "parts", "type_list" }, { "index", "atom" },
        { "islocal", "flag" },
    },
    ["Type.Method"] = {
        { "fqtn", "atom" }, { "name", "atom" },
        { "params", "type_list" }, { "rettypes", "type_list" },
        { "varargtype", "maybe_type" }, { "flexrettype", "maybe_type" },
        { "paramnames", "string_list_or_false" }, { "scope", "maybe_type" },
        { "typeparams", "type_list_default" }, { "islocal", "flag" },
    },
    ["Type.StaticMethod"] = {
        { "fqtn", "atom" }, { "name", "atom" },
        { "params", "type_list" }, { "rettypes", "type_list" },
        { "varargtype", "maybe_type" }, { "flexrettype", "maybe_type" },
        { "paramnames", "string_list_or_false" }, { "scope", "maybe_type" },
        { "typeparams", "type_list_default" }, { "islocal", "flag" },
    },
    ["Type.Record"] = {
        { "name", "atom" }, { "fields", "indexed_type_list" },
        { "functions", "type_map" }, { "methods", "type_map" },
        { "nfields", "atom" }, { "scope", "maybe_type" },
        { "typeparams", "type_list_default" }, { "islocal", "flag" },
    },
    ["Type.Union"] = {
        { "name", "atom" }, { "variants", "indexed_type_list" },
        { "functions", "type_map" }, { "methods", "type_map" },
        { "nvariants", "atom" }, { "scope", "maybe_type" },
        { "typeparams", "type_list_default" }, { "islocal", "flag" },
    },
    ["Type.Interface"] = {
        { "name", "atom" }, { "fields", "indexed_type_list" },
        { "methods", "indexed_type_list" }, { "scope", "maybe_type" },
        { "typeparams", "type_list_default" }, { "islocal", "flag" },
    },
    ["Type.ModuleMember"] = {
        { "modname", "atom" }, { "name", "atom" }, { "type", "type" },
        { "paramnames", "string_list_or_false" }, { "islocal", "flag" },
        { "_foreign_source", "flag" },
    },
    ["Type.ModuleVariable"] = {
        { "modname", "atom" }, { "name", "atom" }, { "type", "type" },
        { "isconst", "atom" }, { "islocal", "flag" },
    },
    ["Type.CInteger"] = {
        { "spelling", "atom" }, { "signed", "atom" },
        { "rank", "atom" }, { "bits", "atom" },
        { "_c_declaration_spelling", "atom" },
        { "_c_enum_enumerator", "atom" }, { "_ffi_scope", "atom" },
        { "_c_origin_header", "header" },
    },
    ["Type.CFloat"] = {
        { "spelling", "atom" }, { "_ffi_scope", "atom" },
        { "_c_origin_header", "header" },
    },
    ["Type.CPointer"] = {
        { "pointee", "type" }, { "quals", "string_list_default" },
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
    ["Type.CArray"] = {
        { "elem", "type" }, { "len", "extent" },
        { "quals", "string_list_default" }, { "_ffi_scope", "atom" },
        { "_c_origin_header", "header" },
    },
    ["Type.CFunction"] = {
        { "params", "type_list" }, { "ret", "type" },
        { "vararg", "atom" }, { "abi", "atom" },
        { "_paramstyle", "parameter_style" },
        { "_return_declaration_qualifiers", "string_list_default" },
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
    ["Type.CStruct"] = {
        { "cname", "name" }, { "tagname", "name" },
        { "typedef", "name" },
        { "_c_tag_scope", "atom" }, { "_ffi_scope", "atom" },
        { "_c_origin_header", "header" },
    },
    ["Type.CUnion"] = {
        { "cname", "name" }, { "tagname", "name" },
        { "typedef", "name" }, { "_c_tag_scope", "atom" },
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
    ["Type.CField"] = {
        { "owner", "type" }, { "name", "atom" }, { "type", "type" },
        { "bitfield", "extent" }, { "flexible_array", "atom" },
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
    ["Type.CTypedef"] = {
        { "name", "name" }, { "target", "type" },
        { "quals", "string_list_default" }, { "_ffi_scope", "atom" },
        { "_c_origin_header", "header" },
    },
    ["Type.COwned"] = {
        { "pointee", "type" }, { "count", "atom" },
        { "_ffi_scope", "atom" }, { "_c_origin_header", "header" },
    },
}

local Encoder = {}
Encoder.__index = Encoder

function Encoder.new(header_inputs)
    return setmetatable({
        active_ids = {},
        next_id = 0,
        header_inputs = header_inputs or {},
    }, Encoder)
end

-- A stable logical include alone cannot cover an omitted C aggregate layout:
-- the generated module environment may change while keeping that spelling.
-- Bind the compiler-owned environment digest into the manifest.
function Encoder:generated_header(origin)
    return origin.generated_header
end

function Encoder:require_aggregate_origin(value, tag)
    local origin = value._c_origin_header
    if type(origin) ~= "table" or type(origin.rendered) ~= "string"
       or origin.rendered == "" then
        fail(tag .. " has no stable C header origin for its omitted layout")
    end

    local covered = false
    local function check_inputs(inputs, label)
        if inputs == nil then return end
        local length = dense_length(inputs, label)
        for index = 1, length do
            local input = inputs[index]
            if type(input) ~= "table" then
                fail(label .. " entry " .. index .. " must be a table")
            end
            if input.restat ~= false then
                local kind, path, identity =
                    input.kind, input.path, input.identity
                local key = tostring(kind) .. "\0" .. tostring(path)
                if self.header_inputs[key] ~= identity then
                    fail(tag .. " C header origin input " .. index ..
                        " is not covered by the source interface")
                end
                covered = true
            end
        end
    end
    check_inputs(origin.c_header_dependencies,
        tag .. " C header dependencies")
    check_inputs(origin.c_header_search_inputs,
        tag .. " C header search inputs")

    -- The validated descriptor covers generated text; physical author headers
    -- and include-search observations must still be covered independently above.
    if self:generated_header(origin, tag) then covered = true end
    if not covered then
        fail(tag .. " C header origin is not covered by the source interface")
    end
end

function Encoder:list(value, label, encode, allow_string_keys)
    local length = dense_length(value, label, allow_string_keys)
    local out = { atom(length) }
    for index = 1, length do
        out[#out + 1] = encode(self, value[index],
            label .. " entry " .. index)
    end
    return tuple("l", table.concat(out))
end

function Encoder:string_list(value, label)
    return self:list(value, label, function(_, item, item_label)
        if type(item) ~= "string" then fail(item_label .. " must be a string") end
        return atom(item)
    end)
end

function Encoder:type_list(value, label, allow_string_keys)
    return self:list(value, label, function(encoder, item, item_label)
        return encoder:descriptor(item, item_label)
    end, allow_string_keys)
end

function Encoder:type_map(value, label)
    if type(value) ~= "table" then fail(label .. " must be a table") end
    local names = {}
    for key in pairs(value) do
        if type(key) ~= "string" then fail(label .. " has a non-string key") end
        names[#names + 1] = key
    end
    table.sort(names, util.bytewise_less)
    local out = { atom(#names) }
    for _, name in ipairs(names) do
        out[#out + 1] = atom(name)
        out[#out + 1] = self:descriptor(value[name], label .. " member " .. name)
    end
    return tuple("m", table.concat(out))
end

function Encoder:field(value, spec, owner_tag)
    local name, kind = spec[1], spec[2]
    local field = value[name]
    local label = owner_tag .. " field " .. name
    if kind == "atom" then
        return atom(field, label)
    elseif kind == "flag" then
        return atom(field == true)
    elseif kind == "type" then
        return self:descriptor(field, label)
    elseif kind == "maybe_type" then
        return field == false and "f" or self:descriptor(field, label)
    elseif kind == "type_list" then
        return self:type_list(field, label)
    elseif kind == "type_list_default" then
        return self:type_list(field or {}, label)
    elseif kind == "indexed_type_list" then
        return self:type_list(field, label, true)
    elseif kind == "type_map" then
        return self:type_map(field, label)
    elseif kind == "string_list_default" then
        return self:string_list(field or {}, label)
    elseif kind == "string_list_or_false" then
        return field == false and "f" or self:string_list(field, label)
    elseif kind == "parameter_style" then
        return atom(field or "prototype", label)
    elseif kind == "extent" then
        return atom(cdeclarator.render_array_extent(field), label)
    elseif kind == "name" then
        if field == nil or field == false or type(field) == "string" then
            return atom(field, label)
        end
        return self:string_list(field, label)
    elseif kind == "header" then
        if field == nil or field == false then return "n" end
        if type(field) ~= "table" or type(field.rendered) ~= "string"
           or field.rendered == "" then
            fail(label .. " has no stable rendered spelling")
        end
        local header = self:generated_header(field, label)
        if header then return tuple("g", atom(field.rendered), atom(header.digest)) end
        return atom(field.rendered)
    end
end

function Encoder:descriptor(value, label)
    label = label or "type descriptor"
    if type(value) ~= "table" or type(value._tag) ~= "string" then
        fail(label .. " is not a type descriptor")
    end
    local previous = self.active_ids[value]
    if previous then return tuple("r", atom(previous)) end
    local tag = value._tag
    local schema = SCHEMAS[tag]
    if not schema then fail("unsupported source-visible descriptor tag " .. tag) end
    if tag == "Type.CInteger" and value._c_enum_unspellable
       and not value._c_declaration_spelling then
        fail("unspellable anonymous C enum reached a source interface")
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        if not types.is_c_lua_state(value) then
            self:require_aggregate_origin(value, tag)
        end
    end

    self.next_id = self.next_id + 1
    local id = self.next_id
    self.active_ids[value] = id
    local fields = {}
    for _, spec in ipairs(schema) do
        fields[#fields + 1] = tuple("p", atom(spec[1]),
            self:field(value, spec, tag))
    end
    self.active_ids[value] = nil
    return tuple("d", atom(id), atom(tag), table.concat(fields))
end

local function encode_headers(headers)
    if type(headers) ~= "table" then
        fail("C header dependencies must be an ordered array")
    end
    local length = dense_length(headers, "C header dependencies")
    local out, seen = { atom(length) }, {}
    for index = 1, length do
        local dependency = headers[index]
        if type(dependency) ~= "table" then
            fail("C header dependency " .. index .. " must be a table")
        end
        local kind, path, identity = dependency.kind,
            dependency.path, dependency.identity
        if kind ~= "file" and kind ~= "search" then
            fail("C header dependency " .. index .. " has invalid kind")
        elseif type(path) ~= "string" or path:sub(1, 1) ~= "/"
           or path:find("\0", 1, true) then
            fail("C header dependency " .. index .. " has invalid path")
        elseif type(identity) ~= "string" or identity == "" then
            fail("C header dependency " .. index .. " has no identity")
        end
        local key = kind .. "\0" .. path
        if seen[key] then
            fail("C header dependencies repeat " .. kind .. " input " .. path)
        end
        seen[key] = identity
        out[#out + 1] = tuple("h", atom(kind), atom(path), atom(identity))
    end
    return tuple("l", table.concat(out)), seen
end

local function encode_source_delta(modtype, header_inputs)
    local encoder = Encoder.new(header_inputs)
    local public_nominals = {}
    for _, member in ipairs(modtype.members or {}) do
        local typ = member._tag == "Type.ModuleMember" and member.type
        if typ and (typ._tag == "Type.Record" or typ._tag == "Type.Union"
                    or typ._tag == "Type.Interface") then
            public_nominals[#public_nominals + 1] = typ
        end
    end
    return tuple("x",
        encoder:type_list(modtype.source_members or {},
            "source module members", true),
        encoder:type_map(modtype.source_type_members or {},
            "source module type members"),
        encoder:type_list(public_nominals,
            "public nominal source views"))
end

function sourceinterface.serialize(entry)
    if type(entry) ~= "table" or entry.kind ~= "source" then
        return nil, "source interface entry must be a source module"
    elseif type(entry.type) ~= "table"
       or entry.type._tag ~= "Type.Module" or entry.type._source ~= true then
        return nil, "source interface entry has no source Type.Module"
    end
    local ok, result = pcall(function()
        local public = types.serialize(entry.type)
        local headers, header_inputs =
            encode_headers(entry.c_header_dependencies or {})
        return tuple("S", atom(FORMAT), atom(public),
            encode_source_delta(entry.type, header_inputs), headers)
    end)
    if not ok then return nil, tostring(result) end
    return result
end

sourceinterface.FORMAT = FORMAT

return sourceinterface

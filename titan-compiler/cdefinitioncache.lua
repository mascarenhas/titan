-- Closed extracted C definitions for header and converted-namespace caches.
-- Parser tables, CPP contexts and conversion histories are transient. Each
-- projection/reconstruction visits its retained edges once with one memo, so
-- recursive declarations and aliases retain their ordinary semantic sharing.
local graphcodec = require "titan-compiler.graphcodec"
local shared = require "titan-compiler.declarationschemas"

local cache = {}
local schemas = {}
for name, fields in pairs(shared) do
    if name:match("^Type%.C") or name == "extent" or name == "numeric"
       or name == "carriers" then
        local copy = {}
        for field, role in pairs(fields) do copy[field] = role end
        schemas[name] = copy
    end
end
schemas.extent.integer_token = "string?"
schemas["Type.CNamed"] = { tagname = "c_name" }
schemas["Type.CModule"] = { name = "string", members = "type_map", type_members = "type_map" }
schemas["Type.ModuleMember"] = {
    modname = "string", name = "string", type = "type", paramnames = "names_or_false",
    _foreign_namespace = "boolean?", _c_origin_header = "include?",
    _c_integer_constant = "string?",
}
schemas.header_types = {
    file_scope_tags = "raw_tags", typedef_names = "set",
    field_macro_classes = "macros", profile_macros = "profile_macros",
}
schemas.ctype = {
    type = "ctype_value", name = "c_name?", def = "ctype_value?",
    ret = "ctype?", params = "ctypes?", paramnames = "names_or_false?",
    vararg = "boolean?", pointer = "names?", idxs = "extents?",
    fields = "ctypes?", values = "enumerators?", bitfield = "boolean?",
    width = "extent?", anonymous = "boolean?", flexible_array = "boolean?",
    _declarator_base = "parts?", _declarator_ops = "parts?", _paramstyle = "string?",
    _file_scope_tag = "boolean?", _file_scope_tag_metadata = "raw_tag?",
    _canonical_tag = "ctype?", _tag_provenance = "tag_provenance?",
    _prototype_scope_id = "integer?", _allow_outer_binding = "boolean?",
    macro_expression = "extent?", has_integer_literals = "boolean?", _macro_cast = "boolean?",
}
schemas.declaration = { name = "string", type = "ctype" }
schemas.enumerator = { name = "string", value = "extent?" }
schemas.raw_tag = { name = "string", kind = "string", raw_key = "string", declarations = "provenances" }
schemas.tag_provenance = {
    header = "string?", declaration_order = "integer?", scope = "string?", definition = "boolean?",
}
schemas.macro = { name = "string", replacement = "string", path = "names?", unsupported = "boolean?" }
schemas.file_tag = { name = "string", kind = "string", scope = "string", order = "integer", canonical = "type?" }
schemas.profile = {
    int = "string", unsigned_int = "string", lua_integer = "string", lua_number = "string",
    size_t = "string", ptrdiff_t = "string", char_bit = "integer", char_signed = "boolean",
    integers = "profile_integers", floats = "profile_floats", identity = "string",
}
schemas.profile_integer = {
    type = "type", precision = "integer", minimum = "atom", maximum = "atom", unsigned = "string?",
}
schemas.profile_float = {
    type = "type", rank = "integer", bits = "integer", maximum_exponent = "integer?",
    maximum_macro = "string?", radix = "integer?", mantissa_digits = "integer?",
}
schemas.foreign = {
    version = "integer", abi = "atom", key = "string", namespace_type = "type",
    foreign_types = "type_map", field_macros = "macros", file_tags = "file_tags", profile = "profile",
}

local maps = {
    type_map = "type", raw_tags = "raw_tag", macros = "macro", file_tags = "file_tag",
    profile_integers = "profile_integer", profile_floats = "profile_float", set = "true",
    profile_macros = "profile_macro",
}
local lists = {
    names = "string", types = "type", members = "type", ctypes = "ctype", parts = "part",
    extents = "extent", enumerators = "enumerator", provenances = "tag_provenance",
}
local transient_header_metadata = {
    prototype_tags = true, field_macro_paths = true, macro_definitions = true, macro_changes = true,
}

local function fail(message)
    error("invalid C definition manifest: " .. message, 0)
end

local function project(source, role, options)
    options = options or {}
    local work, strict = graphcodec.work(options), options.strict
    local queue, memo, roles = {}, {}, {}
    work(0, true)
    local copy
    copy = function(value, kind)
        work()
        if kind:sub(-1) == "?" then
            if value == nil then return nil end
            kind = kind:sub(1, -2)
        end
        if kind == "names_or_false" or kind == "c_name" then
            if value == false then return false end
            kind = kind == "c_name" and type(value) ~= "table" and "string" or "names"
        elseif kind == "ctype_value" then
            if type(value) == "string" then return value end
            kind = type(value) == "table" and value.type ~= nil and "ctype" or "parts"
        elseif kind == "part" then
            if type(value) == "string" then return value end
            kind = type(value) == "table" and value.type ~= nil and "ctype" or "extent"
        elseif kind == "profile_macro" then
            -- Profile interpretation concatenates object replacement tokens;
            -- function-like values need only the rejecting `args` marker.
            if type(value) == "string" then return value end
            if type(value) == "table" and value.args ~= nil then return { args = {} } end
            fail("invalid target profile macro fact")
        end
        if kind == "extent" and type(value) ~= "table" then kind = "atom" end
        if kind == "true" then
            if value ~= true then fail("expected true set member") end
            return true
        elseif kind == "atom" or kind == "string" or kind == "boolean" or kind == "integer" then
            local actual = type(value)
            if kind == "atom" then
                if actual ~= "string" and actual ~= "number" and actual ~= "boolean" then fail("expected scalar") end
            elseif kind == "integer" then
                if math.type(value) ~= "integer" then fail("expected integer") end
            elseif actual ~= kind then fail("expected " .. kind) end
            if actual == "number" and (value ~= value or value == math.huge or value == -math.huge) then fail("non-finite number") end
            return value
        end
        if type(value) ~= "table" then fail("expected " .. kind .. " table") end
        if kind == "include" then
            if options.external and options.external[value] == "ffi-include" then return value end
            fail("C declaration origin is not the current module header")
        end
        if strict and getmetatable(value) ~= nil then fail("unexpected metatable") end
        if kind == "type" then
            kind = value._tag
            if type(kind) ~= "string" or not schemas[kind] or not kind:match("^Type%.") then fail("unsupported semantic C type") end
        elseif value._tag ~= nil then fail("unexpected tagged parser table") end
        if memo[value] then
            if roles[value] ~= kind then fail("incompatible declaration roles") end
            return memo[value]
        end
        local result = {}
        memo[value], roles[value] = result, kind
        queue[#queue + 1] = { source = value, target = result, kind = kind }
        return result
    end
    local result = copy(source, role)
    local index = 1
    while queue[index] do
        work()
        local item = queue[index]
        local from, to, kind = item.source, item.target, item.kind
        local schema = schemas[kind]
        if schema then
            if kind:match("^Type%.") then to._tag = kind end
            for field, field_kind in pairs(schema) do
                work()
                local value = from[field]
                if not strict and kind == "ctype" then
                    if field == "_macro_cast" and value then value = true
                    elseif field == "has_integer_literals" and from.integer_literals then value = #from.integer_literals > 0 end
                elseif not strict and kind == "extent" and field == "integer_token" and from.integer_literal then
                    value = from.integer_literal.token
                end
                to[field] = copy(value, field_kind)
            end
            if kind == "header_types" then
                for key, value in pairs(from) do
                    work()
                    if type(key) == "number" then
                        if math.type(key) ~= "integer" or key < 1 then fail("invalid declaration index") end
                        to[key] = copy(value, "declaration")
                    elseif not schema[key] and not transient_header_metadata[key]
                       and (type(value) == "table" and value.type ~= nil) then
                        to[copy(key, "string")] = copy(value, "ctype")
                    elseif strict and not schema[key] then fail("unexpected header metadata " .. tostring(key)) end
                end
            elseif kind == "extent" then
                for key, value in pairs(from) do
                    work()
                    if type(key) == "number" then
                        if math.type(key) ~= "integer" or key < 1 then fail("invalid expression index") end
                        to[key] = copy(value, "extent")
                    elseif strict and not schema[key] then fail("unexpected expression metadata " .. tostring(key)) end
                end
            elseif strict then
                for key in pairs(from) do
                    work()
                    if not schema[key] and key ~= "_tag" then fail("unexpected " .. kind .. " field " .. tostring(key)) end
                end
            end
        elseif maps[kind] then
            for key, value in pairs(from) do
                work()
                to[copy(key, "string")] = copy(value, maps[kind])
            end
        elseif lists[kind] then
            local count, maximum = 0, 0
            for key in pairs(from) do
                work()
                if type(key) == "number" then
                    if math.type(key) ~= "integer" or key < 1 then fail("invalid list index") end
                    count, maximum = count + 1, math.max(maximum, key)
                elseif kind ~= "members" or type(key) ~= "string" then fail("invalid list key") end
            end
            if count ~= maximum then fail("sparse declaration list") end
            for i = 1, count do
                work()
                to[i] = copy(from[i], lists[kind])
                if kind == "members" then
                    local name = copy(from[i].name, "string")
                    if to[name] then fail("duplicate field name") end
                    to[name] = to[i]
                end
            end
        else fail("unknown declaration role " .. tostring(kind)) end
        index = index + 1
    end
    work(0, true)
    return result
end

function cache.header(types, options)
    return project(types, "header_types", options)
end

function cache.foreign(snapshot, options)
    return project(snapshot, "foreign", options)
end

return cache

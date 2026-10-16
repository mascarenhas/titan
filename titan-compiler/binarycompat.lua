-- Load-time compatibility is a separate, erased projection of the checked
-- interface. It deliberately contains no module slots or private field layout.
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"

local binarycompat = { VERSION = 1 }
local categories = { "functions", "variables", "records", "unions", "interfaces" }

local function empty(module)
    local result = { version = binarycompat.VERSION, module = module }
    for _, category in ipairs(categories) do result[category] = {} end
    return result
end

local function names(list)
    if list == nil then return nil end
    local result = {}
    for i, name in ipairs(list) do result[i] = name end
    return result
end

-- These strings describe only ordinary erased value types, never complete
-- module/owner declarations. Nominal applications retain their owner identity
-- and discard their source type arguments through the canonical erasure pass.
local function value_type(typ)
    return types.serialize_semantic(types.erase(typ))
end

local function signature(callable, paramnames)
    local typ = callable
    if typ._tag == "Type.Method" or typ._tag == "Type.StaticMethod" then
        typ = types.Function(typ.params, typ.rettypes, false,
            typ.varargtype, typ.flexrettype)
        paramnames = callable.paramnames
    end
    return { type = value_type(typ), parameters = names(paramnames) }
end

local function fields(list)
    local result = {}
    for _, field in ipairs(list) do
        if not field.islocal then
            result[#result + 1] = { name = field.name,
                type = value_type(field.type), const = field.isconst }
        end
    end
    return result
end

local function callables(map)
    local result = {}
    for name, callable in pairs(map or {}) do
        if not callable.islocal then result[name] = signature(callable) end
    end
    return result
end

local function nominal(owner)
    local result = { fqtn = owner.name }
    if owner._tag == "Type.Interface" then
        result.fields, result.methods = fields(owner.fields), {}
        for _, method in ipairs(owner.methods) do
            result.methods[#result.methods + 1] = {
                name = method.name, signature = signature(method),
            }
        end
        return "interfaces", result
    end
    result.functions, result.methods = callables(owner.functions), callables(owner.methods)
    if owner._tag == "Type.Record" then
        result.fields = fields(owner.fields)
        result.literal = not owner.custom_constructor
            and #result.fields == owner.nfields
        return "records", result
    end
    assert(owner._tag == "Type.Union", "expected a nominal owner")
    result.variants, result.nvariants = {}, owner.nvariants
    for _, variant in ipairs(owner.variants) do
        if not variant.islocal then
            result.variants[#result.variants + 1] = {
                name = variant.name, tag = variant.index,
                parts = fields(variant.parts),
            }
        end
    end
    return "unions", result
end

function binarycompat.module(modtype, registry)
    assert(modtype._tag == "Type.Module", "expected a module interface")
    registry = registry or types.registry
    local result, owners = empty(modtype.name), {}
    for _, member in ipairs(modtype.members) do
        local typ = member.type
        if typ._tag == "Type.Record" or typ._tag == "Type.Union" then
            owners[typ.name] = typ
        end
    end
    for _, typ in pairs(modtype.type_members or {}) do
        if typ._tag == "Type.Interface" then owners[typ.name] = typ end
    end
    local function add_nominal(name, typ)
        local tag = typ._tag
        if tag == "Type.Nominal" or tag == "Type.GenericAlias" then
            local fqtn = typ.fqtn or typ.target_owner_fqtn
            typ = assert(owners[fqtn] or registry[fqtn],
                "missing compatibility owner '" .. fqtn .. "'")
            tag = typ._tag
        end
        if tag == "Type.Record" or tag == "Type.Union" or tag == "Type.Interface" then
            local category, descriptor = nominal(typ)
            result[category][name] = descriptor
        end
    end
    for _, member in ipairs(modtype.members) do
        if not member.islocal then
            if member._tag == "Type.ModuleVariable" then
                result.variables[member.name] = {
                    type = value_type(member.type), const = member.isconst,
                }
            elseif member.type._tag == "Type.Function"
                or member.type._tag == "Type.FunctionScheme"
                or member.type._tag == "Type.CFunction" then
                result.functions[member.name] = signature(member.type, member.paramnames)
            else
                add_nominal(member.name, member.type)
            end
        end
    end
    for name, typ in pairs(modtype.type_members or {}) do add_nominal(name, typ) end
    return result
end

local function selected(map, usage, label)
    local result = {}
    for name in pairs(usage or {}) do
        result[name] = assert(map[name], "missing used compatibility " .. label .. " '" .. name .. "'")
    end
    return result
end

function binarycompat.requirements(modtype, registry, usage)
    local available = binarycompat.module(modtype, registry)
    local result = empty(modtype.name)
    usage = usage or {}
    for _, category in ipairs(categories) do
        for name, use in pairs(usage[category] or {}) do
            local descriptor = assert(available[category][name],
                "missing used compatibility " .. category .. " '" .. name .. "'")
            if category == "records" or category == "unions" then
                assert(type(use) == "table", "nominal usage must be a table")
                local entry = { fqtn = descriptor.fqtn,
                    functions = selected(descriptor.functions, use.functions, "function"),
                    methods = selected(descriptor.methods, use.methods, "method"),
                }
                if category == "records" then
                    entry.fields = descriptor.fields
                    if use.literal then entry.literal = true end
                else
                    entry.variants = descriptor.variants
                    if use.closed then entry.nvariants = descriptor.nvariants end
                end
                result[category][name] = entry
            else
                result[category][name] = descriptor
            end
        end
    end
    return result
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do
        assert(type(key) == "string" or math.type(key) == "integer",
            "compatibility table keys must be strings or integers")
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) == "number" end
        return type(a) == "number" and a < b
            or type(a) == "string" and util.bytewise_less(a, b)
    end)
    return keys
end

local function literal(value, active)
    if type(value) == "string" then return string.format("%q", value)
    elseif type(value) == "boolean" then return tostring(value)
    elseif math.type(value) == "integer" then return tostring(value) end
    assert(type(value) == "table" and getmetatable(value) == nil,
        "compatibility values must be plain tables, strings, booleans or integers")
    active = active or {}
    assert(not active[value], "cyclic compatibility table")
    active[value] = true
    local entries = {}
    for _, key in ipairs(sorted_keys(value)) do
        entries[#entries + 1] = "[" .. literal(key) .. "]=" .. literal(value[key], active)
    end
    active[value] = nil
    return "{" .. table.concat(entries, ",") .. "}"
end

function binarycompat.encode(metadata)
    return "return " .. literal(metadata)
end

-- The runtime supplies these three builtins in a private environment. No Lua
-- globals from the importing application participate in verification.
function binarycompat.verifier(expected, importer, dependency)
    local prefix = "binary compatibility mismatch importing '" .. dependency
        .. "' from '" .. importer .. "': "
    local out = {
        "local type, next, error = type, next, error",
        "local expected = " .. literal(expected),
        "local function fail(path) error(" .. literal(prefix) .. " .. path, 0) end",
        [[local function same(want, got, path)
    if type(want) ~= type(got) then fail(path) end
    if type(want) ~= "table" then
        if want ~= got then fail(path) end
        return
    end
    local wanted, present = 0, 0
    for key, value in next, want do
        wanted = wanted + 1
        same(value, got[key], path .. "." .. key)
    end
    for key in next, got do
        present = present + 1
        if want[key] == nil then fail(path .. "." .. key) end
    end
    if wanted ~= present then fail(path) end
end]],
        [[return function(actual)
    if type(actual) ~= "table" then fail("metadata is not a table") end
    same(expected.version, actual.version, "metadata version")
    same(expected.module, actual.module, "module identity")]],
    }
    for _, category in ipairs(categories) do
        local qcategory = literal(category)
        out[#out + 1] = "if type(actual[" .. qcategory .. "]) ~= 'table' then fail("
            .. literal(category .. " metadata is not a table") .. ") end"
        for _, name in ipairs(sorted_keys(expected[category])) do
            local key = "[" .. qcategory .. "][" .. literal(name) .. "]"
            local path = category .. "." .. name
            if category ~= "records" and category ~= "unions" then
                out[#out + 1] = "same(expected" .. key .. ", actual" .. key .. ", " .. literal(path) .. ")"
            else
                out[#out + 1] = "if type(actual" .. key .. ") ~= 'table' then fail(" .. literal(path) .. ") end"
                local descriptor = expected[category][name]
                for _, field in ipairs({ "fqtn", category == "records" and "fields" or "variants", "nvariants", "literal" }) do
                    if descriptor[field] ~= nil then
                        local access = key .. "[" .. literal(field) .. "]"
                        out[#out + 1] = "same(expected" .. access .. ", actual" .. access .. ", " .. literal(path .. "." .. field) .. ")"
                    end
                end
                for _, kind in ipairs({ "functions", "methods" }) do
                    local access = key .. "[" .. literal(kind) .. "]"
                    out[#out + 1] = "if type(actual" .. access .. ") ~= 'table' then fail(" .. literal(path .. "." .. kind) .. ") end"
                    for _, member in ipairs(sorted_keys(descriptor[kind])) do
                        local member_access = access .. "[" .. literal(member) .. "]"
                        out[#out + 1] = "same(expected" .. member_access .. ", actual" .. member_access .. ", " .. literal(path .. "." .. kind .. "." .. member) .. ")"
                    end
                end
            end
        end
    end
    out[#out + 1] = "end"
    return table.concat(out, "\n")
end

return binarycompat

-- Nominal physical storage is deliberately separate from the public type
-- interface. A producer retains its complete native members. A binary reader
-- reconstructs only the real first public-prefix subobject, never a stand-in
-- for an inaccessible C aggregate with a different effective type.
local types = require "titan-compiler.types"
local graphcodec = require "titan-compiler.graphcodec"
local staticmetadata = require "titan-compiler.staticmetadata"
local util = require "titan-compiler.util"

local nominallayout = { VERSION = 1 }

local function fail(message)
    error("invalid nominal layout: " .. message, 0)
end

local function attempt(fn, ...)
    local ok, value = pcall(fn, ...)
    if not ok then
        if type(value) ~= "string" then error(value, 0) end
        return nil, value
    end
    return value
end

local function integer(value, minimum, what)
    if math.type(value) ~= "integer" or value < minimum then
        fail(what .. " must be an integer >= " .. minimum)
    end
    return value
end

local function array(value, length, what)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        fail(what .. " must be a plain list")
    end
    local count = 0
    for key in pairs(value) do
        integer(key, 1, what .. " index")
        count = count + 1
    end
    if count ~= #value or length and count ~= length then
        fail(what .. " has an invalid length")
    end
    for index = 1, count do
        if rawget(value, index) == nil then fail(what .. " is sparse") end
    end
    return value
end

local function name(value, what)
    if type(value) ~= "string" or value == "" then
        fail(what .. " is not a valid name")
    end
    local components = {}
    for component in value:gmatch("[^.]+") do
        if not component:match("^[A-Za-z_][A-Za-z0-9_-]*$") then
            fail(what .. " is not a valid name")
        end
        components[#components + 1] = component
    end
    if table.concat(components, ".") ~= value then fail(what .. " is not a valid name") end
    return value
end

local function boolean(value, what)
    if type(value) ~= "boolean" then fail(what .. " must be a boolean") end
    return value
end

local function erased(typ)
    if type(typ) ~= "table" then fail("slot has no type") end
    return types.contains_generic(typ) and types.erase(typ) or typ
end

-- Completeness is structural; the checker/C compiler owns target-specific
-- alignment and symbolic-extent validation. Pointers stop this traversal.
local function fixed_object(typ, active)
    typ = types.resolve_c_typedef(typ)
    if not typ then fail("missing native object type") end
    active = active or {}
    if active[typ] then fail("recursive by-value C aggregate") end
    local tag = typ._tag
    if tag == "Type.CStruct" or tag == "Type.CUnion" then
        if typ.complete ~= true then fail("incomplete C aggregate") end
        if typ.has_fam then fail("FAM aggregate cannot be an embedded member") end
        active[typ] = true
        for _, field in ipairs(typ.fields) do
            if field.flexible_array then
                fail("FAM aggregate cannot be an embedded member")
            end
            fixed_object(field.type, active)
        end
        active[typ] = nil
    elseif tag == "Type.CArray" then
        if typ.len == nil or typ.len == "" then
            fail("embedded C array has no fixed extent")
        end
        if type(typ.len) == "number" then
            integer(typ.len, 1, "fixed array extent")
        end
        active[typ] = true
        fixed_object(typ.elem, active)
        active[typ] = nil
    elseif tag ~= "Type.CInteger" and tag ~= "Type.CFloat"
       and tag ~= "Type.CPointer" then
        fail("unsupported embedded C object type " .. tostring(tag))
    end
end

local classify
classify = function(typ)
    typ = erased(typ)
    local tag = typ._tag
    if types.is_gc(typ) or tag == "Type.Union" or tag == "Type.Interface" then
        return { storage = "uv", kind = "gc", type = typ }
    elseif tag == "Type.Option" then
        local base = classify(typ.base)
        if base.storage ~= "payload" or base.kind ~= "scalar" then
            fail("optional native storage requires a scalar base")
        end
        return { storage = "payload", kind = "option", type = typ,
            base = base }
    elseif tag == "Type.Nil" or tag == "Type.Boolean"
       or tag == "Type.Integer" or tag == "Type.Float" then
        return { storage = "payload", kind = "scalar", type = typ }
    elseif types.is_direct_c(typ) then
        local resolved = types.resolve_c_typedef(typ)
        if resolved._tag == "Type.CArray" and
           (resolved.len == nil or resolved.len == "") then
            -- The nominal field rule treats an unsized array as a borrowed
            -- pointer view. Preserve the element's explicit C qualification.
            typ = types.CPointer(resolved.elem, types.c_type_qualifiers(typ))
            resolved = typ
        end
        if types.c_automatic_gc_bearing(typ) then
            fail("embedded C aggregate contains GC-bearing storage")
        end
        if resolved._tag == "Type.CInteger" or resolved._tag == "Type.CFloat"
           or resolved._tag == "Type.CPointer" then
            return { storage = "payload", kind = "scalar", type = typ }
        end
        fixed_object(typ)
        return { storage = "payload",
            kind = resolved._tag == "Type.CArray" and "array" or "aggregate",
            type = typ }
    end
    fail("unsupported slot type " .. tostring(tag))
end

function nominallayout.classify(typ)
    return attempt(classify, typ)
end

local function new_plan(kind, fqtn)
    name(fqtn, "owner")
    -- Escape every nonalphanumeric byte, including the escape introducer.
    -- Dotted owner names can otherwise collide with underscores in names.
    local cname = "_titan_nominal_" .. fqtn:gsub("[^A-Za-z0-9]", function(byte)
        return string.format("_%02x", byte:byte())
    end)
    return {
        kind = kind, name = fqtn, cname = cname .. "_payload",
        prefix_cname = cname .. "_public_payload", prefix_member = "_public",
        slots = {}, by_index = {}, by_name = {},
        public_members = {}, private_members = {}, members = {},
        public_uv = {}, private_uv = {}, nuv = 0, npublicuv = 0,
        has_private = false, complete = true, islocal = false,
    }
end

local function add_slot(plan, field, islocal)
    local index = integer(field.index, plan.kind == "record" and 0 or 1,
        "logical slot index")
    if plan.by_index[index] or plan.by_name[field.name] then
        fail("duplicate logical slot")
    end
    local slot = classify(field.type)
    slot.index, slot.name = index, name(field.name, "slot")
    slot.isconst = boolean(field.isconst, "slot constness")
    slot.islocal = islocal == true
    plan.slots[#plan.slots + 1] = slot
    plan.by_index[index], plan.by_name[slot.name] = slot, slot
    if slot.islocal then plan.has_private = true end
    if slot.storage == "uv" then
        local group = slot.islocal and plan.private_uv or plan.public_uv
        group[#group + 1] = slot
    else
        slot.member = (plan.kind == "record" and "f" or "p") .. index
        slot.path = plan.kind == "record" and not slot.islocal
            and plan.prefix_member .. "." .. slot.member or slot.member
        local group = slot.islocal and plan.private_members or plan.public_members
        group[#group + 1] = slot
    end
end

local function finish_plan(plan)
    for _, group in ipairs({plan.public_uv, plan.private_uv}) do
        for _, slot in ipairs(group) do
            slot.uv_index = plan.nuv
            plan.nuv = plan.nuv + 1
        end
    end
    plan.npublicuv = #plan.public_uv
    for _, group in ipairs({plan.public_members, plan.private_members}) do
        for _, slot in ipairs(group) do plan.members[#plan.members + 1] = slot end
    end
    return plan
end

function nominallayout.record(owner)
    return attempt(function()
        if owner._tag ~= "Type.Record" then fail("expected a record owner") end
        local plan = new_plan("record", owner.name)
        plan.islocal = owner.islocal == true
        plan.nfields = integer(owner.nfields, 0, "record field count")
        for position, field in ipairs(owner.fields) do
            if field.index >= plan.nfields then fail("record field index exceeds arity") end
            if position > 1 and owner.fields[position - 1].index >= field.index then
                fail("record fields are not in declaration order")
            end
            add_slot(plan, field, field.islocal)
        end
        if #plan.slots > plan.nfields then fail("record field count is inconsistent") end
        if #plan.slots < plan.nfields then
            plan.complete, plan.has_private = false, true
        end
        return finish_plan(plan)
    end)
end

function nominallayout.variant(owner, variant)
    return attempt(function()
        if owner._tag ~= "Type.Union" or variant._tag ~= "Type.Variant"
           or variant.fqtn ~= owner.name then fail("expected a variant of this union") end
        local plan = new_plan("variant", owner.name .. "." .. variant.name)
        plan.owner = owner.name
        plan.tag = integer(variant.index, 0, "variant tag")
        plan.arity = #variant.parts
        plan.header_member, plan.tag_member, plan.tag_ctype = "header", "tag", "unsigned int"
        plan.islocal = owner.islocal == true or variant.islocal == true
        for index, part in ipairs(variant.parts) do
            if part.index ~= index then fail("union part index disagrees with its position") end
            -- Union parts retain canonical isconst=false. Their immutable
            -- binding/fusion rule belongs to the union context, not this flag.
            add_slot(plan, part, plan.islocal)
        end
        return finish_plan(plan)
    end)
end

-- The wire representation uses positional lists only. Besides providing a
-- closed schema, this keeps graph traversal independent of Lua hash seeds.
-- GC slots intentionally carry no type graph: their checked type already
-- belongs to the unchanged semantic interface.
local function type_recipe(typ, seen)
    if not seen and typ._tag:match("^Type%.C")
       and not types.is_exportable_c_type_graph(typ) then
        fail("public native member has no portable or exportable C declaration")
    end
    seen = seen or {}
    if seen[typ] then return seen[typ] end
    local tag = typ._tag
    if tag == "Type.Nil" or tag == "Type.Boolean" or tag == "Type.Integer"
       or tag == "Type.Float" then return { tag }
    elseif tag == "Type.Option" then return { tag, type_recipe(typ.base, seen) } end
    local recipe = { tag }
    seen[typ] = recipe
    if tag == "Type.CVoid" then return recipe
    elseif tag == "Type.CInteger" then
        recipe[2], recipe[3], recipe[4], recipe[5] =
            typ.spelling, typ.signed, typ.rank, typ.bits
        return recipe
    elseif tag == "Type.CFloat" then
        recipe[2] = typ.spelling
        return recipe
    elseif tag == "Type.CPointer" then
        local quals = {}
        for i, qualifier in ipairs(typ.quals) do quals[i] = qualifier end
        local pointee = types.is_c_lua_state(typ.pointee)
            and { "lua_State" } or type_recipe(typ.pointee, seen)
        recipe[2], recipe[3] = pointee, quals
        return recipe
    elseif tag == "Type.CFunction" then
        local params = {}
        for i, param in ipairs(typ.params) do params[i] = type_recipe(param, seen) end
        -- Portable C functions have no optional ABI annotation.
        recipe[2], recipe[3], recipe[4] = params, type_recipe(typ.ret, seen), false
        return recipe
    elseif tag == "Type.CArray" then
        recipe[2], recipe[3], recipe[4] = type_recipe(typ.elem, seen), typ.len, typ.quals
        return recipe
    elseif tag == "Type.CTypedef" then
        recipe[2], recipe[3], recipe[4], recipe[5] = typ.name,
            type_recipe(typ.target, seen), typ.quals, types.c_declaration_origin(typ)
        return recipe
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        recipe[2], recipe[3], recipe[4] = typ.cname or false,
            typ.tagname or false, typ.typedef or false
        recipe[5], recipe[6], recipe[7], recipe[8] = {}, typ.complete,
            typ.has_fam or false, types.c_declaration_origin(typ)
        for index, field in ipairs(typ.fields) do
            recipe[5][index] = {field.name, type_recipe(field.type, seen),
                field.bitfield or false, field.flexible_array}
        end
        return recipe
    end
    fail("unsupported public native declaration " .. tostring(tag))
end

local function recipe_type(recipe, depth, seen)
    seen = seen or {}
    if seen[recipe] then return seen[recipe] end
    depth = (depth or 0) + 1
    if depth > 64 then fail("native declaration is too deep") end
    array(recipe, nil, "native declaration")
    local tag = recipe[1]
    local typ
    if tag == "Type.Nil" or tag == "Type.Boolean" or tag == "Type.Integer"
       or tag == "Type.Float" or tag == "Type.CVoid" then
        array(recipe, 1, "scalar declaration")
        typ = types[tag:sub(6)]()
    elseif tag == "Type.Option" then
        array(recipe, 2, "optional declaration")
        typ = types.Option(recipe_type(recipe[2], depth, seen))
    elseif tag == "Type.CInteger" then
        array(recipe, 5, "C integer declaration")
        typ = types.CInteger(recipe[2], recipe[3], recipe[4], recipe[5])
    elseif tag == "Type.CFloat" then
        array(recipe, 2, "C floating declaration")
        typ = types.CFloat(recipe[2])
    elseif tag == "Type.CPointer" then
        array(recipe, 3, "C pointer declaration")
        array(recipe[3], nil, "C pointer qualifiers")
        local pointee
        if type(recipe[2]) == "table" and recipe[2][1] == "lua_State" then
            array(recipe[2], 1, "Lua state declaration")
            pointee = types.CStruct(nil, "lua_State", nil, {}, false, false)
        else pointee = recipe_type(recipe[2], depth, seen) end
        typ = types.CPointer(pointee, recipe[3])
    elseif tag == "Type.CFunction" then
        array(recipe, 4, "C function declaration")
        array(recipe[2], nil, "C function parameters")
        local params = {}
        for i, param in ipairs(recipe[2]) do params[i] = recipe_type(param, depth, seen) end
        typ = types.CFunction(params, recipe_type(recipe[3], depth, seen), recipe[4], nil)
    elseif tag == "Type.CArray" then
        array(recipe, 4, "C array declaration")
        typ = types.CArray(recipe_type(recipe[2], depth, seen), recipe[3], recipe[4])
    elseif tag == "Type.CTypedef" then
        array(recipe, 5, "C typedef declaration")
        typ = types.CTypedef(recipe[2], nil, recipe[4], recipe[5])
        seen[recipe] = typ
        typ.target = recipe_type(recipe[3], depth, seen)
    elseif tag == "Type.CStruct" or tag == "Type.CUnion" then
        array(recipe, 8, "C aggregate declaration")
        array(recipe[5], nil, "C aggregate fields")
        if tag == "Type.CStruct" then
            typ = types.CStruct(recipe[2] or nil, recipe[3] or nil,
                recipe[4] or nil, {}, recipe[6], recipe[7], recipe[8])
        else
            if recipe[7] ~= false then fail("C union has a flexible-array flag") end
            typ = types.CUnion(recipe[2] or nil, recipe[3] or nil,
                recipe[4] or nil, {}, recipe[6], recipe[8])
        end
        seen[recipe] = typ
        for index, field in ipairs(recipe[5]) do
            array(field, 4, "C aggregate field")
            local declared = types.CField(typ, field[1],
                recipe_type(field[2], depth, seen), field[3] or nil, field[4])
            if typ.fields[declared.name] then fail("duplicate C aggregate field") end
            typ.fields[index], typ.fields[declared.name] = declared, declared
        end
    else fail("unknown native declaration " .. tostring(tag)) end
    if depth == 1 and tag:match("^Type%.C")
       and not types.is_exportable_c_type_graph(typ) then
        fail("invalid exportable C declaration")
    end
    return typ
end

local function public_wire(plan)
    if plan.islocal then return nil end
    local slots = {}
    for _, slot in ipairs(plan.slots) do
        if not slot.islocal then
            local recipe = false
            if slot.storage == "payload" then recipe = type_recipe(slot.type) end
            slots[#slots + 1] = {slot.index, slot.name, slot.isconst, slot.storage,
                slot.storage == "uv" and slot.uv_index or slot.member,
                recipe}
        end
    end
    return {plan.kind, plan.name, plan.complete and not plan.has_private,
        plan.kind == "record" and plan.nfields or plan.arity,
        plan.npublicuv, slots, plan.owner or false, plan.tag or false}
end

local function restore_public(wire)
    array(wire, 8, "nominal descriptor")
    local kind = wire[1]
    if kind ~= "record" and kind ~= "variant" then fail("unknown nominal kind") end
    local plan = new_plan(kind, wire[2])
    plan.complete = boolean(wire[3], "layout completeness")
    plan.has_private = not plan.complete
    local count = integer(wire[4], 0, "logical slot count")
    local nuv = integer(wire[5], 0, "public UV count")
    if count > 65535 or nuv > 65535 then fail("slot count exceeds userdata limit") end
    array(wire[6], nil, "public slots")
    if kind == "record" then
        plan.nfields = count
        if wire[7] ~= false or wire[8] ~= false then fail("record has variant metadata") end
    else
        plan.arity, plan.owner = count, name(wire[7], "union owner")
        plan.tag = integer(wire[8], 0, "variant tag")
        if not plan.complete or plan.name:sub(1, #plan.owner + 1) ~= plan.owner .. "." then
            fail("public variant is incomplete or belongs to another union")
        end
        plan.header_member, plan.tag_member, plan.tag_ctype = "header", "tag", "unsigned int"
    end
    local previous = kind == "record" and -1 or 0
    for _, item in ipairs(wire[6]) do
        array(item, 6, "public slot")
        local index = integer(item[1], kind == "record" and 0 or 1, "logical slot index")
        if index <= previous or index >= count + (kind == "record" and 0 or 1) then
            fail("public slot indices are not ordered within arity")
        end
        previous = index
        local slot = { index = index, name = name(item[2], "slot"),
            isconst = boolean(item[3], "slot constness"), islocal = false }
        if plan.by_name[slot.name] then fail("duplicate public slot name") end
        if item[4] == "uv" then
            if item[6] ~= false or item[5] ~= #plan.public_uv then
                fail("public UV indices are not dense")
            end
            slot.storage, slot.kind, slot.uv_index = "uv", "gc", item[5]
            plan.public_uv[#plan.public_uv + 1] = slot
        elseif item[4] == "payload" then
            local classified = classify(recipe_type(item[6]))
            if classified.storage ~= "payload" then fail("native member is GC-bearing") end
            slot.storage, slot.kind, slot.type, slot.base = classified.storage,
                classified.kind, classified.type, classified.base
            slot.member = (kind == "record" and "f" or "p") .. index
            if item[5] ~= slot.member then fail("native member name disagrees with its index") end
            slot.path = kind == "record" and "_public." .. slot.member or slot.member
            plan.public_members[#plan.public_members + 1] = slot
            plan.members[#plan.members + 1] = slot
        else fail("unknown public storage kind") end
        plan.slots[#plan.slots + 1] = slot
        plan.by_index[index], plan.by_name[slot.name] = slot, slot
    end
    if #plan.public_uv ~= nuv then fail("public UV count disagrees with slots") end
    if plan.complete and #plan.slots ~= count then fail("complete layout has missing slots") end
    plan.nuv, plan.npublicuv = nuv, nuv
    return plan
end

function nominallayout.public(plan)
    return attempt(function()
        local wire = public_wire(plan)
        return wire and restore_public(wire) or nil
    end)
end

function nominallayout.encode(module_name, plans)
    return attempt(function()
        if not staticmetadata.valid_module_name(module_name) then fail("invalid module name") end
        local entries, names = {}, {}
        for _, plan in pairs(plans) do
            local wire = public_wire(plan)
            if wire then
                local restored = restore_public(wire)
                if names[restored.name] then fail("duplicate nominal descriptor") end
                names[restored.name] = true
                entries[#entries + 1] = wire
            end
        end
        table.sort(entries, function(a, b) return util.bytewise_less(a[2], b[2]) end)
        local encoded, err = graphcodec.encode({"titan-nominal-layouts",
            nominallayout.VERSION, module_name, entries})
        if not encoded then fail(err) end
        return encoded
    end)
end

function nominallayout.decode(bytes, module_name)
    return attempt(function()
        local wire, err = graphcodec.decode(bytes)
        if not wire then fail(err) end
        array(wire, 4, "layout envelope")
        if wire[1] ~= "titan-nominal-layouts" or wire[2] ~= nominallayout.VERSION then
            fail("incompatible layout envelope")
        end
        if not staticmetadata.valid_module_name(wire[3]) or
           module_name and wire[3] ~= module_name then fail("module name mismatch") end
        array(wire[4], nil, "module layouts")
        local result = {version = nominallayout.VERSION, module = wire[3],
            layouts = {}, records = {}, variants = {}}
        local previous
        for _, entry in ipairs(wire[4]) do
            local plan = restore_public(entry)
            if previous and not util.bytewise_less(previous, plan.name) then
                fail("module layouts are not unique and ordered")
            end
            previous = plan.name
            local owner = plan.kind == "record" and plan.name or plan.owner
            if owner:match("^(.*)%.[^.]+$") ~= result.module then
                fail("nominal descriptor belongs to another module")
            end
            result.layouts[plan.name] = plan
            if plan.kind == "record" then result.records[plan.name] = plan
            else
                local variants = result.variants[plan.owner] or {}
                if variants[plan.tag] then fail("duplicate union tag") end
                variants[plan.tag] = plan
                result.variants[plan.owner] = variants
            end
        end
        return result
    end)
end

return nominallayout

local core = require "titan-compiler.coder.core"
local _ENV = core

local layout = require "titan-compiler.nominallayout"

-- A nominal's logical indices never denote physical storage. All generated
-- clients (including Lua accessors and callback bridges) use these plans.
function coder._nominal_plan(ctx, owner, variant)
    if owner._tag == "Type.Nominal" then
        owner = assert(types.registry[owner.fqtn])
    end
    local tl = ctx.tlcontext or ctx
    local key = owner.name .. (variant and "." .. variant.name or "")
    local plan = tl.nominal_plans[key]
    if not plan then
        plan = tl.imported_nominal_layouts[key]
        if not plan then
            plan = assert(variant and layout.variant(owner, variant)
                or layout.record(owner))
        end
        tl.nominal_plans[key] = plan
        tl.nominal_plan_list[#tl.nominal_plan_list + 1] = plan
    end
    return plan
end

function coder._nominal_member(plan, slot, object)
    assert(slot.storage == "payload")
    local typename, path = plan.cname, slot.path
    if plan.kind == "record" and not slot.islocal then
        -- The public prefix is an actual first subobject, not a shorter cast
        -- over a flat private struct. getudatamem uses the object's true UV
        -- count, which can include producer-private traced slots.
        typename, path = plan.prefix_cname, slot.member
    end
    return "((" .. typename .. " *)getudatamem(" .. object .. "))->" .. path
end

function coder._nominal_uv(slot, object)
    return "&((" .. object .. ")->uv[" .. slot.uv_index .. "].uv)"
end

local function payload_declaration(slot)
    if slot.kind == "option" then
        local base = slot.base and slot.base.type or slot.type.base
        local value = types.is_direct_c(base)
            and cdeclarator.render_declaration(coder._c_value_type(base), "value")
            or ctype(base) .. " value"
        return "struct { int present; " .. value .. "; } " .. slot.member .. ";"
    end
    if types.is_direct_c(slot.type) then
        return cdeclarator.render_declaration(
            coder._c_value_type(slot.type), slot.member) .. ";"
    end
    return ctype(slot.type) .. " " .. slot.member .. ";"
end

function coder._nominal_declarations(tl)
    local declarations = {
        "typedef struct { unsigned int tag; } _titan_union_header;",
    }
    for _, plan in ipairs(tl.nominal_plan_list) do
        local members = {}
        if plan.kind == "record" then
            if #plan.public_members > 0 then
                for _, slot in ipairs(plan.public_members) do
                    members[#members + 1] = payload_declaration(slot)
                end
                declarations[#declarations + 1] = "typedef struct {\n"
                    .. table.concat(members, "\n") .. "\n} "
                    .. plan.prefix_cname .. ";"
            end
            if plan.complete then
                members = {}
                if #plan.public_members > 0 then
                    members[1] = plan.prefix_cname .. " " .. plan.prefix_member .. ";"
                end
                for _, slot in ipairs(plan.private_members) do
                    members[#members + 1] = payload_declaration(slot)
                end
                if #members > 0 then
                    declarations[#declarations + 1] = "typedef struct {\n"
                        .. table.concat(members, "\n") .. "\n} " .. plan.cname .. ";"
                end
            end
        else
            members[1] = "_titan_union_header header;"
            for _, slot in ipairs(plan.members) do
                members[#members + 1] = payload_declaration(slot)
            end
            declarations[#declarations + 1] = "typedef struct {\n"
                .. table.concat(members, "\n") .. "\n} " .. plan.cname .. ";"
        end
        if plan.complete and (plan.kind ~= "record" or #plan.members > 0) then
            -- Lua guarantees UValue alignment, not arbitrary over-alignment.
            declarations[#declarations + 1] = "typedef char " .. plan.cname
                .. "_alignment[(_Alignof(" .. plan.cname
                .. ") <= _Alignof(UValue)) ? 1 : -1];"
        end
    end
    return table.concat(declarations, "\n")
end

function coder._nominal_size(plan)
    assert(plan.complete, "cannot allocate an incomplete imported nominal layout")
    return plan.kind == "record" and #plan.members == 0 and "0"
        or "sizeof(" .. plan.cname .. ")"
end

function coder._nominal_tag(object)
    return "((_titan_union_header *)getudatamem(" .. object .. "))->tag"
end

-- Read a native value. Only a true boxed consumer should call _nominal_box;
-- fixed aggregates project a borrowed pointer into their rooted nominal owner.
function coder._nominal_read(ctx, plan, slot, typ, object)
    if slot.storage == "uv" then
        return "", getslot(typ, nil, coder._nominal_uv(slot, object))
    end
    local member = coder._nominal_member(plan, slot, object)
    if slot.kind == "aggregate" then
        return "", "&(" .. member .. ")"
    elseif slot.kind == "array" then
        return "", member
    elseif slot.kind == "option" then
        local decl, name = newtmp(ctx, typ, false)
        if coder._is_native_option(typ) then
            return decl .. "\n" .. name .. ".present = " .. member .. ".present;\n"
                .. "if (" .. name .. ".present) " .. name .. ".value = "
                .. member .. ".value;", name
        end
        return decl .. "\n" .. coder._nominal_box(ctx, plan, slot,
            typ, object, "&" .. name), name
    end
    return "", member
end

function coder._nominal_store(ctx, plan, slot, typ, object, value)
    if slot.storage == "uv" then
        local dst = coder._nominal_uv(slot, object)
        return setslot(typ, dst, value) .. "\n"
            .. "luaC_barrierback(L, obj2gco(" .. object .. "), " .. dst .. ");"
    end
    local member = coder._nominal_member(plan, slot, object)
    if slot.kind == "array" then
        return "memcpy((void *)" .. member .. ", " .. value .. ", sizeof(" .. member .. "));"
    elseif slot.kind == "aggregate" then
        -- The destination is freshly allocated storage or a checker-approved
        -- whole-object replacement. C assignment cannot initialize an object
        -- whose declaration (or a nested member) is const-qualified.
        local decl, name = newforeigntmp(ctx, typ, value)
        return "{ " .. decl .. "\nmemcpy((void *)&(" .. member .. "), &"
            .. name .. ", sizeof(" .. member .. "));\n}"
    elseif slot.kind == "option" then
        if coder._is_native_option(typ) then
            local name = fresh_lowering_name(ctx, "_nominal_option_")
            return "{ " .. ctype(typ) .. " " .. name .. " = " .. value .. ";\n"
                .. member .. ".present = " .. name .. ".present;\n"
                .. "if (" .. name .. ".present) " .. member .. ".value = "
                .. name .. ".value;\n}"
        end
        local name = fresh_lowering_name(ctx, "_nominal_option_")
        return "{ TValue " .. name .. " = " .. value .. ";\n"
            .. member .. ".present = !ttisnil(&" .. name .. ");\n"
            .. "if (" .. member .. ".present) " .. member .. ".value = "
            .. getslot(typ.base, nil, "&" .. name) .. ";\n}"
    end
    return member .. " = " .. value .. ";"
end

function coder._nominal_box(ctx, plan, slot, typ, object, dst)
    if slot.storage == "uv" then
        return copyboxed(ctx, typ, dst, coder._nominal_uv(slot, object))
    end
    local member = coder._nominal_member(plan, slot, object)
    if slot.kind == "aggregate" then
        return "setpvalue(" .. dst .. ", (void *)&(" .. member .. "));"
    elseif slot.kind == "array" then
        return "setpvalue(" .. dst .. ", (void *)" .. member .. ");"
    elseif slot.kind == "option" then
        return "if (" .. member .. ".present) {\n"
            .. setboxed(ctx, typ.base, dst, member .. ".value")
            .. "\n} else { setnilvalue(" .. dst .. "); }"
    end
    return setboxed(ctx, typ, dst, member)
end

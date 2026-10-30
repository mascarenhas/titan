local core = require "titan-compiler.coder.core"
local _ENV = core

-- Type-directed projections retain every native integer bit and recurse through
-- C objects using C member expressions. No padding, addresses, or private
-- physical layout is interpreted by the reflection library.
local function unsupported(typ)
    return "luaL_error(L, " .. c_string_literal(
        "unsupported reflected native storage: " .. types.tostring(typ)) .. ");"
end

local function project_c(ctx, typ, expression, depth)
    local resolved = types.resolve_c_typedef(typ)
    local tag = resolved._tag
    depth = depth or 0
    if tag == "Type.CInteger" then
        if not resolved.bits or resolved.bits > 64 then return unsupported(typ) end
        -- memcpy, rather than an implementation-defined unsigned-to-signed
        -- conversion, transfers the complete uint64 bit pattern to Lua.
        return "{ uint64_t _bits = (uint64_t)(" .. expression .. "); "
            .. "lua_Integer _integer; memcpy(&_integer, &_bits, sizeof(_integer)); "
            .. "lua_pushinteger(L, _integer); }"
    elseif tag == "Type.CFloat" then
        if resolved.spelling == "long double" then
            return "{ char _text[128]; int _length = titan_reflect_format_long_double(_text, sizeof(_text), (long double)("
                .. expression .. ")); if (_length < 0 || (size_t)_length >= sizeof(_text)) "
                .. "luaL_error(L, \"long double projection exceeds its text buffer\"); "
                .. "lua_pushlstring(L, _text, (size_t)_length); }"
        end
        return "lua_pushnumber(L, (lua_Number)(" .. expression .. "));"
    elseif tag == "Type.CPointer" then
        return "lua_pushlightuserdata(L, titan_cast_func(void *, " .. expression .. "));"
    elseif tag == "Type.CArray" and resolved.len ~= nil and resolved.len ~= "" then
        local array, index = "_projection_array_" .. depth, "_projection_index_" .. depth
        local count = "(sizeof(" .. expression .. ") / sizeof((" .. expression .. ")[0]))"
        return "{ Table *" .. array .. " = titan_reflect_projection_array(L, " .. count .. ");\n"
            .. "for (size_t " .. index .. " = 0; " .. index .. " < " .. count .. "; ++" .. index .. ") {\n"
            .. project_c(ctx, resolved.elem, "(" .. expression .. ")[" .. index .. "]", depth + 1)
            .. "\ntitan_reflect_projection_put(L, " .. array .. ", (lua_Integer)" .. index .. " + 1);\n} }"
    elseif tag == "Type.CStruct" and resolved.complete and not resolved.has_fam then
        local array = "_projection_array_" .. depth
        local code = { "{ Table *" .. array .. " = titan_reflect_projection_array(L, " .. #resolved.fields .. ");" }
        for index, field in ipairs(resolved.fields) do
            if not field.name or field.name == "" or field.flexible_array then return unsupported(typ) end
            code[#code + 1] = project_c(ctx, field.type,
                "(" .. expression .. ")." .. field.name, depth + 1)
            code[#code + 1] = "titan_reflect_projection_put(L, " .. array .. ", " .. index .. ");"
        end
        code[#code + 1] = "}"
        return table.concat(code, "\n")
    end
    return unsupported(typ)
end

local function construct_c(ctx, typ, expression, source, depth)
    local resolved = types.resolve_c_typedef(typ)
    local tag = resolved._tag
    depth = depth or 0
    if tag == "Type.CInteger" or tag == "Type.CFloat" or tag == "Type.CPointer" then
        local value = "_projection_scalar_" .. depth
        local declaration = cdeclarator.render_declaration(coder._c_value_type(typ), value)
        local code = { "{ " .. declaration .. ";" }
        if tag == "Type.CInteger" then
            if not resolved.bits or resolved.bits > 64 then return unsupported(typ) end
            code[#code + 1] = "if (!ttisinteger(" .. source .. ")) luaL_error(L, \"native integer projection requires integer bits\");"
            if resolved.spelling == "_Bool" or resolved.spelling == "bool" then
                code[#code + 1] = "if (ivalue(" .. source .. ") != 0 && ivalue(" .. source
                    .. ") != 1) luaL_error(L, \"native boolean projection out of range\");"
            end
            if resolved.signed then
                if resolved.bits < 64 then
                    local shift = 64 - resolved.bits
                    code[#code + 1] = "if (ivalue(" .. source .. ") < -(INT64_MAX >> " .. shift .. ") - 1"
                        .. " || ivalue(" .. source .. ") > (INT64_MAX >> " .. shift
                        .. ")) luaL_error(L, \"native integer projection out of range\");"
                end
                code[#code + 1] = value .. " = (" .. cdeclarator.render_declaration(coder._c_value_type(typ), "") .. ")ivalue(" .. source .. ");"
            else
                code[#code + 1] = "uint64_t _bits; lua_Integer _integer = ivalue(" .. source .. "); memcpy(&_bits, &_integer, sizeof(_bits));"
                if resolved.bits < 64 then
                    code[#code + 1] = "if (_bits > (UINT64_MAX >> " .. (64 - resolved.bits)
                        .. ")) luaL_error(L, \"native integer projection out of range\");"
                end
                code[#code + 1] = value .. " = (" .. cdeclarator.render_declaration(coder._c_value_type(typ), "") .. ")_bits;"
            end
        elseif tag == "Type.CFloat" then
            if resolved.spelling == "long double" then
                code[#code + 1] = "if (!ttisstring(" .. source .. ")) luaL_error(L, \"long double projection requires hexadecimal text\");"
                code[#code + 1] = "const char *_text = getstr(tsvalue(" .. source .. ")); char *_end; errno = 0; "
                    .. value .. " = titan_reflect_parse_long_double(_text, &_end);"
                code[#code + 1] = "if (_end == _text || (size_t)(_end - _text) != tsslen(tsvalue(" .. source
                    .. ")) || (errno == ERANGE && (" .. value .. " == 0 || isinf(" .. value
                    .. ")))) luaL_error(L, \"invalid or out-of-range long double projection\");"
            else
                code[#code + 1] = "if (!ttisfloat(" .. source .. ")) luaL_error(L, \"native float projection requires float\");"
                code[#code + 1] = value .. " = (" .. cdeclarator.render_declaration(coder._c_value_type(typ), "") .. ")fltvalue(" .. source .. ");"
                code[#code + 1] = "if (isfinite(fltvalue(" .. source .. ")) && !isfinite(" .. value
                    .. ")) luaL_error(L, \"native float projection out of range\");"
            end
        else
            -- A pointer typedef can carry top-level const. Initializing the
            -- temporary is legal even when a later assignment would not be.
            code[1] = "{"
            code[#code + 1] = "if (!ttislightuserdata(" .. source .. ")) luaL_error(L, \"native pointer projection requires a raw pointer\");"
            code[#code + 1] = declaration .. " = titan_cast_func(" .. cdeclarator.render_declaration(coder._c_value_type(typ), "") .. ", pvalue(" .. source .. "));"
        end
        code[#code + 1] = "memcpy((void *)&(" .. expression .. "), &" .. value .. ", sizeof(" .. value .. "));"
        code[#code + 1] = "}"
        return table.concat(code, "\n")
    elseif tag == "Type.CArray" and resolved.len ~= nil and resolved.len ~= "" then
        local array, index, item = "_projection_array_" .. depth, "_projection_index_" .. depth, "_projection_item_" .. depth
        local count = "(sizeof(" .. expression .. ") / sizeof((" .. expression .. ")[0]))"
        return "{ Table *" .. array .. " = titan_reflect_projection_input(L, " .. source .. ", " .. count .. ");\n"
            .. "for (size_t " .. index .. " = 0; " .. index .. " < " .. count .. "; ++" .. index .. ") {\n"
            .. "TValue " .. item .. "; titan_array_get(" .. array .. ", (lua_Integer)" .. index .. " + 1, &" .. item .. ");\n"
            .. construct_c(ctx, resolved.elem, "(" .. expression .. ")[" .. index .. "]", "&" .. item, depth + 1)
            .. "\n} }"
    elseif tag == "Type.CStruct" and resolved.complete and not resolved.has_fam then
        local array, item = "_projection_array_" .. depth, "_projection_item_" .. depth
        local code = { "{ Table *" .. array .. " = titan_reflect_projection_input(L, " .. source .. ", " .. #resolved.fields .. "); TValue " .. item .. ";" }
        local bitfields, initializers = {}, {}
        for index, field in ipairs(resolved.fields) do
            if not field.name or field.name == "" or field.flexible_array then return unsupported(typ) end
            if field.bitfield ~= nil then
                local value = "_projection_bitfield_" .. depth .. "_" .. index
                code[#code + 1] = cdeclarator.render_declaration(coder._c_value_type(field.type), value) .. " = 0;"
                code[#code + 1] = "titan_array_get(" .. array .. ", " .. index .. ", &" .. item .. ");"
                code[#code + 1] = construct_c(ctx, field.type, value, "&" .. item, depth + 1)
                bitfields[#bitfields + 1] = { name = field.name, value = value }
                initializers[#initializers + 1] = "." .. field.name .. " = " .. value
            end
        end
        if #bitfields > 0 then
            -- Bitfields have no address, and a const bitfield cannot be
            -- assigned. Initialize them in a typed C object, check narrowing,
            -- then copy that object into the fresh destination storage.
            local value = "_projection_bitfields_" .. depth
            code[#code + 1] = cdeclarator.render_declaration(typ, value)
                .. " = { " .. table.concat(initializers, ", ") .. " };"
            for _, field in ipairs(bitfields) do
                code[#code + 1] = "if (" .. value .. "." .. field.name .. " != " .. field.value
                    .. ") luaL_error(L, \"native bitfield projection out of range\");"
            end
            code[#code + 1] = "memcpy((void *)&(" .. expression .. "), &" .. value .. ", sizeof(" .. value .. "));"
        end
        for index, field in ipairs(resolved.fields) do
            if field.bitfield == nil then
                code[#code + 1] = "titan_array_get(" .. array .. ", " .. index .. ", &" .. item .. ");"
                code[#code + 1] = construct_c(ctx, field.type,
                    "(" .. expression .. ")." .. field.name, "&" .. item, depth + 1)
            end
        end
        code[#code + 1] = "}"
        return table.concat(code, "\n")
    end
    return unsupported(typ)
end

function coder._reflection_projection(ctx, plan, field, object)
    local slot = assert(plan.by_index[field.index])
    if slot.storage == "payload" and types.is_direct_c(field.type) then
        return project_c(ctx, slot.type, coder._nominal_member(plan, slot, object))
    elseif slot.storage == "payload" and field.type._tag == "Type.Option"
        and types.is_direct_c(field.type.base) then
        local member = coder._nominal_member(plan, slot, object)
        return "if ((" .. member .. ").present) { "
            .. project_c(ctx, field.type.base, "(" .. member .. ").value")
            .. " } else { lua_pushnil(L); }"
    end
    return "{ TValue _projected = {{0}, 0}; "
        .. coder._nominal_box(ctx, plan, slot, field.type, object, "&_projected")
        .. " lua_pushtvalue(L, _projected); }"
end

-- Closure capture transfer uses the same exact native representations.
coder._reflection_project_c = project_c
coder._reflection_construct_c = construct_c

-- Store one reflected field projection (`source`, a TValue pointer) into
-- fresh nominal storage, with the field's construction conversion. Generated
-- codecs reuse it for fields decoded by the reflective field decoder.
function coder._reflection_store(ctx, loc, plan, field, object, source)
    local slot = assert(plan.by_index[field.index])
    if slot.storage == "payload" and types.is_direct_c(field.type) then
        return construct_c(ctx, slot.type,
            coder._nominal_member(plan, slot, object), source)
    elseif slot.storage == "payload" and field.type._tag == "Type.Option"
        and types.is_direct_c(field.type.base) then
        local member = coder._nominal_member(plan, slot, object)
        return "if (ttisnil(" .. source .. ")) { (" .. member .. ").present = 0; } else { "
            .. construct_c(ctx, field.type.base, "(" .. member .. ").value", source)
            .. " (" .. member .. ").present = 1; }"
    elseif field.dynamic_plan and field.dynamic_plan.tag ~= "none" then
        return cvardecl(ctx, field.type, "_converted") .. " = " .. initval(field.type) .. ";\n"
            .. coder._dynamiccheckandget(ctx,
                maybe3.get_checked(field.dynamic_plan, "reflected construction"),
                field.type, "_converted", source, loc, "reflected construction") .. "\n"
            .. coder._nominal_store(ctx, plan, slot, field.type, object, "_converted")
    end
    return "luaL_error(L, \"field has no reflected construction conversion\");"
end

function coder._reflection_constructor(ctx, node, variant)
    local owner = node._type
    local plan = coder._nominal_plan(ctx, owner, variant)
    local fields = variant and variant.parts or owner.fields
    if plan.has_private then
        return "luaL_error(L, \"cannot construct a record with private fields\");"
    end
    local code = {
        "Table *_fields = titan_reflect_projection_input(L, input, " .. #fields .. ");",
        "(void)_fields;",
        "titan_ensure_stack(L, 2);",
        "ptrdiff_t _saved = savestack(L, L->top.p);",
        "Udata *_rec = luaS_newudata(L, " .. coder._nominal_size(plan) .. ", " .. plan.nuv .. ");",
        "setuvalue(L, s2v(L->top.p), _rec); L->top.p++;",
        "_rec->metatable = hvalue(&_mod->uv[" .. type2metatable(ctx, types.Nominal(owner.name)) .. "].uv);",
        "memset(getudatamem(_rec), 0, " .. coder._nominal_size(plan) .. ");",
    }
    if variant then code[#code + 1] = coder._nominal_tag("_rec") .. " = " .. variant.index .. ";" end
    for index, field in ipairs(fields) do
        -- `titan_array_get` writes only the tag for a negative index, an
        -- out-of-range index, or an empty slot, and the field conversion may
        -- copy the value whole.
        code[#code + 1] = "{ TValue _source = {0}; titan_array_get(_fields, " .. index .. ", &_source);"
        code[#code + 1] = coder._reflection_store(ctx, node.loc, plan, field, "_rec", "&_source")
        code[#code + 1] = "}"
    end
    code[#code + 1] = "setuvalue(L, output, _rec); L->top.p = restorestack(L, _saved);"
    return table.concat(code, "\n")
end

function coder._reflection_metadata(ctx, sigs, code, node)
    local owner = node._type
    local tlcontext = ctx.tlcontext or ctx
    local projector = coder._nominal_function_prefix(owner.name, "projection")
    local constructor = coder._nominal_function_prefix(owner.name, "construction")
    coder._record_private_symbol(tlcontext, projector,
        "nominal reflection '" .. owner.name .. "' projection")
    coder._record_private_symbol(tlcontext, constructor,
        "nominal reflection '" .. owner.name .. "' construction")
    local cases, constructors = {}, {}
    if owner._tag == "Type.Record" then
        local plan = coder._nominal_plan(ctx, owner)
        local ordinal = 0
        for _, field in ipairs(owner.fields) do
            if not field.islocal then
                ordinal = ordinal + 1
                cases[#cases + 1] = "case " .. ordinal .. ": { "
                    .. coder._reflection_projection(ctx, plan, field, "_rec") .. " break; }"
            end
        end
        cases = { "switch (index) { " .. table.concat(cases, "\n")
            .. " default: luaL_error(L, \"projection field out of bounds\"); }" }
        constructors[1] = coder._reflection_constructor(ctx, node)
    else
        for _, variant in ipairs(owner.variants) do
            local plan = coder._nominal_plan(ctx, owner, variant)
            local parts = {}
            for index, field in ipairs(variant.parts) do
                parts[#parts + 1] = "case " .. index .. ": { "
                    .. coder._reflection_projection(ctx, plan, field, "_rec") .. " break; }"
            end
            cases[#cases + 1] = "case " .. variant.index .. ": switch (index) { "
                .. table.concat(parts, "\n")
                .. "default: luaL_error(L, \"projection part out of bounds\"); } break;"
            if not variant.islocal then
                constructors[#constructors + 1] = "case " .. variant.index .. ": { "
                    .. coder._reflection_constructor(ctx, node, variant) .. " return; }"
            end
        end
        cases = { "switch (" .. coder._nominal_tag("_rec") .. ") { "
            .. table.concat(cases, "\n")
            .. " default: luaL_error(L, \"invalid projected union tag\"); }" }
        constructors = { "switch (tag) { " .. table.concat(constructors, "\n")
            .. "default: luaL_error(L, \"cannot construct a private or invalid variant\"); }" }
    end
    sigs[#sigs + 1] = "TITAN_MODULE_PRIVATE void " .. projector
        .. "(lua_State *L, Udata *_rec, lua_Integer index, TValue *output);\n"
        .. "TITAN_MODULE_PRIVATE void " .. constructor
        .. "(lua_State *L, Udata *_mod, lua_Integer tag, TValue *input, TValue *output);"
    code[#code + 1] = "TITAN_MODULE_PRIVATE void " .. projector
        .. "(lua_State *L, Udata *_rec, lua_Integer index, TValue *output) {\n"
        .. "ptrdiff_t _saved = savestack(L, L->top.p); titan_ensure_stack(L, 2);\n"
        .. table.concat(cases, "\n") .. "\n*output = lua_totvalue(L, -1); L->top.p = restorestack(L, _saved);\n}"
    code[#code + 1] = "TITAN_MODULE_PRIVATE void " .. constructor
        .. "(lua_State *L, Udata *_mod, lua_Integer tag, TValue *input, TValue *output) {\n"
        .. "(void)tag; (void)_mod; (void)input; (void)output;\n"
        .. table.concat(constructors, "\n") .. "\n}"
    return projector, constructor
end

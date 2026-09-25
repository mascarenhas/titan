local core = require "titan-compiler.coder.core"
local _ENV = core

-- A direct constructor is a storage destination. Evaluate every argument at
-- its lexical position, retaining fixed-array snapshots and checked fresh
-- allocation counts until the one final userdata can be allocated.
function coder._codenominalcall(ctx, node)
    local constructor = assert(node._nominal_constructor)
    local plan = coder._nominal_plan(ctx, constructor.owner,
        constructor.variant or nil)
    assert(plan.complete, "direct constructor requires its complete layout")
    local stats, values, tails = {}, {}, {}
    local total = fresh_lowering_name(ctx, "_nominal_size_")
    stats[#stats + 1] = "size_t " .. total .. " = " .. coder._nominal_size(plan) .. ";"

    local function failure(loc, message)
        return "luaL_error(L, " .. c_string_literal("%s:%d:%d: " .. message)
            .. ", " .. c_string_literal(loc.filename) .. ", " .. loc.line
            .. ", " .. loc.col .. ");"
    end

    local function fresh(index, exp, allocation)
        -- Adjustment wrappers may preserve the checked allocation as their
        -- operand; find that exact plan rather than re-recognizing source.
        local call = exp
        while call and call._c_allocation_plan ~= allocation do call = call.exp end
        assert(call and call._tag == "Ast.ExpCall", "lost nominal allocation argument")
        local astats, names = coder._codeadjustedfixed(ctx, {
            _result_adjustment = assert(call._arg_adjustment),
            exps = call.args.args,
        }, coder._freeze_code)
        for _, code in ipairs(astats) do stats[#stats + 1] = code end
        if allocation.storage == "nominal_fixed" then
            values[index] = false -- zero directly in final owner
            return
        end
        assert(allocation.storage == "nominal_tail")
        local count = assert(names[1])
        local native = coder._render_c_type_name(allocation.payload_type)
        local offset = fresh_lowering_name(ctx, "_nominal_offset_")
        local bytes = fresh_lowering_name(ctx, "_nominal_bytes_")
        local overflow = failure(call.loc, "C nominal allocation size overflow")
        stats[#stats + 1] = "if (TITAN_UNLIKELY(" .. count .. " < 0)) { "
            .. failure(call.loc, "C allocation count cannot be negative") .. " }"
        stats[#stats + 1] = "if (TITAN_UNLIKELY((lua_Unsigned)" .. count
            .. " > (size_t)-1)) { " .. overflow .. " }"
        local prefix, element = "0", native
        if allocation.fam then
            local field = assert(allocation.fam_field)
            local array = types.resolve_c_typedef(field.type)
            prefix = "offsetof(" .. native .. ", " .. field.name .. ")"
            element = coder._render_c_type_name(array.elem)
        end
        stats[#stats + 1] = "if (TITAN_UNLIKELY((size_t)" .. count
            .. " > ((size_t)-1 - " .. prefix .. ") / sizeof(" .. element
            .. "))) { " .. overflow .. " }"
        stats[#stats + 1] = "size_t " .. bytes .. " = " .. prefix
            .. " + (size_t)" .. count .. " * sizeof(" .. element .. ");"
        if allocation.fam then
            stats[#stats + 1] = "if (" .. bytes .. " < sizeof(" .. native
                .. ")) " .. bytes .. " = sizeof(" .. native .. ");"
        else
            -- An empty view still has its own aligned address, distinct from
            -- another empty tail or a null borrowed pointer.
            stats[#stats + 1] = "if (" .. bytes .. " == 0) " .. bytes
                .. " = sizeof(" .. native .. ");"
        end
        local pad = fresh_lowering_name(ctx, "_nominal_pad_")
        stats[#stats + 1] = "typedef char " .. offset .. "_alignment[(_Alignof("
            .. native .. ") <= _Alignof(UValue)) ? 1 : -1];\n(void)sizeof("
            .. offset .. "_alignment);"
        stats[#stats + 1] = "size_t " .. pad .. " = ("
            .. "_Alignof(" .. native .. ") - " .. total .. " % _Alignof("
            .. native .. ")) % _Alignof(" .. native .. ");"
        stats[#stats + 1] = "if (TITAN_UNLIKELY(" .. total
            .. " > (size_t)-1 - " .. pad .. ")) { " .. overflow .. " }"
        stats[#stats + 1] = "size_t " .. offset .. " = " .. total .. " + " .. pad .. ";"
        stats[#stats + 1] = "if (TITAN_UNLIKELY(" .. offset
            .. " > (size_t)-1 - " .. bytes .. ")) { " .. overflow .. " }"
        stats[#stats + 1] = total .. " = " .. offset .. " + " .. bytes .. ";"
        stats[#stats + 1] = "if (TITAN_UNLIKELY(" .. total
            .. " > MAX_SIZE - udatamemoffset(" .. plan.nuv .. "))) { " .. overflow .. " }"
        tails[index] = { offset = offset, type = allocation.result_type }
    end

    local function evaluate(exp, index)
        local allocation = index and constructor.allocation_plans[index]
        if allocation then return fresh(index, exp, allocation) end
        local cstats, value = codeexp(ctx, exp)
        stats[#stats + 1] = cstats
        if not index then
            stats[#stats + 1] = "(void)(" .. value .. ");"
            return
        end
        local typ = assert(constructor.slots[index]).type
        local slot = assert(plan.by_index[constructor.field_indices[index]])
        if slot.kind == "array" then
            local snapshot = fresh_lowering_name(ctx, "_nominal_snapshot_")
            stats[#stats + 1] = "unsigned char " .. snapshot .. "[sizeof("
                .. cdeclarator.render_declaration(typ, "") .. ")];"
            stats[#stats + 1] = "memcpy(" .. snapshot .. ", " .. value
                .. ", sizeof(" .. snapshot .. "));"
            values[index] = snapshot
        else
            local frozen, name = materialize_code(ctx, exp._type, "", value)
            stats[#stats + 1] = frozen
            values[index] = name
        end
    end

    if node._named_arg_order then
        local seen = {}
        for _, index in ipairs(node._named_arg_order) do
            evaluate(node.args.args[index], index)
            seen[index] = true
        end
        for index, exp in ipairs(node.args.args) do
            if not seen[index] then
                assert(exp._named_omitted)
                evaluate(exp, index)
            end
        end
    else
        local adjusted = assert(node._arg_adjustment)
        assert(not adjusted.open_source and #adjusted.tail_scalars == 0)
        local fixed_index = {}
        for index, exp in ipairs(adjusted.fixed) do fixed_index[exp] = index end
        for _, exp in ipairs(adjusted.exps) do evaluate(exp, fixed_index[exp]) end
    end

    local nominal_type = types.Nominal(constructor.owner.name)
    local decl, object, root = newtmp(ctx, nominal_type, true)
    stats[#stats + 1] = decl
    stats[#stats + 1] = object .. " = luaS_newudata(L, " .. total .. ", " .. plan.nuv .. ");"
    stats[#stats + 1] = "setuvalue(L, " .. root .. ", " .. object .. ");"
    stats[#stats + 1] = object .. "->metatable = hvalue(&_mod->uv["
        .. type2metatable(ctx, nominal_type) .. "].uv);"
    -- Zero once after rooting. This initializes fresh fixed objects and every
    -- aligned tail without a temporary C buffer or separate owned userdata.
    stats[#stats + 1] = "memset(getudatamem(" .. object .. "), 0, " .. total .. ");"
    if constructor.variant then
        stats[#stats + 1] = coder._nominal_tag(object) .. " = " .. plan.tag .. ";"
    end
    for index, field in ipairs(constructor.slots) do
        local slot = assert(plan.by_index[field.index])
        local tail = tails[index]
        if tail then
            values[index] = "((" .. coder._render_c_type_name(tail.type)
                .. ")(getudatamem(" .. object .. ") + " .. tail.offset .. "))"
        end
        if values[index] ~= false then
            stats[#stats + 1] = coder._nominal_store(ctx, plan, slot,
                field.type, object, assert(values[index]))
        end
    end
    return table.concat(stats, "\n"), object
end

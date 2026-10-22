local core = require "titan-compiler.coder.core"
local _ENV = core

-- A direct literal call has a source function scope, but no separate physical
-- C activation. Keep its results outside the block and share the caller's
-- name/root allocator; only control targets and the input/output contracts
-- change while emitting its body.
-- Implementation notes: doc/implementation/immediate-functions.md#logical-functions-in-one-physical-frame
function codeimmediatecall(ctx, node)
    local lambda = assert(coder._immediate_function(node))
    local ftype = assert(node._callee_type)
    local stats, values = {}, {}
    local destination = {
        kind = "inline",
        fixed = {},
        projections = {},
        label = fresh_lowering_name(ctx, "_immediate_done_"),
        boundary_floor = #(ctx.protected_boundary_stack or {}),
    }
    local sources = node._result_sources or {}
    for i, typ in ipairs(node._visible_types or node._types) do
        local decl, name = newtmp(ctx, typ)
        table.insert(stats, decl)
        local save = { typ = typ, cvar = name,
            slot = types.is_gc(typ) and reserveslot(ctx) or nil }
        if save.slot then
            table.insert(stats, "setnilvalue(" .. slotat(save.slot) .. ");")
        end
        values[i] = save
        local source = sources[i] or { kind = "fixed", index = i }
        if source.kind == "fixed" then
            destination.fixed[source.index] = save
        else
            destination.projections[source.index] = save
        end
    end
    -- Missing fixed destinations still evaluate the declared return conversion
    -- for effect. The callable result list owns their positions, so nil slots
    -- need no list-length sentinel here.
    local flexrun, flexwant
    if ftype.flexrettype then
        local open = node._coder_open_want ~= nil
            or node._flex_result_demand == "open"
        local count = fresh_lowering_name(ctx, "_immediate_count_")
        table.insert(stats, "int volatile " .. count .. " = 0;")
        table.insert(stats, "(void)" .. count .. ";")
        if open then
            local args = {}
            flexrun = coder._flex_call_buffer(ctx, node, ftype, stats, args)
            destination.flex = {
                elem = ftype.flexrettype, args = flexrun.args,
                count = count, root_depth = flexrun.root_depth,
                capacity = flexrun.capacity, ownership = "inline",
            }
            -- Return evaluation roots the complete run, including any finite
            -- projections. Consumers receive only its open suffix, whose root
            -- range must start beside args[run.start] so ordinary run cleanup
            -- clears exactly the values it consumed.
            if flexrun.root_depth then
                flexrun.root_depth = flexrun.root_depth + flexrun.prefix
            end
            flexwant = args[2]
            destination.run = flexrun
            node._coder_result_run = flexrun
        else
            flexwant = tostring(node._flex_result_demand or 0)
            destination.flex = {
                elem = ftype.flexrettype, count = count,
                slots = destination.projections,
                capacity = node._flex_result_demand or 0,
                ownership = "inline",
            }
        end
    end

    -- Result roots survive the inline scope. Argument and body roots may be
    -- reused after the call, but must remain live throughout its cleanup.
    -- Measure this scope's peak separately from earlier caller expressions so
    -- its continuation releases only the range used by this logical call.
    local root_base, caller_nslots = ctx.depth, ctx.nslots
    ctx.nslots = root_base
    pushd(ctx)
    push_spillscope(ctx)
    local body, arguments, varargs = {}, {}, nil
    local adjusted = assert(node._arg_adjustment)
    if ftype.varargtype and adjusted.open_source then
        local astats, fixed, tails, run = coder._codeadjustedopen(
            ctx, adjusted, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(body, stat) end
        arguments = fixed
        local pair = {}
        coder._emit_open_vararg_struct(
            ctx, node, ftype, tails, run, body, pair)
        varargs = { cname = "(" .. pair[1] .. ")",
            start = pair[2], elem = ftype.varargtype }
    elseif ftype.varargtype then
        -- A statically sized input tail has already been checked and adjusted.
        -- Stabilize every written value before binding any lambda parameter.
        local fixed_index, tail_index = {}, {}
        for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
        for i, exp in ipairs(adjusted.tail_scalars) do tail_index[exp] = i end
        local tails = {}
        for _, exp in ipairs(adjusted.exps) do
            local cs, ce = codeexp(ctx, exp)
            local fi, ti = fixed_index[exp], tail_index[exp]
            if fi or ti then
                local ms, name = materialize_code(ctx, exp._type, cs, ce)
                table.insert(body, ms)
                if fi then arguments[fi] = name else tails[ti] = name end
            else
                table.insert(body, cs .. "\n(void)(" .. ce .. ");")
            end
        end
        local pair = {}
        emit_vararg_struct(ctx, node, ftype, tails, false,
            #adjusted.fixed + #tails, pair, body)
        varargs = { cname = "(" .. pair[1] .. ")",
            start = pair[2], elem = ftype.varargtype }
    else
        local astats, fixed = coder._codeadjustedfixed(ctx, {
            _result_adjustment = adjusted, exps = node.args.args,
        })
        for _, stat in ipairs(astats) do table.insert(body, stat) end
        arguments = fixed
    end

    -- Freeze inherited demand before entering the new logical function scope.
    if flexwant then
        local want = fresh_lowering_name(ctx, "_immediate_want_")
        table.insert(body, "const int " .. want .. " = " .. flexwant .. ";")
        table.insert(body, "(void)" .. want .. ";")
        flexwant = want
    end
    local fields = { "rettypes", "flexrettype", "flexwant", "varargs",
        "inline_return", "finally_stack", "loopstack", "entry_try",
        "catch_error_decl", "catch_traceback_decl" }
    local saved = {}
    for _, field in ipairs(fields) do saved[field] = ctx[field] end
    ctx.rettypes, ctx.flexrettype = ftype.rettypes, ftype.flexrettype
    ctx.flexwant, ctx.varargs = flexwant, varargs
    ctx.inline_return = destination
    ctx.finally_stack, ctx.loopstack = {}, {}
    ctx.entry_try, ctx.catch_error_decl, ctx.catch_traceback_decl = nil, nil, nil
    for i, param in ipairs(fixed_params(lambda.params)) do
        table.insert(body, coder._codeinitializeddecl(
            ctx, param, "", assert(arguments[i])))
    end
    table.insert(body, emitline(lambda) .. codestat(ctx, lambda.block))
    -- Legal fallthrough is the ordinary empty/nil return. Initialize its
    -- flexible count/projections too: the expression may execute in a loop.
    table.insert(body, coder._reset_pending_flex(destination.flex))
    table.insert(body, coder._finish_immediate_return(ctx))
    table.insert(body, destination.label .. ": ;")
    if ctx.nslots > root_base then
        table.insert(body, render([[
            for (int _immediate_root = $BASE; _immediate_root < $END;
                    _immediate_root++) {
                setnilvalue2s(restorestack(L, _base_off) + _immediate_root);
            }
        ]], { BASE = c_integer_literal(root_base),
            END = c_integer_literal(ctx.nslots) }))
    end
    ctx.nslots = math.max(caller_nslots, ctx.nslots)
    for _, field in ipairs(fields) do ctx[field] = saved[field] end
    pop_spillscope(ctx)
    popd(ctx)
    table.insert(stats, "{\n" .. table.concat(body, "\n") .. "\n}")
    node._extras = {}
    for i = 2, #values do
        node._extras[i] = coder._saved_fixed_value(values[i])
    end
    return table.concat(stats, "\n"), values[1]
        and coder._saved_fixed_value(values[1]) or "((void)0)"
end

-- Store a flexible element directly into finite option projections when no
-- open run is needed. The declared element adjustment has already happened;
-- this is the same present/absent representation used by ordinary calls.
function coder._store_flex_result(flex, index, value)
    if not flex.slots then
        return flex.args .. "[" .. index .. "] = " .. value .. ";\n"
            .. coder._flex_root(flex, index)
    end
    local cases = {}
    for i, save in ipairs(flex.slots) do
        local write = coder._optional_result_store(save.typ, flex.elem, save.cvar, value)
        if save.slot then
            write = write .. "\n"
                .. setslot(save.typ, slotat(save.slot), save.cvar)
        end
        table.insert(cases, "case " .. (i - 1) .. ": " .. write .. " break;")
    end
    return "switch (" .. index .. ") {\n"
        .. table.concat(cases, "\n") .. "\n}"
end

-- Complete a local return after its own cleanup, retaining the caller's
-- active protected regions and Lua-stack frame. Observable consumer casts
-- are still emitted by their original caller expression after this point.
function coder._finish_immediate_return(ctx, pending)
    local destination = assert(ctx.inline_return)
    local lines = {}
    if pending then
        for i in ipairs(pending.fixed) do
            local save = destination.fixed[i]
            if save then
                table.insert(lines, save.cvar .. " = "
                    .. coder._saved_fixed_value(pending.fixed[i]) .. ";")
                if save.slot then
                    table.insert(lines, setslot(save.typ,
                        slotat(save.slot), save.cvar))
                end
            end
        end
        if pending.flex then
            table.insert(lines, coder._reset_pending_flex(destination.flex))
            local index = fresh_lowering_name(ctx, "_immediate_copy_")
            table.insert(lines, "for (int " .. index .. " = 0; " .. index
                .. " < " .. pending.flex.count .. "; " .. index .. "++) {\n"
                .. coder._store_flex_result(destination.flex, index,
                    pending.flex.args .. "[" .. index .. "]") .. "\n}")
            table.insert(lines, destination.flex.count .. " = "
                .. pending.flex.count .. ";")
        end
    end
    if destination.run then
        local flex = destination.flex
        for i, save in ipairs(destination.projections) do
            table.insert(lines, "if (" .. flex.count .. " >= " .. i .. ") {\n"
                .. coder._optional_result_store(save.typ, flex.elem, save.cvar,
                    flex.args .. "[" .. (i - 1) .. "]")
                .. "\n} else { " .. coder._option_nil(save.typ, save.cvar) .. " }")
            if save.slot then
                table.insert(lines, setslot(save.typ, slotat(save.slot), save.cvar))
            end
        end
        if flex.root_depth and destination.run.prefix > 0 then
            -- Finite projections now own their separate result roots. Release
            -- the prefix of the complete return range; its suffix remains live
            -- under the published run until the caller consumes it.
            table.insert(lines, render([[
                for (int _immediate_prefix_i = 0;
                     _immediate_prefix_i < $PREFIX
                         && _immediate_prefix_i < $COUNT;
                     _immediate_prefix_i++) {
                    setnilvalue2s($ROOT + _immediate_prefix_i);
                }
            ]], {
                PREFIX = c_integer_literal(destination.run.prefix),
                COUNT = flex.count,
                ROOT = stackslotat(flex.root_depth),
            }))
        end
        table.insert(lines, destination.run.desc .. ".n_args = (lu_byte)"
            .. flex.count .. ";")
    end
    table.insert(lines, restore_boundaries_to(ctx, destination.boundary_floor))
    table.insert(lines, "goto " .. destination.label .. ";")
    return table.concat(lines, "\n")
end

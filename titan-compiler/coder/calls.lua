local core = require "titan-compiler.coder.core"
local _ENV = core

-- Generate native call arguments in source order. A pure trailing suffix may
-- remain as direct C expressions: with no intervening statements, reordering
-- those reads is unobservable. Every argument at or before effectful setup is
-- frozen in a C temporary at its source position. Native arguments never gain
-- tracing-only Lua-stack copies; this helper preserves evaluation order only.
function expression_contains_call(node)
    local tag = node._tag
    if tag == "Ast.ExpCall" then
        return true
    elseif tag == "Ast.ExpSpread" then
        -- Only the carrier evaluates these expressions. ExpSpreadIndex is a
        -- reference to already-prepared state and therefore contains no call of
        -- its own.
        return expression_contains_call(node.exp)
            or (node.first and expression_contains_call(node.first))
            or (node.last and expression_contains_call(node.last))
    elseif tag == "Ast.ExpCast" or tag == "Ast.ExpIs"
        or tag == "Ast.ExpUnop"
        or tag == "Ast.ExpAdjust" then
        return expression_contains_call(node.exp)
    elseif tag == "Ast.ExpBinop" then
        return expression_contains_call(node.lhs)
            or expression_contains_call(node.rhs)
    end
    return false
end

function ordered_call_args(ctx, args, n)
    local coded = {}
    for i = 1, n do
        local stats, exp = codeexp(ctx, args[i])
        coded[i] = {
            stats = stats,
            exp = exp,
            typ = args[i]._type,
            contains_call = expression_contains_call(args[i]),
        }
    end

    local freeze = {}
    local later_has_stats = false
    for i = n, 1, -1 do
        -- Calls are effectful even when their generated setup is empty.
        local has_stats = coded[i].stats ~= "" or coded[i].contains_call
        freeze[i] = has_stats or later_has_stats
        later_has_stats = later_has_stats or has_stats
    end

    local stats, exps = {}, {}
    for i = 1, n do
        local c = coded[i]
        if freeze[i] then
            local cstats, cexp =
                coder._freeze_code(ctx, c.typ, c.stats, c.exp)
            stats[i], exps[i] = cstats, cexp
        else
            stats[i], exps[i] = c.stats, c.exp
        end
    end
    return stats, exps
end

-- A checked named call carries a dense formal-order argument list plus the
-- formal indexes of explicitly written expressions in lexical order. Freeze
-- each explicit expression immediately in that lexical order, then generate
-- the synthetic nil omissions. The returned expressions remain indexed by
-- formal position for the unchanged native ABI.
function named_ordered_call_args(ctx, args, order)
    local stats = {}
    local exps = {}
    local seen = {}
    for _, index in ipairs(order) do
        assert(index >= 1 and index <= #args)
        assert(not seen[index], "duplicate formal index in named call order")
        assert(not args[index]._named_omitted)
        seen[index] = true
        local cstats, cexp = codeexp(ctx, args[index])
        local mstats, mexp = coder._freeze_code(ctx, args[index]._type,
            cstats, cexp)
        table.insert(stats, mstats)
        exps[index] = mexp
    end
    for index, arg in ipairs(args) do
        if not seen[index] then
            assert(arg._named_omitted,
                "named call order omitted an explicit argument")
            local cstats, cexp = codeexp(ctx, arg)
            local mstats, mexp = coder._freeze_code(ctx, arg._type,
                cstats, cexp)
            table.insert(stats, mstats)
            exps[index] = mexp
        end
    end
    return stats, exps
end

function newforeigntmp(ctx --[[:table]], typ --[[:table]],
                       initializer --[[:string?]])
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local fdecl
    local finit = ""
    local rtyp = types.resolve_c_typedef(typ)
    if typ._tag == "Type.String" then
        fdecl = "char* " .. tmpname
        finit = " = NULL"
    elseif types.is_direct_c(typ) then
        fdecl = coder._render_c_declaration(coder._c_value_type(
            cdeclarator.adjust_parameter_type(typ)), tmpname)
        if typ._tag == "Type.COwned"
            or rtyp._tag == "Type.CPointer" then
            finit = " = NULL"
        elseif rtyp._tag == "Type.CInteger" or rtyp._tag == "Type.CFloat" then
            finit = " = 0"
        elseif types.is_c_tvalue(typ) then
            finit = " = { {0}, 0 }"
        end
    else
        error("don't know how to convert foreign type " .. types.tostring(typ))
    end
    if initializer then
        finit = " = " .. initializer
    end
    return render([[
        $DECL$INIT;
    ]], {
        DECL = fdecl,
        INIT = finit,
    }), tmpname
end

function makestring(ctx, cexp, target, length)
    local cstr
    if length then
        cstr = render("luaS_newlstr(L, $VALUE, $LENGTH)", {
            VALUE = cexp,
            LENGTH = length,
        })
    else
        cstr = render("luaS_new(L, $VALUE)", {
            VALUE = cexp,
        })
    end
    if target then
        return "", cstr
    else
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
        return render([[
            $CTMP
            $TMPNAME = $CSTR;
            setsvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            CTMP = ctmp,
            TMPNAME = tmpname,
            CSTR = cstr,
            TMPSLOT = tmpslot,
        }), tmpname
    end
end

function is_addressable_local(exp)
    if exp._tag ~= "Ast.ExpVar" or exp.var._tag ~= "Ast.VarName" then
        return false
    end
    local decl = exp.var._decl
    return decl and decl._tag == "Ast.Decl" and not decl._boxed
end

function materialize_address_tmp(ctx, exp, cexp)
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local tmpname = "_tmp_" .. tmp
    local slot = types.is_gc(exp._type) and newslot(ctx) or nil
    return render([[
        $CDECL;
        $TMPNAME = $CEXP;
        $ANCHOR
    ]], {
        CDECL = cvardecl(ctx, exp._type, tmpname),
        TMPNAME = tmpname,
        CEXP = cexp,
        ANCHOR = slot and setslot(exp._type, slot, tmpname) or "",
    }), render("(&$TMPNAME)", { TMPNAME = tmpname })
end

function mutable_out_anchor(ctx, exp, target)
    local source = exp
    local direct_address_source = false
    local mutable_authority = false
    while source._tag == "Ast.ExpCast" and source.exp do
        local operand = source.exp
        local conversion = source._c_conversion
        if conversion and conversion.kind ==
            "address_then_unsafe_object_pointer" then
            direct_address_source = operand
            mutable_authority = true
        elseif is_addressable_local(operand)
            and source._adjustment
            and source._adjustment.kind == "direct_coercion"
            and source._adjustment.coercion
            and source._adjustment.coercion.op == "mutable_c_address" then
            -- Preserve the local root across an exact-address inner cast and
            -- an unrelated-pointer outer cast.
            direct_address_source = operand
            mutable_authority = true
        elseif is_addressable_local(operand)
            and (source._written_cast and source._written_cast.tag == "just") then
            local written = coder._checked_written_cast_plan(
                maybe3.get_checked(source._written_cast, "written cast"), operand._type, source._type,
                "mutable C out-argument cast")
            local coercion = written.op == "coercion"
                and written.coercion or nil
            if coercion and coercion.op == "mutable_c_address" then
                direct_address_source = operand
                mutable_authority = true
            end
        end
        source = operand
    end

    source = direct_address_source or exp
    if not mutable_authority
        or not is_addressable_local(source)
        or not types.is_gc(source._type) then
        return nil
    end
    local decl = source.var._decl
    if not decl._slot then
        decl._slot = newslot(ctx)
    end
    return setslot(source._type, decl._slot, decl._cvar)
end

function nativetoforeignexp(ctx, exp, cexp, target, projection)
    local stype = coder._resolve_cast_type(exp._type)
    local ttype = target and coder._resolve_cast_type(target) or nil
    local coercion
    local conversion
    local has_projection_authority = false
    if projection and target then
        if projection._adjustment then
            coder._checked_adjustment_plan(
                projection._adjustment, exp._type, target,
                "native-to-foreign adjustment")
            has_projection_authority = true
            if projection._adjustment.kind == "direct_coercion" then
                coercion = projection._adjustment.coercion
            end
        elseif (projection._written_cast and projection._written_cast.tag == "just") then
            coder._checked_written_cast_plan(
                maybe3.get_checked(projection._written_cast, "written cast"), exp._type, target,
                "written native-to-foreign cast")
            has_projection_authority = true
            if maybe3.get_checked(projection._written_cast, "written cast").op == "coercion" then
                coercion = maybe3.get_checked(projection._written_cast, "written cast").coercion
            elseif maybe3.get_checked(projection._written_cast, "written cast").op == "explicit" then
                conversion = maybe3.get_checked(projection._written_cast, "written cast").conversion
            end
        elseif projection._c_conversion then
            conversion = coder._checked_explicit_conversion_plan(
                projection._c_conversion, exp._type, target,
                "checked native-to-foreign C conversion")
            has_projection_authority = true
        end
    end
    local operation = coercion and coercion.op
        or conversion and (conversion.op or conversion.kind)

    if operation == "c_enum_integer" then
        coder._checked_coercion_plan(
            coercion, exp._type, target,
            "native-to-C enum/integer coercion")
        return "", foreigncast(cexp, target)
    end

    if projection and target
        and coder._is_numeric_type(exp._type)
        and coder._is_numeric_type(target)
        and not types.equals(stype, ttype) then
        local mode = "boundary"
        if coercion then
            coder._checked_numeric_coercion(
                coercion,
                exp._type, target, "native-to-C numeric coercion")
        elseif conversion then
            coder._checked_explicit_numeric_conversion(
                conversion,
                exp._type, target, "written C numeric conversion")
            mode = "explicit_c"
        else
            error("native-to-C numeric conversion lacks checker authority")
        end
        return coder._code_checked_numeric_cast(
            ctx, exp._type, target, cexp, projection.loc, mode)
    end

    if operation == "mutable_c_address" then
        assert(is_addressable_local(exp),
            "mutable C-address plan has a non-addressable source")
        local address = render("(&($CEXP))", { CEXP = cexp })
        if coder._decl_volatile_home(coder._lvalue_root_decl(exp)) then
            address = foreigncast(address, target)
        end
        return "", address
    end

    if operation == "c_address" then
        if is_addressable_local(exp) then
            local address = render("(&($CEXP))", { CEXP = cexp })
            if coder._decl_volatile_home(coder._lvalue_root_decl(exp)) then
                address = foreigncast(address, target)
            end
            return "", address
        end
        return materialize_address_tmp(ctx, exp, cexp)
    end

    if operation == "c_automatic_to_owned"
        or operation == "c_automatic_array_to_owned" then
        local source_stats = ""
        local source_address
        local bytes
        local count = nil
        local fam_plan
        if is_addressable_local(exp) then
            local allocation_plan = exp.var._decl._c_allocation_plan
            if allocation_plan
                and allocation_plan.storage == "automatic_fam" then
                fam_plan = allocation_plan
                local storage = assert(exp.var._decl._c_fam_storage)
                source_address = storage.address
                bytes = storage.bytes
                count = fam_plan.fam_count_literal
            end
        end
        if not source_address then
            if stype._tag == "Type.CArray" then
                source_address = cexp
                bytes = "sizeof(" .. cexp .. ")"
                count = stype.len
            else
                local source_decl, source_name =
                    newforeigntmp(ctx, exp._type, cexp)
                source_stats = source_decl
                source_address = "&" .. source_name
                bytes = "sizeof(" .. source_name .. ")"
            end
        end
        local owner_decl, owner, owner_slot = newtmp(ctx, target, true)
        local metadata = ""
        local nuvalues = 0
        if fam_plan then
            nuvalues = 1
            metadata = "setivalue(&" .. owner
                .. "->uv[0].uv, " .. c_integer_literal(count) .. ");"
        end
        return render([[
            $SOURCESTATS
            $OWNERDECL
            $OWNER = luaS_newudata(L, $BYTES, $NUVALUES);
            $OWNER->metatable = hvalue(&_mod->uv[$META].uv);
            $METADATA
            setuvalue(L, $OWNERSLOT, $OWNER);
            memcpy(getudatamem($OWNER), $SOURCE, $BYTES);
        ]], {
            SOURCESTATS = source_stats,
            OWNERDECL = owner_decl,
            OWNER = owner,
            BYTES = bytes,
            NUVALUES = c_integer_literal(nuvalues),
            META = c_integer_literal(owned_c_metatable(ctx, target)),
            METADATA = metadata,
            OWNERSLOT = owner_slot,
            SOURCE = source_address,
        }), owner
    end

    if operation == "c_function_pointer_to_void"
        or operation == "c_void_to_function_pointer" then
        return "", render("titan_cast_func($TARGET, $SOURCE)", {
            TARGET = coder._render_c_type_name(target),
            SOURCE = cexp,
        })
    end

    if operation == "gc_identity_to_void_pointer" then
        -- Freeze and anchor the native representation before any later call
        -- argument can collect it. Array/Map/record expressions already
        -- evaluate to their Table*/Udata* identity.
        local rootstats, source =
            materialize_code(ctx, exp._type, "", cexp)
        if stype._tag ~= "Type.Function" then
            return rootstats, source
        end

        -- Function values are boxed and may be immediate because callability
        -- is deliberately checked only when they are called.
        local cpointer, pointer = newtmp(ctx, target)
        return render([[
            $ROOTSTATS
            $CPOINTER
            if (TITAN_UNLIKELY(!iscollectable(&$SOURCE))) {
                $THROW
            }
            $POINTER = $CAST;
        ]], {
            ROOTSTATS = rootstats,
            CPOINTER = cpointer,
            SOURCE = source,
            POINTER = pointer,
            CAST = foreigncast(
                render("gcvalue(&$SOURCE)", { SOURCE = source }),
                target),
            FILE = c_string_literal(exp.loc.filename),
            LINE = c_integer_literal(exp.loc.line),
            COL = c_integer_literal(exp.loc.col),
            THROW = codethrow(
                exp.loc,
                "%s:%d:%d: type error, function value has no GC identity",
                { "$FILE", "$LINE", "$COL" }),
        }), pointer
    end

    if target and not types.equals(stype, ttype)
        and not has_projection_authority then
        error("native-to-foreign conversion lacks checker authority: "
            .. types.tostring(exp._type) .. " -> "
            .. types.tostring(target))
    end

    if target and types.is_c_tvalue(target) then
        if stype._tag == "Type.Value" or types.is_c_tvalue(exp._type) then
            return "", cexp
        end
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
        return render([[
            $CTMP
            $SETTMP
            $ANCHOR
        ]], {
            CTMP = ctmp,
            SETTMP = setboxed(ctx, exp._type, "&" .. tmpname, cexp),
            ANCHOR = setslot(types.Value(), tmpslot, tmpname),
        }), tmpname
    end

    if stype._tag == "Type.Value"
        and (not ttype or ttype._tag == "Type.Value") then
        return "", cexp
    end

    if stype._tag == "Type.COwned"
        and (not ttype or ttype._tag == "Type.CPointer") then
        return "", render("getudatamem($EXP)", { EXP = cexp })
    end

    if types.is_direct_c(exp._type) then
        return "", cexp
    end

    if exp._type._tag == "Type.Integer"
        or exp._type._tag == "Type.Float"
        or exp._type._tag == "Type.Boolean" then
        return "", cexp
    end

    if exp._type._tag == "Type.Nil" then
        return "", "NULL"
    end

    if exp._type._tag == "Type.String" then
        if target and not (ttype and ttype._tag == "Type.CPointer") then
            return "", cexp
        end
        local texp, tmp = newforeigntmp(ctx, exp._type)
        local cvtexp = render([[getstr($CEXP)]], { CEXP = cexp })
        return render([[
            $TEXP
            $TMP = $CVTEXP;
        ]], {
            TEXP = texp,
            TMP = tmp,
            CVTEXP = cvtexp,
        }), tmp
    end

    if exp._type._tag == "Type.Value" and target then
        assert(projection and projection._tag == "Ast.ExpCast",
            "boxed value to foreign target lacks its checker cast node")
        local texp, tmp = newforeigntmp(ctx, target)
        return render([[
            $TEXP
            $CHECKANDGET
        ]], {
            TEXP = texp,
            CHECKANDGET = coder._planned_value_projection_get(
                ctx, projection, tmp, "&" .. cexp),
        }), tmp
    end

    error("don't know how to handle type " .. types.tostring(exp._type))
end

function foreigntonativeexp(ctx, exp, cexp, target)
    local etype = types.resolve_c_typedef(exp._type)

    if etype._tag == "Type.Value" then
        return "", cexp
    elseif etype._tag == "Type.CInteger" then
        -- Keep the declaration's exact C carrier. A later explicit/implicit
        -- crossing to Titan integer, or boxing into a TValue slot, performs the
        -- checked range conversion. Prematurely narrowing here would lose the
        -- very value that the boundary must validate.
        return "", cexp
    elseif etype._tag == "Type.CFloat" then
        return "", cexp
    elseif etype._tag == "Type.CPointer" then
        return "", cexp
    elseif etype._tag == "Type.CFunction" then
        return "", cexp
    elseif etype._tag == "Type.CArray" then
        return "", cexp
    elseif etype._tag == "Type.CStruct" or etype._tag == "Type.CUnion" then
        return "", cexp
    end

    if exp._type._tag == "Type.Integer"
        or exp._type._tag == "Type.Float"
        or exp._type._tag == "Type.Boolean" then
        return "", cexp
    end

    if exp._type._tag == "Type.Nil" then
        return "", "0"
    end

    if exp._type._tag == "Type.String" then
        -- A C function may return NULL (e.g. getenv of an unset variable); a
        -- Titan `string` has no nil representation, so raise a clean run-time
        -- error instead of letting luaS_new dereference NULL.
        local texp, tmp = newforeigntmp(ctx, exp._type)
        local guard = render([[
            $TEXP
            $TMP = $CEXP;
            if ($TMP == NULL) {
                luaL_error(L, "foreign function returned a NULL string");
            }
        ]], { TEXP = texp, TMP = tmp, CEXP = cexp })
        local mkstats, mkexp = makestring(ctx, tmp, target)
        return guard .. "\n" .. mkstats, mkexp
    end

    error("don't know how to handle type " .. types.tostring(exp._type))
end

function finish_foreign_call(ctx, ret, prestats, ccall, poststats)
    -- Foreign code can re-enter Lua or otherwise grow and relocate its stack.
    -- Materialize the result before recovering `_base`, then perform any
    -- post-call slot work only through the recovered pointer.
    ctx.uses_base_off = true
    local ret_res = types.resolve_c_typedef(ret)
    local post = table.concat(poststats, "\n")
    if ret_res._tag == "Type.CVoid" then
        return render([[
            $PRESTATS
            $CCALL;
            _base = restorestack(L, _base_off);
            $POST
        ]], {
            PRESTATS = prestats,
            CCALL = ccall,
            POST = post,
        }), "((void)0)"
    end

    local fdecl, fname = newforeigntmp(ctx, ret, ccall)
    return render([[
        $PRESTATS
        $FDECL
        _base = restorestack(L, _base_off);
        $POST
    ]], {
        PRESTATS = prestats,
        FDECL = fdecl,
        POST = post,
    }), fname
end

function coder._append_c_mutation_spills(node, poststats)
    for _, decl in ipairs(node._c_mutated_decls or {}) do
        local update = spill_update(decl)
        if update ~= "" then table.insert(poststats, update) end
    end
end

-- Lower one finite positional strict-C argument list in lexical order, but
-- publish only the checker-selected fixed projections to the ABI. A spread
-- carrier is setup/effect-only and therefore cannot occupy a C formal slot.
-- C-vararg calls retain their separate explicit-scalar path and never reach
-- this helper.
local function code_adjusted_foreign_args(
    ctx, node, cfunc, castats, caexps, poststats)
    local adjusted = assert(node._arg_adjustment)
    assert(not cfunc.vararg and not adjusted.open_source
        and #adjusted.tail_scalars == 0)
    local fixed_index, discard_set = {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local anames = {}
    for _, exp in ipairs(adjusted.exps) do
        local i = fixed_index[exp]
        if i then
            local target = assert(cfunc.params[i])
            local cstat, cexp = codeforeignexp(ctx, exp, target)
            local cdecl, cname = newforeigntmp(ctx, target)
            table.insert(castats, cstat)
            table.insert(castats, cdecl)
            table.insert(castats, cname .. " = " .. cexp .. ";")
            anames[i] = cname
        else
            assert(discard_set[exp] or exp._discard_results,
                "adjusted C argument is neither fixed nor effect-only")
            local cstat, cexp = codeexp(ctx, exp)
            table.insert(castats, cstat)
            table.insert(castats, "(void)(" .. cexp .. ");")
        end
    end
    for i, target in ipairs(cfunc.params) do
        local arg = assert(adjusted.fixed[i])
        table.insert(caexps, assert(anames[i]))
        local anchor = mutable_out_anchor(ctx, arg, target)
        if anchor then table.insert(poststats, anchor) end
    end
end

-- Ordinary strict-C calls already have a one-to-one checker-selected ABI list
-- and retain their established inline foreign lowering. The stabilized path
-- above is needed only when a lexical carrier/effect entry is distinct from
-- the fixed projections actually passed to C (notably an Array/Map spread).
local function needs_adjusted_foreign_args(node, cfunc)
    local adjusted = node._arg_adjustment
    if not adjusted or cfunc.vararg then return false end
    if #adjusted.exps ~= #cfunc.params then return true end
    for i = 1, #cfunc.params do
        if adjusted.exps[i] ~= adjusted.fixed[i] then return true end
    end
    return false
end

function codeforeigncall(ctx, node)
    local cfuncname = coder._foreign_reference_name(
        assert(node._direct_foreign_reference,
            "direct foreign call lacks its checker reference"), ctx)
    local ftype = node.exp._type
    assert(ftype._tag == "Type.CFunction",
        "direct foreign call lost its C function declaration")
    local ret = ftype.ret
    local caexps = {}
    local castats = {}
    local poststats = {}
    if node._named_arg_order then
        assert(node._named_call_kind == "foreign")
        assert(not ftype.vararg)
        assert(#node.args.args == #ftype.params)
        local actuals = {}
        local seen = {}
        local postbyindex = {}
        local function freeze(index)
            assert(index >= 1 and index <= #ftype.params)
            assert(not seen[index], "duplicate formal index in named FFI call")
            seen[index] = true
            local arg = node.args.args[index]
            local target = ftype.params[index]
            local cstat, cexp = codeforeignexp(ctx, arg, target)
            local cdecl, cname = newforeigntmp(ctx, target)
            table.insert(castats, cstat)
            table.insert(castats, cdecl)
            table.insert(castats, cname .. " = " .. cexp .. ";")
            actuals[index] = cname
            postbyindex[index] = mutable_out_anchor(ctx, arg, target)
        end
        for _, index in ipairs(node._named_arg_order) do
            assert(not node.args.args[index]._named_omitted)
            freeze(index)
        end
        for index, arg in ipairs(node.args.args) do
            if not seen[index] then
                assert(arg._named_omitted,
                    "named FFI order omitted an explicit argument")
                freeze(index)
            end
        end
        for index = 1, #ftype.params do
            caexps[index] = assert(actuals[index])
            if postbyindex[index] then
                table.insert(poststats, postbyindex[index])
            end
        end
    elseif needs_adjusted_foreign_args(node, ftype) then
        code_adjusted_foreign_args(
            ctx, node, ftype, castats, caexps, poststats)
    else
        for i, arg in ipairs(node.args.args) do
            local cstat, cexp = codeforeignexp(ctx, arg, ftype.params[i])
            table.insert(castats, cstat)
            table.insert(caexps, cexp)
            local anchor = mutable_out_anchor(ctx, arg, ftype.params[i])
            if anchor then
                table.insert(poststats, anchor)
            end
        end
    end
    -- A direct mutable-address argument may have changed the complete local
    -- object representation. Commit only after the C call returns normally;
    -- a C-side nonlocal exit must retain the last pre-call spill.
    coder._append_c_mutation_spills(node, poststats)
    local cstats = table.concat(castats, "\n")
    local ccall = render("$NAME($CAEXPS)", {
        NAME = cfuncname,
        CAEXPS = table.concat(caexps, ", "),
    })
    return finish_foreign_call(ctx, ret, cstats, ccall, poststats)
end

function codecfunctionptrcall(ctx, node)
    assert(not node._named_arg_order)
    local cfunc = node._c_pointer_call
    local fstats, fexp = codeexp(ctx, node.exp)
    local fdecl, fname = newforeigntmp(ctx, node.exp._type)
    local castats = {
        fstats,
        fdecl,
        render([[
            $FNAME = $FEXP;
            if (TITAN_UNLIKELY($FNAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot call a NULL C function pointer", $FILE, $LINE, $COL);
            }
        ]], {
            FNAME = fname,
            FEXP = fexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true),
    }
    local caexps = {}
    local poststats = {}
    if needs_adjusted_foreign_args(node, cfunc) then
        code_adjusted_foreign_args(
            ctx, node, cfunc, castats, caexps, poststats)
    else
        for i, arg in ipairs(node.args.args) do
            local cstat, cexp = codeforeignexp(ctx, arg, cfunc.params[i])
            table.insert(castats, cstat)
            table.insert(caexps, cexp)
            local anchor = mutable_out_anchor(ctx, arg, cfunc.params[i])
            if anchor then
                table.insert(poststats, anchor)
            end
        end
    end
    coder._append_c_mutation_spills(node, poststats)
    local cstats = table.concat(castats, "\n")
    local ccall = render("$FNAME($ARGS)", {
        FNAME = fname,
        ARGS = table.concat(caexps, ", "),
    })
    return finish_foreign_call(ctx, cfunc.ret, cstats, ccall, poststats)
end

function codeforeignvar(_, node)
    return "", node.name
end

-- Is the callee of this ExpCall a statically-known function symbol (a top-level
-- function, a record function, an imported module function, or a foreign call)?
-- If so, codecall emits a direct native call. Otherwise the callee is a
-- first-class function *value* and codevaluecall handles it.
function is_static_callee(node)
    if node.args._tag ~= "Ast.ArgsFunc" then return true end
    if node.exp._tag ~= "Ast.ExpVar" then return false end
    local var = node.exp.var
    if node._direct_foreign_reference then
        return true -- foreign call, handled by codeforeigncall
    end
    local decl = var._decl
    return decl ~= nil and (decl._tag == "Ast.TopLevelFunc"
        or decl._tag == "Type.ModuleMember"
        or decl._tag == "Type.StaticMethod")
end

-- Build and append the backing-struct argument (`_varargs` + `_start`) for a
-- native call that passes a static argument list to a variadic callee.
-- Appends the two C expressions to `caexps` and the setup statements to
-- `castats`. `vargexps` holds the already-coerced surplus static args (those
-- beyond the callee's fixed params). A call whose arguments end in `...`
-- never reaches here: the checker gives it an open-input plan, which both
-- callers lower through their open-run path instead.
-- Shared by codecall (static call site) and codevaluecall (first-class value
-- fast path) -- both build the struct identically (§5.7).
-- Implementation notes: doc/implementation/variadic-parameters.md#static-call-sites
function emit_vararg_struct(ctx, callee_ftype, vargexps, caexps, castats)
    local callee_vararg = callee_ftype.varargtype
    -- Keep the elements on the C stack and point an exact, named TitanVarg
    -- descriptor at them. This avoids both heap allocation and an
    -- incompatible-struct cast.
    assert(#vargexps <= 200, "static variadic arg count exceeds TITAN_VARARG_MAX")
    local n = #vargexps
    local struct = varg_struct_name(callee_vararg)
    local elem_ct = ctype(callee_vararg)
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_vargargs_" .. suffix
    local vname = "_varg_" .. suffix
    local arrlen = math.max(n, 1)
    local inits = n > 0 and ("{ " .. table.concat(vargexps, ", ") .. " }")
        or "{ 0 }"
    table.insert(castats, render([[
        $ELEM_CT $ARGS[$ARRLEN] = $INITS;
        $STRUCT $VARG = { $N, $ARGS };
    ]], {
        STRUCT = struct,
        ELEM_CT = elem_ct,
        ARGS = argsname,
        ARRLEN = c_integer_literal(arrlen),
        N = c_integer_literal(n),
        VARG = vname,
        INITS = inits,
    }))
    table.insert(caexps, "&" .. vname)
    table.insert(caexps, "0")
end

-- Allocate the caller-owned typed backing for one flexible-result call.  A
-- finite consumer gets its exact right-sized buffer; an open consumer (or a
-- flexible return whose inherited budget is only known at run time) gets the
-- bounded 200-element backing.  Open GC-bearing runs also reserve a parallel,
-- traced Lua-stack range.  The native descriptor is never itself a root.
--
-- `_coder_open_want` is installed transiently by an open sink. It is either
-- `LUA_MULTRET` or a C expression for an inherited finite copy budget. Exact
-- native calls receive that budget directly. Generic calls in this statically
-- open mode always use LUA_MULTRET, recover the raw count from the Lua stack,
-- and copy at most this budget into the run.
function coder._flex_call_buffer(ctx, node, ftype, stats, callargs)
    if not ftype.flexrettype then return nil end
    local demand = node._coder_open_want or node._flex_result_demand or 0
    local isopen = node._coder_open_want ~= nil or demand == "open"
    if demand == "open" then demand = "LUA_MULTRET" end
    if type(demand) == "number" then
        assert(demand >= 0 and demand <= 200)
    else
        assert(type(demand) == "string")
    end
    local prefix = isopen and (node._finite_flex_prefix
        or (node._open_results and node._open_results.start - 1) or 0) or 0
    local call_demand = demand
    if isopen and prefix > 0 then
        if type(demand) == "number" then
            call_demand = math.min(200, prefix + demand)
        else
            call_demand = render([[
                (($WANT == LUA_MULTRET) ? LUA_MULTRET
                    : (($WANT >= $REMAINING) ? TITAN_VARARG_MAX
                        : ($WANT + $PREFIX)))
            ]], {
                WANT = demand,
                REMAINING = c_integer_literal(200 - prefix),
                PREFIX = c_integer_literal(prefix),
            })
        end
    end
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_flexargs_" .. suffix
    local descname = "_flexdesc_" .. suffix
    local cap = isopen and 200
        or (type(demand) == "number" and math.max(demand, 1) or 200)
    table.insert(stats, render([[
        $ELEM $ARGS[$CAP] = {0};
        $STRUCT $DESC = { 0, $ARGS };
    ]], {
        ELEM = ctype(ftype.flexrettype),
        ARGS = argsname,
        CAP = c_integer_literal(cap),
        STRUCT = varg_struct_name(ftype.flexrettype),
        DESC = descname,
    }))
    table.insert(callargs, "&" .. descname)
    table.insert(callargs, type(call_demand) == "number"
        and c_integer_literal(call_demand) or call_demand)
    local run = {
        elem = ftype.flexrettype,
        demand = demand,
        call_demand = call_demand,
        args = argsname,
        desc = descname,
        total_count = "(int)" .. descname .. ".n_args",
        count = prefix == 0 and ("(int)" .. descname .. ".n_args")
            or render("(((int)$DESC.n_args > $START) ? ((int)$DESC.n_args - $START) : 0)", {
                DESC = descname,
                START = c_integer_literal(prefix),
            }),
        start = c_integer_literal(prefix),
        prefix = prefix,
        capacity = cap,
        isopen = isopen,
        effectively_open = node._coder_open_effectively_open
            or (isopen and "1" or "0"),
        ownership = "caller",
    }
    if isopen and types.is_gc(run.elem) then
        run.root_depth = ctx.depth
        for _ = 1, cap do reserveslot(ctx) end
    end
    return run
end

-- Publish a caller-owned run into its parallel traced root range.  This handoff
-- performs no allocation: it is safe immediately after an exact native return
-- and after generic stack values have been converted into the typed backing.
function coder._anchor_result_run(run)
    if not run or not run.root_depth then return "" end
    return render([[
        for (int _rri = 0; _rri < $COUNT; _rri++) {
            $SETSLOT
        }
    ]], {
        COUNT = run.count,
        SETSLOT = setslot(run.elem,
            "s2v(" .. stackslotat(run.root_depth) .. " + _rri)",
            run.args .. "[" .. run.start .. " + _rri]"),
    })
end

-- Release the parallel roots after a sink has copied/stored the run.  Reserved
-- slots remain part of the function's fixed frame and may be reused by the
-- ordinary depth stack; clearing only the live prefix avoids retaining dead
-- collectable values across loops or later allocations.
function coder._cleanup_result_run(run)
    if not run or not run.root_depth then return "" end
    return render([[
        for (int _rri = 0; _rri < $COUNT; _rri++) {
            setnilvalue2s($ROOT + _rri);
        }
    ]], {
        COUNT = run.count,
        ROOT = stackslotat(run.root_depth),
    })
end

-- Implementation notes: doc/implementation/closure-adjustment-wrappers.md#adapter-site-discovery
function coder._callable_adapter_site(tlcontext, adapter)
    coder._validate_callable_adapter_plan(
        adapter, adapter.source, adapter.target,
        "callable adapter registration", {})
    assert(not adapter.exact,
        "exact callable adjustment reached wrapper registration")
    local prior = tlcontext.callable_adapters[adapter]
    if prior then return prior end
    local index = tlcontext.callable_adapter_count
    tlcontext.callable_adapter_count = index + 1
    local stem = tlcontext.prefix
        .. "callable_adapter_" .. tostring(index)
    local site = {
        adapter = adapter,
        index = index,
        native = stem,
        strict = stem .. "_" .. TITAN_ENTRY_TAG .. "_strict",
    }
    tlcontext.callable_adapters[adapter] = site
    tlcontext.callable_adapter_list[#tlcontext.callable_adapter_list + 1] = site
    function_type_tag(tlcontext, adapter.source)
    function_type_tag(tlcontext, adapter.target)
    register_trace_name(tlcontext, site.native, adapter.trace_name)
    register_trace_name(tlcontext, site.strict, adapter.trace_name)
    return site
end

-- Construct the target callable view over one already available, already
-- rooted source value. Eligible exact-Titan sources get a fresh closure whose
-- upvalues are initialized directly while it is white, then published into one
-- traced result slot. Fallback values retain their original identity and are
-- published into that same result slot by the mutually exclusive branch.
-- Implementation notes: doc/implementation/closure-adjustment-wrappers.md#wrapper-layout
function coder._emit_callable_adapter_value(
    ctx, adapter, raw, loc, use, result_root)
    use = use or "callable adapter construction"
    adapter = coder._validate_callable_adapter_plan(
        adapter, adapter.source, adapter.target, use, {})
    assert(not adapter.exact,
        use .. " unexpectedly constructs an exact callable view")
    local site = coder._callable_adapter_site(ctx.tlcontext, adapter)
    local source_decl, source_name = newtmp(ctx, adapter.source)
    local result_decl, result_name = newtmp(ctx, adapter.target)
    result_root = result_root or slotat(reserveslot(ctx))
    local location = adapter.location
    if loc then
        assert(type(loc) == "table" and loc.filename,
            use .. " lacks its owning source location")
    end
    local code = render([[
        $SOURCE_DECL
        $SOURCE_NAME = $RAW;
        $RESULT_DECL
        $RESULT_NAME = $SOURCE_NAME;
        {
            CClosure *_ca_source = ttisCclosure(&$SOURCE_NAME)
                ? clCvalue(&$SOURCE_NAME) : NULL;
            if (_ca_source != NULL
                    && _ca_source->nupvalues >= 5
                    && _ca_source->nupvalues < MAXUPVAL
                    && ttislightuserdata(&_ca_source->upvalue[1])
                    && pvalue(&_ca_source->upvalue[1]) == $SOURCE_TAG
                    && ttislightuserdata(&_ca_source->upvalue[3])
                    && pvalue(&_ca_source->upvalue[3])
                        == TITAN_BRAND) {
                int _ca_nup = (int)_ca_source->nupvalues;
                $LINE
                CClosure *_ca_wrapper =
                    luaF_newCclosure(L, _ca_nup + 1);
                _ca_wrapper->f = _ca_source->f;
                for (int _ca_i = 0; _ca_i < _ca_nup - 1; _ca_i++) {
                    if (_ca_i == 0) {
                        setuvalue(L, &_ca_wrapper->upvalue[_ca_i], _mod);
                    } else if (_ca_i == 1) {
                        setpvalue(&_ca_wrapper->upvalue[_ca_i],
                            (void *)$TARGET_TAG);
                    } else if (_ca_i == 2) {
                        setpvalue(&_ca_wrapper->upvalue[_ca_i],
                            titan_cast_func(void *, $TARGET_ADAPTER));
                    } else {
                        setobj2n(L, &_ca_wrapper->upvalue[_ca_i],
                            &_ca_source->upvalue[_ca_i]);
                    }
                }
                setclCvalue(L,
                    &_ca_wrapper->upvalue[_ca_nup - 1], _ca_source);
                setfvalue(&_ca_wrapper->upvalue[_ca_nup], $TARGET_STRICT);
                lua_assert(iswhite(_ca_wrapper));
                setclCvalue(L, $RESULT_ROOT, _ca_wrapper);
                setclCvalue(L, &$RESULT_NAME, _ca_wrapper);
            } else {
                $PUBLISH_FALLBACK
            }
        }
    ]], {
        SOURCE_DECL = source_decl,
        SOURCE_NAME = source_name,
        RAW = raw,
        RESULT_DECL = result_decl,
        RESULT_NAME = result_name,
        SOURCE_TAG = function_type_tag(
            ctx.tlcontext, adapter.source),
        TARGET_TAG = function_type_tag(
            ctx.tlcontext, adapter.target),
        TARGET_ADAPTER = site.native,
        TARGET_STRICT = site.strict,
        LINE = emitline({ loc = location }),
        RESULT_ROOT = result_root,
        PUBLISH_FALLBACK = setslot(
            adapter.target, result_root, result_name),
    })
    return code, result_name
end

-- Report whether a checker-frozen adjustment constructs a fresh GC object.
-- A runtime-sized sink uses this only to choose a distinct slot for each live
-- dynamic result; the adjustment's cast remains the sole code that publishes
-- the object into that slot. This is neither a second anchor nor a semantic
-- permission check.
function coder._adjustment_allocates_gc(adjustment)
    if adjustment.kind == "callable" then
        return adjustment.exact == false
    end
    if adjustment.interface_conversion then return true end
    if adjustment.kind == "gradual_view"
        and coder._may_discover_interface(adjustment.target) then
        return true
    end
    local coercion = adjustment.coercion
    local function coercion_allocates(plan)
        if not plan or plan.kind == "identity" then
            return false
        end
        if plan.op == "interface_wrapper" then return true end
        if plan.op == "option_map"
            or plan.op == "option_wrap"
            or plan.op == "option_force" then
            return coercion_allocates(plan.inner)
        end
        return false
    end
    return coercion_allocates(coercion)
end

-- Lower one checker-produced assignment adjustment over an already available
-- C expression. Identity, structural gradual views, and callable adjustments
-- preserve representation. Every representation-changing edge is reified as
-- an annotated cast carrying the exact checker plan; code generation never
-- reruns a type relation to rediscover permission.
function coder._code_adjustment_value(
    ctx, adjustment, source_type, target, raw, loc, adapter_alias,
    result_root)
    adjustment = coder._checked_adjustment_plan(
        adjustment, source_type, target, "value adjustment")
    if adjustment.kind == "identity" then
        assert(adapter_alias == nil,
            "identity adjustment has an unexpected callable adapter")
        return "", raw
    elseif adjustment.kind == "callable" then
        if adjustment.exact then
            assert(adapter_alias == nil,
                "exact callable adjustment has an unexpected adapter")
            return "", raw
        end
        local adapter = assert(adjustment._callable_adapter,
            "callable adjustment lacks its frozen adapter")
        assert(adapter_alias == nil or adapter_alias == adapter,
            "callable adjustment alias differs from its raw frozen adapter")
        coder._validate_callable_adapter_plan(
            adapter, source_type, target, "value callable adjustment", {})
        return coder._emit_callable_adapter_value(
            ctx, adapter, raw, loc, "value callable adjustment",
            result_root)
    end
    if adjustment.kind == "gradual_view"
        and adjustment.op == "structural" then
        -- Arrays, Maps, and callables retain a durable view whose component
        -- observations are guarded later. An Option has no separate mutable
        -- backing: its present payload is the immediate component observation.
        -- Guard it while the checker-owned view plan is still attached so a
        -- later identity option_force/option_map cannot forget the actual base
        -- type stored in this TValue.
        local asource = assert(adjustment.source)
        local atarget = assert(adjustment.target)
        if asource._tag ~= "Type.Option"
            or atarget._tag ~= "Type.Option" then
            return "", raw
        end
        assert(adjustment.guard
            and adjustment.guard.op == "option",
            "structural Option view lacks its strict guard plan")
        if coder._is_native_option(source_type)
            and coder._is_native_option(target)
            and coder._native_option_ctype(source_type)
                == coder._native_option_ctype(target) then
            -- A typedef can give an otherwise identical foreign scalar a
            -- structural Option view. Its already-typed native carrier proves
            -- the same scalar category; converting through TValue here would
            -- manufacture a narrower boundary that the source never asked for.
            return "", raw
        end
        -- Most successful guards only borrow the existing payload. A present
        -- Interface leaf may dynamically construct a wrapper. Ordinarily this
        -- cast owns one traced temporary; a runtime-sized enclosing sink can
        -- instead select its indexed result slot, into which this same cast
        -- publishes once so multiple loop iterations remain live together.
        local csrc, srcname = newtmp(ctx, source_type, false)
        local needs_anchor = coder._may_discover_interface(target)
        local cdst, dstname, dstslot =
            newtmp(ctx, target, needs_anchor and not result_root)
        local anchor_root = needs_anchor and (result_root or dstslot) or nil
        local boxed_source, box_stats = "&" .. srcname, ""
        if coder._is_native_option(source_type) then
            local boxed_name = fresh_lowering_name(ctx, "_option_view_box_")
            box_stats = "TValue " .. boxed_name .. ";\n"
                .. coder._native_option_box(source_type, "&" .. boxed_name, srcname)
            boxed_source = "&" .. boxed_name
        end
        return render([[
            $CSRC
            $SRCNAME = $RAW;
            $CDST
            $BOX
            $CHECK
            $REBASE
            $ANCHOR
        ]], {
            CSRC = csrc,
            SRCNAME = srcname,
            RAW = raw,
            CDST = cdst,
            BOX = box_stats,
            CHECK = coder._strictcheckandget(
                ctx, adjustment.guard, target, dstname, boxed_source,
                loc, "structural Option view"),
            REBASE = coder._rebase_after_interface_discovery(ctx, target),
            ANCHOR = anchor_root
                and setslot(target, anchor_root, dstname) or "",
        }), dstname
    end
    assert(adjustment.kind == "direct_coercion"
        or (adjustment.kind == "gradual_view"
            and (adjustment.op == "inject"
                or adjustment.op == "project")),
        "unknown checker adjustment kind " .. tostring(adjustment.kind))

    local csrc, srcname = newtmp(ctx, source_type)
    local synthvar = {
        _tag = "Ast.VarName",
        _type = source_type,
        _decl = { _cvar = srcname },
    }
    local synthcast = {
        _tag = "Ast.ExpCast",
        _written_cast = maybe3.unknown(),
        loc = loc,
        exp = synthvar,
        target = target,
        _type = target,
        _implicit_coercion = true,
        _adjustment = adjustment,
        _interface_conversion = adjustment.interface_conversion,
        _allocation_result_root = result_root,
    }
    local convstats, convexp = codeexp(ctx, synthcast)
    return render([[
        $CSRC
        $SRCNAME = $RAW;
        $CONVSTATS
    ]], {
        CSRC = csrc,
        SRCNAME = srcname,
        RAW = raw,
        CONVSTATS = convstats,
    }), convexp
end

-- Read one typed run element and consume the open sink's stored adjustment.
-- Contiguous runs borrow their source provenance. A non-contiguous reader can
-- instead use the supplied result slot as its ordinary VM lookup destination;
-- buffered sinks pass a distinct slot for every still-live result.
function coder._convert_result_run_element(
    ctx, run, target, index, loc, result_root, result_stack)
    local readstats, raw
    if run.read then
        readstats, raw = run.read(
            ctx, index, loc, result_root, result_stack)
    else
        readstats = ""
        raw = run.args .. "[" .. run.start .. " + " .. index .. "]"
    end
    coder._checked_adjustment_plan(
        run.adjustment, run.elem, target, "open result adjustment")
    if types.equals(run.elem, target) then
        assert(run.adjustment.kind == "identity",
            "equal open result elements lack an identity checker adjustment: "
            .. types.tostring(run.elem) .. " -> "
            .. types.tostring(target) .. " used "
            .. tostring(run.adjustment.kind))
        return readstats, raw
    end
    -- A non-contiguous reader may need result_root to retain its raw VM result
    -- even when the following adjustment cannot allocate. Only an allocating
    -- adjustment may select that same slot as its own final cast anchor.
    local adjustment_root = coder._adjustment_allocates_gc(run.adjustment)
        and result_root or nil
    local convstats, converted = coder._code_adjustment_value(
        ctx, run.adjustment, run.elem, target, raw, loc,
        run.callable_adapter, adjustment_root)
    return readstats .. "\n" .. convstats, converted
end

-- Lower the sole open producer of an adjusted expression list. Input `...`
-- borrows its descriptor elements' existing traced provenance; a flexible call publishes a
-- caller-owned run through `_coder_result_run`.  `want` and
-- `effectively_open` let a flexible-return sink pass its inherited run-time
-- budget while arrays and variadic arguments use an unconditional open demand.
function coder._carries_open_source(exp, source)
    if exp == source then return true end
    return exp and exp._tag == "Ast.ExpCast"
        and coder._carries_open_source(exp.exp, source) or false
end

function coder._code_open_source(ctx, source, want, effectively_open, carrier)
    if source._tag == "Ast.ExpDots" then
        local va = assert(ctx.varargs, "open '...' outside a variadic function")
        local projection = source._open_dots and source._open_dots.start or 1
        local logical_start = projection == 1 and tostring(va.start)
            or render("($START + $DELTA)", {
                START = va.start,
                DELTA = c_integer_literal(projection - 1),
            })
        local start = render("(((int)$SRC->n_args < $LOGICAL) ? (int)$SRC->n_args : $LOGICAL)", {
            SRC = va.cname,
            LOGICAL = logical_start,
        })
        return "", "((void)0)", {
            elem = va.elem,
            args = va.cname .. "->args",
            start = start,
            count = render("((int)$SRC->n_args - $START)", {
                SRC = va.cname,
                START = start,
            }),
            capacity = 200,
            isopen = true,
            effectively_open = effectively_open or "1",
            ownership = "borrowed",
        }
    end
    if source._tag == "Ast.ExpSpread" then
        local stats, exp = codeexp(ctx, carrier or source)
        local prepared = assert(source._coder_spread,
            "open spread producer did not publish prepared state")
        local run = assert(prepared.run,
            "open spread producer did not publish a result run")
        run.effectively_open = effectively_open or "1"
        run.want = want or "LUA_MULTRET"
        return stats, exp, run
    end
    assert(source._tag == "Ast.ExpCall")
    source._coder_open_want = want or "LUA_MULTRET"
    source._coder_open_effectively_open = effectively_open or "1"
    local stats, exp = codeexp(ctx, carrier or source)
    local run = assert(source._coder_result_run,
        "open call producer did not publish a result run")
    source._coder_open_want = nil
    source._coder_open_effectively_open = nil
    return stats, exp, run
end

-- Evaluate an adjusted open expression list exactly once in lexical order.
-- Its finite prefix and explicit scalar tail are materialized separately; the
-- sole trailing dynamic producer is returned as a shared result run.  A call
-- may simultaneously provide a fixed primary value and the dynamic run, so
-- open-source identity is orthogonal to fixed/tail membership.
function coder._codeadjustedopen(
    ctx, adjusted, want, effectively_open, stabilize)
    stabilize = stabilize or materialize_code
    local fixed_index, tail_index, discard_set = {}, {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for i, exp in ipairs(adjusted.tail_scalars) do tail_index[exp] = i end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local stats, fixednames, tailnames = {}, {}, {}
    local run
    for _, exp in ipairs(adjusted.exps) do
        local cs, ce
        if coder._carries_open_source(exp, adjusted.open_source) then
            cs, ce, run = coder._code_open_source(ctx,
                adjusted.open_source, want, effectively_open, exp)
        else
            cs, ce = codeexp(ctx, exp)
        end
        local fi, ti = fixed_index[exp], tail_index[exp]
        if fi or ti then
            local mstats, name = stabilize(
                ctx, exp._type, cs, ce)
            table.insert(stats, mstats)
            if fi then fixednames[fi] = name else tailnames[ti] = name end
        else
            assert(coder._carries_open_source(exp, adjusted.open_source)
                or discard_set[exp] or exp._discard_results)
            table.insert(stats, cs)
            table.insert(stats, "(void)(" .. ce .. ");")
        end
    end
    assert(run, "adjusted open expression list produced no result run")
    run.adjustment = assert(adjusted.open_adjustment,
        "open expression list lacks checker adjustment")
    run.callable_adapter = adjusted.open_callable_adapter or nil
    if run.adjustment.kind == "callable" then
        assert(run.callable_adapter == run.adjustment._callable_adapter,
            "open callable adapter alias differs from its raw plan")
    else
        assert(run.callable_adapter == nil,
            "non-callable open adjustment has a callable adapter alias")
    end
    return stats, fixednames, tailnames, run
end

-- Validate a runtime-sized open argument run before any fixed backing array,
-- Lua-stack reservation, or element loop observes its count. Spread ranges can
-- span the full lua_Integer domain, unlike the byte-sized call/dots runs, so
-- compare before addition and publish the now-small count under one C name.
function coder._check_open_vararg_count(ctx, node, nprefix, run, stats)
    if run.vararg_count then return run.vararg_count end
    assert(nprefix >= 0 and nprefix <= 200)
    local count = fresh_lowering_name(ctx, "_open_varg_count_")
    table.insert(stats, render([[
        lua_Unsigned $COUNT = (lua_Unsigned)($RUNCOUNT);
        if (TITAN_LIKELY(
                $COUNT <= (lua_Unsigned)TITAN_VARARG_MAX - $NPREFIX)) {
            /* count is safe for the bounded descriptor and int loops */
        } else {
            luaL_error(L,
                "%s:%d:%d: too many variadic arguments (max %d)",
                $FILE, $LINE, $COL, (int)TITAN_VARARG_MAX);
        }
    ]], {
        COUNT = count,
        RUNCOUNT = run.count,
        NPREFIX = c_integer_literal(nprefix),
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
    }))
    run.vararg_count = count
    return count
end

-- Materialize an adjusted scalar-prefix + dynamic run as one input-variadic
-- descriptor. Native inputs remain C values; each open conversion that actually
-- allocates a fresh callable/Interface wrapper establishes that allocation's
-- immediate element-specific traced root. A conditional identity fallback does
-- not publish the source there. The descriptor backing is an untraced caller C
-- array.
function coder._emit_open_vararg_struct(ctx, node, callee_ftype, tailnames,
                                        run, stats, callargs)
    local elem = assert(callee_ftype.varargtype)
    local suffix = tostring(ctx.tmp)
    ctx.tmp = ctx.tmp + 1
    local argsname = "_open_vargs_" .. suffix
    local descname = "_open_vargdesc_" .. suffix
    local countname = "_open_vargcount_" .. suffix
    local runcount = coder._check_open_vararg_count(
        ctx, node, #tailnames, run, stats)
    local root_depth
    if run.retain_read_results
        or coder._adjustment_allocates_gc(run.adjustment) then
        root_depth = ctx.depth
        for _ = 1, 200 do reserveslot(ctx) end
    end
    local runindex = c_integer_literal(#tailnames) .. " + _vai"
    local result_stack = root_depth and ("("
        .. stackslotat(root_depth) .. " + " .. runindex .. ")") or nil
    local result_root = result_stack and ("s2v(" .. result_stack .. ")")
        or nil
    local convstats, convexp = coder._convert_result_run_element(
        ctx, run, elem, "_vai", node.loc, result_root, result_stack)
    local prefixsets = {}
    for i, name in ipairs(tailnames) do
        local index = c_integer_literal(i - 1)
        table.insert(prefixsets, render([[
            $ARGS[$INDEX] = $VALUE;
        ]], {
            ARGS = argsname,
            INDEX = index,
            VALUE = name,
        }))
    end
    table.insert(stats, render([[
        int $COUNT = $NPREFIX + (int)$RUNCOUNT;
        $ELEM $ARGS[TITAN_VARARG_MAX] = {0};
        $PREFIXSETS
        for (int _vai = 0; _vai < (int)$RUNCOUNT; _vai++) {
            $CONVSTATS
            $ARGS[$NPREFIX + _vai] = $VALUE;
        }
        $STRUCT $DESC = { (lu_byte)$COUNT, $ARGS };
    ]], {
        COUNT = countname,
        NPREFIX = c_integer_literal(#tailnames),
        RUNCOUNT = runcount,
        FILE = c_string_literal(node.loc.filename),
        LINE = c_integer_literal(node.loc.line),
        COL = c_integer_literal(node.loc.col),
        ELEM = ctype(elem),
        ARGS = argsname,
        PREFIXSETS = table.concat(prefixsets, "\n"),
        CONVSTATS = convstats,
        VALUE = convexp,
        STRUCT = varg_struct_name(elem),
        DESC = descname,
    }))
    table.insert(callargs, "&" .. descname)
    table.insert(callargs, "0")
    return {
        elem = elem,
        args = argsname,
        desc = descname,
        count = countname,
        start = "0",
        ownership = "caller",
        -- This is the call-site materialization range, distinct from any
        -- roots owned by the upstream producer run. Open values begin after
        -- the scalar prefix; clearing the complete descriptor count also
        -- removes stale prefix slots left by a shorter later materialization.
        root_depth = root_depth,
    }
end

-- Generate a call through a first-class function *value* (a boxed TValue of
-- type Type.Function). The value may be a Titan closure, a Lua closure, a C
-- function, or a `__call` object. An exact Titan tag takes the direct native
-- path; generic Titan and Lua-callable cases go through the Lua stack with
-- `luaD_callnoyield`, which raises cleanly if the value is not callable.
--
-- luaD_callnoyield can grow (and relocate) the Lua stack for the callee's
-- frame, which would dangle this native function's `_base`. We therefore use
-- savestack/restorestack offsets for everything that must survive the call and
-- recompute `_base` from `_base_off` afterwards (see codefuncdec).
-- Implementation notes: doc/implementation/codegen-overview.md#calling-function-values-codevaluecall
function codevaluecall(ctx, node)
    assert(not node._named_arg_order)
    ctx.uses_base_off = true
    -- `_callee_type` / `_types` describe the callable's native ABI.  The
    -- checker deliberately keeps those separate from the results visible to
    -- this particular consumer: a discarded call, for example, has
    -- `_type == Void` and no visible results while the native entry still
    -- returns its complete fixed prefix.  Keep both counts explicit here.
    local ftype = node._callee_type or node.exp._type
    local abi_nresults = #node._types
    local visible_types = node._visible_types or node._types
    local nresults = #visible_types
    if not node._open_results then
        assert(nresults <= LUA_VM_MAX_RESULTS,
            "checker admitted an oversized finite generic result request")
    end
    local stats = {}

    -- 1. evaluate the callee once into a C temporary. The exact Titan branch
    -- receives it through the native convention; only the slow branches later
    -- publish it on the Lua stack as an actual Lua-convention argument.
    local fstat, fexp = codeexp(ctx, node.exp)
    local fdecl, fname = newtmp(ctx, ftype, false)
    table.insert(stats, fstat)
    table.insert(stats, fdecl)
    table.insert(stats, fname .. " = " .. fexp .. ";")

    -- A variadic callee value: `ftype.varargtype` is set. The argument list holds
    -- the fixed-param args (1..nfixed) followed by any surplus static args (each
    -- destined for the backing struct), and a trailing `Ast.ExpDots` marker when
    -- the call forwards the current function's own `...` (§2.B). The marker never
    -- reaches codeexp. Dispatch is identical to a non-variadic value: the fast
    -- path (exact tag match) builds the struct and calls the native pointer with
    -- `_varargs` + `_start`; the generic path pushes every arg (expanding any
    -- forwarded `...` element-by-element) and lets the callee's genluaentry
    -- coerce + rebuild.
    local callee_vararg = ftype.varargtype
    local args = node.args.args
    local nargs = #args
    local dots_tail = nargs > 0 and args[nargs]._tag == "Ast.ExpDots"
    local nstatic = dots_tail and (nargs - 1) or nargs
    -- `_npassed_args` trims only fixed-arity surplus. Every explicit argument
    -- to an input-variadic callee belongs to its fixed prefix or variadic run.
    local npassed = callee_vararg and nstatic
        or (node._npassed_args or nstatic)
    assert(npassed <= nstatic)
    local nfixed = #ftype.params

    -- 2. evaluate arguments into C temporaries. Fixed-param args (1..nfixed)
    --    use the callee's declared parameter type; surplus static args use the
    --    vararg element type and become native backing-struct elements. Slow
    --    branches later box these same values into their Lua argument slots.
    local argnames, argtypes = {}, {} -- fixed-param args (both paths)
    local vargexps = {}               -- surplus static-arg C exprs (struct + push)
    local inputrun, inputtail
    if callee_vararg and node._arg_adjustment
        and node._arg_adjustment.open_source then
        local astats, fixednames, tailnames, run = coder._codeadjustedopen(
            ctx, node._arg_adjustment, "LUA_MULTRET", "1", coder._freeze_code)
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for i, atype in ipairs(ftype.params) do
            argnames[i] = assert(fixednames[i])
            argtypes[i] = atype
        end
        inputrun, inputtail = run, tailnames
        coder._check_open_vararg_count(
            ctx, node, #tailnames, inputrun, stats)
    elseif not callee_vararg and node._arg_adjustment then
        local astats, anames = coder._codeadjustedfixed(ctx, {
            _result_adjustment = node._arg_adjustment,
            exps = args,
        }, coder._freeze_code)
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for i, atype in ipairs(ftype.params) do
            argnames[i] = assert(anames[i])
            argtypes[i] = atype
        end
    else
        for i = 1, nstatic do
            local arg = args[i]
            local astat, aexp = codeexp(ctx, arg)
            table.insert(stats, astat)
            if i <= npassed then
                local atype = (callee_vararg and i > nfixed) and callee_vararg
                    or ftype.params[i]
                local adecl, aname = newtmp(ctx, atype, false)
                table.insert(stats, adecl)
                table.insert(stats, aname .. " = " .. aexp .. ";")
                if callee_vararg and i > nfixed then
                    table.insert(vargexps, aname)
                else
                    argnames[i] = aname
                    argtypes[i] = atype
                end
            else
                -- Positional Titan surplus is effect-only.  Keep the lexical
                -- expression exactly once without adding it to the callable ABI.
                table.insert(stats, "(void)(" .. aexp .. ");")
            end
        end
    end

    -- 3. The fast native branch must satisfy the complete fixed ABI, while the
    -- generic VM branch produces only this consumer's visible projection. Keep
    -- those storage domains separate and converge into visible holders.
    local abinames = {}
    for i = 1, abi_nresults do
        local rtype = node._types[i]
        local rdecl, rname = newtmp(ctx, rtype)
        table.insert(stats, rdecl)
        abinames[i] = rname
    end
    local visnames, visslots = {}, {}
    for i, rtype in ipairs(visible_types) do
        local rdecl, rname = newtmp(ctx, rtype)
        table.insert(stats, rdecl)
        visnames[i] = rname
        if types.is_gc(rtype) then
            visslots[i] = slotat(reserveslot(ctx))
        end
    end

    -- Build the backing struct (`_varargs`, `_start`) when the callee is variadic
    -- and its arguments are a static list (a trailing `...` selects `inputrun`).
    -- The two struct C exprs go into `vargca` (consumed by `fastargs`); the setup
    -- statements go into a FRESH local list `vargstats` -- NOT the shared `stats`
    -- prelude -- and are spliced into the FAST branch only (the `$VARGSTATS` slot,
    -- right before `$FASTCALL`). The struct is therefore built ONLY on the fast
    -- path (exact tag match). The generic path re-pushes elements directly from
    -- `vargexps` and does not read the struct. The descriptor's native elements
    -- remain C arguments and receive no tracing-only copies.
    local vargca = {}    -- the two struct C exprs (_varargs ptr, _start)
    local vargstats = {} -- the struct-build setup statements (fast path only)
    if callee_vararg and not inputrun then
        assert(not dots_tail, "a trailing '...' must use the open-input run")
        emit_vararg_struct(ctx, ftype, vargexps, vargca, vargstats)
    end

    -- 4a. fast path: the value is a Titan closure whose exact type tag matches
    --     the callee's static type -> unboxed direct native call
    ctx.valuecall_count = (ctx.valuecall_count or 0) + 1
    local fptype = "_vc_fp_t_" .. ctx.valuecall_count
    -- _fn on the fast path is the callee closure itself, so its native entry can
    -- reach any captured upvalues (slots 4+).
    local fastargs = { "L", "_vc_mod", "_vc_callee" }
    for _, aname in ipairs(argnames) do table.insert(fastargs, aname) end
    -- A variadic callee: `vargca` holds the trailing native args at the pinned ABI
    -- slot -- the backing-struct pointer + `_start`, preceded (in the start-adjust
    -- case) by the fixed params borrowed from this function's own `...`. They sit
    -- after the static fixed-param args and before the out-params (function_sig).
    local inputvarg
    if inputrun then
        inputvarg = coder._emit_open_vararg_struct(ctx, node, ftype,
            inputtail, inputrun, vargstats, fastargs)
    else
        for _, vexp in ipairs(vargca) do table.insert(fastargs, vexp) end
    end
    for i = 2, abi_nresults do
        table.insert(fastargs, "&" .. abinames[i])
    end
    local flexrun = coder._flex_call_buffer(ctx, node, ftype, stats, fastargs)
    local fastcall = "_vc_fp(" .. table.concat(fastargs, ", ") .. ");"
    if abi_nresults > 0 then
        fastcall = abinames[1] .. " = " .. fastcall
    end

    local fastprojections = {}
    local sources = node._result_sources or {}
    for i, name in ipairs(visnames) do
        local source = sources[i] or { kind = "fixed", index = i }
        if source.kind == "fixed" then
            table.insert(fastprojections,
                name .. " = " .. assert(abinames[source.index]) .. ";")
        else
            assert(source.kind == "flex" and flexrun)
            table.insert(fastprojections, render([[
                if ($DESC.n_args >= $INDEX) {
                    $SETPRESENT;
                } else {
                    $SETNIL
                }
            ]], {
                DESC = flexrun.desc,
                INDEX = c_integer_literal(source.index),
                SETPRESENT = coder._optional_result_store(visible_types[i], flexrun.elem, name,
                    flexrun.args .. "[" .. c_integer_literal(source.index - 1) .. "]"),
                SETNIL = coder._option_nil(visible_types[i], name),
            }))
        end
    end
    -- ABI holders are assigned only by the exact native branch. Mark even a
    -- consumer-hidden holder used in that branch so discarded fixed results do
    -- not trigger -Wunused-but-set-variable, without reading uninitialized
    -- storage after the generic branch.
    for _, name in ipairs(abinames) do
        table.insert(fastprojections, "(void)" .. name .. ";")
    end
    if flexrun and flexrun.isopen then
        table.insert(fastprojections, coder._anchor_result_run(flexrun))
        node._coder_result_run = flexrun
    end

    -- 4b. generic path: box function + args and call through the Lua stack. For a
    -- variadic callee, push every fixed and surplus static arg, then (when
    -- forwarding) each `...` element one by one; the callee's genluaentry reads
    -- `nfixed` fixed params and the rest as vararg, coercing each.
    local argpushes = {}
    local pushfixed = callee_vararg and nfixed or npassed
    for i = 1, pushfixed do
        if argnames[i] then
            table.insert(argpushes,
                setboxed(ctx, argtypes[i], "s2v(L->top.p)", argnames[i])
                .. " L->top.p++;")
        end
    end
    local npush_dynamic = ""
    if inputrun then
        local checked_input_count = assert(inputrun.vararg_count)
        npush_dynamic = " + " .. c_integer_literal(#inputtail)
            .. " + (int)" .. checked_input_count
        table.insert(argpushes, render([[
            if (TITAN_UNLIKELY($NPREFIX + $COUNT > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "%s:%d:%d: too many variadic arguments (%d, max %d)",
                    $FILE, $LINE, $COL, $NPREFIX + (int)$COUNT,
                    (int)TITAN_VARARG_MAX);
            }
        ]], {
            NPREFIX = c_integer_literal(#inputtail),
            COUNT = checked_input_count,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }))
        for _, name in ipairs(inputtail) do
            table.insert(argpushes,
                setboxed(ctx, callee_vararg, "s2v(L->top.p)", name)
                .. " L->top.p++;")
        end
        local pushstats, pushexp
        if node._arg_adjustment.open_source._tag == "Ast.ExpDots" then
            -- Preserve the existing forwarding contract for an input `...`:
            -- the exact native branch converts it to the static descriptor,
            -- while the generic branch pushes the written representation and
            -- lets the runtime callee's Lua entry perform its own checks.  A
            -- value-typed run viewed through a compatible (...: integer)
            -- static type may dispatch to a runtime (...: value) closure;
            -- narrowing it here would raise before that dispatch can occur.
            pushstats = ""
            pushexp = inputrun.args .. "[" .. inputrun.start .. " + _vpj]"
        else
            -- A flexible-result producer is consumed by this call's static
            -- input sink, just like an explicit scalar argument.  Apply its
            -- element conversion on both branches; only borrowed input `...`
            -- has the established runtime-signature forwarding behavior above.
            pushstats, pushexp = coder._convert_result_run_element(
                ctx, inputrun, callee_vararg, "_vpj", node.loc)
        end
        table.insert(argpushes, render([[
            for (int _vpj = 0; _vpj < $COUNT; _vpj++) {
                $PUSHSTATS
                $SETSLOT L->top.p++;
            }
        ]], {
            COUNT = checked_input_count,
            PUSHSTATS = pushstats,
            SETSLOT = setboxed(ctx,
                node._arg_adjustment.open_source._tag == "Ast.ExpDots"
                and inputrun.elem or callee_vararg,
                "s2v(L->top.p)", pushexp),
        }))
    else
        for _, vexp in ipairs(vargexps) do
            table.insert(argpushes,
                setboxed(ctx, callee_vararg, "s2v(L->top.p)", vexp)
                .. " L->top.p++;")
        end
    end
    if dots_tail and not inputvarg then
        -- forward the current `...`: push each element start-relative. The element
        -- C type matches the vararg struct exactly, so this is a wrapped store.
        local va = assert(ctx.varargs, "forwarding '...' in a value call outside a variadic function")
        local source_start = node._open_args and render("($START + $DELTA)", {
            START = va.start,
            DELTA = c_integer_literal(node._open_args.start - 1),
        }) or va.start
        source_start = render([[
            (((int)$SRC->n_args < ($LOGICAL))
                ? (int)$SRC->n_args : ($LOGICAL))
        ]], { SRC = va.cname, LOGICAL = source_start })
        npush_dynamic = render(" + ((int)$SRC->n_args - $START)",
            { SRC = va.cname, START = source_start })
        table.insert(argpushes, render([[
            for (int _vpj = 0; _vpj < (int)$SRC->n_args - $START; _vpj++) {
                $SETSLOT L->top.p++;
            }
        ]], {
            SRC = va.cname,
            START = source_start,
            SETSLOT = setboxed(ctx, va.elem, "s2v(L->top.p)",
                render("$SRC->args[$START + _vpj]",
                    { SRC = va.cname, START = source_start })),
        }))
    end
    local lua_pushes = {
        "setobj2s(L, L->top.p, &" .. fname .. "); L->top.p++;",
    }
    local strict_pushes = {
        [[
        setobj2s(L, L->top.p,
            &_vc_callee->upvalue[_vc_callee->nupvalues - 1]);
        L->top.p++;]],
        "setobj2s(L, L->top.p, &" .. fname .. "); L->top.p++;",
    }
    for _, push in ipairs(argpushes) do
        table.insert(lua_pushes, push)
        table.insert(strict_pushes, push)
    end

    local function make_slowreads(strict)
        local reads = {}
        for i = 1, nresults do
            local source =
                "s2v(restorestack(L, _vc_func) + " .. (i - 1) .. ")"
            if strict then
                local plans = assert(node._strict_result_guard_plans,
                    "generic call lacks checker strict result guards")
                assert(plans[i] ~= nil,
                    "generic call result lacks its checker strict guard")
                local check = coder._strictcheckandget(
                    ctx, maybe3.get_checked(plans[i], "call result plan"), visible_types[i], visnames[i], source,
                    node.loc, "branded Titan callable result")
                local anchor = coder._may_discover_interface(
                        visible_types[i]) and visslots[i]
                    and setslot(visible_types[i], visslots[i], visnames[i])
                    or ""
                table.insert(reads, check .. "\n" .. anchor)
            else
                local plans = assert(node._lua_result_dynamic_plans,
                    "generic call lacks checker dynamic result plans")
                assert(plans[i] ~= nil,
                    "generic call result lacks its checker dynamic plan")
                local check = coder._dynamiccheckandget(
                    ctx, maybe3.get_checked(plans[i], "call result plan"), visible_types[i], visnames[i], source,
                    node.loc, "non-Titan Lua callable result")
                local anchor = coder._may_discover_interface(
                        visible_types[i]) and visslots[i]
                    and setslot(visible_types[i], visslots[i], visnames[i])
                    or ""
                table.insert(reads, check .. "\n" .. anchor)
            end
        end
        return table.concat(reads, "\n")
    end
    local lua_slowreads = make_slowreads(false)
    local strict_slowreads = make_slowreads(true)
    local slowcall = render([[
        luaD_callnoyield(L, restorestack(L, _vc_func), $NRESULTS);
    ]], { NRESULTS = c_integer_literal(nresults) })
    local slowpre, lua_slowopen, strict_slowopen = "", "", ""
    -- Reserve the generic branch's complete finite result area as well as the
    -- function and arguments. `luaD_callnoyield` is an internal primitive and
    -- therefore assumes its caller has satisfied the public API's
    -- `checkresults` capacity invariant; finite nil-padding may write every
    -- requested slot even when the callable returns nothing.
    local npushfixed = 2 + pushfixed
        + (inputrun and 0 or #vargexps) + nresults
    if flexrun and flexrun.isopen then
        -- A statically open generic producer always uses LUA_MULTRET. Its
        -- results remain rooted on the Lua stack while Titan measures the raw
        -- count, applies the static fixed/flexible shape, and copies only the
        -- enclosing sink's finite/open budget into typed backing.
        slowcall = [[
            luaD_callnoyield(L, restorestack(L, _vc_func), LUA_MULTRET);
            if (L->ci->top.p < L->top.p) L->ci->top.p = L->top.p;
            int _vc_raw = (int)(L->top.p - restorestack(L, _vc_func));
        ]]
        slowpre = render([[
            while (L->top.p < restorestack(L, _vc_func) + $NVISIBLE) {
                setnilvalue2s(L->top.p);
                L->top.p++;
            }
        ]], { NVISIBLE = c_integer_literal(nresults) })
        local function make_slowopen(strict)
            local readone
            local source = "s2v(restorestack(L, _vc_func) + "
                .. c_integer_literal(abi_nresults) .. " + _vri)"
            local result_root = coder._may_discover_interface(flexrun.elem)
                and flexrun.root_depth and
                ("s2v(" .. stackslotat(flexrun.root_depth)
                    .. " + _vri)") or nil
            if strict then
                local guard = maybe3.get_checked(node._strict_open_result_guard_plan,
                    "open generic call result guard")
                readone = coder._strictcheckandget(
                    ctx, guard,
                    flexrun.elem, flexrun.args .. "[_vri]",
                    source, node.loc,
                    "branded Titan callable flexible result")
            else
                local plan = maybe3.get_checked(node._lua_open_result_dynamic_plan,
                    "open generic call result conversion")
                readone = coder._dynamiccheckandget(
                    ctx, plan, flexrun.elem,
                    flexrun.args .. "[_vri]", source, node.loc,
                    "non-Titan Lua callable flexible result")
            end
            local immediate_anchor = result_root and setslot(
                flexrun.elem, result_root, flexrun.args .. "[_vri]") or ""
            return render([[
            int _vc_flexraw = _vc_raw - $NFIXED;
            if (_vc_flexraw < 0) _vc_flexraw = 0;
            int _vc_want = $WANT;
            if (($EFFECTIVELY_OPEN) && TITAN_UNLIKELY(_vc_flexraw > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "%s:%d:%d: too many flexible return values (%d, max %d)",
                    $FILE, $LINE, $COL, _vc_flexraw, (int)TITAN_VARARG_MAX);
            }
            int _vc_keep = _vc_flexraw;
            if (_vc_want != LUA_MULTRET && _vc_keep > _vc_want)
                _vc_keep = _vc_want;
            if (_vc_keep > TITAN_VARARG_MAX) _vc_keep = TITAN_VARARG_MAX;
            $DESC.n_args = (lu_byte)_vc_keep;
            for (int _vri = 0; _vri < _vc_keep; _vri++) {
                $READONE
                $IMMEDIATE_ANCHOR
            }
            $ANCHORRUN
        ]], {
                NFIXED = c_integer_literal(abi_nresults),
                WANT = flexrun.call_demand,
                EFFECTIVELY_OPEN = flexrun.effectively_open,
                FILE = c_string_literal(node.loc.filename),
                LINE = c_integer_literal(node.loc.line),
                COL = c_integer_literal(node.loc.col),
                DESC = flexrun.desc,
                READONE = readone,
                IMMEDIATE_ANCHOR = immediate_anchor,
                ANCHORRUN = coder._anchor_result_run(flexrun),
            })
        end
        lua_slowopen = make_slowopen(false)
        strict_slowopen = make_slowopen(true)
    end

    -- Only consumer-visible holders are live after branch convergence. Hidden
    -- ABI temporaries die in the fast branch without crossing an allocation;
    -- anchoring them on the generic branch would read uninitialized storage.
    local anchors = {}
    for i, rtype in ipairs(visible_types) do
        if visslots[i] then
            table.insert(anchors,
                setslot(rtype, visslots[i], visnames[i]))
        end
    end
    table.insert(stats, render([[
        {
        CClosure *_vc_callee =
            ttisCclosure(&$FNAME) ? clCvalue(&$FNAME) : NULL;
        if (TITAN_LIKELY(_vc_callee != NULL
                && _vc_callee->nupvalues >= 5
                && pvalueraw(valraw(&_vc_callee->upvalue[1]))
                    == $FUNCTAG)) {
            /* fast path: exact function-type match, unboxed native call */
            Udata *_vc_mod = uvalue(&_vc_callee->upvalue[0]);
            $FPTYPEDEF;
            $FPTYPE _vc_fp = titan_cast_func($FPTYPE,
                pvalue(&_vc_callee->upvalue[2]));
            $VARGSTATS
            $LINEDIR
            $FASTCALL
            $FASTPROJECTIONS
            _base = restorestack(L, _base_off);
            $FASTINPUTCLEANUP
        } else {
            int _vc_is_titan =
                _vc_callee != NULL
                && _vc_callee->nupvalues >= 5
                && pvalueraw(valraw(&_vc_callee->upvalue[3]))
                    == TITAN_BRAND;
            if (_vc_is_titan) {
                /* Branded non-exact Titan closure: call its trailing strict
                   entry. The original closure is the hidden first VM argument
                   so the strict entry retains the owning module and captures. */
                titan_ensure_stack(L, $NPUSH);
                ptrdiff_t _vc_func = savestack(L, L->top.p);
                $STRICTPUSHES
                $LINEDIR
                $SLOWCALL
                $SLOWPRE
                $STRICTSLOWREADS
                $STRICTSLOWOPEN
                L->top.p = restorestack(L, _vc_func);
            } else {
                /* Genuine Lua/dynamic callable: dispatch through Lua with the
                   same already checker-adjusted arguments; only results
                   crossing back into typed Titan slots use the dynamic
                   boundary plan. */
                titan_ensure_stack(L, $NPUSH);
                ptrdiff_t _vc_func = savestack(L, L->top.p);
                $LUAPUSHES
                $LINEDIR
                $SLOWCALL
                $SLOWPRE
                $LUASLOWREADS
                $LUASLOWOPEN
                L->top.p = restorestack(L, _vc_func);
            }
        }
        _base = restorestack(L, _base_off);
        $ANCHORS
        $INPUTCLEANUP
        }
    ]], {
        FNAME = fname,
        FUNCTAG = function_type_tag(ctx.tlcontext, ftype),
        FPTYPEDEF = "typedef " .. function_sig(fptype, ftype, true),
        FPTYPE = fptype,
        VARGSTATS = table.concat(vargstats, "\n"),
        LINEDIR = emitline(node),
        FASTCALL = fastcall,
        FASTPROJECTIONS = table.concat(fastprojections, "\n"),
        FASTINPUTCLEANUP = coder._cleanup_result_run(inputvarg),
        NPUSH = c_integer_literal(npushfixed) .. npush_dynamic,
        STRICTPUSHES = table.concat(strict_pushes, "\n"),
        LUAPUSHES = table.concat(lua_pushes, "\n"),
        SLOWCALL = slowcall,
        SLOWPRE = slowpre,
        STRICTSLOWREADS = strict_slowreads,
        STRICTSLOWOPEN = strict_slowopen,
        LUASLOWREADS = lua_slowreads,
        LUASLOWOPEN = lua_slowopen,
        ANCHORS = table.concat(anchors, "\n"),
        INPUTCLEANUP = coder._cleanup_result_run(inputrun),
    }))

    -- 5. expose extra return values for ExpExtra readers
    if nresults >= 2 then
        node._extras = node._extras or {}
        for i = 2, nresults do
            node._extras[i] = visnames[i]
        end
    end

    local cstats = table.concat(stats, "\n")
    if nresults == 0 then
        return cstats, "((void)0)"
    else
        return cstats, visnames[1]
    end
end

local function lower_call(ctx, node)
    local constructor = node._nominal_constructor
    if constructor then
        local module = constructor.owner.name:match("^(.*)%.[^.]+$")
        -- A separate record provider owns `new`'s replaceable implementation.
        -- Fresh native storage is the exception: its argument plans require
        -- raw construction and the checker records that capability explicitly.
        if constructor.kind ~= "record" or module == ctx.module
           or ctx.tlcontext.static_deps[module] == true
           or next(constructor.allocation_plans) ~= nil then
            return coder._codenominalcall(ctx, node)
        end
    end
    if coder._immediate_function(node) then
        return codeimmediatecall(ctx, node)
    end
    if node._named_arg_order then
        assert(node._named_call_kind == "titan")
    end
    if not is_static_callee(node) then
        return codevaluecall(ctx, node)
    end
    local castats, caexps = {}, { "L" }
    local fname
    local fnode = node.exp.var
    local modarg = "_mod"
    if node.args._tag == "Ast.ArgsFunc" then
        if fnode._tag == "Ast.VarName" then
            fname = func_name(ctx.module, fnode.name, fnode._decl.islocal)
        elseif fnode._tag == "Ast.VarDot" then
            if fnode.exp._type._tag == "Type.CModule" then
                return codeforeigncall(ctx, node)
            elseif fnode._decl._tag == "Type.StaticMethod" then
                fname = static_name(fnode._decl)
                local mod, record = fnode._decl.fqtn:match("^(.*)%.([^.]+)$")
                if mod ~= ctx.module then
                    ctx.functions[fnode._decl.fqtn .. "." .. fnode._decl.name] = {
                        module = mod,
                        record = record,
                        type = fnode._decl,
                        name = fnode._decl.name,
                        mangled = fname
                    }
                    fname = coder._external_reference(ctx, mod, fname)
                    if fnode._alias_namespace then
                        modarg = coder._nominal_owner_module_expr(
                            ctx, fnode._decl.fqtn)
                    else
                        assert(fnode.exp.var._tag == "Ast.VarDot")
                        modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                            INDEX = c_integer_literal(
                                fnode.exp.var.exp.var._decl._upvalue) -- whew!
                        })
                    end
                end
            else
                assert(fnode._decl._tag == "Type.ModuleMember")
                fname = func_name(
                    fnode._decl.modname, fnode.name, fnode._decl.islocal)
                local mod = fnode._decl.modname
                if mod ~= ctx.module then
                    ctx.functions[mod .. "." .. fnode.name] = {
                        module = mod,
                        name = fnode.name,
                        type = fnode._type,
                        mangled = fname
                    }
                    fname = coder._external_reference(ctx, mod, fname)
                end
                modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                    INDEX = c_integer_literal(fnode.exp.var._decl._upvalue)
                })
            end
        end
        table.insert(caexps, modarg)
        table.insert(caexps, "NULL") -- _fn: a static top-level call has no closure
    else
        assert(node.args._tag == "Ast.ArgsMethod")
        if node._interface then
            local interface = node._interface
            local mtype = assert(node._interface_method)
            local index = assert(node._interface_method_index)
            local indexed = interface.methods[index + 1]
            assert(interface._tag == "Type.Interface"
                and index >= 0
                and indexed
                and indexed.name == mtype.name
                and types.equals(
                    types.method_function_type(indexed),
                    types.method_function_type(mtype)),
                "Interface call has a noncanonical method slot")
            local cstat, wrapper = coder._freeze(ctx, node.exp)
            local fptr = fresh_lowering_name(
                ctx, "_titan_interface_call_")
            table.insert(castats, cstat)
            table.insert(castats, render([[
                if (TITAN_UNLIKELY(
                        $WRAPPER->len % sizeof(TitanInterfaceMethod) != 0
                        || $WRAPPER->len / sizeof(TitanInterfaceMethod)
                            != $METHOD_COUNT)) {
                    luaL_error(L,
                        "malformed internal Interface wrapper for %s",
                        $IFACE);
                }
                TitanInterfaceMethod $STORED =
                    ((TitanInterfaceMethod *)getudatamem(
                        $WRAPPER))[$INDEX];
                if (TITAN_UNLIKELY(
                        $STORED == NULL)) {
                    luaL_error(L,
                        "uninitialized internal Interface method %s:%s",
                        $IFACE, $METHOD);
                }
                $FPTR_DECL = titan_cast_func(
                    $FPTR_TYPE,
                    $STORED);
            ]], {
                WRAPPER = wrapper,
                METHOD_COUNT = c_integer_literal(#interface.methods),
                IFACE = c_string_literal(interface.name),
                METHOD = c_string_literal(mtype.name),
                INDEX = c_integer_literal(index),
                STORED = fptr .. "_stored",
                FPTR_DECL = function_sig(fptr, mtype, true),
                FPTR_TYPE = function_sig("", mtype, true),
            }))
            fname = fptr
            table.insert(caexps,
                "uvalue(&" .. wrapper .. "->uv[0].uv)")
            table.insert(caexps, "NULL")
            table.insert(caexps,
                "uvalue(&" .. wrapper .. "->uv[1].uv)")
        else
            local mtype = node._method
            fname = method_name(mtype)
            local mod, record = mtype.fqtn:match("^(.*)%.([^.]+)$")
            if mod ~= ctx.module then
                ctx.functions[mtype.fqtn .. ":" .. mtype.name] = {
                    module = mod,
                    record = record,
                    name = mtype.name,
                    type = mtype,
                    mangled = fname
                }
                fname = coder._external_reference(ctx, mod, fname)
                if not ctx.modules[mod] then
                    ctx.modules[mod] = nextupvalue(ctx.tlcontext)
                end
                modarg = render("uvalue(&_mod->uv[$INDEX].uv)", {
                    INDEX = c_integer_literal(ctx.modules[mod])
                })
            end
            local cstat, cexp = coder._freeze(ctx, node.exp)
            table.insert(castats, cstat)
            table.insert(caexps, modarg)
            table.insert(caexps, "NULL")
            table.insert(caexps, cexp)
        end
    end
    -- The callee's static type, to detect a variadic callee and its fixed arity.
    -- ArgsMethod -> node._method; a static-method VarDot -> fnode._decl; otherwise
    -- the var's resolved Type.Function on fnode._type.
    local callee_ftype
    if node.args._tag == "Ast.ArgsMethod" then
        callee_ftype = node._interface_method or node._method
    elseif fnode._tag == "Ast.VarDot"
        and fnode._decl and fnode._decl._tag == "Type.StaticMethod" then
        callee_ftype = fnode._decl
    else
        callee_ftype = fnode._type
    end
    if callee_ftype and callee_ftype._tag == "Type.Function" then
        assert(callee_ftype.vararg == false,
            "Type.Function reserved vararg field must be false")
    end
    local callee_vararg = callee_ftype and callee_ftype.varargtype
    if node._named_arg_order then
        assert(callee_ftype)
        assert(not callee_vararg)
    end
    -- Any native Titan call can reallocate the Lua stack (directly or while
    -- servicing a collection). Keep `_base` as an offset and materialize the
    -- call so `_base` can be restored before result anchoring or later slot use.
    ctx.uses_base_off = true
    local args = node.args.args
    local nargs = #args
    -- A trailing `Ast.ExpDots` marker means this call FORWARDS the current
    -- function's own `...` into the (variadic) callee (the checker kept it for a
    -- variadic callee; §5.7). The static-prefix args are args[1..nargs-1]; the
    -- marker itself never reaches codeexp.
    local dots_tail = nargs > 0 and args[nargs]._tag == "Ast.ExpDots"
    if node._named_arg_order then assert(not dots_tail) end
    local nstatic = dots_tail and (nargs - 1) or nargs
    -- `_npassed_args` trims only fixed-arity surplus. Every explicit argument
    -- to an input-variadic callee belongs to its fixed prefix or variadic run.
    local npassed = callee_vararg and nstatic
        or (node._npassed_args or nstatic)
    assert(npassed <= nstatic)
    local nfixed = callee_vararg and #callee_ftype.params or npassed
    local vargexps = {} -- surplus static args destined for the backing struct
    local inputrun, inputvarg
    if node._named_arg_order then
        assert(nstatic == #callee_ftype.params)
        local argstats, argexps = named_ordered_call_args(ctx, args,
            node._named_arg_order)
        for _, stat in ipairs(argstats) do
            table.insert(castats, stat)
        end
        for i = 1, nstatic do
            local argexp = assert(argexps[i])
            table.insert(caexps, argexp)
        end
    elseif callee_vararg and node._arg_adjustment
        and node._arg_adjustment.open_source then
        local astats, fixednames, tailnames, run = coder._codeadjustedopen(
            ctx, node._arg_adjustment, "LUA_MULTRET", "1", coder._freeze_code)
        for _, stat in ipairs(astats) do table.insert(castats, stat) end
        for i = 1, #callee_ftype.params do
            local fixedname = assert(fixednames[i])
            table.insert(caexps, fixedname)
        end
        inputvarg = coder._emit_open_vararg_struct(ctx, node, callee_ftype,
            tailnames, run, castats, caexps)
        inputrun = run
    elseif not callee_vararg and node._arg_adjustment then
        -- The adjusted fixed inputs are not necessarily a prefix of the lexical
        -- expression list: a zero-result trailing producer can be retained for
        -- effect before a synthesized nil occupies the formal slot. Drive the
        -- ABI arguments from object-identity mapping, not `_npassed_args` alone.
        local astats, anames = coder._codeadjustedfixed(ctx, {
            _result_adjustment = node._arg_adjustment,
            exps = args,
        }, coder._freeze_code)
        for _, stat in ipairs(astats) do table.insert(castats, stat) end
        for i = 1, #callee_ftype.params do
            local aname = assert(anames[i])
            table.insert(caexps, aname)
        end
    else
        -- Only arguments that belong to the native input shape need stable C
        -- values.  A positional surplus is a lexical suffix; generate that
        -- suffix separately below so an effectful discarded call is never
        -- materialized with its consumer-facing `Void` type.
        local argstats, argexps = ordered_call_args(ctx, args, npassed)
        for i = 1, npassed do
            local cexp = argexps[i]
            table.insert(castats, argstats[i])
            if callee_vararg and i > nfixed then
                -- a surplus static arg -> a backing-struct element (already coerced
                -- to the element type by the checker)
                table.insert(vargexps, cexp)
            else
                table.insert(caexps, cexp)
            end
        end
        for i = npassed + 1, nstatic do
            -- Surplus positional Titan arguments remain in source order and
            -- are evaluated once, but are not part of the native ABI.
            local stat, exp = codeexp(ctx, args[i])
            table.insert(castats, stat)
            table.insert(castats, "(void)(" .. exp .. ");")
        end
    end
    -- Build + append the backing struct (`_varargs`, `_start`) for a variadic
    -- callee with a static argument list (a trailing `...` selects
    -- `inputrun`). Its C payload borrows the already evaluated native values.
    if callee_vararg and not inputrun then
        assert(not dots_tail, "a trailing '...' must use the open-input run")
        emit_vararg_struct(ctx, callee_ftype, vargexps, caexps, castats)
    end
    -- Keep the complete fixed ABI prefix in native temporaries even when this
    -- consumer hides some or all of it. Consumer-visible results get separate
    -- holders below; this is what lets a flex-only primary be an option TValue
    -- while the native entry itself still returns C void.
    local abinames = {}
    for i, typ in ipairs(node._types) do
        local decl, name = newtmp(ctx, typ)
        table.insert(castats, decl)
        abinames[i] = name
        if i >= 2 then table.insert(caexps, "&" .. name) end
    end
    local flexrun = coder._flex_call_buffer(ctx, node, callee_ftype,
        castats, caexps)

    local visible = node._visible_types or node._types
    local sources = node._result_sources or {}
    local visnames, visslots, projections = {}, {}, {}
    for i, typ in ipairs(visible) do
        local decl, name = newtmp(ctx, typ)
        table.insert(castats, decl)
        visnames[i] = name
        if types.is_gc(typ) then
            visslots[i] = slotat(reserveslot(ctx))
        end
        local source = sources[i] or { kind = "fixed", index = i }
        if source.kind == "fixed" then
            table.insert(projections,
                name .. " = " .. assert(abinames[source.index]) .. ";")
        else
            assert(source.kind == "flex" and flexrun)
            table.insert(projections, render([[
                if ($DESC.n_args >= $INDEX) {
                    $SETPRESENT;
                } else {
                    $SETNIL
                }
            ]], {
                DESC = flexrun.desc,
                INDEX = c_integer_literal(source.index),
                SETPRESENT = coder._optional_result_store(typ, flexrun.elem, name,
                    flexrun.args .. "[" .. c_integer_literal(source.index - 1) .. "]"),
                SETNIL = coder._option_nil(typ, name),
            }))
        end
    end

    local anchors = {}
    for i, typ in ipairs(visible) do
        if visslots[i] then
            table.insert(anchors,
                setslot(typ, visslots[i], visnames[i]) .. ";")
        end
    end
    node._extras = node._extras or {}
    for i = 2, #visnames do node._extras[i] = visnames[i] end

    local ccall = render("$NAME($CAEXPS)", {
        NAME = fname,
        CAEXPS = table.concat(caexps, ", "),
    })
    local callstat = #node._types > 0
        and (abinames[1] .. " = " .. ccall .. ";")
        or (ccall .. ";")
    table.insert(castats, emitline(node) .. callstat)
    -- The callee may relocate the Lua stack; restore `_base` before addressing
    -- any reserved result root, then publish only the visible projection.
    table.insert(castats, "_base = restorestack(L, _base_off);")
    if flexrun and flexrun.isopen then
        table.insert(castats, coder._anchor_result_run(flexrun))
        node._coder_result_run = flexrun
    end
    for _, stat in ipairs(projections) do table.insert(castats, stat) end
    for _, stat in ipairs(anchors) do table.insert(castats, stat) end
    if inputrun then
        table.insert(castats, coder._cleanup_result_run(inputrun))
        table.insert(castats, coder._cleanup_result_run(inputvarg))
    end
    for _, name in ipairs(abinames) do
        table.insert(castats, "(void)" .. name .. ";")
    end

    local cstats = table.concat(castats, "\n")
    if #visnames == 0 then
        return cstats, "((void)0)"
    end
    return cstats, visnames[1]
end

-- A normally returning ordinary Titan callee may have completed a write
-- through an aggregate's contextual mutable address. Commit each tracked byte
-- spill only after the call returns; calls passing no tracked aggregate
-- address emit nothing extra. Foreign calls commit `_c_mutated_decls` instead.
-- Implementation notes: doc/implementation/c-ffi-expressions.md#longjmp-safe-aggregate-spills
function codecall(ctx, node)
    local cstats, cexp = lower_call(ctx, node)
    local commits = {}
    for _, decl in ipairs(coder._titan_call_aggregate_out_decls(node)) do
        local update = spill_update(decl)
        if update ~= "" then table.insert(commits, update) end
    end
    if #commits == 0 then return cstats, cexp end
    return cstats .. "\n" .. table.concat(commits, "\n"), cexp
end

return core.coder

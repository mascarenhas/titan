local core = require "titan-compiler.coder.core"
local _ENV = core

-- All the code generation functions for EXPRESSIONS return
-- preliminary C code necessary for computing the expression
-- as a string of C statements, plus the code for the expression
-- as a string with a C expression. For trivial expressions
-- the preliminary code is always the empty string

codecindex_parts = function(ctx, node)
    if node._c_fam_access then
        local access = node._c_fam_access
        local istats, iexp = codeexp(ctx, node.exp2)
        local cidx, idxname = newtmp(ctx, types.Integer())
        local bstats, baseexp, lenexp
        if access.kind == "owned" then
            local owner_node = assert(node.exp1.var).exp
            local owner_stats, owner_exp = codeexp(ctx, owner_node)
            local owner_decl, owner_name = newtmp(ctx, owner_node._type)
            local owner_type = types.resolve_c_typedef(owner_node._type)
            local payload = coder._render_c_declaration(
                owner_type.pointee, "")
            bstats = render([[
                $STATS
                $DECL
                $OWNER = $EXP;
            ]], {
                STATS = owner_stats,
                DECL = owner_decl,
                OWNER = owner_name,
                EXP = owner_exp,
            })
            baseexp = "((" .. payload .. " *)getudatamem("
                .. owner_name .. "))->" .. access.field.name
            lenexp = "ivalue(&" .. owner_name .. "->uv[0].uv)"
        else
            bstats, baseexp = codeexp(ctx, node.exp1)
            lenexp = c_integer_literal(access.count)
        end
        local bounds = render([[
            if (TITAN_UNLIKELY($IDX < 0 || $IDX >= $LEN)) {
                luaL_error(L, "%s:%d:%d: C flexible-array index %I out of range [0, %d)", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
            }
        ]], {
            IDX = idxname,
            LEN = lenexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
        return {
            bstats = bstats,
            istats = istats,
            cidx = cidx,
            idxname = idxname,
            iexp = iexp,
            bounds = bounds,
            baseexp = baseexp,
        }
    end

    local basetype = types.resolve_c_typedef(node.exp1._type)
    local bstats, bexp = codeexp(ctx, node.exp1)
    local istats, iexp = codeexp(ctx, node.exp2)
    local cidx, idxname = newtmp(ctx, types.Integer())
    local baseexp, lenexp, bounds

    if basetype._tag == "Type.CPointer" then
        local cbase, basename = newtmp(ctx, node.exp1._type)
        bstats = render([[
            $BSTATS
            $CBASE
            $BASENAME = $BEXP;
            if (TITAN_UNLIKELY($BASENAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot index a NULL C pointer", $FILE, $LINE, $COL);
            }
        ]], {
            BSTATS = bstats,
            CBASE = cbase,
            BASENAME = basename,
            BEXP = bexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
        baseexp = basename
        bounds = ""
    elseif basetype._tag == "Type.CArray" then
        baseexp = bexp
        lenexp = c_integer_literal(basetype.len)
    elseif basetype._tag == "Type.COwned" then
        baseexp = code_owned_payload(bexp, basetype.pointee)
        lenexp = render("((lua_Integer)($OWNER->len / sizeof($CT)))", {
            OWNER = bexp,
            CT = coder._render_c_declaration(basetype.pointee, ""),
        })
    else
        error("invalid C index base " .. types.tostring(node.exp1._type))
    end

    if lenexp then
        bounds = render([[
            if (TITAN_UNLIKELY($IDX < 0 || $IDX >= $LEN)) {
                luaL_error(L, "%s:%d:%d: C index %I out of range [0, %d)", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
            }
        ]], {
            IDX = idxname,
            LEN = lenexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    end

    return {
        bstats = bstats,
        istats = istats,
        cidx = cidx,
        idxname = idxname,
        iexp = iexp,
        bounds = bounds,
        baseexp = baseexp,
    }
end

codecfield = function(ctx, node)
    local basetype = types.resolve_c_typedef(node.exp._type)
    local cstats, cexp = codeexp(ctx, node.exp)
    local field = node._decl
    if basetype._tag == "Type.CPointer" then
        local cbase, basename = newtmp(ctx, node.exp._type)
        return render([[
            $CSTATS
            $CBASE
            $BASENAME = $CEXP;
            if (TITAN_UNLIKELY($BASENAME == NULL)) {
                luaL_error(L, "%s:%d:%d: cannot access field '%s' of a NULL C pointer", $FILE, $LINE, $COL, $FIELDSTR);
            }
        ]], {
            CSTATS = cstats,
            CBASE = cbase,
            BASENAME = basename,
            CEXP = cexp,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            FIELDSTR = c_string_literal(field.name),
        }, true), render("$BASE->$FIELD", {
            BASE = basename,
            FIELD = field.name,
        })
    elseif basetype._tag == "Type.COwned" then
        return cstats, render("$BASE->$FIELD", {
            BASE = code_owned_payload(cexp, basetype.pointee),
            FIELD = field.name,
        })
    else
        return cstats, render("$BASE.$FIELD", {
            BASE = cexp,
            FIELD = field.name,
        })
    end
end

function codevar(ctx, node)
    if node._tag == "Ast.VarDot" then
        if node._decl._tag == "Type.Field" then
            local cstats, cexp = codeexp(ctx, node.exp)
            return cstats,
                getslot(node._type, nil, render("&(($EXP)->uv[$INDEX].uv)", {
                    EXP = cexp,
                    INDEX = node._decl.index
                }))
        elseif node._decl._tag == "Type.CField" then
            return codecfield(ctx, node)
        elseif node._decl._tag == "Type.CPseudoSize" then
            local op = node._decl.name == "sizeof" and "sizeof" or "_Alignof"
            local expression = render("$OP($CT)", {
                OP = op,
                CT = ctype(node._decl.ctype),
            })
            assert(node._decl.result_source,
                "C size pseudo-member lacks its checker-owned size_t type")
            return coder._code_checked_numeric_cast(
                ctx, node._decl.result_source, node._type,
                expression, node.loc, "boundary")
        elseif node._decl._tag == "Type.ModuleMember"
               and node._type._tag == "Type.Function" then
            -- Reference to an imported module's function as a first-class value:
            -- index the canonical closure out of that module's `_mod` directly
            -- (the closure slot is reconstructed in import_module), so the
            -- reference is O(1) and identity-preserving.
            return "", getslot(node._type, nil, render(
                "&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$FNINDEX].uv)", {
                MODINDEX = c_integer_literal(node.exp.var._decl._upvalue),
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and ctx.tlcontext.static_slots[node._decl.fqtn .. "." .. node._decl.name] then
            -- Same-module nominal static: read its canonical closure directly.
            return "", getslot(node._type, nil, render("&_mod->uv[$SLOT].uv", {
                SLOT = c_integer_literal(
                    ctx.tlcontext.static_slots[node._decl.fqtn .. "." .. node._decl.name]),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and node._alias_namespace then
            -- A type alias preserves the nominal owner's static namespace; it
            -- does not manufacture a closure slot in the facade. Recover the
            -- initialized owner module from Titan's registry and index its
            -- ordinary ABI-visible static prefix.
            assert(node._decl._closure_upvalue ~= nil,
                "aliased public static lacks an owner prefix slot")
            local owner = coder._nominal_owner_module_expr(
                ctx, node._decl.fqtn)
            return "", getslot(node._type, nil, render(
                "&(($OWNER)->uv[$FNINDEX].uv)", {
                OWNER = owner,
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
            }))
        elseif node._decl._tag == "Type.StaticMethod"
               and node._import_decl then
            -- Imported nominal static: both modules reconstruct the ABI-visible
            -- canonical-closure prefix, so no namespace-table lookup or fresh
            -- closure is needed.
            return "", getslot(node._type, nil, render(
                "&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$FNINDEX].uv)", {
                MODINDEX = c_integer_literal(node._import_decl._upvalue),
                FNINDEX = c_integer_literal(node._decl._closure_upvalue),
            }))
        else
            assert(node._decl._tag == "Type.ModuleVariable")
            ctx.variables[node.exp.var.name .. "." .. node.name] = {
                module = node.exp.var.name,
                name = node.name,
                slot = node._decl._slot
            }
            local slot = render("&(uvalue(&_mod->uv[$MODINDEX].uv)->uv[$VARINDEX].uv)", {
                MODINDEX = c_integer_literal(node.exp.var._decl._upvalue),
                VARINDEX = c_integer_literal(node._decl._upvalue)
            })
            return "", getslot(node._type, nil, slot)
        end
    elseif node._decl._tag == "Ast.TopLevelVar" then
        return "", getslot(node._type, nil, node._decl._slot)
    elseif node._decl._tag == "Ast.TopLevelFunc" then
        -- Reference to a top-level function as a first-class value: read its
        -- canonical closure from the shadow upvalue slot, boxed as a TValue.
        return "", getslot(node._type, nil, render("&_mod->uv[$SLOT].uv", {
            SLOT = c_integer_literal(node._decl._closure_upvalue)
        }))
    elseif ctx.captures and ctx.captures[node._decl] then
        -- Inside a lambda body: the variable is captured from an enclosing
        -- function and lives in this closure's upvalues (read via _fn). A boxed
        -- capture is read through its box; a by-value capture directly.
        local cap = ctx.captures[node._decl]
        if cap.boxed then
            return "", box_read(node._type, cap.boxvar)
        else
            return "", getslot(node._type, nil,
                "&_fn->upvalue[" .. c_integer_literal(cap.index) .. "]")
        end
    elseif node._decl._boxed then
        -- Captured-and-mutated local/param of the current function: read through
        -- its box cell.
        return "", box_read(node._type, node._decl._box)
    else
        return "", node._decl._cvar
    end
end

function codevalue(ctx, node, target)
    local tag = node._tag
    if tag == "Ast.ExpNil" then
        return "", "0"
    elseif tag == "Ast.ExpBool" then
        return "", node.value and "1" or "0"
    elseif tag == "Ast.ExpInteger" then
        return "", c_integer_literal(node.value)
    elseif tag == "Ast.ExpFloat" then
        return "", c_float_literal(node.value)
    elseif tag == "Ast.ExpString" then
        return makestring(ctx, c_string_literal(node.value), target,
            tostring(#node.value))
    else
        error("invalid tag for a literal value: " .. tag)
    end
end

-- Materialize the position stream shared by dense Array and positional
-- integer-Map constructors.  Values are evaluated and converted once in source
-- order before either representation is allocated.  Fixed positions are held
-- in scanned slots; a sole open producer remains as a typed result-run view
-- whose elements the representation-specific fill loop converts in order.
function coder._materialize_positional_inputs(ctx, node, elemtype)
    local stats, slots, discarded = {}, {}, {}
    local openrun
    local adjustment = assert(
        node._positional_adjustment or node._array_adjustment,
        "positional constructor lacks checker adjustment")
    for _, exp in ipairs(adjustment.discards) do
        discarded[exp] = true
    end

    local nfields = #node.fields
    local dots_tail = nfields > 0
        and node.fields[nfields].exp._tag == "Ast.ExpDots"
    local nprefix = dots_tail and nfields - 1 or nfields
    if adjustment.open_source then
        local astats, _, tailnames, run = coder._codeadjustedopen(
            ctx, adjustment, "LUA_MULTRET", "1")
        for _, stat in ipairs(astats) do table.insert(stats, stat) end
        for _, name in ipairs(tailnames) do
            local slot = slotat(reserveslot(ctx))
            table.insert(stats, setslot(elemtype, slot, name))
            table.insert(slots, slot)
        end
        openrun = run
    else
        for i = 1, nprefix do
            local exp = node.fields[i].exp
            local cstats, cexp = codeexp(ctx, exp)
            if discarded[exp] then
                table.insert(stats, cstats)
                table.insert(stats, "(void)(" .. cexp .. ");")
            else
                local ctmpe, tmpename, tmpeslot =
                    newtmp(ctx, elemtype, true)
                table.insert(stats, render([[
                    $CSTATS
                    $CTMPE
                    $TMPENAME = $CEXP;
                    $SETSLOT
                ]], {
                    CSTATS = cstats,
                    CTMPE = ctmpe,
                    TMPENAME = tmpename,
                    CEXP = cexp,
                    SETSLOT = setslot(elemtype, tmpeslot, tmpename),
                }))
                table.insert(slots, tmpeslot)
            end
        end
    end
    return stats, slots, openrun
end

function codearray(ctx, node, target)
    -- Always build the Array in a scanned stack slot. A target such as a
    -- module-global upvalue is not necessarily remembered until the caller's
    -- post-expression barrier, while constructor/open-run work can allocate.
    -- The caller copies this rooted result into its final owner afterward.
    local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    local inputstats, slots, openrun =
        coder._materialize_positional_inputs(ctx, node, node._type.elem)
    local stats = {}
    -- Keep the C temporary in the constructor's outer scope. Runtime-sized
    -- constructors perform allocation and filling in an inner block, but the
    -- expression result is consumed after that block.
    table.insert(stats, ctmp)
    for _, stat in ipairs(inputstats) do table.insert(stats, stat) end
    ctx.uses_base_off = true
    local elemtype = node._type.elem
    local writer_elem = assert(node._array_element_type,
        "Array construction lacks its normalized checker element type")
    assert(types.equals(writer_elem, types.normalize(elemtype)),
        "Array construction writer element disagrees with final Array type")
    local writer = coder._array_writer(
        ctx, writer_elem, node._array_writer_plan)
    local function initarray(capacity)
        return render([[
            $TMPNAME = titan_array_new(
                L, $META, $CAPACITY, &_mod->uv[$WRITER].uv);
            _base = restorestack(L, _base_off);
            sethvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
            META = array_metatable(ctx),
            CAPACITY = capacity,
            WRITER = c_integer_literal(writer.slot),
        })
    end
    local nstored = #slots
    if openrun then
        -- Runtime-sized array build. The vararg elements are already anchored
        -- upstream (§2.D) and the GC is non-moving, so reading `args[]` across the
        -- resize is safe -- no pre-copy needed; this is the case-3 forward copy
        -- (§5.7) plus the table back barrier on each store. The prefix temps are
        -- on reserved stack slots, so they too survive the resize-GC.
        -- Drive the backing-struct typedef and the `args[]` stride/read off the
        -- REAL vararg element type (`va.elem`) -- the struct the callee actually
        -- allocated. The array's declared element type (`elemtype`) may differ
        -- (the checker §4.7 lets a context override it, e.g. `{...integer}` in a
        -- `{float}` context); casting the buffer to the array-element struct would
        -- bit-reinterpret a 8-byte `lua_Integer` slot as a 8-byte `lua_Number` or
        -- read 16-byte `TValue`s out of the smaller buffer. Convert each element
        -- from `va.elem` to `elemtype` before storing (the checker has proven it
        -- coerceable; identical types convert to a verbatim copy).
        -- `luaH_resizearray` -> `luaM_reallocvector` can GC, which may shrink and
        -- relocate the Lua stack (`luaD_shrinkstack`), dangling the raw `_base`
        -- pointer. Save it as an offset and recompute it after the resize so
        -- the prefix-slot reads and `obj2arr` stores below use
        -- the live stack. The preamble declares `_base_off` when uses_base_off.
        ctx.uses_base_off = true
        -- A reusable TValue scratch to wrap each vararg element before `obj2arr`
        -- (which takes a `TValue *`); for value/option/function the converted
        -- element already IS a TValue and `setwrapped` copies it verbatim.
        local vslot = "_vaslot_" .. ctx.tmp
        ctx.tmp = ctx.tmp + 1
        local barrier = types.is_gc(elemtype) and render([[
            luaC_barrierback(L, obj2gco($TMPNAME), &$VSLOT);
        ]], { TMPNAME = tmpname, VSLOT = vslot }) or ""
        -- The per-element store consumes the checker's open adjustment. Equal
        -- types copy directly; every other accepted edge is lowered by the
        -- plan-aware conversion helper.
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, elemtype, "_vj", node.loc)
        local element_store = render([[
            $CONVSTATS
            $SETWRAPPED
        ]], {
            CONVSTATS = convstats,
            SETWRAPPED = setslot(elemtype, "&" .. vslot, convexp),
        })
        table.insert(stats, render([[
            {
                int _vacount = $RUNCOUNT;
                $INITARRAY
                $PREFIX_STORES
                /* zero-init: a boolean store sets only the tag (booleans carry
                 * no payload), but obj2arr copies value_ too — leaving it
                 * undefined would warn under -Wmaybe-uninitialized / break
                 * -Werror. */
                TValue $VSLOT = {0};
                for (int _vj = 0; _vj < _vacount; _vj++) {
                    $SETWRAPPED
                    obj2arr($TMPNAME, $NPREFIX + _vj, &$VSLOT);
                    $BARRIER
                }
                unsigned _array_length =
                    cast_uint($NPREFIX + _vacount);
                while (_array_length > 0 &&
                       tagisempty(*getArrTag($TMPNAME,
                                            _array_length - 1u)))
                    _array_length--;
                titan_array_set_length($TMPNAME, _array_length);
                $CLEANUP
            }
        ]], {
            RUNCOUNT = openrun.count,
            TMPNAME = tmpname,
            NPREFIX = c_integer_literal(nstored),
            INITARRAY = initarray(render([[
                ((lua_Unsigned)$NPREFIX + (lua_Unsigned)_vacount)
            ]], {
                NPREFIX = c_integer_literal(nstored),
            })),
            VSLOT = vslot,
            SETWRAPPED = element_store,
            BARRIER = barrier,
            CLEANUP = coder._cleanup_result_run(openrun),
            PREFIX_STORES = (function()
                local ps = {}
                for i = 1, nstored do
                    local slot = slots[i]
                    table.insert(ps, render([[
                        obj2arr($TMPNAME, $INDEX, $SLOT);
                    ]], { TMPNAME = tmpname, INDEX = c_integer_literal(i - 1), SLOT = slot }))
                    if types.is_gc(elemtype) then
                        table.insert(ps, render([[
                            luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
                        ]], { TMPNAME = tmpname, SLOT = slot }))
                    end
                end
                return table.concat(ps, "\n")
            end)(),
        }))
        return table.concat(stats, "\n"), tmpname
    end
    table.insert(stats, initarray(c_integer_literal(nstored)))
    for i, slot in ipairs(slots) do
        table.insert(stats, render([[
            obj2arr($TMPNAME, $INDEX, $SLOT);
        ]], {
            TMPNAME = tmpname,
            INDEX = i-1,
            SLOT = slot
        }))
        if types.is_gc(elemtype) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
            ]], {
                TMPNAME = tmpname,
                SLOT = slot,
            }))
        end
    end
    table.insert(stats, render([[
        {
            unsigned _array_length = $SIZE;
            while (_array_length > 0 &&
                   tagisempty(*getArrTag($TMPNAME, _array_length - 1u)))
                _array_length--;
            titan_array_set_length($TMPNAME, _array_length);
        }
    ]], {
        SIZE = c_integer_literal(nstored),
        TMPNAME = tmpname,
    }))
    return table.concat(stats, "\n"), tmpname
end

function coder._codepositionalmap(ctx, node, target)
    local valuetype = node._type.values
    local inputstats, slots, openrun =
        coder._materialize_positional_inputs(ctx, node, valuetype)
    local ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end

    local stats = { ctmp }
    for _, stat in ipairs(inputstats) do table.insert(stats, stat) end
    ctx.uses_base_off = true

    local function initmap(count)
        return render([[
            if (TITAN_UNLIKELY((lua_Unsigned)($COUNT) >
                               (lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY)) {
                luaL_error(L, "positional map is too large");
            }
            $TMPNAME = luaH_new(L);
            _base = restorestack(L, _base_off);
            sethvalue(L, $TMPSLOT, $TMPNAME);
            luaH_resizearray(L, $TMPNAME, cast_uint($COUNT));
            _base = restorestack(L, _base_off);
        ]], {
            COUNT = count,
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
        })
    end

    local function fixedstores()
        local stores = {}
        for i, slot in ipairs(slots) do
            table.insert(stores, render([[
                {
                    TValue _map_value = {0};
                    $BOX
                    obj2arr($TMPNAME, $INDEX, &_map_value);
                    $BARRIER
                }
            ]], {
                BOX = setboxed(ctx, valuetype, "&_map_value",
                    getslot(valuetype, nil, slot)),
                TMPNAME = tmpname,
                INDEX = c_integer_literal(i - 1),
                BARRIER = types.is_gc(valuetype)
                    and render([[
                        luaC_barrierback(L, obj2gco($TMPNAME),
                                         &_map_value);
                    ]], { TMPNAME = tmpname })
                    or "",
            }))
        end
        return table.concat(stores, "\n")
    end

    if openrun then
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, valuetype, "_mi", node.loc)
        table.insert(stats, render([[
            {
                int _map_open_count = $RUNCOUNT;
                lua_Unsigned _map_count =
                    (lua_Unsigned)$NPREFIX +
                    (lua_Unsigned)_map_open_count;
                $INITMAP
                $FIXEDSTORES
                TValue _map_value = {0};
                for (int _mi = 0; _mi < _map_open_count; _mi++) {
                    $CONVSTATS
                    $BOX
                    obj2arr($TMPNAME, $NPREFIX + _mi, &_map_value);
                    $BARRIER
                }
                $CLEANUP
            }
        ]], {
            RUNCOUNT = openrun.count,
            NPREFIX = c_integer_literal(#slots),
            INITMAP = initmap("_map_count"),
            FIXEDSTORES = fixedstores(),
            CONVSTATS = convstats,
            BOX = setboxed(ctx, valuetype, "&_map_value", convexp),
            TMPNAME = tmpname,
            BARRIER = types.is_gc(valuetype)
                and render([[
                    luaC_barrierback(L, obj2gco($TMPNAME), &_map_value);
                ]], { TMPNAME = tmpname })
                or "",
            CLEANUP = coder._cleanup_result_run(openrun),
        }))
    else
        table.insert(stats, initmap(c_integer_literal(#slots)))
        table.insert(stats, fixedstores())
    end
    return table.concat(stats, "\n"), tmpname
end

function codemap(ctx, node, target)
    if node._positional_adjustment then
        return coder._codepositionalmap(ctx, node, target)
    end
    local stats = {}
    local cinit, ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        -- always build the map anchored in a stack slot (see codearray)
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end
    cinit = render([[
        $CTMP
        $TMPNAME = luaH_new(L);
        sethvalue(L, $TMPSLOT, $TMPNAME);
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
    })
    table.insert(stats, cinit)
    local slots = {}
    for _, field in ipairs(node.fields) do
        local kexp = field.name
        local ckstats, ckexp = codeexp(ctx, kexp)
        local ctmpk, tmpkname, tmpkslot = newtmp(ctx, node._type.keys, true)

        local vexp = field.exp
        local cvstats, cvexp = codeexp(ctx, vexp)
        local ctmpv, tmpvname, tmpvslot = newtmp(ctx, node._type.values, true)

        local code = render([[
            $CKSTATS
            $CTMPK
            $TMPKNAME = $CKEXP;
            $SETSLOTK

            $CVSTATS
            $CTMPV
            $TMPVNAME = $CVEXP;
            $SETSLOTV
        ]], {
            CKSTATS = ckstats,
            CTMPK = ctmpk,
            TMPKNAME = tmpkname,
            CKEXP = ckexp,
            SETSLOTK = setboxed(ctx, node._type.keys, tmpkslot, tmpkname),

            CVSTATS = cvstats,
            CTMPV = ctmpv,
            TMPVNAME = tmpvname,
            CVEXP = cvexp,
            SETSLOTV = setboxed(ctx, node._type.values, tmpvslot, tmpvname),
        })

        table.insert(slots, { k = tmpkslot, v = tmpvslot })
        table.insert(stats, code)
    end
    for _, slot in ipairs(slots) do
        table.insert(stats, render([[
            {
                $STORE
            }
        ]], {
            STORE = set_table_entry(node._type.keys, tmpname, slot.k, slot.v),
        }))
        if types.is_gc(node._type.values) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOTV);
            ]], {
                TMPNAME = tmpname,
                SLOTV = slot.v,
            }))
        end
    end
    return table.concat(stats, "\n"), tmpname
end

function coderecord(ctx, node, target)
    local stats = {}
    local cinit, ctmp, tmpname, tmpslot
    local record = types.registry[node._type.fqtn]
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end
    -- The record value IS the Udata: one allocation, fields in user values
    -- uv[0..N-1] (0-based), type identity is the udata's metatable (no raw
    -- payload), metatable straight on the udata. luaS_newudata returns the
    -- object already nil-filled and white, and we anchor it via setuvalue
    -- immediately, so the half-built record is reachable before any field is
    -- evaluated; each gc field store uses the back barrier to keep it honest.
    cinit = render([[
        $CTMP
        $TMPNAME = luaS_newudata(L, 0, $NUSERVALUES);
        $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
        setuvalue(L, $TMPSLOT, $TMPNAME);
    ]], {
        CTMP = ctmp,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        NUSERVALUES = record.nfields or #record.fields,
        META = c_integer_literal(type2metatable(ctx, node._type))
    })
    table.insert(stats, cinit)
    for _, field in ipairs(node.fields) do
        local exp = field.exp
        local cstats, cexp = codeexp(ctx, exp)
        local ctmpe, tmpename, tmpeslot = newtmp(ctx, field._field.type, true)
        local code = render([[
            $CSTATS
            $CTMPE
            $TMPENAME = $CEXP;
            $SETSLOT;
            setobj2t(L, &($RECORD->uv[$INDEX].uv), $SLOT);
        ]], {
            CSTATS = cstats,
            CTMPE = ctmpe,
            TMPENAME = tmpename,
            CEXP = cexp,
            SETSLOT = setslot(field._field.type, tmpeslot, tmpename),
            SLOT = tmpeslot,
            RECORD = tmpname,
            INDEX = field._field.index
        })
        table.insert(stats, code)
        if types.is_gc(field._field.type) then
            table.insert(stats, render([[
                luaC_barrierback(L, obj2gco($TMPNAME), $SLOT);
            ]], {
                TMPNAME = tmpname,
                SLOT = tmpeslot,
            }))
        end
    end
    return table.concat(stats, "\n"), tmpname
end

-- Lower the internal expression synthesized for one union-variant
-- constructor. The union userdata is rooted immediately; its absolute tag and
-- opaque payload then use ordinary internal TValue slots.
function coder._codeunioninit(ctx, node, target)
    local union = assert(node._union)
    local variant = assert(node._variant)
    assert(union._tag == "Type.Union" and variant._tag == "Type.Variant")
    assert(node._type._tag == "Type.Nominal"
        and node._type.fqtn == union.name)

    local ctmp, tmpname, tmpslot
    if target and target._cvar then
        ctmp, tmpname, tmpslot = "", target._cvar, target._slot
    else
        ctmp, tmpname, tmpslot = newtmp(ctx, node._type, true)
    end

    local stats = {
        render([[
            $CTMP
            $TMPNAME = luaS_newudata(L, 0, $NUSERVALUES);
            $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
            setuvalue(L, $TMPSLOT, $TMPNAME);
            setivalue(&$TMPNAME->uv[0].uv, $TAG);
        ]], {
            CTMP = ctmp,
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
            NUSERVALUES = variant.payload == false and "1" or "2",
            META = c_integer_literal(type2metatable(ctx, node._type)),
            TAG = c_integer_literal(variant.index),
        }),
    }

    if variant.payload ~= false then
        assert(node.value and node.value ~= false,
            "payload variant initializer has no value")
        local cstats, cexp = codeexp(ctx, node.value)
        local payloadslot = "&" .. tmpname .. "->uv[1].uv"
        table.insert(stats, render([[
            $CSTATS
            $SETSLOT
            $BARRIER
        ]], {
            CSTATS = cstats,
            SETSLOT = setslot(variant.payload, payloadslot, cexp),
            BARRIER = types.is_gc(variant.payload)
                and render("luaC_barrierback(L, obj2gco($UNION), $SLOT);", {
                    UNION = tmpname,
                    SLOT = payloadslot,
                }) or "",
        }))
    else
        assert(node.value == false or node.value == nil,
            "empty variant initializer unexpectedly has a value")
    end

    return table.concat(stats, "\n"), tmpname
end

function coder._freeze_c_operator_operand(ctx, exp, target)
    local cstats, cexp
    if exp._type._tag == "Type.Nil" then
        -- A nil-producing call can keep its effect in the expression half
        -- rather than in `stats`; the generic native-to-foreign bridge quite
        -- correctly replaces the value with NULL, but would then discard that
        -- expression.  Evaluate it explicitly before materializing the
        -- target-typed null constant.
        cstats, cexp = codeexp(ctx, exp)
        cstats = cstats .. "\n(void)(" .. cexp .. ");"
        cexp = "0"
    else
        -- The checker-owned C-operator trait, not an assignment relation on
        -- the operand AST, selects `target`. First recover the operand's raw
        -- C representation without asking the generic native-to-foreign
        -- bridge to authorize that distinct target; the checked numeric path
        -- below and the final explicit C cast then consume the trait.
        cstats, cexp = codeforeignexp(ctx, exp)
    end
    if coder._is_numeric_type(exp._type)
       and coder._is_numeric_type(target)
       and not types.equals(
            coder._resolve_cast_type(exp._type),
            coder._resolve_cast_type(target)) then
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, exp._type, target, cexp, exp.loc, "c_operator")
        cstats = cstats .. nstats
        cexp = nexp
    end
    local cdecl, cname = newforeigntmp(ctx, target)
    return render([[
        $CSTATS
        $CDECL
        $CNAME = $CAST;
    ]], {
        CSTATS = cstats,
        CDECL = cdecl,
        CNAME = cname,
        CAST = foreigncast(cexp, target),
    }), cname
end

function coder._code_c_unary_operator(ctx, node)
    local trait = assert(node._c_operator)
    local stats, operand = coder._freeze_c_operator_operand(
        ctx, node.exp, trait.lhs_target)
    return stats, "(" .. trait.cop .. operand .. ")"
end

function coder._code_c_binary_operator(ctx, node)
    local trait = assert(node._c_operator)
    -- Always freeze both sides.  Besides preserving Titan's left-to-right
    -- evaluation rule for two raw C calls, this makes array decay happen into
    -- the selected pointer temporary rather than ever attempting an array
    -- temporary assignment.
    local lstats, lhs = coder._freeze_c_operator_operand(
        ctx, node.lhs, trait.lhs_target)
    local rstats, rhs = coder._freeze_c_operator_operand(
        ctx, node.rhs, trait.rhs_target)
    local expression =
        "(" .. lhs .. " " .. trait.cop .. " " .. rhs .. ")"
    local ltarget = types.resolve_c_typedef(trait.lhs_target)
    local rtarget = types.resolve_c_typedef(trait.rhs_target)
    if node._type._tag == "Type.Integer"
       and ltarget and rtarget
       and ltarget._tag == "Type.CPointer"
       and rtarget._tag == "Type.CPointer"
       and trait.cop == "-" then
        assert(trait.result_source,
            "C pointer subtraction lacks its checker-owned ptrdiff_t type")
        local cstats, cexp = coder._code_checked_numeric_cast(
            ctx, trait.result_source, node._type,
            expression, node.loc, "boundary")
        return lstats .. "\n" .. rstats .. "\n" .. cstats, cexp
    end
    return lstats .. "\n" .. rstats, expression
end

function codeunaryop(ctx, node, iscondition)
    if node._c_operator then
        return coder._code_c_unary_operator(ctx, node)
    end
    local op = node.op
    if op == "not" then
        local estats, ecode = codeexp(ctx, node.exp, iscondition)
        return estats, "!(" .. ecode .. ")"
    elseif op == "#" then
        local estats, ecode = codeexp(ctx, node.exp)
        local etype = types.resolve_c_typedef(node.exp._type)
        if node._c_fam_access then
            local access = node._c_fam_access
            if access.kind == "automatic" then
                return estats, c_integer_literal(access.count)
            end
            local owner_node = assert(node.exp.var).exp
            local owner_stats, owner_exp = codeexp(ctx, owner_node)
            local owner_decl, owner_name = newtmp(ctx, owner_node._type)
            return render([[
                $STATS
                $DECL
                $OWNER = $EXP;
            ]], {
                STATS = owner_stats,
                DECL = owner_decl,
                OWNER = owner_name,
                EXP = owner_exp,
            }), "ivalue(&" .. owner_name .. "->uv[0].uv)"
        elseif node.exp._type._tag == "Type.Array" then
            return estats, "((lua_Integer)titan_array_length(" .. ecode .. "))"
        elseif node.exp._type._tag == "Type.Map" then
            assert(types.equals(node.exp._type.keys, types.Integer()))
            return estats, "l_castU2S(luaH_getn(L, " .. ecode .. "))"
        elseif etype._tag == "Type.CArray" then
            return estats, c_integer_literal(etype.len)
        elseif etype._tag == "Type.COwned" and etype.count then
            return estats, render("((lua_Integer)($OWNER->len / sizeof($CT)))", {
                OWNER = ecode,
                CT = coder._render_c_declaration(etype.pointee, ""),
            })
        else
            return estats, "tsslen(" .. ecode .. ")"
        end
    elseif op == "-" and node.exp._type._tag == "Type.Integer" then
        -- Integer negation wraps two's-complement like Lua (intop(-,0,x));
        -- raw (-x) is signed-overflow UB for math.mininteger.
        local estats, ecode = codeexp(ctx, node.exp)
        return estats, "intop(-, 0, " .. ecode .. ")"
    else
        local estats, ecode = codeexp(ctx, node.exp)
        return estats, "(" .. op .. ecode .. ")"
    end
end

-- In Lua and Titan, the shift amount in a bitshift can be any integer, but in
-- C shift amount must be a positive number less than the width of the integer
-- type being shifted. This means that we need some if statements to implement
-- the Lua shift semantics in C.
--
-- Most of the time, the shift amount should be a constant, which will allow the
-- C compiler to eliminate all of these branches as dead code and generate code that is
-- just as good as a raw C bitshift without the extra Lua semantics.
--
-- For the dynamic case, we gain a bit of performance (~20%) compared to the
-- algorithm in luaV_shiftl by reordering the branches to put the common case
-- (shift amount is a small positive integer) under only one level of branching
-- and with a TITAN_LIKELY annotation.
ordered_binary_operands = nil

function generate_binop_shift(shift_pos, shift_neg, exp, ctx)
    local x_stats, x_code = codeexp(ctx, exp.lhs)
    local y_stats, y_code = codeexp(ctx, exp.rhs)
    local xdecl, x_var = newtmp(ctx, types.Integer())
    local ydecl, y_var = newtmp(ctx, types.Integer())
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${X_STATS}
        ${X_DECL}
        ${X} = ${X_CODE};
        ${Y_STATS}
        ${Y_DECL}
        ${Y} = ${Y_CODE};
        ${R_DECL}
        if (TITAN_LIKELY(l_castS2U(${Y}) < TITAN_LUAINTEGER_NBITS)) {
            ${R} = intop(${SHIFT_POS}, ${X}, ${Y});
        } else {
            if (l_castS2U(intop(-, 0, ${Y})) < TITAN_LUAINTEGER_NBITS) {
                ${R} = intop(${SHIFT_NEG}, ${X}, intop(-, 0, ${Y}));
            } else {
                ${R} = 0;
            }
        }
    ]], {
        SHIFT_POS = shift_pos,
        SHIFT_NEG = shift_neg,
        X = x_var,
        X_DECL = xdecl,
        X_CODE = x_code,
        X_STATS = x_stats,
        Y = y_var,
        Y_DECL = ydecl,
        Y_CODE = y_code,
        Y_STATS = y_stats,
        R = rname,
        R_DECL = rdecl,
    })
    return cstats, rname
end

-- Lua/Titan integer division rounds to negative infinity instead of towards
-- zero. We inline luaV_div here to give the C compiler more optimization
-- opportunities (see that function for comments on how it works).
function generate_binop_idiv_int(exp, ctx)
    local m_stats, m_code = codeexp(ctx, exp.lhs)
    local n_stats, n_code = codeexp(ctx, exp.rhs)
    local mdecl, m_var = newtmp(ctx, types.Integer())
    local ndecl, n_var = newtmp(ctx, types.Integer())
    local qdecl, qname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${M_STATS}
        ${M_DECL}
        ${M} = ${M_CODE};
        ${N_STATS}
        ${N_DECL}
        ${N} = ${N_CODE};
        ${Q_DECL}
        if (l_castS2U(${N}) + 1u <= 1u) {
            if (${N} == 0){
                $THROW_DIV0
            } else {
                ${Q} = intop(-, 0, ${M});
            }
        } else {
            ${Q} = ${M} / ${N};
            if ((${M} ^ ${N}) < 0 && ${M} % ${N} != 0) {
                ${Q} -= 1;
            }
        }
    ]], {
        M = m_var,
        M_DECL = mdecl,
        M_CODE = m_code,
        M_STATS = m_stats,
        N = n_var,
        N_DECL = ndecl,
        N_CODE = n_code,
        N_STATS = n_stats,
        Q = qname,
        Q_DECL = qdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_DIV0 = codethrow(exp.loc, "error at line %d, divide by zero", { "$LINE" })
    })
    return cstats, qname
end

-- see luai_numidiv
function generate_binop_idiv_flt(exp, ctx)
    local stats, x_var, y_var = ordered_binary_operands(ctx, exp)
    local rdecl, rname = newtmp(ctx, exp._type)
    local cstats = util.render([[
        ${STATS}
        ${R_DECL}
        ${R_NAME} = floor(${X} / ${Y});
    ]], {
        X = x_var,
        Y = y_var,
        STATS = stats,
        R_DECL = rdecl,
        R_NAME = rname,
    })
    return cstats, rname
end

-- Lua/Titan guarantees that (m == n*(m//n) + (,%n))
-- See generate binop_intdiv and luaV_mod
function generate_binop_mod_int(exp, ctx)
    local m_stats, m_code = codeexp(ctx, exp.lhs)
    local n_stats, n_code = codeexp(ctx, exp.rhs)
    local mdecl, m_var = newtmp(ctx, types.Integer())
    local ndecl, n_var = newtmp(ctx, types.Integer())
    local rdecl, rname = newtmp(ctx, types.Integer())
    local cstats = util.render([[
        ${M_STATS}
        ${M_DECL}
        ${M} = ${M_CODE};
        ${N_STATS}
        ${N_DECL}
        ${N} = ${N_CODE};
        ${R_DECL};
        if (l_castS2U(${N}) + 1u <= 1u) {
            if (${N} == 0){
                $THROW_MOD0
            } else {
                ${R} = 0;
            }
        } else {
            ${R} = ${M} % ${N};
            if (${R} != 0 && (${M} ^ ${N}) < 0) {
                ${R} += ${N};
            }
        }
    ]], {
        M = m_var,
        M_DECL = mdecl,
        M_CODE = m_code,
        M_STATS = m_stats,
        N = n_var,
        N_DECL = ndecl,
        N_CODE = n_code,
        N_STATS = n_stats,
        R = rname,
        R_DECL = rdecl,
        LINE = c_integer_literal(exp.loc.line),
        THROW_MOD0 = codethrow(exp.loc, "error at line %d, %% by zero", { "$LINE" })
    })
    return cstats, rname
end

-- Float modulo, faithful to Lua's luai_nummod (see lvm.c/llimits.h):
--   m = fmod(a, b); if ((m>0) ? b<0 : (m<0 && b!=0)) m += b;
-- This differs from C's fmod for operands of opposite sign, where Lua
-- (like floored division) returns a result with the sign of the divisor.
function generate_binop_mod_flt(exp, ctx)
    local stats, m_var, n_var = ordered_binary_operands(ctx, exp)
    local bdecl, bname = newtmp(ctx, types.Float())
    local rdecl, rname = newtmp(ctx, types.Float())
    local cstats = util.render([[
        ${STATS}
        ${B_DECL};
        ${R_DECL};
        ${B} = ${N};
        ${R} = fmod(${M}, ${B});
        if (((${R}) > 0) ? ((${B}) < 0) : (((${R}) < 0) && ((${B}) > 0))) {
            ${R} += ${B};
        }
    ]], {
        M = m_var,
        N = n_var,
        STATS = stats,
        B = bname,
        B_DECL = bdecl,
        R = rname,
        R_DECL = rdecl,
    })
    return cstats, rname
end

-- Preserve Titan/Lua's left-to-right operand evaluation. If preparing the RHS
-- emits statements, freeze the LHS first; otherwise those statements could
-- mutate state that a deferred LHS expression still reads.
ordered_binary_operands = function(ctx, node)
    local lstats, lcode = codeexp(ctx, node.lhs)
    local rstats, rcode = codeexp(ctx, node.rhs)
    if rstats == "" then
        return lstats, lcode, rcode
    end
    local ldecl, lname, lslot =
        newtmp(ctx, node.lhs._type, types.is_gc(node.lhs._type))
    local anchor = lslot and setslot(node.lhs._type, lslot, lname) or ""
    return render([[
        $LSTATS
        $LDECL
        $LNAME = $LCODE;
        $ANCHOR
        $RSTATS
    ]], {
        LSTATS = lstats,
        LDECL = ldecl,
        LNAME = lname,
        LCODE = lcode,
        ANCHOR = anchor,
        RSTATS = rstats,
    }), lname, rcode
end

function codebinaryop(ctx, node, _)
    if node._c_operator then
        return coder._code_c_binary_operator(ctx, node)
    end
    local op = node.op
    if op == "~=" then op = "!=" end
    local comparison
    if op == "==" or op == "!=" then
        local plan = node._comparison
        local function original_operand_type(exp, adjustment, side)
            if not adjustment then return exp._type end
            assert(exp._tag == "Ast.ExpCast"
                   and exp._adjustment == adjustment,
                "equality " .. side
                    .. " operand lost its ComparisonPlan adjustment")
            assert(exp.exp
                   and types.equals(
                       types.normalize(exp.exp._type),
                       types.normalize(adjustment.source)),
                "equality " .. side
                    .. " operand has the wrong original type")
            assert(types.equals(exp._type, adjustment.target),
                "equality " .. side
                    .. " operand has the wrong adjusted type")
            return adjustment.source
        end
        comparison = coder._checked_comparison_plan(
            plan,
            original_operand_type(
                node.lhs, plan and plan.left_adjustment, "left"),
            original_operand_type(
                node.rhs, plan and plan.right_adjustment, "right"),
            "equality comparison")
    end
    if op == "and" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local rdecl, rname = newtmp(ctx, types.Boolean())
            return render([[
                $LSTATS
                $RDECL
                if (!$LCODE) {
                    $RNAME = 0;
                } else {
                    $RSTATS
                    $RNAME = $RCODE;
                }
            ]], {
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                RDECL = rdecl,
                RNAME = rname,
            }), rname
        elseif types.is_truthy(node.lhs._type) then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. "\n((void)" .. lcode .. ");\n" .. rstats, rcode
        elseif types.is_falsy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        else
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            local code = render([[
                $LSTATS
                $CTMP
                if(!($COND)) {
                    setnilvalue(&$TMPNAME);
                } else {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                COND = toboolean(node.lhs._type, lcode),
                LSTATS = lstats,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
            })
            return code, tmpname
        end
    elseif op == "or" then
        if node._type._tag == "Type.Boolean" then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local rdecl, rname = newtmp(ctx, types.Boolean())
            return render([[
                $LSTATS
                $RDECL
                if ($LCODE) {
                    $RNAME = 1;
                } else {
                    $RSTATS
                    $RNAME = $RCODE;
                }
            ]], {
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                RDECL = rdecl,
                RNAME = rname,
            }), rname
        elseif types.is_truthy(node.lhs._type) then
            local lstats, lcode = codeexp(ctx, node.lhs)
            return lstats, lcode
        elseif types.is_falsy(node.lhs._type) then
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = codeexp(ctx, node.rhs)
            return lstats .. "\n((void)" .. lcode .. ");\n" .. rstats, rcode
        elseif node.lhs._type._tag == "Type.Option" then
            assert(types.equals(node.lhs._type.base, node.rhs._type))
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, node._type, types.is_gc(node._type))
            local tmpset = types.is_gc(node._type) and setslot(node._type, tmpslot, tmpname) or ""
            local code = render([[
                $LSTATS
                $CTMP
                if(!($COND)) {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                } else {
                    $GETL;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                COND = toboolean(node.lhs._type, lcode),
                LSTATS = lstats,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
                GETL = getslot(node._type, tmpname, "&" .. lcode),
            })
            return code, tmpname
        else
            assert(node._type._tag == "Type.Value")
            local lstats, lcode = materialize(ctx, node.lhs)
            local rstats, rcode = materialize(ctx, node.rhs)
            local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
            local tmpset = setslot(types.Value(), tmpslot, tmpname)
            local code = render([[
                $LSTATS
                $CTMP
                $TMPNAME = $LCODE;
                if(l_isfalse(&$TMPNAME)) {
                    $RSTATS;
                    $TMPNAME = $RCODE;
                }
                $TMPSET;
            ]], {
                CTMP = ctmp,
                TMPNAME = tmpname,
                LSTATS = lstats,
                LCODE = lcode,
                RSTATS = rstats,
                RCODE = rcode,
                TMPSET = tmpset,
            })
            return code, tmpname
        end
    elseif op == "^" then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        local bdecl, bname = newtmp(ctx, types.Float())
        local edecl, ename = newtmp(ctx, types.Float())
        local cstats = render([[
            $STATS
            $BDECL
            $EDECL
            $B = $LCODE;
            $E = $RCODE;
        ]], { STATS=stats, BDECL=bdecl, EDECL=edecl,
              B=bname, E=ename, LCODE=lcode, RCODE=rcode })
        -- luai_numpow: exponent 2 is a*a, not pow(a,2) (differs by 1 ULP).
        return cstats, "((" .. ename .. " == 2) ? (" .. bname .. " * " .. bname
                       .. ") : pow(" .. bname .. ", " .. ename .. "))"
    elseif op == "~" then
        -- Lua's binary '~' is bitwise exclusive-or; C's binary xor is '^'
        -- (Titan's '^' is exponentiation). Wrap like Lua's intop(^,...).
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "intop(^, " .. lcode .. ", " .. rcode .. ")"
    elseif op == "<<" then
        return generate_binop_shift("<<", ">>", node, ctx)
    elseif op == ">>" then
        return generate_binop_shift(">>", "<<", node, ctx)
    elseif op == "%" then
        local ltyp = node.lhs._type._tag
        local rtyp = node.rhs._type._tag
        if ltyp == "Type.Integer" and rtyp == "Type.Integer" then
            return generate_binop_mod_int(node, ctx)
        elseif ltyp == "Type.Float" and rtyp == "Type.Float" then
            return generate_binop_mod_flt(node, ctx)
        else
            error("impossible: " .. ltyp .. " " .. rtyp)
        end
    elseif op == "//" then
        local ltyp = node.lhs._type._tag
        local rtyp = node.rhs._type._tag
        if ltyp == "Type.Integer" and rtyp == "Type.Integer" then
            return generate_binop_idiv_int(node, ctx)
        elseif ltyp == "Type.Float" and rtyp == "Type.Float" then
            return generate_binop_idiv_flt(node, ctx)
        else
            error("impossible: " .. ltyp .. " " .. rtyp)
        end
    elseif node.lhs._type._tag == "Type.String"
           and node.rhs._type._tag == "Type.String"
           and (op == "==" or op == "!=" or op == "<"
                or op == "<=" or op == ">" or op == ">=") then
        -- String comparison must be by content, not by TString* pointer:
        -- equality via luaS_eqstr, ordering via the VM's lexicographic
        -- comparators (which call l_strcmp). Pointer comparison is wrong for
        -- long (non-interned) strings and never lexicographic.
        local cstats, lcode, rcode = ordered_binary_operands(ctx, node)
        if op == "==" then
            return cstats, "luaS_eqstr(" .. lcode .. ", " .. rcode .. ")"
        elseif op == "!=" then
            return cstats, "(!luaS_eqstr(" .. lcode .. ", " .. rcode .. "))"
        else
            local ltmp, ltn = newtmp(ctx, types.Value())
            local rtmp, rtn = newtmp(ctx, types.Value())
            cstats = cstats .. render([[
                $LTMP
                setsvalue(L, &$LTN, $LCODE);
                $RTMP
                setsvalue(L, &$RTN, $RCODE);
            ]], { LTMP = ltmp, LTN = ltn, RTMP = rtmp, RTN = rtn,
                  LCODE = lcode, RCODE = rcode })
            local cmp
            if op == "<" then
                cmp = "luaV_lessthan(L, &" .. ltn .. ", &" .. rtn .. ")"
            elseif op == "<=" then
                cmp = "luaV_lessequal(L, &" .. ltn .. ", &" .. rtn .. ")"
            elseif op == ">" then
                cmp = "luaV_lessthan(L, &" .. rtn .. ", &" .. ltn .. ")"
            else
                cmp = "luaV_lessequal(L, &" .. rtn .. ", &" .. ltn .. ")"
            end
            return cstats, cmp
        end
    elseif (op == "==" or op == "!=") and
            coder._raw_ctype(node.lhs._type) == "TValue" and
            coder._raw_ctype(node.rhs._type) == "TValue" then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        if op == "!=" then
            return stats, "!luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        else
            return stats, "luaV_rawequalobj(&(" .. lcode .. "),&(" .. rcode .. "))"
        end
    elseif (op == "<" or op == "<=" or op == ">" or op == ">="
            or ((op == "==" or op == "!=")
                and comparison.op == "numeric"))
           and ((node.lhs._type._tag == "Type.Integer" and node.rhs._type._tag == "Type.Float")
             or (node.lhs._type._tag == "Type.Float"   and node.rhs._type._tag == "Type.Integer")) then
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        local ldecl, lname = newtmp(ctx, node.lhs._type)
        local rdecl, rname = newtmp(ctx, node.rhs._type)
        local cstats = render([[
            $STATS
            $LDECL
            $LNAME = $LCODE;
            $RDECL
            $RNAME = $RCODE;
        ]], { STATS=stats, LDECL=ldecl, LNAME=lname, LCODE=lcode,
              RDECL=rdecl, RNAME=rname, RCODE=rcode })
        local lint = node.lhs._type._tag == "Type.Integer"
        local cmp
        if op == "==" or op == "!=" then
            cmp = lint and ("titan_eq_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_eq_intfloat(" .. rname .. ", " .. lname .. ")")
            if op == "!=" then cmp = "(!" .. cmp .. ")" end
        elseif op == "<" then
            cmp = lint and ("titan_lt_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_lt_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == "<=" then
            cmp = lint and ("titan_le_intfloat(" .. lname .. ", " .. rname .. ")")
                        or ("titan_le_floatint(" .. lname .. ", " .. rname .. ")")
        elseif op == ">" then           -- a > b  ==  b < a
            cmp = lint and ("titan_lt_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_lt_intfloat(" .. rname .. ", " .. lname .. ")")
        else                            -- ">=":  a >= b  ==  b <= a
            cmp = lint and ("titan_le_floatint(" .. rname .. ", " .. lname .. ")")
                        or ("titan_le_intfloat(" .. rname .. ", " .. lname .. ")")
        end
        return cstats, cmp
    elseif (op == "+" or op == "-" or op == "*")
           and node.lhs._type._tag == "Type.Integer"
           and node.rhs._type._tag == "Type.Integer" then
        -- Integer + - * wrap two's-complement like Lua (intop), instead of raw
        -- signed C arithmetic which is overflow UB under -O2 (no -fwrapv).
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "intop(" .. op .. ", " .. lcode .. ", " .. rcode .. ")"
    else
        local stats, lcode, rcode = ordered_binary_operands(ctx, node)
        return stats, "(" .. lcode .. op .. rcode .. ")"
    end
end

function codeindexarray(ctx, node)
    local castats, caexp = materialize(ctx, node.exp1)
    local cistats, ciexp = materialize(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = coder._strictcheckandgetmixed(
        ctx, node._read_guard, typ, tmpname, "_s", node.loc,
        "typed Array read")
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
    end
    local stats = render([[
        $CTMP
        {
            $CASTATS
            $CISTATS
            Table *_t = $CAEXP;
            lua_Integer _k = $CIEXP;

            TValue _av = {0};
            if (_k < 1) {
                setnilvalue(&_av);
            } else {
                lua_Unsigned _actual_i = l_castS2U(_k) - 1u;
                if (_actual_i < _t->asize) {
                    arr2obj(_t, cast_uint(_actual_i), &_av);
                    if (tagisempty(ttypetag(&_av)))
                        setnilvalue(&_av);
                } else {
                    setnilvalue(&_av);
                }
            }
            const TValue *_s = &_av;

            $CCHECK
            $CSET
    }]], {
        CTMP = ctmp,
        CASTATS = castats,
        CISTATS = cistats,
        CAEXP = caexp,
        CIEXP = ciexp,
        CCHECK = ccheck,
        CSET = cset,
    })
    return stats, tmpname
end

function codeindexmap(ctx, node)
    local cmstats, cmexp = materialize(ctx, node.exp1)
    local ckstats, ckexp = codeexp(ctx, node.exp2)
    local typ = node._type
    local ctmp, tmpname, tmpslot = newtmp(ctx, typ, types.is_gc(typ))
    local cset = ""
    local ccheck = coder._strictcheckandgetmixed(
        ctx, node._read_guard, typ, tmpname, "_s", node.loc,
        "typed Map read")
    if types.is_gc(typ) then
        cset = setslot(typ, tmpslot, tmpname)
    end
    local ktyp = node.exp2._type
    local ctmpk, tmpkname, tmpkslot = newtmp(ctx, ktyp, true)
    local stats = render([[
        $CTMP
        {
            $CMSTATS
            $CKSTATS
            Table *_t = $CMEXP;
            $CTMPK
            $TMPKNAME = $CKEXP;
            $SETSLOTK
            const TValue* _s;
            $CTABLEKEY
            $CCHECK
            $CSET
    }]], {
        CTMP = ctmp,
        CMSTATS = cmstats,
        CKSTATS = ckstats,
        CMEXP = cmexp,
        CTMPK = ctmpk,
        TMPKNAME = tmpkname,
        CKEXP = ckexp,
        SETSLOTK = setboxed(ctx, ktyp, tmpkslot, tmpkname),
        CTABLEKEY = get_table_key(ktyp, "_t", tmpkslot, "_s"),
        CCHECK = ccheck,
        CSET = cset,
    })
    return stats, tmpname
end

function codeindexc(ctx, node)
    local elem = node._type
    local parts = codecindex_parts(ctx, node)
    local ctmp, tmpname, tmpslot = newtmp(ctx, elem, types.is_gc(elem))
    local cset = types.is_gc(elem) and setslot(elem, tmpslot, tmpname) or ""

    return render([[
        $CTMP
        {
            $BSTATS
            $ISTATS
            $CIDX
            $IDX = $IEXP;
            $BOUNDS
            $TMPNAME = $BASE[$IDX];
            $CSET
        }
    ]], {
        CTMP = ctmp,
        BSTATS = parts.bstats,
        ISTATS = parts.istats,
        CIDX = parts.cidx,
        IDX = parts.idxname,
        IEXP = parts.iexp,
        BOUNDS = parts.bounds,
        TMPNAME = tmpname,
        BASE = parts.baseexp,
        CSET = cset,
    }), tmpname
end

function codecpseudonew(ctx, node)
    assert(not node._named_arg_order)
    local decl = node.exp.var._decl
    local plan = node._c_allocation_plan or {
        storage = "owned",
        payload_type = decl.ctype,
        array = decl.array == true,
        fam = decl.fam == true,
    }
    assert(not plan.storage:match("^automatic"),
        "automatic C allocation reached expression lowering")
    local ctyp = plan.payload_type
    local owner_type = types.COwned(ctyp, plan.array)
    local ctmp, tmpname, tmpslot = newtmp(ctx, owner_type, true)
    local countstats, countdecl, countassign

    if plan.array or plan.fam then
        local arg = node.args.args[1]
        local countname
        countstats, countname = codeexp(ctx, arg)
        countdecl = ""
        countassign = render([[
            $COUNTSTATS
            lua_Integer _count = $COUNTEXP;
            if (TITAN_UNLIKELY(_count < 0)) {
                luaL_error(L, "%s:%d:%d: C allocation count cannot be negative", $FILE, $LINE, $COL);
            }
        ]], {
            COUNTSTATS = countstats,
            COUNTEXP = countname,
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    else
        countdecl = "lua_Integer _count = 1;"
        countassign = ""
    end

    local sizecode
    local nuvalues = 0
    local metadata = ""
    if plan.fam then
        local field = assert(plan.fam_field,
            "FAM allocation lacks its field descriptor")
        local resolved_field = types.resolve_c_typedef(field.type)
        assert(resolved_field._tag == "Type.CArray")
        nuvalues = 1
        sizecode = render([[
            size_t _prefix = offsetof($CT, $FIELD);
            size_t _elem_size = sizeof($ELEM);
            if (TITAN_UNLIKELY((size_t)_count > (((size_t)-1) - _prefix) / _elem_size)) {
                luaL_error(L, "%s:%d:%d: C flexible-array allocation size overflow", $FILE, $LINE, $COL);
            }
            size_t _nbytes = _prefix + (size_t)_count * _elem_size;
            if (_nbytes < sizeof($CT)) _nbytes = sizeof($CT);
        ]], {
            CT = coder._render_c_declaration(ctyp, ""),
            FIELD = field.name,
            ELEM = coder._render_c_declaration(resolved_field.elem, ""),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
        metadata = "setivalue(&" .. tmpname
            .. "->uv[0].uv, _count);"
    else
        sizecode = render([[
            size_t _elem_size = sizeof($CT);
            if (TITAN_UNLIKELY((size_t)_count > ((size_t)-1) / _elem_size)) {
                luaL_error(L, "%s:%d:%d: C allocation size overflow", $FILE, $LINE, $COL);
            }
            size_t _nbytes = (size_t)_count * _elem_size;
        ]], {
            CT = coder._render_c_declaration(ctyp, ""),
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
        }, true)
    end

    local stats = render([[
        $CTMP
        {
            $COUNTDECL
            $COUNTASSIGN
            $SIZECODE
            $TMPNAME = luaS_newudata(L, _nbytes, $NUVALUES);
            $TMPNAME->metatable = hvalue(&_mod->uv[$META].uv);
            $METADATA
            setuvalue(L, $TMPSLOT, $TMPNAME);
            memset(getudatamem($TMPNAME), 0, _nbytes);
        }
    ]], {
        CTMP = ctmp,
        COUNTDECL = countdecl,
        COUNTASSIGN = countassign,
        SIZECODE = sizecode,
        TMPNAME = tmpname,
        TMPSLOT = tmpslot,
        NUVALUES = c_integer_literal(nuvalues),
        METADATA = metadata,
        META = c_integer_literal(owned_c_metatable(ctx, owner_type)),
    })
    if plan.storage == "owned_borrow" then
        return stats, render("(($CT *)getudatamem($OWNER))", {
            CT = coder._render_c_declaration(ctyp, ""),
            OWNER = tmpname,
        })
    end
    return stats, tmpname
end

-- `...[i]` (Ast.ExpDotsIndex). The current frame's vararg view is
-- `args[_start .. n_args-1]`, 1-based for the user, so `...[i]` reads
-- `args[_start + i - 1]` after a `1 <= i <= n_args - _start` bounds check.
-- Two modes set by the checker:
--   _nilfill == false (user `...[i]`, non-optional adjust-up): out-of-range
--     RAISES a Titan runtime error; result is the unboxed element value, type t.
--   _nilfill == true (optional adjust-up): out-of-range yields nil; result is a
--     t? option TValue (mirrors the codeindexarray option branch).
function codedotsindex(ctx, node)
    local va = assert(ctx.varargs, "...[i] outside a variadic function")
    local elem = va.elem
    local cistats, ciexp = codeexp(ctx, node.exp)
    -- Materialize the index into a temp first: the bounds check and the element
    -- read both reference it, and the operand may have side effects.
    local cidx, idxname = newtmp(ctx, types.Integer())
    -- length expression: n_args - _start
    local lenexp = render("((lua_Integer)$NAME->n_args - $START)",
        { NAME = va.cname, START = va.start })
    local elemexp = render("$NAME->args[$START + $IDX - 1]",
        { NAME = va.cname, START = va.start, IDX = idxname })
    if not node._nilfill then
        -- non-optional: bounds check raises; result is the unboxed element.
        local ctmp, tmpname, tmpslot = newtmp(ctx, elem, types.is_gc(elem))
        local cset = types.is_gc(elem) and setslot(elem, tmpslot, tmpname) or ""
        local throw = render([[
            luaL_error(L, "%s:%d:%d: variadic index %I out of range [1, %d]", $FILE, $LINE, $COL, (l_uacInt)$IDX, (int)$LEN);
        ]], {
            FILE = c_string_literal(node.loc.filename),
            LINE = c_integer_literal(node.loc.line),
            COL = c_integer_literal(node.loc.col),
            IDX = idxname,
            LEN = lenexp,
        }, true)
        return render([[
            $CTMP
            {
                $CISTATS
                $CIDX
                $IDX = $CIEXP;
                if (TITAN_UNLIKELY($IDX < 1 || $IDX > $LEN)) {
                    $THROW
                }
                $TMPNAME = $ELEMEXP;
                $CSET
            }
        ]], {
            CTMP = ctmp,
            CISTATS = cistats,
            CIDX = cidx,
            IDX = idxname,
            CIEXP = ciexp,
            LEN = lenexp,
            THROW = throw,
            TMPNAME = tmpname,
            ELEMEXP = elemexp,
            CSET = cset,
        }), tmpname
    else
        -- optional: out-of-range -> nil; in-range -> wrap the element into a t?
        -- TValue. node._type is the option type; elem is its base.
        local opttype = node._type
        local ctmp, tmpname = newtmp(ctx, opttype)
        return render([[
            $CTMP
            {
                $CISTATS
                $CIDX
                $IDX = $CIEXP;
                if ($IDX < 1 || $IDX > $LEN) {
                    setnilvalue(&$TMPNAME);
                } else {
                    $SETSLOT
                }
            }
        ]], {
            CTMP = ctmp,
            CISTATS = cistats,
            CIDX = cidx,
            IDX = idxname,
            CIEXP = ciexp,
            LEN = lenexp,
            TMPNAME = tmpname,
            SETSLOT = setslot(elem, "&" .. tmpname, elemexp),
        }), tmpname
    end
end

function coder._cast_coercion(node)
    local plan = node._adjustment or node._written_cast
    local coercion = plan and plan.coercion
    if not coercion then return nil end
    return coder._checked_coercion_plan(
        coercion, node.exp._type, node._type, "expression coercion")
end

function coder._inner_assignment(source, target, inner)
    assert(inner, "Option conversion lacks its inner checker plan")
    inner = coder._checked_coercion_plan(
        inner, source, target, "Option inner conversion")
    source = assert(types.normalize(source),
        "Option inner conversion has an unnormalizable source")
    target = assert(types.normalize(target),
        "Option inner conversion has an unnormalizable target")
    if inner.kind == "identity" then return inner end
    return {
        kind = "direct_coercion",
        source = source,
        target = target,
        coercion = inner,
    }
end

-- Generate code for expression 'node'
-- 'iscondition' is 'true' if expression is used not for value but for
--    controlling conditinal execution
-- 'target' is not nil if expression is rvalue for a 'Ast.VarName' lvalue,
--    in this case it will be the '_decl' of the lvalue
function codeexp_dispatch(ctx, node, iscondition, target)
    local tag = node._tag
    if tag == "Ast.ExpCast" and not node._typedef_resolved then
        if node._adjustment then
            coder._checked_adjustment_plan(
                node._adjustment, node.exp._type, node._type,
                "expression adjustment")
        end
        if node._written_cast then
            coder._checked_written_cast_plan(
                node._written_cast, node.exp._type, node._type,
                "written expression cast")
        end
        if node._c_conversion then
            coder._checked_explicit_conversion_plan(
                node._c_conversion, node.exp._type, node._type,
                "checked expression C conversion")
        end
    end
    if tag == "Ast.VarDot" and node.exp._type._tag == "Type.CModule" then
        local fstats, fexp = codeforeignvar(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.VarName" or (tag == "Ast.VarDot" and node._decl) then
        return codevar(ctx, node)
    elseif tag == "Ast.VarBracket" then
        if node.exp1._type._tag == "Type.Array" then
            return codeindexarray(ctx, node)
        elseif node.exp1._type._tag == "Type.Map" then
            return codeindexmap(ctx, node)
        elseif types.is_direct_c(node.exp1._type) then
            return codeindexc(ctx, node)
        end
        error("impossible var bracket")
    elseif tag == "Ast.ExpNil" or
                tag == "Ast.ExpBool" or
                tag == "Ast.ExpInteger" or
                tag == "Ast.ExpFloat" or
                tag == "Ast.ExpString" then
        return codevalue(ctx, node, target)
    elseif tag == "Ast.ExpInitList" then
        if node._type._tag == "Type.Nominal" then
            return coderecord(ctx, node, target)
        elseif node._type._tag == "Type.Map" then
            return codemap(ctx, node, target)
        else
            return codearray(ctx, node, target)
        end
        error("impossible init list")
    elseif tag == "Ast.ExpUnionInit" then
        return coder._codeunioninit(ctx, node, target)
    elseif tag == "Ast.ExpVar" then
        if node._foreign_function_reference then
            return "", foreigncast(
                coder._foreign_reference_name(node._foreign_function_reference),
                node._type)
        end
        return codeexp(ctx, node.var, iscondition)
    elseif tag == "Ast.ExpUnop" then
        return codeunaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpBinop" then
        return codebinaryop(ctx, node, iscondition)
    elseif tag == "Ast.ExpCall"
           and node.exp.var
           and node.exp.var._decl
           and node.exp.var._decl._tag == "Checker.CPseudoNew" then
        return codecpseudonew(ctx, node)
    elseif tag == "Ast.ExpCall" and node._c_pointer_call then
        local fstats, fexp = codecfunctionptrcall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" and node._direct_foreign_reference then
        local fstats, fexp = codeforeigncall(ctx, node)
        local cstats, cexp = foreigntonativeexp(ctx, node, fexp, target)
        return fstats .. cstats, cexp
    elseif tag == "Ast.ExpCall" then
        return codecall(ctx, node, target)
    elseif tag == "Ast.ExpExtra" then
        return "", node.exp._extras[node.index]
    elseif tag == "Ast.ExpIs" then
        return coder._codeis(ctx, node)
    elseif tag == "Ast.ExpCast" and node._interface_conversion then
        return coder._code_interface_conversion(ctx, node)
    elseif tag == "Ast.ExpCast" and node._interface_downcast then
        return coder._code_interface_downcast(ctx, node, false)
    elseif tag == "Ast.ExpCast" and types.equals(node.exp._type, node._type) then
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast"
           and ((node._adjustment
                    and node._adjustment.kind == "callable")
                or (node._written_cast
                    and (node._written_cast.op == "gradual"
                        or node._written_cast.op == "callable"))) then
        -- A finite callable edge is an allocating target view; a written
        -- structural gradual cast remains the existing representation view.
        -- Both consume only the checker-owned plan attached to this cast.
        local adjustment
        if node._adjustment then
            adjustment = node._adjustment
        else
            local cast = node._written_cast
            adjustment = cast.op == "gradual"
                and assert(cast.view,
                    "written gradual cast lacks its checker view plan")
                or assert(cast.callable,
                    "written callable cast lacks its checker adjustment")
        end
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local astats, aexp = coder._code_adjustment_value(
            ctx, adjustment, node.exp._type, node._type, cexp, node.loc,
            node._callable_adapter)
        return cstats .. astats, aexp
    elseif tag == "Ast.ExpCast"
           and (node.exp._type._tag == "Type.Typedef"
                or node._type._tag == "Type.Typedef") then
        -- A scalar foreign typedef (e.g. size_t) IS its underlying scalar in C,
        -- so `<typedef> as T` (or a cast TO a typedef) behaves exactly like the
        -- cast of/to the underlying type. Resolve the typedef(s) and re-dispatch
        -- through the ordinary cast arms via a synthetic cast node, mirroring
        -- `ctype` (which recurses through `Type.Typedef._type`). We never mutate
        -- the shared AST/type tables in place; the synthetic node carries its own
        -- resolved types and reuses the original operand and location.
        local function resolve(t)
            -- Unwrap ALL typedef levels: typedefs can chain (e.g. macOS's
            -- `size_t` -> `__darwin_size_t` -> `unsigned long`, glibc's
            -- `clock_t` -> `__clock_t` -> long). A one-level unwrap leaves a
            -- Typedef on the synthesized cast, which re-enters this arm forever.
            while t and t._tag == "Type.Typedef" do t = t._type end
            return t
        end
        local stype = resolve(node.exp._type)
        local ttype = resolve(node._type)
        if types.equals(stype, ttype) then
            -- typedef-vs-underlying identity (e.g. size_t as integer): no-op
            return codeexp(ctx, node.exp, iscondition, target)
        end
        local synthexp
        if node.exp._type._tag == "Type.Typedef" then
            -- Re-tag the operand with its underlying type by wrapping it in a
            -- pass-through cast node so the existing arms see a native source.
            synthexp = { _tag = "Ast.ExpCast", loc = node.exp.loc,
                         exp = node.exp, target = stype, _type = stype,
                         _typedef_resolved = true }
        else
            synthexp = node.exp
        end
        local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                            exp = synthexp, target = ttype, _type = ttype }
        for _, key in ipairs({
            "_implicit_coercion",
            "_adjustment",
            "_written_cast",
            "_c_conversion",
            "_operator_conversion",
        }) do
            synthcast[key] = node[key]
        end
        return codeexp(ctx, synthcast, iscondition, target)
    elseif tag == "Ast.ExpCast" and node._typedef_resolved then
        -- Pass-through wrapper produced above: the operand's static type is a
        -- typedef but its C representation already is the underlying scalar, so
        -- just emit the operand unchanged under its resolved type.
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpCast"
           and node._c_conversion
           and node._c_conversion.kind ==
               "address_then_unsafe_object_pointer" then
        coder._checked_explicit_conversion_plan(
            node._c_conversion, node.exp._type, node._type,
            "native address-then-pointer conversion")
        assert(is_addressable_local(node.exp),
            "native address-then-pointer conversion has a "
            .. "non-addressable source")
        local cstats, cexp = codeexp(ctx, node.exp)
        local address = render("(&($CEXP))", { CEXP = cexp })
        return cstats, foreigncast(address, node._type)
    elseif tag == "Ast.ExpCast"
           and types.is_direct_c(node._type)
           and (node.exp._type._tag ~= "Type.Option"
                or (types.is_c_tvalue(node._type)
                    and coder._cast_coercion(node)
                    and coder._cast_coercion(node).op == "to_c_tvalue")) then
        if node.exp._type._tag == "Type.Option" then
            assert(coder._cast_coercion(node).op == "to_c_tvalue",
                "Option-to-C-TValue cast lacks its whole-slot checker plan")
        end
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp =
            nativetoforeignexp(ctx, node.exp, cexp, node._type, node)
        if types.is_c_tvalue(node._type) then
            return cstats .. fstats, fexp
        end
        return cstats .. fstats, foreigncast(fexp, node._type)
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Integer" then
        local cstats, cexp = codeexp(ctx, node.exp)
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "C-to-Titan integer coercion")
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, node.exp._type, node._type, cexp, node.loc, "boundary")
        return cstats .. nstats, nexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Float" then
        local cstats, cexp = codeexp(ctx, node.exp)
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "C-to-Titan float coercion")
        local nstats, nexp = coder._code_checked_numeric_cast(
            ctx, node.exp._type, node._type, cexp, node.loc, "boundary")
        return cstats .. nstats, nexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.Boolean" then
        local cstats, cexp = codeexp(ctx, node.exp)
        return cstats, toboolean(types.resolve_c_typedef(node.exp._type), cexp)
    elseif tag == "Ast.ExpCast"
           and types.is_counted_c_character_owner(node.exp._type)
           and node._type._tag == "Type.String" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local ownerstats, owner =
            materialize_code(ctx, node.exp._type, cstats, cexp)
        local mkstats, mkexp = makestring(
            ctx,
            render("((const char *)getudatamem($OWNER))", {
                OWNER = owner,
            }),
            target,
            render("$OWNER->len", { OWNER = owner }))
        return ownerstats .. "\n" .. mkstats, mkexp
    elseif tag == "Ast.ExpCast" and types.is_direct_c(node.exp._type)
           and node._type._tag == "Type.String" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local ctmp, tmpname = newforeigntmp(ctx, node.exp._type)
        local guard = render([[
            $CSTATS
            $CTMP
            $TMPNAME = $CEXP;
            if ($TMPNAME == NULL) {
                luaL_error(L, "foreign pointer cast to string was NULL");
            }
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            TMPNAME = tmpname,
            CEXP = cexp,
        })
        local mkstats, mkexp = makestring(ctx, tmpname, target)
        return guard .. "\n" .. mkstats, mkexp
    elseif tag == "Ast.ExpCast"
           and node.exp._tag == "Ast.ExpVar"
           and node.exp.var._tag == "Ast.VarBracket"
           and node.exp._type._tag ~= "Type.Option"
           and node.exp._type._tag ~= "Type.Value" then
        -- Fold casts of array/map indexing into the code for the operation
        local t = node.exp.var._type
        node.exp.var._type = node._type
        local cstats, cexp = codeexp(ctx, node.exp.var)
        node.exp.var._type = t
        return cstats, cexp
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Value" then
        -- An implicit projection is a strict gradual observation; a written
        -- `value as T` consumes the broader Lua-boundary conversion plan.
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local ctmps, tmpnames = newtmp(ctx, node.exp._type)
        local ctmpt, tmpnamet = newtmp(ctx, node.target)
        local cget = coder._planned_value_projection_get(
            ctx, node, tmpnamet, "&" .. tmpnames)
        return render([[
            $EXPSTATS
            $TMPSOURCE
            $SOURCE = $EXP;
            $TMPTARGET
            $CHECKANDGET
        ]], {
            EXPSTATS = cstats,
            TMPSOURCE = ctmps,
            SOURCE = tmpnames,
            TMPTARGET = ctmpt,
            EXP = cexp,
            CHECKANDGET = cget
        }), tmpnamet
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Value" then
        -- cast to value from any type
        local cstats, cexp = codeexp(ctx, node.exp, iscondition)
        local ctmp, tmpname = newtmp(ctx, node.target)
        return render([[
            $EXPSTATS
            $TMPTARGET
            $SETSLOT
        ]], {
            EXPSTATS = cstats,
            TMPTARGET = ctmp,
            SETSLOT = setboxed(ctx, node.exp._type, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Integer" and node._type._tag == "Type.Float" then
        -- cast from integer to float
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "integer-to-float coercion")
        local cstat, cexp = codeexp(ctx, node.exp)
        return cstat, "((lua_Number)" .. cexp .. ")"
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Boolean" then
        -- cast to boolean from any type (including options, via truthiness)
        local cstat, cexp = codeexp(ctx, node.exp, true)
        return cstat, toboolean(node.exp._type, cexp)
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Float" and node.target._tag == "Type.Integer" then
        -- cast from float to integer
        coder._checked_numeric_coercion(
            coder._cast_coercion(node),
            node.exp._type, node._type, "float-to-integer coercion")
        local cstat, cexp = codeexp(ctx, node.exp)
        local ctmp1, tmpname1 = newtmp(ctx, types.Float())
        local ctmp2, tmpname2 = newtmp(ctx, types.Float())
        local ctmp3, tmpname3 = newtmp(ctx, types.Integer())
        local cfloor = render([[
            $CSTAT
            $CTMP1
            $CTMP2
            $CTMP3
            $TMPNAME1 = $CEXP;
            $TMPNAME2 = l_floor($TMPNAME1);
            if ($TMPNAME1 != $TMPNAME2) {
                $THROW_WRONG_INT
            } else if (!lua_numbertointeger($TMPNAME2, &$TMPNAME3)) {
                $THROW_WRONG_INT
            }
        ]], {
            CSTAT = cstat,
            CEXP = cexp,
            CTMP1 = ctmp1,
            CTMP2 = ctmp2,
            CTMP3 = ctmp3,
            TMPNAME1 = tmpname1,
            TMPNAME2 = tmpname2,
            TMPNAME3 = tmpname3,
            LINE = c_integer_literal(node.loc.line),
            THROW_WRONG_INT = codethrow(node.loc, "type error at line %d, number '%f' has no integer representation", { "$LINE", "$TMPNAME1" })
        })
        return cfloor, tmpname3
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.String"
           and node.exp._type._tag ~= "Type.Option" then
        local cvt
        local cstats, cexp = codeexp(ctx, node.exp)
        if node.exp._type._tag == "Type.Integer" then
            local conversion = assert(node._operator_conversion,
                "integer-to-string cast lacks its checker operator plan")
            assert(conversion.kind == "operator_conversion"
                    and conversion.op == "number_to_string",
                "integer-to-string cast has the wrong checker operator plan")
            cvt = render("_integer2str(L, $EXP)", { EXP = cexp })
        elseif node.exp._type._tag == "Type.Float" then
            local conversion = assert(node._operator_conversion,
                "float-to-string cast lacks its checker operator plan")
            assert(conversion.kind == "operator_conversion"
                    and conversion.op == "number_to_string",
                "float-to-string cast has the wrong checker operator plan")
            cvt = render("_float2str(L, $EXP)", { EXP = cexp })
        else
            error("invalid node type for coercion to string: " .. types.tostring(node.exp._type))
        end
        if target then
            return cstats, cvt
        else
            local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
            local code = render([[
                $CSTATS
                $CTMP
                $TMPNAME = $CVT;
                setsvalue(L, $TMPSLOT, $TMPNAME);
            ]], {
                CSTATS = cstats,
                CTMP = ctmp,
                TMPNAME = tmpname,
                CVT = cvt,
                TMPSLOT = tmpslot,
            })
            return code, tmpname
        end
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option" and node.exp._type._tag == "Type.Nil" then
        -- Nil-producing expressions are not necessarily literals. Preserve an
        -- effectful call before materializing the option nil (argument/result
        -- adjustment commonly inserts this cast around such a producer).
        local cstats, cexp = codeexp(ctx, node.exp)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            (void)($CEXP);
            $CTMP
            setnilvalue(&$TMPNAME);
        ]], {
            CSTATS = cstats,
            CEXP = cexp,
            CTMP = ctmp,
            TMPNAME = tmpname
        }), tmpname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option"
           and node.exp._type._tag == "Type.Option" then
        -- t1? -> t2? (coerceable bases): propagate nil; for a present value,
        -- unwrap the base, convert it base-to-base, and re-wrap. The base
        -- conversion reuses the ordinary cast codegen via a synthetic cast of
        -- the extracted value (so e.g. float->integer keeps its range check).
        local sbase = node.exp._type.base
        local tbase = node._type.base
        local cstats, cexp = codeexp(ctx, node.exp)
        local csrc, srcname = newtmp(ctx, node.exp._type)
        local cbase, basename = newtmp(ctx, sbase)
        local cdst, dstname = newtmp(ctx, node._type)
        local synthvar = { _tag = "Ast.VarName", _type = sbase,
                           _decl = { _cvar = basename } }
        local outer_coercion = coder._cast_coercion(node)
        assert(outer_coercion and outer_coercion.op == "option_map",
            "Option-to-Option cast lacks its checker coercion plan")
        local inner = assert(outer_coercion.inner,
            "Option map lacks its inner adjustment")
        local inner_adjustment =
            coder._inner_assignment(sbase, tbase, inner)
        local synthcast = { _tag = "Ast.ExpCast", loc = node.loc,
                            exp = synthvar, target = tbase, _type = tbase,
                            _implicit_coercion = true,
                            _adjustment = inner_adjustment }
        local convstats, convexp = codeexp(ctx, synthcast)
        return render([[
            $CSTATS
            $CSRC
            $SRCNAME = $CEXP;
            $CDST
            if (TITAN_UNLIKELY(ttisnil(&$SRCNAME))) {
                setnilvalue(&$DSTNAME);
            } else {
                $CBASE
                $GETBASE;
                $CONVSTATS
                $SETDST
            }
        ]], {
            CSTATS = cstats,
            CSRC = csrc,
            SRCNAME = srcname,
            CEXP = cexp,
            CBASE = cbase,
            GETBASE = getslot(sbase, basename, "&" .. srcname),
            CONVSTATS = convstats,
            CDST = cdst,
            DSTNAME = dstname,
            SETDST = setslot(tbase, "&" .. dstname, convexp),
        }), dstname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Option" then
        -- Cast from S to T?. The checker records one outer option_wrap plan;
        -- lower its inner S-to-T operation here without reclassifying it.
        local coercion = coder._cast_coercion(node)
        assert(coercion and coercion.op == "option_wrap",
            "Option injection has the wrong checker adjustment")
        local tbase = node._type.base
        local inner = assert(coercion.inner,
            "Option injection lacks its inner checker plan")
        local inner_adjustment =
            coder._inner_assignment(node.exp._type, tbase, inner)
        local converted = node.exp
        if inner.kind ~= "identity" then
            converted = {
                _tag = "Ast.ExpCast",
                loc = node.loc,
                exp = node.exp,
                target = tbase,
                _type = tbase,
                _implicit_coercion = true,
                _adjustment = inner_adjustment,
            }
        else
            assert(types.equals(node.exp._type, tbase),
                "identity Option injection changes its base type")
        end
        local cstats, cexp = codeexp(ctx, converted)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CTMP
            $SETSLOT
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            SETSLOT = setslot(tbase, "&" .. tmpname, cexp)
        }), tmpname
    elseif tag == "Ast.ExpCast" and node.exp._type._tag == "Type.Option" then
        -- Cast from S? to T. Preserve nil failure, then lower the checker
        -- plan's inner S-to-T operation without reclassifying it.
        local coercion = coder._cast_coercion(node)
        assert(coercion and coercion.op == "option_force",
            "Option projection has the wrong checker adjustment")
        local sbase = node.exp._type.base
        local inner = assert(coercion.inner,
            "Option projection lacks its inner checker plan")
        local inner_adjustment =
            coder._inner_assignment(sbase, node._type, inner)
        local cstats, cexp = codeexp(ctx, node.exp)
        -- Materialize the option value into a TValue temp first: the operand
        -- may be a non-lvalue (e.g. a direct call returning t?), so we cannot
        -- take its address directly.
        local csrc, srcname = newtmp(ctx, node.exp._type)
        local cbase, basename = newtmp(ctx, sbase)
        local synthvar = {
            _tag = "Ast.VarName",
            _type = sbase,
            _decl = { _cvar = basename },
        }
        local converted = synthvar
        if inner.kind ~= "identity" then
            converted = {
                _tag = "Ast.ExpCast",
                loc = node.loc,
                exp = synthvar,
                target = node._type,
                _type = node._type,
                _implicit_coercion = true,
                _adjustment = inner_adjustment,
            }
        else
            assert(types.equals(sbase, node._type),
                "identity Option projection changes its base type")
        end
        local convstats, convexp = codeexp(ctx, converted)
        local ctmp, tmpname = newtmp(ctx, node._type)
        return render([[
            $CSTATS
            $CSRC
            $SRCNAME = $CEXP;
            $CTMP
            if(TITAN_UNLIKELY(ttisnil(&$SRCNAME))) {
                $THROW_WRONG_CAST
            } else {
                $CBASE
                $GETBASE;
                $CONVSTATS
                $TMPNAME = $CONVEXP;
            }
        ]], {
            CSTATS = cstats,
            CSRC = csrc,
            SRCNAME = srcname,
            CEXP = cexp,
            CBASE = cbase,
            GETBASE = getslot(sbase, basename, "&" .. srcname),
            CONVSTATS = convstats,
            CONVEXP = convexp,
            CTMP = ctmp,
            TMPNAME = tmpname,
            FILE = c_string_literal(node.loc.filename),
            LINE = node.loc.line,
            COL = node.loc.col,
            TYPENAME = c_string_literal(types.tostring(node._type)),
            THROW_WRONG_CAST = codethrow(node.loc, "%s:%d:%d: type error, expected %s but found nil", { "$FILE", "$LINE", "$COL", "$TYPENAME" })
        }), tmpname
    elseif tag == "Ast.ExpCast" and node._type._tag == "Type.Pointer" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp = nativetoforeignexp(ctx, node.exp, cexp)
        return cstats .. fstats, foreigncast(fexp, node._type)
    elseif tag == "Ast.ExpConcat" then
        local strs, copies = {}, {}
        local ctmp, tmpname, tmpslot = newtmp(ctx, types.String(), true)
        for i, exp in ipairs(node.exps) do
            local cstat, cexp = codeexp(ctx, exp)
            local strvar = string.format('_str%d', i)
            local lenvar = string.format('_len%d', i)
            table.insert(strs, render([[
                $CSTAT
                TString *$STRVAR = $CEXP;
                size_t $LENVAR = tsslen($STRVAR);
                if (TITAN_UNLIKELY($LENVAR >=
                        MAX_SIZE - sizeof(TString) - _len)) {
                    luaL_error(L, "string length overflow");
                }
                _len += $LENVAR;
            ]], {
                CSTAT = cstat,
                CEXP = cexp,
                STRVAR = strvar,
                LENVAR = lenvar,
            }))
            table.insert(copies, render([[
                memcpy(_buff + _tl, getstr($STRVAR), $LENVAR * sizeof(char));
                _tl += $LENVAR;
            ]], {
                STRVAR = strvar,
                LENVAR = lenvar,
            }))
        end
        local code = render([[
          $CTMP
          {
              size_t _len = 0;
              size_t _tl = 0;
              $STRS
              if(_len <= LUAI_MAXSHORTLEN) {
                  char _buff[LUAI_MAXSHORTLEN];
                  $COPIES
                  $TMPNAME = luaS_newlstr(L, _buff, _len);
              } else {
                  $TMPNAME = luaS_createlngstrobj(L, _len);
                  char *_buff = getstr($TMPNAME);
                  $COPIES
              }
          }
          setsvalue(L, $TMPSLOT, $TMPNAME);
        ]], {
            CTMP = ctmp,
            STRS = table.concat(strs, "\n"),
            COPIES = table.concat(copies, "\n"),
            TMPNAME = tmpname,
            TMPSLOT = tmpslot,
        })
        return code, tmpname
    elseif tag == "Ast.ExpAdjust" then
        if node._adjustvoid then
            -- `(f())` on a zero-return call: execute the void call for effect,
            -- then yield a single nil value (encoded as int 0, like Type.Nil)
            local cstats, cexp = codeexp(ctx, node.exp, iscondition)
            return cstats .. "\n    " .. cexp .. ";", "0"
        end
        return codeexp(ctx, node.exp, iscondition, target)
    elseif tag == "Ast.ExpDotsLen" then
        -- `#...` -> logical length of the current frame's vararg view, which is
        -- the total backing count minus the start offset.
        local va = assert(ctx.varargs, "#... outside a variadic function")
        return "", render("((lua_Integer)$NAME->n_args - $START)",
            { NAME = va.cname, START = va.start })
    elseif tag == "Ast.ExpDotsIndex" then
        return codedotsindex(ctx, node)
    elseif tag == "Ast.ExpFunction" then
        return codelambda(ctx, node)
    elseif tag == "Ast.ExpMethodRef" then
        return codemethodref(ctx, node)
    else
        error("invalid node tag " .. tag)
    end
end

-- codeexp's `stats` half is frequently spliced *mid-line* into a larger
-- template (e.g. an expression-position slot), so a blanket `#line` prepend
-- here would land a `#` off column 1 and break compilation. Instead, error
-- attribution within an expression's expanded C is pinned where it matters —
-- directly above each luaL_error in codethrow — so we keep codeexp a plain
-- dispatch passthrough (the function-entry/statement/throw stamps cover the
-- rest).
function codeexp(ctx, node, iscondition, target)
    local stats, value =
        codeexp_dispatch(ctx, node, iscondition, target)
    local adjustment = node._assignment_adjustment
    if not adjustment then
        return stats, value
    end
    local adjusted_stats, adjusted_value =
        coder._code_adjustment_value(
            ctx, adjustment, node._type,
            adjustment.target or node._type, value, node.loc)
    return stats .. adjusted_stats, adjusted_value
end

function codeforeignexp(ctx, node, target)
    local tag = node._tag
    if tag == "Ast.ExpCall" and node._c_pointer_call then
        return codecfunctionptrcall(ctx, node)
    elseif tag == "Ast.ExpCall" and node._direct_foreign_reference then
        return codeforeigncall(ctx, node)
    elseif tag == "Ast.VarDot" and node.exp._type._tag == "Type.CModule" then
        return codeforeignvar(ctx, node)
    elseif tag == "Ast.ExpVar"
           and not node._foreign_function_reference
           and node.var
           and node.var._tag == "Ast.VarDot"
           and node.var.exp
           and node.var.exp._type
           and node.var.exp._type._tag == "Type.CModule" then
        -- `codeexp` normally converts a foreign scalar/module member into its
        -- Titan representation at this wrapper.  C operators and C call
        -- operands need the declaration's raw C expression so promotions
        -- happen from its actual type (not a premature lua_Integer/
        -- lua_Number cast).
        return codeforeignvar(ctx, node.var)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpCast" and node.target._tag == "Type.String" then
        local cstats, cexp = codeforeignexp(ctx, node.exp)
        return cstats, foreigncast(cexp, node._type)
    elseif tag == "Ast.ExpCast"
           and node._c_conversion
           and node._c_conversion.kind ==
               "address_then_unsafe_object_pointer" then
        coder._checked_explicit_conversion_plan(
            node._c_conversion, node.exp._type, node._type,
            "foreign address-then-pointer conversion")
        assert(is_addressable_local(node.exp),
            "foreign address-then-pointer conversion has a "
            .. "non-addressable source")
        local cstats, cexp = codeexp(ctx, node.exp)
        local address = render("(&($CEXP))", { CEXP = cexp })
        return cstats, foreigncast(address, node._type)
    elseif tag == "Ast.ExpCast"
           and types.is_direct_c(node._type)
           and node.exp._type._tag ~= "Type.Option" then
        local cstats, cexp = codeexp(ctx, node.exp)
        local fstats, fexp =
            nativetoforeignexp(ctx, node.exp, cexp, node._type, node)
        if types.is_c_tvalue(node._type) then
            return cstats .. fstats, fexp
        end
        return cstats .. fstats, foreigncast(fexp, node._type)
    else
        local cstat, cexp = codeexp(ctx, node)
        local fstat, fexp = nativetoforeignexp(ctx, node, cexp, target)
        return cstat .. fstat, fexp
    end
end

return core.coder

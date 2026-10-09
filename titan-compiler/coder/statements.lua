local core = require "titan-compiler.coder.core"
local _ENV = core

-- A captured-and-mutated local/param is stored in a "box": a heap cell whose
-- single value holds the variable's value. The box pointer is the thing copied
-- into closures that capture the variable, so all sharers mutate one cell. The
-- box is a Lua *userdata* (`Udata*`), not a CClosure: a userdata's GC traversal
-- (`traverseudata`) calls `genlink`, so an overwriting write can use the BACK
-- barrier (`luaC_barrierback`) — which, unlike the forward barrier a CClosure
-- box would require, does not float fresh values written in a hot loop to the
-- old generation until the next major GC. A box never crosses a module boundary
-- (it backs a captured local inside one module's closures, and only that module
-- generates the code that touches it), so this representation is module-internal
-- and does not affect the cross-module ABI (no TITAN_ABI_VERSION bump).
--
-- Two representations, chosen by `is_rawbox` (= `not types.is_gc(typ)`):
--   (N) any non-gc type (integer/float/boolean/Nil/ordinary foreign
--       pointer/scalar typedef, plus an Option of a non-gc base whose TValue is
--       only ever nil-or-scalar): a 0-uservalue userdata (`Udata0`) with the
--       raw, non-collectable C value stored inline (`getudatamem`). No TValue
--       tagging and no barrier — ever.
--   (G) every gc type (TValue-stored: String/Array/Map/record/Function/Value,
--       COwned, C TValue, Lua-internal Udata*, and an Option of a gc base): a
--       1-uservalue userdata holding a TValue in `uv[0].uv`, written with the
--       BACK barrier.

-- A box uses the raw (N) representation iff its value can never hold a GC
-- pointer, i.e. `not types.is_gc(typ)`. `is_gc` is exactly the predicate that
-- governs every other barrier decision in the coder, so a non-gc type has no GC
-- reference and is safe to store raw and untraced in a Udata0. Because newbox /
-- box_read / box_write derive the storage type and size from ctype(typ) /
-- sizeof(ctype(typ)), any non-gc type works with no enumeration: integer, float,
-- boolean, Nil (a dummy int), an Option of a non-gc base (a TValue that is only
-- ever nil-or-scalar), ordinary foreign pointers, and scalar typedefs all route
-- here automatically. Everything that may hold a GC object uses (G).
function is_rawbox(typ --[[:table]])
    return not types.is_gc(typ)
end

-- The C lvalue/rvalue for a box's stored value.
--   (G) -> "&BOX->uv[0].uv" (a TValue*, used with setslot/getslot)
--   (N) -> "*(CT *)getudatamem(BOX)" (the raw unboxed C value)
function box_value_slot(boxvar)
    return "&" .. boxvar .. "->uv[0].uv"
end

-- Read a box's value as a C rvalue yielding the unboxed value.
function box_read(typ --[[:table]], boxvar --[[:string]])
    if is_rawbox(typ) then
        return render("(*($CT *)getudatamem($BOX))",
            { CT = ctype(typ), BOX = boxvar })
    else
        return getslot(typ, nil, box_value_slot(boxvar))
    end
end

-- Write `cexp` into a box. (N) stores the raw scalar inline, no barrier.
-- (G) stores a TValue and, when the value may be collectable, runs the BACK
-- barrier (safe because the box is a genlink-managed userdata).
function box_write(typ --[[:table]], boxvar --[[:string]], cexp --[[:string]])
    if is_rawbox(typ) then
        return render("*($CT *)getudatamem($BOX) = $CEXP;",
            { CT = ctype(typ), BOX = boxvar, CEXP = cexp })
    else
        local slot = box_value_slot(boxvar)
        local code = setslot(typ, slot, cexp)
        if types.is_gc(typ) then
            code = code .. render(
                "\nluaC_barrierback(L, obj2gco($BOX), $SLOT);",
                { BOX = boxvar, SLOT = slot })
        end
        return code
    end
end

-- `newbox` emits the box allocation: declares the `Udata*` C var, allocates the
-- cell inline (luaS_newudata expanded with the size check dropped — the size is
-- a tiny constant), and anchors the box in a fresh stack slot against the GC
-- BEFORE any later allocation. For (G) the value slot is nil'd before anchoring
-- so a GC triggered by a later alloc never traverses a garbage uv[0]. The caller
-- stores the initial value afterwards (via box_write).
--   typ:      the Titan type of the boxed variable (selects (G) vs (N))
--   boxvar:   name of the `Udata*` C variable to declare
--   slot: relocation-safe expression for the box's anchor slot
function newbox(ctx, typ, boxvar, slot)
    if is_rawbox(typ) then
        return render([[
            Udata *$BOXVAR = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(0, sizeof($CT))));
            $BOXVAR->len = sizeof($CT); $BOXVAR->nuvalue = 0; $BOXVAR->metatable = NULL;
            setuvalue(L, $SLOT, $BOXVAR);
        ]], {
            BOXVAR = boxvar,
            SLOT = slot,
            CT = ctype(typ),
        })
    else
        return render([[
            Udata *$BOXVAR = gco2u(luaC_newobj(L, LUA_VUSERDATA, sizeudata(1, 0)));
            $BOXVAR->len = 0; $BOXVAR->nuvalue = 1; $BOXVAR->metatable = NULL;
            setnilvalue(&$BOXVAR->uv[0].uv);
            setuvalue(L, $SLOT, $BOXVAR);
        ]], {
            BOXVAR = boxvar,
            SLOT = slot,
        })
    end
end

function pushd(ctx)
    table.insert(ctx.dstack, ctx.depth)
end

function popd(ctx)
    ctx.depth = table.remove(ctx.dstack)
end

function push_spillscope(ctx)
    ctx.spill_scope_stack = ctx.spill_scope_stack or {}
    local n = ctx.active_spill_decls and #ctx.active_spill_decls or 0
    table.insert(ctx.spill_scope_stack, n)
end

function pop_spillscope(ctx)
    local n = table.remove(ctx.spill_scope_stack)
    if not ctx.active_spill_decls then return end
    for i = #ctx.active_spill_decls, n + 1, -1 do
        local decl = ctx.active_spill_decls[i]
        ctx.active_spill_decls[i] = nil
        if ctx.spill_decl_seen then ctx.spill_decl_seen[decl] = nil end
    end
end

-- Emit the statements of a block's `stats` list, stopping after the first
-- terminator (the rest is unreachable, unchecked dead code).
function codestats(ctx, stats_list)
    local out = {}
    for _, stat in ipairs(stats_list) do
        table.insert(out, codestat(ctx, stat))
        if is_terminator(stat) then break end
    end
    return out
end

-- All the code generation functions for STATEMENTS take
-- the function context and the AST node and return the
-- generated C code for the statement, as a string

function codeblock(ctx, node)
    pushd(ctx)
    push_spillscope(ctx)
    local stats = codestats(ctx, node.stats)
    pop_spillscope(ctx)
    popd(ctx)
    return " {\n " .. table.concat(stats, "\n ") .. "\n }"
end

function codetransparentblock(ctx, node)
    push_spillscope(ctx)
    local stats = codestats(ctx, node.stats)
    pop_spillscope(ctx)
    return table.concat(stats, "\n")
end

-- Open a loop frame (#3): if the loop body contains a try, allocate a save id so
-- a `break` crossing that try boundary can restore the loop-entry errorjmp/nC.
-- Returns the frame; the caller must `close_loop` after coding the body, then
-- splice `loop_save_lines(frame)` at loop entry.
function open_loop(ctx, node)
    ctx.loop_after_id = (ctx.loop_after_id or 0) + 1
    local frame = { try_depth = ctx.try_depth or 0, after_id = ctx.loop_after_id }
    if stat_contains_try(node.block) then
        ctx.loop_save_id = (ctx.loop_save_id or 0) + 1
        frame.save_id = ctx.loop_save_id
    end
    ctx.loopstack = ctx.loopstack or {}
    table.insert(ctx.loopstack, frame)
    return frame
end

function close_loop(ctx)
    table.remove(ctx.loopstack)
end

-- The loop-entry errorjmp/nC save lines, emitted ONLY if a `break` inside the
-- loop actually crossed a try boundary (frame.used, set in the StatBreak arm).
function loop_save_lines(frame)
    if not (frame.save_id and frame.used) then return "" end
    return render([[
        lua_longjmp *_loop_errorjmp_$ID = L->errorJmp;
        l_uint32 _loop_nC_$ID = L->nCcalls;
    ]], { ID = c_integer_literal(frame.save_id) })
end

-- The label spliced immediately AFTER a loop so a PA_BREAK dispatch inside a
-- finally (which cannot use a bare C `break`) can `goto` past the loop. Emitted
-- only when such a break was actually generated (frame.uses_after_label).
function after_loop_label(frame)
    if not frame.uses_after_label then return "" end
    return "\n_after_loop_" .. frame.after_id .. ": ;"
end

function codewhile(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    local nallocs = ctx.allocations
    local cstats, cexp = codeexp(ctx, node.condition, true)
    local cblk = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    local tmpl
    if cstats == "" then
        tmpl = [[
            $LOOPSAVE
            while($CEXP) {
                $CBLK
                $CHECKGC
            }$AFTER
        ]]
    else
        tmpl = [[
            $LOOPSAVE
            while(1) {
                $CSTATS
                if(!($CEXP)) {
                    break;
                }
                $CBLK
                $CHECKGC
            }$AFTER
        ]]
    end
    return render(tmpl, {
        LOOPSAVE = loopsave,
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CBLK = cblk,
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        AFTER = after_loop_label(frame),
    })
end

function coderepeat(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    local nallocs = ctx.allocations
    -- In Lua the `until` condition is in the scope of the body, so it may
    -- reference body-local variables. Code the body's statements INLINE (not
    -- wrapped in a nested C block) and then the condition, so both share one
    -- C scope and the body locals' C names are bound and still visible.
    local cblk = table.concat(codestats(ctx, node.block.stats), "\n")
    local cstats, cexp = codeexp(ctx, node.condition, true)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    local condition_begin, condition_end = "", ""
    if coder._coverage_source_regions and not ctx._coverage_generated then
        local locations = require("titan-compiler.coverage_lines")
        condition_begin = locations.begin("source",
            node.condition.loc.filename, node.condition.loc.line)
        condition_end = locations.finish()
    end
    return render([[
        $LOOPSAVE
        while(1) {
            $CBLK
            $CSTATS
            ${CONDITIONBEGIN}if($CEXP) {
                break;
            }
            $CONDITIONEND$CHECKGC
        }$AFTER
    ]], {
        LOOPSAVE = loopsave,
        CBLK = cblk,
        CSTATS = cstats,
        CEXP = toboolean(node.condition._type, cexp),
        CONDITIONBEGIN = condition_begin,
        CONDITIONEND = condition_end,
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        AFTER = after_loop_label(frame),
    })
end

function codeif(ctx, node, idx)
    idx = idx or 1
    local cstats, cexp, cthn, cels
    if idx == #node.thens then -- last condition
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        -- Put the else body on its own line(s): a statement's code now begins
        -- with a `#line` directive, which must start
        -- a line — gluing it after `else ` on one line would put the `#` off
        -- column 1 and break compilation. `else\n<body>` is equally valid C.
        cels = node.elsestat and "else\n" .. codestat(ctx, node.elsestat) or ""
    else
        cstats, cexp = codeexp(ctx, node.thens[idx].condition, true)
        cthn = codestat(ctx, node.thens[idx].block)
        cels = "else\n" .. codeif(ctx, node, idx + 1)
    end
    return coverage_region(node.thens[idx].condition, render([[
        {
            $CSTATS
            if($CEXP) {
                $CTHN
            } $CELS
        }
    ]], {
        CSTATS = cstats,
        CEXP = toboolean(node.thens[idx].condition._type, cexp),
        CTHN = cthn,
        CELS = cels
    }), ctx)
end

function codefor(ctx, node)
    pushd(ctx)
    local frame = open_loop(ctx, node)
    node.decl._cvar = "_local_" .. node.decl.name
    local csstats, csexp = codeexp(ctx, node.start)
    local cfstats, cfexp = codeexp(ctx, node.finish)
    local cistats, ciexp = codeexp(ctx, node.inc)
    local nallocs = ctx.allocations
    local cblock = codestat(ctx, node.block)
    nallocs = ctx.allocations - nallocs
    if nallocs > 0 then ctx.uses_base_off = true end
    close_loop(ctx)
    popd(ctx)
    local loopsave = loop_save_lines(frame)
    -- Lua-faithful numeric for (see lvm.c forprep/forloop/floatforloop):
    -- a zero step raises a run-time error; the integer loop is driven by an
    -- unsigned iteration count so it cannot overflow past the integer limits
    -- into a non-terminating loop; and the visible control variable is a
    -- fresh copy each iteration (a separate internal index advances), so it
    -- is independent of the iteration and read-only.
    local subs = {
        LOOPSAVE = loopsave,
        CVAR = node.decl._cvar,
        -- declare the visible control variable only if the body uses it.
        CVARDECL = node.decl._used
            and (cvardecl(ctx, node.decl._type, node.decl._cvar) .. " = _foridx;") or "",
        CSSTATS = csstats, CSEXP = csexp,
        CFSTATS = cfstats, CFEXP = cfexp,
        CISTATS = cistats, CIEXP = ciexp,
        CBLOCK = cblock,
        CHECKGC = nallocs > 0
            and "luaC_checkGC(L); _base = restorestack(L, _base_off);" or "",
        FILE = c_string_literal(node.loc.filename),
        LINE = node.loc.line,
        COL = node.loc.col,
        STEP0 = codethrow(node.loc, "%s:%d:%d: 'for' step is zero",
                          { "$FILE", "$LINE", "$COL" }),
        AFTER = after_loop_label(frame),
    }
    if node.decl._type._tag == "Type.Integer" then
        return render([[
            {
                $LOOPSAVE
                $CSSTATS
                lua_Integer _forstart = $CSEXP;
                $CFSTATS
                lua_Integer _forlimit = $CFEXP;
                $CISTATS
                lua_Integer _forstep = $CIEXP;
                if (_forstep == 0) {
                    $STEP0
                }
                if (_forstep > 0 ? (_forstart <= _forlimit) : (_forstart >= _forlimit)) {
                    lua_Unsigned _forcount = (_forstep > 0)
                        ? (l_castS2U(_forlimit) - l_castS2U(_forstart)) / l_castS2U(_forstep)
                        : (l_castS2U(_forstart) - l_castS2U(_forlimit)) / (l_castS2U(-(_forstep + 1)) + 1u);
                    lua_Integer _foridx = _forstart;
                    while (1) {
                        $CVARDECL
                        $CBLOCK
                        $CHECKGC
                        if (_forcount == 0) {
                            break;
                        }
                        _forcount--;
                        _foridx = l_castU2S(l_castS2U(_foridx) + l_castS2U(_forstep));
                    }
                }
            }$AFTER
        ]], subs)
    else
        return render([[
            {
                $LOOPSAVE
                $CSSTATS
                lua_Number _forstart = $CSEXP;
                $CFSTATS
                lua_Number _forlimit = $CFEXP;
                $CISTATS
                lua_Number _forstep = $CIEXP;
                if (_forstep == 0) {
                    $STEP0
                }
                if (_forstep > 0 ? (_forstart <= _forlimit) : (_forstart >= _forlimit)) {
                    lua_Number _foridx = _forstart;
                    while (1) {
                        $CVARDECL
                        $CBLOCK
                        $CHECKGC
                        _foridx = luai_numadd(L, _foridx, _forstep);
                        if (!(_forstep > 0 ? (_foridx <= _forlimit) : (_foridx >= _forlimit))) {
                            break;
                        }
                    }
                }
            }$AFTER
        ]], subs)
    end
end

-- Reads the entry for key $K (a boxed TValue*) of table $T and points $SLOT
-- at the result. Lua 5.5's luaH_get* functions leave their output untouched
-- on a miss, so the rooted key slot can also be the result slot, as it is in
-- lua_gettable. A raw miss takes luaV_finishget only when __index may exist;
-- its result then flows through the caller's ordinary typed Map-read guard.
function get_table_key(ctx, keytype, t, k, kstack, slot)
    ctx.uses_base_off = true
    local tgetkey
    if keytype._tag == "Type.String" then
        tgetkey = [[
            lu_byte ${SLOT}_tag;
            if (ttypetag($K) == LUA_VSHRSTR) {
                ${SLOT}_tag = luaH_getshortstr($T, tsvalue($K), $K);
            } else {
                ${SLOT}_tag = luaH_get($T, $K, $K);
            }
        ]]
    elseif keytype._tag == "Type.Integer" then
        tgetkey = [[
            lu_byte ${SLOT}_tag = luaH_getint($T, ivalue($K), $K);
        ]]
    elseif keytype._tag == "Type.Float" then
        tgetkey = [[
            lu_byte ${SLOT}_tag;
            {
                lua_Integer _ik;
                if (luaV_tointeger($K, &_ik, F2Ieq)) {
                    ${SLOT}_tag = luaH_getint($T, _ik, $K);
                } else {
                    ${SLOT}_tag = luaH_get($T, $K, $K);
                }
            }
        ]]
    else
        tgetkey = [[
            lu_byte ${SLOT}_tag = luaH_get($T, $K, $K);
        ]]
    end
    return render(tgetkey .. [[
        if (tagisempty(${SLOT}_tag)) {
            if (TITAN_LIKELY(checknoTM($T->metatable, TM_INDEX))) {
                setnilvalue($K);
            } else {
                TValue ${SLOT}_table;
                sethvalue(L, &${SLOT}_table, $T);
                ${SLOT}_tag = luaV_finishget(
                    L, &${SLOT}_table, $K, $KSTACK, ${SLOT}_tag);
                _base = restorestack(L, _base_off);
            }
        }
        $SLOT = $K;
    ]], {
        SLOT = slot,
        T = t,
        K = k,
        KSTACK = kstack,
    })
end

-- Stores the TValue $V directly into table $T at key $K (a boxed TValue*).
-- Lua 5.5 removed the "get a writable slot" API (luaH_newkey is gone);
-- raw stores go through luaH_set/luaH_setint, which take the value.
-- The GC barrier for the stored value is the caller's responsibility;
-- new keys are barriered internally by the insertion code.
function set_table_entry_raw(keytype, t, k, v)
    local tsetkey
    if keytype._tag == "Type.Integer" then
        tsetkey = [[
            luaH_setint(L, $T, ivalue($K), $V);
        ]]
    elseif keytype._tag == "Type.Float" then
        tsetkey = [[
            {
                lua_Integer _ik;
                if (luaV_tointeger($K, &_ik, F2Ieq)) {
                    luaH_setint(L, $T, _ik, $V);
                } else {
                    luaH_set(L, $T, $K, $V);
                }
            }
        ]]
    else
        tsetkey = [[
            luaH_set(L, $T, $K, $V);
            invalidateTMcache($T);
        ]]
    end
    return render(tsetkey, {
        T = t,
        K = k,
        V = v,
    })
end

-- Stores through ordinary Lua table-assignment semantics while retaining the
-- raw setter above as the likely no-metamethod path. When __newindex may be
-- present, Lua's partial setters update an existing slot in place and return a
-- location code for a missing slot; only that latter case enters
-- luaV_finishset and its function/table/value metamethod chain.
function set_table_entry(ctx, keytype, t, k, v)
    ctx.uses_base_off = true
    local pset
    if keytype._tag == "Type.Integer" then
        pset = [[
            luaH_fastseti($T, ivalue($K), $V, _hres);
        ]]
    elseif keytype._tag == "Type.Float" then
        pset = [[
            {
                lua_Integer _ik;
                if (luaV_tointeger($K, &_ik, F2Ieq)) {
                    luaH_fastseti($T, _ik, $V, _hres);
                } else {
                    _hres = luaH_pset($T, $K, $V);
                }
            }
        ]]
    else
        pset = [[
            _hres = luaH_pset($T, $K, $V);
        ]]
    end
    return render([[
        if (TITAN_LIKELY(checknoTM($T->metatable, TM_NEWINDEX))) {
            $RAWSET
        } else {
            int _hres;
            $PSET
            if (_hres != HOK) {
                TValue _table;
                sethvalue(L, &_table, $T);
                luaV_finishset(L, &_table, $K, $V, _hres);
                _base = restorestack(L, _base_off);
            }
        }
    ]], {
        T = t,
        K = k,
        V = v,
        RAWSET = set_table_entry_raw(keytype, t, k, v),
        PSET = render(pset, { T = t, K = k, V = v }),
    })
end

codecfield = nil

codecindex_parts = nil

function code_owned_payload(owner, pointee)
    return render("(($CT)getudatamem($OWNER))", {
        CT = coder._render_c_type_name(types.CPointer(pointee, {})),
        OWNER = owner,
    })
end

function coder._prepared_c_null_check(var, base)
    local message
    local args
    if var._tag == "Ast.VarDot" then
        message = "%s:%d:%d: cannot access field '%s' of a NULL C pointer"
        args = {
            c_string_literal(var.loc.filename),
            c_integer_literal(var.loc.line),
            c_integer_literal(var.loc.col),
            c_string_literal(var.name),
        }
    else
        message = "%s:%d:%d: cannot index a NULL C pointer"
        args = {
            c_string_literal(var.loc.filename),
            c_integer_literal(var.loc.line),
            c_integer_literal(var.loc.col),
        }
    end
    return render([[
        if (TITAN_UNLIKELY($BASE == NULL)) {
            $THROW
        }
    ]], {
        BASE = base,
        THROW = codethrow(var.loc, message, args),
    })
end

function coder._prepared_c_bounds_check(var, index, length)
    return render([[
        if (TITAN_UNLIKELY($INDEX < 0 || $INDEX >= $LENGTH)) {
            luaL_error(L,
                "%s:%d:%d: C index %I out of range [0, %d)",
                $FILE, $LINE, $COL, (l_uacInt)$INDEX, (int)$LENGTH);
        }
    ]], {
        INDEX = index,
        LENGTH = length,
        FILE = c_string_literal(var.loc.filename),
        LINE = c_integer_literal(var.loc.line),
        COL = c_integer_literal(var.loc.col),
    }, true)
end

function coder._materialize_c_aggregate(ctx, exp)
    local stats, value = codeexp(ctx, exp)
    local tmp = ctx.tmp
    ctx.tmp = ctx.tmp + 1
    local name = "_tmp_" .. tmp
    return render([[
        $STATS
        $DECLARATION;
        $NAME = $VALUE;
    ]], {
        STATS = stats,
        DECLARATION = coder._render_c_declaration(exp._type, name),
        NAME = name,
        VALUE = value,
    }), name
end

-- Prepare an addressable C subobject without copying it. The top-level target
-- defers its own NULL/range validation until the store; any field/index step
-- needed to obtain that target's base is an ordinary LHS read, so its checks
-- execute during preparation. COwned roots remain in scanned slots across the
-- RHS. Aggregate and array subobjects retain a stable access path assembled
-- only from already-frozen roots and indices. This is equivalent to retaining
-- their address but does not require naming an anonymous C struct/union (or an
-- array whose element is one), which C99 cannot express in a declarator.
function coder._is_nested_c_storage(exp)
    if exp._tag ~= "Ast.ExpVar" then return false end
    local var = exp.var
    if var._tag == "Ast.VarDot" then
        return var._decl and var._decl._tag == "Type.CField"
            and types.is_direct_c(var.exp._type)
    elseif var._tag == "Ast.VarBracket" then
        return types.is_direct_c(var.exp1._type)
    end
    return false
end

function coder._prepare_c_loaded_value(ctx, exp)
    if coder._is_nested_c_storage(exp) then
        -- This path reads a pointer value needed as the final target's base.
        -- A by-value aggregate may therefore be copied to a temporary long
        -- enough to read that pointer; unlike a final aggregate mutation, no
        -- persistent address for the by-value object itself is required.
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, true)
        return materialize_code(ctx, exp._type, stats, storage)
    end
    return materialize(ctx, exp)
end

function coder._prepare_c_base(ctx, exp, allow_temporary)
    local basetype = types.resolve_c_typedef(exp._type)
    if exp._c_fam_access then
        local access = exp._c_fam_access
        if access.kind == "owned" then
            local owner_node = assert(exp.var).exp
            local stats, owner = materialize(ctx, owner_node)
            local owner_type = types.resolve_c_typedef(owner_node._type)
            local payload = coder._render_c_declaration(
                owner_type.pointee, "")
            return stats, {
                type = basetype,
                base = "((" .. payload .. " *)getudatamem("
                    .. owner .. "))->" .. access.field.name,
                length = "ivalue(&" .. owner .. "->uv[0].uv)",
                indirect = false,
            }
        end
        local stats, storage = coder._prepare_c_storage(
            ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            length = c_integer_literal(access.count),
            indirect = false,
        }
    end
    if basetype._tag == "Type.CPointer" then
        local stats, pointer = coder._prepare_c_loaded_value(ctx, exp)
        return stats, {
            type = basetype,
            base = pointer,
            indirect = true,
        }
    elseif basetype._tag == "Type.COwned" then
        local stats, owner = materialize(ctx, exp)
        local length = basetype.count and render(
            "((lua_Integer)($OWNER->len / sizeof($TYPE)))", {
                OWNER = owner,
                TYPE = coder._render_c_declaration(
                    basetype.pointee, ""),
            }) or nil
        return stats, {
            type = basetype,
            base = code_owned_payload(owner, basetype.pointee),
            length = length,
            indirect = true,
        }
    elseif basetype._tag == "Type.CArray" then
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            length = c_integer_literal(basetype.len),
            indirect = false,
        }
    elseif basetype._tag == "Type.CStruct"
           or basetype._tag == "Type.CUnion" then
        local stats, storage =
            coder._prepare_c_storage(ctx, exp, allow_temporary)
        return stats, {
            type = basetype,
            base = storage,
            indirect = false,
        }
    end
    error("invalid prepared C base " .. types.tostring(exp._type))
end

function coder._prepared_c_field(base, name)
    if base.indirect then
        return render("($BASE)->$FIELD", {
            BASE = base.base,
            FIELD = name,
        })
    end
    return render("($BASE).$FIELD", {
        BASE = base.base,
        FIELD = name,
    })
end

function coder._prepare_c_storage(ctx, exp, allow_temporary)
    if exp._tag ~= "Ast.ExpVar" then
        local basetype = types.resolve_c_typedef(exp._type)
        if allow_temporary
           and (basetype._tag == "Type.CStruct"
                or basetype._tag == "Type.CUnion") then
            return coder._materialize_c_aggregate(ctx, exp)
        end
        error("C assignment receiver has no persistent storage")
    end
    local var = exp.var
    if var._tag == "Ast.VarDot"
       and var._decl
       and var._decl._tag == "Type.CField"
       and types.is_direct_c(var.exp._type) then
        local stats, base =
            coder._prepare_c_base(ctx, var.exp, allow_temporary)
        local check = base.type._tag == "Type.CPointer"
            and coder._prepared_c_null_check(var, base.base) or ""
        return render([[
            $STATS
            $CHECK
        ]], {
            STATS = stats,
            CHECK = check,
        }), coder._prepared_c_field(base, var.name)
    elseif var._tag == "Ast.VarBracket"
           and types.is_direct_c(var.exp1._type) then
        local stats, base =
            coder._prepare_c_base(ctx, var.exp1, allow_temporary)
        local indexstats, index = materialize(ctx, var.exp2)
        local checks = {}
        if base.type._tag == "Type.CPointer" then
            table.insert(checks,
                coder._prepared_c_null_check(var, base.base))
        elseif base.length then
            table.insert(checks,
                coder._prepared_c_bounds_check(
                    var, index, base.length))
        end
        return render([[
            $STATS
            $INDEXSTATS
            $CHECKS
        ]], {
            STATS = stats,
            INDEXSTATS = indexstats,
            CHECKS = table.concat(checks, "\n"),
        }), render("$BASE[$INDEX]", {
            BASE = base.base,
            INDEX = index,
        })
    end
    return codeexp(ctx, exp)
end

function codeassignment(ctx, var, cexp, etype, lvalue)
    local vtag = var._tag
    if vtag == "Ast.VarName" or (vtag == "Ast.VarDot" and var._decl) then
        if vtag == "Ast.VarDot" and var._decl._tag == "Type.Field" then
            assert(var._decl.isconst == false
                   and not var._interface_field,
                "const field lvalue reached code generation")
            local lstats, lexp
            if lvalue then
                lstats, lexp = "", assert(lvalue.record)
            else
                lstats, lexp = codeexp(ctx, var.exp)
            end
            local plan = coder._nominal_plan(ctx, var.exp._type)
            return lstats .. "\n{ Udata *_recobj = " .. lexp .. ";\n"
                .. coder._nominal_store(ctx, plan,
                    assert(plan.by_index[var._decl.index]),
                    var._decl.type, "_recobj", cexp) .. "\n}"
        elseif vtag == "Ast.VarDot" and var._decl._tag == "Type.CField" then
            local spill = spill_update(coder._lvalue_root_decl(var))
            if lvalue and lvalue.cfield_base then
                local base = {
                    type = assert(lvalue.cfield_type),
                    base = lvalue.cfield_base,
                    indirect = lvalue.cfield_indirect,
                }
                local check = base.type._tag == "Type.CPointer"
                    and coder._prepared_c_null_check(
                        var, base.base) or ""
                local field =
                    coder._prepared_c_field(base, var._decl.name)
                return render([[
                    $CHECK
                    $FIELD = $CEXP;
                    $SPILL
                ]], {
                    CHECK = check,
                    FIELD = field,
                    CEXP = cexp,
                    SPILL = spill,
                })
            end
            local lstats, lexp
            if lvalue then
                lstats, lexp = "", assert(lvalue.cfield)
            else
                lstats, lexp = codecfield(ctx, var)
            end
            return render([[
                $STATS
                $FIELD = $CEXP;
                $SPILL
            ]], {
                STATS = lstats,
                FIELD = lexp,
                CEXP = cexp,
                SPILL = spill,
            })
        elseif vtag == "Ast.VarDot" then -- module variable
            assert(var._decl._tag == "Type.ModuleVariable")
            ctx.variables[var.exp.var.name .. "." .. var.name] = {
                module = var.exp.var.name,
                name = var.name,
                slot = var._decl._slot
            }
            return render([[
                {
                    Udata *_imod = uvalue(&_mod->uv[$MODINDEX].uv);
                    TValue *_varslot = &_imod->uv[$VARINDEX].uv;
                    $SETSLOT;
                    $BARRIER
                }
            ]], {
                SETSLOT = setslot(var._type, "_varslot", cexp),
                BARRIER = types.is_gc(var._type)
                          and "luaC_barrierback(L, obj2gco(_imod), _varslot);" or "",
                MODINDEX = c_integer_literal(var.exp.var._decl._upvalue),
                VARINDEX = coder._imported_slot(ctx, var._decl.modname,
                    "variable", var._decl)
            })
        elseif var._decl._tag == "Ast.TopLevelVar" then
            local cset = setslot(var._type, var._decl._slot, cexp)
            if types.is_gc(var._type) then
                cset = cset .. "\nluaC_barrierback(L, obj2gco(_mod), " .. var._decl._slot .. ");"
            end
            return cset
        elseif ctx.captures and ctx.captures[var._decl] then
            -- Inside a lambda body: write to a captured (boxed) variable through
            -- its box cell. By-value captures are immutable, so a write target is
            -- always boxed.
            local cap = ctx.captures[var._decl]
            return box_write(var._type, cap.boxvar, cexp)
        elseif var._decl._boxed then
            -- Captured-and-mutated local/param of the current function: write
            -- through its box cell.
            return box_write(var._type, var._decl._box, cexp)
        elseif var._decl._used and cexp ~= var._decl._cvar then
            local cset = ""
            if types.is_gc(var._type) then
                cset = setslot(var._type, var._decl._slot, var._decl._cvar)
            end
            return render([[
                $CVAR = $CEXP;
                $CSET
                $SPILL
            ]], {
                CVAR = var._decl._cvar,
                CEXP = cexp,
                CSET = cset,
                SPILL = spill_update(var._decl),
            })
        else
            return render([[
                ((void)$CEXP);
            ]], {
                CEXP = cexp,
            })
        end
    elseif vtag == "Ast.VarBracket" then
        local exp1type = var.exp1._type._tag
        if exp1type == "Type.Array" then
            assert(var.exp1._type.isconst.tag == "no",
                "const Array assignment reached code generation")
            local arr = var.exp1
            local idx = var.exp2
            local castats, caexp, cistats, ciexp
            if lvalue then
                castats, caexp = "", assert(lvalue.array)
                cistats, ciexp = "", assert(lvalue.index)
            else
                castats, caexp = codeexp(ctx, arr)
                cistats, ciexp = codeexp(ctx, idx)
            end
            -- A resize can collect and relocate the Lua stack. Root both the
            -- backing and RHS only on that slow path, save `_base` by offset,
            -- then reload both values after the helper restores lenhint.
            ctx.uses_base_off = true
            local arrroot = slotat(reserveslot(ctx))
            local valroot = slotat(reserveslot(ctx))
            local barrier = types.is_gc(arr._type.elem)
                and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            return render([[
                {
                    $CASTATS
                    $CISTATS
                    Table *_t = $CAEXP;
                    lua_Integer _k = $CIEXP;
                    TValue _vv = {0};
                    $SETVV
                    if (TITAN_UNLIKELY(_k < 1)) {
                        $BADINDEX
                    }
                    lua_Unsigned _actual_i = l_castS2U(_k);
                    unsigned _asize = _t->asize;
                    if (_actual_i < _asize) {
                        unsigned _length = cast_uint(titan_array_length(_t));
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                        $BARRIER
                        if (ttisnil(&_vv)) {
                            if (_actual_i == _length) {
                                while (_length > 0 &&
                                       tagisempty(*getArrTag(_t, _length)))
                                    _length--;
                                titan_array_set_length(_t, _length);
                            }
                        } else if (_actual_i > _length) {
                            titan_array_set_length(_t, _actual_i);
                        }
                    } else if (!ttisnil(&_vv)) {
                        sethvalue(L, $ARRROOT, _t);
                        setobj2t(L, $VALROOT, &_vv);
                        unsigned _newasize =
                            titan_array_growth(L, _actual_i);
                        titan_array_resize(L, _t, _newasize);
                        _base = restorestack(L, _base_off);
                        _t = hvalue($ARRROOT);
                        setobj(L, &_vv, $VALROOT);
                        obj2arr(_t, cast_uint(_actual_i), &_vv);
                        $BARRIER
                        titan_array_set_length(_t, _actual_i);
                    }
                }
            ]], {
                CASTATS = castats,
                CISTATS = cistats,
                CAEXP = caexp,
                CIEXP = ciexp,
                SETVV = setslot(etype, "&_vv", cexp),
                ARRROOT = arrroot,
                VALROOT = valroot,
                BARRIER = barrier,
                BADINDEX = codethrow(var.loc,
                    "%s:%d:%d: array index must be positive",
                    { c_string_literal(var.loc.filename),
                      c_integer_literal(var.loc.line),
                      c_integer_literal(var.loc.col) }),
            })
        elseif exp1type == "Type.Map" then
            local map = var.exp1
            local key = var.exp2
            local cmstats, cmexp, keyprep, tmpkslot
            if lvalue then
                cmstats, cmexp = "", assert(lvalue.map)
                keyprep, tmpkslot = "", assert(lvalue.keyslot)
            else
                cmstats, cmexp = codeexp(ctx, map)
                local ckstats, ckexp = codeexp(ctx, key)
                local ctmpk, tmpkname
                ctmpk, tmpkname, tmpkslot =
                    newtmp(ctx, key._type, true)
                keyprep = render([[
                    $CKSTATS
                    $CTMPK
                    $TMPKNAME = $CKEXP;
                    $SETSLOTK
                ]], {
                    CKSTATS = ckstats,
                    CTMPK = ctmpk,
                    TMPKNAME = tmpkname,
                    CKEXP = ckexp,
                    SETSLOTK =
                        setboxed(ctx, key._type, tmpkslot, tmpkname),
                })
            end

            return render([[
                {
                    $CMSTATS
                    Table *_t = $CMEXP;
                    $KEYPREP

                    TValue _vv;
                    $SETVV
                    $STORE
                    $BARRIER
                }
            ]], {
                CMSTATS = cmstats,
                CMEXP = cmexp,
                KEYPREP = keyprep,
                SETVV = setboxed(ctx, etype, "&_vv", cexp),
                STORE = set_table_entry(
                    ctx, key._type, "_t", tmpkslot, "&_vv"),
                BARRIER = types.is_gc(map._type.values)
                          and "luaC_barrierback(L, obj2gco(_t), &_vv);" or ""
            })
        elseif types.is_direct_c(var.exp1._type) then
            local spill = spill_update(coder._lvalue_root_decl(var))
            local parts, indexprep
            if lvalue then
                local basetype = assert(lvalue.cbase_type)
                local baseexp = assert(lvalue.cbase)
                local checks = {}
                if basetype._tag == "Type.CPointer" then
                    table.insert(checks,
                        coder._prepared_c_null_check(var, baseexp))
                else
                    table.insert(checks, coder._prepared_c_bounds_check(
                        var, assert(lvalue.cindex),
                        assert(lvalue.clength)))
                end
                parts = {
                    bstats = "",
                    idxname = assert(lvalue.cindex),
                    baseexp = baseexp,
                }
                indexprep = table.concat(checks, "\n")
            else
                parts = codecindex_parts(ctx, var)
                indexprep = render([[
                    $ISTATS
                    $CIDX
                    $IDX = $IEXP;
                    $BOUNDS
                ]], {
                    ISTATS = parts.istats,
                    CIDX = parts.cidx,
                    IDX = parts.idxname,
                    IEXP = parts.iexp,
                    BOUNDS = parts.bounds,
                })
            end
            return render([[
                {
                    $BSTATS
                    $INDEXPREP
                    $BASE[$IDX] = $CEXP;
                    $SPILL
                }
            ]], {
                BSTATS = parts.bstats,
                INDEXPREP = indexprep,
                IDX = parts.idxname,
                BASE = parts.baseexp,
                CEXP = cexp,
                SPILL = spill,
            })
        end
    else
        error("invalid tag for lvalue of assignment: " .. vtag)
    end
end

-- Lua evaluates an indexed assignment's container and key before its RHS.
-- Materialize the Array lvalue explicitly so the backing stays in a scanned
-- root while the index and RHS run, then let codeassignment perform only the
-- mutation.  (The backing is non-moving, but it may otherwise be reachable
-- solely through a transient C local returned by a call.)
function coder._materialize_array_lvalue(ctx, var)
    local castats, caexp = codeexp(ctx, var.exp1)
    local cta, taname, taslot = newtmp(ctx, var.exp1._type, true)
    local cistats, ciexp = codeexp(ctx, var.exp2)
    local cti, tiname = newtmp(ctx, var.exp2._type)
    return render([[
        $CASTATS
        $CTA
        $TANAME = $CAEXP;
        $ANCHOR
        $CISTATS
        $CTI
        $TINAME = $CIEXP;
    ]], {
        CASTATS = castats,
        CTA = cta,
        TANAME = taname,
        CAEXP = caexp,
        ANCHOR = setslot(var.exp1._type, taslot, taname),
        CISTATS = cistats,
        CTI = cti,
        TINAME = tiname,
        CIEXP = ciexp,
    }), {
        array = taname,
        index = tiname,
    }
end

-- Every assignment freezes its effectful target operands before evaluating
-- the RHS. Multiple assignment applies the same preparation in lexical LHS
-- order across target kinds, so an Array target cannot leapfrog a preceding
-- record, Map, or C target. The returned descriptor retains GC owners/keys in
-- scanned slots; codeassignment performs only final-target validation and
-- mutation.
function coder._materialize_assignment_lvalue(ctx, var)
    if var._tag == "Ast.VarDot" and var._decl then
        if var._decl._tag == "Type.Field" then
            local stats, name = materialize(ctx, var.exp)
            return stats, { record = name }
        elseif var._decl._tag == "Type.CField" then
            local stats, base = coder._prepare_c_base(ctx, var.exp)
            return stats, {
                cfield_base = base.base,
                cfield_type = base.type,
                cfield_indirect = base.indirect,
            }
        end
        return "", nil
    elseif var._tag ~= "Ast.VarBracket" then
        return "", nil
    end

    local basetype = var.exp1._type
    if basetype._tag == "Type.Array" then
        assert(basetype.isconst.tag == "no",
            "const Array lvalue reached code generation")
        return coder._materialize_array_lvalue(ctx, var)
    elseif basetype._tag == "Type.Map" then
        local mapstats, mapexp = codeexp(ctx, var.exp1)
        local mapdecl, mapname, mapslot =
            newtmp(ctx, basetype, true)
        local keystats, keyexp = codeexp(ctx, var.exp2)
        local keydecl, keyname, keyslot =
            newtmp(ctx, var.exp2._type, true)
        return render([[
            $MAPSTATS
            $MAPDECL
            $MAPNAME = $MAPEXP;
            $ANCHORMAP
            $KEYSTATS
            $KEYDECL
            $KEYNAME = $KEYEXP;
            $ANCHORKEY
        ]], {
            MAPSTATS = mapstats,
            MAPDECL = mapdecl,
            MAPNAME = mapname,
            MAPEXP = mapexp,
            ANCHORMAP = setslot(basetype, mapslot, mapname),
            KEYSTATS = keystats,
            KEYDECL = keydecl,
            KEYNAME = keyname,
            KEYEXP = keyexp,
            ANCHORKEY =
                setboxed(ctx, var.exp2._type, keyslot, keyname),
        }), {
            map = mapname,
            keyslot = keyslot,
        }
    elseif types.is_direct_c(basetype) then
        local basestats, base =
            coder._prepare_c_base(ctx, var.exp1)
        local indexstats, indexname = materialize(ctx, var.exp2)
        return basestats .. "\n" .. indexstats, {
            cbase = base.base,
            cbase_type = base.type,
            cindex = indexname,
            clength = base.length,
        }
    end
    error("invalid bracket lvalue type " .. types.tostring(basetype))
end

-- Evaluate a checker-adjusted finite expression list once in lexical order.
-- Values delivered to fixed sink slots use the supplied stabilizer; ordinary
-- sinks default to traced materialization, while native-call sites supply
-- `coder._freeze_code` so arguments remain C-only. Explicit surplus expressions are
-- forced for effect and never acquire a fake sink/output position.
function coder._codeadjustedfixed(ctx, node, stabilize)
    stabilize = stabilize or materialize_code
    local adjusted = node._result_adjustment
        or { exps = node.exps, fixed = node.exps, tail_scalars = {},
             discards = {}, open_source = nil }
    assert(not adjusted.open_source and #adjusted.tail_scalars == 0)
    local fixed_index, discard_set = {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local stats, names, exptypes = {}, {}, {}
    for _, exp in ipairs(adjusted.exps) do
        local cstats, cexp = codeexp(ctx, exp)
        local i = fixed_index[exp]
        if i then
            local mstats, name
            local sink = node.vars and node.vars[i]
            local storage = sink and sink._nominal_storage
            if storage and storage.kind == "fixed_aggregate"
               and types.resolve_c_typedef(storage.storage_type)._tag
                   == "Type.CArray" then
                -- A whole nominal array assignment copies its value now,
                -- before a later RHS can mutate the source or another target
                -- can overwrite bytes shared by this source.
                name = fresh_lowering_name(ctx, "_nominal_array_copy_")
                mstats = cstats .. "\nunsigned char " .. name .. "[sizeof("
                    .. cdeclarator.render_declaration(storage.storage_type, "")
                    .. ")];\nmemcpy(" .. name .. ", " .. cexp
                    .. ", sizeof(" .. name .. "));"
            elseif types.is_direct_c(exp._type)
               and not types.is_gc(exp._type) then
                -- Initialize directly: aggregates can contain const members
                -- and therefore support initialization but not C assignment.
                local decl
                decl, name = newforeigntmp(ctx, exp._type, cexp)
                mstats = render([[
                    $CSTATS
                    $DECL
                ]], {
                    CSTATS = cstats,
                    DECL = decl,
                    NAME = name,
                    EXP = cexp,
                })
            else
                mstats, name = stabilize(ctx, exp._type,
                    cstats, cexp)
            end
            table.insert(stats, mstats)
            names[i], exptypes[i] = name, exp._type
        else
            assert(discard_set[exp] or exp._discard_results)
            table.insert(stats, cstats)
            table.insert(stats, "(void)(" .. cexp .. ");")
        end
    end
    return stats, names, exptypes
end

function codesingleassignment(ctx, node)
    local var = node.vars[1]
    local lvalue_stats, lvalue =
        coder._materialize_assignment_lvalue(ctx, var)
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    table.insert(stats, 1, lvalue_stats)
    table.insert(stats, codeassignment(ctx, var,
        assert(tmps[1]), assert(exptypes[1]), lvalue))
    return table.concat(stats, "\n")
end

function codemultiassignment(ctx, node)
    local lvalue_stats = {}
    local lvalues = {}
    for i, var in ipairs(node.vars) do
        local stats, lvalue =
            coder._materialize_assignment_lvalue(ctx, var)
        if stats ~= "" then
            table.insert(lvalue_stats, stats)
        end
        lvalues[i] = lvalue
    end
    local stats, tmps, exptypes = coder._codeadjustedfixed(ctx, node)
    table.insert(stats, 1, table.concat(lvalue_stats, "\n"))
    for i, var in ipairs(node.vars) do
        if tmps[i] then
            table.insert(stats,
                codeassignment(ctx, var, tmps[i], exptypes[i],
                    lvalues[i]))
        end
    end
    return table.concat(stats, "\n")
end

-- A `StatTry` body/catch is emitted as straight-line C inside an inline setjmp
-- boundary, so the `lua_longjmp _lj` is an automatic of an inner C scope. A
-- `return` that jumps out of the whole native function, or a `break` that jumps
-- out of an enclosing loop, must first restore `L->errorJmp` (and `nCcalls`) to
-- the values they held BEFORE the protected region was entered, or `L->errorJmp`
-- would dangle to an out-of-scope `_lj`. We snapshot those once at function entry
-- (`_entry_errorjmp`/`_entry_nC`) and at each loop entry whose body contains a
-- try (`_loop_errorjmp_N`/`_loop_nC_N`), then restore at the crossing transfer.
-- Only emitted when a try is actually in scope, to keep try-free code untouched.
function restore_entry_errorjmp()
    return [[
        L->errorJmp = _entry_errorjmp;
        L->nCcalls = _entry_nC;]]
end

-- Pending-action discriminator values (B.3). A `StatTry` with a finally records,
-- on every exit of its protected region, a pending action; the finally runs
-- straight-line; then an if-chain dispatch (NEVER a C `switch`, which would
-- capture the PA_BREAK arm's `break`) performs it. PA_NONE falls through.
PA_NONE   = "0"

PA_RETURN = "1"

PA_BREAK  = "2"

PA_RAISE  = "3"

-- Compute the per-return saved-value storage for a try-with-finally (B.4 "GC
-- anchoring"). Fixed results use stack-anchored slots for GC types and
-- `volatile` C temps for non-GC scalars. A flexible result gets frame-owned
-- backing plus a volatile count; GC-bearing elements also get a parallel range
-- of traced Lua-stack slots. The descriptor itself is deliberately not used:
-- the pending frame owns its backing until dispatch copies it to the caller.
function make_return_frame(ctx, id)
    local rettypes = ctx.rettypes or {}
    local saves = {}
    local decls = {}
    for i = 1, #rettypes do
        local typ = rettypes[i]
        local cvar = "_pa_ret_" .. id .. "_" .. i
        local isgc = types.is_gc(typ)
        local slot
        if isgc then
            -- GC saved return: anchor in a reserved stack slot so it survives the
            -- finally (which may allocate / run the GC). The C temp just caches a
            -- copy; the slot is the live root.
            slot = reserveslot(ctx)
            table.insert(decls, render("$VQ$CT $CVAR = $INIT;", {
                VQ = "", CT = ctype(typ), CVAR = cvar, INIT = initval(typ),
            }))
        else
            -- Non-GC saved return: a plain C temp. The whole native function is a
            -- setjmp scope, so mark it volatile (the value is set before the
            -- finally — which may longjmp out on a raise — and read in dispatch).
            table.insert(decls, render("$CT volatile $CVAR = $INIT;", {
                CT = ctype(typ), CVAR = cvar, INIT = initval(typ),
            }))
        end
        -- A try-with-finally that contains no `return` leaves these temps written
        -- nowhere (or, for GC types, written but only ever read via the slot), so
        -- silence -Wunused-variable / -Wunused-but-set unconditionally.
        table.insert(decls, "(void)" .. cvar .. ";")
        saves[i] = { typ = typ, cvar = cvar, slot = slot }
    end
    local flex = nil
    if ctx.flexrettype then
        local capacity = ctx.inline_return and ctx.inline_return.flex.capacity or 200
        local args = "_pa_flexargs_" .. id
        local count = "_pa_flexcount_" .. id
        local root_depth
        if types.is_gc(ctx.flexrettype) then
            root_depth = ctx.depth
            for _ = 1, capacity do reserveslot(ctx) end
        end
        table.insert(decls, render([[
            $ELEM $ARGS[$CAPACITY] = {0};
            int volatile $COUNT = 0;
            (void)$ARGS;
            (void)$COUNT;
        ]], {
            ELEM = ctype(ctx.flexrettype),
            CAPACITY = capacity == 200 and "TITAN_VARARG_MAX"
                or c_integer_literal(math.max(capacity, 1)),
            ARGS = args,
            COUNT = count,
        }))
        flex = {
            elem = ctx.flexrettype,
            args = args,
            count = count,
            root_depth = root_depth,
            start = "0",
            capacity = capacity,
            ownership = "pending",
        }
    end
    return {
        id = id,
        fixed = saves,
        flex = flex,
    }, table.concat(decls, "\n")
end

function coder._saved_fixed_value(save)
    if save.slot then
        return getslot(save.typ, nil, slotat(save.slot))
    end
    return save.cvar
end

function coder._flex_root(flex, index)
    if not flex.root_depth then return "" end
    return setslot(flex.elem,
        "s2v(" .. stackslotat(flex.root_depth) .. " + " .. index .. ")",
        flex.args .. "[" .. index .. "]")
end

-- Clear the live root prefix from a previous, partially evaluated pending
-- return, then reset the count before a body/catch return starts evaluating.
-- A conversion can longjmp after publishing earlier elements, so the count is
-- volatile and is the authoritative prefix length on recovery.
function coder._reset_pending_flex(flex)
    if not flex then return "" end
    if flex.slots then
        local lines = {}
        for _, save in ipairs(flex.slots) do
            table.insert(lines, coder._option_nil(save.typ, save.cvar))
            if save.slot then
                table.insert(lines, "setnilvalue(" .. slotat(save.slot) .. ");")
            end
        end
        table.insert(lines, flex.count .. " = 0;")
        return table.concat(lines, "\n")
    end
    local clear = ""
    if flex.root_depth then
        clear = render([[
            for (int _pa_clear_i = 0; _pa_clear_i < $COUNT; _pa_clear_i++) {
                setnilvalue2s($ROOT + _pa_clear_i);
            }
        ]], {
            COUNT = flex.count,
            ROOT = stackslotat(flex.root_depth),
        })
    end
    return clear .. "\n" .. flex.count .. " = 0;"
end

-- Emit the real function epilogue for a return saved by a finally frame. Read
-- fixed roots and copy the complete flexible run before resetting `L->top`;
-- after that reset no allocation occurs before control reaches the caller.
function dispatch_return_epilogue(ctx, frame)
    if ctx.inline_return then
        return coder._finish_immediate_return(ctx, frame)
    end
    local from = frame.fixed
    local lines = {}
    -- restore the errorjmp chain to the function-entry values (this return is
    -- crossing the finally's torn-down boundary back to the caller)
    ctx.used_entry_restore = true
    table.insert(lines, restore_entry_errorjmp())
    -- Read each saved value into a fresh C temp BEFORE resetting the stack top:
    -- a GC saved return lives in a slot at `_base + d` (>= _base), so reading it
    -- after `L->top.p = _base` would touch a slot above top. No allocation runs
    -- here, so the temps hold valid (register-held) values across the reset.
    for i = 1, #from do
        local name = "_pa_dret_" .. frame.id .. "_" .. i
        table.insert(lines, render("$DECL = $READ;", {
            DECL = cvardecl(ctx, from[i].typ, name),
            READ = coder._saved_fixed_value(from[i]),
        }))
    end
    if frame.flex then
        table.insert(lines, render([[
            int _pa_dflex_count_$ID = (int)$COUNT;
            for (int _pa_dflex_i_$ID = 0;
                 _pa_dflex_i_$ID < _pa_dflex_count_$ID;
                 _pa_dflex_i_$ID++) {
                _flexout->args[_pa_dflex_i_$ID] = $ARGS[_pa_dflex_i_$ID];
            }
            _flexout->n_args = (lu_byte)_pa_dflex_count_$ID;
        ]], {
            ID = c_integer_literal(frame.id),
            COUNT = frame.flex.count,
            ARGS = frame.flex.args,
        }))
    end
    table.insert(lines, "L->top.p = _base;")
    for i = 2, #from do
        table.insert(lines, "*_outparam_" .. i .. " = _pa_dret_"
            .. frame.id .. "_" .. i .. ";")
    end
    if #from == 0 then
        table.insert(lines, "return;")
    else
        table.insert(lines, "return _pa_dret_" .. frame.id .. "_1;")
    end
    return table.concat(lines, "\n")
end

-- A `return`/`break` inside the body or catch of an enclosing try-with-finally
-- is NOT realized as the real control transfer: it sets that try's pending
-- action (+ saves the return values), then `goto`s the try's `_finally` label so
-- the finally still runs before the action is performed (B.3 rule d/h). The
-- innermost enclosing try-with-finally is `ctx.finally_stack[#ctx.finally_stack]`.
function innermost_finally(ctx)
    local fs = ctx.finally_stack
    return fs and fs[#fs] or nil
end

function push_boundary(ctx, tag)
    ctx.protected_boundary_stack = ctx.protected_boundary_stack or {}
    table.insert(ctx.protected_boundary_stack, tag)
end

function pop_boundary(ctx)
    assert(ctx.protected_boundary_stack and #ctx.protected_boundary_stack > 0)
    table.remove(ctx.protected_boundary_stack)
end

-- A pending return/break that jumps to a finally label leaves the C scope of
-- every inline boundary opened between the target try and the current point.
-- Restore those `lua_longjmp` links before the `goto`; otherwise a raise from
-- the finally would longjmp to an out-of-scope `_lj_*` object. Stop at `floor`
-- so outer still-active boundaries remain installed and can catch/cascade a
-- raise from the finally (the plan's inside-out finally semantics).
function restore_boundaries_to(ctx, floor)
    local bs = ctx.protected_boundary_stack or {}
    local lines = {}
    for i = #bs, floor + 1, -1 do
        table.insert(lines, render([[
            L->errorJmp = _lj_$T.previous;
            L->nCcalls = _oldnC_$T;
        ]], { T = bs[i] }))
    end
    return table.concat(lines, "\n")
end

function coder._adjusted_return(node)
    local adjusted = node._result_adjustment
    if not adjusted then
        -- Compatibility for hand-built ASTs: the checker normally publishes
        -- the richer adjustment record on every return.
        adjusted = { exps = node.exps, fixed = node.exps,
            tail_scalars = {}, discards = {}, open_source = nil }
    end
    return adjusted
end

-- Peel only checker-synthesized sink coercions from a statically visible
-- flexible-tail expression. A user-written explicit cast is unmarked and is
-- therefore part of the carrier evaluation even when the caller discards that
-- tail position.
function coder._implicit_tail_carrier(exp)
    local carrier = exp
    while carrier._tag == "Ast.ExpCast" and carrier._implicit_coercion do
        carrier = carrier.exp
    end
    return carrier
end

-- Rebuild the peeled implicit-cast chain over an already materialized carrier.
-- This lets the carrier run exactly once in lexical order while the target
-- checks/conversions remain inside the caller's remaining-result guard.
function coder._retarget_implicit_tail(exp, carrier, replacement)
    if exp == carrier then return replacement end
    assert(exp._tag == "Ast.ExpCast" and exp._implicit_coercion)
    local copy = {}
    for key, value in pairs(exp) do copy[key] = value end
    copy.exp = coder._retarget_implicit_tail(exp.exp, carrier, replacement)
    return copy
end

-- Lower the checker's return adjustment into either the caller's real ABI
-- destination or a finally frame. Both destinations use this exact lexical
-- walk, so fixed projections, effect-only surplus expressions, explicit tail
-- scalars, open runs, conversions, truncation, and cleanup stay identical.
-- Returns the emitted statements and (for a direct return) its fixed holders.
function coder._lower_return_to_destination(ctx, node, destination)
    local adjusted = coder._adjusted_return(node)
    local fixed_index, tail_set, discard_set = {}, {}, {}
    for i, exp in ipairs(adjusted.fixed) do fixed_index[exp] = i end
    for _, exp in ipairs(adjusted.tail_scalars) do tail_set[exp] = true end
    for _, exp in ipairs(adjusted.discards) do discard_set[exp] = true end

    local cstats, fixednames = {}, {}
    local flex = destination.flex
    local want = ctx.flexwant or "_flexwant"
    local openrun
    local tail_seen = 0
    if flex and destination.kind == "direct" then
        local suffix = tostring(ctx.tmp)
        ctx.tmp = ctx.tmp + 1
        flex.count = "_flexcount_" .. suffix
        table.insert(cstats, "int " .. flex.count .. " = 0;")
        table.insert(cstats, "_flexout->n_args = 0;")
    elseif flex then
        table.insert(cstats, coder._reset_pending_flex(flex))
    end

    local function append_flexible(setup, value)
        assert(flex)
        return render([[
            if ($WANT == LUA_MULTRET || $COUNT < $WANT) {
                $SETUP
                if (TITAN_UNLIKELY($COUNT >= TITAN_VARARG_MAX)) {
                    luaL_error(L, "too many flexible return values (max %d)",
                        (int)TITAN_VARARG_MAX);
                }
                $WRITE
                $COUNT++;
            }
        ]], {
            COUNT = flex.count,
            SETUP = setup,
            WANT = want,
            WRITE = coder._store_flex_result(flex, flex.count, value),
        })
    end

    -- Walk the checker's lexical expression list exactly once. Sink values are
    -- materialized (and GC-rooted when necessary); explicit surplus expressions
    -- are still forced for effect but never mapped to a native out-parameter.
    for _, exp in ipairs(adjusted.exps) do
        local fi = fixed_index[exp]
        local istail = tail_set[exp]
        local carrier = istail and coder._implicit_tail_carrier(exp) or exp
        local cs, ce
        if coder._carries_open_source(exp, adjusted.open_source) then
            assert(flex)
            -- The open producer may also expose statically visible fixed
            -- results that the checker mapped into the flexible tail. Reserve
            -- their positions before asking the producer for its dynamic run;
            -- generic value calls perform element conversion while building
            -- that run, so over-requesting even one element can raise on a
            -- value that the inherited finite result budget would discard.
            local pending_tail = #adjusted.tail_scalars - tail_seen
            cs, ce, openrun = coder._code_open_source(ctx,
                adjusted.open_source, render([[
                (($WANT == LUA_MULTRET) ? LUA_MULTRET
                    : (($WANT > ($COUNT + $PENDING))
                        ? ($WANT - $COUNT - $PENDING) : 0))
            ]], {
                COUNT = flex.count,
                PENDING = c_integer_literal(pending_tail),
                WANT = want,
            }), "(" .. want .. " == LUA_MULTRET)", carrier)
        else
            cs, ce = codeexp(ctx, carrier)
        end
        if fi then
            -- The checker deliberately stops annotating statements after an
            -- always-escaping construct. C emission still visits that dead
            -- syntax, so use the destination type when such an unreachable
            -- return expression has no `_type` annotation.
            local sinktype = exp._type
                or (destination.fixed and destination.fixed[fi]
                    and destination.fixed[fi].typ)
                or ctx.rettypes[fi]
            local mstats, name = materialize_code(ctx,
                assert(sinktype), cs, ce)
            table.insert(cstats, mstats)
            if destination.fixed then
                local save = destination.fixed[fi]
                if save then
                    table.insert(cstats, save.cvar .. " = " .. name .. ";")
                else
                    table.insert(cstats, "(void)" .. name .. ";")
                end
                if save and save.slot then
                    -- Publish the frame root immediately: a later return
                    -- expression may allocate or relocate the Lua stack.
                    table.insert(cstats,
                        setslot(save.typ, slotat(save.slot), save.cvar))
                end
            else
                fixednames[fi] = name
            end
        elseif istail then
            -- Evaluate and stabilize the written carrier regardless of demand;
            -- return expressions retain their ordinary effects/order. Only the
            -- checker-inserted conversion to the flexible element type belongs
            -- to the result sink and is suppressed when this position is beyond
            -- the inherited finite budget.
            local carrier_type = assert(carrier._type or exp._type)
            local carrier_stats, carrier_name = materialize_code(ctx,
                carrier_type, cs, ce)
            table.insert(cstats, carrier_stats)
            local conversion_stats, value = "", carrier_name
            if carrier ~= exp then
                local replacement = {
                    _tag = "Ast.VarName",
                    _type = carrier_type,
                    _decl = { _cvar = carrier_name },
                }
                local converted = coder._retarget_implicit_tail(exp,
                    carrier, replacement)
                conversion_stats, value = codeexp(ctx, converted)
            end
            table.insert(cstats,
                append_flexible(conversion_stats, value))
            tail_seen = tail_seen + 1
        else
            -- This includes declared explicit surplus. `codeexp` supplies any
            -- setup statements; `(void)` forces bare foreign/scalar calls too.
            assert(coder._carries_open_source(exp, adjusted.open_source)
                or discard_set[exp] or exp._discard_results)
            table.insert(cstats, cs)
            table.insert(cstats, "(void)(" .. ce .. ");")
        end
    end
    if openrun then
        openrun.adjustment = assert(adjusted.open_adjustment,
            "open return expression lacks its checker adjustment")
        -- A direct flexible-output descriptor is untraced. Most open sources
        -- borrow durable provenance, but function-valued Map __index can
        -- produce fresh collectables and an element conversion can allocate a
        -- fresh wrapper. Keep every still-live result in its own ordinary VM
        -- result slot until the native caller consumes the completed buffer.
        -- Pending-finally destinations already own an equivalent root range.
        local read_root_depth = flex.root_depth
        if not flex.slots and not read_root_depth
           and (openrun.retain_read_results
                or coder._adjustment_allocates_gc(openrun.adjustment)) then
            read_root_depth = ctx.depth
            for _ = 1, 200 do reserveslot(ctx) end
        end
        local result_stack = read_root_depth and ("("
            .. stackslotat(read_root_depth) .. " + " .. flex.count .. ")")
            or nil
        local result_root = result_stack
            and ("s2v(" .. result_stack .. ")") or nil
        local convstats, convexp = coder._convert_result_run_element(
            ctx, openrun, flex.elem, "_ori", node.loc,
            result_root, result_stack)
        local adjustment_allocates =
            coder._adjustment_allocates_gc(openrun.adjustment)
        if adjustment_allocates and not flex.slots then
            assert(result_root,
                "allocating open return adjustment lacks its selected root")
        end
        -- An allocating adjustment already published its final value into the
        -- sink-selected slot. Otherwise publish the assigned result here: the
        -- slot may still be required for a retained read or ordinary GC output.
        local root = adjustment_allocates and ""
            or (result_root
                and setslot(flex.elem, result_root,
                    flex.args .. "[" .. flex.count .. "]")
                or coder._flex_root(flex, flex.count))
        table.insert(cstats, render([[
            lua_Unsigned _open_return_count =
                (lua_Unsigned)($RUNCOUNT);
            if ($WANT != LUA_MULTRET) {
                int _open_return_remaining = $WANT - $COUNT;
                if (_open_return_remaining < 0)
                    _open_return_remaining = 0;
                if (_open_return_count >
                        (lua_Unsigned)_open_return_remaining)
                    _open_return_count =
                        (lua_Unsigned)_open_return_remaining;
            }
            if (TITAN_LIKELY(
                    _open_return_count <=
                        (lua_Unsigned)TITAN_VARARG_MAX
                            - (lua_Unsigned)$COUNT)) {
                /* the complete consumed run fits before its loop */
            } else {
                luaL_error(L,
                    "too many flexible return values (max %d)",
                    (int)TITAN_VARARG_MAX);
            }
            for (lua_Unsigned _ori = 0;
                 _ori < _open_return_count; _ori++) {
                if ($WANT == LUA_MULTRET || $COUNT < $WANT) {
                    if (TITAN_UNLIKELY($COUNT >= TITAN_VARARG_MAX)) {
                        luaL_error(L, "too many flexible return values (max %d)",
                            (int)TITAN_VARARG_MAX);
                    }
                    $CONVSTATS
                    $WRITE
                    $COUNT++;
                }
            }
            $CLEANUP
        ]], {
            RUNCOUNT = openrun.count,
            COUNT = flex.count,
            CONVSTATS = convstats,
            WANT = want,
            WRITE = flex.slots
                and coder._store_flex_result(flex, flex.count, convexp)
                or (flex.args .. "[" .. flex.count .. "] = "
                    .. convexp .. ";\n" .. root),
            CLEANUP = coder._cleanup_result_run(openrun),
        }))
    end
    if flex and destination.kind == "direct" then
        table.insert(cstats,
            "_flexout->n_args = (lu_byte)" .. flex.count .. ";")
    end
    return cstats, fixednames
end

function codereturn(ctx, node)
    -- Route through an enclosing finally: evaluate into the innermost frame,
    -- publish RETURN only after every conversion and root write succeeded, then
    -- tear down the crossed boundaries and enter the finally.
    local fin = innermost_finally(ctx)
    if fin then
        fin.label_used = true
        local cstats = coder._lower_return_to_destination(ctx, node, {
            kind = "pending",
            fixed = fin.fixed,
            flex = fin.flex,
        })
        table.insert(cstats, fin.pa_var .. " = " .. PA_RETURN .. ";")
        table.insert(cstats,
            restore_boundaries_to(ctx, fin.boundary_floor))
        table.insert(cstats, "goto " .. fin.label .. ";")
        return table.concat(cstats, "\n")
    end

    if ctx.inline_return then
        local stats = coder._lower_return_to_destination(
            ctx, node, ctx.inline_return)
        table.insert(stats, coder._finish_immediate_return(ctx))
        return table.concat(stats, "\n")
    end

    -- Clean-exit restore (#3): a `return` crossing one or more protected regions
    -- must put L->errorJmp/nCcalls back to their function-entry values before the
    -- epilogue, so the dangling inner `_lj` is never reachable.
    local crossing = ctx.try_depth and ctx.try_depth > 0
    if crossing then ctx.used_entry_restore = true end
    local restore = crossing and restore_entry_errorjmp() .. "\n" or ""
    local destination = {
        kind = "direct",
        flex = ctx.flexrettype and {
            elem = ctx.flexrettype,
            args = "_flexout->args",
            ownership = "direct",
        } or nil,
    }
    local cstats, fixednames = coder._lower_return_to_destination(ctx, node,
        destination)

    -- Always reset the stack top to _base on return. Read/copy the fixed
    -- results only after every lexical expression has executed, but before the
    -- final native return; no allocation occurs during this handoff.
    for i = 2, #ctx.rettypes do
        table.insert(cstats,
            "*_outparam_" .. i .. " = " .. assert(fixednames[i]) .. ";")
    end
    table.insert(cstats, restore)
    table.insert(cstats, "L->top.p = _base;")
    if #ctx.rettypes == 0 then
        table.insert(cstats, "return;")
    else
        table.insert(cstats, "return " .. assert(fixednames[1]) .. ";")
    end
    return table.concat(cstats, "\n")
end

-- `raise <exp>`: evaluate the (already `value`-coerced) operand into an anchored
-- temp, place it in the one top slot required by Lua's error ABI, then
-- `lua_error(L)`. The
-- entry wrapper ensured `errorhandler` is active on `L->errfunc`, so the longjmp
-- through `lua_error` runs that handler, which builds the unified Lua+Titan trace before
-- unwinding. The temp is a `value`-typed (GC) TValue, so `newtmp` anchors it in a
-- reserved stack slot; that anchor keeps it alive across the internal raising
-- stack-growth path (which may run the GC and reallocate the stack) before we
-- copy it to the new top.
-- An `emitline` stamps the throw to the raise's exact `.titan` line so the native
-- frame symbolizes there (mirrors `codethrow`).
function coderaise(ctx, node)
    if not node.exp then
        -- Bare `raise` (re-raise) — legal only inside a catch (checker-enforced).
        -- Reinstall the catch's saved `traceback` into registry[TITAN_BACKTRACE_KEY]
        -- and SET the pin (TITAN_TRACE_PINNED), so errorhandler KEEPS the ORIGINAL
        -- trace rather than capturing a fresh one at this (shallower) re-raise
        -- site; then place the saved `error` in Lua's error-object slot and call
        -- lua_error(L). The enclosing catch's implicit locals are threaded
        -- through ctx (`ctx.catch_*_decl`).
        local errcvar = ctx.catch_error_decl._cvar      -- TValue (the error value)
        local tbcvar = ctx.catch_traceback_decl._cvar   -- TString* (the trace)
        ctx.raise_id = (ctx.raise_id or 0) + 1
        local raise_id = ctx.raise_id
        ctx.uses_base_off = true
        return render([[
            TValue _reraise_trace_$ID;
            TValue _reraise_pin_$ID = {0};
            setsvalue(L, &_reraise_trace_$ID, $TB);
            setbtvalue(&_reraise_pin_$ID);
            titan_registry_set_string(
                L, TITAN_BACKTRACE_KEY, &_reraise_trace_$ID);
            titan_registry_set_string(
                L, TITAN_TRACE_PINNED, &_reraise_pin_$ID);
            _base = restorestack(L, _base_off);
            titan_ensure_stack(L, 1);
            setobj2s(L, L->top.p, &$ERR);
            L->top.p++;
            $LINEDIR
            lua_error(L);
        ]], {
            ID = raise_id,
            LINEDIR = emitline(node),
            TB = tbcvar,
            ERR = errcvar,
        })
    end
    local cstats, cexp = codeexp(ctx, node.exp)
    local ctmp, tmpname, tmpslot = newtmp(ctx, types.Value(), true)
    return render([[
        $CSTATS
        $CTMP
        $TMPNAME = $CEXP;
        $ANCHOR
        titan_ensure_stack(L, 1);
        setobj2t(L, s2v(L->top.p), &$TMPNAME);
        L->top.p++;
        $LINEDIR
        lua_error(L);
    ]], {
        CSTATS = cstats,
        CTMP = ctmp,
        TMPNAME = tmpname,
        CEXP = cexp,
        ANCHOR = setslot(types.Value(), tmpslot, tmpname),
        LINEDIR = emitline(node),
    })
end

-- Find the innermost enclosing finally frame that is in the SAME target loop as a
-- `break` issued at the current point (i.e. opened at or below the innermost
-- loop). A break inside a finally-protected region must run that finally before it
-- can reach the loop; if there is none in the loop, the break is realized directly
-- (restore loop errorjmp + goto past the loop). `ctx.loopstack`/`ctx.finally_stack`
-- reflect the lexical context of the call site.
function enclosing_break_finally(ctx)
    local fs = ctx.finally_stack
    if not fs or #fs == 0 then return nil end
    local loop_len = ctx.loopstack and #ctx.loopstack or 0
    local fin = fs[#fs]
    -- The frame is between the break and the innermost loop iff it was opened while
    -- that loop (or a deeper one) was already on the stack.
    if fin.loopstack_len >= loop_len and loop_len > 0 then
        return fin
    end
    return nil
end

-- Realize a `break` at the current point: if an enclosing finally lies between the
-- break and its target loop, route through it (set pending BREAK, goto its
-- finally); otherwise restore the loop-entry errorjmp/nC (if a try boundary is
-- open) and `goto` the label past the enclosing loop (NOT a bare `break`, which a
-- dispatch if-chain could not safely sit inside). Used by both the StatBreak arm
-- and the PA_BREAK dispatch arm (which chains finallys inside-out).
function realize_break(ctx)
    local fin = enclosing_break_finally(ctx)
    if fin then
        fin.label_used = true
        return render([[
            $PA = $PABREAK;
            $RESTORE
            goto $LABEL;
        ]], {
            PA = fin.pa_var,
            PABREAK = PA_BREAK,
            RESTORE = restore_boundaries_to(ctx, fin.boundary_floor),
            LABEL = fin.label,
        })
    end
    -- direct break: target the innermost loop frame, restoring its entry errorjmp
    -- if a try boundary is open between here and the loop entry.
    local frame = ctx.loopstack and ctx.loopstack[#ctx.loopstack]
    assert(frame, "internal error: break with no enclosing loop")
    frame.uses_after_label = true
    local restore = ""
    if frame.save_id and (ctx.try_depth or 0) > frame.try_depth then
        frame.used = true
        restore = render([[
            L->errorJmp = _loop_errorjmp_$ID;
            L->nCcalls = _loop_nC_$ID;
        ]], { ID = c_integer_literal(frame.save_id) })
    end
    return render([[
        $RESTORE
        goto $AFTER;
    ]], { RESTORE = restore, AFTER = "_after_loop_" .. frame.after_id })
end

-- The pending-action dispatch if-chain emitted after a finally (B.3 rule i). Never
-- a C `switch` (which would capture PA_BREAK's `break`). PA_RETURN/PA_BREAK chain
-- through any enclosing finally; PA_RAISE reinstalls the saved trace + pin and
-- re-raises; PA_NONE falls through.
function dispatch_after_finally(ctx, pa_var, frame, d_pa_err, d_pa_tb)
    -- RETURN arm: chain to an outer finally if one encloses this try, else emit
    -- the real return epilogue with the saved values.
    local outer_fin = innermost_finally(ctx)
    local return_arm
    if outer_fin then
        outer_fin.label_used = true
        -- Copy this try's complete pending return into the outer frame. Inner
        -- roots stay live until every outer backing/root write and the final
        -- count publication are complete. Only then publish RETURN, restore all
        -- boundaries crossed by the goto, and enter the outer finally.
        local lines = {}
        for i = 1, #frame.fixed do
            local from = frame.fixed[i]
            local to = outer_fin.fixed[i]
            table.insert(lines,
                to.cvar .. " = " .. coder._saved_fixed_value(from) .. ";")
            if to.slot then
                table.insert(lines, setslot(to.typ, slotat(to.slot), to.cvar))
            end
        end
        if frame.flex then
            assert(outer_fin.flex)
            local copy_count = "_pa_copy_count_" .. frame.id
                .. "_" .. outer_fin.id
            local copy_index = "_pa_copy_i_" .. frame.id
                .. "_" .. outer_fin.id
            table.insert(lines, coder._reset_pending_flex(outer_fin.flex))
            table.insert(lines, "int " .. copy_count .. " = (int)"
                .. frame.flex.count .. ";")
            table.insert(lines, render([[
                for (int $INDEX = 0; $INDEX < $COPYCOUNT; $INDEX++) {
                    $TOARGS[$INDEX] = $FROMARGS[$INDEX];
                    $ROOT
                }
                $TOCOUNT = $COPYCOUNT;
            ]], {
                INDEX = copy_index,
                COPYCOUNT = copy_count,
                TOARGS = outer_fin.flex.args,
                FROMARGS = frame.flex.args,
                ROOT = coder._flex_root(outer_fin.flex, copy_index),
                TOCOUNT = outer_fin.flex.count,
            }))
        end
        table.insert(lines, outer_fin.pa_var .. " = " .. PA_RETURN .. ";")
        table.insert(lines,
            restore_boundaries_to(ctx, outer_fin.boundary_floor))
        table.insert(lines, "goto " .. outer_fin.label .. ";")
        return_arm = table.concat(lines, "\n")
    else
        return_arm = dispatch_return_epilogue(ctx, frame)
    end

    -- BREAK arm: chain through enclosing finallys or break past the loop. Only a
    -- try that is itself inside a loop can ever observe a pending BREAK (a break in
    -- the body/catch targets the innermost ENCLOSING loop; a break to a loop
    -- written inside the body is handled by that inner loop's own frame). With no
    -- enclosing loop, PA_BREAK is unreachable, so emit nothing.
    local break_arm = (ctx.loopstack and #ctx.loopstack > 0)
        and realize_break(ctx) or "/* unreachable: no enclosing loop */ ;"

    -- RAISE arm: reinstall the saved trace + pin (preserve original trace), put
    -- the saved error in Lua's one required error-object slot, and lua_error.
    ctx.uses_base_off = true
    local raise_arm = render([[
        TValue _pa_trace_$ID;
        TValue _pa_pin_$ID = {0};
        TValue _pa_error_$ID;
        setobj(L, &_pa_trace_$ID, $PATB);
        setbtvalue(&_pa_pin_$ID);
        setobj(L, &_pa_error_$ID, $PAERR);
        titan_registry_set_string(
            L, TITAN_BACKTRACE_KEY, &_pa_trace_$ID);
        titan_registry_set_string(
            L, TITAN_TRACE_PINNED, &_pa_pin_$ID);
        _base = restorestack(L, _base_off);
        titan_ensure_stack(L, 1);
        setobj2s(L, L->top.p, &_pa_error_$ID);
        L->top.p++;
        lua_error(L);
    ]], {
        ID = frame.id,
        PATB = slotat(d_pa_tb),
        PAERR = slotat(d_pa_err),
    })

    return render([[
        if ($PA == $PARETURN) {
            $RETARM
        } else if ($PA == $PABREAK) {
            $BREAKARM
        } else if ($PA == $PARAISE) {
            $RAISEARM
        }
        /* PA_NONE: fall through past the try */
    ]], {
        PA = pa_var,
        PARETURN = PA_RETURN,
        PABREAK = PA_BREAK,
        PARAISE = PA_RAISE,
        RETARM = return_arm,
        BREAKARM = break_arm,
        RAISEARM = raise_arm,
    })
end

-- The "save" prologue of an inline setjmp boundary (rawrunprotected save), tagged
-- with `tag` so a try with two boundaries (body + catch) keeps distinct locals.
function boundary_save(tag)
    return render([[
        /* inline protected boundary (rawrunprotected save) */
        l_uint32 _oldnC_$T = L->nCcalls;
        CallInfo *_oldci_$T = L->ci;
        lu_byte _oldah_$T = L->allowhook;
        ptrdiff_t _oldtop_$T = savestack(L, L->top.p);
        ptrdiff_t _olderrfunc_$T = L->errfunc;
        lua_longjmp _lj_$T;
        _lj_$T.status = LUA_OK;
        _lj_$T.previous = L->errorJmp;
        L->errorJmp = &_lj_$T;
        if (TITAN_SETJMP(_lj_$T.b) == 0) {
    ]], { T = tag })
end

-- The "tail" that closes a boundary's protected block and restores the
-- error-handler chain (rawrunprotected tail), opening the `if (status != OK)`
-- recovery arm and saving the caught error into slot `d_err` and its snapshotted
-- trace into slot `d_tb`. The caller supplies the recovery body and closes braces.
function boundary_recover_open(ctx, tag, d_err, d_tb)
    return render([[
        }
        /* restore the error-handler chain (rawrunprotected tail) */
        L->errorJmp = _lj_$T.previous;
        L->nCcalls = _oldnC_$T;
        if (_lj_$T.status != LUA_OK) {
            /* raised; errorhandler already filled the trace slot. Mirror
             * luaD_pcall's recovery: restore ci/allowhook, close any to-be-
             * closed vars from called Lua, materialize the error object. */
            L->ci = _oldci_$T;
            L->allowhook = _oldah_$T;
            /* A longjmp can skip an inner Titan Lua-entry wrapper before that
             * wrapper restores L->errfunc. Put the boundary-entry message
             * handler back before closing Lua frames, so any __close error is
             * handled by a valid Titan errorhandler instead of a stale stack
             * slot from the skipped inner entry. */
            L->errfunc = _olderrfunc_$T;
            _lj_$T.status = luaD_closeprotected(L, _oldtop_$T, _lj_$T.status);
            luaD_seterrorobj(L, _lj_$T.status, restorestack(L, _oldtop_$T));
            /* a value-call or another stack-growing operation inside the protected
             * region may have reallocated the stack; recompute _base before
             * touching any reserved slot */
            _base = restorestack(L, _base_off);
            /* Save the error object into its anchored slot, then drop it from the
             * top. Registry bookkeeping below uses Lua internals directly and
             * does not borrow the Lua stack. */
            setobj2s(L, $ERRSTACK, s2v(L->top.p - 1));
            L->top.p = restorestack(L, _oldtop_$T);
            /* snapshot registry[TITAN_BACKTRACE_KEY] into the traceback slot */
            TValue _caught_trace_$T;
            lu_byte _caught_trace_tag_$T = titan_registry_get_string(
                L, TITAN_BACKTRACE_KEY, &_caught_trace_$T);
            if (tagisempty(_caught_trace_tag_$T)
                    || !ttisstring(&_caught_trace_$T)) {
                TString *_empty_trace_$T = luaS_newliteral(L, "");
                setsvalue(L, &_caught_trace_$T, _empty_trace_$T);
            }
            (void)_caught_trace_tag_$T;
            _base = restorestack(L, _base_off);
            setobj2s(L, $TBSTACK, &_caught_trace_$T);
            /* clear slot + pin so a fresh error raised later is captured anew
             * (a bare re-raise re-pins the saved trace) */
            TValue _cleared_trace_$T = {0};
            setnilvalue(&_cleared_trace_$T);
            titan_registry_set_string(
                L, TITAN_BACKTRACE_KEY, &_cleared_trace_$T);
            titan_registry_set_string(
                L, TITAN_TRACE_PINNED, &_cleared_trace_$T);
            _base = restorestack(L, _base_off);
            /* re-establish the function's steady-state reserved top
             * (`_base + nslots`) so any reserved slots used in the recovery sit
             * below L->top.p and are GC-scanned. The literal nslots is patched in
             * by codefuncdec/codelambdadec once the high-water mark is known. */
            L->top.p = _base + TITAN_RESERVED_NSLOTS;
            $SPILLRELOAD
    ]], {
        T = tag,
        ERRSTACK = stackslotat(d_err),
        TBSTACK = stackslotat(d_tb),
        SPILLRELOAD = spill_reload(ctx),
    })
end

-- `catch`/`finally` codegen.
--
-- A StatTry wraps its body in an inline setjmp boundary that replicates
-- luaD_rawrunprotected + luaD_pcall's error recovery, emitted as straight-line C
-- in the native function (no thunk, no capture conversion). The Lua entry wrapper
-- already ensured errorhandler is active on L->errfunc, and luaG_errormsg invokes
-- it regardless of which boundary is on L->errorJmp, so the unified trace is
-- already in registry[TITAN_BACKTRACE_KEY] by the time the longjmp lands here.
--
-- Per-try anchored slots (reserveslot -> depths within the function's _base..nslots
-- region) hold the caught error value and the snapshotted trace string; a write
-- into a stack slot needs no GC barrier (the stack is a root).
--
-- Boundary accounting (B.4): the BODY always gets a boundary. A CATCH gets its
-- OWN boundary only when a FINALLY follows (so a raise in the catch still runs the
-- finally); without a finally a catch error propagates to the outer boundary.
-- A FINALLY itself installs no boundary: it is straight-line,
-- and a raise/runtime error in it longjmps out, skipping the dispatch (override).
function codetry(ctx, node)
    -- A function containing a try always needs `_base` recomputed from an offset
    -- after a caught longjmp (a value-call or GC inside the body may have
    -- relocated the stack), so force the base-offset preamble.
    ctx.uses_base_off = true
    ctx.try_id = (ctx.try_id or 0) + 1
    local id = ctx.try_id
    local has_finally = node.finallyblock and true or false
    local has_catch = node.catchblock and true or false

    -- Reserve the per-try anchored slots up front (depths persist across the body,
    -- catch, and finally). The recovery recomputes addresses inline from a freshly
    -- restored `_base`, so only the depth index is needed.
    local d_err = reserveslot(ctx)   -- the BODY-boundary caught error
    local d_tb = reserveslot(ctx)    -- ... and its snapshotted trace
    -- For a try-with-finally, the pending RAISE carries its own saved error +
    -- trace slots (set on a body raise with no catch, or on a catch raise), since
    -- the dispatch re-raises after the finally runs.
    local d_pa_err, d_pa_tb
    if has_finally then
        d_pa_err = reserveslot(ctx)
        d_pa_tb = reserveslot(ctx)
    end

    -- Per-try pending-action discriminator + saved-return storage (finally only).
    local pa_var = "_pa_" .. id
    local fin_label = "_finally_" .. id
    local ret_frame, ret_decls, fin_frame
    if has_finally then
        ret_frame, ret_decls = make_return_frame(ctx, id)
        -- Push the finally frame so body/catch `return`/`break` route here. Record
        -- the current loop nesting so a break can decide whether an OUTER finally
        -- in the same target loop must also run (chaining).
        ctx.finally_stack = ctx.finally_stack or {}
        ret_frame.pa_var = pa_var
        ret_frame.label = fin_label
        ret_frame.loopstack_len = ctx.loopstack and #ctx.loopstack or 0
        ret_frame.boundary_floor = ctx.protected_boundary_stack
            and #ctx.protected_boundary_stack or 0
        ret_frame.label_used = false -- set when return/break gotos it
        table.insert(ctx.finally_stack, ret_frame)
        fin_frame = ret_frame
    end

    -- The body and catch run as protected straight-line C. Within them, a
    -- `return`/`break` that escapes a NON-finally try must clean-exit-restore the
    -- errorjmp chain (#3); for a finally try, return/break route to the finally
    -- instead (codereturn / the StatBreak arm consult ctx.finally_stack first).
    ctx.try_depth = (ctx.try_depth or 0) + 1
    push_boundary(ctx, tostring(id))
    local cbody = node.block._defer_tail
        and codetransparentblock(ctx, node.block)
        or codestat(ctx, node.block)
    if ctx.entry_try == node then
        -- A function-scope catch is also the safety boundary for a trusted
        -- native entry (for example the coroutine and libuv dispatchers).
        -- Install its jump target before the entry GC step: an emergency-GC
        -- allocation failure must land in the Titan catch, never unwind across
        -- the native caller's stack. Callback domains reserve LUA_MINSTACK
        -- before entry, so the non-raising stack reservation preamble remains
        -- safe outside this boundary.
        cbody = [[
            luaC_checkGC(L);
            _base = restorestack(L, _base_off);
        ]] .. cbody
    end
    pop_boundary(ctx)
    ctx.try_depth = ctx.try_depth - 1

    -- Bind the catch's implicit locals to C autos populated in the recovery.
    local errcvar = "_catch_error_" .. id
    local tbcvar = "_catch_tb_" .. id
    local ccatch = ""
    if has_catch then
        local errdecl = node._error_decl
        local tbdecl = node._traceback_decl
        errdecl._cvar = errcvar
        tbdecl._cvar = tbcvar
        local saved_err, saved_tb = ctx.catch_error_decl, ctx.catch_traceback_decl
        ctx.catch_error_decl = errdecl
        ctx.catch_traceback_decl = tbdecl
        ctx.try_depth = ctx.try_depth + 1
        if has_finally then push_boundary(ctx, id .. "c") end
        ccatch = codestat(ctx, node.catchblock)
        if has_finally then pop_boundary(ctx) end
        ctx.try_depth = ctx.try_depth - 1
        ctx.catch_error_decl, ctx.catch_traceback_decl = saved_err, saved_tb
    end

    -- Pop the finally frame BEFORE coding the finally block: a `return`/`break`
    -- inside the finally must NOT loop back to this finally (it would be illegal —
    -- the checker bans escaping return/break in a finally — and a contained break
    -- targets a loop opened inside the finally, handled by the normal loop frame).
    if has_finally then
        table.remove(ctx.finally_stack)
    end
    local cfinally = has_finally and codestat(ctx, node.finallyblock) or ""

    if not has_finally then
        -- Body boundary; on error, materialize+bind catch locals
        -- and run the catch directly (no own boundary — its raise propagates out).
        return render([[
            {
                $SAVE
                    $CBODY
                $RECOVER
                    TValue $ERR = *$ERRSLOT;
                    TString *$TB = tsvalue($TBSLOT);
                    (void)$ERR;
                    (void)$TB;
                    $CCATCH
                }
            }
        ]], {
            SAVE = boundary_save(tostring(id)),
            CBODY = cbody,
            RECOVER = boundary_recover_open(ctx, tostring(id), d_err, d_tb),
            CCATCH = ccatch,
            ERR = errcvar,
            TB = tbcvar,
            ERRSLOT = slotat(d_err),
            TBSLOT = slotat(d_tb),
        })
    end

    -- ===== try WITH finally =====

    -- On a caught error with NO catch: stash error+trace into the PA_RAISE slots
    -- and set pending RAISE (reinstall the original trace when re-raising).
    local no_catch_raise = render([[
        setobj2t(L, $PAERR, $ERR);
        setsvalue(L, $PATB, tsvalue($TB));
        $PA = $PARAISE;
    ]], {
        PAERR = slotat(d_pa_err),
        PATB = slotat(d_pa_tb),
        ERR = slotat(d_err),
        TB = slotat(d_tb),
        PA = pa_var,
        PARAISE = PA_RAISE,
    })

    -- The catch body, run under ITS OWN boundary so a raise in it still runs the
    -- finally. The body boundary's recovery binds the catch locals, then opens a
    -- second boundary around the catch; on a catch error -> stash to PA_RAISE
    -- slots + pending RAISE; on catch normal completion the pending stays whatever
    -- the body set it to (NONE unless a return/break in the body routed here, but
    -- a body that raised reached here by error, so it is NONE -> finally swallows).
    local catch_under_boundary = ""
    if has_catch then
        catch_under_boundary = render([[
            TValue $ERR = *$ERRSLOT;
            TString *$TB = tsvalue($TBSLOT);
            (void)$ERR;
            (void)$TB;
            $CSAVE
                $CCATCH
            $CRECOVER
                $NOCATCHRAISE
            }
        ]], {
            ERR = errcvar,
            TB = tbcvar,
            ERRSLOT = slotat(d_err),
            TBSLOT = slotat(d_tb),
            CSAVE = boundary_save(id .. "c"),
            CCATCH = ccatch,
            CRECOVER = boundary_recover_open(ctx, id .. "c", d_err, d_tb),
            NOCATCHRAISE = no_catch_raise,
        })
    else
        -- finally-only: a body error becomes a pending RAISE re-propagated after
        -- the finally (rule c).
        catch_under_boundary = no_catch_raise
    end

    local dispatch = dispatch_after_finally(ctx, pa_var, ret_frame,
        d_pa_err, d_pa_tb)

    local tmpl
    if node._defer_tail then
        tmpl = [[
            int $PA = $PANONE;
            $RETDECLS
            $SAVE
                $CBODY
            $RECOVER
                $CATCHARM
            }
            $FINLABEL
            $CFINALLY
            /* dispatch the pending action (if-chain — never a C switch, which
             * would capture the PA_BREAK arm's `break`) */
            $DISPATCH
        ]]
    else
        tmpl = [[
            {
                int $PA = $PANONE;
                $RETDECLS
                {
                    $SAVE
                        $CBODY
                    $RECOVER
                        $CATCHARM
                    }
                }
                $FINLABEL
                $CFINALLY
                /* dispatch the pending action (if-chain — never a C switch, which
                 * would capture the PA_BREAK arm's `break`) */
                $DISPATCH
            }
        ]]
    end

    return render(tmpl, {
        PA = pa_var,
        PANONE = PA_NONE,
        RETDECLS = ret_decls,
        SAVE = boundary_save(tostring(id)),
        CBODY = cbody,
        RECOVER = boundary_recover_open(ctx, tostring(id), d_err, d_tb),
        CATCHARM = catch_under_boundary,
        FINLABEL = fin_frame.label_used and (fin_label .. ": ;") or "",
        CFINALLY = cfinally,
        DISPATCH = dispatch,
    })
end

function localname(ctx, name)
    local idx = ctx.names[name] or 1
    ctx.names[name] = idx + 1
    return name .. "_" .. tostring(idx)
end

function forin_is_nil(typ, cexp)
    if coder._is_native_option(typ) then
        return "!(" .. coder._option_present(typ, cexp) .. ")"
    elseif typ._tag == "Type.Option" or typ._tag == "Type.Value" then
        return "ttisnil(&" .. cexp .. ")"
    elseif types.is_c_tvalue(typ) then
        return "ttisnil(&" .. cexp .. ")"
    elseif types.resolve_c_typedef(typ)._tag == "Type.CPointer" then
        return "(" .. cexp .. " == NULL)"
    elseif typ._tag == "Type.Nil" then
        return "1"
    else
        return "0"
    end
end

function code_hidden_decl(ctx, decl, exp, prepared)
    local typ = decl._type
    local cstats, cexp
    if prepared then
        cstats, cexp = "", prepared
    else
        cstats, cexp = codeexp(ctx, exp)
    end
    decl._cvar = "_forin_" .. localname(ctx, decl.name)
    local cset = ""
    if types.is_gc(typ) then
        decl._slot = newslot(ctx)
        cset = setslot(typ, decl._slot, decl._cvar)
    end
    return render([[
        $CSTATS
        $CDECL
        $CVAR = $CEXP;
        (void)$CVAR;
        $CSET
    ]], {
        CSTATS = cstats,
        CDECL = cvardecl(ctx, typ, decl._cvar) .. " = " .. initval(typ) .. ";",
        CVAR = decl._cvar,
        CEXP = cexp,
        CSET = cset,
    })
end

function code_hidden_result_decls(ctx, decls)
    local out = {}
    for _, decl in ipairs(decls) do
        local typ = decl._type
        decl._cvar = "_forin_" .. localname(ctx, decl.name)
        if types.is_gc(typ) then
            decl._slot = newslot(ctx)
        end
        table.insert(out, cvardecl(ctx, typ, decl._cvar)
            .. " = " .. initval(typ) .. ";")
    end
    return table.concat(out, "\n")
end

function predeclare_defer_tail(ctx, block)
    local out = {}
    local function visit_block(b)
        for _, stat in ipairs(b.stats) do
            if stat._tag == "Ast.StatDecl" then
                for _, decl in ipairs(stat.decls) do
                    if decl._used and not (decl._captured and decl._assigned)
                       and not decl._defer_tail_predeclared then
                        decl._defer_tail_predeclared = true
                        local plan = decl._c_allocation_plan
                        if plan and plan.storage:match("^automatic") then
                            local declaration =
                                coder._codeautomaticallocationdecl(ctx, decl)
                            if declaration ~= "" then
                                table.insert(out, declaration)
                            end
                            decl._c_allocation_predeclared = true
                            decl._defer_tail_spill_predeclared = true
                        else
                            decl._cvar = "_local_" .. localname(ctx, decl.name)
                            if decl._c_zero_init then
                                table.insert(out,
                                    cvardecl(ctx, decl._type, decl._cvar)
                                    .. " = {0};")
                                decl._c_zero_predeclared = true
                            else
                                table.insert(out,
                                    cvardecl(ctx, decl._type, decl._cvar) .. ";")
                            end
                            local spill = decl._c_zero_init
                                and spill_decl_init(ctx, decl)
                                or spill_decl_zero(ctx, decl)
                            if spill ~= "" then
                                decl._defer_tail_spill_predeclared = true
                                table.insert(out, spill)
                            end
                        end
                    end
                end
            elseif stat._tag == "Ast.StatTry" and stat._defer_tail then
                visit_block(stat.block)
            end
        end
    end
    visit_block(block)
    return table.concat(out, "\n")
end

function code_hidden_assign(decl, cexp)
    local cset = ""
    if types.is_gc(decl._type) then
        cset = setslot(decl._type, decl._slot, decl._cvar)
    end
    return render([[
        $CVAR = $CEXP;
        $CSET
    ]], {
        CVAR = decl._cvar,
        CEXP = cexp,
        CSET = cset,
    })
end

function code_forin_call(ctx, call, result_decls)
    local cstats, cexp = codeexp(ctx, call)
    local out = { cstats }
    if result_decls[1] then
        table.insert(out, code_hidden_assign(result_decls[1], cexp))
    end
    for i = 2, #result_decls do
        table.insert(out, code_hidden_assign(result_decls[i], call._extras[i]))
    end
    return table.concat(out, "\n")
end

function codeforinrun(ctx, node)
    local forin = node.forin
    local initcall = code_forin_call(ctx, forin._init_call, forin._result_decls)
    local visible = codestat(ctx, forin._visible_stat)
    local body = codestat(ctx, forin.block)
    local nextcall = code_forin_call(ctx, forin._next_call, forin._result_decls)
    local ctrl = forin._result_decls[1]
    return render([[
        $INITCALL
        while (1) {
            if ($ISNIL) {
                break;
            }
            $VISIBLE
            $BODY
            $NEXTCALL
            luaC_checkGC(L);
            _base = restorestack(L, _base_off);
        }
    ]], {
        INITCALL = initcall,
        ISNIL = forin_is_nil(ctrl._type, ctrl._cvar),
        VISIBLE = visible,
        BODY = body,
        NEXTCALL = nextcall,
    })
end

function codeforin(ctx, node)
    pushd(ctx)
    ctx.uses_base_off = true
    local tuple, tuplevalues = coder._codeadjustedfixed(ctx, {
        _result_adjustment = node._tuple_adjustment,
        exps = node.exps,
    })
    for i, decl in ipairs(node._tuple_decls) do
        table.insert(tuple,
            code_hidden_decl(ctx, decl, node.exps[i], tuplevalues[i]))
    end
    table.insert(tuple, code_hidden_result_decls(ctx, node._result_decls))

    local frame = open_loop(ctx, node)
    local runnode = { _tag = "Ast.StatForInRun", loc = node.loc, forin = node }
    local loopcode
    if node._has_close then
        local closestat = {
            _tag = "Ast.StatCall",
            loc = node.loc,
            callexp = node._close_call,
            _forin_nil_guard = node._runtime_optional_close
                and node._tuple_decls[4] or nil,
        }
        local trynode = {
            _tag = "Ast.StatTry",
            loc = node.loc,
            block = {
                _tag = "Ast.StatBlock",
                loc = node.loc,
                stats = { runnode },
            },
            catchblock = nil,
            finallyblock = {
                _tag = "Ast.StatBlock",
                loc = node.loc,
                stats = { closestat },
            },
        }
        loopcode = codestat(ctx, trynode)
    else
        loopcode = codestat(ctx, runnode)
    end
    close_loop(ctx)
    popd(ctx)

    return render([[
        {
            $TUPLE
            $LOOPSAVE
            $LOOPCODE
        }$AFTER
    ]], {
        TUPLE = table.concat(tuple, "\n"),
        LOOPSAVE = loop_save_lines(frame),
        LOOPCODE = loopcode,
        AFTER = after_loop_label(frame),
    })
end

function coder._codeautomaticallocationdecl(ctx, decl)
    local plan = assert(decl._c_allocation_plan)
    decl._boxed = false
    if decl._c_allocation_predeclared or not decl._used then return "" end
    local logical = localname(ctx, decl.name)
    local storage = plan.storage
    if storage == "automatic_object" or storage == "automatic_array" then
        decl._cvar = decl._cvar or ("_local_" .. logical)
        return render([[
            $CDECL = {0};
            $CSPILLDECL
        ]], {
            CDECL = cvardecl(ctx, decl._type, decl._cvar),
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    elseif storage == "automatic_array_borrow" then
        local count = assert(plan.array_count_literal)
        local backing = "_foreign_backing_" .. logical
        decl._cvar = decl._cvar or ("_local_" .. logical)
        local array_type = types.CArray(plan.payload_type, count)
        decl._c_backing_storage = {
            address = backing,
            bytes = "sizeof(" .. backing .. ")",
        }
        decl._spill_cvar = "_spill_foreign_backing_" .. logical
        return render([[
            $BACKING = {0};
            $POINTER;
            $POINTER = $BACKING_NAME;
            $CSPILLDECL
        ]], {
            BACKING = coder._render_c_declaration(array_type, backing),
            BACKING_NAME = backing,
            POINTER = coder._render_c_declaration(decl._type, decl._cvar),
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    elseif storage == "automatic_fam" then
        local field = assert(plan.fam_field)
        local array = types.resolve_c_typedef(field.type)
        assert(array._tag == "Type.CArray")
        local count = assert(plan.fam_count_literal)
        local union_name = "_foreign_fam_backing_" .. logical
        local pointer = "_foreign_fam_pointer_" .. logical
        local ctype_name = coder._render_c_declaration(plan.payload_type, "")
        local elem_name = coder._render_c_declaration(array.elem, "")
        local extent = render([[
            ((sizeof($CT) > (offsetof($CT, $FIELD) +
                ((size_t)$COUNT * sizeof($ELEM))))
                ? sizeof($CT)
                : (offsetof($CT, $FIELD) +
                    ((size_t)$COUNT * sizeof($ELEM))))
        ]], {
            CT = ctype_name,
            FIELD = field.name,
            COUNT = c_integer_literal(count),
            ELEM = elem_name,
        })
        decl._cvar = "(*" .. pointer .. ")"
        decl._c_fam_storage = {
            address = union_name .. ".bytes",
            bytes = "sizeof(" .. union_name .. ".bytes)",
        }
        decl._c_backing_storage = decl._c_fam_storage
        decl._spill_cvar = "_spill_foreign_fam_" .. logical
        return render([[
            union {
                $CT _align;
                unsigned char bytes[$EXTENT];
            } $UNION = {0};
            $CT *$POINTER = ($CT *)$UNION.bytes;
            $CSPILLDECL
        ]], {
            CT = ctype_name,
            EXTENT = extent,
            UNION = union_name,
            POINTER = pointer,
            CSPILLDECL = spill_decl_init(ctx, decl),
        })
    end
    error("unsupported automatic C allocation storage " .. tostring(storage))
end

-- Initialize one ordinary local declaration from an already materialized
-- native value. Case payload binders use this same path as source StatDecls so
-- capture boxes, GC roots, and setjmp spills remain one implementation.
function coder._codeinitializeddecl(ctx, decl, cstats, cexp)
    decl._boxed = decl._captured and decl._assigned
    if decl._boxed then
        -- Captured-and-mutated: storage is a heap box (Udata cell). Ordering
        -- avoids an unanchored-box window: freeze+anchor the value, allocate
        -- and anchor the box, then write it with the ordinary barrier.
        local typ = decl._type
        local isgc = types.is_gc(typ)
        local n = localname(ctx, decl.name)
        local ctmp, tmpname, tmpslot = newtmp(ctx, typ, isgc)
        decl._box = "_box_" .. n
        local boxslot = newslot(ctx)
        local anchortmp = tmpslot
            and setslot(typ, tmpslot, tmpname) or ""
        return render([[
            $CSTATS
            $CTMP
            $TMPNAME = $CEXP;
            $ANCHORTMP
            $NEWBOX
            $SETSLOT
        ]], {
            CSTATS = cstats,
            CTMP = ctmp,
            TMPNAME = tmpname,
            CEXP = cexp,
            ANCHORTMP = anchortmp,
            NEWBOX = newbox(ctx, typ, decl._box, boxslot),
            SETSLOT = box_write(typ, decl._box, tmpname),
        })
    elseif decl._used then
        local typ = decl._type
        if not decl._cvar then
            decl._cvar = "_local_" .. localname(ctx, decl.name)
        end
        local cdecl = decl._defer_tail_predeclared
            and "" or cvardecl(ctx, typ, decl._cvar) .. ";"
        local cset = ""
        local cspilldecl = decl._defer_tail_spill_predeclared
            and "" or spill_decl_zero(ctx, decl)
        local cspillset = spill_update(decl)
        if types.is_gc(typ) then
            decl._slot = newslot(ctx)
            cset = render([[
                /* update slot */
                $SETSLOT
            ]], {
                SETSLOT = setslot(typ, decl._slot, decl._cvar),
            })
        end
        return render([[
            $CDECL
            $CSPILLDECL
            $CSTATS
            $CVAR = $CEXP;
            $CSET
            $CSPILLSET
        ]], {
            CDECL = cdecl,
            CSPILLDECL = cspilldecl,
            CSTATS = cstats,
            CVAR = decl._cvar,
            CEXP = cexp,
            CSET = cset,
            CSPILLSET = cspillset,
        })
    end
    return render([[
        $CSTATS
        ((void)$CEXP);
    ]], {
        CSTATS = cstats,
        CEXP = cexp,
    })
end

-- Emit a tag-only switch whose arms live outside the switch. This preserves
-- Titan's enclosing-loop `break` semantics while allowing each arm to be an
-- ordinary full block (including catch/finally and lowered defers).
function coder._codecase(ctx, node)
    ctx.case_id = (ctx.case_id or 0) + 1
    local id = ctx.case_id
    local prefix = "_case_" .. id
    local endlabel = prefix .. "_end"
    local elselabel = prefix .. "_else"
    local scrutinee_stats, scrutinee =
        materialize(ctx, node.exp)
    local dispatch, bodies = {}, {}

    for i, arm in ipairs(node.arms) do
        local label = prefix .. "_arm_" .. (i - 1)
        table.insert(dispatch, render("case $TAG: goto $LABEL;", {
            TAG = c_integer_literal(arm._variant_index),
            LABEL = label,
        }))

        pushd(ctx)
        push_spillscope(ctx)
        local bindings = {}
        for _, binding in ipairs(arm.bindings) do
            local part = assert(binding._part)
            assert(arm._variant.parts[part.index],
                "case binder refers to a missing payload part")
            local plan = coder._nominal_plan(ctx, node.exp._type, arm._variant)
            local reads, value = coder._nominal_read(ctx, plan,
                assert(plan.by_index[part.index]), part.type, scrutinee)
            bindings[#bindings + 1] = coder._codeinitializeddecl(
                ctx, binding, reads, value)
        end
        local block = codestat(ctx, arm.block)
        pop_spillscope(ctx)
        popd(ctx)

        table.insert(bodies, render([[
            $LABEL: {
                $BINDING
                $BLOCK
                goto $END;
            }
        ]], {
            LABEL = label,
            BINDING = table.concat(bindings, "\n"),
            BLOCK = block,
            END = endlabel,
        }))
    end

    local elsebody = ""
    pushd(ctx)
    push_spillscope(ctx)
    if node.elseblock then
        elsebody = codestat(ctx, node.elseblock)
    end
    pop_spillscope(ctx)
    popd(ctx)
    table.insert(bodies, render([[
        $LABEL: {
            $BLOCK
            goto $END;
        }
    ]], {
        LABEL = elselabel,
        BLOCK = elsebody,
        END = endlabel,
    }))

    return render([[
        {
            $SCRUTINEE_STATS
            lua_Integer $TAGNAME = $TAG;
            switch ($TAGNAME) {
                $DISPATCH
                default: goto $ELSE;
            }
            $BODIES
            $END: ;
        }
    ]], {
        SCRUTINEE_STATS = scrutinee_stats,
        TAGNAME = prefix .. "_tag",
        TAG = coder._nominal_tag(scrutinee),
        DISPATCH = table.concat(dispatch, "\n"),
        ELSE = elselabel,
        BODIES = table.concat(bodies, "\n"),
        END = endlabel,
    })
end

function codestat_dispatch(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatDecl" then
        if node._c_zero_init then
            local decl = assert(node.decls[1])
            assert(#node.decls == 1 and #node.exps == 0
                and decl._c_zero_init)
            -- Automatic C aggregates are direct C objects, never adjusted
            -- expression results or closure boxes. An unused object has no
            -- observable initialization, so it may follow the ordinary unused
            -- local elision rule.
            decl._boxed = false
            if not decl._used then return "" end
            if not decl._cvar then
                decl._cvar = "_local_" .. localname(ctx, decl.name)
            end
            if decl._c_zero_predeclared then
                return ""
            end
            return render([[
                $CDECL = {0};
                $CSPILLDECL
            ]], {
                CDECL = cvardecl(ctx, decl._type, decl._cvar),
                CSPILLDECL = spill_decl_init(ctx, decl),
            })
        end

        local has_automatic_allocation = false
        for _, decl in ipairs(node.decls) do
            if decl._c_allocation_plan
               and decl._c_allocation_plan.storage:match("^automatic") then
                has_automatic_allocation = true
                break
            end
        end
        if has_automatic_allocation then
            local code = {}
            local adjusted = assert(node._result_adjustment)
            for i, decl in ipairs(node.decls) do
                local plan = decl._c_allocation_plan
                if plan and plan.storage:match("^automatic") then
                    table.insert(code,
                        coder._codeautomaticallocationdecl(ctx, decl))
                else
                    local exp = assert(adjusted.fixed[i])
                    local cstats, cexp = codeexp(ctx, exp)
                    table.insert(code, coder._codeinitializeddecl(
                        ctx, decl, cstats, cexp))
                end
            end
            return table.concat(code, "\n")
        end

        local code, initnames = coder._codeadjustedfixed(ctx, node)
        for i = 1, #node.decls do
            local decl = node.decls[i]
            table.insert(code, coder._codeinitializeddecl(
                ctx, decl, "", assert(initnames[i])))
        end
        return table.concat(code, "\n")
    elseif tag == "Ast.StatBlock" then
        return codeblock(ctx, node)
    elseif tag == "Ast.StatWhile" then
        return codewhile(ctx, node)
    elseif tag == "Ast.StatRepeat" then
        return coderepeat(ctx, node)
    elseif tag == "Ast.StatIf" then
        return codeif(ctx, node)
    elseif tag == "Ast.StatCase" then
        return coder._codecase(ctx, node)
    elseif tag == "Ast.StatFor" then
        return codefor(ctx, node)
    elseif tag == "Ast.StatForIn" then
        return codeforin(ctx, node)
    elseif tag == "Ast.StatForInRun" then
        return codeforinrun(ctx, node)
    elseif tag == "Ast.StatAssign" then
        if #node.vars == 1 then
            return codesingleassignment(ctx, node)
        else
            return codemultiassignment(ctx, node)
        end
    elseif tag == "Ast.StatCall" then
        local callcode
        if node.callexp._c_pointer_call then
            local fstats, fexp = codecfunctionptrcall(ctx, node.callexp)
            callcode = fstats .. "\n    ((void)(" .. fexp .. "));"
        elseif node.callexp._direct_foreign_reference then
            local fstats, fexp = codeforeigncall(ctx, node.callexp)
            callcode = fstats .. "\n    ((void)(" .. fexp .. "));"
        else
            local cstats, cexp = codecall(ctx, node.callexp)
            callcode = cstats .. "\n    ((void)(" .. cexp .. "));"
        end
        if node._forin_nil_guard then
            local decl = node._forin_nil_guard
            assert(decl._type._tag == "Type.Function" and decl._cvar)
            return render([[
                if (!ttisnil(&$CLOSE)) {
                    $CALL
                }
            ]], {
                CLOSE = decl._cvar,
                CALL = callcode,
            })
        end
        return callcode
    elseif tag == "Ast.StatReturn" then
        return codereturn(ctx, node)
    elseif tag == "Ast.StatBreak" then
        -- A `break` inside the body/catch of an enclosing try-with-finally (in the
        -- same target loop) must run that finally first: set its pending BREAK and
        -- `goto` the finally (which then chains outward or breaks past the loop).
        if enclosing_break_finally(ctx) then
            return realize_break(ctx)
        end
        -- Clean-exit restore (#3): a `break` crossing one or more protected
        -- regions inside its target loop must restore L->errorJmp/nCcalls to the
        -- loop's entry values (saved when the loop body contains a try) before
        -- the C `break`, else L->errorJmp dangles to an out-of-scope `_lj`. The
        -- target loop is the innermost loop frame; a restore is needed only when
        -- a try boundary is open between this break and that loop entry.
        local frame = ctx.loopstack and ctx.loopstack[#ctx.loopstack]
        if frame and frame.save_id and (ctx.try_depth or 0) > frame.try_depth then
            frame.used = true   -- the loop must emit its entry errorjmp/nC save
            return render([[
                L->errorJmp = _loop_errorjmp_$ID;
                L->nCcalls = _loop_nC_$ID;
                break;]], { ID = c_integer_literal(frame.save_id) })
        end
        return "break;"
    elseif tag == "Ast.StatRaise" then
        return coderaise(ctx, node)
    elseif tag == "Ast.StatTry" then
        local predecls = node._defer_tail and predeclare_defer_tail(ctx, node.block) or ""
        local trycode = codetry(ctx, node)
        if predecls == "" then return trycode end
        return predecls .. "\n" .. trycode
    else
        error("invalid node tag " .. tag)
    end
end

-- Prepend a `#line` directive so each statement's generated C attributes back
-- to its .titan source line, then dispatch.
-- The directive is a standalone leading line; codestat_dispatch never splices
-- between multiply-referenced operand slots, so this cannot misattribute or
-- break an un-hoisted operand.
function codestat(ctx, node)
    local code = codestat_dispatch(ctx, node)
    if coder._coverage_source_regions then
        -- Blocks/try machinery own no executable Titan decision. Their real
        -- body/catch/finally statements carry their own nested regions.
        if node._tag == "Ast.StatBlock" then return code end
        if node._tag == "Ast.StatTry" then
            return require("titan-compiler.coverage_lines").region(code, "generated")
        end
        return coverage_region(node, code, ctx)
    end
    return emitline(node) .. code
end

return core.coder

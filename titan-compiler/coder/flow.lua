local core = require "titan-compiler.coder.core"
local _ENV = core

-- A statement after which control never falls through (return/break/raise or a
-- checker-proven infinite loop). The
-- checker does NOT type-check statements that follow such a terminator within a
-- block (they are dead code: their var uses get no `_decl`/`_type`), so the coder
-- MUST NOT attempt to generate them — doing so dereferences those nil
-- annotations. Stopping at the terminator also drops the unreachable C. (This
-- predates error handling: `raise`/`return` followed by any var-using statement
-- always produced unchecked nodes; it only became reachable now that `raise`
-- routinely precedes dead code in try bodies.)
function is_terminator(node)
    return node._tag == "Ast.StatBreak" or node._always_returns == true
end

-- The last statement that control can reach in a function body (the first
-- terminator, or the final statement if none terminates). A function-level
-- `catch` is represented directly by StatTry rather than an outer StatBlock;
-- that whole protected statement is the reachable tail. For an ordinary block,
-- mirror codestats' dead-code stop so this reflects exactly what the coder
-- emitted.
function last_reachable_stat(block)
    if block._tag ~= "Ast.StatBlock" then return block end
    local last
    for _, s in ipairs(block.stats) do
        last = s
        if is_terminator(s) then break end
    end
    return last
end

function set_add(set, decl)
    if decl then set[decl] = true end
end

function set_union(dst, src)
    if not src then return dst end
    for k in pairs(src) do dst[k] = true end
    return dst
end

function set_copy(src)
    return set_union({}, src)
end

-- C `setjmp` correctness (C11 §7.13.2.1): an automatic variable of a function
-- that calls `setjmp`, is changed between that `setjmp` and its matching
-- `longjmp`, and is read after the longjmp has an indeterminate value unless the
-- read is made from volatile-backed storage. We do not make every local/param
-- volatile. Instead this pass marks only Decl objects assigned in a protected
-- region whose post-longjmp path can read them. Codegen then keeps GC values in
-- their existing Lua-stack slots and uses volatile scalar or byte-
-- representation spill storage for non-GC values.
collect_reads_exp, collect_reads_stat, collect_writes_stat = nil, nil, nil

function collect_reads_var(node, out)
    if not node then return out end
    local tag = node._tag
    if tag == "Ast.VarName" then
        set_add(out, node._decl)
    elseif tag == "Ast.VarDot" then
        collect_reads_exp(node.exp, out)
        if node._decl and node._decl._tag == "Ast.Decl" then
            set_add(out, node._decl)
        end
    elseif tag == "Ast.VarBracket" then
        collect_reads_exp(node.exp1, out)
        collect_reads_exp(node.exp2, out)
    end
    return out
end

function collect_lvalue_reads(node, out)
    if not node then return out end
    local tag = node._tag
    if tag == "Ast.VarDot" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.VarBracket" then
        collect_reads_exp(node.exp1, out)
        collect_reads_exp(node.exp2, out)
    end
    return out
end

-- Follow a C aggregate subobject lvalue back to its automatic root. Pointer
-- dereferences deliberately stop the walk: a raw pointer may alias any object,
-- so only direct by-value aggregate storage has a checker-visible root whose
-- complete representation we can commit.
function coder._lvalue_root_decl(node)
    if not node then return nil end
    if node._tag == "Ast.ExpVar" then
        return coder._lvalue_root_decl(node.var)
    elseif node._tag == "Ast.VarName" then
        local decl = node._decl
        if decl and decl._tag == "Ast.Decl" then return decl end
    elseif node._tag == "Ast.VarDot" then
        if node._decl and node._decl._tag == "Type.CField"
           and node.exp and node.exp._type
           and types.is_c_aggregate(node.exp._type) then
            return coder._lvalue_root_decl(node.exp)
        end
    elseif node._tag == "Ast.VarBracket" then
        if node.exp1 and node.exp1._type
           and types.is_c_aggregate(node.exp1._type) then
            return coder._lvalue_root_decl(node.exp1)
        end
    end
    return nil
end

function collect_lvalue_write(node, out)
    set_add(out, coder._lvalue_root_decl(node))
    return out
end

function collect_reads_block(node, out)
    out = out or {}
    if not node then return out end
    for _, stat in ipairs(node.stats) do
        collect_reads_stat(stat, out)
        if is_terminator(stat) then break end
    end
    return out
end

function collect_writes_block(node, out)
    out = out or {}
    if not node then return out end
    for _, stat in ipairs(node.stats) do
        collect_writes_stat(stat, out)
        if is_terminator(stat) then break end
    end
    return out
end

collect_reads_exp = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.VarName" or tag == "Ast.VarDot"
            or tag == "Ast.VarBracket" then
        collect_reads_var(node, out)
    elseif tag == "Ast.ExpVar" then
        collect_reads_var(node.var, out)
    elseif tag == "Ast.ExpInitList" then
        for _, field in ipairs(node.fields) do
            collect_reads_exp(field.exp, out)
        end
    elseif tag == "Ast.ExpCall" then
        collect_reads_exp(node.exp, out)
        for _, arg in ipairs(node.args.args) do
            collect_reads_exp(arg, out)
        end
    elseif tag == "Ast.ExpUnionInit" then
        collect_reads_exp(node.value, out)
    elseif tag == "Ast.ExpUnop" or tag == "Ast.ExpCast"
            or tag == "Ast.ExpIs"
            or tag == "Ast.ExpAdjust" or tag == "Ast.ExpDotsIndex" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpBinop" then
        collect_reads_exp(node.lhs, out)
        collect_reads_exp(node.rhs, out)
    elseif tag == "Ast.ExpConcat" then
        for _, exp in ipairs(node.exps) do
            collect_reads_exp(exp, out)
        end
    elseif tag == "Ast.ExpExtra" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpMethodRef" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.ExpFunction" then
        -- Nested functions/lambdas have their own setjmp scopes and contexts.
    else
        -- literals, ExpDots, ExpDotsLen
    end
    return out
end

function coder._collect_writes_exp(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.VarDot" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.VarBracket" then
        coder._collect_writes_exp(node.exp1, out)
        coder._collect_writes_exp(node.exp2, out)
    elseif tag == "Ast.ExpVar" then
        coder._collect_writes_exp(node.var, out)
    elseif tag == "Ast.ExpInitList" then
        for _, field in ipairs(node.fields) do
            coder._collect_writes_exp(field.exp, out)
        end
    elseif tag == "Ast.ExpCall" then
        for _, decl in ipairs(node._c_mutated_decls or {}) do
            set_add(out, decl)
        end
        coder._collect_writes_exp(node.exp, out)
        for _, arg in ipairs(node.args.args) do
            coder._collect_writes_exp(arg, out)
        end
    elseif tag == "Ast.ExpUnionInit" then
        coder._collect_writes_exp(node.value, out)
    elseif tag == "Ast.ExpUnop" or tag == "Ast.ExpCast"
            or tag == "Ast.ExpIs"
            or tag == "Ast.ExpAdjust" or tag == "Ast.ExpDotsIndex"
            or tag == "Ast.ExpExtra" or tag == "Ast.ExpMethodRef" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.ExpBinop" then
        coder._collect_writes_exp(node.lhs, out)
        coder._collect_writes_exp(node.rhs, out)
    elseif tag == "Ast.ExpConcat" then
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.ExpFunction" then
        -- Nested functions/lambdas have their own setjmp scopes and contexts.
    else
        -- names and literals do not write.
    end
    return out
end

collect_reads_stat = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        collect_reads_block(node, out)
    elseif tag == "Ast.StatDecl" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatAssign" then
        for _, var in ipairs(node.vars) do collect_lvalue_reads(var, out) end
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatCall" then
        collect_reads_exp(node.callexp, out)
    elseif tag == "Ast.StatReturn" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
    elseif tag == "Ast.StatRaise" then
        collect_reads_exp(node.exp, out)
    elseif tag == "Ast.StatWhile" then
        collect_reads_exp(node.condition, out)
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatRepeat" then
        collect_reads_stat(node.block, out)
        collect_reads_exp(node.condition, out)
    elseif tag == "Ast.StatFor" then
        collect_reads_exp(node.start, out)
        collect_reads_exp(node.finish, out)
        collect_reads_exp(node.inc, out)
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatForIn" then
        for _, exp in ipairs(node.exps) do collect_reads_exp(exp, out) end
        collect_reads_stat(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            collect_reads_exp(t.condition, out)
            collect_reads_stat(t.block, out)
        end
        collect_reads_stat(node.elsestat, out)
    elseif tag == "Ast.StatCase" then
        collect_reads_exp(node.exp, out)
        for _, arm in ipairs(node.arms) do
            collect_reads_stat(arm.block, out)
        end
        collect_reads_stat(node.elseblock, out)
    elseif tag == "Ast.StatTry" then
        collect_reads_stat(node.block, out)
        collect_reads_stat(node.catchblock, out)
        collect_reads_stat(node.finallyblock, out)
    else
        -- StatBreak has no reads.
    end
    return out
end

collect_writes_stat = function(node, out)
    out = out or {}
    if not node or node == false then return out end
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        collect_writes_block(node, out)
    elseif tag == "Ast.StatDecl" then
        for _, decl in ipairs(node.decls) do set_add(out, decl) end
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatAssign" then
        for _, var in ipairs(node.vars) do
            collect_lvalue_write(var, out)
            coder._collect_writes_exp(var, out)
        end
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatCall" then
        coder._collect_writes_exp(node.callexp, out)
    elseif tag == "Ast.StatReturn" then
        for _, exp in ipairs(node.exps) do
            coder._collect_writes_exp(exp, out)
        end
    elseif tag == "Ast.StatRaise" then
        coder._collect_writes_exp(node.exp, out)
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
            or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
        if tag == "Ast.StatWhile" or tag == "Ast.StatRepeat" then
            coder._collect_writes_exp(node.condition, out)
        elseif tag == "Ast.StatFor" then
            coder._collect_writes_exp(node.start, out)
            coder._collect_writes_exp(node.finish, out)
            coder._collect_writes_exp(node.inc, out)
        else
            for _, exp in ipairs(node.exps) do
                coder._collect_writes_exp(exp, out)
            end
        end
        if tag == "Ast.StatForIn" then
            for _, decl in ipairs(node.decls) do set_add(out, decl) end
        end
        collect_writes_stat(node.block, out)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(node.thens) do
            coder._collect_writes_exp(t.condition, out)
            collect_writes_stat(t.block, out)
        end
        collect_writes_stat(node.elsestat, out)
    elseif tag == "Ast.StatCase" then
        coder._collect_writes_exp(node.exp, out)
        for _, arm in ipairs(node.arms) do
            set_add(out, arm.binding)
            collect_writes_stat(arm.block, out)
        end
        collect_writes_stat(node.elseblock, out)
    elseif tag == "Ast.StatTry" then
        collect_writes_stat(node.block, out)
        collect_writes_stat(node.catchblock, out)
        collect_writes_stat(node.finallyblock, out)
    end
    return out
end

function mark_spills(assigned, reads)
    for decl in pairs(assigned) do
        if reads[decl] then decl._needs_spill = true end
    end
end

analyze_try_spills_block = nil

function coder._analyze_try_spills_stat(stat, after)
    if not stat or stat == false then return end
    local tag = stat._tag
    if tag == "Ast.StatBlock" then
        analyze_try_spills_block(stat, after)
    elseif tag == "Ast.StatWhile" or tag == "Ast.StatRepeat"
            or tag == "Ast.StatFor" or tag == "Ast.StatForIn" then
        local loop_after = set_copy(after)
        collect_reads_stat(stat, loop_after)
        coder._analyze_try_spills_stat(stat.block, loop_after)
    elseif tag == "Ast.StatIf" then
        for _, t in ipairs(stat.thens) do
            coder._analyze_try_spills_stat(t.block, after)
        end
        coder._analyze_try_spills_stat(stat.elsestat, after)
    elseif tag == "Ast.StatCase" then
        for _, arm in ipairs(stat.arms) do
            coder._analyze_try_spills_stat(arm.block, after)
        end
        coder._analyze_try_spills_stat(stat.elseblock, after)
    elseif tag == "Ast.StatTry" then
        local catch_reads = collect_reads_stat(stat.catchblock)
        local finally_reads = collect_reads_stat(stat.finallyblock)

        -- A body error reaches code after the try only if a catch can handle
        -- it. A finally-only body error re-raises after the finally, so only
        -- the finally can observe body-written values on that longjmp path.
        local body_boundary_reads = set_copy(catch_reads)
        set_union(body_boundary_reads, finally_reads)
        if stat.catchblock then set_union(body_boundary_reads, after) end
        mark_spills(collect_writes_stat(stat.block), body_boundary_reads)

        -- The catch has a protected boundary only when a finally follows; if
        -- it raises, dispatch re-raises after the finally, so post-try code is
        -- not reached on that longjmp path.
        if stat.catchblock and stat.finallyblock then
            mark_spills(collect_writes_stat(stat.catchblock), finally_reads)
        end

        local nested_body_after = set_copy(after)
        set_union(nested_body_after, catch_reads)
        set_union(nested_body_after, finally_reads)
        coder._analyze_try_spills_stat(stat.block, nested_body_after)

        local nested_catch_after = set_copy(after)
        set_union(nested_catch_after, finally_reads)
        coder._analyze_try_spills_stat(stat.catchblock, nested_catch_after)
        coder._analyze_try_spills_stat(stat.finallyblock, after)
    end
end

analyze_try_spills_block = function(block, after_reads)
    if not block or not block.stats then
        coder._analyze_try_spills_stat(block, after_reads or {})
        return
    end
    local stats = {}
    for _, stat in ipairs(block.stats) do
        table.insert(stats, stat)
        if is_terminator(stat) then break end
    end
    local after = set_copy(after_reads or {})
    for i = #stats, 1, -1 do
        local stat = stats[i]
        coder._analyze_try_spills_stat(stat, after)

        local reads = collect_reads_stat(stat)
        if is_terminator(stat) then
            after = reads
        else
            set_union(reads, after)
            after = reads
        end
    end
end

function analyze_try_spills(block)
    analyze_try_spills_block(block, {})
end

-- A non-void/non-nil function whose last reachable statement is something other
-- than a plain `StatReturn` (a `raise`, a proven infinite loop, or a
-- `StatTry`/`if` whose arms do not fall through) falls off the end of the
-- generated C even though Titan control never reaches there: the returns live
-- inside an inner C scope or after a `lua_error` (which Lua 5.5 declares
-- returning `int`, NOT `l_noret`), so the C compiler cannot always prove
-- no-fall-through and warns "control reaches end of non-void function". The
-- checker has already proven the function non-fallthrough, so emit an
-- unreachable trailing `return` of the zero value to satisfy the C control-flow
-- check (dead code; never executed). A function whose last reachable statement
-- IS a `StatReturn` needs nothing (the C return is right there).
function unreachable_return(rettype, block)
    if not rettype or rettype._tag == "Type.Nil" then return nil end
    local last = last_reachable_stat(block)
    if last and last._tag == "Ast.StatReturn" then return nil end
    -- A braced initializer (`{ {0}, 0 }` for TValue-boxed types) is illegal in a
    -- bare `return`, so zero a temp first and return it.
    return render([[
        /* unreachable: no Titan path above falls through; this satisfies the C
         * control-flow check */
        {
            $DECL = $INIT;
            L->top.p = _base;
            return _ur;
        }]], {
            DECL = cvardecl(nil, rettype, "_ur"),
            INIT = initval(rettype),
        })
end

-- The `TitanVarg*` descriptor for a vararg of element type `elemtype`, keyed on
-- `ctype(elemtype)` so its element pointer has the exact C type (§2.F). Mirrors
-- titan.h's seven typedefs.
varg_struct_by_ctype = {
    ["lua_Integer"] = "TitanVargInteger",
    ["lua_Number"]  = "TitanVargFloat",
    ["int"]         = "TitanVargBoolean",
    ["TString*"]    = "TitanVargString",
    ["Table*"]      = "TitanVargArrayOrMap",
    ["TValue"]      = "TitanVargValue",
    ["Udata*"]      = "TitanVargNominal",
}

function varg_struct_name(elemtype --[[:table]])
    -- An owned C value is represented by its owning full Udata, just like a
    -- Titan nominal value. Select this semantically: C declarator rendering
    -- spells the owner as `Udata *`, while the ordinary nominal ctype is
    -- `Udata*`, and ABI selection must not depend on whitespace.
    local resolved = types.resolve_c_typedef(elemtype)
    if resolved and resolved._tag == "Type.COwned" then
        return "TitanVargNominal"
    end
    local ct = ctype(elemtype)
    local name = varg_struct_by_ctype[ct]
    if not name then
        error("no variadic struct for element ctype " .. ct
              .. " (type " .. types.tostring(elemtype) .. ")")
    end
    return name
end

-- The AST `node.params` keeps the trailing vararg marker Decl (`name == false`)
-- even after the checker lifts its element type onto the function type's
-- `varargtype` slot. The coder's param loops generate per-name C parameters, so
-- they must skip that marker (the vararg is emitted separately as the backing
-- struct + start). Returns the fixed-parameter Decls only.
function fixed_params(params)
    local n = #params
    if n > 0 and params[n].name == false then
        local out = {}
        for i = 1, n - 1 do out[i] = params[i] end
        return out
    end
    return params
end

function function_sig(fname, ftype, is_pointer)
    -- Every native entry takes the function's own closure (_fn) right after the
    -- module closure (_mod): NULL on the static path, the callee on a value call,
    -- the wrapper closure in the Lua entry. Closures read captured upvalues from
    -- it; top-level/static/method bodies ignore it. This uniform ABI lets the
    -- value-call fast path dispatch on the type tag alone.
    local params = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    if ftype._tag == "Type.Method" then
        table.insert(params, "Udata*")
    end
    for _, ptype in ipairs(ftype.params) do
        table.insert(params, ctype(ptype))
    end
    -- A variadic function takes its backing struct + start offset right after the
    -- declared params and before the out-params (§5.2). `varargtype` is the Titan
    -- vararg element type (false for non-variadic, and for C-FFI `vararg`).
    if ftype.varargtype then
        table.insert(params, varg_struct_name(ftype.varargtype) .. " *_varargs")
        table.insert(params, "int _start")
    end
    for i = 2, #ftype.rettypes do
        table.insert(params, cpointertype(ftype.rettypes[i]))
    end
    -- A flexible result run is caller-owned typed storage. Keep this pair last
    -- so every fixed-only signature remains byte-for-byte unchanged.
    if ftype.flexrettype then
        table.insert(params,
            varg_struct_name(ftype.flexrettype) .. " *_flexout")
        table.insert(params, "int _flexwant")
    end
    local rettype = ftype.rettypes[1]
    -- A zero-return `() -> ()` function has a `void` native entry. Rendering
    -- the return type around the complete function declarator also handles a
    -- C function-pointer return without losing precedence.
    return cfunctiondecl(
        rettype, fname, table.concat(params, ", "), is_pointer)
end

-- creates a new code generation context for a function
function newcontext(tlcontext)
    return {
        tmp = 1,    -- next temporary index (for generating temporary names)
        nslots = 0, -- number of slots needed by function
        allocations = 0, -- number of allocations
        depth = 0,  -- current stack depth
        dstack = {}, -- stack of stack depths
        prefix = tlcontext.prefix, -- prefix for module member functions and variables
        names = {}, -- map of names to autoincrement suffixes for disambiguation,
        metatables = tlcontext.metatables, -- set of record metatables that we need
        functions = tlcontext.functions, -- set of external functions and methods that we call
        variables = tlcontext.variables, -- set of external variables that we use
        module = tlcontext.module, -- module name,
        modules = tlcontext.modules, -- set of record metatables that we need
        bound_luas = tlcontext.bound_luas, -- external bound-method Lua trampolines we bind
        bound_stricts = tlcontext.bound_stricts,
        tlcontext = tlcontext -- toplevel context
    }
end

-- Address a reserved Lua-stack slot by its stable stack offset. Lua's GC is
-- non-moving, so pointers to GC objects remain valid; only pointers into the
-- Lua stack must be recomputed after an operation that can reallocate it.
function stackslotat(depth --[[:number]])
    return render("(restorestack(L, _base_off) + $DEPTH)", {
        DEPTH = c_integer_literal(depth),
    })
end

function slotat(depth --[[:number]])
    return "s2v(" .. stackslotat(depth) .. ")"
end

function reserveslot(ctx --[[:table]])
    local d = ctx.depth
    ctx.depth = ctx.depth + 1
    ctx.allocations = ctx.allocations + 1
    if ctx.depth > ctx.nslots then ctx.nslots = ctx.depth end
    ctx.uses_base_off = true
    return d
end

function newslot(ctx --[[:table]])
    return slotat(reserveslot(ctx))
end

function decl_needs_spill(decl)
    return decl and decl._needs_spill and decl._used and not decl._boxed
end

function register_spill_decl(ctx, decl)
    if not decl_needs_spill(decl) then return end
    if ctx.spill_decl_seen and ctx.spill_decl_seen[decl] then return end
    ctx.spill_decl_seen = ctx.spill_decl_seen or {}
    ctx.spill_decl_seen[decl] = true
    ctx.active_spill_decls = ctx.active_spill_decls or {}
    table.insert(ctx.active_spill_decls, decl)
end

function spill_cvar(decl)
    if not decl._spill_cvar then
        decl._spill_cvar = "_spill" .. decl._cvar
    end
    return decl._spill_cvar
end

function coder._aggregate_spill_copy(decl, to_spill)
    local spill = spill_cvar(decl)
    local cvar = assert(decl._cvar)
    local address = decl._c_backing_storage
        and decl._c_backing_storage.address or ("&(" .. cvar .. ")")
    local bytes = decl._c_backing_storage
        and decl._c_backing_storage.bytes or ("sizeof(" .. cvar .. ")")
    if to_spill then
        return render([[
            {
                for (size_t _spill_i = 0;
                     _spill_i < $BYTES; _spill_i++) {
                    $SPILL[_spill_i] =
                        ((const unsigned char *)$ADDRESS)[_spill_i];
                }
            }
        ]], {
            SPILL = spill,
            ADDRESS = address,
            BYTES = bytes,
        })
    end
    return render([[
        {
            for (size_t _spill_i = 0;
                 _spill_i < $BYTES; _spill_i++) {
                ((unsigned char *)$ADDRESS)[_spill_i] =
                    $SPILL[_spill_i];
            }
        }
    ]], {
        SPILL = spill,
        ADDRESS = address,
        BYTES = bytes,
    })
end

function spill_decl_init(ctx, decl)
    if not decl_needs_spill(decl) then return "" end
    register_spill_decl(ctx, decl)
    if types.is_gc(decl._type) then
        -- GC values already have a Lua-stack slot. That slot is the stable
        -- storage; no separate C spill is needed.
        return ""
    end
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        local bytes = decl._c_backing_storage
            and decl._c_backing_storage.bytes
            or ("sizeof(" .. decl._cvar .. ")")
        return render([[
            unsigned char volatile $SPILL[$BYTES];
            $COPY
        ]], {
            SPILL = spill_cvar(decl),
            BYTES = bytes,
            COPY = coder._aggregate_spill_copy(decl, true),
        })
    end
    return render([[
        $CT volatile $SPILL = $CVAR;
    ]], {
        CT = ctype(decl._type),
        SPILL = spill_cvar(decl),
        CVAR = decl._cvar,
    })
end

function spill_decl_zero(ctx, decl)
    if not decl_needs_spill(decl) then return "" end
    register_spill_decl(ctx, decl)
    if types.is_gc(decl._type) then return "" end
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        local bytes = decl._c_backing_storage
            and decl._c_backing_storage.bytes
            or ("sizeof(" .. decl._cvar .. ")")
        return render([[
            unsigned char volatile $SPILL[$BYTES] = {0};
        ]], {
            SPILL = spill_cvar(decl),
            BYTES = bytes,
        })
    end
    return render([[
        $CT volatile $SPILL = $INIT;
    ]], {
        CT = ctype(decl._type),
        SPILL = spill_cvar(decl),
        INIT = initval(decl._type),
    })
end

function spill_update(decl)
    if not decl_needs_spill(decl) or types.is_gc(decl._type) then return "" end
    if types.is_c_aggregate(decl._type) or decl._c_backing_storage then
        return coder._aggregate_spill_copy(decl, true)
    end
    return render([[
        $SPILL = $CVAR;
    ]], {
        SPILL = spill_cvar(decl),
        CVAR = decl._cvar,
    })
end

function spill_reload(ctx)
    local decls = ctx.active_spill_decls
    if not decls then return "" end
    local lines = {}
    for _, decl in ipairs(decls) do
        if decl_needs_spill(decl) then
            if types.is_gc(decl._type) then
                if decl._slot then
                    table.insert(lines,
                        getslot(decl._type, decl._cvar, decl._slot) .. ";")
                end
            elseif decl._spill_cvar then
                if types.is_c_aggregate(decl._type)
                   or decl._c_backing_storage then
                    table.insert(lines,
                        coder._aggregate_spill_copy(decl, false))
                else
                    table.insert(lines, render("$CVAR = $SPILL;", {
                        CVAR = decl._cvar,
                        SPILL = decl._spill_cvar,
                    }))
                end
            end
        end
    end
    if #lines == 0 then return "" end
    return "/* reload setjmp-sensitive Titan locals/params */\n"
        .. table.concat(lines, "\n")
end

function newtmp(ctx --[[:table]], typ --[[:table]], isgc --[[:boolean]],
                      initializer --[[:string?]])
    -- Module-level Lua entry wrappers share the translation-unit context but
    -- may be emitted before any native body has needed a temporary. Treat that
    -- as the first allocation just like `fresh_lowering_name`; GC-bearing
    -- temporaries still require an ordinary function context with stack slots.
    local tmp = ctx.tmp or 1
    ctx.tmp = tmp + 1
    local tmpname = "_tmp_" .. tmp
    -- A temporary freezes an expression value, so a C array/function uses its
    -- adjusted pointer representation. Direct array declarators are reserved
    -- for actual object storage (locals/fields), never assignment-based temps.
    local tmptype = (types.is_direct_c(typ) and
        cdeclarator.adjust_parameter_type(typ)) or typ
    if isgc then
        local depth = reserveslot(ctx)
        local slot = slotat(depth)
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, tmptype, tmpname),
            INIT = initializer or initval(typ)
        }), tmpname, slot, stackslotat(depth)
    else
        return render([[
            $DECL = $INIT;
        ]], {
            DECL = cvardecl(ctx, tmptype, tmpname),
            INIT = initializer or initval(typ)
        }), tmpname
    end
end

-- Evaluate already-generated expression code now, exactly once, and keep its
-- value stable across later expression setup. GC-able values are anchored in a
-- reserved stack slot so a subsequent collection cannot sweep them; the slot
-- itself is addressed by offset because a call may reallocate the Lua stack.
function materialize_code(ctx, typ, stats, exp)
    local decl, name, slot = newtmp(ctx, typ, types.is_gc(typ))
    local anchor = slot and setslot(typ, slot, name) or ""
    return render([[
        $STATS
        $DECL
        $NAME = $EXP;
        $ANCHOR
    ]], {
        STATS = stats,
        DECL = decl,
        NAME = name,
        EXP = exp,
        ANCHOR = anchor,
    }), name
end

function materialize(ctx, node)
    local stats, exp = codeexp(ctx, node)
    return materialize_code(ctx, node._type, stats, exp)
end

return core.coder

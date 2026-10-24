local core = require "titan-compiler.coder.core"
local _ENV = core

-- Generate one Lua-stack entry for a Titan function. The ordinary entry is the
-- canonical closure's CClosure.f and applies genuine-Lua dynamic coercions.
-- The strict entry is stored as the closure's final LCF upvalue; it receives
-- the original closure as one hidden first argument and applies gradual tag
-- guards before calling the same native entry.
-- Implementation notes: doc/implementation/lua-interop-internals.md#the-two-lua-stack-entries-genluaentry
function genluaentry(tlcontext, titan_name, titan_entry, typ, loc,
                     lua_name, options)
    options = options or {}
    local strict = options.strict == true
    local hidden = strict and 1 or 0
    local dynamic_plans = options.dynamic_plans
    local strict_plans = options.strict_plans
    local interface_method_index = options.interface_method_index
    if interface_method_index ~= nil then
        assert(not strict and typ._tag == "Type.Method"
            and interface_method_index >= 0,
            "invalid Interface Lua-entry dispatch configuration")
    end
    if not strict then
        assert(type(dynamic_plans) == "table",
            "genuine Lua function entry lacks checker parameter plans")
    else
        assert(type(strict_plans) == "table",
            "strict Titan function entry lacks checker guard plans")
    end
    local storage = options.storage or "TITAN_MODULE_PRIVATE"
    local unavailable_result
    for index, result in ipairs(typ.rettypes) do
        if not types.has_tvalue_representation(result) then
            unavailable_result = "return " .. tostring(index)
                .. " has type '" .. types.tostring(result) .. "'"
            break
        end
    end
    if not unavailable_result and typ.flexrettype
        and not types.has_tvalue_representation(typ.flexrettype) then
        unavailable_result = "flexible return has type '"
            .. types.tostring(typ.flexrettype) .. "'"
    end
    if unavailable_result then
        return render([[
    $STORAGE int $LUANAME(lua_State *L) {
        return luaL_error(L, "%s", $ERROR);
    }]], {
            STORAGE = storage,
            LUANAME = lua_name,
            ERROR = c_string_literal("Titan function '" .. titan_name
                .. "' " .. unavailable_result
                .. ", which has no Lua/TValue representation"),
        })
    end
    local function readfixed(param, cvar, slot, index)
        if strict then
            assert(strict_plans[index] ~= nil,
                "strict Titan function parameter lacks its checker guard")
            return coder._strictcheckandget(
                tlcontext, maybe3.get_checked(strict_plans[index], "parameter guard"), param, cvar, slot, loc,
                "strict Titan function parameter", true)
        end
        assert(dynamic_plans[index] ~= nil,
            "genuine Lua function parameter lacks its checker plan")
        return coder._dynamiccheckandget(
            tlcontext, maybe3.get_checked(dynamic_plans[index], "parameter conversion"), param, cvar, slot, loc,
            "genuine Lua function parameter", true)
    end
    local stats = {}
    local pnames = { "L", "_mod", "_fn" }
    local params
    if typ._tag == "Type.Function" or typ._tag == "Type.StaticMethod" then
        params = typ.params
    else
        assert(typ._tag == "Type.Method")
        params = { types.Nominal(typ.fqtn), table.unpack(typ.params) }
    end
    -- Closure tags describe callable signatures, not named declarations.
    -- Static namespaces publish this same Function shape; retaining a
    -- StaticMethod tag here would reject its own non-exact strict calls.
    local callable_type = types.Function(params, typ.rettypes, false,
        typ.varargtype, typ.flexrettype)
    for i, param in ipairs(params) do
        local pname = "_param_" .. tostring(i)
        local slot = "s2v(L->ci->func.p + " .. (i + hidden) .. ")"
        table.insert(pnames, pname)
        local native_param = types.is_direct_c(param)
            and cdeclarator.adjust_parameter_type(param) or param
        table.insert(stats, cvardecl(tlcontext, native_param, pname)
            .. " = " .. initval(native_param) .. ";")
        table.insert(stats, readfixed(param, pname, slot, i))
    end
    local call_entry = titan_entry
    if interface_method_index ~= nil then
        local interface = assert(types.registry[typ.fqtn],
            "Interface method owner is absent from the type registry")
        local registered_method =
            interface.methods[interface_method_index + 1]
        assert(interface._tag == "Type.Interface"
            and registered_method
            and registered_method.name == typ.name
            and types.equals(
                types.method_function_type(registered_method),
                types.method_function_type(typ)),
            "Interface Lua-entry method index is not canonical")
        local payload_name =
            "_titan_interface_method_" .. tostring(interface_method_index)
        table.insert(stats, render([[
            if (TITAN_UNLIKELY(
                    _param_1->len % sizeof(TitanInterfaceMethod) != 0
                    || _param_1->len / sizeof(TitanInterfaceMethod)
                        != $METHOD_COUNT)) {
                return luaL_error(L,
                    "malformed internal Interface wrapper for %s", $IFACE);
            }
            TitanInterfaceMethod _titan_interface_stored =
                ((TitanInterfaceMethod *)getudatamem(_param_1))[$INDEX];
            if (TITAN_UNLIKELY(_titan_interface_stored == NULL)) {
                return luaL_error(L,
                    "uninitialized internal Interface method %s:%s",
                    $IFACE, $METHOD);
            }
            $METHOD_DECL = titan_cast_func(
                $METHOD_TYPE, _titan_interface_stored);
            Udata *_titan_interface_concrete_module =
                uvalue(&_param_1->uv[0].uv);
            Udata *_titan_interface_concrete_self =
                uvalue(&_param_1->uv[1].uv);
        ]], {
            METHOD_COUNT = c_integer_literal(#interface.methods),
            IFACE = c_string_literal(interface.name),
            METHOD = c_string_literal(typ.name),
            INDEX = c_integer_literal(interface_method_index),
            METHOD_DECL = function_sig(payload_name, typ, true),
            METHOD_TYPE = function_sig("", typ, true),
        }))
        pnames = {
            "L",
            "_titan_interface_concrete_module",
            "NULL",
            "_titan_interface_concrete_self",
        }
        for i = 2, #params do
            table.insert(pnames, "_param_" .. tostring(i))
        end
        call_entry = payload_name
    end
    -- Variadic: build the backing struct from the surplus Lua-stack args. Pinned
    -- after the fixed params and before the out-params in the native call. The
    -- struct is a GC-anchored Udata0 (not a C-stack VLA): it must survive the
    -- error-handler frame and any GC the per-element coercion triggers. Surplus
    -- arg slots `func + nfixed + j` stay on the Lua stack below L->top.p for the
    -- whole native call, so they remain the anchors for any collectable element
    -- (§2.D); this struct's payload (getudatamem) is untraced.
    local varargtype = typ.varargtype
    if varargtype then
        local nfixed = #params
        local elem_ct = ctype(varargtype)
        local struct = varg_struct_name(varargtype)
        -- Allocate 0-uservalue Udata for the runtime-sized element storage,
        -- anchor it on the Lua stack so the GC keeps that storage alive across
        -- the native call, then make a small C-stack descriptor point at the
        -- payload. Each surplus arg is read through the same checkandget coercion
        -- the fixed params use, into `_varargs->args[j]`. `_start` is 0 (the
        -- generic entry always builds a fresh, fully-backed run). The entry guard
        -- below has already ensured the arg count is >= nfixed.
        local readone
        if strict then
            local guard = maybe3.get_checked(options.strict_vararg_plan,
                "strict Titan variadic parameter guard")
            readone = coder._strictcheckandget(
                tlcontext, guard, varargtype,
                "_varargs->args[_vj]",
                "s2v(L->ci->func.p + " .. (nfixed + hidden)
                .. " + 1 + _vj)",
                loc, "strict Titan variadic parameter", true)
        else
            local plan = maybe3.get_checked(options.dynamic_vararg_plan,
                "genuine Lua variadic parameter conversion")
            readone = coder._dynamiccheckandget(
                tlcontext, plan, varargtype,
                "_varargs->args[_vj]",
                "s2v(L->ci->func.p + " .. (nfixed + hidden)
                .. " + 1 + _vj)",
                loc, "genuine Lua variadic parameter", true)
        end
        table.insert(stats, render([[
            ptrdiff_t _vcount = _nargs - $NFIXED;
            if (TITAN_UNLIKELY(_vcount > TITAN_VARARG_MAX)) {
                luaL_error(L, "too many variadic arguments to Titan function %s (%d, max %d)", $NAME, (int)_vcount, (int)TITAN_VARARG_MAX);
            }
            lu_byte _nvarargs = (lu_byte)_vcount;
            titan_ensure_stack(L, 1);
            Udata *_varargs_ud = titan_new_udata_object(L,
                sizeudata(0, (size_t)_nvarargs * sizeof($ELEM_CT)));
            _varargs_ud->len = (size_t)_nvarargs * sizeof($ELEM_CT);
            _varargs_ud->nuvalue = 0; _varargs_ud->metatable = NULL;
            setuvalue(L, s2v(L->top.p), _varargs_ud);
            L->top.p++;
            /* Every surplus-argument read is based on the current CallInfo:
               an Interface witness call may relocate the stack between loop
               iterations. */
            $ELEM_CT *_varargs_args = ($ELEM_CT *)getudatamem(_varargs_ud);
            $STRUCT _varargs_desc = { _nvarargs, _varargs_args };
            $STRUCT *_varargs = &_varargs_desc;
            for (int _vj = 0; _vj < (int)_nvarargs; _vj++) {
                $READONE
            }
            int _start = 0;
        ]], {
            NFIXED = c_integer_literal(nfixed),
            NAME = c_string_literal(titan_name),
            STRUCT = struct,
            ELEM_CT = elem_ct,
            READONE = readone,
        }))
        table.insert(pnames, "_varargs")
        table.insert(pnames, "_start")
    end
    for i = 2, #typ.rettypes do
        local ptype = typ.rettypes[i]
        local pname = "_outparam_" .. i
        table.insert(pnames, "&" .. pname)
        table.insert(stats, cvardecl(tlcontext, ptype, pname)
            .. " = " .. initval(ptype) .. ";")
    end
    local flexrettype = typ.flexrettype
    if flexrettype then
        table.insert(stats, render([[
            int _requested_results = get_nresults(L->ci->callstatus);
            int _flexwant = (_requested_results == LUA_MULTRET)
                ? LUA_MULTRET : _requested_results - $NFIXED;
            if (_flexwant != LUA_MULTRET && _flexwant < 0) _flexwant = 0;
            if (TITAN_UNLIKELY(_flexwant > TITAN_VARARG_MAX)) {
                luaL_error(L,
                    "too many flexible results requested from Titan function %s (%d, max %d)",
                    $NAME, _flexwant, (int)TITAN_VARARG_MAX);
            }
            int _flexcap = (_flexwant == LUA_MULTRET)
                ? TITAN_VARARG_MAX : _flexwant;
            $ELEM _flexargs[(_flexcap > 0) ? _flexcap : 1];
            $STRUCT _flexdesc = { 0, _flexargs };
        ]], {
            NFIXED = c_integer_literal(#typ.rettypes),
            NAME = c_string_literal(titan_name),
            ELEM = ctype(flexrettype),
            STRUCT = varg_struct_name(flexrettype),
        }))
        table.insert(pnames, "&_flexdesc")
        table.insert(pnames, "_flexwant")
    end
    local rettype = typ.rettypes[1]
    if strict or #params > 0 then
        table.insert(stats, [[
            lua_pushvalue(L, 1); /* make space for error slot */
            lua_pushnil(L);
            lua_replace(L, 1); /* replace first stack element with nil, this is our error slot */
        ]])
    end
    if flexrettype then
        local call
        if rettype then
            call = render("$DECL = $NAME($PARAMS);", {
                DECL = cvardecl(tlcontext, rettype, "res"),
                NAME = call_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        else
            call = render("$NAME($PARAMS);", {
                NAME = call_entry,
                PARAMS = table.concat(pnames, ", "),
            })
        end
        local fixedsets = {}
        if rettype then
            table.insert(fixedsets,
                setboxed(tlcontext, rettype, "s2v(_firstret)", "res") .. ";")
        end
        for i = 2, #typ.rettypes do
            table.insert(fixedsets, render([[
                $SETSLOT;
            ]], {
                SETSLOT = setboxed(tlcontext, typ.rettypes[i],
                    "s2v(_firstret + " .. c_integer_literal(i - 1) .. ")",
                    "_outparam_" .. i),
            }))
        end
        table.insert(stats, render([[
            titan_ensure_stack(L, $NFIXED + _flexcap);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            for (int _ri = 0; _ri < $NFIXED + _flexcap; _ri++) {
                setnilvalue2s(L->top.p + _ri);
            }
            L->top.p += $NFIXED + _flexcap;
            $CALL
            /* The native callee may relocate the stack. Restore the reserved
               destination base before publishing fixed/flexible results. */
            StkId _firstret = restorestack(L, _firstret_off);
            $FIXEDSETS
            for (int _fri = 0; _fri < (int)_flexdesc.n_args; _fri++) {
                $SETFLEX;
            }
            L->top.p = _firstret + $NFIXED + (int)_flexdesc.n_args;
        ]], {
            NFIXED = c_integer_literal(#typ.rettypes),
            CALL = call,
            FIXEDSETS = table.concat(fixedsets, "\n"),
            SETFLEX = setboxed(tlcontext, flexrettype,
                "s2v(_firstret + " .. c_integer_literal(#typ.rettypes)
                .. " + _fri)", "_flexdesc.args[_fri]"),
        }))
    elseif #typ.rettypes == 0 then
        -- zero-return `() -> ()`: invoke the void native entry purely for
        -- effect and return no values across the Lua boundary
        table.insert(stats, render([[
            $NAME($PARAMS);
        ]], {
            NAME = call_entry,
            PARAMS = table.concat(pnames, ", "),
        }))
    else
        table.insert(stats, render([[
            titan_ensure_stack(L, $NRET);
            ptrdiff_t _firstret_off = savestack(L, L->top.p);
            L->top.p += $NRET;
            $DECL = $NAME($PARAMS);
            /* the native callee may have grown (and thus relocated) the Lua
               stack, so recompute the return slot pointer
               from the saved offset before writing through it */
            StkId _firstret = restorestack(L, _firstret_off);
            $SETSLOT;
            _firstret++;
        ]], {
            DECL = cvardecl(tlcontext, rettype, "res"),
            NAME = call_entry,
            PARAMS = table.concat(pnames, ", "),
            SETSLOT = setboxed(tlcontext, rettype, "s2v(_firstret)", "res"),
            NRET = #typ.rettypes
        }))
        for i = 2, #typ.rettypes do
            table.insert(stats, render([[
                $SETSLOT;
                _firstret++;
            ]], {
                SETSLOT = setboxed(tlcontext, typ.rettypes[i],
                    "s2v(_firstret)", "_outparam_" .. i)
            }))
        end
    end
    table.insert(stats, render([[
        if (TITAN_UNLIKELY(__installed_errfunc)) {
            L->errfunc = __save_errfunc;
        }
        return $NRET;
    ]], {
        NRET = flexrettype
            and (c_integer_literal(#typ.rettypes)
                .. " + (int)_flexdesc.n_args")
            or c_integer_literal(#typ.rettypes)
    }))
    -- Missing Lua arguments are adjusted upward with nil before parameter
    -- coercion, matching Titan call-site adjustment. Input-variadic wrappers
    -- collect surplus arguments; fixed wrappers deliberately ignore them.
    local argcheck
    if varargtype then
        argcheck = render([[
        ptrdiff_t _nargs = L->top.p - func - 1 - $HIDDEN;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            titan_ensure_stack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue2s(L->top.p);
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
            HIDDEN = c_integer_literal(hidden),
            NAME = c_string_literal(titan_name),
        })
    else
        argcheck = render([[
        ptrdiff_t _nargs = L->top.p - func - 1 - $HIDDEN;
        if (_nargs < $EXPECTED) {
            ptrdiff_t _missing = $EXPECTED - _nargs;
            titan_ensure_stack(L, (int)_missing);
            func = L->ci->func.p;
            while (_missing-- > 0) {
                setnilvalue2s(L->top.p);
                L->top.p++;
                _nargs++;
            }
        }]], {
            EXPECTED = c_integer_literal(#params),
            HIDDEN = c_integer_literal(hidden),
        })
    end
    local module_setup = "Udata *_mod = uvalue(&_fn->upvalue[0]);"
    local carrier
    if strict then
        assert(options.strict_name)
        if options.callable_adapter then
            local adapter = options.callable_adapter
            assert(adapter.target == typ
                or types.equals(adapter.target, typ),
                "callable strict relay has a mismatched target")
            carrier = render([[
            ptrdiff_t _strict_raw_nargs = L->top.p - func - 1;
            if (TITAN_UNLIKELY(_strict_raw_nargs < 1
                    || !ttisCclosure(s2v(func + 1)))) {
                return luaL_error(L,
                    "invalid callable strict-relay carrier");
            }
            CClosure *_fn = clCvalue(s2v(func + 1));
            if (TITAN_UNLIKELY(_fn->nupvalues < 6
                    || !ttisfulluserdata(&_fn->upvalue[0])
                    || !ttislightuserdata(&_fn->upvalue[1])
                    || !ttislightuserdata(&_fn->upvalue[2])
                    || !ttislightuserdata(&_fn->upvalue[3])
                    || !ttisCclosure(
                        &_fn->upvalue[_fn->nupvalues - 2])
                    || !ttislcf(&_fn->upvalue[
                        _fn->nupvalues - 1])
                    || pvalue(&_fn->upvalue[2])
                        != titan_cast_func(void *, $ADAPTER)
                    || pvalue(&_fn->upvalue[3])
                        != TITAN_BRAND
                    || fvalue(&_fn->upvalue[_fn->nupvalues - 1])
                        != $STRICTENTRY)) {
                return luaL_error(L,
                    "invalid callable strict-relay wrapper");
            }
            Udata *_mod = uvalue(&_fn->upvalue[0]);
            if (TITAN_UNLIKELY(_mod->len < sizeof($NATIVETYPE)
                    || pvalue(&_fn->upvalue[1]) != $FUNCTAG)) {
                return luaL_error(L,
                    "invalid callable strict-relay wrapper");
            }
            ]], {
                NATIVETYPE = tlcontext.prefix .. "native_data",
                STRICTENTRY = options.strict_name,
                ADAPTER = titan_entry,
                FUNCTAG = function_type_tag(tlcontext, callable_type),
            })
        else
            assert(options.lua_entry)
            carrier = render([[
            ptrdiff_t _strict_raw_nargs = L->top.p - func - 1;
            if (TITAN_UNLIKELY(_strict_raw_nargs < 1
                    || !ttisCclosure(s2v(func + 1)))) {
                return luaL_error(L, "invalid Titan strict-call carrier");
            }
            CClosure *_fn = clCvalue(s2v(func + 1));
            if (TITAN_UNLIKELY(_fn->nupvalues < 5
                    || _fn->f != $LUAENTRY
                    || !ttisfulluserdata(&_fn->upvalue[0])
                    || !ttislightuserdata(&_fn->upvalue[1])
                    || !ttislightuserdata(&_fn->upvalue[2])
                    || !ttislcf(&_fn->upvalue[_fn->nupvalues - 1])
                    || fvalue(&_fn->upvalue[_fn->nupvalues - 1])
                        != $STRICTENTRY)) {
                return luaL_error(L, "invalid Titan strict-call closure");
            }
            Udata *_mod = uvalue(&_fn->upvalue[0]);
            if (TITAN_UNLIKELY(_mod->len < sizeof($NATIVETYPE) ||
                    pvalue(&_fn->upvalue[1]) != $FUNCTAG)) {
                return luaL_error(L, "mistagged Titan strict-call closure");
            }
            ]], {
                NATIVETYPE = tlcontext.prefix .. "native_data",
                LUAENTRY = options.lua_entry,
                STRICTENTRY = options.strict_name,
                FUNCTAG = function_type_tag(tlcontext, callable_type),
            })
        end
        module_setup = ""
    else
        carrier = render([[
        CClosure *_fn = clCvalue(s2v(func));
        /* Callable views keep the source's genuine-Lua entry, but their
         * native adapter and module belong to the adapting consumer. Follow
         * the checked source trailer before reading source-owned payload. */
        while (_fn->nupvalues >= 6
                && ttisfulluserdata(&_fn->upvalue[0])
                && ttislightuserdata(&_fn->upvalue[3])
                && pvalue(&_fn->upvalue[3]) == TITAN_BRAND
                && ttislightuserdata(&_fn->upvalue[2])
                && ttislcf(&_fn->upvalue[_fn->nupvalues - 1])
                && ttisCclosure(&_fn->upvalue[_fn->nupvalues - 2])
                && pvalue(&_fn->upvalue[2])
                    != titan_cast_func(void *, $NATIVE)) {
            CClosure *_source = clCvalue(
                &_fn->upvalue[_fn->nupvalues - 2]);
            if (TITAN_UNLIKELY(_source->f != _fn->f
                    || _source->nupvalues + 1 != _fn->nupvalues)) {
                return luaL_error(L, "invalid callable Lua-entry source");
            }
            _fn = _source;
        }
        ]], { NATIVE = options.native_carrier_entry or titan_entry })
    end
    return render([[
    $STORAGE int $LUANAME(lua_State *L) {
        StkId func = L->ci->func.p;
        $CARRIER
        $ARGCHECK
        $ERRORSLOT
        ptrdiff_t __save_errfunc = L->errfunc;
        int __installed_errfunc = 0;
        if (TITAN_UNLIKELY(!titan_errfunc_is_errorhandler(L))) {
            lua_pushcfunction(L, errorhandler);
            L->errfunc = savestack(L, L->top.p - 1);
            __installed_errfunc = 1;
        }
        $MODULE_SETUP
        $ENTRYLINE$BODY
    }]], {
        LUANAME = lua_name,
        STORAGE = storage,
        CARRIER = carrier,
        ARGCHECK = argcheck,
        ERRORSLOT = (not strict and #params == 0)
            and "lua_pushnil(L);" or "",
        MODULE_SETUP = module_setup,
        NAME = c_string_literal(titan_name),
        -- Stamp the Lua-entry wrapper to the function definition's .titan loc
        -- so its native frame, and any arg-coercion throw within it, symbolizes
        -- to the .titan source rather than drifting through the wrapper's
        -- generated C.
        ENTRYLINE = emitline({ loc = loc }),
        BODY = table.concat(stats, "\n"),
    })
end

-- Implementation notes: doc/implementation/closure-adjustment-wrappers.md#target-native-adapter
function coder._emit_callable_adapter(tlcontext, site)
    local adapter = coder._validate_callable_adapter_plan(
        site.adapter, site.adapter.source, site.adapter.target,
        "callable adapter emission", {})
    local ctx = newcontext(tlcontext)
    local roots = coder._interface_adapter_allocate_roots(ctx, adapter)
    local loc = adapter.location
    local argument_sources =
        coder._emit_interface_adapter_argument_sources(
            ctx, adapter, roots, loc)
    local flex_validation = ""
    if adapter.target.flexrettype then
        flex_validation = render([[
            if (TITAN_UNLIKELY(
                    _flexout == NULL
                    || (_flexwant != LUA_MULTRET
                        && (_flexwant < 0
                            || _flexwant > TITAN_VARARG_MAX)))) {
                luaL_error(L,
                    "malformed callable adapter flexible-result demand for %s",
                    $TRACE);
            }
        ]], {
            TRACE = c_string_literal(adapter.trace_name),
        })
    end
    local arguments = coder._emit_interface_adapter_arguments(
        ctx, adapter, roots, loc)
    local call = coder._emit_interface_adapter_call(
        ctx, adapter, roots)
    local results = coder._emit_interface_adapter_results(
        ctx, adapter, roots, loc)
    local handoff = {}
    for index = 2, #adapter.target.rettypes do
        handoff[#handoff + 1] = render([[
            *_ia_out_$INDEX = _ia_interface_result_$INDEX;
        ]], {
            INDEX = c_integer_literal(index),
        })
    end
    local finish
    if #adapter.target.rettypes == 0 then
        finish = "L->top.p = _base;\nreturn;"
    else
        finish = [[
            L->top.p = _base;
            return _ia_interface_result_1;
        ]]
    end
    local root_preamble
    if ctx.nslots > 0 then
        root_preamble = render([[
            titan_ensure_stack(L, $NSLOTS);
            StkId _base = L->top.p;
            L->top.p += $NSLOTS;
            for (StkId _ia_slot = L->top.p - 1;
                 _base <= _ia_slot; _ia_slot--) {
                setnilvalue2s(_ia_slot);
            }
            ptrdiff_t _base_off = savestack(L, _base);
        ]], {
            NSLOTS = c_integer_literal(ctx.nslots),
        })
    else
        root_preamble = [[
            StkId _base = L->top.p;
            ptrdiff_t _base_off = savestack(L, _base);
        ]]
    end
    coder._record_private_symbol(tlcontext, site.native,
        "callable adapter " .. tostring(site.index))
    coder._record_private_symbol(tlcontext, site.strict,
        "callable adapter " .. tostring(site.index) .. " strict entry")
    local native_signature = coder._callable_adapter_signature(
        site.native, adapter.target, false)
    local native_body = render([[
        TITAN_MODULE_PRIVATE TITAN_NOINLINE $SIGNATURE {
            $LINE$GC_POLL
            $ROOT_PREAMBLE
            $ARGUMENT_SOURCES
            $FLEX_VALIDATION
            $ARGUMENTS
            $CALL
            $RESULTS
            $HANDOFF
            $FINISH
        }
    ]], {
        SIGNATURE = native_signature,
        LINE = emitline({ loc = loc }),
        GC_POLL = coder._adapter_actions_allocate(adapter)
            and "luaC_checkGC(L);" or "",
        ROOT_PREAMBLE = root_preamble,
        ARGUMENT_SOURCES = argument_sources,
        FLEX_VALIDATION = flex_validation,
        ARGUMENTS = arguments,
        CALL = call,
        RESULTS = results,
        HANDOFF = table.concat(handoff, "\n"),
        FINISH = finish,
    })

    local strict_plans = {}
    for index, slot in ipairs(adapter.strict_relay.parameters) do
        strict_plans[index] = slot.guard
    end
    local strict_body = genluaentry(
        tlcontext, adapter.trace_name, site.native,
        adapter.target, loc, site.strict, {
            strict = true,
            strict_name = site.strict,
            callable_adapter = adapter,
            strict_plans = strict_plans,
            strict_vararg_plan = adapter.strict_relay.vararg
                and adapter.strict_relay.vararg.guard or nil,
        })
    local declarations = table.concat({
        "TITAN_MODULE_PRIVATE TITAN_NOINLINE "
        .. coder._callable_adapter_signature(
            site.native, adapter.target, false) .. ";",
        "TITAN_MODULE_PRIVATE int " .. site.strict .. "(lua_State *L);",
    }, "\n")
    return declarations, native_body .. "\n" .. strict_body
end

-- A captured-and-mutated parameter is boxed: its incoming value is anchored in
-- its reserved slot for gc types, then copied into a fresh box cell so a nested
-- lambda capturing it shares the same mutable storage. Sets `param._box`.
function codeboxparam(ctx, param)
    local typ = param._type
    param._box = "_box_" .. param.name
    local boxslot = newslot(ctx)
    return render([[
        $NEWBOX
        $SETSLOT
    ]], {
        NEWBOX = newbox(ctx, typ, param._box, boxslot),
        SETSLOT = box_write(typ, param._box, param._cvar),
    })
end

-- Implementation notes: doc/implementation/foreign-functions.md#contents-and-inline-classification
function coder._foreign_function_is_inline(node)
    -- Public callbacks need one provider-owned address, including when their
    -- implementation could otherwise fit in an explicit source-import header.
    if not node.islocal then return false end
    if node._coverage_foreign_outline then return false end
    -- Private nominal layout declarations belong to the producer C unit.
    -- Its source header exports only the native callback prototype.
    if node._native_record_fields then return false end
    local block = node.block
    if not block or block._tag ~= "Ast.StatBlock" then return false end
    local stats = block.stats
    local first = 1
    while stats[first] and stats[first]._tag == "Ast.StatDecl" do
        first = first + 1
    end
    local function return_block(candidate)
        return candidate and candidate._tag == "Ast.StatBlock"
            and #candidate.stats == 1
            and candidate.stats[1]._tag == "Ast.StatReturn"
    end
    if first == #stats and stats[first]._tag == "Ast.StatReturn" then
        return true
    end
    local conditional = stats[first]
    if not conditional or conditional._tag ~= "Ast.StatIf"
        or #conditional.thens ~= 1
        or not return_block(conditional.thens[1].block) then
        return false
    end
    if first == #stats and return_block(conditional.elsestat) then
        return true
    end
    return first + 1 == #stats and not conditional.elsestat
        and stats[first + 1]._tag == "Ast.StatReturn"
end

function coder._new_foreign_context(tlcontext)
    return {
        tlcontext = tlcontext,
        temporary = 0,
        local_count = 0,
    }
end

function coder._foreign_temp(ctx, typ, prefix)
    ctx.temporary = ctx.temporary + 1
    local name = "_foreign_" .. (prefix or "tmp") .. "_"
        .. tostring(ctx.temporary)
    return coder._render_c_declaration(coder._c_value_type(typ), name) .. ";", name
end

-- Implementation notes: doc/implementation/foreign-functions.md#exact-raw-c-lowering-and-sequencing
function coder._foreign_freeze(ctx, node, target, prefix)
    local stats, exp = coder._foreign_raw_exp(ctx, node)
    local typ = target or node._type
    local resolved = types.resolve_c_typedef(typ)
    if resolved and resolved._tag == "Type.CArray" then
        typ = cdeclarator.adjust_parameter_type(typ)
    end
    local decl, name = coder._foreign_temp(ctx, typ, prefix)
    local value = target and foreigncast(exp, target) or exp
    return table.concat({ stats, decl, name .. " = " .. value .. ";" }, "\n"), name
end

function coder._foreign_source_member_reference(var)
    local decl = var and var._decl
    if not decl then return nil end
    if decl._tag == "Ast.TopLevelForeignFunc" then
        return { source = true, module = decl._foreign_module, name = decl.name }
    elseif decl._tag == "Type.ModuleMember"
            and decl.type._tag == "Type.CFunction" then
        return {
            source = true, module = decl.modname, name = decl.name,
            public = not decl.islocal, type = decl.type,
        }
    end
end

function coder._foreign_raw_var(ctx, node)
    if node._tag == "Ast.VarName" then
        if node._decl and node._decl._foreign_cname then
            return "", node._decl._foreign_cname
        end
        local reference = coder._foreign_source_member_reference(node)
        if reference then
            return "", coder._foreign_reference_name(reference, ctx)
        end
        error("foreign variable lacks a C name: " .. tostring(node.name))
    elseif node._tag == "Ast.VarDot" then
        local base_type = types.resolve_c_typedef(node.exp._type)
        if node.exp._type._tag == "Type.CModule" then
            return "", node.name
        end
        local reference = coder._foreign_source_member_reference(node)
        if reference then
            return "", coder._foreign_reference_name(reference, ctx)
        end
        if node._decl and node._decl._tag == "Type.CPseudoSize" then
            local op = node._decl.name == "sizeof" and "sizeof" or "_Alignof"
            return "", op .. "(" .. coder._render_c_declaration(
                node._decl.ctype, "") .. ")"
        end
        assert(node._decl and node._decl._tag == "Type.CField",
            "foreign member is not a C field")
        local stats, base = coder._foreign_raw_exp(ctx, node.exp)
        if base_type._tag == "Type.CPointer" then
            return stats, "(" .. base .. ")->" .. node._decl.name
        end
        return stats, "(" .. base .. ")." .. node._decl.name
    elseif node._tag == "Ast.VarBracket" then
        local bstats, base = coder._foreign_raw_exp(ctx, node.exp1)
        local istats, index = coder._foreign_raw_exp(ctx, node.exp2)
        return bstats .. "\n" .. istats,
            "(" .. base .. ")[" .. index .. "]"
    end
    error("unsupported foreign variable " .. tostring(node._tag))
end

function coder._foreign_raw_call(ctx, node)
    if node._native_record_field then
        return coder._foreign_record_field_read(ctx, node)
    end
    local signature
    local callee_stats = ""
    local callee
    if node._direct_foreign_reference then
        signature = node.exp._type
        callee = coder._foreign_reference_name(node._direct_foreign_reference, ctx)
    elseif node._c_pointer_call then
        signature = node._c_pointer_call
        callee_stats, callee = coder._foreign_freeze(
            ctx, node.exp, nil, "callee")
    else
        error("foreign function body reached a non-C call")
    end
    local stats = { callee_stats }
    local args = {}
    if node._named_arg_order then
        local frozen = {}
        for _, index in ipairs(node._named_arg_order) do
            local arg = node.args.args[index]
            local astats, value = coder._foreign_freeze(
                ctx, arg, signature.params[index], "arg")
            stats[#stats + 1] = astats
            frozen[index] = value
        end
        for index, arg in ipairs(node.args.args) do
            if not frozen[index] then
                local astats, value = coder._foreign_freeze(
                    ctx, arg, signature.params[index], "arg")
                stats[#stats + 1] = astats
                frozen[index] = value
            end
        end
        for index = 1, #signature.params do
            args[index] = assert(frozen[index],
                "named foreign argument was not frozen")
        end
    else
        for index, arg in ipairs(node.args.args) do
            local target = signature.params[index]
            local astats, value = coder._foreign_freeze(
                ctx, arg, target, "arg")
            stats[#stats + 1] = astats
            args[#args + 1] = value
        end
    end
    local call = callee .. "(" .. table.concat(args, ", ") .. ")"
    local ret = types.resolve_c_typedef(signature.ret)
    if ret._tag == "Type.CVoid" then
        stats[#stats + 1] = call .. ";"
        return table.concat(stats, "\n"), "((void)0)"
    end
    local decl, result = coder._foreign_temp(ctx, signature.ret, "result")
    stats[#stats + 1] = decl
    stats[#stats + 1] = result .. " = " .. call .. ";"
    return table.concat(stats, "\n"), result
end

function coder._foreign_raw_exp(ctx, node)
    local tag = node._tag
    if tag == "Ast.ExpNil" then
        return "", "NULL"
    elseif tag == "Ast.ExpBool" then
        return "", node.value and "1" or "0"
    elseif tag == "Ast.ExpInteger" then
        return "", c_integer_literal(node.value)
    elseif tag == "Ast.ExpFloat" then
        return "", c_float_literal(node.value)
    elseif tag == "Ast.ExpString" then
        return "", c_string_literal(node.value)
    elseif tag == "Ast.ExpVar" then
        if node._foreign_function_reference then
            return "", coder._foreign_reference_name(
                node._foreign_function_reference, ctx)
        end
        return coder._foreign_raw_var(ctx, node.var)
    elseif tag == "Ast.VarName" or tag == "Ast.VarDot"
        or tag == "Ast.VarBracket" then
        return coder._foreign_raw_var(ctx, node)
    elseif tag == "Ast.ExpCall" then
        return coder._foreign_raw_call(ctx, node)
    elseif tag == "Ast.ExpCast" then
        local stats, exp = coder._foreign_raw_exp(ctx, node.exp)
        local operation
        if node._adjustment
            and node._adjustment.kind == "direct_coercion" then
            operation = node._adjustment.coercion.op
        elseif (node._written_cast and node._written_cast.tag == "just") then
            if maybe3.get_checked(node._written_cast, "written cast").op == "coercion" then
                operation = maybe3.get_checked(node._written_cast, "written cast").coercion.op
            elseif maybe3.get_checked(node._written_cast, "written cast").op == "explicit" then
                operation = maybe3.get_checked(node._written_cast, "written cast").conversion.op
                    or maybe3.get_checked(node._written_cast, "written cast").conversion.kind
            end
        elseif node._c_conversion then
            operation = node._c_conversion.op or node._c_conversion.kind
        end
        if operation == "c_address" or operation == "mutable_c_address" then
            return stats, "(&(" .. exp .. "))"
        elseif operation == "c_function_pointer_to_void"
            or operation == "c_void_to_function_pointer" then
            return stats, render("titan_cast_func($TARGET, $SOURCE)", {
                TARGET = coder._render_c_type_name(node._type),
                SOURCE = exp,
            })
        end
        return stats, foreigncast(exp, node._type)
    elseif tag == "Ast.ExpAdjust" then
        return coder._foreign_raw_exp(ctx, node.exp)
    elseif tag == "Ast.ExpUnop" then
        local stats, exp = coder._foreign_freeze(
            ctx, node.exp,
            node._c_operator and node._c_operator.lhs_target or nil,
            "operand")
        local op = node._c_operator and node._c_operator.cop or node.op
        if op == "not" then op = "!" end
        return stats, "(" .. op .. "(" .. exp .. "))"
    elseif tag == "Ast.ExpBinop" then
        local trait = node._c_operator
        local lstats, lhs = coder._foreign_freeze(
            ctx, node.lhs, trait and trait.lhs_target or nil, "lhs")
        local rstats, rhs = coder._foreign_freeze(
            ctx, node.rhs, trait and trait.rhs_target or nil, "rhs")
        local op = trait and trait.cop or node.op
        if op == "~=" then
            op = "!="
        elseif op == "~" then
            op = "^"
        elseif op == "and" then
            op = "&&"
        elseif op == "or" then
            op = "||"
        end
        return lstats .. "\n" .. rstats,
            "((" .. lhs .. ") " .. op .. " (" .. rhs .. "))"
    end
    error("unsupported expression in foreign function: " .. tostring(tag))
end

function coder._foreign_raw_lvalue(ctx, node)
    if node._tag == "Ast.VarBracket" then
        local bstats, base = coder._foreign_freeze(
            ctx, node.exp1, nil, "lvalue_base")
        local istats, index = coder._foreign_freeze(
            ctx, node.exp2, nil, "lvalue_index")
        return bstats .. "\n" .. istats,
            "(" .. base .. ")[" .. index .. "]"
    elseif node._tag == "Ast.VarDot"
        and node._decl and node._decl._tag == "Type.CField" then
        local base_type = types.resolve_c_typedef(node.exp._type)
        if base_type._tag == "Type.CPointer" then
            local stats, base = coder._foreign_freeze(
                ctx, node.exp, nil, "lvalue_base")
            return stats, "(" .. base .. ")->" .. node._decl.name
        end
        local base_node = node.exp._tag == "Ast.ExpVar"
            and node.exp.var or node.exp
        if base_node._tag == "Ast.VarName"
            or base_node._tag == "Ast.VarDot"
            or base_node._tag == "Ast.VarBracket" then
            local stats, base = coder._foreign_raw_lvalue(ctx, base_node)
            return stats, "(" .. base .. ")." .. node._decl.name
        end
    end
    return coder._foreign_raw_var(ctx, node)
end

function coder._foreign_raw_block(ctx, block, braces)
    local stats = {}
    for _, stat in ipairs(block.stats) do
        stats[#stats + 1] = coder._foreign_raw_stat(ctx, stat)
        if stat._always_returns then break end
    end
    local body = table.concat(stats, "\n")
    if braces == false then return body end
    return "{\n" .. body .. "\n}"
end

local function foreign_raw_stat_dispatch(ctx, node)
    local tag = node._tag
    if tag == "Ast.StatBlock" then
        return coder._foreign_raw_block(ctx, node)
    elseif tag == "Ast.StatDecl" then
        local out, values = {}, {}
        for _, decl in ipairs(node.decls) do
            ctx.local_count = ctx.local_count + 1
            decl._foreign_cname = "_foreign_local_" .. decl.name .. "_"
                .. tostring(ctx.local_count)
            out[#out + 1] = coder._render_c_declaration(
                coder._c_value_type(decl._type), decl._foreign_cname) .. ";"
        end
        for index, exp in ipairs(node.exps) do
            local decl = assert(node.decls[index],
                "foreign local initializer has no declaration")
            local stats, value = coder._foreign_freeze(
                ctx, exp, decl._type, "declaration")
            out[#out + 1] = stats
            values[index] = value
        end
        for index, decl in ipairs(node.decls) do
            out[#out + 1] = decl._foreign_cname .. " = "
                .. assert(values[index],
                    "foreign local declaration has no initializer") .. ";"
        end
        return table.concat(out, "\n")
    elseif tag == "Ast.StatAssign" then
        local out, targets, values = {}, {}, {}
        for _, var in ipairs(node.vars) do
            local stats, target = coder._foreign_raw_lvalue(ctx, var)
            out[#out + 1] = stats
            targets[#targets + 1] = target
        end
        for index, exp in ipairs(node.exps) do
            local target_type = node.vars[index] and node.vars[index]._type
            local stats, value = coder._foreign_freeze(
                ctx, exp, target_type, "assignment")
            out[#out + 1] = stats
            values[index] = value
        end
        for index, target in ipairs(targets) do
            out[#out + 1] = target .. " = " .. values[index] .. ";"
        end
        return table.concat(out, "\n")
    elseif tag == "Ast.StatCall" then
        local stats = coder._foreign_raw_exp(ctx, node.callexp)
        return stats
    elseif tag == "Ast.StatReturn" then
        if #node.exps == 0 then return "return;" end
        local stats, value = coder._foreign_raw_exp(ctx, node.exps[1])
        return stats .. "\nreturn " .. value .. ";"
    elseif tag == "Ast.StatBreak" then
        return "break;"
    elseif tag == "Ast.StatIf" then
        local chunks = {}
        for index, arm in ipairs(node.thens) do
            local stats, condition = coder._foreign_raw_exp(ctx, arm.condition)
            local decision = stats .. "\nif (" .. condition .. ") "
            if index > 1 then
                decision = coverage_region(arm.condition, decision, ctx)
            end
            chunks[#chunks + 1] = "{\n" .. decision
                .. coder._foreign_raw_block(ctx, arm.block)
                .. "\nelse "
        end
        local tail = node.elsestat
            and coder._foreign_raw_block(ctx, node.elsestat)
            or "{}"
        return table.concat(chunks) .. tail
            .. string.rep("\n}", #node.thens)
    elseif tag == "Ast.StatWhile" then
        local stats, condition = coder._foreign_raw_exp(ctx, node.condition)
        return "while (1) {\n" .. stats .. "\nif (!(" .. condition
            .. ")) break;\n" .. coder._foreign_raw_block(ctx, node.block, false)
            .. "\n}"
    elseif tag == "Ast.StatRepeat" then
        local stats, condition = coder._foreign_raw_exp(ctx, node.condition)
        return "do {\n" .. coder._foreign_raw_block(ctx, node.block, false)
            .. "\n" .. coverage_region(node.condition,
                stats .. "\nif (" .. condition .. ") break;", ctx)
            .. "\n} while (1);"
    elseif tag == "Ast.StatFor" then
        local start_stats, start = coder._foreign_freeze(
            ctx, node.start, node.decl._type, "for_start")
        local finish_stats, finish = coder._foreign_freeze(
            ctx, node.finish, node.decl._type, "for_finish")
        local step_stats, step = coder._foreign_freeze(
            ctx, node.inc, node.decl._type, "for_step")
        ctx.local_count = ctx.local_count + 1
        node.decl._foreign_cname = "_foreign_for_" .. node.decl.name .. "_"
            .. tostring(ctx.local_count)
        local control = node.decl._foreign_cname
        return table.concat({
            "{", start_stats, finish_stats, step_stats,
            coder._render_c_declaration(node.decl._type, control) .. ";",
            "for (" .. control .. " = " .. start .. "; (" .. step
            .. " >= 0 ? " .. control .. " <= " .. finish .. " : "
            .. control .. " >= " .. finish .. "); " .. control
            .. " += " .. step .. ") "
            .. coder._foreign_raw_block(ctx, node.block),
            "}",
        }, "\n")
    end
    error("unsupported statement in foreign function: " .. tostring(tag))
end

function coder._foreign_raw_stat(ctx, node)
    local code = foreign_raw_stat_dispatch(ctx, node)
    if node._tag == "Ast.StatBlock" then return code end
    if node._tag == "Ast.StatRepeat" and coder._coverage_source_regions
        and not ctx._coverage_generated then
        -- The constant C backedge is scaffolding; the authored decision is
        -- the nested until region, which may be bypassed by a body break.
        return require("titan-compiler.coverage_lines").region(code, "generated")
    end
    return coverage_region(node, code, ctx)
end

function coder._foreign_function_signature(node)
    local params = {}
    local fixed_index = 1
    for _, param in ipairs(node.params) do
        if param.name ~= nil then
            param._foreign_cname = "_param_" .. param.name
            local typ = cdeclarator.adjust_parameter_type(
                node._type.params[fixed_index])
            params[#params + 1] = coder._render_c_declaration(
                typ, param._foreign_cname)
            fixed_index = fixed_index + 1
        end
    end
    local ret = types.resolve_c_typedef(node._type.ret)
    local rettype = ret._tag == "Type.CVoid" and nil or node._type.ret
    return cfunctiondecl(rettype,
        coder._foreign_func_name(node._foreign_module, node.name),
        #params == 0 and "void" or table.concat(params, ", "), false)
end

function coder._code_foreign_function(tlcontext, node, inline)
    local ctx = coder._new_foreign_context(tlcontext)
    -- Header generation also runs outside generate's policy reset. Ordinary
    -- inline interfaces must never inherit a previous coverage invocation.
    ctx._coverage_generated = not node._coverage_foreign_outline
    local signature = coder._foreign_function_signature(node)
    local body = coder._foreign_raw_block(ctx, node.block, false)
    local storage = inline and "static inline"
        or node.islocal and "TITAN_SOURCE_LOCAL" or ""
    return storage .. " " .. signature .. " {\n" .. body .. "\n}"
end

-- Titan calling convention:
--     first parameter is a lua_State*; remaining inputs use their actual native
--     C types. The caller never publishes tracing-only Lua-stack copies of those
--     arguments. A callee creates a separate local home only when mutation or
--     setjmp spilling requires one. The function returns its first result
--     directly and writes later results through out parameters. A native caller
--     roots each GC-bearing result immediately after return, before later work
--     can collect it; returning itself cannot run the collector.
-- Implementation notes: doc/implementation/codegen-overview.md#the-titan-native-function-and-its-calling-convention
function codefuncdec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    ctx._coverage_generated = node._record_constructor or node._union_constructor
    local stats = {}
    local rettype = node._type.rettypes[1]
    local has_function_value = node._tag ~= "Ast.TopLevelFunc"
        or not node.islocal
        or node._closure_upvalue
    local fname, luaname, strictname, tracename
    if node._tag == "Ast.TopLevelFunc" then
        fname = func_name(tlcontext.module, node.name, node.islocal)
        luaname = func_luaname(tlcontext.module, node.name, node.islocal)
        strictname = coder._func_strictname(
            tlcontext.module, node.name, node.islocal)
        tracename = tlcontext.module .. "." .. node.name
        register_trace_name(tlcontext, fname, tracename)
        if has_function_value then
            register_trace_name(tlcontext, strictname, tracename)
        end
    elseif node._tag == "Ast.TopLevelStatic" then
        fname = static_name(node._type)
        luaname = static_luaname(node._type)
        strictname = coder._static_strictname(node._type)
        -- fqtn is "<module>.<record>"; a static is "<module>.<record>.<static>".
        tracename = node._type.fqtn .. "." .. node._type.name
        register_trace_name(tlcontext, fname, tracename)
        register_trace_name(tlcontext, strictname, tracename)
    else
        assert(node._tag == "Ast.TopLevelMethod")
        fname = method_name(node._type)
        luaname = method_luaname(node._type)
        -- fqtn is "<module>.<record>"; a method is "<module>.<record>:<method>".
        tracename = node._type.fqtn .. ":" .. node._type.name
        register_trace_name(tlcontext, fname, tracename)
    end
    -- Detect a `StatTry` in this function's body up front. Nested
    -- function/lambda bodies have their own contexts and are not scanned.
    ctx.has_try = stat_contains_try(node.block)
    ctx.entry_try = node.block._tag == "Ast.StatTry" and
        node.block.catchblock and node.block or nil
    if ctx.has_try then analyze_try_spills(node.block) end
    -- The declared return types, so a `return` routed through a finally
    -- (codetry/codereturn) can size + fill the per-try saved-return temps.
    ctx.rettypes = node._type.rettypes
    ctx.flexrettype = node._type.flexrettype or nil
    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    if node._tag == "Ast.TopLevelMethod" then
        -- `self` is a real Decl that capture analysis can mark captured/assigned,
        -- so it is treated exactly like a parameter: anchored when a gc-typed and
        -- assigned self, and boxed when captured-and-mutated by a nested lambda.
        local self = node._self
        self._cvar = "__self__"
        self._boxed = self._captured and self._assigned
        if types.is_gc(self._type) and (self._assigned or self._needs_spill) then
            self._slot = newslot(ctx)
            -- anchor the incoming gc self before the box allocation (which can
            -- trigger GC), so a reassigned/captured self stays live
            table.insert(stats, setslot(self._type, self._slot, self._cvar))
        end
        if self._boxed then
            table.insert(stats, codeboxparam(ctx, self))
        end
        table.insert(stats, spill_decl_init(ctx, self))
        table.insert(cparams, cvardecl(ctx, self._type, self._cvar))
    end
    for _, param in ipairs(fixed_params(node.params)) do
        param._cvar = "_param_" .. param.name
        param._boxed = param._captured and param._assigned
        if types.is_gc(param._type) and (param._assigned or param._needs_spill) then
            param._slot = newslot(ctx)
            -- anchor the incoming gc param in its own slot before the box
            -- allocation (which can trigger GC) — see codeboxparam
            table.insert(stats, setslot(param._type, param._slot, param._cvar))
        end
        if param._boxed then
            table.insert(stats, codeboxparam(ctx, param))
        end
        table.insert(stats, spill_decl_init(ctx, param))
        table.insert(cparams, coder._local_cvardecl(ctx, param))
    end
    -- Variadic: the backing struct + start offset, pinned after the declared
    -- params and before the out-params, and threaded into ctx for `...` lowering.
    local varargtype = node._type.varargtype
    if varargtype then
        table.insert(cparams, varg_struct_name(varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        ctx.varargs = { cname = "_varargs", start = "_start", elem = varargtype }
    end
    for i = 2, #node._type.rettypes do
        local outtype = node._type.rettypes[i]
        table.insert(cparams,
            cpointerdecl(outtype, "_outparam_" .. i))
    end
    if node._type.flexrettype then
        table.insert(cparams,
            varg_struct_name(node._type.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
    end
    -- Attribute the first native frame to the function definition: a `#line`
    -- at function entry (after parameter setup, before the body) so a
    -- backtrace through the entry shows the .titan definition line, not the
    -- generated .c.
    local body = emitline(node) .. codestat(ctx, node.block)
    local nslots = ctx.nslots
    -- Patch the try-recovery's reserved-top restore (codetry emits the symbolic
    -- TITAN_RESERVED_NSLOTS so a catch's own slots are GC-scanned) now that the
    -- function-wide high-water mark is final.
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    -- Calls and allocation/GC helpers can relocate the Lua stack and dangle
    -- `_base`. Any lowering with such a rebase point sets `uses_base_off`, so
    -- the function saves `_base` as an offset for recovery afterward.
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    -- Clean-exit restore foundation (#3): snapshot the errorjmp chain at function
    -- entry so a `return` crossing a protected region can restore it before the
    -- epilogue (the inner `_lj` would otherwise be out of scope). Emitted only
    -- when a `return` actually crossed a try (codereturn set used_entry_restore),
    -- so a try with no escaping return adds no dead locals.
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
        .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        titan_ensure_stack(L, $NSLOTS);
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue2s(_s);
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        -- No reserved slots, but still anchor _base so every return path can
        -- reset L->top.p uniformly (the reset is then a no-op).
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    table.insert(stats, body)
    -- A zero-return `() -> ()` function has no `rettypes[1]`: its native entry
    -- returns C `void`, so falling off the end emits a bare `return;`. A
    -- `nil`-returning function returns the int 0 (the native nil encoding).
    local flexempty = node._type.flexrettype
        and "            _flexout->n_args = 0;\n" or ""
    if not rettype then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return;]])
    elseif rettype._tag == "Type.Nil" then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return 0;]])
    else
        local ur = unreachable_return(rettype, node.block)
        if ur then table.insert(stats, ur) end
    end
    local nativesig = cfunctiondecl(
        rettype, fname, table.concat(cparams, ", "), false)
    node._body = render([[
    $ISLOCAL $SIGNATURE {
        $BODY
    }]], {
        ISLOCAL = node.islocal and "TITAN_SOURCE_LOCAL" or "",
        SIGNATURE = nativesig,
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        $ISLOCAL $SIGNATURE;
    ]], {
        ISLOCAL = node.islocal and "TITAN_SOURCE_LOCAL" or "",
        SIGNATURE = nativesig,
    })
    node._luabody = genluaentry(
        tlcontext, node.name, fname, node._type, node.loc, luaname, {
            dynamic_plans = node._lua_dynamic_plans,
            dynamic_vararg_plan = node._lua_vararg_dynamic_plan,
        })
    if has_function_value then
        coder._record_private_symbol(tlcontext, luaname,
            "function '" .. tracename .. "' Lua entry")
        node._sig = node._sig .. "\n    TITAN_MODULE_PRIVATE int " .. luaname
            .. "(lua_State *L);"
    end
    if strictname and has_function_value then
        coder._record_private_symbol(tlcontext, strictname,
            "function '" .. tracename .. "' strict entry")
        node._strictbody = genluaentry(
            tlcontext, node.name, fname, node._type, node.loc, strictname, {
                strict = true,
                strict_name = strictname,
                lua_entry = luaname,
                strict_plans = node._strict_guard_plans,
                strict_vararg_plan = node._strict_vararg_guard_plan,
            })
        node._sig = node._sig .. "\n    TITAN_MODULE_PRIVATE int " .. strictname
            .. "(lua_State *L);"
        coder._transfer_register_source(tlcontext,
            types.Function(node._type.params, node._type.rettypes, false,
                node._type.varargtype, node._type.flexrettype),
            fname, luaname, strictname, {}, node.loc)
    end
end

function codeinitializerdec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local fname = module_initializer_name(tlcontext)
    ctx.has_try = stat_contains_try(node)
    ctx.entry_try = node._tag == "Ast.StatTry" and
        node.catchblock and node or nil
    if ctx.has_try then analyze_try_spills(node) end
    ctx.rettypes = {}

    local body = codestat(ctx, node)
    local nslots = ctx.nslots
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
        .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        titan_ensure_stack(L, $NSLOTS);
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue2s(_s);
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    table.insert(stats, "        (void)_mod;")
    table.insert(stats, "        (void)_fn;")
    table.insert(stats, body)
    table.insert(stats, [[
            L->top.p = _base;
            return;]])
    coder._record_private_symbol(tlcontext, fname,
        "module initializer body")
    node._body = render([[
    TITAN_MODULE_PRIVATE void $NAME(lua_State *L, Udata *_mod, CClosure *_fn) {
        $BODY
    }]], {
        NAME = fname,
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        TITAN_MODULE_PRIVATE void $NAME(lua_State *L, Udata *_mod, CClosure *_fn);
    ]], {
        NAME = fname,
    })
end

-- Emit the two bound-method trampolines for a TopLevelMethod, delegating to the
-- method's own native/Lua entries. They turn `obj:m` into a first-class function
-- value of the self-removed type `(params) -> rettypes`, with `self` captured in
-- the closure's `upvalue[4]`. Public methods export these trampolines so a bind
-- site in a module that only has this module's `.so` can still reach them; local
-- methods keep them file-local.
-- Produces node._boundsig / node._boundbody.
function codemethodtrampoline(tlcontext, node)
    local mtype = node._type
    -- the self-removed function type whose ABI the native trampoline matches
    local ftype = types.Function(mtype.params, mtype.rettypes, false,
        mtype.varargtype, mtype.flexrettype)
    local nativename = bound_method_name(mtype)
    local luaname = bound_method_luaname(mtype)
    local strictname = coder._bound_method_strictname(mtype)
    local mnative = method_name(mtype)
    local mlua = method_luaname(mtype)
    -- The bound trampoline forwards to the method; if its own native frame ever
    -- appears in a trace, name it after the method (<module>.<record>:<method>).
    register_trace_name(tlcontext, nativename,
        mtype.fqtn .. ":" .. mtype.name)
    register_trace_name(tlcontext, strictname,
        mtype.fqtn .. ":" .. mtype.name)
    local rettype = mtype.rettypes[1]

    -- Named parameter list matching function_sig(ftype) so the trampoline body
    -- can forward each one. Names are local to the trampoline (`_bp_N` for params,
    -- `_outparam_N` for out-params), independent of the method's own _cvar names.
    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    local callargs = { "L", "_mod", "NULL",
        "uvalue(&_fn->upvalue[4])" }
    for i, ptype in ipairs(mtype.params) do
        local pname = "_bp_" .. i
        table.insert(cparams, cvardecl(tlcontext, ptype, pname))
        table.insert(callargs, pname)
    end
    -- A variadic method's bound trampoline forwards the backing struct + start
    -- offset verbatim, at the pinned position (after params, before out-params),
    -- so it matches function_sig(ftype) byte-for-byte.
    if mtype.varargtype then
        table.insert(cparams, varg_struct_name(mtype.varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        table.insert(callargs, "_varargs")
        table.insert(callargs, "_start")
    end
    for i = 2, #mtype.rettypes do
        local oname = "_outparam_" .. i
        table.insert(cparams,
            cpointerdecl(mtype.rettypes[i], oname))
        table.insert(callargs, oname)
    end
    if mtype.flexrettype then
        table.insert(cparams,
            varg_struct_name(mtype.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
        table.insert(callargs, "_flexout")
        table.insert(callargs, "_flexwant")
    end
    local call = render("$NAME($ARGS)", {
        NAME = mnative,
        ARGS = table.concat(callargs, ", "),
    })
    local bodycall
    if rettype then
        bodycall = "return " .. call .. ";"
    else
        bodycall = call .. ";\n        return;"
    end

    -- native trampoline signature == function_sig of the self-removed type, but
    -- with named parameters so the body can forward them.
    local storage = node.islocal and "TITAN_SOURCE_LOCAL " or ""
    local strictbody = genluaentry(
        tlcontext, mtype.name, nativename, ftype, node.loc,
        strictname, {
            strict = true,
            strict_name = strictname,
            lua_entry = luaname,
            storage = node.islocal and "TITAN_SOURCE_LOCAL" or "",
            strict_plans = node._bound_strict_guard_plans,
            strict_vararg_plan = node._bound_strict_vararg_guard_plan,
        })
    local nativesig = storage .. cfunctiondecl(
        rettype, nativename, table.concat(cparams, ", "), false)
    -- Public bound trampolines are exported (non-static): a bind site in a
    -- module that only has this module's `.so` reaches the native one for the
    -- fast path AND the Lua one (the closure's lua_CFunction) by dlsym.
    node._boundbody = render([[
    $SIG {
        $BODYCALL
    }
    $STORAGE int $LUANAME(lua_State *L) {
        /* insert the captured receiver (self) as the first stack argument, then
           delegate to the method's Lua entry (which reuses all the boundary
           checks/coercions). upvalue[4] holds the record udata directly (the
           record value IS the udata), which is exactly the Lua-facing value the
           method Lua entry expects. The bound closure's upvalue[0] is the
           method's module, so the method Lua entry recovers _mod correctly from
           it. */
        CClosure *_bound = clCvalue(s2v(L->ci->func.p));
        titan_ensure_stack(L, 1);
        setobj2s(L, L->top.p, &(_bound->upvalue[4]));
        L->top.p++;
        lua_insert(L, 1);
        return $MLUA(L);
    }
    $STRICTBODY]], {
        SIG = nativesig,
        STORAGE = storage,
        BODYCALL = bodycall,
        LUANAME = luaname,
        MLUA = mlua,
        STRICTBODY = strictbody,
    })
    node._boundsig = render([[
        $STORAGE$SIG;
        $STORAGE int $LUANAME(lua_State *L);
        $STORAGE int $STRICTNAME(lua_State *L);
    ]], {
        STORAGE = storage,
        SIG = function_sig(nativename, ftype, false),
        LUANAME = luaname,
        STRICTNAME = strictname,
    })
    -- Publish the bound function type's tag from the DEFINING module (every
    -- method, even one never bound here): a `.so`-only importer recovers the tag
    -- from the registry this module populates, so its bound value's fast path can
    -- recognise the trampoline. (publish-or-recover dedupes a double publish.)
    function_type_tag(tlcontext, ftype)
    coder._transfer_register_source(tlcontext, ftype,
        nativename, luaname, strictname, {{
            type = types.Nominal(mtype.fqtn), boxed = false,
            dynamic_plan = node._lua_dynamic_plans[1], loc = node.loc,
        }}, node.loc)
end

-- Names + registration for a lambda node, assigned on first sight at its use
-- site. Both the closure-creation (codelambda) and the body emission
-- (codelambdadec) read these; assigning here (lazily) keeps the native/Lua names
-- stable across the two.
function lambda_register(tlcontext, node)
    if not node._lambda_native then
        local n = tlcontext.lambda_count
        tlcontext.lambda_count = n + 1
        local stem = coder._private_symbol(tlcontext.module, "lambda", n)
        node._lambda_index = n
        node._lambda_native = stem
        node._lambda_lua = stem .. "_" .. TITAN_ENTRY_TAG .. "_lua"
        node._lambda_strict = stem .. "_" .. TITAN_ENTRY_TAG .. "_strict"
        -- (the lambda's DEFINITION loc), formatted into the name table here.
        register_trace_name(tlcontext, node._lambda_native, anon_qualname(node.loc))
        register_trace_name(tlcontext, node._lambda_strict,
            anon_qualname(node.loc))
        table.insert(tlcontext.lambdas, node)
    end
end

-- Read a captured variable in the CURRENT function for direct initialization
-- of a nested lambda's closure. Returns (boxexpr, valuestats, valueexpr): for a boxed
-- capture, `boxexpr` is the C expression for the box `Udata*`; for a by-value
-- capture, `valueexpr` (with prelude `valuestats`) is the C value expression.
-- A capture that is itself captured by the current function (transitive) is
-- reached through the current `_fn`; otherwise it is a local/param of the current
-- function.
function read_capture(ctx, decl)
    local cap = ctx.captures and ctx.captures[decl]
    if cap then
        -- transitive: the current function captured this decl too
        if cap.boxed then
            return cap.boxvar, nil, nil
        else
            return nil, "", getslot(decl._type, nil,
                "&_fn->upvalue[" .. c_integer_literal(cap.index) .. "]")
        end
    elseif decl._boxed then
        return decl._box, nil, nil
    else
        -- a by-value local/param of the current function
        return nil, "", decl._cvar
    end
end

-- Use-site code for an anonymous function: build a fresh CClosure with
-- upvalue[0]=_mod, [1]=type tag, [2]=native ptr, [3]=closure brand,
-- [4+i]=captured variable i, and the strict LCF in the final upvalue, then
-- return the closure value
-- (anchored in a gc temp). The upvalues are initialized directly while the
-- closure is white; they never transit through the Lua stack.
-- Implementation notes: doc/implementation/codegen-overview.md#closures-and-captured-variables
function codelambda(ctx, node)
    local tlcontext = ctx.tlcontext
    lambda_register(tlcontext, node)
    local ncap = #node._captures
    local nup = 5 + ncap
    local cdecl, tmpname, tmpslot = newtmp(ctx, node._type, true)
    local closurename = tmpname .. "_closure"
    local capturestats = {}

    -- The debt check after publication may run the collector and re-enter code
    -- that relocates the Lua stack. Recompute _base from its saved offset after
    -- it, as for any other stack-relocating operation.
    ctx.uses_base_off = true
    for i, decl in ipairs(node._captures) do
        local captype = decl._type
        local boxexpr, vstats, vexpr = read_capture(ctx, decl)
        local dst = render("&$CLOSURE->upvalue[$INDEX]", {
            CLOSURE = closurename,
            INDEX = c_integer_literal(4 + i - 1),
        })
        if boxexpr then
            table.insert(capturestats, render([[
                setuvalue(L, $DST, $BOX);
            ]], { DST = dst, BOX = boxexpr }))
        else
            table.insert(capturestats, render([[
                $VSTATS
                $SETSLOT
            ]], {
                VSTATS = vstats,
                SETSLOT = setslot(captype, dst, vexpr),
            }))
        end
    end

    -- No barrier is needed while initializing a fresh white closure. Publish it
    -- into its traced result slot before paying the allocation's GC debt.
    local stats = render([[
        $CDECL
        lua_assert($NUP <= MAXUPVAL);
        CClosure *$CLOSURE = luaF_newCclosure(L, $NUP);
        $CLOSURE->f = $LUANAME;
        setuvalue(L, &$CLOSURE->upvalue[0], _mod);
        setpvalue(&$CLOSURE->upvalue[1], (void *)$FUNCTAG);
        setpvalue(&$CLOSURE->upvalue[2],
            titan_cast_func(void *, $NATIVE));
        setpvalue(&$CLOSURE->upvalue[3], TITAN_BRAND);
        $CAPTURES
        setfvalue(&$CLOSURE->upvalue[$STRICTINDEX], $STRICTNAME);
        lua_assert(iswhite($CLOSURE));
        setclCvalue(L, $TMPSLOT, $CLOSURE);
        setclCvalue(L, &$TMPNAME, $CLOSURE);
        luaC_checkGC(L);
        _base = restorestack(L, _base_off);
    ]], {
        NUP = c_integer_literal(nup),
        CLOSURE = closurename,
        LUANAME = node._lambda_lua,
        CDECL = cdecl,
        FUNCTAG = function_type_tag(tlcontext, node._type),
        NATIVE = node._lambda_native,
        CAPTURES = table.concat(capturestats, "\n"),
        STRICTINDEX = c_integer_literal(nup - 1),
        STRICTNAME = node._lambda_strict,
        TMPSLOT = tmpslot,
        TMPNAME = tmpname,
    })
    return stats, tmpname
end

-- Use-site code for a bound method reference `obj:m`: evaluate the receiver once
-- into a C temp, then build a 6-upvalue CClosure exactly like a
-- 1-capture lambda whose capture is `self`:
--   upvalue[0] = the method's module closure
--   upvalue[1] = the self-removed function-type tag (light userdata)
--   upvalue[2] = the bound native trampoline pointer (light userdata)
--   upvalue[3] = the Titan function-closure brand (light userdata)
--   upvalue[4] = self (the captured receiver)
--   upvalue[5] = the bound strict entry (light C function)
-- The closure's lua_CFunction is the bound Lua trampoline. The result is an
-- ordinary Type.Function value, callable through both paths and Lua-crossable.
-- Implementation notes: doc/implementation/codegen-overview.md#bound-method-trampolines
function codemethodref(ctx, node)
    local tlcontext = ctx.tlcontext
    local is_interface = node._interface_bound == true
    local mtype = is_interface
        and assert(node._interface_method) or node._method
    local ftype = node._type -- Type.Function (self removed)
    local nativename = is_interface
        and coder._interface_bound_method_name(mtype)
        or bound_method_name(mtype)
    local luaname = is_interface
        and coder._interface_bound_method_luaname(mtype)
        or bound_method_luaname(mtype)
    local strictname = is_interface
        and coder._interface_bound_method_strictname(mtype)
        or coder._bound_method_strictname(mtype)
    local mod, record = mtype.fqtn:match("^(.*)%.([^.]+)$")

    -- The bound closure's upvalue[0] must be the defining module's closure: `_mod`
    -- for a same-module method, or the imported module's closure recovered from
    -- our `_mod` upvalues exactly as method *calls* do. Cross-module also requires
    -- the trampoline symbol to be reachable (extern / dlsym), registered in
    -- ctx.functions keyed by its mangled name.
    local modexpr = "_mod"
    if mod ~= ctx.module then
        ctx.functions[mtype.fqtn .. (is_interface
            and ":interface-bound:" or ":bound:") .. mtype.name] = {
            module = mod,
            record = record,
            name = mtype.name,
            type = ftype,
            mangled = nativename,
        }
        -- the Lua trampoline (the closure's lua_CFunction) is not function_sig
        -- shaped, so it gets its own extern/dlsym registry entry
        ctx.bound_luas[luaname] = { module = mod }
        ctx.bound_stricts[strictname] = { module = mod }
        nativename = coder._external_reference(ctx, mod, nativename)
        luaname = coder._external_reference(ctx, mod, luaname)
        strictname = coder._external_reference(ctx, mod, strictname)
        if not ctx.modules[mod] then
            ctx.modules[mod] = nextupvalue(ctx.tlcontext)
        end
        modexpr = render("uvalue(&_mod->uv[$INDEX].uv)", {
            INDEX = c_integer_literal(ctx.modules[mod]),
        })
    end

    ctx.uses_base_off = true
    local stats = {}

    -- 1. evaluate the receiver once into a C temp (self: Udata*).
    local rtype = node.exp._type
    local rstat, rexp = codeexp(ctx, node.exp)
    local rdecl, rname = newtmp(ctx, rtype, false)
    table.insert(stats, rstat)
    table.insert(stats, rdecl)
    table.insert(stats, rname .. " = " .. rexp .. ";")

    -- 2. initialize the fresh white closure directly, publish its initial root,
    -- then pay the allocation's GC debt and recover any relocated stack base.
    local cdecl, tmpname, tmpslot = newtmp(ctx, ftype, true)
    local closurename = tmpname .. "_closure"
    table.insert(stats, render([[
        $CDECL
        CClosure *$CLOSURE = luaF_newCclosure(L, 6);
        $CLOSURE->f = $LUANAME;
        setuvalue(L, &$CLOSURE->upvalue[0], $MODEXPR);
        setpvalue(&$CLOSURE->upvalue[1], (void *)$FUNCTAG);
        setpvalue(&$CLOSURE->upvalue[2],
            titan_cast_func(void *, $NATIVE));
        setpvalue(&$CLOSURE->upvalue[3], TITAN_BRAND);
        $SETSELF
        setfvalue(&$CLOSURE->upvalue[5], $STRICTNAME);
        lua_assert(iswhite($CLOSURE));
        setclCvalue(L, $TMPSLOT, $CLOSURE);
        setclCvalue(L, &$TMPNAME, $CLOSURE);
        luaC_checkGC(L);
        _base = restorestack(L, _base_off);
    ]], {
        CDECL = cdecl,
        CLOSURE = closurename,
        LUANAME = luaname,
        MODEXPR = modexpr,
        FUNCTAG = function_type_tag(tlcontext, ftype),
        NATIVE = nativename,
        SETSELF = setslot(rtype,
            "&" .. closurename .. "->upvalue[4]", rname),
        STRICTNAME = strictname,
        TMPSLOT = tmpslot,
        TMPNAME = tmpname,
    }))
    return table.concat(stats, "\n"), tmpname
end

-- File-scope emission of a lambda: its native entry (signature via function_sig,
-- so the uniform (L,_mod,_fn,params...,outparams) ABI) and Lua entry. The body
-- reads captures from _fn->upvalue[4+i]; the ctx.captures map (decl -> {index,
-- boxed, boxvar}) is consulted by codevar/codeassignment before the local/box
-- logic. Produces node._sig / node._body / node._luabody.
function codelambdadec(tlcontext, node)
    local ctx = newcontext(tlcontext)
    local stats = {}
    local rettype = node._type.rettypes[1]
    local fname = node._lambda_native
    local luaname = node._lambda_lua
    -- A try inside this lambda's own body gets its own spill analysis and entry
    -- errorjmp-save (an enclosing function's try does not affect this context).
    ctx.has_try = stat_contains_try(node.block)
    ctx.entry_try = node.block._tag == "Ast.StatTry" and
        node.block.catchblock and node.block or nil
    if ctx.has_try then analyze_try_spills(node.block) end
    -- The lambda's own return types (sizes finally saved-return temps).
    ctx.rettypes = node._type.rettypes
    ctx.flexrettype = node._type.flexrettype or nil

    -- Build the capture map and bind each boxed capture's box pointer once at
    -- body entry. By-value captures are read directly from _fn (immutable).
    ctx.captures = {}
    local capbinds = {}
    for i, decl in ipairs(node._captures) do
        local index = 4 + (i - 1)
        local boxed = decl._boxed and true or false
        local entry = { index = index, boxed = boxed }
        if boxed then
            entry.boxvar = "_box_cap_" .. i
            table.insert(capbinds, render([[
                Udata *$BOXVAR = uvalue(&_fn->upvalue[$INDEX]);
            ]], { BOXVAR = entry.boxvar, INDEX = c_integer_literal(index) }))
        end
        ctx.captures[decl] = entry
    end

    local cparams = { "lua_State *L", "Udata *_mod", "CClosure *_fn" }
    for _, param in ipairs(fixed_params(node.params)) do
        param._cvar = "_param_" .. param.name
        param._boxed = param._captured and param._assigned
        if types.is_gc(param._type) and (param._assigned or param._needs_spill) then
            param._slot = newslot(ctx)
            table.insert(stats, setslot(param._type, param._slot, param._cvar))
        end
        if param._boxed then
            table.insert(stats, codeboxparam(ctx, param))
        end
        table.insert(stats, spill_decl_init(ctx, param))
        table.insert(cparams, coder._local_cvardecl(ctx, param))
    end
    -- A lambda's `ctx` is fresh (newcontext), so ctx.varargs starts nil; set it
    -- only for a variadic lambda. An inner lambda thus NEVER inherits an enclosing
    -- function's `...` (scope rule 4) — its own ctx governs `...` lowering.
    local varargtype = node._type.varargtype
    if varargtype then
        table.insert(cparams, varg_struct_name(varargtype) .. " *_varargs")
        table.insert(cparams, "int _start")
        ctx.varargs = { cname = "_varargs", start = "_start", elem = varargtype }
    end
    for i = 2, #node._type.rettypes do
        local outtype = node._type.rettypes[i]
        table.insert(cparams,
            cpointerdecl(outtype, "_outparam_" .. i))
    end
    if node._type.flexrettype then
        table.insert(cparams,
            varg_struct_name(node._type.flexrettype) .. " *_flexout")
        table.insert(cparams, "int _flexwant")
    end

    local body = codestat(ctx, node.block)
    local nslots = ctx.nslots
    body = body:gsub("TITAN_RESERVED_NSLOTS", c_integer_literal(nslots))
    local baseoff = ctx.uses_base_off
        and "\n        ptrdiff_t _base_off = savestack(L, _base);" or ""
    local entrysave = ctx.used_entry_restore
        and "\n        lua_longjmp *_entry_errorjmp = L->errorJmp;"
        .. "\n        l_uint32 _entry_nC = L->nCcalls;" or ""
    if nslots > 0 then
        table.insert(stats, 1, render([[
        $ENTRYGC
        /* function preamble: reserve needed stack space */
        titan_ensure_stack(L, $NSLOTS);
        StkId _base = L->top.p;
        L->top.p += $NSLOTS;
        for(StkId _s = L->top.p - 1; _base <= _s; _s--) {
            setnilvalue2s(_s);
        }$BASEOFF$ENTRYSAVE
        ]], {
            NSLOTS = c_integer_literal(nslots),
            ENTRYGC = ctx.entry_try and "" or "luaC_checkGC(L);",
            BASEOFF = baseoff,
            ENTRYSAVE = entrysave,
        }))
    else
        table.insert(stats, 1, "        StkId _base = L->top.p;" .. baseoff .. entrysave)
    end
    -- box-capture bindings come first, before any body code or preamble use
    for i = #capbinds, 1, -1 do
        table.insert(stats, 1, capbinds[i])
    end
    table.insert(stats, body)
    local flexempty = node._type.flexrettype
        and "            _flexout->n_args = 0;\n" or ""
    if not rettype then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return;]])
    elseif rettype._tag == "Type.Nil" then
        table.insert(stats, flexempty .. [[
            L->top.p = _base;
            return 0;]])
    else
        local ur = unreachable_return(rettype, node.block)
        if ur then table.insert(stats, ur) end
    end
    coder._record_private_symbol(tlcontext, fname,
        "anonymous function " .. tostring(node._lambda_index))
    coder._record_private_symbol(tlcontext, luaname,
        "anonymous function " .. tostring(node._lambda_index) .. " Lua entry")
    coder._record_private_symbol(tlcontext, node._lambda_strict,
        "anonymous function " .. tostring(node._lambda_index) .. " strict entry")
    local nativesig = cfunctiondecl(
        rettype, fname, table.concat(cparams, ", "), false)
    node._body = render([[
    TITAN_MODULE_PRIVATE $RETENTION$SIGNATURE {
        $BODY
    }]], {
        SIGNATURE = nativesig,
        RETENTION = coder._coverage_keep_native_lambdas and "__attribute__((used)) " or "",
        BODY = table.concat(stats, "\n")
    })
    node._sig = render([[
        TITAN_MODULE_PRIVATE $SIGNATURE;
        TITAN_MODULE_PRIVATE int $LUANAME(lua_State *L);
        TITAN_MODULE_PRIVATE int $STRICTNAME(lua_State *L);
    ]], {
        SIGNATURE = nativesig,
        LUANAME = luaname,
        STRICTNAME = node._lambda_strict,
    })
    node._luabody = genluaentry(
        tlcontext, "lambda", fname, node._type, node.loc, luaname, {
            dynamic_plans = node._lua_dynamic_plans,
            dynamic_vararg_plan = node._lua_vararg_dynamic_plan,
        })
    node._strictbody = genluaentry(
        tlcontext, "lambda", fname, node._type, node.loc,
        node._lambda_strict, {
            strict = true,
            strict_name = node._lambda_strict,
            lua_entry = luaname,
            strict_plans = node._strict_guard_plans,
            strict_vararg_plan = node._strict_vararg_guard_plan,
        })
    local captures = {}
    for index, decl in ipairs(node._captures) do
        captures[index] = {
            type = decl._type, boxed = decl._boxed and true or false,
            dynamic_plan = assert(node._capture_dynamic_plans[index]),
            loc = decl.loc or node.loc,
        }
    end
    coder._transfer_register_source(tlcontext, node._type,
        fname, luaname, node._lambda_strict, captures, node.loc)
end

function codevardec(ctx, initvars, switch_get, switch_set, gvar_map, node)
    local cstats, cexp = codeexp(ctx, node.value)
    node._slot = render("&_mod->uv[$INDEX].uv",
        { INDEX = c_integer_literal(node._upvalue) })
    table.insert(initvars, coverage_region(node, render([[
        $CSTATS
        {
            $CDECL = $CEXP;
            $SETSLOT
            $BARRIER
        }
    ]], {
        CSTATS = cstats,
        CEXP = cexp,
        CDECL = cvardecl(ctx, node._type, "_var"),
        SETSLOT = setslot(node._type, node._slot, "_var"),
        BARRIER = types.is_gc(node._type)
            and "luaC_barrierback(L, obj2gco(_mod), " .. node._slot .. ");" or ""
    }), ctx))
    if not node.islocal then
        table.insert(gvar_map, render([[
            lua_pushinteger(L, $INDEX);
            lua_setfield(L, -2, $NAME);
        ]], {
            INDEX = c_integer_literal(node._upvalue),
            NAME = c_string_literal(node.decl.name),
        }))
        table.insert(switch_get, render([[
            case $I: {
                $COPYSLOT;
                break;
            }
        ]], {
            I = c_integer_literal(node._upvalue),
            COPYSLOT = copyboxed(ctx, node._type,
                "s2v(L->top.p - 1)", node._slot)
        }))
        if node.isconst then
            table.insert(switch_set, render([[
                case $I: {
                    return luaL_error(L,
                        "cannot assign const variable '%s' in Titan module '%s'",
                        lua_tostring(L, 2), $MODULE);
                }
            ]], {
                I = c_integer_literal(node._upvalue),
                MODULE = c_string_literal(ctx.module),
            }))
        else
            table.insert(switch_set, render([[
                case $I: {
                    $SETSLOT;
                    $BARRIER
                    break;
                }
            ]], {
                I = c_integer_literal(node._upvalue),
                SETSLOT = coder._dynamiccheckandset(
                    ctx, maybe3.get_checked(node._lua_write_dynamic_plan, "_lua_write_dynamic_plan"), node._type,
                    node._slot, "_value", node.loc,
                    "Lua module-variable write"),
                BARRIER = types.is_gc(node._type)
                    and "luaC_barrierback(L, obj2gco(_mod), "
                    .. node._slot .. ");" or ""
            }))
        end
    end
end

return core.coder

local core = require "titan-compiler.coder.core"
local _ENV = core

-- `checkandget`/`checkandset` lower the deliberately coercive dynamic
-- boundary shared by written `value as/is T` and genuine Lua entry points.
-- Strict Titan observations (implicit gradual projections, typed Array/Map
-- reads, and branded non-exact Titan calls) use the separate helpers declared
-- here and defined once the native C type helpers are available.
checkandset = nil

-- `loc` is the .titan source location of the raise; it stamps a fully-resolved
-- `#line` directly above the luaL_error so the native frame that throws
-- symbolizes to the throw's exact .titan line instead of a
-- line drifted N rows into the surrounding expanded coercion C. The `#line`
-- uses resolved values (not $LINE/$FILE placeholders) so it is independent of
-- whatever render vars the caller's enclosing template happens to define. The
-- `$LINE`/`$FILE`/etc. placeholders left in $PARAMS are still filled by that
-- enclosing template (ignore_missing=true keeps them intact here).
-- Lua declares luaL_error as returning int even though it always raises. The
-- C99 abort fallback makes this branch terminal for the native optimizer too;
-- otherwise it can join a failed Option force with a zero-initialized result
-- and diagnose the following nominal field access as an out-of-bounds read.
function codethrow(loc, template, params)
    local line = loc and emitline({ loc = loc }) or ""
    return render([[
        $LINEDIR
        luaL_error(L, "$TEMPLATE", $PARAMS);
        abort();
    ]], {
        LINEDIR = line,
        TEMPLATE = template,
        PARAMS = table.concat(params, ',')
    }, true)
end

-- Dynamic Interface discovery is a code-generation property of a nominal
-- target. The checker continues to emit the ordinary nominal plan; resolve the
-- descriptor here only to select the richer runtime lowering.
function coder._is_interface_nominal(typ)
    local resolved = types.normalize(typ)
    if not resolved or resolved._tag ~= "Type.Nominal" then return false end
    local owner = types.registry[resolved.fqtn]
    return owner ~= nil and owner._tag == "Type.Interface"
end

function coder._may_discover_interface(typ)
    local resolved = types.normalize(typ)
    if not resolved then return false end
    if resolved._tag == "Type.Option" then
        return coder._may_discover_interface(resolved.base)
    end
    return coder._is_interface_nominal(resolved)
end

function coder._rebase_after_interface_discovery(ctx, typ)
    if not ctx.tlcontext or not coder._may_discover_interface(typ) then
        return ""
    end
    ctx.uses_base_off = true
    return "_base = restorestack(L, _base_off);"
end

function checkandget(ctx, typ --[[:table]], cvar --[[:string]], exp --[[:string]], loc --[[:table]], retain_interface_result --[[:boolean?]])
    local tag
    if typ._tag == "Type.Integer" then
        return render([[
            if (TITAN_LIKELY(ttisinteger($EXP))) {
                $VAR = ivalue($EXP);
            } else if (ttisfloat($EXP)) {
                lua_Number _v = fltvalue($EXP);
                lua_Number _flt = l_floor(_v);
                if (TITAN_UNLIKELY(_v != _flt)) {
                    $THROWFLOAT
                } else if (TITAN_UNLIKELY(!lua_numbertointeger(_flt, &$VAR))) {
                    $THROWFLOAT
                }
            } else {
                $THROWINTEGER
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROWFLOAT = codethrow(loc, "%s:%d:%d: type error, number '%f' has no integer representation", { "$FILE", "$LINE", "$COL", "_v" }),
            THROWINTEGER = codethrow(loc, "%s:%d:%d: type error, expected integer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.Float" then
        return render([[
            if (TITAN_LIKELY(ttisfloat($EXP))) {
                $VAR = fltvalue($EXP);
            } else if (ttisinteger($EXP)) {
                $VAR = (lua_Number)ivalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected float but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.Boolean" then
        return render([[
            if (l_isfalse($EXP)) {
                $VAR = 0;
            } else {
                $VAR = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif types.is_c_tvalue(typ) then
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif typ._tag == "Type.CInteger" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CInteger") then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, false)
    elseif typ._tag == "Type.CFloat" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CFloat") then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, false)
    elseif types.is_c_udata_pointer(typ) then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
                $VAR = ($CT)uvalue($EXP);
            } else if (ttisnil($EXP)) {
                $VAR = NULL;
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = coder._render_c_type_name(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected C userdata pointer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.CPointer" or
           (typ._tag == "Type.CTypedef" and types.resolve_c_typedef(typ)._tag == "Type.CPointer") then
        return render([[
            if (TITAN_LIKELY(ttislightuserdata($EXP))) {
                $VAR = ($CT)pvalue($EXP);
            } else if (ttisnil($EXP)) {
                $VAR = NULL;
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CT = coder._render_c_type_name(typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected C pointer but found %s", { "$FILE", "$LINE", "$COL", "lua_typename(L, ttype($EXP))" })
        })
    elseif typ._tag == "Type.COwned" then
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP)
                    && uvalue($EXP)->metatable == $META)) {
                $VAR = uvalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            META = coder._owned_c_metatable_expr(ctx, typ),
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", {
                "$FILE", "$LINE", "$COL",
                c_string_literal(types.tostring(typ)),
                "lua_typename(L, ttype($EXP))"
            })
        })
    elseif typ._tag == "Type.Array" then
        -- Lua/value boundaries carry the canonical Array proxy, while the
        -- exact/native representation remains its backing Table*. Use the
        -- module's cached metatable pointer; never query the registry here.
        if typ.isconst.tag == "maybe" then
            return render([[
                {
                    Table *_titan_array =
                        titan_array_try_backing_either($EXP, $MUTABLE_META, $CONST_META);
                    if (TITAN_LIKELY(_titan_array != NULL)) {
                        $VAR = _titan_array;
                    } else {
                        $THROW
                    }
                }
            ]], {
                EXP = exp,
                MUTABLE_META = array_metatable_kind(ctx, false),
                CONST_META = array_metatable_kind(ctx, true),
                VAR = cvar,
                FILE = c_string_literal(loc.filename),
                LINE = c_integer_literal(loc.line),
                COL = c_integer_literal(loc.col),
                THROW = codethrow(loc,
                    "%s:%d:%d: type error, expected array but found %s",
                    { "$FILE", "$LINE", "$COL",
                      "lua_typename(L, ttype($EXP))" }),
            })
        end
        return render([[
            {
                Table *_titan_array = titan_array_try_backing($EXP, $META);
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    $VAR = _titan_array;
                } else {
                    $THROW
                }
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx, typ),
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Nil" then tag = "nil"
    elseif typ._tag == "Type.String" then tag = "string"
    elseif typ._tag == "Type.Map" then tag = "table"
    elseif typ._tag == "Type.Value" then
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif typ._tag == "Type.Function" then
        -- No callability check at the boundary: a function-typed value is
        -- stored boxed exactly like `value`. If it turns out not to be
        -- callable, luaD_callnoyield raises cleanly when it is actually called.
        return render([[
            setobj2t(L, &$VAR, $EXP);
        ]], {
            EXP = exp,
            VAR = cvar
        })
    elseif coder._is_native_option(typ) then
        return render([[
            if (ttisnil($EXP)) {
                $NIL
            } else {
                $CHECK
                ($VAR).present = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            NIL = coder._option_nil(typ, cvar),
            CHECK = checkandget(ctx, typ.base, "(" .. cvar .. ").value", exp, loc),
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if(ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECKANDSET
            }
        ]], {
            VAR = cvar,
            EXP = exp,
            CHECKANDSET = checkandset(ctx, typ.base, "&" .. cvar, exp, loc)
        })
    elseif typ._tag == "Type.Nominal" then
        local metatable = coder._nominal_metatable_expr(ctx, typ)
        local common = {
            MT = metatable,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            EXP = exp,
            VAR = cvar,
            NAME = types.tostring(typ),
            THROWUNKNOWN = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', '"userdata"' }),
            THROWNAMED = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "getstr(tsvalue(&_titan_nominal_name))" }),
            THROWPRIM = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", '"$NAME"', "lua_typename(L, ttype($EXP))" })
        }
        if not coder._is_interface_nominal(typ) then
            return render([[
                if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
                  Udata* _ud = uvalue($EXP);
                  if (TITAN_LIKELY(_ud->metatable == $MT)) {
                    $VAR = _ud;
                  } else {
                    TValue _titan_nominal_key;
                    TValue _titan_nominal_name;
                    setpvalue(&_titan_nominal_key,
                        (void *)_ud->metatable);
                    lu_byte _titan_nominal_name_tag = luaH_get(
                        hvalue(&G(L)->l_registry),
                        &_titan_nominal_key, &_titan_nominal_name);
                    if (tagisempty(_titan_nominal_name_tag)
                            || !ttisstring(&_titan_nominal_name)) {
                        $THROWUNKNOWN
                    } else {
                        $THROWNAMED
                    }
                  }
                } else {
                  $THROWPRIM
                }
            ]], common)
        end

        common.RESTORE_TOP = retain_interface_result and "" or
            "L->top.p = restorestack(L, _titan_interface_call);"
        return render([[
            if (TITAN_LIKELY(ttisfulluserdata($EXP))) {
                Udata *_ud = uvalue($EXP);
                Table *_titan_interface_target = $MT;
                if (TITAN_LIKELY(
                        _ud->metatable == _titan_interface_target)) {
                    $VAR = _ud;
                } else {
                    TValue _titan_interface_key;
                    TValue _titan_interface_witness;
                    lu_byte _titan_interface_witness_tag = LUA_VNIL;
                    if (_ud->metatable != NULL) {
                        sethvalue(L, &_titan_interface_key,
                            _titan_interface_target);
                        _titan_interface_witness_tag = luaH_get(
                            _ud->metatable, &_titan_interface_key,
                            &_titan_interface_witness);
                    }
                    if (TITAN_LIKELY(
                            !tagisempty(_titan_interface_witness_tag))) {
                        ptrdiff_t _titan_interface_call =
                            savestack(L, L->top.p);
                        titan_ensure_stack(L, 2);
                        StkId _titan_interface_func =
                            restorestack(L, _titan_interface_call);
                        setobj2s(L, _titan_interface_func,
                            &_titan_interface_witness);
                        setuvalue(L,
                            s2v(_titan_interface_func + 1), _ud);
                        L->top.p = _titan_interface_func + 2;
                        luaD_callnoyield(L,
                            restorestack(L, _titan_interface_call), 1);
                        $VAR = uvalue(s2v(restorestack(
                            L, _titan_interface_call)));
                        $RESTORE_TOP
                    } else {
                        TValue _titan_nominal_key;
                        TValue _titan_nominal_name;
                        setpvalue(&_titan_nominal_key,
                            (void *)_ud->metatable);
                        lu_byte _titan_nominal_name_tag = luaH_get(
                            hvalue(&G(L)->l_registry),
                            &_titan_nominal_key,
                            &_titan_nominal_name);
                        if (tagisempty(_titan_nominal_name_tag)
                                || !ttisstring(&_titan_nominal_name)) {
                            $THROWUNKNOWN
                        } else {
                            $THROWNAMED
                        }
                    }
                }
            } else {
                $THROWPRIM
            }
        ]], common)
    else
        error("invalid type " .. types.tostring(typ))
    end
    return render([[
        if (TITAN_LIKELY($PREDICATE($EXP))) {
            $GETSLOT;
        } else {
            $THROW
        }
    ]], {
        EXP = exp,
        TAG = c_string_literal(tag),
        PREDICATE = 'ttis'..tag,
        GETSLOT = getslot(typ, cvar, exp),
        FILE = c_string_literal(loc.filename),
        LINE = c_integer_literal(loc.line),
        COL = c_integer_literal(loc.col),
        THROW = codethrow(loc, "%s:%d:%d: type error, expected %s but found %s", { "$FILE", "$LINE", "$COL", "$TAG", "lua_typename(L, ttype($EXP))" })
    })
end

function checkandset(ctx, typ --[[:table]], dst --[[:string]], src --[[:string]], loc --[[:table]])
    return coder._dynamiccheckandset_from_get(ctx, typ, dst, src, loc)
end

function setslot(typ --[[:table]], dst --[[:string]], src --[[:string]])
    local tmpl
    if typ._tag == "Type.Integer" then tmpl = "setivalue($DST, $SRC);"
    elseif typ._tag == "Type.Float" then tmpl = "setfltvalue($DST, $SRC);"
    elseif typ._tag == "Type.Boolean" then tmpl = "titan_setbvalue($DST, $SRC);"
    elseif typ._tag == "Type.Nil" then tmpl = "setnilvalue($DST); ((void)$SRC);"
    elseif typ._tag == "Type.String" then tmpl = "setsvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Array" then tmpl = "sethvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Map" then tmpl = "sethvalue(L, $DST, $SRC);"
    elseif typ._tag == "Type.Value" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif types.is_c_tvalue(typ) then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif typ._tag == "Type.Nominal" then tmpl = "setuvalue(L, $DST, $SRC);"
    elseif coder._is_native_option(typ) then
        return coder._native_option_box(typ, dst, src)
    elseif typ._tag == "Type.Option" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif typ._tag == "Type.Function" then tmpl = "do { TValue _titan_v = $SRC; setobj2t(L, $DST, &_titan_v); } while (0);"
    elseif types.resolve_c_typedef(typ)._tag == "Type.CInteger" then
        return coder._code_checked_numeric_setslot(typ, dst, src)
    elseif types.resolve_c_typedef(typ)._tag == "Type.CFloat" then
        return coder._code_checked_numeric_setslot(typ, dst, src)
    elseif types.is_c_udata_pointer(typ) then
        tmpl = [[do {
            Udata *_titan_u = (Udata *)($SRC);
            if (_titan_u == NULL) setnilvalue($DST);
            else setuvalue(L, $DST, _titan_u);
        } while (0);]]
    elseif types.resolve_c_typedef(typ)._tag == "Type.CPointer" then
        if types.c_pointer_category(typ) == "function" then
            tmpl = "setpvalue($DST, titan_cast_func(void*, $SRC));"
        else
        tmpl = "setpvalue($DST, ((void*)$SRC));"
        end
    elseif types.resolve_c_typedef(typ)._tag == "Type.CArray" then
        tmpl = "setpvalue($DST, ((void*)$SRC));"
    elseif typ._tag == "Type.COwned" then
        tmpl = "setuvalue(L, $DST, $SRC);"
    else
        error("invalid type " .. types.tostring(typ))
    end
    local code = render(tmpl, { DST = dst, SRC = src })
    return code
end

coder._dynamic_op_for_tag = {
    ["Type.Integer"] = "integer",
    ["Type.Float"] = "float",
    ["Type.Boolean"] = "truthiness",
    ["Type.Nil"] = "nil",
    ["Type.String"] = "string",
    ["Type.Value"] = "value",
    ["Type.Array"] = "array",
    ["Type.Map"] = "map",
    ["Type.Function"] = "callable",
    ["Type.Nominal"] = "nominal",
    ["Type.Record"] = "nominal",
    ["Type.Union"] = "nominal",
    ["Type.Interface"] = "nominal",
    ["Type.Option"] = "option",
    ["Type.CInteger"] = "c_integer",
    ["Type.CFloat"] = "c_float",
    ["Type.COwned"] = "c_owned",
}

-- Validate the checker-owned dynamic decision before emitting any operation.
-- Callers unwrap a checked Maybe3 state first. A nil payload is an explicit
-- unavailable policy at the annotated root (currently raw C pointers and
-- compounds containing one). A present Option plan must contain a complete
-- present child plan.
function coder._checked_dynamic_plan_impl(plan, typ, use, seen, root)
    if plan == nil then
        assert(root,
            (use or "dynamic boundary")
                .. " contains an unavailable recursive plan")
        return nil
    end
    assert(plan.kind == "dynamic_coercion",
        (use or "dynamic boundary") .. " has unknown plan kind "
            .. tostring(plan.kind))

    local target = assert(types.normalize(typ),
        (use or "dynamic boundary") .. " has an unnormalizable target")
    assert(plan.target and types.equals(plan.target, target),
        (use or "dynamic boundary") .. " plan target does not match "
            .. types.tostring(typ))

    seen = seen or {}
    local prior = seen[plan]
    if prior then
        assert(types.equals(prior.target, target),
            (use or "dynamic boundary")
                .. " reuses one recursive plan for different targets")
        assert(not prior.active,
            (use or "dynamic boundary")
                .. " contains a recursive dynamic-plan cycle")
        return plan
    end
    seen[plan] = { target = target, active = true }

    local expected = types.is_c_tvalue(target)
        and "c_tvalue" or coder._dynamic_op_for_tag[target._tag]
    assert(expected,
        (use or "dynamic boundary") .. " has unsupported target "
            .. types.tostring(target))
    assert(plan.op == expected,
        (use or "dynamic boundary") .. " has unknown/mismatched operation "
            .. tostring(plan.op))
    if plan.op == "array" then
        assert(plan.isconst.tag == target.isconst.tag
               and types.valid_array_constness(plan.isconst),
            (use or "dynamic boundary")
                .. " has a mismatched Array const qualifier")
    elseif plan.op == "option" then
        assert(plan.isconst == nil,
            (use or "dynamic boundary")
                .. " has an unexpected Array const qualifier")
        coder._checked_dynamic_plan_impl(
            plan.inner, target.base,
            (use or "dynamic boundary") .. " Option present value",
            seen, false)
    else
        assert(plan.isconst == nil,
            (use or "dynamic boundary")
                .. " has an unexpected Array const qualifier")
    end
    seen[plan].active = false
    return plan
end

function coder._checked_dynamic_plan(plan, typ, use)
    return coder._checked_dynamic_plan_impl(plan, typ, use, {}, true)
end

-- Store a native/internal Titan value in a Lua-visible TValue domain.  Arrays
-- are the exceptional representation: internal storage is the backing Table,
-- while Lua/value/raw-Map storage is the canonical proxy Udata.  Keep this
-- helper semantically typed (rather than dispatching on ctype): Array and Map
-- both use Table*, and Option(Array), value, and Function all use TValue.
function setboxed(ctx, typ --[[:table]], dst --[[:string]], src --[[:string]])
    if typ._tag == "Type.Array" then
        return render([[
            {
                Udata *_titan_proxy = titan_array_require_proxy($SRC);
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
        })
    elseif typ._tag == "Type.Option"
           and typ.base._tag == "Type.Array" then
        return render([[
            do {
                TValue _titan_v = $SRC;
                if (ttisnil(&_titan_v)) {
                    setnilvalue($DST);
                } else {
                    Udata *_titan_proxy = titan_array_require_proxy(
                        hvalue(&_titan_v));
                    setuvalue(L, $DST, _titan_proxy);
                }
            } while (0);
        ]], {
            DST = dst,
            SRC = src,
        })
    elseif typ._tag == "Type.Nominal" then
        -- A record value IS the Udata; hand Lua the udata directly ($SRC is a
        -- Udata*).
        return render([[
            setuvalue(L, $DST, $SRC);
        ]], {
            DST = dst,
            SRC = src
        })
    elseif typ._tag == "Type.Option" and typ.base._tag == "Type.Nominal" then
        -- $SRC is a TValue already holding the udata value.
        return render([[
            do {
                TValue _titan_v = $SRC;
                if(ttisnil(&_titan_v)) {
                setnilvalue($DST);
                } else {
                    setobj2t(L, $DST, &_titan_v);
                }
            } while (0);
        ]], {
            DST = dst,
            SRC = src
        })
    else
        return setslot(typ, dst, src)
    end
end

-- Publish a compiler-internal TValue slot through a Lua accessor.  This is
-- type-aware for Array and Option(Array); every other internal slot already
-- has its Lua-visible representation.
function copyboxed(ctx, typ, dst, src)
    if typ._tag == "Type.Array" then
        return render([[
            {
                Udata *_titan_proxy = titan_array_require_proxy(
                    hvalue($SRC));
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
        })
    elseif typ._tag == "Type.Option"
           and typ.base._tag == "Type.Array" then
        return render([[
            if (ttisnil($SRC)) {
                setnilvalue($DST);
            } else {
                Udata *_titan_proxy = titan_array_require_proxy(
                    hvalue($SRC));
                setuvalue(L, $DST, _titan_proxy);
            }
        ]], {
            DST = dst,
            SRC = src,
        })
    end
    return render([[
        setobj2t(L, $DST, $SRC);
    ]], {
        DST = dst,
        SRC = src,
    })
end

function foreigncast(exp, typ --[[:table]])
    return render([[(($CASTTYPE)($CEXP))]], {
        CASTTYPE = coder._render_c_type_name(typ),
        CEXP = exp,
    })
end

function coder._raw_ctype(typ --[[:table]])
    if typ._tag == "Type.Integer" then return "lua_Integer"
    elseif typ._tag == "Type.Float" then return "lua_Number"
    elseif typ._tag == "Type.Boolean" then return "int"
    elseif typ._tag == "Type.Nil" then return "int"
    elseif typ._tag == "Type.String" then return "TString*"
    elseif typ._tag == "Type.Array" then return "Table*"
    elseif typ._tag == "Type.Map" then return "Table*"
    elseif typ._tag == "Type.Value" then return "TValue"
    elseif typ._tag == "Type.Nominal" then return "Udata*"
    elseif typ._tag == "Type.COwned" then
        return cdeclarator.render_type_name(typ)
    elseif types.is_direct_c(typ) then
        return cdeclarator.render_type_name(
            coder._c_value_type(cdeclarator.adjust_parameter_type(typ)))
    elseif coder._is_native_option(typ) then return coder._native_option_ctype(typ)
    elseif typ._tag == "Type.Option" then return "TValue"
    -- A first-class function value is boxed (it may be a Titan closure, a Lua
    -- closure, a C function, or a `__call` object), like `value`/`option`.
    elseif typ._tag == "Type.Function" then return "TValue"
    -- A foreign typedef of a supported scalar (e.g. size_t -> integer) can
    -- leak in via inference; use the C type of its resolved underlying type.
    else error("invalid type " .. types.tostring(typ))
    end
end

function ctype(typ --[[:table]])
    return coder._raw_ctype(typ)
end

function initval(typ --[[:table]])
    if coder._is_native_option(typ) then return "{0}" end
    if typ._tag == "Type.Value" or typ._tag == "Type.Option"
       or typ._tag == "Type.Function" or types.is_c_tvalue(typ) then
        return "{ {0}, 0 }"
    end
    local resolved = types.resolve_c_typedef(typ)
    if resolved._tag == "Type.CStruct" or resolved._tag == "Type.CUnion" then
        return "{0}"
    end
    return "0"
end

-- C declarations for values and temporaries. Recovery homes are selected by
-- _local_cvardecl: ordinary values use spill/reload storage, while address-
-- exposed non-GC scalars use the same volatile object throughout the call.
function cvardecl(ctx, typ, name, quals)
    if types.is_direct_c(typ) then
        local decl_type = typ
        if quals and #quals > 0 then
            decl_type = cdeclarator.adjust_parameter_type(typ)
        end
        return coder._render_c_declaration(
            coder._c_value_type(decl_type), name, quals)
    end
    if quals and #quals > 0 then
        return ctype(typ) .. " " .. table.concat(quals, " ") .. " " .. name
    end
    return ctype(typ) .. " " .. name
end

function fresh_lowering_name(ctx, prefix)
    local index = ctx.tmp or 1
    ctx.tmp = index + 1
    return prefix .. tostring(index)
end

-- Some boxed-store paths predate checker-owned boundary plans, but C
-- scalar/pointer values still need a native temporary because their boxed and
-- native representations differ.  This helper only performs that mechanical
-- representation step; its caller remains responsible for authorization.
function coder._dynamiccheckandset_from_get(ctx, typ, dst, src, loc)
    local name = fresh_lowering_name(ctx, "_titan_checked_c_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = checkandget(ctx, typ, name, src, loc),
        STORE = setslot(typ, dst, name),
    })
end

-- Lower the checker-owned DynamicCoercionPlan to a native/internal result.
-- The per-type emitter below is deliberately not an authorization oracle: the
-- plan operation is validated first, Option recursion consumes `inner`, and a
-- checked unavailable marker emits a well-behaved boundary error.
function coder._dynamiccheckandget(
        ctx, plan, typ, cvar, exp, loc, use,
        retain_interface_result)
    plan = coder._checked_dynamic_plan(plan, typ, use)
    if plan == nil then
        return render([[
            (void)($EXP);
            $THROW
        ]], {
            EXP = exp,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            TYPE = c_string_literal(types.tostring(typ)),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, dynamic coercion to %s is unavailable",
                { "$FILE", "$LINE", "$COL", "$TYPE" }),
        })
    elseif plan.op == "option" and coder._is_native_option(typ) then
        return render([[
            if (ttisnil($EXP)) {
                $NIL
            } else {
                $PRESENT
                ($VAR).present = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            NIL = coder._option_nil(typ, cvar),
            PRESENT = coder._dynamiccheckandget(
                ctx, plan.inner, typ.base, "(" .. cvar .. ").value", exp, loc,
                (use or "dynamic boundary") .. " Option present value",
                retain_interface_result),
        })
    elseif plan.op == "option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $PRESENT
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            PRESENT = coder._dynamiccheckandset(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "dynamic boundary") .. " Option present value",
                retain_interface_result),
        })
    end
    return checkandget(ctx, typ, cvar, exp, loc,
        retain_interface_result)
end

-- Derive the boxed-store form from the exact same native-result plan.  This is
-- the single path used by Lua formals, module/record writes, Array writers,
-- and any other genuine Lua sink, preventing representation-specific drift.
function coder._dynamiccheckandset(
        ctx, plan, typ, dst, src, loc, use,
        retain_interface_result)
    local name = fresh_lowering_name(ctx, "_titan_dynamic_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._dynamiccheckandget(
            ctx, plan, typ, name, src, loc, use,
            retain_interface_result),
        STORE = setslot(typ, dst, name),
    })
end

function coder._planned_value_projection_get(ctx, node, cvar, source)
    local adjustment = node._adjustment
    if adjustment
       and adjustment.kind == "gradual_view"
       and adjustment.op == "project" then
        return coder._strictcheckandget(
            ctx, adjustment.guard, node._type, cvar, source, node.loc,
            "implicit value projection")
    elseif adjustment
           and adjustment.kind == "direct_coercion"
           and adjustment.coercion
           and adjustment.coercion.op == "value_to_c_value" then
        -- A named Option force/map may carry the strict Value-to-C leaf as an
        -- inner coercion because the outer Option operation is itself direct.
        -- It retains gradual-observation semantics: exact C scalar/owned
        -- categories only, never the broader written/Lua conversion.
        return coder._strictcheckandget(
            ctx, adjustment.coercion.guard, node._type, cvar, source,
            node.loc, "Option-composed value projection")
    end

    local cast = assert(maybe3.get_checked(node._written_cast, "written cast"),
        "value projection is missing its checker written-cast plan")
    if cast.op == "dynamic" then
        return coder._dynamiccheckandget(
            ctx, assert(cast.dynamic,
                "dynamic written cast lacks its embedded plan"),
            node._type, cvar, source, node.loc, "written value as",
            nil)
    elseif cast.op == "explicit"
           and cast.conversion
           and cast.conversion.op == "unsafe_dynamic_c_pointer" then
        local target = types.normalize(node._type)
        assert(target and target._tag == "Type.CPointer",
            "unsafe dynamic pointer exception has a non-pointer target")
        -- This is the sole intentional use of the old lightuserdata
        -- category conversion without a DynamicCoercionPlan.  Its authority
        -- is the checker-owned written-cast conversion above.
        return checkandget(ctx, node._type, cvar, source, node.loc)
    end
    error("unknown value projection plan operation " .. tostring(cast.op))
end

coder._gradual_op_for_tag = {
    ["Type.Integer"] = "integer",
    ["Type.Float"] = "float",
    ["Type.Boolean"] = "boolean",
    ["Type.Nil"] = "nil",
    ["Type.String"] = "string",
    ["Type.Value"] = "value",
    ["Type.Array"] = "array",
    ["Type.Map"] = "map",
    ["Type.Function"] = "callable",
    ["Type.Nominal"] = "nominal",
    ["Type.Record"] = "nominal",
    ["Type.Union"] = "nominal",
    ["Type.Interface"] = "nominal",
    ["Type.Option"] = "option",
    ["Type.CInteger"] = "c_integer",
    ["Type.CFloat"] = "c_float",
    ["Type.COwned"] = "c_owned",
}

function checked_gradual_guard(plan, typ, use, seen, root)
    use = use or "strict gradual observation"
    if plan == nil then
        assert(root, use .. " contains an unavailable recursive guard")
        return nil
    end
    assert(plan.kind == "gradual_guard",
        use .. " has unknown guard plan kind " .. tostring(plan.kind))

    local target = assert(types.normalize(typ),
        use .. " has an unnormalizable target")
    assert(plan.target and types.equals(plan.target, target),
        use .. " guard target does not match " .. types.tostring(typ))

    seen = seen or {}
    if seen[plan] then
        assert(types.equals(seen[plan], target),
            use .. " reuses one recursive guard for different targets")
        return plan
    end
    seen[plan] = target

    local expected = types.is_c_tvalue(target)
        and "c_tvalue" or coder._gradual_op_for_tag[target._tag]
    assert(expected,
        use .. " has unsupported guard target " .. types.tostring(target))
    assert(plan.op == expected,
        use .. " has unknown/mismatched guard operation "
            .. tostring(plan.op))
    if expected == "array" then
        assert(plan.isconst.tag == target.isconst.tag
               and types.valid_array_constness(plan.isconst),
            use .. " has a mismatched Array const qualifier")
        checked_gradual_guard(
            plan.element, target.elem, use .. " Array element", seen, false)
    elseif expected == "map" then
        assert(plan.isconst == nil,
            use .. " has an unexpected Array const qualifier")
        checked_gradual_guard(
            plan.key, target.keys, use .. " Map key", seen, false)
        checked_gradual_guard(
            plan.value, target.values, use .. " Map value", seen, false)
    elseif expected == "option" then
        assert(plan.isconst == nil,
            use .. " has an unexpected Array const qualifier")
        checked_gradual_guard(
            plan.inner, target.base, use .. " Option present value",
            seen, false)
    else
        assert(plan.isconst == nil,
            use .. " has an unexpected Array const qualifier")
    end
    return plan
end

function coder._checked_gradual_guard(plan, typ, use)
    return checked_gradual_guard(plan, typ, use, {}, true)
end

function coder._checked_plan_pair(plan, source_type, target_type, use)
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")
    local planned_source = plan.source and types.normalize(plan.source)
    local planned_target = plan.target and types.normalize(plan.target)
    assert(planned_source and planned_target
           and types.equals(planned_source, source)
           and types.equals(planned_target, target),
        use .. " plan does not match its operand types")
    return source, target
end

function coder._checked_identity_plan(plan, source_type, target_type, use)
    assert(plan ~= nil, use .. " lacks its checker plan")
    assert(type(plan) == "table", use .. " reached code generation after rejection")
    assert(plan.kind == "identity",
        use .. " has unknown plan kind " .. tostring(plan.kind))
    local source, target =
        coder._checked_plan_pair(plan, source_type, target_type, use)
    assert(types.equals(source, target)
           or (source._tag == "Type.Array" and target._tag == "Type.Array"
               and target.isconst.tag == "maybe"
               and (source.isconst.tag == "no" or source.isconst.tag == "yes" or source.isconst.tag == "maybe")
               and types.equals(source.elem, target.elem)),
        use .. " identity plan changes its operand type")
    return plan
end

function coder._is_c_pointer_plan_type(typ)
    return typ and typ._tag == "Type.CPointer"
end

function coder._is_boxable_c_value_plan_type(typ)
    if not typ then return false end
    return typ._tag == "Type.CInteger"
        or typ._tag == "Type.CFloat"
        or typ._tag == "Type.COwned"
        or types.is_c_tvalue(typ)
        or typ._tag == "Type.CPointer"
end

function coder._checked_coercion_plan_impl(
        coercion, source_type, target_type, use, seen)
    use = use or "direct coercion"
    assert(coercion ~= nil, use .. " lacks its checker plan")
    assert(type(coercion) == "table",
        use .. " reached code generation after rejection")
    if coercion.kind == "identity" then
        return coder._checked_identity_plan(
            coercion, source_type, target_type, use)
    end
    assert(coercion.kind == "coercion",
        use .. " has unknown plan kind " .. tostring(coercion.kind))

    local source, target =
        coder._checked_plan_pair(coercion, source_type, target_type, use)
    seen = seen or {}
    local prior = seen[coercion]
    if prior then
        assert(types.equals(prior.source, source)
               and types.equals(prior.target, target),
            use .. " reuses one recursive plan for different operand types")
        assert(not prior.active,
            use .. " contains a recursive coercion cycle")
        return coercion
    end
    seen[coercion] = {
        source = source,
        target = target,
        active = true,
    }

    local op = coercion.op
    local numeric_key = source._tag .. ":" .. target._tag
    local expected_numeric = coder._numeric_coercion_ops
        and coder._numeric_coercion_ops[numeric_key]
    if expected_numeric and op == expected_numeric then
        coder._checked_numeric_coercion(
            coercion, source, target, use)
    elseif op == "c_enum_integer" then
        assert(types.is_c_enum_integer_conversion(source, target),
            use .. " has a mismatched C enum/integer operation")
    elseif op == "c_automatic_to_owned" then
        local resolved_source = types.resolve_c_typedef(source)
        assert(target._tag == "Type.COwned" and not target.count
               and (resolved_source._tag == "Type.CStruct"
                    or resolved_source._tag == "Type.CUnion")
               and types.equals(source,
                   types.resolve_c_typedef(target.pointee)),
            use .. " has a mismatched automatic-C-object ownership operation")
    elseif op == "c_automatic_array_to_owned" then
        assert(target._tag == "Type.COwned" and target.count
               and source._tag == "Type.CArray"
               and type(source.len) == "number"
               and types.equals(source.elem, target.pointee),
            use .. " has a mismatched automatic-C-array ownership operation")
    elseif op == "c_owner_truthiness" then
        assert(source._tag == "Type.COwned"
               and target._tag == "Type.Boolean",
            use .. " has a mismatched C-owner truthiness operation")
    elseif op == "c_pointer_truthiness" then
        assert(coder._is_c_pointer_plan_type(source)
               and target._tag == "Type.Boolean",
            use .. " has a mismatched C-pointer truthiness operation")
    elseif op == "nil_to_c_pointer" then
        assert(source._tag == "Type.Nil"
               and coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched nil-to-C-pointer operation")
    elseif op == "c_address" then
        assert(types.c_address_coerceable(source, target),
            use .. " has a mismatched const C-address operation")
    elseif op == "mutable_c_address" then
        assert(types.c_mutable_address_coerceable(source, target),
            use .. " has a mismatched mutable C-address operation")
    elseif op == "c_pointer" then
        assert(types.is_c_pointer_coercion(source, target),
            use .. " has a mismatched C-pointer operation")
    elseif op == "c_object_to_void_pointer" then
        assert(types.is_c_object_to_void_pointer_conversion(
                source, target),
            use .. " has a mismatched C object-to-void-pointer operation")
    elseif op == "c_void_to_object_pointer" then
        assert(types.is_c_void_to_object_pointer_coercion(
                source, target),
            use .. " has a mismatched C void-to-object-pointer operation")
    elseif op == "string_to_c_pointer" then
        assert(types.is_string_to_c_pointer_coercion(source, target),
            use .. " has a mismatched string-to-C-pointer operation")
    elseif op == "c_value_to_value" then
        assert(coder._is_boxable_c_value_plan_type(source)
               and target._tag == "Type.Value",
            use .. " has a mismatched C-value boxing operation")
    elseif op == "value_to_c_value" then
        assert(source._tag == "Type.Value"
               and coder._is_boxable_c_value_plan_type(target)
               and not coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched value-to-C operation")
        coder._checked_gradual_guard(
            coercion.guard, target, use .. " strict C-value guard")
    elseif op == "c_value_to_c_tvalue" then
        assert(coder._is_boxable_c_value_plan_type(source)
               and types.is_c_tvalue(target),
            use .. " has a mismatched C-TValue boxing operation")
    elseif op == "to_c_tvalue" then
        assert(not types.is_direct_c(source)
               and types.is_c_tvalue(target),
            use .. " has a mismatched whole-slot C-TValue operation")
    elseif op == "truthiness" then
        assert(target._tag == "Type.Boolean"
               and source._tag ~= "Type.Boolean"
               and source._tag ~= "Type.Value"
               and not types.is_direct_c(source),
            use .. " has a mismatched truthiness operation")
    elseif op == "option_nil" then
        assert(source._tag == "Type.Nil"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-nil operation")
        assert(coercion.inner == nil,
            use .. " Option-nil operation has an unexpected inner plan")
    elseif op == "option_map" then
        assert(source._tag == "Type.Option"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-map operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source.base, target.base,
            use .. " Option map", seen)
    elseif op == "option_wrap" then
        assert(source._tag ~= "Type.Nil"
               and source._tag ~= "Type.Option"
               and target._tag == "Type.Option",
            use .. " has a mismatched Option-wrap operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source, target.base,
            use .. " Option wrap", seen)
    elseif op == "option_force" then
        assert(source._tag == "Type.Option"
               and target._tag ~= "Type.Option",
            use .. " has a mismatched Option-force operation")
        coder._checked_coercion_plan_impl(
            coercion.inner, source.base, target,
            use .. " Option force", seen)
    elseif op == "interface_wrapper" then
        assert(source._tag == "Type.Nominal"
               and target._tag == "Type.Nominal"
               and type(coercion.methods) == "table",
            use .. " has a mismatched Interface-wrapper operation")
        -- The scalar operation is representation-changing and must be paired
        -- with the richer cast-site `_interface_conversion` annotation. This
        -- validator only proves that the ordinary coercion tree retained the
        -- expected endpoint/op; expression lowering validates and consumes the
        -- canonical descriptors, ordered mappings, and exactness marker.
    else
        error(use .. " has unknown/mismatched operation " .. tostring(op))
    end

    seen[coercion].active = false
    return coercion
end

function coder._checked_coercion_plan(
        coercion, source_type, target_type, use)
    return coder._checked_coercion_plan_impl(
        coercion, source_type, target_type, use, {})
end

function coder._checked_callable_plan_impl(
        callable, source_type, target_type, use, seen)
    use = use or "callable adjustment"
    assert(callable ~= nil, use .. " lacks its checker plan")
    assert(type(callable) == "table",
        use .. " reached code generation after rejection")
    assert(callable.kind == "callable",
        use .. " has unknown plan kind " .. tostring(callable.kind))
    local source, target =
        coder._checked_plan_pair(callable, source_type, target_type, use)
    assert(source._tag == "Type.Function"
           and target._tag == "Type.Function",
        use .. " has non-callable operand types")
    assert(source.vararg == false and target.vararg == false,
        use .. " has a non-false reserved Function slot")
    assert(callable.exact == types.equals(source, target),
        use .. " has a mismatched exact-callable marker")
    assert(type(callable.arguments) == "table"
           and type(callable.results) == "table",
        use .. " lacks its action lists")

    seen = seen or {}
    local prior = seen[callable]
    if prior then
        assert(types.equals(prior.source, source)
               and types.equals(prior.target, target),
            use .. " reuses one recursive plan for different callable types")
        assert(not prior.active,
            use .. " contains a recursive callable-plan cycle")
        return callable
    end
    seen[callable] = {
        source = source,
        target = target,
        active = true,
    }

    local argument_index = 0
    local function argument(kind, label)
        argument_index = argument_index + 1
        local action = callable.arguments[argument_index]
        assert(action,
            use .. " is missing " .. label)
        assert(action.kind == kind,
            use .. " has " .. tostring(action.kind)
                .. " where " .. kind .. " was required")
        return action
    end
    local function component(action, from, to, label)
        assert(action.adjustment
               and action.adjustment.kind ~= "direct_coercion",
            use .. " " .. label
                .. " contains an ordinary component coercion")
        coder._checked_adjustment_plan_impl(
            action.adjustment, from, to,
            use .. " " .. label, seen)
    end

    local function accepts_missing_nil(typ)
        typ = types.normalize(typ)
        local tag = typ and typ._tag
        return tag == "Type.Nil" or tag == "Type.Value"
            or tag == "Type.Option"
            or tag == "Type.CPointer"
    end

    local shared_arguments = math.min(#source.params, #target.params)
    for index = 1, shared_arguments do
        local action = argument("argument", "shared argument action")
        assert(action.expected_index == index
               and action.actual_index == index,
            use .. " has mismatched shared argument indexes")
        component(action, target.params[index], source.params[index],
            "argument " .. index)
    end
    for index = #target.params + 1, #source.params do
        assert(accepts_missing_nil(source.params[index]),
            use .. " nil-fills a non-nullable actual argument")
        if target.varargtype then
            local action = argument(
                "tail_or_nil_to_argument", "tail-to-argument action")
            assert(action.actual_index == index
                   and action.expected_tail_offset
                       == index - #target.params,
                use .. " has mismatched tail-to-argument indexes")
            component(action, target.varargtype, source.params[index],
                "tail-to-argument " .. index)
        else
            local action = argument("nil_fill", "nil-fill action")
            assert(action.actual_index == index,
                use .. " has a mismatched nil-fill index")
            assert(action.adjustment == nil,
                use .. " nil-fill action has an unexpected adjustment")
        end
    end
    for index = #source.params + 1, #target.params do
        if source.varargtype then
            local action = argument(
                "argument_to_tail", "argument-to-tail action")
            assert(action.expected_index == index,
                use .. " has a mismatched argument-to-tail index")
            component(action, target.params[index], source.varargtype,
                "argument-to-tail " .. index)
        else
            local action = argument(
                "ignore_argument", "ignored-argument action")
            assert(action.expected_index == index,
                use .. " has a mismatched ignored-argument index")
            assert(action.adjustment == nil,
                use .. " ignored-argument action has an unexpected adjustment")
        end
    end
    if source.varargtype and target.varargtype then
        local action = argument("tail_to_tail", "tail-to-tail action")
        assert(action.expected_tail_consumed
                   == math.max(0, #source.params - #target.params),
            use .. " has a mismatched tail-to-tail offset")
        component(action, target.varargtype, source.varargtype,
            "input tail")
    elseif source.varargtype then
        local action = argument("empty_tail", "empty-tail action")
        assert(action.adjustment == nil,
            use .. " empty-tail action has an unexpected adjustment")
    elseif target.varargtype then
        local action = argument("ignore_tail", "ignored-tail action")
        assert(action.expected_tail_consumed
                   == math.max(0, #source.params - #target.params),
            use .. " has a mismatched ignored-tail offset")
        assert(action.adjustment == nil,
            use .. " ignored-tail action has an unexpected adjustment")
    end
    assert(argument_index == #callable.arguments,
        use .. " has unexpected extra argument actions")

    local result_index = 0
    local function result(kind, label)
        result_index = result_index + 1
        local action = callable.results[result_index]
        assert(action,
            use .. " is missing " .. label)
        assert(action.kind == kind,
            use .. " has " .. tostring(action.kind)
                .. " where " .. kind .. " was required")
        return action
    end

    for index, expected in ipairs(target.rettypes) do
        local actual = source.rettypes[index]
        if actual then
            local action = result("result", "fixed-result action")
            assert(action.actual_index == index
                   and action.expected_index == index,
                use .. " has mismatched fixed-result indexes")
            component(action, actual, expected, "result " .. index)
        elseif source.flexrettype then
            if expected._tag == "Type.Option" then
                local action = result(
                    "flex_to_optional_result",
                    "flexible-to-optional result action")
                assert(action.expected_index == index
                       and action.actual_flex_offset
                           == index - #source.rettypes,
                    use .. " has mismatched flexible-result indexes")
                assert(action.wrap_present == nil
                       or action.wrap_present == true,
                    use .. " has invalid optional-result wrap metadata")
                local adjusted_target =
                    action.wrap_present and expected.base or expected
                component(action, source.flexrettype, adjusted_target,
                    "flexible result " .. index)
            else
                local action = result(
                    "flex_to_result", "flexible-result action")
                assert(action.expected_index == index
                       and action.actual_flex_offset
                           == index - #source.rettypes,
                    use .. " has mismatched flexible-result indexes")
                assert(action.wrap_present == nil,
                    use .. " non-optional flexible result has wrap metadata")
                component(action, source.flexrettype, expected,
                    "flexible result " .. index)
            end
        else
            local action = result(
                "nil_fill_result", "missing-result nil-fill action")
            assert(accepts_missing_nil(expected)
                   and action.expected_index == index
                   and action.expected_type
                   and types.equals(action.expected_type, expected)
                   and action.adjustment == nil,
                use .. " has a malformed missing-result nil-fill action")
        end
    end
    for index = #target.rettypes + 1, #source.rettypes do
        if target.flexrettype then
            local action = result(
                "result_to_flex", "result-to-flex action")
            assert(action.actual_index == index
                   and action.expected_flex_offset
                       == index - #target.rettypes,
                use .. " has mismatched result-to-flex indexes")
            component(action, source.rettypes[index], target.flexrettype,
                "result-to-flex " .. index)
        else
            local action = result("hide_result", "hidden-result action")
            assert(action.actual_index == index,
                use .. " has a mismatched hidden-result index")
            assert(action.adjustment == nil,
                use .. " hidden-result action has an unexpected adjustment")
        end
    end
    if source.flexrettype and target.flexrettype then
        local action = result("flex_to_flex", "flex-to-flex action")
        assert(action.actual_flex_consumed
                   == math.max(0, #target.rettypes - #source.rettypes),
            use .. " has a mismatched flex-to-flex offset")
        component(action, source.flexrettype, target.flexrettype,
            "flexible result tail")
    elseif source.flexrettype then
        local action = result("hide_flex", "hidden-flex action")
        assert(action.actual_flex_consumed
                   == math.max(0, #target.rettypes - #source.rettypes),
            use .. " has a mismatched hidden-flex offset")
        assert(action.adjustment == nil,
            use .. " hidden-flex action has an unexpected adjustment")
    elseif target.flexrettype then
        local action = result("end_flex", "end-flex action")
        assert(action.adjustment == nil,
            use .. " end-flex action has an unexpected adjustment")
    end
    assert(result_index == #callable.results,
        use .. " has unexpected extra result actions")

    seen[callable].active = false
    return callable
end

function coder._checked_adjustment_plan_impl(
        adjustment, source_type, target_type, use, seen)
    use = use or "assignment adjustment"
    assert(adjustment ~= nil, use .. " lacks its checker plan")
    assert(type(adjustment) == "table",
        use .. " reached code generation after rejection")
    local kind = adjustment.kind
    if kind == "identity" then
        return coder._checked_identity_plan(
            adjustment, source_type, target_type, use)
    end

    local source, target =
        coder._checked_plan_pair(adjustment, source_type, target_type, use)
    if kind == "direct_coercion" then
        coder._checked_coercion_plan_impl(
            adjustment.coercion, source, target,
            use .. " direct coercion", {})
    elseif kind == "gradual_view" then
        local op = adjustment.op
        if op == "inject" then
            assert(target._tag == "Type.Value"
                   and source._tag ~= "Type.Value",
                use .. " has a mismatched gradual injection")
            assert(adjustment.guard == nil,
                use .. " gradual injection has an unexpected guard")
        elseif op == "project" then
            assert(source._tag == "Type.Value"
                   and target._tag ~= "Type.Value",
                use .. " has a mismatched gradual projection")
            coder._checked_gradual_guard(
                adjustment.guard, target, use .. " projection guard")
        elseif op == "structural" then
            assert(source._tag == target._tag
                   and (source._tag == "Type.Array"
                        or source._tag == "Type.Map"
                        or source._tag == "Type.Option"),
                use .. " has a mismatched structural gradual view")
            coder._checked_gradual_guard(
                adjustment.guard, target, use .. " structural guard")
        else
            error(use .. " has unknown gradual-view operation "
                .. tostring(op))
        end
    elseif kind == "callable" then
        coder._checked_callable_plan_impl(
            adjustment, source, target, use, seen or {})
    elseif kind == "written_cast" then
        coder._checked_written_cast_plan(
            adjustment, source, target, use .. " written cast")
    else
        error(use .. " has unknown plan kind " .. tostring(kind))
    end
    return adjustment
end

function coder._checked_adjustment_plan(
        adjustment, source_type, target_type, use)
    return coder._checked_adjustment_plan_impl(
        adjustment, source_type, target_type, use, {})
end

function coder._checked_callable_plan(
        callable, source_type, target_type, use)
    return coder._checked_callable_plan_impl(
        callable, source_type, target_type, use, {})
end

coder._explicit_conversion_ops = {
    pointer_to_string = true,
    gc_identity_to_void_pointer = true,
    legacy_pointer_to_c_void = true,
    c_function_pointer_to_void = true,
    c_void_to_function_pointer = true,
    counted_owner_to_string = true,
    c_numeric = true,
    c_object_to_void_pointer = true,
    c_void_to_object_pointer = true,
    unsafe_dynamic_c_pointer = true,
}

function coder._checked_explicit_conversion_plan(
        conversion, source_type, target_type, use)
    use = use or "written explicit conversion"
    assert(conversion ~= nil, use .. " lacks its checker plan")
    assert(type(conversion) == "table",
        use .. " reached code generation after rejection")
    local source = assert(types.normalize(source_type),
        use .. " has an unnormalizable source")
    local target = assert(types.normalize(target_type),
        use .. " has an unnormalizable target")

    if conversion.kind == "unsafe_object_pointer"
       or conversion.kind == "address_then_unsafe_object_pointer" then
        local planned_source = conversion.source
            and types.normalize(conversion.source)
        local planned_target = conversion.target
            and types.normalize(conversion.target)
        local expected_source
        local source_is_addressable_object = source._tag == "Type.CStruct"
            or source._tag == "Type.CUnion"
        if conversion.kind == "unsafe_object_pointer" then
            if coder._is_c_pointer_plan_type(source) then
                expected_source = source
            elseif source._tag == "Type.CArray" then
                expected_source = types.normalize(
                    types.c_local_address_pointer(source_type))
            end
        else
            expected_source = types.normalize(
                types.c_local_address_pointer(source_type))
        end
        local candidate = planned_source and planned_target
            and types.c_unsafe_object_pointer_candidate(
                planned_source, planned_target)
        assert(coder._is_c_pointer_plan_type(planned_source)
               and coder._is_c_pointer_plan_type(expected_source)
               and coder._is_c_pointer_plan_type(planned_target)
               and coder._is_c_pointer_plan_type(target)
               and candidate
               and types.equals(planned_source, expected_source)
               and types.equals(planned_target, target)
               and type(conversion.probe_key) == "string"
               and conversion.probe_key ~= "",
            use .. " has a mismatched checked C-pointer operation")
        if conversion.kind == "unsafe_object_pointer" then
            assert(coder._is_c_pointer_plan_type(source)
                   or source._tag == "Type.CArray",
                use .. " has an invalid checked C-pointer source")
        else
            assert(source_is_addressable_object,
                use .. " has an invalid checked C-address source")
        end
        return conversion
    end

    assert(conversion.kind == "explicit_conversion",
        use .. " has unknown plan kind " .. tostring(conversion.kind))
    coder._checked_plan_pair(conversion, source, target, use)
    assert(coder._explicit_conversion_ops[conversion.op],
        use .. " has unknown operation " .. tostring(conversion.op))

    local op = conversion.op
    if op == "c_numeric" then
        coder._checked_explicit_numeric_conversion(
            conversion, source, target, use)
    elseif op == "pointer_to_string" then
        assert(types.is_pointer_to_string_cast(source, target),
            use .. " has a mismatched pointer-to-string operation")
    elseif op == "counted_owner_to_string" then
        assert(types.is_counted_c_character_owner(source)
               and target._tag == "Type.String",
            use .. " has a mismatched counted-owner-to-string operation")
    elseif op == "unsafe_dynamic_c_pointer" then
        assert(source._tag == "Type.Value"
               and coder._is_c_pointer_plan_type(target),
            use .. " has a mismatched unsafe dynamic-pointer operation")
    elseif op == "gc_identity_to_void_pointer" then
        assert(types.is_gc_identity_void_pointer_cast(source, target),
            use .. " has a mismatched GC-identity pointer operation")
    elseif op == "c_function_pointer_to_void" then
        assert(types.is_c_function_pointer_void_cast(source, target),
            use .. " has a mismatched C-function-to-void-pointer operation")
    elseif op == "c_void_to_function_pointer" then
        assert(types.is_c_void_function_pointer_cast(source, target),
            use .. " has a mismatched C-void-to-function-pointer operation")
    elseif op == "c_object_to_void_pointer" then
        assert(types.is_c_object_to_void_pointer_conversion(
                source, target),
            use .. " has a mismatched written object-to-void-pointer operation")
    elseif op == "c_void_to_object_pointer" then
        assert(types.is_written_c_void_to_object_pointer_cast(
                source, target),
            use .. " has a mismatched written void-to-object-pointer operation")
    end
    return conversion
end

function coder._checked_written_cast_plan(
        cast, source_type, target_type, use)
    use = use or "written cast"
    assert(cast ~= nil, use .. " lacks its checker plan")
    assert(type(cast) == "table", use .. " reached code generation after rejection")
    assert(cast.kind == "written_cast",
        use .. " has unknown plan kind " .. tostring(cast.kind))
    local source, target =
        coder._checked_plan_pair(cast, source_type, target_type, use)

    if cast.op == "identity" then
        assert(types.equals(source, target),
            use .. " identity operation changes its operand type")
    elseif cast.op == "current_module" then
        assert(source._tag == "Type.Module" and source._current_module
               and types.is_c_udata_pointer(target),
            use .. " has an invalid current-module pointer cast")
    elseif cast.op == "dynamic" then
        assert(source._tag == "Type.Value",
            use .. " dynamic operation has a non-value source")
        coder._checked_dynamic_plan(
            cast.dynamic, target, use .. " dynamic conversion")
    elseif cast.op == "coercion" then
        coder._checked_coercion_plan(
            cast.coercion, source, target, use .. " direct coercion")
    elseif cast.op == "explicit" then
        coder._checked_explicit_conversion_plan(
            cast.conversion, source, target, use .. " explicit conversion")
    elseif cast.op == "callable" then
        coder._checked_callable_plan(
            cast.callable, source, target, use .. " callable adjustment")
    elseif cast.op == "gradual" then
        coder._checked_adjustment_plan(
            cast.view, source, target, use .. " gradual view")
        assert(cast.guard == cast.view.guard,
            use .. " gradual guard differs from its view plan")
    elseif cast.op == "interface_downcast" then
        local source_base = source._tag == "Type.Option"
            and source.base or source
        local source_owner = source_base._tag == "Type.Nominal"
            and types.registry[source_base.fqtn] or nil
        local target_owner = target._tag == "Type.Nominal"
            and types.registry[target.fqtn] or nil
        assert(source_owner
               and source_owner._tag == "Type.Interface"
               and target_owner
               and (target_owner._tag == "Type.Record"
                    or target_owner._tag == "Type.Union"),
            use .. " has a mismatched Interface downcast")
    elseif cast.op == "array_freeze" then
        assert(source._tag == "Type.Array"
               and target._tag == "Type.Array"
               and source.isconst.tag == "no"
               and target.isconst.tag == "yes"
               and (cast.mode == "copy" or cast.mode == "freeze")
               and cast.allocation_free_test == true,
            use .. " has a malformed Array freeze operation")
        if types.equals(source.elem, target.elem) then
            assert(cast.element_view == nil,
                use .. " exact Array freeze has an element view")
        else
            coder._checked_adjustment_plan(
                cast.element_view, source.elem, target.elem,
                use .. " Array element view")
        end
    elseif cast.op == "maybe_array_cast_mutable" then
        assert(source._tag == "Type.Array" and source.isconst.tag == "maybe"
               and target._tag == "Type.Array" and target.isconst.tag == "no",
            use .. " has a malformed maybe-array cast to mutable")
    elseif cast.op == "maybe_array_cast_const" then
        assert(source._tag == "Type.Array" and source.isconst.tag == "maybe"
               and target._tag == "Type.Array" and target.isconst.tag == "yes",
            use .. " has a malformed maybe-array cast to const")
    elseif cast.op == "maybe_array_cast_upcast" then
        assert(source._tag == "Type.Array" and target._tag == "Type.Array"
               and target.isconst.tag == "maybe",
            use .. " has a malformed maybe-array upcast")
    else
        error(use .. " has unknown operation " .. tostring(cast.op))
    end
    return cast
end

function coder._checked_comparison_plan(plan, left, right, use)
    use = use or "equality comparison"
    assert(plan ~= nil, use .. " is missing its checker comparison plan")
    assert(type(plan) == "table", use .. " reached code generation after rejection")
    assert(plan.kind == "comparison",
        use .. " has unknown comparison plan kind " .. tostring(plan.kind))
    left, right = types.normalize(left), types.normalize(right)
    assert(left and right and plan.left and plan.right
           and types.equals(plan.left, left)
           and types.equals(plan.right, right),
        use .. " comparison plan does not match its operand types")
    local op = plan.op
    assert(op == "identity" or op == "consistent"
           or op == "numeric" or op == "option",
        use .. " has unknown comparison operation " .. tostring(op))
    if op == "identity" then
        assert(types.equals(left, right),
            use .. " identity comparison has unequal operands")
    elseif op == "numeric" then
        assert((left._tag == "Type.Integer"
                and right._tag == "Type.Float")
               or (left._tag == "Type.Float"
                   and right._tag == "Type.Integer"),
            use .. " numeric comparison has nonnumeric operand tags")
    elseif op == "consistent" then
        local left_value = left._tag == "Type.Value"
        local right_value = right._tag == "Type.Value"
        if left_value ~= right_value then
            local adjustment
            local unexpected
            if left_value then
                adjustment = plan.right_adjustment
                unexpected = plan.left_adjustment
            else
                adjustment = plan.left_adjustment
                unexpected = plan.right_adjustment
            end
            assert(unexpected == nil,
                use .. " has an adjustment on the value operand")
            coder._checked_adjustment_plan_impl(
                adjustment,
                left_value and right or left,
                left_value and left or right,
                use .. " value injection", {})
        else
            assert(not left_value,
                use .. " consistent comparison duplicates identity")
            assert(plan.left_adjustment == nil
                   and plan.right_adjustment == nil,
                use .. " has an unexpected consistency adjustment")
            assert(left._tag == right._tag
                   and (left._tag == "Type.Array"
                        or left._tag == "Type.Map"
                        or left._tag == "Type.Option"
                        or left._tag == "Type.Function"),
                use .. " has no structural consistency evidence")
        end
    elseif op == "option" then
        assert(left._tag == "Type.Option"
               and right._tag == "Type.Option",
            use .. " Option comparison has non-Option operands")
        coder._checked_comparison_plan(
            plan.inner, left.base, right.base, use .. " Option payload")
    end
    return plan
end

-- Read a boxed slot for a Titan observation through a gradual view.  Unlike
-- `checkandget`, this is a tag guard, not a dynamic conversion: Titan integer,
-- float, and boolean representations must already be exact.  The remaining
-- categories already use exact outer-kind/metatable checks in `checkandget`;
-- Option recurses here so its present arm cannot accidentally regain the
-- coercive numeric/truthiness policy.
function coder._strictcheckandget(
        ctx, plan, typ, cvar, exp, loc, use,
        retain_interface_result)
    plan = coder._checked_gradual_guard(plan, typ, use)
    if plan == nil then
        return render([[
            (void)($EXP);
            $THROW
        ]], {
            EXP = exp,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            TYPE = c_string_literal(types.tostring(typ)),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, strict observation of %s is unavailable",
                { "$FILE", "$LINE", "$COL", "$TYPE" }),
        })
    end
    local resolved = typ._tag == "Type.CTypedef"
        and types.resolve_c_typedef(typ) or typ
    if typ._tag == "Type.Integer" then
        return render([[
            if (TITAN_LIKELY(ttisinteger($EXP))) {
                $VAR = ivalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected integer tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Float" then
        return render([[
            if (TITAN_LIKELY(ttisfloat($EXP))) {
                $VAR = fltvalue($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected float tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Boolean" then
        return render([[
            if (TITAN_LIKELY(ttisboolean($EXP))) {
                $VAR = !l_isfalse($EXP);
            } else {
                $THROW
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected boolean tag but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif resolved._tag == "Type.CInteger" then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, true)
    elseif resolved._tag == "Type.CFloat" then
        return coder._code_checked_boxed_numeric(
            ctx, typ, cvar, exp, loc, true)
    elseif coder._is_native_option(typ) then
        return render([[
            if (ttisnil($EXP)) {
                $NIL
            } else {
                $CHECK
                ($VAR).present = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            NIL = coder._option_nil(typ, cvar),
            CHECK = coder._strictcheckandgetmixed(
                ctx, plan.inner, typ.base, "(" .. cvar .. ").value", exp, loc,
                (use or "strict gradual observation") .. " Option present value",
                retain_interface_result),
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECK
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CHECK = coder._strictcheckandsetmixed(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "strict gradual observation")
                    .. " Option present value",
                retain_interface_result),
        })
    end
    return checkandget(ctx, typ, cvar, exp, loc,
        retain_interface_result)
end

-- Box the result of the same strict observation.  Keeping this mechanically
-- derived from `strictcheckandget` prevents the old function-argument versus
-- field-write split from reappearing for strict paths.
function coder._strictcheckandset(
        ctx, plan, typ, dst, src, loc, use,
        retain_interface_result)
    local name = fresh_lowering_name(ctx, "_titan_strict_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._strictcheckandget(
            ctx, plan, typ, name, src, loc, use,
            retain_interface_result),
        STORE = setslot(typ, dst, name),
    })
end

-- Array/Map slots may contain a nested Array either as its internal backing or
-- as the canonical Lua proxy.  Normalize only those two sanctioned shapes;
-- all leaf observations still use the strict tag policy above.
function coder._strictcheckandgetmixed(
        ctx, plan, typ, cvar, exp, loc, use,
        retain_interface_result)
    plan = coder._checked_gradual_guard(plan, typ, use)
    if plan == nil then
        return coder._strictcheckandget(
            ctx, plan, typ, cvar, exp, loc, use,
            retain_interface_result)
    end
    if typ._tag == "Type.Array" then
        if typ.isconst.tag == "maybe" then
            return render([[
                {
                    Table *_titan_array = NULL;
                    if (ttistable($EXP)) {
                        Table *_titan_candidate = hvalue($EXP);
                        if (titan_array_try_proxy_either(_titan_candidate, $MUTABLE_META, $CONST_META) != NULL)
                            _titan_array = _titan_candidate;
                    } else {
                        _titan_array = titan_array_try_backing_either($EXP, $MUTABLE_META, $CONST_META);
                    }
                    if (TITAN_LIKELY(_titan_array != NULL)) {
                        $VAR = _titan_array;
                    } else {
                        $THROW
                    }
                }
            ]], {
                EXP = exp,
                MUTABLE_META = array_metatable_kind(ctx, false),
                CONST_META = array_metatable_kind(ctx, true),
                VAR = cvar,
                FILE = c_string_literal(loc.filename),
                LINE = c_integer_literal(loc.line),
                COL = c_integer_literal(loc.col),
                THROW = codethrow(loc,
                    "%s:%d:%d: type error, expected array but found %s",
                    { "$FILE", "$LINE", "$COL",
                      "lua_typename(L, ttype($EXP))" }),
            })
        end
        return render([[
            {
                Table *_titan_array = NULL;
                if (ttistable($EXP)) {
                    Table *_titan_candidate = hvalue($EXP);
                    if (titan_array_try_proxy(_titan_candidate, $META) != NULL)
                        _titan_array = _titan_candidate;
                } else {
                    _titan_array = titan_array_try_backing($EXP, $META);
                }
                if (TITAN_LIKELY(_titan_array != NULL)) {
                    $VAR = _titan_array;
                } else {
                    $THROW
                }
            }
        ]], {
            EXP = exp,
            META = array_metatable(ctx, typ),
            VAR = cvar,
            FILE = c_string_literal(loc.filename),
            LINE = c_integer_literal(loc.line),
            COL = c_integer_literal(loc.col),
            THROW = codethrow(loc,
                "%s:%d:%d: type error, expected array but found %s",
                { "$FILE", "$LINE", "$COL",
                  "lua_typename(L, ttype($EXP))" }),
        })
    elseif typ._tag == "Type.Value" then
        return render([[
            if (ttistable($EXP)) {
                Udata *_titan_proxy =
                    titan_array_try_proxy_either(
                        hvalue($EXP), $MUTABLE_META, $CONST_META);
                if (_titan_proxy != NULL) {
                    setuvalue(L, &$VAR, _titan_proxy);
                } else {
                    setobj2t(L, &$VAR, $EXP);
                }
            } else {
                setobj2t(L, &$VAR, $EXP);
            }
        ]], {
            EXP = exp,
            MUTABLE_META = array_metatable_kind(ctx, false),
            CONST_META = array_metatable_kind(ctx, true),
            VAR = cvar,
        })
    elseif coder._is_native_option(typ) then
        return render([[
            if (ttisnil($EXP)) {
                $NIL
            } else {
                $CHECK
                ($VAR).present = 1;
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            NIL = coder._option_nil(typ, cvar),
            CHECK = coder._strictcheckandgetmixed(
                ctx, plan.inner, typ.base, "(" .. cvar .. ").value", exp, loc,
                (use or "strict gradual observation") .. " Option present value",
                retain_interface_result),
        })
    elseif typ._tag == "Type.Option" then
        return render([[
            if (ttisnil($EXP)) {
                setnilvalue(&$VAR);
            } else {
                $CHECK
            }
        ]], {
            EXP = exp,
            VAR = cvar,
            CHECK = coder._strictcheckandsetmixed(
                ctx, plan.inner, typ.base, "&" .. cvar, exp, loc,
                (use or "strict gradual observation")
                    .. " Option present value",
                retain_interface_result),
        })
    end
    return coder._strictcheckandget(
        ctx, plan, typ, cvar, exp, loc, use,
        retain_interface_result)
end

function coder._strictcheckandsetmixed(
        ctx, plan, typ, dst, src, loc, use,
        retain_interface_result)
    local name = fresh_lowering_name(ctx, "_titan_strict_mixed_value_")
    return render([[
        {
            $DECL = $INIT;
            $CHECK
            $STORE
        }
    ]], {
        DECL = cvardecl(ctx, typ, name),
        INIT = initval(typ),
        CHECK = coder._strictcheckandgetmixed(
            ctx, plan, typ, name, src, loc, use,
            retain_interface_result),
        STORE = setslot(typ, dst, name),
    })
end

-- Emit the generated dynamic-boundary writer and initialize its module-local
-- cached CClosure for each Array element type constructed by this module.
-- These closures are carried by proxies; they are never published as tags.
function coder._emit_array_writers(tlcontext, sigs, code, initfuncs)
    for _, entry in ipairs(tlcontext.array_writer_list) do
        local loc = {
            filename = "<Lua write to "
                .. types.tostring(types.Array(entry.elem, { tag = "no" })) .. ">",
            line = 1,
            col = 1,
        }
        table.insert(sigs, render([[
            static int $NAME(lua_State *L);
        ]], {
            NAME = entry.name,
        }))
        table.insert(code, render([[
            static int $NAME(lua_State *L) {
                StkId func = L->ci->func.p;
                if (TITAN_UNLIKELY(L->top.p - func - 1 < 1)) {
                    return luaL_error(L,
                        "missing value for Titan Array writer");
                }
                CClosure *_fn = clCvalue(s2v(func));
                Udata *_mod = uvalue(&_fn->upvalue[0]);
                (void)_mod; /* conversion policies without nominal/C caches */
                titan_ensure_stack(L, 1);
                func = L->ci->func.p;
                TValue *_src = s2v(func + 1);
                $CONVERT
                L->top.p++;
                return 1;
            }
        ]], {
            NAME = entry.name,
            CONVERT = coder._dynamiccheckandset(
                tlcontext, entry.plan, entry.elem,
                "s2v(L->top.p)", "_src", loc, "Array writer"),
        }))
        table.insert(initfuncs, render([[
            titan_pushmodule(L, _mod);
            lua_pushcclosure(L, $NAME, 1);
            setobj2t(L, &_mod->uv[$SLOT].uv, s2v(L->top.p - 1));
            luaC_barrierback(L, obj2gco(_mod), &_mod->uv[$SLOT].uv);
            lua_pop(L, 1);
        ]], {
            NAME = entry.name,
            SLOT = c_integer_literal(entry.slot),
        }))
    end
end

function cpointerdecl(typ, name)
    if types.is_direct_c(typ) then
        return coder._render_c_declaration(
            types.CPointer(coder._c_value_type(typ), {}), name)
    end
    return ctype(typ) .. " *" .. name
end

function cpointertype(typ)
    if types.is_direct_c(typ) then
        return coder._render_c_type_name(
            types.CPointer(coder._c_value_type(typ), {}))
    end
    return ctype(typ) .. "*"
end

function cfunctiondecl(rettype, name, params, is_pointer)
    local declarator = is_pointer and "(*" .. name .. ")" or name
    declarator = declarator .. "(" .. params .. ")"
    if rettype
       and types.is_direct_c(rettype) then
        return coder._render_c_declaration(rettype, declarator)
    end
    return (rettype and ctype(rettype) or "void") .. " " .. declarator
end

return core.coder

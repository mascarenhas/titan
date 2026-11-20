local core = require "titan-compiler.coder.core"
local _ENV = core

function coder._resolve_cast_type(typ)
    return types.resolve_c_typedef(typ)
end

function coder._is_numeric_type(typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    return tag == "Type.Integer" or tag == "Type.Float"
        or tag == "Type.CInteger" or tag == "Type.CFloat"
end

function coder._is_c_numeric_type(typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    return tag == "Type.CInteger" or tag == "Type.CFloat"
end

function coder._numeric_carriers(source_type, target_type)
    local source = coder._resolve_cast_type(source_type)
    local target = coder._resolve_cast_type(target_type)
    local anchor
    if source and (source._tag == "Type.CInteger"
                   or source._tag == "Type.CFloat") then
        anchor = source
    elseif target and (target._tag == "Type.CInteger"
                       or target._tag == "Type.CFloat") then
        anchor = target
    end
    assert(anchor and anchor._c_numeric_carriers,
        "C numeric lowering lacks authoritative target-profile metadata")
    return anchor._c_numeric_carriers
end

function coder._numeric_trait(source_type, target_type, typ)
    local resolved = coder._resolve_cast_type(typ)
    local tag = resolved and resolved._tag
    local carriers = coder._numeric_carriers(source_type, target_type)
    if tag == "Type.Integer" then
        return carriers.lua_integer
    elseif tag == "Type.Float" then
        return carriers.lua_number
    elseif tag == "Type.CInteger" or tag == "Type.CFloat" then
        assert(resolved._c_numeric,
            "direct C numeric type lacks target-profile traits")
        assert(resolved._c_numeric_carriers
               and resolved._c_numeric_carriers.identity == carriers.identity,
            "C numeric conversion combines different target profiles")
        return resolved._c_numeric
    end
    error("non-numeric type in numeric lowering: " .. types.tostring(typ))
end

function coder._numeric_c_name(typ, trait)
    local resolved = coder._resolve_cast_type(typ)
    if resolved._tag == "Type.Integer" then return "lua_Integer" end
    if resolved._tag == "Type.Float" then return "lua_Number" end
    return trait.spelling
end

function coder._integer_maximum_expression(trait)
    local ct = trait.spelling
    if not trait.signed then
        if trait.precision == 1 then
            return render("(($CT)1)", { CT = ct })
        end
        return render("((($CT)~($CT)0))", { CT = ct })
    end
    assert(trait.unsigned and trait.precision,
        "signed C integer trait lacks its unsigned partner/precision")
    return render([[
        (($CT)((((($UCT)1) << $PRECISION) - (($UCT)1))))
    ]], {
        CT = ct,
        UCT = trait.unsigned,
        PRECISION = c_integer_literal(trait.precision),
    })
end

function coder._integer_minimum_expression(trait)
    if not trait.signed then
        return render("(($CT)0)", { CT = trait.spelling })
    end
    return render("(($CT)(-($MAXIMUM) - 1))", {
        CT = trait.spelling,
        MAXIMUM = coder._integer_maximum_expression(trait),
    })
end

function coder._integer_range_predicate(
        source_type, target_type, source, source_trait, target_trait)
    local contains, err =
        coder._csemantics.integer_range_contains(
            target_trait, source_trait)
    assert(contains ~= nil, err)
    if contains then return "1" end

    local checks = {}
    local source_ct = coder._numeric_c_name(source_type, source_trait)
    if source_trait.signed and not target_trait.signed then
        checks[#checks + 1] = render("(($SOURCE) >= 0)", {
            SOURCE = source,
        })
    elseif source_trait.signed and target_trait.signed
           and target_trait.precision < source_trait.precision then
        checks[#checks + 1] = render(
            "(($SOURCE) >= (($SOURCE_CT)($MINIMUM)))", {
                SOURCE = source,
                SOURCE_CT = source_ct,
                MINIMUM = coder._integer_minimum_expression(target_trait),
            })
    end

    local needs_maximum
    if source_trait.signed == target_trait.signed then
        needs_maximum =
            target_trait.precision < source_trait.precision
    else
        needs_maximum =
            target_trait.precision < source_trait.precision
    end
    if needs_maximum then
        checks[#checks + 1] = render(
            "(($SOURCE) <= (($SOURCE_CT)($MAXIMUM)))", {
                SOURCE = source,
                SOURCE_CT = source_ct,
                MAXIMUM = coder._integer_maximum_expression(target_trait),
            })
    end
    assert(#checks > 0,
        "non-containing integer ranges produced no runtime checks")
    return "(" .. table.concat(checks, " && ") .. ")"
end

function coder._float_integer_capacity(trait)
    assert(trait and trait.kind == "float"
           and trait.maximum_exponent and trait.radix,
        "integer-to-floating lowering lacks target radix/exponent metadata")
    local radix = trait.radix
    local radix_binary_exponent = 0
    while radix >= 2 do
        radix = math.floor(radix / 2)
        radix_binary_exponent = radix_binary_exponent + 1
    end
    assert(radix_binary_exponent > 0)
    -- C's maximum finite value is at least radix^(maximum_exponent - 1).
    -- This lower bound is deliberately conservative for non-binary targets.
    return radix_binary_exponent * (trait.maximum_exponent - 1)
end

-- Generate the non-raising acceptance half of one native numeric conversion.
-- The source expression must already be stable. The returned setup statements
-- run before the predicate; callers cast/store only after it succeeds.
function coder._code_native_numeric_predicate(
        ctx, source_type, target_type, source, mode)
    assert(coder._is_numeric_type(source_type)
           and coder._is_numeric_type(target_type),
        "numeric predicate received a non-numeric type")
    local source_res = coder._resolve_cast_type(source_type)
    local target_res = coder._resolve_cast_type(target_type)
    local source_trait =
        coder._numeric_trait(source_type, target_type, source_type)
    local target_trait =
        coder._numeric_trait(source_type, target_type, target_type)

    if source_trait.kind == "integer"
       and target_trait.kind == "integer" then
        if mode == "c_operator"
           or (mode == "explicit_c"
               and source_res._tag == "Type.CInteger"
               and target_res._tag == "Type.CInteger") then
            return "", "1"
        end
        return "", coder._integer_range_predicate(
            source_type, target_type, source, source_trait, target_trait)
    elseif source_trait.kind == "float"
           and target_trait.kind == "float" then
        if target_trait.rank >= source_trait.rank then
            return "", "1"
        end
        assert(target_trait.maximum_macro,
            "narrow C floating target lacks its <float.h> maximum")
        return "", render([[
            (isfinite((long double)($SOURCE))
                && fabsl((long double)($SOURCE))
                    <= (long double)($MAXIMUM))
        ]], {
            SOURCE = source,
            MAXIMUM = target_trait.maximum_macro,
        })
    elseif source_trait.kind == "integer"
           and target_trait.kind == "float" then
        if source_trait.precision <=
           coder._float_integer_capacity(target_trait) then
            return "", "1"
        end
        local long_double = coder._numeric_carriers(
            source_type, target_type).long_double
        assert(source_trait.precision <=
               coder._float_integer_capacity(long_double),
            "integer source is wider than the target profile's long double")
        assert(target_trait.maximum_macro,
            "C floating target lacks its <float.h> maximum")
        return "", render([[
            (fabsl((long double)($SOURCE))
                <= (long double)($MAXIMUM))
        ]], {
            SOURCE = source,
            MAXIMUM = target_trait.maximum_macro,
        })
    elseif source_trait.kind == "float"
           and target_trait.kind == "integer" then
        assert(ctx, "float-to-integer acceptance needs a lowering context")
        local truncated =
            fresh_lowering_name(ctx, "_titan_numeric_truncated_")
        local magnitude = render(
            "ldexpl(1.0L, $PRECISION)", {
                PRECISION = c_integer_literal(target_trait.precision),
            })
        local lower = target_trait.signed
            and "(-(" .. magnitude .. "))" or "0.0L"
        return render([[
            long double $TRUNCATED =
                truncl((long double)($SOURCE));
        ]], {
            TRUNCATED = truncated,
            SOURCE = source,
        }), render([[
            (isfinite((long double)($SOURCE))
                && $TRUNCATED >= $LOWER
                && $TRUNCATED < $UPPER)
        ]], {
            SOURCE = source,
            TRUNCATED = truncated,
            LOWER = lower,
            UPPER = magnitude,
        })
    end
    error("unknown numeric conversion category")
end

coder._numeric_coercion_ops = {
    ["Type.Integer:Type.Float"] = "integer_to_float",
    ["Type.Float:Type.Integer"] = "float_to_integer",
    ["Type.CInteger:Type.Integer"] = "c_integer_to_integer",
    ["Type.Integer:Type.CInteger"] = "integer_to_c_integer",
    ["Type.CFloat:Type.Float"] = "c_float_to_float",
    ["Type.Float:Type.CFloat"] = "float_to_c_float",
    ["Type.Integer:Type.CFloat"] = "integer_to_c_float",
}

-- Central authority check for scalar coercion lowering. Tag-driven dispatch is
-- not permission: every automatic/written coercion must carry the exact
-- checker-owned source/target/op decision.
function coder._checked_numeric_coercion(plan, source_type, target_type, use)
    assert(plan, (use or "numeric coercion") .. " lacks its checker plan")
    assert(plan.kind == "coercion",
        (use or "numeric coercion") .. " has unknown plan kind "
            .. tostring(plan.kind))
    local source = assert(types.normalize(source_type))
    local target = assert(types.normalize(target_type))
    assert(plan.source and plan.target
           and types.equals(plan.source, source)
           and types.equals(plan.target, target),
        (use or "numeric coercion")
            .. " plan does not match its operand types")
    local key = source._tag .. ":" .. target._tag
    local expected = coder._numeric_coercion_ops[key]
    assert(expected and plan.op == expected,
        (use or "numeric coercion")
            .. " has unknown/mismatched operation " .. tostring(plan.op))
    return plan
end

function coder._checked_explicit_numeric_conversion(
        conversion, source_type, target_type, use)
    assert(conversion,
        (use or "explicit C numeric conversion") .. " lacks its checker plan")
    assert(conversion.kind == "explicit_conversion"
           and conversion.op == "c_numeric",
        (use or "explicit C numeric conversion")
            .. " has unknown plan operation " .. tostring(conversion.op))
    local source = assert(types.normalize(source_type))
    local target = assert(types.normalize(target_type))
    assert(conversion.source and conversion.target
           and types.equals(conversion.source, source)
           and types.equals(conversion.target, target)
           and coder._is_c_numeric_type(source)
           and coder._is_c_numeric_type(target),
        (use or "explicit C numeric conversion")
            .. " plan does not match its operand types")
    return conversion
end

function coder._numeric_range_throw(loc, source_type, target_type)
    return codethrow(loc,
        "%s:%d:%d: type error, numeric value is outside the range of %s",
        {
            c_string_literal(loc.filename),
            c_integer_literal(loc.line),
            c_integer_literal(loc.col),
            c_string_literal(types.tostring(target_type)),
        })
end

-- Checked native-to-native scalar conversion. Integer-to-integer explicit C
-- casts retain C semantics; every other potentially unsafe crossing validates
-- representability before the cast and before any destination mutation.
function coder._code_checked_numeric_cast(
        ctx, source_type, target_type, source, loc, mode)
    -- A function may return a const-qualified C typedef. Capture it in its
    -- declaration so universal foreign-call materialization does not require
    -- a later assignment to a read-only temporary.
    local csource, source_name = newtmp(ctx, source_type, false, source)
    local ctarget, target_name = newtmp(ctx, target_type)
    local predicate_stats, predicate =
        coder._code_native_numeric_predicate(
            ctx, source_type, target_type, source_name, mode)
    local target_trait =
        coder._numeric_trait(source_type, target_type, target_type)
    return render([[
        $CSOURCE
        $PREDICATE_STATS
        if (TITAN_UNLIKELY(!($PREDICATE))) {
            $THROW
        }
        $CTARGET
        $TARGET_NAME = (($TARGET_CT)$SOURCE_NAME);
    ]], {
        CSOURCE = csource,
        SOURCE_NAME = source_name,
        PREDICATE_STATS = predicate_stats,
        PREDICATE = predicate,
        THROW = coder._numeric_range_throw(
            loc, source_type, target_type),
        CTARGET = ctarget,
        TARGET_NAME = target_name,
        TARGET_CT = coder._numeric_c_name(target_type, target_trait),
    }), target_name
end

function coder._code_boxed_numeric_predicate(
        ctx, target, source, strict)
    local resolved = coder._resolve_cast_type(target)
    local result_decl, result = newtmp(ctx, types.Boolean())
    local lines = { result_decl, result .. " = 0;" }

    local function branch(tag_predicate, source_type, get_value, prefix)
        local source_decl, source_name = newtmp(ctx, source_type)
        local predicate_stats, predicate =
            coder._code_native_numeric_predicate(
                ctx, source_type, target, source_name, "boundary")
        lines[#lines + 1] = render([[
            $PREFIX ($TAG_PREDICATE) {
                $SOURCE_DECL
                $SOURCE_NAME = $GET_VALUE;
                $PREDICATE_STATS
                $RESULT = $PREDICATE;
            }
        ]], {
            PREFIX = prefix,
            TAG_PREDICATE = tag_predicate,
            SOURCE_DECL = source_decl,
            SOURCE_NAME = source_name,
            GET_VALUE = get_value,
            PREDICATE_STATS = predicate_stats,
            RESULT = result,
            PREDICATE = predicate,
        })
    end

    if resolved._tag == "Type.CInteger" then
        branch("ttisinteger(" .. source .. ")", types.Integer(),
            "ivalue(" .. source .. ")", "if")
        if not strict then
            local value_decl, value = newtmp(ctx, types.Float())
            local integer_decl, integer = newtmp(ctx, types.Integer())
            local predicate_stats, predicate =
                coder._code_native_numeric_predicate(
                    ctx, types.Integer(), target, integer, "boundary")
            lines[#lines + 1] = render([[
                else if (ttisfloat($SOURCE)) {
                    $VALUE_DECL
                    $INTEGER_DECL
                    $VALUE = fltvalue($SOURCE);
                    if (isfinite($VALUE)
                        && truncl((long double)$VALUE)
                            == (long double)$VALUE
                        && lua_numbertointeger($VALUE, &$INTEGER)) {
                        $PREDICATE_STATS
                        $RESULT = $PREDICATE;
                    }
                }
            ]], {
                SOURCE = source,
                VALUE_DECL = value_decl,
                INTEGER_DECL = integer_decl,
                VALUE = value,
                INTEGER = integer,
                PREDICATE_STATS = predicate_stats,
                RESULT = result,
                PREDICATE = predicate,
            })
        end
    else
        branch("ttisfloat(" .. source .. ")", types.Float(),
            "fltvalue(" .. source .. ")", "if")
        if not strict then
            branch("ttisinteger(" .. source .. ")", types.Integer(),
                "ivalue(" .. source .. ")", "else if")
        end
    end
    return table.concat(lines, "\n"), result
end

function coder._code_checked_boxed_numeric(
        ctx, target, cvar, source, loc, strict)
    local predicate_stats, predicate =
        coder._code_boxed_numeric_predicate(
            ctx, target, source, strict)
    local resolved = coder._resolve_cast_type(target)
    local tag_name = resolved._tag == "Type.CInteger"
        and "C-integer" or "C-float"
    return render([[
        $PREDICATE_STATS
        if (TITAN_UNLIKELY(!($PREDICATE))) {
            $THROW
        }
        if (ttisinteger($SOURCE)) {
            $CVAR = (($CT)ivalue($SOURCE));
        } else {
            $CVAR = (($CT)fltvalue($SOURCE));
        }
    ]], {
        PREDICATE_STATS = predicate_stats,
        PREDICATE = predicate,
        SOURCE = source,
        CVAR = cvar,
        CT = coder._render_c_type_name(target),
        THROW = codethrow(loc,
            "%s:%d:%d: type error, expected representable %s but found %s",
            {
                c_string_literal(loc.filename),
                c_integer_literal(loc.line),
                c_integer_literal(loc.col),
                c_string_literal(tag_name),
                "lua_typename(L, ttype(" .. source .. "))",
            }),
    })
end

function coder._code_checked_numeric_setslot(typ, dst, src)
    local resolved = coder._resolve_cast_type(typ)
    local target = resolved._tag == "Type.CInteger"
        and types.Integer() or types.Float()
    local predicate_stats, predicate =
        coder._code_native_numeric_predicate(
            nil, typ, target, "_titan_numeric_box_source", "carrier")
    assert(predicate_stats == "",
        "C scalar carrier boxing unexpectedly needs predicate setup")
    local store = resolved._tag == "Type.CInteger"
        and "setivalue($DST, ((lua_Integer)_titan_numeric_box_source));"
        or "setfltvalue($DST, ((lua_Number)_titan_numeric_box_source));"
    return render([[
        do {
            $DECL = $SRC;
            if (TITAN_UNLIKELY(!($PREDICATE))) {
                luaL_error(L,
                    "type error, C scalar is outside its Titan carrier range");
            }
            $STORE
        } while (0);
    ]], {
        DECL = coder._render_c_declaration(
            typ, "_titan_numeric_box_source"),
        SRC = src,
        PREDICATE = predicate,
        STORE = render(store, { DST = dst }),
    })
end

-- Predicate twin of checkandget's value->integer/C-integer conversion.
function coder._code_boxed_is_integer(ctx, source)
    local cresult, result = newtmp(ctx, types.Boolean())
    local cvalue, value = newtmp(ctx, types.Float())
    local cfloor, floor = newtmp(ctx, types.Float())
    local cinteger, integer = newtmp(ctx, types.Integer())
    return render([[
        $CRESULT
        $CVALUE
        $CFLOOR
        $CINTEGER
        $RESULT = 0;
        if (ttisinteger($SOURCE)) {
            $RESULT = 1;
        } else if (ttisfloat($SOURCE)) {
            $VALUE = fltvalue($SOURCE);
            $FLOOR = l_floor($VALUE);
            $RESULT = ($VALUE == $FLOOR
                && lua_numbertointeger($FLOOR, &$INTEGER));
        }
    ]], {
        CRESULT = cresult,
        RESULT = result,
        CVALUE = cvalue,
        VALUE = value,
        CFLOOR = cfloor,
        FLOOR = floor,
        CINTEGER = cinteger,
        INTEGER = integer,
        SOURCE = source,
    }), result
end

-- Interface `is` is the non-invoking twin of dynamic discovery. Exact wrappers
-- retain the likely fast path; otherwise a non-nil raw metatable entry is
-- sufficient, even when debug/foreign code installed a non-callable value.
function coder._code_interface_discovery_predicate(ctx, target, source)
    local cresult, result = newtmp(ctx, types.Boolean())
    return render([[
        $CRESULT
        {
            Table *_titan_interface_target = $TARGET;
            $RESULT = 0;
            if (ttisfulluserdata($SOURCE)) {
                Udata *_titan_interface_candidate = uvalue($SOURCE);
                if (_titan_interface_candidate->metatable ==
                        _titan_interface_target) {
                    $RESULT = 1;
                } else if (_titan_interface_candidate->metatable != NULL) {
                    TValue _titan_interface_key;
                    TValue _titan_interface_witness;
                    sethvalue(L, &_titan_interface_key,
                        _titan_interface_target);
                    lu_byte _titan_interface_witness_tag = luaH_get(
                        _titan_interface_candidate->metatable,
                        &_titan_interface_key,
                        &_titan_interface_witness);
                    $RESULT = !tagisempty(
                        _titan_interface_witness_tag);
                }
            }
        }
    ]], {
        CRESULT = cresult,
        RESULT = result,
        SOURCE = source,
        TARGET = coder._nominal_metatable_expr(ctx, target),
    }), result
end

local function array_predicate(ctx, target, source)
    if target.isconst.tag == "maybe" then
        return render([[
            ((ttistable($SOURCE)
                && titan_array_try_proxy_either(hvalue($SOURCE), $MUTABLE, $CONST) != NULL)
             || titan_array_try_backing_either($SOURCE, $MUTABLE, $CONST) != NULL)
        ]], {
            SOURCE = source,
            MUTABLE = array_metatable_kind(ctx, false),
            CONST = array_metatable_kind(ctx, true),
        })
    end
    return render([[
        ((ttistable($SOURCE)
            && titan_array_try_proxy(hvalue($SOURCE), $META) != NULL)
         || titan_array_try_backing($SOURCE, $META) != NULL)
    ]], {
        SOURCE = source,
        META = array_metatable(ctx, target),
    })
end

-- Return setup statements and a C boolean expression for the non-raising form
-- of one checker-owned DynamicCoercionPlan.  This is the predicate twin of
-- `dynamiccheckandget`: in particular Option recurses through the embedded
-- plan, so a present `boolean?` uses truthiness just like `boolean`.
function coder._code_dynamic_predicate(ctx, plan, target, source)
    plan = coder._checked_dynamic_plan(plan, target, "written value is")
    if plan == nil then return "", "0" end
    local resolved = coder._resolve_cast_type(target)
    local op = plan.op

    if op == "integer" then
        return coder._code_boxed_is_integer(ctx, source)
    elseif op == "c_integer" or op == "c_float" then
        return coder._code_boxed_numeric_predicate(
            ctx, target, source, false)
    elseif op == "float" then
        return "", render("(ttisfloat($SOURCE) || ttisinteger($SOURCE))", {
            SOURCE = source,
        })
    elseif op == "truthiness" or op == "value"
           or op == "callable" or op == "c_tvalue" then
        return "", "1"
    elseif op == "c_owned" then
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable ==
                    hvalue(&_mod->uv[$META].uv))
        ]], {
            SOURCE = source,
            META = c_integer_literal(owned_c_metatable(ctx, resolved)),
        })
    elseif op == "array" then
        return "", array_predicate(ctx, resolved, source)
    elseif op == "nil" then
        return "", render("ttisnil($SOURCE)", { SOURCE = source })
    elseif op == "string" then
        return "", render("ttisstring($SOURCE)", { SOURCE = source })
    elseif op == "map" then
        return "", render("ttistable($SOURCE)", { SOURCE = source })
    elseif op == "nominal" then
        assert(resolved._tag == "Type.Nominal",
            "current nominal dynamic lowering requires a nominal value type")
        if coder._is_interface_nominal(resolved) then
            return coder._code_interface_discovery_predicate(
                ctx, resolved, source)
        end
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable == $META)
        ]], {
            SOURCE = source,
            META = render("hvalue(&_mod->uv[$INDEX].uv)", {
                INDEX = c_integer_literal(type2metatable(ctx, resolved)),
            }),
        })
    elseif op == "option" then
        local basestats, baseexp =
            coder._code_dynamic_predicate(
                ctx, plan.inner, resolved.base, source)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CRESULT
            if (ttisnil($SOURCE)) {
                $RESULT = 1;
            } else {
                $BASESTATS
                $RESULT = $BASEEXP;
            }
        ]], {
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
            BASESTATS = basestats,
            BASEEXP = baseexp,
        }), result
    end

    error("unknown dynamic predicate operation " .. tostring(op))
end

-- Non-raising twin of `_strictcheckandget` for a checker-owned GuardPlan.
-- Written tests between gradual Option views need to inspect the immediate
-- present payload without accidentally applying the broader Lua conversion
-- policy. Arrays, Maps, and callables retain deferred component checks; their
-- outer representation test is all that this predicate observes.
function coder._code_strict_predicate(ctx, plan, target, source)
    plan = coder._checked_gradual_guard(
        plan, target, "written gradual type test")
    if plan == nil then return "", "0" end

    local resolved = coder._resolve_cast_type(target)
    local op = plan.op
    if op == "integer" then
        return "", render("ttisinteger($SOURCE)", { SOURCE = source })
    elseif op == "c_integer" or op == "c_float" then
        return coder._code_boxed_numeric_predicate(
            ctx, target, source, true)
    elseif op == "float" then
        return "", render("ttisfloat($SOURCE)", { SOURCE = source })
    elseif op == "boolean" then
        return "", render("ttisboolean($SOURCE)", { SOURCE = source })
    elseif op == "nil" then
        return "", render("ttisnil($SOURCE)", { SOURCE = source })
    elseif op == "string" then
        return "", render("ttisstring($SOURCE)", { SOURCE = source })
    elseif op == "value" or op == "callable"
           or op == "c_tvalue" then
        return "", "1"
    elseif op == "array" then
        return "", array_predicate(ctx, resolved, source)
    elseif op == "map" then
        return "", render("ttistable($SOURCE)", { SOURCE = source })
    elseif op == "nominal" then
        assert(resolved._tag == "Type.Nominal",
            "strict nominal predicate requires a nominal value type")
        if coder._is_interface_nominal(resolved) then
            return coder._code_interface_discovery_predicate(
                ctx, resolved, source)
        end
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable == $META)
        ]], {
            SOURCE = source,
            META = render("hvalue(&_mod->uv[$INDEX].uv)", {
                INDEX = c_integer_literal(type2metatable(ctx, resolved)),
            }),
        })
    elseif op == "c_owned" then
        return "", render([[
            (ttisfulluserdata($SOURCE)
                && uvalue($SOURCE)->metatable ==
                    hvalue(&_mod->uv[$META].uv))
        ]], {
            SOURCE = source,
            META = c_integer_literal(owned_c_metatable(ctx, resolved)),
        })
    elseif op == "option" then
        local innerstats, innerexp = coder._code_strict_predicate(
            ctx, plan.inner, resolved.base, source)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CRESULT
            if (ttisnil($SOURCE)) {
                $RESULT = 1;
            } else {
                $INNERSTATS
                $RESULT = $INNEREXP;
            }
        ]], {
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
            INNERSTATS = innerstats,
            INNEREXP = innerexp,
        }), result
    end

    error("unknown strict predicate operation " .. tostring(op))
end

-- Non-raising twin of a checker-owned direct CoercionPlan. Most direct
-- coercions are total; the numeric narrowing and recursive Option operations
-- below are the cases whose corresponding `as` can reject the already
-- evaluated operand. The recursive helper consumes the exact stored inner
-- plan rather than asking the relation again.
function coder._code_coercion_predicate(
        ctx, coercion, source_type, target_type, source)
    coercion = coder._checked_coercion_plan(
        coercion, source_type, target_type,
        "written coercion type test")
    if coercion.kind == "identity" then return "", "1" end

    local op = coercion.op
    if coder._numeric_coercion_ops[
            assert(types.normalize(source_type))._tag .. ":"
            .. assert(types.normalize(target_type))._tag] then
        coder._checked_numeric_coercion(
            coercion, source_type, target_type,
            "written numeric coercion type test")
    end
    if op == "c_enum_integer" then
        assert(types.is_c_enum_integer_conversion(source_type, target_type),
            "C enum/integer predicate has mismatched types")
        return render("(void)($SOURCE);", { SOURCE = source }), "1"
    elseif op == "float_to_integer" then
        local cvalue, value = newtmp(ctx, types.Float())
        local cfloor, floor = newtmp(ctx, types.Float())
        local cinteger, integer = newtmp(ctx, types.Integer())
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CVALUE
            $CFLOOR
            $CINTEGER
            $CRESULT
            $VALUE = $SOURCE;
            $FLOOR = l_floor($VALUE);
            $RESULT = ($VALUE == $FLOOR
                && lua_numbertointeger($FLOOR, &$INTEGER));
        ]], {
            CVALUE = cvalue,
            VALUE = value,
            CFLOOR = cfloor,
            FLOOR = floor,
            CINTEGER = cinteger,
            INTEGER = integer,
            CRESULT = cresult,
            RESULT = result,
            SOURCE = source,
        }), result
    elseif op == "integer_to_float" then
        return render("(void)($SOURCE);", { SOURCE = source }), "1"
    elseif op == "c_integer_to_integer"
           or op == "integer_to_c_integer"
           or op == "c_float_to_float"
           or op == "float_to_c_float"
           or op == "integer_to_c_float" then
        return coder._code_native_numeric_predicate(
            ctx, source_type, target_type, source, "boundary")
    elseif op == "value_to_c_value" then
        assert(source_type._tag == "Type.Value",
            "value-to-C predicate has a non-value source")
        return coder._code_strict_predicate(
            ctx, assert(coercion.guard,
                "value-to-C predicate lacks its strict guard"),
            target_type, "&" .. source)
    elseif op == "option_nil" then
        return "", "1"
    elseif op == "option_wrap" then
        return coder._code_coercion_predicate(
            ctx, coercion.inner, source_type, target_type.base, source)
    elseif op == "option_force" or op == "option_map" then
        local source_base = source_type.base
        local inner_target = op == "option_map"
            and target_type.base or target_type
        local cbase, basename =
            newtmp(ctx, source_base, types.is_gc(source_base))
        local innerstats, innerexp = coder._code_coercion_predicate(
            ctx, coercion.inner, source_base, inner_target, basename)
        local cresult, result = newtmp(ctx, types.Boolean())
        return render([[
            $CBASE
            $CRESULT
            if (!($PRESENT)) {
                $RESULT = $NILRESULT;
            } else {
            $GETBASE;
                $INNERSTATS
                $RESULT = $INNEREXP;
            }
        ]], {
            CBASE = cbase,
            CRESULT = cresult,
            PRESENT = coder._option_present(source_type, source),
            RESULT = result,
            NILRESULT = op == "option_map" and "1" or "0",
            GETBASE = coder._option_get(source_type, basename, source),
            INNERSTATS = innerstats,
            INNEREXP = innerexp,
        }), result
    end

    -- Truthiness, widening, boxing, admitted pointer conversions, and whole
    -- C-TValue copies cannot reject an already evaluated value. Checked C
    -- scalar representability operations are handled here by their dedicated
    -- branches once classified with the same CoercionPlan.
    return render("(void)($SOURCE);", { SOURCE = source }), "1"
end

-- Implementation notes: doc/implementation/codegen-constructs.md#type-tests-expis
function coder._codeis(ctx, node)
    if node.length then
        return coder._code_counted_string(ctx, node, true)
    end
    if node._interface_downcast then
        return coder._code_interface_downcast(ctx, node, true)
    elseif node._interface_test then
        local test = node._interface_test
        local conversion = assert(test.conversion)
        assert(test.kind == "interface_implementation_test"
               and test.allocation_free == true
               and conversion.kind == "interface_conversion"
               and not conversion.source_optional
               and not conversion.target_optional,
            "malformed allocation-free Interface implementation test")
        local concrete = assert(conversion.concrete)
        local interface = assert(conversion.interface)
        assert((concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
               and interface._tag == "Type.Interface"
               and types.validate_interface_descriptor(interface)
               and #conversion.methods == #interface.methods,
            "malformed allocation-free Interface implementation mapping")
        local all_exact = true
        for index, mapping in ipairs(conversion.methods) do
            local required = interface.methods[index]
            assert(mapping.index == index - 1
                   and mapping.required == required
                   and mapping.name == required.name
                   and mapping.concrete
                   and mapping.concrete._tag == "Type.Method"
                   and mapping.concrete.fqtn == concrete.name
                   and mapping.source
                   and mapping.target
                   and types.equals(
                       mapping.source,
                       types.method_function_type(mapping.concrete))
                   and types.equals(
                       mapping.target,
                       types.method_function_type(required))
                   and mapping.exact == types.equals(
                       mapping.source, mapping.target),
                "malformed allocation-free Interface mapping at slot "
                    .. tostring(index - 1))
            all_exact = all_exact and mapping.exact
            if mapping.exact then
                assert(mapping.slot_kind == "exact"
                       and mapping.interface_adapter == nil,
                    "malformed exact Interface implementation mapping")
            else
                assert(mapping.slot_kind == "adapter"
                       and mapping.interface_adapter,
                    "adjusted Interface implementation test lacks its plan")
                coder._validate_interface_adapter(
                    mapping.interface_adapter,
                    concrete, interface, mapping,
                    "allocation-free Interface test slot "
                        .. tostring(index - 1))
            end
        end
        assert(conversion.exact == all_exact,
            "allocation-free Interface test has wrong exactness")
        local stats, source = materialize(ctx, node.exp)
        return stats .. "\n(void)(" .. source .. ");", "1"
    end

    -- Freeze the operand before inspecting it. This both enforces exactly-once
    -- evaluation and roots GC values while metatable/Array checks run.
    local original_source_type = node.exp._type
    local cast = coder._checked_written_cast_plan(
        maybe3.get_checked(node._written_cast, "written cast"),
        original_source_type, node.target,
        "written type test")
    if cast.op == "current_module" then
        return "", "1"
    end
    local source_type = coder._resolve_cast_type(node.exp._type)
    local target_type = coder._resolve_cast_type(node.target)
    local stats, source
    if source_type._tag == "Type.CStruct"
       or source_type._tag == "Type.CUnion" then
        -- Generic temporaries use scalar initialization, which is not valid
        -- for a by-value C aggregate. Preserve the ordinary assignment-based
        -- aggregate materialization used by other expression consumers.
        stats, source = coder._materialize_c_aggregate(ctx, node.exp)
    else
        stats, source = materialize(ctx, node.exp)
    end
    local predicate_stats, predicate

    if cast.op == "maybe_array_cast_mutable" or cast.op == "maybe_array_cast_const" then
        predicate_stats = ""
        predicate = render("(titan_array_try_proxy($SOURCE, $META) != NULL)", {
            SOURCE = source,
            META = array_metatable(ctx, target_type),
        })
    elseif source_type._tag == "Type.Value" then
        if cast.op == "identity" then
            predicate_stats = render("(void)($SOURCE);", { SOURCE = source })
            predicate = "1"
        elseif cast.op == "dynamic" then
            predicate_stats, predicate =
                coder._code_dynamic_predicate(
                    ctx, assert(cast.dynamic,
                        "dynamic written cast lacks its embedded plan"),
                    node.target, "&" .. source)
        elseif cast.op == "explicit"
               and cast.conversion
               and cast.conversion.op == "unsafe_dynamic_c_pointer" then
            predicate_stats = ""
            local category = types.is_c_udata_pointer(node.target)
                and "ttisfulluserdata" or "ttislightuserdata"
            predicate = render(
                "($CATEGORY($SOURCE) || ttisnil($SOURCE))", {
                    CATEGORY = category,
                    SOURCE = "&" .. source,
                })
        else
            error("unknown value type-test plan operation "
                .. tostring(cast.op))
        end
    elseif (node._written_cast and node._written_cast.tag == "just")
           and maybe3.get_checked(node._written_cast, "written cast").op == "coercion" then
        predicate_stats, predicate = coder._code_coercion_predicate(
            ctx, assert(maybe3.get_checked(node._written_cast, "written cast").coercion),
            original_source_type, node.target, source)
    elseif (node._written_cast and node._written_cast.tag == "just")
           and maybe3.get_checked(node._written_cast, "written cast").op == "explicit"
           and maybe3.get_checked(node._written_cast, "written cast").conversion
           and maybe3.get_checked(node._written_cast, "written cast").conversion.op == "c_numeric" then
        coder._checked_explicit_numeric_conversion(
            maybe3.get_checked(node._written_cast, "written cast").conversion,
            original_source_type, node.target,
            "written C numeric type test")
        predicate_stats, predicate =
            coder._code_native_numeric_predicate(
                ctx, original_source_type, node.target,
                source, "explicit_c")
    elseif (node._written_cast and node._written_cast.tag == "just")
           and maybe3.get_checked(node._written_cast, "written cast").op == "gradual"
           and source_type._tag == "Type.Option"
           and target_type._tag == "Type.Option" then
        if coder._is_native_option(source_type)
           and coder._is_native_option(target_type)
           and coder._native_option_ctype(source_type)
                == coder._native_option_ctype(target_type) then
            -- Transparent numeric typedef views already have the target's
            -- exact carrier; there is no boxed payload tag to inspect.
            return stats .. "\n(void)(" .. source .. ");", "1"
        end
        -- Option has no separate component-bearing backing. A written gradual
        -- test therefore observes its present payload now, with strict
        -- consistency guards rather than Lua-boundary coercions. Structural
        -- Array/Map/callable tests remain total at this outer view edge.
        predicate_stats, predicate = coder._code_strict_predicate(
            ctx, maybe3.get_checked(node._written_cast, "written cast").guard, node.target, "&" .. source)
    elseif original_source_type._tag == "Type.Option"
           and types.equals(original_source_type.base, node.target) then
        predicate = coder._option_present(original_source_type, source)
        predicate_stats = ""
    elseif (node._written_cast and node._written_cast.tag == "just")
           and maybe3.get_checked(node._written_cast, "written cast").op == "explicit"
           and maybe3.get_checked(node._written_cast, "written cast").conversion
           and maybe3.get_checked(node._written_cast, "written cast").conversion.op ==
               "gc_identity_to_void_pointer"
           and source_type._tag == "Type.Function" then
        -- Function values deliberately defer callability checks until call
        -- time, so their boxed TValue is not necessarily collectable.  The
        -- explicit void-pointer cast can expose an identity only when there is
        -- an underlying GC object.
        predicate = render("iscollectable(&$SOURCE)", { SOURCE = source })
        predicate_stats = ""
    elseif source_type._tag == "Type.CPointer"
           and target_type._tag == "Type.String" then
        predicate = render("($SOURCE != NULL)", { SOURCE = source })
        predicate_stats = ""
    else
        -- Identity, boxing, truthiness, numeric widening, C numeric/pointer
        -- conversions, and every other admitted explicit cast are total.
        predicate_stats = render("(void)($SOURCE);", { SOURCE = source })
        predicate = "1"
    end

    return stats .. "\n" .. predicate_stats, predicate
end

return core.coder

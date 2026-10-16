local core = require "titan-compiler.checker.core"
local _ENV = core

local function strip_linear_from_type(t)
    if not t or type(t) ~= "table" then return t end
    if t._tag == "Type.Array" and t.linear then
        local stripped = types.Array(t.elem, t.isconst)
        return stripped
    elseif t._tag == "Type.Function" then
        local new_rets = {}
        local changed = false
        for i, ret in ipairs(t.rettypes) do
            local stripped = strip_linear_from_type(ret)
            new_rets[i] = stripped
            if stripped ~= ret then changed = true end
        end
        if changed then
            return types.Function(t.params, new_rets, t.vararg, t.varargtype, t.flexrettype)
        end
    end
    return t
end

-- Typechecks an expression
--   node: Exp_* AST node
--   st: symbol table
--   errors: list of compile-time errors
--   context: expected type for this expression, if applicable
--   annotates the node with its type in a "_type" field
checkexp = util.make_visitor({
    ["Ast.ExpForeignType"] = function(node, st, errors, context)
        node._type = typefromnode(node.type, st, errors)
        if context ~= c_type_namespace_context then
            node._type = invalid(errors, node.loc,
                "a foreign type expression requires a new, new_array, sizeof, or alignof operation")
        end
    end,

    ["Ast.ExpNil"] = function(node)
        node._type = types.Nil()
    end,

    ["Ast.ExpBool"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            node._type = st.c_profile and st.c_profile.integers
                and st.c_profile.integers._Bool
                and st.c_profile.integers._Bool.type
                or types.CInteger("_Bool", false, 0, 8)
            node._foreign_literal = true
        else
            node._type = types.Boolean()
        end
    end,

    ["Ast.ExpInteger"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            local spelling = st.c_profile and st.c_profile.int or "int"
            node._type = st.c_profile and st.c_profile.integers
                and st.c_profile.integers[spelling]
                and st.c_profile.integers[spelling].type
                or types.CInteger("int", true, 3, 32)
            node._foreign_literal = true
        else
            node._type = types.Integer()
        end
    end,

    ["Ast.ExpFloat"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            node._type = st.c_profile and st.c_profile.floats
                and st.c_profile.floats.double
                and st.c_profile.floats.double.type
                or types.CFloat("double")
            node._foreign_literal = true
        else
            node._type = types.Float()
        end
    end,

    ["Ast.ExpString"] = function(node, st)
        if checker._foreign_function_depth > 0 then
            local char = st.c_profile and st.c_profile.integers
                and st.c_profile.integers.char
                and st.c_profile.integers.char.type
                or types.CInteger("char", true, 1, 8)
            node._type = types.CPointer(char, { "const" })
            node._foreign_string_literal = true
        else
            node._type = types.String()
        end
    end,

    ["Ast.ExpUnionInit"] = function(node, st, errors, _)
        local owner_node = st:find_symbol(node.owner)
        local union = owner_node and owner_node._type
        local variant = node.variant and node.variant._type
        if not owner_node or owner_node._tag ~= "Ast.TopLevelUnion"
           or not union or union._tag ~= "Type.Union" then
            node._type = invalid(errors, node.loc,
                "invalid synthesized union constructor owner '%s'",
                tostring(node.owner))
            for _, value in ipairs(node.values) do checkexp(value, st, errors) end
            return
        elseif not variant or variant._tag ~= "Type.Variant"
           or variant.fqtn ~= union.name
           or union.variants[variant.name] ~= variant then
            node._type = invalid(errors, node.loc,
                "invalid synthesized variant constructor for union '%s'",
                union.name)
            for _, value in ipairs(node.values) do checkexp(value, st, errors) end
            return
        end

        node._union = union
        node._variant = variant
        if #node.values ~= #variant.parts then
            checker.typeerror(errors, node.loc,
                "variant '%s.%s' has mismatched synthesized payload values",
                union.name, variant.name)
        end
        for index, value in ipairs(node.values) do
            local part = variant.parts[index]
            checkexp(value, st, errors, part and part.type)
            if part then
                node.values[index] = coerce_and_check(
                    value, part.type,
                    "part " .. part.name .. " of variant " .. variant.name,
                    errors, value.loc)
            end
        end
        node._type = types.Nominal(
            union.name, generic_parameter_arguments(union))
    end,

    ["Ast.ExpInitList"] = function(node, st, errors, context)
        return generic_with_inference_operation(
            node, st, function(operation)
        context = context and deoptionize(context)
        local dependent_context = operation and context
            and generic_inference_type_has_unresolved(
                operation.context, context)
        local shape, kinds, dots_field, invalid_dots =
            classify_constructor_fields(node, errors)

        local direct_context = dependent_context
            and context._tag == "Type.Parameter"
            and generic_inference_cell(
                operation.context, context)
        if shape == "empty" and direct_context then
            generic_defer_empty_constructor(
                node, st, errors, context, operation)
            return
        elseif shape == "positional" and direct_context then
            generic_check_direct_positional_constructor(
                node, st, errors, context, operation)
            return
        elseif shape == "computed" and direct_context then
            generic_check_direct_computed_constructor(
                node, st, errors, context, operation)
            return
        end

        if invalid_dots or shape == "mixed" then
            if shape == "mixed" then
                checker.typeerror(errors, node.loc,
                    "cannot mix %s fields in a constructor",
                    table.concat(kinds, ", "))
            end
            check_rejected_constructor_fields(node, st, errors, context)
            node._type = context or types.Invalid()
            return
        end

        local expected = context and context._tag
        if expected ~= "Type.Array"
           and expected ~= "Type.Map"
           and expected ~= "Type.Nominal" then
            if shape == "computed" then
                expected = "Type.Map"
            elseif shape == "named" then
                expected = "Type.Nominal"
            else
                -- Empty and positional constructors default to Array without a
                -- useful structural context.
                expected = "Type.Array"
            end
            -- A direct ambient cell has no owner shape yet. Preserve it only
            -- for a named constructor: its fields can be checked once now and
            -- the record owner can be discovered from later sibling evidence.
            if not (shape == "named" and dependent_context) then
                context = nil
            end
        end

        if dots_field and expected == "Type.Nominal" then
            checker.typeerror(errors, dots_field.loc,
                "'...' can only appear in an all-positional array or integer-keyed map constructor")
            check_rejected_constructor_fields(node, st, errors, context)
            node._type = context or types.Invalid()
            return
        end

        if expected == "Type.Array" then
            if shape == "empty" or shape == "positional" then
                check_positional_constructor(node, st, errors, expected, nil,
                    context and context.elem, operation,
                    context and context.isconst or nil)
            else
                for _, field in ipairs(node.fields) do
                    if shape == "named" then
                        checker.typeerror(errors, field.loc,
                            "initializing field '%s' when expecting array",
                            field.name)
                    else
                        checker.typeerror(errors, field.loc,
                            "initializing a computed field when expecting array")
                    end
                end
                check_rejected_constructor_fields(node, st, errors)
                node._type = context or types.Array(types.Integer(), { tag = "no" })
            end
        elseif expected == "Type.Map" then
            if shape == "computed" then
                check_computed_map_constructor(
                    node, st, errors, context, operation)
            elseif shape == "empty" then
                assert(context)
                check_computed_map_constructor(
                    node, st, errors, context, operation)
            elseif shape == "positional" then
                assert(context)
                if types.equals(context.keys, types.Integer()) then
                    check_positional_constructor(node, st, errors, expected,
                        context.keys, context.values, operation)
                else
                    checker.typeerror(errors, node.loc,
                        "positional fields require an integer-keyed map, but found key type %s",
                        types.tostring(context.keys))
                    check_rejected_constructor_fields(
                        node, st, errors, context)
                    node._type = context
                end
            else
                assert(context)
                for _, field in ipairs(node.fields) do
                    checker.typeerror(errors, field.loc,
                        "initializing field '%s' when expecting map", field.name)
                end
                check_rejected_constructor_fields(node, st, errors)
                node._type = context
            end
        elseif expected == "Type.Nominal" then
            generic_check_named_record_constructor(
                node, st, errors, context, operation)
        end
        end, "constructor")
    end,

    ["Ast.ExpVar"] = function(node, st, errors, context)
        -- A generic/for-in eligibility probe may already own the Var descent.
        -- Reuse its annotations, then continue with this consumer's contextual
        -- first-class, foreign-function, and value handling below.
        if not node._generic_var_prechecked then
            generic_checkvar_for_expression(node, st, errors, context)
        end
        if node.var._decl then node.var._decl._used = true end
        local texp = node.var._type
        if node.var._generic_owner_explicit then
            node._type = invalid(errors, node.loc,
                "an explicitly applied nominal function can only be used in a direct call")
        elseif #(node._nominal_typeargs or {}) > 0 then
            node._type = invalid(errors, node.loc,
                "explicit type arguments are only supported in a direct call")
        elseif texp._tag == "Type.Module" and texp._current_module
               and context == current_module_cast_context then
            node._type = texp
        elseif texp._tag == "Type.Module" or texp._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "trying to access module '%s' as a first-class value",
                node.var.name)
        elseif c_resolve(texp)
               and c_resolve(texp)._tag == "Type.CFunction" then
            -- A direct C declaration is not a value. Its only value-producing
            -- context is decay to an exactly compatible C function pointer;
            -- there is no Titan closure or Lua-callable representation.
            local cfunc = c_resolve(texp)
            local var = node.var
            local reference = checker._foreign_function_reference(var)
            if reference
               and c_function_pointer_accepts_declaration(context, cfunc) then
                node._type = context
                node._foreign_function_reference = reference
                if not reference.source then
                    node._foreign_function_pointer = reference.name
                end
            else
                node._type = invalid(errors, node.loc,
                    "a foreign (C) function cannot be used as a first-class value")
            end
        elseif texp._tag == "Type.FunctionScheme"
           or (texp._tag == "Type.Function"
               and node.var._generic_declaration) then
            local closed = generic_instantiate_first_class_variable(
                node, node.var, texp, context, st, errors)
            if closed then
                node._type = strip_linear_from_type(closed)
                local decl = node.var._decl
                if decl and decl._tag == "Ast.TopLevelFunc" then
                    decl._valref = true
                end
            else
                node._type = invalid(errors, node.loc,
                    "generic declaration '%s' requires a monomorphic expected function type when used as a first-class value",
                    node.var.name)
            end
        elseif texp._tag == "Type.Function" then
            -- Every Type.Function is a first-class Titan/Lua callable value.
            node._type = strip_linear_from_type(texp)
            -- Mark a referenced *local* function declaration so the coder
            -- builds its canonical closure (exported functions and statics
            -- always get one; a function-typed local is already a value).
            local decl = node.var._decl
            if decl and decl._tag == "Ast.TopLevelFunc" then
                decl._valref = true
            end
        elseif texp._tag == "Type.Record" or texp._tag == "Type.Union" then
            local kind = texp._tag == "Type.Record" and "record" or "union"
            node._type = invalid(errors, node.loc,
                "trying to access %s type '%s' as a first-class value",
                kind, texp.name)
        else
            node._type = texp
        end
        if node.var._c_fam_access then
            node._c_fam_access = node.var._c_fam_access
        end
    end,

    ["Ast.ExpUnop"] = function(node, st, errors, _)
        local op = node.op
        checkexp(node.exp, st, errors)
        if check_c_unary_operator(node, st, errors) then
            return
        end
        local texp = node.exp._type
        local loc = node.loc
        if texp._tag == "Type.Parameter" then
            checker.typeerror(errors, loc,
                "operator '%s' is not available for rigid type parameter '%s'",
                op, texp.diagnostic_name)
            node._type = (op == "not" or op == "#")
                and (op == "not" and types.Boolean() or types.Integer())
                or types.Invalid()
            return
        end
        if op == "#" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag == "Type.Map"
               and not types.equals(texp.keys, types.Integer()) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a map with key type %s instead of an integer-keyed map",
                    types.tostring(texp.keys))
            elseif texp._tag ~= "Type.Array"
               and texp._tag ~= "Type.Map"
               and texp._tag ~= "Type.String"
               and not node.exp._c_fam_access
               and not has_c_length(texp) then
                checker.typeerror(errors, loc,
                    "trying to take the length of a %s instead of an array, integer-keyed map, string, C array, or counted owned C array",
                    types.tostring(texp))
            end
            if node.exp._c_fam_access then
                node._c_fam_access = node.exp._c_fam_access
            end
            node._type = types.Integer()
        elseif op == "-" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            if texp._tag ~= "Type.Integer" and texp._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "trying to negate a %s instead of a number",
                    types.tostring(texp))
            end
            node._type = texp
        elseif op == "~" then
            node.exp = tryforce(node.exp)
            texp = node.exp._type
            -- always tries to coerce floats to integer
            node.exp = node.exp._type._tag == "Type.Float" and trycoerce(node.exp, types.Integer(), errors) or node.exp
            texp = node.exp._type
            if texp._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "trying to bitwise negate a %s instead of an integer",
                    types.tostring(texp))
            end
            node._type = types.Integer()
        elseif op == "not" then
            node.exp = truthiness(node.exp)
            node._type = types.Boolean()
        else
            error("invalid unary operation " .. op)
        end
    end,

    ["Ast.ExpConcat"] = function(node, st, errors, _)
        for i, exp in ipairs(node.exps) do
            checkexp(exp, st, errors, types.String())
            exp = tryforce(exp)
            -- always tries to coerce numbers to string
            exp = trytostr(exp)
            node.exps[i] = exp
            local texp = exp._type
            if texp._tag == "Type.Value" then
                checker.typeerror(errors, exp.loc,
                    "cannot concatenate with value of type 'value'")
            elseif texp._tag ~= "Type.String" then
                checker.typeerror(errors, exp.loc,
                    "cannot concatenate with %s value", types.tostring(texp))
            end
        end
        node._type = types.String()
    end,

    ["Ast.ExpBinop"] = function(node, st, errors, context)
        -- Only ordinary equality uses a ComparisonPlan. C operators and the
        -- other binary operators finish this analysis without such a plan.
        node._comparison = maybe3.none()
        local op = node.op
        checkexp(node.lhs, st, errors)
        local tlhs = node.lhs._type
        checkexp(node.rhs, st, errors)
        local trhs = node.rhs._type
        if check_c_binary_operator(node, st, errors) then
            return
        end
        local loc = node.loc
        if op ~= "==" and op ~= "~="
           and (tlhs._tag == "Type.Parameter"
                or trhs._tag == "Type.Parameter") then
            local parameter = tlhs._tag == "Type.Parameter" and tlhs or trhs
            checker.typeerror(errors, loc,
                "operator '%s' is not available for rigid type parameter '%s'",
                op, parameter.diagnostic_name)
            node._type = (op == "<" or op == ">"
                or op == "<=" or op == ">=")
                and types.Boolean() or types.Invalid()
            return
        end
        if op == "==" or op == "~=" then
            if tlhs._tag == "Type.Option"
               and trhs._tag == "Type.Nil" then
                node.rhs = trycoerce(node.rhs, tlhs, errors)
                trhs = node.rhs._type
            elseif trhs._tag == "Type.Option"
               and tlhs._tag == "Type.Nil" then
                node.lhs = trycoerce(node.lhs, trhs, errors)
                tlhs = node.lhs._type
            elseif tlhs._tag == "Type.Option"
               or trhs._tag == "Type.Option" then
                node.lhs = trycoerce(node.lhs, optionize(tlhs), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, optionize(trhs), errors)
                trhs = node.rhs._type
            end
            local comparison = types.comparable(tlhs, trhs)
            if not comparison then
                local lcarrier = generic_rigid_parameter_carrier(tlhs)
                local rcarrier = generic_rigid_parameter_carrier(trhs)
                if (lcarrier and not rcarrier and types.equals(lcarrier, trhs))
                   or (rcarrier and not lcarrier and types.equals(tlhs, rcarrier)) then
                    comparison = {
                        kind = "comparison",
                        op = "rigid_carrier",
                        left = tlhs,
                        right = trhs,
                    }
                end
            end
            node._comparison = maybe3.from_optional(comparison)
            if comparison then
                local function apply_comparison_adjustment(exp, adjustment)
                    if not adjustment then return exp end
                    local adjusted, consumed = trycoerce(
                        exp, adjustment.target, errors,
                        "equality operand", maybe3.from_optional(adjustment))
                    assert(consumed == adjustment,
                        "equality operand lost its ComparisonPlan adjustment")
                    return adjusted
                end
                node.lhs = apply_comparison_adjustment(
                    node.lhs, comparison.left_adjustment)
                node.rhs = apply_comparison_adjustment(
                    node.rhs, comparison.right_adjustment)
            else
                checker.typeerror(errors, loc,
                    "trying to compare values of incomparable types: %s and %s",
                    types.tostring(tlhs), types.tostring(trhs))
            end
            node._type = types.Boolean()
        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            node.lhs = tryforce(node.lhs); tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs); trhs = node.rhs._type
            local lnum = tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float"
            local rnum = trhs._tag == "Type.Integer" or trhs._tag == "Type.Float"
            local lstr, rstr = tlhs._tag == "Type.String", trhs._tag == "Type.String"
            if (lnum and rnum) or (lstr and rstr) then
                -- ok: numbers compare to numbers (int vs float exactly), strings to strings
            elseif rnum and not lnum then
                checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a number", types.tostring(tlhs))
            elseif lnum and not rnum then
                checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a number", types.tostring(trhs))
            elseif rstr and not lstr then
                checker.typeerror(errors, loc, "left hand side of relational expression is a %s instead of a string", types.tostring(tlhs))
            elseif lstr and not rstr then
                checker.typeerror(errors, loc, "right hand side of relational expression is a %s instead of a string", types.tostring(trhs))
            elseif types.equals(tlhs, trhs) then
                checker.typeerror(errors, loc, "trying to use relational expression with two %s values", types.tostring(tlhs))
            else
                checker.typeerror(errors, loc, "trying to use relational expression with %s and %s", types.tostring(tlhs), types.tostring(trhs))
            end
            node._type = types.Boolean()
        elseif op == "+" or op == "-" or op == "*" or op == "%" or op == "//" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            if not (tlhs._tag == "Type.Integer" or tlhs._tag == "Type.Float") then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if not (trhs._tag == "Type.Integer" or trhs._tag == "Type.Float") then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            -- tries to coerce to float if either side is float
            if tlhs._tag == "Type.Float" or trhs._tag == "Type.Float" then
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag == "Type.Float" and trhs._tag == "Type.Float" then
                node._type = types.Float()
            elseif tlhs._tag == "Type.Integer" and trhs._tag == "Type.Integer" then
                node._type = types.Integer()
            else
                -- error
                node._type = invalid(errors, loc, "invalid types in arithmetic expression")
            end
        elseif op == "/" or op == "^" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            if tlhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.lhs = trycoerce(node.lhs, types.Float(), errors)
                tlhs = node.lhs._type
            end
            if trhs._tag == "Type.Integer" then
                -- always tries to coerce to float
                node.rhs = trycoerce(node.rhs, types.Float(), errors)
                trhs = node.rhs._type
            end
            if tlhs._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if trhs._tag ~= "Type.Float" then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            node._type = types.Float()
        elseif op == "and" then
            if context and context._tag == "Type.Boolean" then
                -- convert everything to boolean if used in boolean context
                node.lhs = truthiness(node.lhs)
                tlhs = node.lhs._type
                node.rhs = truthiness(node.rhs)
                trhs = node.rhs._type
                node._type = context
            elseif types.is_truthy(tlhs) then
                node._type = trhs
            elseif types.is_falsy(tlhs) then
                node._type = tlhs
            else
                node.rhs = trycoerce(node.rhs, optionize(trhs), errors)
                trhs = node.rhs._type
                node._type = trhs
            end
        elseif op == "or" then
            if context and context._tag == "Type.Boolean" then
                -- convert everything to boolean if used in boolean context
                node.lhs = truthiness(node.lhs)
                tlhs = node.lhs._type
                node.rhs = truthiness(node.rhs)
                trhs = node.rhs._type
                node._type = context
            elseif tlhs._tag == "Type.Boolean" or trhs._tag == "Type.Boolean" then
                -- use truthiness if the other side selects a boolean result
                node.lhs = truthiness(node.lhs)
                tlhs = node.lhs._type
                node.rhs = truthiness(node.rhs)
                trhs = node.rhs._type
                node._type = types.Boolean()
            elseif types.is_truthy(tlhs) then
                node._type = tlhs
            elseif types.is_falsy(tlhs) then
                node._type = trhs
            elseif tlhs._tag == "Type.Option" and types.equals(tlhs.base, trhs) then
                node._type = trhs
            elseif tlhs._tag == "Type.Option" and trhs._tag == "Type.Value" then
                node.lhs = trycoerce(node.lhs, types.Value(), errors)
                tlhs = node.lhs._type
                node._type = types.Value()
            elseif tlhs._tag == "Type.Value" then
                node.rhs = trycoerce(node.rhs, types.Value(), errors)
                trhs = node.rhs._type
                node._type = types.Value()
            else
                checker.typeerror(errors, loc,
                    "left hand side of 'or' is a %s but right hand side is a %s",
                    types.tostring(tlhs), types.tostring(trhs))
                node._type = types.Invalid()
            end
        elseif op == "|" or op == "&" or op == "~" or op == "<<" or op == ">>" then
            node.lhs = tryforce(node.lhs)
            tlhs = node.lhs._type
            node.rhs = tryforce(node.rhs)
            trhs = node.rhs._type
            -- always tries to coerce floats to integer
            node.lhs = node.lhs._type._tag == "Type.Float" and trycoerce(node.lhs, types.Integer(), errors) or node.lhs
            tlhs = node.lhs._type
            -- always tries to coerce floats to integer
            node.rhs = node.rhs._type._tag == "Type.Float" and trycoerce(node.rhs, types.Integer(), errors) or node.rhs
            trhs = node.rhs._type
            if tlhs._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(tlhs))
            end
            if trhs._tag ~= "Type.Integer" then
                checker.typeerror(errors, loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(trhs))
            end
            node._type = types.Integer()
        else
            error("invalid binary operation " .. op)
        end
    end,

    ["Ast.ExpCall"] = function(node, st, errors, context, demand)
        return generic_with_inference_operation(node, st,
        function(inference_operation)
        demand = demand or default_call_result_demand(node, context)
        if checker._native_record_field_call(node, st, errors, demand) then return end
        local written_exp = node.exp
        if node.exp._tag == "Ast.ExpVar" then
            local var = node.exp.var
            if node.exp._generic_var_prechecked then
                node.exp._generic_var_prechecked = nil
            else
                generic_checkvar_for_expression(
                    node.exp, st, errors, c_pseudo_callee_context)
            end
            if var._decl then var._decl._used = true end
            node.exp._type = var._type
        elseif node._generic_callee_prechecked then
            node._generic_callee_prechecked = nil
        else
            checkexp(node.exp, st, errors)
        end

        local argtag = node.args._tag
        local named = argtag == "Ast.ArgsNamedFunc"
            or argtag == "Ast.ArgsNamedMethod"
        local method = argtag == "Ast.ArgsMethod"
            or argtag == "Ast.ArgsNamedMethod"
        assert(argtag == "Ast.ArgsFunc" or argtag == "Ast.ArgsMethod"
            or argtag == "Ast.ArgsNamedFunc"
            or argtag == "Ast.ArgsNamedMethod")

        if not method then
            if node.exp._type._tag == "Type.Record" then
                -- Calling the namespace is exactly selecting its ordinary
                -- static `new`: visibility, named arguments and generic
                -- inference remain owned by the existing selector/call path.
                local namespace = node.exp
                if #(node.typeargs or {}) > 0 then
                    namespace._nominal_typeargs = node.typeargs
                    namespace._nominal_typeargs_loc = namespace.loc
                    node.typeargs = {}
                end
                namespace._generic_var_prechecked = true
                node.exp = ast.ExpVar(namespace.loc,
                    ast.VarDot(namespace.loc, namespace, "new"))
                generic_checkvar_for_expression(node.exp, st, errors)
                node.exp._type = node.exp.var._type
                if node.exp.var._decl then node.exp.var._decl._used = true end
                written_exp = node.exp
            end
            node._nominal_constructor = checker._direct_nominal_constructor(node)
            local ftype = generic_instantiate_direct_call(
                node, node.exp._type, st, errors, demand)
            local fname = expname(node.exp)
            local pseudo_new = node.exp._tag == "Ast.ExpVar"
                and node.exp.var._decl
                and node.exp.var._decl._tag == "Checker.CPseudoNew"
                and node.exp.var._decl or nil
            if pseudo_new then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local allocation_decl = demand and demand.allocation_decl
                local allocation_target = allocation_decl
                    and allocation_decl._type or nil
                local resolved_payload = c_resolve(pseudo_new.ctype)
                local literal_count = pseudo_new.array
                    and checker._allocation_integer_literal(
                        node.args.args[1], st) or nil
                local allow_automatic_array = pseudo_new.array
                    and resolved_payload
                    and resolved_payload._tag == "Type.CArray"
                    and allocation_decl ~= nil
                    and literal_count and literal_count > 0
                    and (allocation_target == nil
                         or allocation_target._tag == "Type.CArray"
                         or checker._pointer_to_allocation_payload(
                             allocation_target, pseudo_new.ctype))
                local nominal = demand and demand.nominal_constructor
                local nominal_slot = nominal
                    and nominal.slots[demand.nominal_slot_index]
                if nominal_slot and types.is_c_array(nominal_slot.type)
                   and types.equals(nominal_slot.type, pseudo_new.ctype)
                   and not pseudo_new.array then
                    allow_automatic_array = true
                end
                local alloc_err = c_allocation_error(
                    pseudo_new.ctype, st, allow_automatic_array)
                if alloc_err then
                    node._type = invalid(errors, node.loc, alloc_err)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                annotate_call_arguments(node,
                    checkargs(pseudo_new, node.args.args, node.loc,
                        "function '" .. fname .. "'", st, errors, false))
                checker._plan_c_allocation(
                    node, pseudo_new, demand, st, errors)
                annotate_call_results(node, pseudo_new, demand, errors)
                return
            end
            if ftype._tag == "Type.Invalid" then
                node._type = ftype
                check_call_argument_expressions(node.args, st, errors)
                return
            end

            local direct_foreign_reference = node.exp._tag == "Ast.ExpVar"
                and checker._foreign_function_reference(node.exp.var) or nil
            local direct_cfunc = direct_foreign_reference
                and c_resolve(ftype) or nil
            if direct_cfunc
               and direct_cfunc._tag == "Type.CFunction" then
                node._direct_foreign_reference = direct_foreign_reference
                if not checker._ensure_c_enum_supported(
                        st, direct_cfunc, node.loc, errors) then
                    node._type = types.Invalid()
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end

                if named then
                    local paramnames, lowering, recognized_ffi =
                        named_function_metadata(node)
                    if recognized_ffi and paramnames == nil then
                        node._type = invalid(errors, node.loc,
                            "parameter names are unavailable for foreign function '%s' "
                            .. "because its prototypes do not provide one complete unambiguous list",
                            fname)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    elseif not recognized_ffi or lowering ~= "foreign"
                           or type(paramnames) ~= "table" then
                        node._type = types.Invalid()
                        named_target_error(errors, node.loc)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    elseif direct_cfunc.vararg then
                        node._type = invalid(errors, node.loc,
                            "named arguments are not supported for variadic function '%s'",
                            fname)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    end
                    local dense, order = check_named_args(
                        direct_cfunc, paramnames, node.args.fields, node.loc,
                        "function '" .. fname .. "'", st, errors,
                        named_call_declaration(node))
                    if dense then
                        local previous_args = node.args
                        node._surface_named_args = previous_args.fields
                        node.args = ast.ArgsFunc(previous_args.loc, dense)
                        node._named_arg_order = order
                        node._named_call_kind = "foreign"
                    end
                else
                    annotate_call_arguments(node,
                        checkargs(direct_cfunc, node.args.args, node.loc,
                            "function '" .. fname .. "'", st, errors,
                            false))
                end
                annotate_c_call_mutations(node, direct_cfunc)
                annotate_call_results(node, direct_cfunc, demand, errors)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
                return
            end

            local cfunc = c_function_pointer_type(ftype)
            if cfunc then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                if not checker._ensure_c_enum_supported(
                        st, cfunc, node.loc, errors) then
                    node._type = types.Invalid()
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                node._c_pointer_call = cfunc
                annotate_call_arguments(node,
                    checkargs(cfunc, node.args.args, node.loc,
                        "function pointer '" .. fname .. "'", st, errors,
                        false))
                annotate_c_call_mutations(node, cfunc)
                annotate_call_results(node, cfunc, demand, errors)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
                return
            end
            local contextual_args
            local dependent_call = false
            if ftype._tag == "Type.Value" then
                if named then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end

                local synthesized
                synthesized, contextual_args = synthesize_value_call_type(
                    node, demand, st, errors)
                local original = node.exp
                node._contextual_value_call = true
                node._contextual_function_type = synthesized
                synthesized, dependent_call =
                    generic_infer_dependent_value_call_application(
                        inference_operation, synthesized, node,
                        contextual_args, st, errors,
                        "function '" .. fname .. "'", function(closed)
                            generic_finalize_contextual_value_callee(
                                node, original, closed, errors)
                        end)
                if not dependent_call then
                    generic_close_generic_adjusted_arguments(
                        inference_operation
                            and inference_operation.context or nil,
                        node, contextual_args, node.args.args,
                        synthesized, st, errors,
                        "function '" .. fname .. "'")
                    generic_finalize_contextual_value_callee(
                        node, original, synthesized, errors)
                end
                ftype = synthesized
            end
            -- Auto-unwrap an option-of-function callee (e.g. an array element
            -- `arr[i]`, which has type `T?`): cast to the underlying function
            -- type. Named syntax remains unavailable because the callee is a
            -- structural value, not a direct declaration.
            if ftype._tag == "Type.Option" and ftype.base._tag == "Type.Function" then
                node.exp = tryforce(node.exp)
                ftype = ftype.base
                generic_defer_inference_force(
                    inference_operation, node, written_exp, "Type.Function")
            end
            if ftype._tag ~= "Type.Function" then
                node._type = invalid(errors, node.loc,
                    "'%s' is not a function but %s",
                    fname, types.tostring(ftype))
                check_call_argument_expressions(node.args, st, errors)
                return
            end

            -- Named function syntax requires a direct declaration, so a
            -- computed generic result cannot be its callee. Positional calls
            -- through such a result contribute ordinary argument/result
            -- evidence to the ambient inference context instead.
            if not named and not contextual_args then
                ftype, dependent_call =
                    generic_infer_dependent_call_application(
                        inference_operation, ftype, node, demand, st, errors,
                        "function '" .. fname .. "'")
            end

            if named then
                local paramnames, lowering, recognized_ffi =
                    named_function_metadata(node)
                if recognized_ffi and paramnames == nil then
                    node._type = invalid(errors, node.loc,
                        "parameter names are unavailable for foreign function '%s' "
                        .. "because its prototypes do not provide one complete unambiguous list",
                        fname)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif not lowering or type(paramnames) ~= "table" then
                    node._type = types.Invalid()
                    named_target_error(errors, node.loc)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif ftype.varargtype then
                    node._type = invalid(errors, node.loc,
                        "named arguments are not supported for variadic function '%s'",
                        fname)
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local dense, order
                if node._generic_named_dense then
                    dense, order = node._generic_named_dense,
                        node._generic_named_order
                elseif not node._generic_named_pending then
                    dense, order = check_named_args(ftype, paramnames,
                        node.args.fields, node.loc,
                        "function '" .. fname .. "'", st, errors,
                        named_call_declaration(node), node._nominal_constructor)
                end
                if dense then
                    local previous_args = node.args
                    node._surface_named_args = previous_args.fields
                    node.args = ast.ArgsFunc(previous_args.loc, dense)
                    node._named_arg_order = order
                    node._named_call_kind = lowering
                end
            else
                if contextual_args then
                    annotate_call_arguments(node, contextual_args)
                elseif node._generic_arg_adjustment then
                    annotate_call_arguments(node,
                        node._generic_arg_adjustment)
                else
                    annotate_call_arguments(node,
                        checkargs(ftype, node.args.args, node.loc,
                            "function '" .. fname .. "'", st, errors,
                            nil, node._nominal_constructor))
                end
            end
            annotate_call_results(node, ftype, demand, errors)
            generic_defer_inherited_call_result_finalization(
                node, demand, dependent_call and inference_operation or nil)
            check_generic_result_limit(node, errors)
            if node._type._tag == "Type.Void" and not node._voidok
               and not demand.tail then
                node._type = invalid(errors, node.loc,
                    "a function returning no values cannot be used as a value")
            end
        else
            local otype = node.exp._type
            completion_members(node.args, node.exp, otype, st, errors, "colon")
            if otype._tag == "Type.Invalid" then
                node._type = otype
                check_call_argument_expressions(node.args, st, errors)
                return
            end
            -- Auto-unwrap an option receiver before resolving the method. The
            -- receiver is still generated once, before any named expressions.
            if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
                node.exp = tryforce(node.exp)
                otype = otype.base
                generic_defer_inference_force(
                    inference_operation, node, written_exp, "Type.Nominal")
            end
            if otype._tag == "Type.Parameter"
               and otype.erased_constraint ~= nil then
                node._rigid_receiver_type = otype
                otype = otype.erased_constraint
            end
            if otype._tag == "Type.Nominal" and
               types.registry[otype.fqtn] and
               (types.registry[otype.fqtn]._tag == "Type.Record"
                or types.registry[otype.fqtn]._tag == "Type.Union"
                or types.registry[otype.fqtn]._tag == "Type.Interface") then
                local class = generic_applied_owner_view(
                    otype, errors, node.loc)
                local owner_kind = class._tag == "Type.Record"
                    and "record"
                    or (class._tag == "Type.Union"
                        and "union" or "interface")
                local method_name_text = node.args.method
                if not is_nominal_visible_from(st, otype.fqtn) then
                    node._type = invalid(errors, node.loc,
                        "%s type '%s' is local to module '%s'",
                        owner_kind, otype.fqtn, nominal_module(otype.fqtn))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                elseif not class.methods[method_name_text] then
                    node._type = invalid(errors, node.loc,
                        "method '%s' not found in %s '%s'",
                        method_name_text, owner_kind, types.tostring(otype))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                local ftype = class.methods[method_name_text]
                node.args._decl = ftype
                if not is_nominal_member_visible_from(st, ftype) then
                    node._type = invalid(errors, node.loc,
                        "method '%s:%s' is local to module '%s'",
                        class.name, method_name_text, nominal_module(class.name))
                    check_call_argument_expressions(node.args, st, errors)
                    return
                end
                ftype = generic_instantiate_method_declaration(
                    node, ftype, st, errors, class.name, demand)
                local dependent_call = false
                if not named or (not ftype.varargtype
                        and type(ftype.paramnames) == "table") then
                    ftype, dependent_call =
                        generic_infer_dependent_call_application(
                            inference_operation, ftype, node, demand,
                            st, errors,
                            "method '" .. class.name .. ":"
                                .. method_name_text .. "'",
                            ftype.paramnames,
                            function(closed)
                                node._method = closed
                            end)
                end
                if named then
                    if ftype.varargtype then
                        node._type = invalid(errors, node.loc,
                            "named arguments are not supported for variadic method '%s:%s'",
                            class.name, method_name_text)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    elseif type(ftype.paramnames) ~= "table" then
                        node._type = types.Invalid()
                        named_target_error(errors, node.loc)
                        check_call_argument_expressions(node.args, st, errors)
                        return
                    end
                    local desc = "method '" .. class.name .. ":" .. method_name_text .. "'"
                    local dense, order
                    if node._generic_named_dense then
                        dense, order = node._generic_named_dense,
                            node._generic_named_order
                    elseif not node._generic_named_pending then
                        dense, order = check_named_args(
                            ftype, ftype.paramnames, node.args.fields,
                            node.loc, desc, st, errors,
                            named_call_declaration(node))
                    end
                    if dense then
                        local previous_args = node.args
                        node._surface_named_args = previous_args.fields
                        node.args = ast.ArgsMethod(
                            previous_args.loc, method_name_text, dense)
                        node.args._name_loc = previous_args._name_loc
                        node.args._decl = ftype
                        node._named_arg_order = order
                        node._named_call_kind = "titan"
                    end
                else
                    if node._generic_arg_adjustment then
                        annotate_call_arguments(node,
                            node._generic_arg_adjustment)
                    else
                        annotate_call_arguments(node,
                            checkargs(ftype, node.args.args, node.loc,
                                "method '" .. class.name .. ":" .. method_name_text .. "'",
                                st, errors))
                    end
                end
                node._method = ftype
                if class._tag == "Type.Interface" then
                    node._interface = class
                    node._interface_method = ftype
                    node._interface_method_index =
                        assert(interface_method_index(
                            class, method_name_text))
                end
                generic_defer_inherited_interface_finalization(
                    node, class, method_name_text,
                    dependent_call and inference_operation or nil)
                annotate_call_results(node, ftype, demand, errors)
                generic_defer_inherited_call_result_finalization(
                    node, demand,
                    dependent_call and inference_operation or nil)
                if node._type._tag == "Type.Void" and not node._voidok
                   and not demand.tail then
                    node._type = invalid(errors, node.loc,
                        "a function returning no values cannot be used as a value")
                end
            else
                if otype._tag ~= "Type.Nominal" then
                    checker.typeerror(errors, node.loc,
                        "expected record in receiver of method call but found '%s'",
                        types.tostring(otype))
                elseif not types.registry[otype.fqtn] then
                    checker.typeerror(errors, node.loc,
                        "record type '%s' in receiver of method call does not exist",
                        types.tostring(otype))
                elseif types.registry[otype.fqtn]._tag ~= "Type.Record" then
                    checker.typeerror(errors, node.loc,
                        "expected record in receiver of method call but found '%s'",
                        types.tostring(types.registry[otype.fqtn]))
                end
                check_call_argument_expressions(node.args, st, errors)
                node._type = invalid(errors, node.loc, "expected a record type")
            end
        end
        end)
    end,

    ["Ast.ExpCast"] = function(node, st, errors, _)
        node._type = check_explicit_cast_relation(node, st, errors)
    end,

    ["Ast.ExpIs"] = function(node, st, errors, _)
        check_explicit_cast_relation(node, st, errors)
        node._type = types.Boolean()
    end,

    ["Ast.ExpAdjust"] = function(node, st, errors, context, demand)
        node.exp = normalize_spread_expression(node.exp)
        -- Parenthesized varargs/spreads select exactly one optional value,
        -- padding an empty run with nil just like a parenthesized call.
        if node.exp._tag == "Ast.ExpDots" then
            local index = ast.ExpInteger(node.exp.loc, 1)
            local projection = ast.ExpDotsIndex(node.exp.loc, index)
            projection._nilfill = true
            checkexp(projection, st, errors)
            node.exp = projection
            node._type = projection._type
            return
        end
        if node.exp._tag == "Ast.ExpSpread" then
            local spread = node.exp
            check_spread_marker(spread, st, errors)
            local projection = ast.ExpSpreadIndex(
                node.loc, spread, 1, spread._spread_optional_type)
            projection._nilfill = true
            node.exp = projection
            node._adjusted_spread = spread
            node._type = projection._type
            return
        end

        return generic_with_inference_operation(node, st,
        function(operation)
            node.exp._voidok = true
            -- Parentheses force exactly one result even though `_voidok`
            -- permits a genuinely zero-return call (which is adjusted upward
            -- to nil below). Pass the demand explicitly so `_voidok` is not
            -- mistaken for a statement/discard context. Preserve a generic
            -- discovery pattern for a directly enclosed contextual `value`
            -- call without making it an ordinary expected type elsewhere.
            local provisional = demand and demand.inference_fixed
                and demand.inference_fixed[1] or nil
            if not provisional and demand
               and #(demand.fixed or {}) == 0 and demand.tail then
                -- ExpAdjust turns its child's first result into one scalar.  If
                -- that scalar occupies an open consumer (for example the sole
                -- field of a dependent positional constructor), its inference
                -- pattern lives on the tail side channel rather than slot 1.
                provisional = demand.inference_tail or nil
            end
            checkexp(node.exp, st, errors, context,
                result_demand({ context or UNKNOWN_SLOT }, false, {
                    term = "parenthesized expression",
                    loc = node.loc,
                    inference_fixed = { provisional },
                }))

            local function finish()
                if node.exp._type._tag == "Type.Void" then
                    -- `(f())` on a zero-return call adjusts up to a single
                    -- `nil`, mirroring Lua's parenthesized-call adjustment.
                    node._type = types.Nil()
                    node._adjustvoid = true
                else
                    node._type = node.exp._type
                    node._adjustvoid = nil
                end
            end
            finish()
            generic_defer_inference_derived_annotations(
                operation, node, {
                    _assignment_adjustment = function(value)
                        return generic_finalize_adjustment_annotation(
                            operation, value)
                    end,
                }, finish)
        end, "parenthesized expression")
    end,

    -- Anonymous function expression (lambda). Both parameter and return types
    -- may be inferred from the expected function type (`context`): an unannotated
    -- parameter takes its type from the context, and a missing return annotation
    -- is likewise taken from the context. With no usable context the return type
    -- defaults to zero-return `()`, exactly like an unannotated top-level
    -- function.
    ["Ast.ExpFunction"] = function(node, st, errors, context)
        -- A trailing vararg `Decl` (`name == nil`) is dropped from the fixed
        -- params; its element type is resolved separately below. A lambda vararg
        -- may be untyped (`type == nil`), in which case the element type is
        -- inferred from context, exactly like an untyped lambda parameter.
        -- `nfixed` is the count compared against a context's arity.
        local nparams = #node.params
        local varargtype = nil
        local varargdecl = node.params[nparams]
        local has_vararg = varargdecl and varargdecl.name == nil
        local nfixed = has_vararg and nparams - 1 or nparams

        -- Checking mode iff the context is a function type whose fixed arity
        -- matches; element-type matching is not enforced for inference here.
        local expected = (context and context._tag == "Type.Function"
            and #context.params == nfixed) and context or nil

        -- Resolve the vararg element type (explicit annotation wins; otherwise
        -- infer from the expected function type's `varargtype`). An untyped `...`
        -- with a non-variadic context, or with no usable context at all, is an
        -- error — mirroring an uninferable untyped lambda parameter.
        if has_vararg then
            if varargdecl.type then
                varargdecl._type = varargdecl._generic_inference_type
                    or typefromnode(varargdecl.type, st, errors)
            elseif expected and expected.varargtype then
                varargdecl._type = expected.varargtype
            elseif expected then
                varargdecl._type = invalid(errors, varargdecl.loc,
                    "cannot infer the type of '...'; the lambda is variadic but "
                    .. "the expected type is not")
            else
                varargdecl._type = invalid(errors, varargdecl.loc,
                    "cannot infer the type of '...'; annotate it or use the "
                    .. "lambda where its type is known")
            end
            varargtype = check_varg_elem(
                varargdecl._type, varargdecl.loc, errors, "parameter")
        end

        -- Resolve fixed parameter types.
        local paramtypes = {}
        for i = 1, nfixed do
            local param = node.params[i]
            if param.type then
                param._type = param._generic_inference_type
                    or typefromnode(param.type, st, errors)
            elseif expected then
                param._type = expected.params[i]
            else
                param._type = invalid(errors, param.loc,
                    "cannot infer type of parameter '%s'; annotate it or use "
                    .. "the lambda where its type is known", param.name)
            end
            paramtypes[i] = param._type
        end

        -- Resolve / set up return types. Like parameters, the return type comes
        -- only from the expected function type (`context`); it is never inferred
        -- from the body's `return`s.
        local rettypes
        local flexrettype
        if type(node.rettypes) == "table" then
            -- Explicit annotation, including `: ()` (an empty list).
            if node._generic_inference_rettypes ~= nil then
                rettypes = node._generic_inference_rettypes
                flexrettype = node._generic_inference_flexrettype
            else
                rettypes = {}
                for _, rt in ipairs(node.rettypes) do
                    table.insert(rettypes, typefromnode(rt, st, errors))
                end
                flexrettype = flexible_return_type(node, st, errors)
            end
        elseif expected then
            -- Checking mode: take both fixed and flexible results from the
            -- context. This is deliberately distinct from an explicit `: ()`,
            -- whose parser shape is an empty fixed list plus `flexrettype =
            -- nil` and must not inherit the context's tail.
            rettypes = expected.rettypes
            flexrettype = expected.flexrettype
        else
            -- No annotation, no usable context: default to zero-return `()`,
            -- exactly like an unannotated top-level function.
            rettypes = {}
            flexrettype = nil
        end

        node._type = types.Function(paramtypes, rettypes, false, varargtype,
            flexrettype)

        -- Open the lambda's own block so `$function`/params do not leak into the
        -- enclosing scope (mirrors checkbodies+checkfunc). `with_block` keeps
        -- only the first return value, so open/close the block by hand to also
        -- recover the frame.
        st:open_block(node)
        local _, frame = checkfuncbody(node, st, errors)
        st:close_block()

        -- Save the ordered list of enclosing decls this lambda captures, for
        -- codegen (closure-creation pushes + lambda-body upvalue indexing).
        node._captures = frame.captures
        annotate_closure_transfer_captures(node)
        -- Lua closures allow at most 255 upvalues. Titan reserves the first
        -- four for module/tag/native/brand and the final one for the strict
        -- stack entry, leaving 250 source-level captures.
        if #node._captures > 250 then
            checker.typeerror(errors, node.loc,
                "function captures too many variables (%d, max 250)",
                #node._captures)
        end

        return node._type
    end,

    -- Bound method reference `obj:m` (no call): yields a function value, the
    -- method's type with the implicit `self` removed and the receiver captured.
    -- Mirrors the method-resolution of the ArgsMethod arm of ExpCall.
    ["Ast.ExpMethodRef"] = function(node, st, errors, context)
        return generic_with_inference_operation(node, st,
        function(operation)
        local written_exp = node.exp
        checkexp(node.exp, st, errors)
        if #(node._nominal_typeargs or {}) > 0 then
            node._type = invalid(errors, node.loc,
                "explicit method type arguments are only supported in a direct call")
            return node._type
        end
        local otype = node.exp._type
        completion_members(node, node.exp, otype, st, errors, "colon")
        -- auto-unwrap an option receiver, like a method call does, so `p:m` on a
        -- Point? unwraps to the underlying record (the cast codegen nil-checks).
        if otype._tag == "Type.Option" and otype.base._tag == "Type.Nominal" then
            node.exp = tryforce(node.exp)
            otype = otype.base
        end
        if otype._tag == "Type.Parameter"
           and otype.erased_constraint ~= nil then
            node._rigid_receiver_type = otype
            otype = otype.erased_constraint
        end
        if otype._tag == "Type.CModule" then
            node._type = invalid(errors, node.loc,
                "a foreign (C) method cannot be used as a first-class value")
        elseif otype._tag == "Type.Nominal" and
           types.registry[otype.fqtn] and
           (types.registry[otype.fqtn]._tag == "Type.Record"
            or types.registry[otype.fqtn]._tag == "Type.Union"
            or types.registry[otype.fqtn]._tag == "Type.Interface") then
            local class = generic_applied_owner_view(
                otype, errors, node.loc)
            local owner_kind = class._tag == "Type.Record"
                and "record"
                or (class._tag == "Type.Union"
                    and "union" or "interface")
            local mtype = class.methods[node.name]
            if not is_nominal_visible_from(st, otype.fqtn) then
                node._type = invalid(errors, node.loc,
                    "%s type '%s' is local to module '%s'",
                    owner_kind, otype.fqtn, nominal_module(otype.fqtn))
            elseif not mtype then
                node._type = invalid(errors, node.loc,
                    "method '%s' not found in %s '%s'",
                    node.name, owner_kind, types.tostring(otype))
            elseif not is_nominal_member_visible_from(st, mtype) then
                node._type = invalid(errors, node.loc,
                    "method '%s:%s' is local to module '%s'",
                    class.name, node.name, nominal_module(class.name))
            else
                node._decl = mtype
                if mtype.scope ~= nil then
                    local expected = context
                    if expected and expected._tag == "Type.Option"
                       and expected.base._tag == "Type.Function" then
                        expected = expected.base
                    end
                    if expected and expected._tag ~= "Type.Function" then
                        expected = nil
                    end
                    local subject = "generic bound method '" .. class.name
                        .. ":" .. node.name .. "'"
                    node._generic_declaration = mtype
                    local closed = generic_infer_first_class_application(
                        node, subject, { generic_inference_scope_entry(
                            mtype.scope, mtype.typeparams) },
                        types.method_function_type(mtype), expected,
                        st, errors, node.loc,
                        function(final_type, arguments, inference, use)
                            local closed_method =
                                generic_close_inference_declaration(
                                    inference, use, mtype, true)
                            node._generic_type_arguments = arguments
                            node._method = closed_method
                            node._type = final_type
                            if class._tag == "Type.Interface" then
                                node._interface = class
                                node._interface_method = closed_method
                                node._interface_method_index =
                                    assert(interface_method_index(class, node.name))
                                node._interface_bound = true
                            end
                        end)
                    node._type = closed
                else
                    node._method = mtype
                    node._type = types.method_function_type(mtype)
                    if class._tag == "Type.Interface" then
                        node._interface = class
                        node._interface_method = mtype
                        node._interface_method_index =
                            assert(interface_method_index(class, node.name))
                        node._interface_bound = true
                    end
                end
            end
        elseif otype._tag ~= "Type.Nominal" then
            node._type = invalid(errors, node.loc,
                "expected record in receiver of method reference but found '%s'",
                types.tostring(otype))
        elseif not types.registry[otype.fqtn] then
            node._type = invalid(errors, node.loc,
                "record type '%s' in receiver of method reference does not exist",
                types.tostring(otype))
        else
            node._type = invalid(errors, node.loc,
                "expected record in receiver of method reference but found '%s'",
                types.tostring(types.registry[otype.fqtn]))
        end
        generic_defer_inference_derived_annotations(
            operation, node, {
                _type = true,
                _method = true,
                _interface = true,
                _interface_method = true,
                _rigid_receiver_type = true,
                _assignment_adjustment = function(value)
                    return generic_finalize_adjustment_annotation(
                        operation, value)
                end,
            }, function()
                node.exp = written_exp
                if node.exp._type._tag == "Type.Option"
                   and node.exp._type.base._tag == "Type.Nominal" then
                    node.exp = tryforce(node.exp)
                end
            end)
        return node._type
        end, "bound method projection")
    end,

    -- A comma-bearing bracket suffix is deliberately a general parser node so
    -- future suffix syntax stays unambiguous. Only a tail spread may consume
    -- it; every ordinary scalar/indexing use is rejected here after checking
    -- its children for their own diagnostics.
    ["Ast.ExpSubset"] = function(node, st, errors, _)
        if node.exp._tag == "Ast.ExpDots" then
            -- `...[first, last]` is an explicit syntactic form even outside a
            -- list tail. Resolve its vararg scope without routing the wrapped
            -- marker through the defensive bare-`...` scalar diagnostic.
            check_dots_marker(node.exp, st, errors)
        else
            checkexp(node.exp, st, errors)
        end
        local function check_bound(bound, name)
            if not bound then return end
            checkexp(bound, st, errors)
            if bound._type._tag ~= "Type.Invalid" then
                coerce_and_check(bound, types.Integer(),
                    "subset " .. name .. " bound", errors, bound.loc)
            end
        end
        check_bound(node.first, "lower")
        check_bound(node.last, "upper")
        node._type = invalid(errors, node.loc,
            "a subset index can only be used in a spread expression")
    end,

    -- A valid ExpSpread is intercepted by expression-list adjustment before
    -- ordinary scalar checking. Reaching this arm means a hand-built/recovered
    -- AST placed it in a scalar position.
    ["Ast.ExpSpread"] = function(node, st, errors, _)
        check_spread_marker(node, st, errors)
        if node._spread_elem._tag ~= "Type.Invalid" then
            checker.typeerror(errors, node.loc,
                "a spread can only be used as the last item of an argument list, "
                .. "a return, an assignment, a generic for iterator tuple, "
                .. "or a positional array/integer-keyed map constructor")
        end
    end,

    -- Checker-synthesized finite projections are always optional. Their
    -- shared carrier was checked before they were inserted into adjusted.exps.
    ["Ast.ExpSpreadIndex"] = function(node, _, _, _)
        node._nilfill = true
        node._type = node._type
            or node.spread._spread_optional_type
            or optionize(node.spread._spread_elem)
    end,

    -- The grammar accepts bare varargs in ordinary expression positions. Valid
    -- tail/scalar-adjustment consumers intercept them; all other uses fail here.
    ["Ast.ExpDots"] = function(node, st, errors, _)
        node._vararg_elem = resolve_vararg(st, node.loc, errors)
        node._type = node._vararg_elem
        if node._vararg_elem._tag ~= "Type.Invalid" then
            checker.typeerror(errors, node.loc,
                "'...' can only be used as the last item of an argument list, "
                .. "a return, an assignment, a generic for iterator tuple, "
                .. "or a positional array/integer-keyed map constructor")
        end
    end,

    ["Ast.ExpDotsLen"] = function(node, st, errors, _)
        resolve_vararg(st, node.loc, errors)
        node._type = types.Integer()
    end,

    -- `...[e]` (1-based). Type is the element type `t` (NOT `t?`): codegen
    -- bounds-checks and raises on out-of-range, so an in-range access is always a
    -- valid `t`. `_nilfill` defaults to false (raise); adjust-up synthesis (§4.6)
    -- sets `_nilfill = true` / `_type = s?` for an optional target slot.
    ["Ast.ExpDotsIndex"] = function(node, st, errors, _)
        local elem = resolve_vararg(st, node.loc, errors)
        checkexp(node.exp, st, errors, types.Integer())
        node.exp = coerce_and_check(node.exp, types.Integer(),
            "variadic index", errors, node.exp.loc)
        if node._nilfill == nil then node._nilfill = false end
        node._type = node._type
            or (node._nilfill and elem._tag ~= "Type.Invalid"
                and optionize(elem) or elem)
    end
})

return core.checker

local core = require "titan-compiler.checker.core"
local _ENV = core

-- Only a resolved nominal namespace selector identifies the synthesized
-- constructor. A first-class callable alias has an ordinary declaration and
-- must retain its independent allocation/borrowing behavior.
function checker._direct_nominal_constructor(node)
    local variable = node.exp and node.exp._tag == "Ast.ExpVar"
        and node.exp.var
    local declaration = variable and variable._decl
    if not declaration or declaration._tag ~= "Type.StaticMethod" then return nil end
    local owner = types.registry[declaration.fqtn]
    local variant, slots
    if owner and owner._tag == "Type.Record" and not owner.custom_constructor
       and declaration.name == "new" then
        slots = owner.fields
    elseif owner and owner._tag == "Type.Union" then
        variant = owner.variants[declaration.name]
        slots = variant and variant.parts
    end
    if not slots then return nil end
    local indices = {}
    for index, slot in ipairs(slots) do indices[index] = slot.index end
    return {
        kind = variant and "union" or "record",
        owner = owner,
        variant = variant or nil,
        slots = slots,
        field_indices = indices,
        allocation_plans = {},
    }
end

function checker._nominal_argument_demand(demand, constructor, index)
    if constructor and constructor.slots[index] then
        demand.nominal_constructor = constructor
        demand.nominal_slot_index = index
    end
    return demand
end

-- Check a named list in lexical order, then produce the positional dense list
-- consumed by the existing native/direct-C lowering. The separate order map is
-- retained so codegen can evaluate explicit expressions in source order before
-- assembling operands in formal order.
function named_call_declaration(node)
    if node.args and node.args._decl then return node.args._decl end
    local variable = node.exp and node.exp._tag == "Ast.ExpVar"
        and node.exp.var or nil
    return variable and variable._decl or nil
end

function check_named_args(
        callable, paramnames, fields, loc, fname, st, errors, declaration,
        nominal_constructor)
    local signature = assert(call_signature(callable),
        "named-call checking requires a callable signature")
    assert(type(paramnames) == "table")
    assert(#paramnames == #signature.params,
        "declaration parameter-name metadata does not match its fixed arity")

    local byname = {}
    for i, name in ipairs(paramnames) do
        assert(type(name) == "string")
        if byname[name] then
            -- Duplicate parameter declarations are diagnosed while checking
            -- the callee body, but all signatures are published first. A later
            -- body may therefore try a named call before the invalid program is
            -- rejected. Keep that recovery path diagnostic-only: the spelling
            -- cannot identify one unambiguous formal position.
            checker.typeerror(errors, loc,
                "%s has duplicate parameter name '%s'; named arguments are unavailable",
                fname, name)
            for _, field in ipairs(fields) do
                checkexp(field.exp, st, errors)
            end
            return nil
        end
        byname[name] = i
    end

    local dense = {}
    local supplied = {}
    local order = {}
    for _, field in ipairs(fields) do
        local index = byname[field.name]
        if not index then
            checker.typeerror(errors, field.loc,
                "%s has no parameter named '%s'%s",
                fname, field.name,
                #paramnames > 0 and
                    ("; available parameters are " .. table.concat(paramnames, ", "))
                    or "")
            checkexp(field.exp, st, errors)
        else
            local ptype = signature.params[index]
            field._decl = named_parameter_declaration(
                declaration, index, field.name)
            checkexp(field.exp, st, errors, ptype,
                checker._nominal_argument_demand(
                    result_demand({ ptype }, false, { term = fname }),
                    nominal_constructor, index))
            local term =
                "named argument '" .. field.name .. "' of " .. fname
            local exp = coerce_and_check(
                field.exp, ptype, term, errors, field.loc)
            if supplied[index] then
                checker.typeerror(errors, field.loc,
                    "named argument '%s' is supplied more than once", field.name)
            else
                supplied[index] = true
                dense[index] = exp
                table.insert(order, index)
            end
        end
    end

    for i, name in ipairs(paramnames) do
        if not supplied[i] then
            local ptype = signature.params[i]
            local exp = ast.ExpNil(loc)
            exp._type = types.Nil()
            local adjustment =
                types.assignment_adjustment(exp._type, ptype)
            if adjustment then
                exp = coerce_and_check(exp, ptype,
                    "omitted named argument '" .. name .. "' of " .. fname,
                    errors, loc, maybe3.from_optional(adjustment))
            else
                checker.typeerror(errors, loc,
                    "parameter '%s' of type %s cannot be omitted because it does not accept nil",
                    name, types.tostring(ptype))
            end
            exp._named_omitted = true
            dense[i] = exp
        end
    end
    return dense, order
end

function is_direct_c_bitfield_expression(exp)
    return exp
       and exp._tag == "Ast.ExpVar"
       and exp.var
       and exp.var._decl
       and exp.var._decl._tag == "Type.CField"
       and exp.var._decl.bitfield ~= nil
end

function reject_direct_c_bitfield(node, operands, errors)
    for _, operand in ipairs(operands) do
        if is_direct_c_bitfield_expression(operand) then
            checker.typeerror(errors, operand.loc or node.loc,
                "C operator '%s' cannot be applied directly to bit-field "
                .. "'%s'; cast the bit-field to an ordinary C or Titan "
                .. "integer type first",
                node.op, operand.var._decl.name)
            node._type = types.Invalid()
            return true
        end
    end
    return false
end

function c_operator_pointer_type(typ)
    local value = csemantics.decay_array(typ)
    value = types.resolve_c_typedef(value)
    return value and value._tag == "Type.CPointer"
        and value or nil
end

function c_operator_integer_type(typ)
    typ = types.resolve_c_typedef(typ)
    return typ and (typ._tag == "Type.Integer"
        or typ._tag == "Type.CInteger") or false
end

function reject_invisible_c_operator_pointee(
        node, st, errors, operand, subject)
    local pointer = c_operator_pointer_type(operand._type)
    if not pointer then return false end
    local err = incomplete_c_object_error(
        pointer.pointee, st, subject)
    if not err then return false end
    checker.typeerror(errors, operand.loc or node.loc, "%s", err)
    node._type = types.Invalid()
    return true
end

function reject_invisible_c_operator_object(node, st, errors)
    if node._tag ~= "Ast.ExpBinop"
       or (node.op ~= "+" and node.op ~= "-") then
        return false
    end

    local lhs_pointer = c_operator_pointer_type(node.lhs._type)
    local rhs_pointer = c_operator_pointer_type(node.rhs._type)
    local lhs_integer = c_operator_integer_type(node.lhs._type)
    local rhs_integer = c_operator_integer_type(node.rhs._type)
    if node.op == "+"
       and lhs_pointer and rhs_integer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '+' pointer arithmetic")
    elseif node.op == "+"
       and lhs_integer and rhs_pointer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.rhs,
            "C operator '+' pointer arithmetic")
    elseif node.op == "-"
       and lhs_pointer and rhs_integer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '-' pointer arithmetic")
    elseif node.op == "-"
       and lhs_pointer and rhs_pointer then
        return reject_invisible_c_operator_pointee(
            node, st, errors, node.lhs,
            "C operator '-' pointer subtraction")
            or reject_invisible_c_operator_pointee(
                node, st, errors, node.rhs,
                "C operator '-' pointer subtraction")
    end
    return false
end

local function c_numeric_literal_parts(node)
    local leaf, negative = node, false
    while leaf._tag == "Ast.ExpUnop" and leaf.op == "-" do
        negative = not negative
        leaf = leaf.exp
    end
    if leaf._tag ~= "Ast.ExpInteger" and leaf._tag ~= "Ast.ExpFloat" then
        return nil
    end
    local token = leaf._numeral or tostring(leaf.value)
    if token:match("^%d+$") then
        token = token:gsub("^0+", "")
        if token == "" then token = "0" end
    end
    local literal = cdefines.integer_literal_metadata(token)
    if not literal then token = util.c_float_literal(leaf.value) end
    return token, literal, leaf, negative
end

local function typed_c_literal(typ, token)
    return "((" .. cdeclarator.render_type_name(typ) .. ")(" .. token .. "))"
end

function try_contextual_c_numeric_literal(node, st, errors, context)
    if not context or checker._foreign_function_depth == 0 then return false end
    local token, literal, leaf, negative = c_numeric_literal_parts(node)
    if not token then return false end
    local resolved = types.resolve_c_typedef(context)
    if not resolved or resolved._c_enum_identity
       or (literal and resolved._tag ~= "Type.CInteger")
       or (not literal and resolved._tag ~= "Type.CFloat") then
        return false
    end
    local profile = ensure_c_profile(st)
    if not profile then return false end
    local target = csemantics.numeric_trait(profile, context)
    if not target then return false end
    local magnitude
    if literal then
        -- The widest unsigned candidate also covers the positive magnitude of
        -- a signed minimum, even when the default decimal candidates do not.
        magnitude = csemantics.classify_integer_literal(profile, {
            token = literal.token, digits = literal.digits, radix = literal.radix,
            candidate_classes = { { spelling = "unsigned long long" } },
        })
        if not magnitude then return false end
        local value = negative and magnitude.value ~= "0"
            and "-" .. magnitude.value or magnitude.value
        if not csemantics.integer_range_contains(target, {
            kind = "integer", minimum = value, maximum = value,
        }) then
            return false
        end
        token = magnitude.value .. "ULL"
        if negative and magnitude.value ~= "0" then
            -- Avoid an out-of-range positive signed constant at LLONG_MIN.
            token = "(-((long long)(" .. token .. " - 1ULL)) - 1LL)"
        end
    else
        local value = leaf.value
        if value ~= value or value == math.huge or value == -math.huge then
            return false
        end
        local maximum = (1 - target.radix ^ -target.mantissa_digits)
            * target.radix ^ (target.maximum_exponent - 1) * target.radix
        if math.abs(value) > maximum then return false end
        if negative then token = "-(" .. token .. ")" end
    end
    if leaf ~= node then
        -- The contextual literal is the complete signed source expression.
        -- Keep its children typed, but do not retain a C unary trait on the
        -- root: promotion is not the selected contextual-literal operation.
        if literal and not csemantics.classify_integer_literal(profile, literal) then
            leaf._type = magnitude.type
            leaf._c_literal = typed_c_literal(magnitude.type, magnitude.value .. "ULL")
        else
            classify_c_numeric_literal(leaf, st, errors)
        end
        local function annotate_unary(exp)
            if exp == leaf then return end
            annotate_unary(exp.exp)
            if exp ~= node then check_c_unary_operator(exp, st, errors) end
        end
        annotate_unary(node)
        node._c_operator = nil
    end
    node._type = context
    node._c_literal = typed_c_literal(context, token)
    node._foreign_literal = true
    return true
end

-- This is shared by foreign-body numerals and literal operands selected by
-- C arithmetic. Keep lexical integer digits separate from Lua's numeric value.
function classify_c_numeric_literal(node, st, errors, context)
    if try_contextual_c_numeric_literal(node, st, errors, context) then return end
    local profile, profile_error = ensure_c_profile(st)
    if not profile then
        node._type = invalid(errors, node.loc,
            "cannot classify C numeric literal: %s", tostring(profile_error))
        return
    end
    local token, literal = c_numeric_literal_parts(node)
    if literal then
        local result, err = csemantics.classify_integer_literal(profile, literal)
        if not result then
            node._type = invalid(errors, node.loc, "%s", err)
            return
        end
        node._type = result.type
        token = result.value .. (result.type.signed and "LL" or "ULL")
    else
        node._type = profile.floats.double.type
    end
    node._c_literal = typed_c_literal(node._type, token)
end

local literal_c_operators = {
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
    ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true,
}

local function is_c_arithmetic_type(typ)
    local resolved = types.resolve_c_typedef(typ)
    return resolved and (resolved._tag == "Type.CInteger"
        or resolved._tag == "Type.CFloat")
end

local function is_numeric_literal_operand(node)
    if node._tag == "Ast.ExpInteger" or node._tag == "Ast.ExpFloat" then
        return true
    elseif node._tag == "Ast.ExpUnop"
       and (node.op == "-" or node.op == "~") then
        return is_numeric_literal_operand(node.exp)
    elseif node._tag == "Ast.ExpCast" and node._implicit_coercion then
        -- Ordinary Titan `~` may have inserted a float-to-integer adjustment
        -- before its enclosing operator selected C literal semantics.
        return is_numeric_literal_operand(node.exp)
    end
    return false
end

local function classify_c_literal_operand(node, st, errors)
    if node._tag == "Ast.ExpCast" and node._implicit_coercion then
        return classify_c_literal_operand(node.exp, st, errors)
    elseif node._tag == "Ast.ExpUnop" then
        node.exp = classify_c_literal_operand(node.exp, st, errors)
        check_c_unary_operator(node, st, errors)
    else
        classify_c_numeric_literal(node, st, errors)
    end
    return node
end

function finish_c_operator(node, st, errors, decide, operands)
    if reject_direct_c_bitfield(node, operands, errors) then
        return true
    end
    for _, operand in ipairs(operands) do
        if operand._type._tag == "Type.Invalid" then
            node._type = types.Invalid()
            return true
        end
    end
    if reject_invisible_c_operator_object(node, st, errors) then
        return true
    end

    local trait, decision_error = decide(st.c_profile)
    if not trait and decision_error
       and decision_error:match("target profile") then
        local _, profile_error = ensure_c_profile(st)
        if not st.c_profile then
            checker.typeerror(errors, node.loc,
                "cannot determine C operator '%s' semantics because the "
                .. "configured C target profile is unavailable: %s",
                node.op, tostring(profile_error))
            node._type = types.Invalid()
            return true
        end
        trait, decision_error = decide(st.c_profile)
    end
    if not trait then
        checker.typeerror(errors, node.loc, "%s",
            decision_error or
                ("unsupported C operator '" .. tostring(node.op) .. "'"))
        node._type = types.Invalid()
        return true
    end
    trait.lhs_literal = operands[1]._c_literal
    trait.rhs_literal = operands[2] and operands[2]._c_literal

    local module_probe, probe_error = checker._probe_for_c_types(st, {
        trait.lhs_source, trait.lhs_target,
        trait.rhs_source, trait.rhs_target,
    })
    if not module_probe then
        checker.typeerror(errors, node.loc,
            "cannot validate C operator '%s' because the configured "
            .. "C probe service is unavailable: %s",
            node.op, tostring(probe_error))
        node._type = types.Invalid()
        return true
    end

    local probe = module_probe:probe_operator(trait)
    if not probe or probe.status ~= "success" then
        checker.typeerror(errors, node.loc, "%s",
            probe and probe.message or
                "cannot validate C operator because the probe returned no result")
        node._type = types.Invalid()
        return true
    end

    trait.probe_key = probe.key
    node._c_operator = trait
    node._type = trait.result
    return true
end

function check_c_unary_operator(node, st, errors)
    if not csemantics.is_unary_operator_candidate(
            node.op, node.exp._type) then
        return false
    end
    return finish_c_operator(node, st, errors, function(profile)
        return csemantics.decide_unary_operator(
            profile, node.op, node.exp._type)
    end, {node.exp})
end

function check_c_binary_operator(node, st, errors)
    if not csemantics.is_binary_operator_candidate(
            node.op, node.lhs._type, node.rhs._type) then
        return false
    end
    if literal_c_operators[node.op] then
        -- Foreign-body operands already have their C99 types. Only
        -- replace ordinary Titan literals, not casts, variables or pointers.
        if is_c_arithmetic_type(node.lhs._type)
           and not is_c_arithmetic_type(node.rhs._type)
           and is_numeric_literal_operand(node.rhs) then
            node.rhs = classify_c_literal_operand(node.rhs, st, errors)
        elseif is_c_arithmetic_type(node.rhs._type)
           and not is_c_arithmetic_type(node.lhs._type)
           and is_numeric_literal_operand(node.lhs) then
            node.lhs = classify_c_literal_operand(node.lhs, st, errors)
        end
    end
    return finish_c_operator(node, st, errors, function(profile)
        return csemantics.decide_binary_operator(
            profile, node.op, node.lhs._type, node.rhs._type)
    end, {node.lhs, node.rhs})
end

function interface_downcast_plan(source, target, st)
    local source_nominal = source
    local source_optional = false
    if source_nominal._tag == "Type.Option" then
        source_optional = true
        source_nominal = source_nominal.base
    end
    if source_nominal._tag ~= "Type.Nominal"
       or target._tag ~= "Type.Nominal" then
        return nil
    end
    local interface = types.registry[source_nominal.fqtn]
    local concrete = types.registry[target.fqtn]
    if not interface or interface._tag ~= "Type.Interface"
       or not concrete
       or (concrete._tag ~= "Type.Record"
           and concrete._tag ~= "Type.Union")
       or not is_nominal_visible_from(st, target.fqtn) then
        return nil
    end
    return {
        kind = "interface_downcast",
        source = source,
        target = target,
        interface = interface,
        concrete = concrete,
        source_optional = source_optional,
    }
end

-- Check the source/target relation shared by a written `as` cast and its
-- non-raising `is` predicate. Both constructs contextualize and check the
-- operand exactly once, admit the same explicit C conversions, and carry the
-- same pointer-conversion annotation into code generation. Their result types
-- differ in the expression visitor below.
function check_explicit_cast_relation(node, st, errors)
    node.target = typefromnode(node.target, st, errors)
    report_incomplete_c_object(node.target, st,
        "by-value C cast target", node.loc, errors)
    local cast_context = node.target
    if node.exp._tag == "Ast.ExpVar"
       and node.exp.var._tag == "Ast.VarName" then
        local binding = st:find_symbol(node.exp.var.name)
        if binding and binding._current_module then
            cast_context = current_module_cast_context
        end
    end
    checkexp(node.exp, st, errors, cast_context)
    if node.length then checkexp(node.length, st, errors) end
    local source = node.exp._type
    local target = node.target
    if source._tag == "Type.Invalid" or target._tag == "Type.Invalid"
       or (node.length and node.length._type._tag == "Type.Invalid") then
        node._written_cast_failed = true
        node._written_cast = maybe3.none()
        return target
    end
    if node.length then
        local length_type = types.resolve_c_typedef(node.length._type)
        local message
        if checker._foreign_function_depth > 0 then
            message = "counted string conversion is unavailable in a foreign function body"
        elseif not types.is_pointer_to_string_cast(source, target) then
            message = "counted string conversion requires a character or void pointer and a string target"
        elseif length_type._tag ~= "Type.Integer"
           and length_type._tag ~= "Type.CInteger" then
            message = "counted string length must be an integer or C integer"
        end
        local profile, profile_error
        if not message then profile, profile_error = ensure_c_profile(st) end
        local size_entry = profile and profile.integers[profile.size_t]
        if not message and not (size_entry and size_entry.type) then
            message = profile_error or "counted string conversion requires the target size_t type"
        end
        if message then
            checker.typeerror(errors, node.loc, "%s", message)
            node._written_cast_failed = true
            node._written_cast = maybe3.none()
        else
            node._written_cast = maybe3.just({
                kind = "written_cast", op = "explicit",
                source = source, target = target,
                conversion = {
                    kind = "explicit_conversion", op = "counted_pointer_to_string",
                    source = source, target = target,
                    length_type = node.length._type, size_type = size_entry.type,
                },
            })
        end
        return target
    end
    if reject_const_c_mutable_address(
            node.exp, target, errors, "explicit C cast") then
        node._written_cast_failed = true
        node._written_cast = maybe3.none()
        return target
    end
    local cast_plan
    local applied_application, application_plan =
        generic_applied_nominal_adjustment(source, target, st)
    if not applied_application
       and (source._tag == "Type.Option" or target._tag == "Type.Option") then
        local source_base = source._tag == "Type.Option" and source.base or source
        local target_base = target._tag == "Type.Option" and target.base or target
        local inner_applied, inner_plan =
            generic_applied_nominal_adjustment(
                source_base, target_base, st)
        if inner_applied then
            applied_application = true
            application_plan = inner_plan and types.written_cast(
                types.erase(source), types.erase(target)) or nil
        end
    end
    local rigid_source = generic_rigid_parameter_carrier(source)
    local rigid_target = generic_rigid_parameter_carrier(target)
    if applied_application then
        if application_plan then
            if application_plan.kind == "written_cast" then
                cast_plan = application_plan
            else
                cast_plan = {
                    kind = "written_cast",
                    op = "identity",
                    source = source,
                    target = target,
                    generic_view = application_plan,
                }
            end
        end
    elseif rigid_source or rigid_target then
        local effective_source = rigid_source or source
        local effective_target = rigid_target or target
        local carrier_plan = types.written_cast(
            effective_source, effective_target)
        if carrier_plan then
            cast_plan = {
                kind = "written_cast",
                op = "rigid_carrier",
                source = source,
                target = target,
                carrier_source = effective_source,
                carrier_target = effective_target,
                carrier = carrier_plan,
            }
        end
    else
        cast_plan = types.written_cast(source, target)
    end
    local interface_failure

    -- Written concrete-to-Interface casts authorize only the direct scalar
    -- pair. In particular, do not pass this policy to the first general query:
    -- doing so would silently admit source/target Option lifting that Titan's
    -- written cast table deliberately excludes.
    if not cast_plan
       and source._tag == "Type.Nominal"
       and target._tag == "Type.Nominal" then
        local concrete = types.registry[source.fqtn]
        local interface = types.registry[target.fqtn]
        if concrete
           and (concrete._tag == "Type.Record"
                or concrete._tag == "Type.Union")
           and interface and interface._tag == "Type.Interface" then
            local policy = interface_relation_policy(st)
            cast_plan = types.written_cast(source, target, policy)
            interface_failure = policy.interface_failure or nil
            if cast_plan then
                local conversion = make_interface_conversion(
                    source, target, cast_plan)
                cast_plan.interface_conversion = conversion
                node._interface_conversion = conversion
                if node._tag == "Ast.ExpIs" then
                    node._interface_test = {
                        kind = "interface_implementation_test",
                        conversion = conversion,
                        allocation_free = true,
                    }
                end
            end
        end
    end

    if not cast_plan then
        local downcast = interface_downcast_plan(source, target, st)
        if downcast then
            node._interface_downcast = downcast
            cast_plan = {
                kind = "written_cast",
                op = "interface_downcast",
                source = source,
                target = target,
                interface = downcast.interface,
                concrete = downcast.concrete,
                source_optional = downcast.source_optional,
                downcast = downcast,
            }
            if node._tag == "Ast.ExpIs" then
                node._interface_test = {
                    kind = "interface_downcast_test",
                    downcast = downcast,
                    allocation_free = true,
                }
            end
        end
    end

    -- Written object-pointer casts always reinterpret the pointer value. Only
    -- an implicit exact out-parameter adjustment takes a pointer local's
    -- address; `raw as **void` must continue to mean a C pointer cast.
    local source_c_type = types.resolve_c_typedef(source)
    local written_pointer_cast = source_c_type
        and source_c_type._tag == "Type.CPointer"
    if not written_pointer_cast and is_mutable_c_address_source(node.exp)
       and types.c_mutable_address_coerceable(source, target)
       and not types.c_address_coerceable(source, target) then
        mark_mutable_c_address_source(node.exp)
        assert(not cast_plan,
            "mutable C-address cast unexpectedly has a type-only plan")
        cast_plan = {
            kind = "written_cast",
            op = "coercion",
            source = source,
            target = target,
            coercion = {
                kind = "coercion",
                op = "mutable_c_address",
                source = source,
                target = target,
            },
        }
    elseif not written_pointer_cast
       and types.c_mutable_address_coerceable(source, target) then
        checker.typeerror(errors, node.exp.loc,
            "cannot take a mutable C address of non-addressable "
            .. "expression of type '%s'",
            types.tostring(source))
        node._written_cast_failed = true
        node._written_cast = maybe3.none()
        return target
    elseif not cast_plan then
        if report_interface_failure(
                errors, node.loc, interface_failure) then
            node._written_cast_failed = true
            node._written_cast = maybe3.none()
            return target
        end
        -- Unsafe object-pointer reinterpretation and mutable local address
        -- taking depend on expression shape and, for the former, the active C
        -- toolchain. They are deliberately absent from the type-only written
        -- relation and become complete plans only here.
        local conversion, rejected = checker._unsafe_c_pointer_conversion(
            node.exp, target, errors, "explicit C cast")
        if conversion then
            node._c_conversion = conversion
            cast_plan = {
                kind = "written_cast",
                op = "explicit",
                source = source,
                target = target,
                conversion = conversion,
            }
        elseif rejected then
            -- The conversion helper already emitted the more precise
            -- category/qualifier/probe diagnostic.
            node._written_cast_failed = true
            node._written_cast = maybe3.none()
            return target
        end
    end
    node._written_cast = maybe3.from_optional(cast_plan)
    if node._tag == "Ast.ExpCast"
       and cast_plan and cast_plan.op == "callable" then
        node._callable_adapter = checker.freeze_callable_adapter(
            cast_plan.callable, source, target, node.loc)
    end
    if not cast_plan then
        checker.typeerror(errors, node.loc, "cannot cast '%s' to '%s'",
            types.tostring(source), types.tostring(target))
    end
    return target
end

function generic_recover_complete_type_arguments(
        typearg_nodes, count, st, errors, loc, subject)
    local arguments = generic_resolve_type_argument_nodes(
        typearg_nodes, st, errors)
    local written = #arguments
    local valid = written == count
    if written == 0 and count > 0 then
        checker.typeerror(errors, loc,
            "%s is generic and requires an explicit complete type argument list in this checker phase",
            subject)
    elseif written ~= count then
        checker.typeerror(errors, loc,
            "%s expected %d type arguments but found %d",
            subject, count, written)
    end

    -- Keep substitution total after an error, but never silently turn an
    -- ineligible written argument into `value`: emit the admission diagnostic
    -- before installing that recovery carrier.
    local recovered = {}
    for index = 1, count do
        local argument = arguments[index]
        if argument and types.transient_roundtrip(argument) then
            recovered[index] = argument
        else
            if argument and argument._tag ~= "Type.Invalid" then
                checker.typeerror(errors, loc,
                    "%s type argument %d ('%s') has no sound transient round trip",
                    subject, index, types.tostring(argument))
            end
            recovered[index] = types.Value()
            valid = false
        end
    end
    return recovered, valid
end

function generic_callable_function_type(callable)
    return types.Function(callable.params, callable.rettypes, false,
        callable.varargtype or nil, callable.flexrettype or nil)
end

function generic_inference_scope_entry(scope, typeparams, parameters)
    local entry = {
        scope = scope,
        typeparams = typeparams or {},
        parameters = parameters or {},
        cells = {},
    }
    for index, typeparam in ipairs(entry.typeparams) do
        local parameter = entry.parameters[index]
        if not parameter then
            parameter = types.Parameter(scope, index, typeparam.name,
                typeparam.constraint and types.erase_constraint(typeparam.constraint))
        end
        entry.parameters[index] = parameter
        local cell = {
            name = typeparam.name,
            parameter = parameter,
            binding = nil,
            evidence = nil,
            invalid = false,
            recursive_inference = false,
            conflicts = {},
        }
        cell.parent = cell
        entry.cells[index] = cell
    end
    return entry
end

function generic_new_inference_context(subject, scopes, st, errors, loc)
    local context = {
        subject = subject,
        scopes = {},
        st = st,
        errors = errors,
        loc = loc,
        closed = false,
        roots = {},
        active_use = nil,
        scope_entries = {},
        constraint_queue = {},
        constraint_queued = {},
        constraint_head = 1,
        next_constraint_sequence = 0,
    }
    for _, entry in ipairs(scopes or {}) do
        entry.subject = entry.subject or subject
        entry.loc = entry.loc or loc
        for _, cell in ipairs(entry.cells) do
            cell.subject = entry.subject
            cell.loc = entry.loc
            cell.entry = entry
        end
        context.scopes[#context.scopes + 1] = entry
        context.scope_entries[entry.scope] = entry
    end
    return context
end

function generic_freshen_inference_type(
        context, typ, entries, subject, loc)
    local out = typ
    for _, entry in ipairs(entries or {}) do
        out = generic_substitute(
            out, entry.declaration_scope, entry.parameters,
            context.errors, loc or entry.loc or context.loc,
            "cannot create fresh inference variables for "
                .. (subject or entry.subject or context.subject)) or out
    end
    return out
end

function generic_freshen_inference_entries(
        context, entries, subject, loc)
    for _, entry in ipairs(entries) do
        context.next_scope = (context.next_scope or 0) + 1
        local scope = entry.scope
        entry.declaration_scope = scope
        entry.source_typeparams = entry.typeparams
        entry.source_parameters = entry.parameters
        entry.scope = types.GenericScope(
            tostring(scope.modname) .. "\0inference:" .. context.next_scope,
            scope.owner_fqtn, scope.callable_name, scope.role,
            scope.declaration_kind)
        entry.parameters = {}
        entry.cells = {}
        for index, typeparam in ipairs(entry.source_typeparams) do
            local source = entry.source_parameters[index]
            local parameter = types.Parameter(
                entry.scope, index, typeparam.name,
                source and source.erased_constraint or nil)
            entry.parameters[index] = parameter
            local cell = {
                name = typeparam.name,
                parameter = parameter,
                binding = nil,
                evidence = nil,
                invalid = false,
                recursive_inference = false,
                conflicts = {},
            }
            cell.parent = cell
            entry.cells[index] = cell
        end
    end
    -- Constraints and erased parameter carriers may mention another binder in
    -- the same owner/callable application. Freshen only after every declaration
    -- scope in this use has its distinct occurrence scope.
    for _, entry in ipairs(entries) do
        local fresh_typeparams = {}
        for index, typeparam in ipairs(entry.source_typeparams) do
            local constraint = typeparam.constraint
            if constraint ~= nil then
                constraint = generic_freshen_inference_type(
                    context, constraint, entries, subject, loc)
            end
            fresh_typeparams[index] =
                types.TypeParameter(typeparam.name, constraint)
            local source = entry.source_parameters[index]
            local erased = source and source.erased_constraint or nil
            if erased ~= nil then
                entry.parameters[index].erased_constraint =
                    generic_freshen_inference_type(
                        context, erased, entries, subject, loc)
            end
        end
        entry.typeparams = fresh_typeparams
    end
end

function generic_register_inference_use(
        context, node, subject, loc, scopes, owns_context)
    local use = {
        node = node,
        subject = subject,
        loc = loc,
        scopes = scopes or {},
        children = {},
        discoveries = {},
        finalizers = {},
        derived_nodes = {},
        context = context,
        parent = context.active_use or nil,
        owns_context = owns_context and true or false,
    }
    if use.parent then
        use.parent.children[#use.parent.children + 1] = use
    else
        context.roots[#context.roots + 1] = use
    end
    return use
end

function generic_acquire_inference_context(
        node, subject, scopes, st, errors, loc)
    local context = st and st.generic_inference_context or nil
    if context and context.closed then context = nil end
    local owns = context == nil
    if owns then
        context = generic_new_inference_context(
            subject, {}, st, errors, loc)
        context.owner = node
    end

    scopes = scopes or {}
    generic_freshen_inference_entries(
        context, scopes, subject, loc)
    local use = generic_register_inference_use(
        context, node, subject, loc, scopes, owns)
    for _, entry in ipairs(use.scopes) do
        entry.subject = subject
        entry.loc = loc
        entry.use = use
        for _, cell in ipairs(entry.cells) do
            cell.subject = subject
            cell.loc = loc
            cell.entry = entry
        end
        context.scopes[#context.scopes + 1] = entry
        context.scope_entries[entry.scope] = entry
        for index, typeparam in ipairs(entry.typeparams) do
            if typeparam.constraint ~= nil then
                context.next_constraint_sequence =
                    context.next_constraint_sequence + 1
                local record = {
                    cell = entry.cells[index],
                    typeparam = typeparam,
                    sequence = context.next_constraint_sequence,
                }
                local root = entry.cells[index]
                root.constraint_records = root.constraint_records or {}
                root.constraint_records[#root.constraint_records + 1] = record
            end
        end
    end
    node._generic_inference_context = context
    node._generic_inference_use = use
    return context, use, owns
end

function generic_with_inference_use(context, use, st, action)
    local prior_context = st and st.generic_inference_context or nil
    local prior_use = context.active_use
    if st then st.generic_inference_context = context end
    context.active_use = use
    local result = table.pack(pcall(action))
    context.active_use = prior_use
    if st then st.generic_inference_context = prior_context end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

function generic_with_inference_operation(node, st, action, subject)
    local context = st and st.generic_inference_context or nil
    if not context or context.closed or not context.active_use then
        return action(false)
    end

    -- An ExpVar delegates projection checking to its Var child. Keep the
    -- expression itself as the operation identity so parent expression-list
    -- aliases observe the finalized annotations on the delivered AST node.
    local operation_node = node
    if node._tag == "Ast.VarDot" or node._tag == "Ast.VarBracket" then
        operation_node = st.generic_inference_expression_owner or node
    end

    -- A dependent operation needs its own use-tree position before descending,
    -- so nested generic uses and operations finalize before it freezes the
    -- annotations derived from their provisional types.
    local use = generic_register_inference_use(
        context, operation_node, subject or "dependent operation",
        operation_node.loc, {}, false)
    use.derived_nodes[1] = operation_node
    operation_node._generic_inference_operation_use = use
    return generic_with_inference_use(context, use, st, function()
        return action(use)
    end)
end

function generic_add_inference_discovery(use, discovery, phase)
    use.discoveries[#use.discoveries + 1] = {
        callback = discovery,
        complete = false,
        phase = phase or "evidence",
    }
end

function generic_add_inference_finalizer(use, finalizer)
    use.finalizers[#use.finalizers + 1] = finalizer
end

function generic_substitute_inference_graph(
        operation, value, recover, seen)
    if type(value) ~= "table" then return value end
    if type(value._tag) == "string"
       and value._tag:match("^Type%.") then
        return generic_substitute_inference(
            operation.context, value, recover ~= false)
    end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        out[key] = generic_substitute_inference_graph(
            operation, child, recover, seen)
    end
    return out
end

function generic_finalize_inference_annotation(
        operation, value, recover)
    return generic_substitute_inference_graph(
        operation, value, recover, {})
end

-- Derived expressions own no fresh binders. They still need a postorder slot so
-- checker annotations copied from an open child are refreshed only after that
-- child has closed, without redispatching any written expression. `fields`
-- maps each annotation key to either true (smart-substitute a Type value) or a
-- refresh callback `(old, context, operation_node, node) -> new`.
function generic_register_inference_derived_node(operation, node)
    operation.derived_nodes[#operation.derived_nodes + 1] = node
end

function generic_defer_inference_derived_annotations(
        operation, node, fields, finalizer)
    if not operation then return false end
    local operation_node = operation.node or node
    generic_register_inference_derived_node(operation, node)
    if operation_node ~= node then
        generic_register_inference_derived_node(
            operation, operation_node)
    end
    generic_add_inference_finalizer(operation, function()
        local copies = {}
        for key, refresh in pairs(fields or {}) do
            local value = node[key]
            if refresh == true then
                value = generic_finalize_inference_annotation(
                    operation, value, true)
            else
                value = refresh(value, operation.context,
                    operation_node, node)
            end
            node[key] = value
            copies[key] = value
        end
        if finalizer then finalizer(operation.context, operation_node) end
        if operation_node ~= node then
            for key, value in pairs(copies) do operation_node[key] = value end
            if node._type then operation_node._type = node._type end
        end
    end)
    operation.dependent_derived = true
    return true
end

-- Auto-forcing a dependent computed callee/receiver creates a checker-owned
-- ExpCast whose target is copied from the still-open child.  Rebuild only that
-- wrapper after the child's operation closes; the written expression remains
-- checked once and retains its AST identity.
function generic_defer_inference_force(
        operation, node, written, expected_base_tag)
    if not operation or node.exp == written then return false end
    generic_add_inference_finalizer(operation, function()
        node.exp = written
        local typ = written._type
        if typ and typ._tag == "Type.Option"
           and typ.base._tag == expected_base_tag then
            node.exp = tryforce(written)
        end
    end)
    operation.dependent_derived = true
    return true
end

function generic_finalize_inference_use(use)
    -- Postorder gives every parent closed child annotations before it freezes
    -- its own argument adjustments. Siblings remain in lexical registration
    -- order, preserving diagnostic and checking order.
    for _, child in ipairs(use.children) do
        generic_finalize_inference_use(child)
    end
    for _, finalizer in ipairs(use.finalizers) do finalizer() end
    if use.node then
        if use.node._generic_inference_use == use then
            use.node._generic_inference_context = nil
            use.node._generic_inference_use = nil
        end
        if use.node._generic_inference_operation_use == use then
            use.node._generic_inference_operation_use = nil
        end
    end
end

function generic_inference_root(cell)
    if cell.parent ~= cell then
        cell.parent = generic_inference_root(cell.parent)
    end
    return cell.parent
end

function generic_inference_cell(context, parameter)
    if not parameter or parameter._tag ~= "Type.Parameter" then return nil end
    local entry = context.scope_entries and context.scope_entries[parameter.scope]
    if entry then return entry.cells[parameter.index] end
    -- Rehydrated/test-built scope descriptors may be structurally equal without
    -- sharing table identity. Keep the bounded compatibility fallback, then
    -- memoize it so ordinary solver traffic remains constant-time.
    for _, candidate in ipairs(context.scopes) do
        if types.same_generic_scope(candidate.scope, parameter.scope) then
            context.scope_entries[parameter.scope] = candidate
            return candidate.cells[parameter.index]
        end
    end
    return nil
end

function generic_inference_evidence_name(evidence)
    return evidence or "type context"
end

-- Follow only inference equations, not the declared constraints of free cells.
-- A constraint may validly mention another binder and does not equate that
-- binder with its carrier. Bindings, on the other hand, are equations and must
-- remain acyclic before the fixed-point substitution path can expand them.
function generic_inference_type_occurs(
        context, target, typ, seen_types, seen_roots)
    if type(typ) ~= "table" then return false end
    target = generic_inference_root(target)
    seen_types = seen_types or {}
    seen_roots = seen_roots or {}

    if typ._tag == "Type.Parameter" then
        local cell = generic_inference_cell(context, typ)
        if not cell then return false end
        local root = generic_inference_root(cell)
        if root == target then return true end
        if seen_roots[root] then return false end
        seen_roots[root] = true
        return root.binding and generic_inference_type_occurs(
            context, target, root.binding, seen_types, seen_roots) or false
    end

    if seen_types[typ] then return false end
    seen_types[typ] = true
    for key, value in pairs(typ) do
        if key ~= "scope" and type(value) == "table" then
            if value._tag then
                if generic_inference_type_occurs(
                        context, target, value, seen_types, seen_roots) then
                    return true
                end
            else
                for _, item in pairs(value) do
                    if generic_inference_type_occurs(
                            context, target, item, seen_types, seen_roots) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function generic_reject_recursive_inference(
        context, cell, related, evidence, loc)
    cell = generic_inference_root(cell)
    related = related and generic_inference_root(related) or nil
    local reported = cell.recursive_inference
        or (related and related.recursive_inference)
    cell.invalid = true
    cell.recursive_inference = true
    if related then
        related.invalid = true
        related.recursive_inference = true
    end
    if not reported then
        checker.typeerror(context.errors, loc or cell.loc or context.loc,
            "cannot infer a recursive type for type parameter '%s' in %s from %s",
            cell.name, cell.subject
                or (related and related.subject) or context.subject,
            generic_inference_evidence_name(evidence))
    end
    return false
end

function generic_enqueue_constraint_root(context, cell)
    local root = generic_inference_root(cell)
    for _, record in ipairs(root.constraint_records or {}) do
        if not context.constraint_queued[record] then
            context.constraint_queued[record] = true
            context.constraint_queue[#context.constraint_queue + 1] = record
        end
    end
end

function generic_union_inference_cells(context, left, right,
                                                 evidence, loc)
    left = generic_inference_root(left)
    right = generic_inference_root(right)
    if left == right then return true end

    local left_binding, right_binding = left.binding, right.binding
    -- Joining two classes also substitutes either representative through the
    -- other's existing structural equation. Reject that edge before changing
    -- the union-find forest when it would make either binding self-referential.
    if (left_binding and generic_inference_type_occurs(
            context, right, left_binding))
       or (right_binding and generic_inference_type_occurs(
            context, left, right_binding)) then
        return generic_reject_recursive_inference(
            context, left, right, evidence, loc)
    end

    -- Keep the pattern-side representative stable. Besides producing clearer
    -- diagnostics, this makes an outer owner's cell the canonical endpoint of
    -- an equation registered by a nested use.
    right.parent = left
    left.constraint_records = left.constraint_records or {}
    for _, record in ipairs(right.constraint_records or {}) do
        left.constraint_records[#left.constraint_records + 1] = record
    end
    table.sort(left.constraint_records, function(a, b)
        return a.sequence < b.sequence
    end)
    left.invalid = left.invalid or right.invalid
    left.recursive_inference = left.recursive_inference
        or right.recursive_inference
    for key in pairs(right.conflicts) do left.conflicts[key] = true end
    if not left.subject then left.subject = right.subject end
    if not left.loc then left.loc = right.loc end

    left.binding = left_binding or right_binding
    if left_binding and right_binding then
        left.binding = left_binding
        generic_enqueue_constraint_root(context, left)
        return generic_bind_inference_cell(
            context, left, right_binding, evidence, loc)
    end
    if right_binding and not left_binding then
        left.evidence, left.loc = right.evidence, right.loc
    end
    if left.binding then
        generic_enqueue_constraint_root(context, left)
    end
    return true
end

function generic_bind_inference_cell(context, cell, candidate,
                                               evidence, loc)
    cell = generic_inference_root(cell)
    candidate = types.normalize(candidate) or candidate
    if not candidate or candidate._tag == "Type.Invalid" then return false end

    local candidate_cell = generic_inference_cell(context, candidate)
    if candidate_cell then
        return generic_union_inference_cells(
            context, cell, candidate_cell, evidence, loc)
    end
    if generic_inference_type_occurs(context, cell, candidate) then
        return generic_reject_recursive_inference(
            context, cell, nil, evidence, loc)
    end

    if not cell.binding then
        cell.binding = candidate
        cell.evidence = generic_inference_evidence_name(evidence)
        cell.loc = loc
        generic_enqueue_constraint_root(context, cell)
        return true
    end
    if types.equals(cell.binding, candidate) then return true end
    local resolved_binding = generic_substitute_inference(
        context, cell.binding, false)
    local resolved_candidate = generic_substitute_inference(
        context, candidate, false)
    if types.equals(resolved_binding, resolved_candidate) then
        if not types.equals(cell.binding, resolved_binding) then
            cell.binding = resolved_binding
            generic_enqueue_constraint_root(context, cell)
        end
        return true
    end
    -- A prior equation may have bound this class to a structure containing
    -- cells owned by a nested use (for example outer U = Maybe<V>). Later
    -- concrete evidence must decompose that equation before it can be called a
    -- conflict.
    if generic_inference_type_has_unresolved(
            context, cell.binding)
       or generic_inference_type_has_unresolved(
            context, candidate) then
        if generic_unify_inference(
                context, cell.binding, candidate, evidence, loc) then
            return true
        end
    end

    local key = types.tostring(candidate)
    if not cell.conflicts[key] then
        cell.conflicts[key] = true
        checker.typeerror(context.errors, loc or cell.loc or context.loc,
            "conflicting type evidence for type parameter '%s' in %s: "
            .. "inferred '%s' from %s but found '%s' from %s",
            cell.name, cell.subject or context.subject,
            types.tostring(cell.binding), cell.evidence, key,
            generic_inference_evidence_name(evidence))
    end
    cell.invalid = true
    return false
end

-- Phase-one inference is invariant only while an ambient cell remains open.
-- Once both smart-substituted endpoints are closed, the owning phase-two
-- finalizer applies Titan's ordinary directional assignment relation instead.
function generic_unify_inference(context, pattern, evidence,
                                          term, loc, seen)
    if not pattern or not evidence then return false end
    pattern = generic_substitute_inference(context, pattern, false)
    evidence = generic_substitute_inference(context, evidence, false)
    pattern, evidence = types.normalize(pattern), types.normalize(evidence)
    if not pattern or not evidence
       or generic_inference_type_has_invalid(pattern)
       or generic_inference_type_has_invalid(evidence) then
        return false
    end

    -- Inference is ordered. Once both sides of an edge are independent closed
    -- types, this edge can no longer select a binding. Its ordinary directional
    -- adjustment is frozen by the owning use's finalization pass. If either side
    -- still contains an ambient cell, structural descent must continue so a
    -- closed target can bind cells owned by a nested producer.
    if not generic_inference_type_has_unresolved(context, pattern)
       and not generic_inference_type_has_unresolved(context, evidence) then
        return true
    end

    local cell = generic_inference_cell(context, pattern)
    if cell then
        return generic_bind_inference_cell(
            context, cell, evidence, term, loc)
    end
    local evidence_cell = generic_inference_cell(context, evidence)
    if evidence_cell then
        return generic_bind_inference_cell(
            context, evidence_cell, pattern, term, loc)
    end
    if types.equals(pattern, evidence) then return true end

    seen = seen or {}
    local pair_key = pattern
    local evidence_seen = seen[pair_key]
    if evidence_seen and evidence_seen[evidence] then return true end
    evidence_seen = evidence_seen or {}
    seen[pair_key] = evidence_seen
    evidence_seen[evidence] = true

    local ptag, etag = pattern._tag, evidence._tag
    if ptag == "Type.Option" and etag == "Type.Option" then
        return generic_unify_inference(context,
            pattern.base, evidence.base, term, loc, seen)
    elseif ptag == "Type.Option" and etag == "Type.Value" then
        -- Option(value) canonicalizes to value. This is reconstruction of the
        -- same invariant application, not a lifted gradual conversion.
        return generic_unify_inference(context,
            pattern.base, evidence, term, loc, seen)
    elseif ptag == "Type.Array" and etag == "Type.Array" then
        return generic_unify_inference(context,
            pattern.elem, evidence.elem, term, loc, seen)
    elseif ptag == "Type.Map" and etag == "Type.Map" then
        local keys = generic_unify_inference(context,
            pattern.keys, evidence.keys, term, loc, seen)
        local values = generic_unify_inference(context,
            pattern.values, evidence.values, term, loc, seen)
        return keys and values
    elseif ptag == "Type.Nominal" and etag == "Type.Nominal"
       and pattern.fqtn == evidence.fqtn
       and #(pattern.args or {}) == #(evidence.args or {}) then
        local ok = true
        for index, argument in ipairs(pattern.args or {}) do
            ok = generic_unify_inference(context, argument,
                evidence.args[index], term, loc, seen) and ok
        end
        return ok
    elseif ptag == "Type.Function" and etag == "Type.Function"
       and #pattern.params == #evidence.params
       and #pattern.rettypes == #evidence.rettypes
       and (pattern.varargtype == nil) == (evidence.varargtype == nil)
       and (pattern.flexrettype == nil) == (evidence.flexrettype == nil) then
        local ok = true
        for index, parameter in ipairs(pattern.params) do
            ok = generic_unify_inference(context, parameter,
                evidence.params[index], term, loc, seen) and ok
        end
        for index, result in ipairs(pattern.rettypes) do
            ok = generic_unify_inference(context, result,
                evidence.rettypes[index], term, loc, seen) and ok
        end
        if pattern.varargtype ~= nil then
            ok = generic_unify_inference(context,
                pattern.varargtype, evidence.varargtype,
                term, loc, seen) and ok
        end
        if pattern.flexrettype ~= nil then
            ok = generic_unify_inference(context,
                pattern.flexrettype, evidence.flexrettype,
                term, loc, seen) and ok
        end
        return ok
    end
    return false
end

function generic_inference_arguments(entry, recover)
    local arguments = {}
    for index, cell in ipairs(entry.cells) do
        local root = generic_inference_root(cell)
        arguments[index] = root.binding
            or (recover and generic_rigid_parameter_carrier(
                entry.parameters[index]))
            or entry.parameters[index]
    end
    return arguments
end

function generic_substitute_inference(context, typ, recover)
    local out = typ
    local entries, present = {}, {}

    local function discover(value, seen)
        if type(value) ~= "table" then return end
        seen = seen or {}
        if seen[value] then return end
        seen[value] = true
        if value._tag == "Type.Parameter" then
            local cell = generic_inference_cell(context, value)
            local entry = cell and cell.entry
            if entry and not present[entry] then
                present[entry] = true
                entries[#entries + 1] = entry
            end
            return
        end
        for key, child in pairs(value) do
            if key ~= "scope" and type(child) == "table" then
                if child._tag then
                    discover(child, seen)
                else
                    for _, item in pairs(child) do discover(item, seen) end
                end
            end
        end
    end

    discover(out)
    local pass = 1
    -- Substitute only occurrence scopes actually reachable from this type.
    -- A binding may introduce another scope (or one processed earlier), so
    -- rescan the small reachable set to a fixed point rather than sweeping
    -- every sibling use in the ambient context after every lexical edge.
    while pass <= math.max(1, #entries + 1) do
        local before = out
        local limit = #entries
        for index = 1, limit do
            local entry = entries[index]
            local ok, rewritten = pcall(types.substitute_inference,
                out, entry.scope,
                generic_inference_arguments(entry, recover))
            if not ok then
                context.substitution_failures =
                    context.substitution_failures or {}
                local message = tostring(rewritten)
                local key = tostring(entry.scope) .. "\0" .. message
                if not context.substitution_failures[key] then
                    context.substitution_failures[key] = true
                    checker.typeerror(context.errors,
                        entry.loc or context.loc,
                        "cannot close %s: %s",
                        entry.subject or context.subject, message)
                end
                local invalid = {}
                for argument_index = 1, #entry.cells do
                    invalid[argument_index] = types.Invalid()
                end
                local recovered_ok, recovered_type = pcall(
                    types.substitute_inference, out, entry.scope, invalid)
                out = recovered_ok and recovered_type or types.Invalid()
            else
                out = rewritten
            end
        end
        discover(out)
        if types.equals(before, out) then break end
        pass = pass + 1
    end
    return out
end

function generic_inference_type_has_unresolved(context, typ, seen)
    if type(typ) ~= "table" then return false end
    seen = seen or {}
    if seen[typ] then return false end
    seen[typ] = true

    if typ._tag == "Type.Parameter" then
        local cell = generic_inference_cell(context, typ)
        if not cell then return false end
        local root = generic_inference_root(cell)
        if not root.binding then return true end
        return generic_inference_type_has_unresolved(
            context, root.binding, seen)
    end
    for key, value in pairs(typ) do
        if key ~= "scope" and type(value) == "table" then
            if value._tag then
                if generic_inference_type_has_unresolved(context, value, seen) then
                    return true
                end
            else
                for _, item in pairs(value) do
                    if generic_inference_type_has_unresolved(context, item, seen) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function generic_closed_inference_pattern(context, typ)
    local substituted = generic_substitute_inference(
        context, typ, false)
    if generic_inference_type_has_unresolved(context, substituted) then return nil end
    return substituted
end

function generic_inference_entry_type_arguments(context, entry)
    local arguments = {}
    for index, cell in ipairs(entry.cells) do
        local root = generic_inference_root(cell)
        arguments[index] = generic_substitute_inference(
            context, root.binding or entry.parameters[index], true)
    end
    return arguments
end

function generic_inference_type_arguments(context, entries)
    local arguments = {}
    for _, entry in ipairs(entries or context.scopes) do
        local local_arguments =
            generic_inference_entry_type_arguments(context, entry)
        for _, argument in ipairs(local_arguments) do
            arguments[#arguments + 1] = argument
        end
    end
    return arguments
end

-- A rigid actual parameter can contribute dependency evidence without being
-- replaced by its erased runtime carrier. If W is bound to an outer T whose
-- declared surface constraint is I<U>, a callee constraint W: I<V> provides
-- the invariant equation I<V> = I<U> and can therefore bind V to U. Iterate a
-- bounded number of times so chains of dependent constraints settle before
-- free inference cells close to their declared carriers.
function generic_infer_constraint_evidence(context)
    local queue = context.constraint_queue
    while context.constraint_head <= #queue do
        local record = queue[context.constraint_head]
        context.constraint_head = context.constraint_head + 1
        context.constraint_queued[record] = nil

        local cell = record.cell
        local typeparam = record.typeparam
        local root = cell and generic_inference_root(cell)
        local argument = root and root.binding
        if argument and argument._tag == "Type.Parameter"
           and not root.invalid and typeparam.constraint ~= nil then
            local surface, surface_valid = types.parameter_surface_constraint(
                argument, context.st and context.st.generic_scope_bindings)
            local required = generic_substitute_inference(
                context, typeparam.constraint, false)
            local surface_owner = surface_valid and surface
                and generic_owner_type(surface)
            local required_owner = required
                and generic_owner_type(required)
            if surface_valid and surface
               and surface._tag == "Type.Nominal"
               and required and required._tag == "Type.Nominal"
               and surface.fqtn == required.fqtn
               and surface_owner and required_owner
               and surface_owner._tag == "Type.Interface"
               and required_owner._tag == "Type.Interface"
               and #(surface.args or {}) == #(required.args or {}) then
                generic_unify_inference(
                    context, required, surface,
                    "declared constraint of type parameter '" ..
                        tostring(argument.diagnostic_name) .. "'",
                    cell.loc or context.loc)
            end
        end
    end
    -- Every queued record was consumed. Reset rather than retaining a growing
    -- sparse prefix across the remaining lexical edges of this operation.
    context.constraint_queue = {}
    context.constraint_head = 1
end

function generic_inference_discovery_pass(use, phase)
    local completed = 0
    -- A parent discovery may depend on a nested derived operation. Match the
    -- finalizer order here: deepest children first, lexical siblings in order.
    for _, child in ipairs(use.children) do
        completed = completed
            + generic_inference_discovery_pass(child, phase)
    end
    for _, discovery in ipairs(use.discoveries) do
        if not discovery.complete and discovery.phase == phase then
            -- A deferred expression must register any nested generic use below
            -- its original AST-owned occurrence, not below whichever sibling
            -- happened to unlock it.
            local done = generic_with_inference_use(
                use.context, use, use.context.st, discovery.callback)
            if done then
                discovery.complete = true
                completed = completed + 1
            end
        end
    end
    return completed
end

function generic_run_inference_discovery_phase(context, phase)
    local total = 0
    while true do
        generic_infer_constraint_evidence(context)
        local completed = 0
        for _, use in ipairs(context.roots) do
            completed = completed
                + generic_inference_discovery_pass(use, phase)
        end
        if completed == 0 then break end
        total = total + completed
    end
    generic_infer_constraint_evidence(context)
    return total
end

function generic_discover_inference_evidence(context)
    -- Real equations and context-ready producers always settle before a
    -- syntax default. A default may in turn close an earlier pending term, so
    -- drain evidence again after each finite default round. Generic carrier
    -- closure happens only after this language-level fixed point.
    while true do
        generic_run_inference_discovery_phase(context, "evidence")
        local defaulted = generic_run_inference_discovery_phase(
            context, "default")
        if defaulted == 0 then break end
    end
    generic_run_inference_discovery_phase(context, "evidence")
end

function generic_default_inference_cells(context)
    -- Defaults belong to equivalence classes, not declaration positions. A
    -- nested constrained binder equated with an unconstrained outer binder must
    -- contribute its Interface carrier before `value` can close that class.
    -- Dependent constraints may become closed only after another genuinely
    -- unconstrained class has taken its value carrier, so alternate those two
    -- steps to a fixed point while always preferring a constraint.
    local function classes()
        local out, order = {}, {}
        for _, entry in ipairs(context.scopes) do
            for index, cell in ipairs(entry.cells) do
                local root = generic_inference_root(cell)
                local class = out[root]
                if not class then
                    class = { root = root, members = {}, constrained = false }
                    out[root] = class
                    order[#order + 1] = class
                end
                class.members[#class.members + 1] = {
                    entry = entry,
                    index = index,
                    typeparam = entry.typeparams[index],
                }
                if entry.typeparams[index].constraint ~= nil then
                    class.constrained = true
                end
            end
        end
        return order
    end

    local class_count = #classes()
    for _ = 1, math.max(1, class_count * 2 + 1) do
        local changed = false
        local current = classes()
        for _, class in ipairs(current) do
            local root = generic_inference_root(class.root)
            if not root.binding then
                for _, member in ipairs(class.members) do
                    local constraint = member.typeparam.constraint
                    if constraint ~= nil then
                        constraint = generic_substitute_inference(
                            context, constraint, false)
                        if not generic_inference_type_has_unresolved(
                                context, constraint) then
                            root.binding = constraint
                            root.evidence = "declared erased carrier"
                            root.loc = member.entry.loc or context.loc
                            root.subject = member.entry.subject or context.subject
                            changed = true
                            break
                        end
                    end
                end
            end
        end
        if changed then
            generic_infer_constraint_evidence(context)
        else
            -- Only classes without any constrained declaration are genuinely
            -- free at this point. Their fixed carrier can unlock a dependent
            -- constrained class on the next iteration.
            for _, class in ipairs(current) do
                local root = generic_inference_root(class.root)
                if not root.binding and not class.constrained then
                    root.binding = types.Value()
                    root.evidence = "declared erased carrier"
                    root.loc = root.loc or context.loc
                    changed = true
                end
            end
        end
        if not changed then break end
    end

    local unresolved, seen = 0, {}
    for _, class in ipairs(classes()) do
        local root = generic_inference_root(class.root)
        if not seen[root] and not root.binding then
            seen[root] = true
            unresolved = unresolved + 1
        end
    end
    return unresolved
end

function generic_assert_inference_derived_nodes_closed(context)
    local source_backreference = {
        _decl = true,
        _declared_type = true,
        _generic_scheme = true,
        _generic_declaration = true,
        _generic_owner = true,
    }
    local seen = {}
    local function visit(value, path)
        if type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        if value._tag == "Type.Parameter"
           and generic_inference_cell(context, value) then
            error("ambient inference parameter survived derived finalization at "
                .. path, 0)
        end
        for key, child in pairs(value) do
            if not source_backreference[key] then
                visit(child, path .. "." .. tostring(key))
            end
        end
    end
    local function visit_use(use)
        for _, node in ipairs(use.derived_nodes) do
            visit(node, node._tag or "derived operation")
        end
        for _, child in ipairs(use.children) do visit_use(child) end
    end
    for _, use in ipairs(context.roots) do visit_use(use) end
end

-- Implementation notes: doc/implementation/generics.md#local-instantiation-and-inference
function generic_close_inference_context(context)
    if context.closed then return context.valid end
    assert(not context.closing, "recursive generic inference-context close")
    context.closing = true
    generic_discover_inference_evidence(context)
    local unresolved = generic_default_inference_cells(context)
    local valid = unresolved == 0

    local seen_roots = {}
    for _, entry in ipairs(context.scopes) do
        for _, cell in ipairs(entry.cells) do
            local root = generic_inference_root(cell)
            if not seen_roots[root] then
                seen_roots[root] = true
                if not root.binding then
                    checker.typeerror(context.errors, entry.loc or context.loc,
                        "cannot close type argument '%s' for %s to its declared erased carrier",
                        cell.name, entry.subject or context.subject)
                    root.binding = types.Value()
                    root.invalid = true
                    valid = false
                else
                    root.binding = generic_substitute_inference(
                        context, root.binding, true)
                    if not types.transient_roundtrip(root.binding) then
                        checker.typeerror(context.errors,
                            root.loc or entry.loc or context.loc,
                            "%s inferred type argument '%s' for '%s', which has no sound transient round trip",
                            root.subject or entry.subject or context.subject,
                            types.tostring(root.binding), cell.name)
                        -- Retain the selected surface type through phase-two
                        -- finalization so every later edge receives its ordinary
                        -- directional diagnostic. The enclosing checker already
                        -- skips erased lowering after this admission error.
                        root.invalid = true
                        valid = false
                    elseif root.invalid then
                        valid = false
                    end
                end
            end
        end
    end

    -- Constraints remain declaration-local even when their cells participate in
    -- an equation owned by another use. Validate every declared binder against
    -- the one closed equivalence-class argument.
    for _, entry in ipairs(context.scopes) do
        for index, typeparam in ipairs(entry.typeparams) do
            local root = generic_inference_root(entry.cells[index])
            if not root.invalid and typeparam.constraint ~= nil then
                local constraint = generic_substitute_inference(
                    context, typeparam.constraint, true)
                local argument = generic_substitute_inference(
                    context, root.binding, true)
                local satisfied = generic_constraint_satisfied(
                    argument, constraint, context.st)
                if not satisfied then
                    checker.typeerror(context.errors,
                        root.loc or entry.loc or context.loc,
                        "type argument %d ('%s') for %s does not satisfy constraint '%s'",
                        index, types.tostring(argument),
                        entry.subject or context.subject,
                        types.tostring(constraint))
                    valid = false
                end
            end
        end
    end
    context.valid = valid
    context.closed = true
    context.closing = false
    for _, use in ipairs(context.roots) do
        generic_finalize_inference_use(use)
    end
    generic_assert_inference_derived_nodes_closed(context)
    return valid
end

function generic_unify_adjusted_inference(
        context, pattern, target, term, loc)
    -- Ordinary argument/result sinks may add or remove one outer Option
    -- around a structured type. Use its base as boundary evidence, while keeping
    -- a direct binder authoritative (`T` itself still binds to `X?`).  The
    -- eventual ordinary assignment check remains responsible for admitting
    -- the actual option conversion.
    local direct = generic_inference_cell(context, pattern)
    local ok
    if not direct and pattern and target then
        if pattern._tag ~= "Type.Option"
           and target._tag == "Type.Option" then
            ok = generic_unify_inference(
                context, pattern, target.base, term, loc)
        elseif pattern._tag == "Type.Option"
           and target._tag ~= "Type.Option"
           and target._tag ~= "Type.Nil" then
            ok = generic_unify_inference(
                context, pattern.base, target, term, loc)
        end
    end
    if ok == nil then
        ok = generic_unify_inference(
            context, pattern, target, term, loc)
    end
    generic_infer_constraint_evidence(context)
    return ok
end

function generic_infer_result_evidence(context, signature, demand)
    for index, target in ipairs(demand.fixed or {}) do
        target = expected_type(target)
        if target then
            local pattern = signature.rettypes[index]
            if not pattern and signature.flexrettype then
                pattern = optionize(signature.flexrettype)
            end
            if pattern then
                generic_unify_adjusted_inference(context, pattern, target,
                    "expected result " .. index, demand.loc or context.loc)
            end
        end
    end
    local tail = expected_type(demand.tail)
    if tail then
        for index = #(demand.fixed or {}) + 1, #signature.rettypes do
            generic_unify_adjusted_inference(context,
                signature.rettypes[index], tail,
                "expected open result", demand.loc or context.loc)
        end
        if signature.flexrettype then
            generic_unify_adjusted_inference(context,
                signature.flexrettype, tail,
                "expected open result", demand.loc or context.loc)
        end
    end
end

-- Static expected-result context is intentionally a distinct phase boundary.
-- It has no run-time evaluation and currently selects open callable-local cells
-- after the callee/receiver but before evaluated arguments. Keep this policy
-- isolated here while its precedence remains an explicit language-design choice.
function generic_infer_static_result_context(
        context, signature, demand)
    generic_infer_result_evidence(context, signature, demand)
end

function generic_lambda_full_explicit_type(node)
    local nparams = #node.params
    local vararg = node.params[nparams]
    local has_vararg = vararg and vararg.name == nil
    local nfixed = has_vararg and nparams - 1 or nparams
    local params = {}
    for index = 1, nfixed do
        local typ = node.params[index]._generic_inference_type
        if not typ then return nil end
        params[index] = typ
    end
    local varargtype = nil
    if has_vararg then
        varargtype = vararg._generic_inference_type
        if not varargtype then return nil end
    end
    if type(node.rettypes) ~= "table"
       or node._generic_inference_rettypes == nil then
        return nil
    end
    return types.Function(params, node._generic_inference_rettypes,
        false, varargtype, node._generic_inference_flexrettype)
end

function generic_prepare_lambda_inference(node, pattern,
                                                   context, st, errors)
    local nparams = #node.params
    local vararg = node.params[nparams]
    local has_vararg = vararg and vararg.name == nil
    local nfixed = has_vararg and nparams - 1 or nparams
    for index = 1, nfixed do
        local parameter = node.params[index]
        if parameter.type and not parameter._generic_inference_type then
            parameter._generic_inference_type =
                typefromnode(parameter.type, st, errors)
        end
    end
    if has_vararg and vararg.type and not vararg._generic_inference_type then
        vararg._generic_inference_type = check_varg_elem(
            typefromnode(vararg.type, st, errors), vararg.loc,
            errors, "parameter")
    end
    if type(node.rettypes) == "table"
       and node._generic_inference_rettypes == nil then
        node._generic_inference_rettypes = {}
        for index, typenode in ipairs(node.rettypes) do
            node._generic_inference_rettypes[index] =
                typefromnode(typenode, st, errors)
        end
        node._generic_inference_flexrettype = node.flexrettype
            and check_varg_elem(typefromnode(node.flexrettype, st, errors),
                node.flexrettype.loc or node.loc, errors, "return")
            or nil
    end

    local current = generic_substitute_inference(
        context, pattern, false)
    local cell = current._tag == "Type.Parameter"
        and generic_inference_cell(context, current) or nil
    if cell then
        local explicit = generic_lambda_full_explicit_type(node)
        if explicit then
            generic_bind_inference_cell(context, cell, explicit,
                "explicit lambda signature", node.loc)
            generic_infer_constraint_evidence(context)
        end
        return
    end
    if current._tag ~= "Type.Function" or #current.params ~= nfixed then
        return
    end

    for index = 1, nfixed do
        local actual = node.params[index]._generic_inference_type
        if actual then
            generic_unify_inference(context,
                current.params[index], actual,
                "lambda parameter " .. index, node.params[index].loc)
        end
    end
    if has_vararg and vararg._generic_inference_type
       and current.varargtype ~= nil then
        generic_unify_inference(context,
            current.varargtype, vararg._generic_inference_type,
            "lambda variadic parameter", vararg.loc)
    end
    if node._generic_inference_rettypes
       and #node._generic_inference_rettypes == #current.rettypes then
        for index, actual in ipairs(node._generic_inference_rettypes) do
            generic_unify_inference(context,
                current.rettypes[index], actual,
                "lambda result " .. index, node.loc)
        end
        if node._generic_inference_flexrettype ~= nil
           and current.flexrettype ~= nil then
            generic_unify_inference(context,
                current.flexrettype, node._generic_inference_flexrettype,
                "lambda flexible result", node.loc)
        end
    end
    generic_infer_constraint_evidence(context)
end

function generic_formal_pattern(signature, index)
    return signature.params[index] or signature.varargtype or nil
end

function generic_expression_result_types(exp)
    if exp._tag == "Ast.ExpCall" then
        return exp._visible_types or exp._types or {},
            exp._open_results and exp._open_results.source_type or nil
    end
    return { exp._type }, nil
end

function generic_contextual_record_constructor_evidence(
        context, pattern, exp, evidence)
    -- A record initializer has no independent nominal owner: its expected type
    -- selects the record, and the initializer itself builds that non-Option
    -- record. If the surrounding generic pattern has already closed to exactly
    -- one ordinary Option away, keep that outer pattern as the invariant
    -- evidence and let the final argument edge own the wrap/force adjustment.
    -- Arrays and Maps remain ordinary structural evidence, as do every
    -- nonconstructor expression and every difference beyond one outer Option.
    if not pattern or not exp or exp._tag ~= "Ast.ExpInitList"
       or not evidence then
        return evidence
    end
    evidence = types.normalize(evidence)
    if not evidence then return evidence end
    local nominal = evidence._tag == "Type.Option"
        and evidence.base or evidence
    if nominal._tag ~= "Type.Nominal" then return evidence end
    local owner = types.registry[nominal.fqtn]
    if not owner or owner._tag ~= "Type.Record" then return evidence end

    local expected = types.normalize(
        generic_substitute_inference(context, pattern, false))
    if not expected then return evidence end
    local one_option_apart =
        (expected._tag == "Type.Option"
            and types.equals(expected.base, evidence))
        or (evidence._tag == "Type.Option"
            and types.equals(evidence.base, expected))
    if not one_option_apart then return evidence end
    return expected
end

function generic_unify_expression_results(context, signature, exp,
                                                first, term)
    local results, open = generic_expression_result_types(exp)
    local index = first
    for _, actual in ipairs(results) do
        local pattern = generic_formal_pattern(signature, index)
        if pattern then
            actual = generic_contextual_record_constructor_evidence(
                context, pattern, exp, actual)
            generic_unify_adjusted_inference(context, pattern, actual,
                term .. " " .. index, exp.loc)
        end
        index = index + 1
    end
    if open and signature.varargtype then
        generic_unify_adjusted_inference(context,
            signature.varargtype, open, term .. " open tail", exp.loc)
    end
end

function generic_inference_expression_context(context, pattern, exp)
    local expected = pattern
        and generic_closed_inference_pattern(context, pattern)
        or nil
    -- Brace constructors can preserve an unresolved structural owner without
    -- committing any ordinary adjustment. Their AST-owned operation finalizer
    -- substitutes that provisional context after every sibling has contributed
    -- evidence. Other expressions continue to receive only closed contexts.
    if not expected and pattern and exp._tag == "Ast.ExpInitList" then
        expected = generic_substitute_inference(
            context, pattern, false)
    end
    return expected
end

function generic_discovery_demand(context, signature, first, original)
    local fixed, inference_fixed = {}, {}
    for offset = 1, #(original.fixed or {}) do
        local pattern = generic_formal_pattern(
            signature, first + offset - 1)
        local closed = pattern and
            generic_closed_inference_pattern(context, pattern)
        fixed[offset] = closed or UNKNOWN_SLOT
        inference_fixed[offset] = pattern and
            generic_substitute_inference(context, pattern, false)
            or nil
    end
    local tail, inference_tail = nil, nil
    if original.tail then
        local pattern = signature.varargtype
        local closed = pattern and
            generic_closed_inference_pattern(context, pattern)
        tail = closed or INFER_OPEN
        inference_tail = pattern and
            generic_substitute_inference(context, pattern, false)
            or nil
    end
    return result_demand(fixed, tail, {
        term = original.term,
        loc = original.loc,
        suppress_flex_cap = original.suppress_flex_cap,
        inference_fixed = inference_fixed,
        inference_tail = inference_tail,
    })
end

function generic_finalize_adjustment_annotation(
        operation, adjustment)
    return generic_finalize_inference_annotation(
        operation, adjustment, true)
end

function generic_refresh_finalized_argument_projections(adjusted, context)
    -- A scalar derived expression (field/index/bound method/parentheses) can
    -- retain its original AST identity while postorder finalization replaces
    -- only checker-owned annotations. Keep the owning expression-list aliases
    -- synchronized before classifying its final sink adjustment.
    for index = 1, #adjusted.fixed do
        local exp = adjusted.fixed[index]
        local delivered = exp._demand_slot == index and exp or nil
        if not delivered then
            for _, candidate in ipairs(adjusted.exps) do
                if candidate._demand_slot == index then
                    delivered = candidate
                    break
                end
            end
        end
        if delivered and delivered ~= exp then adjusted.fixed[index] = delivered end
    end
    for index, exp in ipairs(adjusted.tail_scalars) do
        local delivered = exp._demand_tail and exp or nil
        if not delivered then
            for _, candidate in ipairs(adjusted.exps) do
                if candidate._demand_tail then
                    delivered = candidate
                    break
                end
            end
        end
        if delivered and delivered ~= exp then
            adjusted.tail_scalars[index] = delivered
        end
    end

    -- A spread carrier likewise snapshots its nested subject's provisional
    -- element. Close that descriptor once, then refresh every shared finite
    -- projection before the parent classifies its final adjustment.
    local function spread_projection(exp)
        while exp and exp._tag == "Ast.ExpCast"
              and exp._implicit_coercion do
            exp = exp.exp
        end
        return exp and exp._tag == "Ast.ExpSpreadIndex" and exp or nil
    end
    for _, exp in ipairs(adjusted.exps) do
        if exp._tag == "Ast.ExpSpread" then
            local elem = refresh_spread_subject_force(exp, context)
            if not elem then
                elem = context and generic_substitute_inference(
                    context, exp._spread_elem, true) or exp._spread_elem
            end
            refresh_spread_element_annotations(exp, elem)
        end
    end
    for _, exp in ipairs(adjusted.exps) do
        local projection = spread_projection(exp)
        if projection then
            projection._type = projection.spread._spread_optional_type
        end
    end

    -- A trailing child call is checked once while its generic occurrence is
    -- still open. `adjust_explist` consequently snapshots its finite extras and
    -- open element type before postorder finalization closes that child. Refresh
    -- only those checker-synthesized projections from the finalized call; the
    -- written call and its argument subtree remain checked exactly once.
    for _, exp in ipairs(adjusted.exps) do
        if exp._tag == "Ast.ExpExtra"
           and exp.exp._tag == "Ast.ExpCall" then
            local producer = exp.exp
            local typ = producer._visible_types
                and producer._visible_types[exp.index]
            if typ then
                exp._type = typ
                local source = producer._result_sources
                    and producer._result_sources[exp.index]
                exp._result_source = source
                exp._from_flex = source and source.kind == "flex" or nil
                exp._possibly_absent = source and source.may_absent or nil
            end
        end
    end

    local source = adjusted.open_source
    local open = open_source_descriptor(source)
    if open then
        adjusted.open_type = open.source_type
    end
end

function generic_finish_generic_open_arguments(adjusted, target, st, errors,
                                             term)
    if not adjusted.open_source then return end
    adjusted.open_target = target
    local allow = adjusted.open_source._tag ~= "Ast.ExpDots"
    local adjustment, interface_conversion, interface_failure =
        checker_assignment_adjustment(adjusted.open_type, target, st, {
            allow_coercion = allow,
        })
    adjusted.open_adjustment = adjustment or nil
    adjusted.open_callable_adapter = adjustment
        and adjustment.kind == "callable"
        and checker.freeze_callable_adapter(adjustment,
            adjusted.open_type, target, adjusted.open_source.loc)
        or nil
    adjusted.open_interface_conversion = interface_conversion or nil
    local open = open_source_descriptor(adjusted.open_source)
    if open then
        open.target_type = target
        open.adjustment = adjusted.open_adjustment
        open.callable_adapter = adjusted.open_callable_adapter
    end
    if not adjustment
       and adjusted.open_type._tag ~= "Type.Invalid"
       and target._tag ~= "Type.Invalid" then
        if not report_interface_failure(
                errors, adjusted.open_source.loc, interface_failure) then
            checker.typeerror(errors, adjusted.open_source.loc,
                "open argument element type %s is not compatible with %s element type %s",
                types.tostring(adjusted.open_type), term,
                types.tostring(target))
        end
    end
end

function generic_close_generic_adjusted_arguments(
        context, node, adjusted, args, signature, st, errors, term)
    generic_refresh_finalized_argument_projections(adjusted, context)
    for index = 1, #adjusted.fixed do
        local exp = adjusted.fixed[index]
        local target = signature.params[index]
        if target and target._tag ~= "Type.Invalid"
           and exp._type._tag ~= "Type.Invalid" then
            local source = exp
            local replacement = coerce_and_check(exp, target,
                "argument " .. index .. " of " .. term,
                errors, exp.loc)
            replace_adjusted_value(adjusted, source, replacement)
            for position, argument in ipairs(args) do
                if argument == source then args[position] = replacement end
            end
        end
    end
    if signature.varargtype then
        for _, exp in ipairs({ table.unpack(adjusted.tail_scalars) }) do
            if signature.varargtype._tag ~= "Type.Invalid"
               and exp._type._tag ~= "Type.Invalid" then
                local replacement = coerce_and_check(exp, signature.varargtype,
                    "variadic argument of " .. term, errors, exp.loc)
                replace_adjusted_value(adjusted, exp, replacement)
            end
        end
        generic_finish_generic_open_arguments(adjusted, signature.varargtype,
            st, errors, term)
    end
    for index = #args, 1, -1 do args[index] = nil end
    for _, exp in ipairs(adjusted.exps) do args[#args + 1] = exp end

    -- annotate_call_arguments copies the adjusted open-run descriptor for the
    -- coder.  An inherited operation may already have made that copy before
    -- its postorder close substituted a dependent producer/target/plan, so
    -- refresh every copied field from the now-final adjusted record.
    annotate_call_arguments(node, adjusted)
end

function generic_is_generic_first_class_expression(
        exp, st, errors, context)
    if exp._tag ~= "Ast.ExpVar" then return false end
    if exp.var._tag == "Ast.VarName" then
        local declaration = st:find_symbol(exp.var.name)
        local declared = declaration and declaration._type
        if not declared or declared._tag ~= "Type.FunctionScheme" then
            return false
        end
    end
    generic_precheckvar_for_expression(
        exp, st, errors, context)
    if exp.var._decl then exp.var._decl._used = true end
    exp._type = exp.var._type
    return exp._type._tag == "Type.FunctionScheme"
        or (exp._type._tag == "Type.Function"
            and exp.var._generic_declaration ~= nil)
end

function generic_resolve_deferred_generic_arguments(
        context, deferred, st, errors, label)
    -- A generic declaration contributes a fresh function-shaped occurrence to
    -- the ambient context. A complete outer pattern supplies immediate
    -- evidence; otherwise its local cells remain equated with the outer cells
    -- until the owning use closes them together. Lambdas remain deferred
    -- because v1 never infers their missing annotations from the body.
    for _, item in ipairs(deferred) do
        if item.exp._tag ~= "Ast.ExpFunction" then
            local expected = generic_closed_inference_pattern(
                context, item.pattern)
            checkexp(item.exp, st, errors, expected,
                result_demand({ expected or UNKNOWN_SLOT }, false, {
                    term = label,
                }))
            generic_unify_adjusted_inference(context, item.pattern,
                item.exp._type, label, item.exp.loc)
            item.checked = true
        end
    end
end

function generic_infer_positional_call(context, signature, args,
                                                st, errors, term,
                                                nominal_constructor)
    local deferred, deferred_by_exp = {}, {}
    local consumed_results, consumed_open = {}, {}
    local consumed_spreads = {}

    local fixed = {}
    for index = 1, #signature.params do fixed[index] = UNKNOWN_SLOT end
    local adjusted = adjust_explist(args,
        result_demand(fixed,
            signature.varargtype and INFER_OPEN or nil, {
            term = term,
            open_term = term,
            loc = context.loc,
            missing = "nil",
            explicit_surplus = "discard",
            defer_open_check = true,
            check_expression = function(exp, est, eerrors, _, subdemand,
                                        sink_index)
                local pattern = generic_formal_pattern(
                    signature, sink_index)
                local expected = pattern and
                    generic_inference_expression_context(
                        context, pattern, exp) or nil

                -- Eligibility probing is itself a descent through a possibly
                -- computed expression. Do it at this written argument's slot,
                -- never in an up-front scan that would visit later arguments
                -- before earlier ones.
                local contextual = pattern
                    and exp._tag == "Ast.ExpFunction"
                if contextual then
                    generic_prepare_lambda_inference(
                        exp, pattern, context, est, eerrors)
                    local item = { exp = exp, pattern = pattern }
                    deferred[#deferred + 1] = item
                    deferred_by_exp[exp] = item
                    exp._type = generic_closed_inference_pattern(
                        context, pattern) or types.Invalid()
                    return
                end

                local demand = generic_discovery_demand(
                    context, signature, sink_index, subdemand)
                checker._nominal_argument_demand(
                    demand, nominal_constructor, sink_index)
                checkexp(exp, est, eerrors, expected, demand)
                generic_unify_expression_results(
                    context, signature, exp, sink_index, "argument")
                local results, open =
                    generic_expression_result_types(exp)
                consumed_results[exp] = #results
                if open then consumed_open[exp] = true end
            end,
            check_spread = function(spread, _, _, first_index)
                local elem = spread._spread_elem
                local finite = spread._spread_optional_type
                for index = first_index, #signature.params do
                    local pattern = signature.params[index]
                    generic_unify_adjusted_inference(context, pattern, finite,
                        "spread argument " .. index, spread.loc)
                end
                if signature.varargtype then
                    generic_unify_adjusted_inference(context,
                        signature.varargtype, elem,
                        "open spread argument", spread.loc)
                end
                elem = generic_substitute_inference(
                    context, elem, false)
                refresh_spread_element_annotations(spread, elem)
                consumed_spreads[spread] = true
                return elem
            end,
        }), st, errors)

    local function consumed_spread_projection(exp)
        while exp and exp._tag == "Ast.ExpCast"
              and exp._implicit_coercion do
            exp = exp.exp
        end
        return exp and exp._tag == "Ast.ExpSpreadIndex"
            and consumed_spreads[exp.spread] or false
    end

    local function already_consumed(exp)
        local source = exp._tag == "Ast.ExpExtra" and exp.exp or exp
        local result_index = exp._tag == "Ast.ExpExtra" and exp.index or 1
        return consumed_results[source]
            and result_index <= consumed_results[source]
    end

    -- Written expressions already contributed in lexical order above. This
    -- dense pass is for checker-synthesized nil fills and dots projections; keep
    -- it in delivered slot order as well.
    for index = 1, #adjusted.fixed do
        local exp = adjusted.fixed[index]
        local pattern = generic_formal_pattern(
            signature, index)
        if pattern and not deferred_by_exp[exp]
           and not consumed_spread_projection(exp)
           and not already_consumed(exp) then
            local evidence =
                generic_contextual_record_constructor_evidence(
                    context, pattern, exp, exp._type)
            generic_unify_adjusted_inference(context, pattern,
                evidence, "argument " .. index, exp.loc)
        end
    end
    for _, exp in ipairs(adjusted.tail_scalars) do
        if signature.varargtype and not deferred_by_exp[exp]
           and not already_consumed(exp) then
            local evidence =
                generic_contextual_record_constructor_evidence(
                    context, signature.varargtype, exp, exp._type)
            generic_unify_adjusted_inference(context,
                signature.varargtype, evidence,
                "variadic argument", exp.loc)
        end
    end
    if adjusted.open_source and signature.varargtype
       and not consumed_spreads[adjusted.open_source]
       and not consumed_open[adjusted.open_source] then
        generic_unify_adjusted_inference(context,
            signature.varargtype, adjusted.open_type,
            "open variadic argument", adjusted.open_source.loc)
    end

    generic_infer_constraint_evidence(context)
    generic_resolve_deferred_generic_arguments(
        context, deferred, st, errors, "generic function argument")
    return adjusted, deferred
end

function generic_decl_paramnames(node)
    local variable = node.exp._tag == "Ast.ExpVar" and node.exp.var or nil
    local declaration = variable and variable._decl or nil
    if not declaration then return nil end
    if declaration._tag == "Ast.TopLevelFunc" then
        return declaration._paramnames
    elseif declaration._tag == "Type.StaticMethod"
        or declaration._tag == "Type.Method" then
        return declaration.paramnames
    elseif declaration._tag == "Type.ModuleMember" then
        return declaration.paramnames
    end
end

function generic_infer_named_call(context, signature, fields,
                                  paramnames, st, errors, term, declaration,
                                  nominal_constructor)
    if type(paramnames) ~= "table" then
        for _, field in ipairs(fields) do checkexp(field.exp, st, errors) end
        return { unavailable = true, fields = fields }
    end
    local byname = {}
    for index, name in ipairs(paramnames) do byname[name] = index end
    local deferred, supplied, checked = {}, {}, {}

    for _, field in ipairs(fields) do
        local index = byname[field.name]
        if not index then
            checker.typeerror(errors, field.loc,
                "%s has no parameter named '%s'%s", term, field.name,
                #paramnames > 0 and
                    ("; available parameters are " .. table.concat(paramnames, ", "))
                    or "")
            checkexp(field.exp, st, errors)
        else
            local pattern = signature.params[index]
            field._decl = named_parameter_declaration(
                declaration, index, field.name)
            local expected = generic_inference_expression_context(
                context, pattern, field.exp)
            if field.exp._tag == "Ast.ExpFunction" then
                generic_prepare_lambda_inference(
                    field.exp, pattern, context, st, errors)
                deferred[#deferred + 1] = {
                    exp = field.exp,
                    pattern = pattern,
                }
            else
                local provisional = not expected and
                    generic_substitute_inference(
                        context, pattern, false) or nil
                checkexp(field.exp, st, errors, expected,
                    checker._nominal_argument_demand(result_demand(
                        { expected or UNKNOWN_SLOT }, false, {
                        term = "named generic argument",
                        inference_fixed = { provisional },
                    }), nominal_constructor, index))
                local evidence =
                    generic_contextual_record_constructor_evidence(
                        context, pattern, field.exp, field.exp._type)
                generic_unify_adjusted_inference(context, pattern,
                    evidence, "named argument '" .. field.name .. "'",
                    field.loc)
            end
            checked[field] = index
            if supplied[index] then
                checker.typeerror(errors, field.loc,
                    "named argument '%s' is supplied more than once", field.name)
            else
                supplied[index] = field
            end
        end
    end
    for index, name in ipairs(paramnames) do
        if not supplied[index] then
            generic_unify_adjusted_inference(context,
                signature.params[index], types.Nil(),
                "omitted named argument '" .. name .. "'", context.loc)
        end
    end

    generic_infer_constraint_evidence(context)
    generic_resolve_deferred_generic_arguments(
        context, deferred, st, errors, "named generic function argument")
    return {
        fields = fields,
        paramnames = paramnames,
        deferred = deferred,
        supplied = supplied,
        checked = checked,
    }
end

function generic_close_deferred_generic_arguments(
        context, deferred, st, errors)
    for _, item in ipairs(deferred or {}) do
        if not item.checked then
            local expected = generic_substitute_inference(
                context, item.pattern, true)
            checkexp(item.exp, st, errors, expected,
                result_demand({ expected }, false, {
                    term = "contextual generic argument",
                }))
            item.checked = true
        end
    end
end

function generic_close_named_inference_plan(
        context, plan, closed, st, errors, term)
    if plan.unavailable then return nil, nil end
    generic_close_deferred_generic_arguments(
        context, plan.deferred, st, errors)

    local dense, order = {}, {}
    for _, field in ipairs(plan.fields) do
        local index = plan.checked[field]
        if index then
            local replacement = coerce_and_check(field.exp,
                closed.params[index],
                "named argument '" .. field.name .. "' of " .. term,
                errors, field.loc)
            if plan.supplied[index] == field then
                dense[index] = replacement
                order[#order + 1] = index
            end
        end
    end
    for index, name in ipairs(plan.paramnames) do
        if not dense[index] then
            local exp = ast.ExpNil(context.loc)
            exp._type = types.Nil()
            exp._missing_value = true
            exp = coerce_and_check(exp, closed.params[index],
                "omitted named argument '" .. name .. "' of " .. term,
                errors, context.loc)
            exp._named_omitted = true
            dense[index] = exp
        end
    end
    return dense, order
end

function generic_infer_call_application(context, use, signature, node,
                                                  demand, st, errors, term,
                                                  paramnames)
    local named = node.args._tag == "Ast.ArgsNamedFunc"
        or node.args._tag == "Ast.ArgsNamedMethod"
    local named_plan, adjusted, deferred
    generic_with_inference_use(context, use, st, function()
        generic_infer_static_result_context(
            context, signature, demand)
        if named then
            named_plan = generic_infer_named_call(
                context, signature, node.args.fields,
                paramnames or generic_decl_paramnames(node),
                st, errors, term, named_call_declaration(node),
                node._nominal_constructor)
        else
            adjusted, deferred = generic_infer_positional_call(
                context, signature, node.args.args, st, errors, term,
                node._nominal_constructor)
            node._generic_arg_adjustment = adjusted
        end
    end)

    use.signature = signature
    generic_add_inference_finalizer(use, function()
        local closed = generic_substitute_inference(
            context, signature, true)
        use.closed = closed
        if named then
            local dense, order = generic_close_named_inference_plan(
                context, named_plan, closed, st, errors, term)
            node._generic_named_dense = dense
            node._generic_named_order = order
            node._generic_named_pending = nil
            -- An inherited use has already returned through its ExpCall visitor;
            -- finish the declaration-only named lowering here. The owning use
            -- closes before that visitor resumes and follows the ordinary path.
            if dense and not use.owns_context then
                local args = node.args
                local method = args._tag == "Ast.ArgsNamedMethod"
                node._surface_named_args = args.fields
                node.args = method
                    and ast.ArgsMethod(args.loc, args.method, dense)
                    or ast.ArgsFunc(args.loc, dense)
                if method then
                    node.args._name_loc = args._name_loc
                    node.args._decl = args._decl or use.closed
                end
                node._named_arg_order = order
                node._named_call_kind = "titan"
            end
        else
            generic_close_deferred_generic_arguments(
                context, deferred, st, errors)
            generic_close_generic_adjusted_arguments(
                context, node, adjusted, node.args.args,
                closed, st, errors, term)
        end
    end)

    local provisional = generic_substitute_inference(
        context, signature, false)
    if named and not use.owns_context then
        node._generic_named_pending = true
    end
    return provisional
end

function generic_infer_dependent_call_application(
        operation, signature, node, demand, st, errors, term, paramnames,
        finalize)
    if not operation or node._generic_inference_use
       or not generic_inference_type_has_unresolved(
           operation.context, signature) then
        return signature, false
    end

    assert(operation.node == node)
    assert(not operation.signature,
        "ordinary inference operation registered more than one call plan")
    local provisional = generic_infer_call_application(
        operation.context, operation, signature, node, demand,
        st, errors, term, paramnames)
    operation.dependent = true
    if finalize then
        generic_add_inference_finalizer(operation, function()
            finalize(operation.closed)
        end)
    end
    return provisional, true
end

-- A direct call through `value` has already checked its callee and discovered
-- its argument run exactly once before its contextual function shape exists.
-- When that shape contains ambient cells, keep the zero-binder operation open:
-- later sibling evidence closes the synthesized parameters/results, then this
-- postorder finalizer freezes the ordinary argument edges and callee cast
-- without redispatching any written expression.
function generic_infer_dependent_value_call_application(
        operation, signature, node, adjusted, st, errors, term, finalize)
    if not operation
       or not generic_inference_type_has_unresolved(
           operation.context, signature) then
        return signature, false
    end

    assert(operation.node == node)
    assert(not operation.signature
            and not operation.contextual_value_signature,
        "ordinary inference operation registered more than one call plan")
    operation.contextual_value_signature = signature
    operation.dependent = true
    generic_add_inference_finalizer(operation, function()
        local closed = generic_substitute_inference(
            operation.context, signature, true)
        operation.closed = closed
        generic_close_generic_adjusted_arguments(
            operation.context, node, adjusted, node.args.args,
            closed, st, errors, term)
        finalize(closed)
    end)
    return signature, true
end

function generic_close_inference_declaration(
        context, use, declaration, recover)
    local fresh = generic_freshen_inference_type(
        context, declaration, use.scopes, use.subject, use.loc)
    return generic_substitute_inference(
        context, fresh, recover)
end

function generic_infer_call_use(
        node, subject, scopes, signature, demand, st, errors, paramnames,
        finalize)
    local context, use, owns = generic_acquire_inference_context(
        node, subject, scopes, st, errors, node.loc)
    signature = generic_freshen_inference_type(
        context, signature, use.scopes, subject, node.loc)
    local provisional = generic_infer_call_application(
        context, use, signature, node, demand, st, errors, subject, paramnames)
    if finalize then
        generic_add_inference_finalizer(use, function()
            local arguments = generic_inference_type_arguments(
                context, use.scopes)
            use.arguments = arguments
            finalize(use.closed, arguments, context, use)
        end)
    end
    if owns then generic_close_inference_context(context) end
    return use.closed or provisional, use.arguments, context, use
end

function generic_defer_inherited_interface_finalization(
        node, class, method_name, operation)
    local use = operation or node._generic_inference_use
    if class._tag ~= "Type.Interface" or not use
       or use.owns_context or use.context.closed then
        return
    end
    generic_add_inference_finalizer(use, function()
        local closed_class = generic_substitute_inference(
            use.context, class, true)
        node._interface = closed_class
        node._interface_method = node._method
        node._interface_method_index = assert(interface_method_index(
            closed_class, method_name))
    end)
end

function generic_defer_inherited_call_result_finalization(
        node, demand, operation)
    local use = operation or node._generic_inference_use
    if not use or use.owns_context or use.context.closed then return end
    generic_add_inference_finalizer(use, function()
        local callable = use.closed or node._method or node.exp._type
        annotate_call_results(node, callable, demand, {})
    end)
end

function generic_infer_first_class_application(
        node, subject, scopes, signature, expected, st, errors, loc,
        finalize)
    local context, use, owns = generic_acquire_inference_context(
        node, subject, scopes, st, errors, loc)
    signature = generic_freshen_inference_type(
        context, signature, use.scopes, subject, loc)
    generic_with_inference_use(context, use, st, function()
        if expected then
            generic_unify_inference(context, signature, expected,
                "expected first-class function type", loc)
        end
    end)
    generic_add_inference_finalizer(use, function()
        use.closed = generic_substitute_inference(
            context, signature, true)
        use.arguments = generic_inference_type_arguments(
            context, use.scopes)
    end)
    if finalize then
        generic_add_inference_finalizer(use, function()
            finalize(use.closed, use.arguments, context, use)
        end)
    end
    local provisional = generic_substitute_inference(
        context, signature, false)
    if owns then generic_close_inference_context(context) end
    return use.closed or provisional, use.arguments, context, use
end

function generic_instantiate_first_class_variable(
        node, variable, declared, expected, st, errors)
    if expected and expected._tag == "Type.Option"
       and expected.base._tag == "Type.Function" then
        expected = expected.base
    end
    if expected and expected._tag ~= "Type.Function" then
        expected = nil
    end

    local subject = "generic declaration '" .. variable.name .. "'"
    local scopes, signature, declaration = {}, nil, nil
    if declared._tag == "Type.FunctionScheme" then
        scopes[1] = generic_inference_scope_entry(
            declared.scope, declared.typeparams)
        signature = declared.signature
    elseif declared._tag == "Type.Function" then
        declaration = variable._generic_declaration or variable._decl
        if not declaration or declaration._tag ~= "Type.StaticMethod" then
            return nil
        end
        local owner = variable._generic_owner
            or types.registry[declaration.fqtn]
        local callable = declaration
        if variable._generic_owner_fixed then
            callable = variable._closed_generic_declaration or declaration
        elseif owner and #(owner.typeparams or {}) > 0 then
            scopes[#scopes + 1] = generic_inference_scope_entry(
                owner.scope, owner.typeparams, owner._generic_parameters)
        end
        if #(callable.typeparams or {}) > 0 then
            scopes[#scopes + 1] = generic_inference_scope_entry(
                callable.scope, callable.typeparams)
        end
        if #scopes == 0 and not variable._generic_owner_fixed then return nil end
        signature = generic_callable_function_type(callable)
    else
        return nil
    end

    if declared._tag == "Type.FunctionScheme" then
        node._generic_scheme = declared
    else
        node._generic_declaration = declaration
    end
    local closed = generic_infer_first_class_application(
        node, subject, scopes, signature, expected,
        st, errors, node.loc,
        function(final_type, arguments, context, use)
            node._generic_type_arguments = arguments
            node._type = final_type
            if declaration then
                node._closed_generic_declaration =
                    generic_close_inference_declaration(
                        context, use, declaration, true)
            end
        end)
    return closed
end

function generic_instantiate_function_scheme(
        scheme, typearg_nodes, st, errors, loc, subject)
    local count = #(scheme.typeparams or {})
    local arguments, valid =
        generic_recover_complete_type_arguments(
            typearg_nodes, count, st, errors, loc, subject)
    if valid then
        generic_validate_binder_arguments(scheme.scope,
            scheme.typeparams, arguments, st, errors, loc, subject, false)
    end
    local closed = generic_substitute(
        scheme.signature, scheme.scope, arguments,
        errors, loc, "cannot instantiate " .. subject)
    return closed or scheme.signature, arguments
end

function generic_instantiate_static_declaration(
        declaration, owner, typearg_nodes, st, errors, loc, subject)
    local owner_count = owner and #(owner.typeparams or {}) or 0
    local local_count = #(declaration.typeparams or {})
    local total = owner_count + local_count
    local arguments, valid =
        generic_recover_complete_type_arguments(
            typearg_nodes, total, st, errors, loc, subject)
    local owner_arguments, local_arguments = {}, {}
    for index = 1, owner_count do
        owner_arguments[index] = arguments[index]
    end
    for index = 1, local_count do
        local_arguments[index] = arguments[owner_count + index]
    end

    local closed = declaration
    if owner_count > 0 then
        if valid then
            local owner_valid = generic_validate_binder_arguments(
                owner.scope, owner.typeparams, owner_arguments,
                st, errors, loc, subject, false)
            if owner_valid then
                generic_validate_owner_reconstruction(
                    owner, owner_arguments, st, errors, loc, subject, false)
            end
        end
        closed = generic_substitute(closed, owner.scope, owner_arguments,
            errors, loc, "cannot instantiate " .. subject) or closed
    end
    if local_count > 0 then
        -- Owner substitution also specializes constraints that mention owner
        -- binders, so validate against the fresh method/static view.
        if valid then
            generic_validate_binder_arguments(closed.scope,
                closed.typeparams, local_arguments,
                st, errors, loc, subject, false)
        end
        closed = generic_substitute(closed, closed.scope, local_arguments,
            errors, loc, "cannot instantiate " .. subject) or closed
    end
    return generic_callable_function_type(closed), arguments, closed
end

function generic_instantiate_owner_applied_static(
        node, declaration, closed_owner_declaration, variable,
        st, errors, demand, subject)
    local local_count = #(closed_owner_declaration.typeparams or {})
    local owner_was_written = variable._generic_owner_explicit == true
    local local_was_written = #(node.typeargs or {}) > 0

    if owner_was_written and local_count > 0 and not local_was_written then
        checker.typeerror(errors, node.loc,
            "%s must provide both the owner and callable type argument lists, or infer both",
            subject)
    end

    local closed, local_arguments = closed_owner_declaration, {}
    if local_count > 0 then
        if local_was_written then
            local valid
            local_arguments, valid =
                generic_recover_complete_type_arguments(
                    node.typeargs, local_count, st, errors, node.loc, subject)
            if valid then
                generic_validate_binder_arguments(
                    closed_owner_declaration.scope,
                    closed_owner_declaration.typeparams, local_arguments,
                    st, errors, node.loc, subject, false)
            end
            closed = generic_substitute(
                closed_owner_declaration, closed_owner_declaration.scope,
                local_arguments, errors, node.loc,
                "cannot instantiate " .. subject) or closed_owner_declaration
        elseif not owner_was_written then
            local scopes = { generic_inference_scope_entry(
                closed_owner_declaration.scope,
                closed_owner_declaration.typeparams) }
            node._generic_declaration = declaration
            local signature = generic_infer_call_use(
                node, subject, scopes,
                generic_callable_function_type(
                    closed_owner_declaration), demand, st, errors,
                closed_owner_declaration.paramnames,
                function(final_signature, arguments, context, use)
                    local final_declaration =
                        generic_close_inference_declaration(
                            context, use, closed_owner_declaration, true)
                    node._generic_type_arguments = arguments
                    node._closed_generic_declaration = final_declaration
                    node.exp._type = final_signature
                end)
            node.exp._type = signature
            return signature
        end
    elseif local_was_written then
        checker.typeerror(errors, node.loc,
            "%s has no callable type parameters; attach owner arguments to the nominal namespace",
            subject)
    end

    node._generic_declaration = declaration
    node._generic_type_arguments = local_arguments
    node._closed_generic_declaration = closed
    local signature = generic_callable_function_type(closed)
    node.exp._type = signature
    return signature
end

function generic_instantiate_direct_call(
        node, ftype, st, errors, demand)
    local subject = "call to '" .. expname(node.exp) .. "'"
    if ftype._tag == "Type.FunctionScheme" then
        node._generic_scheme = ftype
        if #(node.typeargs or {}) > 0 then
            local closed, arguments =
                generic_instantiate_function_scheme(
                    ftype, node.typeargs, st, errors, node.loc, subject)
            node._generic_type_arguments = arguments
            node.exp._type = closed
            return closed
        end
        local scopes = { generic_inference_scope_entry(
            ftype.scope, ftype.typeparams) }
        local closed = generic_infer_call_use(
            node, subject, scopes, ftype.signature, demand, st, errors, nil,
            function(final_signature, arguments)
                node._generic_type_arguments = arguments
                node.exp._type = final_signature
            end)
        node.exp._type = closed
        return closed
    end

    local variable = node.exp._tag == "Ast.ExpVar" and node.exp.var or nil
    local declaration = variable and variable._decl or nil
    if declaration and declaration._tag == "Type.StaticMethod" then
        local owner = variable._generic_owner
            or types.registry[declaration.fqtn]
        if variable._generic_owner_fixed then
            local closed_owner = variable._closed_generic_declaration
                or node._closed_generic_declaration or declaration
            return generic_instantiate_owner_applied_static(
                node, declaration, closed_owner, variable,
                st, errors, demand, subject)
        end
        local owner_count = owner and #(owner.typeparams or {}) or 0
        local local_count = #(declaration.typeparams or {})
        local count = owner_count + local_count
        if count > 0 then
            local closed, arguments, closed_declaration
            if #(node.typeargs or {}) > 0 then
                if owner_count > 0 then
                    checker.typeerror(errors, node.loc,
                        "%s cannot receive owner type arguments after the member name; attach them to the nominal namespace",
                        subject)
                end
                closed, arguments, closed_declaration =
                    generic_instantiate_static_declaration(
                        declaration, owner, node.typeargs, st, errors,
                        node.loc, subject)
            else
                local scopes = {}
                if owner_count > 0 then
                    scopes[#scopes + 1] = generic_inference_scope_entry(
                        owner.scope, owner.typeparams,
                        owner._generic_parameters)
                end
                if local_count > 0 then
                    scopes[#scopes + 1] = generic_inference_scope_entry(
                        declaration.scope, declaration.typeparams)
                end
                node._generic_declaration = declaration
                local signature = generic_callable_function_type(
                    declaration)
                closed = generic_infer_call_use(
                    node, subject, scopes, signature, demand, st, errors,
                    declaration.paramnames,
                    function(final_signature, final_arguments, context, use)
                        node._generic_type_arguments = final_arguments
                        node._closed_generic_declaration =
                            generic_close_inference_declaration(
                                context, use, declaration, true)
                        node.exp._type = final_signature
                    end)
                node.exp._type = closed
                return closed
            end
            node._generic_declaration = declaration
            node._generic_type_arguments = arguments
            node._closed_generic_declaration = closed_declaration
            node.exp._type = closed
            return closed
        end
    end

    if #(node.typeargs or {}) > 0 then
        checker.typeerror(errors, node.loc,
            "%s is not generic and cannot receive type arguments", subject)
    end
    return ftype
end

function generic_instantiate_method_declaration(
        node, method, st, errors, owner_name, demand)
    local count = #(method.typeparams or {})
    local subject = "call to method '" .. owner_name .. ":"
        .. node.args.method .. "'"
    if count == 0 then
        if #(node.typeargs or {}) > 0 then
            checker.typeerror(errors, node.loc,
                "%s is not generic and cannot receive type arguments", subject)
        end
        return method
    end

    local closed, arguments
    if #(node.typeargs or {}) > 0 then
        local valid
        arguments, valid =
            generic_recover_complete_type_arguments(
                node.typeargs, count, st, errors, node.loc, subject)
        if valid then
            generic_validate_binder_arguments(method.scope,
                method.typeparams, arguments,
                st, errors, node.loc, subject, false)
        end
        closed = generic_substitute(
            method, method.scope, arguments, errors, node.loc,
            "cannot instantiate " .. subject) or method
    else
        local scopes = { generic_inference_scope_entry(
            method.scope, method.typeparams) }
        local final_method
        node._generic_declaration = method
        local _, _, context = generic_infer_call_use(
            node, subject, scopes,
            generic_callable_function_type(method), demand,
            st, errors, method.paramnames,
            function(_, final_arguments, inference, use)
                final_method = generic_close_inference_declaration(
                    inference, use, method, true)
                node._generic_type_arguments = final_arguments
                node._method = final_method
                if node._interface_method then
                    node._interface_method = final_method
                end
            end)
        closed = final_method or generic_close_inference_declaration(
            context, node._generic_inference_use, method, false)
        return closed
    end
    node._generic_declaration = method
    node._generic_type_arguments = arguments
    return closed
end

return core.checker

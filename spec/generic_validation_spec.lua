local types = require "titan-compiler.types"
local documentation = require "titan-compiler.documentation"
require "titan-compiler.checker"
local core = require "titan-compiler.checker.core"

local function scope(owner, kind)
    return types.GenericScope("validation", owner or "validation.Box", nil,
        "owner", kind or "record")
end

local function rejected_by_both(typ, binder, arguments, message)
    for _, operation in ipairs({types.substitute, types.validate_substitution}) do
        assert.has_error(function() operation(typ, binder, arguments) end, message)
    end
end

local function without_constructors(fn)
    local previous = {}
    for _, name in ipairs({"Array", "Option", "Map", "Function", "Parameter",
        "Field", "Variant", "Method", "StaticMethod", "Record", "Union",
        "Interface", "ModuleMember", "ModuleVariable", "Module", "TypeParameter",
        "FunctionScheme", "GenericAlias", "Nominal"}) do
        previous[name] = types[name]
        types[name] = function() error("validation constructed " .. name, 0) end
    end
    local copy, copy_map = documentation.copy, documentation.copy_map
    documentation.copy = function() error("validation copied documentation", 0) end
    documentation.copy_map = documentation.copy
    local ok, err = pcall(fn)
    for name, constructor in pairs(previous) do types[name] = constructor end
    documentation.copy, documentation.copy_map = copy, copy_map
    if not ok then error(err, 0) end
end

describe("generic substitution validation", function()
    local previous_registry
    before_each(function()
        previous_registry = types.registry
        types.registry = {}
    end)
    after_each(function() types.registry = previous_registry end)

    it("validates owner graphs without constructing their result or copying docs", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 1, "T", nil)
        local field = types.Field("validation.Box", "item",
            types.Array(types.Option(parameter), {tag = "no"}), 0, false)
        local method = types.Method("validation.Box", "map", {
            types.Map(types.String(), parameter),
        }, {types.Nominal("validation.Box", {parameter})}, nil, nil, {"item"})
        local owner = types.Record("validation.Box", {field}, {}, {
            map = method,
        }, 1, binder, {types.TypeParameter("T", nil)})
        local variant = types.Variant("validation.Choice", "Item", {
            types.Field("validation.Choice", "item", parameter, 1, false),
        }, 0)
        local union = types.Union("validation.Choice", {variant}, {}, {}, 1,
            binder, {types.TypeParameter("T", nil)})
        local interface = types.Interface("validation.View", {
            types.Field("validation.View", "item", parameter, 0, true),
        }, {})
        local module = types.Module("validation", {
            types.ModuleMember("validation", "Box", owner, nil),
            types.ModuleMember("validation", "Choice", union, nil),
            types.ModuleVariable("validation", "item", parameter, false),
            types.ModuleMember("validation", "identity", types.FunctionScheme(
                binder, {types.TypeParameter("T", nil)},
                types.Function({parameter}, {parameter}, false, nil, nil)), {"item"}),
        }, {
            View = interface,
            Alias = types.GenericAlias("validation", "Alias", false,
                "validation.Box", nil, binder, {types.TypeParameter("T", nil)}),
        })
        local doc = documentation.parse("A documented owner.\n@param item The item.")
        owner._documentation = doc
        owner._type_documentation = {Item = doc}
        field._documentation = doc
        local arguments = {types.Integer()}
        without_constructors(function()
            assert.is_true(types.validate_substitution(module, binder, arguments))
        end)
        assert.equal(doc, owner._documentation)
        assert.equal(doc, field._documentation)
        assert.equal(parameter, field.type.elem.base)
        assert.equal(binder, owner.scope)
        assert.is_nil(types.registry["validation.Box"])
    end)

    it("rejects the same invalid argument lists and transient types", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 1, "T", nil)
        rejected_by_both(parameter, false, {}, "substitution scope must be a GenericScope")
        rejected_by_both(parameter, binder, false, "expected a dense numeric list")
        rejected_by_both(parameter, binder, {[2] = types.Integer()},
            "expected a dense numeric list")
        rejected_by_both(parameter, binder, {named = types.Integer()},
            "expected numeric list keys only")
        rejected_by_both(parameter, binder, {7}, "type argument 1 is not a type")
        local pointer = types.CPointer(types.CInteger("int", true, 3, 32), {})
        rejected_by_both(parameter, binder, {pointer},
            "type argument 1 ('foreign *int') has no sound transient round trip")
        rejected_by_both(parameter, binder, {},
            "missing type argument 1 for " .. types.generic_scope_key(binder))
    end)

    it("retains structural cycle, descriptor and supported tag errors", function()
        local binder = scope()
        rejected_by_both("not a type", binder, {},
            "generic type rewrite expected a Type descriptor")
        rejected_by_both({_tag = "Type.Unknown"}, binder, {},
            "unsupported tag in generic type rewrite: Type.Unknown")
        local cycle = types.Array(types.Integer(), {tag = "no"})
        cycle.elem = cycle
        rejected_by_both(cycle, binder, {},
            "cyclic structural type in generic type rewrite")
        rejected_by_both(types.Function({}, {}, true, nil, nil), binder, {},
            "Type.Function reserved vararg field must be false")
        local malformed = types.Field("validation.Box", "item", types.Integer(), 0, false)
        malformed.isconst = "no"
        rejected_by_both(malformed, binder, {}, "Field const qualifier must be a boolean")
        local variable = types.ModuleVariable("validation", "item", types.Integer(), false)
        variable.isconst = "no"
        rejected_by_both(variable, binder, {}, "ModuleVariable const qualifier must be a boolean")
        local interface = types.Interface("validation.View", {
            types.Field("validation.View", "item", types.Integer(), 0, true),
        }, {})
        interface.fields[1].index = 1
        rejected_by_both(interface, binder, {}, "invalid Interface members: field 'item' " ..
            "has a noncanonical index or const qualifier")
    end)

    it("uses canonical substituted map keys and callable tails", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 1, "T", nil)
        local key = types.Map(types.Option(parameter), types.Integer())
        rejected_by_both(key, binder, {types.Integer()},
            "type of map key cannot be option type")
        assert.is_true(types.validate_substitution(key, binder, {types.Value()}))
        rejected_by_both(types.Map(parameter, types.Integer()), binder,
            {types.Nil()}, "type of map key cannot be nil")
        rejected_by_both(types.Function({}, {}, false, parameter, nil), binder,
            {types.Nil()}, "a variadic parameter cannot have type nil")
        local pointer = types.CTypedef("pointer",
            types.CPointer(types.CInteger("int", true, 3, 32), {}), {})
        rejected_by_both(types.Function({}, {}, false, nil, pointer), binder, {},
            "a flexible return cannot have a foreign pointer type")
        local other_scope = scope("validation.Other")
        local other = types.Parameter(other_scope, 1, "U", parameter)
        local callable = types.Function({}, {}, false, other, nil)
        assert.is_true(types.validate_substitution(callable, binder, {types.Integer()}))
        rejected_by_both(callable, binder, {types.Nil()},
            "a variadic parameter cannot use type U because it has no supported " ..
            "variadic-value representation")
        assert.is_true(types.validate_substitution(
            types.Option(other), binder, {types.Integer()}))
        assert.is_true(types.validate_substitution(
            types.Parameter(other_scope, 1, "U", nil), binder, {}))
    end)

    it("rechecks mutable owners and arguments on every call", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 1, "T", nil)
        local field = types.Field("validation.Box", "item", parameter, 0, false)
        local owner = types.Record("validation.Box", {field}, {}, {}, 1, binder,
            {types.TypeParameter("T", nil)})
        local arguments = {types.Integer()}
        assert.is_true(types.validate_substitution(owner, binder, arguments))
        parameter.index = 2
        rejected_by_both(owner, binder, arguments,
            "missing type argument 2 for " .. types.generic_scope_key(binder))
        parameter.index = 1
        arguments[1] = false
        rejected_by_both(owner, binder, arguments, "type argument 1 is not a type")
    end)

    it("retains documentation admission and canonical collapse behavior", function()
        local binder = scope()
        local owner = types.Record("validation.Box", {}, {}, {}, 0, binder,
            {types.TypeParameter("T", nil)})
        owner._documentation = {summary = "incomplete"}
        rejected_by_both(owner, binder, {types.Integer()}, "invalid documentation metadata")
        owner._documentation = nil
        owner._type_documentation = false
        -- A false metadata attachment is ignored by the existing rewrite.
        assert.is_true(types.validate_substitution(owner, binder, {types.Integer()}))
        owner._type_documentation = {[1] = documentation.parse("Item.")}
        rejected_by_both(owner, binder, {types.Integer()}, "invalid type documentation name")
        local option = types.Option(types.Parameter(binder, 1, "T", nil))
        option._documentation = {summary = "ignored on canonical collapse"}
        assert.is_true(types.validate_substitution(option, binder, {types.Value()}))
        rejected_by_both(option, binder, {types.Integer()}, "invalid documentation metadata")
    end)

    it("keeps recovered constraint substitution and visibility checks independent", function()
        local binder = scope()
        local constraint = types.Nominal("validation.Renderable")
        local method = types.Method("validation.Private", "render", {},
            {types.String()}, nil, nil, {})
        method.islocal = true
        types.registry["validation.Private"] = types.Record(
            "validation.Private", {}, {}, {render = method}, 0)
        types.registry["validation.Renderable"] = types.Interface(
            "validation.Renderable", {}, {
                types.Method("validation.Renderable", "render", {},
                    {types.String()}, nil, nil, {}),
            })
        local owner = types.Record("validation.Box", {}, {}, {}, 0, binder,
            {types.TypeParameter("T", constraint)})
        local nominal = types.Nominal("validation.Box", {
            types.Nominal("validation.Private"),
        })
        local private = {visibility = "validation",
            method_visible = function() return true end,
            field_visible = function() return true end}
        local public = {visibility = "consumer",
            method_visible = function(member) return not member.islocal end,
            field_visible = function(member) return not member.islocal end}
        assert.is_true(core.generic_validate_recovered_application(nominal, owner, private))
        local ok, err = core.generic_validate_recovered_application(nominal, owner, public)
        assert.is_nil(ok)
        assert.match("does not satisfy constraint 'validation.Renderable'", err, 1, true)
        assert.is_true(core.generic_validate_recovered_application(nominal, owner, private))
        local malformed = types.Array(types.Integer(), {tag = "no"})
        malformed.elem = malformed
        owner.typeparams[1].constraint = malformed
        ok, err = core.generic_validate_recovered_application(nominal, owner, private)
        assert.is_nil(ok)
        assert.match("constraint 1 could not be reconstructed", err, 1, true)
    end)

    it("does not decorate arguments used by consumed callable projections", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 1, "T", nil)
        parameter.source_marker = "declaration-only"
        local other = types.Parameter(scope("validation.Other"), 1, "U", nil)
        local callable = types.Function({}, {}, false, parameter, nil)
        assert.is_true(types.validate_substitution(callable, binder, {other}))
        assert.is_nil(other.source_marker)
        local argument = types.Option(types.Integer())
        local option = types.Option(parameter)
        option.source_marker = "option-only"
        callable.varargtype = option
        assert.is_true(types.validate_substitution(callable, binder, {argument}))
        assert.is_nil(argument.source_marker)
    end)

    it("validates recovered owners without substituting their discarded result", function()
        local binder = scope()
        local owner = types.Record("validation.Box", {}, {}, {}, 0, binder,
            {types.TypeParameter("T", nil)})
        local nominal = types.Nominal("validation.Box", {types.Integer()})
        local original = types.substitute
        types.substitute = function() error("discarded owner substitution", 0) end
        local called, valid, err = pcall(
            core.generic_validate_recovered_application, nominal, owner, {})
        types.substitute = original
        assert.is_true(called, tostring(valid))
        assert.is_true(valid, err)
    end)

    it("retains recovered canonical application diagnostics", function()
        local binder = scope()
        local parameter = types.Parameter(binder, 2, "T", nil)
        local field = types.Field("validation.Box", "item", parameter, 0, false)
        local owner = types.Record("validation.Box", {field}, {}, {}, 1, binder,
            {types.TypeParameter("T", nil)})
        local nominal = types.Nominal("validation.Box", {types.Integer()})
        local function rejected(message)
            local ok, err = core.generic_validate_recovered_application(nominal, owner, {})
            assert.is_nil(ok)
            assert.match("is not a canonical application:", err, 1, true)
            assert.match(message, err, 1, true)
        end
        rejected("missing type argument 2")
        parameter.index = 1
        local cycle = types.Option(types.Integer())
        cycle.base = cycle
        field.type = cycle
        rejected("cyclic structural type in generic type rewrite")
        field.type = {_tag = "Type.Unknown"}
        rejected("unsupported tag in generic type rewrite: Type.Unknown")
        field.type = parameter
        owner.scope = types.Integer()
        rejected("substitution scope must be a GenericScope")
    end)
end)

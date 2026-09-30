local types = require "titan-compiler.types"
local compat = require "titan-compiler.binarycompat"

local function func(name, params, results, paramnames, tail, flexible)
    return types.ModuleMember("provider", name,
        types.Function(params or {}, results or {}, false,
            tail, flexible), paramnames or {})
end

local function field(owner, name, typ, index, private, const)
    local result = types.Field(owner, name, typ, index, const == true)
    result.islocal = private == true
    return result
end

local function method(owner, name, typ, parameter, private)
    local result = types.Method(owner, name, {typ}, {types.Integer()},
        nil, nil, {parameter or "item"})
    result.islocal = private == true
    return result
end

local function owner_module(owner, extras, aliases)
    local members = { types.ModuleMember("provider", "Item", owner, nil) }
    for _, extra in ipairs(extras or {}) do members[#members + 1] = extra end
    return types.Module("provider", members, aliases or {})
end

local function module(members, aliases)
    return types.Module("provider", members or {}, aliases or {})
end

local function checker(modtype, usage, registry)
    local expected = compat.requirements(modtype, registry or {}, usage)
    local source = compat.verifier(expected, "consumer", modtype.name)
    return assert(load(source, "compatibility verifier", "t", {
        type = type, next = next, error = error,
    }))(), expected, source
end

local function check_metadata(modtype, registry)
    return compat.module(modtype, registry or {})
end

local function reject(verify, metadata, fragment)
    local ok, err = pcall(verify, metadata)
    assert.is_false(ok)
    assert.is_string(err)
    assert.truthy(err:find("binary compatibility mismatch importing 'provider' from 'consumer':", 1, true), err)
    assert.truthy(err:find(fragment, 1, true), err)
end

describe("binary dependency compatibility", function()
    it("ignores declaration order and unused functions or variables", function()
        local used = func("used", {types.Integer()}, {types.String()}, {"count"})
        local variable = types.ModuleVariable("provider", "state", types.String(), false)
        local original = module({used, func("unused"), variable})
        local verify = checker(original, {
            functions = {used = true}, variables = {state = true},
        })
        verify(check_metadata(module({variable, func("added"), used})))
        reject(verify, check_metadata(module({variable})), "functions.used")
        reject(verify, check_metadata(module({used})), "variables.state")
    end)

    it("compares callable names, fixed signatures, and both typed tails", function()
        local original = module({func("used", {types.Integer()}, {types.String()},
            {"count"}, types.String(), types.Integer())})
        local verify = checker(original, { functions = {used = true} })
        for _, replacement in ipairs({
            func("used", {types.Integer()}, {types.String()}, {"number"}, types.String(), types.Integer()),
            func("used", {types.Float()}, {types.String()}, {"count"}, types.String(), types.Integer()),
            func("used", {types.Integer()}, {types.Integer()}, {"count"}, types.String(), types.Integer()),
            func("used", {types.Integer()}, {types.String()}, {"count"}, nil, types.Integer()),
            func("used", {types.Integer()}, {types.String()}, {"count"}, types.String(), nil),
        }) do
            reject(verify, check_metadata(module({replacement})), "functions.used")
        end
    end)

    it("retains variable mutability and nested container qualification", function()
        local original = module({types.ModuleVariable("provider", "state",
            types.Array(types.Integer(), {tag="no"}), false)})
        local verify = checker(original, { variables = {state = true} })
        reject(verify, check_metadata(module({types.ModuleVariable("provider", "state",
            types.Array(types.Integer(), {tag="no"}), true)})), "variables.state.const")
        reject(verify, check_metadata(module({types.ModuleVariable("provider", "state",
            types.Array(types.Integer(), {tag="yes"}), false)})), "variables.state.type")
    end)

    it("erases generic binders and nominal applications without mutating the interface", function()
        local scope = types.GenericScope("provider", nil, "identity", "callable", "function")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local scheme = types.FunctionScheme(scope, {types.TypeParameter("T", nil)},
            types.Function({parameter, types.Nominal("provider.Box", {parameter})},
                {parameter}, false, nil, nil))
        local original = module({types.ModuleMember("provider", "identity", scheme, {"item", "box"})})
        local before = types.serialize(original)
        local verify = checker(original, {functions = {identity = true}})
        verify(check_metadata(module({func("identity", {types.Value(), types.Nominal("provider.Box")},
            {types.Value()}, {"item", "box"})})))
        assert.equal(before, types.serialize(original))
        local constrained = types.Parameter(scope, 1, "T", types.Nominal("provider.View"))
        local changed = types.FunctionScheme(scope,
            {types.TypeParameter("T", types.Nominal("provider.View"))},
            types.Function({constrained, types.Nominal("provider.Box")},
                {constrained}, false, nil, nil))
        reject(verify, check_metadata(module({types.ModuleMember("provider", "identity", changed,
            {"item", "box"})})), "functions.identity.type")
    end)

    it("checks all public record fields but permits arbitrary private fields and indices", function()
        local name = "provider.Item"
        local original = types.Record(name, {
            field(name, "secret", types.Integer(), 0, true),
            field(name, "count", types.Integer(), 1),
            field(name, "label", types.String(), 2),
        }, {}, {}, 3)
        local verify = checker(owner_module(original), {records = {Item = {}}})
        local replacement = types.Record(name, {
            field(name, "count", types.Integer(), 0),
            field(name, "hidden", types.Value(), 1, true),
            field(name, "another", types.String(), 2, true),
            field(name, "label", types.String(), 3),
        }, {}, {}, 4)
        verify(check_metadata(owner_module(replacement)))
        local metadata = check_metadata(owner_module(replacement))
        metadata.records.Item.fields[1], metadata.records.Item.fields[2] =
            metadata.records.Item.fields[2], metadata.records.Item.fields[1]
        reject(verify, metadata, "records.Item.fields")
        metadata = check_metadata(owner_module(replacement))
        metadata.records.Item.fields[1].const = true
        reject(verify, metadata, "records.Item.fields.1.const")
        metadata = check_metadata(owner_module(replacement))
        metadata.records.Item.fields[3] = {name = "extra", type = "Integer()", const = false}
        reject(verify, metadata, "records.Item.fields.3")
    end)

    it("selects only referenced concrete methods and statics", function()
        local name = "provider.Item"
        local original = types.Record(name, {}, {
            new = types.StaticMethod(name, "new", {}, {types.Nominal(name)}, nil, nil, {}),
        }, {
            used = method(name, "used", types.Integer()),
            unused = method(name, "unused", types.String()),
            secret = method(name, "secret", types.Value(), "item", true),
        }, 0)
        local verify = checker(owner_module(original), {
            records = {Item = {functions = {new = true}, methods = {used = true}}},
        })
        local metadata = check_metadata(owner_module(original))
        assert.is_nil(metadata.records.Item.methods.secret)
        metadata.records.Item.methods.unused = nil
        metadata.records.Item.methods.added = {type = "arbitrary", parameters = {}}
        verify(metadata)
        metadata.records.Item.functions.new = nil
        reject(verify, metadata, "records.Item.functions.new")
        metadata = check_metadata(owner_module(original))
        metadata.records.Item.methods.used.parameters[1] = "renamed"
        reject(verify, metadata, "records.Item.methods.used.parameters.1")
    end)

    it("makes construction depend on public new while access survives added private fields", function()
        local name = "provider.Item"
        local original = types.Record(name, {field(name, "count", types.Integer(), 0)}, {
            new = types.StaticMethod(name, "new", {types.Integer()},
                {types.Nominal(name)}, nil, nil, {"count"}),
        }, {}, 1)
        local accessor = checker(owner_module(original), {records = {Item = {}}})
        local constructor = checker(owner_module(original), {
            records = {Item = {functions = {new = true}}},
        })
        local replacement = types.Record(name, {
            field(name, "count", types.Integer(), 0),
            field(name, "private", types.String(), 1, true),
        }, {}, {}, 2)
        local metadata = check_metadata(owner_module(replacement))
        accessor(metadata)
        reject(constructor, metadata, "records.Item.functions.new")
    end)

    it("checks public union shape and requires total inventory only for closed proofs", function()
        local name = "provider.Item"
        local ready = types.Variant(name, "ready", {field(name, "value", types.Integer(), 1)}, 0)
        local original = types.Union(name, {ready}, {}, {}, 1)
        local ordinary = checker(owner_module(original), {unions = {Item = {}}})
        local closed = checker(owner_module(original), {unions = {Item = {closed = true}}})
        local hidden = types.Variant(name, "secret", {}, 1)
        hidden.islocal = true
        local metadata = check_metadata(owner_module(types.Union(name, {ready, hidden}, {}, {}, 2)))
        ordinary(metadata)
        reject(closed, metadata, "unions.Item.nvariants")
        metadata.unions.Item.variants[1].parts[1].name = "renamed"
        reject(ordinary, metadata, "unions.Item.variants.1.parts.1.name")
        metadata = check_metadata(owner_module(original))
        metadata.unions.Item.variants[1].tag = 1
        reject(ordinary, metadata, "unions.Item.variants.1.tag")
    end)

    it("requires exact independently ordered Interface fields and methods", function()
        local name = "provider.View"
        local view = types.Interface(name, {
            field(name, "first", types.Integer(), 0, false, true),
            field(name, "second", types.String(), 1, false, true),
        }, {method(name, "read", types.Integer()), method(name, "write", types.String())})
        local original = module({}, {View = view})
        local verify = checker(original, {interfaces = {View = true}})
        for _, collection in ipairs({"fields", "methods"}) do
            local metadata = check_metadata(original)
            local entries = metadata.interfaces.View[collection]
            entries[1], entries[2] = entries[2], entries[1]
            reject(verify, metadata, "interfaces.View." .. collection)
        end
        local metadata = check_metadata(original)
        metadata.interfaces.View.methods[3] = {name = "extra", signature = {}}
        reject(verify, metadata, "interfaces.View.methods.3")
    end)

    it("puts direct and generic nominal aliases in their owner categories", function()
        local name = "owner.Box"
        local scope = types.GenericScope("owner", name, nil, "owner", "record")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local owner = types.Record(name, {field(name, "item", parameter, 0)}, {}, {}, 1,
            scope, {types.TypeParameter("T", nil)})
        local alias = types.GenericAlias("provider", "Alias", false, name, nil,
            scope, {types.TypeParameter("U", nil)})
        local original = module({}, {Alias = alias, Concrete = types.Nominal(name, {types.String()}),
            Count = types.Integer()})
        local registry = {[name] = owner}
        local metadata = check_metadata(original, registry)
        assert.same(metadata.records.Alias, metadata.records.Concrete)
        assert.equal(name, metadata.records.Alias.fqtn)
        assert.equal("Value()", metadata.records.Alias.fields[1].type)
        assert.is_nil(metadata.records.Count)
        local verify = checker(original, {records = {Alias = {}}}, registry)
        verify(metadata)
        metadata.records.Alias.fqtn = "other.Box"
        reject(verify, metadata, "records.Alias.fqtn")
    end)

    it("serializes deterministically into a self-contained table chunk", function()
        local first = func("first")
        local second = func("second")
        local left = compat.encode(check_metadata(module({first, second})))
        local right = compat.encode(check_metadata(module({second, first})))
        assert.equal(left, right)
        local decoded = assert(load(left, "compatibility metadata", "t", {}))()
        assert.same(check_metadata(module({first, second})), decoded)
        local verify = checker(module({first}), {functions = {first = true}})
        verify(decoded)
    end)

    it("rejects malformed required metadata and missing used declarations", function()
        local original = module({func("used")})
        local verify = checker(original, {functions = {used = true}})
        reject(verify, false, "metadata is not a table")
        local metadata = check_metadata(original)
        metadata.version = 999
        reject(verify, metadata, "metadata version")
        metadata = check_metadata(original)
        metadata.module = "other"
        reject(verify, metadata, "module identity")
        metadata = check_metadata(original)
        metadata.functions.used = true
        reject(verify, metadata, "functions.used")
        metadata = check_metadata(original)
        metadata.interfaces = false
        reject(verify, metadata, "interfaces metadata is not a table")
        assert.has_error(function()
            checker(original, {functions = {missing = true}})
        end, "missing used compatibility functions 'missing'")
    end)
end)

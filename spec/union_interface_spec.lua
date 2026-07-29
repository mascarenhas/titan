local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"

local function canonical_module()
    local fqtn = "sample.Message"
    local nominal = types.Nominal(fqtn)
    local quit = types.Variant(fqtn, "quit", false, 0)
    local write = types.Variant(fqtn, "write", types.String(), 2)
    local union = types.Union(fqtn, {quit, write}, {
        quit = types.StaticMethod(
            fqtn, "quit", {}, {nominal}, false, false, false),
        write = types.StaticMethod(
            fqtn, "write", {types.String()}, {nominal},
            false, false, false),
    }, {}, 3)
    return types.Module("sample", {
        types.ModuleMember("sample", "Message", union, false),
    }), union
end

local function canonical_record_module()
    local fqtn = "sample.Box"
    local nominal = types.Nominal(fqtn)
    local first = types.Field(
        fqtn, "first", types.Integer(), 0)
    local second = types.Field(
        fqtn, "second", types.String(), 1)
    local constructor = types.StaticMethod(
        fqtn, "new", {types.Integer(), types.String()}, {nominal},
        false, false, {"first", "second"})
    local inspect = types.StaticMethod(
        fqtn, "inspect", {}, {},
        false, false, false)
    local show = types.Method(
        fqtn, "show", {}, {},
        false, false, false)
    local record = types.Record(
        fqtn, {first, second}, {
            new = constructor,
            inspect = inspect,
        }, {
            show = show,
        }, 2)
    return types.Module("sample", {
        types.ModuleMember(
            "sample", "Box", record, false),
    }), record
end

describe("union module interfaces", function()
    it("accepts public variants with gaps in their absolute tags", function()
        local module = canonical_module()
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.truthy(ok, err)
    end)

    it("rejects a variant outside its owning union", function()
        local escaped = types.Variant(
            "sample.Message", "quit", false, 0)
        local module = types.Module("sample", {
            types.ModuleMember("sample", "quit", escaped, false),
        })
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "Type%.Variant is only valid inside its owning union", err)
    end)

    it("rejects noncanonical variant owners, indices, and name maps",
    function()
        local module, union = canonical_module()
        union.variants.write.fqtn = "other.Message"
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union variant has an invalid schema", err)

        module, union = canonical_module()
        union.variants.write.index = 0
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union variant has an invalid schema", err)

        module, union = canonical_module()
        union.variants[1], union.variants[2] =
            union.variants[2], union.variants[1]
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union variant has an invalid schema", err)

        module, union = canonical_module()
        union.variants.write = union.variants.quit
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union variant has an invalid schema", err)
    end)

    it("rejects constructors that do not exactly match their variants",
    function()
        local module, union = canonical_module()
        union.functions.write.paramnames = {"payload"}
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "union constructor 'write' does not match its variant", err)

        module, union = canonical_module()
        union.functions.quit = nil
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "union constructor 'quit' does not match its variant", err)

        module, union = canonical_module()
        union.functions.write.params[1] = types.Integer()
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "union constructor 'write' does not match its variant", err)
    end)

    it("rejects a union published under a noncanonical module member",
    function()
        local module, union = canonical_module()
        union.name = "sample.Other"
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union has a noncanonical owner or variant count", err)
    end)

    it("rejects value-facing metadata wrappers that can hide a variant",
    function()
        local fqtn = "sample.Message"
        local function escaped()
            return types.Variant(fqtn, "quit", false, 0)
        end
        local wrappers = {
            types.Field(fqtn, "field", escaped(), 0),
            types.Method(fqtn, "method", {escaped()}, {},
                false, false, {"value"}),
            types.StaticMethod(fqtn, "static", {escaped()}, {},
                false, false, {"value"}),
            types.ModuleMember("sample", "nested", escaped(), false),
            types.ModuleVariable("sample", "nested", escaped()),
        }

        for index, wrapper in ipairs(wrappers) do
            local module = types.Module("sample", {
                types.ModuleMember(
                    "sample", "bad" .. index,
                    types.Array(wrapper), false),
            })
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "is not valid in a value%-facing type graph", err)
        end
    end)

    it("rejects malformed callable parameter-name metadata", function()
        local module, union = canonical_module()
        union.functions.inspect = types.StaticMethod(
            union.name, "inspect", {types.Integer()}, {},
            false, false, {"value", "extra"})
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("callable member has an invalid schema", err)

        module, union = canonical_module()
        union.methods.inspect = types.Method(
            union.name, "inspect", {types.Integer(), types.Integer()}, {},
            false, false, {"value", "value"})
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("callable member has an invalid schema", err)
    end)

    it("rejects collisions in a decoded union member namespace", function()
        local module, union = canonical_module()
        union.methods.quit = types.Method(
            union.name, "quit", {}, {}, false, false, {})
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("nominal function and method maps collide", err)

        module, union = canonical_module()
        union.functions.inspect = types.StaticMethod(
            union.name, "inspect", {}, {}, false, false, {})
        union.methods.inspect = types.Method(
            union.name, "inspect", {}, {}, false, false, {})
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("nominal function and method maps collide", err)

        module, union = canonical_module()
        union.functions.quit = nil
        union.methods.quit = types.Method(
            union.name, "quit", {}, {}, false, false, false)
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("union variant and method maps collide", err)
    end)

    it("rejects malformed nominal and variant maps", function()
        local cases = {
            {
                pattern = "nominal member maps have an invalid schema",
                mutate = function(union)
                    union.functions = false
                end,
            },
            {
                pattern = "nominal function map has an invalid entry",
                mutate = function(union)
                    union.functions.alias = union.functions.quit
                end,
            },
            {
                pattern = "nominal method map has an invalid entry",
                mutate = function(union)
                    union.methods.alias = types.Method(
                        union.name, "different", {}, {},
                        false, false, false)
                end,
            },
            {
                pattern = "union variant map has an invalid entry",
                mutate = function(union)
                    union.variants.alias = union.variants.quit
                end,
            },
            {
                pattern = "union variant table has an invalid key",
                mutate = function(union)
                    union.variants[true] = union.variants.quit
                end,
            },
            {
                pattern = "type graph contains an invalid descriptor",
                mutate = function(union)
                    union.variants.write.payload = {}
                end,
            },
        }

        for _, case in ipairs(cases) do
            local module, union = canonical_module()
            case.mutate(union)
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok, case.pattern .. ": " .. tostring(err))
            assert.match(case.pattern, err)
        end
    end)

    it("validates nested value graphs and module metadata", function()
        local map = types.Map(
            types.String(), types.Option(types.Integer()))
        local module = types.Module("sample", {
            types.ModuleMember("sample", "lookup", map, false),
        })
        local ok, err =
            driver.validate_module_interface(module, "sample")
        assert.truthy(ok, err)

        map.keys = {}
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("type graph contains an invalid descriptor", err)

        local cases = {
            {
                pattern = "function type has an invalid schema",
                member = types.ModuleMember(
                    "sample", "bad_function",
                    types.Function({}, {}, "not boolean", false, false),
                    false),
            },
            {
                pattern = "module function 'bad_names' has invalid "
                    .. "parameter%-name metadata",
                member = types.ModuleMember(
                    "sample", "bad_names",
                    types.Function(
                        {types.Integer()}, {}, false, false, false),
                    {"value", "extra"}),
            },
            {
                pattern = "non%-function module member 'bad_names' has "
                    .. "parameter%-name metadata",
                member = types.ModuleMember(
                    "sample", "bad_names", types.Integer(), {"value"}),
            },
        }
        for _, case in ipairs(cases) do
            module = types.Module("sample", {case.member})
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok, case.pattern .. ": " .. tostring(err))
            assert.match(case.pattern, err)
        end

        module = types.Module("sample", {}, {
            Bad = types.Field(
                "sample.Bad", "value", types.Integer(), 0),
        })
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "module type member 'Bad' has an invalid type graph", err)
        assert.match(
            "Type%.Field is not valid in a value%-facing type graph", err)
    end)

    it("rejects private decorations on recovered public descriptors",
    function()
        local cases = {
            {
                pattern = "deserialize to a Type%.Module",
                decorate = function(module)
                    module.islocal = true
                end,
            },
            {
                pattern = "module member 1 has an invalid schema",
                decorate = function(module)
                    module.members[1].islocal = true
                end,
            },
            {
                pattern = "union has a noncanonical owner or variant count",
                decorate = function(_, union)
                    union.islocal = true
                end,
            },
            {
                pattern = "union variant has an invalid schema",
                decorate = function(_, union)
                    union.variants.quit.islocal = true
                end,
            },
            {
                pattern = "callable member has an invalid schema",
                decorate = function(_, union)
                    union.functions.quit.islocal = true
                end,
            },
            {
                pattern = "callable member has an invalid schema",
                decorate = function(_, union)
                    union.methods.inspect = types.Method(
                        union.name, "inspect", {}, {},
                        false, false, false)
                    union.methods.inspect.islocal = true
                end,
            },
        }

        for _, case in ipairs(cases) do
            local module, union = canonical_module()
            case.decorate(module, union)
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok, case.pattern .. ": " .. tostring(err))
            assert.match(case.pattern, err)
        end
    end)

    it("rejects private decorations on recovered public record schemas",
    function()
        local cases = {
            {
                pattern = "record has a noncanonical owner or field count",
                decorate = function(record)
                    record.islocal = true
                end,
            },
            {
                pattern = "record field has an invalid schema",
                decorate = function(record)
                    record.fields[1].islocal = true
                end,
            },
            {
                pattern = "callable member has an invalid schema",
                decorate = function(record)
                    record.functions.new.islocal = true
                end,
            },
            {
                pattern = "callable member has an invalid schema",
                decorate = function(record)
                    record.functions.inspect.islocal = true
                end,
            },
            {
                pattern = "callable member has an invalid schema",
                decorate = function(record)
                    record.methods.show.islocal = true
                end,
            },
        }

        for _, case in ipairs(cases) do
            local module, record = canonical_record_module()
            case.decorate(record)
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok, case.pattern .. ": " .. tostring(err))
            assert.match(case.pattern, err)
        end
    end)

    it("rejects malformed public record projections and constructors",
    function()
        local module, record = canonical_record_module()
        record.fields[1], record.fields[2] =
            record.fields[2], record.fields[1]
        record.functions.new.params[1],
            record.functions.new.params[2] =
            record.functions.new.params[2],
            record.functions.new.params[1]
        record.functions.new.paramnames[1],
            record.functions.new.paramnames[2] =
            record.functions.new.paramnames[2],
            record.functions.new.paramnames[1]
        local ok, err =
            driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("record field has an invalid schema", err)

        module, record = canonical_record_module()
        record.functions.new = nil
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("all%-public record is missing its constructor", err)

        module, record = canonical_record_module()
        record.functions.new.rettypes[1] =
            types.Nominal("sample.Other")
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("record constructor does not match its owner", err)

        module, record = canonical_record_module()
        record.functions.new.paramnames = {"second", "first"}
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("record constructor does not match its fields", err)
    end)

    it("allows an absent constructor for a record with hidden fields",
    function()
        local fqtn = "sample.Partial"
        local shown = types.Field(
            fqtn, "shown", types.String(), 1)
        local record = types.Record(
            fqtn, {shown}, {}, {}, 2)
        local module = types.Module("sample", {
            types.ModuleMember(
                "sample", "Partial", record, false),
        })
        local ok, err =
            driver.validate_module_interface(module, "sample")
        assert.truthy(ok, err)
    end)
end)

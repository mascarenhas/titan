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

local function canonical_interface_module()
    local fqtn = "sample.Stream"
    local read = types.Method(
        fqtn, "read", {types.Integer()},
        {types.Option(types.String())},
        false, false, {"count"})
    local close = types.Method(
        fqtn, "close", {}, {},
        false, false, {})
    local interface = types.Interface(fqtn, {read, close})
    return types.Module("sample", {}, {
        Stream = interface,
    }), interface
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
            types.ModuleVariable("sample", "lookup", map),
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
                pattern = "function type has an invalid schema",
                member = types.ModuleMember(
                    "sample", "c_vararg_function",
                    types.Function({}, {}, true, false, false),
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

        local _, record = canonical_record_module()
        module = types.Module("sample", {
            types.ModuleVariable("sample", "Box", record),
        })
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "Type%.Record is only valid as its owning module member", err)

        module = types.Module("sample", {
            types.ModuleMember(
                "sample", "ordinary", types.Integer(), false),
        })
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "module member 'ordinary' has invalid declaration type "
                .. "Type%.Integer",
            err)

        for _, fqtn in ipairs({
                "evil", ".evil", "evil.", "evil..Type",
            }) do
            module = types.Module("sample", {
                types.ModuleVariable(
                    "sample", "bad_nominal", types.Nominal(fqtn)),
            })
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok, fqtn)
            assert.match(
                "nominal type has an invalid qualified name", err)
        end
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

    it("rejects record field and callable namespace collisions",
    function()
        local module, record = canonical_record_module()
        record.methods.first = types.Method(
            record.name, "first", {}, {},
            false, false, {})
        local ok, err =
            driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("record field and method maps collide at 'first'", err)

        module, record = canonical_record_module()
        record.functions.second = types.StaticMethod(
            record.name, "second", {}, {},
            false, false, {})
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "record field and function maps collide at 'second'", err)
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

    describe("Interface type members", function()
        it("accepts and round-trips one canonical ordered declaration",
        function()
            local module, interface = canonical_interface_module()
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.truthy(ok, err)
            assert.is_true(
                interface.methods.read == interface.methods[1])
            assert.is_true(
                interface.methods.close == interface.methods[2])

            local serialized = types.serialize(module)
            local rebuilt, decode_err = driver.decode_module_interface(
                serialized, "sample", "interface-test")
            assert.truthy(rebuilt, decode_err)
            local recovered = rebuilt.type_members.Stream
            assert.equal("Type.Interface", recovered._tag)
            assert.is_true(
                recovered.methods.read == recovered.methods[1])
            assert.is_true(
                recovered.methods.close == recovered.methods[2])
            assert.same({"count"},
                recovered.methods.read.paramnames)
        end)

        it("rejects noncanonical owners and private decorations",
        function()
            local module, interface = canonical_interface_module()
            interface.name = "sample.Other"
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "interface has a noncanonical owner or locality", err)

            module, interface = canonical_interface_module()
            interface.islocal = true
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "interface has a noncanonical owner or locality", err)

            module, interface = canonical_interface_module()
            interface.methods.read.islocal = true
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match("callable member has an invalid schema", err)
        end)

        it("rejects malformed ordered method projections", function()
            local cases = {
                {
                    pattern = "does not reference its ordered descriptor",
                    mutate = function(interface)
                        interface.methods.read = interface.methods.close
                    end,
                },
                {
                    pattern = "extra derived key",
                    mutate = function(interface)
                        interface.methods.extra = interface.methods.read
                    end,
                },
                {
                    pattern = "method list is sparse",
                    mutate = function(interface)
                        interface.methods[1] = nil
                    end,
                },
                {
                    pattern = "belongs to a different owner",
                    mutate = function(interface)
                        interface.methods[1].fqtn = "other.Stream"
                    end,
                },
                {
                    pattern = "callable member has an invalid schema",
                    mutate = function(interface)
                        interface.methods[1].paramnames = {
                            "count", "extra",
                        }
                    end,
                },
                {
                    pattern = "interface method parameter names have "
                        .. "an invalid schema",
                    mutate = function(interface)
                        interface.methods[1].paramnames = false
                    end,
                },
                {
                    pattern = "callable member has an invalid schema",
                    mutate = function(interface)
                        interface.methods[1].params.extra =
                            types.Integer()
                    end,
                },
                {
                    pattern = "callable member has an invalid schema",
                    mutate = function(interface)
                        interface.methods[1].rettypes.extra =
                            types.String()
                    end,
                },
            }
            for _, case in ipairs(cases) do
                local module, interface =
                    canonical_interface_module()
                case.mutate(interface)
                local ok, err =
                    driver.validate_module_interface(module, "sample")
                assert.falsy(ok,
                    case.pattern .. ": " .. tostring(err))
                assert.match(case.pattern, err)
            end
        end)

        it("allows Interface descriptors only in their direct type slot",
        function()
            local _, interface = canonical_interface_module()
            local module = types.Module("sample", {
                types.ModuleMember(
                    "sample", "bad", interface, false),
            })
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "Type%.Interface is only valid as its owning module type member",
                err)

            _, interface = canonical_interface_module()
            module = types.Module("sample", {}, {
                Alias = types.Array(interface),
            })
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "Type%.Interface is only valid as its owning module type member",
                err)

            module, interface = canonical_interface_module()
            interface.methods.read.params[1] = interface
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(
                "Type%.Interface is only valid as its owning module type member",
                err)
        end)

        it("rejects descriptors outside the closed value type language",
        function()
            local cases = {
                {
                    label = "error-recovery marker",
                    make = types.Invalid,
                    pattern = "Type%.Invalid",
                },
                {
                    label = "no-value marker",
                    make = types.Void,
                    pattern = "Type%.Void",
                },
                {
                    label = "nested module",
                    make = function()
                        return types.Module("evil", {})
                    end,
                    pattern = "Type%.Module",
                },
                {
                    label = "C FFI descriptor",
                    make = function()
                        return types.CInteger("int", true, 3, 32)
                    end,
                    pattern = "Type%.CInteger",
                },
                {
                    label = "unknown descriptor",
                    make = function()
                        return { _tag = "Type.Unknown" }
                    end,
                    pattern = "Type%.Unknown",
                },
            }
            local placements = {
                function(method, typ)
                    method.params[1] = typ
                end,
                function(method, typ)
                    method.rettypes[1] = typ
                end,
                function(method, typ)
                    method.varargtype = typ
                end,
                function(method, typ)
                    method.flexrettype = typ
                end,
            }

            for _, case in ipairs(cases) do
                for _, place in ipairs(placements) do
                    local module, interface =
                        canonical_interface_module()
                    place(interface.methods.read, case.make())
                    local ok, err =
                        driver.validate_module_interface(module, "sample")
                    assert.falsy(ok, case.label)
                    assert.match(case.pattern ..
                        " is not valid in a value%-facing type graph", err)
                end
            end
        end)

        it("rejects noncanonical optional type shapes", function()
            local cases = {
                types.Option(types.Option(types.String())),
                types.Option(types.Value()),
            }
            for _, typ in ipairs(cases) do
                local module, interface =
                    canonical_interface_module()
                interface.methods.read.params[1] = typ
                local ok, err =
                    driver.validate_module_interface(module, "sample")
                assert.falsy(ok)
                assert.match("option type has an invalid schema", err)
            end
        end)

        it("keeps the type-only namespace independent of values",
        function()
            local _, interface = canonical_interface_module()
            local module = types.Module("sample", {
                types.ModuleVariable(
                    "sample", "Stream", types.Integer()),
            }, {
                Stream = interface,
            })
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.truthy(ok, err)
        end)
    end)
end)

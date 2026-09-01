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
        fqtn, "first", types.Integer(), 0, false)
    local second = types.Field(
        fqtn, "second", types.String(), 1, false)
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
    local interface = types.Interface(fqtn, {}, {read, close})
    return types.Module("sample", {}, {
        Stream = interface,
    }), interface
end

local function canonical_generic_module()
    local show_scope = types.GenericScope(
        "sample", "sample.Show", false, "owner", "interface")
    local show_parameter = types.Parameter(
        show_scope, 1, "E", false)
    local show = types.Interface("sample.Show", {}, {
        types.Method("sample.Show", "show", {show_parameter},
            {types.String()}, false, false, {"value"}),
    }, show_scope, {types.TypeParameter("E", false)})

    local box_scope = types.GenericScope(
        "sample", "sample.Box", false, "owner", "record")
    local erased_show = types.Nominal(
        "sample.Show", {types.String()})
    local box_parameter = types.Parameter(
        box_scope, 1, "T", erased_show)
    local box_constraint = types.Nominal(
        "sample.Show", {types.String()})
    local box_nominal = types.Nominal(
        "sample.Box", {box_parameter})

    local method_scope = types.GenericScope(
        "sample", "sample.Box", "convert", "method", "method")
    local method_parameter = types.Parameter(
        method_scope, 1, "U", types.Nominal("sample.Show", {
            erased_show,
        }))
    local method = types.Method("sample.Box", "convert",
        {method_parameter}, {box_nominal}, false, false, {"value"},
        method_scope, {
            types.TypeParameter("U",
                types.Nominal("sample.Show", {box_parameter})),
        })
    local box = types.Record("sample.Box", {
        types.Field("sample.Box", "item", box_parameter, 0, false),
    }, {
        new = types.StaticMethod("sample.Box", "new", {box_parameter},
            {box_nominal}, false, false, {"item"}),
    }, {
        convert = method,
    }, 1, box_scope, {
        types.TypeParameter("T", box_constraint),
    })

    local function_scope = types.GenericScope(
        "sample", false, "id", "function", "function")
    local function_parameter = types.Parameter(
        function_scope, 1, "V", false)
    local scheme = types.FunctionScheme(function_scope, {
        types.TypeParameter("V", false),
    }, types.Function({function_parameter}, {function_parameter},
        false, false, false))
    local alias = types.GenericAlias(
        "sample", "Crate", false, "sample.Box", false,
        box_scope, {types.TypeParameter("T", box_constraint)})

    local module = types.Module("sample", {
        types.ModuleMember("sample", "Box", box, false),
        types.ModuleMember("sample", "id", scheme, {"value"}),
    }, {
        Crate = alias,
        Show = show,
    })
    return module, {
        alias = alias,
        box = box,
        box_parameter = box_parameter,
        method = method,
        scheme = scheme,
        show = show,
    }
end

describe("union module interfaces", function()
    it("rejects compiler-only source views in recovered metadata", function()
        local fields = {
            "_source", "source_members", "source_type_members",
            "_source_foreign_includes", "_source_c_context",
        }
        for _, field in ipairs(fields) do
            local module = canonical_module()
            module[field] = field == "_source" and true or {}
            local ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match("compiler%-only source interface state", err)
        end

        local module, union = canonical_module()
        union._source_complete = true
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("compiler%-only source state", err)
    end)

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
            types.Field(fqtn, "field", escaped(), 0, false),
            types.Method(fqtn, "method", {escaped()}, {},
                false, false, {"value"}),
            types.StaticMethod(fqtn, "static", {escaped()}, {},
                false, false, {"value"}),
            types.ModuleMember("sample", "nested", escaped(), false),
            types.ModuleVariable("sample", "nested", escaped(), false),
        }

        for index, wrapper in ipairs(wrappers) do
            local module = types.Module("sample", {
                types.ModuleMember(
                    "sample", "bad" .. index,
                    types.Array(wrapper, false), false),
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

    it("rejects names outside Titan's source and module grammars", function()
        local module = types.Module("evil$line", {})
        local ok, err =
            driver.validate_module_interface(module, "evil$line")
        assert.falsy(ok)
        assert.match("invalid logical Titan module name", err, 1, true)

        module = types.Module("sample", {
            types.ModuleMember(
                "sample", "$line", types.Integer(), false),
        })
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("module member 1 has an invalid schema", err, 1, true)

        local union
        module, union = canonical_module()
        union.functions.write.paramnames = { "$line" }
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("callable member has an invalid schema", err, 1, true)
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
            types.ModuleVariable("sample", "lookup", map, false),
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
                    "sample", "nonfalse_reserved_function",
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
                "sample.Bad", "value", types.Integer(), 0, false),
        })
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match(
            "module type member 'Bad' has an invalid type graph", err)
        assert.match(
            "Type%.Field is not valid in a value%-facing type graph", err)

        local _, record = canonical_record_module()
        module = types.Module("sample", {
            types.ModuleVariable("sample", "Box", record, false),
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
                    "sample", "bad_nominal", types.Nominal(fqtn), false),
            })
            ok, err = driver.validate_module_interface(module, "sample")
            assert.falsy(ok, fqtn)
            assert.match(
                "nominal type has an invalid qualified name", err)
        end
    end)

    it("round-trips every ABI-visible const descriptor axis", function()
        local record_name = "sample.Box"
        local record_nominal = types.Nominal(record_name)
        local item = types.Field(
            record_name, "item", types.Integer(), 0, true)
        local record = types.Record(record_name, {item}, {
            new = types.StaticMethod(record_name, "new", {
                types.Integer(),
            }, {record_nominal}, false, false, {"item"}),
        }, {}, 1)
        local interface_name = "sample.BoxView"
        local interface = types.Interface(interface_name, {
            types.Field(
                interface_name, "item", types.Integer(), 0, true),
        }, {})
        local module = types.Module("sample", {
            types.ModuleMember("sample", "Box", record, false),
            types.ModuleVariable("sample", "frozen",
                types.Array(types.String(), true), true),
        }, {
            BoxView = interface,
        })

        local ok, err = driver.validate_module_interface(module, "sample")
        assert.truthy(ok, err)
        local rebuilt, decode_error = driver.decode_module_interface(
            types.serialize(module), "sample", "const-roundtrip")
        assert.truthy(rebuilt, decode_error)
        assert.is_true(rebuilt.members.Box.type.fields[1].isconst)
        assert.is_true(rebuilt.members.frozen.isconst)
        assert.is_true(rebuilt.members.frozen.type.isconst)
        assert.is_true(rebuilt.type_members.BoxView.fields.item.isconst)
    end)

    it("rejects missing or non-boolean serialized const qualifiers",
    function()
        local cases = {
            {
                pattern = "module variable 'lookup'.*const qualifier",
                make = function()
                    return types.Module("sample", {
                        types.ModuleVariable("sample", "lookup",
                            types.Map(types.String(), types.Integer()),
                            false),
                    })
                end,
                mutate = function(module)
                    module.members.lookup.isconst = nil
                end,
            },
            {
                pattern = "array type.*const qualifier",
                make = function()
                    return types.Module("sample", {
                        types.ModuleVariable("sample", "items",
                            types.Array(types.Integer(), false), false),
                    })
                end,
                mutate = function(module)
                    module.members.items.type.isconst = "false"
                end,
            },
            {
                pattern = "record field has an invalid schema",
                make = canonical_record_module,
                mutate = function(module)
                    module.members.Box.type.fields[1].isconst = nil
                end,
            },
        }

        for _, case in ipairs(cases) do
            local module = case.make()
            case.mutate(module)
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok, case.pattern)
            assert.match(case.pattern, err)
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
            fqtn, "shown", types.String(), 1, false)
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

        it("rejects hostile Interface field projections", function()
            local function canonical()
                local fqtn = "sample.Named"
                local field = types.Field(
                    fqtn, "name", types.String(), 0, true)
                local interface = types.Interface(fqtn, {field}, {})
                return types.Module("sample", {}, {
                    Named = interface,
                }), interface
            end
            local cases = {
                {
                    pattern = "does not reference its ordered descriptor",
                    mutate = function(interface)
                        interface.fields.name = types.Field(
                            interface.name, "name",
                            types.String(), 0, true)
                    end,
                },
                {
                    pattern = "field list is sparse",
                    mutate = function(interface)
                        interface.fields[2] = interface.fields[1]
                        interface.fields[1] = nil
                    end,
                },
                {
                    pattern = "different owner",
                    mutate = function(interface)
                        interface.fields[1].fqtn = "other.Named"
                    end,
                },
                {
                    pattern = "index, const qualifier, or locality",
                    mutate = function(interface)
                        interface.fields[1].index = 1
                    end,
                },
                {
                    pattern = "index, const qualifier, or locality",
                    mutate = function(interface)
                        interface.fields[1].isconst = false
                    end,
                },
                {
                    pattern = "index, const qualifier, or locality",
                    mutate = function(interface)
                        interface.fields[1].islocal = true
                    end,
                },
                {
                    pattern = "interface member 'name' is duplicated",
                    mutate = function(interface)
                        local method = types.Method(
                            interface.name, "name", {}, {},
                            false, false, {})
                        interface.methods[1] = method
                        interface.methods.name = method
                    end,
                },
            }

            for _, case in ipairs(cases) do
                local module, interface = canonical()
                case.mutate(interface)
                local ok, err =
                    driver.validate_module_interface(module, "sample")
                assert.falsy(ok, case.pattern)
                assert.match(case.pattern, err)
            end
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
                Alias = types.Array(interface, false),
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
                    label = "header-dependent C FFI descriptor",
                    make = function()
                        return types.CTypedef("platform_int",
                            types.CInteger("int", true, 3, 32), {})
                    end,
                    pattern = "Type%.CTypedef",
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
                    "sample", "Stream", types.Integer(), false),
            }, {
                Stream = interface,
            })
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.truthy(ok, err)
        end)
    end)
end)


describe("generic compiled module metadata", function()
    it("accepts closed binders, applications, schemes, methods, and aliases",
    function()
        local module = canonical_generic_module()
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.truthy(ok, err)

        local rebuilt, decode_error = driver.decode_module_interface(
            types.serialize(module), "sample", "generic-fixture")
        assert.truthy(rebuilt, decode_error)
        assert.is_true(types.alpha_equals(module, rebuilt))
    end)

    it("rejects free, out-of-range, sparse, and renamed Parameter metadata",
    function()
        local cases = {
            {
                pattern = "free scope reference",
                mutate = function(parts)
                    parts.box.fields[1].type = types.Parameter(
                        types.GenericScope("sample", false, "other",
                            "function", "function"),
                        1, "T", false)
                end,
            },
            {
                pattern = "invalid binder index",
                mutate = function(parts)
                    parts.box.fields[1].type.index = 2
                end,
            },
            {
                pattern = "binder list is not dense",
                mutate = function(parts)
                    parts.box.typeparams[2] = parts.box.typeparams[1]
                    parts.box.typeparams[1] = nil
                end,
            },
            {
                pattern = "noncanonical diagnostic name",
                mutate = function(parts)
                    parts.box.fields[1].type.diagnostic_name = "Renamed"
                end,
            },
            {
                pattern = "noncanonical erased constraint",
                mutate = function(parts)
                    parts.box.fields[1].type.erased_constraint = false
                end,
            },
        }
        for _, case in ipairs(cases) do
            local module, parts = canonical_generic_module()
            case.mutate(parts)
            local ok, err =
                driver.validate_module_interface(module, "sample")
            assert.falsy(ok)
            assert.match(case.pattern, err)
        end
    end)

    it("rejects malformed constraints and applied nominal arity", function()
        local module, parts = canonical_generic_module()
        parts.box.typeparams[1].constraint = types.Nominal(
            "sample.Box", {types.String()})
        parts.box_parameter.erased_constraint =
            types.Nominal("sample.Box", {types.String()})
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("constraint does not name an Interface", err)

        module, parts = canonical_generic_module()
        parts.method.rettypes[1] = types.Nominal("sample.Box", {})
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("wrong generic arity", err)

        module, parts = canonical_generic_module()
        parts.box.functions.new.rettypes[1] =
            types.Nominal("sample.Box", {types.Value()})
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("constructor does not match its owner", err)
    end)

    it("rejects noncanonical owner, callable, and scheme scopes", function()
        local module, parts = canonical_generic_module()
        parts.box.scope.role = "function"
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("scope does not match its declaration", err)

        module, parts = canonical_generic_module()
        parts.method.scope.role = "static"
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("scope does not match its declaration", err)

        module, parts = canonical_generic_module()
        parts.scheme.scope.callable_name = "other"
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("scope does not match its declaration", err)

        module, parts = canonical_generic_module()
        parts.method.typeparams[1].name = "T"
        parts.method.params[1].diagnostic_name = "T"
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("generic binder 1 has an invalid schema", err)
    end)

    it("rejects noncanonical and cyclic GenericAlias projections", function()
        local module, parts = canonical_generic_module()
        parts.alias.target_scope = types.GenericScope(
            "sample", "sample.Box", false, "owner", "union")
        parts.alias.typeparams = {types.TypeParameter("T", false)}
        local ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("projection does not match its target owner", err)

        module, parts = canonical_generic_module()
        parts.alias.locality = true
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("GenericAlias has an invalid schema", err)

        module, parts = canonical_generic_module()
        module.type_members.Crate = nil
        module.type_members.Wrong = parts.alias
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("published under a noncanonical name", err)

        module, parts = canonical_generic_module()
        local choice = types.GenericAlias(
            "sample", "Choice", false, "sample.Box", "sample.Crate",
            parts.box.scope, parts.alias.typeparams)
        parts.alias.target_alias_fqtn = "sample.Choice"
        module.type_members.Choice = choice
        ok, err = driver.validate_module_interface(module, "sample")
        assert.falsy(ok)
        assert.match("GenericAlias chain is cyclic", err)
    end)

    it("rejects hostile serialized generic metadata during decoding", function()
        local module, parts = canonical_generic_module()
        parts.scheme.scope.callable_name = "other"
        local decoded, err = driver.decode_module_interface(
            types.serialize(module), "sample", "hostile-generic")
        assert.falsy(decoded)
        assert.match("scope does not match its declaration", err)
    end)
end)

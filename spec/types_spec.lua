local types = require "titan-compiler.types"

describe("Titan types", function()

    it("keeps a module's selected physical provider out of its interface",
       function()
        local module = types.Module("pkg.child", {})
        local exact = types.serialize(module)
        module.file = "pkg.so"
        assert.equal(exact, types.serialize(module))

        local rehydrated = assert(load(
            "return " .. exact, "pkg.child", "t", types))()
        assert.equal("pkg/child.so", rehydrated.file)
    end)

    it("serializes keyed interface members in numeric-byte order", function()
        local function make_record(reverse)
            local methods = {}
            local functions = {}
            local names = reverse and { "\195\169", "z", "A" }
                or { "A", "z", "\195\169" }
            for _, name in ipairs(names) do
                methods[name] = types.Method("sample.Box", name, {}, {},
                    false, false, {})
                functions[name] = types.StaticMethod("sample.Box", name,
                    {}, {}, false, false, {})
            end
            return types.Record("sample.Box", {}, functions, methods, 0)
        end

        local first = types.Module("sample", {}, {
            ["\195\169"] = make_record(false),
            z = make_record(true),
            A = make_record(false),
        })
        local second_members = {}
        second_members.A = make_record(true)
        second_members.z = make_record(false)
        second_members["\195\169"] = make_record(true)
        local second = types.Module("sample", {}, second_members)

        local serialized = types.serialize(first)
        assert.equal(serialized, types.serialize(second))
        local original_locale = os.setlocale(nil, "collate")
        local locale_results = {}
        for _, locale in ipairs({
            "C", "C.UTF-8", "en_US.UTF-8", "pt_BR.UTF-8",
        }) do
            if os.setlocale(locale, "collate") then
                locale_results[#locale_results + 1] =
                    types.serialize(first)
                locale_results[#locale_results + 1] =
                    types.serialize(second)
            end
        end
        if original_locale then os.setlocale(original_locale, "collate") end
        assert.is_true(#locale_results > 0)
        for _, result in ipairs(locale_results) do
            assert.equal(serialized, result)
        end
        local apos = assert(serialized:find('["A"]', 1, true))
        local zpos = assert(serialized:find('["z"]', 1, true))
        local utf8pos = assert(serialized:find('["\195\169"]', 1, true))
        assert.is_true(apos < zpos and zpos < utf8pos)
        assert.is_true(serialized:find("A = Method", 1, true) <
            serialized:find("z = Method", 1, true))
        assert.is_true(serialized:find("z = Method", 1, true) <
            serialized:find("\195\169 = Method", 1, true))
        assert.is_true(serialized:find("A = StaticMethod", 1, true) <
            serialized:find("z = StaticMethod", 1, true))
        assert.is_true(serialized:find("z = StaticMethod", 1, true) <
            serialized:find("\195\169 = StaticMethod", 1, true))
    end)

    it("preserves declaration order for module members and record fields",
       function()
        local record = types.Record("sample.Box", {
            types.Field("sample.Box", "z", types.Integer(), 0, false),
            types.Field("sample.Box", "A", types.Integer(), 1, false),
        }, {}, {}, 2)
        local module = types.Module("sample", {
            types.ModuleMember("sample", "z", types.Integer(), false),
            types.ModuleMember("sample", "A", types.Integer(), false),
        }, { Box = record })

        local serialized = types.serialize(module)
        assert.is_true(serialized:find("ModuleMember('sample', 'z'", 1,
            true) < serialized:find("ModuleMember('sample', 'A'", 1, true))
        assert.is_true(serialized:find("Field('sample.Box', 'z'", 1, true) <
            serialized:find("Field('sample.Box', 'A'", 1, true))
    end)

    it("pretty-prints types", function()
        assert.same("{ integer }",
            types.tostring(types.Array(types.Integer(), false)))
        assert.same("const { integer }",
            types.tostring(types.Array(types.Integer(), true)))

        local c_integer = types.CInteger("int", true, 3, 32)
        assert.same("{ const *int }", types.tostring(types.Array(
            types.CPointer(c_integer, {"const"}), false)))
        assert.same("const { *int }", types.tostring(types.Array(
            types.CPointer(c_integer, {}), true)))
    end)

    it("requires every serialized const qualifier explicitly", function()
        local constructors = {
            function() return types.Array(types.Integer()) end,
            function()
                return types.Field(
                    "sample.Box", "item", types.Integer(), 0)
            end,
            function()
                return types.ModuleVariable(
                    "sample", "item", types.Integer())
            end,
        }
        for _, construct in ipairs(constructors) do
            local ok, err = pcall(construct)
            assert.is_false(ok)
            assert.match("const qualifier must be a boolean", tostring(err))
        end

        local mutable = types.Field(
            "sample.Box", "item", types.Integer(), 0, false)
        local immutable = types.Field(
            "sample.Box", "item", types.Integer(), 0, true)
        assert.is_false(types.equals(mutable, immutable))
        assert.is_false(types.equals(
            types.ModuleVariable("sample", "item", types.Integer(), false),
            types.ModuleVariable("sample", "item", types.Integer(), true)))
    end)

    it("pretty-prints a function with multiple return types", function()
        local f = types.Function({types.Integer()},
                                 {types.Integer(), types.String()}, false, false,
                                 false)
        assert.same("(integer) -> (integer, string)", types.tostring(f))
    end)

    it("pretty-prints flexible returns canonically without changing fixed-only forms", function()
        local flexonly = types.Function({}, {}, false, false, types.Integer())
        local mixed = types.Function(
            {types.Integer()}, {types.Boolean()}, false, types.String(),
            types.Value())

        assert.same("() -> (...: integer)", types.tostring(flexonly))
        assert.same(
            "(integer, ...: string) -> (boolean, ...: value)",
            types.tostring(mixed))
        assert.same("(integer) -> boolean", types.tostring(types.Function(
            {types.Integer()}, {types.Boolean()}, false, false, false)))
    end)

    it("renders a function-typed flexible element without colliding with a fixed result", function()
        local elem = types.Function({}, {types.Integer()}, false, false, false)
        local fixed = types.Function({}, {elem}, false, false, false)
        local flexible = types.Function({}, {}, false, false, elem)

        assert.same("() -> (() -> integer)", types.tostring(fixed))
        assert.same("() -> (...: () -> integer)", types.tostring(flexible))
        assert.not_equal(types.tostring(fixed), types.tostring(flexible))
    end)

    it("pretty-prints a method with one return type", function()
        local method = types.Method("sample.Box", "get",
            {types.Integer()}, {types.String()}, false, false, {"index"})
        assert.same("sample.Box:get(integer): string", types.tostring(method))
    end)

    it("pretty-prints flexible method and record-function returns", function()
        local method = types.Method("sample.Box", "items", {}, {}, false,
            types.String(), {})
        local static = types.StaticMethod("sample.Box", "lookup", {},
            {types.Boolean()}, false, types.Integer(), {})

        assert.same("sample.Box:items(): (...: string)",
            types.tostring(method))
        assert.same("sample.Box.lookup(): (boolean, ...: integer)",
            types.tostring(static))
    end)

    it("checks if a type is garbage collected", function()
        assert.truthy(types.is_gc(types.String()))
        assert.truthy(types.is_gc(types.Array(types.Integer(), false)))
        assert.truthy(types.is_gc(types.Map(types.Integer(), types.Integer())))
        assert.truthy(types.is_gc(types.Function({}, {}, false, false, false)))
    end)

    it("compares identical functions", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false, false)
        assert.truthy(types.equals(f1, f2))
    end)

    it("compares functions with different arguments", function()
        local f1 = types.Function({types.String(), types.Boolean()}, {types.Boolean()}, false, false, false)
        local f2 = types.Function({types.Integer(), types.Integer()}, {types.Boolean()}, false, false, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("compares functions with different returns", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Integer()}, false, false, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("includes flexible return presence and element type in function identity", function()
        local fixed = types.Function({}, {}, false, false, false)
        local ints1 = types.Function({}, {}, false, false, types.Integer())
        local ints2 = types.Function({}, {}, false, false, types.Integer())
        local strings = types.Function({}, {}, false, false, types.String())

        assert.truthy(types.equals(ints1, ints2))
        assert.falsy(types.equals(fixed, ints1))
        assert.falsy(types.equals(ints1, fixed))
        assert.falsy(types.equals(ints1, strings))
    end)

    it("compares method and record-function descriptors structurally", function()
        local constructors = { types.Method, types.StaticMethod }
        local i, s, b = types.Integer(), types.String(), types.Boolean()

        for _, constructor in ipairs(constructors) do
            local base = constructor("sample.Box", "items", {i}, {s}, i, b,
                {"count"})
            local renamed = constructor("sample.Box", "items",
                {types.Integer()}, {types.String()}, types.Integer(),
                types.Boolean(), {"renamed"})

            -- Parameter names are declaration metadata, not callable identity.
            assert.truthy(types.equals(base, renamed))
            assert.truthy(types.equals(renamed, base))

            local different = {
                constructor("other.Box", "items", {i}, {s}, i, b, {"count"}),
                constructor("sample.Box", "other", {i}, {s}, i, b, {"count"}),
                constructor("sample.Box", "items", {s}, {s}, i, b, {"count"}),
                constructor("sample.Box", "items", {i}, {i}, i, b, {"count"}),
                constructor("sample.Box", "items", {i}, {s}, s, b, {"count"}),
                constructor("sample.Box", "items", {i}, {s}, i, s, {"count"}),
                constructor("sample.Box", "items", {i}, {s}, false, b, {"count"}),
                constructor("sample.Box", "items", {i}, {s}, i, false, {"count"}),
            }
            for _, descriptor in ipairs(different) do
                assert.falsy(types.equals(base, descriptor))
                assert.falsy(types.equals(descriptor, base))
            end
        end

        assert.falsy(types.equals(
            types.Method("sample.Box", "items", {i}, {s}, i, b, {}),
            types.StaticMethod("sample.Box", "items", {i}, {s}, i, b, {})))
    end)

    it("keeps exact function equality strict across arity and tails",
    function()
        local i = types.Integer()
        local function fn(params, results, varargtype, flexrettype)
            return types.Function(params or {}, results or {}, false,
                varargtype or false, flexrettype or false)
        end
        local base = fn({i}, {i})
        assert.falsy(types.equals(base, fn({}, {i})))
        assert.falsy(types.equals(base, fn({i}, {i, i})))
        assert.falsy(types.equals(base, fn({i}, {i}, i)))
        assert.falsy(types.equals(base, fn({i}, {i}, false, i)))
    end)

    it("keeps the compiled Function vararg slot reserved false", function()
        local valid = types.Function(
            { types.Integer() }, { types.Integer() }, false, false, false)
        local malformed = types.Function(
            { types.Integer() }, { types.Integer() }, true, false, false)

        assert.is_false(types.equals(valid, malformed))
        assert.is_false(types.equals(malformed, malformed))
        assert.is_false(types.consistent(valid, malformed))
        assert.is_false(types.callable_adjustment(valid, malformed))
        assert.is_false(types.has_sound_gradual_guard(malformed))
        assert.has_error(function()
            types.serialize(malformed)
        end, "Type.Function reserved vararg field must be false")
        assert.match("Function%([^,]+,[^,]+,false,",
            types.serialize(valid))
    end)

    describe("Interface descriptors and direct implementation matching",
    function()
        local function method(
                owner, name, params, results, paramnames,
                varargtype, flexrettype)
            return types.Method(
                owner,
                name,
                params or {},
                results or {},
                varargtype or false,
                flexrettype or false,
                paramnames or {})
        end

        local function constructor_fails(owner, fields, methods, pattern)
            local ok, err = pcall(types.Interface, owner, fields, methods)
            assert.is_false(ok)
            assert.match(pattern, tostring(err))
        end

        it("builds one canonical ordered list and name-map projection",
        function()
            local owner = "api.Stream"
            local read = method(
                owner, "read", {types.Integer()}, {types.String()},
                {"count"})
            local close = method(owner, "close")
            local interface = types.Interface(owner, {}, {read, close})

            assert.equal(2, #interface.methods)
            assert.is_true(interface.methods[1] == read)
            assert.is_true(interface.methods[2] == close)
            assert.is_true(interface.methods.read == read)
            assert.is_true(interface.methods.close == close)
            assert.is_true(
                types.validate_interface_descriptor(interface)
                    == interface)
            assert.equal(owner, types.tostring(interface))
            assert.is_false(types.is_gc(interface))
            assert.is_false(
                types.has_tvalue_representation(interface))
            assert.is_false(types.consistent(
                interface, interface))
            assert.is_false(types.gradual_guard(interface))
            assert.is_false(types.dynamic_coercion(interface))
            assert.is_false(types.coercion(
                interface, types.Value()))
            assert.is_false(types.assignment_adjustment(
                interface, types.Value()))
            assert.is_false(types.written_cast(
                interface, types.Value()))

            local nominal = types.Nominal(owner)
            assert.is_true(types.is_gc(nominal))
            assert.is_true(
                types.has_tvalue_representation(nominal))
            assert.is_true(types.consistent(
                nominal, types.Value()))
        end)

        it("rejects noncanonical Interface constructor input",
        function()
            local owner = "api.Stream"
            local read = method(owner, "read")
            local close = method(owner, "close")

            constructor_fails(owner, {}, {},
                "at least one member")
            constructor_fails(owner, {}, {
                [1] = read,
                [3] = close,
            }, "dense")
            constructor_fails(owner, {}, {
                [1] = read,
                read = read,
            }, "numeric list keys only")
            constructor_fails(owner, {}, {
                read,
                method(owner, "read"),
            }, "duplicate or cross%-kind member")
            constructor_fails(owner, {}, {
                method("other.Stream", "read"),
            }, "different owner")
            constructor_fails(owner, {}, {
                types.StaticMethod(
                    owner, "read", {}, {},
                    false, false, {}),
            }, "not a method descriptor")
        end)

        it("builds canonical field-only and mixed member projections",
        function()
            local owner = "api.Named"
            local name = types.Field(
                owner, "name", types.String(), 0, true)
            local show = method(owner, "show")
            local interface = types.Interface(owner, {name}, {show})

            assert.equal(1, #interface.fields)
            assert.is_true(interface.fields[1] == name)
            assert.is_true(interface.fields.name == name)
            assert.is_true(interface.methods.show == show)
            assert.is_true(types.validate_interface_descriptor(interface)
                == interface)

            local rebuilt = assert(load(
                "return " .. types.serialize(interface), owner, "t", types))()
            assert.is_true(types.equals(interface, rebuilt))
            assert.is_true(rebuilt.fields.name == rebuilt.fields[1])
            assert.is_true(rebuilt.fields[1].isconst)

            constructor_fails(owner, {
                types.Field(owner, "name", types.String(), 0, true),
            }, {method(owner, "name")}, "cross%-kind member")
            constructor_fails(owner, {
                types.Field(owner, "name", types.String(), 1, true),
            }, {}, "noncanonical index")
            constructor_fails(owner, {
                types.Field(owner, "name", types.String(), 0, false),
            }, {}, "const qualifier")
        end)

        it("matches const record fields and freezes their full adjustments",
        function()
            local iname, rname = "api.View", "sample.Box"
            local required_name = types.Field(
                iname, "name", types.String(), 0, true)
            local required_number = types.Field(
                iname, "number", types.Float(), 1, true)
            local interface = types.Interface(
                iname, {required_name, required_number}, {})
            local concrete_name = types.Field(
                rname, "name", types.String(), 3, true)
            local concrete_number = types.Field(
                rname, "number", types.Integer(), 7, true)
            local record = types.Record(
                rname, {concrete_name, concrete_number}, {}, {}, 8)

            local implementation = assert(types.interface_implementation(
                record, interface, {visibility = "sample"}))
            assert.equal(2, #implementation.fields)
            assert.equal(3, implementation.fields[1].source_index)
            assert.equal(0, implementation.fields[1].target_index)
            assert.is_true(implementation.fields[1].exact)
            assert.equal("direct_coercion",
                implementation.fields[2].adjustment.kind)
            assert.equal("integer_to_float",
                implementation.fields[2].adjustment.coercion.op)
            assert.is_false(implementation.fields[2].exact)
            assert.is_false(implementation.exact)

            concrete_name.isconst = false
            local matched, failure = types.interface_implementation(
                record, interface, {visibility = "sample"})
            assert.is_false(matched)
            assert.equal("mutable", failure.reason)
            assert.equal("field", failure.member_kind)

            concrete_name.isconst = true
            concrete_name.islocal = true
            matched, failure = types.interface_implementation(
                record, interface, {visibility = "client"})
            assert.is_false(matched)
            assert.equal("inaccessible", failure.reason)

            local union = types.Union(
                "sample.Choice", {}, {}, {}, 0)
            matched, failure = types.interface_implementation(
                union, interface, {visibility = "sample"})
            assert.is_false(matched)
            assert.equal("fields_require_record", failure.reason)
        end)

        it("retains nested Interface field implementation annotations",
        function()
            local inner_interface_name = "api.Inner"
            local inner_record_name = "sample.Inner"
            local required_method = method(inner_interface_name, "show")
            local concrete_method = method(inner_record_name, "show")
            local inner_interface = types.Interface(
                inner_interface_name, {}, {required_method})
            local inner_record = types.Record(
                inner_record_name, {}, {}, {show = concrete_method}, 0)

            local outer_interface_name = "api.Outer"
            local outer_record_name = "sample.Outer"
            local outer_interface = types.Interface(outer_interface_name, {
                types.Field(outer_interface_name, "inner",
                    types.Nominal(inner_interface_name), 0, true),
            }, {})
            local outer_record = types.Record(outer_record_name, {
                types.Field(outer_record_name, "inner",
                    types.Nominal(inner_record_name), 0, true),
            }, {}, {}, 1)
            local policy = {visibility = "sample"}
            policy.interface_coercion = function(source, target, received)
                if source.fqtn ~= inner_record_name
                   or target.fqtn ~= inner_interface_name then
                    return false
                end
                return types.interface_implementation(
                    inner_record, inner_interface, received)
            end

            local implementation = assert(types.interface_implementation(
                outer_record, outer_interface, policy))
            local nested = implementation.fields[1]
                .adjustment.coercion
            assert.equal("interface_wrapper", nested.op)
            assert.equal("interface_implementation",
                nested.implementation.kind)
            assert.is_true(nested.implementation.methods[1].concrete
                == concrete_method)
        end)

        it("substitutes owner-generic Interface fields before matching",
        function()
            local interface_scope = types.GenericScope(
                "api", "api.BoxView", false, "owner", "interface")
            local record_scope = types.GenericScope(
                "sample", "sample.Box", false, "owner", "record")
            local interface_parameter = types.Parameter(
                interface_scope, 1, "T", false)
            local record_parameter = types.Parameter(
                record_scope, 1, "T", false)
            local interface = types.Interface("api.BoxView", {
                types.Field("api.BoxView", "item",
                    interface_parameter, 0, true),
            }, {}, interface_scope, {
                types.TypeParameter("T", false),
            })
            local record = types.Record("sample.Box", {
                types.Field("sample.Box", "item",
                    record_parameter, 0, true),
            }, {}, {}, 1, record_scope, {
                types.TypeParameter("T", false),
            })

            local closed_interface = types.substitute(
                interface, interface_scope, {types.Integer()})
            local closed_record = types.substitute(
                record, record_scope, {types.Integer()})
            assert.equal("Type.Integer",
                closed_interface.fields[1].type._tag)
            assert.equal("Type.Integer",
                closed_record.fields[1].type._tag)
            assert.is_true(closed_interface.fields[1].isconst)
            assert.is_true(closed_record.fields[1].isconst)

            local implementation = assert(
                types.generic_interface_implementation(
                    closed_record, closed_interface,
                    {visibility = "sample"}))
            assert.is_true(implementation.exact)
            assert.is_true(implementation.fields[1].required
                == closed_interface.fields[1])
            assert.is_true(implementation.fields[1].concrete
                == closed_record.fields[1])
        end)

        it("compares and serializes only canonical declaration order",
        function()
            local owner = "api.Stream"
            local first = types.Interface(owner, {}, {
                method(owner, "read",
                    {types.Integer()}, {types.String()}, {"count"}),
                method(owner, "close"),
            })
            local renamed = types.Interface(owner, {}, {
                method(owner, "read",
                    {types.Integer()}, {types.String()}, {"n"}),
                method(owner, "close"),
            })
            local reordered = types.Interface(owner, {}, {
                method(owner, "close"),
                method(owner, "read",
                    {types.Integer()}, {types.String()}, {"count"}),
            })
            local distinct = types.Interface("other.Stream", {}, {
                method("other.Stream", "read",
                    {types.Integer()}, {types.String()}, {"count"}),
                method("other.Stream", "close"),
            })

            -- Declaration parameter names support named calls but are not
            -- part of projected callable identity.
            assert.is_true(types.equals(first, renamed))
            assert.is_false(types.equals(first, reordered))
            assert.is_false(types.equals(first, distinct))
            assert.is_false(types.consistent(
                types.Nominal(owner),
                types.Nominal("other.Stream")))

            local serialized = types.serialize(first)
            local read_position =
                assert(serialized:find("'read'", 1, true))
            local close_position =
                assert(serialized:find("'close'", 1, true))
            assert.is_true(read_position < close_position)
            assert.is_nil(serialized:find("[\"read\"]", 1, true))

            local rebuilt = assert(load(
                "return " .. serialized, owner, "t", types))()
            assert.is_true(types.equals(first, rebuilt))
            assert.is_true(
                rebuilt.methods.read == rebuilt.methods[1])
            assert.is_true(
                rebuilt.methods.close == rebuilt.methods[2])
            assert.same({"count"},
                rebuilt.methods.read.paramnames)

            local malformed = types.Interface(owner, {}, {
                method(owner, "read"),
            })
            malformed.methods.read = method(owner, "read")
            local valid, validation_error =
                types.validate_interface_descriptor(malformed)
            assert.is_nil(valid)
            assert.match("does not reference",
                validation_error)
            assert.is_false(types.equals(malformed, malformed))
            local ok, err = pcall(types.serialize, malformed)
            assert.is_false(ok)
            assert.match("malformed Interface descriptor",
                tostring(err))
        end)

        it("allows portable C types in Interface method signatures",
        function()
            local owner = "api.Foreign"
            local cint =
                types.CInteger("int", true, 3, 32)
            local interface = types.Interface(owner, {}, {
                method(owner, "take", {cint}),
            })

            assert.is_true(
                types.first_c_type(interface) == cint)
            assert.is_true(types.contains_c_ffi_type(interface))
            assert.is_nil(types.first_non_exportable_type(interface))
            assert.match('CInteger%("int",true,3,32%)',
                types.serialize(interface))
        end)

        it("projects methods without self or parameter-name identity",
        function()
            local owner = "api.Stream"
            local declaration = method(
                owner, "read",
                {types.Integer()}, {types.String()}, {"count"},
                types.Value(), types.Boolean())
            local renamed = method(
                owner, "read",
                {types.Integer()}, {types.String()}, {"n"},
                types.Value(), types.Boolean())
            local projected =
                types.method_function_type(declaration)
            local other =
                types.method_function_type(renamed)

            assert.equal("Type.Function", projected._tag)
            assert.is_false(projected.vararg)
            assert.is_true(
                projected.params == declaration.params)
            assert.is_true(
                projected.rettypes == declaration.rettypes)
            assert.is_true(
                projected.varargtype == declaration.varargtype)
            assert.is_true(
                projected.flexrettype == declaration.flexrettype)
            assert.is_true(types.equals(projected, other))
        end)

        it("matches record and union methods in Interface order",
        function()
            local iname, rname, uname =
                "api.Consumer", "sample.Record", "sample.Union"
            local consume_required = method(
                iname, "consume",
                {types.Integer(), types.Integer()},
                {types.Value()}, {"left", "right"})
            local close_required =
                method(iname, "close", {}, {}, {"unused"})
            local interface = types.Interface(
                iname, {}, {consume_required, close_required})

            local consume = method(
                rname, "consume",
                {types.Integer()}, {types.Integer()}, {"renamed"})
            local close = method(
                rname, "close", {}, {}, {"different"})
            local extra = method(rname, "extra")
            local record = types.Record(
                rname, {}, {}, {
                    extra = extra,
                    close = close,
                    consume = consume,
                }, 0)

            local seen_policy
            local original = types.callable_adjustment
            types.callable_adjustment = function(source, target, policy)
                seen_policy = policy
                return original(source, target, policy)
            end
            local ok, implementation = pcall(
                types.interface_implementation,
                record, interface, {visibility = "sample"})
            types.callable_adjustment = original
            assert.is_true(ok, implementation)
            assert.equal("interface_implementation",
                implementation.kind)
            assert.is_false(implementation.exact)
            assert.equal(2, #implementation.methods)
            assert.equal("consume",
                implementation.methods[1].name)
            assert.equal(0, implementation.methods[1].index)
            assert.is_true(
                implementation.methods[1].concrete == consume)
            assert.is_false(
                implementation.methods[1].exact)
            assert.equal("ignore_argument",
                implementation.methods[1]
                    .adjustment.arguments[2].kind)
            assert.equal("gradual_view",
                implementation.methods[1]
                    .adjustment.results[1].adjustment.kind)
            assert.equal("close",
                implementation.methods[2].name)
            assert.is_true(
                implementation.methods[2].exact)
            assert.is_false(seen_policy.aligned_coercions)

            local union_consume = method(
                uname, "consume",
                {types.Integer(), types.Integer()},
                {types.Value()}, {"x", "y"})
            local union_close =
                method(uname, "close")
            local union = types.Union(
                uname, {}, {}, {
                    consume = union_consume,
                    close = union_close,
                }, 0)
            local union_implementation =
                assert(types.interface_implementation(
                    union, interface, {
                        method_visible = function()
                            return true
                        end,
                    }))
            assert.is_true(union_implementation.exact)
            assert.is_true(
                union_implementation.methods[1].concrete
                    == union_consume)
        end)

        it("reports the first ordered shape or visibility failure",
        function()
            local iname, rname =
                "api.Required", "sample.Concrete"
            local interface = types.Interface(iname, {}, {
                method(iname, "first"),
                method(iname, "second"),
            })
            local record =
                types.Record(rname, {}, {}, {}, 0)

            local implementation, failure =
                types.interface_implementation(
                    record, interface, {visibility = "sample"})
            assert.is_false(implementation)
            assert.equal("missing", failure.reason)
            assert.equal(1, failure.index)
            assert.equal("first", failure.name)

            implementation, failure =
                types.interface_implementation(record, interface)
            assert.is_false(implementation)
            assert.equal("missing_visibility", failure.reason)

            local local_first = method(rname, "first")
            local_first.islocal = true
            record.methods.first = local_first
            record.methods.second = method(rname, "second")
            implementation = assert(
                types.interface_implementation(
                    record, interface, {visibility = "sample"}))
            assert.is_true(implementation.exact)

            implementation, failure =
                types.interface_implementation(
                    record, interface, {visibility = "client"})
            assert.is_false(implementation)
            assert.equal("inaccessible", failure.reason)
            assert.equal("first", failure.name)
        end)

        it("preserves callable nil-fill, tail, and flexible-result actions",
        function()
            local iname, rname =
                "api.Shape", "sample.Shape"
            local interface = types.Interface(iname, {}, {
                method(iname, "fill",
                    {types.Integer()}, {types.Option(types.Integer())}),
                method(iname, "tail",
                    {types.Integer(), types.Integer()}),
                method(iname, "missing", {}, {types.Value()}),
            })
            local fill = method(
                rname, "fill",
                {types.Integer(), types.Option(types.Integer())}, {},
                {}, false, types.Integer())
            local tail = method(
                rname, "tail",
                {types.Integer()}, {}, {},
                types.Integer(), false)
            local missing = method(rname, "missing", {}, {})
            local record = types.Record(
                rname, {}, {}, {
                    fill = fill,
                    tail = tail,
                    missing = missing,
                }, 0)

            local implementation = assert(
                types.interface_implementation(
                    record, interface, {visibility = "sample"}))
            assert.equal("nil_fill",
                implementation.methods[1]
                    .adjustment.arguments[2].kind)
            assert.equal("flex_to_optional_result",
                implementation.methods[1]
                    .adjustment.results[1].kind)
            assert.is_true(
                implementation.methods[1]
                    .adjustment.results[1].wrap_present)
            assert.equal("argument_to_tail",
                implementation.methods[2]
                    .adjustment.arguments[2].kind)
            assert.equal("empty_tail",
                implementation.methods[2]
                    .adjustment.arguments[3].kind)
            local missing_result = implementation.methods[3]
                .adjustment.results[1]
            assert.equal("nil_fill_result", missing_result.kind)
            assert.equal(1, missing_result.expected_index)
            assert.equal("Type.Value",
                missing_result.expected_type._tag)
            assert.is_nil(missing_result.adjustment)
        end)

        it("rejects non-method and coercion-only implementation slots",
        function()
            local iname, rname =
                "api.Required", "sample.Concrete"
            local required = types.Interface(iname, {}, {
                method(iname, "convert", {},
                    {types.Float()}),
            })
            local numeric_method = method(
                rname, "convert", {},
                {types.Integer()})
            local record = types.Record(
                rname, {}, {}, {convert = numeric_method}, 0)
            local implementation, failure =
                types.interface_implementation(
                    record, required, {visibility = "sample"})
            assert.is_false(implementation)
            assert.equal("incompatible", failure.reason)

            local field = types.Field(
                rname, "convert", types.Integer(), 0, false)
            local field_record =
                types.Record(rname, {field}, {}, {}, 1)
            implementation, failure =
                types.interface_implementation(
                    field_record, required,
                    {visibility = "sample"})
            assert.is_false(implementation)
            assert.equal("not_method", failure.reason)
            assert.is_true(failure.member == field)

            local static = types.StaticMethod(
                rname, "convert", {}, {types.Float()},
                false, false, {})
            local static_record =
                types.Record(rname, {}, {convert = static}, {}, 0)
            implementation, failure =
                types.interface_implementation(
                    static_record, required,
                    {visibility = "sample"})
            assert.is_false(implementation)
            assert.equal("not_method", failure.reason)
            assert.is_true(failure.member == static)
        end)

        it("does not recurse through concrete-to-Interface results",
        function()
            local iname, rname =
                "api.Cloneable", "sample.Concrete"
            local interface = types.Interface(iname, {}, {
                method(iname, "clone", {},
                    {types.Nominal(iname)}),
            })
            local concrete_result = method(
                rname, "clone", {},
                {types.Nominal(rname)})
            local record = types.Record(
                rname, {}, {}, {clone = concrete_result}, 0)

            local implementation, failure =
                types.interface_implementation(
                    record, interface, {visibility = "sample"})
            assert.is_false(implementation)
            assert.equal("incompatible", failure.reason)

            local interface_result = method(
                rname, "clone", {},
                {types.Nominal(iname)})
            record.methods.clone = interface_result
            implementation = assert(
                types.interface_implementation(
                    record, interface, {visibility = "sample"}))
            assert.is_true(implementation.exact)
        end)

        it("authorizes only a direct nominal wrapper coercion",
        function()
            local iname, rname =
                "api.Closer", "sample.Concrete"
            local required =
                method(iname, "close")
            local concrete =
                method(rname, "close")
            local interface =
                types.Interface(iname, {}, {required})
            local record = types.Record(
                rname, {}, {}, {close = concrete}, 0)
            local descriptors = {
                [iname] = interface,
                [rname] = record,
            }
            local calls = 0
            local policy = {
                visibility = "sample",
                interface_coercion = function(source, target, received)
                    calls = calls + 1
                    local implementation =
                        types.interface_implementation(
                            descriptors[source.fqtn],
                            descriptors[target.fqtn],
                            received)
                    return implementation
                        and implementation.methods
                end,
            }
            local source, target =
                types.Nominal(rname), types.Nominal(iname)

            assert.is_false(types.consistent(source, target))
            assert.is_false(types.coercion(source, target))
            local coercion = assert(types.coercion(
                source, target, policy))
            assert.equal("interface_wrapper", coercion.op)
            assert.is_true(coercion.source == source)
            assert.is_true(coercion.target == target)
            assert.is_true(
                coercion.methods[1].concrete == concrete)
            assert.equal(1, calls)

            assert.equal("direct_coercion",
                assert(types.assignment_adjustment(
                    source, target, policy)).kind)
            assert.equal(2, calls)
            assert.is_false(types.coercion(
                target, source, policy))
            assert.equal(3, calls)
            assert.is_false(types.coercion(
                types.Array(source, false),
                types.Array(target, false), policy))
            assert.is_false(types.callable_adjustment(
                types.Function({}, {source}, false, false, false),
                types.Function({}, {target}, false, false, false)))
            assert.equal(3, calls)

            local optional = assert(types.coercion(
                types.Option(source),
                types.Option(target), policy))
            assert.equal("option_map", optional.op)
            assert.equal("interface_wrapper", optional.inner.op)
            assert.equal(4, calls)
        end)
    end)

    describe("separated type relations", function()
        local function fn(params, results, varargtype, flexrettype)
            return types.Function(params or {}, results or {}, false,
                varargtype or false, flexrettype or false)
        end

        it("does not expose the retired aggregate relation APIs", function()
            assert.is_nil(types.compatible)
            assert.is_nil(types.coerceable)
            assert.is_nil(types.explicitly_coerceable)
        end)

        it("normalizes transparent aliases without following cycles",
        function()
            local cint = types.CInteger("int", true, 3, 32)
            local aliases = types.CTypedef("first",
                types.CTypedef("second",
                    types.CTypedef("third", cint)))
            assert.is_true(types.normalize(aliases) == cint)

            local qualified =
                types.CTypedef("const_int", cint, {"const"})
            assert.is_true(types.normalize(qualified) == cint)
        end)

        it("keeps relation classifications invariant under long aliases",
        function()
            local function c_chain(base)
                local result = base
                for index = 1, 64 do
                    result = types.CTypedef(
                        "c_alias_" .. index, result)
                end
                return result
            end

            local function classification(result)
                if not result then return false end
                return (result.kind or "") .. ":" .. (result.op or "")
            end

            local i, v =
                types.Integer(), types.Value()

            local ci = types.CInteger("int", true, 3, 32)
            local alias_ci = c_chain(ci)
            assert.is_true(types.normalize(alias_ci) == ci)
            assert.equal(types.consistent(ci, v),
                types.consistent(alias_ci, v))
            assert.equal(classification(types.dynamic_coercion(ci)),
                classification(types.dynamic_coercion(alias_ci)))
            assert.equal(classification(types.coercion(ci, i)),
                classification(types.coercion(alias_ci, i)))
            assert.equal(classification(types.written_cast(v, ci)),
                classification(types.written_cast(v, alias_ci)))

            local raw_pointer = types.CPointer(ci, {})
            local alias_pointer = c_chain(raw_pointer)
            assert.equal("explicit",
                assert(types.written_cast(v, alias_pointer)).op)
            assert.is_false(types.dynamic_coercion(alias_pointer))
        end)

        it("rejects cyclic alias graphs in every new relation", function()
            local c_a = types.CTypedef("c_a", false)
            local c_b = types.CTypedef("c_b", c_a)
            c_a.target = c_b

            local i, v = types.Integer(), types.Value()
            for _, cycle in ipairs({c_a, c_b}) do
                assert.is_nil(types.normalize(cycle))
                assert.is_false(
                    types.has_tvalue_representation(cycle))
                assert.is_false(types.has_sound_gradual_guard(cycle))
                assert.is_false(types.gradual_guard(cycle))
                assert.is_false(types.dynamic_coercion(cycle))
                assert.is_false(types.consistent(cycle, cycle))
                assert.is_false(types.consistent(cycle, v))
                assert.is_false(types.consistent(v, cycle))
                assert.is_false(types.coercion(cycle, cycle))
                assert.is_false(types.coercion(cycle, i))
                assert.is_false(types.coercion(i, cycle))
                assert.is_false(types.written_cast(cycle, cycle))
                assert.is_false(types.written_cast(v, cycle))
                assert.is_false(types.written_cast(cycle, v))
                assert.is_false(types.comparable(cycle, v))
                assert.is_false(
                    types.assignment_adjustment(cycle, i))
                assert.is_false(
                    types.assignment_adjustment(cycle, cycle))
                assert.is_false(types.callable_adjustment(
                    fn({cycle}), fn({i})))
                assert.is_false(types.consistent(
                    fn({}, {cycle}), fn({}, {i})))
            end
        end)

        it("defines a reflexive symmetric non-transitive consistency",
        function()
            local i, s, v = types.Integer(), types.String(), types.Value()
            local oi = types.Option(i)
            local samples = {
                i, s, v, oi,
                types.Array(i, false),
                types.Map(s, i),
                fn({i}, {s}),
                types.Nominal("sample.Box"),
            }
            for _, typ in ipairs(samples) do
                assert.is_true(types.consistent(typ, typ),
                    types.tostring(typ))
            end

            local pairs = {
                {i, v},
                {types.Array(i, false), types.Array(v, false)},
                {types.Map(s, i), types.Map(v, v)},
                {types.Option(i), types.Option(v)},
                {fn({i}, {v}), fn({v}, {i})},
            }
            for _, pair in ipairs(pairs) do
                assert.equal(
                    types.consistent(pair[1], pair[2]),
                    types.consistent(pair[2], pair[1]))
                assert.is_true(types.consistent(pair[1], pair[2]))
            end
            for _, left in ipairs(samples) do
                for _, right in ipairs(samples) do
                    assert.equal(
                        types.consistent(left, right),
                        types.consistent(right, left),
                        types.tostring(left) .. " ~ "
                            .. types.tostring(right))
                end
            end

            assert.is_true(types.consistent(i, v))
            assert.is_true(types.consistent(v, s))
            assert.is_false(types.consistent(i, s))
            assert.is_true(types.consistent(
                types.Array(i, false), types.Array(v, false)))
            assert.is_true(types.consistent(
                types.Array(v, false), types.Array(s, false)))
            assert.is_false(types.consistent(
                types.Array(i, false), types.Array(s, false)))
            assert.is_true(types.consistent(
                types.Map(i, i), types.Map(v, v)))
            assert.is_true(types.consistent(
                types.Map(v, v), types.Map(s, s)))
            assert.is_false(types.consistent(
                types.Map(i, i), types.Map(s, s)))
        end)

        it("keeps Array mutability invariant except for a written freeze",
        function()
            local i, f, v = types.Integer(), types.Float(), types.Value()
            local mutable_i = types.Array(i, false)
            local mutable_v = types.Array(v, false)
            local const_i = types.Array(i, true)
            local const_v = types.Array(v, true)

            assert.equal("{ integer }", types.tostring(mutable_i))
            assert.equal("const { integer }", types.tostring(const_i))
            assert.is_false(types.equals(mutable_i, const_i))
            assert.is_false(types.consistent(mutable_i, const_i))
            assert.is_true(types.consistent(mutable_i, mutable_v))
            assert.is_true(types.consistent(const_i, const_v))
            assert.is_false(types.assignment_adjustment(
                mutable_i, const_i))
            assert.is_false(types.assignment_adjustment(
                const_i, mutable_i))
            assert.is_false(types.comparable(mutable_i, const_i))

            local freeze = assert(types.written_cast(mutable_i, const_i))
            assert.equal("array_freeze", freeze.op)
            assert.equal("copy", freeze.mode)
            assert.is_true(freeze.allocation_free_test)
            assert.is_false(freeze.element_view)

            local gradual = assert(types.written_cast(mutable_i, const_v))
            assert.equal("array_freeze", gradual.op)
            assert.equal("gradual_view", gradual.element_view.kind)
            assert.is_false(types.written_cast(
                mutable_i, types.Array(f, true)))
            assert.is_false(types.written_cast(const_i, mutable_i))

            local const_guard = assert(types.gradual_guard(const_i))
            assert.equal("array", const_guard.op)
            assert.is_true(const_guard.isconst)
            local const_dynamic = assert(types.dynamic_coercion(const_i))
            assert.equal("array", const_dynamic.op)
            assert.is_true(const_dynamic.isconst)
            local mutable_dynamic = assert(
                types.dynamic_coercion(mutable_i))
            assert.is_false(mutable_dynamic.isconst)

            local serialized = types.serialize(const_i)
            assert.equal("Array(Integer(),true)", serialized)
            local rebuilt = assert(load(
                "return " .. serialized, "const-array", "t", types))()
            assert.is_true(types.equals(const_i, rebuilt))
        end)

        it("uses the exact missing-nil representation frontier", function()
            local cint = types.CInteger("int", true, 3, 32)
            for _, typ in ipairs({
                    types.Nil(), types.Value(),
                    types.Option(types.Integer()),
                    types.CPointer(cint, {}),
                }) do
                assert.is_true(types.accepts_missing_nil(typ),
                    types.tostring(typ))
            end
            for _, typ in ipairs({
                    types.Boolean(), types.Integer(), types.String(),
                    types.Array(types.Integer(), false),
                    types.COwned(cint, false),
                }) do
                assert.is_false(types.accepts_missing_nil(typ),
                    types.tostring(typ))
            end
        end)

        it("does not let malformed cycles prove non-identity consistency",
        function()
            local i = types.Integer()
            local short, wide = fn({i}), fn({i, i})
            local a, b, x, y = fn(), fn(), fn(), fn()
            a.params, b.params = {y, short}, {x, wide}
            a.rettypes, b.rettypes = {y}, {x}
            x.rettypes, y.rettypes = {a}, {b}

            assert.is_false(types.callable_adjustment(a, b))
            assert.is_false(types.callable_adjustment(b, a))
            assert.is_false(types.consistent(a, b))
            assert.is_false(types.consistent(b, a))

            -- Titan syntax cannot construct this graph: recursive source
            -- declarations reach a Type.Nominal leaf, and alias resolution
            -- rejects structural cycles. Keep the internal relation defensive
            -- when handed one directly.
            local p, q = fn(), fn()
            p.params = {p, types.Option(p)}
            q.params = {q}
            assert.is_false(types.equals(p, q))
            assert.is_false(types.has_sound_gradual_guard(p))
            assert.is_false(types.consistent(p, types.Value()))
            assert.is_false(types.callable_adjustment(p, q))
            assert.is_false(types.callable_adjustment(q, p))
            assert.is_false(types.consistent(p, q))
            assert.is_false(types.consistent(q, p))
        end)

        it("memoizes completed pairs in shared acyclic type DAGs",
        function()
            local left, right = types.Integer(), types.Value()
            local depth = 16
            for _ = 1, depth do
                left = types.Map(left, left)
                right = types.Map(right, right)
            end

            local normalize = types.normalize
            local calls = 0
            types.normalize = function(typ)
                calls = calls + 1
                return normalize(typ)
            end
            local ok, result = pcall(types.consistent, left, right)
            types.normalize = normalize

            assert.is_true(ok)
            assert.is_true(result)
            assert.is_true(calls < depth * 20,
                "completed pairs should be visited linearly")
        end)

        it("keeps automatic conversions out of consistency", function()
            local i, f = types.Integer(), types.Float()
            local ci = types.CInteger("int", true, 3, 32)
            local cf = types.CFloat("double")
            local oi = types.Option(i)

            local rejected = {
                {i, f},
                {i, oi},
                {types.Array(i, false), types.Array(f, false)},
                {types.Array(f, false), types.Array(cf, false)},
                {types.Map(i, i), types.Map(i, f)},
                {fn({}, {i}), fn({}, {oi})},
                {fn({}, {i}), fn({}, {f})},
                {fn({i}), fn({f})},
                {ci, i},
                {cf, f},
            }
            for _, pair in ipairs(rejected) do
                assert.is_false(types.consistent(pair[1], pair[2]),
                    types.tostring(pair[1]) .. " ~ "
                        .. types.tostring(pair[2]))
                assert.is_false(types.consistent(pair[2], pair[1]),
                    "symmetry for rejected conversion pair")
            end

            local raw_pointer = types.CPointer(ci, {})
            assert.is_false(types.consistent(raw_pointer, types.Value()))
            assert.is_false(types.consistent(types.Value(), raw_pointer))
        end)

        it("keeps future Interface wrapping as a direct nominal policy",
        function()
            local concrete = types.Nominal("sample.Concrete")
            local interface = types.Nominal("sample.Interface")
            local methods = { marker = "resolved at cast site" }
            local calls = 0
            local policy = {
                visibility = "sample",
                interface_coercion = function(source, target, received)
                    calls = calls + 1
                    assert.is_true(source == concrete)
                    assert.is_true(target == interface)
                    assert.is_true(received.visibility == "sample")
                    return methods
                end,
            }

            assert.is_false(types.consistent(concrete, interface))
            assert.is_false(types.coercion(concrete, interface))
            local coercion =
                assert(types.coercion(concrete, interface, policy))
            assert.equal("interface_wrapper", coercion.op)
            assert.is_true(coercion.source == concrete)
            assert.is_true(coercion.target == interface)
            assert.is_true(coercion.methods == methods)
            assert.equal(1, calls)

            assert.is_false(types.coercion(
                types.Array(concrete, false),
                types.Array(interface, false), policy))
            assert.is_false(types.callable_adjustment(
                fn({}, {concrete}), fn({}, {interface})))
            assert.equal(1, calls)
        end)

        it("does not consult operational relations from consistency",
        function()
            local saved = {
                coercion = types.coercion,
                dynamic = types.dynamic_coercion,
                written = types.written_cast,
            }
            local function forbidden()
                error("operational relation reached from consistency")
            end
            types.coercion = forbidden
            types.dynamic_coercion = forbidden
            types.written_cast = forbidden
            local ok, result = pcall(types.consistent,
                types.Array(types.Integer(), false),
                types.Array(types.Value(), false))
            types.coercion = saved.coercion
            types.dynamic_coercion = saved.dynamic
            types.written_cast = saved.written
            assert.is_true(ok)
            assert.is_true(result)
        end)

        it("returns named direct coercion plans without structural lifting",
        function()
            local i, f = types.Integer(), types.Float()
            local oi, of = types.Option(i), types.Option(f)
            local ci = types.CInteger("int", true, 3, 32)

            local numeric = assert(types.coercion(i, f))
            assert.equal("coercion", numeric.kind)
            assert.equal("integer_to_float", numeric.op)

            local wrap = assert(types.coercion(i, oi))
            assert.equal("option_wrap", wrap.op)
            assert.equal("identity", wrap.inner.kind)

            local force = assert(types.coercion(oi, i))
            assert.equal("option_force", force.op)
            assert.equal("identity", force.inner.kind)

            local mapped = assert(types.coercion(oi, of))
            assert.equal("option_map", mapped.op)
            assert.equal("integer_to_float", mapped.inner.op)

            assert.equal("c_integer_to_integer",
                assert(types.coercion(ci, i)).op)
            local raw_pointer = types.CPointer(ci, {})
            assert.equal("c_value_to_value",
                assert(types.coercion(raw_pointer, types.Value())).op)
            assert.equal("direct_coercion",
                assert(types.assignment_adjustment(
                    raw_pointer, types.Value())).kind)
            assert.is_false(
                types.coercion(types.Value(), raw_pointer))
            assert.is_false(types.coercion(i, i))
            assert.is_false(types.coercion(
                types.Array(i, false), types.Array(f, false)))
            assert.is_false(types.coercion(
                fn({}, {i}), fn({}, {f})))
        end)

        it("separates strict guards from dynamic coercions", function()
            local integer_guard =
                assert(types.gradual_guard(types.Integer()))
            assert.equal("gradual_guard", integer_guard.kind)
            assert.equal("integer", integer_guard.op)

            local option_guard =
                assert(types.gradual_guard(
                    types.Option(types.Boolean())))
            assert.equal("option", option_guard.op)
            assert.equal("boolean", option_guard.inner.op)

            local dynamic_integer =
                assert(types.dynamic_coercion(types.Integer()))
            assert.equal("dynamic_coercion", dynamic_integer.kind)
            assert.equal("integer", dynamic_integer.op)
            assert.equal("truthiness",
                assert(types.dynamic_coercion(types.Boolean())).op)

            local dynamic_option =
                assert(types.dynamic_coercion(
                    types.Option(types.Boolean())))
            assert.equal("option", dynamic_option.op)
            assert.equal("truthiness", dynamic_option.inner.op)

            local raw_pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            assert.is_false(types.has_sound_gradual_guard(raw_pointer))
            assert.is_false(types.gradual_guard(raw_pointer))
            assert.is_false(types.dynamic_coercion(raw_pointer))
            assert.is_true(types.has_sound_gradual_guard(
                types.Option(types.Integer())))

            assert.equal("array", assert(types.dynamic_coercion(
                types.Array(types.Integer(), false))).op)
            assert.equal("map", assert(types.dynamic_coercion(
                types.Map(types.String(), types.Integer()))).op)
            assert.equal("callable", assert(types.dynamic_coercion(
                fn({types.Integer()}, {types.String()}))).op)

            local blocked = {
                types.Option(raw_pointer),
                types.Array(raw_pointer, false),
                types.Array(types.Array(raw_pointer, false), false),
                types.Map(raw_pointer, types.String()),
                types.Map(types.String(), raw_pointer),
                types.Map(types.String(),
                    types.Array(raw_pointer, false)),
                fn({raw_pointer}, {types.Integer()}),
                fn({types.Integer()}, {raw_pointer}),
                fn({}, {}, raw_pointer),
                fn({}, {}, false, raw_pointer),
            }
            for _, target in ipairs(blocked) do
                assert.is_false(
                    types.has_sound_gradual_guard(target))
                assert.is_false(types.gradual_guard(target))
                assert.is_false(types.dynamic_coercion(target))
                -- The unsafe written exception is deliberately limited to a
                -- direct raw-pointer target; it must not tunnel through a
                -- gradual container or callable plan.
                assert.is_false(
                    types.written_cast(types.Value(), target))
            end
        end)

        it("classifies written casts independently", function()
            local i, f, v = types.Integer(), types.Float(), types.Value()
            local dynamic = assert(types.written_cast(v, i))
            assert.equal("written_cast", dynamic.kind)
            assert.equal("dynamic", dynamic.op)
            assert.equal("integer", dynamic.dynamic.op)

            local numeric = assert(types.written_cast(i, f))
            assert.equal("coercion", numeric.op)
            assert.equal("integer_to_float", numeric.coercion.op)

            local gradual = assert(types.written_cast(
                types.Array(i, false), types.Array(v, false)))
            assert.equal("gradual", gradual.op)
            assert.equal("array", gradual.guard.op)

            local raw_pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            local pointer = assert(types.written_cast(v, raw_pointer))
            assert.equal("explicit", pointer.op)
            assert.equal("unsafe_dynamic_c_pointer",
                pointer.conversion.op)
        end)

        it("returns directional callable shape actions", function()
            local i, s, v = types.Integer(), types.String(), types.Value()

            local ignored = assert(types.callable_adjustment(
                fn({i}), fn({i, s})))
            assert.equal("callable", ignored.kind)
            assert.equal("argument", ignored.arguments[1].kind)
            assert.equal("ignore_argument", ignored.arguments[2].kind)

            local nil_fill = assert(types.callable_adjustment(
                fn({i, types.Option(i)}), fn({i})))
            assert.equal("nil_fill", nil_fill.arguments[2].kind)
            assert.is_false(types.callable_adjustment(
                fn({i, i}), fn({i})))

            local tail = assert(types.callable_adjustment(
                fn({i}, {}, i), fn({i, i}, {}, i)))
            assert.equal("argument_to_tail", tail.arguments[2].kind)
            assert.equal("tail_to_tail", tail.arguments[3].kind)

            local projected = assert(types.callable_adjustment(
                fn({}, {}, false, i),
                fn({}, {types.Option(i)})))
            assert.equal(
                "flex_to_optional_result", projected.results[1].kind)
            assert.is_true(projected.results[1].wrap_present)
            assert.equal("hide_flex", projected.results[2].kind)

            local dynamic_projected = assert(types.callable_adjustment(
                fn({}, {}, false, v),
                fn({}, {types.Option(i)})))
            assert.falsy(
                dynamic_projected.results[1].wrap_present)
            assert.equal("gradual_view",
                dynamic_projected.results[1].adjustment.kind)

            local gradual = assert(types.callable_adjustment(
                fn({}, {i}), fn({}, {v})))
            assert.equal("gradual_view",
                gradual.results[1].adjustment.kind)

            local missing = assert(types.callable_adjustment(
                fn(), fn({}, {v, types.Option(i)})))
            assert.equal(2, #missing.results)
            for index, action in ipairs(missing.results) do
                assert.equal("nil_fill_result", action.kind)
                assert.equal(index, action.expected_index)
                assert.is_true(types.equals(
                    action.expected_type,
                    index == 1 and v or types.Option(i)))
                assert.is_nil(action.adjustment)
            end

            -- A flexible producer remains authoritative even when the target
            -- type itself accepts nil; nil-fill is only for a genuinely ended
            -- result shape.
            local flexible = assert(types.callable_adjustment(
                fn({}, {}, false, v), fn({}, {v})))
            assert.equal("flex_to_result", flexible.results[1].kind)

            assert.is_false(types.callable_adjustment(
                fn({}, {i}), fn({}, {types.Option(i)})))
            assert.is_false(types.callable_adjustment(
                fn({}, {i}), fn({}, {types.Float()})))
            assert.is_false(types.callable_adjustment(
                fn({types.Float()}), fn({i})))
        end)

        it("nil-fills only directly nil-accepting missing results",
        function()
            local i = types.Integer()
            local c_pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            local admitted = {
                types.Nil(),
                types.Value(),
                types.Option(i),
                c_pointer,
            }
            for index, expected in ipairs(admitted) do
                local adjustment = assert(types.callable_adjustment(
                    fn(), fn({}, {expected})),
                    "missing result case " .. tostring(index))
                assert.is_false(adjustment.exact)
                assert.equal(1, #adjustment.results)
                local action = adjustment.results[1]
                assert.equal("nil_fill_result", action.kind)
                assert.equal(1, action.expected_index)
                assert.is_true(types.equals(expected,
                    action.expected_type))
                assert.is_nil(action.adjustment)
            end

            local rejected = {
                types.Boolean(),
                i,
                types.Float(),
                types.String(),
                types.Nominal("sample.Record"),
                fn(),
            }
            for index, expected in ipairs(rejected) do
                assert.is_false(types.callable_adjustment(
                    fn(), fn({}, {expected})),
                    "required result case " .. tostring(index))
            end
        end)

        it("covers directional callable arity and tail adjustment",
        function()
            local i, s, v =
                types.Integer(), types.String(), types.Value()
            local oi = types.Option(i)
            local cases = {
                {
                    "short actual ignores expected fixed suffix",
                    fn({i}), fn({i, s}), true,
                },
                {
                    "long actual cannot nil-fill a required suffix",
                    fn({i, i}), fn({i}), false,
                },
                {
                    "actual integer tail accepts moved fixed integer",
                    fn({i}, {}, i), fn({i, i}), true,
                },
                {
                    "actual string tail rejects moved fixed integer",
                    fn({i}, {}, s), fn({i, i}), false,
                },
                {
                    "fixed actual ignores expected tail",
                    fn({i}), fn({i}, {}, i), true,
                },
                {
                    "matching input tails",
                    fn({i}, {}, i), fn({i}, {}, i), true,
                },
                {
                    "incompatible observed input tails",
                    fn({i}, {}, s), fn({i}, {}, i), false,
                },
                {
                    "nilable hidden actual fixed parameter",
                    fn({i, oi}), fn({i}), true,
                },
                {
                    "value hidden actual fixed parameter",
                    fn({i, v}), fn({i}), true,
                },
                {
                    "all hidden actual fixed parameters are checked",
                    fn({i, oi, s}), fn({i}), false,
                },
                {
                    "option coercion is not lifted into a tail transfer",
                    fn({i, oi}), fn({i}, {}, i), false,
                },
                {
                    "gradual tail transfer reaches a hidden option",
                    fn({i, oi}), fn({i}, {}, v), true,
                },
                {
                    "actual fixed result surplus is hidden",
                    fn({}, {i, s}), fn({}, {i}), true,
                },
                {
                    "actual fixed required-result deficit is rejected",
                    fn({}, {i}), fn({}, {i, i}), false,
                },
                {
                    "actual fixed nil-accepting result deficit is filled",
                    fn({}, {i}), fn({}, {i, v}), true,
                },
                {
                    "flex result projects into an optional fixed slot",
                    fn({}, {}, false, i), fn({}, {oi}), true,
                },
                {
                    "partial flex result reaches a required fixed slot",
                    fn({}, {}, false, i), fn({}, {i}), true,
                },
                {
                    "incompatible flex projection is rejected",
                    fn({}, {}, false, i), fn({}, {s}), false,
                },
                {
                    "finite expected results hide the actual tail",
                    fn({}, {i}, false, s), fn({}, {i}), true,
                },
                {
                    "expected result tail consumes a fixed suffix",
                    fn({}, {i, i}), fn({}, {i}, false, i), true,
                },
                {
                    "expected result tail rejects a fixed suffix",
                    fn({}, {i, s}), fn({}, {i}, false, i), false,
                },
                {
                    "open expected results accept an empty fixed actual",
                    fn(), fn({}, {}, false, i), true,
                },
                {
                    "matching result tails",
                    fn({}, {}, false, i),
                    fn({}, {}, false, i), true,
                },
                {
                    "incompatible result tails",
                    fn({}, {}, false, s),
                    fn({}, {}, false, i), false,
                },
                {
                    "finite zero-result type hides the actual tail",
                    fn({}, {}, false, s), fn(), true,
                },
            }
            for _, case in ipairs(cases) do
                assert.equal(case[4],
                    types.callable_adjustment(
                        case[2], case[3]) ~= false,
                    case[1])
            end
        end)

        it("keeps nested callable adjustment directional", function()
            local i = types.Integer()
            local short = fn({i})
            local wide = fn({i, i})

            local accepted = types.callable_adjustment(
                fn({wide}), fn({short}))
            local rejected = types.callable_adjustment(
                fn({short}), fn({wide}))
            assert.truthy(accepted)
            assert.falsy(rejected)
            assert.equal("callable",
                accepted.arguments[1].adjustment.kind)
        end)

        it("classifies assignment without lifting direct coercions",
        function()
            local i, f, v = types.Integer(), types.Float(), types.Value()
            assert.equal("identity",
                assert(types.assignment_adjustment(i, i)).kind)

            local numeric =
                assert(types.assignment_adjustment(i, f))
            assert.equal("direct_coercion", numeric.kind)
            assert.equal("integer_to_float", numeric.coercion.op)

            local inject =
                assert(types.assignment_adjustment(i, v))
            assert.equal("gradual_view", inject.kind)
            assert.equal("inject", inject.op)

            local project =
                assert(types.assignment_adjustment(v, i))
            assert.equal("project", project.op)
            assert.equal("integer", project.guard.op)

            assert.equal("direct_coercion",
                assert(types.assignment_adjustment(
                    i, types.Option(i))).kind)
            assert.equal("gradual_view",
                assert(types.assignment_adjustment(
                    types.Array(i, false),
                    types.Array(v, false))).kind)
            assert.is_false(types.assignment_adjustment(
                types.Array(i, false), types.Array(f, false)))
            assert.is_false(types.assignment_adjustment(
                fn({}, {i}), fn({}, {types.Option(i)})))
            assert.equal("callable",
                assert(types.assignment_adjustment(
                    fn({}, {i}), fn({}, {v}))).kind)
        end)

        it("makes equality comparability symmetric", function()
            local i, f, v = types.Integer(), types.Float(), types.Value()
            assert.equal("numeric", assert(types.comparable(i, f)).op)
            assert.equal("numeric", assert(types.comparable(f, i)).op)
            local iv = assert(types.comparable(i, v))
            local vi = assert(types.comparable(v, i))
            assert.equal("consistent", iv.op)
            assert.equal("inject", iv.left_adjustment.op)
            assert.equal("consistent", vi.op)
            assert.equal("inject", vi.right_adjustment.op)
            assert.is_false(types.comparable(i, types.String()))
            local pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            assert.is_false(types.comparable(pointer, v))
            assert.is_false(types.comparable(v, pointer))

            local short = fn({i}, {i})
            local wide = fn({i, i}, {i})
            assert.is_truthy(types.callable_adjustment(short, wide))
            assert.is_false(types.callable_adjustment(wide, short))
            local short_wide = assert(types.comparable(short, wide))
            local wide_short = assert(types.comparable(wide, short))
            assert.equal("consistent", short_wide.op)
            assert.equal("consistent", wide_short.op)
        end)
    end)

    it("compares functions of different input arity", function()
        local s = types.String()
        local f1 = types.Function({}, {s}, false, false, false)
        local f2 = types.Function({s}, {s}, false, false, false)
        local f3 = types.Function({s, s}, {s}, false, false, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("compares functions of different output arity", function()
        local s = types.String()
        local f1 = types.Function({s}, {}, false, false, false)
        local f2 = types.Function({s}, {s}, false, false, false)
        local f3 = types.Function({s}, {s, s}, false, false, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("pretty-prints a zero-return () function as `-> ()`", function()
        assert.same("() -> ()", types.tostring(types.Function({}, {}, false, false, false)))
        assert.same("(integer) -> ()",
            types.tostring(types.Function({types.Integer()}, {}, false, false, false)))
    end)

    it("distinguishes a zero-return () function from a nil-returning one", function()
        local void = types.Function({types.Integer()}, {}, false, false, false)
        local nilret = types.Function({types.Integer()}, {types.Nil()}, false, false, false)
        assert.falsy(types.equals(void, nilret))
        assert.same("(integer) -> nil", types.tostring(nilret))
    end)

    it("pretty-prints higher-order and function-returning-function types", function()
        local int = types.Integer()
        local intfn = types.Function({int}, {int}, false, false, false)
        -- (integer -> integer, integer) -> integer
        assert.same("((integer) -> integer, integer) -> integer",
            types.tostring(types.Function({intfn, int}, {int}, false, false, false)))
        -- (integer) -> ((integer) -> integer)
        assert.same("(integer) -> ((integer) -> integer)",
            types.tostring(types.Function({int}, {intfn}, false, false, false)))
    end)

    it("treats consistent-but-not-equal function types distinctly", function()
        local exact = types.Function({types.Integer()}, {types.Integer()}, false, false, false)
        local valued = types.Function({types.Value()}, {types.Integer()}, false, false, false)
        assert.truthy(types.consistent(exact, valued))
        assert.truthy(types.consistent(valued, exact))
        -- but they are not equal (so a fast-path tag match must not be assumed)
        assert.falsy(types.equals(exact, valued))
    end)

    it("round-trips nested function types through serialize/load", function()
        local int = types.Integer()
        local nested = types.Function(
            {types.Function({int}, {int}, false, false, false), int},
            {types.Function({}, {}, false, false, false)}, false, false, false)
        local s = types.serialize(nested)
        local rebuilt = load("return " .. s, "t", "t", types)()
        assert.truthy(types.equals(nested, rebuilt))
    end)

    it("serializes an explicit absent tail and round-trips a flexible tail", function()
        local fixed = types.Function({}, {}, false, false, false)
        assert.same("Function({},{},false,false,false)",
            types.serialize(fixed))

        local flex = types.Function({types.String()}, {types.Boolean()}, false,
            types.Integer(), types.Value())
        local rebuilt = load(
            "return " .. types.serialize(flex), "t", "t", types)()
        assert.truthy(types.equals(flex, rebuilt))
        assert.same(types.Value(), rebuilt.flexrettype)
    end)

    it("round-trips callable declaration parameter names", function()
        local ftype = types.Function(
            {types.Integer(), types.String()}, {types.Boolean()}, false, false,
            false)
        local member = types.ModuleMember(
            "sample", "choose", ftype, {"repeat", "label"})
        local rebuilt = load(
            "return " .. types.serialize(member), "t", "t", types)()

        assert.same({"repeat", "label"}, rebuilt.paramnames)
        assert.truthy(types.equals(ftype, rebuilt.type))
    end)

    it("distinguishes known-empty and unavailable declaration names", function()
        local ftype = types.Function({}, {}, false, false, false)
        local known = types.ModuleMember("sample", "known", ftype, {})
        local unavailable = types.ModuleMember(
            "sample", "unavailable", ftype, false)

        local rebuilt_known = load(
            "return " .. types.serialize(known), "t", "t", types)()
        local rebuilt_unavailable = load(
            "return " .. types.serialize(unavailable), "t", "t", types)()

        assert.same({}, rebuilt_known.paramnames)
        assert.is_false(rebuilt_unavailable.paramnames)
    end)

    it("round-trips record method and static parameter names", function()
        local int = types.Integer()
        local method = types.Method("sample.Box", "move",
            {int, int}, {}, false, false, {"dx", "dy"})
        local static = types.StaticMethod("sample.Box", "new",
            {int, int}, {types.Nominal("sample.Box")}, false, false,
            {"x", "y"})
        local record = types.Record("sample.Box", {},
            {new = static}, {move = method}, 0)
        local rebuilt = load(
            "return " .. types.serialize(record), "t", "t", types)()

        assert.same({"dx", "dy"}, rebuilt.methods.move.paramnames)
        assert.same({"x", "y"}, rebuilt.functions.new.paramnames)
    end)

    it("round-trips public union metadata with absolute variant indices",
    function()
        local fqtn = "sample.Message"
        local result = types.Nominal(fqtn)
        local quit = types.Variant(fqtn, "quit", false, 0)
        local hidden = types.Variant(fqtn, "hidden", types.Integer(), 1)
        hidden.islocal = true
        local write = types.Variant(fqtn, "write", types.String(), 2)

        local quit_constructor = types.StaticMethod(
            fqtn, "quit", {}, {result}, false, false, false)
        local hidden_constructor = types.StaticMethod(
            fqtn, "hidden", {types.Integer()}, {result},
            false, false, false)
        hidden_constructor.islocal = true
        local write_constructor = types.StaticMethod(
            fqtn, "write", {types.String()}, {result},
            false, false, false)
        local inspect = types.Method(
            fqtn, "inspect", {}, {types.String()}, false, false, {})
        local private = types.Method(
            fqtn, "private", {}, {}, false, false, {})
        private.islocal = true

        local union = types.Union(fqtn, {quit, hidden, write}, {
            write = write_constructor,
            hidden = hidden_constructor,
            quit = quit_constructor,
        }, {
            private = private,
            inspect = inspect,
        }, 3)
        local projection, projection_error =
            types.validate_union_source_projection(union)
        assert.truthy(projection, projection_error)
        assert.same({quit, write},
            {projection.variants[1], projection.variants[2]})
        assert.is_nil(projection.variants.hidden)
        assert.is_nil(projection.functions.hidden)

        hidden_constructor.islocal = false
        local invalid, invalid_error =
            types.validate_union_source_projection(union)
        assert.falsy(invalid)
        assert.match("disagree on locality", invalid_error)
        hidden_constructor.islocal = true

        local rebuilt = assert(load(
            "return " .. types.serialize(union), "t", "t", types))()
        local rebuilt_again = assert(load(
            "return " .. types.serialize(union), "t", "t", types))()

        assert.equal(3, rebuilt.nvariants)
        assert.equal(2, #rebuilt.variants)
        assert.equal(0, rebuilt.variants[1].index)
        assert.equal(2, rebuilt.variants[2].index)
        assert.is_true(rebuilt.variants.quit == rebuilt.variants[1])
        assert.is_true(rebuilt.variants.write == rebuilt.variants[2])
        assert.is_nil(rebuilt.variants.hidden)
        assert.is_nil(rebuilt.functions.hidden)
        assert.is_nil(rebuilt.methods.private)
        assert.is_false(rebuilt.functions.quit.paramnames)
        assert.is_false(rebuilt.functions.write.paramnames)
        assert.truthy(types.equals(types.String(),
            rebuilt.variants.write.payload))
        assert.truthy(types.equals(rebuilt, rebuilt_again))
        rebuilt_again.nvariants = 4
        assert.falsy(types.equals(rebuilt, rebuilt_again))
        assert.equal(fqtn, types.tostring(rebuilt))
        assert.equal(
            fqtn .. ".write", types.tostring(rebuilt.variants.write))
    end)

    it("distinguishes an empty union variant from a nil payload", function()
        local fqtn = "sample.Maybe"
        local empty = types.Variant(fqtn, "empty", false, 0)
        local explicit_nil = types.Variant(fqtn, "nil_value", types.Nil(), 1)
        local rebuilt = assert(load("return " .. types.serialize(types.Union(
            fqtn, {empty, explicit_nil}, {}, {}, 2)),
            "t", "t", types))()

        assert.is_false(rebuilt.variants.empty.payload)
        assert.equal("Type.Nil", rebuilt.variants.nil_value.payload._tag)
    end)

    it("keeps variant descriptors out of value type relations", function()
        local first = types.Variant(
            "sample.Message", "write", types.String(), 0)
        local second = types.Variant(
            "sample.Message", "write", types.String(), 0)
        local value = types.Value()

        assert.truthy(types.equals(first, second),
            "metadata comparison still needs structural equality")
        assert.falsy(types.consistent(first, second))
        assert.falsy(types.consistent(first, value))
        assert.falsy(types.consistent(value, first))
        assert.falsy(types.coercion(first, value))
        assert.falsy(types.coercion(value, first))
        assert.falsy(types.written_cast(first, value))
        assert.falsy(types.written_cast(value, first))
        assert.falsy(types.assignment_adjustment(first, value))
        assert.falsy(types.dynamic_coercion(first))
        assert.falsy(types.has_tvalue_representation(first))
    end)

    it("rejects malformed source-union projections", function()
        local invalid, invalid_error =
            types.validate_union_source_projection(types.Integer())
        assert.falsy(invalid)
        assert.match("descriptor is not a union", invalid_error)

        local function source_union(payload)
            local fqtn = "sample.Source"
            local variant = types.Variant(
                fqtn, "only", payload, 0)
            local constructor = types.StaticMethod(
                fqtn, "only",
                payload == false and {} or {payload},
                {types.Nominal(fqtn)}, false, false, false)
            return types.Union(
                fqtn, {variant}, {only = constructor}, {}, 1),
                variant, constructor
        end

        local cases = {
            {
                pattern = "variant 'only' has no matching constructor",
                mutate = function(union)
                    union.functions.only = nil
                end,
            },
            {
                pattern = "empty variant 'only' has a payload constructor",
                mutate = function(_, _, constructor)
                    constructor.params = {types.Integer()}
                end,
            },
            {
                payload = types.String(),
                pattern = "payload variant 'only' has a mismatched "
                    .. "constructor",
                mutate = function(_, _, constructor)
                    constructor.params = {types.Integer()}
                end,
            },
            {
                pattern = "variant 'only' was not projected with its "
                    .. "constructor",
                mutate = function(union, _, constructor)
                    union.islocal = true
                    constructor.islocal = true
                end,
            },
            {
                pattern = "local union publishes function 'inspect'",
                mutate = function(union, variant, constructor)
                    union.islocal = true
                    variant.islocal = true
                    constructor.islocal = true
                    union.functions.inspect = types.StaticMethod(
                        union.name, "inspect", {}, {},
                        false, false, false)
                end,
            },
            {
                pattern = "local union publishes method 'inspect'",
                mutate = function(union, variant, constructor)
                    union.islocal = true
                    variant.islocal = true
                    constructor.islocal = true
                    union.methods.inspect = types.Method(
                        union.name, "inspect", {}, {},
                        false, false, false)
                end,
            },
        }

        for _, case in ipairs(cases) do
            local union, variant, constructor =
                source_union(case.payload or false)
            case.mutate(union, variant, constructor)
            invalid, invalid_error =
                types.validate_union_source_projection(union)
            assert.falsy(invalid,
                case.pattern .. ": " .. tostring(invalid_error))
            assert.match(case.pattern, invalid_error)
        end
    end)

    it("round-trips record method and static flexible return tails", function()
        local method = types.Method("sample.Box", "items", {}, {}, false,
            types.String(), {"unused"})
        local static = types.StaticMethod("sample.Box", "lookup", {},
            {types.Boolean()}, false, types.Integer(), {})
        local record = types.Record("sample.Box", {},
            {lookup = static}, {items = method}, 0)
        local rebuilt = load(
            "return " .. types.serialize(record), "t", "t", types)()

        assert.same(types.String(), rebuilt.methods.items.flexrettype)
        assert.same(types.Integer(), rebuilt.functions.lookup.flexrettype)
        assert.same({"unused"}, rebuilt.methods.items.paramnames)
    end)

    it("keeps declaration names out of structural function identity", function()
        local left = types.ModuleMember("sample", "f",
            types.Function({types.Integer()}, {}, false, false, false), {"left"})
        local right = types.ModuleMember("sample", "f",
            types.Function({types.Integer()}, {}, false, false, false), {"right"})

        assert.truthy(types.equals(left.type, right.type))
        assert.equal(types.serialize(left.type), types.serialize(right.type))
        assert.equal(types.tostring(left.type), types.tostring(right.type))
    end)

    it("reports nested function types as garbage collected", function()
        local int = types.Integer()
        local hof = types.Function(
            {types.Function({int}, {int}, false, false, false)},
            {int}, false, false, false)
        assert.truthy(types.is_gc(hof))
        assert.truthy(types.is_gc(types.Function({}, {}, false, false, false)))
    end)

    describe("C FFI types", function()
        local function cint()
            return types.CInteger("int", true, 3, 32)
        end

        it("constructs and pretty-prints the planned C vocabulary", function()
            local int = cint()
            assert.same("Type.CInteger", int._tag)
            assert.same("int", types.tostring(int))
            assert.same("void", types.tostring(types.CVoid()))
            assert.same("bool", types.tostring(
                types.CInteger("_Bool", false, 0, 8)))
            assert.same("foreign float",
                types.tostring(types.CFloat("float")))
            assert.same("double", types.tostring(types.CFloat("double")))
            assert.same("const *int", types.tostring(types.CPointer(int, {"const"})))
            assert.same("int[4]", types.tostring(types.CArray(int, 4)))
            assert.same("const int[4]",
                types.tostring(types.CArray(int, 4, {"const"})))
            assert.same("foreign  (int, ...) -> double", types.tostring(
                types.CFunction({int}, types.CFloat("double"), true, "cdecl")))
            assert.same("struct point", types.tostring(
                types.CStruct("struct point", "point", false, {}, true, false)))
            assert.same("union value", types.tostring(
                types.CUnion("union value", "value", false, {}, true)))
            assert.same("x: int", types.tostring(
                types.CField(false, "x", int, false, false)))
            assert.same("foreign size_t", types.tostring(types.CTypedef("size_t", int)))
            assert.same("owned *int",
                types.tostring(types.COwned(int, false)))
            assert.same("owned int[]",
                types.tostring(types.COwned(int, true)))
        end)

        it("uses CModule as the public foreign module type", function()
            local mod = types.CModule("stdio.h", { printf = cint() }, {})
            assert.same("Type.CModule", mod._tag)
            assert.same("stdio.h", mod.name)
            assert.same("C module stdio.h", types.tostring(mod))
            assert.same(nil, types.ForeignModule)
        end)

        it("keeps C compatibility structural across source scopes", function()
            local left = types.CPointer(cint(), {})
            local right = types.CPointer(cint(), {})
            left._ffi_scope = "left"
            right._ffi_scope = "right"

            assert.truthy(types.equals(left, right))
            assert.truthy(types.c_declaration_type_equals(left, right))
        end)

        it("compares C types by exact C identity", function()
            local int = cint()
            local uint = types.CInteger("unsigned int", false, 3, 32)
            assert.truthy(types.equals(int, cint()))
            assert.falsy(types.equals(int, uint))
            assert.truthy(types.equals(
                types.CPointer(int, {"const"}),
                types.CPointer(cint(), {"const"})))
            assert.falsy(types.equals(
                types.CPointer(int, {"const"}),
                types.CPointer(cint(), {})))
            assert.truthy(types.equals(
                types.CArray(int, 3, {"const"}),
                types.CArray(cint(), 3, {"const"})))
            assert.falsy(types.equals(
                types.CArray(int, 3, {"const"}),
                types.CArray(cint(), 3)))
            assert.truthy(types.equals(
                types.CFunction({int}, types.CVoid(), false, "cdecl"),
                types.CFunction({cint()}, types.CVoid(), false, "cdecl")))
            assert.falsy(types.equals(int, types.Integer()))
            assert.falsy(types.consistent(int, types.Integer()))
            assert.equal("c_integer_to_integer",
                assert(types.coercion(int, types.Integer())).op)

            local enum_left = cint()
            enum_left._c_enum_identity = "enum:/tmp/one.h:E"
            local enum_right = types.CInteger(
                "unsigned int", false, 3, 32)
            enum_right._c_enum_identity = "enum:/tmp/one.h:E"
            local enum_other = cint()
            enum_other._c_enum_identity = "enum:/tmp/two.h:E"
            assert.truthy(types.equals(enum_left, enum_right))
            assert.falsy(types.equals(enum_left, enum_other))
            assert.falsy(types.equals(enum_left, int))

            local enumerator = cint()
            enumerator._c_enum_identity = "enumerator:/tmp/one.h:A"
            enumerator._c_enum_owner = enum_left
            assert.equal("c_enum_integer",
                assert(types.coercion(enumerator, enum_left)).op)
            assert.falsy(types.coercion(enumerator, enum_other))
            assert.falsy(types.coercion(enumerator, int))
            assert.falsy(types.coercion(enum_left, enumerator))
        end)

        it("collects only headers in a rendered C declaration graph",
        function()
            local h1 = { rendered = '"/tmp/origin-one.h"' }
            local h2 = { rendered = '<origin-two.h>' }
            local h3 = { rendered = '<hidden-field.h>' }
            local int = cint()
            local alias = types.CTypedef("origin_int", int)
            alias._c_origin_header = h1
            local owner = types.CStruct(
                nil, "origin_owner", nil, {}, true, false)
            owner._c_origin_header = h2
            local pointer = types.CPointer(owner, {})
            owner.fields[1] = types.CField(
                owner, "next", pointer, false, false)
            local callback = types.CFunction(
                { types.CPointer(alias, {}) },
                types.CPointer(owner, {}), false, false)

            local includes = types.c_ffi_includes(callback)
            assert.equal(2, #includes)
            assert.equal(h1, includes[1])
            assert.equal(h2, includes[2])

            local hidden = types.CStruct(
                nil, "hidden_owner", nil, {}, true, false)
            hidden._c_origin_header = h2
            local hidden_type = types.CTypedef("hidden_field", int)
            hidden_type._c_origin_header = h3
            hidden.fields[1] = types.CField(
                hidden, "field", hidden_type, false, false)
            assert.same({ h2 }, types.c_ffi_includes(hidden))

            local owned = types.COwned(hidden, false)
            owned._c_origin_header = h2
            assert.same({}, types.c_ffi_includes(owned))

            local function_type = types.Function(
                { int }, { int }, false, false, false)
            types.mark_c_ffi_include(function_type, h1)
            assert.is_nil(function_type._c_origin_header)
            assert.is_nil(int._c_origin_header)

            local unrelated = types.Record(
                "origin.Unrelated", {}, {}, {}, 0)
            unrelated.hidden = callback
            assert.same({}, types.c_ffi_includes(unrelated))
        end)

        it("compares C function signatures through aliases and qualifiers",
        function()
            local int = cint()
            local first_int = types.CTypedef("ffi_first_int", int)
            local second_int = types.CTypedef("ffi_second_int", cint())
            local first = types.CFunction(
                {first_int}, first_int, false, "cdecl")
            local second = types.CFunction(
                {second_int}, second_int, false, "cdecl")

            assert.is_true(types.c_function_types_equal(first, second))
            assert.is_true(types.equals(
                types.CPointer(first, {}),
                types.CPointer(second, {})))

            local first_callback =
                types.CTypedef("ffi_first_callback",
                    types.CPointer(first, {}))
            local second_callback =
                types.CTypedef("ffi_second_callback",
                    types.CPointer(second, {}))
            assert.is_true(types.equals(
                types.CPointer(first_callback, {}),
                types.CPointer(second_callback, {})))

            local const_return = types.CFunction(
                {second_int}, second_int, false, "cdecl")
            const_return._return_declaration_qualifiers = {"const"}
            assert.equal("foreign  (foreign ffi_second_int) -> foreign ffi_second_int",
                types.tostring(const_return))
            assert.is_false(types.c_function_types_equal(
                first, const_return))
            assert.is_false(types.equals(
                types.CPointer(first, {}),
                types.CPointer(const_return, {})))

            local mutable_pointer =
                types.CPointer(first_int, {})
            local const_pointer =
                types.CPointer(second_int, {"const"})
            local takes_mutable = types.CFunction(
                {mutable_pointer}, types.CVoid(), false, "cdecl")
            local takes_const = types.CFunction(
                {const_pointer}, types.CVoid(), false, "cdecl")
            assert.is_false(types.c_function_types_equal(
                takes_mutable, takes_const))
            assert.is_false(types.equals(
                types.CPointer(
                    types.CTypedef("ffi_mutable_callback",
                        types.CPointer(takes_mutable, {})), {}),
                types.CPointer(
                    types.CTypedef("ffi_const_callback",
                        types.CPointer(takes_const, {})), {})))

            local top_const_pointer =
                types.CTypedef("ffi_const_pointer",
                    types.CPointer(first_int, {}), {"const"})
            local top_plain_pointer =
                types.CPointer(second_int, {})
            assert.is_true(types.c_function_types_equal(
                types.CFunction(
                    {top_const_pointer}, types.CVoid(), false, "cdecl"),
                types.CFunction(
                    {top_plain_pointer}, types.CVoid(), false, "cdecl")))

            local const_void =
                types.CFunction({}, types.CVoid(), false, "cdecl")
            const_void._return_declaration_qualifiers = {"const"}
            assert.is_false(types.c_function_types_equal(
                const_void,
                types.CFunction({}, types.CVoid(), false, "cdecl")))
            local const_void_alias =
                types.CTypedef("ffi_const_void", types.CVoid(), {"const"})
            assert.is_true(types.c_function_types_equal(
                const_void,
                types.CFunction(
                    {}, const_void_alias, false, "cdecl")))

            local first_value =
                types.Function({first_int}, {first_int},
                    false, false, false)
            local second_value =
                types.Function({second_int}, {second_int},
                    false, false, false)
            -- Titan/Lua function identity follows its callable value shape; it
            -- does not borrow C declaration compatibility or qualifiers.
            assert.is_false(types.equals(first_value, second_value))
            assert.is_false(types.equals(first, first_value))
            assert.is_false(types.consistent(first, first_value))
            assert.is_false(types.callable_adjustment(first, first_value))
            assert.is_false(types.callable_adjustment(first_value, first))
            assert.equal("foreign  () -> void", types.tostring(const_void))

            local unknown_array =
                types.CArray(first_int, nil)
            local known_array =
                types.CArray(second_int, 7)
            assert.is_true(types.c_function_types_equal(
                types.CFunction({
                    types.CPointer(unknown_array, {}),
                }, types.CVoid(), false, "cdecl"),
                types.CFunction({
                    types.CPointer(known_array, {}),
                }, types.CVoid(), false, "cdecl")))
            assert.is_false(types.c_function_types_equal(
                types.CFunction({
                    types.CPointer(types.CArray(first_int, 6), {}),
                }, types.CVoid(), false, "cdecl"),
                types.CFunction({
                    types.CPointer(known_array, {}),
                }, types.CVoid(), false, "cdecl")))
        end)

        it("resolves C typedef chains", function()
            local int = cint()
            local size_t = types.CTypedef("size_t", int)
            local alias = types.CTypedef("alias_size_t", size_t)
            assert.same(int, types.resolve_c_typedef(alias))
            assert.same(int, types.normalize(alias))
            assert.truthy(types.consistent(alias, int))
            assert.truthy(types.equals(
                types.CTypedef("size_t", int),
                types.CTypedef("size_t", alias)))
        end)

        it("treats borrowed C pointers as nullable but owned C values as userdata", function()
            local ptr = types.CPointer(cint(), {})
            local owned = types.COwned(cint(), 1)

            assert.falsy(types.consistent(ptr, types.Nil()))
            assert.falsy(types.consistent(types.Nil(), ptr))
            assert.equal("nil_to_c_pointer",
                assert(types.coercion(types.Nil(), ptr)).op)
            assert.falsy(types.coercion(ptr, types.Nil()))
            assert.falsy(types.consistent(owned, types.Nil()))
            assert.falsy(types.consistent(types.Nil(), owned))
        end)

        it("uses ordinary option wrapping and unwrapping for owned C values",
        function()
            local owner = types.COwned(cint(), false)
            local optional = types.Option(owner)

            assert.equal("option_wrap",
                assert(types.coercion(owner, optional)).op)
            assert.equal("option_force",
                assert(types.coercion(optional, owner)).op)
            assert.equal("option_nil",
                assert(types.coercion(types.Nil(), optional)).op)
        end)

        it("distinguishes structural C provenance from direct C values",
        function()
            local owner = types.COwned(cint(), false)
            local owners = types.Array(owner, false)
            local by_name = types.Map(types.String(), owner)
            local callback = types.Function(
                { owner }, { owner }, false, false, false)

            assert.truthy(types.is_c(owners))
            assert.truthy(types.is_c(by_name))
            assert.falsy(types.is_c(callback))
            assert.truthy(types.contains_c_ffi_type(callback))
            assert.is_nil(types.first_non_exportable_type(callback))
            assert.falsy(types.is_direct_c(owners))
            assert.falsy(types.is_direct_c(by_name))
            assert.falsy(types.is_direct_c(callback))

            for _, boxed in ipairs({ owners, by_name, callback }) do
                assert.truthy(types.consistent(boxed, types.Value()))
                assert.truthy(types.consistent(types.Value(), boxed))
                assert.equal("inject", assert(
                    types.assignment_adjustment(
                        boxed, types.Value())).op)
                assert.equal("project", assert(
                    types.assignment_adjustment(
                        types.Value(), boxed)).op)
            end
        end)

        it("allows options only for types with a TValue representation",
        function()
            local int = cint()
            local owner = types.COwned(int, false)
            local object_pointer = types.CPointer(int, {})
            local aggregate = types.CStruct(
                "struct point", "point", false, {}, true, false)
            local direct_function = types.CFunction(
                { int }, int, false, "cdecl")
            local function_pointer =
                types.CPointer(direct_function, {})

            assert.truthy(types.has_tvalue_representation(owner))
            assert.truthy(types.has_tvalue_representation(object_pointer))
            assert.truthy(types.has_tvalue_representation(
                types.Array(owner, false)))
            assert.truthy(types.has_tvalue_representation(
                types.Option(owner)))
            assert.falsy(types.has_tvalue_representation(aggregate))
            assert.falsy(types.has_tvalue_representation(direct_function))
            assert.falsy(types.has_tvalue_representation(function_pointer))
        end)

        it("does not decay an optional owner into an optional pointer",
        function()
            local int = cint()
            local optional_owner =
                types.Option(types.COwned(int, false))
            local optional_pointer =
                types.Option(types.CPointer(int, {}))

            assert.falsy(types.coercion(
                optional_owner, optional_pointer))
            assert.falsy(types.consistent(
                optional_pointer, optional_owner))
        end)

        it("allows only soundly guardable C values through value", function()
            local int = cint()
            local ptr = types.CPointer(int, {})
            local arr = types.CArray(int, 4)
            local owned = types.COwned(int, true)
            local aggregate = types.CStruct("struct point", "point", false, {}, true, false)

            assert.truthy(types.consistent(int, types.Value()))
            assert.truthy(types.consistent(types.Value(), int))
            assert.falsy(types.consistent(ptr, types.Value()))
            assert.falsy(types.consistent(types.Value(), ptr))
            assert.falsy(types.consistent(arr, types.Value()))
            assert.falsy(types.consistent(types.Value(), arr))
            assert.truthy(types.consistent(owned, types.Value()))
            assert.truthy(types.consistent(types.Value(), owned))
            assert.falsy(types.consistent(aggregate, types.Value()))
            assert.falsy(types.consistent(types.Value(), aggregate))
            assert.equal("explicit", assert(types.written_cast(
                types.Value(), ptr)).op)
        end)

        it("recognizes only counted owned character arrays as binary strings",
        function()
            local char =
                types.CInteger("char", true, 1, 8)
            local signed =
                types.CInteger("signed char", true, 1, 8)
            local unsigned =
                types.CInteger("unsigned char", false, 1, 8)
            local alias = types.CTypedef("ffi_byte", unsigned)

            assert.is_true(types.is_counted_c_character_owner(
                types.COwned(char, true)))
            assert.is_true(types.is_counted_c_character_owner(
                types.COwned(signed, true)))
            assert.is_true(types.is_counted_c_character_owner(
                types.COwned(alias, true)))
            assert.is_false(types.is_counted_c_character_owner(
                types.COwned(char, false)))
            assert.is_false(types.is_counted_c_character_owner(
                types.COwned(cint(), true)))
        end)

        it("does not take an automatic C address of a dynamic value",
        function()
            local const_void_pointer =
                types.CPointer(types.CVoid(), {"const"})
            local tvalue = types.CStruct(
                "TValue", "TValue", false, {}, true, false)
            local const_tvalue_pointer =
                types.CPointer(tvalue, {"const"})
            local dynamic = types.Value()

            assert.is_false(types.c_address_coerceable(
                dynamic, const_void_pointer))
            assert.is_false(types.c_address_coerceable(
                dynamic, const_tvalue_pointer))
            -- Keep the earlier direct-coercion rejection authoritative even
            -- if addressability grows new C cases later.
            assert.is_false(types.coercion(
                dynamic, const_void_pointer))
            assert.is_false(types.coercion(
                dynamic, const_tvalue_pointer))
        end)

        it("uses C-compatible pointer conversions", function()
            local int = cint()
            local alias = types.CTypedef("ffi_int", int)
            local iptr = types.CPointer(int, {})
            local vptr = types.CPointer(types.CVoid(), {})
            local const_vptr = types.CPointer(types.CVoid(), {"const"})
            local const_iptr = types.CPointer(int, {"const"})
            local alias_array = types.CArray(alias, 4)
            local const_array = types.CArray(alias, 4, {"const"})
            local volatile_array =
                types.CArray(alias, 4, {"volatile"})
            local volatile_iptr =
                types.CPointer(int, {"volatile"})
            local const_alias =
                types.CTypedef("ffi_const_int", int, {"const"})
            local const_alias_array =
                types.CArray(const_alias, 4)
            local owner = types.COwned(alias, false)
            local const_owner = types.COwned(const_alias, false)

            assert.equal("c_void_to_object_pointer",
                assert(types.coercion(vptr, iptr)).op)
            assert.truthy(types.coercion(iptr, vptr))
            assert.truthy(types.coercion(iptr, const_vptr))
            assert.falsy(types.coercion(const_iptr, vptr))
            assert.truthy(types.coercion(const_iptr, const_vptr))
            assert.falsy(types.c_address_coerceable(iptr, const_vptr))
            assert.falsy(types.c_mutable_address_coerceable(iptr, vptr))
            assert.truthy(types.coercion(alias_array, iptr))
            assert.falsy(types.coercion(const_array, iptr))
            assert.truthy(types.coercion(const_array, const_iptr))
            assert.falsy(types.coercion(volatile_array, iptr))
            assert.truthy(types.coercion(
                volatile_array, volatile_iptr))
            assert.falsy(types.coercion(
                const_alias_array, iptr))
            assert.truthy(types.coercion(
                const_alias_array, const_iptr))
            assert.falsy(types.coercion(
                types.CPointer(const_alias, {}), iptr))
            assert.truthy(types.coercion(owner, iptr))
            assert.truthy(types.coercion(owner, const_iptr))
            assert.truthy(types.coercion(owner, vptr))
            assert.truthy(types.coercion(owner, const_vptr))
            assert.falsy(types.coercion(const_owner, iptr))
            assert.falsy(types.coercion(const_owner, vptr))
            assert.truthy(types.coercion(const_owner, const_iptr))
            assert.truthy(types.coercion(const_owner, const_vptr))
            assert.same({"const"},
                types.c_local_address_pointer(const_array).quals)
        end)

        it("leaves addressable-local and checked pointer casts to the checker",
        function()
            local integer = types.CInteger("int", true, 3, 32)
            local floating = types.CFloat("double")
            local aggregate = types.CStruct(
                "struct ffi_item", "ffi_item", false, {}, true, false)
            local aggregate_pointer = types.CPointer(aggregate, {})
            local integer_pointer = types.CPointer(integer, {})
            local floating_pointer = types.CPointer(floating, {})

            assert.truthy(types.c_mutable_address_coerceable(
                aggregate, aggregate_pointer))
            assert.falsy(types.written_cast(
                aggregate, aggregate_pointer))
            assert.truthy(types.c_unsafe_object_pointer_candidate(
                integer_pointer, floating_pointer))
            assert.falsy(types.written_cast(
                integer_pointer, floating_pointer))
        end)

        it("allows explicit stable GC identities and pointer kinds as C void pointers",
        function()
            local record = types.Nominal("test.Owner")
            local array = types.Array(record, false)
            local map = types.Map(types.String(), record)
            local callback =
                types.Function({}, {}, false, false, false)
            local void_pointer =
                types.CPointer(types.CVoid(), {})
            local object_pointer =
                types.CPointer(cint(), {})
            local function_pointer = types.CPointer(
                types.CFunction({cint()}, cint(), false, "cdecl"), {})

            for _, gc_type in ipairs({
                record,
                array,
                map,
                callback,
            }) do
                local cast = assert(types.written_cast(
                    gc_type, void_pointer))
                assert.equal("explicit", cast.op)
                assert.equal("gc_identity_to_void_pointer",
                    cast.conversion.op)
                assert.truthy(types.is_gc_identity_void_pointer_cast(
                    gc_type, void_pointer))
                assert.falsy(types.coercion(gc_type, void_pointer))
                assert.falsy(types.written_cast(
                    gc_type, object_pointer))
            end

            assert.equal("c_function_pointer_to_void",
                assert(types.written_cast(
                    function_pointer, void_pointer)).conversion.op)
            assert.falsy(types.coercion(
                function_pointer, void_pointer))
            assert.equal("c_void_to_function_pointer",
                assert(types.written_cast(
                    void_pointer, function_pointer)).conversion.op)
            assert.falsy(types.coercion(
                void_pointer, function_pointer))
            -- String keeps its established implicit byte-buffer conversion,
            -- rather than participating in the GC-identity conversion.
            assert.equal("string_to_c_pointer",
                assert(types.coercion(
                    types.String(), void_pointer)).op)
            assert.falsy(types.is_gc_identity_void_pointer_cast(
                types.String(), void_pointer))

            assert.equal("unsafe_dynamic_c_pointer",
                assert(types.written_cast(
                    types.Value(), void_pointer)).conversion.op)
            assert.falsy(types.written_cast(
                types.Option(record), void_pointer))
        end)

        it("detects C types nested inside type trees", function()
            assert.truthy(types.is_c(types.CPointer(cint(), {})))
            assert.truthy(types.is_c(types.Option(types.CPointer(cint(), {}))))
            assert.truthy(types.is_c(types.ModuleMember(
                "m", "x", types.CFloat("float"), false)))
            assert.falsy(types.is_c(types.Function(
                {types.Integer()}, {types.String()}, false, false, false)))
            assert.falsy(types.is_c(types.Function(
                {types.CPointer(cint(), {})}, {}, false, false, false)))
            assert.truthy(types.contains_c_ffi_type(
                types.Function({types.CPointer(cint(), {})}, {}, false, false,
                    false)))
            assert.truthy(types.contains_c_ffi_type(types.Function(
                {}, {}, false, false, types.CPointer(cint(), {}))))
        end)

        it("serializes the portable C surface recursively", function()
            local callback = types.CPointer(types.CFunction(
                {cint(), types.CPointer(types.CVoid(), {"const"})},
                types.CFloat("double"), false, false), {})
            local owner = types.COwned(callback, true)
            local serialized = types.serialize(owner)
            local rebuilt = assert(load(
                "return " .. serialized, "portable-c", "t", types))()

            assert.truthy(types.equals(owner, rebuilt))
            assert.is_nil(types.first_non_exportable_type(rebuilt))
            assert.truthy(types.contains_c_ffi_type(rebuilt))
        end)

        it("finds the first non-exportable C descriptor", function()
            local portable = types.CPointer(cint(), {"const"})
            assert.is_nil(types.first_non_exportable_type(portable))

            local alias = types.CTypedef("ffi_int", cint())
            assert.equal(alias, types.first_non_exportable_type(alias))
            assert.equal(alias, types.first_non_exportable_type(
                types.Array(alias, false)))

            local oldstyle = types.CFunction(
                {}, types.CVoid(), false, false)
            oldstyle._paramstyle = "oldstyle"
            local cyclic = types.CPointer(types.CVoid(), {})
            cyclic.pointee = cyclic

            for _, malformed in ipairs({
                types.CPointer(cint(), {"volatile"}),
                types.CArray(cint(), 2),
                types.CFunction({types.CVoid()}, types.CVoid(), false, false),
                types.CFunction({types.COwned(cint(), false)},
                    types.CVoid(), false, false),
                types.CFunction({cint()}, types.CVoid(), true, false),
                types.COwned(types.CVoid(), false),
                types.CPointer(types.Integer(), {}),
                types.CPointer(types.COwned(cint(), false), {}),
                types.COwned(types.Integer(), false),
                types.CPointer(types.CFunction(
                    {types.Integer()}, types.CVoid(), false, false), {}),
                types.CFunction({cint()}, types.Integer(), false, false),
                oldstyle,
                cyclic,
                types.CModule("ffi", {}, {}),
            }) do
                assert.truthy(types.first_non_exportable_type(malformed))
            end
        end)

        it("serializes and deserializes all C FFI type shapes", function()
            local int = cint()
            local ptr = types.CPointer(int, {"const"})
            local arr = types.CArray(int, 4, {})
            local func = types.CFunction({int, ptr}, types.CFloat("double"), true, "cdecl")
            local st = types.CStruct("struct point", "point", false, {}, true, false)
            local un = types.CUnion("union data", "data", false, {}, true)
            local field = types.CField(false, "x", int, false, false)
            local alias = types.CTypedef("ffi_int", int, {"const"})
            local owned_ptr = types.COwned(int, false)
            local owned_arr = types.COwned(int, true)
            local mod = types.CModule("myffi", {
                func = types.ModuleMember("myffi", "func", func, {"a", "b"})
            }, {
                Point = st
            })

            local function round_trip(typ)
                local s = types.serialize(typ)
                local rebuilt = assert(load("return " .. s, "c-type", "t", types))()
                assert.truthy(types.equals(typ, rebuilt))
                return s, rebuilt
            end

            round_trip(types.CVoid())
            round_trip(int)
            round_trip(types.CFloat("float"))
            round_trip(types.CFloat("double"))
            round_trip(ptr)
            round_trip(arr)
            round_trip(func)
            round_trip(st)
            round_trip(un)
            round_trip(field)
            round_trip(alias)
            round_trip(owned_ptr)
            round_trip(owned_arr)
            round_trip(mod)
        end)

        it("reattaches target numeric traits to recovered portable scalars",
        function()
            local integer_traits = { kind = "integer" }
            local float_traits = { kind = "float" }
            local carriers = { identity = "test-profile" }
            local canonical_int = cint()
            canonical_int._c_numeric = integer_traits
            canonical_int._c_numeric_carriers = carriers
            local canonical_float = types.CFloat("double")
            canonical_float._c_numeric = float_traits
            canonical_float._c_numeric_carriers = carriers
            local profile = {
                integers = { int = { type = canonical_int } },
                floats = { double = { type = canonical_float } },
            }
            local recovered_int = cint()
            local recovered_float = types.CFloat("double")
            local graph = types.Function(
                {recovered_int}, {recovered_float}, false, false, false)

            assert.truthy(types.normalize_portable_c_numeric_types(
                graph, profile))
            assert.equal(integer_traits, recovered_int._c_numeric)
            assert.equal(float_traits, recovered_float._c_numeric)
            assert.equal(carriers, recovered_int._c_numeric_carriers)

            local mismatched = types.CInteger("int", true, 3, 64)
            local ok, err = types.normalize_portable_c_numeric_types(
                mismatched, profile)
            assert.is_nil(ok)
            assert.match("disagrees with the selected target profile", err)
        end)

        it("treats owned C pointers as GC values, but C modules as non-values", function()
            assert.truthy(types.is_gc(types.COwned(cint(), false)))
            assert.falsy(types.is_gc(types.CModule("ffi", {}, {})))
            assert.falsy(types.is_c(types.CModule("ffi", {}, {})))
            assert.falsy(types.is_truthy(types.CPointer(cint(), {})))
            assert.falsy(types.is_truthy(types.CTypedef(
                "ffi_iptr", types.CPointer(cint(), {}))))
            assert.truthy(types.is_truthy(types.COwned(cint(), false)))
            assert.falsy(types.is_falsy(types.CPointer(cint(), {})))
        end)
    end)

    describe("generic surface type algebra", function()
        local function scope(callable, role, kind, owner)
            return types.GenericScope(
                "sample", owner or false, callable or false,
                role or "function", kind or "function")
        end

        local function reload(typ)
            return assert(load(
                "return " .. types.serialize(typ),
                "generic-type", "t", types))()
        end

        it("builds structural scopes and deterministic diagnostics", function()
            local owner_scope = scope(false, "owner", "record", "sample.Pair")
            local callable_scope = scope("map", "method", "method", "sample.Pair")
            local tparam = types.TypeParameter("T", false)
            local uparam = types.TypeParameter(
                "U", types.Nominal("sample.Show", {types.Value()}))
            local rigid = types.Parameter(callable_scope, 1, "U", false)
            local scheme = types.FunctionScheme(callable_scope, {uparam},
                types.Function({rigid}, {rigid}, false, false, false))

            assert.equal(types.generic_scope_key(owner_scope),
                types.generic_scope_key(scope(
                    false, "owner", "record", "sample.Pair")))
            assert.equal("T", types.tostring(tparam))
            assert.equal("U: sample.Show<value>", types.tostring(uparam))
            assert.equal("<U: sample.Show<value>>(U) -> U",
                types.tostring(scheme))
            assert.equal("sample.Pair<integer, string>", types.tostring(
                types.Nominal("sample.Pair",
                    {types.Integer(), types.String()})))
            assert.same({}, types.Nominal("sample.Legacy").args)
        end)

        it("uses scope and index identity while alpha-renaming diagnostics",
        function()
            local first_scope = scope("id")
            local renamed_scope = scope("id")
            local first = types.FunctionScheme(first_scope,
                {types.TypeParameter("T", false)},
                types.Function(
                    {types.Parameter(first_scope, 1, "T", false)},
                    {types.Parameter(first_scope, 1, "T", false)},
                    false, false, false))
            local renamed = types.FunctionScheme(renamed_scope,
                {types.TypeParameter("Element", false)},
                types.Function(
                    {types.Parameter(renamed_scope, 1, "Element", false)},
                    {types.Parameter(renamed_scope, 1, "Element", false)},
                    false, false, false))

            assert.is_true(types.equals(first, renamed))
            assert.is_true(types.alpha_equals(first, renamed))
            assert.is_true(types.equals(
                types.Parameter(first_scope, 1, "T", false),
                types.Parameter(first_scope, 1, "Renamed",
                    types.Nominal("sample.Show"))))
            assert.is_false(types.equals(
                types.Parameter(first_scope, 1, "T", false),
                types.Parameter(first_scope, 2, "T", false)))
            assert.is_false(types.equals(
                types.Parameter(first_scope, 1, "T", false),
                types.Parameter(scope("other"), 1, "T", false)))
        end)

        it("alpha-compares corresponding binders from different declaration scopes",
        function()
            local left_scope = types.GenericScope(
                "sample", "sample.I", "map", "method", "interface")
            local right_scope = types.GenericScope(
                "sample", "sample.R", "map", "method", "record")
            local left = types.Method("sample.I", "map", {
                types.Parameter(left_scope, 1, "T", false),
            }, {
                types.Parameter(left_scope, 1, "T", false),
            }, false, false, {"x"}, left_scope, {
                types.TypeParameter("T", false),
            })
            local right = types.Method("sample.I", "map", {
                types.Parameter(right_scope, 1, "U", false),
            }, {
                types.Parameter(right_scope, 1, "U", false),
            }, false, false, {"x"}, right_scope, {
                types.TypeParameter("U", false),
            })

            assert.is_false(types.equals(left, right))
            assert.is_true(types.alpha_equals(left, right))
        end)

        it("keeps applied nominals invariant and erases only arguments",
        function()
            local first = types.Nominal("sample.Pair",
                {types.Integer(), types.String()})
            local same = types.Nominal("sample.Pair",
                {types.Integer(), types.String()})
            local different = types.Nominal("sample.Pair",
                {types.String(), types.Integer()})

            assert.is_true(types.equals(first, same))
            assert.is_false(types.equals(first, different))
            assert.is_true(types.contains_generic(first))
            assert.is_true(types.equals(
                types.erase(first), types.erase(different)))
            assert.same({}, types.erase(first).args)
            assert.is_true(types.is_erased(types.erase(first)))
        end)

        it("keeps applied owners invariant while allowing shallow value consistency",
        function()
            local cell_scope = types.GenericScope(
                "sample", "sample.Cell", false, "owner", "record")
            types.registry["sample.Cell"] = types.Record(
                "sample.Cell", {}, {}, {}, 0, cell_scope, {
                    types.TypeParameter("T", false),
                })
            local precise = types.Nominal("sample.Cell", {types.Integer()})
            local erased = types.Nominal("sample.Cell", {types.Value()})
            local wrong = types.Nominal("sample.Cell", {types.String()})
            local nested = types.Nominal("sample.Cell", {
                types.Array(types.Integer(), false),
            })
            local nested_view = types.Nominal("sample.Cell", {
                types.Array(types.Value(), false),
            })

            assert.is_false(types.equals(precise, erased))
            assert.is_true(types.consistent(precise, erased))
            assert.is_true(types.consistent(erased, precise))
            assert.is_false(types.consistent(precise, wrong))
            assert.is_false(types.consistent(nested, nested_view))
            assert.is_true(types.consistent(nested, erased))
            assert.is_false(types.assignment_adjustment(precise, wrong))
            assert.is_false(types.assignment_adjustment(precise, erased))
            assert.is_truthy(types.generic_owner_view(precise, erased))

            local box_scope = types.GenericScope(
                "sample", "sample.Box", false, "owner", "record")
            types.registry["sample.Box"] = types.Record(
                "sample.Box", {}, {}, {}, 0, box_scope, {
                    types.TypeParameter("T", types.Nominal("sample.Show")),
                })
            local implementation = types.Nominal("sample.Shown")
            local constrained = types.Nominal(
                "sample.Box", {implementation})
            local carrier = types.Nominal("sample.Box", {
                types.Nominal("sample.Show"),
            })
            local invalid = types.Nominal(
                "sample.Box", {types.Value()})
            assert.is_true(types.consistent(constrained, carrier))
            assert.is_false(types.consistent(constrained, invalid))
        end)

        it("relates each rigid parameter only to its erased constraint carrier",
        function()
            local owner_scope = scope(
                false, "owner", "record", "sample.Box")
            local unconstrained = types.Parameter(
                owner_scope, 1, "T", false)
            local constrained = types.Parameter(owner_scope, 2, "U",
                types.Nominal("sample.Show", {unconstrained}))
            local another_scope = scope(
                false, "other", "record", "sample.Other")
            local another = types.Parameter(
                another_scope, 1, "V", false)

            assert.is_true(types.consistent(
                unconstrained, types.Value()))
            assert.is_true(types.consistent(
                types.Value(), unconstrained))
            assert.is_false(types.consistent(unconstrained, another))
            assert.is_false(types.is_truthy(unconstrained))
            assert.is_true(types.is_truthy(constrained))
            assert.is_true(types.consistent(constrained,
                types.Nominal("sample.Show", {types.Value()})))
            assert.is_false(types.consistent(constrained, types.Value()))
            assert.is_true(types.consistent(
                types.Option(unconstrained),
                types.Option(types.Value())))
            assert.is_true(types.consistent(
                types.Array(unconstrained, false),
                types.Array(types.Value(), false)))
            assert.is_true(types.consistent(
                types.Function({unconstrained}, {unconstrained},
                    false, false, false),
                types.Function({types.Value()}, {types.Value()},
                    false, false, false)))
        end)

        it("smart-substitutes owner and callable scopes independently",
        function()
            local owner_scope = scope(
                false, "owner", "record", "sample.Pair")
            local method_scope = scope(
                "convert", "method", "method", "sample.Pair")
            local t = types.Parameter(owner_scope, 1, "T", false)
            local u = types.Parameter(method_scope, 1, "U", false)
            local method = types.Method("sample.Pair", "convert", {
                types.Array(types.Option(t), false),
                types.Map(types.String(), types.Option(t)),
                u,
            }, {
                types.Nominal("sample.Pair", {t, u}),
            }, u, t, {"items", "lookup", "value"}, method_scope, {
                types.TypeParameter("U",
                    types.Nominal("sample.Mapper", {t})),
            })

            local owner_view = types.substitute(
                method, owner_scope, {types.Integer()})
            assert.is_true(types.same_generic_scope(
                method_scope, owner_view.scope))
            assert.equal("sample.Mapper<integer>", types.tostring(
                owner_view.typeparams[1].constraint))

            local local_closed = types.substitute(
                method, method_scope, {types.String()})
            assert.is_false(local_closed.scope)
            assert.same({}, local_closed.typeparams)
            assert.equal("string", types.tostring(local_closed.params[3]))
            assert.equal("T", types.tostring(local_closed.params[1].elem))

            local closed = types.substitute(
                local_closed, owner_scope, {types.Integer()})
            assert.equal("{ integer }", types.tostring(closed.params[1]))
            assert.equal("{ string : integer }",
                types.tostring(closed.params[2]))
            assert.equal("sample.Pair<integer, string>",
                types.tostring(closed.rettypes[1]))
            assert.equal("string", types.tostring(closed.varargtype))
            assert.equal("integer", types.tostring(closed.flexrettype))

            local bad_key = types.Map(t, types.Integer())
            assert.has_error(function()
                types.substitute(bad_key, owner_scope,
                    {types.Option(types.Integer())})
            end, "type of map key cannot be option type")

            assert.equal("value", types.tostring(types.substitute(
                types.Option(t), owner_scope, {types.Value()})))
        end)

        it("closes schemes and constructor-preserving aliases", function()
            local fn_scope = scope("choose")
            local t = types.Parameter(fn_scope, 1, "T", false)
            local scheme = types.FunctionScheme(fn_scope,
                {types.TypeParameter("T", false)},
                types.Function({t, t}, {t}, false, false, false))
            local closed = types.apply_scheme(scheme, {types.Integer()})
            assert.equal("(integer, integer) -> integer",
                types.tostring(closed))

            local owner_scope = scope(
                false, "owner", "record", "sample.Pair")
            local alias = types.GenericAlias(
                "sample", "Either", false, "sample.Pair", false,
                owner_scope, {
                    types.TypeParameter("A", false),
                    types.TypeParameter("B", false),
                })
            local applied = types.apply_generic_alias(alias,
                {types.Integer(), types.String()})
            assert.equal("sample.Pair<integer, string>",
                types.tostring(applied))
            assert.equal(
                "sample.Either<A, B> = sample.Pair<A, B>",
                types.tostring(alias))
            assert.has_error(function()
                types.apply_generic_alias(alias, {types.Integer()})
            end, "expected 2 type arguments but found 1")
            assert.is_true(types.alpha_equals(alias, reload(alias)))
        end)

        it("erases rigid carriers throughout declaration descriptors",
        function()
            local owner_scope = scope(
                false, "owner", "record", "sample.Box")
            local t = types.Parameter(owner_scope, 1, "T", false)
            local constrained = types.Parameter(owner_scope, 2, "S",
                types.Nominal("sample.Show", {t}))
            local record = types.Record("sample.Box", {
                types.Field("sample.Box", "item", t, 0, false),
                types.Field(
                    "sample.Box", "shown", constrained, 1, false),
            }, {
                make = types.StaticMethod("sample.Box", "make", {t}, {
                    types.Nominal("sample.Box", {t, constrained}),
                }, false, false, {}),
            }, {}, 2, owner_scope, {
                types.TypeParameter("T", false),
                types.TypeParameter("S",
                    types.Nominal("sample.Show", {t})),
            })

            assert.is_true(types.alpha_equals(record, reload(record)))
            local erased = types.erase(record)
            assert.is_false(erased.scope)
            assert.same({}, erased.typeparams)
            assert.equal("value", types.tostring(erased.fields[1].type))
            assert.equal("sample.Show",
                types.tostring(erased.fields[2].type))
            assert.equal("sample.Box", types.tostring(
                erased.functions.make.rettypes[1]))
            assert.is_true(types.is_erased(erased))
            assert.is_true(types.assert_erased(erased) == erased)
            assert.has_error(function() types.assert_erased(record) end,
                "generic type reached erased core")
        end)

        it("retains recursively erased constraint applications before core erasure",
        function()
            local owner_scope = scope(
                false, "owner", "record", "sample.Box")
            local constrained = types.Parameter(owner_scope, 1, "C",
                types.Nominal("sample.J"))
            local dependent = types.Parameter(owner_scope, 2, "B",
                types.Nominal("sample.I", {constrained}))

            local carrier = types.erase_constraint(dependent)
            assert.equal("sample.I<sample.J>", types.tostring(carrier))
            assert.equal("sample.I", types.tostring(types.erase(dependent)))
        end)

        it("recognizes the exact transient round-trip frontier", function()
            local cinteger = types.CInteger("int", true, 3, 32)
            local cfloat = types.CFloat("double")
            local point = types.CStruct(
                "point", "point", false, {}, true, false)
            local incomplete = types.CStruct(
                "opaque", "opaque", false, {}, false, false)
            local flexible = types.CStruct(
                "flexible", "flexible", false, {}, true, true)
            local tvalue = types.CStruct(
                "TValue", "TValue", false, {}, false, false)
            local rigid_scope = scope("rigid")
            local rigid = types.Parameter(rigid_scope, 1, "T", false)
            local constrained = types.Parameter(rigid_scope, 2, "S",
                types.Nominal("sample.Show", {rigid}))

            local positive = {
                types.Nil(), types.Boolean(), types.Integer(), types.Float(),
                types.String(), types.Value(), types.Option(types.Integer()),
                types.Array(types.String(), false),
                types.Map(types.String(), types.Integer()),
                types.Function({types.Integer()}, {types.String()},
                    false, types.Value(), types.Boolean()),
                types.Nominal("sample.Box", {types.Integer()}),
                rigid, constrained, cinteger, cfloat,
                types.COwned(point, false), tvalue,
                types.CTypedef("number_t", cinteger),
            }
            for _, typ in ipairs(positive) do
                assert.is_true(types.transient_roundtrip(typ),
                    types.tostring(typ))
            end

            local pointer = types.CPointer(cinteger, {})
            local cfunction = types.CFunction({}, cinteger, false, "c")
            local negative = {
                types.Invalid(), types.Void(), pointer,
                types.CArray(cinteger, 2), cfunction,
                types.CPointer(cfunction, {}), point,
                types.COwned(incomplete, false),
                types.COwned(flexible, false),
                types.COwned(flexible, true),
                types.CInteger("enum pending", true, 3, false),
                types.CModule("ffi", {}, {}),
                types.Option(pointer), types.Array(pointer, false),
                types.Map(types.String(), pointer),
                types.Function({types.Integer()}, {pointer},
                    false, false, false),
                types.Function({}, {}, false,
                    types.Nil(), false),
                types.Function({}, {}, false,
                    false, cinteger),
                types.Nominal("sample.Phantom", {pointer}),
                types.Map(types.Option(types.Integer()), types.String()),
                types.Option(types.Value()),
                types.Option(types.Option(types.Integer())),
                types.Array(types.Option(types.Integer()), false),
                types.Map(types.String(), types.Option(types.Integer())),
            }
            for _, typ in ipairs(negative) do
                assert.is_false(types.transient_roundtrip(typ),
                    types.tostring(typ))
            end

            local first = types.CTypedef("first", cinteger)
            local second = types.CTypedef("second", first)
            first.target = second
            assert.is_false(types.transient_roundtrip(first))
        end)

        it("rejects malformed generic scope and binder metadata", function()
            local first_scope = scope("id")
            local other_scope = scope("other")

            assert.is_false(types.same_generic_scope(
                first_scope, types.Integer()))
            assert.is_false(types.equals(first_scope, other_scope))
            assert.equal("scope[" .. types.generic_scope_key(first_scope) ..
                "]", types.tostring(first_scope))
            assert.is_false(types.equals(
                types.TypeParameter("T", false),
                types.TypeParameter("T", types.Integer())))

            local signature = types.Function(
                {}, {}, false, false, false)
            local integer_scheme = types.FunctionScheme(first_scope, {
                types.TypeParameter("T", types.Integer()),
            }, signature)
            local string_scheme = types.FunctionScheme(first_scope, {
                types.TypeParameter("T", types.String()),
            }, signature)
            assert.is_false(types.equals(integer_scheme, string_scheme))

            local first_variable = types.ModuleVariable(
                "sample", "item", types.Integer(), false)
            assert.is_true(types.equals(first_variable,
                types.ModuleVariable(
                    "sample", "item", types.Integer(), false)))
            assert.is_false(types.equals(first_variable,
                types.ModuleVariable(
                    "sample", "item", types.String(), false)))

            local rigid = types.Parameter(
                first_scope, 1, "T", types.Nominal("sample.Erased"))
            local key = types.generic_scope_key(first_scope)
            assert.is_nil(types.parameter_surface_constraint(false, {}))
            assert.is_nil(types.parameter_surface_constraint(rigid, {}))
            assert.is_nil(types.parameter_surface_constraint(rigid, {
                [key] = {
                    types.TypeParameter("T", "not a constraint"),
                },
            }))
            assert.is_false(types.parameter_surface_constraint(rigid, {
                [key] = {types.TypeParameter("T", false)},
            }))
            local constraint = types.Nominal("sample.Show")
            assert.is_true(constraint ==
                types.parameter_surface_constraint(rigid, {
                    [key] = {types.TypeParameter("T", constraint)},
                }))

            assert.has_error(function()
                types.serialize(types.GenericScope(
                    "sample", false, false, "function", 7))
            end, "cannot serialize generic metadata literal 7")
        end)

        it("validates dense type arguments before substitution", function()
            local count, list_error =
                types.dense_type_list_length(false)
            assert.is_nil(count)
            assert.equal("expected a dense numeric list", list_error)

            count, list_error = types.dense_type_list_length({
                argument = types.Integer(),
            })
            assert.is_nil(count)
            assert.equal("expected numeric list keys only", list_error)

            count, list_error = types.dense_type_list_length({
                [2] = types.Integer(),
            })
            assert.is_nil(count)
            assert.equal("expected a dense numeric list", list_error)
            assert.equal(2, types.dense_type_list_length({
                types.Integer(), types.String(),
            }))

            local generic_scope = scope("id")
            local rigid = types.Parameter(
                generic_scope, 1, "T", false)
            local pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            assert.has_error(function()
                types.substitute(rigid, generic_scope, {7})
            end, "type argument 1 is not a type")
            assert.has_error(function()
                types.substitute(rigid, generic_scope, {pointer})
            end, "type argument 1 ('*int') has no sound transient round trip")
            assert.is_true(types.equals(pointer,
                types.substitute_inference(
                    rigid, generic_scope, {pointer})))
            assert.has_error(function()
                types.substitute(rigid, generic_scope, {})
            end, "missing type argument 1 for " ..
                types.generic_scope_key(generic_scope))

            local typeparams = {types.TypeParameter("T", false)}
            local valid, argument_error =
                types.validate_type_arguments(typeparams, {7})
            assert.is_nil(valid)
            assert.equal("type argument 1 is not a type", argument_error)
            valid, argument_error =
                types.validate_type_arguments(typeparams, {pointer})
            assert.is_nil(valid)
            assert.equal("type argument 1 ('*int') has no sound " ..
                "transient round trip", argument_error)
        end)

        it("preserves unrelated scopes during generic rewrites", function()
            local generic_scope = scope("id")
            local unrelated_scope = scope("other")
            local rigid = types.Parameter(
                generic_scope, 1, "T", false)
            local scheme = types.FunctionScheme(generic_scope, {
                types.TypeParameter("T", false),
            }, types.Function({rigid}, {rigid}, false, false, false))
            local alias = types.GenericAlias(
                "sample", "Boxed", false, "sample.Box", false,
                generic_scope, {types.TypeParameter("T", false)})

            local rewritten_scheme = types.substitute(
                scheme, unrelated_scope, {types.Integer()})
            local rewritten_alias = types.substitute(
                alias, unrelated_scope, {types.Integer()})
            assert.is_true(types.alpha_equals(scheme, rewritten_scheme))
            assert.is_true(types.alpha_equals(alias, rewritten_alias))
            assert.is_false(scheme == rewritten_scheme)
            assert.is_false(alias == rewritten_alias)
            assert.is_true(types.same_generic_scope(
                types.erase(generic_scope), generic_scope))
            assert.equal("value", types.tostring(types.erase(
                types.TypeParameter("T", false))))
            assert.equal("sample.Show", types.tostring(types.erase(
                types.TypeParameter(
                    "T", types.Nominal("sample.Show")))))
        end)

        it("rejects malformed generic rewrites and callable tails", function()
            local pointer = types.CPointer(
                types.CInteger("int", true, 3, 32), {})
            assert.has_error(function()
                types.canonical_function({}, {}, false, pointer)
            end, "a flexible return cannot have a foreign pointer type")
            assert.has_error(function()
                types.canonical_function({}, {}, false, types.CVoid())
            end, "a flexible return cannot use type void because it has " ..
                "no supported variadic-value representation")

            assert.has_error(function()
                types.erase("not a type")
            end, "generic type rewrite expected a Type descriptor")
            local cycle = types.Array(types.Integer(), false)
            cycle.elem = cycle
            assert.has_error(function()
                types.erase(cycle)
            end, "cyclic structural type in generic type rewrite")
            assert.has_error(function()
                types.erase(types.Function(
                    {}, {}, true, false, false))
            end, "Type.Function reserved vararg field must be false")
        end)

        it("recognizes aliased owned payloads and generic callable tails",
        function()
            local cinteger = types.CInteger("int", true, 3, 32)
            local complete_union = types.CUnion(
                "number", "number", false, {}, true)
            local incomplete_union = types.CUnion(
                "opaque", "opaque", false, {}, false)
            assert.is_true(types.transient_roundtrip(
                types.COwned(complete_union, false)))
            assert.is_false(types.transient_roundtrip(
                types.COwned(incomplete_union, false)))
            assert.is_true(types.transient_roundtrip(
                types.COwned(cinteger, false)))
            assert.is_false(types.transient_roundtrip(
                types.COwned(types.CArray(cinteger, 2), false)))

            local first = types.CTypedef("first", cinteger)
            local second = types.CTypedef("second", first)
            first.target = second
            assert.is_false(types.transient_roundtrip(
                types.COwned(first, false)))

            local generic_scope = scope("tail")
            local rigid = types.Parameter(
                generic_scope, 1, "T", false)
            local tvalue = types.CStruct(
                "TValue", "TValue", false, {}, false, false)
            for _, tail in ipairs({
                rigid,
                types.Option(types.Integer()),
                tvalue,
            }) do
                assert.is_true(types.transient_roundtrip(
                    types.Function({}, {}, false, tail, false)))
            end
            assert.is_false(types.transient_roundtrip(
                types.Nominal("sample.Malformed", {false})))
        end)

        it("keeps generic relation defenses symmetric", function()
            local first_record = types.Record(
                "sample.Identity", {}, {}, {}, 0)
            local second_record = types.Record(
                "sample.Identity", {
                    types.Field("sample.Identity", "item",
                        types.Integer(), 0, false),
                }, {}, {}, 1)
            assert.is_true(types.consistent(first_record, second_record))

            local short_scope = types.GenericScope(
                "sample", "sample.Short", false, "owner", "record")
            types.registry["sample.Short"] = types.Record(
                "sample.Short", {}, {}, {}, 0, short_scope, {
                    types.TypeParameter("T", false),
                })
            assert.is_false(types.consistent(
                types.Nominal("sample.Short", {
                    types.Integer(), types.Integer(),
                }),
                types.Nominal("sample.Short", {
                    types.Integer(), types.String(),
                })))

            local rigid_scope = scope("constrained")
            local constrained = types.Parameter(
                rigid_scope, 1, "T", types.Nominal("sample.Show"))
            assert.is_false(types.consistent(types.Value(), constrained))
            assert.is_true(types.consistent(
                types.Nominal("sample.Show"), constrained))
            assert.is_false(types.generic_owner_view(
                types.Nominal("sample.Left", {types.Integer()}),
                types.Nominal("sample.Right", {types.Integer()})))
        end)

        it("alpha-closes generic methods for Interface matching", function()
            local function method_scope(owner)
                return types.GenericScope(
                    "sample", owner, "map", "method", "method")
            end
            local function generic_method(
                    owner, generic_scope, constraint, binder_count)
                local params, paramnames, typeparams = {}, {}, {}
                for index = 1, binder_count do
                    local name = "T" .. index
                    params[index] = types.Parameter(
                        generic_scope, index, name, false)
                    paramnames[index] = "value" .. index
                    typeparams[index] = types.TypeParameter(
                        name, index == 1 and constraint or false)
                end
                return types.Method(owner, "map", params, {params[1]},
                    false, false, paramnames, generic_scope, typeparams)
            end

            local required_scope = method_scope("sample.Mapper")
            local concrete_scope = method_scope("sample.Box")
            local required = generic_method(
                "sample.Mapper", required_scope,
                types.Nominal("sample.Show"), 1)
            local concrete = generic_method(
                "sample.Box", concrete_scope,
                types.Nominal("sample.Show"), 1)
            local interface = types.Interface(
                "sample.Mapper", {}, {required})
            local record = types.Record(
                "sample.Box", {}, {}, {map = concrete}, 0)
            local implementation = assert(
                types.generic_interface_implementation(
                    record, interface, {visibility = "sample"}))
            assert.equal("interface_implementation", implementation.kind)
            assert.is_true(implementation.exact)
            assert.is_true(concrete ==
                implementation.methods[1].concrete)
            assert.is_true(required ==
                implementation.methods[1].required)

            local function expect_incompatible(method)
                local candidate = types.Record(
                    "sample.Box", {}, {}, {map = method}, 0)
                local matched, failure =
                    types.generic_interface_implementation(
                        candidate, interface, {visibility = "sample"})
                assert.is_false(matched)
                assert.equal("interface_mismatch", failure.kind)
                assert.equal("incompatible", failure.reason)
                assert.equal("map", failure.name)
                return failure
            end

            expect_incompatible(generic_method(
                "sample.Box", concrete_scope,
                types.Nominal("sample.Hash"), 1))
            expect_incompatible(generic_method(
                "sample.Box", concrete_scope,
                types.Nominal("sample.Show"), 2))
            local incompatible = generic_method(
                "sample.Box", concrete_scope,
                types.Nominal("sample.Show"), 1)
            incompatible.rettypes = {types.String()}
            local failure = expect_incompatible(incompatible)
            assert.is_true(failure.required == required)
            assert.is_true(failure.member == incompatible)
        end)

        it("preserves selected module provenance during generic rewrites",
        function()
            local generic_scope = scope("id")
            local parameter = types.Parameter(
                generic_scope, 1, "T", false)
            local module = types.Module("sample.child", {
                types.ModuleMember("sample.child", "id",
                    types.FunctionScheme(generic_scope, {
                        types.TypeParameter("T", false),
                    }, types.Function({parameter}, {parameter},
                        false, false, false)), {"x"}),
            }, {})
            module.file = "/selected/provider.so"
            module.prefix = "selected_prefix_"

            local applied = types.substitute(
                module, generic_scope, {types.Integer()})
            assert.equal("/selected/provider.so", applied.file)
            assert.equal("selected_prefix_", applied.prefix)
            local erased = types.erase(module)
            assert.equal("/selected/provider.so", erased.file)
            assert.equal("selected_prefix_", erased.prefix)
        end)

        it("serializes generic metadata deterministically and round-trips it",
        function()
            local fn_scope = scope("id")
            local t = types.Parameter(fn_scope, 1, "T", false)
            local scheme = types.FunctionScheme(fn_scope,
                {types.TypeParameter("T", false)},
                types.Function({t}, {types.Option(t)},
                    false, t, t))
            local owner_scope = scope(
                false, "owner", "record", "sample.Pair")
            local first_alias = types.GenericAlias(
                "sample", "Either", false, "sample.Pair", false,
                owner_scope, {
                    types.TypeParameter("A", false),
                    types.TypeParameter("B", false),
                })
            local second_alias = types.GenericAlias(
                "sample", "Choice", false, "sample.Pair",
                "sample.Either", owner_scope, {
                    types.TypeParameter("A", false),
                    types.TypeParameter("B", false),
                })
            local result_scope = scope(
                false, "owner", "union", "sample.Result")
            local result_t = types.Parameter(
                result_scope, 1, "T", false)
            local ok_variant = types.Variant(
                "sample.Result", "ok", result_t, 0)
            local result = types.Union("sample.Result", {ok_variant}, {
                ok = types.StaticMethod("sample.Result", "ok", {
                    result_t,
                }, {
                    types.Nominal("sample.Result", {result_t}),
                }, false, false, false),
            }, {}, 1, result_scope, {
                types.TypeParameter("T", false),
            })
            local show_scope = scope(
                false, "owner", "interface", "sample.Show")
            local show_t = types.Parameter(show_scope, 1, "T", false)
            local show = types.Interface("sample.Show", {}, {
                types.Method("sample.Show", "show", {show_t},
                    {types.String()}, false, false, {"value"}),
            }, show_scope, {types.TypeParameter("T", false)})
            local module = types.Module("sample", {
                types.ModuleMember("sample", "id", scheme, {"value"}),
            }, {
                Choice = second_alias,
                Either = first_alias,
                Result = result,
                Show = show,
            })

            local serialized = types.serialize(module)
            assert.equal(serialized, types.serialize(module))
            assert.is_true(serialized:find('["Choice"]', 1, true) <
                serialized:find('["Either"]', 1, true))
            local rebuilt = reload(module)
            assert.is_true(types.alpha_equals(module, rebuilt))
            assert.is_true(types.alpha_equals(
                scheme, rebuilt.members.id.type))
            assert.is_true(types.alpha_equals(
                result, rebuilt.type_members.Result))
            assert.is_true(types.alpha_equals(
                show, rebuilt.type_members.Show))
            assert.equal(types.serialize(scheme),
                types.serialize(reload(scheme)))
        end)

        it("serializes and rehydrates const? Array types", function()
            local maybe_arr = types.Array(types.Integer(), "maybe")
            assert.equal("const? { integer }", types.tostring(maybe_arr))
            local serialized = types.serialize(maybe_arr)
            assert.match('"maybe"', serialized)
            local rehydrated = assert(load(
                "return " .. serialized, "test", "t", types))()
            assert.is_true(types.equals(maybe_arr, rehydrated))
            assert.equal("maybe", rehydrated.isconst)
        end)

        it("validates assignment adjustment rules for const? and linear arrays", function()
            local mutable_int = types.Array(types.Integer(), false)
            local const_int = types.Array(types.Integer(), true)
            local maybe_int = types.Array(types.Integer(), "maybe")
            local linear_int = types.Array(types.Integer(), false)
            linear_int.linear = true

            -- mutable, const, and maybe to maybe-const target
            assert.truthy(types.assignment_adjustment(mutable_int, maybe_int))
            assert.truthy(types.assignment_adjustment(const_int, maybe_int))
            assert.truthy(types.assignment_adjustment(maybe_int, maybe_int))

            -- maybe-const source to mutable or const target is rejected
            assert.falsy(types.assignment_adjustment(maybe_int, mutable_int))
            assert.falsy(types.assignment_adjustment(maybe_int, const_int))

            -- linear mutable array to const target produces in-place freeze
            local freeze_adj = types.assignment_adjustment(linear_int, const_int)
            assert.truthy(freeze_adj)
            assert.equal("written_cast", freeze_adj.kind)
            assert.equal("freeze", freeze_adj.mode)

            -- option propagation
            local opt_mutable = types.Option(mutable_int)
            local opt_const = types.Option(const_int)
            local opt_maybe = types.Option(maybe_int)
            assert.truthy(types.assignment_adjustment(opt_mutable, opt_maybe))
            assert.truthy(types.assignment_adjustment(opt_const, opt_maybe))
            assert.falsy(types.assignment_adjustment(opt_maybe, opt_mutable))
            assert.falsy(types.assignment_adjustment(opt_maybe, opt_const))
        end)
    end)

end)

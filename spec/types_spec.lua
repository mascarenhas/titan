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
            types.Field("sample.Box", "z", types.Integer(), 0),
            types.Field("sample.Box", "A", types.Integer(), 1),
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
        assert.same("{ integer }", types.tostring(types.Array(types.Integer())))
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

        assert.same("() -> () -> integer", types.tostring(fixed))
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

    -- TODO test vararg functions (types.Function with third argument as true)

    it("checks if a type is garbage collected", function()
        assert.truthy(types.is_gc(types.String()))
        assert.truthy(types.is_gc(types.Array(types.Integer())))
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

    describe("directional function compatibility", function()
        local function fn(params, results, varargtype, flexrettype)
            return types.Function(params or {}, results or {}, false,
                varargtype or false, flexrettype or false)
        end

        it("uses expected-found order for fixed input and result arity",
        function()
            local i, s = types.Integer(), types.String()
            local input_wide = fn({i, s})
            local input_short = fn({i})
            assert.truthy(types.compatible(input_wide, input_short))
            assert.falsy(types.compatible(input_short, input_wide))

            local result_short = fn({}, {i})
            local result_wide = fn({}, {i, s})
            assert.truthy(types.compatible(result_short, result_wide))
            assert.falsy(types.compatible(result_wide, result_short))
        end)

        it("checks moved fixed inputs and variadic tails contravariantly",
        function()
            local i, s = types.Integer(), types.String()
            local cases = {
                { "short actual ignores fixed suffix", fn({i, s}), fn({i}), true },
                { "actual integer tail accepts moved integer", fn({i, i}), fn({i}, {}, i), true },
                { "actual string tail rejects moved integer", fn({i, i}), fn({i}, {}, s), false },
                { "fixed actual ignores expected tail", fn({i}, {}, i), fn({i}), true },
                { "matching tails", fn({i}, {}, i), fn({i}, {}, i), true },
                { "incompatible observed tails", fn({i}, {}, i), fn({i}, {}, s), false },
                { "hidden actual fixed parameter", fn({i}, {}, i), fn({i, i}), false },
            }
            for _, case in ipairs(cases) do
                assert.same(case[4], types.compatible(case[2], case[3]),
                    case[1])
            end
        end)

        it("uses ordinary component coercions in the directional slots",
        function()
            local i, f, b = types.Integer(), types.Float(), types.Boolean()
            -- The actual accepts float, so an integer sent through the expected
            -- type can use the ordinary integer-to-float input conversion.
            assert.truthy(types.compatible(fn({i}), fn({f})))
            assert.truthy(types.compatible(fn({i}), fn({b})))
            -- The actual produces integer, so a float consumer can use the
            -- ordinary result conversion at the generic boundary.
            assert.truthy(types.compatible(fn({}, {f}), fn({}, {i})))
            assert.truthy(types.compatible(fn({}, {b}), fn({}, {i})))
        end)

        it("checks fixed and flexible results covariantly", function()
            local i, s = types.Integer(), types.String()
            local oi = types.Option(i)
            local cases = {
                { "actual fixed surplus is hidden", fn({}, {i}), fn({}, {i, s}), true },
                { "actual fixed deficit", fn({}, {i, i}), fn({}, {i}), false },
                { "safe optional flex projection", fn({}, {oi}), fn({}, {}, false, i), true },
                { "forced flex projection", fn({}, {i}), fn({}, {}, false, i), true },
                { "incompatible flex projection", fn({}, {s}), fn({}, {}, false, i), false },
                { "finite type ignores actual tail", fn({}, {i}), fn({}, {i}, false, s), true },
                { "open expected consumes fixed suffix", fn({}, {i}, false, i), fn({}, {i, i}), true },
                { "open expected rejects fixed suffix", fn({}, {i}, false, i), fn({}, {i, s}), false },
                { "open expected accepts empty fixed actual", fn({}, {}, false, i), fn(), true },
                { "matching result tails", fn({}, {}, false, i), fn({}, {}, false, i), true },
                { "incompatible result tails", fn({}, {}, false, i), fn({}, {}, false, s), false },
                { "finite zero-result hides actual tail", fn(), fn({}, {}, false, s), true },
            }
            for _, case in ipairs(cases) do
                assert.same(case[4], types.compatible(case[2], case[3]),
                    case[1])
            end
        end)

        it("reverses recursive compatibility only for parameter positions",
        function()
            local i = types.Integer()
            local callback_wide = fn({i, i})
            local callback_short = fn({i})
            local expects_short_callback = fn({callback_short})
            local accepts_wide_callback = fn({callback_wide})

            assert.truthy(types.compatible(
                expects_short_callback, accepts_wide_callback))
            assert.falsy(types.compatible(
                accepts_wide_callback, expects_short_callback))
        end)

        it("keeps nested tails and gradual components in expected-found roles",
        function()
            local i = types.Integer()
            local oi = types.Option(i)
            local v = types.Value()
            local a = types.Nominal("sample.A")
            local b = types.Nominal("sample.B")
            local callback_short = fn({i})
            local callback_wide = fn({i, i})

            -- Input tails are parameter positions, so recursive function
            -- compatibility is reversed. Flexible-result tails are result
            -- positions and preserve the expected/found order.
            assert.truthy(types.compatible(
                fn({}, {}, callback_short), fn({}, {}, callback_wide)))
            assert.falsy(types.compatible(
                fn({}, {}, callback_wide), fn({}, {}, callback_short)))
            assert.falsy(types.compatible(
                fn({}, {}, false, callback_short),
                fn({}, {}, false, callback_wide)))
            assert.truthy(types.compatible(
                fn({}, {}, false, callback_wide),
                fn({}, {}, false, callback_short)))

            -- Ordinary option adjustment and the deliberate two-way `value`
            -- rule remain available inside result positions. Nominal identity
            -- remains exact rather than becoming symmetric by fallback.
            local component_cases = {
                { "wrap optional result", fn({}, {oi}), fn({}, {i}), true },
                { "unwrap optional result", fn({}, {i}), fn({}, {oi}), true },
                { "value expected", fn({}, {v}), fn({}, {i}), true },
                { "value found", fn({}, {i}), fn({}, {v}), true },
                { "same nominal", fn({}, {a}), fn({}, {a}), true },
                { "different nominal", fn({}, {a}), fn({}, {b}), false },
            }
            for _, case in ipairs(component_cases) do
                assert.same(case[4], types.compatible(case[2], case[3]),
                    case[1])
            end
        end)

        it("keeps exact equality strict across all arity and tail fields",
        function()
            local i = types.Integer()
            local base = fn({i}, {i})
            assert.falsy(types.equals(base, fn({}, {i})))
            assert.falsy(types.equals(base, fn({i}, {i, i})))
            assert.falsy(types.equals(base, fn({i}, {i}, i)))
            assert.falsy(types.equals(base, fn({i}, {i}, false, i)))
            assert.falsy(types.equals(
                types.Function({i}, {i}, true, false, false), base))
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
        assert.same("(integer) -> (integer) -> integer",
            types.tostring(types.Function({int}, {intfn}, false, false, false)))
    end)

    it("treats compatible-but-not-equal function types distinctly", function()
        local exact = types.Function({types.Integer()}, {types.Integer()}, false, false, false)
        local valued = types.Function({types.Value()}, {types.Integer()}, false, false, false)
        -- value is compatible with integer, so the function types are compatible
        assert.truthy(types.compatible(exact, valued))
        assert.truthy(types.compatible(valued, exact))
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
            assert.same("double", types.tostring(types.CFloat("double")))
            assert.same("const int *", types.tostring(types.CPointer(int, {"const"})))
            assert.same("int[4]", types.tostring(types.CArray(int, 4)))
            assert.same("double (int, ...)", types.tostring(
                types.CFunction({int}, types.CFloat("double"), true, "cdecl")))
            assert.same("struct point", types.tostring(
                types.CStruct("struct point", "point", false, {}, true, false)))
            assert.same("union value", types.tostring(
                types.CUnion("union value", "value", false, {}, true)))
            assert.same("x: int", types.tostring(
                types.CField(false, "x", int, false, false)))
            assert.same("size_t", types.tostring(types.CTypedef("size_t", int)))
            assert.same("owned int", types.tostring(types.COwned(int, false)))
        end)

        it("uses CModule as the public foreign module type", function()
            local mod = types.CModule("stdio.h", { printf = cint() })
            assert.same("Type.CModule", mod._tag)
            assert.same("stdio.h", mod.name)
            assert.same("C module stdio.h", types.tostring(mod))
            assert.same(nil, types.ForeignModule)
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
                types.CFunction({int}, types.CVoid(), false, "cdecl"),
                types.CFunction({cint()}, types.CVoid(), false, "cdecl")))
            assert.falsy(types.equals(int, types.Integer()))
            assert.truthy(types.compatible(int, types.Integer()))
            assert.truthy(types.coerceable(int, types.Integer()))
        end)

        it("resolves C typedef chains", function()
            local int = cint()
            local size_t = types.CTypedef("size_t", int)
            local alias = types.CTypedef("alias_size_t", size_t)
            assert.same(int, types.resolve_c_typedef(alias))
            assert.truthy(types.compatible(alias, int))
            assert.truthy(types.equals(
                types.CTypedef("size_t", int),
                types.CTypedef("size_t", alias)))
        end)

        it("treats borrowed C pointers as nullable but owned C values as userdata", function()
            local ptr = types.CPointer(cint(), {})
            local owned = types.COwned(cint(), 1)

            assert.truthy(types.compatible(ptr, types.Nil()))
            assert.truthy(types.compatible(types.Nil(), ptr))
            assert.falsy(types.compatible(owned, types.Nil()))
            assert.falsy(types.compatible(types.Nil(), owned))
        end)

        it("allows only boxable C representations to cross through value", function()
            local int = cint()
            local ptr = types.CPointer(int, {})
            local arr = types.CArray(int, 4)
            local owned = types.COwned(int, true)
            local aggregate = types.CStruct("struct point", "point", false, {}, true, false)

            assert.truthy(types.compatible(int, types.Value()))
            assert.truthy(types.compatible(types.Value(), int))
            assert.truthy(types.compatible(ptr, types.Value()))
            assert.truthy(types.compatible(types.Value(), ptr))
            assert.falsy(types.compatible(arr, types.Value()))
            assert.falsy(types.compatible(types.Value(), arr))
            assert.truthy(types.compatible(owned, types.Value()))
            assert.truthy(types.compatible(types.Value(), owned))
            assert.falsy(types.compatible(aggregate, types.Value()))
            assert.falsy(types.compatible(types.Value(), aggregate))
        end)

        it("uses C-compatible pointer conversions", function()
            local int = cint()
            local alias = types.CTypedef("ffi_int", int)
            local iptr = types.CPointer(int, {})
            local vptr = types.CPointer(types.CVoid(), {})
            local const_vptr = types.CPointer(types.CVoid(), {"const"})
            local const_iptr = types.CPointer(int, {"const"})
            local alias_array = types.CArray(alias, 4)

            assert.truthy(types.compatible(vptr, iptr))
            assert.truthy(types.coerceable(iptr, vptr))
            assert.truthy(types.coerceable(iptr, const_vptr))
            assert.falsy(types.coerceable(const_iptr, vptr))
            assert.truthy(types.coerceable(const_iptr, const_vptr))
            assert.falsy(types.c_address_coerceable(iptr, const_vptr))
            assert.falsy(types.c_mutable_address_coerceable(iptr, vptr))
            assert.truthy(types.compatible(alias_array, iptr))
            assert.truthy(types.coerceable(alias_array, iptr))
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
            assert.truthy(types.first_c_ffi_type(
                types.Function({types.CPointer(cint(), {})}, {}, false, false,
                    false)))
            assert.truthy(types.first_c_ffi_type(types.Function(
                {}, {}, false, false, types.CPointer(cint(), {}))))
        end)

        it("rejects serializing C FFI types", function()
            local ok, err = pcall(types.serialize, types.CPointer(cint(), {}))
            assert.falsy(ok)
            assert.matches("cannot serialize C FFI type", err)

            ok, err = pcall(types.serialize, types.Array(types.CPointer(cint(), {})))
            assert.falsy(ok)
            assert.matches("cannot serialize C FFI type", err)
        end)

        it("pretty-prints legacy C struct and union placeholders", function()
            assert.same("struct ffi_point",
                types.tostring({ _tag = "Struct", name = "ffi_point" }))
            assert.same("union ffi_value",
                types.tostring({ _tag = "Union", name = "ffi_value" }))
        end)

        it("treats owned C pointers as GC values, but C modules as non-values", function()
            assert.truthy(types.is_gc(types.COwned(cint(), false)))
            assert.falsy(types.is_gc(types.CModule("ffi", {})))
            assert.falsy(types.is_c(types.CModule("ffi", {})))
            assert.falsy(types.is_truthy(types.CPointer(cint(), {})))
            assert.falsy(types.is_truthy(types.CTypedef(
                "ffi_iptr", types.CPointer(cint(), {}))))
            assert.truthy(types.is_truthy(types.COwned(cint(), false)))
            assert.falsy(types.is_falsy(types.CPointer(cint(), {})))
        end)
    end)

end)

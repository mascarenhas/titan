local types = require "titan-compiler.types"

describe("Titan types", function()

    it("pretty-prints types", function()
        assert.same("{ integer }", types.tostring(types.Array(types.Integer())))
    end)

    it("pretty-prints a function with multiple return types", function()
        local f = types.Function({types.Integer()},
                                 {types.Integer(), types.String()}, false, false)
        assert.same("(integer) -> (integer, string)", types.tostring(f))
    end)

    it("pretty-prints a method with one return type", function()
        local method = types.Method("sample.Box", "get",
            {types.Integer()}, {types.String()}, false)
        assert.same("sample.Box:get(integer): string", types.tostring(method))
    end)

    -- TODO test vararg functions (types.Function with third argument as true)

    it("checks if a type is garbage collected", function()
        assert.truthy(types.is_gc(types.String()))
        assert.truthy(types.is_gc(types.Array(types.Integer())))
        assert.truthy(types.is_gc(types.Map(types.Integer(), types.Integer())))
        assert.truthy(types.is_gc(types.Function({}, {}, false, false)))
    end)

    it("compares identical functions", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false)
        assert.truthy(types.equals(f1, f2))
    end)

    it("compares functions with different arguments", function()
        local f1 = types.Function({types.String(), types.Boolean()}, {types.Boolean()}, false, false)
        local f2 = types.Function({types.Integer(), types.Integer()}, {types.Boolean()}, false, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("compares functions with different returns", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Integer()}, false, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("compares functions of different input arity", function()
        local s = types.String()
        local f1 = types.Function({}, {s}, false, false)
        local f2 = types.Function({s}, {s}, false, false)
        local f3 = types.Function({s, s}, {s}, false, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("compares functions of different output arity", function()
        local s = types.String()
        local f1 = types.Function({s}, {}, false, false)
        local f2 = types.Function({s}, {s}, false, false)
        local f3 = types.Function({s}, {s, s}, false, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("pretty-prints a zero-return () function as `-> ()`", function()
        assert.same("() -> ()", types.tostring(types.Function({}, {}, false, false)))
        assert.same("(integer) -> ()",
            types.tostring(types.Function({types.Integer()}, {}, false, false)))
    end)

    it("distinguishes a zero-return () function from a nil-returning one", function()
        local void = types.Function({types.Integer()}, {}, false, false)
        local nilret = types.Function({types.Integer()}, {types.Nil()}, false, false)
        assert.falsy(types.equals(void, nilret))
        assert.same("(integer) -> nil", types.tostring(nilret))
    end)

    it("pretty-prints higher-order and function-returning-function types", function()
        local int = types.Integer()
        local intfn = types.Function({int}, {int}, false, false)
        -- (integer -> integer, integer) -> integer
        assert.same("((integer) -> integer, integer) -> integer",
            types.tostring(types.Function({intfn, int}, {int}, false, false)))
        -- (integer) -> ((integer) -> integer)
        assert.same("(integer) -> (integer) -> integer",
            types.tostring(types.Function({int}, {intfn}, false, false)))
    end)

    it("treats compatible-but-not-equal function types distinctly", function()
        local exact = types.Function({types.Integer()}, {types.Integer()}, false, false)
        local valued = types.Function({types.Value()}, {types.Integer()}, false, false)
        -- value is compatible with integer, so the function types are compatible
        assert.truthy(types.compatible(exact, valued))
        -- but they are not equal (so a fast-path tag match must not be assumed)
        assert.falsy(types.equals(exact, valued))
    end)

    it("round-trips nested function types through serialize/load", function()
        local int = types.Integer()
        local nested = types.Function(
            {types.Function({int}, {int}, false, false), int},
            {types.Function({}, {}, false, false)}, false, false)
        local s = types.serialize(nested)
        local rebuilt = load("return " .. s, "t", "t", types)()
        assert.truthy(types.equals(nested, rebuilt))
    end)

    it("reports nested function types as garbage collected", function()
        local int = types.Integer()
        local hof = types.Function({types.Function({int}, {int}, false, false)}, {int}, false, false)
        assert.truthy(types.is_gc(hof))
        assert.truthy(types.is_gc(types.Function({}, {}, false, false)))
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
            assert.truthy(types.is_c(types.ModuleMember("m", "x", types.CFloat("float"))))
            assert.falsy(types.is_c(types.Function({types.Integer()}, {types.String()}, false, false)))
            assert.falsy(types.is_c(types.Function({types.CPointer(cint(), {})}, {}, false, false)))
            assert.truthy(types.first_c_ffi_type(
                types.Function({types.CPointer(cint(), {})}, {}, false, false)))
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

local types = require "titan-compiler.types"

describe("Titan types", function()

    it("pretty-prints types", function()
        assert.same("{ integer }", types.tostring(types.Array(types.Integer())))
    end)

    it("pretty-prints a function with multiple return types", function()
        local f = types.Function({types.Integer()},
                                 {types.Integer(), types.String()}, false)
        assert.same("(integer) -> (integer, string)", types.tostring(f))
    end)

    -- TODO test vararg functions (types.Function with third argument as true)

    it("checks if a type is garbage collected", function()
        assert.truthy(types.is_gc(types.String()))
        assert.truthy(types.is_gc(types.Array(types.Integer())))
        assert.truthy(types.is_gc(types.Map(types.Integer(), types.Integer())))
        assert.truthy(types.is_gc(types.Function({}, {}, false)))
    end)

    it("compares identical functions", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false)
        assert.truthy(types.equals(f1, f2))
    end)

    it("compares functions with different arguments", function()
        local f1 = types.Function({types.String(), types.Boolean()}, {types.Boolean()}, false)
        local f2 = types.Function({types.Integer(), types.Integer()}, {types.Boolean()}, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("compares functions with different returns", function()
        local f1 = types.Function({types.String(), types.Integer()}, {types.Boolean()}, false)
        local f2 = types.Function({types.String(), types.Integer()}, {types.Integer()}, false)
        assert.falsy(types.equals(f1, f2))
    end)

    it("compares functions of different input arity", function()
        local s = types.String()
        local f1 = types.Function({}, {s}, false)
        local f2 = types.Function({s}, {s}, false)
        local f3 = types.Function({s, s}, {s}, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("compares functions of different output arity", function()
        local s = types.String()
        local f1 = types.Function({s}, {}, false)
        local f2 = types.Function({s}, {s}, false)
        local f3 = types.Function({s}, {s, s}, false)
        assert.falsy(types.equals(f1, f2))
        assert.falsy(types.equals(f2, f1))
        assert.falsy(types.equals(f2, f3))
        assert.falsy(types.equals(f3, f2))
        assert.falsy(types.equals(f1, f3))
        assert.falsy(types.equals(f3, f1))
    end)

    it("pretty-prints a zero-return () function as `-> ()`", function()
        assert.same("() -> ()", types.tostring(types.Function({}, {}, false)))
        assert.same("(integer) -> ()",
            types.tostring(types.Function({types.Integer()}, {}, false)))
    end)

    it("distinguishes a zero-return () function from a nil-returning one", function()
        local void = types.Function({types.Integer()}, {}, false)
        local nilret = types.Function({types.Integer()}, {types.Nil()}, false)
        assert.falsy(types.equals(void, nilret))
        assert.same("(integer) -> nil", types.tostring(nilret))
    end)

    it("pretty-prints higher-order and function-returning-function types", function()
        local int = types.Integer()
        local intfn = types.Function({int}, {int}, false)
        -- (integer -> integer, integer) -> integer
        assert.same("((integer) -> integer, integer) -> integer",
            types.tostring(types.Function({intfn, int}, {int}, false)))
        -- (integer) -> ((integer) -> integer)
        assert.same("(integer) -> (integer) -> integer",
            types.tostring(types.Function({int}, {intfn}, false)))
    end)

    it("treats compatible-but-not-equal function types distinctly", function()
        local exact = types.Function({types.Integer()}, {types.Integer()}, false)
        local valued = types.Function({types.Value()}, {types.Integer()}, false)
        -- value is compatible with integer, so the function types are compatible
        assert.truthy(types.compatible(exact, valued))
        -- but they are not equal (so a fast-path tag match must not be assumed)
        assert.falsy(types.equals(exact, valued))
    end)

    it("round-trips nested function types through serialize/load", function()
        local int = types.Integer()
        local nested = types.Function(
            {types.Function({int}, {int}, false), int},
            {types.Function({}, {}, false)}, false)
        local s = types.serialize(nested)
        local rebuilt = load("return " .. s, "t", "t", types)()
        assert.truthy(types.equals(nested, rebuilt))
    end)

    it("reports nested function types as garbage collected", function()
        local int = types.Integer()
        local hof = types.Function({types.Function({int}, {int}, false)}, {int}, false)
        assert.truthy(types.is_gc(hof))
        assert.truthy(types.is_gc(types.Function({}, {}, false)))
    end)

end)

-- Typechecker tests for the `.so`-only import path. Importing a module that is
-- available only as a compiled shared library forces the checker to *rehydrate*
-- that module's interface from its serialized `<mangled>_types` symbol (rather
-- than re-checking source). These tests verify that the rehydrated types --
-- functions, higher-order/first-class function types, records (incl. methods
-- and transitively-referenced records), and module variables -- are recovered
-- faithfully: correct uses type-check, and wrong uses are rejected using the
-- recovered signatures.
--
-- Each dependency is compiled to a `.so` straight from its AST (so its `.titan`
-- source never reaches the source path); only then is the TYPE CHECKER run on
-- the importer. No importer code is generated or executed here -- the end-to-end
-- run-time behaviour of the same path lives in spec/coder/so_import_spec.lua.
local h = require 'spec.support.helpers'
local so_check = h.check_against_so

describe("typechecker rehydration of .so-only imports", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        os.execute("rm -f *.c")
    end)

    it("rehydrates a function signature and checks calls against it", function ()
        local dep = { name = "rhfoo", src = [[
            function add(a: integer, b: integer): integer return a + b end
        ]] }
        local good = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2, 3) end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2) end   -- wrong arity
        ]])
        assert.truthy(#bad >= 1)
        assert.match("1 arguments but expects 2", table.concat(bad, "\n"))

        local badty = so_check({ dep }, "rhbar", [[
            local f = import "rhfoo"
            function bar(): integer return f.add(2, "x") end  -- wrong arg type
        ]])
        assert.truthy(#badty >= 1)
        assert.match("expected integer but found string", table.concat(badty, "\n"))
    end)

    it("rehydrates a higher-order / first-class function signature", function ()
        local dep = { name = "hofoo", src = [[
            function inc(x: integer): integer return x + 1 end
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
            function adder(): (integer) -> integer
                return inc  -- a function value of the rehydrated return type
            end
        ]] }
        -- the rehydrated `(integer) -> integer` parameter accepts a local fn
        local good = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function inc(x: integer): integer return x + 1 end
            function bar(): integer return f.apply(inc, 10) end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        -- a function-typed return value rehydrates and is assignable
        local good2 = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function bar(): integer
                local g: ((integer) -> integer, integer) -> integer = f.apply
                return g(f.adder(), 5)
            end
        ]])
        assert.equal(0, #good2, table.concat(good2, "\n"))

        -- passing a non-function where a function is expected is rejected
        local bad = so_check({ dep }, "hobar", [[
            local f = import "hofoo"
            function bar(): integer return f.apply(3, 10) end
        ]])
        assert.truthy(#bad >= 1)
    end)

    it("rehydrates a record type, its fields and methods", function ()
        local dep = { name = "recfoo", src = [[
            record Point
              x: float
              y: float
            end
            function Point:move(dx: float, dy: float): Point
                self.x, self.y = self.x + dx, self.y + dy
                return self
            end
        ]] }
        local good = so_check({ dep }, "recbar", [[
            local f = import "recfoo"
            function bar(): float
                local p: f.Point = f.Point.new(1.0, 2.0)
                p:move(3.0, 4.0)
                return p.x + p.y
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        -- a wrong field type in a constructor is caught against the recovered record
        local bad = so_check({ dep }, "recbar", [[
            local f = import "recfoo"
            function bar(): f.Point
                return f.Point.new("a", "b")
            end
        ]])
        assert.truthy(#bad >= 1)
    end)

    it("rehydrates a module variable's type", function ()
        local dep = { name = "varfoo", src = [[ count: integer = 0 ]] }
        local good = so_check({ dep }, "varbar", [[
            local f = import "varfoo"
            function bar(): integer
                f.count = 5
                return f.count
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "varbar", [[
            local f = import "varfoo"
            function bar(): integer
                f.count = "nope"   -- wrong type
                return f.count
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)

    it("rehydrates a record referenced transitively through a .so chain", function ()
        -- recpoint defines Point; recwrap (a .so) returns a Point but does not
        -- re-export it; rectop imports only recwrap. The checker must still
        -- recover Point (from recpoint's .so) so the nominal type resolves.
        local good = so_check({
            { name = "recpoint", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]] },
            { name = "recwrap", src = [[
                local p = import "recpoint"
                function make(x: float, y: float): p.Point
                    return { x = x, y = y }
                end
            ]] },
        }, "rectop", [[
            local w = import "recwrap"
            function bar(): float
                local pt = w.make(2.0, 3.0)
                pt:move(1.0, 1.0)
                return pt.x + pt.y
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
    end)
end)

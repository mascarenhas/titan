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
local checker = require 'titan-compiler.checker'
local parser = require 'titan-compiler.parser'
local types = require 'titan-compiler.types'
local driver = require 'titan-compiler.driver'

local verbose = false

local function parse(code) return parser.parse("(so_rehydrate)", code) end

-- Compile each dependency in `deps` ({name=, src=}, in dependency order) to a
-- `.so` from memory, then run ONLY the typechecker on `main_src` with the
-- dependencies reachable solely through their `.so`. Returns the list of type
-- errors reported for `main` (so tests can assert acceptance or a specific
-- rejection) and the recovered module type.
local function so_check(deps, main_name, main_src)
    for _, d in ipairs(deps) do
        types.registry = {}
        driver.imported = {}
        local sdeps = {}
        local ast = assert(parse(d.src), "parse " .. d.name)
        local _, errs = checker.check(d.name, ast, d.src, d.name .. ".titan",
            driver.defaultloader(sdeps))
        assert(#errs == 0, d.name .. ": " .. table.concat(errs, "\n"))
        local ok, err, lib = driver.compile(d.name, ast, nil, sdeps, verbose)
        assert(ok, err)
        ok, err = driver.compile_library(d.name, { lib }, nil, verbose)
        assert(ok, err)
    end
    types.registry = {}
    driver.imported = {}
    local mast = assert(parse(main_src), "parse " .. main_name)
    local mtype, errs = checker.check(main_name, mast, main_src,
        main_name .. ".titan", driver.defaultloader({}))
    return errs, mtype
end

describe("typechecker rehydration of .so-only imports", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not verbose then os.execute("rm -f *.c") end
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

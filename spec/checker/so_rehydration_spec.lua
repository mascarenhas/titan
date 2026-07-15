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
local types = require 'titan-compiler.types'
local generated_modules = {}

local function clean_generated_modules()
    for name in pairs(generated_modules) do
        os.remove(name .. ".c")
        os.remove(name .. ".o")
        os.remove(name .. ".so")
    end
    generated_modules = {}
end

local function so_check(deps, ...)
    for _, dep in ipairs(deps) do
        generated_modules[dep.name] = true
    end
    return h.check_against_so(deps, ...)
end

describe("typechecker rehydration of .so-only imports", function()
    after_each(clean_generated_modules)

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
            function bar(): integer return f.add(2) end   -- missing nil cannot fill integer
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found nil", table.concat(bad, "\n"))

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

    it("rehydrates only the public surface of records with local members", function ()
        local dep = { name = "lrecfoo", src = [[
            record Box
              local hidden: integer
              shown: integer
            end
            local function Box:secret(): integer
                return self.hidden
            end
            function Box:shown_twice(): integer
                return self.shown * 2
            end
            function make(hidden: integer, shown: integer): Box
                return Box.new(hidden, shown)
            end
            function Box.make(shown: integer): Box
                return Box.new(5, shown)
            end
            local function Box.secret_box(hidden: integer): Box
                return Box.new(hidden, 0)
            end
            function reveal(b: Box): integer
                return b.hidden + b:secret()
            end
        ]] }
        local good = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                local c = f.Box.make(13)
                return b.shown + b:shown_twice() + f.reveal(b) + c.shown
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local rec = assert(types.registry["lrecfoo.Box"])
        assert.equal(2, rec.nfields)
        assert.equal(1, #rec.fields)
        assert.equal("shown", rec.fields[1].name)
        assert.equal(1, rec.fields[1].index)
        assert.falsy(rec.functions.new)
        assert.truthy(rec.functions.make)
        assert.falsy(rec.functions.secret_box)
        assert.falsy(rec.methods.secret)
        assert.truthy(rec.methods.shown_twice)

        local hidden = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                return b.hidden
            end
        ]])
        assert.truthy(#hidden >= 1)
        assert.match("field 'hidden' not found in record 'lrecfoo%.Box'",
            table.concat(hidden, "\n"))

        local method = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                local b = f.make(3, 11)
                return b:secret()
            end
        ]])
        assert.truthy(#method >= 1)
        assert.match("method 'secret' not found in record 'lrecfoo%.Box'",
            table.concat(method, "\n"))

        local func = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): integer
                return f.Box.secret_box(3).shown
            end
        ]])
        assert.truthy(#func >= 1)
        assert.match("trying to access invalid record function 'secret_box'",
            table.concat(func, "\n"))

        local constructor = so_check({ dep }, "lrecbar", [[
            local f = import "lrecfoo"
            function bar(): f.Box
                return { shown = 11 }
            end
        ]])
        assert.truthy(#constructor >= 1)
        assert.match("cannot construct record type 'lrecfoo%.Box' outside module 'lrecfoo' because it has local fields",
            table.concat(constructor, "\n"))
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

    it("rehydrates a record referenced transitively through an option", function ()
        -- recpoint defines Point; recwrap (a .so) returns a Point? but does not
        -- re-export it; rectop imports only recwrap. The checker must descend
        -- through the option and recover Point so the nominal type resolves.
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
                function make(x: float, y: float): p.Point?
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
        assert.truthy(types.registry["recpoint.Point"],
            "recpoint.Point should be registered through the option type")
    end)

    it("recovers a record referenced ONLY as a vararg element type through a .so chain", function ()
        -- vrec defines Box; vrecwrap (a .so) exports a function whose ONLY
        -- reference to Box is as the `...` element type (`...: vrec.Box`), and does
        -- not re-export Box; vrectop imports only vrecwrap. The transitive
        -- record-recovery walker must descend into the Function type's
        -- `varargtype` (not just params/rettypes) to recover Box from vrec's .so,
        -- so the `vrec.Box` nominal resolves and the variadic call type-checks.
        local good = so_check({
            { name = "vrec", src = [[
                record Box
                  v: integer
                end
            ]] },
            { name = "vrecwrap", src = [[
                local r = import "vrec"
                function take(...: r.Box): integer
                    return #...
                end
            ]] },
        }, "vrectop", [[
            local w = import "vrecwrap"
            -- vrectop does NOT import vrec directly: the `vrec.Box` nominal in
            -- `take`'s recovered signature can only resolve if the recovery walker
            -- descended into the Function's varargtype. The empty-vararg call
            -- needs no Box value yet still type-checks against the recovered type.
            function bar(): integer
                return w.take()
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))
        -- The record reached solely via the vararg element type must be registered
        -- (it would be nil before the varargtype arm was added to the walker).
        assert.truthy(types.registry["vrec.Box"],
            "vrec.Box should be registered via the varargtype recovery walker")
    end)

    it("rehydrates a variadic function's varargtype through <mangled>_types", function ()
        -- The exported `sum` is `(...: integer) -> integer`; its serialized
        -- interface must carry the `varargtype` so the importer recovers the
        -- vararg element type. A correct variadic call (any count, integer
        -- elements) type-checks; passing a non-integer element is rejected against
        -- the recovered element type, and forwarding `...` from a caller whose own
        -- `...` element type is incompatible is rejected.
        local dep = { name = "vrhfoo", src = [[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
        ]] }
        local good = so_check({ dep }, "vrhbar", [[
            local f = import "vrhfoo"
            function bar(): integer return f.sum(1, 2, 3) end
            function empty(): integer return f.sum() end
            function asvalue(): integer
                local g: (...: integer) -> integer = f.sum  -- recovered varargtype
                return g(4, 5)
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "vrhbar", [[
            local f = import "vrhfoo"
            function bar(): integer return f.sum(1, "x", 3) end  -- non-integer element
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)

    it("rehydrates a variadic method's varargtype through <mangled>_types", function ()
        -- A variadic METHOD's varargtype must survive serialization too; a correct
        -- method call against the recovered signature type-checks.
        local dep = { name = "vmrhfoo", src = [[
            record Acc
              base: integer
            end
            function Acc:total(...: integer): integer
                local s = self.base
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function make(b: integer): Acc return { base = b } end
        ]] }
        local good = so_check({ dep }, "vmrhbar", [[
            local f = import "vmrhfoo"
            function bar(): integer
                local a = f.make(10)
                return a:total(1, 2, 3)
            end
        ]])
        assert.equal(0, #good, table.concat(good, "\n"))

        local bad = so_check({ dep }, "vmrhbar", [[
            local f = import "vmrhfoo"
            function bar(): integer
                local a = f.make(10)
                return a:total(1, "x")   -- non-integer element against recovered type
            end
        ]])
        assert.truthy(#bad >= 1)
        assert.match("expected integer but found string", table.concat(bad, "\n"))
    end)
end)

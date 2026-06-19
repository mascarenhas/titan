-- End-to-end tests for bound instance methods as first-class values (Phase 5 of
-- anonymous functions). `obj:m` with no argument list evaluates to a function
-- value of the method's type with the implicit `self` removed and the receiver
-- captured. Generate C, compile, run.
--
-- These exercise: both call paths (fast exact-type, slow via `value`), receiver
-- state mutation through the captured self, a bound method handed to Lua, a
-- cross-module / `.so`-only bound method (per-method trampolines reachable across
-- the boundary), and GC stress on a stored bound method.
local h = require 'spec.support.helpers'

local run_coder = h.run_coder

describe("bound methods (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("binds obj:m into a local then calls it (fast path)", function()
        run_coder([[
            record Adder base: integer end
            function Adder:add(x: integer): integer
                return self.base + x
            end
            function run(): integer
                local a = Adder.new(100)
                local f: (integer) -> integer = a:add
                return f(5) + f(7)
            end
        ]], [[
            assert(test.run() == 212)
        ]])
    end)

    it("binds obj:m as a `value` then calls it (slow path)", function()
        run_coder([[
            record Adder base: integer end
            function Adder:add(x: integer): integer
                return self.base + x
            end
            function run(): integer
                local a = Adder.new(100)
                local v: value = a:add
                local g = v as (integer) -> integer
                return g(5)
            end
        ]], [[
            assert(test.run() == 105)
        ]])
    end)

    it("mutates record state through the captured self (accumulates)", function()
        run_coder([[
            record Counter n: integer end
            function Counter:bump(): integer
                self.n = self.n + 1
                return self.n
            end
            function make(): () -> integer
                local c = Counter.new(0)
                return c:bump
            end
        ]], [[
            local f = test.make()
            assert(f() == 1)
            assert(f() == 2)
            assert(f() == 3)
            -- a second bound value over a fresh receiver is independent
            local g = test.make()
            assert(g() == 1)
            assert(f() == 4)
        ]])
    end)

    it("a bound method handed to Lua is callable from Lua", function()
        run_coder([[
            record Greeter prefix: string end
            function Greeter:greet(name: string): string
                return self.prefix .. name
            end
            function make(p: string): (string) -> string
                local g = Greeter.new(p)
                return g:greet
            end
        ]], [[
            local greet = test.make('hi ')
            assert(greet('bob') == 'hi bob')
            assert(greet('ann') == 'hi ann')
        ]])
    end)

    it("GC stress: bound method survives collection, self stays anchored", function()
        run_coder([[
            record Counter n: integer end
            function Counter:bump(): integer
                self.n = self.n + 1
                return self.n
            end
            function make(): () -> integer
                local c = Counter.new(0)
                return c:bump
            end
        ]], [[
            local f = test.make()
            collectgarbage()
            collectgarbage()
            assert(f() == 1)
            collectgarbage()
            assert(f() == 2)
            collectgarbage("collect")
            assert(f() == 3)
        ]])
    end)

    it("a bound method with multiple return values", function()
        run_coder([[
            record Pair a: integer b: integer end
            function Pair:both(): (integer, integer)
                return self.a, self.b
            end
            function run(): integer
                local p = Pair.new(3, 4)
                local f: () -> (integer, integer) = p:both
                local x, y = f()
                return x * 10 + y
            end
        ]], [[
            assert(test.run() == 34)
        ]])
    end)

    it("binds a void-returning method and calls it for effect", function()
        run_coder([[
            record Box v: integer end
            function Box:set(x: integer)
                self.v = x
            end
            function run(): integer
                local b = Box.new(0)
                local f: (integer) -> () = b:set
                f(99)
                return b.v
            end
        ]], [[
            assert(test.run() == 99)
        ]])
    end)

    it("binds a method on a .so-only module and calls it", function()
        local ok, err = h.build_so_chain({
            { name = "bmsofoo", src = [[
                record Counter n: integer end
                function Counter:bump(): integer
                    self.n = self.n + 1
                    return self.n
                end
                function newc(start: integer): Counter
                    return { n = start }
                end
            ]] },
            { name = "bmsobar", src = [[
                local f = import "bmsofoo"
                function run(): integer
                    local c = f.newc(10)
                    local g: () -> integer = c:bump
                    return g() + g()
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = h.call("bmsobar", "assert(bmsobar.run() == 23)")
        assert.truthy(rok, out)
        os.execute("rm -f *.o *.so *.c")
    end)

    it("takes the fast path for a bound method passed into a .so", function()
        -- The importer binds its own method to a value and passes it into a
        -- `.so`-only higher-order function that calls it. If the native
        -- trampoline pointer and the published type tag agree across the
        -- boundary, the call uses the fast path and returns the right value.
        local ok, err = h.build_so_chain({
            { name = "fpbmf", src = [[
                function inner(p: () -> integer): integer return p() end
            ]] },
            { name = "fpbmb", src = [[
                local a = import "fpbmf"
                record Counter n: integer end
                function Counter:get(): integer return self.n end
                function outer(g: (() -> integer) -> integer,
                               p: () -> integer): integer
                    return g(p)
                end
                function run(): integer
                    local c = Counter.new(42)
                    local p: () -> integer = c:get
                    return outer(a.inner, p)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = h.call("fpbmb", "assert(fpbmb.run() == 42)")
        assert.truthy(rok, out)
        os.execute("rm -f *.o *.so *.c")
    end)
end)

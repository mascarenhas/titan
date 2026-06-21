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
        os.execute("rm -rf *.o *.so *.dSYM")
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

    it("binds obj:m and calls it on both the fast and the slow path", function()
        -- `outer(g, p)` calls the function VALUE `g`. A bound method whose type is
        -- exactly `(()->integer)->integer` is called via the fast path (no extra
        -- Lua frame); a plain Lua closure in the same slot falls to the generic
        -- path through luaD_callnoyield (one extra frame). DEPTH_PROBE catches a
        -- tag mismatch that would silently downgrade the bound-method fast path.
        -- The bound method `c:call` also reads `self` (value correctness on the
        -- fast path).
        run_coder([[
            record Caller tag: integer end
            function Caller:call(p: () -> integer): integer
                return p() + self.tag
            end
            function outer(g: (() -> integer) -> integer,
                           p: () -> integer): integer
                return g(p)
            end
            -- fast path: the bound method `c:call` called at its exact type
            function run_fast(p: () -> integer): integer
                local c = Caller.new(0)
                return outer(c:call, p)
            end
            -- slow path: g arrives as a value whose tag is unknown statically
            function run_slow(g: (() -> integer) -> integer,
                              p: () -> integer): integer
                return outer(g, p)
            end
        ]], h.DEPTH_PROBE .. [[
            assert(test.run_fast(function () return 7 end) == 7)
            local fastd = test.run_fast(depth)
            local slowd = test.run_slow(slow_g, depth)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
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
        os.execute("rm -rf *.o *.so *.c *.dSYM")
    end)

    it("takes the fast path for a bound method passed into a .so", function()
        -- The importer binds its own method to a value and passes it into a
        -- `.so`-only higher-order function that calls it. If the native
        -- trampoline pointer and the published type tag agree across the
        -- boundary the call uses the fast path (no extra Lua frame); if they
        -- disagree it silently downgrades to the slow path. A DEPTH_PROBE
        -- assertion (the fast bound-method call is one frame shallower than a
        -- Lua-closure slow call) catches that downgrade, which a return-value
        -- check alone would not.
        local ok, err = h.build_so_chain({
            { name = "fpbmf", src = [[
                function inner(g: (() -> integer) -> integer,
                               p: () -> integer): integer
                    return g(p)
                end
            ]] },
            { name = "fpbmb", src = [[
                local a = import "fpbmf"
                record Caller tag: integer end
                function Caller:call(p: () -> integer): integer
                    return p() + self.tag
                end
                -- fast: the bound method `c:call` is the function value `g`
                function run_fast(p: () -> integer): integer
                    local c = Caller.new(0)
                    return a.inner(c:call, p)
                end
                -- slow: g arrives as a value whose tag is unknown statically
                function run_slow(g: (() -> integer) -> integer,
                                  p: () -> integer): integer
                    return a.inner(g, p)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = h.call("fpbmb", h.DEPTH_PROBE .. [[
            assert(fpbmb.run_fast(function () return 7 end) == 7)
            local fastd = fpbmb.run_fast(depth)
            local slowd = fpbmb.run_slow(slow_g, depth)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
        os.execute("rm -rf *.o *.so *.c *.dSYM")
    end)
end)

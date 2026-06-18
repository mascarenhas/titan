-- End-to-end tests for first-class function values: generate C, compile it, and
-- run it. Covers referencing/storing/passing/returning function values, the
-- exact-type fast call path and the generic (Lua-stack) slow path, stable
-- identity, Lua interop in both directions, source-linked cross-module
-- references, record statics as values, containers, value<->function coercion,
-- and GC safety.
--
-- The checker-only assertions live in spec/checker/first_class_functions_spec.lua,
-- the `.so`-only cross-module variants in spec/coder/so_import_spec.lua, and the
-- pure type-algebra assertions in spec/types_spec.lua.
local h = require 'spec.support.helpers'

local run_coder = h.run_coder
local generate_modules = h.generate_modules
local call = h.call

describe("first-class function values (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("references a top-level function and calls it through a value", function()
        run_coder([[
            function dbl(x: integer): integer return x * 2 end
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
            function run(): integer
                return apply(dbl, 21)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("stores a function value in a local and calls it", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local f: (integer) -> integer = inc
                return f(f(f(10)))
            end
        ]], [[
            assert(test.run() == 13)
        ]])
    end)

    it("gives an exported function value a stable identity", function()
        run_coder([[
            function foo(x: integer): integer return x end
            function get(): (integer) -> integer
                return foo
            end
        ]], [[
            assert(test.foo == test.foo)
            assert(test.get() == test.foo)
        ]])
    end)

    it("calls a Lua closure passed into Titan", function()
        run_coder([[
            function callwith(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]], [[
            assert(test.callwith(function(n) return n * 10 end, 5) == 50)
        ]])
    end)

    it("calls a multi-return function through a value", function()
        run_coder([[
            function dm(a: integer, b: integer): (integer, integer)
                return a // b, a % b
            end
            function run(): integer
                local f: (integer, integer) -> (integer, integer) = dm
                local q, r = f(13, 5)
                return q * 100 + r
            end
        ]], [[
            assert(test.run() == 203)
        ]])
    end)

    it("stores function values in an array and calls them", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function dec(x: integer): integer return x - 1 end
            function run(): integer
                local arr: {(integer) -> integer} = {inc, dec, inc}
                local s = 0
                for i = 1, 3 do
                    s = s + arr[i](10)
                end
                return s
            end
        ]], [[
            assert(test.run() == 31)
        ]])
    end)

    it("holds a function value in a record field", function()
        run_coder([[
            record Box
                fn: (integer) -> integer
            end
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local b: Box = Box.new(inc)
                return b.fn(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("round-trips a function through value and back", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local v: value = inc
                local f: (integer) -> integer = v
                return f(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("keeps a function value in a record alive across a collection", function()
        run_coder([[
            record Box
                fn: (integer) -> integer
            end
            function inc(x: integer): integer return x + 1 end
            function make(): Box return Box.new(inc) end
            function callbox(b: Box, x: integer): integer return b.fn(x) end
        ]], [[
            local b = test.make()
            collectgarbage("collect")
            collectgarbage("collect")
            assert(test.callbox(b, 41) == 42)
        ]])
    end)

    it("raises cleanly when calling a non-callable value", function()
        run_coder([[
            function callit(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]], [[
            local ok = pcall(test.callit, 42, 1)
            assert(not ok)
        ]])
    end)

    it("uses a record static (Rec.new) as a value", function()
        run_coder([[
            record Pair
                a: integer
                b: integer
            end
            function mk(f: (integer, integer) -> Pair): Pair
                return f(3, 4)
            end
            function run(): integer
                local p = mk(Pair.new)
                return p.a * 10 + p.b
            end
        ]], [[
            assert(test.run() == 34)
            assert(test.Pair.new == test.Pair.new)
        ]])
    end)

    it("returns a function from a branch then calls it", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function dec(x: integer): integer return x - 1 end
            function pick(up: boolean): (integer) -> integer
                if up then return inc else return dec end
            end
            function run(up: boolean, x: integer): integer
                local f = pick(up)
                return f(x)
            end
        ]], [[
            assert(test.run(true, 10) == 11)
            assert(test.run(false, 10) == 9)
        ]])
    end)

    it("defers the value->function callability check to the call", function()
        -- value -> function succeeds implicitly; the error is raised only when
        -- the value is actually called and turns out not to be callable.
        run_coder([[
            function tryit(v: value): integer
                local f: (integer) -> integer = v
                return f(10)
            end
        ]], [[
            assert(not pcall(test.tryit, 5))
            assert(test.tryit(function(n) return n + 100 end) == 110)
        ]])
    end)

    it("takes the exact-type fast path (no extra Lua frame), unlike the slow path", function()
        -- `outer` calls `g` as a value. With the Titan `inner` (exact type) the
        -- call uses the fast path -- a direct native call that pushes NO Lua
        -- frame -- so the stack seen by the probe is one frame shallower than
        -- with a Lua closure, which goes through luaD_callnoyield (the slow path).
        run_coder([[
            function inner(p: () -> integer): integer return p() end
            function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                return g(p)
            end
        ]], h.DEPTH_PROBE .. [[
            local fastd = test.outer(test.inner, depth)  -- Titan value: fast path
            local slowd = test.outer(slow_g, depth)      -- Lua closure: slow path
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
    end)

    it("calls a compatible-but-not-exact Titan function through the slow path", function()
        -- `f` is a Titan `(value) -> integer`. Viewed at the compatible type
        -- `(integer) -> integer` (via a `value` round-trip), its runtime type tag
        -- no longer matches the call site, so the value-call cannot take the
        -- exact-type fast path: it goes through the generic path, which coerces
        -- the integer argument to `value` at f's boundary. Result-correctness here
        -- proves the non-exact Titan->Titan slow path marshals arguments right.
        run_coder([[
            function f(x: value): integer
                local i: integer = x
                return i + 1
            end
            function run(): integer
                local v: value = f
                local g: (integer) -> integer = v
                return g(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("sends a non-exact Titan function value down the slow path (extra frame)", function()
        -- The value-call in `outer` dispatches on the *runtime* type tag of `g`.
        -- run_fast passes `inner` (exact type) -> tag matches -> fast path, no
        -- extra Lua frame. run_nonexact passes `inner_compat` (a Titan
        -- `(value) -> integer`, viewed at the call site's
        -- `(() -> integer) -> integer` type via a `value` round-trip) -> the tags
        -- differ, so although the callee IS a Titan function the call takes the
        -- slow path and adds a frame, exactly like the Lua-closure case. So a
        -- non-exact Titan->Titan call is one frame deeper than the exact one and
        -- the same depth as a Lua closure.
        run_coder([[
            function inner(p: () -> integer): integer return p() end
            function inner_compat(q: value): integer
                local fp: () -> integer = q
                return fp()
            end
            function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                return g(p)
            end
            function run_fast(p: () -> integer): integer
                return outer(inner, p)
            end
            function run_nonexact(p: () -> integer): integer
                local v: value = inner_compat
                local g: (() -> integer) -> integer = v
                return outer(g, p)
            end
            function run_slow(p: () -> integer,
                              g: (() -> integer) -> integer): integer
                return outer(g, p)
            end
        ]], h.DEPTH_PROBE .. [[
            local fastd = test.run_fast(depth)
            local nonexactd = test.run_nonexact(depth)
            local luaslowd = test.run_slow(depth, slow_g)
            assert(nonexactd > fastd,
                ('exact/fast=')..fastd..(' non-exact=')..nonexactd)
            assert(nonexactd == luaslowd,
                ('non-exact=')..nonexactd..(' lua-slow=')..luaslowd)
        ]])
    end)

    it("keeps the fast path after a value round-trip back to the original type", function()
        -- A function value moved through `value` and back to its ORIGINAL static
        -- type keeps its runtime type tag, so the value-call still matches the
        -- call site and stays on the fast path -- unlike the non-exact case above,
        -- which casts to a *different* compatible type and loses the match.
        -- Verified two ways: a Titan `value` round-trip (via_value), and a Lua
        -- round-trip (inner handed out through the module table and passed back
        -- into Titan). Both stay one frame shallower than a real Lua closure.
        run_coder([[
            function inner(p: () -> integer): integer return p() end
            function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                return g(p)
            end
            function direct(p: () -> integer): integer
                return outer(inner, p)
            end
            function via_value(p: () -> integer): integer
                local v: value = inner
                local g: (() -> integer) -> integer = v   -- back to inner's own type
                return outer(g, p)
            end
            function slow(p: () -> integer, g: (() -> integer) -> integer): integer
                return outer(g, p)
            end
        ]], h.DEPTH_PROBE .. [[
            local function lua_id(f) return f end
            local fastd  = test.direct(depth)
            local valued = test.via_value(depth)                  -- value -> back to same type
            local luad   = test.outer(lua_id(test.inner), depth)  -- Titan -> Lua -> back in
            local slowd  = test.slow(depth, slow_g)
            assert(valued == fastd, ('value-rt=')..valued..(' fast=')..fastd)
            assert(luad   == fastd, ('lua-rt=')..luad..(' fast=')..fastd)
            assert(slowd  >  fastd, ('slow=')..slowd..(' fast=')..fastd)
        ]])
    end)

    it("references and calls a function across a source-linked module", function()
        local ok, err = generate_modules({
            a = [[
                function dbl(x: integer): integer return x * 2 end
            ]],
            b = [[
                local a = import "a"
                function run(): integer
                    local f: (integer) -> integer = a.dbl
                    return f(21)
                end
                function direct(): integer
                    return a.dbl(21)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local rok, out = call("b", "assert(b.run() == 42); assert(b.direct() == 42)")
        assert.truthy(rok, out)
    end)

    it("passes a module's own function value into its own higher-order function", function()
        local ok, err = generate_modules({
            a = [[
                function inc(x: integer): integer return x + 1 end
                function twice(f: (integer) -> integer, x: integer): integer
                    return f(f(x))
                end
            ]],
            b = [[
                local a = import "a"
                function run(): integer
                    -- a.inc has the exact type a.twice expects; this test only
                    -- checks the result, not which call path is taken -- the
                    -- cross-module fast-path observation lives in the DEPTH_PROBE
                    -- test "takes the fast path for a function value across a
                    -- source-linked module".
                    return a.twice(a.inc, 10)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local rok, out = call("b", "assert(b.run() == 12)")
        assert.truthy(rok, out)
    end)

    it("passes a function value into another module's higher-order function", function()
        local ok, err = generate_modules({
            a = [[
                function compose2(f: (integer) -> integer, x: integer): integer
                    return f(x) + f(x)
                end
            ]],
            b = [[
                local a = import "a"
                function dbl(x: integer): integer return x * 2 end
                function run(): integer
                    return a.compose2(dbl, 5)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local rok, out = call("b", "assert(b.run() == 20)")
        assert.truthy(rok, out)
    end)

    it("takes the fast path for a function value across a source-linked module", function()
        -- Same stack-depth observation as the single-module fast-path test, but
        -- `outer` (module b) calls module a's `inner` as a value. The fast path
        -- fires only if a's and b's tags for the same function type agree, so a
        -- shallower stack confirms the cross-module tag agreement.
        local ok, err = generate_modules({
            spa = [[ function inner(p: () -> integer): integer return p() end ]],
            spb = [[
                local a = import "spa"
                function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                    return g(p)
                end
                function run_fast(p: () -> integer): integer return outer(a.inner, p) end
                function run_slow(p: () -> integer,
                                  g: (() -> integer) -> integer): integer
                    return outer(g, p)
                end
            ]],
        }, "spb")
        assert.truthy(ok, err)
        local rok, out = call("spb", h.DEPTH_PROBE .. [[
            local fastd = spb.run_fast(depth)
            local slowd = spb.run_slow(depth, slow_g)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
    end)
end)

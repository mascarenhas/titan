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

-- A variadic function IS a first-class value (§2.B). Dispatch is identical to a
-- non-variadic value: the fast path (exact runtime tag match) builds the backing
-- struct and calls the native pointer with `_varargs` + `_start`; a gradual
-- mismatch (a `...: value` slot holding a `...: integer` function) routes to the
-- generic Lua-stack path, where the callee's genluaentry coerces each surplus
-- arg and rebuilds the struct. The type tag folds in `varargtype` (via
-- function_sig + types.tostring), so the two element types get different tags.
describe("variadic function values (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("stores a variadic function in a local and calls it (fast path)", function()
        -- The local's static type EXACTLY matches sum's runtime type tag
        -- (`(...: integer) -> integer` both sides) -> fast native path: the value
        -- call builds the struct on the C stack and passes `_varargs` + `_start`.
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function run(): integer
                local f: (...: integer) -> integer = sum
                return f(1, 2, 3, 4) + f() + f(10)
            end
        ]], [[
            assert(test.run() == 10 + 0 + 10)
        ]])
    end)

    it("passes a variadic function as an argument and calls it", function()
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function apply3(f: (...: integer) -> integer): integer
                return f(1, 2, 3)
            end
            function run(): integer
                return apply3(sum)
            end
        ]], [[
            assert(test.run() == 6)
        ]])
    end)

    it("returns a variadic function then calls it as a value", function()
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function get(): (...: integer) -> integer
                return sum
            end
            function run(): integer
                local f = get()
                return f(5, 6, 7)
            end
        ]], [[
            assert(test.run() == 18)
            assert(test.get()(2, 2, 2, 2) == 8)
        ]])
    end)

    it("calls a variadic value forwarding the caller's own ...", function()
        -- The forwarder is ITSELF variadic; it forwards `...` into a variadic
        -- VALUE (not a static callee). The fast path builds the struct via the
        -- pass-through / start-adjust / fresh-copy cases just like a static call.
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function forward(f: (...: integer) -> integer, ...: integer): integer
                return f(...)          -- pass-through: forward ... into the value
            end
            function forward_prefix(f: (...: integer) -> integer, ...: integer): integer
                return f(100, ...)     -- fresh copy: prefix grows the tail
            end
            function run(): (integer, integer)
                return forward(sum, 1, 2, 3), forward_prefix(sum, 4, 5)
            end
        ]], [[
            local a, b = test.run()
            assert(a == 6, "forward="..a)
            assert(b == 109, "forward_prefix="..b)
        ]])
    end)

    it("routes a gradual mismatch (...: value holding ...: integer) through the generic path", function()
        -- `sum` is a Titan `(...: integer) -> integer`. Viewed at the COMPATIBLE
        -- type `(...: value) -> integer` (via a `value` round-trip), its runtime tag
        -- no longer matches the call site (the tags fold in varargtype, and
        -- `...: integer` != `...: value` under types.equals). So the value call cannot
        -- take the fast path: it goes generic, pushing each arg onto the Lua stack,
        -- and sum's genluaentry coerces each `value` surplus arg back to `integer`
        -- (the value->integer check lives in genluaentry, not the struct store).
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function run(): integer
                local v: value = sum
                local g: (...: value) -> integer = v   -- compatible, different tag
                return g(10, 20, 30)
            end
        ]], [[
            assert(test.run() == 60)
        ]])
    end)

    -- The struct build is now FAST-PATH-ONLY, so the generic path never narrows.
    -- This pins the corrected gradual-mismatch-narrowing behaviour: `h` is a
    -- Titan `(...: value) -> integer`; round-tripped through `value` it is stored in
    -- a slot whose STATIC type is `(...: integer) -> integer` (compatible both ways).
    -- A `...: value` forwarder `f` forwards its `...: value` tail into that slot. The
    -- forward into a STATIC `(...: integer)` type hits the struct build's CASE 3
    -- (different element representation => per-element conversion), whose narrowing
    -- arm is a `checkandget` value->integer. But the slot's RUNTIME tag is `h`'s
    -- `(...: value)`, so the call must go GENERIC and dispatch to `h`, which accepts
    -- every value. Pre-fix the struct build ran unconditionally (before the runtime
    -- tag check), so case-3's `checkandget` narrowed value->integer and RAISED on
    -- the non-integer tail elements ("x", 3.5) before the generic path could run;
    -- fast-path-only build => no spurious raise, all three values reach `h`.
    --
    -- Driven through the normal pcall-wrapping harness: a *generic* (tag-mismatch)
    -- value call made from inside a VARIADIC Titan function under an enclosing pcall
    -- frame returns its result correctly (the generic path's savestack/restorestack
    -- on `_vc_func` is relocation-safe and reads result slot 0 at `_vc_func + 0`,
    -- where luaD_callnoyield places the callee's return).
    it("does not narrow a forwarded ...: value tail on a gradual-mismatch generic call", function()
        run_coder([[
            function h(...: value): integer
                -- `h` accepts ANY value; report the count, proving all the
                -- (non-integer) elements reached it without a narrowing raise.
                return #...
            end
            function f(...: value): integer
                local v: value = h
                local g: (...: value) -> integer = v   -- runtime tag is h's (...: value)
                local gi: (...: integer) -> integer = g -- STATIC (...: integer): case-3 narrows
                return gi(...)                        -- forward f's ...: value tail
            end
        ]], [[
            -- the generic path forwards all 3 values to h -> #... == 3
            -- (case-3 narrowing would have spuriously RAISED on "x"/3.5 pre-fix)
            assert(test.f(1, "x", 3.5) == 3)
        ]])
    end)

    -- Regression for the exact conjunction that was suspected of corrupting the
    -- result (variadic CALLER + a generic/tag-mismatch value call + an enclosing
    -- pcall, which is what the run_coder/busted harness installs around every
    -- call). `f` is variadic; the value it calls is `sum` viewed at a COMPATIBLE
    -- but differently-tagged type (`(...: value) -> integer` over a `(...: integer)`
    -- function), so the runtime tag never matches and the call takes the GENERIC
    -- Lua-stack path. The result must be the callee's return value, NOT the callee
    -- closure that the generic path pushed at `_vc_func`.
    it("generic value call from a variadic caller returns its result (not the callee) under pcall", function()
        run_coder([[
            function sum(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function f(...: integer): integer
                local v: value = sum
                local g: (...: value) -> integer = v   -- compatible, different tag => generic
                return g(...)
            end
        ]], [[
            local r = test.f(10, 20, 30)
            assert(r == 60, "expected 60, got "..tostring(r).." ("..type(r)..")")
        ]])
    end)

    it("calls a Lua closure through a variadic value type", function()
        -- A genuinely-foreign Lua closure stored at a variadic Titan function
        -- type: tag never matches, so the generic path drives it; genluaentry on
        -- the Lua side is the Lua function itself (no Titan entry), and the
        -- arguments arrive as plain Lua values.
        run_coder([[
            function callwith(f: (...: integer) -> integer): integer
                return f(3, 4, 5)
            end
        ]], [[
            local r = test.callwith(function(...)
                local s = 0
                for _, n in ipairs({...}) do s = s + n end
                return s
            end)
            assert(r == 12, "got "..r)
        ]])
    end)

    it("survives a forced GC with collectable elements through a value call", function()
        -- A `(...: string) -> integer` value call carrying FRESH (non-interned)
        -- strings, with a forced GC in the callee before any `...[i]` read. The
        -- struct payload is untraced (§2.D); the elements survive only via their
        -- source-slot anchors, which the value-call path keeps live across the
        -- call (the whole dispatch runs inside `stats`, before any L->top.p reset).
        run_coder([[
            function totallen(...: string): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do junk = { k, k + 1 }; k = k + 1 end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do s = s + #(...[i]); i = i + 1 end
                return s
            end
            function run(a: string, b: string, c: string): integer
                local f: (...: string) -> integer = totallen
                return f(a, b, c)
            end
        ]], [[
            collectgarbage("incremental")
            local a = ("p"):rep(5) .. "1"   -- length 6
            local b = ("q"):rep(7) .. "2"   -- length 8
            local c = ("r"):rep(3) .. "3"   -- length 4
            assert(test.run(a, b, c) == 6 + 8 + 4)
        ]])
    end)

    it("uses a variadic bound method (obj:m) as a value", function()
        -- A variadic METHOD's bound reference `obj:m` is a normal first-class
        -- value; calling it dispatches through the bound-method trampoline, which
        -- forwards the backing struct + start verbatim.
        run_coder([[
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
            function run(): integer
                local a: Acc = Acc.new(100)
                local m: (...: integer) -> integer = a:total
                return m(1, 2, 3)
            end
        ]], [[
            assert(test.run() == 106)
        ]])
    end)

    it("takes the fast path on tag match and the slow path on mismatch", function()
        -- Depth probe: an exact-typed variadic value call (the higher-order arg
        -- `p` is itself called inside the variadic callee, so its frame depth is
        -- observable) uses the native fast path -- no extra Lua frame -- when the
        -- value's runtime tag matches; a real Lua closure (the slow `g`) is one
        -- frame deeper. The probe `p` records the stack depth at which it runs.
        run_coder([[
            function inner(f: () -> integer, ...: integer): integer
                local s = f()
                local i = 1
                local n = #...
                while i <= n do s = s + ...[i]; i = i + 1 end
                return s
            end
            function outer(g: (() -> integer, ...: integer) -> integer,
                           p: () -> integer): integer
                return g(p, 1, 2, 3)
            end
            function run_fast(p: () -> integer): integer
                return outer(inner, p)   -- exact tag -> fast native path
            end
            function run_slow(p: () -> integer,
                              g: (() -> integer, ...: integer) -> integer): integer
                return outer(g, p)       -- a Lua closure g -> slow path
            end
        ]], h.DEPTH_PROBE .. [[
            local function slow_g2(p, ...)
                local s = p()
                for _, n in ipairs({...}) do s = s + n end
                return s
            end
            local fastd = test.run_fast(depth)
            local slowd = test.run_slow(depth, slow_g2)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
    end)
end)

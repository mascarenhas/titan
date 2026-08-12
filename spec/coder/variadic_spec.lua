-- End-to-end tests for variadic parameters (`...`): generate C, compile it, and
-- run it. Covers scalar and collectable `...` elements, forwarding an existing
-- `...` to another variadic callee, building `{...}` / `{e1, ..., ...}` arrays
-- from a vararg, GC provenance of variadic arguments under generational mode, and
-- assorted functional coverage gaps (nested variadic lambdas, map-typed
-- elements, variadic methods, side-effecting `...[i]`, `...: boolean`, and the
-- `{...}`-of-a-`value`-vararg-with-a-nil border semantics).
--
-- The checker-only counterparts live in spec/checker/variadic_spec.lua.
local h = require 'spec.support.helpers'

local run_coder = h.run_coder

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("scalar variadic parameters (code generator)", function()
    after_each(clean)

    it("integer vararg: #... and ...[i] called from Lua", function()
        run_coder([[
            function sum(base: integer, ...: integer): integer
                local n = #...
                local s = base
                local i = 1
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
        ]], [[
            assert(test.sum(0) == 0)
            assert(test.sum(0, 1, 2, 3) == 6)
            assert(test.sum(100, 1, 2, 3) == 106)
            assert(test.sum(10, 5) == 15)
        ]])
    end)

    it("float vararg: #... and ...[i] called from Lua", function()
        run_coder([[
            function fsum(...: float): float
                local n = #...
                local s = 0.0
                local i = 1
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
        ]], [[
            assert(test.fsum() == 0.0)
            assert(math.abs(test.fsum(1.5, 2.25, 0.25) - 4.0) < 1e-9)
        ]])
    end)

    it("boolean vararg: #... and ...[i] called from Lua", function()
        run_coder([[
            function allset(...: boolean): boolean
                local n = #...
                local i = 1
                while i <= n do
                    if not ...[i] then
                        return false
                    end
                    i = i + 1
                end
                return true
            end
        ]], [[
            assert(test.allset() == true)
            assert(test.allset(true, true, true) == true)
            assert(test.allset(true, false, true) == false)
        ]])
    end)

    it("#... is 0 and ...[1] raises for the empty vararg", function()
        run_coder([[
            function count(...: integer): integer
                return #...
            end
            function first(...: integer): integer
                return ...[1]
            end
        ]], [[
            assert(test.count() == 0)
            assert(test.first(7) == 7)
        ]])
    end)

    it("...[i] raises a runtime error when out of range", function()
        run_coder([[
            function first(...: integer): integer
                return ...[1]
            end
        ]], [[
            test.first()
        ]], "out of range")
    end)

    it("...[i] raises a runtime error when i <= 0", function()
        run_coder([[
            function at(i: integer, ...: integer): integer
                return ...[i]
            end
        ]], [[
            test.at(0, 10, 20, 30)
        ]], "out of range")
    end)

    it("...[i] past the end raises a runtime error", function()
        run_coder([[
            function at(i: integer, ...: integer): integer
                return ...[i]
            end
        ]], [[
            test.at(4, 10, 20, 30)
        ]], "out of range")
    end)

    it("calls a variadic callee with a static arg list from Titan", function()
        run_coder([[
            function sum(base: integer, ...: integer): integer
                local n = #...
                local s = base
                local i = 1
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
            function caller(): integer
                return sum(100, 1, 2, 3, 4)
            end
            function caller_empty(): integer
                return sum(50)
            end
        ]], [[
            assert(test.caller() == 110)
            assert(test.caller_empty() == 50)
        ]])
    end)

    it("static call site builds a struct for a no-fixed-param variadic callee", function()
        run_coder([[
            function fsum(...: float): float
                local n = #...
                local s = 0.0
                local i = 1
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
            function caller(): float
                return fsum(1.0, 2.0, 3.0)
            end
        ]], [[
            assert(math.abs(test.caller() - 6.0) < 1e-9)
        ]])
    end)

    it("return ... adjust-up fills a fixed return arity from the vararg", function()
        run_coder([[
            function pair(...: integer): (integer, integer)
                return ...
            end
        ]], [[
            local a, b = test.pair(11, 22, 33)
            assert(a == 11)
            assert(b == 22)
        ]])
    end)

    it("local-hydration adjust-up reads ...[k] for each slot", function()
        run_coder([[
            function third(...: integer): integer
                local a, b, c = ...
                return c
            end
        ]], [[
            assert(test.third(7, 8, 9) == 9)
        ]])
    end)

    it("local-hydration into an optional slot nil-fills out of range", function()
        run_coder([[
            function maybe(...: integer): integer?
                local a: integer, b: integer? = ...
                return b
            end
        ]], [[
            assert(test.maybe(1) == nil)
            assert(test.maybe(1, 2) == 2)
        ]])
    end)

    -- Optional adjust-up ACROSS representations: the in-range element must be
    -- CONVERTED from the vararg element type to the option base, not stored raw.
    -- A raw store would bit-reinterpret the element (integer bits read as a
    -- double, or a tagless scalar read as a pointer). One case per adjust-up
    -- site (decl / assign / return / call-arg), plus the boxed `value?` form.
    it("optional decl `float? = ...: integer` converts element to float", function()
        run_coder([[
            function f(...: integer): float
                local x: float? = ...
                if x then return x + 0.5 else return -1.0 end
            end
        ]], [[
            assert(math.type(test.f(7)) == 'float')
            assert(test.f(7) == 7.5)
            assert(test.f() == -1.0)
        ]])
    end)

    it("optional assign `x = ...: integer` (x:float?) converts to float", function()
        run_coder([[
            function f(...: integer): float
                local x: float? = nil
                x = ...
                if x then return x + 0.5 else return -1.0 end
            end
        ]], [[
            assert(math.type(test.f(7)) == 'float')
            assert(test.f(7) == 7.5)
            assert(test.f() == -1.0)
        ]])
    end)

    it("optional `return ...: integer` into a float? return converts to float", function()
        run_coder([[
            function f(...: integer): float?
                return ...
            end
        ]], [[
            assert(math.type(test.f(7)) == 'float')
            assert(test.f(7) == 7.0)
            assert(test.f() == nil)
        ]])
    end)

    it("optional call-arg `...: integer` into a float? fixed param converts", function()
        run_coder([[
            function g(a: float?): float
                if a then return a + 0.5 else return -1.0 end
            end
            function f(...: integer): float
                return g(...)
            end
        ]], [[
            assert(math.type(test.f(7)) == 'float')
            assert(test.f(7) == 7.5)
            assert(test.f() == -1.0)
        ]])
    end)

    it("optional decl `integer? = ...: float` converts element to integer", function()
        run_coder([[
            function f(...: float): integer
                local x: integer? = ...
                if x then return x + 1 else return -1 end
            end
        ]], [[
            assert(math.type(test.f(7.0)) == 'integer')
            assert(test.f(7.0) == 8)
            assert(test.f() == -1)
        ]])
    end)

    it("optional decl `value? = ...: integer` boxes the element correctly", function()
        run_coder([[
            function f(...: integer): value
                local x: value? = ...
                if x then return x else return -1 end
            end
        ]], [[
            assert(math.type(test.f(65)) == 'integer')
            assert(test.f(65) == 65)
        ]])
    end)
end)

describe("collectable variadic parameters (code generator)", function()
    after_each(clean)

    it("keeps static and forwarded native varargs in untraced C storage",
    function()
        local csrc = h.compile_and_read_c([[
            local function sink(...: string): integer
                return #...
            end

            function static_list(a: string, b: string): integer
                return sink(a, b)
            end

            function forward(prefix: string, ...: string): integer
                return sink(prefix, ...)
            end
        ]])
        local function native_body(name)
            local signature = "lua_Integer test_\\u2133_" .. name .. "_titan("
            local declaration = assert(csrc:find(signature, 1, true))
            local first = assert(csrc:find(
                signature, declaration + 1, true))
            local last = assert(csrc:find(
                "static int test_\\u2133_" .. name .. "_titanentry_lua",
                first, true))
            return csrc:sub(first, last - 1)
        end

        local fixed = native_body("static_list")
        assert.truthy(fixed:find(
            "TString%s*%*%s*_vargargs_1%[2%]%s*=%s*" ..
                "{%s*_param_a%s*,%s*_param_b%s*};"), fixed)
        assert.falsy(fixed:find("setsvalue(L", 1, true), fixed)

        local open = native_body("forward")
        local freeze = assert(open:find(
            "_tmp_1 = _param_prefix;", 1, true))
        local prefix = assert(open:find(
            "_open_vargs_2[0] = _tmp_1;", freeze, true))
        local borrow = assert(open:find(
            "=%s*_varargs%-%>args%[", prefix))
        local call = assert(open:find(
            "_titan%s*%(%s*L%s*,%s*_mod%s*,%s*NULL%s*,%s*" ..
                "&_open_vargdesc_2%s*,%s*0%s*%);", borrow))
        assert.falsy(open:sub(freeze, call):find(
            "setsvalue(L", 1, true), open)
        assert.is_true(freeze < prefix and prefix < borrow and borrow < call)
    end)

    -- A `...: string` callee that FORCES a garbage collection in its body (an
    -- allocating loop trips luaC_checkGC) BEFORE reading any `...[i]`. The vararg
    -- struct's payload (raw TString*) is untraced (§2.D); because this call
    -- originates in Lua, the actual VM argument slots retain the elements. Losing
    -- that real transport provenance is near-deterministic corruption.
    it("...: string survives a forced GC in the callee, called from Lua", function()
        run_coder([[
            function totallen(...: string): integer
                -- churn the heap so a minor collection runs before we touch ...[i]
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k, k + 1, k + 2 }
                    k = k + 1
                end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    s = s + #(...[i])
                    i = i + 1
                end
                return s
            end
        ]], [[
            collectgarbage("incremental")
            assert(test.totallen() == 0)
            -- fresh strings (not interned constants) so a dropped anchor collects them
            local a = ("x"):rep(5) .. "1"
            local b = ("y"):rep(7) .. "2"
            local c = ("z"):rep(3) .. "3"
            assert(test.totallen(a, b, c) == 6 + 8 + 4)
        ]])
    end)

    -- Same discipline through the STATIC call site: a Titan caller builds an
    -- untraced descriptor in C and tail-calls a callee that collects before use.
    -- The caller's parameters retain their upstream Lua VM provenance and the
    -- literal retains its ordinary allocation provenance; no static-call input
    -- roots are introduced when `return callee(...)` resets the caller top.
    it("...: string survives a forced GC across a static (Titan) call site", function()
        run_coder([[
            function totallen(...: string): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k, k + 1, k + 2 }
                    k = k + 1
                end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    s = s + #(...[i])
                    i = i + 1
                end
                return s
            end
            function caller(p: string, q: string): integer
                -- fresh strings flow straight into the struct; tail position
                return totallen(p, q, "lit3")
            end
        ]], [[
            collectgarbage("incremental")
            local a = ("a"):rep(4) .. "!"   -- length 5
            local b = ("b"):rep(6) .. "!"   -- length 7
            assert(test.caller(a, b) == 5 + 7 + 4)
        ]])
    end)

    -- A `...: {integer}` callee: exact Array elements remain backing Table*
    -- values in the descriptor's Table** buffer. Read each after a forced GC.
    it("...: {integer} (array) survives a forced GC in the callee", function()
        run_coder([[
            function one(n: integer): {integer}
                return {n}
            end
            function two(a: integer, b: integer): {integer}
                return {a, b}
            end
            function firstsum(...: {integer}): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    s = s + (...[i])[1]
                    i = i + 1
                end
                return s
            end
        ]], [[
            collectgarbage("incremental")
            assert(test.firstsum() == 0)
            assert(test.firstsum(test.one(10), test.two(20, 99), test.one(30)) == 60)
        ]])
    end)

    -- A `...: R` (record/Nominal, Udata*) callee, exercised from BOTH Lua and Titan
    -- with a static arg list, with a forced GC before reading the record fields.
    it("...: R (record) survives a forced GC, from Lua and from Titan", function()
        run_coder([[
            record P
                x: integer
            end
            function sumx(...: P): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    s = s + (...[i]).x
                    i = i + 1
                end
                return s
            end
            function callsumx(a: P, b: P, c: P): integer
                return sumx(a, b, c)
            end
            function mk(v: integer): P
                return { x = v }
            end
        ]], [[
            collectgarbage("incremental")
            local a, b, c = test.mk(3), test.mk(5), test.mk(7)
            assert(test.sumx(a, b, c) == 15)          -- from Lua (genluaentry)
            assert(test.callsumx(a, b, c) == 15)      -- from Titan (static struct)
            assert(test.sumx() == 0)
        ]])
    end)

    -- A `...: value` (TValue element) slice carrying MIXED types, read back after a
    -- forced GC. The struct holds 16-byte tagged TValues whose collectable
    -- payload is untraced; this Lua-originated call borrows the actual VM argument
    -- slots that transport the values.
    it("...: value carries mixed types through a forced GC", function()
        run_coder([[
            function pick(which: integer, ...: value): value
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                return ...[which]
            end
        ]], [[
            collectgarbage("incremental")
            local s = ("m"):rep(9) .. "?"
            -- mixed: integer, fresh string, float, boolean
            assert(test.pick(1, 42, s, 3.5, true) == 42)
            assert(test.pick(2, 42, s, 3.5, true) == s)
            assert(math.abs(test.pick(3, 42, s, 3.5, true) - 3.5) < 1e-9)
            assert(test.pick(4, 42, s, 3.5, true) == true)
        ]])
    end)

    -- A VOID-returning `...: string` callee (collectable element type, returns
    -- nothing) called in STATEMENT position. The static call site sets
    -- varg_collectable = true / dots_tail_close = false, so the void result must
    -- be routed through the void branch and emit the call for effect -- NOT fall
    -- into the varg_collectable branch which would `newtmp(Type.Void)` and raise
    -- "invalid type void". Pins that void + collectable-vararg codegen compiles.
    it("void-returning ...: string called in statement position from Titan and Lua", function()
        run_coder([[
            total: integer = 0
            function sink(...: string)
                local n = #...
                local i = 1
                while i <= n do
                    total = total + #(...[i])
                    i = i + 1
                end
            end
            function drive(a: string, b: string)
                -- static statement call carrying collectable vararg elements
                sink(a, b, "lit3")
            end
        ]], [[
            test.total = 0
            test.drive("xy", "zzz")          -- 2 + 3 + 4
            assert(test.total == 9)
            test.total = 0
            test.sink("a", "bb", "ccc")      -- from Lua: 1 + 2 + 3
            assert(test.total == 6)
            test.total = 0
            test.sink()                      -- empty vararg, no-op
            assert(test.total == 0)
        ]])
    end)
end)

describe("forwarding an existing ... to another variadic callee", function()
    after_each(clean)

    -- CASE 1 (pass-through): caller static prefix exactly fills the callee fixed
    -- params and the element type matches; the current backing struct + start are
    -- passed through unchanged (no allocation, no copy). `g` must see the same
    -- elements the forwarder received.
    it("case 1 pass-through: g(a, ...) with matching fixed arity and element type", function()
        run_coder([[
            function g(a: integer, ...: integer): integer
                local s = a
                local i = 1
                local n = #...
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
            function f(...: integer): integer
                return g(1000, ...)
            end
        ]], [[
            assert(test.f() == 1000)            -- empty tail passes through
            assert(test.f(1, 2, 3) == 1006)     -- a=1000, tail {1,2,3}
            assert(test.f(7) == 1007)
        ]])
    end)

    -- CASE 2 (start-adjust): the callee has MORE fixed params than the caller
    -- supplies static args, so a vararg element is consumed as a fixed param. The
    -- same backing struct is passed with `_start + delta`; no struct mutation,
    -- no save/restore. Verify both the borrowed fixed element and the shortened
    -- tail the callee sees.
    it("case 2 start-adjust: g(x, y, ...) consumes a vararg element as a fixed param", function()
        run_coder([[
            function g(x: integer, y: integer, ...: integer): integer
                -- encode: x*100000 + y*1000 + (#... is tail length)*10 + first-tail
                local n = #...
                local first = 0
                if n > 0 then
                    first = ...[1]
                end
                return x * 100000 + y * 1000 + n * 10 + first
            end
            function f(...: integer): integer
                -- caller supplies one static arg (x=5); g needs two fixed params,
                -- so y is borrowed from ...[1] and the tail starts at ...[2].
                return g(5, ...)
            end
        ]], [[
            -- f(11, 22, 33): x=5, y=11 (borrowed), tail={22,33} so n=2, first=22
            assert(test.f(11, 22, 33) == 5 * 100000 + 11 * 1000 + 2 * 10 + 22)
            -- f(11): x=5, y=11 (borrowed), tail={} so n=0, first=0
            assert(test.f(11) == 5 * 100000 + 11 * 1000 + 0)
        ]])
    end)

    -- Two forwarding args in one expression (g(h1(...), h2(...))). Because case 2
    -- never mutates the backing struct (start is a parameter), correctness does not
    -- depend on the C argument-evaluation order. Both h1 and h2 forward the SAME
    -- `...` start-adjusted independently.
    it("case 2: g(h1(...), h2(...)) is order-independent (no struct mutation)", function()
        run_coder([[
            function h1(a: integer, ...: integer): integer
                -- a borrowed as fixed; returns a + first tail element (or a)
                local n = #...
                if n > 0 then
                    return a + ...[1]
                end
                return a
            end
            function h2(a: integer, b: integer, ...: integer): integer
                -- two fixed params: a, b borrowed; returns a*1000 + b
                return a * 1000 + b
            end
            function g(p: integer, q: integer): integer
                return p * 1000000 + q
            end
            function f(...: integer): integer
                -- h1 borrows ...[1] as `a`, tail starts at ...[2]
                -- h2 borrows ...[1],...[2] as a,b
                return g(h1(...), h2(...))
            end
        ]], [[
            -- f(3, 4, 5):
            --   h1: a=3, tail={4,5}, returns 3+4 = 7
            --   h2: a=3, b=4, returns 3004
            --   g(7, 3004) = 7000000 + 3004 = 7003004
            assert(test.f(3, 4, 5) == 7003004)
        ]])
    end)

    -- CASE 3 (fresh copy), element-type MISMATCH: forward `...: integer` into a
    -- `...: value` callee. Each integer element is boxed into a TValue in a fresh
    -- Udata0 backing struct. A forced GC in the deepest callee proves the fresh
    -- buffer's initial allocation root; these boxed integer elements are non-GC.
    it("case 3 type-mismatch: ...: integer forwarded to ...: value (each element boxed)", function()
        run_coder([[
            -- sink takes ...: value; the forwarder forwards ...: integer, so each
            -- integer element is BOXED into a TValue in a fresh Udata0 (case 3,
            -- element-representation mismatch). sink returns the which-th value
            -- back to Lua unchanged, proving the boxed elements are intact.
            function sink(which: integer, ...: value): value
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                return ...[which]
            end
            function count(...: value): integer
                return #...
            end
            function f(which: integer, ...: integer): value
                return sink(which, ...)
            end
            function n(...: integer): integer
                return count(...)
            end
        ]], [[
            collectgarbage("incremental")
            assert(test.n() == 0)
            assert(test.n(10, 20, 30) == 3)
            -- stepped GC across the boxed-element forward + the value-typed result
            -- (the gc-result rebase path)
            for trial = 1, 50 do
                collectgarbage("step")
                assert(test.f(1, 10, 20, 30) == 10)
                assert(test.f(2, 10, 20, 30) == 20)
                assert(test.f(3, 10, 20, 30) == 30)
            end
        ]])
    end)

    -- CASE 3 (fresh copy), element-type MISMATCH, NARROWING direction: forward
    -- `...: value` into a `...: integer` callee. The source element IS a TValue, so
    -- the per-element conversion goes through `checkandget` (the case-3 else
    -- branch), runtime-checking each value is an integer and unboxing it. This is
    -- the only scalar mismatch the checker permits (int<->float pairs are
    -- rejected upstream); the source being a real TValue is what makes the
    -- `checkandget` source valid.
    it("case 3 type-mismatch: ...: value forwarded to ...: integer (each element unboxed)", function()
        run_coder([[
            function sink(...: integer): integer
                local s = 0
                local i = 1
                local n = #...
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
            function f(...: value): integer
                return sink(...)
            end
        ]], [[
            assert(test.f() == 0)
            assert(test.f(1, 2, 3) == 6)
            assert(test.f(10, 20) == 30)
            -- a non-integer value forwarded raises a clean runtime type error
            local ok = pcall(function() return test.f(1, "x") end)
            assert(not ok)
        ]])
    end)

    -- CASE 3 (fresh copy), PREFIX-GROW: the callee has FEWER fixed params than the
    -- caller supplies static args, so the surplus static args spill into the tail
    -- (prepended to the forwarded `...` elements). Element type matches but the
    -- tail grows, forcing a fresh copy. Force a GC in the callee.
    it("case 3 prefix-grow: static args spill into the forwarded tail", function()
        run_coder([[
            function sink(a: integer, ...: integer): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                local n = #...
                local s = a
                local i = 1
                while i <= n do
                    s = s + ...[i]
                    i = i + 1
                end
                return s
            end
            function f(...: integer): integer
                -- sink has ONE fixed param; we supply three static args (a, then
                -- 100, 200 spill into the tail) followed by the forwarded `...`.
                return sink(1, 100, 200, ...)
            end
        ]], [[
            collectgarbage("incremental")
            -- a=1, tail prefix {100,200}, then forwarded {}
            assert(test.f() == 301)
            -- a=1, tail prefix {100,200}, then forwarded {3,4}
            assert(test.f(3, 4) == 1 + 100 + 200 + 3 + 4)
        ]])
    end)

    it("case 3 prefix-grow returns multiple GC and scalar values", function()
        run_coder([[
            function sink(...: string): (string, integer, string)
                local junk: {integer} = {}
                local k = 1
                while k <= 400 do
                    junk = { k, k + 1, k + 2 }
                    k = k + 1
                end
                return ...[1], #..., ...[2]
            end
            function forward(...: string): (string, integer, string)
                return sink("prefix", ...)
            end
        ]], [[
            collectgarbage("incremental")
            local a, n, b = test.forward("tail")
            assert(a == "prefix")
            assert(n == 2)
            assert(b == "tail")
        ]])
    end)

    -- CASE 3 with a COLLECTABLE element type (string), prefix-grow: the spilled
    -- static prefix string AND the forwarded tail strings must all survive the
    -- Udata0 allocation and a forced GC in the callee.
    it("case 3 prefix-grow with collectable (string) elements survives GC", function()
        run_coder([[
            function sink(...: string): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k }
                    k = k + 1
                end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    s = s + #(...[i])
                    i = i + 1
                end
                return s
            end
            function f(p: string, ...: string): integer
                -- p is a fixed param of f; it spills as a leading tail element
                -- into sink (sink has zero fixed params), ahead of the forwarded
                -- `...`. A fresh string built here must be anchored before alloc.
                return sink(p .. "X", ...)
            end
        ]], [[
            collectgarbage("incremental")
            local a = ("a"):rep(4) .. "!"   -- length 5
            local b = ("b"):rep(6) .. "!"   -- length 7
            -- f(a, b): prefix {a.."X"} (len 6), forwarded {b} (len 7) -> 13
            assert(test.f(a, b) == 6 + 7)
            -- f(a): prefix {a.."X"} (len 6), forwarded {} -> 6
            assert(test.f(a) == 6)
        ]])
    end)

    -- RECURSION: a variadic function forwards `...` to ITSELF (case 2 start-adjust
    -- on each step), with a base case. Each recursive call supplies ZERO static
    -- args to a one-fixed-param callee, so the first vararg element is BORROWED as
    -- the fixed param and the tail shrinks by one -- genuine start-adjust that
    -- terminates (unlike a pass-through, which would never shrink the tail).
    it("recursion: a variadic function forwards ... to itself", function()
        run_coder([[
            function summer(acc: integer, head: integer, ...: integer): integer
                -- fold `head` into `acc`. If the tail is empty we are done;
                -- otherwise recurse supplying ONE static arg (the new acc) to a
                -- TWO-fixed-param callee, so the next `head` is BORROWED from
                -- ...[1] (start-adjust, k=1 < m=2) and the tail shrinks by one.
                local n = #...
                if n == 0 then
                    return acc + head
                end
                return summer(acc + head, ...)
            end
        ]], [[
            assert(test.summer(0, 0) == 0)
            assert(test.summer(0, 1, 2, 3, 4, 5) == 15)
            assert(test.summer(100, 10, 20) == 130)
        ]])
    end)

    -- OVERFLOW: a forwarding chain that GROWS the tail each step (case 3
    -- prefix-grow) eventually exceeds TITAN_VARARG_MAX (200) and must raise a clean
    -- Titan error rather than corrupt memory (lu_byte n_args would otherwise wrap).
    it("overflow: a forwarding chain past TITAN_VARARG_MAX raises cleanly", function()
        run_coder([[
            function grow(depth: integer, ...: integer): integer
                if depth <= 0 then
                    return #...
                end
                -- each step prepends two static args ahead of the forwarded tail,
                -- growing the merged count -- case 3 prefix-grow with a cap check.
                return grow(depth - 1, 1, 1, ...)
            end
        ]], [[
            -- 150 steps * 2 prepended each = 300 > 200; the cap check must fire.
            test.grow(150)
        ]], "too many variadic arguments")
    end)

    -- Sanity: the same overflow chain stays BELOW the cap and returns the count,
    -- confirming the cap is the only thing that raises (not the chain itself).
    it("forwarding chain below the cap merges correctly", function()
        run_coder([[
            function grow(depth: integer, ...: integer): integer
                if depth <= 0 then
                    return #...
                end
                return grow(depth - 1, 1, 1, ...)
            end
        ]], [[
            -- Stress under stepped GC: deep case-3 recursion allocates a fresh
            -- Udata0 per frame, which can relocate the Lua stack; the forward
            -- recomputes `_base` after each call, so the merged count stays correct.
            collectgarbage("incremental")
            for trial = 1, 100 do
                collectgarbage("step")
                local r = test.grow(50)   -- 50 steps * 2 = 100, under the 200 cap
                assert(r == 100, "trial "..trial.." grow(50)="..tostring(r))
            end
        ]])
    end)

    -- CAP BOUNDARY: a forwarding chain that grows the merged count by EXACTLY one
    -- per step. At 200 merged elements the cap is satisfied (TITAN_VARARG_MAX is
    -- 200) and `#...` reports 200; the very next element (201) trips the clean
    -- "too many variadic arguments" Titan error. Pins both sides of the boundary.
    it("a forwarding chain of exactly 200 elements passes (the cap boundary)", function()
        run_coder([[
            function grow(depth: integer, ...: integer): integer
                if depth <= 0 then
                    return #...
                end
                return grow(depth - 1, 1, ...)   -- +1 element per step
            end
        ]], [[
            -- 200 steps each add one element -> 200 merged, exactly at the cap.
            assert(test.grow(200) == 200)
        ]])
    end)

    it("a forwarding chain of exactly 201 elements raises the cap error", function()
        run_coder([[
            function grow(depth: integer, ...: integer): integer
                if depth <= 0 then
                    return #...
                end
                return grow(depth - 1, 1, ...)
            end
        ]], [[
            test.grow(201)   -- one past the cap
        ]], "too many variadic arguments")
    end)
end)

describe("building {...} / {e1, ..., ...} array from a vararg", function()
    after_each(clean)

    -- {...} with a scalar element type: the build is runtime-sized
    -- (#prefix + n_args - _start), resized once and filled from the struct.
    it("scalar {...}: length and element values, returned to Lua", function()
        run_coder([[
            function collect(...: integer): {integer}
                return {...}
            end
        ]], [[
            local t = test.collect(10, 20, 30)
            assert(#t == 3)
            assert(t[1] == 10 and t[2] == 20 and t[3] == 30)
            -- empty vararg -> {} (just an empty array)
            local e = test.collect()
            assert(#e == 0)
        ]])
    end)

    -- {...} into a MISMATCHED array element type (the context overrode the
    -- element type away from the vararg element). Each element must be CONVERTED
    -- from the real vararg element type to the array element type before storing,
    -- driving the backing-struct read off the real element type. A raw cast of
    -- the buffer to the array-element struct would bit-reinterpret each slot.
    it("{...: integer} into a {float} context converts each element to float", function()
        run_coder([[
            function f(...: integer): {float}
                return {...}
            end
        ]], [[
            local t = test.f(3, 4)
            assert(math.type(t[1]) == 'float' and math.type(t[2]) == 'float')
            assert(t[1] == 3.0 and t[2] == 4.0)
            assert(#test.f() == 0)
        ]])
    end)

    it("{...: integer} into a {value} context boxes each element", function()
        run_coder([[
            function f(...: integer): {value}
                return {...}
            end
        ]], [[
            local t = test.f(7, 8)
            assert(math.type(t[1]) == 'integer' and math.type(t[2]) == 'integer')
            assert(t[1] == 7 and t[2] == 8)
        ]])
    end)

    -- {e1, ..., ...} into a mismatched context: the static prefix already coerces
    -- (3 -> 3.0); the spread tail must convert too.
    it("{1, ..., ...: integer} into a {float} context converts prefix and tail", function()
        run_coder([[
            function f(...: integer): {float}
                return {1, ...}
            end
        ]], [[
            local t = test.f(2, 3)
            assert(math.type(t[1]) == 'float')
            assert(t[1] == 1.0 and t[2] == 2.0 and t[3] == 3.0)
        ]])
    end)

    -- {e1, e2, ...}: a static prefix precedes the spread; the prefix occupies
    -- array indices [1..nprefix] and the vararg tail follows.
    it("scalar {e1, e2, ...}: static prefix then the vararg tail", function()
        run_coder([[
            function withprefix(...: integer): {integer}
                return {100, 200, ...}
            end
        ]], [[
            local t = test.withprefix(1, 2, 3)
            assert(#t == 5)
            assert(t[1] == 100 and t[2] == 200)
            assert(t[3] == 1 and t[4] == 2 and t[5] == 3)
            -- N == 0: just the static prefix
            local p = test.withprefix()
            assert(#p == 2)
            assert(p[1] == 100 and p[2] == 200)
        ]])
    end)

    -- {...} consumed entirely inside Titan (length read back via #), so the
    -- result never crosses the Lua boundary as a table -- exercises the build in
    -- a purely native context.
    it("scalar {...} consumed inside the function (# of the result)", function()
        run_coder([[
            function howmany(...: integer): integer
                local t: {integer} = {0, 0, ...}
                return #t
            end
        ]], [[
            assert(test.howmany() == 2)
            assert(test.howmany(1, 2, 3, 4) == 6)
        ]])
    end)

    -- COLLECTABLE element type ({string}) with a FORCED GC after the array is
    -- built but before it is read back. The store path is obj2arr +
    -- luaC_barrierback per element; the resize can relocate the stack (rebased).
    -- Fresh non-interned strings make a dropped barrier/element deterministic
    -- corruption. This is the back-barrier "teeth": removing the barrier (or the
    -- resize-GC rebase) corrupts the result.
    -- The {...: string} build path proper, with the strings minted INSIDE Titan and
    -- passed straight into the variadic callee's {prefix, ...} build, then a heavy
    -- GC churn after the build before reading them back. Nothing on the Lua side
    -- anchors the strings, so the table's array part is their sole root; a missing
    -- obj2arr per-element back barrier (or a botched resize-GC rebase) leaves the
    -- marked table pointing at unmarked/swept strings and the length sums wrong.
    -- This is the barrier teeth: an external Lua anchor would hide a missing one.
    it("{...: string} elements survive a forced GC (back barrier + rebase)", function()
        run_coder([[
            function rep(ch: string, n: integer): string
                local s: string = ""           -- fresh, non-interned heap string
                local i = 1
                while i <= n do
                    s = s .. ch
                    i = i + 1
                end
                return s
            end
            function totallen(...: string): integer
                local prefix: string = rep("p", 4)   -- length 4
                local t: {string} = {prefix, ...}
                local junk: {integer} = {}           -- churn AFTER the build
                local k = 1
                while k <= 400 do
                    junk = { k, k + 1, k + 2 }
                    k = k + 1
                end
                local s = 0
                local i = 1
                while i <= #t do
                    s = s + #(t[i])
                    i = i + 1
                end
                return s
            end
            function go(): integer
                -- strings minted here, no Lua-side anchor
                return totallen(rep("a", 5), rep("b", 7), rep("c", 3))
            end
            function empty(): integer
                return totallen()                    -- {prefix} only, N == 0
            end
        ]], [[
            collectgarbage("incremental")
            assert(test.go() == 4 + 5 + 7 + 3)
            assert(test.empty() == 4)
        ]], nil)
    end)

    -- {...: string} returned to Lua and read back after forced collections.
    it("{...: string} returned to Lua survives a forced GC", function()
        run_coder([[
            function gather(...: string): {string}
                local prefix: string = "p" .. "fx"
                return {prefix, ...}
            end
        ]], [[
            collectgarbage("incremental")
            local a = ("x"):rep(5) .. "1"
            local b = ("y"):rep(7) .. "2"
            local c = ("z"):rep(3) .. "3"
            local t = test.gather(a, b, c)
            for _ = 1, 50 do collectgarbage("step") end
            collectgarbage("collect")
            assert(#t == 4)
            assert(t[1] == "pfx")
            assert(t[2] == a and t[3] == b and t[4] == c)
            assert(#t[2] == 6 and #t[3] == 8 and #t[4] == 4)
            local e = test.gather()
            assert(#e == 1 and e[1] == "pfx")
        ]], nil)
    end)

    -- Same back-barrier teeth with a RECORD element type ({R}, Udata*): build the
    -- array, churn the heap to force a collection, then read each record field.
    it("{...: R} (record) elements survive a forced GC", function()
        run_coder([[
            record R
                v: integer
            end
            function mk(v: integer): R
                return { v = v }
            end
            function pack(...: R): {R}
                return {...}
            end
            function sumfields(...: R): integer
                local t: {R} = {...}
                -- churn AFTER the array is built so a collection runs while the
                -- records are reachable only through the table's array part.
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k, k + 1 }
                    k = k + 1
                end
                local s = 0
                local i = 1
                while i <= #t do
                    s = s + t[i].v
                    i = i + 1
                end
                return s
            end
        ]], [[
            collectgarbage("incremental")
            local a, b, c = test.mk(3), test.mk(5), test.mk(7)
            -- {...: R} returned to Lua, then a forced GC, then field reads
            local t = test.pack(a, b, c)
            for _ = 1, 50 do collectgarbage("step") end
            assert(#t == 3)
            assert(t[1].v == 3 and t[2].v == 5 and t[3].v == 7)
            -- and consumed entirely inside Titan with an internal GC churn
            assert(test.sumfields(a, b, c) == 15)
            assert(test.sumfields() == 0)
        ]])
    end)

    -- An array constructor whose field is a `...[i]` index (ExpDotsIndex), not a
    -- bare `...` spread. The constructor `field` rule must let `...[i]` fall
    -- through to the general `exp` alternative (the `!LBRACKET` guard on the
    -- dots_field alternative) so `{...[1]}` parses, then evaluate the index as an
    -- ordinary single-value element.
    it("{...[i]} index field: a 1-element array of the indexed vararg element", function()
        run_coder([[
            function first(...: integer): {integer}
                return {...[1]}
            end
            function withprefix(...: integer): {integer}
                return {99, ...[2]}
            end
        ]], [[
            local t = test.first(10, 20, 30)
            assert(#t == 1 and t[1] == 10)
            local u = test.withprefix(10, 20, 30)
            assert(#u == 2 and u[1] == 99 and u[2] == 20)
        ]])
    end)
end)

-- The default busted suite runs INCREMENTAL GC, which cannot observe a missing
-- write barrier or dropped traced provenance: a missed mark is reconciled by the
-- next sweep regardless. GENERATIONAL mode is different -- a minor collection
-- sweeps the young generation in one shot, so an unanchored fresh value (or an
-- unbarriered store of a fresh value into an aged container) is reclaimed
-- deterministically. Every test here selects generational mode, churns the
-- young generation, and forces a minor collection (a `step` in generational
-- mode is a minor collection) BEFORE the element read -- so lost provenance
-- becomes near-deterministic corruption rather than a rare race.
describe("variadic GC provenance under generational mode", function()
    after_each(clean)

    -- 1. `...: value` from Lua (genluaentry path): the backing struct holds tagged
    -- TValues whose collectable payload (a long fresh string, fresh tables,
    -- a fresh record) is untraced. The values survive through the actual Lua VM
    -- argument slots used to enter Titan. A forced minor collection runs after heavy
    -- young churn, before `#...`/`...[i]` are read.
    it("...: value from Lua survives a generational minor collection", function()
        run_coder([[
            record P
                x: integer
            end
            function howmany(...: value): integer
                return #...
            end
            function at(i: integer, ...: value): value
                return ...[i]
            end
            function mkP(x: integer): P
                return { x = x }
            end
        ]], [[
            collectgarbage("generational")
            -- fresh, non-interned: a long heap string (built char-by-char so it is
            -- a genuine heap allocation, never an interned constant) + fresh tables
            -- + a fresh record
            local longs = ("z"):rep(5000) .. "_tail"
            local longlen = #longs
            local t1 = { 1, 2, 3 }
            local t2 = { a = "x" }
            local rec = test.mkP(77)
            -- churn the young generation hard, then force a minor collection
            for i = 1, 4000 do local _ = { i, i + 1 } end
            collectgarbage("step")
            assert(test.howmany(longs, t1, t2, rec, 42) == 5)
            assert(test.at(1, longs, t1, t2, rec, 42) == longs)
            -- the returned string must be byte-identical (content survived intact)
            assert(#(test.at(1, longs, t1, t2, rec, 42)) == longlen)
            assert(test.at(2, longs, t1, t2, rec, 42) == t1)
            assert(test.at(4, longs, t1, t2, rec, 42) == rec)
            assert(test.at(5, longs, t1, t2, rec, 42) == 42)
        ]])
    end)

    -- 2. `...: R` (record / Udata*) from Lua under generational GC: the record
    -- fields must survive a minor collection forced before they are read.
    it("...: R (record) from Lua survives a generational minor collection", function()
        run_coder([[
            record R
                v: integer
                s: string
            end
            function mk(v: integer, s: string): R
                return { v = v, s = s }
            end
            function checksum(...: R): integer
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    local r = ...[i]
                    s = s + r.v + #(r.s)
                    i = i + 1
                end
                return s
            end
        ]], [[
            collectgarbage("generational")
            -- fresh records carrying fresh non-interned strings
            local a = test.mk(3, ("a"):rep(4) .. "!")   -- v=3, #s=5
            local b = test.mk(5, ("b"):rep(6) .. "!")   -- v=5, #s=7
            local c = test.mk(7, ("c"):rep(2) .. "!")   -- v=7, #s=3
            for i = 1, 4000 do local _ = { i } end
            collectgarbage("step")
            assert(test.checksum(a, b, c) == (3 + 5) + (5 + 7) + (7 + 3))
        ]])
    end)

    -- 3. CASE 3 forwarding, PREFIX-GROW with a collectable element type, under
    -- generational GC: a forwarder prepends a FRESH string ahead of its whole
    -- forwarded `...: string` (prefix grows the tail -> a fresh Udata0 copy), and a
    -- sink forces a minor collection before concatenating every element. The
    -- fresh prefix keeps its allocation/result root and the forwarded tail keeps
    -- its upstream VM provenance across descriptor construction and collection. Asserts exact
    -- concatenation (not just total length) so a swapped/dropped element shows.
    it("case-3 prefix-grow forwarding of ...: string survives a minor collection", function()
        run_coder([[
            function sink(...: string): string
                -- force a minor collection before reading the elements
                local junk: {integer} = {}
                local k = 1
                while k <= 400 do junk = { k, k + 1 }; k = k + 1 end
                local out: string = ""
                local i = 1
                local n = #...
                while i <= n do out = out .. ...[i]; i = i + 1 end
                return out
            end
            function fwd(p: string, ...: string): string
                -- p .. "|" is a FRESH heap string prepended ahead of the whole
                -- forwarded tail: case-3 prefix-grow into a fresh Udata0 copy.
                return sink(p .. "|", ...)
            end
        ]], [[
            collectgarbage("generational")
            local p = ("p"):rep(3) .. "?"   -- "ppp?"
            local a = ("a"):rep(4) .. "1"   -- "aaaa1"
            local b = ("b"):rep(6) .. "2"   -- "bbbbbb2"
            for i = 1, 3000 do local _ = { i } end
            collectgarbage("step")
            -- fwd prepends (p.."|") then forwards {a, b}
            assert(test.fwd(p, a, b) == (p .. "|") .. a .. b)
            -- empty forwarded tail: just the prefix
            assert(test.fwd(p) == (p .. "|"))
        ]])
    end)

    -- 4. `{...: string}` built into a table that has been AGED into the OLD
    -- generation (two full collects), then young-allocate + step to force minor
    -- collections. A minor collection does NOT rescan old objects, so the table's
    -- per-element `obj2arr` store must have run `luaC_barrierback` to keep the
    -- (then-young) strings reachable from the (now-old) table; a missing barrier
    -- lets the minor collection sweep them. Asserts the elements survive.
    it("{...: string} aged into the old generation survives later minor collections", function()
        run_coder([[
            function gather(...: string): {string}
                return {...}
            end
            function readlen(t: {string}, i: integer): integer
                return #(t[i])
            end
        ]], [[
            collectgarbage("generational")
            local a = ("x"):rep(5) .. "1"   -- 6
            local b = ("y"):rep(7) .. "2"   -- 8
            local c = ("z"):rep(3) .. "3"   -- 4
            local t = test.gather(a, b, c)
            -- promote the table (and its array part) into the old generation
            collectgarbage("collect")
            collectgarbage("collect")
            -- now allocate fresh young garbage and run minor collections; these
            -- must not sweep the old-gen-referenced string elements
            for i = 1, 5000 do local _ = { i } end
            collectgarbage("step")
            collectgarbage("step")
            assert(#t == 3)
            assert(test.readlen(t, 1) == 6)
            assert(test.readlen(t, 2) == 8)
            assert(test.readlen(t, 3) == 4)
            assert(t[1] == a and t[2] == b and t[3] == c)
        ]])
    end)

    -- 5. STATIC `...: value` call (Titan -> Titan) under generational GC: the
    -- caller builds the backing struct on its C stack from fresh strings, then
    -- tail-calls the variadic callee, which forces a minor collection before
    -- reading the boxed values. The static site borrows upstream VM/allocation
    -- provenance and creates no tracing-only input roots.
    it("static ...: value (Titan->Titan) survives a generational minor collection", function()
        run_coder([[
            function totallen(...: value): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 400 do junk = { k }; k = k + 1 end
                local s = 0
                local i = 1
                local n = #...
                while i <= n do
                    s = s + #(...[i] as string)
                    i = i + 1
                end
                return s
            end
            function caller(a: string, b: string): integer
                -- fresh strings flow into the value struct; tail position
                return totallen(a, b, "lit3")
            end
        ]], [[
            collectgarbage("generational")
            local a = ("a"):rep(4) .. "!"   -- 5
            local b = ("b"):rep(6) .. "!"   -- 7
            for i = 1, 3000 do local _ = { i } end
            collectgarbage("step")
            assert(test.caller(a, b) == 5 + 7 + 4)
        ]])
    end)
end)

-- Functional coverage for nested variadic lambdas (scope rule 4 at run time),
-- map-typed elements, variadic methods, a side-effecting `...[i]` index,
-- `...: boolean` through the build/forward/static paths, and the
-- `{...: value}`-with-a-nil border semantics.
describe("variadic parameters: functional coverage gaps (code generator)", function()
    after_each(clean)

    -- A variadic lambda stored in a local and called: the value-call path on an
    -- anonymous variadic function, exercised purely inside Titan.
    it("variadic lambda stored in a local and called", function()
        run_coder([[
            function go(): integer
                local f = function(...: integer): integer
                    local s = 0
                    local i = 1
                    local n = #...
                    while i <= n do s = s + ...[i]; i = i + 1 end
                    return s
                end
                return f(1, 2, 3, 4)
            end
        ]], [[
            assert(test.go() == 10)
        ]])
    end)

    -- SCOPE RULE 4 at run time: a variadic lambda nested inside a variadic
    -- top-level function. The inner lambda's `...` is its OWN `...` (depth-stamped
    -- `$vararg`), so `inner(99)` reads 99 -- NOT the outer call's first arg. The
    -- outer `...` is read by a sibling helper. With outer(7, 8) and inner(99):
    -- helper sees 7 (-> 7000) and the inner lambda sees 99, summing to 7099.
    it("nested variadic lambda reads the inner ... (scope rule 4)", function()
        run_coder([[
            function outer_helper(...: integer): integer
                return ...[1] * 1000
            end
            function outer(...: integer): integer
                local inner = function(...: integer): integer
                    return ...[1]            -- the INNER call's first arg
                end
                return outer_helper(...) + inner(99)
            end
        ]], [[
            -- outer(7, 8): helper(7,8) -> 7000 ; inner(99) -> 99 ; 7099
            assert(test.outer(7, 8) == 7099)
            assert(test.outer(3, 100) == 3099)
        ]])
    end)

    -- MAP-typed vararg element (`...: {string:integer}`): the element is a
    -- collectable Table*. Exercise `#...`, `...[i]`, the `{...}` build, and
    -- forwarding, with a forced GC since each element is GC-able.
    it("map-typed vararg element ...: {string:integer}", function()
        run_coder([[
            function lookup(key: string, ...: {string:integer}): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do junk = { k }; k = k + 1 end
                local n = #...
                local s = 0
                local i = 1
                while i <= n do
                    local m = ...[i]
                    s = s + m[key]
                    i = i + 1
                end
                return s
            end
            function howmany(...: {string:integer}): integer
                local t = {...}
                return #t
            end
            function fwd(key: string, ...: {string:integer}): integer
                return lookup(key, ...)        -- forward the whole tail
            end
        ]], [[
            collectgarbage("incremental")
            local a = { a = 1, b = 2 }
            local b = { a = 10, b = 20 }
            assert(test.lookup("a", a, b) == 11)
            assert(test.lookup("b", a, b) == 22)
            assert(test.howmany(a, b, {}) == 3)
            assert(test.howmany() == 0)
            assert(test.fwd("a", a, b) == 11)
        ]])
    end)

    -- A variadic METHOD reading collectable elements, exercised from Lua, via a
    -- STATIC Titan call site (`obj:m(...)`), and forwarding `...` to itself
    -- (start-adjust). Generational where the element type is collectable.
    it("variadic method ...: string from Lua, static, and self-forwarding", function()
        run_coder([[
            record Acc
                base: integer
            end
            function Acc:total(...: string): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do junk = { k, k + 1 }; k = k + 1 end
                local s = self.base
                local i = 1
                local n = #...
                while i <= n do s = s + #(...[i]); i = i + 1 end
                return s
            end
            function Acc:add(skip: string, ...: string): integer
                -- forward ... to itself; `skip` is dropped (start-adjust)
                return self:total(...)
            end
            function viastatic(a: Acc, x: string, y: string): integer
                return a:total(x, y)            -- static Titan call site obj:m(...)
            end
        ]], [[
            collectgarbage("generational")
            local a = test.Acc.new(100)
            local s1 = ("p"):rep(5) .. "!"   -- 6
            local s2 = ("q"):rep(7) .. "!"   -- 8
            for i = 1, 2000 do local _ = { i } end
            collectgarbage("step")
            assert(a:total(s1, s2) == 100 + 6 + 8)        -- from Lua
            assert(test.viastatic(a, s1, s2) == 100 + 6 + 8) -- static call site
            assert(a:add(("z"):rep(3), s1, s2) == 100 + 6 + 8) -- self-forward
            assert(a:total() == 100)
        ]])
    end)

    -- A variadic method over a RECORD element type (Udata*) from Lua, under
    -- generational GC.
    it("variadic method ...: R (record) from Lua under generational GC", function()
        run_coder([[
            record R
                v: integer
            end
            record Acc
                base: integer
            end
            function Acc:sumv(...: R): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do junk = { k }; k = k + 1 end
                local s = self.base
                local i = 1
                local n = #...
                while i <= n do s = s + (...[i]).v; i = i + 1 end
                return s
            end
            function mk(v: integer): R
                return { v = v }
            end
        ]], [[
            collectgarbage("generational")
            local a = test.Acc.new(10)
            local r1, r2, r3 = test.mk(3), test.mk(5), test.mk(7)
            for i = 1, 2000 do local _ = { i } end
            collectgarbage("step")
            assert(a:sumv(r1, r2, r3) == 25)
            assert(a:sumv() == 10)
        ]])
    end)

    -- A side-effecting `...[i]` index expression: the index `counter()` bumps a
    -- module counter. The index must be evaluated EXACTLY ONCE (operands are not
    -- auto-hoisted, so a template splicing the index more than once would call
    -- `counter()` repeatedly -- see the generated-template multiply-evaluation gotcha).
    it("a side-effecting ...[counter()] index is evaluated exactly once", function()
        run_coder([[
            calls: integer = 0
            function counter(): integer
                calls = calls + 1
                return 2
            end
            function pick(...: integer): integer
                return ...[counter()]
            end
        ]], [[
            test.calls = 0
            assert(test.pick(10, 20, 30) == 20)
            assert(test.calls == 1)
            -- a second call bumps it exactly once more
            assert(test.pick(40, 50, 60) == 50)
            assert(test.calls == 2)
        ]])
    end)

    -- `...: boolean` (a scalar, no-payload element: booleans carry no GC payload)
    -- through the `{...}` build, pass-through forwarding, start-adjust
    -- forwarding, and a fully-static call site.
    it("...: boolean through {...}, forwarding, and a static call", function()
        run_coder([[
            function count_true(...: boolean): integer
                local t: {boolean} = {...}
                local c = 0
                local i = 1
                while i <= #t do
                    if t[i] then c = c + 1 end
                    i = i + 1
                end
                return c
            end
            function fwd(...: boolean): integer
                return count_true(...)              -- pass-through
            end
            function fwd_adjust(first: boolean, ...: boolean): integer
                return count_true(first, ...)       -- start-adjust borrow
            end
            function static_call(): integer
                return count_true(true, false, true, true)
            end
        ]], [[
            assert(test.count_true(true, false, true) == 2)
            assert(test.count_true() == 0)
            assert(test.fwd(true, true, false, true) == 3)
            assert(test.fwd_adjust(true, false, true) == 2)
            assert(test.static_call() == 3)
        ]])
    end)

    -- GENERIC (tag-mismatch) value-call path carrying a FORWARDED `...` with
    -- collectable (string) elements, under generational GC. A `(...: value)`-typed
    -- value actually holds a `(...: string)` function, so its runtime tag does not
    -- match the call site and the call routes through the generic path, which
    -- rebuilds the struct through genluaentry. The forwarded fresh strings must
    -- survive a minor collection in the deepest callee.
    it("generic value-call carrying a forwarded ...: string survives a minor collection", function()
        run_coder([[
            function totallen(...: string): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 400 do junk = { k }; k = k + 1 end
                local s = 0
                local i = 1
                local n = #...
                while i <= n do s = s + #(...[i]); i = i + 1 end
                return s
            end
            function call_generic(f: (...: value) -> integer, ...: string): integer
                -- f holds a ...: string function viewed as ...: value -> tag mismatch
                -- -> the generic path; we forward our own ...: string into it.
                return f(...)
            end
            function run(a: string, b: string): integer
                local v: (...: value) -> integer = totallen
                return call_generic(v, a, b)
            end
        ]], [[
            collectgarbage("generational")
            local a = ("a"):rep(4) .. "!"   -- 5
            local b = ("b"):rep(6) .. "!"   -- 7
            for i = 1, 3000 do local _ = { i } end
            collectgarbage("step")
            assert(test.run(a, b) == 5 + 7)
        ]])
    end)

    -- DESIGN-DECISION PIN: `{...: value}` with a GENUINE nil element. `#...`
    -- counts all passed slots, `...[2]` reads nil, and the resulting dense Array
    -- length is the highest present positive index rather than a Lua table border.
    it("{...: value} with a genuine nil preserves dense Array length", function()
        run_coder([[
            function dotslen(...: value): integer
                return #...
            end
            function at(i: integer, ...: value): value
                return ...[i]
            end
            function tablelen(...: value): integer
                local t = {...}
                return #t
            end
        ]], [[
            -- #... counts every slot, including the nil hole
            assert(test.dotslen(1, nil, 3) == 3)
            -- ...[2] reads the genuine nil
            assert(test.at(2, 1, nil, 3) == nil)
            assert(test.at(1, 1, nil, 3) == 1)
            assert(test.at(3, 1, nil, 3) == 3)
            -- #{...} reports the highest present positive slot despite the hole.
            assert(test.tablelen(1, nil, 3) == 3)
            -- A trailing nil is absent, so the highest present slot remains 2.
            assert(test.tablelen(1, 2, nil) == 2)
        ]])
    end)
end)

-- Context inference of an UNTYPED lambda vararg `...` (no `: type`): the element
-- type is taken from the expected `(...: T) -> R` function type, exactly like an
-- untyped lambda parameter. End-to-end: compile and value-call through it.
describe("untyped lambda vararg inference (code generator)", function()
    after_each(clean)

    -- An untyped `...` lambda assigned to a `(...: integer) -> integer` local
    -- infers the element type as integer, then a value call works at run time.
    it("infers ...:integer from a typed local and value-calls it", function()
        run_coder([[
            function go(): integer
                local f: (...: integer) -> integer = function(...)
                    local s = 0
                    local i = 1
                    local n = #...
                    while i <= n do s = s + ...[i]; i = i + 1 end
                    return s
                end
                return f(1, 2, 3, 4)
            end
        ]], [[
            assert(test.go() == 10)
        ]])
    end)

    -- The untyped `...` lambda is passed as an argument whose param type is the
    -- variadic function type; inference flows from the callee's parameter type.
    it("infers the vararg element from a parameter context (passed as arg)", function()
        run_coder([[
            function apply(f: (...: integer) -> integer): integer
                return f(10, 20, 30)
            end
            function go(): integer
                return apply(function(...)
                    return #... * (...[1] + ...[2] + ...[3])
                end)
            end
        ]], [[
            assert(test.go() == 180)  -- 3 * (10+20+30)
        ]])
    end)

    -- The untyped `...` lambda is RETURNED at a variadic function-type return,
    -- then value-called by the caller.
    it("infers the vararg element from a return-type context", function()
        run_coder([[
            function make(): (...: integer) -> integer
                return function(...)
                    local s = 0
                    local i = 1
                    while i <= #... do s = s + ...[i]; i = i + 1 end
                    return s
                end
            end
            function go(): integer
                local f = make()
                return f(5, 6, 7)
            end
        ]], [[
            assert(test.go() == 18)
        ]])
    end)
end)

-- End-to-end tests for anonymous functions with lexical closure: generate C,
-- compile it, and run it. Covers boxed (captured-and-mutated) capture, by-value
-- capture, both call paths through a closure value, gc-typed captures (the box
-- barrier), transitive multi-level capture, GC stress over live closures/boxes,
-- end-to-end type inference of lambda params/return, and zero-return lambdas.
--
-- The frontend (parser/checker/inference) assertions live in spec/parser_spec.lua
-- and spec/checker/closures_spec.lua; this file is the runtime oracle.
local h = require 'spec.support.helpers'

local run_coder = h.run_coder

describe("closures (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("a counter closure increments a captured boxed integer", function()
        run_coder([[
            function make_counter(): () -> integer
                local n = 0
                return function (): integer
                    n = n + 1
                    return n
                end
            end
        ]], [[
            local c = test.make_counter()
            assert(c() == 1)
            assert(c() == 2)
            assert(c() == 3)
        ]])
    end)

    it("two counters are independent", function()
        run_coder([[
            function make_counter(): () -> integer
                local n = 0
                return function (): integer
                    n = n + 1
                    return n
                end
            end
        ]], [[
            local a = test.make_counter()
            local b = test.make_counter()
            assert(a() == 1)
            assert(a() == 2)
            assert(b() == 1)
            assert(a() == 3)
            assert(b() == 2)
        ]])
    end)

    it("a captured boxed integer starting from an argument", function()
        run_coder([[
            function adder(start: integer): (integer) -> integer
                local acc = start
                return function (x: integer): integer
                    acc = acc + x
                    return acc
                end
            end
        ]], [[
            local f = test.adder(100)
            assert(f(1) == 101)
            assert(f(2) == 103)
            assert(f(10) == 113)
        ]])
    end)

    it("captures a mutated parameter (boxed param)", function()
        run_coder([[
            function bump(n: integer): () -> integer
                return function (): integer
                    n = n + 5
                    return n
                end
            end
        ]], [[
            local f = test.bump(10)
            assert(f() == 15)
            assert(f() == 20)
        ]])
    end)

    it("owning function body and inner closure share the boxed param", function()
        -- The owning function itself reads AND writes the captured+mutated param;
        -- those uses must go through the box (not the raw _param_ C arg), so they
        -- stay consistent with the inner closure's view. Distinguishing values:
        -- if the body used _param_n while the closure used the box they'd diverge.
        run_coder([[
            function make(n: integer): (integer) -> integer
                n = n + 1            -- owning body mutates the boxed param
                local first = n      -- owning body reads the boxed param
                return function (x: integer): integer
                    n = n + x        -- inner mutates the shared box
                    return n + first
                end
            end
        ]], [[
            local f = test.make(10)      -- n -> 11, first = 11
            assert(f(5) == 27)           -- n -> 16, 16 + 11
            assert(f(5) == 32)           -- n -> 21, 21 + 11
            local g = test.make(100)     -- independent box: n -> 101, first = 101
            assert(g(1) == 203)          -- n -> 102, 102 + 101
            assert(f(0) == 32)           -- f unaffected by g
        ]])
    end)

    it("captures a mutated gc-typed (string) parameter", function()
        -- a captured+mutated string param is boxed too; writes through the box
        -- need the forward barrier (gc value into the CClosure-cell box).
        run_coder([[
            function collect(s: string): (string) -> string
                return function (x: string): string
                    s = s .. x
                    return s
                end
            end
        ]], [[
            local f = test.collect("a")
            assert(f("b") == "ab")
            assert(f("c") == "abc")
            local g = test.collect("X")
            assert(g("y") == "Xy")
            assert(f("d") == "abcd")
        ]])
    end)

    it("captures an immutable local by value", function()
        run_coder([[
            function make_adder(k: integer): (integer) -> integer
                local base = k * 10
                return function (x: integer): integer
                    return base + x
                end
            end
        ]], [[
            local add30 = test.make_adder(3)
            assert(add30(5) == 35)
            assert(add30(7) == 37)
        ]])
    end)

    it("loop-created closures each capture the per-iteration value", function()
        run_coder([[
            function make_closures(): {(integer) -> integer}
                local fns: {(integer) -> integer} = {}
                local i = 1
                while i <= 3 do
                    local captured = i
                    fns[i] = function (x: integer): integer
                        return captured * 100 + x
                    end
                    i = i + 1
                end
                return fns
            end
        ]], [[
            local fns = test.make_closures()
            assert(fns[1](7) == 107)
            assert(fns[2](7) == 207)
            assert(fns[3](7) == 307)
        ]])
    end)

    it("calls a closure on both the fast and the slow path", function()
        -- `outer(g, p)` calls the function VALUE `g`. When `g` is a Titan closure
        -- of the exact static type `(()->integer)->integer`, the call takes the
        -- fast path (no extra Lua frame); when `g` is a plain Lua closure it falls
        -- to the generic path through luaD_callnoyield (one extra frame). The
        -- DEPTH_PROBE assertion catches a regression that quietly downgraded the
        -- fast path to the slow one (a value-correct call on either path).
        run_coder([[
            function make_g(): (() -> integer) -> integer
                local calls = 0
                return function (p: () -> integer): integer
                    calls = calls + 1   -- genuine (boxed) capture: g is a closure
                    return p()           -- returned value is purely the probe
                end
            end
            function outer(g: (() -> integer) -> integer,
                           p: () -> integer): integer
                return g(p)
            end
            -- fast path: the captured-closure `g` is called at its exact type
            function run_fast(p: () -> integer): integer
                return outer(make_g(), p)
            end
            -- slow path: `g` arrives as a value (here a Lua closure from the
            -- driver) whose tag is unknown statically -> generic call path
            function run_slow(g: (() -> integer) -> integer,
                              p: () -> integer): integer
                return outer(g, p)
            end
        ]], h.DEPTH_PROBE .. [[
            assert(test.run_fast(function () return 5 end) == 5)
            local fastd = test.run_fast(depth)
            local slowd = test.run_slow(slow_g, depth)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
    end)

    it("captures a gc local (string) by value", function()
        run_coder([[
            function make_tagger(prefix: string): (string) -> string
                local tag = prefix .. ':'
                return function (s: string): string
                    return tag .. s
                end
            end
        ]], [[
            local t = test.make_tagger('log')
            assert(t('hi') == 'log:hi')
            assert(t('bye') == 'log:bye')
        ]])
    end)

    it("captures a string (gc-typed by-value capture)", function()
        run_coder([[
            function greeter(name: string): () -> string
                return function (): string
                    return name
                end
            end
        ]], [[
            local g = test.greeter('world')
            assert(g() == 'world')
            assert(g() == 'world')
        ]])
    end)

    it("captures and mutates a string (gc-typed boxed capture)", function()
        run_coder([[
            function accum(): (string) -> string
                local s = ""
                return function (piece: string): string
                    s = s .. piece
                    return s
                end
            end
        ]], [[
            local f = test.accum()
            assert(f('a') == 'a')
            assert(f('b') == 'ab')
            assert(f('c') == 'abc')
        ]])
    end)

    it("captures and mutates an array (gc-typed boxed capture)", function()
        run_coder([[
            function pusher(): (integer) -> integer
                local xs: {integer} = {}
                return function (v: integer): integer
                    xs[#xs + 1] = v
                    return #xs
                end
            end
        ]], [[
            local f = test.pusher()
            assert(f(10) == 1)
            assert(f(20) == 2)
            assert(f(30) == 3)
        ]])
    end)

    it("transitive 3-level capture of a boxed and a by-value variable", function()
        run_coder([[
            function outer(seed: integer): () -> integer
                local total = 0
                local label = seed * 1000
                return function (): integer
                    -- middle level: itself a closure capturing total + label
                    local inner: () -> integer = function (): integer
                        -- deepest level: mutates total (boxed, shared two levels
                        -- up) and reads label (by-value, two levels up)
                        total = total + 1
                        return label + total
                    end
                    return inner()
                end
            end
        ]], [[
            local f = test.outer(7)
            assert(f() == 7001)
            assert(f() == 7002)
            assert(f() == 7003)
        ]])
    end)

    it("survives a hard GC between closure creation and call", function()
        run_coder([[
            function make_counter(): () -> integer
                local n = 0
                return function (): integer
                    n = n + 1
                    return n
                end
            end
        ]], [[
            collectgarbage('generational')
            local cs = {}
            for i = 1, 50 do cs[i] = test.make_counter() end
            collectgarbage()
            collectgarbage()
            for i = 1, 50 do
                assert(cs[i]() == 1)
                assert(cs[i]() == 2)
            end
            collectgarbage('collect')
            collectgarbage('incremental')
            for i = 1, 50 do
                assert(cs[i]() == 3)
            end
        ]])
    end)

    it("GC stress over closures capturing strings", function()
        run_coder([[
            function accum(): (string) -> string
                local s = "start:"
                return function (piece: string): string
                    s = s .. piece
                    return s
                end
            end
        ]], [[
            local fs = {}
            for i = 1, 30 do fs[i] = test.accum() end
            collectgarbage()
            for i = 1, 30 do
                assert(fs[i]('x') == 'start:x')
            end
            collectgarbage('collect')
            for i = 1, 30 do
                assert(fs[i]('y') == 'start:xy')
            end
        ]])
    end)

    it("GC stress over closures with boxed array captures", function()
        run_coder([[
            function pusher(): (integer) -> integer
                local xs: {integer} = {}
                return function (v: integer): integer
                    xs[#xs + 1] = v * v
                    return xs[#xs]
                end
            end
        ]], [[
            local fs = {}
            for i = 1, 40 do fs[i] = test.pusher() end
            collectgarbage('collect')
            for i = 1, 40 do
                assert(fs[i](3) == 9)
                assert(fs[i](4) == 16)
            end
            collectgarbage('collect')
            for i = 1, 40 do
                assert(fs[i](5) == 25)
            end
        ]])
    end)

    it("infers lambda param and return from a higher-order argument", function()
        run_coder([[
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
            function run(): integer
                -- f's param type and the lambda's return type are inferred from
                -- apply's parameter type
                return apply(function (x) return x * 3 end, 14)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("infers a closure's types and captures at the same time", function()
        run_coder([[
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
            function run(bias: integer): integer
                return apply(function (x) return x + bias end, 10)
            end
        ]], [[
            assert(test.run(5) == 15)
            assert(test.run(100) == 110)
        ]])
    end)

    it("invokes a zero-return lambda for effect", function()
        run_coder([[
            function run(): integer
                local total = 0
                local add: (integer) -> () = function (x: integer)
                    total = total + x
                end
                add(3)
                add(4)
                add(10)
                return total
            end
        ]], [[
            assert(test.run() == 17)
        ]])
    end)

    it("returns a lambda that escapes two frames and is called later", function()
        run_coder([[
            function outer(): () -> (() -> integer)
                local n = 41
                return function (): () -> integer
                    return function (): integer
                        n = n + 1
                        return n
                    end
                end
            end
        ]], [[
            local mid = test.outer()
            local f = mid()
            assert(f() == 42)
            assert(f() == 43)
        ]])
    end)

    it("captures a record local by value and mutates its field", function()
        -- A record is a Udata-backed gc value; a by-value capture copies the
        -- (reference) pointer, so the lambda still sees field mutations.
        run_coder([[
            record Box v: integer end
            function make(): (integer) -> integer
                local b: Box = { v = 0 }
                return function (x: integer): integer
                    b.v = b.v + x      -- mutate a field of the captured record
                    return b.v
                end
            end
        ]], [[
            local f = test.make()
            assert(f(10) == 10)
            assert(f(5) == 15)
        ]])
    end)

    it("captures and reassigns a record-typed local (boxed)", function()
        -- Reassigning the record-typed local itself (not just a field) marks it
        -- captured-and-mutated -> boxed; the box stores a Udata, exercising the
        -- forward barrier on a gc box store.
        run_coder([[
            record Box v: integer end
            function make(): (integer) -> integer
                local b: Box = { v = 1 }
                return function (x: integer): integer
                    b = { v = b.v + x }   -- reassign the captured record local
                    return b.v
                end
            end
        ]], [[
            local f = test.make()
            assert(f(10) == 11)
            assert(f(100) == 111)
        ]])
    end)

    it("GC stress (generational) over a gc-typed boxed string capture", function()
        -- The generational collector is where a missing forward barrier on a
        -- COLLECTABLE box store causes near-deterministic corruption, so drive
        -- the string boxed-capture mutation under it specifically.
        run_coder([[
            function accum(): (string) -> string
                local s = "start:"
                return function (piece: string): string
                    s = s .. piece
                    return s
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.accum() end
            collectgarbage()
            for i = 1, 40 do assert(fs[i]('x') == 'start:x') end
            collectgarbage()
            for i = 1, 40 do assert(fs[i]('y') == 'start:xy') end
            collectgarbage('collect')
            for i = 1, 40 do assert(fs[i]('z') == 'start:xyz') end
        ]])
    end)

    it("GC stress (generational) over a gc-typed boxed array capture", function()
        run_coder([[
            function pusher(): (integer) -> integer
                local xs: {integer} = {}
                return function (v: integer): integer
                    xs[#xs + 1] = v * v
                    return xs[#xs]
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.pusher() end
            collectgarbage()
            for i = 1, 40 do assert(fs[i](3) == 9) end
            collectgarbage()
            for i = 1, 40 do assert(fs[i](4) == 16) end
        ]])
    end)

    it("for-loop-created closures each capture their own iteration value", function()
        -- A `for` control variable is immutable (the implicit increment does not
        -- mark it assigned), so it is captured by value -> fresh per iteration.
        run_coder([[
            function make_closures(): {() -> integer}
                local fns: {() -> integer} = {}
                for i = 1, 3 do
                    fns[i] = function (): integer return i * 100 end
                end
                return fns
            end
        ]], [[
            local fns = test.make_closures()
            assert(fns[1]() == 100)
            assert(fns[2]() == 200)
            assert(fns[3]() == 300)
        ]])
    end)

    it("an IIFE via the parenthesized form is callable", function()
        -- D5: direct application requires parentheses; `(function...end)(x)`.
        run_coder([[
            function run(): integer
                return (function (x: integer): integer return x + 1 end)(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("stores a lambda in a record field, GCs, then calls it", function()
        -- A closure value stored into a record field is a gc store (the record's
        -- backing Udata); after a hard GC the stored closure and its captured
        -- box must still be intact.
        run_coder([[
            record Holder f: () -> integer end
            function make(): Holder
                local n = 100
                return { f = function (): integer
                    n = n + 1
                    return n
                end }
            end
        ]], [[
            local h = test.make()
            collectgarbage()
            collectgarbage('collect')
            assert(h.f() == 101)
            assert(h.f() == 102)
        ]])
    end)
end)

describe("closures inside methods (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("a method's lambda mutates self's field (self captured by value)", function()
        run_coder([[
            record C n: integer end
            function C:bumper(): () -> integer
                return function (): integer
                    self.n = self.n + 1   -- mutate a field through captured self
                    return self.n
                end
            end
            function make(): () -> integer
                local c = C.new(10)
                return c:bumper()
            end
        ]], [[
            local f = test.make()
            collectgarbage()
            assert(f() == 11)
            assert(f() == 12)
            assert(f() == 13)
        ]])
    end)

    it("a method's lambda reassigns self (self is captured-and-mutated -> boxed)", function()
        -- `self = ...` inside the lambda marks self captured-and-mutated, so the
        -- method must box self; the method body and the lambda then share the box.
        run_coder([[
            record C n: integer nxt: C? end
            function C:walk(): () -> integer
                return function (): integer
                    local v = self.n
                    if self.nxt then
                        self = self.nxt as C   -- reassign the boxed self
                    end
                    return v
                end
            end
            function build(): () -> integer
                local c3: C = { n = 30, nxt = nil }
                local c2: C = { n = 20, nxt = c3 }
                local c1: C = { n = 10, nxt = c2 }
                return c1:walk()
            end
        ]], [[
            local f = test.build()
            collectgarbage()
            assert(f() == 10)
            assert(f() == 20)
            assert(f() == 30)
            assert(f() == 30)   -- nxt is nil, self stays
        ]])
    end)
end)

describe("closures across modules (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("passes a lambda across a source-linked import and calls it", function()
        local ok, err = h.generate_modules({
            mka = [[
                function make(start: integer): (integer) -> integer
                    local acc = start
                    return function (x: integer): integer
                        acc = acc + x
                        return acc
                    end
                end
            ]],
            useb = [[
                local a = import "mka"
                function run(): integer
                    local f: (integer) -> integer = a.make(100)
                    return f(1) + f(2)   -- 101 + 103 = 204 (captured state survives)
                end
            ]],
        }, "useb")
        assert.truthy(ok, err)
        local rok, out = h.call("useb", "assert(useb.run() == 204)")
        assert.truthy(rok, out)
    end)
end)

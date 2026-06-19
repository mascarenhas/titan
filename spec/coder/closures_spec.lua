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
        run_coder([[
            function make(): (integer) -> integer
                local k = 1000
                return function (x: integer): integer
                    return k + x
                end
            end
            -- fast path: exact static type
            function fast(x: integer): integer
                local f: (integer) -> integer = make()
                return f(x)
            end
            -- slow path: stored as `value`, then called
            function slow(x: integer): integer
                local v: value = make()
                local f = v as (integer) -> integer
                return f(x)
            end
        ]], [[
            assert(test.fast(5) == 1005)
            assert(test.slow(5) == 1005)
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
end)

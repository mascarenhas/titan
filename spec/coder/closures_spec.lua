local temporary = require "spec.support.temporary"
-- End-to-end tests for anonymous functions with lexical closure: generate C,
-- compile it, and run it. Covers boxed (captured-and-mutated) capture, by-value
-- capture, both call paths through a closure value, gc-typed captures (the box
-- barrier), transitive multi-level capture, GC stress over live closures/boxes,
-- end-to-end type inference of lambda params/return, and zero-return lambdas.
--
-- The frontend (parser/checker/inference) assertions live in spec/parser_spec.lua
-- and spec/checker/closures_spec.lua; this file is the runtime oracle.
local h = require 'spec.support.helpers'

local lfs = require 'lfs'
local generated_modules = {}

local function run_coder(...)
    generated_modules.test = true
    return h.run_coder(...)
end

local function compile_and_read_c(code, name)
    generated_modules[name or "test"] = true
    return h.compile_and_read_c(code, name)
end

local function generate_modules(modules, ...)
    for name in pairs(modules) do generated_modules[name] = true end
    return h.generate_modules(modules, ...)
end

local function remove_generated(path)
    if lfs.symlinkattributes(path, "mode") == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_generated(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    else
        assert(os.remove(path))
    end
end

local function clean()
    -- Only this fixture's generated modules belong to its cleanup; checker
    -- metadata providers from other owners may still be mapped on Windows.
    for name in pairs(generated_modules) do
        local stem = name:gsub("[.]", "/")
        for _, suffix in ipairs({ ".o", ".so", ".dll", ".dylib", ".a", ".def",
                ".dll.def", ".so.dSYM", ".dylib.dSYM", ".ffi.h", ".titan.h",
                ".priv.h", ".parts", ".c" }) do
            local path = stem .. suffix
            if (suffix ~= ".c" or not h.verbose) and lfs.symlinkattributes(path) then
                remove_generated(path)
            end
        end
    end
    generated_modules = {}
end

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function captured_lambda_source(count)
    -- Keep each capture use shallow: this is a closure-capacity test, not a
    -- stress test for a C compiler's recursive handling of one huge expression.
    local declarations, additions = {}, {}
    for i = 1, count do
        declarations[#declarations + 1] =
            string.format("local capture_%03d: integer = %d", i, i)
        additions[#additions + 1] =
            string.format("total = total + capture_%03d", i)
    end
    return string.format([[
        function make(): function (): (integer)
            %s
            return function(): integer
                local total: integer = 0
                %s
                return total
            end
        end
    ]], table.concat(declarations, "\n"), table.concat(additions, "\n"))
end

describe("closures (end-to-end)", function()
    after_each(clean)

    it("a counter closure increments a captured boxed integer", function()
        run_coder([[
            function make_counter(): function (): integer
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

    it("constructs and calls the largest representable captured closure",
    function()
        run_coder(captured_lambda_source(250), [[
            local f = test.make()
            assert(f() == 31375)
        ]])
    end)

    it("two counters are independent", function()
        run_coder([[
            function make_counter(): function (): integer
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
            function adder(start: integer): function (integer): integer
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
            function bump(n: integer): function (): integer
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
            function make(n: integer): function (integer): integer
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
            function collect(s: string): function (string): string
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
            function make_adder(k: integer): function (integer): integer
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
            function make_closures(): {function (integer): integer}
                local fns: {function (integer): integer} = {}
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
            function make_g(): function (function (): integer): integer
                local calls = 0
                return function (p: function (): integer): integer
                    calls = calls + 1   -- genuine (boxed) capture: g is a closure
                    return p()           -- returned value is purely the probe
                end
            end
            function outer(g: function (function (): integer): integer,
                           p: function (): integer): integer
                return g(p)
            end
            -- fast path: the captured-closure `g` is called at its exact type
            function run_fast(p: function (): integer): integer
                return outer(make_g(), p)
            end
            -- slow path: `g` arrives as a value (here a Lua closure from the
            -- driver) whose tag is unknown statically -> generic call path
            function run_slow(g: function (function (): integer): integer,
                              p: function (): integer): integer
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
            function make_tagger(prefix: string): function (string): string
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
            function greeter(name: string): function (): string
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
            function accum(): function (string): string
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
            function pusher(): function (integer): integer
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
            function outer(seed: integer): function (): integer
                local total = 0
                local label = seed * 1000
                return function (): integer
                    -- middle level: itself a closure capturing total + label
                    local inner: function (): integer = function (): integer
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
            function make_counter(): function (): integer
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
            function accum(): function (string): string
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
            function pusher(): function (integer): integer
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
            function apply(f: function (integer): integer, x: integer): integer
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
            function apply(f: function (integer): integer, x: integer): integer
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
                local add: function (integer): () = function (x: integer)
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
            function outer(): function (): (function (): integer)
                local n = 41
                return function (): function (): integer
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
            function make(): function (integer): integer
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
            function make(): function (integer): integer
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
            function accum(): function (string): string
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
            function pusher(): function (integer): integer
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

    it("GC churn over a boxed integer? (raw-TValue Udata0 box)", function()
        -- An `integer?` captured-and-mutated local is boxed, but `integer?` is
        -- NOT a gc type (its TValue is only ever nil-or-scalar), so the box is a
        -- raw 0-uservalue Udata0 storing the TValue inline with no GC barrier.
        -- The closure reads/writes the boxed option across both `nil` and
        -- integer values; drive it under generational GC with allocation churn
        -- to confirm the untraced raw-TValue box round-trips and is GC-safe.
        run_coder([[
            function make_optcell(): function (integer): integer
                local n: integer? = nil
                return function (x: integer): integer
                    local prev = n or -1
                    if x == 0 then
                        n = nil
                    else
                        n = x
                    end
                    return prev
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.make_optcell() end
            collectgarbage()
            -- first call: box holds nil -> prev defaults to -1
            for i = 1, 40 do assert(fs[i](7) == -1) end
            collectgarbage()
            -- box now holds 7; set it back to nil, observing 7
            for i = 1, 40 do assert(fs[i](0) == 7) end
            collectgarbage('collect')
            -- box holds nil again -> prev defaults to -1; store 13
            for i = 1, 40 do assert(fs[i](13) == -1) end
            collectgarbage()
            -- box holds 13
            for i = 1, 40 do assert(fs[i](99) == 13) end
        ]])
    end)

    it("GC churn over a boxed float? (raw-TValue Udata0 box)", function()
        -- Like the integer? case above, a `float?` captured-and-mutated local is
        -- boxed but NOT a gc type (its TValue is only ever nil-or-float), so it
        -- uses the raw 0-uservalue Udata0 box storing the TValue inline with no GC
        -- barrier (ctype = TValue, sizeudata(0, sizeof(TValue)), nuvalue = 0). The
        -- closure round-trips the boxed option across nil and float values under
        -- generational GC churn to confirm the untraced raw box is GC-safe.
        run_coder([[
            function make_optf(): function (float): float
                local n: float? = nil
                return function (x: float): float
                    local prev = n or -1.0
                    if x == 0.0 then
                        n = nil
                    else
                        n = x
                    end
                    return prev
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.make_optf() end
            collectgarbage()
            -- box holds nil -> prev defaults to -1.0; store 2.5
            for i = 1, 40 do assert(fs[i](2.5) == -1.0) end
            collectgarbage()
            -- box holds 2.5; set it back to nil, observing 2.5
            for i = 1, 40 do assert(fs[i](0.0) == 2.5) end
            collectgarbage('collect')
            -- box holds nil again -> prev defaults to -1.0; store 7.25
            for i = 1, 40 do assert(fs[i](7.25) == -1.0) end
            collectgarbage()
            -- box holds 7.25
            for i = 1, 40 do assert(fs[i](99.0) == 7.25) end
        ]])
    end)

    it("GC churn over a boxed boolean? (raw-TValue Udata0 box)", function()
        -- A `boolean?` captured-and-mutated local is boxed but NOT a gc type, so
        -- it uses the raw 0-uservalue Udata0 box (ctype = TValue,
        -- sizeudata(0, sizeof(TValue)), nuvalue = 0, no barrier). `boolean?` has
        -- special-case loadslot/setslot handling distinct from other option bases;
        -- the raw box path bypasses that, so this guards that the raw TValue box
        -- round-trips all three boolean? states (nil / true / false) faithfully
        -- under generational GC churn. The box's initial nil enters via a real
        -- `boolean?` argument (NOT a `nil` literal): a `nil` *literal* coerced to
        -- `boolean?` is a SEPARATE known checker bug (it materializes boolean
        -- false rather than nil; reproduces on a non-boxed boolean? too), unrelated
        -- to the box representation, so it is deliberately avoided here.
        run_coder([[
            -- classify the boxed boolean?: 0 = nil, 1 = true, 2 = false
            function make(init: boolean?): function (boolean?): integer
                local b: boolean? = init
                return function (next: boolean?): integer
                    local r = 0
                    if b == true then
                        r = 1
                    elseif b == false then
                        r = 2
                    else
                        r = 0
                    end
                    b = next
                    return r
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.make(nil) end   -- box starts nil (real nil arg)
            collectgarbage()
            for i = 1, 40 do assert(fs[i](true) == 0) end   -- was nil -> set true
            collectgarbage()
            for i = 1, 40 do assert(fs[i](false) == 1) end  -- was true -> set false
            collectgarbage('collect')
            for i = 1, 40 do assert(fs[i](nil) == 2) end    -- was false -> set nil
            collectgarbage()
            for i = 1, 40 do assert(fs[i](true) == 0) end   -- was nil again -> set true
        ]])
    end)

    it("GC churn over a boxed nil-typed local (raw Udata0 box)", function()
        -- A `nil`-typed captured-and-mutated local IS expressible in surface Titan
        -- (`local n: nil = nil`, captured + reassigned). It is non-gc, so it uses
        -- the raw 0-uservalue Udata0 box with ctype = int (a dummy:
        -- sizeudata(0, sizeof(int)), nuvalue = 0, raw getudatamem, no barrier).
        -- The Nil raw branch is therefore reachable, not defensive-only. The box
        -- never holds anything but a placeholder int; the test confirms the
        -- closure runs and the box survives GC churn.
        run_coder([[
            function make_nilcell(): function (integer): integer
                local n: nil = nil
                return function (x: integer): integer
                    n = nil          -- reassign the boxed nil-typed local
                    return x + 1
                end
            end
        ]], [[
            collectgarbage('generational')
            local fs = {}
            for i = 1, 40 do fs[i] = test.make_nilcell() end
            collectgarbage()
            for i = 1, 40 do assert(fs[i](10) == 11) end
            collectgarbage('collect')
            for i = 1, 40 do assert(fs[i](41) == 42) end
        ]])
    end)

    it("for-loop-created closures each capture their own iteration value", function()
        -- A `for` control variable is immutable (the implicit increment does not
        -- mark it assigned), so it is captured by value -> fresh per iteration.
        run_coder([[
            function make_closures(): {function (): integer}
                local fns: {function (): integer} = {}
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
            record Holder f: function (): integer end
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

    it("a module var initialized with a lambda is a runtime-replaceable function", function()
        -- A module-level `local f = function...end` is a module *variable* holding
        -- a function value (stored into a `_mod` upvalue with the gc barrier), so
        -- `apply` calls it through the first-class value path and `setf` can
        -- reassign it at runtime — the replacement is observed on the next call.
        run_coder([[
            local f = function(x: integer): integer return x * 2 end
            function apply(x: integer): integer return f(x) end
            function setf(g: function (integer): integer) f = g end
        ]], [[
            assert(test.apply(10) == 20)
            test.setf(function(x) return x + 100 end)
            assert(test.apply(10) == 110)   -- reflects the replacement
        ]])
    end)

    it("constructs lambdas and bound methods without Lua-stack assembly",
    function()
        local csrc = compile_and_read_c([[
            record Counter
                n: integer
            end

            function Counter:get(): integer
                return self.n
            end

            function call(value_: Counter): integer
                return value_:get()
            end

            function bind(value_: Counter): function (): integer
                return value_:get
            end

            function capture(value_: integer): function (): integer
                local captured = value_
                return function (): integer
                    return captured
                end
            end
        ]])

        local function native_body(name)
            local signature = "TValue test_\\u2133_" .. name .. "_titan("
            local declaration = assert(csrc:find(signature, 1, true))
            local first = assert(csrc:find(
                signature, declaration + 1, true))
            local last = assert(csrc:find(
                "TITAN_MODULE_PRIVATE int test_\\u2133_" .. name .. "_titanentry_lua",
                first, true))
            return csrc:sub(first, last - 1)
        end

        local function direct_closure(body, expected_lua_entry)
            local closure = assert(body:match(
                "CClosure%s+%*(_tmp_%d+_closure)%s*=%s*"
                    .. "luaF_newCclosure%(L,%s*6%);"))
            local allocation = assert(body:find(
                "CClosure *" .. closure
                    .. " = luaF_newCclosure(L, 6);", 1, true))
            local entry = assert(body:find(
                closure .. "->f = " .. expected_lua_entry .. ";",
                allocation, true))
            local module = assert(body:find(
                "setuvalue(L, &" .. closure .. "->upvalue[0]",
                entry, true))
            local strict = assert(body:find(
                "setfvalue(&" .. closure .. "->upvalue[5]",
                module, true))
            local root = assert(body:find(
                "setclCvalue(L, s2v((restorestack(L, _base_off)",
                strict, true))
            local debt = assert(body:find(
                "luaC_checkGC(L);", root, true))
            local rebase = assert(body:find(
                "_base = restorestack(L, _base_off);", debt, true))
            assert.is_true(allocation < entry and entry < module
                and module < strict and strict < root
                and root < debt and debt < rebase)
            for _, forbidden in ipairs({
                "titan_pushmodule(L,", "lua_pushlightuserdata(L,",
                "lua_pushcfunction(L,", "lua_pushcclosure(L,",
            }) do
                assert.falsy(body:find(forbidden, 1, true), body)
            end
            return closure, allocation, root
        end

        local body = native_body("bind")
        local closure, allocation, root = direct_closure(
            body,
            "test_\\u2133_Counter_\\u2131_get_titanentry_boundlua")
        local before = body:sub(1, allocation - 1)
        assert.matches(
            "Udata%s*%*%s*_tmp_%d+%s*=%s*0;%s*"
                .. "_tmp_%d+%s*=%s*_param_value_;",
            before)
        assert.falsy(before:find("setuvalue(L", 1, true), before)
        local self = assert(body:find(
            "setuvalue(L, &" .. closure .. "->upvalue[4]",
            allocation, true))
        assert.is_true(allocation < self and self < root)

        local lambda_body = native_body("capture")
        local lambda_closure, lambda_allocation, lambda_root =
            direct_closure(lambda_body,
                "test_\\u2119_lambda_0_titanentry_lua")
        local capture = assert(lambda_body:find(
            "setivalue(&" .. lambda_closure .. "->upvalue[4]",
            lambda_allocation, true))
        assert.is_true(lambda_allocation < capture
            and capture < lambda_root)

        local call_declaration = assert(csrc:find(
            "lua_Integer test_\\u2133_call_titan(", 1, true))
        local call_first = assert(csrc:find(
            "lua_Integer test_\\u2133_call_titan(",
            call_declaration + 1, true))
        local call_last = assert(csrc:find(
            "TITAN_MODULE_PRIVATE int test_\\u2133_call_titanentry_lua", call_first, true))
        local call_body = csrc:sub(call_first, call_last - 1)
        local freeze = assert(call_body:find(
            "= _param_value_;", 1, true))
        local native_call = assert(call_body:find(
            "test_\\u2133_Counter_\\u2131_get_titanmethod(L, _mod, NULL,", freeze, true))
        assert.falsy(call_body:sub(freeze, native_call):find(
            "setuvalue(L", 1, true), call_body)
        assert.is_true(freeze < native_call)
    end)

    it("keeps directly constructed callables alive across collector modes",
    function()
        run_coder([[
            record Counter
                total: integer
            end

            function Counter:add(delta: integer): integer
                self.total = self.total + delta
                return self.total
            end

            function make_lambda(start: integer): function (integer): integer
                local total = start
                return function (delta: integer): integer
                    total = total + delta
                    return total
                end
            end

            function make_bound(start: integer): function (integer): integer
                return Counter.new(start):add
            end
        ]], [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for i = 1, 30 do
                    local lambda = test.make_lambda(i)
                    local bound = test.make_bound(i)
                    collectgarbage("collect")
                    assert(lambda(1) == i + 1)
                    assert(lambda(2) == i + 3)
                    assert(bound(3) == i + 3)
                    assert(bound(4) == i + 7)
                end
            end
        ]])
    end)

    it("a module var initialized with a const-receiver bound method ref runs", function()
        -- The receiver is a constructor call with a const arg, which `isconst`
        -- accepts; the bound method-ref initializer evaluates that receiver at
        -- module-init time, captures self, and stores the bound closure into a
        -- `_mod` upvalue (gc store, barriered). Calling it later applies the
        -- method against the captured receiver.
        run_coder([[
            record Adder base: integer end
            function Adder:add(x: integer): integer return self.base + x end
            local f = Adder.new(100):add
            function apply(x: integer): integer return f(x) end
        ]], [[
            assert(test.apply(5) == 105)
            assert(test.apply(7) == 107)
        ]])
    end)

    it("brands module-initializer lambdas and bound method refs before use", function()
        -- Both closures are constructed while _init is evaluating module
        -- variables. Their exact type tags must already be published then;
        -- otherwise a later compatible non-exact call mistakes them for plain
        -- Lua callables and applies the coercive result boundary.
        run_coder([[
            record Source end
            function Source:get(): value return 2.0 end

            local lambda: function (): value =
                function (): value return 2.0 end
            local bound: function (): value = Source.new():get

            function call_lambda_as_integer(): integer
                local f: function (): integer = lambda
                return f()
            end

            function call_bound_as_integer(): integer
                local f: function (): integer = bound
                return f()
            end
        ]], [[
            local ok_lambda = pcall(test.call_lambda_as_integer)
            local ok_bound = pcall(test.call_bound_as_integer)
            assert(not ok_lambda)
            assert(not ok_bound)
        ]])
    end)
end)

describe("closures inside methods (end-to-end)", function()
    after_each(clean)

    it("a method's lambda mutates self's field (self captured by value)", function()
        run_coder([[
            record C n: integer end
            function C:bumper(): function (): integer
                return function (): integer
                    self.n = self.n + 1   -- mutate a field through captured self
                    return self.n
                end
            end
            function make(): function (): integer
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
            function C:walk(): function (): integer
                return function (): integer
                    local v = self.n
                    if self.nxt then
                        self = self.nxt as C   -- reassign the boxed self
                    end
                    return v
                end
            end
            function build(): function (): integer
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
    after_each(clean)

    it("passes a lambda across a source-linked import and calls it", function()
        local ok, err = generate_modules({
            mka = [[
                function make(start: integer): function (integer): integer
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
                    local f: function (integer): integer = a.make(100)
                    return f(1) + f(2)   -- 101 + 103 = 204 (captured state survives)
                end
            ]],
        }, "useb")
        assert.truthy(ok, err)
        local rok, out = h.call("useb", "assert(useb.run() == 204)")
        assert.truthy(rok, out)
    end)
end)

-- Boxes whose value type only arises through `foreign import`: a foreign
-- `Type.CPointer` (e.g. FILE*) and a scalar `Type.CTypedef` (e.g. size_t). Both
-- are non-gc, so a captured-and-mutated local of those types uses the raw
-- 0-uservalue Udata0 box (ctype = foreignctype(typ) / ctype(underlying),
-- sizeudata(0, sizeof(ctype)), nuvalue = 0, raw getudatamem, no barrier). These
-- require the C FFI toolchain (cc/cpp/gcc), like the other foreign-import specs.
describe("closures over foreign-typed boxes (end-to-end)", function()
    after_each(clean)

    it("covers one captured and reassigned foreign-pointer raw box",
    function()
        with_header([[
            typedef int ffi_file;
            static ffi_file ffi_open_file;
            static ffi_file *ffi_open(int present) {
                return present ? &ffi_open_file : (ffi_file *)0;
            }
        ]], function(header)
            run_coder([[
                foreign import "]] .. header .. [["

                function make(present: integer): function (integer): boolean
                    local file = ffi.ffi_open(present)
                    return function(next: integer): boolean
                        local was_open = false
                        if file then was_open = true end
                        file = ffi.ffi_open(next)
                        return was_open
                    end
                end
            ]], [[
                local file = test.make(1)
                assert(file(0))
                assert(not file(1))
                assert(file(1))
            ]])
        end)
    end)

    it("captures and reassigns a foreign pointer (raw Udata0 box) #stress",
    function()
        -- A `FILE*` foreign-pointer local, captured by the lambda and reassigned
        -- inside it, is boxed; the box stores the raw `FILE*` inline (no barrier).
        -- The closure observes whether the box currently holds an open file (a
        -- non-NULL pointer) vs NULL across calls, and reassigns the box each call,
        -- exercising a NULL round-trip under generational GC churn.
        local ok, err = generate_modules({
            foo = [[
                foreign import "stdio.h"
                function make(name: string): function (string): integer
                    local f = ffi.fopen(name, "r")   -- f: FILE* foreign pointer, boxed
                    return function (next: string): integer
                        local opened = 0
                        if f then
                            opened = 1
                            ffi.fclose(f)
                        end
                        f = ffi.fopen(next, "r")     -- reassign the boxed pointer
                        return opened
                    end
                end
            ]],
        }, "foo")
        assert.truthy(ok, err)
        local rok, out = h.call("foo", [[
            local temporary = require "spec.support.temporary"
            local exists = temporary.name()
            local fd = io.open(exists, 'w'); fd:write('x'); fd:close()
            local missing = exists .. '.nope'
            os.remove(missing)
            collectgarbage('generational')
            local fns = {}
            for i = 1, 30 do fns[i] = foo.make(exists) end   -- box opened (existing file)
            collectgarbage()
            for i = 1, 30 do assert(fns[i](exists) == 1) end   -- was open; reopen existing
            collectgarbage()
            for i = 1, 30 do assert(fns[i](missing) == 1) end  -- was open; reassign to NULL
            collectgarbage('collect')
            for i = 1, 30 do assert(fns[i](exists) == 0) end   -- box was NULL; reopen existing
            collectgarbage()
            for i = 1, 30 do assert(fns[i](exists) == 1) end   -- open again
            os.remove(exists)
        ]])
        assert.truthy(rok, out)
    end)

    it("covers one captured and reassigned foreign-scalar raw box",
    function()
        with_header([[
            typedef unsigned long ffi_size;
            static ffi_size ffi_numbers[5] = { 4, 2, 2, 0, 0 };
            static int ffi_number_index = 0;
            static ffi_size ffi_next_number(void) {
                return ffi_numbers[ffi_number_index++];
            }
        ]], function(header)
            run_coder([[
                foreign import "]] .. header .. [["

                function make(): function (): boolean
                    local number = ffi.ffi_next_number()
                    return function(): boolean
                        local next_number = ffi.ffi_next_number()
                        local same = number == next_number
                        number = next_number
                        return same
                    end
                end
            ]], [[
                local number = test.make()
                assert(not number())
                assert(number())
                assert(not number())
                assert(number())
            ]])
        end)
    end)

    it("captures and reassigns a scalar foreign typedef (raw Udata0 box) #stress",
    function()
        -- `strlen` returns `size_t`, which stays a `Type.CTypedef` on the local `n`
        -- (it resolves to ctype lua_Integer only at the storage layer). Captured
        -- and reassigned in the lambda, `n` is boxed raw. The closure compares the
        -- boxed size_t against a fresh strlen and reassigns it (returning boolean,
        -- so no Typedef->integer cast is needed), round-tripping the raw box under
        -- generational GC churn.
        local ok, err = generate_modules({
            foo = [[
                foreign import "string.h"
                function make(s: string): function (string): (boolean)
                    local n = ffi.strlen(s)   -- n: size_t scalar typedef, boxed
                    return function (next: string): boolean
                        local same = (n == ffi.strlen(next))   -- read boxed size_t
                        n = ffi.strlen(next)                    -- reassign boxed size_t
                        return same
                    end
                end
            ]],
        }, "foo")
        assert.truthy(ok, err)
        local rok, out = h.call("foo", [[
            collectgarbage('generational')
            local fns = {}
            for i = 1, 40 do fns[i] = foo.make("abcd") end   -- box n = 4
            collectgarbage()
            for i = 1, 40 do assert(fns[i]("hi") == false) end   -- 4 vs 2 -> false; n -> 2
            collectgarbage()
            for i = 1, 40 do assert(fns[i]("yo") == true) end    -- 2 vs 2 -> true;  n -> 2
            collectgarbage('collect')
            for i = 1, 40 do assert(fns[i]("") == false) end     -- 2 vs 0 -> false; n -> 0
            collectgarbage()
            for i = 1, 40 do assert(fns[i]("") == true) end      -- 0 vs 0 -> true
        ]])
        assert.truthy(rok, out)
    end)
end)

describe("raw userdata allocation under Lua internal assertions (end-to-end)", function()
    local driver = require "titan-compiler.driver"
    after_each(clean)

    -- Under -DLUAI_ASSERT, check_exp evaluates gco2u's operand twice. A
    -- generated `gco2u(luaC_newobj(...))` therefore allocated a second,
    -- never initialized userdata that Lua later freed with whatever size its
    -- recycled header bytes implied. The vararg entry payload's block size
    -- makes that drift Lua's byte count reliably; a capture box's orphan often
    -- reuses an earlier box's header and frees with the right size by luck.
    -- So the run measures the drift for both, and the generated C pins every
    -- raw userdata site to the single-evaluation allocator. A forwarded `...`
    -- allocates nothing: it lowers to a C-stack open-argument array.
    it("keeps Lua's byte accounting balanced for capture boxes and vararg payloads", function()
        local saved = driver.EXTRA_CPPFLAGS
        local flags = { "-DLUAI_ASSERT" }
        for _, flag in ipairs(saved or {}) do flags[#flags + 1] = flag end
        driver.EXTRA_CPPFLAGS = flags
        local ok, failure = pcall(run_coder, [[
            function entry(...: integer): integer
                return #{...}
            end
            function churn_boxes(rounds: integer): integer
                local sum = 0
                for round = 1, rounds do
                    local boxed = round
                    local label = "r"
                    local bump = function()
                        boxed = boxed + 1
                        label = label .. "."
                    end
                    bump()
                    sum = sum + boxed + #label
                end
                return sum
            end
        ]], [[
            local rounds = 20000
            local failures = {}
            local function measure(label, work)
                collectgarbage("collect")
                collectgarbage("collect")
                local before = collectgarbage("count")
                work()
                collectgarbage("collect")
                collectgarbage("collect")
                local drift = collectgarbage("count") - before
                if drift <= -64 then
                    failures[#failures + 1] = label .. " drifted by " .. drift .. " KiB"
                end
            end
            measure("capture boxes", function()
                assert(test.churn_boxes(rounds) > 0)
            end)
            measure("Lua-called variadic entry", function()
                for _ = 1, rounds do assert(test.entry(1, 2, 3, 4, 5, 6, 7, 8) == 8) end
            end)
            assert(#failures == 0, table.concat(failures, "; "))
        ]])
        driver.EXTRA_CPPFLAGS = saved
        if not ok then error(failure, 0) end
        local file = assert(io.open("test.c", "rb"))
        local code = file:read("a")
        file:close()
        assert.falsy(code:find("= gco2u(luaC_newobj", 1, true))
        local _, raw_boxes = code:gsub("titan_new_udata_object%(L, sizeudata%(0, sizeof", "")
        local _, gc_boxes = code:gsub("titan_new_udata_object%(L, sizeudata%(1, 0%)%)", "")
        local _, payloads = code:gsub("_varargs_ud = titan_new_udata_object%(L,", "")
        assert.is_true(raw_boxes > 0 and gc_boxes > 0 and payloads > 0,
            raw_boxes .. " raw boxes, " .. gc_boxes .. " GC boxes, " .. payloads .. " payloads")
    end)
end)

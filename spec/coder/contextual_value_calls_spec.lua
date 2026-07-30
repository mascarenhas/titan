local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"

local run_coder = h.run_coder

local function generate(source)
    h.reset(true)
    local ast, perr = h.parse(source, "test.titan")
    assert.truthy(ast, perr)
    local _, errors = checker.check("test", ast, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", ast, {}, driver.TITAN_VER)
end

describe("contextual calls through value (code generation)", function()
    after_each(function()
        if h.verbose then return end
        os.remove("test.c")
        os.remove("test.o")
        os.remove("test.so")
        os.execute("rm -rf test.dSYM")
    end)

    it("honors finite, open, and zero demand for every Lua callable kind",
    function()
        run_coder([[
            function finite(f: value): (integer, integer?)
                return f()
            end

            function open(f: value): {integer}
                return { f() }
            end

            function discard(f: value): integer
                f()
                return 42
            end

            function cfunction(f: value, text: string): integer
                return f(text)
            end
        ]], [[
            local calls = 0
            local function values()
                calls = calls + 1
                return 10, 20, 30
            end
            local callable = setmetatable({}, { __call = values })

            for _, f in ipairs({ values, callable }) do
                local a, b = test.finite(f)
                assert(a == 10 and b == 20)

                local xs = test.open(f)
                assert(#xs == 3 and xs[1] == 10 and xs[2] == 20
                    and xs[3] == 30)

                local before = calls
                assert(test.discard(f) == 42)
                assert(calls == before + 1)
            end

            for _, invoke in ipairs({ test.finite, test.open, test.discard }) do
                assert(not pcall(invoke, {}))
            end

            assert(test.cfunction(string.byte, "A") == 65)
        ]])
    end)

    it("keeps inner results open in nested outer(inner()) calls", function()
        run_coder([[
            function nested_finite(outer: value, inner: value): integer
                return outer(inner())
            end

            function nested_open(outer: value, inner: value): {integer}
                return { outer(inner()) }
            end
        ]], [[
            local seen
            local function count(...)
                seen = select("#", ...)
                return seen
            end
            assert(test.nested_finite(count,
                function() return 4, 5, 6 end) == 3)
            assert(seen == 3)

            local function pass(...)
                seen = select("#", ...)
                return ...
            end
            local xs = test.nested_open(pass,
                function() return 7, 8, 9 end)
            assert(seen == 3)
            assert(#xs == 3 and xs[1] == 7 and xs[2] == 8 and xs[3] == 9)

            xs = test.nested_open(pass, function() end)
            assert(seen == 0 and #xs == 0)
        ]])
    end)

    it("recovers an exact contextual tag instead of adding a Lua frame",
    function()
        run_coder([[
            function original(probe: () -> integer): integer
                return probe()
            end

            function contextual(callable: value,
                                probe: () -> integer): integer
                return callable(probe)
            end
        ]], h.DEPTH_PROBE .. [[
            local fast_depth = test.contextual(test.original, depth)
            local slow_depth = test.contextual(slow_g, depth)
            assert(slow_depth > fast_depth,
                ("contextual fast=") .. fast_depth
                    .. (" lua slow=") .. slow_depth)
        ]])
    end)

    it("does not expose results hidden by a fixed static function type",
    function()
        local source = [[
            function wide(): (integer, integer, integer)
                return 11, 22, 33
            end

            function count(...: integer): integer
                return #...
            end

            function array_sink(f: () -> integer): {integer}
                return { f() }
            end

            function argument_sink(f: () -> integer): integer
                return count(f())
            end

            function return_sink(f: () -> integer): (...: integer)
                return f()
            end
        ]]

        -- All three consumers are open sinks, but their producer is statically
        -- fixed-only. Both non-exact branches (strict Titan and genuine Lua)
        -- must ask the VM for exactly that one visible result; LUA_MULTRET
        -- would leak a wider runtime callable.
        local csrc = generate(source)
        local _, finite_calls = csrc:gsub(
            "luaD_callnoyield%(L, restorestack%(L, _vc_func%), 1%);", "")
        assert.equal(6, finite_calls)
        assert.not_match(
            "luaD_callnoyield%(L, restorestack%(L, _vc_func%), LUA_MULTRET%)",
            csrc)

        run_coder(source, [[
            local function check(f, expected)
                local xs = test.array_sink(f)
                assert(#xs == 1 and xs[1] == expected)
                assert(test.argument_sink(f) == 1)
                local n, first = select("#", test.return_sink(f)),
                    test.return_sink(f)
                assert(n == 1 and first == expected)
            end

            -- The Titan closure's runtime tag describes three fixed results,
            -- while every sink deliberately sees the narrower () -> integer.
            check(test.wide, 11)
            check(function() return 44, 55, 66 end, 44)
        ]])
    end)

    it("fails when an absent flexible slot is forced to a non-option",
    function()
        run_coder([[
            function absent(): (...: integer)
                return
            end

            function present(): (...: integer)
                return 17
            end

            function exact_required(): integer
                return absent()
            end

            function exact_present(): integer
                return present()
            end

            function generic_required(f: () -> (...: integer)): integer
                return f()
            end
        ]], [[
            local function expect_absent_slot_error(callable, ...)
                local ok, err = pcall(callable, ...)
                assert(not ok)
                assert(tostring(err):find(
                    "expected integer but found nil", 1, true), err)
            end

            expect_absent_slot_error(test.exact_required)
            assert(test.exact_present() == 17)

            expect_absent_slot_error(test.generic_required, function() end)
            assert(test.generic_required(function() return 23 end) == 23)
        ]])
    end)
end)

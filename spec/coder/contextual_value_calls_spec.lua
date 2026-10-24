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
    return coder.generate("test", ast, {}, driver.TITAN_ABI_VERSION).parts[1].code
end

describe("contextual calls through value (code generation)", function()
    after_each(function()
        if h.verbose then return end
        os.remove("test.c")
        os.remove("test.o")
        os.remove("test.so")
        os.execute("rm -rf test.dSYM")
    end)

    it("keeps exact Titan function-value calls on the static likely path",
        function()
            local generated = generate([[
            function increment(number: integer): integer
                return number + 1
            end

            function invoke(
                fn: function (integer): integer,
                number: integer
            ): integer
                return fn(number)
            end
        ]])

            local exact = assert(generated:find(
                "if (TITAN_LIKELY(_vc_callee != NULL", 1, true))
            local static_tag = assert(generated:find(
                "pvalueraw(valraw(&_vc_callee->upvalue[1]))", exact, true))
            local fallback = assert(generated:find(
                "} else {", static_tag, true))
            local brand = assert(generated:find(
                "pvalueraw(valraw(&_vc_callee->upvalue[3]))",
                fallback, true))
            local strict_dispatch = assert(generated:find(
                "if (_vc_is_titan)", brand, true))
            assert.is_true(exact < static_tag)
            assert.is_true(static_tag < fallback)
            assert.is_true(fallback < brand)
            assert.is_true(brand < strict_dispatch)

            local exact_segment = generated:sub(exact, fallback - 1)
            assert.truthy(exact_segment:find(
                "_vc_callee->nupvalues >= 5", 1, true))
            assert.is_nil(exact_segment:find("ttislightuserdata", 1, true))
            assert.is_nil(exact_segment:find("ttisfulluserdata", 1, true))
            assert.is_nil(exact_segment:find("ttislcf", 1, true))

            local classifier = generated:sub(fallback, strict_dispatch - 1)
            assert.truthy(classifier:find(
                "_vc_callee->nupvalues >= 5", 1, true))
            assert.truthy(classifier:find(
                "== TITAN_BRAND", 1, true))
            assert.is_nil(classifier:find("ttis", 1, true))
            assert.is_nil(classifier:find("lua_getfield", 1, true))
            assert.is_nil(generated:find(
                "titan_is_function_type_tag", 1, true))
            assert.truthy(generated:find(
                "lua_pushlightuserdata(L, TITAN_BRAND)",
                1, true))
            assert.truthy(generated:find(
                "pvalue(&_fn->upvalue[1]) != " ..
                "((test_native_data *)getudatamem(_mod))->test_functag_",
                1, true))
        end)

    it("calls static and constructor closures through widened signatures",
        function()
            run_coder([[
            record Callables
                base: integer
            end

            function Callables.add(n: integer): integer return n + 10 end
            function Callables.identity<|T|>(item: T): T return item end
            function Callables:add_to(n: integer): integer
                return self.base + n
            end
            function Callables:echo<|T|>(item: T): T return item end

            union Choice
                item(integer)
                empty()
            end

            function call(fn: function (...: value): (...: value),
                          ...: value): (...: value)
                return fn(...)
            end

            function call_method(fn: function (value, ...: value): (...: value),
                                 receiver: value, ...: value): (...: value)
                return fn(receiver, ...)
            end

            function payload(choice: Choice): integer
                case choice
                when item(n) then return n
                when empty() then return 0
                end
            end
        ]], [[
            assert(test.call(test.Callables.add, 8) == 18)
            assert(test.call(test.Callables.identity, "generic") == "generic")
            assert(test.call(test.Callables.identity, false) == false)

            local receiver = test.call(test.Callables.new, 20)
            assert(test.call_method(receiver.add_to, receiver, 7) == 27)
            assert(test.call_method(receiver.echo, receiver, false) == false)

            assert(test.payload(test.call(test.Choice.item, 31)) == 31)
            assert(test.payload(test.call(test.Choice.empty)) == 0)

            -- Widening still enters the closure's strict parameter guards;
            -- only a genuine Lua call performs numeric coercion.
            for _, fn in ipairs({test.Callables.add, test.Callables.new,
                                 test.Choice.item}) do
                local ok, err = pcall(test.call, fn, 8.0)
                assert(not ok)
                assert(tostring(err):find("expected integer tag", 1, true), err)
            end
            assert(test.Callables.add(8.0) == 18)
        ]])
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

    it("closes dependent contextual calls without repeating lexical evaluation",
        function()
            run_coder([[
            function agree<|T|>(left: T, right: T): T
                return left
            end

            function make_fixed<|T|>(): function (T, T): T
                return function(left: T, right: T): T return left end
            end

            function make_open<|T|>(): function (...: T): T
                return function(...: T): T return ...[1] end
            end

            record Box<|T|>
                item: T
            end

            function take_array<|T|>(items: {T}, witness: T): T
                return witness
            end

            function take_map<|T|>(items: {string: T}, witness: T): T
                return witness
            end

            function take_box<|T|>(box: Box<|T|>, witness: T): T
                return witness
            end

            local phase: integer = 0
            local selections: integer = 0

            function select_callback(callback: value): value
                selections = selections + 1
                phase = phase * 10 + 1
                return callback
            end

            function callback_result(): integer
                phase = phase * 10 + 2
                return 42
            end

            local function witness(): integer
                phase = phase * 10 + 3
                return 42
            end

            local function reset_trace()
                phase = 0
                selections = 0
            end

            function trace(): integer
                return phase * 10 + selections
            end

            function scalar(callback: value): integer
                reset_trace()
                return agree(select_callback(callback)(), witness())
            end

            function named(callback: value): integer
                reset_trace()
                return agree {
                    left = select_callback(callback)(),
                    right = witness()
                }
            end

            function fixed(callback: value): integer
                reset_trace()
                return agree(
                    make_fixed()(select_callback(callback)()), witness())
            end

            function open(callback: value): integer
                reset_trace()
                return agree(
                    make_open()(select_callback(callback)()), witness())
            end

            function array(callback: value): integer
                reset_trace()
                local got = take_array(
                    { select_callback(callback)() }, witness())
                return got
            end

            function map(callback: value): integer
                reset_trace()
                local got = take_map(
                    { ["item"] = select_callback(callback)() }, witness())
                return got
            end

            function boxed(callback: value): integer
                reset_trace()
                local got = take_box(
                    { item = select_callback(callback)() }, witness())
                return got
            end
        ]], [[
            for _, invoke in ipairs({
                test.scalar, test.named, test.fixed, test.open,
                test.array, test.map, test.boxed,
            }) do
                local calls = 0
                local got = invoke(function()
                    calls = calls + 1
                    local number = test.callback_result()
                    return number, number + 1
                end)
                assert(got == 42)
                assert(calls == 1)
                -- select/callback/witness remain left-to-right (123), and the
                -- callback expression itself was selected exactly once (1).
                assert(test.trace() == 1231, test.trace())
            end
        ]])
        end)

    it("runs dependent derived demands and open inputs once in order",
        function()
            run_coder([[
            function agree<|T|>(left: T, right: T): T return left end
            function take<|T|>(items: {T}, witness: T): T return witness end
            function pick<|T|>(left: T?, right: T): T return right end
            function make_map<|T|>(): {T: T} return {} end

            local steps: integer = 0
            local selections: integer = 0
            local order_okay: boolean = true
            local function reset_trace()
                steps = 0
                selections = 0
                order_okay = true
            end
            local function mark(expected: integer)
                steps = steps + 1
                if steps ~= expected then order_okay = false end
            end
            function count(): integer return steps end
            function selected(): integer return selections end
            function ordered(): boolean return order_okay end

            function select_callback(callback: value): value
                mark(1)
                selections = selections + 1
                return callback
            end
            function integer_result(expected: integer): integer
                mark(expected)
                return 42
            end
            function string_result(expected: integer): string
                mark(expected)
                return "item"
            end
            function spread<|T|>(expected: integer): (...: T)
                mark(expected)
                return (40 as value) as T, (41 as value) as T
            end

            function parenthesized(callback: value): integer
                reset_trace()
                return take(
                    {(select_callback(callback)())}, integer_result(3))
            end
            function key(callback: value): string
                reset_trace()
                return pick(make_map()[select_callback(callback)()],
                    string_result(3))
            end
            function open_input(callback: value): integer
                reset_trace()
                return agree(select_callback(callback)(spread(2)),
                    integer_result(4))
            end
        ]], [[
            local calls = 0
            assert(test.parenthesized(function()
                calls = calls + 1
                return test.integer_result(2), 99
            end) == 42)
            assert(calls == 1)
            assert(test.count() == 3)
            assert(test.selected() == 1)
            assert(test.ordered())

            calls = 0
            assert(test.key(function()
                calls = calls + 1
                return test.string_result(2)
            end) == "item")
            assert(calls == 1)
            assert(test.count() == 3)
            assert(test.selected() == 1)
            assert(test.ordered())

            calls = 0
            assert(test.open_input(function(...)
                calls = calls + 1
                assert(select("#", ...) == 2)
                local first, second = ...
                assert(first == 40 and second == 41)
                return test.integer_result(3), 99
            end) == 42)
            assert(calls == 1)
            assert(test.count() == 4)
            assert(test.selected() == 1)
            assert(test.ordered())
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
            function original(probe: function (): integer): integer
                return probe()
            end

            function contextual(callable: value,
                                probe: function (): integer): integer
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

            function array_sink(f: function (): integer): {integer}
                return { f() }
            end

            function argument_sink(f: function (): integer): integer
                return count(f())
            end

            function return_sink(f: function (): integer): (...: integer)
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

            function generic_required(f: function (): (...: integer)): integer
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

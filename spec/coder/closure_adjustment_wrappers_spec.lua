require "titan-compiler.coder.core"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local coder_values = require "titan-compiler.coder.values"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"

local function cleanup_module(name)
    name = name or "test"
    for _, suffix in ipairs({ ".c", ".o", ".so", ".a" }) do
        os.remove(name .. suffix)
    end
    os.execute("rm -rf " .. name .. ".so.dSYM")
end

local function checked(source)
    local ok, err, tree = h.run_checker(source)
    assert.is_true(ok, err)
    return tree
end

local function find_function(tree, name)
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("missing function " .. name)
end

local FIXED_SOURCE = [[
    local function actual(x: integer): integer
        return x + 1
    end

    function source(): (integer) -> integer
        return actual
    end

    function exact(): (integer) -> integer
        local same: (integer) -> integer = actual
        return same
    end

    function view(): (value) -> value
        local adjusted: (value) -> value = actual
        return adjusted
    end

    function direct(): integer
        local adjusted: (integer, value) -> value = actual
        return adjusted(41, "ignored") as integer
    end

    function chained(): integer
        local first: (integer, value) -> value = actual
        local second: (integer, value, value) -> value = first
        return second(41, "a", "b") as integer
    end

    function erased(): integer
        local first: (integer, value) -> value = actual
        local dynamic: value = first
        local second: (integer, value, value) -> value = dynamic
        return second(41, "a", "b") as integer
    end

    local constructions = 0

    local function make_source(): (integer) -> integer
        constructions = constructions + 1
        return actual
    end

    function evaluated_once(): integer
        constructions = 0
        local adjusted: (integer, value) -> value = make_source()
        adjusted(1, "ignored")
        return constructions
    end

    function typed_rejects_float(): boolean
        local adjusted: (value) -> value = actual
        local dynamic: value = 41.0
        local succeeded = true
        do
            adjusted(dynamic)
        catch
            succeeded = false
        end
        return succeeded
    end

    local function invoke_probe(probe: () -> integer): integer
        return probe()
    end

    function wrapper_depth(probe: () -> integer): integer
        local adjusted: (() -> integer, value) -> value = invoke_probe
        return adjusted(probe, nil) as integer
    end

    function fallback_depth(
        carrier: value,
        probe: () -> integer
    ): integer
        local alleged: (() -> integer) -> integer = carrier
        local adjusted: (() -> integer, value) -> value = alleged
        return adjusted(probe, nil) as integer
    end
]]

describe("closure adjustment wrappers (end-to-end)", function()
    it("rejects a C declaration at the callable-plan codegen boundary", function()
        local cint = types.CInteger("int", true, 3, 32)
        local cfunc = types.CFunction({ cint }, cint, false, false)
        local titan = types.Function(
            { types.Integer() }, { types.Integer() }, false, false, false)
        local plan = {
            kind = "callable",
            source = cfunc,
            target = titan,
            exact = false,
            arguments = {},
            results = {},
        }

        assert.has_error(function()
            coder_values._checked_callable_plan(
                plan, cfunc, titan, "C declaration isolation")
        end, "C declaration isolation has non-callable operand types")
    end)

    after_each(function()
        cleanup_module("test")
    end)

    it("conditionally clones fresh target-tagged views and preserves source Lua behavior",
    function()
        h.run_coder(FIXED_SOURCE, h.DEPTH_PROBE .. [[
            local function upvalues(fn)
                local values = {}
                local index = 1
                while true do
                    local name, value = debug.getupvalue(fn, index)
                    if name == nil then break end
                    values[index] = value
                    index = index + 1
                end
                return values
            end

            local source = test.source()
            assert(rawequal(test.exact(), source))
            local first = test.view()
            local second = test.view()
            assert(not rawequal(first, source))
            assert(not rawequal(first, second))

            -- The exact source has the four fixed Titan headers plus its strict
            -- trailer. A realized view copies the source Lua entry/module/brand,
            -- installs the target tag and native adapter, captures the immediate
            -- source, and ends in the consumer-local target strict relay.
            local source_uv = upvalues(source)
            local first_uv = upvalues(first)
            local second_uv = upvalues(second)
            assert(#source_uv == 5)
            assert(#first_uv == 6 and #second_uv == 6)
            assert(rawequal(first_uv[1], source_uv[1]))
            assert(not rawequal(first_uv[2], source_uv[2]))
            assert(not rawequal(first_uv[3], source_uv[3]))
            assert(rawequal(first_uv[4], source_uv[4]))
            assert(rawequal(first_uv[5], source))
            assert(not rawequal(first_uv[6], source_uv[5]))
            assert(rawequal(first_uv[2], second_uv[2]))
            assert(rawequal(first_uv[3], second_uv[3]))
            assert(rawequal(first_uv[6], second_uv[6]))

            assert(first(41.0) == 42) -- copied source coercive Lua entry
            assert(test.direct() == 42) -- target-tagged native adapter
            assert(test.chained() == 42)
            assert(test.erased() == 42) -- consumer-local target strict relay
            assert(test.evaluated_once() == 1)
            assert(not test.typed_rejects_float())

            local fast_depth = test.wrapper_depth(depth)
            local slow_depth = test.fallback_depth(slow_g, depth)
            assert(slow_depth > fast_depth,
                "fast=" .. fast_depth .. " slow=" .. slow_depth)
        ]])
    end)

    it("roots an identity GC result immediately without native input copies",
    function()
        local tree = checked([[
            local function actual(x: integer): string
                return "ok"
            end

            function view(): (integer, value) -> string
                local adjusted: (integer, value) -> string = actual
                return adjusted
            end
        ]])
        local csrc = coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
        local signature =
            "static TITAN_NOINLINE TString* test_callable_adapter_0("
        local declaration = assert(csrc:find(signature, 1, true))
        local first = assert(csrc:find(
            signature, declaration + 1, true))
        local last = assert(csrc:find(
            "static int test_callable_adapter_0_titanentry_strict",
            first, true))
        local body = csrc:sub(first, last - 1)
        local call = assert(body:find(
            "_ia_concrete_result_1 = _ia_source_fp(", 1, true))
        local before = body:sub(1, call - 1)
        assert.falsy(before:find(
            "setobj2t(L, s2v((restorestack(L, _base_off)",
            1, true), before)
        assert.falsy(before:find(
            "setsvalue(L, s2v((restorestack(L, _base_off)",
            1, true), before)
        local rebase = assert(body:find(
            "_base = restorestack(L, _base_off);", call, true))
        local root = assert(body:find(
            "setsvalue(L, s2v((restorestack(L, _base_off)",
            rebase, true))
        local convert = assert(body:find(
            "_ia_interface_result_1 = _ia_concrete_result_1;",
            root, true))
        assert.is_true(call < rebase and rebase < root and root < convert)
    end)

    it("roots an identity flexible GC run before adapter projection",
    function()
        local tree = checked([[
            local function actual(x: integer): (...: string)
                return "a", "b"
            end

            function view(): (integer, value) -> (...: string)
                local adjusted:
                    (integer, value) -> (...: string) = actual
                return adjusted
            end
        ]])
        local csrc = coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
        local signature =
            "static TITAN_NOINLINE void test_callable_adapter_0("
        local declaration = assert(csrc:find(signature, 1, true))
        local first = assert(csrc:find(
            signature, declaration + 1, true))
        local last = assert(csrc:find(
            "static int test_callable_adapter_0_titanentry_strict",
            first, true))
        local body = csrc:sub(first, last - 1)
        local call = assert(body:find(
            "_ia_source_fp(L, _ia_source_mod, _ia_source,", 1, true))
        assert.falsy(body:sub(1, call - 1):find(
            "setsvalue(L, s2v((restorestack(L, _base_off)",
            1, true), body)
        local rebase = assert(body:find(
            "_base = restorestack(L, _base_off);", call, true))
        local root_loop = assert(body:find(
            "for (int _ia_root_i = 0;", rebase, true))
        local root = assert(body:find(
            "setsvalue(L, s2v((restorestack(L, _base_off)",
            root_loop, true))
        local projection = assert(body:find(
            "int _ia_interface_fcount = 0;", root, true))
        assert.is_true(call < rebase and rebase < root_loop
            and root_loop < root and root < projection)
    end)

    it("publishes each open callable result on exactly one adapter branch",
    function()
        local source = [[
            local type Source = (integer) -> integer
            local type Target = (integer, value) -> value

            local function first(...: Target): Target
                return ...[1]
            end

            function forwarded(...: Source): Target
                return first(...)
            end

            function forwarded_value(...: Source): Target
                local consumer: (...: Target) -> Target = first
                return consumer(...)
            end
        ]]
        local function native_body(csrc, name)
            local signature = "TValue test_\\u2133_" .. name .. "_titan("
            local declaration = assert(csrc:find(signature, 1, true))
            local first = assert(csrc:find(
                signature, declaration + 1, true))
            local last = assert(csrc:find(
                "static int test_\\u2133_" .. name .. "_titanentry_lua",
                first, true))
            return csrc:sub(first, last - 1)
        end
        local function assert_branch_publication(body, marker_)
            assert.truthy(body:find(marker_, 1, true), body)
            local allocation = assert(body:find(
                "luaF_newCclosure(L, _ca_nup + 1);", 1, true))
            local root = assert(body:find(
                "setclCvalue(L, s2v(", allocation, true))
            local otherwise = assert(body:find("} else {", root, true))
            local branch_end = assert(body:find(
                "\n            }\n        }", otherwise, true))
            local branch = body:sub(otherwise, branch_end)
            local relative_fallback = assert(branch:find(
                "setobj2t(L, s2v(", 1, true))
            assert.is_nil(branch:find(
                "setobj2t(L, s2v(", relative_fallback + 1, true), body)
            local fallback = otherwise + relative_fallback - 1
            assert.is_true(allocation < root and root < otherwise
                and otherwise < fallback and fallback < branch_end)
        end

        -- The ordinary checked tree uses the shared adjusted-open builder.
        local tree = checked(source)
        local csrc = coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
        assert_branch_publication(
            native_body(csrc, "forwarded"), "_open_vargs_")

        -- Pin the older case-3 template directly as a separate lowering unit:
        -- preserve the checker-frozen per-open plan while bypassing the newer
        -- aggregate expression-list route that normally owns this source form.
        local legacy_tree = checked(source)
        local func = find_function(legacy_tree, "forwarded_value")
        local call = func.block.stats[2].exps[1]
        assert.are.equal("Ast.ExpCall", call._tag)
        assert.truthy(call._arg_adjustment.open_source)
        assert.truthy(call._open_args)
        call._arg_adjustment = nil
        local legacy_csrc = coder.generate(
            "test", legacy_tree, {}, driver.TITAN_ABI_VERSION)
        assert_branch_publication(
            native_body(legacy_csrc, "forwarded_value"), "_varg_")
    end)

    it("allocates and initializes wrapper CClosures without API stack assembly",
    function()
        local tree = checked(FIXED_SOURCE)
        local csrc = coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.truthy(csrc:find(
            "CClosure *_ca_wrapper =", 1, true), csrc)
        assert.truthy(csrc:find(
            "luaF_newCclosure(L, _ca_nup + 1);", 1, true), csrc)
        assert.truthy(csrc:find(
            "setobj2n(L, &_ca_wrapper->upvalue[_ca_i]", 1, true), csrc)
        assert.truthy(csrc:find(
            "&_ca_wrapper->upvalue[_ca_nup - 1], _ca_source);",
            1, true), csrc)
        assert.truthy(csrc:find(
            "lua_assert(iswhite(_ca_wrapper));", 1, true), csrc)
        assert.falsy(csrc:find(
            "titan_ensure_stack(L, _ca_nup + 1);", 1, true), csrc)
        assert.falsy(csrc:find(
            [[lua_pushcclosure(
                    L, _ca_source->f]],
            1, true), csrc)
        assert.falsy(csrc:find(
            "ttisfulluserdata(&_ca_source->upvalue[0])", 1, true), csrc)
        assert.falsy(csrc:find(
            "ttislcf(&_ca_source->upvalue[", 1, true), csrc)
    end)

    it("polls before an adapter that allocates nested callable views",
    function()
        local tree = checked([[
            local function source(
                callback: (integer) -> integer
            ): (integer) -> integer
                return callback
            end

            function view(
                callback: (value) -> value
            ): (value) -> value
                local adjusted:
                    ((value) -> value) -> (value) -> value = source
                return adjusted(callback)
            end
        ]])
        local csrc = coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
        local signature =
            "static TITAN_NOINLINE TValue test_callable_adapter_0("
        local declaration = assert(csrc:find(signature, 1, true))
        local first = assert(csrc:find(signature, declaration + 1, true))
        local last = assert(csrc:find(
            "static int test_callable_adapter_0_titanentry_strict",
            first, true))
        local body = csrc:sub(first, last - 1)
        local poll = assert(body:find("luaC_checkGC(L);", 1, true))
        local base = assert(body:find("StkId _base", 1, true))
        local allocation = assert(body:find("luaF_newCclosure", 1, true))
        assert.is_true(poll < base and base < allocation)
    end)

    it("adapts an explicitly zero-result lambda", function()
        h.run_coder([[
            local seen = 0

            local function invoke(callback: () -> value): value
                return callback()
            end

            function run(): value
                seen = 0
                return invoke(function (): ()
                    seen = 42
                end)
            end

            function observed(): integer
                return seen
            end
        ]], [[
            assert(select("#", test.run()) == 1)
            assert(test.run() == nil)
            assert(test.observed() == 42)
        ]])
    end)

    it("executes the complete fixed, tail, flexible, and nil-result action matrix",
    function()
        h.run_coder([[
            local seen = 0

            local function ignore_actual(x: integer)
                seen = x
            end

            local function fill_actual(x: integer, missing: integer?)
                seen = x
                if missing ~= nil then
                    seen = seen + (missing as integer)
                end
            end

            local function variadic_actual(x: integer, ...: integer)
                seen = x
                local i = 1
                while i <= #... do
                    seen = seen + ...[i]
                    i = i + 1
                end
            end

            local function tail_actual(...: integer)
                seen = 0
                local i = 1
                while i <= #... do
                    seen = seen + ...[i]
                    i = i + 1
                end
            end

            function input_matrix(): integer
                local score = 0
                local ignore: (integer, string) -> () = ignore_actual
                ignore(1, "ignored")
                score = score + seen

                local fill: (integer) -> () = fill_actual
                fill(2)
                score = score + seen

                local tailfill: (integer, ...: value) -> () = fill_actual
                tailfill(3)
                score = score + seen
                tailfill(4, 5)
                score = score + seen
                tailfill(6, 7, "ignored")
                score = score + seen

                local gather: (integer, integer) -> () = variadic_actual
                gather(8, 9)
                score = score + seen

                local passthrough: (...: value) -> () = tail_actual
                passthrough(10, 11)
                score = score + seen

                local empty: (integer) -> () = variadic_actual
                empty(12)
                score = score + seen

                local discard: (integer, ...: string) -> () = ignore_actual
                discard(13, "a", "b")
                score = score + seen
                return score
            end

            local function zero()
            end

            local function one(): integer
                return 14
            end

            local function fixed(): (integer, integer)
                return 15, 16
            end

            local function flexible(): (...: integer)
                return 17, 18
            end

            function result_matrix(): integer
                local score = 0

                local nilfirst: () -> value = zero
                if nilfirst() == nil then score = score + 1 end

                local nilout: () -> (integer, value) = one
                local a: integer, b: value = nilout()
                if a == 14 and b == nil then score = score + 2 end

                local finite: () -> (integer?, integer) = flexible
                local c: integer?, d: integer = finite()
                if (c as integer) == 17 and d == 18 then
                    score = score + 4
                end

                local toflex: () -> (integer, ...: value) = fixed
                local e: integer, f: value? = toflex()
                if e == 15 and (f as integer) == 16 then
                    score = score + 8
                end

                local passthrough: () -> (...: value) = flexible
                local g: value?, h_: value? = passthrough()
                if (g as integer) == 17 and (h_ as integer) == 18 then
                    score = score + 16
                end

                local hidefixed: () -> () = one
                hidefixed()
                score = score + 32

                local hideflex: () -> () = flexible
                hideflex()
                score = score + 64

                local endflex: () -> (...: value) = zero
                local absent: value? = endflex()
                if absent == nil then score = score + 128 end
                return score
            end
        ]], [[
            assert(test.input_matrix() == 91)
            assert(test.result_matrix() == 255)
        ]])
    end)

    it("nil-fills every admitted representation and shared Interface results",
    function()
        local header = os.tmpname() .. "_closure_adjustment_nil.h"
        local file = assert(io.open(header, "wb"))
        assert.truthy(file:write([[
            typedef void *closure_adjustment_pointer;
            static inline int closure_adjustment_is_null(
                    closure_adjustment_pointer pointer) {
                return pointer == 0;
            }
        ]]))
        assert.truthy(file:close())

        local source = string.format([[
            foreign import %s

            local function zero()
            end

            interface Callback
                function invoke(): value
            end

            record Empty
            end

            function Empty:invoke()
            end

            function nil_representations(): boolean
                local as_nil: () -> nil = zero
                local as_value: () -> value = zero
                local as_option: () -> integer? = zero
                local as_cpointer:
                    () -> ffi.closure_adjustment_pointer = zero
                return as_nil() == nil
                    and as_value() == nil
                    and as_option() == nil
                    and ffi.closure_adjustment_is_null(as_cpointer()) == 1
            end

            function interface_nil(): boolean
                local callback: Callback = Empty.new()
                return callback:invoke() == nil
            end
        ]], string.format("%q", header))
        local ok, err = pcall(h.run_coder, source, [[
            assert(test.nil_representations())
            assert(test.interface_nil())
        ]])
        os.remove(header)
        assert.is_true(ok, err)
    end)

    it("preserves ordering and catch plus parser-lowered finally/defer cleanup",
    function()
        h.run_coder([[
            local events = ""

            local function note(event: string)
                events = events .. event
            end

            local function argument(valid: boolean): value
                note("A")
                if valid then return 7 end
                return {}
            end

            local function checked_source(x: integer): value
                note("S")
                return x
            end

            local function bad_result(x: value): value
                note("S")
                return {}
            end

            function argument_guard(valid: boolean): string
                events = ""
                do
                    -- `defer` is lowered to this block's finally clause.
                    defer note("F")
                    do
                        local adjusted: (value) -> integer =
                            checked_source
                        local result = adjusted(argument(valid))
                        if result == 7 then note("R") end
                    catch
                        note("C")
                    end
                end
                return events
            end

            function result_guard(): string
                events = ""
                do
                    defer note("F")
                    do
                        local adjusted: (value) -> integer = bad_result
                        adjusted(argument(true))
                    catch
                        note("C")
                    end
                end
                return events
            end
        ]], [[
            assert(test.argument_guard(true) == "ASRF")
            assert(test.argument_guard(false) == "ACF")
            assert(test.result_guard() == "ASCF")
        ]])
    end)

    it("wraps nested callable components and runtime-open runs", function()
        h.run_coder([[
            local function invoke_wide(
                callback: (integer, integer) -> ()
            )
                callback(5, 999)
            end

            local function make_narrow(): (integer) -> integer
                return function(x: integer): integer
                    return x + 1
                end
            end

            local function actual(x: integer): integer
                return x + 1
            end

            local function produce(): (...: (integer) -> integer)
                return actual, actual
            end

            local function use(...: (integer, value) -> value): integer
                local first = ...[1]
                local second = ...[2]
                return (first(10, "a") as integer)
                    + (second(20, "b") as integer)
            end

            local function forward(
                ...: (integer) -> integer
            ): integer
                return use(...)
            end

            function nested_arguments(): integer
                local adjusted: ((integer) -> ()) -> () = invoke_wide
                local total = 0
                adjusted(function(x: integer)
                    total = total + x
                end)
                return total
            end

            function nested_results(): integer
                local adjusted:
                    () -> (integer, value) -> value = make_narrow
                local callback = adjusted()
                return callback(6, "ignored") as integer
            end

            function open_constructor(): integer
                local callbacks: {(integer, value) -> value} = {produce()}
                return (callbacks[1](10, "a") as integer)
                    + (callbacks[2](20, "b") as integer)
            end

            function open_forward(): integer
                return forward(actual, actual)
            end
        ]], [[
            assert(test.nested_arguments() == 5)
            assert(test.nested_results() == 7)
            assert(test.open_constructor() == 32)
            assert(test.open_forward() == 32)
        ]])
    end)

    it("roots runtime-open wrapper runs across stack relocation and both collectors",
    function()
        local calls = {}
        for index = 1, 80 do
            calls[index] = string.format("make(%d)", index)
        end
        local call_list = table.concat(calls, ", ")
        local source = string.format([[
            local function make(n: integer): (integer) -> integer
                return function(x: integer): integer
                    return n + x
                end
            end

            local function produce(): (...: (integer) -> integer)
                return %s
            end

            local function use(
                ...: (integer, value) -> value
            ): integer
                local total = 0
                local index = 1
                while index <= #... do
                    local callback = ...[index]
                    total = total
                        + (callback(1, "ignored") as integer)
                    index = index + 1
                end
                return total
            end

            local function forward(
                ...: (integer) -> integer
            ): integer
                return use(...)
            end

            function from_dots(): integer
                return forward(%s)
            end

            function from_flexible(): integer
                return use(produce())
            end
        ]], call_list, call_list)
        h.run_coder(source, [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage("collect")
                if mode == "incremental" then
                    collectgarbage("incremental", 1, 1, 1)
                else
                    collectgarbage("generational", 1, 1)
                end
                for _ = 1, 30 do
                    assert(test.from_dots() == 3320)
                    assert(test.from_flexible() == 3320)
                end
            end
        ]])
    end)

    it("publishes 200 nested wrappers through an open target flexible result",
    function()
        local seed, growth = {}, {}
        for index = 1, 100 do seed[index] = "actual" end
        for index = 1, 99 do growth[index] = "actual" end
        local source = string.format([[
            local function actual(x: integer): integer
                return x
            end

            local function seed(): (...: (integer) -> integer)
                return %s
            end

            local function grow99(
                ...: (integer) -> integer
            ): (...: (integer) -> integer)
                return %s, ...
            end

            local function grow1(
                ...: (integer) -> integer
            ): (...: (integer) -> integer)
                return actual, ...
            end

            local function produce200(): (...: (integer) -> integer)
                return grow1(grow99(seed()))
            end

            function open_target(): {(integer, value) -> value}
                local adjusted:
                    () -> (...: (integer, value) -> value) = produce200
                return {adjusted()}
            end
        ]], table.concat(seed, ", "), table.concat(growth, ", "))
        h.run_coder(source, [[
            collectgarbage("collect")
            collectgarbage("generational", 1, 1)
            for _ = 1, 20 do
                local callbacks = test.open_target()
                assert(#callbacks == 200)
                assert(not rawequal(callbacks[1], callbacks[2]))
                collectgarbage("collect")
                assert(callbacks[1](11, "ignored") == 11)
                assert(callbacks[200](22, "ignored") == 22)
            end
        ]])
    end)

    it("accepts 200 open callable arguments and rejects 201", function()
        local seed, growth = {}, {}
        for index = 1, 100 do seed[index] = "actual" end
        for index = 1, 99 do growth[index] = "actual" end
        local source = string.format([[
            local function actual(x: integer): integer
                return x
            end

            local function seed(): (...: (integer) -> integer)
                return %s
            end

            local function grow99(
                ...: (integer) -> integer
            ): (...: (integer) -> integer)
                return %s, ...
            end

            local function grow1(
                ...: (integer) -> integer
            ): (...: (integer) -> integer)
                return actual, ...
            end

            local function produce200(): (...: (integer) -> integer)
                return grow1(grow99(seed()))
            end

            local function use(
                ...: (integer, value) -> value
            ): integer
                local total = 0
                local index = 1
                while index <= #... do
                    local callback = ...[index]
                    total = total
                        + (callback(1, "ignored") as integer)
                    index = index + 1
                end
                return total
            end

            local function forward(
                ...: (integer) -> integer
            ): integer
                return use(...)
            end

            local function add_one_then_forward(
                ...: (integer) -> integer
            ): integer
                return use(actual, ...)
            end

            function at_limit(): integer
                return forward(produce200())
            end

            function over_limit(): boolean
                do
                    add_one_then_forward(produce200())
                catch
                    return true
                end
                return false
            end
        ]], table.concat(seed, ", "), table.concat(growth, ", "))
        h.run_coder(source, [[
            assert(test.at_limit() == 200)
            assert(test.over_limit())
        ]])
    end)

    it("keeps captured and bound sources alive across both collector modes",
    function()
        h.run_coder([[
            record Counter
                count: integer;
            end

            function Counter:add(amount: integer): integer
                self.count = self.count + amount
                return self.count
            end

            interface Adder
                function add(amount: integer): integer
            end

            function captured(start: integer): (integer, value) -> value
                local count = start
                local source = function(amount: integer): integer
                    count = count + amount
                    return count
                end
                local adjusted: (integer, value) -> value = source
                return adjusted
            end

            function bound(start: integer): (integer, value) -> value
                local source: (integer) -> integer = Counter.new(start):add
                local adjusted: (integer, value) -> value = source
                return adjusted
            end

            function interface_bound(
                start: integer
            ): (integer, value) -> value
                local counter: Adder = Counter.new(start)
                local source: (integer) -> integer = counter:add
                local adjusted: (integer, value) -> value = source
                return adjusted
            end
        ]], [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for i = 1, 30 do
                    local captured = test.captured(i)
                    local bound = test.bound(i)
                    local interface_bound = test.interface_bound(i)
                    collectgarbage("collect")
                    assert(captured(1, "ignored") == i + 1)
                    assert(captured(2, "ignored") == i + 3)
                    assert(bound(3, "ignored") == i + 3)
                    assert(interface_bound(4, "ignored") == i + 4)
                end
            end
        ]])
    end)

    it("preserves non-Titan, mistagged, deferred, and max-upvalue fallbacks",
    function()
        -- Keep each capture use shallow: this is a MAXUPVAL fallback test, not
        -- a stress test for a C compiler's handling of one huge expression.
        local locals, additions = {}, {}
        for index = 1, 250 do
            locals[#locals + 1] = string.format(
                "local capture_%d = %d", index, index)
            additions[#additions + 1] =
                "total = total + capture_" .. tostring(index)
        end
        local source = string.format([[
            local function text(value_: string): string
                return value_ .. "!"
            end

            function adapt_dynamic(v: value): (value) -> value
                local source_: (integer) -> integer = v
                local adjusted: (value) -> value = source_
                return adjusted
            end

            function mistagged_source(): (string) -> string
                return text
            end

            function mistagged_view(): (value) -> value
                local dynamic: value = text
                local alleged: (integer) -> integer = dynamic
                local adjusted: (value) -> value = alleged
                return adjusted
            end

            function invoke_dynamic(carrier: value, argument: value): value
                local adjusted = adapt_dynamic(carrier)
                return adjusted(argument)
            end

            function invoke_mistagged(): value
                local adjusted = mistagged_view()
                return adjusted("kept")
            end

            local function saturated(): () -> integer
                %s
                return function(): integer
                    local total: integer = 0
                    %s
                    return total
                end
            end

            function max_upvalue_fallback(): boolean
                local source_ = saturated()
                local adjusted: (value) -> value = source_
                return source_ == adjusted
                    and (adjusted(nil) as integer) == 31375
            end
        ]], table.concat(locals, "\n                "),
            table.concat(additions, "\n                    "))
        h.run_coder(source, [[
            local lua = function(x) return x end
            local cfunction = math.abs
            local callable = setmetatable({}, {
                __call = function(_, x) return x end,
            })
            local deferred = {}
            assert(rawequal(test.adapt_dynamic(lua), lua))
            assert(test.adapt_dynamic(lua)(41) == 41)
            assert(test.invoke_dynamic(lua, 41) == 41)
            assert(rawequal(test.adapt_dynamic(cfunction), cfunction))
            assert(test.adapt_dynamic(cfunction)(-7) == 7)
            assert(test.invoke_dynamic(cfunction, -7) == 7)
            assert(rawequal(test.adapt_dynamic(callable), callable))
            assert(test.adapt_dynamic(callable)("kept") == "kept")
            assert(test.invoke_dynamic(callable, "kept") == "kept")
            local bad = test.adapt_dynamic(deferred)
            assert(rawequal(bad, deferred))
            assert(not pcall(bad, 1))
            assert(not pcall(test.invoke_dynamic, deferred, 1))
            assert(rawequal(
                test.mistagged_source(), test.mistagged_view()))
            assert(test.mistagged_view()("kept") == "kept!")
            assert(test.invoke_mistagged() == "kept!")
            assert(test.max_upvalue_fallback())
        ]])
    end)

    it("attributes adapter frames and conversion failures to the real cast",
    function()
        local output = h.compile_and_run([[
            local function actual(): value
                return {}
            end

            function run(): integer
                local adjusted: () -> integer = actual
                return adjusted()
            end
        ]], [[
            local titan = require "titan"
            assert(not pcall(test.run))
            print(titan.backtrace())
        ]])
        assert.matches("test%.titan:6: in %[%s*callable adapter", output)
        assert.matches("at test%.titan:6:%d+%]", output)
        assert.matches("in test%.run", output)
        assert.is_nil(output:find("callable_adapter_", 1, true))
        assert.is_nil(output:find("test.c", 1, true))
    end)

    it("fails closed on missing and malformed frozen adapter annotations",
    function()
        local source = [[
            local function actual(x: integer): integer
                return x
            end

            function probe()
                local adjusted: (integer, value) -> value = actual
            end
        ]]

        local tree = checked(source)
        local cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._adjustment._callable_adapter = nil
        local ok, err = pcall(
            coder.generate, "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("lacks its frozen adapter", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.dense.argument_count = 999
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("dense inventory", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.rooting.construction.result.condition =
            "always"
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("construction result root", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.strict_relay.parameters[1].index = 2
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("boundary slot", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.source = cast._callable_adapter.target
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("mismatched identity/signatures", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.arguments[1].kind = "ignore_argument"
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("mismatched kind", err)

        tree = checked(source)
        cast = find_function(tree, "probe").block.stats[1].exps[1]
        cast._callable_adapter.rebase_points[1].reason = "corrupt"
        ok, err = pcall(coder.generate,
            "test", tree, {}, driver.TITAN_ABI_VERSION)
        assert.is_false(ok)
        assert.matches("mismatched rebase point", err)
    end)
end)

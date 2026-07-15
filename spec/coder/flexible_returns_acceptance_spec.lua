local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"

local function generate(source)
    h.reset(true)
    local ast, perr = h.parse(source, "test.titan")
    assert.truthy(ast, perr)
    local _, errors = checker.check("test", ast, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", ast, {})
end

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    file:write(contents)
    file:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

local function literals(first, last)
    local out = {}
    for n = first, last do out[#out + 1] = tostring(n) end
    return table.concat(out, ", ")
end

describe("flexible-return runtime acceptance", function()
    after_each(function()
        if h.verbose then return end
        os.remove("test.c")
        os.remove("test.o")
        os.remove("test.so")
        os.execute("rm -rf test.dSYM test.so.dSYM")
    end)

    it("evaluates and ignores surplus Titan arguments for every callable form",
    function()
        h.run_coder([[
            trace: integer = 0

            record Receiver end

            function mark(digit: integer): integer
                trace = trace * 10 + digit
                return digit
            end

            function reset()
                trace = 0
            end

            function take(first: integer): integer
                return first
            end

            function Receiver.static_take(first: integer): integer
                return first
            end

            function Receiver:method_take(first: integer): integer
                return first
            end

            function direct_module(): integer
                reset()
                local result = take(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end

            function direct_static(): integer
                reset()
                local result = Receiver.static_take(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end

            function direct_method(): integer
                reset()
                local receiver = Receiver.new()
                local result = receiver:method_take(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end

            function bound_method(): integer
                reset()
                local receiver = Receiver.new()
                local f: (integer) -> integer = receiver:method_take
                local result = f(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end

            function lambda_call(): integer
                reset()
                local f: (integer) -> integer =
                    function(first: integer): integer
                        return first
                    end
                local result = f(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end

            function first_class_top(): integer
                reset()
                local f: (integer) -> integer = take
                local result = f(mark(1), mark(2), mark(3))
                return result * 1000 + trace
            end
        ]], [[
            for _, call in ipairs({
                test.direct_module,
                test.direct_static,
                test.direct_method,
                test.bound_method,
                test.lambda_call,
                test.first_class_top,
            }) do
                assert(call() == 1123)
            end
        ]])
    end)

    it("adjusts a trailing Titan result list to the exact fixed C arity",
    function()
        with_header([[
            static int flex_accept_add(int left, int right) {
                return left + right;
            }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function triple(): (integer, integer, integer)
                    return 5, 7, 99
                end

                function strict_sum(): integer
                    return c.flex_accept_add(triple()) as integer
                end
            ]], [[
                assert(test.strict_sum() == 12)
            ]])
        end)
    end)

    it("enforces directional input and result compatibility at runtime",
    function()
        h.run_coder([[
            function short_input(first: integer): integer
                return first
            end

            function wide_fixed(): (integer, integer, integer)
                return 1, 2, 3
            end

            function projected(present: boolean): (...: integer)
                if present then return 7, 8 end
                return
            end

            function mixed(): (integer, integer, ...: integer)
                return 4, 5, 6, 7
            end

            function call_short_input(): integer
                local f: (integer, string) -> integer = short_input
                return f(41, "ignored")
            end

            function call_narrow_result(): integer
                local f: () -> integer = wide_fixed
                return f()
            end

            function optional_projection(present: boolean): integer?
                local f: (boolean) -> integer? = projected
                return f(present)
            end

            function required_projection(present: boolean): integer
                local f: (boolean) -> integer = projected
                return f(present)
            end

            function consume_fixed_suffix(): (integer, ...: integer)
                local f: () -> (integer, ...: integer) = wide_fixed
                return f()
            end

            function consume_fixed_and_flexible(): (integer, ...: integer)
                local f: () -> (integer, ...: integer) = mixed
                return f()
            end
        ]], [[
            assert(test.call_short_input() == 41)
            assert(test.call_narrow_result() == 1)
            assert(test.optional_projection(false) == nil)
            assert(test.optional_projection(true) == 7)
            assert(test.required_projection(true) == 7)

            local ok, err = pcall(test.required_projection, false)
            assert(not ok)
            assert(tostring(err):find("expected integer but found nil", 1, true), err)

            local a, b, c = test.consume_fixed_suffix()
            assert(select("#", test.consume_fixed_suffix()) == 3)
            assert(a == 1 and b == 2 and c == 3)

            local d, e, f, g = test.consume_fixed_and_flexible()
            assert(select("#", test.consume_fixed_and_flexible()) == 4)
            assert(d == 4 and e == 5 and f == 6 and g == 7)
        ]])
    end)

    it("preserves simultaneous input and output tails on exact and generic paths",
    function()
        local source = [[
            function bounce(probe: () -> integer,
                            ...: integer): (integer, ...: integer)
                return probe(), ...
            end

            function exact(probe: () -> integer,
                           ...: integer): (integer, ...: integer)
                return bounce(probe, ...)
            end

            function generic(f: (() -> integer, ...: integer)
                                -> (integer, ...: integer),
                             probe: () -> integer,
                             ...: integer): (integer, ...: integer)
                return f(probe, ...)
            end

            function contextual(f: value, probe: () -> integer,
                                ...: integer): (integer, ...: integer)
                return f(probe, ...)
            end
        ]]

        local csrc = generate(source)
        assert.match("TitanVargInteger %*_varargs, int _start, TitanVargInteger %*_flexout, int _flexwant",
            csrc)
        assert.match("if %(ttisCclosure%(", csrc)
        assert.match("luaD_callnoyield%(L, restorestack%(L, _vc_func%), LUA_MULTRET%)",
            csrc)

        h.run_coder(source, h.DEPTH_PROBE .. [[
            local function lua_bounce(probe, ...)
                local result = probe()
                return result, ...
            end

            local native_depth, x, y = test.contextual(
                test.bounce, depth, 11, 12)
            assert(x == 11 and y == 12)

            local generic_depth, p, q = test.contextual(
                lua_bounce, depth, 13, 14)
            assert(p == 13 and q == 14)
            assert(generic_depth > native_depth,
                "native=" .. native_depth .. " generic=" .. generic_depth)

            local exact_depth, a, b = test.exact(depth, 21, 22)
            assert(exact_depth == native_depth and a == 21 and b == 22)

            local via_generic, c, d = test.generic(
                lua_bounce, depth, 31, 32)
            assert(via_generic == generic_depth and c == 31 and d == 32)
        ]])
    end)

    it("accepts 200 and rejects 201 actual open values at both open sinks",
    function()
        -- Each written expression list stays at or below Titan's independent
        -- 100-element syntax limit. These generated, acyclic producers assemble
        -- the boundary values without a deep recursive runtime chain.
        local source = [[
            function tail100(): (...: integer)
                return ]] .. literals(101, 200) .. [[
            end

            function tail101(): (...: integer)
                return 100, tail100()
            end

            function values200(): (...: integer)
                return ]] .. literals(1, 99) .. [[, tail101()
            end

            function values201(): (...: integer)
                return 0, values200()
            end

            function count(...: integer): integer
                return #...
            end

            function array200(): {integer}
                return { values200() }
            end

            function array201(): {integer}
                return { values201() }
            end

            function arguments200(): integer
                return count(values200())
            end

            function arguments201(): integer
                return count(values201())
            end
        ]]

        h.run_coder(source, [[
            local values = test.array200()
            assert(#values == 200 and values[1] == 1 and values[200] == 200)
            assert(test.arguments200() == 200)

            local array_ok, array_err = pcall(test.array201)
            assert(not array_ok)
            assert(tostring(array_err):find("too many flexible return values", 1, true),
                array_err)

            local args_ok, args_err = pcall(test.arguments201)
            assert(not args_ok)
            assert(tostring(args_err):find("too many flexible return values", 1, true),
                args_err)
        ]])
    end)
end)

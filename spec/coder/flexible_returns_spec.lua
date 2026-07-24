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

describe("flexible return code generation", function()
    after_each(function()
        if h.verbose then return end
        os.remove("test.c")
        os.remove("test.o")
        os.remove("test.so")
        for _, name in ipairs({ "flex_provider", "flex_consumer" }) do
            os.remove(name .. ".c")
            os.remove(name .. ".o")
            os.remove(name .. ".so")
        end
        os.execute("rm -rf test.dSYM")
        os.execute("rm -rf flex_provider.dSYM flex_consumer.dSYM")
    end)

    it("appends the flexible pair without changing fixed-only signatures", function()
        local csrc = generate([[
            function fixed(n: integer): (integer, string)
                return n, "fixed"
            end

            function flexible(n: integer): (integer, string, ...: boolean)
                return n, "flexible", true
            end
        ]])

        assert.match("lua_Integer test_fixed_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, lua_Integer _param_n, TString%* %*_outparam_2%)",
            csrc)
        assert.match("lua_Integer test_flexible_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, lua_Integer _param_n, TString%* %*_outparam_2, TitanVargBoolean %*_flexout, int _flexwant%)",
            csrc)
    end)

    it("uses caller-owned typed storage for a finite exact projection", function()
        local csrc = generate([[
            function values(): (integer, ...: string)
                return 7, "a", "b"
            end

            function use(): string?
                local n: integer, s: string? = values()
                return s
            end
        ]])

        assert.match("TString%* _flexargs_%d+%[1%] = {0};", csrc)
        assert.match("TitanVargString _flexdesc_%d+ = { 0, _flexargs_%d+ };",
            csrc)
        assert.match("test_values_titan%([^;]-, &_flexdesc_%d+, 1%)", csrc)
        assert.match("if %(_flexdesc_%d+%.n_args >= 1%)", csrc)
        assert.match("setnilvalue%(&_tmp_%d+%);", csrc)
    end)

    it("initializes an empty flexible fallthrough", function()
        local csrc = generate([[
            function none(): (...: integer)
            end
        ]])
        assert.match("_flexout%->n_args = 0;%s+L%->top%.p = _base;%s+return;",
            csrc)
    end)

    it("evaluates a fixed-only surplus return without writing a fake outparam", function()
        local csrc = generate([[
            function effect(): ()
            end
            function one(): integer
                return 1, effect()
            end
        ]])
        local _, calls = csrc:gsub("test_effect_titan%(L, _mod, NULL%)", "")
        assert.equal(1, calls)
        assert.not_match("_outparam_2", csrc:match(
            "lua_Integer test_one_titan%b()%s*{.-\n%s*}"))
    end)

    it("preserves Lua finite and MULTRET demand through the wrapper", function()
        run_coder([[
            function ints(full: boolean): (...: integer)
                if full then
                    return 10, 20, 30
                end
                return
            end

            function projected(full: boolean): (integer?, integer?)
                return ints(full)
            end
        ]], [[
            assert(select('#', test.ints(false)) == 0)
            assert(select('#', test.ints(true)) == 3)
            local a, b, c = test.ints(true)
            assert(a == 10 and b == 20 and c == 30)
            local x, y = test.projected(true)
            assert(x == 10 and y == 20)
            x, y = test.projected(false)
            assert(x == nil and y == nil)
        ]])
    end)

    it("accepts the maximum finite Lua wrapper demand", function()
        local names = {}
        for i = 1, 200 do names[i] = "v" .. i end
        local lua_test = "local " .. table.concat(names, ", ")
            .. " = test.one()\n"
            .. "assert(v1 == 42 and v2 == nil and v200 == nil)"
        run_coder([[
            function one(): (...: integer)
                return 42
            end
        ]], lua_test)
    end)

    it("accepts the maximum finite exact Titan demand", function()
        local decls = {}
        for i = 1, 200 do decls[i] = "v" .. i .. ": integer?" end
        local source = [[
            function one(): (...: integer)
                return 42
            end

            function internal(): boolean
                local ]] .. table.concat(decls, ", ") .. [[ = one()
                if not v1 then return false end
                if v2 then return false end
                if v200 then return false end
                return (v1 as integer) == 42
            end
        ]]
        run_coder(source, [[
            assert(test.internal())
        ]])
    end)

    it("reserves the maximum finite generic result area", function()
        local decls = {}
        for i = 1, 200 do decls[i] = "v" .. i .. ": integer?" end
        local source = [[
            function generic200(f: () -> (...: integer)): boolean
                local ]] .. table.concat(decls, ", ") .. [[ = f()
                return not v1 and not v200
            end
        ]]
        run_coder(source, [[
            assert(test.generic200(function() end))
        ]])
    end)

    it("uses Lua's finite 250-result boundary only for finite generic calls", function()
        local function typelist(n)
            local out = {}
            for i = 1, n do out[i] = "integer?" end
            return table.concat(out, ", ")
        end

        local fixed50 = typelist(50)
        local fixed51 = typelist(51)
        local finite250 = typelist(250)
        local finite251 = typelist(251)
        local nils51 = {}
        for i = 1, 51 do nils51[i] = "nil" end
        local source = [[
            function actual(): (]] .. fixed51 .. [[, ...: integer?)
                return ]] .. table.concat(nils51, ", ") .. [[
            end

            function finite250(f: () -> (]] .. fixed50
                .. [[, ...: integer?)): (]] .. finite250 .. [[)
                return f()
            end

            function open251(f: () -> (]] .. fixed51
                .. [[, ...: integer?)): (]] .. fixed51 .. [[, ...: integer?)
                return f()
            end

            function direct251(): (]] .. finite251 .. [[)
                return actual()
            end
        ]]

        local csrc = h.compile_and_read_c(source)
        assert.match("luaD_callnoyield%(L, restorestack%(L, _vc_func%), 250%);",
            csrc)
        assert.match("luaD_callnoyield%(L, restorestack%(L, _vc_func%), LUA_MULTRET%);%s+if %(L%->ci%->top%.p < L%->top%.p%) L%->ci%->top%.p = L%->top%.p;",
            csrc)

        -- The ordinary function-value call uses the largest encodable finite
        -- request. The direct native call remains legal with a 251-slot fixed
        -- sink because it does not encode a finite VM request.
        local ok, err = h.call("test", [[
            local ok, first = pcall(test.finite250, function() end)
            assert(ok and first == nil)
            ok, first = pcall(test.direct251)
            assert(ok and first == nil)

            local values = {}
            for i = 1, 251 do values[i] = i end
            local got = table.pack(test.open251(function()
                return table.unpack(values, 1, 251)
            end))
            assert(got.n == 251 and got[1] == 1 and got[251] == 251)
        ]])
        assert.truthy(ok, err)
    end)

    it("forwards exact open runs under inherited finite and open demand", function()
        run_coder([[
            function inner(): (...: integer)
                return 1, 2, 3
            end

            function outer(): (...: integer)
                return inner()
            end

            function first(): integer
                local n: integer? = outer()
                return n as integer
            end
        ]], [[
            assert(test.first() == 1)
            local a, b = test.outer()
            assert(a == 1 and b == 2)
            assert(select("#", test.outer()) == 3)
        ]])
    end)

    it("feeds open runs into variadic calls and array constructors", function()
        run_coder([[
            function values(): (integer, ...: integer)
                return 2, 3, 4
            end

            function checksum(...: integer): integer
                local total: integer = #...
                for i = 1, #... do
                    total = total * 10 + ...[i]
                end
                return total
            end

            function exact_args(): integer
                return checksum(9, values())
            end

            function generic_args(f: (...: integer) -> integer): integer
                return f(9, values())
            end

            function exact_array(): {integer}
                return { 9, values() }
            end

            function generic_array(f: () -> (...: integer)): {integer}
                return { 9, f() }
            end
        ]], [[
            assert(test.exact_args() == 49234)
            assert(test.generic_args(function(...)
                local total = select("#", ...)
                for i = 1, select("#", ...) do
                    total = total * 10 + select(i, ...)
                end
                return total
            end) == 49234)

            local exact = test.exact_array()
            assert(#exact == 4 and exact[1] == 9 and exact[2] == 2
                and exact[3] == 3 and exact[4] == 4)
            local generic = test.generic_array(function() return 2, 3, 4 end)
            assert(#generic == 4 and generic[1] == 9 and generic[2] == 2
                and generic[3] == 3 and generic[4] == 4)
        ]])
    end)

    it("uses the exact finite ABI for top-level, lambda, method, and bound values", function()
        run_coder([[
            record Box
                n: integer;
            end

            function pair(): (...: integer)
                return 3, 4
            end

            function Box:values(): (...: integer)
                return self.n, self.n + 1
            end

            function top_value(): integer
                local f: () -> (...: integer) = pair
                local a: integer?, b: integer? = f()
                return (a as integer) * 10 + (b as integer)
            end

            function discard_value(): integer
                local f: () -> (...: integer) = pair
                f()
                return 12
            end

            function lambda_value(): integer
                local f: () -> (...: integer) = function(): (...: integer)
                    return 5, 6
                end
                local a: integer?, b: integer? = f()
                return (a as integer) * 10 + (b as integer)
            end

            function method_direct(): integer
                local box = Box.new(7)
                local a: integer?, b: integer? = box:values()
                return (a as integer) * 10 + (b as integer)
            end

            function bound_value(): integer
                local box = Box.new(9)
                local f: () -> (...: integer) = box:values
                local a: integer?, b: integer? = f()
                return (a as integer) * 10 + (b as integer)
            end
        ]], [[
            assert(test.top_value() == 34)
            assert(test.discard_value() == 12)
            assert(test.lambda_value() == 56)
            assert(test.method_direct() == 78)
            assert(test.bound_value() == 100)
        ]])
    end)

    it("keeps every exact flexible callable form off the Lua call path", function()
        run_coder([[
            record Runner end

            function top(p: () -> integer): (...: integer)
                return p()
            end

            function Runner.static_probe(p: () -> integer): (...: integer)
                return p()
            end

            function Runner:method_probe(p: () -> integer): (...: integer)
                return p()
            end

            function call_value(g: (() -> integer) -> (...: integer),
                                p: () -> integer): integer
                local n: integer? = g(p)
                return n as integer
            end

            function direct_top(p: () -> integer): integer
                local n: integer? = top(p)
                return n as integer
            end

            function direct_static(p: () -> integer): integer
                local n: integer? = Runner.static_probe(p)
                return n as integer
            end

            function direct_method(p: () -> integer): integer
                local r = Runner.new()
                local n: integer? = r:method_probe(p)
                return n as integer
            end

            function exact_top_value(p: () -> integer): integer
                return call_value(top, p)
            end

            function exact_bound_value(p: () -> integer): integer
                local r = Runner.new()
                return call_value(r:method_probe, p)
            end

            function exact_lambda_value(p: () -> integer): integer
                local f: (() -> integer) -> (...: integer) =
                    function(q: () -> integer): (...: integer)
                        return q()
                    end
                return call_value(f, p)
            end

            function slow(g: (() -> integer) -> (...: integer),
                          p: () -> integer): integer
                return call_value(g, p)
            end
        ]], h.DEPTH_PROBE .. [[
            local native_depth = test.direct_top(depth)
            assert(test.direct_static(depth) == native_depth)
            assert(test.direct_method(depth) == native_depth)
            assert(test.exact_top_value(depth) == native_depth)
            assert(test.exact_bound_value(depth) == native_depth)
            assert(test.exact_lambda_value(depth) == native_depth)

            local slow_depth = test.slow(slow_g, depth)
            assert(slow_depth > native_depth,
                ("native=") .. native_depth .. (" slow=") .. slow_depth)
        ]])
    end)

    it("uses finite Lua-stack demand for compatible generic callables", function()
        run_coder([[
            function invoke(f: () -> (...: integer)): integer
                local a: integer?, b: integer? = f()
                if not a then return -1 end
                if not b then return a as integer end
                return (a as integer) * 10 + (b as integer)
            end
        ]], [[
            assert(test.invoke(function() return 8, 9, 10 end) == 89)
            assert(test.invoke(function() return 7 end) == 7)
            assert(test.invoke(function() end) == -1)
        ]])
    end)

    it("preserves raw generic counts, explicit nils, and callable kinds", function()
        run_coder([[
            function forward(f: () -> (...: value)): (...: value)
                return f()
            end
        ]], [[
            assert(select("#", test.forward(function() end)) == 0)
            assert(select("#", test.forward(function() return nil end)) == 1)
            local n, a, b, c = select("#", test.forward(function()
                return 1, nil, 3
            end)), test.forward(function() return 1, nil, 3 end)
            assert(n == 3 and a == 1 and b == nil and c == 3)

            local thread, ismain = test.forward(coroutine.running)
            assert(thread == coroutine.running() and ismain == true)

            local callable = setmetatable({}, {
                __call = function() return 4, nil, 6 end,
            })
            local x, y, z = test.forward(callable)
            assert(x == 4 and y == nil and z == 6)
            assert(not pcall(test.forward, {}))

            local many = {}
            for i = 1, 201 do many[i] = i end
            local function too_many()
                return table.unpack(many, 1, 201)
            end
            local first, second = test.forward(too_many)
            assert(first == 1 and second == 2)
            assert(not pcall(function() return test.forward(too_many) end))
        ]])
    end)

    it("keeps the caller frame open for 200 generic MULTRET values", function()
        local csrc = generate([[
            function forward(f: () -> (...: string)): (...: string)
                return f()
            end
        ]])
        assert.match("luaD_callnoyield%(L, restorestack%(L, _vc_func%), LUA_MULTRET%);%s+if %(L%->ci%->top%.p < L%->top%.p%) L%->ci%->top%.p = L%->top%.p;",
            csrc)

        run_coder([[
            function forward(f: () -> (...: string)): (...: string)
                return f()
            end
        ]], [[
            local values = {}
            for i = 1, 200 do values[i] = string.rep(string.char(64 + (i % 26)), 64) end
            local function many() return table.unpack(values, 1, 200) end

            local got = { test.forward(many) }
            assert(#got == 200 and got[1] == values[1] and got[200] == values[200])

            local callable = setmetatable({}, { __call = many })
            got = { test.forward(callable) }
            assert(#got == 200 and got[1] == values[1] and got[200] == values[200])
        ]])
    end)

    it("unwinds a failing open light-C call before the next call", function()
        run_coder([[
            function forward(f: () -> (...: value)): (...: value)
                do
                    return f()
                catch
                    return "caught"
                end
            end
        ]], [[
            assert(test.forward(error) == "caught")
            assert(test.forward(function() return "after" end) == "after")
            assert(test.forward(error) == "caught")
        ]])
    end)

    it("recovers after open result conversion and cap failures", function()
        run_coder([[
            function recover(f: () -> (...: integer)): (...: integer)
                do
                    return f()
                catch
                    return 77
                end
            end
        ]], [[
            assert(test.recover(function() return nil end) == 77)
            local a, b = test.recover(function() return 4, 5 end)
            assert(a == 4 and b == 5)

            local values = {}
            for i = 1, 201 do values[i] = i end
            local function many()
                return table.unpack(values, 1, 201)
            end
            local caught = table.pack(test.recover(many))
            assert(caught.n == 1 and caught[1] == 77)

            a, b = test.recover(function() return 8, 9 end)
            assert(a == 8 and b == 9)
        ]])
    end)

    it("converts and caps open inputs before a generic variadic call", function()
        run_coder([[
            function ints(): (...: integer)
                return 1, 2, 3
            end

            function values(): (...: value)
                return 4, "bad"
            end

            function floats(f: (...: float) -> integer): integer
                return f(ints())
            end

            function narrowed(f: (...: integer) -> integer): integer
                return f(values())
            end

            function capped(f: (...: integer) -> integer,
                            ...: integer): integer
                return f(0, ...)
            end
        ]], [[
            assert(test.floats(function(...)
                assert(select("#", ...) == 3)
                assert(math.type(select(1, ...)) == "float")
                assert(math.type(select(2, ...)) == "float")
                assert(math.type(select(3, ...)) == "float")
                return 123
            end) == 123)

            local invoked = false
            assert(not pcall(test.narrowed, function(...)
                invoked = true
                return 0
            end))
            assert(not invoked)

            local args = { function(...) return select("#", ...) end }
            for i = 1, 200 do args[i + 1] = i end
            assert(not pcall(test.capped, table.unpack(args, 1, 201)))
        ]])
    end)

    it("preserves mixed fixed prefixes across exact and generic open calls", function()
        run_coder([[
            function mixed(full: boolean): (integer, ...: integer)
                if full then return 1, 2, 3 end
                return 1
            end

            function exact(full: boolean): (integer, ...: integer)
                return mixed(full)
            end

            function generic(f: () -> (value, ...: value)): (value, ...: value)
                return f()
            end
        ]], [[
            assert(select("#", test.exact(false)) == 1)
            local a, b, c = test.exact(true)
            assert(a == 1 and b == 2 and c == 3)
            assert(select("#", test.exact(true)) == 3)

            assert(select("#", test.generic(function() end)) == 1)
            assert(select(1, test.generic(function() end)) == nil)
            local x, y, z = test.generic(function() return 4, nil, 6 end)
            assert(x == 4 and y == nil and z == 6)
            assert(select("#", test.generic(function() return 4, nil, 6 end)) == 3)
        ]])
    end)

    it("keeps exact finite truncation separate from generic open forwarding", function()
        -- Keep each written expression list within Titan's independent
        -- 100-element parser limit while avoiding the 200-deep native recursion
        -- that collides with Lua's C-call guard in this boundary test.
        local prefix99 = {}
        for i = 1, 99 do prefix99[i] = "1" end
        with_header([[
            typedef struct lua_State lua_State;

            static int flex_request_anchor(void) { return 0; }

            int flex_return_zero(lua_State *L) {
                (void)L;
                return 0;
            }

            int flex_return_nil(lua_State *L) {
                lua_pushnil(L);
                return 1;
            }

            int flex_return_201(lua_State *L) {
                luaL_checkstack(L, 201, "flex_return_201");
                for (int i = 1; i <= 201; i++) lua_pushinteger(L, i);
                return 201;
            }

            static int flex_request_results(lua_State *L) {
                int nresults = (int)lua_tointeger(L, 2);
                luaL_checktype(L, 1, 6); /* LUA_TFUNCTION */
                lua_settop(L, 1);
                lua_call(L, 0, nresults);
                if (nresults == 200) {
                    int ok = lua_gettop(L) == 200
                        && lua_tointeger(L, 1) == 1
                        && lua_tointeger(L, 200) == 1;
                    lua_pushboolean(L, ok);
                    return 1;
                }
                return lua_gettop(L);
            }

            int luaopen_flex_request(lua_State *L) {
                lua_pushcfunction(L, flex_request_results);
                return 1;
            }
        ]], function(header)
            run_coder([[
            local c = foreign import "]] .. header .. [["

            function request_anchor(): integer
                return c.flex_request_anchor() as integer
            end

            function exact_base(): (...: integer)
                return 1, 1
            end

            function exact_tail(): (...: integer)
                return ]] .. table.concat(prefix99, ", ") .. [[, exact_base()
            end

            function exact200(): (...: integer)
                return ]] .. table.concat(prefix99, ", ") .. [[, exact_tail()
            end

            function huge_base(): (...: integer)
                return 1, 1, 1
            end

            function huge_tail(): (...: integer)
                return ]] .. table.concat(prefix99, ", ") .. [[, huge_base()
            end

            function huge(): (...: integer)
                return ]] .. table.concat(prefix99, ", ") .. [[, huge_tail()
            end

            function nonexact(): (...: value)
                local boxed: value = huge
                local f: () -> (...: value) = boxed
                return f()
            end

            function finite(): integer
                local a: value, b: value = nonexact()
                return (a as integer) + (b as integer)
            end

            function maybe_nil(present: boolean): (...: value)
                if present then return nil end
                return
            end

            function typed_maybe_nil(present: boolean): (...: integer)
                local boxed: value = maybe_nil
                local f: (boolean) -> (...: integer) = boxed
                return f(present)
            end

            function c_forward(f: () -> (...: value)): (...: value)
                return f()
            end
        ]], [[
            local exact_ok, exact_count = pcall(function()
                return select("#", test.exact200())
            end)
            assert(exact_ok, "exact200: " .. tostring(exact_count))
            assert(exact_count == 200)
            local exact_a, exact_b
            local finite_huge_ok, finite_huge_err = pcall(function()
                exact_a, exact_b = test.huge()
            end)
            assert(finite_huge_ok, "finite huge: " .. tostring(finite_huge_err))
            assert(exact_a == 1 and exact_b == 1)
            assert(not pcall(function() return test.huge() end))

            local a, b
            local finite_nonexact_ok, finite_nonexact_err = pcall(function()
                a, b = test.nonexact()
            end)
            assert(not finite_nonexact_ok)
            assert(tostring(finite_nonexact_err):find(
                "too many flexible return values", 1, true),
                tostring(finite_nonexact_err))
            assert(not pcall(test.finite))
            assert(test.request_anchor() == 0)
            local request_results = assert(package.loadlib(
                "./test.so", "luaopen_flex_request"))()
            local request_ok, request_err = pcall(
                request_results, test.nonexact, 200)
            assert(not request_ok)
            assert(tostring(request_err):find(
                "too many flexible return values", 1, true),
                tostring(request_err))
            request_ok, request_err = pcall(
                request_results, test.nonexact, 201)
            assert(not request_ok)
            assert(tostring(request_err):find(
                "too many flexible results requested from Titan function nonexact (201, max 200)",
                1, true), tostring(request_err))
            assert(not pcall(function() return test.nonexact() end))

            local c_zero = assert(package.loadlib(
                "./test.so", "flex_return_zero"))
            local c_nil = assert(package.loadlib(
                "./test.so", "flex_return_nil"))
            local c_many = assert(package.loadlib(
                "./test.so", "flex_return_201"))
            assert(select("#", test.c_forward(c_zero)) == 0)
            assert(select("#", test.c_forward(c_nil)) == 1)
            local c_first, c_second = test.c_forward(c_many)
            assert(c_first == 1 and c_second == 2)
            assert(not pcall(function() return test.c_forward(c_many) end))

            local absent = test.typed_maybe_nil(false)
            assert(absent == nil)
            assert(not pcall(function()
                local explicit_nil = test.typed_maybe_nil(true)
            end))
            ]])
        end)
    end)

    it("clamps projected input dots and forwards their open suffix", function()
        run_coder([[
            function count_after_head(head: integer?, ...: integer): integer
                return #...
            end

            function exact(...: integer): integer
                return count_after_head(...)
            end

            function generic(f: (integer?, ...: integer) -> integer,
                             ...: integer): integer
                return f(...)
            end
        ]], [[
            assert(test.exact() == 0)
            assert(test.exact(5) == 0)
            assert(test.exact(5, 6, 7) == 2)
            local count = function(_, ...) return select("#", ...) end
            assert(test.generic(count) == 0)
            assert(test.generic(count, 5) == 0)
            assert(test.generic(count, 5, 6, 7) == 2)
        ]])
    end)

    it("converts and roots flexible array tails", function()
        run_coder([[
            function ints(): (...: integer)
                return 1, 2, 3
            end

            function floats(): {float}
                return { 0.5, ints() }
            end

            function rep(ch: string, n: integer): string
                local out: string = ""
                local i = 1
                while i <= n do
                    out = out .. ch
                    i = i + 1
                end
                return out
            end

            function strings(): (...: string)
                return rep("a", 11), rep("b", 13), rep("c", 17)
            end

            function rooted(): {string}
                return { rep("p", 7), strings() }
            end

            function generic(f: () -> (...: integer)): {float}
                return { 0.25, f() }
            end
        ]], [[
            local fs = test.floats()
            assert(#fs == 4 and fs[1] == 0.5 and fs[2] == 1.0
                and fs[3] == 2.0 and fs[4] == 3.0)
            local gs = test.generic(function() return 4, 5, 6 end)
            assert(#gs == 4 and gs[1] == 0.25 and gs[2] == 4.0
                and gs[3] == 5.0 and gs[4] == 6.0)

            collectgarbage("generational")
            local rooted = test.rooted()
            for _ = 1, 50 do collectgarbage("step") end
            collectgarbage("collect")
            assert(#rooted == 4 and #rooted[1] == 7 and #rooted[2] == 11
                and #rooted[3] == 13 and #rooted[4] == 17)
        ]])
    end)

    it("freezes parenthesized foreign calls in argument order", function()
        with_header([[
            static int flex_order_state = 0;
            static int flex_order_reset(void) { flex_order_state = 0; return 0; }
            static int flex_order_bump(void) { return ++flex_order_state; }
            static int flex_order_read(void) { return flex_order_state; }
        ]], function(header)
            run_coder([[
                local c = foreign import "]] .. header .. [["

                function pair(first: integer, second: integer): integer
                    return first * 10 + second
                end

                function ordered(): integer
                    c.flex_order_reset()
                    return pair((c.flex_order_bump()),
                        c.flex_order_read())
                end
            ]], [[
                local got = test.ordered()
                assert(got == 11, "ordered=" .. tostring(got))
            ]])
        end)
    end)

    it("preserves flexible declarations and exact values across modules", function()
        local ok, err = h.generate_modules({
            flex_provider = [[
                function pair(): (...: integer)
                    return 11, 12
                end
            ]],
            flex_consumer = [[
                local provider = import "flex_provider"

                function direct(): integer
                    local a: integer?, b: integer? = provider.pair()
                    return (a as integer) * 10 + (b as integer)
                end

                function via_value(): integer
                    local f: () -> (...: integer) = provider.pair
                    local a: integer?, b: integer? = f()
                    return (a as integer) * 10 + (b as integer)
                end
            ]],
        }, "flex_consumer")
        assert.truthy(ok, err)
        local rok, out = h.call("flex_consumer", [[
            assert(flex_consumer.direct() == 122)
            assert(flex_consumer.via_value() == 122)
        ]])
        assert.truthy(rok, out)
    end)

    it("executes adjusted surplus expressions and passes synthesized inputs", function()
        run_coder([[
            local hits: integer = 0

            function zero(): ()
                hits = hits + 1
            end

            function nil_effect(): nil
                zero()
                return nil
            end

            function take(a: integer, b: integer?): integer
                if b then return -1 end
                return hits + a - 1
            end

            function stop(): integer?
                return nil
            end

            function exercise(): integer
                local n: integer = 1, zero()
                if hits ~= 1 then return -11 end
                n = 2, zero()
                if hits ~= 2 then return -12 end
                local xs: {integer} = { 1, zero() }
                if #xs ~= 1 or hits ~= 3 then return -13 end
                for _: integer in stop, nil, nil, nil, zero() do
                end
                if hits ~= 4 then return -14 end
                return take(1, nil_effect())
            end

            function mapped_value(): integer
                local f: (integer, integer?) -> integer = take
                return f(1, nil_effect())
            end

            function return_surplus(): integer
                return hits, zero()
            end

            function get_hits(): integer
                return hits
            end
        ]], [[
            local exercised = test.exercise()
            assert(exercised == 5,
                "exercise=" .. tostring(exercised) .. ", hits=" .. tostring(test.get_hits()))
            assert(test.return_surplus() == 5)
            assert(test.get_hits() == 6)
            assert(test.mapped_value() == 7)
            assert(test.take(1, nil, 99) == 7)
        ]])
    end)
end)

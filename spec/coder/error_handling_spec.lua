-- End-to-end coverage for the `raise <exp>` statement (error-handling Phase 2).
--
-- `raise <exp>` evaluates its operand to a Lua value, pushes it as the error
-- object, and calls lua_error(L). The entry wrapper has errorhandler installed
-- on L->errfunc, so the longjmp through lua_error builds the unified Lua+Titan
-- trace (the same machinery the libbacktrace_spec exercises). A `raise` from a
-- Titan function caught by a Lua `pcall` therefore surfaces the raised value as
-- the pcall error and a trace mentioning the Titan native frame.
--
-- catch/finally parse (parser_spec) but are not yet compiled: the checker rejects
-- a StatTry with "catch/finally is not yet implemented", and a bare `raise` (a
-- re-raise, only valid inside a catch) is likewise a checker error for now.
local checker = require 'titan-compiler.checker'
local h = require 'spec.support.helpers'

local parse = h.parse
local compile = h.compile

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

-- Compile `titan_code` as module "test" (parsed under the test.titan chunkname
-- so #line carries the .titan path), then run `lua_test` under stock Lua with
-- `test` and `titan` available; returns the script's stdout.
local function compile_and_run(titan_code, lua_test)
    h.reset()
    local ast, perr = parse(titan_code, "test.titan")
    assert.truthy(ast, perr)
    local _, errs = checker.check("test", ast, titan_code, "test.titan")
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = compile("test", ast)
    assert.truthy(ok, err)

    local script = os.tmpname()
    local sf = assert(io.open(script, "w"))
    sf:write(lua_test)
    sf:close()
    local f = assert(io.popen("lua-5.5.0/src/lua -l test " .. script))
    local out = f:read("*a")
    f:close()
    os.remove(script)
    return out
end

describe("raise <exp> (error-handling Phase 2)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("raises a string error caught by a Lua pcall", function()
        local out = compile_and_run([[
            function boom(): integer
                raise "kaboom"
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.boom)
            assert(not ok, "expected boom to fail")
            assert(err == "kaboom", "wrong error value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("surfaces the message with a unified trace mentioning the Titan frame", function()
        local out = compile_and_run([[
            function inner(): integer
                raise "deep failure"
                return 0
            end
            function outer(): integer
                return inner()
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.outer)
            assert(not ok)
            assert(err == "deep failure", "wrong error value: " .. tostring(err))
            local bt = titan.backtrace()
            assert(bt:find("stack traceback:", 1, true), "missing trace header\n" .. bt)
            -- the raising Titan function symbolizes as a native frame
            assert(bt:find("test_inner_titan", 1, true), "missing inner frame\n" .. bt)
            assert(bt:find("test_outer_titan", 1, true), "missing outer frame\n" .. bt)
            -- attributed to the raise's .titan line via #line, not the generated .c
            assert(bt:find("test%.titan:%d+: in test_inner_titan"),
                   "inner frame not attributed to test.titan:<line>\n" .. bt)
            assert(not bt:find("test%.c:%d+: in test_"),
                   "native frame still attributed to generated .c\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("raises a non-string value (raised value reaches the handler verbatim)", function()
        local out = compile_and_run([[
            function boom(): integer
                local t: {integer} = {1, 2, 3}
                raise t
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.boom)
            assert(not ok, "expected boom to fail")
            assert(type(err) == "table", "expected table error, got " .. type(err))
            assert(err[2] == 2, "wrong table contents")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("raises a computed value expression", function()
        local out = compile_and_run([[
            function boom(n: integer): integer
                raise "code " .. n
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.boom, 42)
            assert(not ok)
            assert(err == "code 42", "wrong error value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects a bare raise at compile time", function()
        h.reset()
        local errs = h.check_errs([[
            function boom(): integer
                raise
                return 0
            end
        ]])
        assert.truthy(#errs > 0, "bare raise should be a checker error")
        assert.match("bare 'raise'", table.concat(errs, "\n"))
    end)

    it("rejects a catch/finally block at compile time (not yet implemented)", function()
        h.reset()
        local errs = h.check_errs([[
            function boom(): integer
                do
                    raise "x"
                catch
                    return 0
                end
                return 0
            end
        ]])
        assert.truthy(#errs > 0, "catch/finally should be a checker error")
        assert.match("catch/finally is not yet implemented", table.concat(errs, "\n"))
    end)
end)

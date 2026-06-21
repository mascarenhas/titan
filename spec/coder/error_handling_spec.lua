-- End-to-end coverage for the `raise <exp>` statement (error-handling Phase 2).
--
-- `raise <exp>` evaluates its operand to a Lua value, pushes it as the error
-- object, and calls lua_error(L). The entry wrapper has errorhandler installed
-- on L->errfunc, so the longjmp through lua_error builds the unified Lua+Titan
-- trace (the same machinery the libbacktrace_spec exercises). A `raise` from a
-- Titan function caught by a Lua `pcall` therefore surfaces the raised value as
-- the pcall error and a trace mentioning the Titan native frame.
--
-- catch/finally parse (parser_spec) and typecheck (Phase 3, spec/checker/
-- error_handling_spec.lua) but are not yet compiled (Phases 4-5), so this
-- end-to-end file only exercises `raise <exp>`. A bare `raise` outside a catch
-- is still a checker error.
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
            -- the raising Titan function symbolizes as a native frame, shown by
            -- its qualified Titan name (not the mangled C symbol)
            assert(bt:find("in test.inner", 1, true), "missing inner frame\n" .. bt)
            assert(bt:find("in test.outer", 1, true), "missing outer frame\n" .. bt)
            -- attributed to the raise's .titan line via #line, not the generated .c
            assert(bt:find("test%.titan:%d+: in test%.inner"),
                   "inner frame not attributed to test.titan:<line>\n" .. bt)
            assert(not bt:find("test%.c:%d+: in test"),
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
end)

describe("catch (error-handling Phase 4)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("catches a body error and continues after the try", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    raise "boom"
                    return 1
                catch
                    return 42
                end
            end
        ]], [==[
            local r = test.run()
            assert(r == 42, "expected 42, got " .. tostring(r))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("falls through to code after the try when the catch handles", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                do
                    raise "boom"
                catch
                    n = 7
                end
                return n + 1
            end
        ]], [==[
            assert(test.run() == 8, "expected 8")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("binds the caught `error` value to what was raised", function()
        local out = compile_and_run([[
            function run(): string
                do
                    raise "the-message"
                    return "unreached"
                catch
                    return error
                end
            end
        ]], [==[
            assert(test.run() == "the-message", "wrong caught error")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("binds a non-string caught error verbatim", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    local t: {integer} = {10, 20, 30}
                    raise t
                    return 0
                catch
                    local got: {integer} = error as {integer}
                    return got[2]
                end
            end
        ]], [==[
            assert(test.run() == 20, "wrong caught table value")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("binds `traceback` to a string containing the unified trace", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "fail-here"
                return 0
            end
            function run(): string
                do
                    local x: integer = deep()
                    return "no-error"
                catch
                    return traceback
                end
            end
        ]], [==[
            local tb = test.run()
            assert(type(tb) == "string", "traceback not a string: " .. type(tb))
            assert(tb:find("stack traceback:", 1, true), "no trace header\n" .. tb)
            assert(tb:find("in test.deep", 1, true), "trace lacks deep frame\n" .. tb)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("bare re-raise preserves the ORIGINAL deep trace", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "deep-boom"
                return 0
            end
            function mid(): integer
                return deep()
            end
            function run(): integer
                do
                    return mid()
                catch
                    raise
                end
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.run)
            assert(not ok)
            assert(err == "deep-boom", "wrong re-raised value: " .. tostring(err))
            local bt = titan.backtrace()
            -- the ORIGINAL trace names the deep raising frame, not just the catch site
            assert(bt:find("in test.deep", 1, true),
                   "re-raise lost the original deep frame\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("raise <exp> in a catch builds a FRESH trace at the raise site", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "deep-boom"
                return 0
            end
            function run(): integer
                do
                    return deep()
                catch
                    raise "fresh-error"
                end
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.run)
            assert(not ok)
            assert(err == "fresh-error", "wrong fresh value: " .. tostring(err))
            local bt = titan.backtrace()
            -- a fresh trace is captured at the catch's raise: it must NOT mention
            -- the original deep frame (which is no longer on the stack)
            assert(not bt:find("in test.deep", 1, true),
                   "fresh trace wrongly kept the original deep frame\n" .. bt)
            assert(bt:find("in test.run", 1, true),
                   "fresh trace lacks the raise-site frame\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a return out of a protected body works (errorjmp restored)", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    return 99
                catch
                    return -1
                end
            end
        ]], [==[
            assert(test.run() == 99, "early return out of try failed")
            -- a subsequent error must still be caught/handled correctly,
            -- proving L->errorJmp was restored (not dangling)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a break out of a protected body in a loop works", function()
        local out = compile_and_run([[
            function run(): integer
                local sum: integer = 0
                local i: integer = 0
                while i < 10 do
                    i = i + 1
                    do
                        if i == 5 then
                            break
                        end
                        sum = sum + i
                    catch
                        sum = sum + 1000
                    end
                end
                return sum
            end
        ]], [==[
            -- breaks at i==5: sums 1+2+3+4 = 10
            assert(test.run() == 10, "break out of try-in-loop failed: " .. tostring(test.run()))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a non-GC local mutated in the body reads correctly after the catch (volatile)", function()
        local out = compile_and_run([[
            function boom(): integer
                raise "boom"
                return 0
            end
            function run(): integer
                local n: integer = 1
                do
                    n = 5
                    n = n + boom()
                catch
                    n = n + 100
                end
                return n
            end
        ]], [==[
            -- n is set to 5 in the body, then the catch reads it (5) and adds 100
            assert(test.run() == 105, "volatile local wrong: " .. tostring(test.run()))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a fresh error after a handled one regenerates the trace", function()
        local out = compile_and_run([[
            function handled(): integer
                do
                    raise "first"
                catch
                    return 0
                end
            end
            function boom(): integer
                raise "second"
                return 0
            end
        ]], [==[
            local titan = require 'titan'
            assert(test.handled() == 0)
            -- after handling, a brand-new error must get its own fresh trace
            local ok, err = pcall(test.boom)
            assert(not ok and err == "second")
            local bt = titan.backtrace()
            assert(bt:find("in test.boom", 1, true), "fresh trace missing\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("compiles a finally and runs it on normal completion (Phase 5)", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                do
                    n = 1
                finally
                    n = n + 10
                end
                return n
            end
        ]], [==[
            assert(test.run() == 11, "finally on normal completion failed")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)
end)

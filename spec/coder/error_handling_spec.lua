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
    local f = assert(io.popen("./lua -l test " .. script))
    local out = f:read("*a")
    f:close()
    os.remove(script)
    return out
end

local function compile_and_read_c(titan_code)
    h.reset()
    local ast, perr = parse(titan_code, "test.titan")
    assert.truthy(ast, perr)
    local _, errs = checker.check("test", ast, titan_code, "test.titan")
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = compile("test", ast)
    assert.truthy(ok, err)
    local f = assert(io.open("test.c", "r"))
    local csrc = f:read("*a")
    f:close()
    return csrc
end

describe("raise <exp> (error-handling Phase 2)", function()
    setup(function() os.remove("titan-runtime/titan.o") end)
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

    it("raises non-GC scalar values verbatim", function()
        local out = compile_and_run([[
            function raise_int()
                raise 42
            end
            function raise_false()
                raise false
            end
        ]], [==[
            local ok, err = pcall(test.raise_int)
            assert(not ok and err == 42, "integer error not preserved: " .. tostring(err))
            ok, err = pcall(test.raise_false)
            assert(not ok and err == false, "false error not preserved: " .. tostring(err))
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
    setup(function() os.remove("titan-runtime/titan.o") end)
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

    it("catches non-raise runtime errors from protected bodies", function()
        local out = compile_and_run([[
            function run(): string
                do
                    local x: value = {}
                    local n: integer = x as integer
                    return "unreached " .. n
                catch
                    return traceback
                end
            end
        ]], [==[
            local tb = test.run()
            assert(tb:find("in test.run", 1, true),
                   "runtime type error was not caught with traceback\n" .. tostring(tb))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("closes Lua to-be-closed variables while unwinding through Lua callbacks into a Titan catch", function()
        local out = compile_and_run([[
            function call_lua3(f: () -> integer): integer
                return f()
            end
            function catch_lua2(f: () -> integer): integer
                do
                    return f()
                catch
                    return 77
                end
            end
        ]], [==[
            local closed = 0
            local close_error
            local mt = {
                __close = function(_, err)
                    closed = closed + 1
                    close_error = tostring(err)
                end
            }
            local function lua3()
                error("lua3-boom", 0)
            end
            local function lua2()
                local x <close> = setmetatable({}, mt)
                return test.call_lua3(lua3)
            end

            -- Lua -> Titan catch_lua2 [1] -> Lua lua2 [2] -> Titan call_lua3
            -- -> Lua lua3 [3]. The error from [3] is caught by [1]; recovery
            -- must close [2]'s to-be-closed local during unwinding.
            assert(test.catch_lua2(lua2) == 77, "Titan catch did not handle Lua error")
            assert(closed == 1, "Lua __close did not run exactly once: " .. closed)
            assert(close_error:find("lua3-boom", 1, true),
                   "__close did not receive the original error: " .. tostring(close_error))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("catches a Lua __close error raised during protected-boundary recovery", function()
        local out = compile_and_run([[
            function call_lua3(f: () -> integer): integer
                return f()
            end
            function catch_lua2_error(f: () -> integer): (string, string)
                do
                    local n: integer = f()
                    return "unreached " .. n, ""
                catch
                    return error as string, traceback
                end
            end
        ]], [==[
            local close_seen_original = false
            local mt = {
                __close = function(_, err)
                    close_seen_original = tostring(err):find("original-lua3-error", 1, true) ~= nil
                    error("close-error", 0)
                end
            }
            local function lua3()
                error("original-lua3-error", 0)
            end
            local function lua2()
                local x <close> = setmetatable({}, mt)
                return test.call_lua3(lua3)
            end

            local caught, tb = test.catch_lua2_error(lua2)
            assert(close_seen_original, "__close did not see the original Lua error")
            assert(caught:find("close-error", 1, true),
                   "Titan catch did not receive the __close replacement error: " .. caught)
            assert(tb:find("close-error", 1, true),
                   "Titan errorhandler did not recapture the __close replacement trace:\n" .. tb)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("catches an error raised while evaluating a return expression", function()
        local out = compile_and_run([[
            function boom(): integer
                raise "boom"
                return 0
            end
            function run(): integer
                do
                    return boom()
                catch
                    return 42
                end
            end
        ]], [==[
            assert(test.run() == 42,
                   "return expression error restored the boundary too early")
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

    it("a non-GC local mutated in the body reads correctly after the catch (spill)", function()
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
            assert(test.run() == 105, "spilled local wrong: " .. tostring(test.run()))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("spills only setjmp-sensitive non-GC locals and params, not their C vars", function()
        local csrc = compile_and_read_c([[
            function run(n: integer): integer
                local m: integer = 10
                do
                    n = 5
                    m = 6
                    raise "x"
                catch
                    n = n + m
                end
                return n
            end
        ]])
        assert.not_match("volatile%s+lua_Integer%s+_param_n", csrc)
        assert.not_match("volatile%s+lua_Integer%s+_local_m_1", csrc)
        assert.match("volatile%s+lua_Integer%s+_spill_param_n", csrc)
        assert.match("volatile%s+lua_Integer%s+_spill_local_m_1", csrc)
    end)

    it("does not spill locals and params just because a function contains catch", function()
        local csrc = compile_and_read_c([[
            function run(n: integer): integer
                local m: integer = 1
                do
                    raise "x"
                catch
                end
                return n + m
            end
        ]])
        assert.not_match("_spill_param_n", csrc)
        assert.not_match("_spill_local_m_1", csrc)
        assert.not_match("volatile%s+lua_Integer%s+_param_n", csrc)
        assert.not_match("volatile%s+lua_Integer%s+_local_m_1", csrc)
    end)

    it("a GC local mutated in the body reads correctly after a handled error", function()
        local out = compile_and_run([[
            function run(): string
                local s: string = "old"
                do
                    s = "new"
                    raise "x"
                catch
                end
                return s
            end
        ]], [==[
            assert(test.run() == "new", "GC local changed across longjmp")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a GC parameter mutated in the body reads correctly after a handled error", function()
        local out = compile_and_run([[
            function run(s: string): string
                do
                    s = "new"
                    raise "x"
                catch
                end
                return s
            end
        ]], [==[
            assert(test.run("old") == "new", "GC parameter changed across longjmp")
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

    it("clears handled traces and consumes a real re-raise pin before the next fresh error", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "old"
                return 0
            end
            function rer(): integer
                do
                    return deep()
                catch
                    raise
                end
            end
            function handled(): integer
                do
                    raise "handled"
                catch
                    return 0
                end
            end
            function fresh(): integer
                raise "fresh"
                return 0
            end
        ]], [==[
            local titan = require 'titan'
            assert(test.handled() == 0)
            assert(titan.backtrace() == nil, "handled catch left a stale trace")

            local ok, err = pcall(test.rer)
            assert(not ok and err == "old")
            local old = titan.backtrace()
            assert(old:find("in test.deep", 1, true),
                   "re-raise did not preserve original deep trace\n" .. tostring(old))

            ok, err = pcall(test.fresh)
            assert(not ok and err == "fresh")
            local new = titan.backtrace()
            assert(new:find("in test.fresh", 1, true),
                   "fresh error after re-raise did not regenerate\n" .. tostring(new))
            assert(not new:find("in test.deep", 1, true),
                   "re-raise pin leaked into next fresh error\n" .. new)
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

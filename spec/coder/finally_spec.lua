-- End-to-end coverage for `finally` + the pending-action machinery
-- (error-handling Phase 5).
--
-- A `finally` runs on EVERY exit of the protected region: normal fall-through,
-- an error caught by the boundary, and `return`/`break` out of the body or
-- catch. The lowering records a per-try pending action {NONE, RETURN(vals),
-- BREAK, RAISE}, runs the finally straight-line, then an if-chain dispatch
-- performs the action — UNLESS the finally itself raises, which overrides and
-- abandons the pending action (the only override path, since `return` and a
-- finally-escaping `break` are Phase-3 checker errors).
--
-- These tests generate C, compile it, and run the result under stock Lua, so
-- they need the full lua-5.5.0 + libbacktrace setup (see CLAUDE.md).
local checker = require 'titan-compiler.checker'
local h = require 'spec.support.helpers'

local parse = h.parse
local compile = h.compile

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

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

describe("finally (error-handling Phase 5)", function()
    setup(function() os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("runs the finally on normal completion", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 1
                do
                    n = 2
                finally
                    n = n + 10
                end
                return n
            end
        ]], [==[
            assert(test.run() == 12, "finally not run on normal completion")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs the finally then returns when the body returns", function()
        local out = compile_and_run([[
            function run(): string
                do
                    return "from-body"
                finally
                    -- side effect proves the finally ran before the return landed
                    raise_if_seen()
                end
            end
            seen: boolean = false
            function raise_if_seen()
                seen = true
            end
            function was_seen(): boolean
                return seen
            end
        ]], [==[
            assert(test.run() == "from-body", "return-in-try wrong value")
            assert(test.was_seen() == true, "finally did not run before return")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs the finally on a break out of a try inside a for loop", function()
        local out = compile_and_run([[
            function run(): integer
                local sum: integer = 0
                for i = 1, 5 do
                    do
                        if i == 3 then
                            break
                        end
                        sum = sum + i
                    finally
                        sum = sum + 100
                    end
                end
                return sum
            end
        ]], [==[
            -- i=1: body +1, finally +100 -> 101
            -- i=2: body +2, finally +100 -> 203
            -- i=3: break (finally +100 still runs) -> 303, then break
            assert(test.run() == 303, "break-in-try-in-for wrong: " .. tostring(test.run()))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs the finally on a raise propagating through it", function()
        local out = compile_and_run([[
            ran: boolean = false
            function mark()
                ran = true
            end
            function did_run(): boolean
                return ran
            end
            function run(): integer
                do
                    raise "boom"
                finally
                    mark()
                end
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "expected raise to propagate")
            assert(err == "boom", "wrong propagated error: " .. tostring(err))
            assert(test.did_run() == true, "finally did not run on a raise")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("re-propagates the ORIGINAL error with its ORIGINAL trace (finally-only)", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "deep-boom"
                return 0
            end
            function run(): integer
                do
                    return deep()
                finally
                    local x: integer = 1
                end
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.run)
            assert(not ok, "expected re-propagation")
            assert(err == "deep-boom", "wrong re-raised value: " .. tostring(err))
            local bt = titan.backtrace()
            -- the original deep frame must survive (the finally reinstalled+pinned
            -- the original trace before re-raising)
            assert(bt:find("in test.deep", 1, true),
                   "finally-only re-raise lost the original deep frame\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs the finally then returns the caught value (catch returns)", function()
        local out = compile_and_run([[
            log: integer = 0
            function note()
                log = log + 1
            end
            function lognum(): integer
                return log
            end
            function run(): string
                do
                    raise "x"
                catch
                    return "handled"
                finally
                    note()
                end
            end
        ]], [==[
            assert(test.run() == "handled", "catch-return-with-finally wrong value")
            assert(test.lognum() == 1, "finally did not run after catch return")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a finally that RAISES overrides a pending return", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    return 7
                finally
                    raise "overridden"
                end
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "finally raise should override the return")
            assert(err == "overridden", "wrong override value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a finally that RAISES overrides a pending catch return", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    raise "body"
                catch
                    return 7
                finally
                    raise "from-finally"
                end
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "finally raise should override the catch return")
            assert(err == "from-finally", "wrong override value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a finally that RAISES overrides a pending break", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                while true do
                    do
                        break
                    finally
                        raise "no-break"
                    end
                end
                return n
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "finally raise should override the break")
            assert(err == "no-break", "wrong override value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a finally that RAISES overrides a pending raise (replaces it)", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    raise "original"
                finally
                    raise "replacement"
                end
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "expected the finally's raise to propagate")
            assert(err == "replacement", "finally raise did not override: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a bare re-raise in a catch that has a finally preserves the original trace", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "deep-boom"
                return 0
            end
            function mid(): integer
                return deep()
            end
            ran: boolean = false
            function mark()
                ran = true
            end
            function ran_finally(): boolean
                return ran
            end
            function run(): integer
                do
                    return mid()
                catch
                    raise
                finally
                    mark()
                end
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.run)
            assert(not ok, "expected the re-raise to propagate")
            assert(err == "deep-boom", "wrong re-raised value: " .. tostring(err))
            assert(test.ran_finally() == true, "finally did not run on a catch re-raise")
            local bt = titan.backtrace()
            assert(bt:find("in test.deep", 1, true),
                   "catch re-raise (with finally) lost the original deep frame\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs nested finallys inside-out", function()
        local out = compile_and_run([[
            function order(): string
                local s: string = ""
                do
                    do
                        s = s .. "body "
                    finally
                        s = s .. "inner "
                    end
                finally
                    s = s .. "outer "
                end
                return s
            end
        ]], [==[
            assert(test.order() == "body inner outer ",
                   "nested finally order wrong: " .. test.order())
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a return chains through nested finallys (both run, value preserved)", function()
        local out = compile_and_run([[
            function nested(): string
                local s: string = ""
                do
                    do
                        return "RET"
                    finally
                        s = s .. "inner "
                    end
                finally
                    s = s .. "outer "
                end
            end
        ]], [==[
            -- the function returns RET; both finallys must have run on the way out
            assert(test.nested() == "RET", "chained return wrong value")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("catch gets its own boundary: a raise in catch still runs the finally", function()
        local out = compile_and_run([[
            log: integer = 0
            function note()
                log = log + 1
            end
            function lognum(): integer
                return log
            end
            function run(): integer
                do
                    raise "body"
                catch
                    raise "from-catch"
                finally
                    note()
                end
                return 0
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok)
            assert(err == "from-catch", "wrong error from catch raise: " .. tostring(err))
            assert(test.lognum() == 1, "finally did not run after a catch raise")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("catch-boundary recovery closes Lua to-be-closed variables before finally", function()
        local out = compile_and_run([[
            log: integer = 0
            function note()
                log = log + 1
            end
            function lognum(): integer
                return log
            end
            function call_lua3(f: () -> integer): integer
                return f()
            end
            function run(f: () -> integer): integer
                do
                    raise "body"
                catch
                    return f()
                finally
                    note()
                end
                return 0
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
                error("catch-lua3-boom", 0)
            end
            local function lua2()
                local x <close> = setmetatable({}, mt)
                return test.call_lua3(lua3)
            end

            local ok, err = pcall(test.run, lua2)
            assert(not ok, "catch callback error should propagate after finally")
            assert(tostring(err):find("catch-lua3-boom", 1, true),
                   "wrong propagated error: " .. tostring(err))
            assert(closed == 1, "Lua __close in catch callback did not run exactly once: " .. closed)
            assert(close_error:find("catch-lua3-boom", 1, true),
                   "__close did not receive catch callback error: " .. tostring(close_error))
            assert(test.lognum() == 1, "finally did not run after catch callback error")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves a non-GC enclosing local across the finally (spill)", function()
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
                finally
                    n = n + 1000
                end
                return n
            end
        ]], [==[
            -- body sets n=5, errors; catch adds 100 (105); finally adds 1000 (1105)
            assert(test.run() == 1105, "spill-across-finally wrong: " .. tostring(test.run()))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("reloads a non-GC local assigned in catch before a catch raise reaches finally", function()
        local out = compile_and_run([[
            seen: integer = 0
            function seen_value(): integer
                return seen
            end
            function run()
                local n: integer = 1
                do
                    raise "body"
                catch
                    n = 7
                    raise "catch"
                finally
                    seen = n
                end
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok)
            assert(err == "catch", "wrong error from catch raise: " .. tostring(err))
            assert(test.seen_value() == 7, "finally read stale catch-assigned local")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("preserves a multi-return through a finally", function()
        local out = compile_and_run([[
            function run(): (integer, string)
                do
                    return 42, "hi"
                finally
                    local x: integer = 0
                end
            end
        ]], [==[
            local a, b = test.run()
            assert(a == 42 and b == "hi", "multi-return through finally wrong: "
                   .. tostring(a) .. "," .. tostring(b))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("keeps GC-valued pending returns rooted while the finally allocates", function()
        local out = compile_and_run([[
            record R
                s: string
            end

            function churn()
                local junk: {string} = {}
                local i = 1
                while i <= 600 do
                    junk = { "x", "y", "z" }
                    i = i + 1
                end
            end

            function ret(a: string, b: string): (string, {string}, R, value)
                do
                    local arr: {string} = { a, b }
                    local r: R = { s = b }
                    local v: value = r
                    return a, arr, r, v
                finally
                    churn()
                end
            end
        ]], [==[
            collectgarbage("generational")
            local a = ("a"):rep(5000) .. "!"
            local b = ("b"):rep(6000) .. "?"
            local s, arr, r, v = test.ret(a, b)
            collectgarbage("step")
            assert(s == a, "string return corrupted")
            assert(arr[2] == b, "array return corrupted")
            assert(r.s == b, "record return corrupted")
            assert(v == r, "value return no longer points at the record")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs finally before a break issued from a catch", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                while n < 10 do
                    do
                        raise "stop"
                    catch
                        break
                    finally
                        n = n + 100
                    end
                    n = n + 1
                end
                return n
            end
        ]], [==[
            assert(test.run() == 100, "catch break did not run finally first")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("cascades nested finally blocks on a propagating raise", function()
        local out = compile_and_run([[
            log: string = ""
            function resetlog()
                log = ""
            end
            function note(s: string)
                log = log .. s
            end
            function getlog(): string
                return log
            end

            function cascade(): integer
                do
                    do
                        raise "x"
                    finally
                        note("inner ")
                    end
                finally
                    note("outer ")
                end
                return 0
            end

            function override_inside_finally(): integer
                do
                    raise "body"
                catch
                    note("catch ")
                finally
                    do
                        raise "inner"
                    finally
                        note("cleanup ")
                    end
                end
                return 0
            end
        ]], [==[
            test.resetlog()
            local ok, err = pcall(test.cascade)
            assert(not ok and err == "x")
            assert(test.getlog() == "inner outer ",
                   "wrong nested-finally order: " .. test.getlog())

            test.resetlog()
            ok, err = pcall(test.override_inside_finally)
            assert(not ok and err == "inner")
            assert(test.getlog() == "catch cleanup ",
                   "inner raise from finally did not override/cascade correctly: "
                   .. test.getlog())
            print("OK")
        ]==])
        assert.match("OK", out)
    end)
end)

require "titan-compiler.coder.core"
-- End-to-end coverage for Titan error handling in generated C.
--
-- This file exercises `raise`, `catch`, `finally`, trace preservation,
-- setjmp-boundary spill/reload behavior, Lua callback unwinding, Lua
-- to-be-closed variables, and standalone top-level reporting. The tests
-- generate C, compile it, and run the result under stock Lua or as a standalone
-- executable, so they need the full lua-5.5.1 + libbacktrace setup.
--
-- `raise <exp>` evaluates its operand to a Lua value, places it in the one
-- error-object slot required by Lua's error ABI, and calls lua_error(L). The
-- traceback registry bookkeeping itself stays off the Lua stack. The entry
-- wrapper has errorhandler installed
-- on L->errfunc, so the longjmp through lua_error builds the unified Lua+Titan
-- trace. A `raise` from a Titan function caught by Lua `pcall` therefore
-- surfaces the raised value as the pcall error and records the Titan frames.
local h = require 'spec.support.helpers'
local coder = require 'titan-compiler.coder'
local coder_names = require 'titan-compiler.coder.names'

local compile_and_run = h.compile_and_run
local compile_and_read_c = h.compile_and_read_c
local compile_and_run_app = h.compile_and_run_app

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM test test__entrypoint.c")
    if not h.verbose then os.execute("rm -f *.c") end
end

local function native_body(csrc, name)
    local symbol = coder_names._function_prefix("test", name) .. "_titan"
    return assert(csrc:match(
        "[^\n]*" .. symbol .. "%b()%s*(%b{})"), symbol)
end

describe("raise <exp>", function()
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

    it("surfaces the error value separately from the raw unified trace", function()
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
            assert(not bt:find("deep failure", 1, true),
                   "raw trace should not include the error message\n" .. bt)
            assert(not bt:find("stack traceback:", 1, true),
                   "raw trace should not include a trace header\n" .. bt)
            assert(not bt:find("\t", 1, true),
                   "raw trace should not include presentation tabs\n" .. bt)
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
            assert(type(err) == "userdata",
                   "expected Array proxy error, got " .. type(err))
            assert(getmetatable(err) == "Titan array metatable")
            assert(err[2] == 2, "wrong Array contents")
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

    it("explicitly re-raising an error payload needs a pinned restored trace", function()
        -- This models the coroutine wrapper path: a C boundary catches a
        -- callback error, leaves/restores that callback trace in the registry,
        -- then a Titan wrapper executes `raise payload`.
        local out = compile_and_run([[
            function fail(): integer
                raise "body failed"
                return 0
            end
            function reraiser(payload: value): integer
                raise payload
                return 0
            end
        ]], [==[
            local titan = require 'titan'

            titan.clear()
            local ok, payload = pcall(test.fail)
            assert(not ok and payload == "body failed")
            local original = titan.backtrace()
            assert(original:find("in test.fail", 1, true),
                   "original error did not capture the body trace\n" .. tostring(original))

            ok, payload = pcall(test.reraiser, payload)
            assert(not ok and payload == "body failed")
            local unpinned = titan.backtrace()
            assert(unpinned:find("in test.reraiser", 1, true),
                   "fresh raise did not regenerate at the wrapper\n" .. tostring(unpinned))
            assert(not unpinned:find("in test.fail", 1, true),
                   "unpinned explicit raise kept the old body trace\n" .. unpinned)

            titan.clear()
            ok, payload = pcall(test.fail)
            assert(not ok and payload == "body failed")
            local restored = titan.backtrace()
            assert(restored:find("in test.fail", 1, true),
                   "restored trace did not capture the body\n" .. tostring(restored))

            titan.pin()
            ok, payload = pcall(test.reraiser, payload)
            assert(not ok and payload == "body failed")
            local pinned = titan.backtrace()
            assert(pinned == restored, "pin did not preserve restored trace")
            assert(not pinned:find("in test.reraiser", 1, true),
                   "pinned raise regenerated at the wrapper\n" .. pinned)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("keeps native catch and re-raise registry bookkeeping off the Lua stack",
    function()
        local csrc = compile_and_read_c([[
            function reraised(flag: boolean): integer
                do
                    if flag then raise "body" end
                catch
                    if flag then raise end
                end
                return 0
            end

            local function complete_pending()
            end

            function pending_finally(): integer
                defer complete_pending()
                raise "pending"
                return 0
            end
        ]])

        local forbidden = {
            "lua_checkstack", "lua_gettop", "lua_settop",
            "lua_pushliteral", "lua_pushboolean", "lua_pushnil",
            "lua_pushvalue", "lua_rawget", "lua_rawset",
        }
        for _, name in ipairs({ "reraised", "pending_finally" }) do
            local body = native_body(csrc, name)
            for _, call in ipairs(forbidden) do
                assert.falsy(body:find(call .. "(", 1, true),
                    name .. " used stack API " .. call .. "\n" .. body)
            end
            assert.falsy(body:find("luaL_", 1, true), body)
            for call in body:gmatch("(lua_[%w_]+)%s*%(") do
                assert.equals("lua_error", call,
                    name .. " used public API " .. call .. "\n" .. body)
            end
            assert.truthy(body:find(
                "titan_registry_get_string(", 1, true), body)
            assert.truthy(body:find(
                "titan_registry_set_string(", 1, true), body)
            assert.truthy(body:find("lua_error(L);", 1, true), body)
        end

        local reraised = native_body(csrc, "reraised")
        assert.truthy(reraised:find(
            "tagisempty(_caught_trace_tag_", 1, true), reraised)
        assert.truthy(reraised:find(
            "titan_ensure_stack(L, 1);", 1, true), reraised)
        assert.falsy(reraised:find(
            "titan_ensure_stack(L, 2);", 1, true), reraised)
        local recover = assert(reraised:find(
            "luaD_seterrorobj(L,", 1, true))
        local steady_top = assert(reraised:find(
            "L->top.p = _base +", recover, true))
        assert.falsy(reraised:sub(recover, steady_top):find(
            "titan_ensure_stack(", 1, true), reraised)

        local helper_count = 0
        for helper in csrc:gmatch(
                "static TITAN_UNUSED inline [^\n]+" ..
                "titan_registry_[gs]et_string%b()%s*(%b{})") do
            helper_count = helper_count + 1
            assert.falsy(helper:find("L->top", 1, true), helper)
            assert.falsy(helper:find("luaL_", 1, true), helper)
            for call in helper:gmatch("(lua_[%w_]+)%s*%(") do
                assert.equals("lua_assert", call, helper)
            end
        end
        assert.equals(2, helper_count)
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

describe("standalone uncaught errors", function()
    after_each(clean)

    it("prints the raised error and a backtrace before exiting non-zero", function()
        local status, out = compile_and_run_app([[
            function deep(): integer
                raise "standalone-boom"
                return 0
            end
            function main(args: {string}): integer
                return deep()
            end
        ]])

        assert.truthy(status and status ~= 0,
            "expected non-zero exit, got " .. tostring(status) .. "\n" .. out)
        assert.truthy(out:find("standalone-boom", 1, true),
            "missing raised error in standalone report\n" .. out)
        assert.truthy(out:find("^test: standalone%-boom\nstack traceback:\n\t"),
            "standalone report is not Lua-shaped\n" .. out)
        assert.falsy(out:find("stack traceback:\t", 1, true),
            "standalone report put the first frame on the header line\n" .. out)
        assert.truthy(out:find("in test.deep", 1, true),
            "missing Titan raising frame in standalone report\n" .. out)
        assert.truthy(out:find("in test.main", 1, true),
            "missing Titan main frame in standalone report\n" .. out)
    end)

    it("formats a standalone non-string error object like lua.c", function()
        local status, out = compile_and_run_app([[
            function main(args: {string}): integer
                raise false
                return 0
            end
        ]])

        assert.truthy(status and status ~= 0,
            "expected non-zero exit, got " .. tostring(status) .. "\n" .. out)
        assert.truthy(out:find("^test: %(error object is a boolean value%)\nstack traceback:\n\t"),
            "standalone report did not use lua.c-style error conversion\n" .. out)
    end)
end)

describe("finally / defer cleanup", function()
    after_each(clean)

    it("runs deferred cleanup on normal completion", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 1
                do
                    defer n = n + 10
                    n = 2
                end
                return n
            end
        ]], [==[
            assert(test.run() == 12, "finally not run on normal completion")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("runs deferred cleanup then returns when the body returns", function()
        local out = compile_and_run([[
            function run(): string
                defer raise_if_seen()
                return "from-body"
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

    it("runs deferred cleanup on a break out of a try inside a for loop", function()
        local out = compile_and_run([[
            function run(): integer
                local sum: integer = 0
                for i = 1, 5 do
                    do
                        defer sum = sum + 100
                        if i == 3 then
                            break
                        end
                        sum = sum + i
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

    it("runs deferred cleanup on a raise propagating through it", function()
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
                    defer mark()
                    raise "boom"
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

    it("re-propagates the original error with its original trace", function()
        local out = compile_and_run([[
            function deep(): integer
                raise "deep-boom"
                return 0
            end
            function run(): integer
                do
                    defer local x: integer = 1
                    return deep()
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

    it("runs deferred cleanup then returns the caught value", function()
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
                    defer note()
                    raise "x"
                catch
                    return "handled"
                end
            end
        ]], [==[
            assert(test.run() == "handled", "catch-return-with-finally wrong value")
            assert(test.lognum() == 1, "finally did not run after catch return")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a deferred raise overrides a pending return", function()
        local out = compile_and_run([[
            function run(): integer
                defer raise "overridden"
                return 7
            end
        ]], [==[
            local ok, err = pcall(test.run)
            assert(not ok, "finally raise should override the return")
            assert(err == "overridden", "wrong override value: " .. tostring(err))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("a deferred raise overrides a pending catch return", function()
        local out = compile_and_run([[
            function run(): integer
                defer raise "from-finally"
                do
                    raise "body"
                catch
                    return 7
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

    it("a deferred raise overrides a pending break", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                while true do
                    do
                        defer raise "no-break"
                        break
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

    it("a deferred raise overrides a pending raise", function()
        local out = compile_and_run([[
            function run(): integer
                do
                    defer raise "replacement"
                    raise "original"
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

    it("a bare re-raise in a catch with deferred cleanup preserves the original trace", function()
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
                    defer mark()
                    return mid()
                catch
                    raise
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

    it("runs nested defers inside-out (LIFO)", function()
        local out = compile_and_run([[
            function order(): string
                local s: string = ""
                do
                    defer s = s .. "outer "
                    do
                        defer s = s .. "inner "
                        s = s .. "body "
                    end
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

    it("a return chains through nested defers", function()
        local out = compile_and_run([[
            function nested(): string
                local s: string = ""
                do
                    defer s = s .. "outer "
                    do
                        defer s = s .. "inner "
                        return "RET"
                    end
                end
            end
        ]], [==[
            -- the function returns RET; both finallys must have run on the way out
            assert(test.nested() == "RET", "chained return wrong value")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("catch gets its own boundary: a raise in catch still runs deferred cleanup", function()
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
                    defer note()
                    raise "body"
                catch
                    raise "from-catch"
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

    it("catch-boundary recovery closes Lua to-be-closed variables before deferred cleanup", function()
        local out = compile_and_run([[
            log: integer = 0
            function note()
                log = log + 1
            end
            function lognum(): integer
                return log
            end
            function call_lua3(f: function (): integer): integer
                return f()
            end
            function run(f: function (): integer): integer
                do
                    defer note()
                    raise "body"
                catch
                    return f()
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

    it("preserves a non-GC enclosing local across deferred cleanup", function()
        local out = compile_and_run([[
            function boom(): integer
                raise "boom"
                return 0
            end
            function run(): integer
                local n: integer = 1
                do
                    defer n = n + 1000
                    n = 5
                    n = n + boom()
                catch
                    n = n + 100
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

    it("reloads a non-GC local assigned in catch before a catch raise reaches deferred cleanup", function()
        local out = compile_and_run([[
            seen: integer = 0
            function seen_value(): integer
                return seen
            end
            function run()
                local n: integer = 1
                defer seen = n
                do
                    raise "body"
                catch
                    n = 7
                    raise "catch"
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

    it("preserves a multi-return through deferred cleanup", function()
        local out = compile_and_run([[
            function run(): (integer, string)
                defer local x: integer = 0
                return 42, "hi"
            end
        ]], [==[
            local a, b = test.run()
            assert(a == 42 and b == "hi", "multi-return through finally wrong: "
                   .. tostring(a) .. "," .. tostring(b))
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("keeps GC-valued pending returns rooted while deferred cleanup allocates", function()
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
                local arr: {string} = { a, b }
                local r: R = { s = b }
                local v: value = r
                defer churn()
                return a, arr, r, v
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

    it("runs deferred cleanup before a break issued from a catch", function()
        local out = compile_and_run([[
            function run(): integer
                local n: integer = 0
                while n < 10 do
                    do
                        defer n = n + 100
                        raise "stop"
                    catch
                        break
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

    it("cascades nested deferred cleanup blocks on a propagating raise", function()
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
                    defer note("outer ")
                    do
                        defer note("inner ")
                        raise "x"
                    end
                end
                return 0
            end

            function override_inside_finally(): integer
                defer do
                    defer note("cleanup ")
                    raise "inner"
                end
                do
                    raise "body"
                catch
                    note("catch ")
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

describe("catch", function()
    after_each(clean)

    it("generates a value-returning function-level catch", function()
        local out = compile_and_run([[
            function quotient(n: integer): integer?
                return 10 // n
            catch
                return nil
            end
        ]], [==[
            assert(test.quotient(2) == 5, "function catch changed success")
            assert(test.quotient(0) == nil, "function catch missed error")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

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
            assert(not tb:find("stack traceback:", 1, true),
                   "catch traceback should not include a trace header\n" .. tb)
            assert(not tb:find("\t", 1, true),
                   "catch traceback should not include presentation tabs\n" .. tb)
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
            function call_lua3(f: function (): integer): integer
                return f()
            end
            function catch_lua2(f: function (): integer): integer
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
            function call_lua3(f: function (): integer): integer
                return f()
            end
            function catch_lua2_error(f: function (): integer): (string, string)
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
            assert(not tb:find("close-error", 1, true),
                   "raw traceback should not include the replacement error message:\n" .. tb)
            assert(tb:find("in test.catch_lua2_error", 1, true),
                   "Titan errorhandler did not recapture the replacement-error boundary:\n" .. tb)
            assert(not tb:find("in test.call_lua3", 1, true),
                   "traceback still points at the original Lua3 call instead of the __close replacement:\n" .. tb)
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
        assert.not_match("lua_Integer%s+volatile%s+_param_n", csrc)
        assert.not_match("lua_Integer%s+volatile%s+_local_m_1", csrc)
        assert.match("lua_Integer%s+volatile%s+_spill_param_n", csrc)
        assert.match("lua_Integer%s+volatile%s+_spill_local_m_1", csrc)
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
        assert.not_match("lua_Integer%s+volatile%s+_param_n", csrc)
        assert.not_match("lua_Integer%s+volatile%s+_local_m_1", csrc)
    end)

    it("installs a trailing catch target before allocating in a native entry",
    function()
        local csrc = compile_and_read_c([[
            local function native_callback()
                local values = { 1 }
                if #values == 0 then raise "unreachable" end
            catch
                return
            end

            function call_callback()
                native_callback()
            end
        ]])
        local native_callback =
            coder_names._function_prefix("test", "native_callback") ..
            "_titan"
        local _, prototype = assert(csrc:find(native_callback, 1, true))
        local definition = assert(csrc:find(
            native_callback, prototype + 1, true))
        -- Later declarations may be exported or indented rather than beginning
        -- with one exact `static ` spelling. Both anchors below are the first
        -- such operations after this definition, so the suffix is the stable
        -- contract and avoids depending on the next declaration's linkage.
        local body = csrc:sub(definition)
        local setjmp = assert(body:find("TITAN_SETJMP", 1, true))
        local first_gc = assert(body:find("luaC_checkGC", 1, true))
        assert.is_true(setjmp < first_gc)
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

end)

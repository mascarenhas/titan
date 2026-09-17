-- End-to-end coverage for the libbacktrace-based unified stack trace.
--
-- These tests generate C, compile it (linking ./libbacktrace/.libs/libbacktrace.a
-- before liblua.a, with -g), and run the result under ./lua. They
-- assert on the merged `titan.backtrace()` string: the native (libbacktrace)
-- frames symbolized and merged with the Lua-side luaL_traceback, plus the
-- registry pin-flag discipline (preserve vs. regenerate).
--
-- Native Titan frames symbolize to the original .titan source file and line
-- (carried in the .so's DWARF via generated `#line` directives), not to the
-- generated .c. The merge filter classifies .titan filenames as visible, so
-- they appear as `<file>.titan:<line>: in <symbol>`.
local h = require 'spec.support.helpers'

local compile_and_run = h.compile_and_run
local compile_and_run_app = h.compile_and_run_app

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM test test__entrypoint.c")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("libbacktrace unified stack trace", function()
    after_each(clean)

    it("keeps the native symbol cache in Lua registry state", function()
        local file = assert(io.open("titan-runtime/titan.c", "rb"))
        local runtime = file:read("*a")
        file:close()
        assert.truthy(runtime:find("TITAN_BT_STATE_KEY", 1, true), runtime)
        assert.truthy(runtime:find("lua_newuserdatauv", 1, true), runtime)
        assert.falsy(runtime:find(
            "static struct backtrace_state *titan_bt_state", 1, true),
            runtime)
        assert.falsy(runtime:find("titan_bt_generation_seen", 1, true),
            runtime)
    end)

    it("merges native frames, showing qualified Titan names not mangled symbols", function()
        -- A Titan error raised two native frames deep. The merged trace must
        -- carry both the Lua-side traceback and the Titan native frames, the
        -- latter shown by their QUALIFIED Titan name (<module>.<func>), not the
        -- mangled C symbol, and with NO entry-wrapper (titanentry) frame.
        local out = compile_and_run([[
            function inner(): integer
                local x: value = {}
                return x
            end
            function outer(): integer
                return inner()
            end
        ]], [==[
            local titan = require 'titan'
            local ok, err = pcall(test.outer)
            assert(not ok)
            local bt = titan.backtrace()
            -- raw trace: no error message, no display header, no tab prefixing
            assert(not bt:find(err, 1, true), "raw trace included error message")
            assert(not bt:find("stack traceback:", 1, true), "raw trace included header")
            assert(not bt:find("\t", 1, true), "raw trace included presentation tabs")
            -- qualified Titan names for BOTH functions present
            assert(bt:find("in test.inner", 1, true), "missing inner frame\n"..bt)
            assert(bt:find("in test.outer", 1, true), "missing outer frame\n"..bt)
            -- NO mangled C symbol and NO trampoline sentinel leaks through
            assert(not bt:find("titanentry", 1, true), "leaked trampoline frame\n"..bt)
            assert(not bt:find("_titan", 1, true), "leaked mangled symbol\n"..bt)
            -- interpreter/runtime/libc frames filtered out of the native part
            assert(not bt:find("lua-5.5.1/src/", 1, true), "leaked interp frame")
            assert(not bt:find("titan-runtime/", 1, true), "leaked runtime frame")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("attributes native frames to the .titan source via #line", function()
        -- With `#line`, the native frames symbolize to the ORIGINAL .titan file
        -- and line carried in the .so's DWARF, NOT the generated .c. The raise
        -- site (the bad `return x` coercion) is stamped by codethrow with the
        -- exact statement line, so the inner frame reports its own line.
        local out = compile_and_run([[
            function inner(): integer
                local x: value = {}
                return x
            end
            function outer(): integer
                return inner()
            end
        ]], [==[
            local titan = require 'titan'
            assert(not pcall(test.outer))
            local bt = titan.backtrace()
            -- Native Titan frames now carry the .titan path + a line number and
            -- the QUALIFIED Titan name, e.g. "test.titan:3: in test.inner".
            assert(bt:find("test%.titan:%d+: in test%.inner"),
                   "inner native frame not attributed to test.titan:<line>\n" .. bt)
            assert(bt:find("test%.titan:%d+: in test%.outer"),
                   "outer native frame not attributed to test.titan:<line>\n" .. bt)
            -- The whole point of #line: the generated .c must NOT appear as the
            -- source of any native Titan frame.
            assert(not bt:find("test%.c:%d+: in test"),
                   "native frame still attributed to generated .c\n" .. bt)
            -- The error is the bad coercion in `inner`'s body; that statement is
            -- the third line of the module, so the inner frame's line must land
            -- there (codethrow stamps the exact raise line).
            assert(bt:find("test%.titan:3: in test%.inner"),
                   "inner frame line is not the raise statement (3)\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("pin preserves an existing trace; clear lets it regenerate", function()
        -- fa and fb each raise. After the first (fa) error the slot holds fa's
        -- trace. Pinning makes a subsequent fb error KEEP fa's trace (no
        -- regenerate). Clearing the slot lets the next fb error regenerate a
        -- fresh trace that mentions fb, not fa.
        local out = compile_and_run([[
            function fa(): integer
                local x: value = {}
                return x
            end
            function fb(): integer
                local y: value = {}
                return y
            end
        ]], [==[
            local titan = require 'titan'

            pcall(test.fa)
            local t1 = titan.backtrace()
            assert(t1:find("in test.fa", 1, true), "first error not captured")

            -- pin, then raise a DIFFERENT error: slot must be kept verbatim
            titan.pin()
            pcall(test.fb)
            local t2 = titan.backtrace()
            assert(t2 == t1, "pin did not preserve the original trace")
            assert(not t2:find("in test.fb", 1, true),
                   "pinned trace was regenerated to fb")

            -- clear the slot, then raise again: must regenerate fresh
            titan.clear()
            pcall(test.fb)
            local t3 = titan.backtrace()
            assert(t3:find("in test.fb", 1, true),
                   "cleared slot did not regenerate")
            assert(not t3:find("in test.fa", 1, true),
                   "regenerated trace still mentions the old error")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("intermingles ALL Lua and Titan frames of a Lua<->Titan chain", function()
        -- A Lua->Titan->Lua->Titan->...->error chain: the Lua driver calls a
        -- Titan function that invokes a Lua callback that calls back into Titan
        -- that invokes another Lua callback that calls the erroring Titan
        -- function. A single luaV_execute runs several pure-Lua activations, so
        -- the unified trace must show EVERY one of those pure-Lua frames AND
        -- every Titan native frame, in one innermost->outer section.
        local out = compile_and_run([[
            function apply(f: function (integer): integer, n: integer): integer
                return f(n)
            end
            function boom(n: integer): integer
                local x: value = {}
                return x
            end
        ]], [==[
            local titan = require 'titan'
            local function lua_inner(n)         -- pure-Lua frame #2
                return test.apply(test.boom, n) -- Titan -> erroring Titan
            end
            local function lua_outer(n)         -- pure-Lua frame #1
                return test.apply(lua_inner, n) -- Titan -> Lua callback
            end
            local ok = pcall(test.apply, lua_outer, 1) -- Titan -> Lua callback
            assert(not ok)
            local bt = titan.backtrace()
            -- raw trace, innermost->outer
            assert(not bt:find("stack traceback:", 1, true),
                   "raw trace included display header\n"..bt)
            assert(not bt:find("C traceback:", 1, true), "regressed to two sections\n"..bt)
            assert(not bt:find("\t", 1, true), "raw trace included presentation tabs\n"..bt)
            -- no trampoline / mangled-symbol leakage anywhere in the trace
            assert(not bt:find("titanentry", 1, true), "leaked trampoline frame\n"..bt)
            assert(not bt:find("_titan", 1, true), "leaked mangled symbol\n"..bt)
            -- EVERY Titan native frame present (apply runs 3x; boom once),
            -- shown by qualified name, ONE frame per logical call (the
            -- entry-wrapper trampoline is collapsed away).
            assert(bt:find("in test.boom", 1, true), "missing boom native\n"..bt)
            -- apply is entered three times along the chain; all three frames
            -- survive (no dropped Titan frame), and each is a SINGLE frame
            -- (no separate entry-wrapper line).
            local _, napply = bt:gsub("in test%.apply\n", "")
            assert(napply == 3, "expected 3 apply native frames, got "..napply.."\n"..bt)
            -- EVERY intermediate pure-Lua frame present. The two Lua callbacks are
            -- invoked as values, so they carry no call-site name; they appear by
            -- source line as `function <script:defline>` activations.
            local _, nfn = bt:gsub("in function <", "")
            assert(nfn >= 2, "expected >=2 pure-Lua callback frames, got "..nfn.."\n"..bt)
            -- And they must be interleaved in actual call order, not merely
            -- present. A regression in the splice used to emit the middle/outer
            -- Titan `apply` frames one C CallInfo too early around Lua callbacks.
            local p_boom = assert(bt:find("in test.boom", 1, true), bt)
            local p_apply_inner = assert(bt:find("in test.apply", p_boom, true), bt)
            local p_lua_inner = assert(bt:find("in function <", p_apply_inner, true), bt)
            local p_apply_middle = assert(bt:find("in test.apply", p_lua_inner, true), bt)
            local p_lua_outer = assert(bt:find("in function <", p_apply_middle, true), bt)
            local p_apply_outer = assert(bt:find("in test.apply", p_lua_outer, true), bt)
            assert(p_boom < p_apply_inner
                   and p_apply_inner < p_lua_inner
                   and p_lua_inner < p_apply_middle
                   and p_apply_middle < p_lua_outer
                   and p_lua_outer < p_apply_outer,
                   "Lua/Titan frames are not innermost-to-outer interleaved\n"..bt)
            -- The native frame for a call expression should attribute to the
            -- source call line, not a generated-C line drifted several helper
            -- statements past the call-site #line directive.
            assert(bt:find("test%.titan:2: in test%.apply"),
                   "apply frame is not attributed to the call statement line\n"..bt)
            assert(not bt:find("test%.titan:1%d+: in test%.apply")
                   and not bt:find("test%.titan:2%d+: in test%.apply"),
                   "apply frame drifted into generated helper lines\n"..bt)
            -- the main chunk appears (the Lua side of the boundary)
            assert(bt:find("in main chunk", 1, true), "missing main chunk\n"..bt)
            -- interpreter/runtime frames still filtered from the native side
            assert(not bt:find("lua%-5%.5%.0/src/"), "leaked interp frame\n"..bt)
            assert(not bt:find("titan%-runtime/"), "leaked runtime frame\n"..bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("keeps genuine Lua C functions in a Lua<->Titan trace chain", function()
        local out = compile_and_run([[
            function call(f: function (): integer): integer
                return f()
            end
            function boom(): integer
                raise "boom"
                return 0
            end
        ]], [==[
            local titan = require 'titan'
            local function via_pcall()
                local ok, err = pcall(test.boom)
                assert(not ok and err == "boom")
                return 0
            end
            assert(test.call(via_pcall) == 0)
            local bt = titan.backtrace()
            local p_boom = assert(bt:find("in test.boom", 1, true), bt)
            local p_pcall = assert(bt:find("[C]: in global 'pcall'", p_boom, true)
                                   or bt:find("[C]: in function 'pcall'", p_boom, true),
                                   "missing genuine pcall C frame\n" .. bt)
            local p_lua = assert(bt:find("in function <", p_pcall, true), bt)
            local p_call = assert(bt:find("in test.call", p_lua, true), bt)
            assert(p_boom < p_pcall and p_pcall < p_lua and p_lua < p_call,
                   "genuine Lua C frame was dropped or spliced out of order\n" .. bt)
            assert(not bt:find("titanentry", 1, true), "leaked Titan entry frame\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("attributes a direct static caller frame to the exact call line", function()
        local out = compile_and_run(
            "function callee(): integer\n" ..
            "    raise \"line\"\n" ..
            "    return 0\n" ..
            "end\n" ..
            "function caller(): integer\n" ..
            "    local pad: integer = 1\n" ..
            "    pad = pad + 1\n" ..
            "    return callee()\n" ..
            "end\n",
            [==[
            local titan = require 'titan'
            assert(not pcall(test.caller))
            local bt = titan.backtrace()
            assert(bt:find("test%.titan:8: in test%.caller"),
                   "caller frame is not attributed to the direct call line\n" .. bt)
            assert(not bt:find("test%.titan:6: in test%.caller")
                   and not bt:find("test%.titan:7: in test%.caller"),
                   "caller frame drifted before the call line\n" .. bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("shows a method frame as <module>.<Rec>:<method>", function()
        -- An error inside a record method must show the qualified method name
        -- with the `:` separator, a SINGLE frame (no trampoline), and the
        -- top-level caller as <module>.<func>.
        local out = compile_and_run([[
            record Point
                x: integer
            end
            function Point:bad(): integer
                local v: value = {}
                return v
            end
            function run(p: Point): integer
                return p:bad()
            end
        ]], [==[
            local titan = require 'titan'
            local p = test.Point.new(1)
            assert(not pcall(test.run, p))
            local bt = titan.backtrace()
            assert(bt:find("in test.Point:bad", 1, true),
                   "missing method frame as test.Point:bad\n"..bt)
            assert(bt:find("in test.run", 1, true), "missing caller frame\n"..bt)
            assert(not bt:find("titanentry", 1, true), "leaked trampoline frame\n"..bt)
            assert(not bt:find("_titan", 1, true), "leaked mangled symbol\n"..bt)
            assert(not bt:find("ℳ", 1, true), "leaked module separator\n"..bt)
            assert(not bt:find("ℱ", 1, true), "leaked nominal separator\n"..bt)
            -- one frame per logical call: exactly one method line
            local _, nbad = bt:gsub("in test%.Point:bad", "")
            assert(nbad == 1, "expected 1 method frame, got "..nbad.."\n"..bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("shows an anonymous function as 'anonymous function at <file>.titan:<line>'", function()
        -- An error inside an anonymous Titan function must show it by its
        -- DEFINITION line, not the mangled lambda symbol. The lambda is defined
        -- on the module's 3rd line, so the frame names that line.
        local out = compile_and_run(
            "function run(): integer\n" ..
            "    local f: function (): (integer) = function(): integer\n" ..
            "        local v: value = {}\n" ..
            "        return v\n" ..
            "    end\n" ..
            "    return f()\n" ..
            "end\n",
            [==[
            local titan = require 'titan'
            assert(not pcall(test.run))
            local bt = titan.backtrace()
            -- the anonymous function is defined on line 2 of the module (the
            -- `function(): integer` literal), reported by its DEFINITION line,
            -- distinct from the body/error line (3).
            assert(bt:find("anonymous function at test%.titan:2"),
                   "missing/mis-lined anonymous-function frame\n"..bt)
            -- the frame's leading execution point is the throw line in the body
            -- (the `return v` coercion, line 4), distinct from the def line (2)
            assert(bt:find("test%.titan:4: in anonymous function at test%.titan:2"),
                   "anonymous frame not showing exec-line:def-line\n"..bt)
            assert(bt:find("in test.run", 1, true), "missing caller frame\n"..bt)
            assert(not bt:find("titanentry", 1, true), "leaked trampoline frame\n"..bt)
            assert(not bt:find("lambda_", 1, true), "leaked mangled lambda symbol\n"..bt)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("an unpinned fresh error always regenerates (no last-trace stickiness)", function()
        -- Without a pin, every error overwrites the slot: a second error after
        -- a handled first one must reflect the second, not stay on the first.
        local out = compile_and_run([[
            function ga(): integer
                local x: value = {}
                return x
            end
            function gb(): integer
                local y: value = {}
                return y
            end
        ]], [==[
            local titan = require 'titan'
            pcall(test.ga)
            assert(titan.backtrace():find("in test.ga", 1, true))
            pcall(test.gb)                       -- no pin: must regenerate
            local bt = titan.backtrace()
            assert(bt:find("in test.gb", 1, true), "did not regenerate")
            assert(not bt:find("in test.ga", 1, true), "stale trace stuck")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)
end)

-- Standalone-executable top-level handler. A module that defines
-- `main(args:{string}):integer` is linked into an executable whose C bootstrap
-- runs the Titan main in protected mode with `errorhandler` installed; an
-- uncaught error must print the message + the unified Lua+Titan trace to stderr
-- and exit non-zero, mirroring lua.c's msghandler/report.
describe("standalone main top-level error handler", function()
    after_each(clean)

    it("prints message + unified trace to stderr and exits non-zero", function()
        -- main -> mid (Titan) -> deep (Titan) -> uncaught error. The bootstrap
        -- runs main under lua_pcall with errorhandler installed; the unified
        -- trace captured on the intact stack is formatted for standalone
        -- reporting, stopping at the Titan main frame.
        local status, out = compile_and_run_app([[
            function deep(): integer
                local x: value = {}
                return x
            end
            function mid(): integer
                return deep()
            end
            function main(args: {string}): integer
                return mid()
            end
        ]])
        assert.equal(1, status)
        assert.equal([=[test: test.titan:3:24: type error, expected integer tag but found userdata
stack traceback:
	test.titan:3: in test.deep
	test.titan:6: in test.mid
	test.titan:9: in test.main
]=], out)
    end)
end)

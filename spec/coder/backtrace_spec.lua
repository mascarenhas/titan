-- End-to-end coverage for the libbacktrace-based unified stack trace
-- (error-handling Phase 0: runtime + driver, no language syntax yet).
--
-- These tests generate C, compile it (linking ./libbacktrace/.libs/libbacktrace.a
-- before liblua.a, with -g), and run the result under lua-5.5.0/src/lua. They
-- assert on the merged `titan.backtrace()` string: the native (libbacktrace)
-- frames symbolized and merged with the Lua-side luaL_traceback, plus the
-- registry pin-flag discipline (preserve vs. regenerate).
--
-- Phase 1 (#line emission) added: the native Titan frames now symbolize to the
-- original .titan source file and line (carried in the .so's DWARF via the
-- `#line` directives the coder emits at function entry, statement starts, and
-- every raise site), NOT to the generated .c. The merge filter (Phase 0)
-- already classifies .titan filenames as "show", so they appear automatically
-- as `<file>.titan:<line>: in <symbol>`.
local checker = require 'titan-compiler.checker'
local h = require 'spec.support.helpers'

local parse = h.parse
local compile = h.compile

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

-- Compile `titan_code` as module "test", then run `lua_test` under stock Lua
-- with `test` and `titan` available; returns the script's stdout.
local function compile_and_run(titan_code, lua_test)
    h.reset()
    -- Parse under the "test.titan" chunkname (not the helper's default "(spec)")
    -- so the AST locs — and thus the `#line` directives the coder emits — carry
    -- the .titan path, matching what `titanc` produces and what the Phase 1
    -- assertions below check for in the symbolized native frames.
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

describe("libbacktrace unified stack trace (error-handling Phase 0)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("merges symbolized native frames with the Lua traceback", function()
        -- A Titan error raised two native frames deep. The merged trace must
        -- carry both the Lua-side traceback and the symbolized native frames
        -- (shown by C symbol name <module>_<fn>_titan).
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
            -- error message and Lua traceback present
            assert(bt:find(err, 1, true), "missing error message")
            assert(bt:find("stack traceback:", 1, true), "missing Lua traceback")
            -- symbolized native frames for BOTH Titan functions present
            assert(bt:find("test_inner_titan", 1, true), "missing inner frame")
            assert(bt:find("test_outer_titan", 1, true), "missing outer frame")
            -- interpreter/runtime/libc frames filtered out of the native part
            assert(not bt:find("lua-5.5.0/src/", 1, true), "leaked interp frame")
            assert(not bt:find("titan-runtime/", 1, true), "leaked runtime frame")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("attributes native frames to the .titan source via #line (Phase 1)", function()
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
            -- Native Titan frames now carry the .titan path + a line number,
            -- e.g. "test.titan:3: in test_inner_titan".
            assert(bt:find("test%.titan:%d+: in test_inner_titan"),
                   "inner native frame not attributed to test.titan:<line>\n" .. bt)
            assert(bt:find("test%.titan:%d+: in test_outer_titan"),
                   "outer native frame not attributed to test.titan:<line>\n" .. bt)
            -- The whole point of #line: the generated .c must NOT appear as the
            -- source of any native Titan frame.
            assert(not bt:find("test%.c:%d+: in test_"),
                   "native frame still attributed to generated .c\n" .. bt)
            -- The error is the bad coercion in `inner`'s body; that statement is
            -- the third line of the module, so the inner frame's line must land
            -- there (codethrow stamps the exact raise line).
            assert(bt:find("test%.titan:3: in test_inner_titan"),
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
            assert(t1:find("test_fa_titan", 1, true), "first error not captured")

            -- pin, then raise a DIFFERENT error: slot must be kept verbatim
            titan.pin()
            pcall(test.fb)
            local t2 = titan.backtrace()
            assert(t2 == t1, "pin did not preserve the original trace")
            assert(not t2:find("test_fb_titan", 1, true),
                   "pinned trace was regenerated to fb")

            -- clear the slot, then raise again: must regenerate fresh
            titan.clear()
            pcall(test.fb)
            local t3 = titan.backtrace()
            assert(t3:find("test_fb_titan", 1, true),
                   "cleared slot did not regenerate")
            assert(not t3:find("test_fa_titan", 1, true),
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
            function apply(f: integer -> integer, n: integer): integer
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
            -- single section, innermost->outer
            assert(bt:find("stack traceback:", 1, true), "missing trace header\n"..bt)
            assert(not bt:find("C traceback:", 1, true), "regressed to two sections\n"..bt)
            -- EVERY Titan native frame present (apply runs 3x; boom once)
            assert(bt:find("test_boom_titan", 1, true), "missing boom native\n"..bt)
            -- apply is entered three times along the chain; all three native runs
            -- survive (no dropped Titan frame). Count the native function lines
            -- specifically: "test_apply_titan\n" (NOT the entry-wrapper symbol
            -- "test_apply_titanentry_lua", which shares the prefix).
            local _, napply = bt:gsub("in test_apply_titan\n", "")
            assert(napply == 3, "expected 3 apply native frames, got "..napply.."\n"..bt)
            -- EVERY intermediate pure-Lua frame present. The two Lua callbacks are
            -- invoked as values, so they carry no call-site name; they appear by
            -- source line as `function <script:defline>` activations.
            local _, nfn = bt:gsub("in function <", "")
            assert(nfn >= 2, "expected >=2 pure-Lua callback frames, got "..nfn.."\n"..bt)
            -- the main chunk appears (the Lua side of the boundary)
            assert(bt:find("in main chunk", 1, true), "missing main chunk\n"..bt)
            -- interpreter/runtime frames still filtered from the native side
            assert(not bt:find("lua%-5%.5%.0/src/"), "leaked interp frame\n"..bt)
            assert(not bt:find("titan%-runtime/"), "leaked runtime frame\n"..bt)
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
            assert(titan.backtrace():find("test_ga_titan", 1, true))
            pcall(test.gb)                       -- no pin: must regenerate
            local bt = titan.backtrace()
            assert(bt:find("test_gb_titan", 1, true), "did not regenerate")
            assert(not bt:find("test_ga_titan", 1, true), "stale trace stuck")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)
end)

-- Standalone-executable top-level handler (plan A.6). A module that defines
-- `main(args:{string}):integer` is linked into an executable whose C bootstrap
-- runs the Titan main in protected mode with `errorhandler` installed; an
-- uncaught error must print the message + the unified Lua+Titan trace to stderr
-- and exit non-zero, mirroring lua.c's msghandler/report.
describe("standalone main top-level error handler (error-handling A.6)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function()
        os.execute("rm -rf *.o *.so *.dSYM test test__entrypoint.c")
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    -- Build `titan_code` (which must define main) as a standalone "test", run it,
    -- and return (exit_status, combined_stdout_stderr).
    local function build_and_run_app(titan_code)
        h.reset()
        local ast, perr = parse(titan_code, "test.titan")
        assert.truthy(ast, perr)
        local _, errs = checker.check("test", ast, titan_code, "test.titan")
        assert.equal(0, #errs, table.concat(errs, "\n"))
        local ok, err = h.compile_app("test", ast)
        assert.truthy(ok, err)
        -- run capturing both streams; `; echo "EXIT:$?"` carries the status out
        local f = assert(io.popen("./test 2>&1; echo \"EXIT:$?\""))
        local out = f:read("*a")
        f:close()
        local status = tonumber(out:match("EXIT:(%d+)%s*$"))
        return status, out
    end

    it("prints message + unified trace to stderr and exits non-zero", function()
        -- main -> mid (Titan) -> deep (Titan) -> uncaught error. The bootstrap
        -- runs main under lua_pcall with errorhandler installed; the unified
        -- trace captured on the intact stack must reach stderr, carrying BOTH
        -- the Lua bootstrap frame(s) and the Titan native frames, and the
        -- process must exit non-zero.
        local status, out = build_and_run_app([[
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
        assert.truthy(status and status ~= 0,
                      "expected non-zero exit, got "..tostring(status).."\n"..out)
        -- single unified trace section reached stderr
        assert.truthy(out:find("stack traceback:", 1, true),
                      "no unified trace on stderr\n"..out)
        assert.falsy(out:find("C traceback:", 1, true))
        -- Titan native frames present (deep is the error site)
        assert.truthy(out:find("test_deep_titan", 1, true),
                      "missing Titan deep frame\n"..out)
        assert.truthy(out:find("test_mid_titan", 1, true),
                      "missing Titan mid frame\n"..out)
        -- and a Lua-level frame: the bootstrap require-chunk that called main
        assert.truthy(out:find("in main chunk", 1, true)
                      or out:find("in function") or out:find(":%d+: in"),
                      "missing Lua-side frame\n"..out)
        -- the error message itself is part of the printed report
        assert.truthy(out:find("type error", 1, true) or out:find("expected", 1, true),
                      "missing error message\n"..out)
    end)
end)

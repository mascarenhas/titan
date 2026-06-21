-- End-to-end coverage for the libbacktrace-based unified stack trace
-- (error-handling Phase 0: runtime + driver, no language syntax yet).
--
-- These tests generate C, compile it (linking ./libbacktrace/.libs/libbacktrace.a
-- before liblua.a, with -g), and run the result under lua-5.5.0/src/lua. They
-- assert on the merged `titan.backtrace()` string: the native (libbacktrace)
-- frames symbolized and merged with the Lua-side luaL_traceback, plus the
-- registry pin-flag discipline (preserve vs. regenerate).
local checker = require 'titan-compiler.checker'
local h = require 'spec.support.helpers'

local parse = h.parse
local compile = h.compile

local function clean()
    os.execute("rm -f *.o *.so")
    if not h.verbose then os.execute("rm -f *.c") end
end

-- Compile `titan_code` as module "test", then run `lua_test` under stock Lua
-- with `test` and `titan` available; returns the script's stdout.
local function compile_and_run(titan_code, lua_test)
    h.reset()
    local ast, perr = parse(titan_code)
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
        -- (shown by C symbol name pre-#line: <module>_<fn>_titan).
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

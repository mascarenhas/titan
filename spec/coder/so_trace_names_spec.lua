-- Cross-module trace-name coverage for the `.so`-ONLY import path (Phase-5
-- deliverable 2).
--
-- libbacktrace reports a native frame's MANGLED C symbol; the coder emits, in
-- each module's `_init`, a name table mapping that symbol to the qualified Titan
-- name (`<module>.<func>`), MERGED into a shared registry sub-table. Because
-- every loaded module's `_init` runs and merges (statically-linked AND dlopened
-- `.so` dependencies alike), a frame from a dlopened `.so` dependency must still
-- symbolize to its qualified name in an error trace.
--
-- This spec builds the raising function's module as a `.so`-ONLY dependency (its
-- `.titan` source never reaches the source path, so it is resolved via dlopen,
-- not statically linked — see build_so_chain) and asserts the trace shows the
-- dep's qualified `<module>.<func>` name, proving the cross-`.so` name merge.
local h = require 'spec.support.helpers'
local build_so_chain, call = h.build_so_chain, h.call

describe(".so-only cross-module trace names (Phase 5 deliverable 2)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -rf *.o *.so *.dSYM")
        os.execute("rm -f *.c")
    end)

    it("shows the qualified <module>.<func> name for a frame from a dlopened .so dep",
       function ()
        local ok, err = build_so_chain({
            { name = "dfoo", src = [[
                function kaboom(): integer
                    raise "from-dfoo"
                    return 0
                end
            ]] },
            { name = "dbar", src = [[
                local foo = import "dfoo"
                function go(): integer
                    return foo.kaboom()
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("dbar", [[
            local titan = require 'titan'
            local ok, err = pcall(dbar.go)
            assert(not ok, "expected the .so dep's raise to propagate")
            assert(err == "from-dfoo", "wrong error value: " .. tostring(err))
            local bt = titan.backtrace()
            -- the raising frame lives in the dlopened dfoo.so; its qualified name
            -- is only present if dfoo's _init merged its names into the shared
            -- registry table across the .so boundary
            assert(bt:find("in dfoo.kaboom", 1, true),
                   "missing qualified .so-dep frame name\n" .. bt)
            -- and the caller's own frame is qualified too
            assert(bt:find("in dbar.go", 1, true),
                   "missing caller frame\n" .. bt)
        ]])
        assert.truthy(rok, out)
    end)
end)

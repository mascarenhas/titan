-- Cross-module trace-name coverage for the `.so`-ONLY import path.
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

describe(".so-only cross-module trace names", function()
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

    it("symbolizes a .so that is dlopened after libbacktrace has already snapshotted",
       function ()
        local ok, err = build_so_chain({
            { name = "btfirst", src = [[
                function boom(): integer
                    raise "first"
                    return 0
                end
            ]] },
            { name = "btsecond", src = [[
                function boom(): integer
                    raise "second"
                    return 0
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("btfirst", [[
            local titan = require 'titan'
            local ok1, err1 = pcall(btfirst.boom)
            assert(not ok1 and err1 == "first")
            local t1 = titan.backtrace()
            assert(t1:find("in btfirst.boom", 1, true),
                   "first trace did not symbolize btfirst\n" .. tostring(t1))

            -- This require dlopens btsecond AFTER the previous trace forced
            -- libbacktrace to create/snapshot its state. loadlib must invalidate
            -- that state on the slow dlopen path, or btsecond's native frames are
            -- unsymbolized and get filtered out.
            local second = require 'btsecond'
            local ok2, err2 = pcall(second.boom)
            assert(not ok2 and err2 == "second")
            local t2 = titan.backtrace()
            assert(t2:find("in btsecond.boom", 1, true),
                   "post-dlopen trace did not symbolize btsecond\n" .. tostring(t2))
            assert(not t2:find("in btfirst.boom", 1, true),
                   "post-dlopen trace kept the previous module's frame\n" .. t2)
        ]])
        assert.truthy(rok, out)
    end)

    it("resymbolizes a Lua-required plugin called under an older module's handler",
       function ()
        local ok, err = build_so_chain({
            { name = "bthost", src = [[
                function boom(): integer
                    raise "host"
                    return 0
                end
                function apply(f: function (): integer): integer
                    return f()
                end
            ]] },
            { name = "btplugin", src = [[
                function boom(): integer
                    raise "plugin"
                    return 0
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("bthost", [[
            local titan = require 'titan'
            local ok1, err1 = pcall(bthost.boom)
            assert(not ok1 and err1 == "host")
            assert(titan.backtrace():find("in bthost.boom", 1, true))

            -- Lua's own require dlopens btplugin after bthost's runtime has
            -- already snapshotted libbacktrace. The subsequent error is raised by
            -- btplugin's native function, but under bthost.apply's Titan entry
            -- handler, so bthost's runtime archive must notice the shared
            -- invalidation.
            local plugin = require 'btplugin'
            local ok2, err2 = pcall(bthost.apply, plugin.boom)
            assert(not ok2 and err2 == "plugin")
            local bt = titan.backtrace()
            assert(bt:find("in btplugin.boom", 1, true),
                   "plugin frame missing under host handler after Lua require\n" .. tostring(bt))
            assert(bt:find("in bthost.apply", 1, true),
                   "host caller frame missing under host handler\n" .. tostring(bt))
        ]])
        assert.truthy(rok, out)
    end)
end)

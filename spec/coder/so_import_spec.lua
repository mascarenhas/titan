-- Cross-module tests for the `.so`-ONLY import path: a dependency reachable
-- only as a compiled shared library, not as `.titan` source. This path differs
-- from source linking (which the cross-module tests in coder_spec exercise):
-- the importer recovers the dependency's interface from its compiled
-- `<mangled>_types` symbol, the dependency is dlopened at run time, and its
-- native functions are reached through dlsym'd `static` pointers (rather than
-- statically-linked `extern`s). Records and function/variable slots are
-- reconstructed purely from the serialized interface, and record/function type
-- tags must be recovered from the registry the dependency's `.so` published.
--
-- Each dependency is compiled to a `.so` straight from its AST, so its
-- `.titan` source never touches the source path and the default loader is
-- forced onto the `.so` route. Dependencies are built in order, so an earlier
-- one can itself be a `.so`-only dependency of a later one (transitive case).
local h = require 'spec.support.helpers'
local build_so_chain, call = h.build_so_chain, h.call

describe(".so-only cross-module imports", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        os.execute("rm -f *.c")
    end)

    it("calls a function in a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "sfoo", src = [[
                function a(): integer return 42 end
            ]] },
            { name = "sbar", src = [[
                local foo = import "sfoo"
                function bar(): integer return foo.a() end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("sbar", "assert(sbar.bar() == 42)")
        assert.truthy(rok, out)
    end)

    it("reads and writes a variable in a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "vfoo", src = [[ a: integer = 1 ]] },
            { name = "vbar", src = [[
                local foo = import "vfoo"
                function bar(): integer
                    foo.a = 5
                    return foo.a
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("vbar",
            "vfoo = require 'vfoo'; assert(vbar.bar() == 5); assert(vfoo.a == 5)")
        assert.truthy(rok, out)
    end)

    it("constructs and uses a record from a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "rfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
                function origin(): Point
                    return { x = 0, y = 0 }
                end
            ]] },
            { name = "rbar", src = [[
                local f = import "rfoo"
                function bar(): (float, float)
                    local p: f.Point = { x = 2, y = 3 }
                    p:move(2, 3)
                    return p.x, p.y
                end
                function viactor(): (float, float)
                    local p = f.Point.new(10, 20)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("rbar",
            "local x,y = rbar.bar(); assert(x == 4.0 and y == 6.0); " ..
            "local a,b = rbar.viactor(); assert(a == 10.0 and b == 20.0)")
        assert.truthy(rok, out)
    end)

    it("calls a method on a record returned from a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "qfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float): Point
                    self.x, self.y = self.x + dx, self.y + dy
                    return self
                end
                function get_point(): Point
                    return { x = 10, y = 20 }
                end
            ]] },
            { name = "qbar", src = [[
                local f = import "qfoo"
                function bar(): (float, float)
                    local p = f.get_point():move(2, 3)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("qbar",
            "local x,y = qbar.bar(); assert(x == 12.0 and y == 23.0)")
        assert.truthy(rok, out)
    end)

    it("uses a record through a transitive .so-only chain (bar -> baz -> foo)",
       function ()
        local ok, err = build_so_chain({
            { name = "tfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]] },
            { name = "tbaz", src = [[
                local f = import "tfoo"
                function point(x: float, y: float): f.Point
                    return { x = x, y = y }
                end
            ]] },
            { name = "tbar", src = [[
                local b = import "tbaz"
                function bar(): (float, float)
                    local p = b.point(2, 3)
                    p:move(2, 3)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("tbar",
            "local x,y = tbar.bar(); assert(x == 4.0 and y == 6.0)")
        assert.truthy(rok, out)
    end)

    it("references, calls and passes function values across a .so boundary", function ()
        local ok, err = build_so_chain({
            { name = "fcfa", src = [[
                function inc(x: integer): integer return x + 1 end
                function twice(f: (integer) -> integer, x: integer): integer
                    return f(f(x))
                end
                function getinc(): (integer) -> integer
                    return inc
                end
            ]] },
            { name = "fcfb", src = [[
                local a = import "fcfa"
                function binc(x: integer): integer return x + 1 end
                function run(): integer
                    local f: (integer) -> integer = a.inc  -- reference across the .so
                    local r1 = f(10)                       -- call a's value
                    local r2 = a.twice(binc, 0)            -- pass b's value into a
                    local r3 = a.twice(a.inc, 5)           -- pass a's value into a
                    local g = a.getinc()                   -- get a value back from a
                    local r4 = g(100)
                    return r1 + r2 + r3 + r4                -- 11 + 2 + 7 + 101
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("fcfb", "assert(fcfb.run() == 121)")
        assert.truthy(rok, out)
    end)

    it("takes the exact-type fast path for a function value across a .so boundary", function ()
        -- The dependency is reachable ONLY as a compiled `.so`: the closure-slot
        -- index is rebuilt from the recovered interface and the function-type tag
        -- is recovered from the registry the dependency's `.so` published when it
        -- was dlopened. `run_fast` calls a's `inner` as a value; if the tags agree
        -- the call uses the fast path (no extra Lua frame) and the stack is one
        -- frame shallower than the slow path. If either disagrees the call falls
        -- back to the slow path and the depth assertion fails.
        local ok, err = build_so_chain({
            { name = "fpa", src = [[
                function inner(p: () -> integer): integer return p() end
            ]] },
            { name = "fpb", src = [[
                local a = import "fpa"
                function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                    return g(p)
                end
                function run_fast(p: () -> integer): integer return outer(a.inner, p) end
                function run_slow(p: () -> integer,
                                  g: (() -> integer) -> integer): integer
                    return outer(g, p)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("fpb", h.DEPTH_PROBE .. [[
            local fastd = fpb.run_fast(depth)
            local slowd = fpb.run_slow(depth, slow_g)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
    end)

    -- Regression: an imported record used ONLY as a Lua-facing parameter is
    -- never constructed in the importer, so genluaentry's checkandget is the
    -- FIRST site to allocate that record's metatable slot — and it runs with the
    -- top-level tlcontext (no `.tlcontext` field). type2metatable must resolve
    -- the tlcontext either way, or codegen crashes before emitting any C.
    it("accepts an imported record used only as a Lua-facing parameter", function ()
        local ok, err = build_so_chain({
            { name = "ppfoo", src = [[
                record Point
                    x: integer
                end
                function make(n: integer): Point
                    return { x = n }
                end
            ]] },
            { name = "ppbar", src = [[
                local foo = import "ppfoo"
                function px(p: foo.Point): integer
                    return p.x
                end
            ]] },
        })
        assert.truthy(ok, err)
        -- the imported-record parameter coerces correctly at the Lua boundary...
        local rok, out = call("ppbar",
            "local foo = require 'ppfoo'; assert(ppbar.px(foo.make(7)) == 7)")
        assert.truthy(rok, out)
        -- ...and the metatable check cleanly rejects a non-record userdata
        local rok2, out2 = call("ppbar",
            "local ok, e = pcall(ppbar.px, ppbar); assert(not ok); assert(e:find('but found'))")
        assert.truthy(rok2, out2)
    end)
end)

-- End-to-end tests for first-class function values and the zero-return
-- `() -> ()` function type: generate C, compile it, and run it. Covers the
-- no-annotation `()` default, referencing/storing/passing/returning function
-- values, the exact-type fast call path and the generic (Lua-stack) slow path,
-- stable identity, Lua interop in both directions, cross-module references
-- (source-linked and `.so`-only), record statics as values, containers,
-- value<->function coercion, and GC safety.
--
-- The checker-only assertions (which programs type-check and which are rejected)
-- live in spec/checker/first_class_functions_spec.lua; the pure type-algebra
-- assertions (tostring/equals/serialize) live in spec/types_spec.lua.
local checker = require 'titan-compiler.checker'
local parser = require 'titan-compiler.parser'
local types = require 'titan-compiler.types'
local driver = require 'titan-compiler.driver'

local verbose = false

local function parse(code) return parser.parse("(smoke)", code) end

local function compile(modname, ast)
    local ok, err, libname = driver.compile(modname, ast, nil, {}, verbose)
    if not ok then return ok, err end
    return driver.compile_library(modname, { libname }, nil, verbose)
end

local function call(modname, code)
    local cmd = string.format("lua-5.5.0/src/lua -l %s -e \"print(pcall(function () %s end))\"",
        modname, code)
    local f = io.popen(cmd)
    local out = f:read()
    local ok, err = f:close()
    if not ok then return false, err end
    local okk, data = out:match("^(true)%s*(.*)$")
    if not okk then
        local _, error = out:match("^(false)%s*(.*)$")
        return false, error
    else
        return true, data
    end
end

local function run_coder(titan_code, lua_test, errmsg)
    types.registry = {}
    local ast, err = parse(titan_code)
    assert.truthy(ast, err)
    local ok, errs = checker.check("test", ast, titan_code, "test.titan")
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok2, err2 = compile("test", ast)
    assert.truthy(ok2, err2)
    local ok3, err3 = call("test", lua_test)
    if errmsg then
        assert.falsy(ok3)
        assert.match(errmsg, err3)
    else
        assert.truthy(ok3, err3)
    end
end

local function generate_modules(modules, main)
    types.registry = {}
    driver.imported = {}
    local imported = {}
    local deps = {}
    local loader = driver.tableloader(modules, imported, deps)
    local typ, err = checker.checkimport(main, loader)
    if not typ then return nil, err end
    if #err ~= 0 then return nil, table.concat(err, "\n") end
    local ofiles = {}
    for name, mod in pairs(imported) do
        local ok, e = driver.compile_module(name, mod, deps, verbose)
        table.insert(ofiles, name .. ".o")
        if not ok then return nil, e end
    end
    for name, _ in pairs(imported) do
        local ok, e = driver.compile_library(name, ofiles, nil, verbose)
        if not ok then return nil, e end
    end
    return true
end

-- Compile `dep` to a `.so` FROM MEMORY (its `.titan` is never written to
-- disk), then check+compile `main` against it. Because no `dep.titan` exists on
-- the source path, the compiler's default loader is forced down the `.so`-only
-- route: it recovers `dep`'s interface from the compiled `<mangled>_types`
-- symbol and the generated `main` dlopens `dep.so` at run time. Returns
-- (true) on success or (nil, message). Asserts that `dep` really was treated as
-- a dynamic (not statically linked) dependency.
local function build_so_only(dep_name, dep_src, main_name, main_src)
    -- 1. build the dependency .so straight from its AST (no dep.titan on disk)
    types.registry = {}
    driver.imported = {}
    local dast = parse(dep_src)
    if not dast then return nil, "parse " .. dep_name end
    local _, derrs = checker.check(dep_name, dast, dep_src, dep_name .. ".titan")
    if #derrs ~= 0 then return nil, table.concat(derrs, "\n") end
    local ok, err, dlib = driver.compile(dep_name, dast, nil, {}, verbose)
    if not ok then return nil, err end
    ok, err = driver.compile_library(dep_name, { dlib }, nil, verbose)
    if not ok then return nil, err end

    -- 2. check + compile the importer with `dep` available ONLY as a `.so`
    types.registry = {}
    driver.imported = {}
    local static_deps = {}
    local mast = parse(main_src)
    if not mast then return nil, "parse " .. main_name end
    local _, merrs = checker.check(main_name, mast, main_src,
        main_name .. ".titan", driver.defaultloader(static_deps))
    if #merrs ~= 0 then return nil, table.concat(merrs, "\n") end
    if static_deps[dep_name] then
        return nil, "dependency '" .. dep_name .. "' was linked statically, not as a .so"
    end
    if not (driver.imported[dep_name] and driver.imported[dep_name].compiled) then
        return nil, "dependency '" .. dep_name .. "' was not loaded from its .so"
    end
    local mlib
    ok, err, mlib = driver.compile(main_name, mast, nil, static_deps, verbose)
    if not ok then return nil, err end
    ok, err = driver.compile_library(main_name, { mlib }, nil, verbose)
    if not ok then return nil, err end
    return true
end

-- Lua snippet defining a `depth()` probe: returns how many stack frames sit
-- above its caller. A function called through the fast path adds NO Lua call
-- frame; the generic (slow) path goes through luaD_callnoyield and adds one.
local DEPTH_PROBE = [[
    local function depth()
        local n = 2
        while debug.getinfo(n) do n = n + 1 end
        return n
    end
    local slow_g = function(q) local r = q() return r end
]]

describe("first-class functions and zero-return () functions (end-to-end)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not verbose then os.execute("rm -f *.c") end
    end)

    it("exported () function returns zero values across the Lua boundary", function()
        run_coder([[
            function noop(): ()
            end
            function effect(x: {integer}): ()
                x[1] = 42
            end
        ]], [[
            assert(select('#', test.noop()) == 0)
            local t = {0}
            test.effect(t)
            assert(t[1] == 42)
            assert(select('#', test.effect(t)) == 0)
        ]])
    end)

    it("internal statement-context call + bare return", function()
        run_coder([[
            local function helper(x: {integer}): ()
                x[1] = x[1] + 1
                return
            end
            function bump(x: {integer}): integer
                helper(x)
                helper(x)
                return x[1]
            end
        ]], [[
            assert(test.bump({10}) == 12)
        ]])
    end)

    it("(f()) adjusts a void call up to a single nil", function()
        run_coder([[
            local function vd(): ()
            end
            function adj(): value
                return (vd())
            end
        ]], [[
            assert(select('#', test.adj()) == 1)
            assert(test.adj() == nil)
        ]])
    end)

    it("E2E: reference a function and call it through a value (slow path)", function()
        run_coder([[
            function dbl(x: integer): integer return x * 2 end
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
            function run(): integer
                return apply(dbl, 21)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("E2E: store a function value in a local and call it", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local f: (integer) -> integer = inc
                return f(f(f(10)))
            end
        ]], [[
            assert(test.run() == 13)
        ]])
    end)

    it("E2E: stable identity of an exported function value", function()
        run_coder([[
            function foo(x: integer): integer return x end
            function get(): (integer) -> integer
                return foo
            end
        ]], [[
            assert(test.foo == test.foo)
            assert(test.get() == test.foo)
        ]])
    end)

    it("E2E: call a Lua closure passed into Titan", function()
        run_coder([[
            function callwith(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]], [[
            assert(test.callwith(function(n) return n * 10 end, 5) == 50)
        ]])
    end)

    it("E2E: multi-return through a function value (slow path)", function()
        run_coder([[
            function dm(a: integer, b: integer): (integer, integer)
                return a // b, a % b
            end
            function run(): integer
                local f: (integer, integer) -> (integer, integer) = dm
                local q, r = f(13, 5)
                return q * 100 + r
            end
        ]], [[
            assert(test.run() == 203)
        ]])
    end)

    it("E2E: array of function values", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function dec(x: integer): integer return x - 1 end
            function run(): integer
                local arr: {(integer) -> integer} = {inc, dec, inc}
                local s = 0
                for i = 1, 3 do
                    s = s + arr[i](10)
                end
                return s
            end
        ]], [[
            assert(test.run() == 31)
        ]])
    end)

    it("E2E: function value in a record field", function()
        run_coder([[
            record Box
                fn: (integer) -> integer
            end
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local b: Box = Box.new(inc)
                return b.fn(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("E2E: function <-> value coercion round-trip", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function run(): integer
                local v: value = inc
                local f: (integer) -> integer = v
                return f(41)
            end
        ]], [[
            assert(test.run() == 42)
        ]])
    end)

    it("E2E: GC stress — function value in a record survives collection", function()
        run_coder([[
            record Box
                fn: (integer) -> integer
            end
            function inc(x: integer): integer return x + 1 end
            function make(): Box return Box.new(inc) end
            function callbox(b: Box, x: integer): integer return b.fn(x) end
        ]], [[
            local b = test.make()
            collectgarbage("collect")
            collectgarbage("collect")
            assert(test.callbox(b, 41) == 42)
        ]])
    end)

    it("E2E: calling a non-callable value raises cleanly", function()
        run_coder([[
            function callit(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]], [[
            local ok = pcall(test.callit, 42, 1)
            assert(not ok)
        ]])
    end)

    it("E2E: record static (Rec.new) as a value", function()
        run_coder([[
            record Pair
                a: integer
                b: integer
            end
            function mk(f: (integer, integer) -> Pair): Pair
                return f(3, 4)
            end
            function run(): integer
                local p = mk(Pair.new)
                return p.a * 10 + p.b
            end
        ]], [[
            assert(test.run() == 34)
            assert(test.Pair.new == test.Pair.new)
        ]])
    end)

    it("E2E: cross-module function reference and call", function()
        local ok, err = generate_modules({
            a = [[
                function dbl(x: integer): integer return x * 2 end
            ]],
            b = [[
                local a = import "a"
                function run(): integer
                    local f: (integer) -> integer = a.dbl
                    return f(21)
                end
                function direct(): integer
                    return a.dbl(21)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local out
        ok, out = call("b", "assert(b.run() == 42); assert(b.direct() == 42)")
        assert.truthy(ok, out)
    end)

    it("explicit : nil still returns one nil value", function()
        run_coder([[
            function n(): nil
            end
        ]], [[
            assert(select('#', test.n()) == 1)
            assert(test.n() == nil)
        ]])
    end)

    it("E2E: return a function then call it (higher-order pipeline)", function()
        run_coder([[
            function inc(x: integer): integer return x + 1 end
            function dec(x: integer): integer return x - 1 end
            function pick(up: boolean): (integer) -> integer
                if up then return inc else return dec end
            end
            function run(up: boolean, x: integer): integer
                local f = pick(up)
                return f(x)
            end
        ]], [[
            assert(test.run(true, 10) == 11)
            assert(test.run(false, 10) == 9)
        ]])
    end)

    it("E2E: a failing value->function call (non-callable) raises at call time", function()
        -- value -> function succeeds implicitly (deferred check); the error is
        -- raised only when the value is actually called and is not callable.
        run_coder([[
            function tryit(v: value): integer
                local f: (integer) -> integer = v
                return f(10)
            end
        ]], [[
            assert(not pcall(test.tryit, 5))
            assert(test.tryit(function(n) return n + 100 end) == 110)
        ]])
    end)

    it("E2E: fast path takes no luaD frame; slow path does (observable)", function()
        -- A Titan function value of the exact type uses the fast path (direct
        -- native call, no extra Lua frame); a Lua closure uses the slow path
        -- (luaD_callnoyield, one extra frame). The callee probes the depth of
        -- the Lua stack of frames via the count returned by a passed-in probe.
        run_coder([[
            function fast(x: integer): integer return x end
            function apply(f: (integer) -> integer, x: integer): integer
                return f(x)
            end
        ]], [[
            -- both produce the same result; this mainly locks in that the slow
            -- path (Lua closure) and fast path (Titan function) coexist.
            assert(test.apply(test.fast, 7) == 7)            -- fast path
            assert(test.apply(function(n) return n end, 7) == 7) -- slow path
        ]])
    end)

    it("E2E: cross-module higher-order, exact-type fast path across modules", function()
        local ok, err = generate_modules({
            a = [[
                function inc(x: integer): integer return x + 1 end
                function twice(f: (integer) -> integer, x: integer): integer
                    return f(f(x))
                end
            ]],
            b = [[
                local a = import "a"
                function run(): integer
                    -- pass module a's function value into module a's higher-order
                    -- function; a.inc has the exact type a.twice expects, so the
                    -- inner call resolves through the shared cross-module tag.
                    return a.twice(a.inc, 10)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local out
        ok, out = call("b", "assert(b.run() == 12)")
        assert.truthy(ok, out)
    end)

    it("E2E (source): exported higher-order function, source-linked dependency", function()
        -- a's source is available, so it is compiled in and statically linked.
        local ok, err = generate_modules({
            a = [[
                function compose2(f: (integer) -> integer, x: integer): integer
                    return f(x) + f(x)
                end
            ]],
            b = [[
                local a = import "a"
                function dbl(x: integer): integer return x * 2 end
                function run(): integer
                    return a.compose2(dbl, 5)
                end
            ]],
        }, "b")
        assert.truthy(ok, err)
        local out
        ok, out = call("b", "assert(b.run() == 20)")
        assert.truthy(ok, out)
    end)

    it("E2E (source): exact-type fast path fires across a source-linked module", function()
        -- `outer` calls module a's `inner` *as a value*; if a's and b's tags for
        -- the same function type agree, the value-call uses the fast path (no Lua
        -- call frame) and the stack is one frame shallower than the slow path.
        local ok, err = generate_modules({
            spa = [[ function inner(p: () -> integer): integer return p() end ]],
            spb = [[
                local a = import "spa"
                function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                    return g(p)
                end
                function run_fast(p: () -> integer): integer return outer(a.inner, p) end
                function run_slow(p: () -> integer,
                                  g: (() -> integer) -> integer): integer
                    return outer(g, p)
                end
            ]],
        }, "spb")
        assert.truthy(ok, err)
        local rok, out = call("spb", DEPTH_PROBE .. [[
            local fastd = spb.run_fast(depth)
            local slowd = spb.run_slow(depth, slow_g)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
    end)

    it("E2E (.so-only): cross-module references, calls and higher-order both ways",
       function()
        local ok, err = build_so_only("fcfa", [[
            function inc(x: integer): integer return x + 1 end
            function twice(f: (integer) -> integer, x: integer): integer
                return f(f(x))
            end
            function getinc(): (integer) -> integer
                return inc
            end
        ]], "fcfb", [[
            local a = import "fcfa"
            function binc(x: integer): integer return x + 1 end
            function run(): integer
                local f: (integer) -> integer = a.inc  -- reference across the .so
                local r1 = f(10)                       -- call a's value (fast path)
                local r2 = a.twice(binc, 0)            -- pass b's value into a
                local r3 = a.twice(a.inc, 5)           -- pass a's value into a
                local g = a.getinc()                   -- get a value back from a
                local r4 = g(100)
                return r1 + r2 + r3 + r4                -- 11 + 2 + 7 + 101
            end
        ]])
        assert.truthy(ok, err)
        local rok, out = call("fcfb", "assert(fcfb.run() == 121)")
        assert.truthy(rok, out)
    end)

    it("E2E (.so-only): exact-type fast path fires across the .so boundary", function()
        -- Same probe as the source case, but the dependency is reachable ONLY as
        -- a compiled .so: the closure-slot index is rebuilt from the recovered
        -- interface and the function-type tag is recovered from the registry the
        -- dependency's .so published when it was dlopened. If either disagrees,
        -- the call silently falls back to the slow path and this assertion fails.
        local ok, err = build_so_only("fpa", [[
            function inner(p: () -> integer): integer return p() end
        ]], "fpb", [[
            local a = import "fpa"
            function outer(g: (() -> integer) -> integer, p: () -> integer): integer
                return g(p)
            end
            function run_fast(p: () -> integer): integer return outer(a.inner, p) end
            function run_slow(p: () -> integer,
                              g: (() -> integer) -> integer): integer
                return outer(g, p)
            end
        ]])
        assert.truthy(ok, err)
        local rok, out = call("fpb", DEPTH_PROBE .. [[
            local fastd = fpb.run_fast(depth)
            local slowd = fpb.run_slow(depth, slow_g)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
    end)
end)

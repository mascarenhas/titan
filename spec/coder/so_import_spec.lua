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
local checker = require 'titan-compiler.checker'
local parser = require 'titan-compiler.parser'
local types = require 'titan-compiler.types'
local driver = require 'titan-compiler.driver'

local verbose = false

local function parse(code) return parser.parse("(so_import)", code) end

-- Build a chain of `.so`-only modules. `mods` is an array of {name=, src=} in
-- dependency order (each may import earlier ones); the last entry is the module
-- under test. Returns true, or (nil, message). Verifies every dependency was
-- resolved dynamically (from its `.so`), never statically linked.
local function build_so_chain(mods)
    local names = {}
    for _, m in ipairs(mods) do names[m.name] = true end
    for i, m in ipairs(mods) do
        types.registry = {}
        driver.imported = {}            -- force `.so` resolution of earlier deps
        local static_deps = {}
        local ast = parse(m.src)
        if not ast then return nil, "parse error in " .. m.name end
        local _, errs = checker.check(m.name, ast, m.src, m.name .. ".titan",
            driver.defaultloader(static_deps))
        if #errs ~= 0 then return nil, m.name .. ": " .. table.concat(errs, "\n") end
        for dep in pairs(static_deps) do
            if names[dep] and dep ~= m.name then
                return nil, m.name .. " linked '" .. dep .. "' statically, not via .so"
            end
        end
        local ok, err, lib = driver.compile(m.name, ast, nil, static_deps, verbose)
        if not ok then return nil, err end
        ok, err = driver.compile_library(m.name, { lib }, nil, verbose)
        if not ok then return nil, err end
    end
    return true
end

local function call(modname, code)
    local cmd = string.format(
        "lua-5.5.0/src/lua -l %s -e \"print(pcall(function () %s end))\"",
        modname, code)
    local f = io.popen(cmd)
    local out = f:read()
    f:close()
    if not out then return false, "no output" end
    if out:match("^true") then return true, out:match("^true%s*(.*)$") end
    return false, out:match("^false%s*(.*)$") or out
end

describe(".so-only cross-module imports", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(function ()
        os.execute("rm -f *.o *.so")
        if not verbose then os.execute("rm -f *.c") end
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
end)

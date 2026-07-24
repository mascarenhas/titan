-- Shared test helpers for the Titan spec suite. Required by the checker and
-- coder specs so the compile/run/import scaffolding lives in one place instead
-- of being copied into every file.
--
-- Everything here assumes busted is run from the repo root (driver/artifact
-- paths are relative to the CWD, not to the spec file). Flip `M.verbose` to true
-- to print the `cc` command lines and keep the generated `.c` files.
local checker = require 'titan-compiler.checker'
local parser = require 'titan-compiler.parser'
local types = require 'titan-compiler.types'
local driver = require 'titan-compiler.driver'

-- A `require`d module does not inherit busted's `assert` (luassert) global, so
-- bring it in explicitly. luassert's `assert` is a superset of Lua's `assert`,
-- so `assert(v)` still works alongside `assert.truthy(...)` etc.
local assert = require 'luassert'

local M = {}

M.verbose = false
local function verbose() return M.verbose end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

-- Prefer an explicitly configured standalone prefix and otherwise use the
-- working Lua from PATH.
local configured_prefix = os.getenv("PREFIX")
local configured_lua = configured_prefix and
    (configured_prefix .. "/bin/lua") or nil
local LUA = configured_lua and file_exists(configured_lua) and configured_lua
    or "lua"

-- Reset the process-global compiler state shared through `require` so one test
-- never leaks types or import caches into the next.
local function reset(imports)
    types.registry = {}
    if imports then driver.imported = {} end
end
M.reset = reset

-- A checker probe session owns one compile-probe service so a spec which
-- repeatedly checks immutable foreign headers can reuse exact compiler-query
-- results. Loader and C-type identity state remain fresh for every check. The
-- caller must close the session and must not rewrite a previously queried path
-- while it is live.
function M.new_checker_probe_session()
    return driver.new_resolver_context()
end

function M.close_checker_probe_session(session)
    local ok, err = driver.close_resolver_context(session)
    assert.truthy(ok, err)
end

local function checker_probe_options(session)
    if not session then return nil end
    return {
        probe_service_provider = function()
            return driver.get_probe_service(session)
        end,
    }
end

-- Production libuv is compiled with this feature-test macro on Linux. Scope
-- the same flag around compiler/codegen fixtures which import uv.h directly,
-- then restore the process-global driver configuration even if an assertion
-- fails.
function M.with_libuv_feature_flags(body)
    if not driver.UNAME:find("Linux", 1, true) then
        return body()
    end

    local previous = driver.EXTRA_CPPFLAGS
    local configured = {}
    for _, flag in ipairs(previous or {}) do
        configured[#configured + 1] = flag
    end
    configured[#configured + 1] = "-D_GNU_SOURCE"
    driver.EXTRA_CPPFLAGS = configured
    driver.configure_foreign_c()

    local results = table.pack(xpcall(body, debug.traceback))
    driver.EXTRA_CPPFLAGS = previous
    driver.configure_foreign_c()
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

function M.parse(code, chunkname)
    return parser.parse(chunkname or "(spec)", code)
end

-- ===== code generation: compile a single module / app =====

function M.compile(modname, ast)
    local ok, err, libname = driver.compile(modname, ast, nil, {}, verbose())
    if not ok then return ok, err end
    return driver.compile_library(modname, { libname }, nil, verbose())
end

function M.compile_app(modname, ast)
    local ok, err, libname = driver.compile(modname, ast, nil, {}, verbose())
    if not ok then return ok, err end
    return driver.compile_program(modname, { libname }, nil, verbose())
end

-- Run `code` under the stock Lua interpreter with `modname` loaded (`-l`),
-- wrapped in pcall. Returns (true, output) on success, or (false, message).
-- The driver code is written to a temp script and run by path rather than via
-- `-e`, so quote characters in `code` (e.g. double-quoted Lua string literals)
-- cannot collide with the shell's quoting of the command line.
function M.call(modname, code)
    local script = os.tmpname()
    local sf = assert(io.open(script, "w"))
    sf:write(string.format("print(pcall(function () %s end))\n", code))
    sf:close()
    local cmd = string.format(
        "%s -l %s %s", LUA, modname, script)
    local f = io.popen(cmd)
    if not f then
        os.remove(script); return false, "popen failed"
    end
    local out = f:read()
    local ok = f:close()
    os.remove(script)
    if not ok then return false, out or "process error" end
    if not out then return false, "no output" end
    local data = out:match("^true%s*(.*)$")
    if data then return true, data end
    return false, out:match("^false%s*(.*)$") or out
end

function M.call_app(appname, ...)
    local cmd = table.concat({ appname, ... }, " ")
    local f = io.popen(cmd)
    if not f then return false, "popen failed", nil, "" end
    local out = f:read() or ""
    local ok, err, status = f:close()
    if err == "exit" then ok = true end
    if not verbose() then
        os.remove(appname)
        -- macOS: dsymutil leaves a `<exe>.dSYM` bundle (a directory) next to the
        -- executable for libbacktrace symbolization; no-op elsewhere.
        os.execute("rm -rf " .. appname .. ".dSYM")
    end
    return ok, err, status, out
end

-- Check + compile + run `titan_code` as module "test". When `errmsg` is given,
-- expects the run to fail with a matching error; otherwise expects success.
function M.run_coder(titan_code, lua_test, errmsg)
    reset()
    local ast, perr = M.parse(titan_code)
    assert.truthy(ast, perr)
    local _, errs = checker.check("test", ast, titan_code, "test.titan")
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = M.compile("test", ast)
    assert.truthy(ok, err)
    local rok, rerr = M.call("test", lua_test)
    if errmsg then
        assert.falsy(rok)
        assert.match(errmsg, rerr)
    else
        assert.truthy(rok, rerr)
    end
end

-- Check + compile `titan_code` as `modname` (default "test"), parsed under the
-- matching `<modname>.titan` chunk name so generated `#line` directives carry a
-- realistic source path, then run `lua_test` with the module loaded. Returns
-- the script's stdout.
function M.compile_and_run(titan_code, lua_test, modname)
    modname = modname or "test"
    reset()
    local filename = modname:gsub("[.]", "/") .. ".titan"
    local ast, perr = M.parse(titan_code, filename)
    assert.truthy(ast, perr)
    local _, errs = checker.check(modname, ast, titan_code, filename)
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = M.compile(modname, ast)
    assert.truthy(ok, err)

    local script = os.tmpname()
    local sf = assert(io.open(script, "w"))
    sf:write(lua_test)
    sf:close()
    local f = assert(io.popen(LUA .. " -l " .. modname .. " " .. script))
    local out = f:read("*a")
    f:close()
    os.remove(script)
    return out
end

-- Check + compile `titan_code` as `modname` (default "test") and return the
-- generated C source followed by the checked AST.
function M.compile_and_read_c(titan_code, modname)
    modname = modname or "test"
    reset()
    local filename = modname:gsub("[.]", "/") .. ".titan"
    local ast, perr = M.parse(titan_code, filename)
    assert.truthy(ast, perr)
    local _, errs = checker.check(modname, ast, titan_code, filename)
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = M.compile(modname, ast)
    assert.truthy(ok, err)
    local f = assert(io.open(modname:gsub("[.]", "/") .. ".c", "r"))
    local csrc = f:read("*a")
    f:close()
    return csrc, ast
end

-- Check + compile `titan_code` as a standalone program and run it, capturing
-- both stdout and stderr. Returns (exit_status, combined_output).
function M.compile_and_run_app(titan_code, modname)
    modname = modname or "test"
    reset()
    local filename = modname:gsub("[.]", "/") .. ".titan"
    local ast, perr = M.parse(titan_code, filename)
    assert.truthy(ast, perr)
    local _, errs = checker.check(modname, ast, titan_code, filename)
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = M.compile_app(modname, ast)
    assert.truthy(ok, err)

    local execname = "./" .. modname:gsub("[.]", "/")
    local f = assert(io.popen(execname .. " 2>&1; echo \"EXIT:$?\""))
    local out = f:read("*a")
    f:close()
    local status = tonumber(out:match("EXIT:(%d+)%s*$"))
    out = out:gsub("EXIT:%d+%s*$", "")
    if not verbose() then
        os.remove(execname)
        os.execute("rm -rf " .. execname .. ".dSYM")
    end
    return status, out
end

-- Build a standalone executable from `titan_code` plus a synthesized `main` and
-- run it, asserting the exit status (and optionally a substring of its output).
function M.run_coder_app(titan_code, main, estatus, eout)
    reset()
    local code = string.format([[
        %s
        function main(args: {string}): integer
            %s
        end
    ]], titan_code, main)
    local ast, perr = M.parse(code)
    assert.truthy(ast, perr)
    local _, errs = checker.check("test", ast, code, "test.titan")
    assert.equal(0, #errs, table.concat(errs, "\n"))
    local ok, err = M.compile_app("test", ast)
    assert.truthy(ok, err)
    local rok, rerr, status, output = M.call_app("./test")
    assert.truthy(rok, rerr)
    assert.equal(estatus, status)
    if eout then assert.match(eout, output) end
end

-- ===== multi-module (source-linked) code generation =====

-- Check + compile a set of in-memory `modules` (source-linked). This legacy
-- test helper intentionally emits exact per-module DSOs so older checker and
-- coder fixtures can address each artifact directly; public `titanc` container
-- grouping is exercised by its dedicated filesystem specs. With `forapp`, it
-- emits an executable for `main`. Returns (true) or (nil, message).
function M.generate_modules(modules, main, forapp)
    reset(true)
    local imported, deps = {}, {}
    local loader = driver.tableloader(modules, imported, deps)
    return driver.with_loader(loader, function(loader)
        local typ, err = checker.checkimport(main, loader)
        if not typ then return nil, err end
        if #err ~= 0 then return nil, table.concat(err, "\n") end
        local ofiles = {}
        for name, mod in pairs(imported) do
            local ok, e = driver.compile_module(name, mod, deps, verbose())
            table.insert(ofiles, name .. ".o")
            if not ok then return nil, e end
        end
        if forapp then
            local ok, e =
                driver.compile_program(main, ofiles, nil, verbose())
            if not ok then return nil, e end
        else
            for name, _ in pairs(imported) do
                local ok, e =
                    driver.compile_library(name, ofiles, nil, verbose())
                if not ok then return nil, e end
            end
        end
        return true
    end)
end

-- ===== `.so`-only import path =====

-- Compile one module to a `.so` straight from its AST (its `.titan` never
-- touches disk, so the default loader must resolve any imports via their own
-- `.so`). `names` is the set of sibling module names in the chain, used to
-- assert none of them was statically linked. Returns (true) or (nil, message).
local function build_one_so(name, src, names)
    reset(true)
    local static_deps = {}
    -- Parse under the `<name>.titan` chunkname so the generated `#line`
    -- directives attribute native frames to that `.titan` file (the unified
    -- backtrace keeps a native frame only when its DWARF filename ends in
    -- `.titan`). The default `(spec)` chunkname would make every Titan frame in
    -- a `.so`-only module invisible in traces.
    local ast = M.parse(src, name .. ".titan")
    if not ast then return nil, "parse error in " .. name end
    local loader = driver.defaultloader(static_deps)
    local _, errs = driver.with_loader(loader, function(loader)
        return checker.check(
            name, ast, src, name .. ".titan", loader)
    end)
    if #errs ~= 0 then return nil, name .. ": " .. table.concat(errs, "\n") end
    for dep in pairs(static_deps) do
        if names[dep] and dep ~= name then
            return nil, name .. " linked '" .. dep .. "' statically, not via .so"
        end
    end
    local ok, err, lib = driver.compile(name, ast, nil, static_deps, verbose())
    if not ok then return nil, err end
    ok, err = driver.compile_library(name, { lib }, nil, verbose())
    if not ok then return nil, err end
    return true
end

-- Build a chain of `.so`-only modules. `mods` is an array of {name=, src=} in
-- dependency order (each may import earlier ones); the last is the module under
-- test. Returns (true) or (nil, message); asserts every dependency resolved
-- dynamically (from its `.so`), never statically linked.
function M.build_so_chain(mods)
    local names = {}
    for _, m in ipairs(mods) do names[m.name] = true end
    for _, m in ipairs(mods) do
        local ok, err = build_one_so(m.name, m.src, names)
        if not ok then return nil, err end
    end
    return true
end

-- ===== typechecker-only helpers =====

function M.run_checker(code, probe_session)
    reset(true)
    local ast = assert(M.parse(code))
    local loader = driver.defaultloader()
    local t, errs = driver.with_loader(loader, function(loader)
        return checker.check(
            "test", ast, code, "test.titan", loader,
            checker_probe_options(probe_session))
    end)
    return #errs == 0, table.concat(errs, "\n"), ast, t
end

function M.run_checker_modules(modules, main)
    reset(true)
    local imported = {}
    local loader = driver.tableloader(modules, imported)
    local modt, err = driver.with_loader(loader, function(loader)
        return checker.checkimport(main, loader)
    end)
    if not modt then return false, err end
    return #err == 0, table.concat(err, "\n"), imported
end

-- Run the checker over `code` and return its list of error strings.
function M.check_errs(code, probe_session)
    reset()
    local ast = assert(M.parse(code))
    local _, errs = checker.check(
        "test", ast, code, "test.titan", nil,
        checker_probe_options(probe_session))
    return errs
end

-- Build each dependency in `deps` ({name=, src=}, in order) to a `.so`, then run
-- ONLY the typechecker on `main_src` against those `.so`-only dependencies.
-- Returns the list of type errors reported for `main` (and the module type).
function M.check_against_so(deps, main_name, main_src)
    local names = {}
    for _, d in ipairs(deps) do names[d.name] = true end
    for _, d in ipairs(deps) do
        assert(build_one_so(d.name, d.src, names))
    end
    reset(true)
    local mast = assert(M.parse(main_src))
    local loader = driver.defaultloader({})
    local mtype, errs = driver.with_loader(loader, function(loader)
        return checker.check(main_name, mast, main_src,
            main_name .. ".titan", loader)
    end)
    return errs, mtype
end

-- ===== AST-subset assertions (checker_spec) =====

-- Return a version of t2 that only contains the fields present in t1
-- (recursively), so AST assertions can compare a small expected subset.
function M.restrict(t1, t2)
    if type(t1) == 'table' and type(t2) == 'table' then
        local out = {}
        for k, _ in pairs(t1) do out[k] = M.restrict(t1[k], t2[k]) end
        return out
    else
        return t2
    end
end

function M.assert_type_check(code)
    local ok, err = M.run_checker(code)
    assert.truthy(ok, err)
end

function M.assert_type_error(expected, code)
    local ok, err = M.run_checker(code)
    assert.falsy(ok)
    assert.match(expected, err)
end

function M.assert_ast(program, expected)
    local received = M.restrict(expected, program)
    assert.are.same(expected, received)
end

-- A Lua snippet defining a `depth()` probe: returns how many stack frames sit
-- above its caller. A Titan function value called through the fast path adds NO
-- Lua call frame; the generic (slow) path goes through luaD_callnoyield and adds
-- one, so a fast call leaves the stack one frame shallower than a slow one.
M.DEPTH_PROBE = [[
    local function depth()
        local n = 2
        while debug.getinfo(n) do n = n + 1 end
        return n
    end
    local slow_g = function(q) local r = q() return r end
]]

return M

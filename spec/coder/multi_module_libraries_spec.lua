local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local LUA_INCLUDE = PREFIX .. "/include"

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, cwd)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(cwd))
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    assert.truthy(lfs.chdir(previous))
    return ok == true, output, why, code
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents)
    local parent = assert(path:match("^(.+)/[^/]+$"))
    make_directory(parent)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function compiler_argv(workspace, source_root, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_16=" .. workspace,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin")
    end

    local installed = PREFIX and exists(PREFIX .. "/bin/titanc")
    if installed then
        table.insert(argv, PREFIX .. "/bin/titanc")
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
        table.insert(argv, "LUA_CPATH=" .. REPO .. "/?.so;;")
        table.insert(argv, LUA)
        table.insert(argv, "-e")
        table.insert(argv, string.format(
            "package.path=%q..package.path", REPO .. "/?.lua;" ..
                REPO .. "/?/init.lua;"))
        table.insert(argv, REPO .. "/titanc")
    end

    table.insert(argv, "--tree")
    table.insert(argv, source_root)
    for _, argument in ipairs({ ... }) do table.insert(argv, argument) end
    return argv
end

local function compile(workspace, source_root, ...)
    return run(compiler_argv(workspace, source_root, ...), workspace)
end

local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?.so;" .. %q .. "/?.so;" .. package.cpath
%s
]], workspace, workspace, REPO, code),
    }, workspace)
end

local function count_plain(text, needle)
    local count = 0
    local start = 1
    while true do
        local at = text:find(needle, start, true)
        if not at then return count end
        count = count + 1
        start = at + #needle
    end
end

describe("multiple logical modules through one public shared library", function()
    local workspace
    local source_root
    local verbose_output

    setup(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root .. "/pkg")

        write_file(source_root .. "/pkg/shared.titan", [[
local visits: integer = 0

function touch(): integer
    visits = visits + 1
    return visits
end
]])
        write_file(source_root .. "/pkg/left.titan", [[
local common = import "pkg.shared"
local current: integer = 10

function read(): integer
    return current + common.touch()
end

do
    current = current + 1
end
]])
        write_file(source_root .. "/pkg/right.titan", [[
local common = import "pkg.shared"
local current: integer = 20

function read(): integer
    return current + common.touch()
end

do
    current = current + 2
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v", "pkg.left", "pkg.right")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        verbose_output = output
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("links one deterministic provider and emits one shim per logical source module",
       function()
        assert.equal("file", lfs.attributes(workspace .. "/pkg.so", "mode"))
        for _, name in ipairs({ "left", "right", "shared" }) do
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".c", "mode"))
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".o", "mode"))
            assert.equal("file", lfs.attributes(
                workspace .. "/pkg/" .. name .. ".lua", "mode"))
            assert.is_nil(lfs.attributes(
                workspace .. "/pkg/" .. name .. ".so", "mode"))

            local shim = read_file(workspace .. "/pkg/" .. name .. ".lua")
            assert.equal("-- Generated by titanc; do not edit.",
                shim:match("([^\n]+)"))
            assert.truthy(shim:find('package.searchpath("pkg", package.cpath)',
                1, true), shim)
            assert.truthy(shim:find('"luaopen_pkg_' .. name .. '"', 1, true),
                shim)
        end

        local link_lines = {}
        for line in verbose_output:gmatch("[^\n]+") do
            if line:find("'-shared'", 1, true) then
                table.insert(link_lines, line)
            end
        end
        assert.equal(1, #link_lines, verbose_output)
        local left_at = assert(link_lines[1]:find(
            "/pkg/left.o'", 1, true), link_lines[1])
        local right_at = assert(link_lines[1]:find(
            "/pkg/right.o'", 1, true), link_lines[1])
        local shared_at = assert(link_lines[1]:find(
            "/pkg/shared.o'", 1, true), link_lines[1])
        assert.is_true(left_at < right_at and right_at < shared_at,
            link_lines[1])

        local left_c = read_file(source_root .. "/pkg/left.c")
        assert.falsy(left_c:find("loadlib(L,", 1, true), left_c)
        assert.truthy(left_c:find("extern Udata *pkg_shared_init", 1, true),
            left_c)
    end)

    it("keeps logical module state independent while reusing the provider",
       function()
        local ok, output = run_lua(workspace, [[
local right = require "pkg.right"
local left = require "pkg.left"
assert(right.read() == 23)
assert(left.read() == 13)
assert(require("pkg.right") == right)
assert(require("pkg.left") == left)
]])
        assert.truthy(ok, output)
    end)

    it("supports a binary-only external consumer through the selected provider",
       function()
        write_file(source_root .. "/consumer.titan", [[
local left = import "pkg.left"
local right = import "pkg.right"

function run(): integer
    return left.read() * 100 + right.read()
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated = read_file(source_root .. "/consumer.c")
        -- The module protocol renders the import setup in its two initialization
        -- paths, so each of the two logical imports appears twice.
        assert.equal(4, count_plain(generated, 'loadlib(L, "pkg.so")'))
        assert.falsy(generated:find('loadlib(L, "pkg/left.so")', 1, true))
        assert.falsy(generated:find('loadlib(L, "pkg/right.so")', 1, true))
        assert.truthy(generated:find('"pkg_left_abi"', 1, true), generated)
        assert.truthy(generated:find('"pkg_right_abi"', 1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 1224)
]])
        assert.truthy(ok, output)
    end)
end)

describe("native trace names across one multi-module image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"

        write_file(source_root .. "/warmup.titan", [[
function boom(): integer
    raise "warmup"
    return 0
end
]])
        write_file(source_root .. "/trace/right.titan", [[
function boom(): integer
    raise "combined"
    return 0
end
]])
        write_file(source_root .. "/trace/left.titan", [[
local right = import "trace.right"

function relay(): integer
    return right.boom()
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("refreshes libbacktrace and symbolizes frames from separate objects",
       function()
        local ok, output, why, code =
            compile(workspace, source_root, "warmup")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        ok, output, why, code = compile(
            workspace, source_root, "trace.left", "trace.right")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("file", lfs.attributes(workspace .. "/trace.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/left.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/right.so", "mode"))

        ok, output = run_lua(workspace, [[
local titan = require "titan"
local warmup = require "warmup"
local warm_ok, warm_err = pcall(warmup.boom)
assert(not warm_ok and warm_err == "warmup")
local warm_trace = titan.backtrace()
assert(warm_trace:find("in warmup.boom", 1, true), warm_trace)

-- Loading trace.so after the first trace must invalidate libbacktrace's
-- snapshot. The next trace crosses the left.c and right.c objects linked into
-- that one provider, and each object contributes its own logical name table.
local left = require "trace.left"
local combined_ok, combined_err = pcall(left.relay)
assert(not combined_ok and combined_err == "combined")
local combined_trace = titan.backtrace()
assert(combined_trace:find("in trace.right.boom", 1, true), combined_trace)
assert(combined_trace:find("in trace.left.relay", 1, true), combined_trace)
assert(combined_trace:find(
    "right%.titan:%d+: in trace%.right%.boom"), combined_trace)
assert(combined_trace:find(
    "left%.titan:%d+: in trace%.left%.relay"), combined_trace)
assert(not combined_trace:find("in warmup.boom", 1, true), combined_trace)
assert(not combined_trace:find("titanentry", 1, true), combined_trace)
]])
        assert.truthy(ok, output)
    end)
end)

describe("rich logical interfaces inside one shared image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"

        write_file(source_root .. "/shape/provider.titan", [[
record Foo
    n: integer
end

function Foo.make(n: integer): Foo
    return Foo.new(n)
end

function Foo:plus(delta: integer): integer
    return self.n + delta
end

function inc(x: integer): integer
    return x + 1
end

function twice(f: (integer) -> integer, x: integer): integer
    return f(f(x))
end
]])
        write_file(source_root .. "/shape/facade.titan", [[
local provider = import "shape.provider"

type Foo = provider.Foo

function make(n: integer): Foo
    return provider.Foo.make(n)
end

function exact(x: integer): integer
    return provider.twice(provider.inc, x)
end

function generic(x: integer): integer
    local dynamic: value = provider.inc
    local f: (integer) -> integer = dynamic
    return f(x)
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("preserves records, aliases, methods, record functions, and function values",
       function()
        local ok, output, why, code = compile(
            workspace, source_root, "shape.provider", "shape.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert.equal("file", lfs.attributes(workspace .. "/shape.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/provider.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/facade.so", "mode"))

        write_file(source_root .. "/consumer.titan", [[
local facade = import "shape.facade"

function run(): integer
    local foo: facade.Foo = facade.make(40)
    local plus: (integer) -> integer = foo:plus
    return foo:plus(1) + plus(2) + facade.exact(1) + facade.generic(5)
end
]])
        ok, output, why, code = compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated = read_file(source_root .. "/consumer.c")
        assert.truthy(generated:find('loadlib(L, "shape.so")', 1, true),
            generated)
        assert.falsy(generated:find(
            'loadlib(L, "shape/facade.so")', 1, true), generated)
        assert.truthy(generated:find(
            'loadglobalsym(L, "shape_provider_Foo_plus_titanmethod")',
            1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 92)
local facade = require "shape.facade"
local provider = require "shape.provider"
assert(facade.make(7):plus(8) == 15)
assert(provider.Foo.make(9):plus(1) == 10)
]])
        assert.truthy(ok, output)
    end)
end)

describe("multi-module library preflight and native support contracts", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root)
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("rejects unrelated roots before producing compiler artifacts", function()
        write_file(source_root .. "/alpha.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/beta.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root, "alpha", "beta")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link modules into one shared library: 'alpha' and 'beta' " ..
            "have no common module prefix", 1, true), output)
        for _, path in ipairs({
            source_root .. "/alpha.c", source_root .. "/alpha.o",
            source_root .. "/beta.c", source_root .. "/beta.o",
            workspace .. "/alpha.so", workspace .. "/alpha.lua",
            workspace .. "/beta.so", workspace .. "/beta.lua",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end
    end)

    it("rejects mangled symbol collisions before code generation", function()
        write_file(source_root .. "/clash/a-b.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/clash/a/b.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "clash.a-b", "clash.a.b")
        assert.falsy(ok)
        assert.truthy(output:find("both use C symbol prefix 'clash_a_b'", 1,
            true), output)
        assert.is_nil(lfs.attributes(source_root .. "/clash/a-b.c", "mode"))
        assert.is_nil(lfs.attributes(source_root .. "/clash/a/b.c", "mode"))
    end)

    it("rejects module/member boundary symbol collisions before code generation",
       function()
        write_file(source_root .. "/boundary/root.titan",
            "function child_leaf(): integer return 1 end\n")
        write_file(source_root .. "/boundary/root/child.titan",
            "function leaf(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root,
            "boundary.root", "boundary.root.child")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link C symbol 'boundary_root_child_leaf_titan'", 1,
            true), output)
        assert.truthy(output:find("function 'boundary.root.child_leaf'", 1,
            true), output)
        assert.truthy(output:find("function 'boundary.root.child.leaf'", 1,
            true), output)
        for _, path in ipairs({
            source_root .. "/boundary/root.c",
            source_root .. "/boundary/root.o",
            source_root .. "/boundary/root/child.c",
            source_root .. "/boundary/root/child.o",
            workspace .. "/boundary/root.so",
            workspace .. "/boundary/root.lua",
            workspace .. "/boundary/root/child.lua",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end
    end)

    it("preflights record-function and bound-method symbols", function()
        write_file(source_root .. "/record_boundary/root.titan", [[
record child_Thing
    n: integer
end

function child_Thing:run(): integer
    return self.n
end
]])
        write_file(source_root .. "/record_boundary/root/child.titan", [[
record Thing
    n: integer
end

function Thing:run(): integer
    return self.n
end
]])

        local ok, output = compile(workspace, source_root,
            "record_boundary.root", "record_boundary.root.child")
        assert.falsy(ok)
        for _, symbol in ipairs({
            "record_boundary_root_child_Thing_new_titanstatic",
            "record_boundary_root_child_Thing_run_titanmethod",
            "record_boundary_root_child_Thing_run_boundmethod",
            "record_boundary_root_child_Thing_run_titanentry_boundlua",
        }) do
            assert.truthy(output:find(
                "cannot link C symbol '" .. symbol .. "'", 1, true), output)
        end
        assert.is_nil(lfs.attributes(
            source_root .. "/record_boundary/root.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/record_boundary/root/child.c", "mode"))
    end)

    it("preflights cross-family protocol symbols from source dependencies",
       function()
        write_file(source_root .. "/bundle/foo_abi.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/bundle/left.titan", [[
local other = import "luaopen.bundle.foo"
function probe(): integer return other.probe() end
]])
        write_file(source_root .. "/luaopen/bundle/foo.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root,
            "bundle.left", "bundle.foo_abi")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link C symbol 'luaopen_bundle_foo_abi'", 1, true),
            output)
        assert.truthy(output:find("module Lua entry", 1, true), output)
        assert.truthy(output:find("module ABI entry", 1, true), output)
        assert.is_nil(lfs.attributes(source_root .. "/bundle/left.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/luaopen/bundle/foo.c", "mode"))
    end)

    it("refuses an unrecognized Lua shim before changing C output", function()
        write_file(source_root .. "/owned/item.titan",
            "function probe(): integer return 1 end\n")
        write_file(workspace .. "/owned/item.lua", "return 'user file'\n")

        local ok, output = compile(workspace, source_root, "owned.item")
        assert.falsy(ok)
        assert.truthy(output:find(
            "refusing to overwrite unrecognized Lua file 'owned/item.lua'",
            1, true), output)
        assert.equal("return 'user file'\n",
            read_file(workspace .. "/owned/item.lua"))
        assert.is_nil(lfs.attributes(source_root .. "/owned/item.c", "mode"))
    end)

    it("requires semantic native support in a physical titan provider", function()
        write_file(source_root .. "/titan/one.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "titan.one", "titan.two")
        assert.falsy(ok)
        assert.truthy(output:find(
            "linked provider 'titan' has an invalid native support entry", 1,
            true), output)
        assert.is_nil(lfs.attributes(workspace .. "/titan.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/one.lua", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/two.lua", "mode"))
    end)

    it("accepts the reviewed native support object and leaves bare support inert",
       function()
        write_file(source_root .. "/titan/one.titan", [[
local initialized: integer = 0
function probe(): integer return initialized end
do initialized = initialized + 1 end
]])
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")
        write_file(workspace .. "/registry-probe.c", [[
#include "lua.h"
#include "lauxlib.h"
int luaopen_probe_registry(lua_State *L) {
    int present;
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module titan.one");
    present = !lua_isnil(L, -1);
    lua_pop(L, 1);
    lua_pushboolean(L, present);
    return 1;
}
]])
        local compiled, compile_output = run({
            "env", "CCACHE_DISABLE=1", "cc", "-std=c99", "-fPIC",
            "-I", LUA_INCLUDE,
            "-c", "registry-probe.c", "-o", "registry-probe.o",
        }, workspace)
        assert.truthy(compiled, compile_output)

        local ok, output, why, code = compile(
            workspace, source_root, "titan.one", "titan.two",
            "-X", REPO .. "/titan-runtime/titanlib.o",
            workspace .. "/registry-probe.o")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        ok, output = run_lua(workspace, [[
local support = require "titan"
assert(type(support._loadlib) == "function")
assert(type(support._loadlibglobal) == "function")
local registry_probe = assert(package.loadlib(
    "./titan.so", "luaopen_probe_registry"))
assert(registry_probe() == false)
local one = require "titan.one"
local two = require "titan.two"
assert(registry_probe() == true)
assert(one.probe() == 1)
assert(two.probe() == 2)
]])
        assert.truthy(ok, output)

        -- The semantic gate owns a fresh controlled Lua process. A parent
        -- compiler may itself have used -E; an inherited LUA_INIT must not be
        -- able to alter package.loadlib or forge the gate's result file.
        write_file(workspace .. "/hostile-init.lua",
            [[error("LUA_INIT reached Titan support validation", 0)]])
        write_file(workspace .. "/validate-support.lua", string.format([[
package.path = %q .. package.path
package.cpath = %q .. package.cpath
local driver = require "titan-compiler.driver"
local valid, validation_error = driver.validate_titan_support(arg[1])
assert(valid, validation_error)
]], REPO .. "/?.lua;" .. REPO .. "/?/init.lua;",
            REPO .. "/?.so;"))
        local validate_argv = {
            "env", "LUA_INIT=@" .. workspace .. "/hostile-init.lua",
        }
        if PREFIX then
            validate_argv[#validate_argv + 1] =
                "TITAN_ROCKS_ROOT=" .. PREFIX
        end
        validate_argv[#validate_argv + 1] = LUA
        validate_argv[#validate_argv + 1] = "-E"
        validate_argv[#validate_argv + 1] =
            workspace .. "/validate-support.lua"
        validate_argv[#validate_argv + 1] = workspace .. "/titan.so"
        ok, output = run(validate_argv, workspace)
        assert.truthy(ok, output)
    end)
end)

local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local STDLIB_MODULES = { "coroutine", "uv", "timer", "fs", "net", "os" }
local LUA_CPATH_SUFFIX = "/lib/lua/5.5/?.so"

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function run(argv, cwd)
    local words = {}
    for index, word in ipairs(argv) do words[index] = quote(word) end
    local command = table.concat(words, " ")
    if cwd then command = "cd " .. quote(cwd) .. " && " .. command end
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    assert.truthy(file:close())
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function make_directory(path)
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), path)
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function temporary_directory(label)
    local path = os.tmpname() .. "-titan-" .. label
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local function root_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        if template:sub(-#LUA_CPATH_SUFFIX) == LUA_CPATH_SUFFIX then
            return template:sub(1, #template - #LUA_CPATH_SUFFIX)
        end
    end
end

local PREFIX = (os.getenv("PREFIX") or root_from_cpath(package.cpath) or "")
    :gsub("/+$", "")
assert.truthy(PREFIX:sub(1, 1) == "/",
    "rockspec specs require the absolute standalone PREFIX used to run tests")

local LUA = PREFIX .. "/bin/lua"
local LUAROCKS = PREFIX .. "/bin/luarocks"
local TITANC = PREFIX .. "/bin/titanc"
local TITAN_LIBDIR = PREFIX .. "/lib/titan/0.11"
local STDLIB_DIR = TITAN_LIBDIR .. "/titan"
local LUA_LIBDIR = PREFIX .. "/lib/lua/5.5"
local LUA_SHAREDIR = PREFIX .. "/share/lua/5.5"
local UV_LOADER = LUA_SHAREDIR .. "/titan/uv.lua"

local function clean_environment(argv)
    local command = {
        "env",
        "-u", "LUA_PATH",
        "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH_5_5",
        "-u", "LUAROCKS_CONFIG",
        "-u", "LUAROCKS_CONFIG_5_5",
        "-u", "LUAROCKS_SYSCONFDIR",
        "-u", "TITAN_PATH_0_11",
        "-u", "TITAN_PATH",
        "-u", "TITAN_ROCKS_ROOT",
        "PATH=" .. PREFIX .. "/bin:" ..
            (os.getenv("PATH") or "/usr/bin:/bin"),
    }
    for _, word in ipairs(argv) do command[#command + 1] = word end
    return command
end

local function compiler_argv(...)
    local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function archive_object_members(output)
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        local basename = assert(member:match("([^/]+)$"))
        if basename ~= "__.SYMDEF" and
           basename ~= "__.SYMDEF SORTED" and
           basename ~= "__.SYMDEF_64" and
           basename ~= "__.SYMDEF_64 SORTED" then
            members[#members + 1] = basename
        end
    end
    table.sort(members)
    return members
end

local function assert_file(path)
    assert.equal("file", lfs.attributes(path, "mode"), path)
end

local function assert_canonical_module(module)
    local canonical = STDLIB_DIR .. "/" .. module .. ".so"
    local compatibility = TITAN_LIBDIR .. "/" .. module .. ".so"
    local lua_module = LUA_LIBDIR .. "/titan/" .. module .. ".so"
    local legacy = LUA_LIBDIR .. "/titan/stdlib_0_11/" .. module .. ".so"
    assert.equal("file", lfs.symlinkattributes(canonical, "mode"), canonical)
    assert.falsy(lfs.symlinkattributes(compatibility), compatibility)
    assert.falsy(lfs.symlinkattributes(lua_module), lua_module)
    assert.falsy(lfs.symlinkattributes(legacy), legacy)
    assert.equal(
        lfs.symlinkattributes("titan/" .. module .. ".so.dSYM", "mode"),
        lfs.symlinkattributes(canonical .. ".dSYM", "mode"),
        canonical .. ".dSYM")
    for _, obsolete in ipairs({ compatibility, lua_module, legacy }) do
        assert.falsy(lfs.symlinkattributes(obsolete .. ".dSYM"),
            obsolete .. ".dSYM")
    end
end

describe("standalone-prefix source installation", function()
    local workspace

    teardown(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    it("installs one matching Lua and Titan SDK before the standard images",
    function()
        for _, source in ipairs({
            "lua.h", "luaconf.h", "lobject.h", "lapi.c", "loadlib.c",
        }) do
            assert_file(PREFIX .. "/src/lua-5.5.0/" .. source)
        end
        for _, header in ipairs({
            "lua.h", "luaconf.h", "titan.h", "titan_longjmp.h",
            "minicoro.h", "titan/ffi.h", "titan/coro.h", "titan/uv.h",
        }) do
            assert_file(PREFIX .. "/include/" .. header)
        end
        for _, archive in ipairs({
            "liblua.a", "libtitan.a", "libbacktrace.a",
        }) do
            assert_file(PREFIX .. "/lib/" .. archive)
        end
        assert_file(LUA)
        assert_file(LUAROCKS)
        assert_file(TITANC)
        assert_file(LUA_LIBDIR .. "/titan.so")
        assert_file(UV_LOADER)

        local configured_tools = {}
        for _, variable in ipairs({ "CC", "LD", "AR", "RANLIB" }) do
            local configured, tool, config_why, config_code = run(
                clean_environment({
                    LUAROCKS, "config", "variables." .. variable,
                }))
            assert.truthy(configured, tool .. "\n(" ..
                tostring(config_why) .. ", " .. tostring(config_code) .. ")")
            configured_tools[variable] = assert(tool:match("^%s*(.-)%s*$"))
            assert.not_equal("", configured_tools[variable])
        end
        assert.equal(configured_tools.CC, configured_tools.LD)

        local luarocks_stamp = read_file(PREFIX ..
            "/etc/titan/luarocks-3.13.0.installed")
        for _, variable in ipairs({ "CC", "AR", "RANLIB" }) do
            assert.truthy(luarocks_stamp:find(
                variable .. "=" .. configured_tools[variable], 1, true),
                variable .. ": " .. luarocks_stamp)
        end

        local source_config = read_file(
            PREFIX .. "/src/lua-5.5.0/luaconf.h")
        local source_loadlib = read_file(
            PREFIX .. "/src/lua-5.5.0/loadlib.c")
        local public_config = read_file(PREFIX .. "/include/luaconf.h")
        assert.equal(source_config, public_config)
        assert.truthy(public_config:find(
            '#define LUA_ROOT "' .. PREFIX .. '/"', 1, true), public_config)
        assert.truthy(public_config:find(
            '#define LUA_TITAN_CDIR%s+LUA_ROOT "lib/titan/0.11/"'),
            public_config)
        local _, titan_cdir_definitions = public_config:gsub(
            "#define LUA_TITAN_CDIR", "")
        assert.equal(1, titan_cdir_definitions, public_config)
        local _, titan_cpath_templates = public_config:gsub(
            'LUA_TITAN_CDIR"%?%.so;"', "")
        assert.equal(1, titan_cpath_templates, public_config)
        assert.falsy(source_loadlib:find("luaopen_titan_uv", 1, true),
            source_loadlib)
        assert.truthy(source_loadlib:find(
            "reg = lsys_load(L, path, *sym == '*');", 1, true),
            source_loadlib)

        local ok, output, why, code = run({
            "ar", "t", PREFIX .. "/lib/libtitan.a",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local members = archive_object_members(output)
        assert.same({ "titan.o", "titan_coro.o", "titan_uv.o" }, members)

        ok, output, why, code = run({
            "cmp", "-s", PREFIX .. "/lib/libbacktrace.a",
            "libbacktrace/.libs/libbacktrace.a",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. "): installed libbacktrace.a")

        local expected_libuv_mode = os.getenv("TITAN_EXPECT_LIBUV_MODE")
            or "bundled"
        if expected_libuv_mode == "system" then
            assert.falsy(lfs.symlinkattributes(PREFIX .. "/lib/libuv.a"))
            assert.falsy(lfs.symlinkattributes(PREFIX .. "/include/uv.h"))
            assert.falsy(lfs.symlinkattributes(PREFIX .. "/include/uv"))
        else
            assert.equal("bundled", expected_libuv_mode)
            assert.falsy(lfs.symlinkattributes(PREFIX .. "/lib/libuv.a"))
            assert_file(PREFIX .. "/include/uv.h")
            assert_file(PREFIX .. "/include/uv/version.h")
        end

        for _, module in ipairs(STDLIB_MODULES) do
            assert_canonical_module(module)
        end
        assert.falsy(lfs.symlinkattributes(LUA_LIBDIR .. "/coro.so"))
        assert.falsy(lfs.symlinkattributes(LUA_LIBDIR .. "/coro.so.dSYM"))

        local manifest = read_file(PREFIX ..
            "/lib/luarocks/rocks-5.5/titan/dev-1/rock_manifest")
        assert.truthy(manifest:find("titan.so", 1, true), manifest)
        for _, module in ipairs(STDLIB_MODULES) do
            assert.falsy(manifest:find(module .. ".so", 1, true), manifest)
        end
        assert.falsy(manifest:find('["uv.lua"]', 1, true), manifest)
    end)

    it("removes obsolete standard-module layouts during migration",
    function()
        assert_file("titan/coroutine.so")
        workspace = temporary_directory("stdlib-layout-migration")

        local canonical = workspace ..
            "/lib/titan/0.11/titan/coroutine.so"
        local stale = {
            workspace .. "/lib/titan/0.11/coroutine.so",
            workspace .. "/lib/lua/5.5/coro.so",
            workspace .. "/lib/lua/5.5/titan/coroutine.so",
            workspace ..
                "/lib/lua/5.5/titan/stdlib_0_11/coroutine.so",
        }

        local function seed_layout()
            for _, path in ipairs({ canonical, table.unpack(stale) }) do
                make_directory(assert(path:match("^(.+)/[^/]+$")))
                write_file(path, "obsolete layout\n")
                make_directory(path .. ".dSYM")
                write_file(path .. ".dSYM/obsolete", "obsolete symbols\n")
            end
        end

        local function assert_migrated()
            assert.equal(read_file("titan/coroutine.so"),
                read_file(canonical))
            assert.equal(
                lfs.symlinkattributes("titan/coroutine.so.dSYM", "mode"),
                lfs.symlinkattributes(canonical .. ".dSYM", "mode"),
                canonical .. ".dSYM")
            for _, path in ipairs(stale) do
                assert.falsy(lfs.symlinkattributes(path), path)
                assert.falsy(lfs.symlinkattributes(path .. ".dSYM"),
                    path .. ".dSYM")
            end
        end

        seed_layout()
        local ok, output, why, code = run({
            "make", "--no-print-directory", "-s",
            "PREFIX=" .. workspace,
            "ROCKS_TREE=",
            "STDLIB_MODULES=coroutine",
            "STDLIB_PLATFORM_PREREQS=",
            "STDLIB_QUALIFIED_SOS=",
            "install-stdlib",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_migrated()

        seed_layout()
        ok, output, why, code = run({
            "make", "--no-print-directory", "-s",
            "MAKE=true",
            "ROCKS_TREE=" .. workspace,
            "ROCK_TITANC=" .. TITANC,
            "STDLIB_MODULES=coroutine",
            "rock-post-install",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_migrated()
    end)

    it("uses the prefix LuaRocks tree and one qualified standard image",
    function()
        workspace = temporary_directory("rock-tree")
        local ok, output, why, code
        for _, option in ipairs({ "--lr-path", "--lr-cpath" }) do
            ok, output, why, code = run(clean_environment({
                LUAROCKS, "path", option,
            }), workspace)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local entries = 0
            for entry in output:gmatch("[^;\r\n]+") do
                entries = entries + 1
                assert.equal(PREFIX .. "/", entry:sub(1, #PREFIX + 1),
                    option .. ": " .. output)
            end
            assert.truthy(entries > 0, option .. ": " .. output)
        end
        ok, output, why, code = run(clean_environment({
            LUAROCKS, "path", "--lr-bin",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local entries = 0
        for entry in output:gmatch("[^:\r\n]+") do
            entries = entries + 1
            assert.equal(PREFIX .. "/", entry:sub(1, #PREFIX + 1), output)
        end
        assert.truthy(entries > 0, output)
        assert.falsy(output:find(workspace .. "/lua_modules", 1, true), output)

        local runtime_program = string.format([[
            local canonical_root = %q
            local titan_module_path = %q
            local uv_loader_path = %q
            local builtin_coroutine = require "coroutine"
            local builtin_os = require "os"
            local titan = require "titan"
            local coroutine = require "titan.coroutine"
            local uv = require "titan.uv"
            local timer = require "titan.timer"
            local fs = require "titan.fs"
            local net = require "titan.net"
            local system = require "titan.os"
            assert(type(builtin_coroutine) == "table")
            assert(type(builtin_os) == "table")
            assert(type(titan) == "table")
            assert(type(titan.backtrace) == "function")
            assert(package.searchpath("titan", package.cpath) ==
                titan_module_path)
            assert(package.searchpath("titan.uv", package.path) ==
                uv_loader_path)
            assert(type(coroutine) == "userdata")
            assert(type(uv) == "userdata")
            assert(type(timer) == "userdata")
            assert(type(fs) == "userdata")
            assert(type(net) == "userdata")
            assert(type(system) == "userdata")
            for name, module in pairs({
                coroutine = coroutine,
                uv = uv,
                timer = timer,
                fs = fs,
                net = net,
                os = system,
            }) do
                local symbol = "luaopen_titan_" .. name
                local canonical_path = canonical_root .. "/" .. name .. ".so"
                assert(package.searchpath("titan." .. name, package.cpath) ==
                    canonical_path)
                local canonical_open = assert(package.loadlib(
                    canonical_path, symbol))
                assert(rawequal(canonical_open(), module))
            end
            assert(require "coroutine" == builtin_coroutine)
            assert(require "os" == builtin_os)
            assert(system.pid() > 0)
            local task = uv.run(function()
                local inner = coroutine.create(function()
                    timer.yield()
                    return "installed"
                end, {})
                return inner:resume(nil, nil)
            end)
            uv.loop()
            assert(task:join() == "installed")

            local direct = uv.run(function()
                timer.yield()
                return "direct"
            end)
            uv.loop()
            assert(direct:join() == "direct")
        ]], STDLIB_DIR, LUA_LIBDIR .. "/titan.so", UV_LOADER)
        ok, output, why, code = run(clean_environment({
            LUA, "-e", runtime_program,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("compiles and runs outside the checkout using configured Lua paths",
    function()
        workspace = temporary_directory("installed-compiler")
        local source = assert(io.open(workspace .. "/installed.titan", "wb"))
        source:write([[
local timer = import "timer"

function main(args: {string}): integer
  timer.sleep(0)
  return 0
end
]])
        source:close()

        -- Running the installed driver from the checkout root must not turn it
        -- back into source mode merely because that CWD contains a Makefile.
        local ok, output = run(clean_environment({
            TITANC, "--lua", PREFIX .. "/src/lua-5.5.0", "installed",
        }))
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--lua is only available in a source checkout", 1, true), output)

        ok, output = run(clean_environment({
            TITANC, "--lua", PREFIX .. "/src/lua-5.5.0", "installed",
        }), workspace)
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--lua is only available in a source checkout", 1, true), output)

        local why, code
        ok, output, why, code = run(clean_environment({
            TITANC, "installed",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_file(workspace .. "/installed")

        ok, output, why, code = run(clean_environment({
            workspace .. "/installed",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("", output)
    end)

    it("loads direct libuv calls lazily for Titan and explicitly for Lua",
    function()
        workspace = temporary_directory("direct-libuv")
        write_file(workspace .. "/provider_probe.h", [[
int titan_uv_provider_probe(void);
]])
        write_file(workspace .. "/provider_probe.c", [[
#include <stddef.h>
#include <uv.h>

int titan_uv_provider_probe(void) {
  unsigned char byte = 0;
  return uv_random(NULL, NULL, &byte, sizeof(byte), 0, NULL);
}
]])
        write_file(workspace .. "/direct_uv.titan", [[
local probe = foreign import "provider_probe.h"
local uv = import "uv"

function check(): boolean
  return (probe.titan_uv_provider_probe() as integer) == 0 and
         #uv.version() > 0
end
]])
        write_file(workspace .. "/lua_direct_uv.titan", [[
local probe = foreign import "provider_probe.h"

function check(): boolean
  return (probe.titan_uv_provider_probe() as integer) == 0
end
]])

        local ok, output = run({ "uname", "-s" }, workspace)
        assert.truthy(ok, output)
        local host = assert(output:match("^%s*(%S+)"))
        local compile = compiler_argv(
            "-std=c99", "-fPIC", "-I", PREFIX .. "/include")
        if host == "Linux" then compile[#compile + 1] = "-D_GNU_SOURCE" end
        for _, word in ipairs({
            "-c", "provider_probe.c", "-o", "provider_probe.o",
        }) do
            compile[#compile + 1] = word
        end
        local why, code
        ok, output, why, code = run(compile, workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        ok, output, why, code = run(clean_environment({
            TITANC, "direct_uv", "-X", "provider_probe.o",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_file(workspace .. "/direct_uv.so")

        ok, output, why, code = run(clean_environment({
            TITANC, "lua_direct_uv", "-X", "provider_probe.o",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_file(workspace .. "/lua_direct_uv.so")

        ok, output, why, code = run({ "nm", "-u", "direct_uv.so" },
            workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:match("[_ ]uv_random[%s\r\n]"), output)

        if host == "Darwin" then
            ok, output, why, code = run({ "otool", "-L", "direct_uv.so" },
                workspace)
        else
            ok, output, why, code = run(
                { "readelf", "-d", "direct_uv.so" }, workspace)
        end
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.falsy(output:find("libuv", 1, true), output)
        assert.falsy(output:find("titan/uv.so", 1, true), output)

        assert.truthy(os.rename(workspace .. "/direct_uv.titan",
            workspace .. "/direct_uv.source"))
        write_file(workspace .. "/consumer.titan", [[
local direct_uv = import "direct_uv"

function main(args: {string}): integer
  if direct_uv.check() then return 0 end
  return 1
end
]])
        ok, output, why, code = run(clean_environment({ TITANC, "consumer" }),
            workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local consumer_c = read_file(workspace .. "/consumer.c")
        assert.truthy(consumer_c:find(
            'loadlib(L, "direct_uv.so")', 1, true), consumer_c)
        ok, output, why, code = run(clean_environment({ "./consumer" }),
            workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local lua_probe = string.format([[
assert(package.searchpath("titan.uv", package.path) == %q)
assert(package.searchpath("titan.uv", package.cpath) == %q)
local uv = require "titan.uv"
local direct_uv = require "lua_direct_uv"
assert(direct_uv.check())
assert(type(uv.version()) == "string")
]], UV_LOADER, STDLIB_DIR .. "/uv.so")
        local lua_path = table.concat({
            LUA_SHAREDIR .. "/?.lua",
            LUA_SHAREDIR .. "/?/init.lua",
        }, ";")
        local lua_cpath = table.concat({
            workspace .. "/?.so",
            TITAN_LIBDIR .. "/?.so",
            LUA_LIBDIR .. "/?.so",
        }, ";")
        ok, output, why, code = run(clean_environment({
            "LUA_PATH_5_5=" .. lua_path,
            "LUA_CPATH_5_5=" .. lua_cpath,
            LUA, "-e", lua_probe,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)
end)

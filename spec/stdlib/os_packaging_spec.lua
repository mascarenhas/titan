local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"
local os_support = require "spec.support.os_test_support"

local FIXTURE = "spec/fixtures/stdlib/os/packaging/"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function copy_file(source, destination)
    write_file(destination, async_stdlib.read(source))
end

local function mkdir(path)
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function compiler_lua()
    return async_stdlib.host_lua()
end

local function compile(workspace, source_root, modname)
    local command = table.concat({
        "env CCACHE_DISABLE=1",
        "TITAN_PATH_0_11=" .. quote(
            async_stdlib.module_root(async_stdlib.standard_dir())),
        "TITAN_PATH=",
        quote(compiler_lua()),
        quote(async_stdlib.repo ..
            "/spec/support/async_stdlib_compile.lua"),
        quote(async_stdlib.repo), quote(source_root), quote(modname),
        quote(workspace .. "/titan-runtime"),
    }, " ")
    return async_stdlib.run(command, workspace)
end

local function defined_global_symbols(binary)
    local ok, _, host = async_stdlib.run("uname -s")
    assert.truthy(ok, host)
    local darwin = host:match("^Darwin") ~= nil
    local command = darwin and
        ("nm -gU " .. quote(binary)) or
        ("nm -g --defined-only " .. quote(binary))
    local symbols_ok, _, output = async_stdlib.run(command)
    assert.truthy(symbols_ok, output)
    local symbols = {}
    for line in output:gmatch("[^\r\n]+") do
        local symbol = line:match("%s([^%s]+)%s*$")
        if symbol then
            if darwin and symbol:sub(1, 1) == "_" then
                symbol = symbol:sub(2)
            end
            symbols[symbol] = true
        end
    end
    return symbols, output
end

local function assert_no_uv_implementation(binary)
    local symbols, output = defined_global_symbols(binary)
    assert.falsy(symbols.titan_uv_init, output)
    assert.falsy(symbols.luaopen_titan_uv, output)
    for symbol in pairs(symbols) do
        assert.falsy(symbol:match("^titan_uvshim_"),
            binary .. " contains shim symbol " .. symbol .. "\n" .. output)
        assert.falsy(symbol:match("^uv_"),
            binary .. " contains libuv symbol " .. symbol .. "\n" .. output)
    end
end

describe("os standard-module packaging", function()
    local workspace
    local source_root
    local process_child

    setup(function()
        workspace = async_stdlib.workspace("os-packaging")
        source_root = workspace .. "/os-app"
        mkdir(source_root)
        copy_file(FIXTURE .. "os_only.titan",
            source_root .. "/os_only.titan")
        copy_file(FIXTURE .. "os_consumer.titan",
            source_root .. "/os_consumer.titan")
        copy_file(FIXTURE .. "process_only.titan",
            source_root .. "/process_only.titan")
        process_child = os_support.process_child(workspace)
        local ok, _, output = compile(workspace, source_root, "os_only")
        assert.truthy(ok, output)
        ok, _, output = compile(workspace, source_root, "os_consumer")
        assert.truthy(ok, output)
        ok, _, output = compile(workspace, source_root, "process_only")
        assert.truthy(ok, output)
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("runs process I/O through canonical binaries and async bootstrap",
    function()
        local generated = async_stdlib.read(source_root .. "/process_only.c")
        assert.match('loadlibwithuv%(L, "titan/os%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)

        local entrypoint = async_stdlib.read(
            workspace .. "/process_only__entrypoint.c")
        assert.match("TITAN_MAIN_BOOTSTRAP_KEY", entrypoint, 1, true)
        assert.match("TITAN_MAIN_ARGC_KEY", entrypoint, 1, true)
        assert.match("TITAN_MAIN_ARGV_KEY", entrypoint, 1, true)
        assert.not_match("uv_setup_args(", entrypoint, 1, true)
        assert_no_uv_implementation(workspace .. "/process_only")

        local command = table.concat({
            "env TITAN_PATH_0_11=" .. quote(
                async_stdlib.module_root(async_stdlib.standard_dir())),
            quote(workspace .. "/process_only"), quote(process_child),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("loads an os-only application through qualified binaries",
    function()
        local generated = async_stdlib.read(source_root .. "/os_only.c")
        assert.match('loadlibwithuv%(L, "titan/os%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)
        assert_no_uv_implementation(workspace .. "/os_only")

        local command = "env TITAN_PATH_0_11=" ..
            quote(async_stdlib.module_root(async_stdlib.standard_dir())) .. " " ..
            quote(workspace .. "/os_only")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local os_c = async_stdlib.read("titan/os.c")
        assert.match('loadlib%(L, "titan/uv%.so"%)', os_c)
        assert.match('"titan_uv_abi"', os_c, 1, true)
        assert.match('"titan_uv_init"', os_c, 1, true)
        assert.not_match("#include <uv.h>", os_c, 1, true)
        assert.not_match("titan_uvshim", os_c, 1, true)
    end)

    it("exports only the qualified Lua entry and no libuv implementation",
    function()
        local os_so = async_stdlib.standard_dir() .. "/os.so"
        local symbols, output = defined_global_symbols(os_so)
        for _, expected in ipairs({
            "titan_os_init", "titan_os_abi", "titan_os_types",
            "luaopen_titan_os",
        }) do
            assert.truthy(symbols[expected],
                "os.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_os, output)
        assert_no_uv_implementation(os_so)

        local ok, _, host = async_stdlib.run("uname -s")
        assert.truthy(ok, host)
        local command = host:match("^Darwin") and
            ("otool -L " .. quote(os_so)) or
            ("readelf -d " .. quote(os_so))
        local deps_ok, _, dependencies = async_stdlib.run(command)
        assert.truthy(deps_ok, dependencies)
        assert.falsy(dependencies:lower():find("libuv", 1, true),
            dependencies)
    end)

    it("uses one canonical Titan os image without replacing Lua os",
    function()
        local canonical = async_stdlib.standard_dir() .. "/os.so"
        local cpath = async_stdlib.canonical_cpath(async_stdlib.standard_dir())
        local lua = async_stdlib.host_lua()
        local program = string.format([[
            local builtin = require "os"
            assert(package.searchpath("titan.os", package.cpath) == %q)
            local canonical_open = assert(package.loadlib(
                %q, "luaopen_titan_os"))
            local module = require "titan.os"
            assert(type(module) == "userdata")
            assert(rawequal(canonical_open(), module))
            assert(rawequal(module, package.loaded["titan.os"]))
            assert(require "os" == builtin)
            assert(package.loaded.os == builtin)
        ]], canonical, canonical)
        local command = table.concat({
            "env TITAN_PATH_0_11=" .. quote(
                async_stdlib.module_root(async_stdlib.standard_dir())),
            "LUA_CPATH=" .. quote(cpath .. ";" .. workspace ..
                "/?.so;;"), quote(lua), "-e", quote(program),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local import_first = string.format([[
            local builtin = require "os"
            local consumer = require "os_consumer"
            assert(consumer.pid() > 0)
            local standard = require "titan.os"
            local canonical_open = assert(package.loadlib(
                %q, "luaopen_titan_os"))
            assert(rawequal(standard, canonical_open()))
            assert(require "os" == builtin)
            assert(package.loaded.os == builtin)
        ]], canonical)
        local command = table.concat({
            "env TITAN_PATH_0_11=" .. quote(
                async_stdlib.module_root(async_stdlib.standard_dir())),
            "LUA_CPATH=" .. quote(workspace .. "/?.so;" .. cpath .. ";;"),
            quote(lua), "-e", quote(import_first),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)

    it("runs process APIs through the qualified Lua alias", function()
        local script = async_stdlib.repo ..
            "/spec/fixtures/libuv/os_production_smoke.lua"
        local command = async_stdlib.lua_command(
            workspace, script, "packaging", process_child)
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os production process smoke packaging passed",
            output, 1, true)
    end)
end)

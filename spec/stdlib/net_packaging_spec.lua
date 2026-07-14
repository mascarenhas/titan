local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"

local FIXTURE = "spec/fixtures/stdlib/net/packaging/"

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

describe("net standard-module packaging", function()
    local workspace
    local source_root

    setup(function()
        workspace = async_stdlib.workspace("net-packaging")
        source_root = workspace .. "/net-app"
        mkdir(source_root)
        copy_file(FIXTURE .. "net_only.titan",
            source_root .. "/net_only.titan")
        local ok, _, output = compile(workspace, source_root, "net_only")
        assert.truthy(ok, output)
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("loads a net-only application through qualified binaries",
    function()
        local generated = async_stdlib.read(source_root .. "/net_only.c")
        assert.match('loadlibwithuv%(L, "titan/net%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)
        assert_no_uv_implementation(workspace .. "/net_only")

        local command = "env TITAN_PATH_0_11=" ..
            quote(async_stdlib.module_root(async_stdlib.standard_dir())) .. " " ..
            quote(workspace .. "/net_only")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local net_c = async_stdlib.read("titan/net.c")
        assert.match('loadlib%(L, "titan/uv%.so"%)', net_c)
        assert.match('"titan_uv_abi"', net_c, 1, true)
        assert.match('"titan_uv_init"', net_c, 1, true)
        assert.not_match("#include <uv.h>", net_c, 1, true)
        assert.not_match("titan_uvshim", net_c, 1, true)
    end)

    it("keeps net.so free of a duplicate libuv implementation", function()
        local net_so = async_stdlib.standard_dir() .. "/net.so"
        local symbols, output = defined_global_symbols(net_so)
        for _, expected in ipairs({
            "titan_net_init", "titan_net_abi", "titan_net_types",
            "luaopen_titan_net",
        }) do
            assert.truthy(symbols[expected],
                "net.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_net, output)
        assert_no_uv_implementation(net_so)

        local ok, _, host = async_stdlib.run("uname -s")
        assert.truthy(ok, host)
        local command = host:match("^Darwin") and
            ("otool -L " .. quote(net_so)) or
            ("readelf -d " .. quote(net_so))
        local deps_ok, _, dependencies = async_stdlib.run(command)
        assert.truthy(deps_ok, dependencies)
        assert.falsy(dependencies:lower():find("libuv", 1, true),
            dependencies)
    end)

    it("resolves Lua require and native load through the canonical net image",
    function()
        local canonical = async_stdlib.standard_dir() .. "/net.so"
        local cpath = async_stdlib.canonical_cpath(async_stdlib.standard_dir())
        local lua = async_stdlib.host_lua()
        local program = string.format([[
            assert(package.searchpath("titan.net", package.cpath) == %q)
            local canonical_open = assert(package.loadlib(
                %q, "luaopen_titan_net"))
            local module = require "titan.net"
            assert(type(module) == "userdata")
            assert(rawequal(canonical_open(), module))
            assert(rawequal(module, package.loaded["titan.net"]))
        ]], canonical, canonical)
        local command = table.concat({
            "env TITAN_PATH_0_11=" .. quote(
                async_stdlib.module_root(async_stdlib.standard_dir())),
            "LUA_CPATH=" .. quote(cpath .. ";;"),
            quote(lua), "-e", quote(program),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)
end)

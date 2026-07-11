local lfs = require "lfs"
local phase2 = require "spec.support.phase2"

local FIXTURE = "spec/fixtures/uv/phase5/packaging/"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function copy_file(source, destination)
    write_file(destination, phase2.read(source))
end

local function mkdir(path)
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function compiler_lua()
    if lfs.attributes(phase2.repo .. "/lua") then
        return phase2.repo .. "/lua"
    end
    return phase2.repo .. "/.lua/bin/lua"
end

local function compile(workspace, source_root, modname, titan_path)
    local command = table.concat({
        "env CCACHE_DISABLE=1",
        "TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
        "TITAN_STDLIB_SOURCE_PATH=" .. quote(phase2.repo .. "/stdlib"),
        "TITAN_PATH_0_11=" .. quote(titan_path or ""),
        "TITAN_PATH=" .. quote(titan_path or ""),
        quote(compiler_lua()),
        quote(phase2.repo .. "/spec/support/phase2_compile.lua"),
        quote(phase2.repo), quote(source_root), quote(modname),
        quote(workspace .. "/titan-runtime"),
    }, " ")
    return phase2.run(command, workspace)
end

local function defined_global_symbols(binary)
    local ok, _, host = phase2.run("uname -s")
    assert.truthy(ok, host)
    local darwin = host:match("^Darwin") ~= nil
    local command = darwin and
        ("nm -gU " .. quote(binary)) or
        ("nm -g --defined-only " .. quote(binary))
    local symbols_ok, _, output = phase2.run(command)
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
    assert.falsy(symbols.uv_init, output)
    assert.falsy(symbols.luaopen_titan_uv, output)
    for symbol in pairs(symbols) do
        assert.falsy(symbol:match("^titan_uvshim_"),
            binary .. " contains shim symbol " .. symbol .. "\n" .. output)
        assert.falsy(symbol:match("^uv_"),
            binary .. " contains libuv symbol " .. symbol .. "\n" .. output)
    end
end

describe("net standard-binary pinning", function()
    local workspace
    local source_root
    local shadow_bin

    setup(function()
        workspace = phase2.workspace("net-packaging")
        source_root = workspace .. "/net-app"
        shadow_bin = workspace .. "/shadow-uv-bin"
        mkdir(source_root)
        mkdir(shadow_bin)
        copy_file(FIXTURE .. "net_only.titan",
            source_root .. "/net_only.titan")
        copy_file(FIXTURE .. "fake_uv.titan", source_root .. "/uv.titan")
        write_file(shadow_bin .. "/uv.so", "not a shared library\n")
        local ok, _, output = compile(workspace, source_root, "net_only",
            shadow_bin)
        assert.truthy(ok, output)
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    it("pins a net-only application and net.so to canonical binaries",
    function()
        local generated = phase2.read(source_root .. "/net_only.c")
        assert.match('loadstdlib%(L, "net%.so"%)', generated)
        assert.not_match('loadlib%(L, "net%.so"%)', generated)
        assert.not_match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)
        assert_no_uv_implementation(workspace .. "/net_only")

        local command = "env TITAN_STDLIB_PATH=" ..
            quote(phase2.standard_dir()) .. " " ..
            quote(workspace .. "/net_only")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local net_c = phase2.read("stdlib/net.c")
        assert.match('loadstdlib%(L, "uv%.so"%)', net_c)
        assert.match('"uv_abi"', net_c, 1, true)
        assert.match('"uv_init"', net_c, 1, true)
        assert.not_match("#include <uv.h>", net_c, 1, true)
        assert.not_match("titan_uvshim", net_c, 1, true)
    end)

    it("rejects direct reserved net source and binary shadows", function()
        local source_shadow = workspace .. "/shadow-net-source"
        mkdir(source_shadow)
        copy_file(FIXTURE .. "net_only.titan",
            source_shadow .. "/net_only.titan")
        copy_file(FIXTURE .. "fake_net.titan",
            source_shadow .. "/net.titan")
        local ok, _, output = compile(workspace, source_shadow, "net_only")
        assert.falsy(ok, output)
        assert.match("reserved standard module 'net' is shadowed by " ..
            "application source", output)

        local binary_source = workspace .. "/net-binary-app"
        local binary_shadow = workspace .. "/shadow-net-bin"
        mkdir(binary_source)
        mkdir(binary_shadow)
        copy_file(FIXTURE .. "net_only.titan",
            binary_source .. "/net_only.titan")
        write_file(binary_shadow .. "/net.so", "not a shared library\n")
        ok, _, output = compile(workspace, binary_source, "net_only",
            binary_shadow)
        assert.falsy(ok, output)
        assert.match("reserved standard module 'net' is shadowed by " ..
            "local binary", output)
    end)

    it("keeps net.so free of a duplicate libuv implementation", function()
        local net_so = phase2.standard_dir() .. "/net.so"
        local symbols, output = defined_global_symbols(net_so)
        for _, expected in ipairs({
            "net_init", "net_abi", "net_types", "luaopen_titan_net",
        }) do
            assert.truthy(symbols[expected],
                "net.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_net, output)
        assert_no_uv_implementation(net_so)

        local ok, _, host = phase2.run("uname -s")
        assert.truthy(ok, host)
        local command = host:match("^Darwin") and
            ("otool -L " .. quote(net_so)) or
            ("readelf -d " .. quote(net_so))
        local deps_ok, _, dependencies = phase2.run(command)
        assert.truthy(deps_ok, dependencies)
        assert.falsy(dependencies:lower():find("libuv", 1, true),
            dependencies)
    end)

    it("maps canonical and Lua alias load orders to one net module Udata",
    function()
        local canonical = phase2.standard_dir() .. "/net.so"
        local cpath = phase2.alias_template()
        local lua = lfs.attributes(phase2.repo .. "/.lua/bin/lua") and
            phase2.repo .. "/.lua/bin/lua" or phase2.repo .. "/lua"
        for _, canonical_first in ipairs({ false, true }) do
            local program = string.format([[
                local open = assert(package.loadlib(%q, "luaopen_titan_net"))
                local first, second
                if %s then
                    first, second = open(), require "titan.net"
                else
                    first, second = require "titan.net", open()
                end
                assert(type(first) == "userdata")
                assert(rawequal(first, second))
                assert(rawequal(second, package.loaded["titan.net"]))
            ]], canonical, tostring(canonical_first))
            local command = table.concat({
                "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
                "LUA_CPATH=" .. quote(cpath .. ";;"),
                quote(lua), "-e", quote(program),
            }, " ")
            local ok, status, output = phase2.run(command, workspace)
            assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        end
    end)
end)

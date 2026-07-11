local lfs = require "lfs"
local phase2 = require "spec.support.phase2"

local FIXTURE = "spec/fixtures/uv/phase3/packaging/"

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

describe("fs standard-binary pinning", function()
    local workspace
    local source_root
    local shadow_bin
    local data_path

    setup(function()
        workspace = phase2.workspace("fs-packaging")
        source_root = workspace .. "/fs-app"
        shadow_bin = workspace .. "/shadow-uv-bin"
        data_path = workspace .. "/canonical.dat"
        mkdir(source_root)
        mkdir(shadow_bin)
        copy_file(FIXTURE .. "fs_only.titan",
            source_root .. "/fs_only.titan")
        copy_file(FIXTURE .. "fake_uv.titan", source_root .. "/uv.titan")
        write_file(shadow_bin .. "/uv.so", "not a shared library\n")
        local ok, _, output = compile(workspace, source_root, "fs_only",
            shadow_bin)
        assert.truthy(ok, output)
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    it("pins an fs-only application and fs.so to canonical binaries",
    function()
        local generated = phase2.read(source_root .. "/fs_only.c")
        assert.match('loadstdlib%(L, "fs%.so"%)', generated)
        assert.not_match('loadlib%(L, "fs%.so"%)', generated)
        assert.not_match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)
        assert_no_uv_implementation(workspace .. "/fs_only")

        local command = table.concat({
            "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
            "TITAN_PATH_0_11=" .. quote(shadow_bin),
            "TITAN_PATH=" .. quote(shadow_bin),
            quote(workspace .. "/fs_only"), quote(data_path),
        }, " ")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local fs_c = phase2.read("stdlib/fs.c")
        assert.match('loadstdlib%(L, "uv%.so"%)', fs_c)
        assert.match('"uv_abi"', fs_c, 1, true)
        assert.match('"uv_init"', fs_c, 1, true)
        assert.not_match("#include <uv.h>", fs_c, 1, true)
        assert.not_match("titan_uvshim", fs_c, 1, true)
    end)

    it("rejects direct reserved fs source and binary shadows", function()
        local source_shadow = workspace .. "/shadow-fs-source"
        mkdir(source_shadow)
        copy_file(FIXTURE .. "fs_only.titan",
            source_shadow .. "/fs_only.titan")
        copy_file(FIXTURE .. "fake_fs.titan",
            source_shadow .. "/fs.titan")
        local ok, _, output = compile(workspace, source_shadow, "fs_only")
        assert.falsy(ok, output)
        assert.match("reserved standard module 'fs' is shadowed by " ..
            "application source", output)
        assert.match("shadow%-fs%-source/fs%.titan", output)

        local binary_source = workspace .. "/fs-binary-app"
        local binary_shadow = workspace .. "/shadow-fs-bin"
        mkdir(binary_source)
        mkdir(binary_shadow)
        copy_file(FIXTURE .. "fs_only.titan",
            binary_source .. "/fs_only.titan")
        write_file(binary_shadow .. "/fs.so", "not a shared library\n")
        ok, _, output = compile(workspace, binary_source, "fs_only",
            binary_shadow)
        assert.falsy(ok, output)
        assert.match("reserved standard module 'fs' is shadowed by " ..
            "local binary", output)
        assert.match("shadow%-fs%-bin/fs%.so", output)
    end)

    it("keeps fs.so free of a duplicate libuv implementation", function()
        local fs_so = phase2.standard_dir() .. "/fs.so"
        local symbols, output = defined_global_symbols(fs_so)
        for _, expected in ipairs({
            "fs_init", "fs_abi", "fs_types", "luaopen_titan_fs",
        }) do
            assert.truthy(symbols[expected],
                "fs.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_fs, output)
        assert_no_uv_implementation(fs_so)

        local ok, _, host = phase2.run("uname -s")
        assert.truthy(ok, host)
        local command = host:match("^Darwin") and
            ("otool -L " .. quote(fs_so)) or
            ("readelf -d " .. quote(fs_so))
        local deps_ok, _, dependencies = phase2.run(command)
        assert.truthy(deps_ok, dependencies)
        assert.falsy(dependencies:lower():find("libuv", 1, true),
            dependencies)
    end)

    it("maps canonical and Lua alias load orders to one fs module Udata",
    function()
        local canonical = phase2.standard_dir() .. "/fs.so"
        local cpath = phase2.alias_template()
        local lua = lfs.attributes(phase2.repo .. "/.lua/bin/lua") and
            phase2.repo .. "/.lua/bin/lua" or phase2.repo .. "/lua"
        for _, canonical_first in ipairs({ false, true }) do
            local program = string.format([[
                local open = assert(package.loadlib(%q, "luaopen_titan_fs"))
                local first, second
                if %s then
                    first, second = open(), require "titan.fs"
                else
                    first, second = require "titan.fs", open()
                end
                assert(type(first) == "userdata")
                assert(rawequal(first, second))
                assert(rawequal(second, package.loaded["titan.fs"]))
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

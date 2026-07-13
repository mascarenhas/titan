local lfs = require "lfs"
local phase2 = require "spec.support.phase2"
local phase6 = require "spec.support.phase6"

local FIXTURE = "spec/fixtures/uv/phase6/packaging/"

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
    return phase2.host_lua()
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

describe("os standard-binary pinning", function()
    local workspace
    local source_root
    local shadow_bin
    local process_child

    setup(function()
        workspace = phase2.workspace("os-packaging")
        source_root = workspace .. "/os-app"
        shadow_bin = workspace .. "/shadow-uv-bin"
        mkdir(source_root)
        mkdir(shadow_bin)
        copy_file(FIXTURE .. "os_only.titan",
            source_root .. "/os_only.titan")
        copy_file(FIXTURE .. "os_consumer.titan",
            source_root .. "/os_consumer.titan")
        copy_file(FIXTURE .. "process_only.titan",
            source_root .. "/process_only.titan")
        copy_file(FIXTURE .. "fake_uv.titan", source_root .. "/uv.titan")
        write_file(shadow_bin .. "/uv.so", "not a shared library\n")
        process_child = phase6.process_child(workspace)
        local ok, _, output = compile(workspace, source_root, "os_only",
            shadow_bin)
        assert.truthy(ok, output)
        ok, _, output = compile(workspace, source_root, "os_consumer",
            shadow_bin)
        assert.truthy(ok, output)
        ok, _, output = compile(workspace, source_root, "process_only",
            shadow_bin)
        assert.truthy(ok, output)
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    it("runs process I/O through canonical binaries and async bootstrap",
    function()
        local generated = phase2.read(source_root .. "/process_only.c")
        assert.match('loadstdlib%(L, "os%.so"%)', generated)
        assert.not_match('loadlib%(L, "os%.so"%)', generated)
        assert.not_match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)

        local entrypoint = phase2.read(
            workspace .. "/process_only__entrypoint.c")
        assert.match("TITAN_MAIN_BOOTSTRAP_KEY", entrypoint, 1, true)
        assert_no_uv_implementation(workspace .. "/process_only")

        local command = table.concat({
            "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
            "TITAN_PATH_0_11=" .. quote(shadow_bin),
            "TITAN_PATH=" .. quote(shadow_bin),
            quote(workspace .. "/process_only"), quote(process_child),
        }, " ")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("pins an os-only application and os.so to canonical binaries",
    function()
        local generated = phase2.read(source_root .. "/os_only.c")
        assert.match('loadstdlib%(L, "os%.so"%)', generated)
        assert.not_match('loadlib%(L, "os%.so"%)', generated)
        assert.not_match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)
        assert_no_uv_implementation(workspace .. "/os_only")

        local command = "env TITAN_STDLIB_PATH=" ..
            quote(phase2.standard_dir()) .. " " ..
            quote(workspace .. "/os_only")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)

        local os_c = phase2.read("stdlib/os.c")
        assert.match('loadstdlib%(L, "uv%.so"%)', os_c)
        assert.match('"uv_abi"', os_c, 1, true)
        assert.match('"uv_init"', os_c, 1, true)
        assert.not_match("#include <uv.h>", os_c, 1, true)
        assert.not_match("titan_uvshim", os_c, 1, true)
    end)

    it("rejects direct reserved os source and binary shadows", function()
        local source_shadow = workspace .. "/shadow-os-source"
        mkdir(source_shadow)
        copy_file(FIXTURE .. "os_only.titan",
            source_shadow .. "/os_only.titan")
        copy_file(FIXTURE .. "fake_os.titan", source_shadow .. "/os.titan")
        local ok, _, output = compile(workspace, source_shadow, "os_only")
        assert.falsy(ok, output)
        assert.match("reserved standard module 'os' is shadowed by " ..
            "application source", output)

        local binary_source = workspace .. "/os-binary-app"
        local binary_shadow = workspace .. "/shadow-os-bin"
        mkdir(binary_source)
        mkdir(binary_shadow)
        copy_file(FIXTURE .. "os_only.titan",
            binary_source .. "/os_only.titan")
        write_file(binary_shadow .. "/os.so", "not a shared library\n")
        ok, _, output = compile(workspace, binary_source, "os_only",
            binary_shadow)
        assert.falsy(ok, output)
        assert.match("reserved standard module 'os' is shadowed by " ..
            "local binary", output)
    end)

    it("exports only the qualified Lua entry and no libuv implementation",
    function()
        local os_so = phase2.standard_dir() .. "/os.so"
        local symbols, output = defined_global_symbols(os_so)
        for _, expected in ipairs({
            "os_init", "os_abi", "os_types", "luaopen_titan_os",
        }) do
            assert.truthy(symbols[expected],
                "os.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_os, output)
        assert_no_uv_implementation(os_so)

        local ok, _, host = phase2.run("uname -s")
        assert.truthy(ok, host)
        local command = host:match("^Darwin") and
            ("otool -L " .. quote(os_so)) or
            ("readelf -d " .. quote(os_so))
        local deps_ok, _, dependencies = phase2.run(command)
        assert.truthy(deps_ok, dependencies)
        assert.falsy(dependencies:lower():find("libuv", 1, true),
            dependencies)
    end)

    it("uses one canonical Titan os image without replacing Lua os",
    function()
        local canonical = phase2.standard_dir() .. "/os.so"
        local cpath = phase2.canonical_cpath(phase2.standard_dir())
        local lua = phase2.host_lua()
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
            "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
            "LUA_CPATH=" .. quote(cpath .. ";" .. workspace ..
                "/?.so;;"), quote(lua), "-e", quote(program),
        }, " ")
        local ok, status, output = phase2.run(command, workspace)
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
            "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
            "LUA_CPATH=" .. quote(workspace .. "/?.so;" .. cpath .. ";;"),
            quote(lua), "-e", quote(import_first),
        }, " ")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)

    it("runs process APIs through the qualified Lua alias", function()
        local script = phase2.repo ..
            "/spec/fixtures/libuv/os_production_smoke.lua"
        local command = phase2.lua_command(
            workspace, script, "packaging", process_child)
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT os production process smoke packaging passed",
            output, 1, true)
    end)
end)

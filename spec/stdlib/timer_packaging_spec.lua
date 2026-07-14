local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"

local FIXTURE = "spec/fixtures/stdlib/timer/packaging/"

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

local function assert_no_standard_implementation(binary)
    local symbols, output = defined_global_symbols(binary)
    assert.falsy(symbols.titan_timer_init,
        binary .. " source-linked titan_timer_init\n" .. output)
    assert.falsy(symbols.titan_uv_init,
        binary .. " source-linked titan_uv_init\n" .. output)
    assert.falsy(symbols.luaopen_titan_uv,
        binary .. " contains the canonical uv module\n" .. output)
    for symbol in pairs(symbols) do
        assert.falsy(symbol:match("^titan_uvshim_"),
            binary .. " contains shim symbol " .. symbol .. "\n" .. output)
        assert.falsy(symbol:match("^uv_"),
            binary .. " contains libuv implementation symbol " .. symbol ..
            "\n" .. output)
    end
end

describe("timer standard-module packaging", function()
    local workspace
    local success_source

    setup(function()
        workspace = async_stdlib.workspace("timer-packaging")
        success_source = workspace .. "/timer-app"
        mkdir(success_source)
        copy_file(FIXTURE .. "timer_only.titan",
            success_source .. "/timer_only.titan")

        local ok, _, output = compile(workspace, success_source, "timer_only")
        assert.truthy(ok, output)
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("loads a timer-only application through qualified binaries",
    function()
        local generated = async_stdlib.read(success_source .. "/timer_only.c")
        assert.match('loadlibwithuv%(L, "titan/timer%.so"%)', generated)
        assert.not_match('loadlib%(L, "titan/uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)

        assert_no_standard_implementation(workspace .. "/timer_only")

        local command = table.concat({
            "env TITAN_PATH_0_11=" .. quote(
                async_stdlib.module_root(async_stdlib.standard_dir())),
            quote(workspace .. "/timer_only"),
        }, " ")
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)

    it("contains no statically linked libuv implementation in timer.so",
    function()
        local timer_so = async_stdlib.standard_dir() .. "/timer.so"
        local symbols, output = defined_global_symbols(timer_so)
        for _, expected in ipairs({
            "titan_timer_init", "titan_timer_abi", "titan_timer_types",
            "luaopen_titan_timer",
        }) do
            assert.truthy(symbols[expected],
                "timer.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_timer, output)
        assert.falsy(symbols.titan_uv_init, output)
        assert.falsy(symbols.luaopen_titan_uv, output)
        for symbol in pairs(symbols) do
            assert.falsy(symbol:match("^titan_uvshim_"),
                "timer.so contains shim symbol " .. symbol .. "\n" .. output)
            assert.falsy(symbol:match("^uv_"),
                "timer.so contains libuv implementation symbol " .. symbol ..
                "\n" .. output)
        end
    end)
end)

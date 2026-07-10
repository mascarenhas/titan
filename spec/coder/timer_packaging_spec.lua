local lfs = require "lfs"
local phase2 = require "spec.support.phase2"

local FIXTURE = "spec/fixtures/uv/packaging/"

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

local function assert_no_standard_implementation(binary)
    local symbols, output = defined_global_symbols(binary)
    assert.falsy(symbols.timer_init,
        binary .. " source-linked timer_init\n" .. output)
    assert.falsy(symbols.uv_init,
        binary .. " source-linked uv_init\n" .. output)
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

describe("timer standard-binary pinning", function()
    local workspace
    local success_source
    local shadow_uv_bin

    setup(function()
        workspace = phase2.workspace("timer-packaging")
        success_source = workspace .. "/timer-app"
        shadow_uv_bin = workspace .. "/shadow-uv-bin"
        mkdir(success_source)
        mkdir(shadow_uv_bin)
        copy_file(FIXTURE .. "timer_only.titan",
            success_source .. "/timer_only.titan")
        -- This source and binary must be irrelevant to an ordinary application's
        -- binary-only timer dependency. timer.so itself uses loadstdlib for uv.
        copy_file(FIXTURE .. "fake_uv.titan", success_source .. "/uv.titan")
        write_file(shadow_uv_bin .. "/uv.so", "not a shared library\n")

        local ok, _, output = compile(workspace, success_source,
            "timer_only", shadow_uv_bin)
        assert.truthy(ok, output)
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    it("pins a timer-only application to canonical binaries with sources visible",
    function()
        local generated = phase2.read(success_source .. "/timer_only.c")
        assert.match('loadstdlib%(L, "timer%.so"%)', generated)
        assert.not_match('loadlib%(L, "timer%.so"%)', generated)
        assert.not_match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)

        assert_no_standard_implementation(workspace .. "/timer_only")

        local command = table.concat({
            "env TITAN_STDLIB_PATH=" .. quote(phase2.standard_dir()),
            "TITAN_PATH_0_11=" .. quote(shadow_uv_bin),
            "TITAN_PATH=" .. quote(shadow_uv_bin),
            quote(workspace .. "/timer_only"),
        }, " ")
        local ok, status, output = phase2.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)

    it("diagnoses a direct reserved timer source or binary shadow", function()
        local source_shadow = workspace .. "/shadow-timer-source"
        mkdir(source_shadow)
        copy_file(FIXTURE .. "timer_only.titan",
            source_shadow .. "/timer_only.titan")
        copy_file(FIXTURE .. "fake_timer.titan",
            source_shadow .. "/timer.titan")

        local ok, _, output = compile(workspace, source_shadow, "timer_only")
        assert.falsy(ok, output)
        assert.match("reserved standard module 'timer' is shadowed by " ..
            "application source", output)
        assert.match("shadow%-timer%-source/timer%.titan", output)

        local binary_source = workspace .. "/timer-binary-app"
        local binary_shadow = workspace .. "/shadow-timer-bin"
        mkdir(binary_source)
        mkdir(binary_shadow)
        copy_file(FIXTURE .. "timer_only.titan",
            binary_source .. "/timer_only.titan")
        write_file(binary_shadow .. "/timer.so", "not a shared library\n")

        ok, _, output = compile(workspace, binary_source, "timer_only",
            binary_shadow)
        assert.falsy(ok, output)
        assert.match("reserved standard module 'timer' is shadowed by " ..
            "local binary", output)
        assert.match("shadow%-timer%-bin/timer%.so", output)
    end)

    it("diagnoses direct uv shadows while timer's pinned uv stays isolated",
    function()
        local source_shadow = workspace .. "/shadow-uv-source"
        mkdir(source_shadow)
        copy_file(FIXTURE .. "uv_only.titan",
            source_shadow .. "/uv_only.titan")
        copy_file(FIXTURE .. "fake_uv.titan", source_shadow .. "/uv.titan")

        local ok, _, output = compile(workspace, source_shadow, "uv_only")
        assert.falsy(ok, output)
        assert.match("reserved standard module 'uv' is shadowed by " ..
            "application source", output)
        assert.match("shadow%-uv%-source/uv%.titan", output)

        local binary_source = workspace .. "/uv-binary-app"
        local binary_shadow = workspace .. "/shadow-direct-uv-bin"
        mkdir(binary_source)
        mkdir(binary_shadow)
        copy_file(FIXTURE .. "uv_only.titan",
            binary_source .. "/uv_only.titan")
        write_file(binary_shadow .. "/uv.so", "not a shared library\n")

        ok, _, output = compile(workspace, binary_source, "uv_only",
            binary_shadow)
        assert.falsy(ok, output)
        assert.match("reserved standard module 'uv' is shadowed by local binary",
            output)
        assert.match("shadow%-direct%-uv%-bin/uv%.so", output)
    end)

    it("contains no statically linked libuv implementation in timer.so",
    function()
        local timer_so = phase2.standard_dir() .. "/timer.so"
        local symbols, output = defined_global_symbols(timer_so)
        for _, expected in ipairs({
            "timer_init", "timer_abi", "timer_types", "luaopen_titan_timer",
        }) do
            assert.truthy(symbols[expected],
                "timer.so is missing " .. expected .. "\n" .. output)
        end
        assert.falsy(symbols.luaopen_timer, output)
        assert.falsy(symbols.uv_init, output)
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

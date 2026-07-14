local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function append_shell_words(argv, words, label)
    local parsed, err = cdriver.split_shell_words(words or "")
    assert.is_table(parsed, label .. ": " .. tostring(err))
    for _, word in ipairs(parsed) do argv[#argv + 1] = word end
end

local function compile_allocation_counter(workspace)
    local object = workspace .. "/titan_uv_test_allocation.o"
    local argv = {}
    append_shell_words(argv, os.getenv("CC") or "cc", "CC")
    argv[#argv + 1] = "-std=c99"
    argv[#argv + 1] = "-fPIC"
    argv[#argv + 1] = "-I" .. async_stdlib.repo .. "/lua-5.5.0/src"
    argv[#argv + 1] = "-I" .. async_stdlib.repo ..
        "/spec/fixtures/stdlib/uv/native_handles"
    append_shell_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = "-c"
    argv[#argv + 1] = async_stdlib.repo ..
        "/spec/fixtures/stdlib/uv/native_handles/titan_uv_test_allocation.c"
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = object
    for index, word in ipairs(argv) do argv[index] = shell_quote(word) end
    local ok, _, output = async_stdlib.run(table.concat(argv, " "), workspace)
    assert.truthy(ok, output)
    return object
end

describe("uv opaque native handle ownership", function()
    local workspace

    setup(function()
        workspace = async_stdlib.workspace("native-owner")
        async_stdlib.copy_source(workspace,
            "spec/fixtures/stdlib/uv/native_handles/native_owner_probe.titan",
            "native_owner_probe")
        async_stdlib.copy_source(workspace,
            "spec/fixtures/stdlib/uv/native_handles/" ..
                "native_owner_consumer.titan",
            "native_owner_consumer")
        local cppflags = async_stdlib.host_libuv_config()
        cppflags = cppflags .. " -I" .. async_stdlib.repo ..
            "/spec/fixtures/stdlib/uv/native_handles"
        local allocation_counter = compile_allocation_counter(workspace)
        local options = {
            cppflags = cppflags,
            cflags = "-fno-strict-aliasing " ..
                "-Dlua_newuserdatauv=titan_uv_test_newuserdatauv " ..
                "-DluaS_newudata=titan_uv_test_newudata",
            extra_objects = {
                allocation_counter,
            },
        }
        async_stdlib.compile(workspace, "native_owner_probe", options)
        async_stdlib.compile(workspace, "native_owner_consumer", options)
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("passes an exact opaque handle across modules without boxing", function()
        local script = workspace .. "/native-handle-no-boxing.lua"
        local file = assert(io.open(script, "wb"))
        file:write([[
            local consumer = require "native_owner_consumer"
            assert(consumer.no_boxing(),
                   "cross-module typed-handle access allocated a userdata")
        ]])
        file:close()
        local ok, _, output = async_stdlib.run(
            async_stdlib.lua_command(workspace, script), workspace)
        assert.truthy(ok, output)
    end)
end)

local cdriver = require "c-parser.cdriver"
local phase2 = require "spec.support.phase2"

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
    argv[#argv + 1] = "-I" .. phase2.repo .. "/lua-5.5.0/src"
    argv[#argv + 1] = "-I" .. phase2.repo .. "/spec/fixtures/uv"
    append_shell_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = "-c"
    argv[#argv + 1] = phase2.repo ..
        "/spec/fixtures/uv/titan_uv_test_allocation.c"
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = object
    for index, word in ipairs(argv) do argv[index] = shell_quote(word) end
    local ok, _, output = phase2.run(table.concat(argv, " "), workspace)
    assert.truthy(ok, output)
    return object
end

describe("uv opaque native handles", function()
    local workspace

    setup(function()
        workspace = phase2.workspace("native-owner")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/native_owner_probe.titan",
            "native_owner_probe")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/native_owner_consumer.titan",
            "native_owner_consumer")
        local cppflags = phase2.host_libuv_config()
        cppflags = cppflags .. " -I" .. phase2.repo .. "/spec/fixtures/uv"
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
        phase2.compile(workspace, "native_owner_probe", options)
        phase2.compile(workspace, "native_owner_consumer", options)
    end)

    teardown(function()
        phase2.cleanup(workspace)
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
        local ok, _, output = phase2.run(
            phase2.lua_command(workspace, script), workspace)
        assert.truthy(ok, output)
    end)
end)

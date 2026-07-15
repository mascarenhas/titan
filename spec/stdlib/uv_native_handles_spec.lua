local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local NATIVE_FIXTURES = async_stdlib.repo .. "/spec/fixtures/stdlib/native"

local NATIVE_OWNER_PROBE = [[
    local libuv = foreign import "uv.h"
    local lua = foreign import "lua.h"
    local ffi = foreign import "titan/ffi.h"
    local allocation = foreign import "titan_uv_test_allocation.h"

    -- Only this module can construct the wrapper or access its native handle.
    -- Importers carry the exact record identity across module calls without
    -- converting it through value.
    record uv_timer_t
      local handle: *libuv.uv_timer_t
      local storage: value
    end

    function new_timer(): uv_timer_t
      local top = lua.lua_gettop(L)
      local memory = lua.lua_newuserdatauv(L, libuv.uv_timer_t.sizeof, 0)
      local storage = ffi.lua_totvalue(L, -1)
      local timer = uv_timer_t.new(memory as *libuv.uv_timer_t, storage)
      lua.lua_settop(L, top)
      return timer
    end

    function _has_native_handle(timer: uv_timer_t): boolean
      return timer.handle ~= nil
    end

    function _access_without_boxing(
        timer: uv_timer_t,
        access: (uv_timer_t) -> boolean): boolean
      allocation.titan_uv_test_reset_userdata_allocations()
      return access(timer) and
          (allocation.titan_uv_test_get_userdata_allocations() as integer) == 0 and
          (allocation.titan_uv_test_get_internal_userdata_allocations()
              as integer) == 0
    end
]]

local NATIVE_OWNER_CONSUMER = [[
    local native = import "native_owner_probe"
    local allocation = foreign import "titan_uv_test_allocation.h"

    local function cross_module_access(timer: native.uv_timer_t): boolean
      return native._has_native_handle(timer)
    end

    function no_boxing(): boolean
      local timer = native.new_timer()
      -- The allocation counter object is linked into both DSOs. Check the caller
      -- and provider copies around the exact typed cross-module call.
      allocation.titan_uv_test_reset_userdata_allocations()
      return native._access_without_boxing(timer, cross_module_access) and
          (allocation.titan_uv_test_get_userdata_allocations() as integer) == 0 and
          (allocation.titan_uv_test_get_internal_userdata_allocations()
              as integer) == 0
    end
]]

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
    argv[#argv + 1] = "-I" .. NATIVE_FIXTURES
    append_shell_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = "-c"
    argv[#argv + 1] = NATIVE_FIXTURES .. "/titan_uv_test_allocation.c"
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
        async_stdlib.write_source(workspace, "native_owner_probe",
            NATIVE_OWNER_PROBE)
        async_stdlib.write_source(workspace, "native_owner_consumer",
            NATIVE_OWNER_CONSUMER)
        local cppflags = async_stdlib.host_libuv_config()
        cppflags = cppflags .. " -I" .. NATIVE_FIXTURES
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

    teardown(function() async_stdlib.cleanup(workspace) end)

    it("passes an exact opaque handle across modules without boxing", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local consumer = require "native_owner_consumer"
            assert(consumer.no_boxing(),
                   "cross-module typed-handle access allocated a userdata")
        ]])
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)
end)

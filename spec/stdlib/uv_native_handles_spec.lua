local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local NATIVE_FIXTURES = async_stdlib.repo .. "/spec/fixtures/stdlib/native"
local UV_SOURCE_ROOT = async_stdlib.repo .. "/titan/uv"

local function read_source(relative)
    return async_stdlib.read(UV_SOURCE_ROOT .. "/" .. relative)
end

local function assert_contains(source, literal, label)
    assert.truthy(source:find(literal, 1, true),
        (label or literal) .. " is missing")
end

local function assert_absent(source, literal, label)
    assert.falsy(source:find(literal, 1, true),
        (label or literal) .. " is still present")
end

local function owner_record_fields(source, name)
    local body = source:match("local record " .. name .. "\n(.-)\nend") or
        source:match("record " .. name .. "\n(.-)\nend")
    assert.truthy(body, "record " .. name .. " is missing")
    local fields = {}
    local declarations = {}
    for line in (body .. "\n"):gmatch("(.-)\n") do
        local field = line:match("^%s+local%s+([%w_]+)%??:")
        if field then
            fields[#fields + 1] = field
            declarations[#declarations + 1] = line
        end
    end
    return fields, declarations
end

local NATIVE_OWNER_PROBE = [[
    local libuv = foreign import "uv.h"
    local allocation = foreign import "titan_uv_test_allocation.h"

    -- Only this module can construct the wrapper or access its native handle.
    -- Importers carry the exact record identity across module calls without
    -- converting it through value.
    record uv_timer_t
      local handle?: owned *libuv.uv_timer_t
    end

    function new_timer(): uv_timer_t
      return uv_timer_t.new(libuv.uv_timer_t.new())
    end

    function _has_native_handle(timer: uv_timer_t): boolean
      if timer.handle then return true end
      return false
    end

    function _access_without_boxing(
        timer: uv_timer_t,
        access: (uv_timer_t) -> boolean): boolean
      allocation.titan_uv_test_reset_internal_userdata_allocations()
      return access(timer) and
          (allocation.titan_uv_test_get_internal_userdata_allocations()
              as integer) == 0
    end

    function _release_without_boxing(timer: uv_timer_t): boolean
      allocation.titan_uv_test_reset_internal_userdata_allocations()
      timer.handle = nil
      return not _has_native_handle(timer) and
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
      allocation.titan_uv_test_reset_internal_userdata_allocations()
      return native._access_without_boxing(timer, cross_module_access) and
          (allocation.titan_uv_test_get_internal_userdata_allocations()
              as integer) == 0
    end

    function early_release(): boolean
      local timer = native.new_timer()
      allocation.titan_uv_test_reset_internal_userdata_allocations()
      return native._release_without_boxing(timer) and
          not native._has_native_handle(timer) and
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

    it("releases an optional native owner without boxing", function()
        local ok, status, output = async_stdlib.run_lua_source(workspace, [[
            local consumer = require "native_owner_consumer"
            assert(consumer.early_release(),
                   "releasing an optional native owner allocated a userdata")
        ]])
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)
end)

describe("uv owned native-storage layout", function()
    local sources

    setup(function()
        sources = {}
        for _, name in ipairs({
            "runtime.titan",
            "task.titan",
            "file.titan",
            "os.titan",
            "process.titan",
            "tcp.titan",
        }) do
            sources[name] = read_source(name)
        end
    end)

    it("uses source-nameable owners and direct FFI constructors", function()
        assert_contains(sources["runtime.titan"],
            "local type Bytes = owned ffi.titan_ffi_char[]")
        assert_contains(sources["runtime.titan"],
            "local handle?: owned *libuv.uv_loop_t")
        assert_contains(sources["runtime.titan"],
            "local handle: owned *libuv.uv_buf_t")
        assert_contains(sources["runtime.titan"], "libuv.uv_loop_t.new()")
        assert_contains(sources["runtime.titan"], "libuv.uv_buf_t.new()")
        assert_contains(sources["runtime.titan"],
            "ffi.titan_ffi_char.new_array(")

        assert_contains(sources["task.titan"], "libuv.uv_timer_t.new()")
        assert_contains(sources["file.titan"], "libuv.uv_fs_t.new()")
        assert_contains(sources["file.titan"], "libuv.uv_dirent_t.new()")
        assert_contains(sources["os.titan"], "libuv.uv_signal_t.new()")
        assert_contains(sources["os.titan"], "libuv.size_t.new_array(1)")
        assert_contains(sources["os.titan"],
            "ffi.titan_ffi_char.new_array(")

        for _, constructor in ipairs({
            "libuv.uv_process_t.new()",
            "libuv.uv_pipe_t.new()",
            "libuv.uv_write_t.new()",
            "libuv.uv_timer_t.new()",
            "shim.titan_uvshim_char_ptr.new_array(",
        }) do
            assert_contains(sources["process.titan"], constructor)
        end

        assert_contains(sources["tcp.titan"],
            "local type AddressList = " ..
            "owned shim.titan_uvshim_address[]")
        for _, constructor in ipairs({
            "libuv.uv_getaddrinfo_t.new()",
            "libuv.uv_connect_t.new()",
            "libuv.uv_write_t.new()",
            "libuv.uv_shutdown_t.new()",
            "libuv.uv_tcp_t.new()",
            "shim.titan_uvshim_address.new_array(",
        }) do
            assert_contains(sources["tcp.titan"], constructor)
        end

        for name, source in pairs(sources) do
            assert_absent(source, "lua_newuserdatauv", name ..
                " raw Lua allocation")
            assert_absent(source, "local storage: value", name ..
                " redundant pointer storage")
            assert_absent(source, ".storage", name ..
                " stale storage field access")
            assert_absent(source, "six-slot", name ..
                " stale owner-slot description")
            assert_absent(source, "six fields", name ..
                " stale owner-field description")
        end

        for _, name in ipairs({
            "task.titan",
            "file.titan",
            "os.titan",
            "process.titan",
            "tcp.titan",
        }) do
            assert_contains(sources[name],
                "as ffi.titan_ffi_void_ptr",
                name .. " explicit owner identity cast")
            assert_absent(sources[name], "lua_togco",
                name .. " Lua-stack owner identity round trip")
        end
    end)

    it("keeps the five Titan owner fields aligned with the native protocol",
    function()
        local records = {
            ["task.titan"] = { "uv_timer_t" },
            ["file.titan"] = { "uv_fs_t" },
            ["os.titan"] = { "uv_signal_t" },
            ["process.titan"] = {
                "uv_pipe_t",
                "uv_pipe_write_t",
                "uv_process_grace_t",
                "uv_process_t",
            },
            ["tcp.titan"] = {
                "uv_getaddrinfo_t",
                "uv_connect_t",
                "uv_write_t",
                "uv_shutdown_t",
                "uv_tcp_t",
            },
        }
        local expected = {
            "handle",
            "main_thread",
            "dispatcher",
            "metadata",
            "buffer",
        }
        for source_name, names in pairs(records) do
            for _, name in ipairs(names) do
                local fields, declarations =
                    owner_record_fields(sources[source_name], name)
                assert.same(expected, fields, source_name .. ": " .. name)
                assert.truthy(declarations[1]:match(
                    "^%s+local handle%?: owned %*"),
                    source_name .. ": " .. name)
            end
        end

        local header = async_stdlib.read(
            async_stdlib.repo .. "/titan-runtime/titan/uv.h")
        assert_contains(header, "TITAN_UV_OWNER_NATIVE_LUA_SLOT = 1")
        assert_contains(header, "TITAN_UV_OWNER_MAIN_THREAD_LUA_SLOT = 2")
        assert_contains(header, "TITAN_UV_OWNER_DISPATCHER_LUA_SLOT = 3")
        assert_contains(header, "TITAN_UV_OWNER_METADATA_LUA_SLOT = 4")
        assert_contains(header, "TITAN_UV_OWNER_BUFFER_LUA_SLOT = 5")
        assert_contains(header, "TITAN_UV_OWNER_LUA_SLOT_COUNT = 5")
        assert_contains(header, "TITAN_UV_OWNER_NATIVE_C_INDEX = 0")
        assert_contains(header, "TITAN_UV_OWNER_MAIN_THREAD_C_INDEX = 1")
        assert_contains(header, "TITAN_UV_OWNER_DISPATCHER_C_INDEX = 2")
        assert_contains(header, "TITAN_UV_OWNER_METADATA_C_INDEX = 3")
        assert_contains(header, "TITAN_UV_OWNER_BUFFER_C_INDEX = 4")
        assert_contains(header, "TITAN_UV_OWNER_C_INDEX_COUNT = 5")
        assert_absent(header, "TITAN_UV_OWNER_STORAGE_",
            "redundant native storage slot")

        local native = async_stdlib.read(
            async_stdlib.repo .. "/titan-runtime/titan_uv.c")
        assert_contains(native, "TITAN_UV_OWNER_MAIN_THREAD_C_INDEX")
        assert_contains(native, "TITAN_UV_OWNER_DISPATCHER_C_INDEX")
        assert_absent(native, "TITAN_UV_OWNER_STORAGE_",
            "native redundant storage-slot access")
    end)

    it("retains callback lengths separately from read-buffer capacity",
    function()
        assert_contains(sources["runtime.titan"], "local record ByteChunk")
        assert_contains(sources["runtime.titan"], "local bytes: Bytes")
        assert_contains(sources["runtime.titan"], "local length: integer")
        assert_contains(sources["runtime.titan"],
            "local function bytes_string(bytes: *ffi.titan_ffi_char,")
        assert_contains(sources["runtime.titan"],
            "local function queued_bytes_string(queue: {ByteChunk})")

        for _, name in ipairs({ "process.titan", "tcp.titan" }) do
            assert_contains(sources[name], "local read_bytes: Bytes?")
            assert_contains(sources[name], "local read_queue: {ByteChunk}")
            assert_contains(sources[name], "ByteChunk.new(bytes, result)")
        end
    end)

    it("uses optional owner fields at explicit early-release boundaries",
    function()
        assert_contains(sources["task.titan"],
            "runtime.loop.handle = nil")
        for _, name in ipairs({
            "task.titan",
            "file.titan",
            "os.titan",
            "process.titan",
            "tcp.titan",
        }) do
            assert_contains(sources[name], ".handle = nil",
                name .. " owner release")
        end
    end)

    it("keeps delayed callback variants on the owned allocation boundary",
    function()
        local dns = async_stdlib.read(async_stdlib.repo ..
            "/spec/support/make_delayed_dns_callback_variant.lua")
        assert_contains(dns,
            "shim.titan_uvshim_address.new_array(count + leading)")
        assert_contains(dns,
            "dns.handle as owned *libuv.uv_getaddrinfo_t\\n")
        assert_contains(dns,
            "libuv.uv_cancel(handle as *libuv.uv_req_t)")
        assert_contains(dns,
            "owner_handle as *libuv.uv_req_t, pointer)")

        local fs = async_stdlib.read(async_stdlib.repo ..
            "/spec/support/make_delayed_fs_callback_variant.lua")
        assert_contains(fs,
            "fs_owner.handle as owned *libuv.uv_fs_t\\n")
        assert_contains(fs,
            "request_handle as *libuv.uv_req_t, pointer)")

        for name, source in pairs({ dns = dns, fs = fs }) do
            assert_absent(source, ".storage",
                name .. " delayed callback storage field")
            assert_absent(source, "lua_newuserdatauv",
                name .. " delayed callback raw allocation")
        end
    end)
end)

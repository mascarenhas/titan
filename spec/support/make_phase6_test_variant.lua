-- Generate an isolated Phase 6 signal-test uv.titan from the production
-- source.  Phase 6 deliberately composes the Phase 5 transformer first so
-- the one shared runtime variant retains all earlier fault instrumentation.
-- Usage: lua make_phase6_test_variant.lua INPUT OUTPUT

local input_path, output_path = assert(arg[1]), assert(arg[2])

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function replace_once(source, marker, replacement, label)
    local first = assert(source:find(marker, 1, true),
        "missing Phase 6 test-variant marker: " .. label)
    assert(not source:find(marker, first + #marker, true),
        "duplicate Phase 6 test-variant marker: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #marker)
end

local script_dir = assert(arg[0]:match("^(.*[/\\])"),
    "Phase 6 transformer must be invoked with its path")
local phase5_path = script_dir .. "make_phase5_test_variant.lua"
local intermediate = os.tmpname() .. "-titan-phase6-phase5.titan"
local saved_input, saved_output = arg[1], arg[2]
arg[1], arg[2] = input_path, intermediate
local ok, failure = pcall(assert(loadfile(phase5_path)))
arg[1], arg[2] = saved_input, saved_output
if not ok then
    os.remove(intermediate)
    error(failure, 0)
end

local source = read(intermediate)
os.remove(intermediate)
assert(source:find("__test_phase5_", 1, true),
    "Phase 5 instrumentation was not composed into Phase 6")
assert(not source:find("__test_phase6_", 1, true),
    "input is already a Phase 6 test variant")

source = replace_once(source, "-- TITAN_UV_PHASE6_TEST_STATE", [==[
-- TITAN_UV_PHASE6_TEST_STATE
-- Variant-only signal counters and one-shot transition faults. This source is
-- generated into a private workspace and is never installed.
local test_phase6_signal_init_attempts = 0
local test_phase6_signal_native_inits = 0
local test_phase6_signal_start_attempts = 0
local test_phase6_signal_native_starts = 0
local test_phase6_signal_arms = 0
local test_phase6_signal_callbacks = 0
local test_phase6_signal_closes = 0
local test_phase6_signal_sends = 0
local test_phase6_force_init_rejection = false
local test_phase6_force_start_rejection = false
local test_phase6_fail_callback = false
local test_phase6_fail_close_callback = false
local test_phase6_os_initial_override = 0
local test_phase6_os_fault_mode = 0
local test_phase6_os_allocations = 0
local test_phase6_os_result_attempts = 0
local test_phase6_os_grows = 0
local test_phase6_os_last_initial = 0
local test_phase6_os_last_grow_from = 0
local test_phase6_os_last_grow_to = 0
]==], "signal counters and controls")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_OS_BUFFER_INIT
  local capacity = OS_BUFFER_INITIAL]==], [==[  -- TITAN_UV_PHASE6_OS_BUFFER_INIT
  local capacity = OS_BUFFER_INITIAL
  if test_phase6_os_initial_override > 0 then
    capacity = test_phase6_os_initial_override
    test_phase6_os_initial_override = 0
  end
  test_phase6_os_result_attempts = 0
  test_phase6_os_allocations = 0
  test_phase6_os_grows = 0
  test_phase6_os_last_initial = capacity
  test_phase6_os_last_grow_from = 0
  test_phase6_os_last_grow_to = 0]==], "OS buffer initial capacity")

source = replace_once(source,
    "    local bytes = allocate_bytes(capacity)", [==[    test_phase6_os_allocations = test_phase6_os_allocations + 1
    local bytes = allocate_bytes(capacity)]==],
    "OS buffer allocation count")

source = replace_once(source, "    -- TITAN_UV_PHASE6_OS_BUFFER_RESULT", [==[
    -- TITAN_UV_PHASE6_OS_BUFFER_RESULT
    test_phase6_os_result_attempts =
        test_phase6_os_result_attempts + 1
    if test_phase6_os_fault_mode ~= 0 then
      -- Obtain the platform's real UV_ENOBUFS value through a public libuv
      -- operation; the parsed uv.h namespace intentionally does not expose
      -- libuv's generated error enum constants to Titan.
      sizes[0] = 1 as libuv.size_t
      status = libuv.uv_cwd(bytes.data, sizes)
      if (shim.titan_uvshim_status_is_enobufs(status) as integer) == 0 then
        raise "one-byte cwd probe did not report UV_ENOBUFS"
      end
    end
    if test_phase6_os_fault_mode == 1 then
      -- One ENOBUFS result that reports no growth requirement exercises the
      -- checked-doubling branch, then the next real libuv call may succeed.
      test_phase6_os_fault_mode = 0
      sizes[0] = capacity as libuv.size_t
    elseif test_phase6_os_fault_mode == 2 then
      -- A size_t value that cannot become int64_t must fail as EOVERFLOW
      -- before allocation or arithmetic uses it.
      test_phase6_os_fault_mode = 0
      sizes[0] = -1 as libuv.size_t
    elseif test_phase6_os_fault_mode == 3 then
      -- Keep reporting a non-growing requirement. The grow marker records the
      -- checked doubling, then holds the applied test capacity at one byte so
      -- all retry-limit iterations remain allocation-safe.
      sizes[0] = capacity as libuv.size_t
    elseif test_phase6_os_fault_mode == 4 then
      -- INT64_MAX is representable by the middle layer but exceeds the
      -- largest payload accepted by lua_newuserdatauv once its header offset
      -- is included. The production allocation validator must reject it
      -- before the grow marker or a second allocate_bytes call.
      test_phase6_os_fault_mode = 0
      sizes[0] = 9223372036854775807 as libuv.size_t
    end
]==], "OS buffer result faults")

source = replace_once(source, "    -- TITAN_UV_PHASE6_OS_BUFFER_GROW", [==[
    -- TITAN_UV_PHASE6_OS_BUFFER_GROW
    test_phase6_os_grows = test_phase6_os_grows + 1
    test_phase6_os_last_grow_from = capacity
    test_phase6_os_last_grow_to = next_capacity
    if test_phase6_os_fault_mode == 3 then
      next_capacity = 1
    end
]==], "OS buffer checked growth")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_SIGNAL_INIT
  local status = shim.titan_uvshim_signal_init(runtime.loop.handle,
                                               owner.handle, pointer)]==], [==[  -- TITAN_UV_PHASE6_SIGNAL_INIT
  test_phase6_signal_init_attempts =
      test_phase6_signal_init_attempts + 1
  local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
  if test_phase6_force_init_rejection then
    test_phase6_force_init_rejection = false
    status = shim.titan_uvshim_error_ecanceled()
  else
    test_phase6_signal_native_inits =
        test_phase6_signal_native_inits + 1
    status = shim.titan_uvshim_signal_init(runtime.loop.handle,
                                           owner.handle, pointer)
  end]==], "signal init rejection")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_SIGNAL_START
  status = shim.titan_uvshim_signal_start_oneshot(
      owner.handle, spec.signum as ffi.titan_ffi_int)]==], [==[  -- TITAN_UV_PHASE6_SIGNAL_START
  test_phase6_signal_start_attempts =
      test_phase6_signal_start_attempts + 1
  if test_phase6_force_start_rejection then
    test_phase6_force_start_rejection = false
    status = shim.titan_uvshim_error_ecanceled()
  else
    test_phase6_signal_native_starts =
        test_phase6_signal_native_starts + 1
    status = shim.titan_uvshim_signal_start_oneshot(
        owner.handle, spec.signum as ffi.titan_ffi_int)
    if (status as integer) >= 0 then
      test_phase6_signal_arms = test_phase6_signal_arms + 1
    end
  end]==], "signal start rejection and arm count")

source = replace_once(source, "    -- TITAN_UV_PHASE6_SIGNAL_CLOSE_CALLBACK", [==[
    -- TITAN_UV_PHASE6_SIGNAL_CLOSE_CALLBACK
    test_phase6_signal_closes = test_phase6_signal_closes + 1
    if test_phase6_fail_close_callback then
      test_phase6_fail_close_callback = false
      raise "phase6-forced-signal-close-callback-failure"
    end
]==], "signal close callback fault")

source = replace_once(source, "  -- TITAN_UV_PHASE6_SIGNAL_CALLBACK", [==[
  -- TITAN_UV_PHASE6_SIGNAL_CALLBACK
  test_phase6_signal_callbacks = test_phase6_signal_callbacks + 1
  if test_phase6_fail_callback then
    test_phase6_fail_callback = false
    raise "phase6-forced-signal-callback-failure"
  end
]==], "signal callback fault")

local hooks = [==[

function __test_phase6_reset_signal_state()
  if active_runtime and
      (active_runtime as Runtime).signal_owner_head ~= nil then
    raise "cannot reset Phase 6 signal state with a live owner"
  end
  test_phase6_signal_init_attempts = 0
  test_phase6_signal_native_inits = 0
  test_phase6_signal_start_attempts = 0
  test_phase6_signal_native_starts = 0
  test_phase6_signal_arms = 0
  test_phase6_signal_callbacks = 0
  test_phase6_signal_closes = 0
  test_phase6_signal_sends = 0
  test_phase6_force_init_rejection = false
  test_phase6_force_start_rejection = false
  test_phase6_fail_callback = false
  test_phase6_fail_close_callback = false
end

-- Test-only self delivery still goes through public libuv; no POSIX signal
-- function is used by either the fixture or the production implementation.
function __test_phase6_send_signal(name: string)
  local signum = shim.titan_uvshim_signal_number(name) as integer
  if signum <= 0 or
      (shim.titan_uvshim_signal_is_waitable(
          signum as ffi.titan_ffi_int) as integer) == 0 then
    raise "test signal is not a supported waitable signal"
  end
  local status = libuv.uv_kill(libuv.uv_os_getpid(),
                               signum as ffi.titan_ffi_int) as integer
  if status < 0 then raise make_error(status, "test.signal.send", name) end
  test_phase6_signal_sends = test_phase6_signal_sends + 1
end

function __test_phase6_force_signal_rejection(operation: string)
  if test_phase6_force_init_rejection or
      test_phase6_force_start_rejection then
    raise "a signal rejection is already pending"
  end
  if operation == "init" then
    test_phase6_force_init_rejection = true
  elseif operation == "start" then
    test_phase6_force_start_rejection = true
  else
    raise "unknown signal rejection operation"
  end
end

function __test_phase6_fail_next_signal_callback()
  if test_phase6_fail_callback then
    raise "a signal callback failure is already pending"
  end
  test_phase6_fail_callback = true
end

function __test_phase6_fail_next_signal_close_callback()
  if test_phase6_fail_close_callback then
    raise "a signal close callback failure is already pending"
  end
  test_phase6_fail_close_callback = true
end

function __test_phase6_signal_init_attempts(): integer
  return test_phase6_signal_init_attempts
end

function __test_phase6_signal_native_inits(): integer
  return test_phase6_signal_native_inits
end

function __test_phase6_signal_start_attempts(): integer
  return test_phase6_signal_start_attempts
end

function __test_phase6_signal_native_starts(): integer
  return test_phase6_signal_native_starts
end

function __test_phase6_signal_arms(): integer
  return test_phase6_signal_arms
end

function __test_phase6_signal_callbacks(): integer
  return test_phase6_signal_callbacks
end

function __test_phase6_signal_closes(): integer
  return test_phase6_signal_closes
end

function __test_phase6_signal_sends(): integer
  return test_phase6_signal_sends
end

function __test_phase6_signal_resources(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).signal_owner_head
  while raw ~= nil do
    count = count + 1
    raw = (raw as uv_signal_t).metadata.next_owner
  end
  return count
end

function __test_phase6_reset_os_buffer_state()
  test_phase6_os_initial_override = 0
  test_phase6_os_fault_mode = 0
  test_phase6_os_allocations = 0
  test_phase6_os_result_attempts = 0
  test_phase6_os_grows = 0
  test_phase6_os_last_initial = 0
  test_phase6_os_last_grow_from = 0
  test_phase6_os_last_grow_to = 0
end

function __test_phase6_os_initial_capacity(capacity: integer)
  if capacity <= 0 then raise "OS test buffer capacity must be positive" end
  test_phase6_os_initial_override = capacity
end

function __test_phase6_os_buffer_fault(mode: string)
  if test_phase6_os_fault_mode ~= 0 then
    raise "an OS buffer fault is already pending"
  end
  if mode == "non-growing" then
    test_phase6_os_fault_mode = 1
  elseif mode == "required-overflow" then
    test_phase6_os_fault_mode = 2
  elseif mode == "retry-exhaustion" then
    test_phase6_os_fault_mode = 3
  elseif mode == "allocation-overflow" then
    test_phase6_os_fault_mode = 4
  else
    raise "unknown OS buffer fault mode"
  end
end

function __test_phase6_os_allocations(): integer
  return test_phase6_os_allocations
end


function __test_phase6_os_result_attempts(): integer
  return test_phase6_os_result_attempts
end

function __test_phase6_os_grows(): integer
  return test_phase6_os_grows
end

function __test_phase6_os_last_initial(): integer
  return test_phase6_os_last_initial
end

function __test_phase6_os_last_grow_from(): integer
  return test_phase6_os_last_grow_from
end

function __test_phase6_os_last_grow_to(): integer
  return test_phase6_os_last_grow_to
end

function __test_phase6_has_active_runtime(): boolean
  if active_runtime then return true end
  return false
end
]==]

source = replace_once(source, "-- TITAN_UV_PHASE6_TEST_HOOKS",
    hooks .. "\n-- TITAN_UV_PHASE6_TEST_HOOKS", "signal hook API")

for _, hook in ipairs({
    "__test_phase6_reset_signal_state",
    "__test_phase6_send_signal",
    "__test_phase6_force_signal_rejection",
    "__test_phase6_fail_next_signal_callback",
    "__test_phase6_fail_next_signal_close_callback",
    "__test_phase6_signal_init_attempts",
    "__test_phase6_signal_native_inits",
    "__test_phase6_signal_start_attempts",
    "__test_phase6_signal_native_starts",
    "__test_phase6_signal_arms",
    "__test_phase6_signal_callbacks",
    "__test_phase6_signal_closes",
    "__test_phase6_signal_sends",
    "__test_phase6_signal_resources",
    "__test_phase6_reset_os_buffer_state",
    "__test_phase6_os_initial_capacity",
    "__test_phase6_os_buffer_fault",
    "__test_phase6_os_allocations",
    "__test_phase6_os_result_attempts",
    "__test_phase6_os_grows",
    "__test_phase6_os_last_initial",
    "__test_phase6_os_last_grow_from",
    "__test_phase6_os_last_grow_to",
    "__test_phase6_has_active_runtime",
}) do
    assert(source:find("function " .. hook, 1, true),
        "Phase 6 hook was not inserted: " .. hook)
end

write(output_path, source)

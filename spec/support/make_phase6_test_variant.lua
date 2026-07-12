-- Generate an isolated Phase 6 OS/signal/process-test uv.titan from production
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
-- Variant-only Phase 6 counters and one-shot transition faults. This source
-- is generated into a private workspace and is never installed.
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
local test_phase6_process_fault = 0
local test_phase6_process_callback_fault = 0
local test_phase6_track_inflight_write = false
local test_phase6_inflight_write_observed = false
local test_phase6_process_write_weak: value = nil
local test_phase6_process_stdio_attempts = 0
local test_phase6_process_stdio_native_calls = 0
local test_phase6_process_init_attempts = 0
local test_phase6_process_init_native_calls = 0
local test_phase6_process_open_attempts = 0
local test_phase6_process_open_native_calls = 0
local test_phase6_process_spawn_attempts = 0
local test_phase6_process_spawn_native_calls = 0
local test_phase6_process_native_initialized = 0
local test_phase6_process_exit_callbacks = 0
local test_phase6_process_close_callbacks = 0
local test_phase6_process_pipe_close_callbacks = 0
local test_phase6_process_pipe_read_callbacks = 0
local test_phase6_process_write_attempts = 0
local test_phase6_process_write_native_calls = 0
local test_phase6_process_write_callbacks = 0
local test_phase6_process_stdin_close_transitions = 0
local test_phase6_process_grace_callbacks = 0
local test_phase6_process_close_before_exit = 0
local test_phase6_process_helper_starts = 0
local test_phase6_process_helper_completions = 0

local function test_phase6_ensure_process_write_weak()
  if test_phase6_process_write_weak == nil then
    local top = lua.lua_gettop(L)
    lua.lua_createtable(L, 6, 0)
    lua.lua_createtable(L, 0, 1)
    lua.lua_pushstring(L, "v")
    lua.lua_setfield(L, -2, "__mode")
    lua.lua_setmetatable(L, -2)
    test_phase6_process_write_weak = ffi.lua_totvalue(L, -1)
    lua.lua_settop(L, top)
  end
end

local function test_phase6_weak_process_write_store(slot: integer,
                                                     item: value)
  test_phase6_ensure_process_write_weak()
  local top = lua.lua_gettop(L)
  ffi.lua_pushtvalue(L, test_phase6_process_write_weak)
  ffi.lua_pushtvalue(L, item)
  lua.lua_rawseti(L, -2, slot as lua.lua_Integer)
  lua.lua_settop(L, top)
end

local function test_phase6_weak_process_write_present(slot: integer): boolean
  test_phase6_ensure_process_write_weak()
  local top = lua.lua_gettop(L)
  ffi.lua_pushtvalue(L, test_phase6_process_write_weak)
  lua.lua_rawgeti(L, -1, slot as lua.lua_Integer)
  local present = lua.lua_type(L, -1) ~= lua.LUA_TNIL
  lua.lua_settop(L, top)
  return present
end
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
    elseif test_phase6_os_fault_mode == 5 then
      -- A portable libuv UV_ENOSYS result must surface as uv.Error without a
      -- hidden host-OS fallback.
      test_phase6_os_fault_mode = 0
      status = shim.titan_uvshim_error_enosys()
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

source = replace_once(source, [==[      -- TITAN_UV_PHASE6_PROCESS_WRITE_SUBMIT
      status = shim.titan_uvshim_pipe_write_start(
          owner.handle, pipe.handle, pointer, buffer.handle)]==], [==[      -- TITAN_UV_PHASE6_PROCESS_WRITE_SUBMIT
      test_phase6_process_write_attempts =
          test_phase6_process_write_attempts + 1
      if test_phase6_process_fault == 10 then
        test_phase6_process_fault = 0
        status = shim.titan_uvshim_error_ecanceled()
      else
        test_phase6_process_write_native_calls =
            test_phase6_process_write_native_calls + 1
        status = shim.titan_uvshim_pipe_write_start(
            owner.handle, pipe.handle, pointer, buffer.handle)
        if (status as integer) >= 0 and
            test_phase6_track_inflight_write then
          -- Observe the real accepted graph without changing its production
          -- lifecycle. The fixture cancels and collects only after this
          -- submission frame has returned and the writer Task has unwound.
          if test_phase6_process_write_callbacks ~= 0 then
            raise "process write callback ran before in-flight tracking hook"
          end
          if operation.owner == nil or owner.metadata.owner == nil or
              owner.storage == nil or owner.root == nil or owner.buffer == nil
          then
            raise "in-flight process write lost its accepted-request roots"
          end
          test_phase6_weak_process_write_store(1, owner)
          test_phase6_weak_process_write_store(2, owner.storage)
          test_phase6_weak_process_write_store(3, buffer)
          test_phase6_weak_process_write_store(4, buffer.storage)
          test_phase6_weak_process_write_store(5, buffer.bytes)
          test_phase6_weak_process_write_store(6, buffer.bytes.storage)
          test_phase6_track_inflight_write = false
          test_phase6_inflight_write_observed = true
        end
      end]==], "process write submission")

source = replace_once(source, [==[      -- TITAN_UV_PHASE6_PROCESS_STDIN_CLOSE
      control.write_shutdown = true
      start_pipe_close(pipe)]==], [==[      -- TITAN_UV_PHASE6_PROCESS_STDIN_CLOSE
      test_phase6_process_stdin_close_transitions =
          test_phase6_process_stdin_close_transitions + 1
      if test_phase6_process_fault == 11 then
        test_phase6_process_fault = 0
        operation.last_error = make_error(
            shim.titan_uvshim_error_ecanceled() as integer,
            "process.stdin.close", nil)
      end
      control.write_shutdown = true
      start_pipe_close(pipe)]==], "ordered stdin close transition")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_PROCESS_STDIO_CREATE
  local status = shim.titan_uvshim_stdio_pipes(
      endpoints, endpoint_count, fillers, filler_count)]==], [==[  -- TITAN_UV_PHASE6_PROCESS_STDIO_CREATE
  test_phase6_process_stdio_attempts =
      test_phase6_process_stdio_attempts + 1
  test_phase6_process_stdio_native_calls =
      test_phase6_process_stdio_native_calls + 1
  local status = shim.titan_uvshim_stdio_pipes(
      endpoints, endpoint_count, fillers, filler_count)
  if test_phase6_process_fault == 1 then
    test_phase6_process_fault = 0
    status = shim.titan_uvshim_error_ecanceled()
  end]==], "process stdio acquisition")

local function replace_process_transition(marker, call, fault,
                                          label, counter)
    source = replace_once(source, marker .. "\n" .. call,
        marker .. "\n" .. [==[    test_phase6_process_]==] .. counter .. [==[_attempts =
        test_phase6_process_]==] .. counter .. [==[_attempts + 1
    if test_phase6_process_fault == ]==] .. fault .. [==[ then
      test_phase6_process_fault = 0
      status = shim.titan_uvshim_error_ecanceled()
    else
      test_phase6_process_]==] .. counter .. [==[_native_calls =
          test_phase6_process_]==] .. counter .. [==[_native_calls + 1
]==] .. call .. "\n    end", label)
end

replace_process_transition(
    "    -- TITAN_UV_PHASE6_PROCESS_STDIN_INIT",
    [==[    status = shim.titan_uvshim_pipe_init(runtime.loop.handle,
        stdin_pipe.handle, stdin_pointer)]==], "2", "stdin pipe init", "init")
replace_process_transition(
    "      -- TITAN_UV_PHASE6_PROCESS_STDOUT_INIT",
    [==[      status = shim.titan_uvshim_pipe_init(runtime.loop.handle,
          stdout_pipe.handle, stdout_pointer)]==], "3", "stdout pipe init", "init")
replace_process_transition(
    "      -- TITAN_UV_PHASE6_PROCESS_STDERR_INIT",
    [==[      status = shim.titan_uvshim_pipe_init(runtime.loop.handle,
          stderr_pipe.handle, stderr_pointer)]==], "4", "stderr pipe init", "init")
replace_process_transition(
    "      -- TITAN_UV_PHASE6_PROCESS_STDIN_OPEN",
    [==[      status = shim.titan_uvshim_pipe_open(stdin_pipe.handle, endpoints,
          endpoint_count[0],
          shim.TITAN_UV_STDIO_STDIN_PARENT as ffi.titan_ffi_int)]==],
    "5", "stdin pipe open", "open")
replace_process_transition(
    "      -- TITAN_UV_PHASE6_PROCESS_STDOUT_OPEN",
    [==[      status = shim.titan_uvshim_pipe_open(stdout_pipe.handle, endpoints,
          endpoint_count[0],
          shim.TITAN_UV_STDIO_STDOUT_PARENT as ffi.titan_ffi_int)]==],
    "6", "stdout pipe open", "open")
replace_process_transition(
    "      -- TITAN_UV_PHASE6_PROCESS_STDERR_OPEN",
    [==[      status = shim.titan_uvshim_pipe_open(stderr_pipe.handle, endpoints,
          endpoint_count[0],
          shim.TITAN_UV_STDIO_STDERR_PARENT as ffi.titan_ffi_int)]==],
    "7", "stderr pipe open", "open")

source = replace_once(source, [==[      -- TITAN_UV_PHASE6_PROCESS_SPAWN_SUBMIT
      status = shim.titan_uvshim_process_spawn(runtime.loop.handle,
          process.handle, process_pointer, file.bytes.data, argv,
          argument_count, endpoints, endpoint_count[0], initialized)]==], [==[      -- TITAN_UV_PHASE6_PROCESS_SPAWN_SUBMIT
      test_phase6_process_spawn_attempts =
          test_phase6_process_spawn_attempts + 1
      if test_phase6_process_fault == 8 then
        test_phase6_process_fault = 0
        initialized[0] = 0 as ffi.titan_ffi_int
        status = shim.titan_uvshim_error_ecanceled()
      else
        test_phase6_process_spawn_native_calls =
            test_phase6_process_spawn_native_calls + 1
        status = shim.titan_uvshim_process_spawn(runtime.loop.handle,
            process.handle, process_pointer, file.bytes.data, argv,
            argument_count, endpoints, endpoint_count[0], initialized)
        if (initialized[0] as integer) ~= 0 then
          test_phase6_process_native_initialized =
              test_phase6_process_native_initialized + 1
        end
      end]==], "process spawn submission")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_PROCESS_RAW_CLOSE
  local raw_close_status = 0]==], [==[  -- TITAN_UV_PHASE6_PROCESS_RAW_CLOSE
  local raw_close_status = 0
  if test_phase6_process_fault == 9 then
    test_phase6_process_fault = 0
    raw_close_status = shim.titan_uvshim_error_ecanceled() as integer
  end]==], "post-spawn descriptor-close failure")

source = replace_once(source, [==[    -- TITAN_UV_PHASE6_PROCESS_EXIT_CALLBACK
    owner.metadata.exit_seen = true
    owner.metadata.exit_status = result
    owner.metadata.term_signal = size as integer
    owner.metadata.lifecycle = PROCESS_EXITED]==], [==[
    -- TITAN_UV_PHASE6_PROCESS_EXIT_CALLBACK
    owner.metadata.exit_seen = true
    owner.metadata.exit_status = result
    owner.metadata.term_signal = size as integer
    owner.metadata.lifecycle = PROCESS_EXITED
    test_phase6_process_exit_callbacks =
        test_phase6_process_exit_callbacks + 1
    if test_phase6_process_callback_fault == 1 then
      test_phase6_process_callback_fault = 0
      raise "phase6-forced-process-exit-callback-failure"
    end
]==], "process exit callback")

source = replace_once(source, [==[    -- TITAN_UV_PHASE6_PROCESS_CLOSE_CALLBACK
    owner.metadata.close_callback_seen = true
    owner.metadata.lifecycle = PROCESS_CLOSED]==], [==[
    -- TITAN_UV_PHASE6_PROCESS_CLOSE_CALLBACK
    owner.metadata.close_callback_seen = true
    owner.metadata.lifecycle = PROCESS_CLOSED
    test_phase6_process_close_callbacks =
        test_phase6_process_close_callbacks + 1
    if owner.metadata.published and not owner.metadata.exit_seen then
      test_phase6_process_close_before_exit =
          test_phase6_process_close_before_exit + 1
    end
    if test_phase6_process_callback_fault == 2 then
      test_phase6_process_callback_fault = 0
      raise "phase6-forced-process-close-callback-failure"
    end
]==], "process close callback")

source = replace_once(source, [==[    -- TITAN_UV_PHASE6_PROCESS_PIPE_CLOSE_CALLBACK
    owner.metadata.close_callback_seen = true
    owner.metadata.lifecycle = PIPE_CLOSED]==], [==[
    -- TITAN_UV_PHASE6_PROCESS_PIPE_CLOSE_CALLBACK
    owner.metadata.close_callback_seen = true
    owner.metadata.lifecycle = PIPE_CLOSED
    test_phase6_process_pipe_close_callbacks =
        test_phase6_process_pipe_close_callbacks + 1
    if test_phase6_process_callback_fault == 3 then
      test_phase6_process_callback_fault = 0
      raise "phase6-forced-process-pipe-close-callback-failure"
    end
]==], "process pipe close callback")

source = replace_once(source, [==[    -- TITAN_UV_PHASE6_PROCESS_PIPE_READ_CALLBACK
    if owner.metadata.read_active then
      shim.titan_uvshim_pipe_read_stop(owner.handle)
      owner.metadata.read_active = false
    end
    if result < 0 then
      if result == (shim.titan_uvshim_error_eof() as integer) then
        owner.metadata.read_terminal = TCP_READ_EOF
      else
        owner.metadata.read_terminal = TCP_READ_ERROR
      end
    end]==], [==[
    -- TITAN_UV_PHASE6_PROCESS_PIPE_READ_CALLBACK
    if owner.metadata.read_active then
      shim.titan_uvshim_pipe_read_stop(owner.handle)
      owner.metadata.read_active = false
    end
    if result < 0 then
      if result == (shim.titan_uvshim_error_eof() as integer) then
        owner.metadata.read_terminal = TCP_READ_EOF
      else
        owner.metadata.read_terminal = TCP_READ_ERROR
      end
    end
    test_phase6_process_pipe_read_callbacks =
        test_phase6_process_pipe_read_callbacks + 1
    if test_phase6_process_callback_fault == 4 then
      test_phase6_process_callback_fault = 0
      raise "phase6-forced-process-pipe-read-callback-failure"
    end
]==], "process pipe read callback")

source = replace_once(source,
    "  -- TITAN_UV_PHASE6_PROCESS_WRITE_CALLBACK", [==[
  -- TITAN_UV_PHASE6_PROCESS_WRITE_CALLBACK
  test_phase6_process_write_callbacks =
      test_phase6_process_write_callbacks + 1
  if test_phase6_process_callback_fault == 5 then
    test_phase6_process_callback_fault = 0
    raise "phase6-forced-process-write-callback-failure"
  end
]==], "process write callback")

source = replace_once(source,
    "    -- TITAN_UV_PHASE6_PROCESS_GRACE_CALLBACK", [==[
    -- TITAN_UV_PHASE6_PROCESS_GRACE_CALLBACK
    test_phase6_process_grace_callbacks =
        test_phase6_process_grace_callbacks + 1
    if test_phase6_process_callback_fault == 6 then
      test_phase6_process_callback_fault = 0
      raise "phase6-forced-process-grace-callback-failure"
    end
]==], "process grace callback")

source = replace_once(source,
    "  -- TITAN_UV_PHASE6_PROCESS_HELPER_COMPLETE", [==[
  -- TITAN_UV_PHASE6_PROCESS_HELPER_COMPLETE
  test_phase6_process_helper_completions =
      test_phase6_process_helper_completions + 1
]==], "process helper completion")

source = replace_once(source, [==[  -- TITAN_UV_PHASE6_PROCESS_HELPER_START
  local owner, status = start_owner(group.runtime, OWNER_START,
                                    task, nil, 0, 0, 0)]==], [==[
  -- TITAN_UV_PHASE6_PROCESS_HELPER_START
  test_phase6_process_helper_starts =
      test_phase6_process_helper_starts + 1
  local owner, status = start_owner(group.runtime, OWNER_START,
                                    task, nil, 0, 0, 0)
  if test_phase6_process_fault == 12 then
    -- The physical timer remains owned and drains normally.  Override the
    -- immediate logical result after the helper is registered/observed to
    -- prove that this infrastructure failure belongs to its HelperGroup.
    test_phase6_process_fault = 0
    status = shim.titan_uvshim_error_ecanceled() as integer
  end
]==], "process helper start")

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
  elseif mode == "enosys" then
    test_phase6_os_fault_mode = 5
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

function __test_phase6_reset_process_state()
  if active_runtime and
      ((active_runtime as Runtime).process_head ~= nil or
       (active_runtime as Runtime).process_request_head ~= nil) then
    raise "cannot reset Phase 6 process state with live native owners"
  end
  test_phase6_process_fault = 0
  test_phase6_process_callback_fault = 0
  test_phase6_track_inflight_write = false
  test_phase6_inflight_write_observed = false
  test_phase6_process_write_weak = nil
  test_phase6_process_stdio_attempts = 0
  test_phase6_process_stdio_native_calls = 0
  test_phase6_process_init_attempts = 0
  test_phase6_process_init_native_calls = 0
  test_phase6_process_open_attempts = 0
  test_phase6_process_open_native_calls = 0
  test_phase6_process_spawn_attempts = 0
  test_phase6_process_spawn_native_calls = 0
  test_phase6_process_native_initialized = 0
  test_phase6_process_exit_callbacks = 0
  test_phase6_process_close_callbacks = 0
  test_phase6_process_pipe_close_callbacks = 0
  test_phase6_process_pipe_read_callbacks = 0
  test_phase6_process_write_attempts = 0
  test_phase6_process_write_native_calls = 0
  test_phase6_process_write_callbacks = 0
  test_phase6_process_stdin_close_transitions = 0
  test_phase6_process_grace_callbacks = 0
  test_phase6_process_close_before_exit = 0
  test_phase6_process_helper_starts = 0
  test_phase6_process_helper_completions = 0
end

function __test_phase6_force_process_failure(stage: string)
  if test_phase6_process_fault ~= 0 then
    raise "a process transition failure is already pending"
  end
  if stage == "stdio" then test_phase6_process_fault = 1
  elseif stage == "stdin-init" then test_phase6_process_fault = 2
  elseif stage == "stdout-init" then test_phase6_process_fault = 3
  elseif stage == "stderr-init" then test_phase6_process_fault = 4
  elseif stage == "stdin-open" then test_phase6_process_fault = 5
  elseif stage == "stdout-open" then test_phase6_process_fault = 6
  elseif stage == "stderr-open" then test_phase6_process_fault = 7
  elseif stage == "spawn" then test_phase6_process_fault = 8
  elseif stage == "raw-close" then test_phase6_process_fault = 9
  elseif stage == "write" then test_phase6_process_fault = 10
  elseif stage == "close" then test_phase6_process_fault = 11
  elseif stage == "helper-start" then test_phase6_process_fault = 12
  else raise "unknown process transition failure stage"
  end
end

function __test_phase6_fail_next_process_callback(stage: string)
  if test_phase6_process_callback_fault ~= 0 then
    raise "a process callback failure is already pending"
  end
  if stage == "exit" then test_phase6_process_callback_fault = 1
  elseif stage == "process-close" then
    test_phase6_process_callback_fault = 2
  elseif stage == "pipe-close" then test_phase6_process_callback_fault = 3
  elseif stage == "pipe-read" then test_phase6_process_callback_fault = 4
  elseif stage == "write" then test_phase6_process_callback_fault = 5
  elseif stage == "grace" then test_phase6_process_callback_fault = 6
  else raise "unknown process callback failure stage"
  end
end

function __test_phase6_track_next_process_write_inflight()
  if test_phase6_track_inflight_write then
    raise "an in-flight process write observation is already pending"
  end
  test_phase6_process_write_weak = nil
  test_phase6_ensure_process_write_weak()
  test_phase6_track_inflight_write = true
  test_phase6_inflight_write_observed = false
end

function __test_phase6_inflight_process_write_observed(): boolean
  return test_phase6_inflight_write_observed
end

function __test_phase6_inflight_process_write_roots_alive(): boolean
  if not test_phase6_inflight_write_observed then return false end
  for slot = 1, 6 do
    if not test_phase6_weak_process_write_present(slot) then return false end
  end
  return true
end

function __test_phase6_inflight_process_write_roots_released(): boolean
  if not test_phase6_inflight_write_observed then return false end
  for slot = 1, 6 do
    if test_phase6_weak_process_write_present(slot) then return false end
  end
  return true
end

function __test_phase6_process_fault_pending(): boolean
  return test_phase6_process_fault ~= 0 or
         test_phase6_process_callback_fault ~= 0 or
         test_phase6_track_inflight_write
end

function __test_phase6_process_counter(name: string): integer
  if name == "stdio-attempts" then return test_phase6_process_stdio_attempts
  elseif name == "stdio-native" then
    return test_phase6_process_stdio_native_calls
  elseif name == "init-attempts" then return test_phase6_process_init_attempts
  elseif name == "init-native" then
    return test_phase6_process_init_native_calls
  elseif name == "open-attempts" then return test_phase6_process_open_attempts
  elseif name == "open-native" then
    return test_phase6_process_open_native_calls
  elseif name == "spawn-attempts" then
    return test_phase6_process_spawn_attempts
  elseif name == "spawn-native" then
    return test_phase6_process_spawn_native_calls
  elseif name == "native-initialized" then
    return test_phase6_process_native_initialized
  elseif name == "exit-callbacks" then
    return test_phase6_process_exit_callbacks
  elseif name == "process-close-callbacks" then
    return test_phase6_process_close_callbacks
  elseif name == "pipe-close-callbacks" then
    return test_phase6_process_pipe_close_callbacks
  elseif name == "pipe-read-callbacks" then
    return test_phase6_process_pipe_read_callbacks
  elseif name == "write-attempts" then
    return test_phase6_process_write_attempts
  elseif name == "write-native" then
    return test_phase6_process_write_native_calls
  elseif name == "write-callbacks" then
    return test_phase6_process_write_callbacks
  elseif name == "stdin-close-transitions" then
    return test_phase6_process_stdin_close_transitions
  elseif name == "grace-callbacks" then
    return test_phase6_process_grace_callbacks
  elseif name == "close-before-exit" then
    return test_phase6_process_close_before_exit
  elseif name == "helper-starts" then
    return test_phase6_process_helper_starts
  elseif name == "helper-completions" then
    return test_phase6_process_helper_completions
  end
  raise "unknown Phase 6 process counter"
  return -1
end

function __test_phase6_process_resources(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).process_head
  while raw ~= nil do
    count = count + 1
    raw = (raw as ProcessControl).next_control
  end
  return count
end

function __test_phase6_process_requests(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).process_request_head
  while raw ~= nil do
    count = count + 1
    raw = (raw as ProcessRequestControl).next_control
  end
  return count
end

function __test_phase6_process_live_helpers(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).task_head
  while raw ~= nil do
    local task = raw as Task
    if task.helper_group ~= nil and not terminal(task.state) then
      count = count + 1
    end
    raw = task.next_task
  end
  return count
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
    "__test_phase6_reset_process_state",
    "__test_phase6_force_process_failure",
    "__test_phase6_fail_next_process_callback",
    "__test_phase6_track_next_process_write_inflight",
    "__test_phase6_inflight_process_write_observed",
    "__test_phase6_inflight_process_write_roots_alive",
    "__test_phase6_inflight_process_write_roots_released",
    "__test_phase6_process_fault_pending",
    "__test_phase6_process_counter",
    "__test_phase6_process_resources",
    "__test_phase6_process_requests",
    "__test_phase6_process_live_helpers",
}) do
    assert(source:find("function " .. hook, 1, true),
        "Phase 6 hook was not inserted: " .. hook)
end

write(output_path, source)

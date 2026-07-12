-- Generate an isolated networking-test uv.titan from the production source.
-- Usage: lua make_phase5_test_variant.lua INPUT OUTPUT
--
-- Exact, single-occurrence markers keep timing controls and diagnostics out of
-- the installed module and fail closed when a callback transition changes.
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
        "missing Phase 5 test-variant marker: " .. label)
    assert(not source:find(marker, first + #marker, true),
        "duplicate Phase 5 test-variant marker: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #marker)
end

local source = read(input_path)
assert(not source:find("__test_phase5_", 1, true),
    "input is already a Phase 5 test variant")

source = replace_once(source, "-- TITAN_UV_PHASE5_OWNER_KINDS", [==[
-- TITAN_UV_PHASE5_OWNER_KINDS
-- Variant-only timer kinds defer logical request delivery after the physical
-- libuv callback has returned to Titan.
local OWNER_PHASE5_DNS_DELAY = 101
local OWNER_PHASE5_CONNECT_DELAY = 102
local OWNER_PHASE5_WRITE_DELAY = 103
]==], "private delay owner kinds")

source = replace_once(source, "-- TITAN_UV_PHASE5_TEST_STATE", [==[
-- TITAN_UV_PHASE5_TEST_STATE
-- Variant-only networking state. This generated source is never installed.
local test_phase5_dns_callbacks = 0
local test_phase5_dns_nonnull_results = 0
local test_phase5_dns_release_calls = 0
local test_phase5_dns_submissions = 0
local test_phase5_dns_cancel_calls = 0
local test_phase5_dns_cancel_actual_status = 0
local test_phase5_dns_cancel_status = 0
local test_phase5_connect_callbacks = 0
local test_phase5_write_callbacks = 0
local test_phase5_tcp_read_callbacks = 0
local test_phase5_tcp_close_callbacks = 0
local test_phase5_connect_publications = 0
local test_phase5_dns_retires = 0
local test_phase5_connect_retires = 0
local test_phase5_write_retires = 0
local test_phase5_shutdown_retires = 0
local test_phase5_output_unlinks = 0
local test_phase5_tcp_close_starts = 0
local test_phase5_tcp_unlinks = 0
local test_phase5_dispatch_fault: string? = nil
local test_phase5_dispatch_fault_hits = 0
local test_phase5_dns_delay = 0
local test_phase5_connect_delay = 0
local test_phase5_write_delay = 0
local test_phase5_force_dns_failure = false
local test_phase5_force_sync_dns = false
local test_phase5_force_sync_tcp_init = false
local test_phase5_force_sync_connect = false
local test_phase5_force_sync_listen = false
local test_phase5_force_sync_write = false
local test_phase5_force_sync_shutdown = false
local test_phase5_force_sync_read_start = false
local test_phase5_dns_cancel_override_success = false
local test_phase5_cancel_inflight_dns = false
local test_phase5_cancel_inflight_connect = false
local test_phase5_cancel_inflight_write = false
local test_phase5_inflight_dns_observed = false
local test_phase5_inflight_connect_observed = false
local test_phase5_inflight_write_observed = false

local function test_phase5_dispatch_fault_point(stage: string)
  local configured: string? = test_phase5_dispatch_fault
  if configured and (configured as string) == stage then
    test_phase5_dispatch_fault = nil
    test_phase5_dispatch_fault_hits = test_phase5_dispatch_fault_hits + 1
    raise "phase5-forced-net-" .. stage .. "-dispatcher-failure"
  end
end
]==], "networking counters and fault controls")

source = replace_once(source, [==[local function retire_net_control(control: NetRequestControl)
  if control.lifecycle == NET_OWNER_RETIRED then return end
  free_dns_result(control)]==], [==[local function retire_net_control(control: NetRequestControl)
  if control.lifecycle == NET_OWNER_RETIRED then return end
  if control.kind == NET_OWNER_DNS then
    test_phase5_dns_retires = test_phase5_dns_retires + 1
  elseif control.kind == NET_OWNER_CONNECT then
    test_phase5_connect_retires = test_phase5_connect_retires + 1
  elseif control.kind == NET_OWNER_WRITE then
    test_phase5_write_retires = test_phase5_write_retires + 1
  elseif control.kind == NET_OWNER_SHUTDOWN then
    test_phase5_shutdown_retires = test_phase5_shutdown_retires + 1
  else
    raise "unknown network owner kind retired by Phase 5 variant"
  end
  free_dns_result(control)]==], "network request terminal retirement counters")

source = replace_once(source, [==[local function remove_output(tcp: uv_tcp_t, operation: NetOperation)
  if not operation.linked or operation.close_waiter then return end
  local control = tcp.metadata]==], [==[local function remove_output(tcp: uv_tcp_t, operation: NetOperation)
  if not operation.linked or operation.close_waiter then return end
  test_phase5_output_unlinks = test_phase5_output_unlinks + 1
  local control = tcp.metadata]==], "network output FIFO unlink counter")

source = replace_once(source, [==[local function discard_tcp_storage(tcp: uv_tcp_t)
  local control = tcp.metadata
  if control.owner == nil then return end
  -- Unlink while every owner/root field is still intact.]==], [==[local function discard_tcp_storage(tcp: uv_tcp_t)
  local control = tcp.metadata
  if control.owner == nil then return end
  test_phase5_tcp_unlinks = test_phase5_tcp_unlinks + 1
  -- Unlink while every owner/root field is still intact.]==],
    "TCP terminal storage unlink counter")

source = replace_once(source, [==[  control.lifecycle = TCP_CLOSING
  shim.titan_uvshim_tcp_close(tcp.handle)
end

local function new_process_control]==], [==[  control.lifecycle = TCP_CLOSING
  test_phase5_tcp_close_starts = test_phase5_tcp_close_starts + 1
  shim.titan_uvshim_tcp_close(tcp.handle)
end

local function new_process_control]==], "TCP native close submission counter")

source = replace_once(source, [==[    operation.addresses = addresses
    free_dns_result(control)
    if addresses.count == 0 then]==], [==[    operation.addresses = addresses
    free_dns_result(control)
    test_phase5_dispatch_fault_point("dns-after-free")
    if addresses.count == 0 then]==],
    "DNS fault after borrowed-result copy and release")

source = replace_once(source, [==[local function tcp_read_dispatch(tcp: uv_tcp_t, result: integer)
  local control = tcp.metadata
  if result == 0 then return end
  local raw_waiter = control.read_waiter]==], [==[local function tcp_read_dispatch(tcp: uv_tcp_t, result: integer)
  local control = tcp.metadata
  if result == 0 then return end
  test_phase5_tcp_read_callbacks = test_phase5_tcp_read_callbacks + 1
  local raw_waiter = control.read_waiter]==], "TCP read callback counter")

source = replace_once(source, [==[  control.read_bytes = nil
  tcp.buffer = nil
  if raw_waiter ~= nil then]==], [==[  control.read_bytes = nil
  tcp.buffer = nil
  test_phase5_dispatch_fault_point("tcp-read-after-root-clear")
  if raw_waiter ~= nil then]==],
    "TCP read fault after waiter buffer-root clear")

-- These one-shot branches replace only the native submit call.  The
-- production rejection path immediately following each call is left intact,
-- so the variant proves that an ALLOCATED owner is retired when libuv rejects
-- synchronously and therefore owes no callback.
source = replace_once(source, [==[  local status = shim.titan_uvshim_tcp_init(runtime.loop.handle, tcp.handle,
                                            pointer)]==], [==[  local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
  if test_phase5_force_sync_tcp_init then
    test_phase5_force_sync_tcp_init = false
    status = shim.titan_uvshim_error_ecanceled()
  else
    status = shim.titan_uvshim_tcp_init(runtime.loop.handle, tcp.handle,
                                        pointer)
  end]==], "synchronous TCP init rejection")

source = replace_once(source, [==[  -- TITAN_UV_PHASE5_DNS_SUBMIT
  local status = shim.titan_uvshim_getaddrinfo_start(
      loop_handle, owner.handle, pointer, node, port)]==], [==[  -- TITAN_UV_PHASE5_DNS_SUBMIT
  local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
  if test_phase5_force_sync_dns then
    test_phase5_force_sync_dns = false
    status = shim.titan_uvshim_error_ecanceled()
  else
    status = shim.titan_uvshim_getaddrinfo_start(
        loop_handle, owner.handle, pointer, node, port)
  end]==], "synchronous DNS rejection")

source = replace_once(source, [==[  if (status as integer) >= 0 then
    owner.metadata.lifecycle = NET_OWNER_SUBMITTED
  else
    owner.metadata.callback_result = status as integer
    retire_net_control(owner.metadata)
  end
  return owner, status as integer
end

local function finish_net_setup]==], [==[  if (status as integer) >= 0 then
    owner.metadata.lifecycle = NET_OWNER_SUBMITTED
    test_phase5_dns_submissions = test_phase5_dns_submissions + 1
  else
    owner.metadata.callback_result = status as integer
    retire_net_control(owner.metadata)
  end
  return owner, status as integer
end

local function finish_net_setup]==], "accepted DNS submission count")

source = replace_once(source, [==[        shim.titan_uvshim_getaddrinfo_cancel(dns.handle)
]==], [==[        test_phase5_dns_cancel_calls =
            test_phase5_dns_cancel_calls + 1
        -- Always exercise the real public API.  As in the Phase 4 FS race
        -- variant, the one-shot override changes only the observed status so
        -- both lifecycle outcomes are deterministic even if a worker claims
        -- the request before this loop-thread cancellation runs.
        local actual_cancel_status =
            shim.titan_uvshim_getaddrinfo_cancel(dns.handle) as integer
        test_phase5_dns_cancel_actual_status = actual_cancel_status
        if test_phase5_dns_cancel_override_success then
          test_phase5_dns_cancel_status = 0
          test_phase5_dns_cancel_override_success = false
        else
          test_phase5_dns_cancel_status = actual_cancel_status
        end
]==], "DNS cancellation observation")

source = replace_once(source, [==[    task.operation = owner
    task.state = TASK_WAITING
    return nil
  end

  local tcp = operation.tcp as uv_tcp_t]==], [==[    task.operation = owner
    task.state = TASK_WAITING
    if test_phase5_cancel_inflight_dns then
      if test_phase5_dns_callbacks ~= 0 then
        raise "DNS callback ran before in-flight cancellation hook"
      end
      test_phase5_cancel_inflight_dns = false
      test_phase5_inflight_dns_observed = true
      lua.lua_gc(L, lua.LUA_GCGEN)
      lua.lua_gc(L, lua.LUA_GCCOLLECT)
      request_cancel(task, "cancel-inflight-dns")
    end
    return nil
  end

  local tcp = operation.tcp as uv_tcp_t]==],
    "in-flight DNS cancellation after Task publication")

source = replace_once(source, [==[        -- TITAN_UV_PHASE5_CONNECT_SUBMIT
        local status = shim.titan_uvshim_tcp_connect_start(
            owner.handle, tcp_handle, pointer, address_data,
            address_count, address_index)]==], [==[        -- TITAN_UV_PHASE5_CONNECT_SUBMIT
        local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
        if test_phase5_force_sync_connect then
          test_phase5_force_sync_connect = false
          status = shim.titan_uvshim_error_ecanceled()
        else
          status = shim.titan_uvshim_tcp_connect_start(
              owner.handle, tcp_handle, pointer, address_data,
              address_count, address_index)
        end
        if (status as integer) >= 0 and
            test_phase5_cancel_inflight_connect then
          -- This runs after libuv accepted the native request and before its
          -- callback can run.  Mark the real lifecycle first, collect while
          -- libuv owns the request, then use the ordinary cancellation path.
          owner.metadata.lifecycle = NET_OWNER_SUBMITTED
          if test_phase5_connect_callbacks ~= 0 then
            raise "connect callback ran before in-flight cancellation hook"
          end
          test_phase5_cancel_inflight_connect = false
          test_phase5_inflight_connect_observed = true
          lua.lua_gc(L, lua.LUA_GCGEN)
          lua.lua_gc(L, lua.LUA_GCCOLLECT)
          request_cancel(operation.task as Task, "cancel-inflight-connect")
        end]==], "synchronous connect rejection")

source = replace_once(source, [==[          status = shim.titan_uvshim_tcp_listen(tcp.handle,
                                                operation.backlog)]==], [==[          if test_phase5_force_sync_listen then
            test_phase5_force_sync_listen = false
            status = shim.titan_uvshim_error_ecanceled()
          else
            status = shim.titan_uvshim_tcp_listen(tcp.handle,
                                                  operation.backlog)
          end]==], "synchronous listen rejection")

source = replace_once(source, [==[      -- TITAN_UV_PHASE5_WRITE_SUBMIT
      status = shim.titan_uvshim_tcp_write_start(
          owner.handle, tcp_handle, pointer, buffer_handle)]==], [==[      -- TITAN_UV_PHASE5_WRITE_SUBMIT
      if test_phase5_force_sync_write then
        test_phase5_force_sync_write = false
        status = shim.titan_uvshim_error_ecanceled()
      else
        status = shim.titan_uvshim_tcp_write_start(
            owner.handle, tcp_handle, pointer, buffer_handle)
      end
      if (status as integer) >= 0 and test_phase5_cancel_inflight_write then
        -- The copied Buffer is reachable only through the request/operation
        -- ownership graph during this collection; libuv still owns its
        -- pointer and has not entered the write callback.
        owner.metadata.lifecycle = NET_OWNER_SUBMITTED
        if test_phase5_write_callbacks ~= 0 then
          raise "write callback ran before in-flight cancellation hook"
        end
        test_phase5_cancel_inflight_write = false
        test_phase5_inflight_write_observed = true
        operation.prepared_buffer = nil
        lua.lua_gc(L, lua.LUA_GCGEN)
        lua.lua_gc(L, lua.LUA_GCCOLLECT)
        request_cancel(operation.task as Task, "cancel-inflight-write")
      end]==], "synchronous write rejection")

source = replace_once(source, [==[      -- TITAN_UV_PHASE5_SHUTDOWN_SUBMIT
      status = shim.titan_uvshim_tcp_shutdown_start(
          owner.handle, tcp_handle, pointer)]==], [==[      -- TITAN_UV_PHASE5_SHUTDOWN_SUBMIT
      if test_phase5_force_sync_shutdown then
        test_phase5_force_sync_shutdown = false
        status = shim.titan_uvshim_error_ecanceled()
      else
        status = shim.titan_uvshim_tcp_shutdown_start(
            owner.handle, tcp_handle, pointer)
      end]==], "synchronous shutdown rejection")

source = replace_once(source, [==[    -- TITAN_UV_PHASE5_READ_START
    local status = shim.titan_uvshim_tcp_read_start(tcp.handle)]==], [==[    -- TITAN_UV_PHASE5_READ_START
    local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
    if test_phase5_force_sync_read_start then
      test_phase5_force_sync_read_start = false
      status = shim.titan_uvshim_error_ecanceled()
    else
      status = shim.titan_uvshim_tcp_read_start(tcp.handle)
    end]==], "synchronous read-start rejection")

source = replace_once(source, "  -- TITAN_UV_PHASE5_TCP_TEST_FIELDS", [==[
  -- TITAN_UV_PHASE5_TCP_TEST_FIELDS
  local test_phase5_read_starts: integer
  local test_phase5_accept_overflow_closes: integer
]==], "per-TCP variant fields")

source = replace_once(source, "    -- TITAN_UV_PHASE5_TCP_TEST_INIT", [==[
    -- TITAN_UV_PHASE5_TCP_TEST_INIT
    test_phase5_read_starts = 0,
    test_phase5_accept_overflow_closes = 0,
]==], "per-TCP variant initialization")

source = replace_once(source, "    -- TITAN_UV_PHASE5_DNS_RELEASE", [==[
    -- TITAN_UV_PHASE5_DNS_RELEASE
    -- This counts the synchronous call into C. uv_freeaddrinfo itself runs
    -- inside titan_uvshim_addrinfo_free and is not directly instrumented here.
    test_phase5_dns_release_calls = test_phase5_dns_release_calls + 1
]==], "DNS result release call")

source = replace_once(source, "  -- TITAN_UV_PHASE5_DNS_CALLBACK", [==[
  -- TITAN_UV_PHASE5_DNS_CALLBACK
  test_phase5_dns_callbacks = test_phase5_dns_callbacks + 1
  if pointer ~= nil then
    test_phase5_dns_nonnull_results =
        test_phase5_dns_nonnull_results + 1
  end
  if test_phase5_force_dns_failure then
    test_phase5_force_dns_failure = false
    result = shim.titan_uvshim_error_eaddrnotavail() as integer
  end
]==], "DNS callback control")

source = replace_once(source, [==[  owner.metadata.result_pointer = pointer
  dns_dispatch_body(owner, event_kind, result, size, pointer)
catch]==], [==[  owner.metadata.result_pointer = pointer
  if test_phase5_dns_delay > 0 then
    local delay = test_phase5_dns_delay
    test_phase5_dns_delay = 0
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_PHASE5_DNS_DELAY, owner, nil, 0, delay, 0)
    if status < 0 then
      raise make_error(status, "test.net.resolve.delay", nil)
    end
    wake.root = owner
    return
  end
  dns_dispatch_body(owner, event_kind, result, size, pointer)
catch]==], "DNS callback deferral")

source = replace_once(source, "  -- TITAN_UV_PHASE5_CONNECT_CALLBACK", [==[
  -- TITAN_UV_PHASE5_CONNECT_CALLBACK
  test_phase5_connect_callbacks = test_phase5_connect_callbacks + 1
  if test_phase5_connect_delay > 0 then
    local delay = test_phase5_connect_delay
    test_phase5_connect_delay = 0
    local tcp = owner.metadata.operation.tcp as uv_tcp_t
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_PHASE5_CONNECT_DELAY, owner, nil, 0, delay, 0)
    if status < 0 then
      raise make_error(status, "test.net.connect.delay", nil)
    end
    -- The physical callback cleared this flag before reaching the marker.
    -- Reassert it while logical delivery is delayed so a cancellation-driven
    -- close callback cannot retire setup_operation and clear operation.tcp
    -- before connect_dispatch_body consumes the recorded result.
    tcp.metadata.connect_pending = true
    wake.root = owner
    return
  end
  test_phase5_dispatch_fault_point("connect-before-publish")
]==], "connect callback deferral")

source = replace_once(source, "  -- TITAN_UV_PHASE5_WRITE_CALLBACK", [==[
  -- TITAN_UV_PHASE5_WRITE_CALLBACK
  test_phase5_write_callbacks = test_phase5_write_callbacks + 1
  if test_phase5_write_delay > 0 then
    local delay = test_phase5_write_delay
    test_phase5_write_delay = 0
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_PHASE5_WRITE_DELAY, owner, nil, 0, delay, 0)
    if status < 0 then
      raise make_error(status, "test.net.write.delay", nil)
    end
    wake.root = owner
    return
  end
  test_phase5_dispatch_fault_point("write-before-unlink")
]==], "write callback deferral")

source = replace_once(source, "  -- TITAN_UV_PHASE5_TIMER_DISPATCH", [==[
  -- TITAN_UV_PHASE5_TIMER_DISPATCH
  elseif kind == OWNER_PHASE5_DNS_DELAY then
    local delayed = owner.metadata.task as uv_getaddrinfo_t
    dns_dispatch_body(delayed, EVENT_GETADDRINFO,
        delayed.metadata.callback_result, 0 as libuv.size_t,
        delayed.metadata.result_pointer)
  elseif kind == OWNER_PHASE5_CONNECT_DELAY then
    local delayed = owner.metadata.task as uv_connect_t
    local tcp = delayed.metadata.operation.tcp as uv_tcp_t
    tcp.metadata.connect_pending = false
    connect_dispatch_body(delayed, EVENT_CONNECT,
                          delayed.metadata.callback_result,
                          0 as libuv.size_t)
  elseif kind == OWNER_PHASE5_WRITE_DELAY then
    local delayed = owner.metadata.task as uv_write_t
    complete_output_callback(delayed.metadata, EVENT_WRITE, EVENT_WRITE,
                             delayed.metadata.callback_result, "net.write")
]==], "delayed logical callback delivery")

source = replace_once(source, "    -- TITAN_UV_PHASE5_CONNECT_PUBLISH", [==[
    -- TITAN_UV_PHASE5_CONNECT_PUBLISH
    test_phase5_connect_publications =
        test_phase5_connect_publications + 1
]==], "successful connect publication")

source = replace_once(source, "    -- TITAN_UV_PHASE5_TCP_CLOSE_CALLBACK", [==[
    -- TITAN_UV_PHASE5_TCP_CLOSE_CALLBACK
    test_phase5_tcp_close_callbacks =
        test_phase5_tcp_close_callbacks + 1
    test_phase5_dispatch_fault_point("tcp-close-after-terminal")
]==], "TCP close callback count")

source = replace_once(source, "    -- TITAN_UV_PHASE5_READ_START", [==[
    -- TITAN_UV_PHASE5_READ_START
    control.test_phase5_read_starts =
        control.test_phase5_read_starts + 1
]==], "TCP read-start count")

source = replace_once(source, "    -- TITAN_UV_PHASE5_ACCEPT_OVERFLOW", [==[
    -- TITAN_UV_PHASE5_ACCEPT_OVERFLOW
    control.test_phase5_accept_overflow_closes =
        control.test_phase5_accept_overflow_closes + 1
]==], "accepted-client overflow count")

local hook_api = [==[

-- Variant-only networking controls and diagnostics. The generated DSO is
-- isolated from installed/package artifacts.
function __test_phase5_reset_counters()
  if test_phase5_dns_delay ~= 0 or test_phase5_cancel_inflight_dns or
      test_phase5_dns_cancel_override_success or
      test_phase5_dispatch_fault then
    raise "cannot reset while a Phase 5 one-shot control is pending"
  end
  test_phase5_dns_callbacks = 0
  test_phase5_dns_nonnull_results = 0
  test_phase5_dns_release_calls = 0
  test_phase5_dns_submissions = 0
  test_phase5_dns_cancel_calls = 0
  test_phase5_dns_cancel_actual_status = 0
  test_phase5_dns_cancel_status = 0
  test_phase5_connect_callbacks = 0
  test_phase5_write_callbacks = 0
  test_phase5_tcp_read_callbacks = 0
  test_phase5_tcp_close_callbacks = 0
  test_phase5_connect_publications = 0
  test_phase5_dns_retires = 0
  test_phase5_connect_retires = 0
  test_phase5_write_retires = 0
  test_phase5_shutdown_retires = 0
  test_phase5_output_unlinks = 0
  test_phase5_tcp_close_starts = 0
  test_phase5_tcp_unlinks = 0
  test_phase5_dispatch_fault = nil
  test_phase5_dispatch_fault_hits = 0
  test_phase5_dns_delay = 0
  test_phase5_connect_delay = 0
  test_phase5_write_delay = 0
  test_phase5_force_dns_failure = false
  test_phase5_force_sync_dns = false
  test_phase5_force_sync_tcp_init = false
  test_phase5_force_sync_connect = false
  test_phase5_force_sync_listen = false
  test_phase5_force_sync_write = false
  test_phase5_force_sync_shutdown = false
  test_phase5_force_sync_read_start = false
  test_phase5_dns_cancel_override_success = false
  test_phase5_cancel_inflight_dns = false
  test_phase5_cancel_inflight_connect = false
  test_phase5_cancel_inflight_write = false
  test_phase5_inflight_dns_observed = false
  test_phase5_inflight_connect_observed = false
  test_phase5_inflight_write_observed = false
end

function __test_phase5_fail_next_dispatch(stage: string)
  if test_phase5_dispatch_fault then
    raise "a network dispatcher fault is already pending"
  end
  if stage ~= "dns-after-free" and stage ~= "connect-before-publish" and
      stage ~= "write-before-unlink" and
      stage ~= "tcp-read-after-root-clear" and
      stage ~= "tcp-close-after-terminal" then
    raise "unknown network dispatcher fault stage"
  end
  test_phase5_dispatch_fault = stage
end

function __test_phase5_dispatch_fault_pending(): boolean
  if test_phase5_dispatch_fault then return true end
  return false
end

function __test_phase5_dispatch_fault_hits(): integer
  return test_phase5_dispatch_fault_hits
end

function __test_phase5_cancel_next_dns_inflight()
  if test_phase5_cancel_inflight_dns then
    raise "an in-flight DNS cancellation is already pending"
  end
  if test_phase5_dns_cancel_override_success then
    raise "a DNS cancel-status override is already pending"
  end
  test_phase5_cancel_inflight_dns = true
  test_phase5_dns_cancel_override_success = true
  test_phase5_inflight_dns_observed = false
end

function __test_phase5_cancel_next_connect_inflight()
  if test_phase5_cancel_inflight_connect then
    raise "an in-flight connect cancellation is already pending"
  end
  test_phase5_cancel_inflight_connect = true
  test_phase5_inflight_connect_observed = false
end

function __test_phase5_cancel_next_write_inflight()
  if test_phase5_cancel_inflight_write then
    raise "an in-flight write cancellation is already pending"
  end
  test_phase5_cancel_inflight_write = true
  test_phase5_inflight_write_observed = false
end

function __test_phase5_inflight_connect_observed(): boolean
  return test_phase5_inflight_connect_observed
end

function __test_phase5_inflight_dns_observed(): boolean
  return test_phase5_inflight_dns_observed
end

function __test_phase5_inflight_write_observed(): boolean
  return test_phase5_inflight_write_observed
end

function __test_phase5_force_sync_rejection(operation: string)
  if test_phase5_force_sync_dns or test_phase5_force_sync_tcp_init or
      test_phase5_force_sync_connect or test_phase5_force_sync_listen or
      test_phase5_force_sync_write or test_phase5_force_sync_shutdown or
      test_phase5_force_sync_read_start then
    raise "a synchronous rejection is already pending"
  end
  if operation == "dns" then
    test_phase5_force_sync_dns = true
  elseif operation == "tcp-init" then
    test_phase5_force_sync_tcp_init = true
  elseif operation == "connect" then
    test_phase5_force_sync_connect = true
  elseif operation == "listen" then
    test_phase5_force_sync_listen = true
  elseif operation == "write" then
    test_phase5_force_sync_write = true
  elseif operation == "shutdown" then
    test_phase5_force_sync_shutdown = true
  elseif operation == "read-start" then
    test_phase5_force_sync_read_start = true
  else
    raise "unknown synchronous rejection operation"
  end
end

function __test_phase5_sync_rejection_pending(): boolean
  return test_phase5_force_sync_dns or test_phase5_force_sync_tcp_init or
         test_phase5_force_sync_connect or test_phase5_force_sync_listen or
         test_phase5_force_sync_write or test_phase5_force_sync_shutdown or
         test_phase5_force_sync_read_start
end

function __test_phase5_delay_next_connect_callback(milliseconds: integer)
  if milliseconds <= 0 then raise "connect callback delay must be positive" end
  if test_phase5_connect_delay ~= 0 then
    raise "a connect callback delay is already pending"
  end
  test_phase5_connect_delay = milliseconds
end

function __test_phase5_delay_next_dns_callback(milliseconds: integer)
  if milliseconds <= 0 then raise "DNS callback delay must be positive" end
  if test_phase5_dns_delay ~= 0 then
    raise "a DNS callback delay is already pending"
  end
  test_phase5_dns_delay = milliseconds
end

function __test_phase5_delay_next_write_callback(milliseconds: integer)
  if milliseconds <= 0 then raise "write callback delay must be positive" end
  if test_phase5_write_delay ~= 0 then
    raise "a write callback delay is already pending"
  end
  test_phase5_write_delay = milliseconds
end

function __test_phase5_force_next_dns_failure()
  if test_phase5_force_dns_failure then
    raise "a forced DNS failure is already pending"
  end
  test_phase5_force_dns_failure = true
end

function __test_phase5_dns_callbacks(): integer
  return test_phase5_dns_callbacks
end

function __test_phase5_dns_nonnull_results(): integer
  return test_phase5_dns_nonnull_results
end

function __test_phase5_dns_submissions(): integer
  return test_phase5_dns_submissions
end

function __test_phase5_dns_cancel_calls(): integer
  return test_phase5_dns_cancel_calls
end

function __test_phase5_dns_cancel_actual_status(): integer
  return test_phase5_dns_cancel_actual_status
end

function __test_phase5_dns_cancel_status(): integer
  return test_phase5_dns_cancel_status
end

function __test_phase5_dns_release_calls(): integer
  return test_phase5_dns_release_calls
end

function __test_phase5_connect_callbacks(): integer
  return test_phase5_connect_callbacks
end

function __test_phase5_write_callbacks(): integer
  return test_phase5_write_callbacks
end

function __test_phase5_tcp_read_callbacks(): integer
  return test_phase5_tcp_read_callbacks
end

function __test_phase5_tcp_close_callbacks(): integer
  return test_phase5_tcp_close_callbacks
end

function __test_phase5_connect_publications(): integer
  return test_phase5_connect_publications
end

function __test_phase5_net_retires(kind: string): integer
  if kind == "dns" then return test_phase5_dns_retires end
  if kind == "connect" then return test_phase5_connect_retires end
  if kind == "write" then return test_phase5_write_retires end
  if kind == "shutdown" then return test_phase5_shutdown_retires end
  raise "unknown network retirement counter"
  return 0
end

function __test_phase5_output_unlinks(): integer
  return test_phase5_output_unlinks
end

function __test_phase5_tcp_close_starts(): integer
  return test_phase5_tcp_close_starts
end

function __test_phase5_tcp_unlinks(): integer
  return test_phase5_tcp_unlinks
end

function __test_phase5_bound_port(server: uv_tcp_t): integer
  validate_tcp(server, "query a bound port on", true, false)
  local port = shim.titan_uvshim_tcp_bound_port(server.handle) as integer
  if port < 0 then raise make_error(port, "test.net.bound_port", "server") end
  return port
end

function __test_phase5_accept_queue_size(server: uv_tcp_t): integer
  validate_tcp(server, "query the accept queue on", true, false)
  return server.metadata.accept_count
end

function __test_phase5_accept_overflow_closes(server: uv_tcp_t): integer
  validate_tcp(server, "query accept overflow on", true, false)
  return server.metadata.test_phase5_accept_overflow_closes
end

function __test_phase5_reset(connection: uv_tcp_t)
  validate_tcp(connection, "reset", false, false)
  local control = connection.metadata
  if control.output_head ~= nil or control.output_current ~= nil or
      control.read_active then
    raise "test reset requires an idle Connection"
  end
  local status = shim.titan_uvshim_tcp_close_reset(connection.handle) as integer
  if status < 0 then raise make_error(status, "test.net.reset", "connection") end
  control.close_requested = true
  control.lifecycle = TCP_CLOSING
end

function __test_phase5_read_starts(connection: uv_tcp_t): integer
  validate_tcp(connection, "query read starts on", false, false)
  return connection.metadata.test_phase5_read_starts
end

function __test_phase5_net_pending(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).net_pending_head
  while raw ~= nil do
    count = count + 1
    raw = (raw as NetRequestControl).next_control
  end
  return count
end

function __test_phase5_tcp_resources(): integer
  if not active_runtime then return 0 end
  local count = 0
  local raw = (active_runtime as Runtime).tcp_head
  while raw ~= nil do
    count = count + 1
    raw = (raw as TcpControl).next_control
  end
  return count
end

function __test_phase5_runtime_active(): boolean
  if active_runtime then return true end
  return false
end
]==]

source = replace_once(source, "-- TITAN_UV_TEST_HOOKS",
    hook_api .. "\n-- TITAN_UV_TEST_HOOKS", "variant hook API")

for _, hook in ipairs({
    "__test_phase5_reset_counters",
    "__test_phase5_fail_next_dispatch",
    "__test_phase5_dispatch_fault_pending",
    "__test_phase5_dispatch_fault_hits",
    "__test_phase5_cancel_next_dns_inflight",
    "__test_phase5_cancel_next_connect_inflight",
    "__test_phase5_cancel_next_write_inflight",
    "__test_phase5_inflight_connect_observed",
    "__test_phase5_inflight_write_observed",
    "__test_phase5_inflight_dns_observed",
    "__test_phase5_force_sync_rejection",
    "__test_phase5_sync_rejection_pending",
    "__test_phase5_delay_next_connect_callback",
    "__test_phase5_delay_next_write_callback",
    "__test_phase5_delay_next_dns_callback",
    "__test_phase5_force_next_dns_failure",
    "__test_phase5_dns_callbacks",
    "__test_phase5_dns_nonnull_results",
    "__test_phase5_dns_submissions",
    "__test_phase5_dns_cancel_calls",
    "__test_phase5_dns_cancel_actual_status",
    "__test_phase5_dns_cancel_status",
    "__test_phase5_dns_release_calls",
    "__test_phase5_connect_callbacks",
    "__test_phase5_write_callbacks",
    "__test_phase5_tcp_read_callbacks",
    "__test_phase5_tcp_close_callbacks",
    "__test_phase5_connect_publications",
    "__test_phase5_net_retires",
    "__test_phase5_output_unlinks",
    "__test_phase5_tcp_close_starts",
    "__test_phase5_tcp_unlinks",
    "__test_phase5_bound_port",
    "__test_phase5_accept_queue_size",
    "__test_phase5_accept_overflow_closes",
    "__test_phase5_reset",
    "__test_phase5_read_starts",
    "__test_phase5_net_pending",
    "__test_phase5_tcp_resources",
    "__test_phase5_runtime_active",
}) do
    assert(source:find("function " .. hook, 1, true),
        "Phase 5 hook was not inserted: " .. hook)
end

write(output_path, source)

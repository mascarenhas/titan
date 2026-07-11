-- Generate an isolated fault-enabled uv.titan from the cleaned production
-- source. Usage: lua make_uv_test_variant.lua INPUT OUTPUT
--
-- This intentionally uses exact source anchors. A scheduler edit must update
-- this transformer explicitly; silently skipping instrumentation would turn
-- invariant tests into false positives.
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

local function replace_once(source, needle, replacement, label)
    local first = assert(source:find(needle, 1, true),
        "missing uv test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate uv test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local function replace_exact_count(source, needle, replacement, expected, label)
    local pieces = {}
    local cursor = 1
    local count = 0
    while true do
        local first = source:find(needle, cursor, true)
        if not first then break end
        pieces[#pieces + 1] = source:sub(cursor, first - 1)
        pieces[#pieces + 1] = replacement
        cursor = first + #needle
        count = count + 1
    end
    pieces[#pieces + 1] = source:sub(cursor)
    assert(count == expected, string.format(
        "expected %d uv test-variant anchors for %s, found %d",
        expected, label, count))
    return table.concat(pieces)
end

local function count_plain(source, needle)
    local cursor = 1
    local count = 0
    while true do
        local first = source:find(needle, cursor, true)
        if not first then return count end
        cursor = first + #needle
        count = count + 1
    end
end

local source = read(input_path)
assert(not source:find("_phase2_", 1, true),
    "input still exposes prototype _phase2_ hooks")
assert(not source:find("__test_", 1, true),
    "input is already a test variant")
assert(not source:find("function _cleanup_", 1, true),
    "cleanup shield must be local in production")

source = replace_exact_count(source,
    [[libuv.uv_run(runtime.loop.handle, libuv.UV_RUN_DEFAULT)]],
    [[test_uv_run_enter()
    libuv.uv_run(runtime.loop.handle, libuv.UV_RUN_DEFAULT)
    test_uv_run_exit()]], 2, "outer uv_run calls")

source = replace_once(source, [==[
    local callbacks = libuv.uv_run(runtime.loop.handle,
                                  libuv.UV_RUN_DEFAULT) as integer
]==], [==[
    test_uv_run_enter()
    local callbacks = libuv.uv_run(runtime.loop.handle,
                                  libuv.UV_RUN_DEFAULT) as integer
    test_uv_run_exit()
]==], "close-runtime uv_run call")

source = replace_once(source,
[[local active_runtime: Runtime? = nil]],
[[local active_runtime: Runtime? = nil

-- Variant-only state. This generated source is never installed.
local test_fail_next_cancel_timer = false
local test_fail_sleep_submissions = 0
local test_fallback_cancel_drives = 0
local test_deferred_error_callbacks = 0
local test_fail_next_close_bookkeeping = false
local test_retired_closed_owners = 0
local test_fail_next_join_wake = false
local test_join_wake_delay = 0
local test_deferred_error_delay = 0
local test_owner_starts = 0
local test_untracked_timer_storage: value = nil
local test_untracked_timer_handle: *libuv.uv_timer_t = nil
local test_callback_depth = 0
local test_max_callback_depth = 0
local test_non_main_dispatches = 0
local test_native_dispatches = 0
local test_uv_run_depth = 0
local test_max_uv_run_depth = 0

local function test_uv_run_enter()
  test_uv_run_depth = test_uv_run_depth + 1
  if test_uv_run_depth > test_max_uv_run_depth then
    test_max_uv_run_depth = test_uv_run_depth
  end
end

local function test_uv_run_exit()
  if test_uv_run_depth <= 0 then
    raise "test uv_run depth became unbalanced"
  end
  test_uv_run_depth = test_uv_run_depth - 1
end]], "test state and outer uv_run counters")

source = replace_once(source, [==[
local function start_owner(runtime: Runtime, kind: integer, task: value,
                           peer: value, epoch: integer,
                           timeout: integer, repeat_time: integer):
                           (uv_timer_t, integer)
  local owner, pointer = allocate_owner(runtime, kind, task, peer, epoch)
]==], [==[
local function start_owner(runtime: Runtime, kind: integer, task: value,
                           peer: value, epoch: integer,
                           timeout: integer, repeat_time: integer):
                           (uv_timer_t, integer)
  test_owner_starts = test_owner_starts + 1
  local owner, pointer = allocate_owner(runtime, kind, task, peer, epoch)
]==], "owner-start counter")

source = replace_once(source, [==[
local function timer_dispatch(owner: uv_timer_t, event_kind: integer,
                              result: integer, size: libuv.size_t,
                              pointer: ffi.titan_ffi_void_ptr)
  local runtime = owner.metadata.runtime
]==], [==[
local function timer_dispatch(owner: uv_timer_t, event_kind: integer,
                              result: integer, size: libuv.size_t,
                              pointer: ffi.titan_ffi_void_ptr)
  test_callback_depth = test_callback_depth + 1
  test_native_dispatches = test_native_dispatches + 1
  if test_callback_depth > test_max_callback_depth then
    test_max_callback_depth = test_callback_depth
  end
  if not on_main_thread() then
    test_non_main_dispatches = test_non_main_dispatches + 1
  end
  local runtime = owner.metadata.runtime
]==], "dispatcher entry counters")

source = replace_once(source, [==[
    owner.buffer = nil
    unlink_owner(owner)
    return
]==], [==[
    owner.buffer = nil
    unlink_owner(owner)
    test_callback_depth = test_callback_depth - 1
    return
]==], "dispatcher close exit counter")

source = replace_once(source, [==[
  else
    raise "timer owner has an invalid operation kind"
  end
catch
]==], [==[
  else
    raise "timer owner has an invalid operation kind"
  end
  test_callback_depth = test_callback_depth - 1
catch
]==], "dispatcher normal exit counter")

source = replace_once(source, [==[
catch
  if not owner.metadata.runtime.fatal then
    owner.metadata.runtime.fatal = true
    owner.metadata.runtime.closing = true
    owner.metadata.runtime.fatal_error = error
    owner.metadata.runtime.fatal_traceback = traceback
  end
  libuv.uv_stop(owner.metadata.runtime.loop.handle)
  return
end

local function adapt(func: () -> value): (value) -> value
]==], [==[
catch
  if not owner.metadata.runtime.fatal then
    owner.metadata.runtime.fatal = true
    owner.metadata.runtime.closing = true
    owner.metadata.runtime.fatal_error = error
    owner.metadata.runtime.fatal_traceback = traceback
  end
  libuv.uv_stop(owner.metadata.runtime.loop.handle)
  test_callback_depth = test_callback_depth - 1
  return
end

local function adapt(func: () -> value): (value) -> value
]==], "timer dispatcher catch exit counter")

source = replace_once(source, [==[
    local owner, status = start_owner(task.runtime, OWNER_JOIN_WAKE,
                                      joiner, task, joiner.epoch, 0, 0)
    if status < 0 then
      promote_fatal(task.runtime,
                    make_error(status, "task.join.wake", nil), "")
    else
      joiner.operation = owner
    end
]==], [==[
    if test_fail_next_join_wake then
      test_fail_next_join_wake = false
      promote_fatal(task.runtime,
          Error.new(-1, "EINJECTED", "injected Phase-2 fault",
                    "task.join.wake.injected", nil), "")
    else
      local join_timeout = test_join_wake_delay
      test_join_wake_delay = 0
      local owner, status = start_owner(task.runtime, OWNER_JOIN_WAKE,
                                        joiner, task, joiner.epoch,
                                        join_timeout, 0)
      if status < 0 then
        promote_fatal(task.runtime,
                      make_error(status, "task.join.wake", nil), "")
      else
        joiner.operation = owner
      end
    end
]==], "join-wake injection")

source = replace_once(source, [==[
  if task.state ~= TASK_RUNNING then
    detach_wait(task)
  end
  local owner, status = start_owner(runtime, OWNER_CANCEL, task, nil,
                                    task.epoch, 0, 0)
]==], [==[
  if task.state ~= TASK_RUNNING then
    detach_wait(task)
  end
  if test_fail_next_cancel_timer then
    test_fail_next_cancel_timer = false
    task.cancel_fallback = true
    promote_fatal(runtime,
        Error.new(-1, "EINJECTED", "injected Phase-2 fault",
                  "task.cancel.injected", nil), "")
    return
  end
  local owner, status = start_owner(runtime, OWNER_CANCEL, task, nil,
                                    task.epoch, 0, 0)
]==], "cancel-submit injection")

source = replace_once(source, [==[
  if request.kind == REQUEST_SLEEP then
    local owner, status = start_owner(runtime, OWNER_SLEEP, task, request,
]==], [==[
  if request.kind == REQUEST_SLEEP then
    if test_fail_sleep_submissions > 0 then
      test_fail_sleep_submissions = test_fail_sleep_submissions - 1
      task.current_request = nil
      return Error.new(-1, "EINJECTED", "injected Phase-2 fault",
                       "timer.start.injected", nil)
    end
    local owner, status = start_owner(runtime, OWNER_SLEEP, task, request,
]==], "sleep-submit injection")

source = replace_once(source, [==[
    if task.cleanup_shield_depth <= 0 then
      raise "cleanup Request escaped its cleanup shield"
    end
    local owner, status = start_owner(runtime, OWNER_CLEANUP_SLEEP,
]==], [==[
    if task.cleanup_shield_depth <= 0 then
      raise "cleanup Request escaped its cleanup shield"
    end
    if test_fail_sleep_submissions > 0 then
      test_fail_sleep_submissions = test_fail_sleep_submissions - 1
      task.current_request = nil
      return Error.new(-1, "EINJECTED", "injected Phase-2 fault",
                       "cleanup.timer.start.injected", nil)
    end
    local owner, status = start_owner(runtime, OWNER_CLEANUP_SLEEP,
]==], "cleanup-submit injection")

source = replace_once(source, [==[
        local deferred, deferred_status = start_owner(runtime,
            OWNER_DEFER_ERROR, task, immediate_error, task.epoch,
            0, 0)
]==], [==[
        local defer_timeout = test_deferred_error_delay
        test_deferred_error_delay = 0
        local deferred, deferred_status = start_owner(runtime,
            OWNER_DEFER_ERROR, task, immediate_error, task.epoch,
            defer_timeout, 0)
]==], "deferred-error delay")

source = replace_once(source, [==[
    if kind == OWNER_OBSERVE then
      runtime.pending_observations = runtime.pending_observations - 1
    end
    -- Keep this callback's owner strongly reachable while a helper can run or
]==], [==[
    if kind == OWNER_OBSERVE then
      runtime.pending_observations = runtime.pending_observations - 1
    end
    if test_fail_next_close_bookkeeping then
      test_fail_next_close_bookkeeping = false
      raise "injected close-bookkeeping failure"
    end
    -- Keep this callback's owner strongly reachable while a helper can run or
]==], "dispatcher-close injection")

source = replace_once(source, [==[
      drive_task(task, DRIVE_ERROR, owner.metadata.peer, "")
]==], [==[
      test_deferred_error_callbacks = test_deferred_error_callbacks + 1
      drive_task(task, DRIVE_ERROR, owner.metadata.peer, "")
]==], "deferred callback counter")

source = replace_once(source, [==[
      task.cancel_fallback = false
      drive_task(task, DRIVE_ERROR, task.cancel_value, "")
]==], [==[
      task.cancel_fallback = false
      test_fallback_cancel_drives = test_fallback_cancel_drives + 1
      drive_task(task, DRIVE_ERROR, task.cancel_value, "")
]==], "fallback counter")

source = replace_once(source, [==[
local function retire_closed_owners(runtime: Runtime)
  local raw = runtime.timer_owner_head
  while raw ~= nil do
    local owner = raw as uv_timer_t
    raw = owner.metadata.next_owner
    if owner.metadata.lifecycle == OWNER_CLOSED then
      owner.handle = nil
      owner.storage = nil
      owner.root = nil
      owner.buffer = nil
      unlink_owner(owner)
    end
  end
end
]==], [==[
local function retire_closed_owners(runtime: Runtime)
  local raw = runtime.timer_owner_head
  while raw ~= nil do
    local owner = raw as uv_timer_t
    raw = owner.metadata.next_owner
    if owner.metadata.lifecycle == OWNER_CLOSED then
      owner.handle = nil
      owner.storage = nil
      owner.root = nil
      owner.buffer = nil
      unlink_owner(owner)
      test_retired_closed_owners = test_retired_closed_owners + 1
    end
  end
end
]==], "retired-owner counter")

local hook_api = [==[

-- Variant-only public hooks. The generated DSO is isolated and never packed.
function __test_run_main(func: () -> value): Task
  return run_internal(func, true)
end

function __test_cancel_main(reason: value)
  local runtime = current_runtime()
  if runtime.main_task == nil then
    raise "test Runtime has no main Task"
  end
  request_cancel(runtime.main_task as Task, reason)
end

function __test_cleanup_begin()
  cleanup_begin()
end

function __test_cleanup_sleep(milliseconds: integer)
  cleanup_sleep(milliseconds)
end

function __test_cleanup_end()
  cleanup_end()
end

function __test_fail_next_cancel_timer()
  test_fail_next_cancel_timer = true
end

function __test_fail_sleep_submissions(count: integer)
  if count < 0 then raise "fault count must not be negative" end
  test_fail_sleep_submissions = count
end

function __test_fallback_cancel_drives(): integer
  return test_fallback_cancel_drives
end

function __test_deferred_error_callbacks(): integer
  return test_deferred_error_callbacks
end

function __test_fail_next_close_bookkeeping()
  test_fail_next_close_bookkeeping = true
end

function __test_retired_closed_owners(): integer
  return test_retired_closed_owners
end

function __test_fail_next_join_wake()
  test_fail_next_join_wake = true
end

function __test_delay_next_join_wake(milliseconds: integer)
  if milliseconds < 0 then raise "join-wake delay must not be negative" end
  test_join_wake_delay = milliseconds
end

function __test_owner_starts(): integer
  return test_owner_starts
end

function __test_init_untracked_timer()
  local runtime = current_runtime()
  local top = lua.lua_gettop(L)
  local memory = lua.lua_newuserdatauv(L, libuv.uv_timer_t.sizeof, 0)
  test_untracked_timer_storage = ffi.lua_totvalue(L, -1)
  test_untracked_timer_handle = memory as *libuv.uv_timer_t
  local status = libuv.uv_timer_init(runtime.loop.handle,
                                    test_untracked_timer_handle)
  lua.lua_settop(L, top)
  if (status as integer) < 0 then
    test_untracked_timer_handle = nil
    test_untracked_timer_storage = nil
    raise make_error(status as integer, "test.untracked.timer.init", nil)
  end
end

function __test_close_untracked_timer()
  if test_untracked_timer_handle ~= nil then
    shim.titan_uvshim_timer_close_discard(test_untracked_timer_handle)
  end
end

function __test_release_untracked_timer()
  test_untracked_timer_handle = nil
  test_untracked_timer_storage = nil
end

function __test_delay_next_deferred_error(milliseconds: integer)
  if milliseconds < 0 then raise "deferred-error delay must not be negative" end
  test_deferred_error_delay = milliseconds
end

function __test_reset_callback_counters()
  test_callback_depth = 0
  test_max_callback_depth = 0
  test_non_main_dispatches = 0
  test_native_dispatches = 0
  test_uv_run_depth = 0
  test_max_uv_run_depth = 0
end

function __test_callback_depth(): integer
  return test_callback_depth
end

function __test_max_callback_depth(): integer
  return test_max_callback_depth
end

function __test_non_main_dispatches(): integer
  return test_non_main_dispatches
end

function __test_native_dispatches(): integer
  return test_native_dispatches
end

function __test_uv_run_depth(): integer
  return test_uv_run_depth
end

function __test_max_uv_run_depth(): integer
  return test_max_uv_run_depth
end
]==]

source = replace_once(source, [==[
local function cleanup_end()
  local task = running_task()
  if task.cleanup_shield_depth <= 0 then
    raise "cleanup shield is not active"
  end
  task.cleanup_shield_depth = task.cleanup_shield_depth - 1
  if task.cleanup_shield_depth == 0 and task.cancel_requested then
    -- Keep cancellation sticky without interrupting a sequence of library
    -- cleanup operations.  The next ordinary await injects it, or drive_task
    -- classifies a returning Task as cancelled.
    task.cancel_deferred = false
  end
end
]==], [==[
local function cleanup_end()
  local task = running_task()
  if task.cleanup_shield_depth <= 0 then
    raise "cleanup shield is not active"
  end
  task.cleanup_shield_depth = task.cleanup_shield_depth - 1
  if task.cleanup_shield_depth == 0 and task.cancel_requested then
    -- Keep cancellation sticky without interrupting a sequence of library
    -- cleanup operations.  The next ordinary await injects it, or drive_task
    -- classifies a returning Task as cancelled.
    task.cancel_deferred = false
  end
end
]==] .. hook_api, "variant hook API")

assert(source:find("function __test_run_main", 1, true))
assert(source:find("function __test_max_callback_depth", 1, true))
assert(source:find("function __test_max_uv_run_depth", 1, true))
assert(source:find("function __test_delay_next_join_wake", 1, true))
assert(source:find("function __test_owner_starts", 1, true))
assert(source:find("function __test_init_untracked_timer", 1, true))
assert(source:find("function __test_close_untracked_timer", 1, true))
assert(source:find("function __test_release_untracked_timer", 1, true))
assert(source:find("local function test_uv_run_enter", 1, true))
assert(source:find("local function test_uv_run_exit", 1, true))
assert(count_plain(source, "libuv.uv_run(") == 3,
    "an outer uv_run call escaped test instrumentation")
assert(source:find("injected close-bookkeeping failure", 1, true))
write(output_path, source)

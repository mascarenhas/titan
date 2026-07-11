-- Generate an isolated race-enabled uv.titan from the production source.
-- Usage: lua make_phase4_test_variant.lua INPUT OUTPUT
--
-- Every edit uses a unique source anchor and fails closed when the scheduler
-- changes. The generated module belongs only to the spec workspace.
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
        "missing Phase 4 test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate Phase 4 test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local source = read(input_path)
assert(not source:find("__test_phase4_", 1, true),
    "input is already a Phase 4 test variant")

source = replace_once(source, [==[
local OWNER_TASK_DRIVE = 10
]==], [==[
local OWNER_TASK_DRIVE = 10
-- Variant-only timer that defers logical FS callback delivery after libuv has
-- already returned the native request.
local OWNER_PHASE4_FS_DELAY = 100
]==], "delayed FS owner kind")

source = replace_once(source, [==[
local active_runtime: Runtime? = nil
]==], [==[
local active_runtime: Runtime? = nil

-- Variant-only race controls. This generated source is never installed.
local test_phase4_owner_starts = 0
local test_phase4_cancel_delay = 0
local test_phase4_fs_delay = 0
local test_phase4_fs_physical_callbacks = 0
local test_phase4_fs_deliveries = 0
local test_phase4_fs_cancel_calls = 0
local test_phase4_fs_cancel_status = 0
local test_phase4_fs_cancel_override = 0
local test_phase4_fs_cancel_override_armed = false
local test_phase4_fs_cleanups = 0
]==], "race-control state")

source = replace_once(source, [==[
    -- TITAN_UV_FS_TEST_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    owner.metadata.cleaned = true
]==], [==[
    -- TITAN_UV_FS_TEST_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    test_phase4_fs_cleanups = test_phase4_fs_cleanups + 1
    owner.metadata.cleaned = true
]==], "FS cleanup counter")

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
  test_phase4_owner_starts = test_phase4_owner_starts + 1
  local owner, pointer = allocate_owner(runtime, kind, task, peer, epoch)
]==], "owner allocation counter")

source = replace_once(source, [==[
      shim.titan_uvshim_fs_cancel(fs_owner.handle)
]==], [==[
      test_phase4_fs_cancel_calls = test_phase4_fs_cancel_calls + 1
      local actual_cancel_status =
          shim.titan_uvshim_fs_cancel(fs_owner.handle) as integer
      if test_phase4_fs_cancel_override_armed then
        test_phase4_fs_cancel_status = test_phase4_fs_cancel_override
        test_phase4_fs_cancel_override = 0
        test_phase4_fs_cancel_override_armed = false
      else
        test_phase4_fs_cancel_status = actual_cancel_status
      end
]==], "FS cancel observation")

source = replace_once(source, [==[
  local owner, status = start_owner(runtime, OWNER_CANCEL, task, nil,
                                    task.epoch, 0, 0)
]==], [==[
  local cancel_delay = test_phase4_cancel_delay
  test_phase4_cancel_delay = 0
  local owner, status = start_owner(runtime, OWNER_CANCEL, task, nil,
                                    task.epoch, cancel_delay, 0)
]==], "delayed cancellation delivery")

source = replace_once(source, [==[
  if event_kind == EVENT_FS and result >= 0 and
      owner.metadata.operation.kind == FS.open then
    owner.metadata.acquired_file = result as libuv.uv_file
    owner.metadata.has_acquired_file = true
  end
  fs_dispatch_body(owner, event_kind, result, size)
]==], [==[
  if event_kind == EVENT_FS and result >= 0 and
      owner.metadata.operation.kind == FS.open then
    owner.metadata.acquired_file = result as libuv.uv_file
    owner.metadata.has_acquired_file = true
  end
  if test_phase4_fs_delay > 0 then
    local delay = test_phase4_fs_delay
    test_phase4_fs_delay = 0
    test_phase4_fs_physical_callbacks =
        test_phase4_fs_physical_callbacks + 1
    owner.metadata.callback_result = result
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_PHASE4_FS_DELAY, owner, nil, 0, delay, 0)
    if status < 0 then
      raise make_error(status, "test.fs.delay", nil)
    end
    wake.root = owner
    return
  end
  fs_dispatch_body(owner, event_kind, result, size)
]==], "physical FS callback deferral")

source = replace_once(source, [==[
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task as Task
]==], [==[
  elseif kind == OWNER_PHASE4_FS_DELAY then
    local fs_owner = owner.metadata.task as uv_fs_t
    test_phase4_fs_deliveries = test_phase4_fs_deliveries + 1
    fs_dispatch(fs_owner, EVENT_FS, fs_owner.metadata.callback_result,
                0 as libuv.size_t, nil)
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task as Task
]==], "delayed FS logical delivery")

local hook_api = [==[

-- Variant-only public controls. The generated DSO is isolated and never
-- installed or packed.
function __test_phase4_owner_starts(): integer
  return test_phase4_owner_starts
end

function __test_phase4_delay_next_cancel(milliseconds: integer)
  if milliseconds < 0 then raise "cancel delay must not be negative" end
  test_phase4_cancel_delay = milliseconds
end

function __test_phase4_delay_next_fs_callback(milliseconds: integer)
  if milliseconds <= 0 then raise "FS callback delay must be positive" end
  if test_phase4_fs_delay ~= 0 then
    raise "an FS callback delay is already pending"
  end
  test_phase4_fs_delay = milliseconds
end

function __test_phase4_reset_fs_counters()
  if test_phase4_fs_delay ~= 0 then
    raise "cannot reset while an FS callback delay is pending"
  end
  test_phase4_fs_physical_callbacks = 0
  test_phase4_fs_deliveries = 0
  test_phase4_fs_cancel_calls = 0
  test_phase4_fs_cancel_status = 0
  test_phase4_fs_cancel_override = 0
  test_phase4_fs_cancel_override_armed = false
  test_phase4_fs_cleanups = 0
end

function __test_phase4_override_next_fs_cancel_success()
  if test_phase4_fs_cancel_override_armed then
    raise "an FS cancel-status override is already pending"
  end
  test_phase4_fs_cancel_override = 0
  test_phase4_fs_cancel_override_armed = true
end

function __test_phase4_fs_physical_callbacks(): integer
  return test_phase4_fs_physical_callbacks
end

function __test_phase4_fs_deliveries(): integer
  return test_phase4_fs_deliveries
end

function __test_phase4_fs_cancel_calls(): integer
  return test_phase4_fs_cancel_calls
end

function __test_phase4_fs_cancel_status(): integer
  return test_phase4_fs_cancel_status
end

function __test_phase4_fs_cleanups(): integer
  return test_phase4_fs_cleanups
end
]==]

source = replace_once(source, [==[
-- TITAN_UV_TEST_HOOKS
]==], hook_api .. [==[
-- TITAN_UV_TEST_HOOKS
]==], "variant hook API")

for _, hook in ipairs({
    "__test_phase4_owner_starts",
    "__test_phase4_delay_next_cancel",
    "__test_phase4_delay_next_fs_callback",
    "__test_phase4_reset_fs_counters",
    "__test_phase4_override_next_fs_cancel_success",
    "__test_phase4_fs_physical_callbacks",
    "__test_phase4_fs_deliveries",
    "__test_phase4_fs_cancel_calls",
    "__test_phase4_fs_cancel_status",
    "__test_phase4_fs_cleanups",
}) do
    assert(source:find("function " .. hook, 1, true),
        "Phase 4 hook was not inserted: " .. hook)
end

write(output_path, source)

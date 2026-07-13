-- Generate an isolated filesystem-fault-enabled uv.titan from the production
-- source. Usage: lua make_fs_test_variant.lua INPUT OUTPUT
--
-- Exact, single-occurrence anchors make this fail closed when the filesystem
-- owner or File pump changes. The generated module is private to the spec
-- workspace and is never installed.
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
        "missing fs test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate fs test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local source = read(input_path)
assert(not source:find("__test_fs_", 1, true),
    "input is already a filesystem test variant")

source = replace_once(source, [==[
local shim = foreign import "titan/uv.h"
]==], [==[
local shim = foreign import "titan/uv.h"
local test_cstring = foreign import "string.h"
]==], "variant memset import")

source = replace_once(source, [==[
  local previous_file: uv_file?
  local close_enqueued: boolean
  local close_failures: integer
  local close_retry_exhausted: boolean
end
]==], [==[
  local previous_file: uv_file?
  local close_enqueued: boolean
  local close_failures: integer
  local close_retry_exhausted: boolean
  -- Variant-only counter; absent from the production opaque record.
  local test_active: integer
end
]==], "per-File active counter")

source = replace_once(source, [==[
local active_runtime: Runtime? = nil
]==], [==[
local active_runtime: Runtime? = nil

-- Variant-only filesystem state. This generated source is never installed.
local test_fs_submissions = 0
local test_fs_cleanups = 0
local test_fs_active = 0
local test_fs_max_file_active = 0
local test_fs_fail_operation: string? = nil
local test_fs_fail_prepare_operation: string? = nil
local test_fs_fail_prepare_skip = 0
local test_fs_close_callback_errors = 0
local test_fs_write_limit = 0
local test_fs_pause_next = false
local test_fs_paused_file: value = nil
local test_fs_paused_operation: value = nil
]==], "filesystem test state")

source = replace_once(source, [==[
  local file = uv_file.new(handle, runtime, runtime.generation, FS.file_open,
      subject, nil, nil, nil, nil, nil, nil, nil, false, 0, false)
]==], [==[
  local file = uv_file.new(handle, runtime, runtime.generation, FS.file_open,
      subject, nil, nil, nil, nil, nil, nil, nil, false, 0, false, 0)
]==], "variant uv_file constructor")

source = replace_once(source, [==[
    -- TITAN_UV_FS_TEST_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    owner.metadata.cleaned = true
]==], [==[
    -- TITAN_UV_FS_TEST_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    test_fs_cleanups = test_fs_cleanups + 1
    owner.metadata.cleaned = true
]==], "ordinary request cleanup counter")

source = replace_once(source, [==[
local function clean_fs_owner(owner: uv_fs_t)
]==], [==[
local function test_fs_zero_request(owner: uv_fs_t)
  test_cstring.memset(owner.handle, 0, libuv.uv_fs_t.sizeof)
end

local function clean_fs_owner(owner: uv_fs_t)
]==], "safe injected-request initialization")

source = replace_once(source, [==[
local function submit_fs_operation(operation: FsOperation):
                                   (uv_fs_t, integer)
]==], [==[
local function test_fs_mark_submitted(operation: FsOperation)
  test_fs_active = test_fs_active + 1
  if operation.file then
    local file = operation.file as uv_file
    file.test_active = file.test_active + 1
    if file.test_active > test_fs_max_file_active then
      test_fs_max_file_active = file.test_active
    end
  end
end

local function test_fs_mark_callback(operation: FsOperation)
  if test_fs_active <= 0 then
    raise "filesystem test active-request counter underflow"
  end
  test_fs_active = test_fs_active - 1
  if operation.file then
    local file = operation.file as uv_file
    if file.test_active <= 0 then
      raise "filesystem test per-File counter underflow"
    end
    file.test_active = file.test_active - 1
  end
end

local function submit_fs_operation(operation: FsOperation):
                                   (uv_fs_t, integer)
]==], "filesystem counter helpers")

source = replace_once(source, [==[
  local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
  -- TITAN_UV_FS_TEST_BEFORE_SUBMIT
  if kind == FS.stat then
]==], [==[
  local status: ffi.titan_ffi_int = 0 as ffi.titan_ffi_int
  -- TITAN_UV_FS_TEST_BEFORE_SUBMIT
  test_fs_submissions = test_fs_submissions + 1
  local injected = false
  local configured: string? = test_fs_fail_operation
  if configured and
      (configured as string) == fs_operation_name(kind) then
    test_fs_fail_operation = nil
    test_fs_zero_request(owner)
    status = shim.titan_uvshim_error_eio()
    injected = true
  end
  if injected then
    -- A synchronous wrapper failure has no callback.
  elseif kind == FS.stat then
]==], "submission counter and synchronous failure")

source = replace_once(source, [==[
    local write_length = bytes.length - operation.write_offset
    -- TITAN_UV_FS_TEST_WRITE_LIMIT
    operation.prepared_buffer =
        make_buffer(bytes, operation.write_offset, write_length,
                    "fs.buffer.init")
]==], [==[
    local write_length = bytes.length - operation.write_offset
    -- TITAN_UV_FS_TEST_WRITE_LIMIT
    if test_fs_write_limit > 0 and write_length > test_fs_write_limit then
      write_length = test_fs_write_limit
    end
    operation.prepared_buffer =
        make_buffer(bytes, operation.write_offset, write_length,
                    "fs.buffer.init")
]==], "partial-write clamp")

source = replace_once(source, [==[
  -- TITAN_UV_FS_TEST_AFTER_PREPARE
  local owner = allocate_fs_owner(runtime, operation)
]==], [==[
  -- TITAN_UV_FS_TEST_AFTER_PREPARE
  local configured_prepare: string? = test_fs_fail_prepare_operation
  if configured_prepare and
      (configured_prepare as string) == fs_operation_name(operation.kind) then
    if test_fs_fail_prepare_skip > 0 then
      test_fs_fail_prepare_skip = test_fs_fail_prepare_skip - 1
    else
      test_fs_fail_prepare_operation = nil
      raise "injected filesystem prepare failure"
    end
  end
  local owner = allocate_fs_owner(runtime, operation)
]==], "pre-submission preparation failure")

source = replace_once(source, [==[
local function fs_dispatch(owner: uv_fs_t, event_kind: integer,
                           result: integer, size: libuv.size_t,
                           pointer: ffi.titan_ffi_void_ptr)
  owner.metadata.callback_result = result
  owner.metadata.callback_recorded = true
]==], [==[
local function fs_dispatch(owner: uv_fs_t, event_kind: integer,
                           result: integer, size: libuv.size_t,
                           pointer: ffi.titan_ffi_void_ptr)
  local callback_operation = owner.metadata.operation
  if test_fs_close_callback_errors > 0 and
      (callback_operation.kind == FS.close or
       callback_operation.kind == FS.internal_close) then
    test_fs_close_callback_errors = test_fs_close_callback_errors - 1
    result = shim.titan_uvshim_error_eio() as integer
  end
  owner.metadata.callback_result = result
  owner.metadata.callback_recorded = true
]==], "persistent close callback failures")

source = replace_once(source, [==[
  if (status as integer) < 0 then
    clean_fs_owner(owner)
  end
  -- TITAN_UV_FS_TEST_AFTER_SUBMIT
  return owner, status as integer
]==], [==[
  if (status as integer) < 0 then
    clean_fs_owner(owner)
  else
    test_fs_mark_submitted(operation)
  end
  -- TITAN_UV_FS_TEST_AFTER_SUBMIT
  return owner, status as integer
]==], "successful submission counter")

source = replace_once(source, [==[
    local operation = file.queue_head as FsOperation
    file.current = operation
    -- TITAN_UV_FS_TEST_PAUSE_BEFORE_ALLOCATION
    local owner, status = submit_fs_operation(operation)
]==], [==[
    local operation = file.queue_head as FsOperation
    file.current = operation
    -- TITAN_UV_FS_TEST_PAUSE_BEFORE_ALLOCATION
    if test_fs_pause_next then
      test_fs_pause_next = false
      test_fs_paused_file = file
      test_fs_paused_operation = operation
      return nil
    end
    local owner, status = submit_fs_operation(operation)
]==], "pre-allocation pause")

source = replace_once(source, [==[
  owner.metadata.lifecycle = FS_OWNER_CALLBACK
  local operation = owner.metadata.operation
]==], [==[
  owner.metadata.lifecycle = FS_OWNER_CALLBACK
  local operation = owner.metadata.operation
  test_fs_mark_callback(operation)
  local configured_dispatch: string? = test_fs_fail_operation
  if configured_dispatch and
      (configured_dispatch as string) ==
          "dispatch:" .. fs_operation_name(operation.kind) then
    test_fs_fail_operation = nil
    raise "injected filesystem dispatcher failure"
  end
]==], "callback active counter")

source = replace_once(source, [==[
    -- TITAN_UV_FS_TEST_CATCH_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    owner.metadata.cleaned = true
]==], [==[
    -- TITAN_UV_FS_TEST_CATCH_CLEANUP
    libuv.uv_fs_req_cleanup(owner.handle)
    test_fs_cleanups = test_fs_cleanups + 1
    owner.metadata.cleaned = true
]==], "dispatcher-catch cleanup counter")

local hook_api = [==[
-- Variant-only filesystem hooks. The generated DSO is isolated and never
-- installed or packed.
function __test_fs_reset_counters()
  if test_fs_active ~= 0 then
    raise "cannot reset filesystem counters with active requests"
  end
  if test_fs_paused_file ~= nil then
    raise "cannot reset filesystem counters with a paused submission"
  end
  test_fs_submissions = 0
  test_fs_cleanups = 0
  test_fs_max_file_active = 0
  test_fs_fail_operation = nil
  test_fs_fail_prepare_operation = nil
  test_fs_fail_prepare_skip = 0
  test_fs_close_callback_errors = 0
  test_fs_write_limit = 0
  test_fs_pause_next = false
end

function __test_fs_submission_count(): integer
  return test_fs_submissions
end

function __test_fs_cleanup_count(): integer
  return test_fs_cleanups
end

function __test_fs_current_active(): integer
  return test_fs_active
end

function __test_fs_max_active_per_file(): integer
  return test_fs_max_file_active
end

function __test_fs_fail_next_submit(operation: string)
  test_fs_fail_operation = operation
end

function __test_fs_fail_next_prepare(operation: string)
  test_fs_fail_prepare_operation = operation
  test_fs_fail_prepare_skip = 0
end

function __test_fs_fail_prepare_after(operation: string,
                                      successful_preparations: integer)
  if successful_preparations < 0 then
    raise "preparation skip count must not be negative"
  end
  test_fs_fail_prepare_operation = operation
  test_fs_fail_prepare_skip = successful_preparations
end

function __test_fs_force_close_callback_errors(count: integer)
  if count < 0 then raise "close callback count must not be negative" end
  test_fs_close_callback_errors = count
end

function __test_fs_close_retry_limit(): integer
  return FS_CLOSE_RETRY_LIMIT
end

function __test_fs_set_max_write_chunk(bytes: integer)
  if bytes < 0 then raise "write chunk limit must not be negative" end
  test_fs_write_limit = bytes
end

function __test_fs_pause_next_file_submission()
  if test_fs_paused_file ~= nil or test_fs_pause_next then
    raise "a filesystem submission pause is already pending"
  end
  test_fs_pause_next = true
end

function __test_fs_resume_file_submissions()
  if test_fs_paused_file == nil or test_fs_paused_operation == nil then
    raise "no filesystem submission is paused"
  end
  local file = test_fs_paused_file as uv_file
  local operation = test_fs_paused_operation as FsOperation
  if file.current ~= operation or not operation.linked then
    raise "paused filesystem operation is no longer current"
  end
  test_fs_paused_file = nil
  test_fs_paused_operation = nil
  file.current = nil
  submit_file_head(file, nil)
end
]==]

source = replace_once(source, [==[
-- TITAN_UV_TEST_HOOKS
]==], hook_api .. [==[
-- TITAN_UV_TEST_HOOKS
]==], "variant hook API")

for _, hook in ipairs({
    "__test_fs_reset_counters",
    "__test_fs_submission_count",
    "__test_fs_cleanup_count",
    "__test_fs_current_active",
    "__test_fs_max_active_per_file",
    "__test_fs_fail_next_submit",
    "__test_fs_fail_next_prepare",
    "__test_fs_fail_prepare_after",
    "__test_fs_force_close_callback_errors",
    "__test_fs_close_retry_limit",
    "__test_fs_set_max_write_chunk",
    "__test_fs_pause_next_file_submission",
    "__test_fs_resume_file_submissions",
}) do
    assert(source:find("function " .. hook, 1, true),
        "filesystem hook was not inserted: " .. hook)
end

write(output_path, source)

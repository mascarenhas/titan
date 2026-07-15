-- Generate an isolated callback-timing uv.titan from the production source.
-- Usage: lua make_delayed_fs_callback_variant.lua INPUT OUTPUT
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
        "missing delayed-FS test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate delayed-FS test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local source = read(input_path)

source = replace_once(source, [==[
local OWNER_TASK_DRIVE = 8
]==], [==[
local OWNER_TASK_DRIVE = 8
-- Variant-only timer that defers logical FS callback delivery after libuv has
-- already returned the native request.
local OWNER_DELAYED_FS_CALLBACK = 100
]==], "delayed FS owner kind")

source = replace_once(source, [==[
local active_runtime: Runtime? = nil
]==], [==[
local active_runtime: Runtime? = nil

-- Variant-only callback controls. This generated source is never installed.
local test_fs_delay = 0
local test_fs_callback_delayed = false
local test_fs_delayed_result = 0
]==], "callback-control state")

source = replace_once(source, [==[
  if result >= 0 and owner.metadata.operation.kind == FS.open then
    owner.metadata.acquired_file = result as libuv.uv_file
  end
  fs_dispatch_body(owner, result)
]==], [==[
  if result >= 0 and owner.metadata.operation.kind == FS.open then
    owner.metadata.acquired_file = result as libuv.uv_file
  end
  if test_fs_delay > 0 then
    local delay = test_fs_delay
    test_fs_delay = 0
    test_fs_callback_delayed = true
    test_fs_delayed_result = result
    local wake, status = start_owner(owner.metadata.runtime,
        OWNER_DELAYED_FS_CALLBACK, nil, owner, 0, delay, 0)
    if status < 0 then
      raise make_error(status, "test.fs.delay", nil)
    end
    return
  end
  fs_dispatch_body(owner, result)
]==], "physical FS callback deferral")

source = replace_once(source, [==[
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task
]==], [==[
  elseif kind == OWNER_DELAYED_FS_CALLBACK then
    local fs_owner = owner.metadata.peer as uv_fs_t
    fs_dispatch(fs_owner, 0, test_fs_delayed_result,
                0 as libuv.size_t, nil)
  elseif kind == OWNER_TASK_DRIVE then
    local task = owner.metadata.task
]==], "delayed FS logical delivery")

local hook_api = [==[

-- Variant-only controls. The generated DSO is isolated and never installed.
function __test_delay_next_fs_callback(milliseconds: integer)
  test_fs_delay = milliseconds
  test_fs_callback_delayed = false
end

function __test_fs_callback_is_delayed(): boolean
  return test_fs_callback_delayed
end
]==]

source = replace_once(source, [==[
do
  UV_EIO = shim.titan_uvshim_error_eio() as integer
]==], hook_api .. [==[

do
  UV_EIO = shim.titan_uvshim_error_eio() as integer
]==], "module initializer")

write(output_path, source)

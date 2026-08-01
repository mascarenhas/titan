-- Generate an isolated callback-timing titan.uv folder from production.
-- Usage: lua make_delayed_fs_callback_variant.lua INPUT_DIR OUTPUT_DIR
local lfs = require "lfs"

local input_dir, output_dir = assert(arg[1]), assert(arg[2])
assert(lfs.attributes(input_dir, "mode") == "directory",
    "delayed-FS input is not a directory: " .. input_dir)
if not lfs.attributes(output_dir, "mode") then
    assert(lfs.mkdir(output_dir), "could not create " .. output_dir)
else
    assert(lfs.attributes(output_dir, "mode") == "directory",
        "delayed-FS output is not a directory: " .. output_dir)
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function replace_once(source, needle, replacement, label)
    local first = assert(source:find(needle, 1, true),
        "missing delayed-FS test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate delayed-FS test-variant anchor: " .. label)
    return source:sub(1, first - 1) .. replacement ..
           source:sub(first + #needle)
end

local sources = {}
local filenames = {}
for entry in lfs.dir(input_dir) do
    local path = input_dir .. "/" .. entry
    if entry:match("%.titan$") and
            lfs.attributes(path, "mode") == "file" then
        sources[entry] = read(path)
        filenames[#filenames + 1] = entry
    end
end
table.sort(filenames)
for _, required in ipairs({ "uv.titan", "file.titan", "task.titan" }) do
    assert(sources[required], "missing delayed-FS source " .. required)
end

local function patch(filename, needle, replacement, label)
    sources[filename] = replace_once(sources[filename], needle, replacement,
        filename .. ": " .. label)
end

local function require_once(filename, needle, label)
    local source = sources[filename]
    local first = assert(source:find(needle, 1, true),
        "missing delayed-FS direct-call contract: " .. filename .. ": " ..
        label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate delayed-FS direct-call contract: " .. filename .. ": " ..
        label)
end

patch("uv.titan", [==[
local OWNER_TASK_DRIVE = 8
]==], [==[
local OWNER_TASK_DRIVE = 8
-- Variant-only timer that defers logical FS callback delivery after libuv has
-- already returned the native request.
local OWNER_DELAYED_FS_CALLBACK = 100
]==], "delayed FS owner kind")

patch("uv.titan", [==[
local active_runtime: Runtime? = nil
]==], [==[
local active_runtime: Runtime? = nil

-- Variant-only callback controls. This generated source is never installed.
local test_fs_delay = 0
local test_fs_callback_delayed = false
local test_fs_delayed_result = 0
]==], "callback-control state")

patch("file.titan", [==[
  if result >= 0 and
      (owner.metadata.operation.kind == FS.open or
       owner.metadata.operation.kind == FS.tmpname) then
    owner.metadata.acquired_file = result as libuv.uv_file
  end
  fs_dispatch_body(owner, result)
]==], [==[
  if result >= 0 and
      (owner.metadata.operation.kind == FS.open or
       owner.metadata.operation.kind == FS.tmpname) then
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

patch("task.titan", [==[
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

patch("uv.titan", [==[
do
  local sigpipe_status =
]==], hook_api .. [==[

do
  local sigpipe_status =
]==], "module initializer")

-- The variant must retain the production source's direct public-libuv
-- ownership boundary. These unique checks fail before generating a stale
-- test-only copy if request publication or cancellation moves contributors.
require_once("file.titan",
    "libuv.uv_req_set_data(\n" ..
    "      request_handle as *libuv.uv_req_t, pointer)",
    "FS owner data installation")
require_once("task.titan",
    "fs_owner.handle as owned *libuv.uv_fs_t\n" ..
    "      libuv.uv_cancel(handle as *libuv.uv_req_t)",
    "submitted FS cancellation")

for _, filename in ipairs(filenames) do
    local output = output_dir .. "/" .. filename
    assert(not lfs.attributes(output), "refusing to overwrite " .. output)
    write(output, sources[filename])
end

-- Generate an isolated titan.uv folder whose next shutdown-owned File close
-- reports a callback failure after the native close has completed.
-- Usage: lua make_exit_cleanup_failure_variant.lua INPUT_DIR OUTPUT_DIR
local lfs = require "lfs"

local input_dir, output_dir = assert(arg[1]), assert(arg[2])
assert(lfs.attributes(input_dir, "mode") == "directory",
    "exit-cleanup input is not a directory: " .. input_dir)
if not lfs.attributes(output_dir, "mode") then
    assert(lfs.mkdir(output_dir), "could not create " .. output_dir)
else
    assert(lfs.attributes(output_dir, "mode") == "directory",
        "exit-cleanup output is not a directory: " .. output_dir)
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
        "missing exit-cleanup test-variant anchor: " .. label)
    assert(not source:find(needle, first + #needle, true),
        "duplicate exit-cleanup test-variant anchor: " .. label)
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
for _, required in ipairs({ "uv.titan", "file.titan" }) do
    assert(sources[required], "missing exit-cleanup source " .. required)
end

local hook = "__test_fail_next_exit_cleanup"
for _, filename in ipairs(filenames) do
    assert(not sources[filename]:find(hook, 1, true),
        "production source already exposes exit-cleanup hook " .. hook ..
        " in " .. filename)
end

local function patch(filename, needle, replacement, label)
    sources[filename] = replace_once(sources[filename], needle, replacement,
        filename .. ": " .. label)
end

patch("file.titan", [==[
function _fs_open(path: string, mode: string): uv_file
]==], [==[
-- Variant-only control. The generated DSO is isolated and never installed.
local test_fail_next_exit_cleanup = false

function __test_fail_next_exit_cleanup()
  test_fail_next_exit_cleanup = true
end

function _fs_open(path: string, mode: string): uv_file
]==], "cleanup-failure control")

patch("file.titan", [==[
  local failure: Error? = nil
  local acquired_path: string? = nil
  if result < 0 then
]==], [==[
  local failure: Error? = nil
  local acquired_path: string? = nil
  if operation.kind == FS.internal_close and
      test_fail_next_exit_cleanup then
    test_fail_next_exit_cleanup = false
    failure = Error.new(
        libuv.UV_EIO as integer,
        "EIO",
        "injected exit cleanup failure",
        "fs.close",
        fs_operation_subject(operation))
  elseif result < 0 then
]==], "shutdown-owned close callback failure")

for _, filename in ipairs(filenames) do
    local output = output_dir .. "/" .. filename
    assert(not lfs.attributes(output), "refusing to overwrite " .. output)
    write(output, sources[filename])
end

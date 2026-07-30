local fs_support = require "spec.support.fs_test_support"

local FS_CASES = [==[
local fs = import "fs"
local timer = import "timer"
local async = import "async"
local tio = import "io"

local retained_file: fs.File? = nil

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function expect_failure(func: () -> value, message: string)
  local failed = false
  do
    func()
  catch
    failed = true
  end
  check(failed, message)
end

local function contains(entries: {string}, wanted: string): boolean
  for i = 1, #entries do
    local entry = entries[i] as string
    if entry == wanted then return true end
  end
  return false
end

function schedule_modes(root: string): async.Task
  return async.run(function (): value
    local path = root .. "/modes.dat"

    local file = fs.open(path, "w")
    check(file:write("abcdef") == 6, "w did not report a full write")
    file:flush()
    file:close()
    file:close()
    check(file:is_closed(), "double close did not leave File closed")
    expect_failure(function (): value
      file:read(1)
      return nil
    end, "read after close succeeded")
    expect_failure(function (): value
      file:write("x")
      return nil
    end, "write after close succeeded")
    expect_failure(function (): value
      file:flush()
      return nil
    end, "flush after close succeeded")

    file = fs.open(path, "r")
    check(file:read(2) == "ab", "r returned the wrong first chunk")
    check(file:read(100) == "cdef", "r did not preserve a short read")
    check(not file:read(1), "read did not return nil at EOF")
    check(not file:read(1), "EOF was not sticky")
    expect_failure(function (): value
      file:read(0)
      return nil
    end, "read(0) succeeded")
    expect_failure(function (): value
      file:read(-1)
      return nil
    end, "negative read succeeded")
    local portable_limit = false
    do
      file:read(4294967296)
    catch
      portable_limit =
        error == "read size exceeds the portable libuv buffer limit"
    end
    check(portable_limit,
          "read larger than UINT_MAX reached allocation or libuv")
    file:close()

    file = fs.open(path, "a")
    check(file:write("GH") == 2, "a did not report a full write")
    file:close()
    check(fs.read_file(path) == "abcdefGH", "a did not append")

    file = fs.open(path, "r+")
    check(file:read(3) == "abc", "r+ read failed")
    check(file:write("XYZ") == 3, "r+ write failed")
    file:close()
    check(fs.read_file(path) == "abcXYZGH", "r+ position was wrong")

    file = fs.open(path, "w+")
    check(file:write("new") == 3, "w+ write failed")
    file:close()
    check(fs.read_file(path) == "new", "w+ did not truncate")

    file = fs.open(path, "a+")
    check(file:write("tail") == 4, "a+ write failed")
    file:close()
    check(fs.read_file(path) == "newtail", "a+ did not append")

    -- The optional b is accepted but does not change Linux/macOS behavior.
    local binary_modes = { "rb", "wb", "ab", "r+b", "w+b", "a+b" }
    for i = 1, #binary_modes do
      local mode = binary_modes[i] as string
      local binary = fs.open(path, mode)
      binary:close()
    end

    local invalid_modes = { "", "x", "rr", "br", "rbb", "r++" }
    for i = 1, #invalid_modes do
      local mode = invalid_modes[i] as string
      expect_failure(function (): value
        local invalid = fs.open(path, mode)
        invalid:close()
        return nil
      end, "invalid mode was accepted: " .. mode)
    end

    expect_failure(function (): value
      fs.open(root .. "/bad\0suffix", "r")
      return nil
    end, "NUL-containing path was accepted")

    return "modes-ok"
  end)
end

function schedule_binary(root: string, payload: string): async.Task
  return async.run(function (): value
    local path = root .. "/binary.dat"
    fs.write_file(path, payload)
    check(fs.read_file(path) == payload,
          "whole-file helper changed binary payload")

    local file = fs.open(path, "rb")
    local rebuilt = ""
    while true do
      local chunk: string? = file:read(4093)
      if not chunk then break end
      rebuilt = rebuilt .. (chunk as string)
    end
    file:close()
    check(rebuilt == payload, "chunked read changed binary payload")

    local empty_path = root .. "/empty.dat"
    fs.write_file(empty_path, "")
    check(fs.read_file(empty_path) == "", "empty file did not round-trip")
    file = fs.open(empty_path, "r")
    check(not file:read(1), "empty file did not report EOF")
    file:close()
    return #payload
  end)
end

function schedule_delimited_reads(root: string, boundary_payload: string,
                                  retained_payload: string,
                                  many_chunks: string): async.Task
  return async.run(function (): value
    local default_path = root .. "/default-read.dat"
    fs.write_file(default_path, "default-payload")
    local file = fs.open(default_path, "r")
    check(file:read() == "default-payload",
          "omitted read size did not use the default")
    check(not file:read(nil), "omitted-size read did not reach EOF")
    file:close()
    file = fs.open(default_path, "r")
    check(file:read(nil) == "default-payload",
          "explicit nil read size did not use the default")
    file:close()

    local retained_path = root .. "/retained-excess.dat"
    fs.write_file(retained_path, "alpha--beta--tail")
    file = fs.open(retained_path, "r")
    check(file:read_until("--") == "alpha--",
          "delimiter read did not include its delimiter")
    check(file:read(2) == "be",
          "plain read exceeded its limit while consuming excess")
    check(file:read_until("--", true) == "ta",
          "chopped delimiter read returned the wrong retained prefix")
    check(file:read() == "tail",
          "plain read did not consume the retained delimiter suffix")
    check(not file:read_until("--"),
          "empty EOF after retained excess did not return nil")
    file:close()

    local binary_path = root .. "/binary-delimiter.dat"
    fs.write_file(binary_path, "\0Dpayload")
    file = fs.open(binary_path, "r")
    check(file:read_until("\0D", true) == "",
          "binary delimiter at the start did not chop to an empty string")
    check(file:read() == "payload",
          "binary delimiter retained the wrong suffix")
    expect_failure(function (): value
      file:read_until("")
      return nil
    end, "empty read delimiter succeeded")
    file:close()

    local boundary_path = root .. "/boundary-delimiter.dat"
    fs.write_file(boundary_path, boundary_payload)
    file = fs.open(boundary_path, "r")
    local boundary_prefix =
      file:read_until("\0Y", true) as string
    check(#boundary_prefix == 65535,
          "delimiter spanning native reads returned the wrong prefix")
    check(file:read() == "tail",
          "delimiter spanning native reads lost retained bytes")
    file:close()

    local short_excess_path = root .. "/short-excess.dat"
    fs.write_file(short_excess_path, retained_payload)
    file = fs.open(short_excess_path, "r")
    local first = file:read_until("END") as string
    check(#first == 65533,
          "near-boundary delimiter returned the wrong included length")
    check(file:read(100) == "xyz",
          "short excess was topped up from a new native read")
    check(file:read(100) == "native-tail",
          "native read after short excess returned the wrong tail")
    file:close()

    local many_path = root .. "/many-chunks.dat"
    fs.write_file(many_path, many_chunks)
    file = fs.open(many_path, "r")
    check(file:read_until("delimiter-that-is-not-present") == many_chunks,
          "unterminated many-chunk read did not return its EOF tail")
    check(not file:read_until("delimiter-that-is-not-present"),
          "empty EOF after many chunks did not return nil")
    file:close()

    local growth_path = root .. "/growth-after-eof.dat"
    fs.write_file(growth_path, "old")
    file = fs.open(growth_path, "r")
    check(file:read_until("|") == "old",
          "unterminated initial tail was not returned")
    check(not file:read(), "initial EOF did not return nil")
    local appender = fs.open(growth_path, "a")
    appender:write("new|tail")
    appender:close()
    check(file:read_until("|") == "new|",
          "File EOF became sticky after later growth")
    check(file:read() == "tail",
          "growth delimiter read lost its retained suffix")
    file:close()

    local interface_path = root .. "/interface.dat"
    fs.write_file(interface_path, "interface-data|rest")
    file = fs.open(interface_path, "r+")
    local stream: tio.ReaderWriterCloser = file
    check(stream:read_until("|", true) == "interface-data",
          "File interface delimiter dispatch failed")
    stream:write("X")
    check(stream:read() == "rest",
          "File interface nil-fill read adapter failed")
    stream:close()
    check(fs.read_file(interface_path) == "interface-data|restX",
          "File interface result-discard write adapter failed")

    local fifo_path = root .. "/read-until-fifo.dat"
    fs.write_file(fifo_path, many_chunks)
    file = fs.open(fifo_path, "r+")
    local reader = async.run(function (): value
      return file:read_until("|")
    end)
    local writer = async.run(function (): value
      return file:write("|later")
    end)
    while reader:status() == "ready" or writer:status() == "ready" do
      timer.yield()
    end
    check(reader:join() == many_chunks,
          "queued write interleaved between delimiter-read submissions")
    check((writer:join() as integer) == 6,
          "write queued behind delimiter read failed")
    file:close()

    local readers_path = root .. "/concurrent-readers.dat"
    fs.write_file(readers_path, "abcd")
    file = fs.open(readers_path, "r")
    local first_reader = async.run(function (): value
      return file:read(2)
    end)
    local second_reader = async.run(function (): value
      return file:read(2)
    end)
    check(first_reader:join() == "ab" and second_reader:join() == "cd",
          "concurrent File readers did not follow FIFO order")
    file:close()
    return "delimited-reads-ok"
  end)
end

function schedule_paths(root: string): async.Task
  return async.run(function (): value
    local dir = root .. "/tree"
    local sub = dir .. "/sub"
    local first = dir .. "/first.bin"
    local renamed = dir .. "/renamed.bin"

    fs.mkdir(dir)
    fs.mkdir(sub)
    fs.write_file(first, "abc\0def")

    local file_stat = fs.stat(first)
    check(file_stat.size == 7, "stat returned the wrong file size")
    check(file_stat.kind == "file", "stat did not classify a regular file")
    check(file_stat.mode >= 0, "stat returned a negative mode")
    check(file_stat.modified_nanoseconds >= 0 and
          file_stat.modified_nanoseconds < 1000000000,
          "stat returned invalid modification nanoseconds")

    local dir_stat = fs.stat(sub)
    check(dir_stat.kind == "directory",
          "stat did not classify a directory")

    local entries = fs.list(dir)
    check(#entries == 2 and contains(entries, "first.bin") and
          contains(entries, "sub"), "list returned the wrong entries")
    for i = 1, #entries do
      local entry = entries[i] as string
      check(entry ~= "." and entry ~= "..", "list exposed dot entries")
    end

    fs.rename(first, renamed)
    check(fs.read_file(renamed) == "abc\0def", "rename lost file data")
    expect_failure(function (): value
      fs.stat(first)
      return nil
    end, "renamed source still exists")
    expect_failure(function (): value
      fs.rmdir(dir)
      return nil
    end, "rmdir removed a non-empty directory")
    expect_failure(function (): value
      fs.unlink(sub)
      return nil
    end, "unlink removed a directory")

    fs.unlink(renamed)
    fs.rmdir(sub)
    check(#fs.list(dir) == 0, "path cleanup left directory entries")
    fs.rmdir(dir)

    expect_failure(function (): value
      fs.stat(root .. "/missing")
      return nil
    end, "stat accepted a missing path")
    expect_failure(function (): value
      fs.list(root .. "/missing")
      return nil
    end, "list accepted a missing path")
    return "paths-ok"
  end)
end

function schedule_symlink_stat(target: string, link: string): async.Task
  return async.run(function (): value
    local result = fs.stat(link)
    check(result.kind == "file",
          "stat did not follow a symlink to its regular-file target")
    check(result.size == 6, "stat returned the wrong symlink-target size")
    fs.unlink(link)
    fs.unlink(target)
    return "symlink-stat-ok"
  end)
end

function schedule_permission_error(path: string): async.Task
  return async.run(function (): value
    expect_failure(function (): value
      fs.stat(path)
      return nil
    end, "stat accepted a path below an inaccessible directory")
    return "permission-error-ok"
  end)
end

function schedule_fifo_and_close(root: string): async.Task
  return async.run(function (): value
    local path = root .. "/fifo.dat"
    local file = fs.open(path, "w")
    local first = async.run(function (): value
      return file:write("first")
    end)
    local second = async.run(function (): value
      return file:write("-second")
    end)
    local third = async.run(function (): value
      return file:write("-third")
    end)

    -- Wait until every writer has had a start turn and is either active or
    -- queued on the File. The per-File pump must never submit two together.
    while first:status() == "ready" or second:status() == "ready" or
        third:status() == "ready" do
      timer.yield()
    end

    local closer = async.run(function (): value
      file:close()
      return nil
    end)
    while closer:status() == "ready" do timer.yield() end

    local late = async.run(function (): value
      do
        file:write("-late")
      catch
        return "rejected"
      end
      return "accepted"
    end)

    check((first:join() as integer) == 5, "first FIFO write failed")
    check((second:join() as integer) == 7, "second FIFO write failed")
    check((third:join() as integer) == 6, "third FIFO write failed")
    closer:join()
    check(late:join() == "rejected", "operation after close was accepted")
    file:close()
    check(file:is_closed(), "FIFO File did not close")
    check(fs.read_file(path) == "first-second-third",
          "File operations did not run in FIFO order")
    return "fifo-close-ok"
  end)
end

function schedule_retained_file(root: string): async.Task
  return async.run(function (): value
    retained_file = fs.open(root .. "/retained.dat", "w")
    local file = retained_file as fs.File
    file:write("retained")
    timer.sleep(5)
    file:close()
    retained_file = nil
    return nil
  end)
end

function retained(): value
  return retained_file
end

function schedule_leaked_file(root: string): async.Task
  return async.run(function (): value
    local file = fs.open(root .. "/leaked.dat", "w")
    file:write("session-one")
    return file
  end)
end

function schedule_second_session(root: string): async.Task
  return async.run(function (): value
    fs.write_file(root .. "/session-two.dat", "session-two")
    return fs.read_file(root .. "/session-two.dat")
  end)
end

function schedule_stale_file(file: fs.File): async.Task
  return async.run(function (): value
    local failures = 0
    do file:read(1) catch
      check(error == "File belongs to a stale libuv Runtime",
            "stale File read reported the wrong error")
      failures = failures + 1
    end
    do file:write("stale") catch
      check(error == "File belongs to a stale libuv Runtime",
            "stale File write reported the wrong error")
      failures = failures + 1
    end
    do file:flush() catch
      check(error == "File belongs to a stale libuv Runtime",
            "stale File flush reported the wrong error")
      failures = failures + 1
    end
    check(failures == 3, "old-generation File accepted an operation")
    return "stale-file-rejected"
  end)
end
]==]

describe("fs runtime", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.workspace("runtime")
        fs_support.write_source(workspace, "fs_cases", FS_CASES)
        fs_support.compile(workspace, "fs_cases")
    end)

    teardown(function()
        fs_support.cleanup(workspace)
    end)

    local function run_lua(source)
        local ok, status, output = fs_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("covers modes, binary/NUL data, EOF/short reads, stat symlinks, " ..
       "permission errors, and paths",
    function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local async = require "titan.async"
local fs = require "titan.fs"
local cases = require "fs_cases"

assert(type(fs) == "userdata")

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function shell_success(command)
    local ok, _, status = os.execute(command)
    return ok == true or status == 0
end

local function chmod(path, mode)
    assert(shell_success("chmod " .. mode .. " " .. shell_quote(path)),
        "could not chmod filesystem test directory")
end

local unit = "A\0B\255tail"
local payload = unit:rep(32769)
local symlink_target = root .. "/stat-target.dat"
local symlink_path = root .. "/stat-link.dat"
local target = assert(io.open(symlink_target, "wb"))
assert(target:write("target"))
assert(target:close())
assert(shell_success("ln -s " .. shell_quote(symlink_target) .. " " ..
    shell_quote(symlink_path)), "could not create test symlink")
local blocked_dir = root .. "/permission-denied"
local blocked_path = blocked_dir .. "/target.dat"
assert(shell_success("mkdir " .. shell_quote(blocked_dir)))
local blocked = assert(io.open(blocked_path, "wb"))
assert(blocked:write("blocked"))
assert(blocked:close())
chmod(blocked_dir, "000")
local permission_is_enforced = not shell_success(
    "test -e " .. shell_quote(blocked_path))
local modes = cases.schedule_modes(root)
local binary = cases.schedule_binary(root, payload)
local paths = cases.schedule_paths(root)
local symlink = cases.schedule_symlink_stat(symlink_target, symlink_path)
local permission = permission_is_enforced and
    cases.schedule_permission_error(blocked_path) or nil
local loop_ok, loop_error = pcall(async.loop)
chmod(blocked_dir, "700")
assert(loop_ok, loop_error)
assert(modes:join() == "modes-ok")
assert(binary:join() == #payload)
assert(paths:join() == "paths-ok")
assert(symlink:join() == "symlink-stat-ok")
if permission then assert(permission:join() == "permission-error-ok") end
]==])
    end)

    it("supports default and delimiter reads, retained excess, growth, " ..
       "interfaces, and one logical FIFO operation",
    function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local async = require "titan.async"
local cases = require "fs_cases"

local boundary = string.rep("x", 65535) .. "\0Ytail"
local retained = string.rep("p", 65530) .. "ENDxyznative-tail"
local many = string.rep("z", 5 * 65536 + 17)
local task = cases.schedule_delimited_reads(
    root, boundary, retained, many)
async.loop()
assert(task:join() == "delimited-reads-ok")
]==])
    end)

    it("serializes each File FIFO and makes close immediate and idempotent",
    function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local cases = require "fs_cases"
local async = require "titan.async"
local task = cases.schedule_fifo_and_close(root)
async.loop()
assert(task:join() == "fifo-close-ok")
]==])
    end)

    it("roots pending files, releases closed owners, and resets sessions",
    function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local cases = require "fs_cases"
local async = require "titan.async"
local timer = require "titan.timer"

collectgarbage("collect")
collectgarbage("generational")
local weak = setmetatable({}, { __mode = "v" })
local holder = cases.schedule_retained_file(root)
local observer = async.run(function()
    while cases.retained() == nil do timer.yield() end
    weak.file = cases.retained()
    collectgarbage("collect")
    assert(weak.file ~= nil, "pending File was not rooted")
    return true
end)
async.loop()
assert(holder:join() == nil)
assert(observer:join())
holder, observer = nil, nil
for _ = 1, 4 do collectgarbage("collect") end
assert(weak.file == nil, "closed File was retained after session cleanup")

local leaked_task = cases.schedule_leaked_file(root)
async.loop()
local old_file = leaked_task:join()
assert(old_file:is_closed(), "final-Task cleanup did not close idle File")
old_file:close()

local stale = cases.schedule_stale_file(old_file)
local second = cases.schedule_second_session(root)
async.loop()
assert(stale:join() == "stale-file-rejected")
assert(second:join() == "session-two")
]==])
    end)
end)

local fs_support = require "spec.support.fs_test_support"
local lfs = require "lfs"

local FS_CASES = [==[
local async = import "async"
local fs = import "fs"
local stream = import "io"
local timer = import "timer"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function contains(entries: {string}, wanted: string): boolean
  for index = 1, #entries do
    if entries[index] as string == wanted then return true end
  end
  return false
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

local function active(task: async.Task): boolean
  return not task:status():has_finished()
end

function result(): string
  return outcome
end

function start_io(root: string, boundary: string): async.Task
  outcome = "running"
  return async.run(function (): value
    local binary_path = root .. "/binary.dat"
    fs.write_file(binary_path, boundary)
    check(fs.read_file(binary_path) == boundary,
          "whole-file helpers changed binary data")

    local file = fs.open(binary_path, "rb")
    expect_failure(function (): value
      file:read_until("")
      return nil
    end, "File accepted an empty delimiter")
    local selected: string? = file:read_until("\0Y", true)
    check(selected ~= nil and #(selected as string) == 65535,
          "delimiter spanning native reads returned the wrong prefix")
    check(file:read() == "tail",
          "delimiter read lost retained excess")
    check(not file:read(1) and not file:read_until("missing"),
          "repeated File reads did not return EOF")
    file:close()
    file:close()
    check(file:is_closed(), "File close was not idempotent")
    check(not file:read() and not file:read_until("missing"),
          "closed File did not behave as Reader EOF")
    expect_failure(function (): value
      file:write("late")
      return nil
    end, "closed File accepted a write")
    expect_failure(function (): value
      file:flush()
      return nil
    end, "closed File accepted a flush")

    local modes_path = root .. "/modes.dat"
    file = fs.open(modes_path, "w")
    check(file:write("abc") == 3, "write returned the wrong length")
    file:flush()
    file:close()
    file = fs.open(modes_path, "a")
    check(file:write("d") == 1, "append returned the wrong length")
    file:close()
    check(fs.read_file(modes_path) == "abcd", "append changed file data")

    file = fs.open(modes_path, "r+")
    check(file:read(2) == "ab", "read/update mode returned wrong bytes")
    check(file:write("XY") == 2, "read/update write failed")
    file:flush()
    file:close()
    check(fs.read_file(modes_path) == "abXY",
          "read/update mode used the wrong file position")

    local valid_modes = {
      "r", "rb", "r+", "r+b", "rb+", "a", "ab", "a+", "a+b", "ab+"
    }
    for index = 1, #valid_modes do
      local opened = fs.open(modes_path, valid_modes[index] as string)
      opened:close()
    end
    local truncating_modes = {"w", "wb", "w+", "w+b", "wb+"}
    for index = 1, #truncating_modes do
      local opened = fs.open(modes_path, truncating_modes[index] as string)
      opened:close()
    end

    local invalid_modes = {"", "x", "rr", "br", "r++"}
    for index = 1, #invalid_modes do
      local mode = invalid_modes[index] as string
      expect_failure(function (): value
        fs.open(modes_path, mode)
        return nil
      end, "invalid mode was accepted")
    end
    expect_failure(function (): value
      fs.open(root .. "/bad\0path", "r")
      return nil
    end, "embedded-NUL path was accepted")

    file = fs.open(binary_path, "r")
    expect_failure(function (): value
      file:read(0)
      return nil
    end, "zero-sized read was accepted")
    file:close()

    local interface_path = root .. "/interface.dat"
    fs.write_file(interface_path, "line\nrest")
    file = fs.open(interface_path, "r+")
    local concrete: stream.ReaderWriterCloser = file
    check(concrete:read_until("\n", true) == "line",
          "ReaderWriterCloser delimiter dispatch failed")
    concrete:write("X")
    check(concrete:read() == "rest",
          "ReaderWriterCloser retained read failed")
    concrete:close()
    check(fs.read_file(interface_path) == "line\nrestX",
          "ReaderWriterCloser write changed position")

    fs.unlink(binary_path)
    fs.unlink(modes_path)
    fs.unlink(interface_path)
    outcome = "io-ok"
    return nil
  end)
end

function start_paths(root: string, target: string,
                     link: string): async.Task
  outcome = "running"
  return async.run(function (): value
    local tree = root .. "/tree"
    local sub = tree .. "/sub"
    local first = tree .. "/first.dat"
    local renamed = tree .. "/renamed.dat"
    local cwd = root .. "/cwd"

    fs.mkdir(tree)
    fs.mkdir(sub)
    fs.mkdir(cwd)
    fs.write_file(cwd .. "/marker", "cwd")
    fs.write_file(first, "abc\0def")

    local info = fs.stat(first)
    check(info.kind == "file" and info.size == 7,
          "stat returned wrong regular-file metadata")
    check(info.mode >= 0 and info.modified_nanoseconds >= 0 and
          info.modified_nanoseconds < 1000000000,
          "stat returned invalid portable metadata")
    check(fs.stat(sub).kind == "directory",
          "stat did not classify a directory")
    check(fs.stat(link).kind == "file",
          "stat did not follow a symbolic link")
    check(fs.lstat(link).kind == "symlink",
          "lstat did not classify the symbolic link")

    local entries = fs.list(tree)
    check(#entries == 2 and contains(entries, "first.dat") and
          contains(entries, "sub"), "list returned wrong entries")
    check(not contains(entries, ".") and not contains(entries, ".."),
          "list exposed dot entries")

    fs.rename(first, renamed)
    check(fs.read_file(renamed) == "abc\0def", "rename lost file data")
    expect_failure(function (): value
      fs.rmdir(tree)
      return nil
    end, "rmdir removed a nonempty directory")
    expect_failure(function (): value
      fs.unlink(sub)
      return nil
    end, "unlink removed a directory")

    local missing_error = false
    do
      fs.stat(root .. "/missing")
    catch
      local failure = error as async.OperationError
      check(failure.operation == "fs.stat",
            "missing stat reported the wrong operation")
      missing_error = true
    end
    check(missing_error, "stat accepted a missing path")
    expect_failure(function (): value
      fs.list(root .. "/missing")
      return nil
    end, "list accepted a missing path")

    check(fs.tmpdir() == root and fs.homedir() == root,
          "portable directory helpers returned wrong paths")
    local temporary = fs.tmpname()
    check(fs.lstat(temporary).kind == "file",
          "tmpname did not leave a closed regular file")
    fs.unlink(temporary)

    local original = fs.pwd()
    do
      defer fs.chdir(original)
      fs.chdir(cwd)
      local changed = fs.pwd()
      check(changed ~= original and fs.read_file("marker") == "cwd",
            "chdir did not select the requested directory")
      check(fs.read_file(changed .. "/marker") == "cwd",
            "pwd did not identify the current directory")
    end
    check(fs.pwd() == original, "chdir did not restore pwd")

    fs.unlink(link)
    fs.unlink(target)
    fs.unlink(renamed)
    fs.unlink(cwd .. "/marker")
    fs.rmdir(sub)
    fs.rmdir(tree)
    fs.rmdir(cwd)
    outcome = "paths-ok"
    return nil
  end)
end

function start_parallel(root: string): async.Task
  outcome = "running"
  return async.run(function (): value
    local first_path = root .. "/parallel-first.dat"
    local second_path = root .. "/parallel-second.dat"
    local first = async.run(function (): value
      fs.write_file(first_path, "first")
      return nil
    end)
    local second = async.run(function (): value
      fs.write_file(second_path, "second")
      return nil
    end)

    while active(first) or active(second) do timer.yield() end
    check(first:status():as_string() == "succeeded" and
          second:status():as_string() == "succeeded",
          "independent filesystem Tasks did not succeed")
    check(fs.read_file(first_path) == "first" and
          fs.read_file(second_path) == "second",
          "independent filesystem results changed")
    fs.unlink(first_path)
    fs.unlink(second_path)
    outcome = "parallel-ok"
    return nil
  end)
end
]==]

describe("fs standard library", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.workspace("direct-runtime")
        fs_support.write_source(workspace, "fs_cases", FS_CASES)
        fs_support.compile(workspace, "fs_cases")
    end)

    teardown(function()
        fs_support.cleanup(workspace)
    end)

    local function run(source, options)
        local ok, status, output =
            fs_support.run_lua_source(workspace, source, options)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    local function task_prelude(function_name, arguments, expected)
        return ([==[
local async = require "titan.async"
local cases = require "fs_cases"
local task = assert(cases.%s(%s))
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, arguments, expected)
    end

    it("covers binary I/O, delimiters, modes, interfaces, and close", function()
        local source = "local root = " .. string.format("%q", root) ..
            "\nlocal boundary = string.rep(\"x\", 65535) .. \"\\0Ytail\"\n" ..
            task_prelude("start_io", "root, boundary", "io-ok")
        run(source)
    end)

    it("covers metadata, path operations, locations, tmpname, and errors",
    function()
        local aliased_root = workspace .. "/data-alias"
        assert.truthy(lfs.link(root, aliased_root, true))
        local target = aliased_root .. "/target.dat"
        local link = aliased_root .. "/target-link"
        local source = table.concat({
            "local root = " .. string.format("%q", aliased_root),
            "local target = root .. '/target.dat'",
            "local link = root .. '/target-link'",
            "local lfs = require 'lfs'",
            "local file = assert(io.open(target, 'wb'))",
            "assert(file:write('target'))",
            "assert(file:close())",
            "assert(lfs.link(target, link, true))",
            task_prelude(
                "start_paths", "root, target, link", "paths-ok"),
        }, "\n")
        run(source, {
            exec_prefix = {
                "HOME=" .. aliased_root,
                "TMPDIR=" .. aliased_root,
            },
        })
    end)

    it("runs independent filesystem continuations",
    function()
        local source = "local root = " .. string.format("%q", root) ..
            "\n" .. task_prelude(
                "start_parallel", "root", "parallel-ok")
        run(source)
    end)
end)

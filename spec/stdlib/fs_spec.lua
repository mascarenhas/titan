local fs_support = require "spec.support.fs_test_support"
local async_stdlib = require "spec.support.async_stdlib"
local lfs = require "lfs"

local FS_CASES = [==[
local fs = import "fs"
local timer = import "timer"
local async = import "async"
local tio = import "io"
local system = import "os"

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
    check(not file:read(1), "read after close did not return EOF")
    check(not file:read_until("never"),
          "delimiter read after close did not return EOF")
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
    local read_chunk = function (): string?
      return file:read(4093)
    end
    for chunk in read_chunk do
      rebuilt = rebuilt .. chunk
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
    local excess_limit = false
    do
      file:read(4294967296)
    catch
      excess_limit =
        error == "read size exceeds the portable libuv buffer limit"
    end
    check(excess_limit,
          "retained excess bypassed the portable read-size limit")
    check(file:read(2) == "be",
          "failed oversized read changed retained excess")
    check(file:read_until("--", true) == "ta",
          "chopped delimiter read returned the wrong retained prefix")
    check(file:read() == "tail",
          "plain read did not consume the retained delimiter suffix")
    check(not file:read_until("--"),
          "empty EOF after retained excess did not return nil")
    file:close()

    local cancelled_path = root .. "/cancelled-builder.dat"
    fs.write_file(cancelled_path, "selected|restored-after-cancel")
    file = fs.open(cancelled_path, "r")
    check(file:read_until("|") == "selected|",
          "could not seed cancellation-test excess")
    local cancelled_reader = async.run(function (): value
      return file:read_until("delimiter-that-is-not-present")
    end)
    -- The excess-only File read and its non-yielding append are synchronous.
    -- The next native read waits at EOF; cancellation there must restore the
    -- chunk already accumulated in the builder.
    while cancelled_reader:status() == "ready" do timer.yield() end
    check(cancelled_reader:status() == "waiting",
          "delimiter reader did not reach its next native read")
    cancelled_reader:cancel("cancel-delimiter-read")
    local cancelled = false
    do
      cancelled_reader:join()
    catch
      local failure = error as async.Cancelled
      check(failure.reason == "cancel-delimiter-read",
            "delimiter-read cancellation reason changed")
      cancelled = true
    end
    check(cancelled, "delimiter-read cancellation did not win")
    check(file:read() == "restored-after-cancel",
          "delimiter-read cancellation did not restore consumed excess")
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

    local closed_excess_path = root .. "/closed-excess.dat"
    fs.write_file(closed_excess_path, "selected|retained")
    file = fs.open(closed_excess_path, "r")
    check(file:read_until("|") == "selected|",
          "could not seed excess before close")
    file:close()
    check(not file:read(), "closed File served retained excess")
    check(not file:read_until("retained"),
          "closed File delimiter read served retained excess")

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

    local close_race_path = root .. "/close-read-until-race.dat"
    fs.write_file(close_race_path, many_chunks)
    file = fs.open(close_race_path, "r")
    local delimiter_reader = async.run(function (): value
      local interrupted = false
      do
        file:read_until("delimiter-that-is-not-present")
      catch
        check(error == "cannot read from a closing File",
              "read_until interrupted by close reported the wrong error")
        interrupted = true
      end
      check(interrupted, "close did not interrupt a delimiter read")

      local excess_rejected = false
      do
        file:read()
      catch
        check(error == "cannot read from a closing File",
              "retained excess reported the wrong closing error")
        excess_rejected = true
      end
      check(excess_rejected,
            "retained excess bypassed the closing File state")
      return "delimiter-close-rejected"
    end)
    while delimiter_reader:status() == "ready" do timer.yield() end
    check(delimiter_reader:status() == "waiting",
          "delimiter reader did not submit its first File read")
    local delimiter_closer = async.run(function (): value
      file:close()
      return "delimiter-close-complete"
    end)
    while delimiter_closer:status() == "ready" do timer.yield() end
    check(delimiter_reader:join() == "delimiter-close-rejected",
          "delimiter reader did not observe logical close")
    check(delimiter_closer:join() == "delimiter-close-complete",
          "delimiter close did not complete")
    check(file:is_closed(), "delimiter-race File did not physically close")
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
    local link_result = fs.lstat(link)
    check(link_result.kind == "symlink",
          "lstat did not report the symbolic link itself")
    fs.unlink(link)
    fs.unlink(target)
    return "symlink-stat-lstat-ok"
  end)
end

local function restore_environment(name: string, original: string?)
  if original then
    system.setenv(name, original as string)
  else
    system.unsetenv(name)
  end
end

function exercise_working_directory(alternate: string): string
  local original = fs.pwd()
  do
    fs.chdir(alternate)
    check(fs.pwd() == alternate,
          "synchronous pwd did not observe fs.chdir")
  finally
    fs.chdir(original)
  end
  check(fs.pwd() == original,
        "synchronous fs.chdir did not restore the original directory")
  return "working-directory-ok"
end

function schedule_path_helpers(root: string): async.Task
  return async.run(function (): value
    local original_cwd = fs.pwd()
    local alternate = root .. "/cwd"
    local temp = root .. "/tmp"
    fs.mkdir(alternate)
    fs.mkdir(temp)

    do
      fs.chdir(alternate)
      check(fs.pwd() == alternate,
            "pwd did not observe fs.chdir")
    finally
      fs.chdir(original_cwd)
    end
    check(fs.pwd() == original_cwd,
          "fs.chdir did not restore the original directory")

    local original_tmp: string? = system.getenv("TMPDIR")
    do
      system.setenv("TMPDIR", temp)
      local first = fs.tmpname()
      local second = fs.tmpname()
      check(first ~= second, "tmpname returned a duplicate path")
      check(fs.lstat(first).kind == "file" and
            fs.lstat(second).kind == "file",
            "tmpname did not leave regular files in place")
      fs.unlink(first)
      fs.unlink(second)
    finally
      restore_environment("TMPDIR", original_tmp)
    end

    local lstat_failed = false
    do
      fs.lstat(root .. "/missing-lstat")
    catch
      local failure = error as async.Error
      check(failure.operation == "fs.lstat",
            "missing lstat reported the wrong operation")
      lstat_failed = true
    end
    check(lstat_failed, "lstat accepted a missing path")

    local chdir_failed = false
    do
      fs.chdir(root .. "/missing-chdir")
    catch
      local failure = error as async.Error
      check(failure.operation == "fs.chdir",
            "missing chdir reported the wrong operation")
      chdir_failed = true
    end
    check(chdir_failed, "chdir accepted a missing path")

    local nul_failed = false
    do
      fs.chdir(root .. "\0suffix")
    catch
      local failure = error as async.Error
      check(failure.operation == "fs.chdir",
            "NUL chdir reported the wrong operation")
      nul_failed = true
    end
    check(nul_failed, "chdir accepted an embedded NUL")

    local tmp_failed = false
    original_tmp = system.getenv("TMPDIR")
    do
      system.setenv("TMPDIR", root .. "/missing-tmpdir")
      do
        fs.tmpname()
      catch
        local failure = error as async.Error
        check(failure.operation == "fs.tmpname",
              "failed tmpname reported the wrong operation")
        tmp_failed = true
      end
    finally
      restore_environment("TMPDIR", original_tmp)
    end
    check(tmp_failed, "tmpname accepted a missing temporary directory")

    fs.rmdir(temp)
    fs.rmdir(alternate)
    return "path-helpers-ok"
  end)
end

function schedule_cancelled_tmpnames(temp: string,
                                     count: integer): async.Task
  return async.run(function (): value
    local original_tmp: string? = system.getenv("TMPDIR")
    local cancelled = 0
    do
      system.setenv("TMPDIR", temp)
      local tasks: {async.Task} = {}
      for i = 1, count do
        tasks[i] = async.run(function (): value
          return fs.tmpname()
        end)
      end

      -- The child zero timers run first and submit mkstemp requests. The
      -- parent then cancels them before the filesystem callbacks are driven.
      timer.yield()
      for i = 1, count do
        local task = tasks[i] as async.Task
        task:cancel("tmpname-cancel")
      end
      for i = 1, count do
        local task = tasks[i] as async.Task
        do
          local path = task:join() as string
          -- A request that completed before cancellation still returns its
          -- closed, caller-owned file and must not perturb the leak check.
          fs.unlink(path)
        catch
          local failure = error as async.Cancelled
          check(failure.reason == "tmpname-cancel",
                "tmpname cancellation reason changed")
          cancelled = cancelled + 1
        end
      end
    finally
      restore_environment("TMPDIR", original_tmp)
    end
    check(cancelled > 0,
          "tmpname cancellation did not reach an in-flight request")
    return cancelled
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
    check(not file:read_until(""),
          "closed File validated a delimiter instead of returning EOF")
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
    check(not file:read(1),
          "terminal stale File read did not return EOF")
    check(not file:read_until("never"),
          "terminal stale File delimiter read did not return EOF")
    local failures = 0
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
    check(failures == 2,
          "old-generation File accepted a mutating operation")
    return "stale-file-rejected"
  end)
end
]==]

local LATE_TMPNAME_CASES = [==[
-- Runs only against the generated delayed-filesystem-callback uv variant.
local uv = import "uv"

local result_delivered = false

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

function schedule_cancelled_successful_tmpname(): uv.Task
  result_delivered = false
  uv.__test_delay_next_fs_callback(40)

  local target = uv._run(function (): value
    local path = uv._fs_tmpname()
    result_delivered = true
    return path
  end)
  local canceller = uv._run(function (): value
    while not uv.__test_fs_callback_is_delayed() do uv._yield() end
    -- The native mkstemp callback has succeeded and created the path, but the
    -- variant has not yet delivered that result to the waiting Task.
    target:cancel("late-successful-tmpname-cancel")
    return nil
  end)

  return uv._run(function (): value
    canceller:join()
    local caught = false
    do
      target:join()
    catch
      local cancelled = error as uv.Cancelled
      check(cancelled.reason == "late-successful-tmpname-cancel",
            "late successful-tmpname cancellation reason changed")
      caught = true
    end
    check(caught and target:status() == "cancelled",
          "late successful-tmpname cancellation did not win logically")

    -- Keep the Runtime alive until delayed delivery has queued and completed
    -- the acquired descriptor's internal close.
    uv._sleep(60)
    check(not result_delivered,
          "cancelled successful tmpname published its path")
    return "late-successful-tmpname-cancellation-ok"
  end)
end

function loop()
  uv._loop()
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
assert(symlink:join() == "symlink-stat-lstat-ok")
if permission then assert(permission:join() == "permission-error-ok") end
]==])
    end)

    it("supports lstat, closed persistent tmpnames, pwd/chdir, and fs errors",
    function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local async = require "titan.async"
local lfs = require "lfs"
local cases = require "fs_cases"

local synchronous = root .. "/synchronous-cwd"
assert(lfs.mkdir(synchronous))
assert(cases.exercise_working_directory(synchronous) ==
    "working-directory-ok")
assert(lfs.rmdir(synchronous))

local task = cases.schedule_path_helpers(root)
async.loop()
assert(task:join() == "path-helpers-ok")
]==])
    end)

    it("closes descriptors acquired by cancelled tmpname requests", function()
        run_lua("local root = " .. string.format("%q", root) .. [==[
local lfs = require "lfs"
local async = require "titan.async"
local cases = require "fs_cases"

local temp = root .. "/cancelled-tmpnames"
assert(lfs.mkdir(temp))

-- Warm one complete Runtime session before taking the descriptor baseline so
-- lazy libuv/module initialization cannot masquerade as an fs descriptor.
local warm = async.run(function() return "warm" end)
async.loop()
assert(warm:join() == "warm")

local function descriptor_count()
    local count = 0
    for entry in lfs.dir("/dev/fd") do
        if entry ~= "." and entry ~= ".." then count = count + 1 end
    end
    return count
end

local before = descriptor_count()
local task = cases.schedule_cancelled_tmpnames(temp, 64)
async.loop()
assert(task:join() > 0)
local after = descriptor_count()
assert(after == before,
    string.format("cancelled tmpname leaked descriptors: %d -> %d",
        before, after))

-- Successfully-created requests whose logical Tasks were cancelled retain
-- their paths by contract; remove those test-owned files after the FD proof.
for entry in lfs.dir(temp) do
    if entry ~= "." and entry ~= ".." then
        assert(os.remove(temp .. "/" .. entry))
    end
end
assert(lfs.rmdir(temp))
]==])
    end)

    it("supports default and delimiter reads, retained excess, growth, " ..
       "interfaces, and concurrent reads",
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
assert(old_file:read() == nil,
    "terminal File read required an active Runtime")
assert(old_file:read_until("never") == nil,
    "terminal File delimiter read required an active Runtime")

local stale = cases.schedule_stale_file(old_file)
local second = cases.schedule_second_session(root)
async.loop()
assert(stale:join() == "stale-file-rejected")
assert(second:join() == "session-two")
]==])
    end)
end)

describe("fs portable location helpers", function()
    local workspace
    local root

    setup(function()
        workspace, root = fs_support.workspace("portable-locations")
        async_stdlib.write_source(
            workspace, "titan.fs", async_stdlib.read("titan/fs.titan"))
        fs_support.compile(workspace, "titan.fs")
    end)

    teardown(function()
        fs_support.cleanup(workspace)
    end)

    it("exposes libuv home and temporary directories without a Task",
    function()
        local source = "local expected = " .. string.format("%q", root) ..
            [==[
local fs = require "titan.fs"
local system = require "titan.os"

assert(type(fs) == "userdata")
assert(fs.tmpdir() == expected)
assert(fs.homedir() == expected)
assert(fs.tmpdir() == system.tmpdir())
assert(fs.homedir() == system.homedir())
]==]
        local ok, status, output = fs_support.run_lua_source(
            workspace, source, {
                exec_prefix = {
                    "HOME=" .. root,
                    "TMPDIR=" .. root,
                },
            })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("retries libuv buffers for long home and temporary directories",
    function()
        local expected_home = root .. "/" .. string.rep("home", 70)
        local expected_tmp = root .. "/" .. string.rep("temp", 70)
        assert.is_true(#expected_home > 256)
        assert.is_true(#expected_tmp > 256)
        local source =
            "local expected_home = " .. string.format("%q", expected_home) ..
            "\nlocal expected_tmp = " .. string.format("%q", expected_tmp) ..
            [==[
local fs = require "titan.fs"

assert(fs.homedir() == expected_home)
assert(fs.tmpdir() == expected_tmp)
]==]
        local ok, status, output = fs_support.run_lua_source(
            workspace, source, {
                exec_prefix = {
                    "HOME=" .. expected_home,
                    "TMPDIR=" .. expected_tmp,
                },
            })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)

describe("fs tmpname delayed-callback cancellation", function()
    local workspace
    local root
    local temp
    local layout

    setup(function()
        workspace, layout = async_stdlib.variant_workspace(
            "spec/support/make_delayed_fs_callback_variant.lua", {
                facades = false,
            })
        root = workspace .. "/data"
        assert.truthy(lfs.mkdir(root))
        temp = root .. "/tmp"
        assert.truthy(lfs.mkdir(temp))
        async_stdlib.write_source(
            workspace, "fs_late_tmpname_cases", LATE_TMPNAME_CASES)
        async_stdlib.compile(workspace, "fs_late_tmpname_cases", {
            layout = layout,
        })
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    it("keeps a path created before logical cancellation", function()
        local source = [==[
local lfs = require "lfs"
local cases = require "fs_late_tmpname_cases"
local task = cases.schedule_cancelled_successful_tmpname()
cases.loop()
assert(task:join() == "late-successful-tmpname-cancellation-ok")

local temp = assert(os.getenv("TMPDIR"))
local paths = {}
for entry in lfs.dir(temp) do
    if entry ~= "." and entry ~= ".." then
        paths[#paths + 1] = temp .. "/" .. entry
    end
end
assert(#paths == 1,
    "cancelled successful tmpname did not retain exactly one path")
assert(lfs.attributes(paths[1], "mode") == "file",
    "cancelled successful tmpname did not retain a regular file")
assert(os.remove(paths[1]))
]==]
        local ok, status, output = async_stdlib.run_lua_source(
            workspace, source, {
                layout = layout,
                exec_prefix = { "TMPDIR=" .. temp },
            })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)

local os_support = require "spec.support.os_test_support"

local PROCESS_CASES = [====[
-- Public os.Process behavior against the owned test child executable.
local lua = foreign import "lua.h"
local os = import "os"
local stream = import "io"
local uv = import "uv"
local timer = import "timer"
local async = import "async"

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

local function expect_direction_failure(func: () -> value,
                                        operation: string)
  local failed = false
  do
    func()
  catch
    check(error == "Process stream has an incompatible direction",
          operation .. " reported the wrong direction error")
    failed = true
  end
  check(failed, operation .. " accepted the wrong stream direction")
end

local function expect_stale_stream(func: () -> value, operation: string)
  local failed = false
  do
    func()
  catch
    check(error == "stdio belongs to a stale libuv Runtime",
          "stale " .. operation .. " reported the wrong error")
    failed = true
  end
  check(failed,
        "closed " .. operation .. " from an older Runtime was accepted")
end

local function expect_cancelled(task: async.Task, reason: string)
  local caught = false
  do
    task:join()
  catch
    local cancelled = error as async.Cancelled
    check(cancelled.reason == reason, "cancellation reason changed")
    caught = true
  end
  check(caught and task:status() == "cancelled",
        "Task did not finish cancelled")
end

local function wait_until_started(task: async.Task)
  while task:status() == "ready" do timer.yield() end
end

local function doubled(seed: string, turns: integer): string
  local result = seed
  for _ = 1, turns do result = result .. result end
  return result
end

local function captured_streams(process: os.Process):
    (os.OutputStream, os.InputStream, os.InputStream)
  local input? = process.stdin
  local output? = process.stdout
  local diagnostics? = process.stderr
  check(input and output and diagnostics,
        "captured process omitted a standard stream")
  return input as os.OutputStream,
         output as os.InputStream,
         diagnostics as os.InputStream
end

local function read_stdout_all(process: os.Process): string
  local _input, output, _diagnostics = captured_streams(process)
  local result = ""
  for bytes in output:read do
    result = result .. bytes
  end
  return result
end

local function read_stderr_all(process: os.Process): string
  local _input, _output, diagnostics = captured_streams(process)
  local result = ""
  for bytes in diagnostics:read do
    result = result .. bytes
  end
  return result
end

local function next_pipe_chunk(pipe: uv.uv_pipe_t): string?
  return uv._os_stream_read(pipe)
end

local function check_normal(status: os.ExitStatus, message: string)
  check(status.code == 0 and not status.signal and
        status.signal_number == 0, message)
end

-- Return only Interface views so the source Process record goes out of scope.
-- Each facade retains its own pipe wrapper, whose control keeps the shared
-- native process owner alive.
local function spawn_pipe_views(
    child: string): (stream.WriterCloser, stream.Reader, stream.Reader)
  local process = os.spawn(child, { "echo" })
  return captured_streams(process)
end

local function restore_environment(name: string, original: string?)
  if original then
    os.setenv(name, original as string)
  else
    os.unsetenv(name)
  end
end

function schedule_spawn_and_metadata(child: string,
                                     envname: string): async.Task
  return async.run(function (): value
    expect_failure(function (): value
      os.spawn("", {})
      return nil
    end, "spawn accepted an empty executable")
    expect_failure(function (): value
      os.spawn(child .. "\0suffix", {})
      return nil
    end, "spawn accepted an embedded NUL in the executable")
    expect_failure(function (): value
      os.spawn(child, { "echo\0suffix" })
      return nil
    end, "spawn accepted an embedded NUL in an argument")

    local original: string? = os.getenv(envname)
    local environment = "os-process-child-environment"
    do
      os.setenv(envname, environment)
      local cwd = os.cwd()
      local process = os.spawn(child, {
        "argv-env-cwd", envname, "alpha", "", "beta",
      })
      local input, _output_stream, _diagnostics_stream =
        captured_streams(process)
      input:close()
      local output = read_stdout_all(process)
      local diagnostics = read_stderr_all(process)
      local status = process:wait()
      local expected =
        "cwd:" .. #cwd .. ":" .. cwd .. "\n" ..
        "env:" .. #environment .. ":" .. environment .. "\n" ..
        "argv0:" .. #child .. ":" .. child .. "\n" ..
        "arg:5:alpha\narg:0:\narg:4:beta\n"
      check(output == expected, "spawn changed argv, environment, or cwd")
      check(diagnostics == "", "metadata child wrote unexpected stderr")
      check_normal(status, "metadata child did not exit normally")
    finally
      restore_environment(envname, original)
    end
    local restored: string? = os.getenv(envname)
    if original then
      check(restored and (restored as string) == (original as string),
            "spawn test did not restore an existing environment value")
    else
      check(not restored, "spawn test leaked its environment variable")
    end
    return "spawn-metadata-ok"
  end)
end

function schedule_binary_fifo(child: string): async.Task
  return async.run(function (): value
    local process = os.spawn(child, { "echo" })
    local input, output_stream, _diagnostics_stream =
      captured_streams(process)
    local reader = async.run(function (): value
      return read_stdout_all(process)
    end)

    input:write("")
    local first_bytes = doubled("first\0", 15)
    local second_bytes = doubled("-second", 14)
    local third_bytes = doubled("third-", 14)
    local issued = 0
    local first = async.run(function (): value
      issued = 1
      input:write(first_bytes)
      return "first"
    end)
    local second = async.run(function (): value
      while issued < 1 do timer.yield() end
      issued = 2
      input:write(second_bytes)
      return "second"
    end)
    local third = async.run(function (): value
      while issued < 2 do timer.yield() end
      issued = 3
      input:write(third_bytes)
      return "third"
    end)
    while issued < 3 do timer.yield() end

    -- Physical EOF is FIFO behind every request that was already accepted.
    input:close()
    check(first:join() == "first" and second:join() == "second" and
          third:join() == "third", "stdin FIFO writers failed")
    input:close()
    expect_failure(function (): value
      input:write("")
      return nil
    end, "empty write bypassed the closed-stdin lifecycle check")

    local output = reader:join() as string
    check(output == first_bytes .. second_bytes .. third_bytes,
          "stdin writes were reordered or changed binary bytes")
    check(not output_stream:read(), "stdout EOF was not sticky")
    check(read_stderr_all(process) == "",
          "echo child wrote unexpected stderr")
    check_normal(process:wait(), "echo child did not exit normally")
    return "binary-fifo-ok"
  end)
end

function schedule_delimiter_reads(child: string): async.Task
  return async.run(function (): value
    local framed = os.spawn(child, { "echo" })
    local framed_input, framed_output, framed_diagnostics =
      captured_streams(framed)
    expect_failure(function (): value
      framed_output:read_until("")
      return nil
    end, "stdout accepted an empty read delimiter")
    expect_failure(function (): value
      framed_diagnostics:read_until("")
      return nil
    end, "stderr accepted an empty read delimiter")

    framed_input:write("\nleft\r")
    timer.sleep(2)
    framed_input:write("\nright")
    framed_input:close()
    local empty: string? = framed_output:read_until("\n", true)
    check(empty and #(empty as string) == 0,
          "a chopped leading stdout delimiter was confused with EOF")
    check(framed_output:read_until("\r\n", false) == "left\r\n",
          "stdout did not retain a split delimiter or false chop")
    check(framed_output:read_until("\n", true) == "right",
          "stdout changed an unterminated EOF tail")
    check(not framed_output:read_until("\n") and
          not framed_output:read(), "stdout EOF was not sticky")
    check(not framed_diagnostics:read_until("\n") and
          not framed_diagnostics:read(), "empty stderr EOF was not sticky")
    check_normal(framed:wait(), "framed echo did not exit normally")

    local binary = os.spawn(child, { "echo" })
    local binary_input, binary_output, binary_diagnostics =
      captured_streams(binary)
    binary_input:write("alpha\0betaEXCESS")
    binary_input:close()
    check(binary_output:read_until("\0beta") == "alpha\0beta",
          "stdout changed a NUL-containing delimiter or binary data")
    check(binary_output:read() == "EXCESS",
          "NUL-delimited stdout did not retain excess bytes")
    check(not binary_output:read_until("\0beta") and
          not binary_output:read(), "binary stdout EOF was not sticky")
    check(not binary_diagnostics:read(),
          "binary echo wrote unexpected stderr")
    check_normal(binary:wait(), "binary echo did not exit normally")

    local independent = os.spawn(child, { "early-output-exit" })
    local independent_input, independent_output, independent_diagnostics =
      captured_streams(independent)
    independent_input:close()
    local stdout_reader = async.run(function (): value
      return independent_output:read_until("\n")
    end)
    local stderr_reader = async.run(function (): value
      return independent_diagnostics:read_until("\n")
    end)
    check(stdout_reader:join() == "early\0stdout" and
          stderr_reader:join() == "early\0stderr",
          "stdout and stderr did not drain independently")
    check(not independent_output:read_until("\n") and
          not independent_diagnostics:read_until("\n"),
          "independent output EOF was not sticky")
    local status = independent:wait()
    check(status.code == 23 and not status.signal,
          "independent output child exit status changed")
    return "delimiter-reads-ok"
  end)
end

function schedule_pipe_interfaces(child: string): async.Task
  return async.run(function (): value
    local writer, output, diagnostics = spawn_pipe_views(child)
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    writer:write("interface\0pipes\n")
    writer:close()
    check(output:read_until("\n", true) == "interface\0pipes",
          "WriterCloser/Reader dispatch changed process pipe bytes")
    check(not output:read() and not diagnostics:read(),
          "Interface pipe views did not retain sticky EOF")

    -- Public pipe fields are ordinary mutable record fields. Swapping the
    -- output records must swap their facade-visible streams without changing
    -- either record's independent retained state.
    local swapped = os.spawn(child, { "early-output-exit" })
    local swapped_input, original_stdout, original_stderr =
      captured_streams(swapped)
    swapped_input:close()
    swapped.stdout = original_stderr
    swapped.stderr = original_stdout
    local _input, swapped_stdout, swapped_stderr = captured_streams(swapped)
    check(swapped_stdout:read_until("\n") == "early\0stderr" and
          swapped_stderr:read_until("\n") == "early\0stdout",
          "Process pipe-field reassignment did not behave as record mutation")
    check(not swapped_stdout:read() and not swapped_stderr:read(),
          "reassigned output streams did not preserve independent EOF")
    local status = swapped:wait()
    check(status.code == 23 and not status.signal,
          "reassigned-pipe child exit status changed")
    return "pipe-interfaces-ok"
  end)
end

function schedule_stream_direction_guards(child: string): async.Task
  return async.run(function (): value
    local process = uv._os_process_spawn(child, { "echo" })
    local stdin, stdout, stderr = uv._os_process_pipes(process)

    expect_direction_failure(function (): value
      return uv._os_stream_read(stdin)
    end, "read from stdin")
    expect_direction_failure(function (): value
      uv._os_stream_validate_read(stdin)
      return nil
    end, "read validation for stdin")
    expect_direction_failure(function (): value
      uv._os_stream_write(stdout, "")
      return nil
    end, "write to stdout")
    -- Readable captured streams now implement the same idempotent Closer
    -- contract as writable stdin.
    uv._os_stream_close(stderr)
    uv._os_stream_close(stderr)
    check(not uv._os_stream_read(stderr),
          "closed readable process stream did not publish EOF")

    uv._os_stream_write(stdin, "direction\0guards\n")
    uv._os_stream_close(stdin)
    local output = ""
    for bytes in next_pipe_chunk, stdout do
      output = output .. bytes
    end
    local diagnostics = ""
    for bytes in next_pipe_chunk, stderr do
      diagnostics = diagnostics .. bytes
    end
    local code, signal_number = uv._os_process_wait(process)
    check(output == "direction\0guards\n" and diagnostics == "" and
          code == 0 and signal_number == 0,
          "direction guards damaged normal stream cleanup")
    return "stream-direction-guards-ok"
  end)
end

function schedule_exit_statuses(child: string): async.Task
  return async.run(function (): value
    expect_failure(function (): value
      os.spawn(child .. ".missing", {})
      return nil
    end, "missing executable unexpectedly spawned")

    local exited = os.spawn(child, { "exit", "37" })
    local exited_input, _exited_output, _exited_diagnostics =
      captured_streams(exited)
    exited_input:close()
    check(read_stdout_all(exited) == "" and
          read_stderr_all(exited) == "",
          "exit child produced output")
    local first = exited:wait()
    local second = exited:wait()
    check(first.code == 37 and not first.signal and
          first.signal_number == 0, "normal exit status was lost")
    check(second.code == first.code and second.signal == first.signal and
          second.signal_number == first.signal_number,
          "repeated wait did not return the retained status")
    expect_failure(function (): value
      exited:kill("term")
      return nil
    end, "kill targeted an already exited Process")
    expect_failure(function (): value
      exited_input:write("")
      return nil
    end, "empty write bypassed the exited-Process lifecycle check")

    local signalled = os.spawn(child, { "self-unknown-signal" })
    local signalled_input, _signalled_output, _signalled_diagnostics =
      captured_streams(signalled)
    signalled_input:close()
    local unknown = signalled:wait()
    check(not unknown.signal and unknown.signal_number > 0,
          "unknown terminating signal number was not preserved")
    check(read_stdout_all(signalled) == "" and
          read_stderr_all(signalled) == "",
          "self-signalled child produced output")

    local killed = os.spawn(child, { "ready-wait" })
    local killed_input, killed_output, _killed_diagnostics =
      captured_streams(killed)
    killed_input:close()
    check(killed_output:read_until("\n") == "READY\n",
          "kill child did not publish its marker")
    killed:kill("kill")
    local killed_status = killed:wait()
    check(killed_status.signal == "kill" and
          killed_status.signal_number > 0,
          "public kill signal was not preserved in ExitStatus")
    check(read_stdout_all(killed) == "" and
          read_stderr_all(killed) == "",
          "killed child left unread output")

    -- A failed spawn has completed its close path before control returns, so
    -- ordinary process use in the same Runtime must remain valid.
    local followup = os.spawn(child, { "exit", "0" })
    local followup_input, _followup_output, _followup_diagnostics =
      captured_streams(followup)
    followup_input:close()
    check_normal(followup:wait(), "post-failure spawn was unusable")
    return "exit-statuses-ok"
  end)
end

function schedule_wait_and_read_cancellation(child: string): async.Task
  return async.run(function (): value
    local process = os.spawn(child, { "ready-wait" })
    local input, output_stream, _diagnostics_stream =
      captured_streams(process)
    input:close()
    check(output_stream:read_until("\n") == "READY\n",
          "ready child did not publish its marker")
    local waiter = async.run(function (): value
      return process:wait()
    end)
    wait_until_started(waiter)
    expect_failure(function (): value
      process:wait()
      return nil
    end, "Process admitted two concurrent waiters")
    waiter:cancel("cancel-process-wait")
    expect_cancelled(waiter, "cancel-process-wait")

    expect_failure(function (): value
      process:kill("not-a-signal")
      return nil
    end, "Process accepted an unknown signal name")
    expect_failure(function (): value
      process:kill("term\0kill")
      return nil
    end, "Process accepted an embedded NUL in a signal name")
    local replacement = async.run(function (): value
      return process:wait()
    end)
    wait_until_started(replacement)
    process:kill("term")
    local status = replacement:join() as os.ExitStatus
    check(status.signal == "term" and status.signal_number > 0,
          "replacement waiter lost SIGTERM status")
    local retained = process:wait()
    check(retained.signal == status.signal and
          retained.signal_number == status.signal_number,
          "signal status was not retained after replacement wait")
    check(read_stdout_all(process) == "" and
          read_stderr_all(process) == "",
          "terminated child left unread output")

    -- duplex publishes a delimiter-free prefix before waiting for stdin EOF,
    -- so cancellation happens only after stdout:read_until has accumulated it.
    local delayed = os.spawn(child, { "duplex", "64" })
    local delayed_input, delayed_output, _delayed_diagnostics =
      captured_streams(delayed)
    local expected_prefix = doubled("OUT\0pattern-1234", 2)
    local expected_stderr = doubled("ERR\0pattern-5678", 2)
    delayed_input:write("x")
    timer.sleep(20)
    local reader = async.run(function (): value
      return delayed_output:read_until("\n", true)
    end)
    wait_until_started(reader)
    expect_failure(function (): value
      delayed_output:read()
      return nil
    end, "stdout admitted two concurrent readers")
    reader:cancel("cancel-process-read")
    expect_cancelled(reader, "cancel-process-read")
    delayed_input:close()
    check(delayed_output:read_until("\n", true) == expected_prefix,
          "replacement stdout reader lost its restored prefix")
    check(delayed_output:read_until("\n", true) == "INPUT:1",
          "replacement stdout reader lost post-cancellation output")
    check(not delayed_output:read(),
          "replacement stdout EOF was not sticky")
    check(read_stderr_all(delayed) == expected_stderr,
          "stdout cancellation interfered with independent stderr buffering")
    check_normal(delayed:wait(), "duplex child did not exit normally")
    return "wait-read-cancellation-ok"
  end)
end

function schedule_queued_write_cancellation(child: string): async.Task
  return async.run(function (): value
    local process = os.spawn(child, { "delay-read-eof" })
    local input, _output_stream, diagnostics_stream =
      captured_streams(process)
    local output_reader = async.run(function (): value
      return read_stdout_all(process)
    end)
    local payload = doubled("queued-write\0", 18)
    local first = async.run(function (): value
      input:write(payload)
      return "first-write"
    end)
    wait_until_started(first)
    local queued = async.run(function (): value
      input:write("MUST-NOT-BE-WRITTEN")
      return "queued-write"
    end)
    wait_until_started(queued)
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
    queued:cancel("cancel-queued-process-write")
    expect_cancelled(queued, "cancel-queued-process-write")
    check(first:join() == "first-write", "submitted stdin write failed")
    input:close()
    check(output_reader:join() == "EOF:" .. #payload .. "\n",
          "cancelled queued write reached the child")
    check(not diagnostics_stream:read(), "wait-eof child wrote stderr")
    check_normal(process:wait(), "wait-eof child did not exit normally")
    return "queued-write-cancellation-ok"
  end)
end

local retained_process: os.Process? = nil

function schedule_forced_runtime_shutdown(child: string,
                                          pid_path: string): async.Task
  return async.run(function (): value
    local process = os.spawn(child, { "ignore-term", pid_path })
    retained_process = process
    local input, output_stream, _diagnostics_stream =
      captured_streams(process)
    input:close()
    -- Let the complete marker reach the continuously drained native queue,
    -- then retain a known facade suffix across Runtime shutdown.
    timer.sleep(50)
    check(output_stream:read_until("R", true) == "",
          "TERM-resistant child did not publish its marker prefix")
    -- No Task remains after this continuation. Runtime shutdown must TERM,
    -- wait through its private grace timer, KILL, reap, and close the process.
    return "forced-runtime-shutdown-ready"
  end)
end

function schedule_stale_process_rejection(child: string): async.Task
  return async.run(function (): value
    local process = retained_process as os.Process
    local input, output_stream, diagnostics_stream =
      captured_streams(process)
    local caught = false
    do
      process:wait()
    catch
      check(error == "Process belongs to a stale libuv Runtime",
            "stale Process wait reported the wrong error")
      caught = true
    end
    check(caught,
          "closed Process from an older Runtime generation was accepted")

    expect_stale_stream(function (): value
      input:write("")
      return nil
    end, "stdin write")
    -- Closer idempotence survives Runtime generations. The completed close is
    -- a no-op, while every operation that could touch the stale owner rejects.
    input:close()
    expect_stale_stream(function (): value
      return output_stream:read()
    end, "stdout read")
    expect_stale_stream(function (): value
      return diagnostics_stream:read()
    end, "stderr read")

    retained_process = nil
    local current = os.spawn(child, { "echo" })
    local current_input, _current_output, _current_diagnostics =
      captured_streams(current)
    current_input:write("new-generation")
    current_input:close()
    local output = read_stdout_all(current)
    local diagnostics = read_stderr_all(current)
    local status = current:wait()
    check(output == "new-generation" and diagnostics == "",
          "new Runtime was unusable after forced process shutdown")
    check_normal(status, "new-generation child did not exit normally")
    return "stale-process-rejected"
  end)
end

function retained_process_value(): os.Process?
  return retained_process
end

function retained_stdin_value(): os.OutputStream?
  if not retained_process then return nil end
  return (retained_process as os.Process).stdin
end

function retained_stdout_value(): os.InputStream?
  if not retained_process then return nil end
  return (retained_process as os.Process).stdout
end

function retained_stderr_value(): os.InputStream?
  if not retained_process then return nil end
  return (retained_process as os.Process).stderr
end
]====]

describe("os child processes", function()
    local workspace
    local child
    local envname

    setup(function()
        workspace = os_support.workspace("process")
        child = os_support.process_child(workspace)
        envname = ("TITAN_OS_PROCESS_" .. workspace):
            gsub("[^A-Za-z0-9_]", "_")
        os_support.write_source(workspace, "os_process_cases", PROCESS_CASES)
        os_support.compile(workspace, "os_process_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function source_preamble()
        return "local child = " .. string.format("%q", child) ..
            "\nlocal envname = " .. string.format("%q", envname) ..
            "\nlocal workspace = " .. string.format("%q", workspace) .. "\n"
    end

    local function run_lua(source, default_sigpipe)
        local options
        if default_sigpipe then
            options = { exec_prefix = { child, "exec-default-sigpipe" } }
        end
        local ok, status, output = os_support.run_lua_source(
            workspace, source_preamble() .. source, options)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("preserves argv/environment/cwd and retained exit status", function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"

local metadata = assert(cases.schedule_spawn_and_metadata(child, envname))
async.loop()
assert(metadata:join() == "spawn-metadata-ok")

local statuses = assert(cases.schedule_exit_statuses(child))
async.loop()
assert(statuses:join() == "exit-statuses-ok")
]==])
    end)

    it("keeps binary stdio FIFO across GC and queued cancellation", function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"

local fifo = assert(cases.schedule_binary_fifo(child))
async.loop()
assert(fifo:join() == "binary-fifo-ok")

local cancellation = assert(cases.schedule_queued_write_cancellation(child))
async.loop()
assert(cancellation:join() == "queued-write-cancellation-ok")
]==])
    end)

    it("frames stdout and stderr with independent reader state", function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"

local task = assert(cases.schedule_delimiter_reads(child))
async.loop()
assert(task:join() == "delimiter-reads-ok")
]==])
    end)

    it("uses public process pipes through exact stream Interfaces", function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"

local task = assert(cases.schedule_pipe_interfaces(child))
async.loop()
assert(task:join() == "pipe-interfaces-ok")

local guards = assert(cases.schedule_stream_direction_guards(child))
async.loop()
assert(guards:join() == "stream-direction-guards-ok")
]==])
    end)

    it("cancels replaceable wait and read waiters", function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"

local task = assert(cases.schedule_wait_and_read_cancellation(child))
async.loop()
assert(task:join() == "wait-read-cancellation-ok")
]==])
    end)

    it("terminates, reaps, and closes a leaked TERM-resistant child",
    function()
        run_lua([==[
local async = require "titan.async"
local cases = require "os_process_cases"
local pid_path = workspace .. "/shutdown.pid"

local shutdown =
    assert(cases.schedule_forced_runtime_shutdown(child, pid_path))
async.loop()
assert(shutdown:join() == "forced-runtime-shutdown-ready")

local pid_file = assert(io.open(pid_path, "rb"))
local pid = assert(tonumber(assert(pid_file:read("*l"))))
assert(pid_file:close())
-- This host-side probe is intentionally POSIX-only: Linux and macOS are
-- the supported stdlib platforms. Exit 1 means the reaped PID no longer
-- exists; shell lookup/execution failures (126/127) must not false-pass.
local alive, kind, status = os.execute(
    "kill -0 " .. pid .. " >/dev/null 2>&1")
assert(alive == nil and kind == "exit" and status == 1,
    "forced-shutdown child was live/unreaped or kill probe failed: " ..
    tostring(alive) .. "/" .. tostring(kind) .. "/" .. tostring(status))
assert(os.remove(pid_path))

local weak = setmetatable({
    process = cases.retained_process_value(),
    stdin = cases.retained_stdin_value(),
    stdout = cases.retained_stdout_value(),
    stderr = cases.retained_stderr_value(),
}, { __mode = "v" })
local stale = assert(cases.schedule_stale_process_rejection(child))
async.loop()
assert(stale:join() == "stale-process-rejected")
collectgarbage("collect")
collectgarbage("collect")
assert(weak.process == nil, "closed old-generation Process stayed rooted")
assert(weak.stdin == nil, "closed old-generation stdin stayed rooted")
assert(weak.stdout == nil, "closed old-generation stdout stayed rooted")
assert(weak.stderr == nil, "closed old-generation stderr stayed rooted")
]==])
    end)
end)

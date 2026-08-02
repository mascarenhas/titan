local os_support = require "spec.support.os_test_support"

local PROCESS_CASES = [====[
local async = import "async"
local os = import "os"

local outcome = "not-run"

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

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
end

local function required_input(candidate: os.InputStream?,
                              label: string): os.InputStream
  if not candidate then raise label .. " was not captured" end
  return candidate as os.InputStream
end

local function required_output(candidate: os.OutputStream?,
                               label: string): os.OutputStream
  if not candidate then raise label .. " was not captured" end
  return candidate as os.OutputStream
end

local function read_all(input: os.InputStream): string
  local result = ""
  for chunk in input:read do result = result .. chunk end
  return result
end

local function normal(status: os.ExitStatus, label: string)
  check(status.code == 0 and not status.signal and
        status.signal_number == 0, label .. " did not exit normally")
end

local function restore_environment(name: string, original: string?)
  if original then
    os.setenv(name, original as string)
  else
    os.unsetenv(name)
  end
end

function result(): string
  return outcome
end

function start_spawn_and_streams(child: string,
                                 envname: string): async.Task
  outcome = "running"
  return async.run(function (): value
    expect_failure(function (): value
      os.spawn("", {})
      return nil
    end, "spawn accepted an empty executable")
    expect_failure(function (): value
      os.spawn(child .. "\0suffix", {})
      return nil
    end, "spawn accepted an embedded NUL executable")
    expect_failure(function (): value
      os.spawn(child, { "echo\0suffix" })
      return nil
    end, "spawn accepted an embedded NUL argument")

    local original: string? = os.getenv(envname)
    local environment = "direct-continuation-process"
    do
      os.setenv(envname, environment)
      local cwd = os.cwd()
      local process = os.spawn(child, {
        "argv-env-cwd", envname, "alpha", "", "beta",
      })
      required_output(process.stdin, "metadata stdin"):close()
      local stdout = read_all(
        required_input(process.stdout, "metadata stdout"))
      local stderr = read_all(
        required_input(process.stderr, "metadata stderr"))
      normal(process:wait(), "metadata child")
      local expected =
        "cwd:" .. #cwd .. ":" .. cwd .. "\n" ..
        "env:" .. #environment .. ":" .. environment .. "\n" ..
        "argv0:" .. #child .. ":" .. child .. "\n" ..
        "arg:5:alpha\narg:0:\narg:4:beta\n"
      check(stdout == expected,
            "spawn changed argv, environment, or cwd")
      check(stderr == "", "metadata child wrote stderr")
    finally
      restore_environment(envname, original)
    end

    local payload = "head\0middle\ntrail"
    local echoed = os.spawn(child, { "echo" })
    local echo_input = required_output(echoed.stdin, "echo stdin")
    local echo_output = required_input(echoed.stdout, "echo stdout")
    local echo_error = required_input(echoed.stderr, "echo stderr")
    echo_input:write(payload)
    echo_input:close()
    echo_input:close()
    check(read_all(echo_output) == payload,
          "captured process stream changed binary input")
    check(read_all(echo_error) == "", "echo child wrote stderr")
    normal(echoed:wait(), "echo child")
    check(not echoed:is_running(), "reaped child remained running")

    local split = os.spawn(child, { "dual", "64" })
    required_output(split.stdin, "dual stdin"):close()
    local split_stdout = read_all(
      required_input(split.stdout, "dual stdout"))
    local split_stderr = read_all(
      required_input(split.stderr, "dual stderr"))
    normal(split:wait(), "dual-output child")
    check(#split_stdout == 64 and #split_stderr == 64,
          "separate captures returned the wrong byte counts")
    check(split_stdout ~= split_stderr,
          "stdout and stderr captures were conflated")

    local exited = os.spawn(child, { "exit", "37" })
    required_output(exited.stdin, "exit stdin"):close()
    local first = exited:wait()
    local second = exited:wait()
    check(first.code == 37 and not first.signal and
          first.signal_number == 0,
          "normal process exit status changed")
    check(second.code == first.code and second.signal == first.signal and
          second.signal_number == first.signal_number,
          "repeated wait did not retain process status")
    expect_failure(function (): value
      exited:kill("term")
      return nil
    end, "kill targeted an exited Process")

    local killed = os.spawn(child, { "ready-wait" })
    required_output(killed.stdin, "kill stdin"):close()
    local killed_stdout = required_input(killed.stdout, "kill stdout")
    check(killed_stdout:read_until("\n", true) == "READY",
          "kill child did not become ready")
    check(killed:is_running(), "live child was not running")
    expect_failure(function (): value
      killed:kill("not-a-signal")
      return nil
    end, "Process accepted an unknown signal name")
    expect_failure(function (): value
      killed:kill("term\0kill")
      return nil
    end, "Process accepted an embedded-NUL signal name")
    check(killed:is_running(),
          "invalid signal validation changed Process state")
    killed:kill("kill")
    local killed_status = killed:wait()
    check(killed_status.signal == "kill" and
          killed_status.signal_number > 0,
          "signal termination was not preserved")
    check(not killed:is_running(), "killed child remained running")

    local detached = os.spawn(child, { "ready-wait" })
    required_output(detached.stdin, "detached stdin"):close()
    local detached_stdout = required_input(
        detached.stdout, "detached stdout")
    check(detached_stdout:read_until("\n", true) == "READY",
          "detached-wait child did not become ready")
    local waiter = async.run(function (): value
      detached:wait()
      return nil
    end)
    local reader = async.run(function (): value
      detached_stdout:read()
      return nil
    end)
    while waiter:status() == "ready" or
          reader:status() == "ready" or
          waiter:status() == "running" or
          reader:status() == "running" do
      async.yield()
    end
    check(waiter:status() == "waiting" and
          reader:status() == "waiting",
          "process waiters did not suspend")
    waiter:cancel("detach process waiter")
    reader:cancel("detach process reader")
    check(waiter:status() == "waiting" and
          reader:status() == "waiting",
          "cancellation resumed a process waiter synchronously")
    while active(waiter) or active(reader) do async.yield() end
    check(waiter:status() == "cancelled" and
          reader:status() == "cancelled",
          "detached waiters did not receive their own later callbacks")
    check(detached:is_running(),
          "detaching waiters unexpectedly terminated the child")
    detached:kill("kill")
    local detached_status = detached:wait()
    check(detached_status.signal == "kill" and
          detached_status.signal_number > 0,
          "replacement wait lost process termination")

    outcome = "spawn-and-streams-ok"
    return nil
  end)
end

]====]

describe("os process", function()
    local workspace
    local child

    setup(function()
        workspace = os_support.workspace("process-direct")
        child = os_support.process_child(workspace)
        os_support.write_source(workspace, "os_process_cases", PROCESS_CASES)
        os_support.compile(workspace, "os_process_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function run_lua(source)
        local ok, status, output =
            os_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("spawns, captures binary streams, waits, and kills", function()
        run_lua(([==[
local async = require "titan.async"
local cases = require "os_process_cases"
local task = assert(cases.start_spawn_and_streams(%q, %q))
async.loop()
assert(task:status() == "succeeded", task:status())
assert(cases.result() == "spawn-and-streams-ok", cases.result())
]==]):format(child, "TITAN_PROCESS_DIRECT_ENV"))
    end)
end)

-- Public os stream/configuration behavior is a standard-library integration
-- suite and runs outside LuaCov. Every native provider is exact and private;
-- the shared checkout runtime and combined standard image remain read-only.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"
local facade_support = require "spec.support.os_stream_facade"

local CASES = [====[
local os = import "os"
local stream = import "io"
local async = import "async"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function required_input(candidate: os.InputStream?,
                              label: string): os.InputStream
  if not candidate then raise label .. " is unexpectedly inherited" end
  return candidate as os.InputStream
end

local function required_output(candidate: os.OutputStream?,
                               label: string): os.OutputStream
  if not candidate then raise label .. " is unexpectedly inherited" end
  return candidate as os.OutputStream
end

local function read_all(input: os.InputStream): string
  local result = ""
  for chunk in input:read do
    result = result .. chunk
  end
  return result
end

local function normal(status: os.ExitStatus, label: string)
  check(status.code == 0 and not status.signal and
        status.signal_number == 0, label .. " did not exit normally")
end

local function inherit_then_capture(config: os.SpawnConfig): integer
  local status = os.with_parent_stdout(config)
  if status < 0 then return status end
  return os.with_stdout(config)
end

local option_tail_called = false

local function reject_spawn_option(_config: os.SpawnConfig): integer
  return -1
end

local function forbidden_spawn_option(_config: os.SpawnConfig): integer
  option_tail_called = true
  return 0
end

local function check_interfaces(input: os.OutputStream,
                                output: os.InputStream)
  local reader: stream.Reader = output
  local reader_closer: stream.ReaderCloser = output
  local writer: stream.Writer = input
  local closer: stream.Closer = input
  local writer_closer: stream.WriterCloser = input
  if not reader or not reader_closer or not writer or not closer or
      not writer_closer then
    raise "stream Interface conversion produced nil"
  end
end

function schedule_process_facades(): async.Task
  return async.run(function (): value
    local option_rejected = false
    do
      os.spawn("/bin/sh", {"-c", ":"},
               reject_spawn_option, forbidden_spawn_option)
    catch
      option_rejected = true
    end
    check(option_rejected and not option_tail_called,
          "spawn did not stop at the first negative option status")

    local separate = os.spawn(
      "/bin/sh", {"-c", "printf separate; printf diagnostic >&2"})
    local separate_input? = separate.stdin
    local separate_output? = separate.stdout
    local separate_error? = separate.stderr
    local input = required_output(separate_input, "default stdin")
    local output = required_input(separate_output, "default stdout")
    local diagnostics = required_input(separate_error, "default stderr")
    check_interfaces(input, output)
    check(not input:is_tty() and not output:is_tty() and
          not diagnostics:is_tty(),
          "captured process pipe was classified as a TTY")
    input:close()
    check(read_all(output) == "separate", "default stdout bytes changed")
    check(read_all(diagnostics) == "diagnostic",
          "default stderr bytes changed")
    normal(separate:wait(), "default capture")
    check(not separate:is_running(),
          "is_running stayed true after retained exit status")

    local merged = os.spawn(
      "/bin/sh", {"-c", "printf A; printf B >&2"},
      os.with_parent_stdout, os.with_merged_output)
    local merged_input? = merged.stdin
    local merged_output? = merged.stdout
    local merged_error? = merged.stderr
    local merged_writer = required_output(merged_input, "merged stdin")
    local merged_reader = required_input(merged_output, "merged stdout")
    local merged_diagnostics = required_input(merged_error, "merged stderr")
    check(merged_reader == merged_diagnostics,
          "merged output did not publish the exact same facade")
    merged_writer:close()
    check(read_all(merged_reader) == "AB", "merged output bytes changed")
    check(not merged_diagnostics:read(),
          "merged facade did not share terminal state")
    normal(merged:wait(), "parent-then-merge")

    local split = os.spawn(
      "/bin/sh", {"-c", "printf D >&2"},
      os.with_merged_output, os.with_parent_stdout)
    local split_input? = split.stdin
    local split_output? = split.stdout
    local split_error? = split.stderr
    required_output(split_input, "split stdin"):close()
    check(not split_output, "later parent stdout did not remove its endpoint")
    check(read_all(required_input(split_error, "split stderr")) == "D",
          "later parent stdout did not split stderr capture")
    normal(split:wait(), "merge-then-parent")

    local recaptured = os.spawn(
      "/bin/sh", {"-c", "printf E; printf F >&2"},
      os.with_merged_output, inherit_then_capture,
      os.with_stderr, os.with_stderr)
    local recaptured_input? = recaptured.stdin
    local recaptured_output? = recaptured.stdout
    local recaptured_error? = recaptured.stderr
    required_output(recaptured_input, "recaptured stdin"):close()
    local recaptured_stdout = required_input(
      recaptured_output, "recaptured stdout")
    local recaptured_stderr = required_input(
      recaptured_error, "recaptured stderr")
    check(recaptured_stdout ~= recaptured_stderr,
          "later separate captures retained stale merged identity")
    check(read_all(recaptured_stdout) == "E" and
          read_all(recaptured_stderr) == "F",
          "custom/repeated options changed final ordering")
    normal(recaptured:wait(), "recaptured output")

    local inherited = os.spawn(
      "/bin/sh", {"-c", ":"},
      os.with_parent_stdin, os.with_parent_stdout,
      os.with_parent_stderr)
    local inherited_input? = inherited.stdin
    local inherited_output? = inherited.stdout
    local inherited_error? = inherited.stderr
    check(not inherited_input and not inherited_output and not inherited_error,
          "inherited descriptor exposed a parent-side endpoint")
    normal(inherited:wait(), "fully inherited child")

    local running = os.spawn(
      "/bin/sh", {"-c", "while :; do :; done"},
      os.with_parent_stdin, os.with_parent_stdout,
      os.with_parent_stderr)
    check(running:is_running(), "new live child was not running")
    running:kill("term")
    local terminated = running:wait()
    check(terminated.signal == "term" and terminated.signal_number > 0,
          "terminated child lost its signal status")
    check(not running:is_running(), "terminated child remained running")
    return "process-facades-ok"
  end)
end

function schedule_close_pending_read(): async.Task
  return async.run(function (): value
    local process = os.spawn(
      "/bin/sh", {"-c", "while :; do :; done"})
    local input = required_output(process.stdin, "pending-read stdin")
    local output = required_input(process.stdout, "pending-read stdout")
    local diagnostics = required_input(
      process.stderr, "pending-read stderr")
    local reader = async.run(function (): value
      return output:read()
    end)
    while reader:status() == "ready" do async.yield() end
    check(reader:status() == "waiting",
          "captured InputStream read did not block")

    output:close()
    output:close()
    check(reader:join() == nil,
          "closing captured InputStream did not wake its reader with nil")
    check(not output:read() and not output:read_until(""),
          "closed captured InputStream did not retain terminal EOF")

    diagnostics:close()
    input:close()
    process:kill("term")
    local status = process:wait()
    check(status.signal == "term" and status.signal_number > 0,
          "pending-read child did not terminate and reap")

    local delimited = os.spawn(
      "/bin/sh", {"-c", "printf partial; while :; do :; done"})
    local delimited_input = required_output(
      delimited.stdin, "pending-delimiter stdin")
    local delimited_output = required_input(
      delimited.stdout, "pending-delimiter stdout")
    local delimited_diagnostics = required_input(
      delimited.stderr, "pending-delimiter stderr")
    -- Let the continuous native reader queue the prefix first. The delimiter
    -- Task appends it synchronously, then suspends in the next native read.
    for _ = 1, 20 do async.yield() end
    local delimiter_reader = async.run(function (): value
      return delimited_output:read_until("\n")
    end)
    while delimiter_reader:status() == "ready" do async.yield() end
    check(delimiter_reader:status() == "waiting",
          "captured delimiter read did not block with a partial chunk")

    delimited_output:close()
    delimited_output:close()
    check(delimiter_reader:join() == nil,
          "captured InputStream close published an in-flight tail")
    check(not delimited_output:read(),
          "closed delimiter InputStream did not retain terminal EOF")

    delimited_diagnostics:close()
    delimited_input:close()
    delimited:kill("term")
    status = delimited:wait()
    check(status.signal == "term" and status.signal_number > 0,
          "pending-delimiter child did not terminate and reap")
    return "pending-read-close-ok"
  end)
end

function schedule_parent_generation_one(): async.Task
  return async.run(function (): value
    local stdout_tty = os.stdout:is_tty()
    local stderr_tty = os.stderr:is_tty()
    if stdout_tty and not stdout_tty then raise "unreachable" end
    if stderr_tty and not stderr_tty then raise "unreachable" end
    os.stdout:close()
    os.stderr:close()
    local first: string? = os.stdin:read_until("|", true)
    check(first == "first", "parent stdin delimiter read changed bytes")
    return "parent-generation-one-ok"
  end)
end

function schedule_parent_generation_two(): async.Task
  return async.run(function (): value
    local stale: string? = os.stdin:read()
    check(not stale,
          "parent stdin retained facade excess from an old Runtime")
    return "parent-generation-two-ok"
  end)
end
]====]

describe("os stream facade", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("os-stream-facade")
        layout = facade_support.prepare(workspace, true)
        async_stdlib.write_source(workspace, "os_stream_facade_cases", CASES)
        async_stdlib.compile(workspace, "os_stream_facade_cases", {
            layout = layout,
            cppflags = "",
        })
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run_lua(source, options)
        options = options or {}
        local ok, status, output = facade_support.run_lua_source(
            workspace, layout, source, options)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("applies options left to right and preserves endpoint identity",
    function()
        run_lua([[
local uv = require "titan.uv"
local system = require "titan.os"
local cases = require "os_stream_facade_cases"
local has_communicate = pcall(function() return system.communicate end)
assert(not has_communicate)
local task = assert(cases.schedule_process_facades())
local loop_ok, loop_error = pcall(uv._loop)
if not loop_ok then
    local fields = {}
    for _, name in ipairs({"name", "message", "operation", "subject",
            "reason"}) do
        local field_ok, value = pcall(function() return loop_error[name] end)
        if field_ok and value ~= nil then
            fields[#fields + 1] = name .. "=" .. tostring(value)
        end
    end
    error("process facade loop failed: " .. tostring(loop_error) ..
        (#fields > 0 and " (" .. table.concat(fields, ", ") .. ")" or ""))
end
local ok, result = pcall(task.join, task)
if not ok then
    local fields = {}
    for _, name in ipairs({"name", "message", "operation", "subject",
            "reason"}) do
        local field_ok, value = pcall(function() return result[name] end)
        if field_ok and value ~= nil then
            fields[#fields + 1] = name .. "=" .. tostring(value)
        end
    end
    error("process facade task failed: " .. tostring(result) ..
        (#fields > 0 and " (" .. table.concat(fields, ", ") .. ")" or ""))
end
assert(result == "process-facades-ok")
]], {
            exec_prefix = {
                "sh", "-c", "printf '' | exec \"$@\"",
                "titan-os-process-stdio",
            },
        })
    end)

    it("wakes a pending captured-input reader on repeated close", function()
        run_lua([[
local uv = require "titan.uv"
local cases = require "os_stream_facade_cases"
local task = assert(cases.schedule_close_pending_read())
uv._loop()
assert(task:join() == "pending-read-close-ok")
]])
    end)

    it("reuses stable parent records without old-generation input state",
    function()
        run_lua([[
local uv = require "titan.uv"
local system = require "titan.os"
local cases = require "os_stream_facade_cases"
local input, output, diagnostics = system.stdin, system.stdout, system.stderr
local first = assert(cases.schedule_parent_generation_one())
uv._loop()
assert(first:join() == "parent-generation-one-ok")
assert(rawequal(input, system.stdin))
assert(rawequal(output, system.stdout))
assert(rawequal(diagnostics, system.stderr))
local second = assert(cases.schedule_parent_generation_two())
uv._loop()
assert(second:join() == "parent-generation-two-ok")
assert(rawequal(input, system.stdin))
assert(rawequal(output, system.stdout))
assert(rawequal(diagnostics, system.stderr))
]], {
            exec_prefix = {
                "sh", "-c", "printf 'first|stale' | exec \"$@\"",
                "titan-os-parent-stdio",
            },
        })
    end)
end)

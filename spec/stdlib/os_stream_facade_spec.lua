local os_support = require "spec.support.os_test_support"

local FACADE_CASES = [====[
local async = import "async"
local stream = import "io"
local os = import "os"

local outcome = "not-run"
local closed_input: os.InputStream? = nil
local closed_output: os.OutputStream? = nil

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function active(task: async.Task): boolean
  return not task:status():has_finished()
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

local option_tail_called = false

local function reject_option(_config: os.SpawnConfig): integer
  return -1
end

local function forbidden_tail(_config: os.SpawnConfig): integer
  option_tail_called = true
  return 0
end

local function inherit_then_capture(config: os.SpawnConfig): integer
  local status = os.with_parent_stdout(config)
  if status < 0 then return status end
  return os.with_stdout(config)
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
    raise "process stream Interface conversion produced nil"
  end
end

function result(): string
  return outcome
end

function start_facades(): async.Task
  outcome = "running"
  return async.run(function (): value
    local option_rejected = false
    do
      os.spawn("/bin/sh", {"-c", ":"},
               reject_option, forbidden_tail)
    catch
      option_rejected = true
    end
    check(option_rejected and not option_tail_called,
          "spawn continued after a failed option")

    local separate = os.spawn(
      "/bin/sh", {"-c", "printf separate; printf diagnostic >&2"})
    local input = required_output(separate.stdin, "default stdin")
    local output = required_input(separate.stdout, "default stdout")
    local diagnostics = required_input(separate.stderr, "default stderr")
    check_interfaces(input, output)
    check(not input:is_tty() and not output:is_tty() and
          not diagnostics:is_tty(),
          "captured pipe was classified as a TTY")
    input:close()
    input:close()
    check(read_all(output) == "separate",
          "default stdout capture changed")
    check(read_all(diagnostics) == "diagnostic",
          "default stderr capture changed")
    normal(separate:wait(), "default capture")

    local merged = os.spawn(
      "/bin/sh", {"-c", "printf A; printf B >&2"},
      os.with_merged_output)
    required_output(merged.stdin, "merged stdin"):close()
    local merged_output = required_input(merged.stdout, "merged stdout")
    local merged_error = required_input(merged.stderr, "merged stderr")
    check(merged_output == merged_error,
          "merged output did not expose one stream facade")
    check(read_all(merged_output) == "AB",
          "merged stdout/stderr bytes changed")
    check(not merged_error:read(),
          "merged stream did not share terminal EOF")
    normal(merged:wait(), "merged capture")

    local recaptured = os.spawn(
      "/bin/sh", {"-c", "printf E; printf F >&2"},
      os.with_merged_output, inherit_then_capture,
      os.with_stderr, os.with_stderr)
    required_output(recaptured.stdin, "recaptured stdin"):close()
    local recaptured_output = required_input(
      recaptured.stdout, "recaptured stdout")
    local recaptured_error = required_input(
      recaptured.stderr, "recaptured stderr")
    check(recaptured_output ~= recaptured_error,
          "final spawn choices retained stale merged identity")
    check(read_all(recaptured_output) == "E" and
          read_all(recaptured_error) == "F",
          "final spawn choices returned the wrong streams")
    normal(recaptured:wait(), "recaptured streams")

    local inherited = os.spawn(
      "/bin/sh", {"-c", ":"},
      os.with_parent_stdout, os.with_parent_stderr)
    required_output(inherited.stdin, "inherited stdin"):close()
    check(not inherited.stdout and not inherited.stderr,
          "inherited descriptors exposed captured endpoints")
    normal(inherited:wait(), "inherited stdio")

    outcome = "facades-ok"
    return nil
  end)
end

function start_pending_read_close(): async.Task
  outcome = "running"
  return async.run(function (): value
    local process = os.spawn(
      "/bin/sh", {"-c", "while :; do :; done"})
    local input = required_output(process.stdin, "pending stdin")
    local output = required_input(process.stdout, "pending stdout")
    local diagnostics = required_input(process.stderr, "pending stderr")
    local read_result = "not-resumed"
    local reader = async.run(function (): value
      local chunk? = output:read()
      if chunk then
        read_result = chunk as string
      else
        read_result = "eof"
      end
      return nil
    end)
    while reader:status():as_string() == "ready" or
          reader:status():as_string() == "running" do
      async.yield()
    end
    check(reader:status():as_string() == "waiting",
          "captured read did not reach its callback wait")
    local competing_reader_rejected = false
    do
      output:read()
    catch
      competing_reader_rejected = true
    end
    check(competing_reader_rejected,
          "captured input accepted a second waiting reader")
    output:close()
    output:close()
    while active(reader) do async.yield() end
    check(reader:status():as_string() == "succeeded" and read_result == "eof",
          "closing captured input did not wake its reader with EOF")
    check(not output:read() and not output:read_until("missing"),
          "closed captured input did not keep terminal EOF")
    diagnostics:close()
    input:close()
    process:kill("term")
    local status = process:wait()
    check(status.signal == "term" and status.signal_number > 0,
          "pending-read child was not reaped")
    outcome = "pending-read-close-ok"
    return nil
  end)
end

function start_parent_input(): async.Task
  outcome = "running"
  return async.run(function (): value
    local reader: stream.ReaderCloser = os.stdin
    local writer: stream.Writer = os.stdout
    local diagnostics: stream.Writer = os.stderr
    if not reader or not writer or not diagnostics then
      raise "parent stdio Interface conversion produced nil"
    end
    check(os.stdin:read_until("|", true) == "first",
          "parent stdin delimiter read changed")
    check(os.stdin:read() == "second",
          "parent stdin retained bytes changed")
    check(not os.stdin:read(), "parent stdin did not reach EOF")
    os.stdin:close()
    check(not os.stdin:read(), "borrowed stdin close changed EOF")
    outcome = "parent-input-ok"
    return nil
  end)
end

function start_close_for_next_runtime(): async.Task
  outcome = "running"
  return async.run(function (): value
    local process = os.spawn("/bin/sh", {"-c", ":"})
    local input = required_output(process.stdin, "retained stdin")
    local output = required_input(process.stdout, "retained stdout")
    local diagnostics = required_input(process.stderr, "retained stderr")
    input:close()
    output:close()
    diagnostics:close()
    normal(process:wait(), "retained-stream child")
    closed_input = output
    closed_output = input
    outcome = "closed-for-next-runtime"
    return nil
  end)
end

function start_read_closed_in_next_runtime(): async.Task
  outcome = "running"
  return async.run(function (): value
    local input = closed_input as os.InputStream
    check(not input:read() and not input:read_until("missing"),
          "closed captured input lost terminal EOF in a later Runtime")
    input:close()
    local output = closed_output as os.OutputStream
    output:close()
    local write_rejected = false
    do
      output:write("late")
    catch
      write_rejected = true
    end
    check(write_rejected,
          "closed captured output became writable in a later Runtime")
    outcome = "cross-runtime-closed-ok"
    return nil
  end)
end
]====]

describe("os stream facades", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("stream-facades-direct")
        os_support.write_source(workspace, "os_stream_facade_cases",
                                FACADE_CASES)
        os_support.compile(workspace, "os_stream_facade_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function run(function_name, expected, options)
        local source = ([==[
local async = require "titan.async"
local cases = require "os_stream_facade_cases"
local task = assert(cases.%s())
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, expected)
        local ok, status, output =
            os_support.run_lua_source(workspace, source, options)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("adapts captures, merges, inheritance, options, and Interfaces",
    function()
        run("start_facades", "facades-ok")
    end)

    it("wakes a pending captured reader when its stream closes", function()
        run("start_pending_read_close", "pending-read-close-ok")
    end)

    it("reads binary-safe parent stdin through the stable facade", function()
        run("start_parent_input", "parent-input-ok", {
            exec_prefix = {
                "sh", "-c", "printf 'first|second' | exec \"$@\"",
                "titan-parent-stdin",
            },
        })
    end)

    it("keeps a closed captured input terminal in a later Runtime", function()
        local source = [[
local async = require "titan.async"
local cases = require "os_stream_facade_cases"

local first = assert(cases.start_close_for_next_runtime())
async.loop()
assert(first:status():as_string() == "succeeded", first:status():as_string())
assert(cases.result() == "closed-for-next-runtime", cases.result())

local second = assert(cases.start_read_closed_in_next_runtime())
async.loop()
assert(second:status():as_string() == "succeeded", second:status():as_string())
assert(cases.result() == "cross-runtime-closed-ok", cases.result())
]]
        local ok, status, output =
            os_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)

-- Public io.popen behavior against private exact os/uv providers. This is a
-- standard-library integration suite and deliberately runs outside LuaCov.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"
local facade_support = require "spec.support.os_stream_facade"

local CASES = [====[
local io = import "io"
local os = import "os"
local async = import "async"

local retained_pipe: io.InputOutputStream? = nil

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function read_all(input: io.InputOutputStream): string
  local result = ""
  for chunk in input:read do
    result = result .. chunk
  end
  return result
end

local function check_interfaces(input: io.InputOutputStream)
  local reader: io.Reader = input
  local writer: io.Writer = input
  local closer: io.Closer = input
  local reader_writer: io.ReaderWriter = input
  local reader_closer: io.ReaderCloser = input
  local writer_closer: io.WriterCloser = input
  local all: io.ReaderWriterCloser = input
  if not reader or not writer or not closer or not reader_writer or
      not reader_closer or not writer_closer or not all then
    raise "InputOutputStream Interface conversion produced nil"
  end
end

local function same_status(first: os.ExitStatus,
                           second: os.ExitStatus): boolean
  return first.code == second.code and first.signal == second.signal and
         first.signal_number == second.signal_number
end

local function doubled(seed: string, turns: integer): string
  local result = seed
  for _ = 1, turns do result = result .. result end
  return result
end

local function expect_cancelled(task: async.Task, reason: string)
  local caught = false
  do
    task:join()
  catch
    local cancelled = error as async.Cancelled
    check(cancelled.reason == reason, "close cancellation reason changed")
    caught = true
  end
  check(caught and task:status() == "cancelled",
        "close Task did not finish cancelled")
end

function schedule_interactive(): async.Task
  return async.run(function (): value
    local rejected_nul = false
    do
      io.popen("printf forbidden\0suffix")
    catch
      rejected_nul = true
    end
    check(rejected_nul,
          "popen accepted an embedded NUL in its shell command")

    local pipe = io.popen(
      "IFS= read -r line; printf 'OUT:%s' \"$line\"; " ..
      "printf ':ERR' >&2; exit 7")
    check_interfaces(pipe)
    pipe:write("hello world\n")
    check(read_all(pipe) == "OUT:hello world:ERR",
          "popen did not merge interactive stdout/stderr")
    local first = pipe:wait()
    local second = pipe:wait()
    check(first.code == 7 and not first.signal and
          first.signal_number == 0 and same_status(first, second),
          "popen wait did not cache normal status")
    pipe:close()
    pipe:close()
    check(same_status(first, pipe:wait()),
          "close changed a status cached by wait")
    return "interactive-ok"
  end)
end

function schedule_large_duplex(): async.Task
  return async.run(function (): value
    local command =
      "i=0; while [ \"$i\" -lt 4096 ]; do " ..
      "IFS= read -r line || exit 9; printf '%s\\n' \"$line\"; " ..
      "i=$((i + 1)); done"
    local pipe = io.popen(command)
    local line = doubled("0123456789abcdef", 3) .. "\n"
    local payload = doubled(line, 12)
    local writer = async.run(function (): value
      pipe:write(payload)
      return "writer-ok"
    end)
    local reader = async.run(function (): value
      return read_all(pipe)
    end)
    check(writer:join() == "writer-ok", "large popen writer failed")
    check(reader:join() == payload,
          "large concurrent popen traffic changed bytes")
    local status = pipe:wait()
    check(status.code == 0 and not status.signal,
          "large duplex command did not exit normally")
    pipe:close()
    check(same_status(status, pipe:wait()),
          "large duplex close changed cached status")
    return "large-duplex-ok"
  end)
end

function schedule_signal_and_close(): async.Task
  return async.run(function (): value
    local signalled = io.popen("kill -TERM $$")
    check(read_all(signalled) == "", "signal command produced output")
    local direct = signalled:wait()
    check(direct.signal == "term" and direct.signal_number > 0,
          "popen lost direct signal termination")
    signalled:close()
    check(same_status(direct, signalled:wait()),
          "close changed direct signal status")

    local closed = io.popen(
      "printf 'READY\\n'; while :; do :; done")
    check(closed:read_until("\n", true) == "READY",
          "running close child did not become ready")
    closed:close()
    closed:close()
    check(not closed:read() and
          not closed:read_until("\n", true),
          "closed popen stream did not publish terminal EOF")
    local status = closed:wait()
    check(status.signal == "term" and status.signal_number > 0,
          "close did not terminate and reap a running child")
    check(same_status(status, closed:wait()),
          "close did not cache the reaped signal status")
    return "signal-close-ok"
  end)
end

function schedule_cancelled_close_retry(): async.Task
  return async.run(function (): value
    local pipe = io.popen(
      "trap 'sleep 1; exit 0' TERM; " ..
      "printf 'READY\\nUNREAD\\n'; while :; do :; done")
    check(pipe:read_until("\n", true) == "READY",
          "cancellable close child did not become ready")
    local closer = async.run(function (): value
      pipe:close()
      return "closed"
    end)
    while closer:status() == "ready" do async.yield() end
    check(closer:status() == "waiting",
          "close did not reach its process wait")
    closer:cancel("cancel-popen-close")
    expect_cancelled(closer, "cancel-popen-close")

    -- A cancelled first close must not publish the composite idempotence bit,
    -- but its final cleanup has already discarded the merged stream's unread
    -- bytes and published terminal ReaderCloser EOF.
    check(not pipe:read() and not pipe:read_until("\n", true),
          "cancelled close did not immediately dispose merged output")

    -- Retrying closes the already-monotonic endpoints and still waits/reaps.
    pipe:close()
    pipe:close()
    local first = pipe:wait()
    local second = pipe:wait()
    check(same_status(first, second),
          "retried close did not retain the reaped status")
    return "cancelled-close-retry-ok"
  end)
end

function schedule_descendant_output_close(): async.Task
  return async.run(function (): value
    local pipe = io.popen(
      "sleep 3 & child=$!; printf 'READY\\n'; exit 0")
    check(pipe:read_until("\n", true) == "READY",
          "descendant-output command did not become ready")
    local status = pipe:wait()
    check(status.code == 0 and not status.signal,
          "descendant-output shell did not exit normally")
    pipe:close()
    pipe:close()
    check(not pipe:read() and not pipe:read_until(""),
          "closed descendant-output stream did not stay at EOF")
    return "descendant-output-close-ok"
  end)
end

function schedule_retain_popen(): async.Task
  return async.run(function (): value
    retained_pipe = io.popen("printf retained")
    return "retained-popen-ready"
  end)
end

function schedule_close_retained_popen(): async.Task
  return async.run(function (): value
    local pipe = retained_pipe as io.InputOutputStream
    pipe:close()
    pipe:close()
    check(not pipe:read() and not pipe:read_until(""),
          "cross-generation popen close did not stay at EOF")
    retained_pipe = nil
    return "retained-popen-closed"
  end)
end
]====]

describe("io process stream", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("io-process")
        layout = facade_support.prepare(workspace, true)
        async_stdlib.write_source(workspace, "io_process_cases", CASES)
        async_stdlib.compile(workspace, "io_process_cases", {
            layout = layout,
            cppflags = "",
        })
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run_case(name, expected)
        local source = ([==[
local uv = require "titan.uv"
local cases = require "io_process_cases"
local task = assert(cases.%s())
uv._loop()
assert(task:join() == %q)
]==]):format(name, expected)
        local ok, status, output = facade_support.run_lua_source(
            workspace, layout, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("merges interactive output and caches normal status", function()
        run_case("schedule_interactive", "interactive-ok")
    end)

    it("supports large concurrent duplex traffic", function()
        run_case("schedule_large_duplex", "large-duplex-ok")
    end)

    it("preserves signal status and idempotently reaps on close", function()
        run_case("schedule_signal_and_close", "signal-close-ok")
    end)

    it("keeps a cancelled close retryable until reaping succeeds", function()
        run_case("schedule_cancelled_close_retry",
                 "cancelled-close-retry-ok")
    end)

    it("disposes merged output held open by a descendant", function()
        local source = [==[
local uv = require "titan.uv"
local cases = require "io_process_cases"
local started = os.time()
local task = assert(cases.schedule_descendant_output_close())
uv._loop()
assert(task:join() == "descendant-output-close-ok")
assert(os.time() - started < 2, "descendant kept the Runtime alive")
]==]
        local ok, status, output = facade_support.run_lua_source(
            workspace, layout, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)

    it("keeps close idempotent after the owning Runtime shuts down",
    function()
        local source = [==[
local uv = require "titan.uv"
local cases = require "io_process_cases"
local first = assert(cases.schedule_retain_popen())
uv._loop()
assert(first:join() == "retained-popen-ready")
local second = assert(cases.schedule_close_retained_popen())
uv._loop()
assert(second:join() == "retained-popen-closed")
]==]
        local ok, status, output = facade_support.run_lua_source(
            workspace, layout, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end)
end)

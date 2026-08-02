local os_support = require "spec.support.os_test_support"

local IO_PROCESS_CASES = [====[
local async = import "async"
local stream = import "io"
local os = import "os"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function same_status(first: os.ExitStatus,
                           second: os.ExitStatus): boolean
  return first.code == second.code and first.signal == second.signal and
         first.signal_number == second.signal_number
end

local function check_interfaces(pipe: stream.InputOutputStream)
  local reader: stream.Reader = pipe
  local writer: stream.Writer = pipe
  local closer: stream.Closer = pipe
  local reader_writer: stream.ReaderWriter = pipe
  local reader_closer: stream.ReaderCloser = pipe
  local writer_closer: stream.WriterCloser = pipe
  local all: stream.ReaderWriterCloser = pipe
  if not reader or not writer or not closer or not reader_writer or
      not reader_closer or not writer_closer or not all then
    raise "InputOutputStream Interface conversion produced nil"
  end
end

local function read_all(pipe: stream.InputOutputStream): string
  local result = ""
  for chunk in pipe:read do result = result .. chunk end
  return result
end

function result(): string
  return outcome
end

function start_interactive(): async.Task
  outcome = "running"
  return async.run(function (): value
    local rejected_nul = false
    do
      stream.popen("printf forbidden\0suffix")
    catch
      rejected_nul = true
    end
    check(rejected_nul, "popen accepted an embedded NUL command")

    local pipe = stream.popen(
      "IFS= read -r line; printf 'OUT:%s' \"$line\"; " ..
      "printf ':ERR' >&2; exit 7")
    check_interfaces(pipe)
    pipe:write("hello world\n")
    check(read_all(pipe) == "OUT:hello world:ERR",
          "interactive popen changed merged output")
    local first = pipe:wait()
    local second = pipe:wait()
    check(first.code == 7 and not first.signal and
          first.signal_number == 0 and same_status(first, second),
          "popen did not retain normal exit status")
    pipe:close()
    pipe:close()
    check(not pipe:read() and not pipe:read_until("missing"),
          "closed popen stream did not keep terminal EOF")
    check(same_status(first, pipe:wait()),
          "close changed a retained exit status")
    outcome = "interactive-ok"
    return nil
  end)
end

function start_binary_delimiters(): async.Task
  outcome = "running"
  return async.run(function (): value
    local payload = "head\0middle\ntrail"
    local pipe = stream.popen(
      "dd bs=1 count=17 2>/dev/null; printf '|done'")
    pipe:write(payload)
    check(pipe:read_until("|", true) == payload,
          "popen binary delimiter read changed bytes")
    check(pipe:read() == "done",
          "popen delimiter read lost retained excess")
    check(not pipe:read() and not pipe:read_until("missing"),
          "repeated popen reads did not return EOF")
    local status = pipe:wait()
    check(status.code == 0 and not status.signal,
          "binary popen command did not exit normally")
    pipe:close()
    outcome = "binary-delimiters-ok"
    return nil
  end)
end

function start_close_running(): async.Task
  outcome = "running"
  return async.run(function (): value
    local pipe = stream.popen(
      "printf 'READY\nUNREAD\n'; while :; do :; done")
    check(pipe:read_until("\n", true) == "READY",
          "running popen command did not become ready")
    pipe:close()
    pipe:close()
    check(not pipe:read() and not pipe:read_until("missing"),
          "closing popen did not discard unread output")
    local first = pipe:wait()
    local second = pipe:wait()
    check(first.signal == "term" and first.signal_number > 0 and
          same_status(first, second),
          "popen close did not terminate and retain status")
    outcome = "close-running-ok"
    return nil
  end)
end
]====]

describe("io process stream", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("io-process-direct")
        os_support.write_source(workspace, "io_process_cases",
                                IO_PROCESS_CASES)
        os_support.compile(workspace, "io_process_cases")
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function run(function_name, expected)
        local source = ([==[
local async = require "titan.async"
local cases = require "io_process_cases"
local task = assert(cases.%s())
async.loop()
assert(task:status() == "succeeded", task:status())
assert(cases.result() == %q, cases.result())
]==]):format(function_name, expected)
        local ok, status, output =
            os_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("merges interactive output and retains status", function()
        run("start_interactive", "interactive-ok")
    end)

    it("preserves binary data across delimited reads", function()
        run("start_binary_delimiters", "binary-delimiters-ok")
    end)

    it("idempotently terminates and reaps a running command", function()
        run("start_close_running", "close-running-ok")
    end)
end)

local os_support = require "spec.support.os_test_support"

local FACADE_CASES = [====[
local async = import "async"
local stream = import "io"
local os = import "os"

local outcome = "not-run"
local closed_input: os.InputStream? = nil
local closed_output: os.OutputStream? = nil

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

function result(): string
  return outcome
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
    if os.stdin:read_until("|", true) ~= "first" then
      raise "parent stdin delimiter read changed"
    end
    if os.stdin:read() ~= "second" then
      raise "parent stdin retained bytes changed"
    end
    if os.stdin:read() then raise "parent stdin did not reach EOF" end
    os.stdin:close()
    if os.stdin:read() then raise "borrowed stdin close changed EOF" end
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
    local status = process:wait()
    if status.code ~= 0 or status.signal or status.signal_number ~= 0 then
      raise "retained-stream child did not exit normally"
    end
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
    if input:read() or input:read_until("missing") then
      raise "closed captured input lost terminal EOF in a later Runtime"
    end
    input:close()
    local output = closed_output as os.OutputStream
    output:close()
    local write_rejected = false
    do
      output:write("late")
    catch
      write_rejected = true
    end
    if not write_rejected then
      raise "closed captured output became writable in a later Runtime"
    end
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

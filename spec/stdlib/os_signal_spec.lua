local os_support = require "spec.support.os_test_support"

local SIGNAL_CASES = [====[
local libuv = foreign import "uv.h"
local ffi = foreign import "titan/ffi.h"
local async = import "async"
local os = import "os"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function active(task: async.Task): boolean
  local status = task:status()
  return status == "ready" or status == "running" or status == "waiting"
end

local function wait_until_waiting(task: async.Task)
  while task:status() == "ready" or task:status() == "running" do
    async.yield()
  end
  check(task:status() == "waiting",
        "signal Task did not suspend for its callback")
end

local function send_signal(name: string)
  local signum: ffi.titan_ffi_int = libuv.SIGUSR1
  if name == "usr2" then
    signum = libuv.SIGUSR2
  else
    check(name == "usr1", "test requested an unsupported signal")
  end
  check((libuv.uv_kill(libuv.uv_os_getpid(), signum) as integer) == 0,
        "libuv self-delivery failed")
end

function result(): string
  return outcome
end

function start(): async.Task
  outcome = "running"
  return async.run(function (): value
    local unknown = false
    do
      os.wait_signal("not-a-signal")
    catch
      unknown = true
    end
    local uncatchable = false
    do
      os.wait_signal("kill")
    catch
      uncatchable = true
    end
    local embedded_nul = false
    do
      os.wait_signal("usr1\0ignored")
    catch
      embedded_nul = true
    end
    check(unknown and uncatchable and embedded_nul,
          "invalid signal name was accepted")

    local received = ""
    local waiter = async.run(function (): value
      received = os.wait_signal("usr1")
      return nil
    end)
    wait_until_waiting(waiter)
    send_signal("usr1")
    while active(waiter) do async.yield() end
    check(waiter:status() == "succeeded" and received == "usr1",
          "one-shot signal continuation returned the wrong result")

    local cancelled_resumed = false
    local cancelled = async.run(function (): value
      os.wait_signal("usr2")
      cancelled_resumed = true
      return nil
    end)
    wait_until_waiting(cancelled)
    cancelled:cancel("discard signal wait")
    check(cancelled:status() == "waiting",
          "signal cancellation resumed synchronously")
    while active(cancelled) do async.yield() end
    check(cancelled:status() == "cancelled" and not cancelled_resumed,
          "cancelled signal continuation resumed")

    local replacement_received = ""
    local replacement = async.run(function (): value
      replacement_received = os.wait_signal("usr2")
      return nil
    end)
    wait_until_waiting(replacement)
    send_signal("usr2")
    while active(replacement) do async.yield() end
    check(replacement:status() == "succeeded" and
          replacement_received == "usr2",
          "replacement one-shot signal watcher failed")

    outcome = "signals-ok"
    return nil
  end)
end
]====]

describe("os signals", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("signals-direct")
        os_support.write_source(workspace, "os_signal_cases", SIGNAL_CASES)
        os_support.compile(workspace, "os_signal_cases", {
            cppflags = os_support.libuv_cppflags(),
        })
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    it("validates, delivers, cancels, and replaces one-shot watchers",
    function()
        local ok, status, output = os_support.run_lua_source(workspace, [==[
local async = require "titan.async"
local cases = require "os_signal_cases"
local task = assert(cases.start())
async.loop()
assert(task:status() == "succeeded", task:status())
assert(cases.result() == "signals-ok", cases.result())
]==])
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)
end)

local os_support = require "spec.support.os_test_support"

local SIGNAL_CASES = [====[
-- Public one-shot signal behavior against the canonical production modules.
-- Self-delivery uses libuv rather than POSIX helpers or private test hooks.
local libuv = foreign import "uv.h"
local lua = foreign import "lua.h"
local ffi = foreign import "titan/ffi.h"
local os = import "os"
local timer = import "timer"
local uv = import "uv"

local cancelled_wait_resumed = false
local sent_cancelled_wait_resumed = false

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function wait_until_waiting(task: uv.Task)
  local status = task:status()
  while status ~= "waiting" do
    check(status == "new" or status == "ready" or status == "running",
          "signal waiter terminated before reaching its wait point")
    timer.yield()
    status = task:status()
  end
end

local function send_signal(name: string)
  local signum: ffi.titan_ffi_int = libuv.SIGUSR1
  if name == "usr2" then
    signum = libuv.SIGUSR2
  else
    check(name == "usr1", "test requested an unsupported signal")
  end
  local status = libuv.uv_kill(libuv.uv_os_getpid(), signum)
  check((status as integer) == 0, "public libuv self-delivery failed")
end

function schedule_one_shot(name: string): uv.Task
  return uv.run(function (): value
    local waiter = uv.run(function (): value
      return os.wait_signal(name)
    end)
    wait_until_waiting(waiter)
    send_signal(name)
    local result = waiter:join() as string
    check(result == name, "one-shot signal returned the wrong name")
    return result
  end)
end

function schedule_cancelled_wait(): uv.Task
  cancelled_wait_resumed = false
  return uv.run(function (): value
    local target = uv.run(function (): value
      local result = os.wait_signal("usr1")
      cancelled_wait_resumed = true
      return result
    end)

    wait_until_waiting(target)
    target:cancel("cancelled-signal-wait")
    local caught = false
    do
      target:join()
    catch
      local cancelled = error as uv.Cancelled
      check(cancelled.reason == "cancelled-signal-wait",
            "signal cancellation reason changed")
      caught = true
    end
    check(caught and target:status() == "cancelled",
          "signal waiter was not cancelled")

    -- A replacement watcher receives the signal. If the cancelled watcher
    -- retained a stale waiter, it would resume too or consume this delivery.
    local replacement = uv.run(function (): value
      return os.wait_signal("usr1")
    end)
    wait_until_waiting(replacement)
    send_signal("usr1")
    check(replacement:join() == "usr1",
          "replacement signal watcher did not receive the signal")
    check(not cancelled_wait_resumed,
          "cancelled signal waiter resumed from a stale callback")
    return "cancelled-signal-wait-ok"
  end)
end

function schedule_sent_then_cancelled_wait(): uv.Task
  sent_cancelled_wait_resumed = false
  return uv.run(function (): value
    local target = uv.run(function (): value
      local result = os.wait_signal("usr1")
      sent_cancelled_wait_resumed = true
      return result
    end)

    wait_until_waiting(target)
    -- uv_kill has handed the signal to the process, but libuv cannot enter
    -- its callback reentrantly while this continuation is still running.
    -- The synchronous cancellation mark must suppress that delivery.
    send_signal("usr1")
    target:cancel("cancel-after-signal-send")
    local caught = false
    do
      target:join()
    catch
      local cancelled = error as uv.Cancelled
      check(cancelled.reason == "cancel-after-signal-send",
            "sent-signal cancellation reason changed")
      caught = true
    end
    check(caught and target:status() == "cancelled",
          "sent-signal waiter was not cancelled")
    check(not sent_cancelled_wait_resumed,
          "already-sent signal resumed a synchronously cancelled waiter")
    return "sent-then-cancelled-signal-wait-ok"
  end)
end

function schedule_generational_gc(): uv.Task
  return uv.run(function (): value
    local waiter = uv.run(function (): value
      return os.wait_signal("usr2")
    end)
    wait_until_waiting(waiter)

    -- The Runtime, signal owner, Task, and shared coroutine tag are all old
    -- before delivery. The callback identity is the Runtime-rooted wrapper
    -- record, not its separate native-storage userdata.
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)
    send_signal("usr2")
    check(waiter:join() == "usr2",
          "signal owner did not survive generational collection")
    return "signal-generational-gc-ok"
  end)
end

function schedule_validation_rejections(): uv.Task
  return uv.run(function (): value
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
    check(unknown and uncatchable,
          "invalid or uncatchable signal name was accepted")

    -- Immediate validation failures must leave ordinary signal use intact.
    local waiter = uv.run(function (): value
      return os.wait_signal("usr1")
    end)
    wait_until_waiting(waiter)
    send_signal("usr1")
    check(waiter:join() == "usr1",
          "signal use failed after validation rejection")
    return "signal-validation-rejections-ok"
  end)
end
]====]

describe("os one-shot signals", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("signal")
        os_support.write_source(workspace, "os_signal_cases", SIGNAL_CASES)
        os_support.compile(workspace, "os_signal_cases", {
            cppflags = os_support.libuv_cppflags(),
        })
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

    it("delivers, cancels, collects, validates, and drains sequential sessions",
    function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "os_signal_cases"

local usr1 = assert(cases.schedule_one_shot("usr1"))
uv.loop()
assert(usr1:join() == "usr1")

local usr2 = assert(cases.schedule_one_shot("usr2"))
uv.loop()
assert(usr2:join() == "usr2")

local cancelled = assert(cases.schedule_cancelled_wait())
uv.loop()
assert(cancelled:join() == "cancelled-signal-wait-ok")

local sent_then_cancelled =
    assert(cases.schedule_sent_then_cancelled_wait())
uv.loop()
assert(sent_then_cancelled:join() ==
    "sent-then-cancelled-signal-wait-ok")

local generational = assert(cases.schedule_generational_gc())
uv.loop()
assert(generational:join() == "signal-generational-gc-ok")

local validation = assert(cases.schedule_validation_rejections())
uv.loop()
assert(validation:join() == "signal-validation-rejections-ok")
]==])
    end)
end)

-- Graceful os.exit behavior is exercised against one private exact-provider
-- graph. The variant changes only one test-controlled cleanup callback; no
-- canonical stdlib artifact or shared runtime archive is rebuilt by this spec.
local assert = require "luassert"
local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"
local os_support = require "spec.support.os_test_support"

local prefix = os.getenv("PREFIX")
local function exists(path)
    return lfs.attributes(path) ~= nil
end
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

-- titan.fs and titan.os need only this narrow binary-safe string surface in
-- this focused suite. Their complete implementations have their own exact
-- provider tests; avoiding PEG/regex here keeps the exit fixture narrow.
local STRING_SUPPORT = [====[
local ffi = foreign import "titan/ffi.h"
local cstring = foreign import "string.h"
local async = import "async"

record StringWriter
  local contents: string
  local yielding: boolean
end

function writer(yielding: boolean?): StringWriter
  local actual_yielding = true
  if yielding ~= nil then actual_yielding = yielding end
  return StringWriter.new("", actual_yielding)
end

function StringWriter:write(data: string)
  if self.yielding then async.yield() end
  self.contents = self.contents .. data
end

function StringWriter:drain(): string
  local result = self.contents
  self.contents = ""
  return result
end

function StringWriter:close()
end

local function initial_position(position: integer,
                                length: integer): integer
  if position > 0 then
    return position
  elseif position == 0 or position < -length then
    return 1
  else
    return length + position + 1
  end
end

local function ending_position(position: integer,
                               length: integer): integer
  if position > length then
    return length
  elseif position >= 0 then
    return position
  elseif position < -length then
    return 0
  else
    return length + position + 1
  end
end

function sub(subject: string, first: integer,
             last: integer?): string
  local actual_last = -1
  if last then actual_last = last end
  local initial = initial_position(first, #subject)
  local ending = ending_position(actual_last, #subject)
  if initial > ending then return "" end
  local count = ending - initial + 1
  local storage = ffi.titan_ffi_char.new_array(count)
  cstring.memcpy(
    storage as *ffi.titan_ffi_char,
    (subject as const *ffi.titan_ffi_char) + initial - 1,
    count as cstring.size_t)
  return storage as string
end

function find(subject: string, needle: string,
              init: integer?): (integer?, integer?)
  local raw_init = 1
  if init then raw_init = init end
  local first = initial_position(raw_init, #subject)
  if first > #subject + 1 then return nil, nil end
  if #needle == 0 then return first, first - 1 end
  if first > #subject or #needle > #subject - first + 1 then
    return nil, nil
  end
  local subject_bytes = subject as const *ffi.titan_ffi_char
  local needle_bytes = needle as const *ffi.titan_ffi_char
  local offset = first - 1
  local limit = #subject - #needle
  while offset <= limit do
    if cstring.memcmp(
        subject_bytes + offset, needle_bytes,
        #needle as cstring.size_t) == 0 then
      return offset + 1, offset + #needle
    end
    offset = offset + 1
  end
  return nil, nil
end
]====]

local EXIT_APP = [====[
local system = import "os"
local fs = import "fs"
local uv = import "uv"
local timer = import "timer"
local async = import "async"
local stdio = foreign import "stdio.h"

local retained_file: fs.File? = nil
local retained_process: system.Process? = nil
local retained_stdout: uv.uv_stdio_t? = nil

local function append(path: string, text: string)
  local file = stdio.fopen(path, "ab")
  if not file then raise "could not open exit marker" end
  local written = stdio.fwrite(text, #text, 1, file)
  if (written as integer) ~= 1 then
    stdio.fclose(file)
    raise "could not write exit marker"
  end
  if stdio.fclose(file) ~= 0 then
    raise "could not close exit marker"
  end
end

local function wait_for_path(path: string)
  local attempts = 0
  local ready = false
  while not ready and attempts < 5000 do
    do
      fs.stat(path)
      ready = true
    catch
    end
    if not ready then timer.sleep(1) end
    attempts = attempts + 1
  end
  if not ready then raise "child did not publish its pid file" end
end

local function default_exit(marker: string): integer
  defer append(marker, "defer;")
  do
    system.exit()
  finally
    append(marker, "finally;")
  end
  append(marker, "after;")
  return 99
end

local function explicit_exit(marker: string): integer
  defer append(marker, "defer;")
  system.exit(23)
  append(marker, "after;")
  return 99
end

local function detached_child_exit(marker: string): integer
  async.run(function (): value
    do
      timer.yield()
      system.exit(29)
      append(marker, "detached-after;")
    finally
      append(marker, "detached-finally;")
      system.exit(92)
    end
    return nil
  end)
  defer append(marker, "completed-main-defer;")
  return 7
end

local function child_exit(marker: string, child: string,
                          pid_path: string): integer
  local file = fs.open(marker .. ".live-file", "w")
  retained_file = file
  file:write("live until Runtime shutdown")
  retained_stdout = uv._os_parent_stdout()
  retained_process = system.spawn(child, { "ignore-term", pid_path })
  wait_for_path(pid_path)

  async.run(function (): value
    do
      timer.sleep(60000)
    finally
      append(marker, "sibling-finally;")
    end
    return nil
  end)
  async.run(function (): value
    do
      timer.yield()
      system.exit(27)
      append(marker, "requester-after;")
    finally
      append(marker, "requester-finally;")
      -- A request made while the first request is unwinding cannot replace
      -- the already committed standalone status.
      system.exit(91)
    end
    return nil
  end)

  do
    timer.sleep(60000)
  finally
    append(marker, "main-finally;")
  end
  append(marker, "main-after;")
  return 99
end

function main(args: {string}): integer
  if #args < 2 then return 98 end
  if args[1] == "default" then
    return default_exit(args[2])
  elseif args[1] == "explicit" then
    return explicit_exit(args[2])
  elseif args[1] == "detached-child" then
    return detached_child_exit(args[2])
  elseif args[1] == "child" and #args == 4 then
    return child_exit(args[2], args[3], args[4])
  end
  return 97
end
]====]

local EXIT_CASES = [====[
local system = import "os"
local fs = import "fs"
local uv = import "uv"
local timer = import "timer"
local async = import "async"

local retained_file: fs.File? = nil
local retained_process: system.Process? = nil
local retained_stdout: uv.uv_stdio_t? = nil
local sibling: async.Task? = nil
local requester: async.Task? = nil
local coordinator_finally = false
local sibling_finally = false
local requester_finally = false
local requester_after_exit = false

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function wait_for_path(path: string)
  local attempts = 0
  local ready = false
  while not ready and attempts < 5000 do
    do
      fs.stat(path)
      ready = true
    catch
    end
    if not ready then timer.sleep(1) end
    attempts = attempts + 1
  end
  if not ready then raise "child did not publish its pid file" end
end

function schedule_exit(file_path: string, child: string,
                       pid_path: string): async.Task
  retained_file = nil
  retained_process = nil
  retained_stdout = nil
  sibling = nil
  requester = nil
  coordinator_finally = false
  sibling_finally = false
  requester_finally = false
  requester_after_exit = false

  return async.run(function (): value
    local file = fs.open(file_path, "w")
    retained_file = file
    file:write("live until embedded Runtime shutdown")
    retained_stdout = uv._os_parent_stdout()
    retained_process = system.spawn(child, { "ignore-term", pid_path })
    wait_for_path(pid_path)

    sibling = async.run(function (): value
      do
        timer.sleep(60000)
      finally
        sibling_finally = true
      end
      return nil
    end)
    requester = async.run(function (): value
      do
        timer.yield()
        system.exit(37)
        requester_after_exit = true
      finally
        requester_finally = true
      end
      return nil
    end)

    do
      timer.sleep(60000)
    finally
      coordinator_finally = true
    end
    return nil
  end)
end

local function status(task: async.Task?): string
  if not task then return "missing" end
  return task:status()
end

function sibling_status(): string
  return status(sibling)
end

function requester_status(): string
  return status(requester)
end

function finalizers_ran(): boolean
  return coordinator_finally and sibling_finally and requester_finally
end

function code_after_exit_ran(): boolean
  return requester_after_exit
end

function retained_file_is_closed(): boolean
  if not retained_file then return false end
  return retained_file:is_closed()
end

function schedule_next_generation(): async.Task
  return async.run(function (): value
    local stale = retained_stdout as uv.uv_stdio_t
    local rejected = false
    do
      uv._os_stdio_kind(stale)
    catch
      check(error == "stdio belongs to a stale libuv Runtime",
            "old parent stdio reported the wrong stale error")
      rejected = true
    end
    check(rejected, "old parent stdio survived a Runtime generation")
    local current = uv._os_parent_stdout()
    check(current ~= stale, "new Runtime reused the old stdio facade")
    local kind = uv._os_stdio_kind(current)
    check(kind == "tty" or kind == "stream",
          "new Runtime returned an unknown parent stdio kind")
    retained_stdout = current
    return "next-generation-ok"
  end)
end

function schedule_cleanup_failure(path: string): async.Task
  retained_file = nil
  return async.run(function (): value
    local file = fs.open(path, "w")
    retained_file = file
    file:write("cleanup failure owner")
    uv.__test_fail_next_exit_cleanup()
    system.exit(31)
    requester_after_exit = true
    return nil
  end)
end

function schedule_task_cleanup_failure(): async.Task
  return async.run(function (): value
    do
      system.exit(41)
    finally
      raise "injected exit Task cleanup failure"
    end
    return nil
  end)
end
]====]

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function count_plain(subject, needle)
    local count = 0
    local start = 1
    while true do
        local first = subject:find(needle, start, true)
        if not first then return count end
        count = count + 1
        start = first + #needle
    end
end

local function read_pid(path)
    local text = read_file(path)
    local digits = assert(text:match("^(%d+)%s*$"),
        "invalid child pid file: " .. text)
    local pid = assert(tonumber(digits))
    assert.truthy(pid > 1 and pid % 1 == 0, "invalid child pid")
    return pid
end

local function assert_pid_reaped(path)
    local pid = read_pid(path)
    local command = "kill -0 " .. string.format("%.0f", pid) ..
        " >/dev/null 2>&1"
    local alive, kind, status = os.execute(command)
    local diagnostic = "exit child was live/unreaped or kill probe failed: " ..
        tostring(alive) .. "/" .. tostring(kind) .. "/" .. tostring(status)
    assert.is_nil(alive, diagnostic)
    assert.equals("exit", kind, diagnostic)
    assert.equals(1, status, diagnostic)
end

describe("os.exit graceful Runtime shutdown", function()
    local workspace
    local layout
    local child

    setup(function()
        workspace, layout = async_stdlib.variant_workspace(
            "spec/support/make_exit_cleanup_failure_variant.lua", {
                facades = true,
            })

        async_stdlib.write_source(workspace, "titan.string", STRING_SUPPORT)
        async_stdlib.compile(workspace, "titan.string", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.string")

        async_stdlib.write_source(
            workspace, "titan.fs", async_stdlib.read("titan/fs.titan"))
        async_stdlib.compile(workspace, "titan.fs", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.fs")

        async_stdlib.write_source(
            workspace, "titan.os", async_stdlib.read("titan/os.titan"))
        async_stdlib.compile(workspace, "titan.os", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.os")

        child = os_support.process_child(workspace)
        async_stdlib.write_source(workspace, "os_exit_cases", EXIT_CASES)
        async_stdlib.compile(workspace, "os_exit_cases", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "os_exit_cases")
        async_stdlib.write_source(workspace, "os_exit_app", EXIT_APP)
        async_stdlib.compile(workspace, "os_exit_app", {
            layout = layout,
            cppflags = "",
        })
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run_app(...)
        local command = {
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_20=" .. quote(workspace),
            "TITAN_PATH=",
            quote(workspace .. "/os_exit_app"),
        }
        for _, argument in ipairs({ ... }) do
            command[#command + 1] = quote(argument)
        end
        return async_stdlib.run(table.concat(command, " "), workspace)
    end

    local function run_lua(source)
        local lua_path = workspace .. "/?.lua"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so"
        local command = table.concat({
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_20=" .. quote(workspace),
            "TITAN_PATH=",
            "LUA_PATH=" .. quote(lua_path),
            "LUA_PATH_5_5=" .. quote(lua_path),
            "LUA_CPATH=" .. quote(cpath),
            "LUA_CPATH_5_5=" .. quote(cpath),
            quote(LUA), "-e", quote(source),
        }, " ")
        local ok, status, output =
            async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("returns default and explicit statuses after main-Task cleanup",
    function()
        local default_marker = workspace .. "/default.marker"
        local ok, status, output =
            run_app("default", default_marker)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status)
        assert.equals("finally;defer;", read_file(default_marker))

        local explicit_marker = workspace .. "/explicit.marker"
        ok, status, output = run_app("explicit", explicit_marker)
        assert.equals(23, status, output)
        assert.equals("defer;", read_file(explicit_marker))
    end)

    it("lets a detached child request replace a completed main result",
    function()
        local marker = workspace .. "/detached-child.marker"
        local _, status, output = run_app("detached-child", marker)
        assert.equals(29, status, output)
        local markers = read_file(marker)
        assert.equals(1, count_plain(markers, "completed-main-defer;"),
            markers)
        assert.equals(1, count_plain(markers, "detached-finally;"), markers)
        assert.equals(0, count_plain(markers, "detached-after;"), markers)
    end)

    it("honors a child-Task request after settling Tasks and live owners",
    function()
        local marker = workspace .. "/child.marker"
        local pid_path = workspace .. "/child.pid"
        local _, status, output =
            run_app("child", marker, child, pid_path)
        assert.equals(27, status, output)

        local markers = read_file(marker)
        for _, token in ipairs({
            "sibling-finally;", "requester-finally;", "main-finally;",
        }) do
            assert.equals(1, count_plain(markers, token), markers)
        end
        assert.equals(0, count_plain(markers, "requester-after;"), markers)
        assert.equals(0, count_plain(markers, "main-after;"), markers)
        assert_pid_reaped(pid_path)
    end)

    it("returns to an embedding and supports a later Runtime generation",
    function()
        local file_path = workspace .. "/embedded-live-file"
        local pid_path = workspace .. "/embedded-child.pid"
        run_lua(table.concat({
            "local async = require 'titan.async'",
            "local cases = require 'os_exit_cases'",
            "local root = cases.schedule_exit(" ..
                string.format("%q", file_path) .. ", " ..
                string.format("%q", child) .. ", " ..
                string.format("%q", pid_path) .. ")",
            "local ok, failure = pcall(async.loop)",
            "assert(ok, failure)",
            "assert(root:status() == 'cancelled', root:status())",
            "assert(cases.sibling_status() == 'cancelled', " ..
                "cases.sibling_status())",
            "local requester = cases.requester_status()",
            "assert(requester == 'succeeded' or requester == 'cancelled', " ..
                "requester)",
            "assert(cases.finalizers_ran())",
            "assert(not cases.code_after_exit_ran())",
            "assert(cases.retained_file_is_closed())",
            "collectgarbage('collect')",
            "assert(('lua-state-alive'):sub(1, 3) == 'lua')",
            "local next_task = cases.schedule_next_generation()",
            "async.loop()",
            "assert(next_task:join() == 'next-generation-ok')",
        }, "\n"))
        assert_pid_reaped(pid_path)
    end)

    it("keeps cleanup failure fatal instead of returning requested status",
    function()
        local file_path = workspace .. "/cleanup-failure-file"
        run_lua(table.concat({
            "local async = require 'titan.async'",
            "local cases = require 'os_exit_cases'",
            "cases.schedule_cleanup_failure(" ..
                string.format("%q", file_path) .. ")",
            "local ok, failure = pcall(async.loop)",
            "assert(not ok, 'exit cleanup failure became success')",
            "local field_ok, message = pcall(function() " ..
                "return failure.message end)",
            "assert(field_ok and message == " ..
                "'injected exit cleanup failure', tostring(failure))",
            "local operation_ok, operation = pcall(function() " ..
                "return failure.operation end)",
            "assert(operation_ok and operation == 'fs.close', " ..
                "tostring(failure))",
            "assert(not cases.code_after_exit_ran())",
        }, "\n"))
    end)

    it("keeps an unobserved non-main cleanup failure fatal",
    function()
        run_lua(table.concat({
            "local async = require 'titan.async'",
            "local cases = require 'os_exit_cases'",
            "cases.schedule_task_cleanup_failure()",
            "local ok, failure = pcall(async.loop)",
            "assert(not ok, 'Task cleanup failure became exit success')",
            "assert(tostring(failure):find(" ..
                "'injected exit Task cleanup failure', 1, true), " ..
                "tostring(failure))",
        }, "\n"))
    end)
end)

-- Public titan.lua behavior is a standard-library integration suite and runs
-- outside LuaCov.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

local REPO = async_stdlib.repo
local LPEGLABEL_ARCHIVE =
    REPO .. "/lpeglabel-build/libtitan-lpeglabel.a"
local LPEGLABEL_CPPFLAGS = "-I" .. REPO .. "/vendor/lpeglabel"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local prefix = os.getenv("PREFIX")
local LUA = prefix and exists(prefix .. "/bin/lua")
    and prefix .. "/bin/lua" or "lua"

local PROBE_SOURCE = [[
local fs = import "fs"
local str = import "string"
local timer = import "timer"
local tlua = import "titan.lua"

local record TrackingReader
  local chunks: {string}
  local index: integer
  local closed: boolean
end

local function TrackingReader:read(): string?
  self.index = self.index + 1
  return self.chunks[self.index]
end

local function TrackingReader:read_until(_delimiter: string,
                                         _chop: boolean?): string?
  raise "unused read_until"
end

local function TrackingReader:close()
  self.closed = true
end

function reader_results(): (...: value)
  local reader = TrackingReader.new({
    "return 'left', nil, ",
    "'right'",
  }, 0, false)
  local chunk = tlua.load_from_reader(reader, "=reader", nil)
  if reader.closed then raise "load_from_reader closed its reader" end
  return chunk()
end

function empty_reader_result(): value
  local reader = TrackingReader.new({
    "", "return ", "", "'empty-chunks-ok'", "",
  }, 0, false)
  local chunk = tlua.load_from_reader(reader, "=empty-reader", nil)
  return chunk()
end

-- This reader receives bytes from one completed filesystem read, then makes
-- its second read an ordinary bounded async wait. The exported phase is a
-- test-only handshake: observing "waiting" proves load_from_reader consumed
-- the byte-bearing first result before cancellation is requested.
local blocking_phase = "idle"
local blocking_transformed = false

local record BlockingReader
  local bytes: string
  local index: integer
end

local function BlockingReader:read(): string?
  self.index = self.index + 1
  if self.index == 1 then return self.bytes end
  blocking_phase = "waiting"
  timer.sleep(5000)
  return nil
end

local function BlockingReader:read_until(_delimiter: string,
                                          _chop: boolean?): string?
  raise "unused read_until"
end

local function BlockingReader:close()
end

function blocking_source_phase(): string
  return blocking_phase
end

function blocking_source_transformed(): boolean
  return blocking_transformed
end

function load_blocking_source(path: string)
  blocking_phase = "opening"
  blocking_transformed = false
  local file = fs.open(path, "r")
  local file_open = true
  defer if file_open then file:close() end

  blocking_phase = "reading"
  local maybe_bytes? = file:read()
  if not maybe_bytes then raise "blocking source file was empty" end
  local bytes = maybe_bytes as string
  file:close()
  file_open = false
  blocking_phase = "consumed"

  local reader = BlockingReader.new(bytes, 0)
  do
    tlua.load_from_reader(reader, "@" .. path, nil)
  catch
    -- Match the source searcher's error translation boundary. Task
    -- cancellation remains authoritative over this transformed error.
    blocking_transformed = true
    raise "error loading module 'lua_spec_blocking' from file '" ..
          path .. "':\n\t" .. str.tostring(error)
  end
  raise "blocking source reader unexpectedly reached EOF"
end
]]

local REQUIRED_TITAN_SOURCE = [[
function answer(): integer
  return 42
end
]]

describe("titan.lua", function()
    local workspace
    local layout

    setup(function()
        assert.truthy(exists(LPEGLABEL_ARCHIVE),
            "run make lpeglabel before titan.lua specs")
        workspace = async_stdlib.workspace("lua")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.prepare_gc(workspace, layout)

        for _, name in ipairs({
            "peg", "native", "combinators", "relabel", "relabel_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.peg." .. name,
                async_stdlib.read("titan/peg/" .. name .. ".titan"))
        end
        async_stdlib.compile(workspace, "titan.peg", {
            layout = layout,
            cppflags = LPEGLABEL_CPPFLAGS,
            extra_objects = { LPEGLABEL_ARCHIVE },
        })
        async_stdlib.register_exact_provider(layout, "titan.peg")

        for _, name in ipairs({
            "string", "bytes", "format", "pack",
            "regex_api", "regex_compile", "regex_parser",
        }) do
            async_stdlib.write_source(
                workspace, "titan.string." .. name,
                async_stdlib.read("titan/string/" .. name .. ".titan"))
        end
        async_stdlib.compile(workspace, "titan.string", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.string")
        async_stdlib.prepare_async_core(workspace, layout)

        for _, name in ipairs({ "os", "io", "fs", "lua", "timer" }) do
            async_stdlib.write_source(
                workspace, "titan." .. name,
                async_stdlib.read("titan/" .. name .. ".titan"))
            async_stdlib.compile(workspace, "titan." .. name, {
                layout = layout,
                cppflags = "",
            })
            async_stdlib.register_exact_provider(layout, "titan." .. name)
        end

        async_stdlib.write_source(workspace, "lua_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "lua_probe", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.write_source(
            workspace, "lua_required_titan", REQUIRED_TITAN_SOURCE)
        async_stdlib.compile(workspace, "lua_required_titan", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "lua_required_titan")
    end)

    teardown(function()
        async_stdlib.cleanup(workspace)
    end)

    local function run(source, watchdog_seconds)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so;;"
        local command_words = {
            "env", "-u", "LUA_PATH", "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
            "TITAN_PATH_0_20=" .. workspace,
            "TITAN_PATH=",
            "LUA_PATH=" .. lua_path,
            "LUA_PATH_5_5=" .. lua_path,
            "LUA_CPATH=" .. cpath,
            "LUA_CPATH_5_5=" .. cpath,
            LUA, "-e", source,
        }
        local quoted_words = {}
        for index, word in ipairs(command_words) do
            quoted_words[index] = quote(word)
        end
        local command = table.concat(quoted_words, " ")
        if watchdog_seconds then
            -- Run the exact argv under a portable external watchdog. The env
            -- process execs Lua, so TERM/KILL always targets the process that
            -- owns stdout; even a broken async cancellation cannot leave
            -- async_stdlib.run's read("*a") waiting indefinitely.
            local watchdog = string.format([[
"$@" &
test_pid=$!
(
  delay_pid=
  trap 'if [ -n "$delay_pid" ]; then
          kill -TERM "$delay_pid" 2>/dev/null || :
        fi
        exit 0' TERM HUP INT
  sleep %d </dev/null >/dev/null 2>&1 &
  delay_pid=$!
  wait "$delay_pid"
  delay_pid=
  printf 'titan.lua fixture timed out after %d seconds\n' >&2
  kill -TERM "$test_pid" 2>/dev/null || exit 0
  sleep 2 </dev/null >/dev/null 2>&1 &
  delay_pid=$!
  wait "$delay_pid"
  delay_pid=
  kill -KILL "$test_pid" 2>/dev/null || :
) &
watchdog_pid=$!
wait "$test_pid"
test_status=$?
kill -TERM "$watchdog_pid" 2>/dev/null || :
wait "$watchdog_pid" 2>/dev/null || :
exit "$test_status"
]], watchdog_seconds, watchdog_seconds)
            command = "/bin/sh -c " .. quote(watchdog) ..
                " titan-lua-watchdog " .. command
        end
        local ok, status, output = async_stdlib.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    it("loads binary-safe chunks with flexible arguments and environments",
    function()
        run([[
local tlua = require "titan.lua"

local passthrough = tlua.load("return ...", "=passthrough", nil)
local values = table.pack(passthrough(1, nil, 3))
assert(values.n == 3)
assert(values[1] == 1 and values[2] == nil and values[3] == 3)

local binary = tlua.load('return "a\\0b"', "=binary", nil)
assert(binary() == "a\0b")

local nul_ok, nul_err = pcall(
    tlua.load, "return 1\0return 2", "=embedded-nul", nil)
assert(not nul_ok)
assert(tostring(nul_err):find("embedded-nul", 1, true), nul_err)

local dump_source = function(...) return ... end
assert(debug.getupvalue(dump_source, 1) == nil)
local dumped = string.dump(dump_source)
local dumped_values =
    table.pack(tlua.load(dumped, "=dumped", { ignored = true })(7, nil, 9))
assert(dumped_values.n == 3)
assert(dumped_values[1] == 7 and dumped_values[2] == nil and
    dumped_values[3] == 9)

local environment = { answer = 42 }
local scoped = tlua.load("return answer, _G", "=environment", environment)
local answer, global = scoped()
assert(answer == 42 and global == nil)
assert(tlua.load("return _G")() == _G)

local ok, err = pcall(tlua.load, "this is not Lua", "=named-load", nil)
assert(not ok)
assert(tostring(err):find("named-load", 1, true), err)
]])
    end)

    it("loads Reader chunks through EOF without closing the Reader", function()
        run([[
local async = require "titan.async"
local probe = require "lua_probe"
local completed = false
local task = async.run(function()
    local values = table.pack(probe.reader_results())
    assert(values.n == 3)
    assert(values[1] == "left" and values[2] == nil and
        values[3] == "right")

    assert(probe.empty_reader_result() == "empty-chunks-ok")
    completed = true
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(completed)
]])
    end)

    it("runs files with flexible arguments/results and closes on errors",
    function()
        local success = workspace .. "/dofile-success.lua"
        local runtime_error = workspace .. "/dofile-runtime-error.lua"
        local syntax_error = workspace .. "/dofile-syntax-error.lua"
        run(string.format([[
local async = require "titan.async"
local tlua = require "titan.lua"
local lfs = require "lfs"

local function open_fd_count()
    local count = 0
    for entry in lfs.dir("/dev/fd") do
        if entry:match("^%%d+$") then count = count + 1 end
    end
    return count
end

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

write(%q, "return ...")
write(%q, "error('runtime marker')")
write(%q, "this is not Lua")

local completed = false
local task = async.run(function()
    local values = table.pack(tlua.dofile(%q, 4, nil, 6))
    assert(values.n == 3)
    assert(values[1] == 4 and values[2] == nil and values[3] == 6)

    local runtime_ok, runtime_err = pcall(tlua.dofile, %q)
    assert(not runtime_ok)
    assert(tostring(runtime_err):find("runtime marker", 1, true), runtime_err)
    local syntax_ok, syntax_err = pcall(tlua.dofile, %q)
    assert(not syntax_ok)
    assert(tostring(syntax_err):find("dofile-syntax-error", 1, true),
        syntax_err)

    local baseline_fds = open_fd_count()
    for _ = 1, 24 do
        assert(not pcall(tlua.dofile, %q))
        assert(not pcall(tlua.dofile, %q))
    end
    local final_fds = open_fd_count()
    assert(final_fds <= baseline_fds + 2,
        ("dofile leaked descriptors: %%d -> %%d"):format(
            baseline_fds, final_fds))
    completed = true
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(completed)
assert(os.remove(%q))
assert(os.remove(%q))
assert(os.remove(%q))
]], success, runtime_error, syntax_error, success, runtime_error,
            syntax_error, runtime_error, syntax_error,
            success, runtime_error, syntax_error))
    end)

    it("preserves preload, cache, false reload, and fallback-true semantics",
    function()
        run([[
local tlua = require "titan.lua"

local calls = 0
package.preload["lua_spec.preloaded"] = function(name, data)
    calls = calls + 1
    assert(name == "lua_spec.preloaded" and data == ":preload:")
    return { calls = calls }
end
local first = tlua.require("lua_spec.preloaded")
assert(first.calls == 1)
assert(tlua.require("lua_spec.preloaded") == first)
assert(calls == 1)

package.preload["lua_spec.fallback"] = function() end
assert(tlua.require("lua_spec.fallback") == true)
assert(package.loaded["lua_spec.fallback"] == true)

local false_calls = 0
package.preload["lua_spec.false"] = function()
    false_calls = false_calls + 1
    return false
end
assert(tlua.require("lua_spec.false") == false)
assert(tlua.require("lua_spec.false") == false)
assert(false_calls == 2)
]])
    end)

    it("loads Lua source asynchronously and rejects a concurrent duplicate",
    function()
        local source = workspace .. "/lua_spec_source.lua"
        local concurrent = workspace .. "/lua_spec_concurrent.lua"
        local cancel_retry = workspace .. "/lua_spec_cancel_retry.lua"
        local cancel_source = workspace .. "/lua_spec_cancel_source.fifo"
        local blocking_source = workspace .. "/lua_spec_blocking.lua"
        local fifo_ok, fifo_status, fifo_output =
            async_stdlib.run("mkfifo " .. quote(cancel_source))
        assert.truthy(fifo_ok,
            "mkfifo exit " .. tostring(fifo_status) .. "\n" .. fifo_output)
        run(string.format([[
local async = require "titan.async"
local probe = require "lua_probe"
local tlua = require "titan.lua"
local timer = require "titan.timer"

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
local function active(task)
    return not task:status():has_finished()
end
write(%q, "return { name = ..., filename = select(2, ...) }")
write(%q, "return { loaded = true }")
write(%q, "return { retried = true }")
write(%q, "return { bounded = true }")
local cancel_source = %q

local phase = 0
local completed = false
local coordinator = async.run(function()
    phase = 1
    local observer = async.run(function()
        assert(phase == 1)
        phase = 2
    end)
    local result = tlua.require("lua_spec_source")
    assert(phase == 2)
    assert(observer:status():as_string() == "succeeded", observer:status():as_string())
    assert(result.name == "lua_spec_source")
    assert(result.filename == %q)
    assert(tlua.require("lua_spec_source") == result)

    local first_started = false
    local first_loaded = false
    local duplicate = ""
    local first = async.run(function()
        first_started = true
        local loaded = tlua.require("lua_spec_concurrent")
        first_loaded = loaded.loaded == true
    end)
    local second = async.run(function()
        while not first_started do timer.yield() end
        local ok, err = pcall(tlua.require, "lua_spec_concurrent")
        assert(not ok)
        duplicate = tostring(err)
    end)
    while active(first) or active(second) do timer.yield() end
    assert(first:status():as_string() == "succeeded", first:status():as_string())
    assert(second:status():as_string() == "succeeded", second:status():as_string())
    assert(first_loaded)
    assert(duplicate:find("already being loaded", 1, true), duplicate)

    -- First prove cancellation after a byte-bearing filesystem read has
    -- completed and load_from_reader has requested its next chunk. The probe's
    -- five-second fallback keeps this path bounded even if cancellation is not
    -- delivered; this whole child also has an external watchdog.
    local post_read = async.run(function()
        probe.load_blocking_source(%q)
    end)
    local probes = 0
    while probe.blocking_source_phase() ~= "waiting" and
          active(post_read) and probes < 5000 do
        timer.sleep(1)
        probes = probes + 1
    end
    local consumed_read = probe.blocking_source_phase() == "waiting"
    local post_read_waiting =
        post_read:status():as_string() == "waiting"
    if active(post_read) then post_read:cancel() end
    local post_cancel_waiting =
        post_read:status():as_string() == "waiting"
    while active(post_read) do timer.yield() end
    assert(consumed_read, probe.blocking_source_phase())
    assert(post_read_waiting, post_read:status():as_string())
    assert(post_cancel_waiting,
        "reader cancellation abandoned its accepted read")
    assert(post_read:status():as_string() == "cancelled",
        post_read:status():as_string())
    assert(probe.blocking_source_transformed(),
        "source wrapper did not transform the injected cancellation")

    local saved_path = package.path
    package.path = cancel_source
    local cancelled_started = false
    local cancelled = async.run(function()
        cancelled_started = true
        tlua.require("lua_spec_cancel_retry")
    end)
    local open_probes = 0
    while (not cancelled_started or
           cancelled:status():as_string() == "ready" or
           cancelled:status():as_string() == "running") and
          open_probes < 5000 do
        timer.sleep(1)
        open_probes = open_probes + 1
    end
    local reached_open_wait =
        cancelled_started and cancelled:status():as_string() == "waiting"
    if reached_open_wait then cancelled:cancel() end
    local open_cancel_waiting =
        cancelled:status():as_string() == "waiting"

    -- A waiting require has no earlier async boundary: its FIFO read-side open
    -- is already submitted. Only now is a synchronous writer opened, so this
    -- call has a guaranteed counterpart and cannot be the blocking edge that
    -- strands the test. Closing it supplies bounded EOF to the accepted open.
    if reached_open_wait then
        local source_writer = assert(io.open(cancel_source, "w"))
        assert(source_writer:close())
    end
    while active(cancelled) do timer.yield() end
    package.path = saved_path
    assert(reached_open_wait, cancelled:status():as_string())
    assert(open_cancel_waiting,
        "filesystem-open cancellation abandoned its accepted request")
    assert(cancelled:status():as_string() == "cancelled", cancelled:status():as_string())

    local retry = tlua.require("lua_spec_cancel_retry")
    assert(retry.retried == true)
    completed = true
end)
async.loop()
assert(coordinator:status():as_string() == "succeeded", coordinator:status():as_string())
assert(completed)
assert(os.remove(%q))
assert(os.remove(cancel_source))
]], source, concurrent, cancel_retry, blocking_source, cancel_source,
            source, blocking_source, cancel_retry), 20)
    end)

    it("loads Titan shims, C modules, and appended custom searchers", function()
        run([[
local async = require "titan.async"
local tlua = require "titan.lua"

local completed = false
local task = async.run(function()
    local titan_module = tlua.require("lua_required_titan")
    assert(titan_module.answer() == 42)

    package.loaded.lfs = nil
    local lfs = tlua.require("lfs")
    assert(type(lfs.attributes) == "function")

    local source_slot = package.searchers[2]
    package.searchers[2] = function()
        error("synchronous source searcher was called")
    end
    local custom_index = #package.searchers + 1
    package.searchers[custom_index] = function(name)
        if name ~= "lua_spec.custom" then return "custom miss" end
        return function(modname, data)
            assert(modname == name and data == "custom-data")
            return "custom-result"
        end, "custom-data"
    end
    local custom = tlua.require("lua_spec.custom")
    package.searchers[custom_index] = nil
    package.searchers[2] = source_slot
    assert(custom == "custom-result")
    completed = true
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(completed)
]])
    end)

    it("reports accumulated asynchronous source and searcher misses", function()
        run([[
local async = require "titan.async"
local tlua = require "titan.lua"
local completed = false
local task = async.run(function()
    local saved_path = package.path
    local custom_index = #package.searchers + 1
    package.path = "/titan-lua-spec/first/?/again/?.lua;" ..
        "/titan-lua-spec/second/?/init.lua"
    package.searchers[custom_index] = function()
        return "custom diagnostic last"
    end
    local ok, err = pcall(tlua.require, "lua_spec.definitely_missing")
    package.searchers[custom_index] = nil
    package.path = saved_path
    assert(not ok)
    local message = tostring(err)
    assert(message:find("module 'lua_spec.definitely_missing' not found", 1,
        true), message)
    local first = assert(message:find(
        "no file '/titan-lua-spec/first/lua_spec/definitely_missing/" ..
        "again/lua_spec/definitely_missing.lua'", 1, true))
    local second = assert(message:find(
        "no file '/titan-lua-spec/second/lua_spec/definitely_missing/" ..
        "init.lua'", 1, true))
    local custom = assert(message:find("custom diagnostic last", 1, true))
    assert(first < second and second < custom, message)
    completed = true
end)
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(completed)
]])
    end)
end)

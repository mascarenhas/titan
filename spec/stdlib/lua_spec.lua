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
        async_stdlib.prepare_async_core(workspace, layout)
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

    local function run(source)
        local lua_path = workspace .. "/?.lua;;"
        local cpath = workspace .. "/?.so;" ..
            workspace .. "/titan-runtime/bootstrap/?.so;;"
        local command = table.concat({
            "env -u LUA_PATH -u LUA_CPATH" ..
                " -u LUA_PATH_5_5 -u LUA_CPATH_5_5",
            "TITAN_PATH_0_20=" .. quote(workspace),
            "TITAN_PATH=",
            "LUA_PATH=" .. quote(lua_path),
            "LUA_PATH_5_5=" .. quote(lua_path),
            "LUA_CPATH=" .. quote(cpath),
            "LUA_CPATH_5_5=" .. quote(cpath),
            quote(LUA) .. " -e " .. quote(source),
        }, " ")
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
local task = async.run(function()
    local values = table.pack(probe.reader_results())
    assert(values.n == 3)
    assert(values[1] == "left" and values[2] == nil and
        values[3] == "right")

    assert(probe.empty_reader_result() == "empty-chunks-ok")
    return true
end)
async.loop()
assert(task:join() == true)
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
    return true
end)
async.loop()
assert(task:join() == true)
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
        run(string.format([[
local async = require "titan.async"
local tlua = require "titan.lua"
local timer = require "titan.timer"

local function write(path, contents)
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
write(%q, "return { name = ..., filename = select(2, ...) }")
write(%q, "return { loaded = true }")
write(%q, "return { retried = true }")

local phase = 0
local source_task = async.run(function()
    phase = 1
    local observer = async.run(function()
        assert(phase == 1)
        phase = 2
        return true
    end)
    local result = tlua.require("lua_spec_source")
    assert(phase == 2)
    observer:join()
    assert(result.name == "lua_spec_source")
    assert(result.filename == %q)
    assert(tlua.require("lua_spec_source") == result)
    return true
end)
async.loop()
assert(source_task:join() == true)

local first = async.run(function()
    return tlua.require("lua_spec_concurrent")
end)
local second = async.run(function()
    local ok, err = pcall(tlua.require, "lua_spec_concurrent")
    assert(not ok)
    return tostring(err)
end)
async.loop()
assert(first:join().loaded == true)
local duplicate = second:join()
assert(duplicate:find("already being loaded", 1, true), duplicate)

local saved_path = package.path
package.path = "/dev/zero"
local cancelled = async.run(function()
    return tlua.require("lua_spec_cancel_retry")
end)
local canceller = async.run(function()
    timer.sleep(10)
    cancelled:cancel("cancel-source-read")
    return true
end)
async.loop()
package.path = saved_path
assert(canceller:join() == true)
local cancel_ok, cancel_err = pcall(cancelled.join, cancelled)
assert(not cancel_ok)
assert(cancelled:status() == "cancelled", tostring(cancel_err))
assert(cancel_err.reason == "cancel-source-read")

local retry = async.run(function()
    return tlua.require("lua_spec_cancel_retry")
end)
async.loop()
assert(retry:join().retried == true)
assert(os.remove(%q))
]], source, concurrent, cancel_retry, source, cancel_retry))
    end)

    it("loads Titan shims, C modules, and appended custom searchers", function()
        run([[
local async = require "titan.async"
local tlua = require "titan.lua"

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
    return true
end)
async.loop()
assert(task:join() == true)
]])
    end)

    it("reports accumulated asynchronous source and searcher misses", function()
        run([[
local async = require "titan.async"
local tlua = require "titan.lua"
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
    return true
end)
async.loop()
assert(task:join() == true)
]])
    end)
end)

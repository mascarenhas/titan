-- Public titan.io behavior is a standard-library integration suite and runs
-- outside LuaCov.
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"

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

-- Keep the pure print/lines contract independent of libuv. These exact test
-- providers expose the same nominal surface that titan.io consumes while also
-- recording conversion and write calls for assertions that ordinary output
-- redirection cannot observe precisely.
local STRING_SUPPORT = [[
local conversions = ""

record StringWriter
  local contents: string
end

function writer(): StringWriter
  return StringWriter.new("")
end

function StringWriter:write(data: string)
  self.contents = self.contents .. data
end

function StringWriter:drain(): string
  local result = self.contents
  self.contents = ""
  return result
end

function StringWriter:close()
end

function tostring(candidate: value): string
  local result = candidate as string
  if #conversions > 0 then conversions = conversions .. "|" end
  conversions = conversions .. result
  if result == "!conversion-error!" then raise "conversion failure" end
  return "<" .. result .. ">"
end

function _test_reset()
  conversions = ""
end

function _test_conversions(): string
  return conversions
end
]]

local OS_SUPPORT = [[
record ExitStatus
  code: integer
  signal: string?
  signal_number: integer
end

record SpawnConfig
end

type SpawnOption = (SpawnConfig) -> integer

record InputStream
end

function InputStream:read(): string? return nil end
function InputStream:read_until(_delimiter: string,
                                _chop: boolean?): string? return nil end
function InputStream:close() end
function InputStream:is_tty(): boolean return false end

record OutputStream
  local contents: string
  local writes: integer
end

function OutputStream:write(data: string)
  self.contents = self.contents .. data
  self.writes = self.writes + 1
end

function OutputStream:close() end
function OutputStream:is_tty(): boolean return false end

record Process
  local running: boolean
  stdin: OutputStream?
  stdout: InputStream?
  stderr: InputStream?
end

function Process:wait(): ExitStatus
  self.running = false
  return ExitStatus.new(0, nil, 0)
end

function Process:kill(_signal: string)
  self.running = false
end

function Process:is_running(): boolean return self.running end

stdin: InputStream = InputStream.new()
stdout: OutputStream = OutputStream.new("", 0)
stderr: OutputStream = OutputStream.new("", 0)

function with_stdin(_config: SpawnConfig): integer return 0 end
function with_stdout(_config: SpawnConfig): integer return 0 end
function with_stderr(_config: SpawnConfig): integer return 0 end
function with_parent_stdin(_config: SpawnConfig): integer return 0 end
function with_parent_stdout(_config: SpawnConfig): integer return 0 end
function with_parent_stderr(_config: SpawnConfig): integer return 0 end
function with_merged_output(_config: SpawnConfig): integer return 0 end

function spawn(_file: string, _args: {string},
               ...: SpawnOption): Process
  local config = SpawnConfig.new()
  local index = 1
  while index <= #... do
    local option = ...[index]
    if option(config) < 0 then raise "spawn option failed" end
    index = index + 1
  end
  return Process.new(
    true, OutputStream.new("", 0), InputStream.new(), InputStream.new())
end

function _test_output(): OutputStream
  return OutputStream.new("", 0)
end

function _test_contents(output: OutputStream): string
  return output.contents
end

function _test_writes(output: OutputStream): integer
  return output.writes
end
]]

local PROBE_SOURCE = [[
local io = import "io"
local os = import "os"
local str = import "string"

function print_values(): (string, string, integer)
  str._test_reset()
  local output = os._test_output()
  os.stdout = output
  io.print("first", "second", "third")
  return str._test_conversions(), os._test_contents(output),
         os._test_writes(output)
end

function print_empty(): (string, integer)
  local output = os._test_output()
  os.stdout = output
  io.print()
  return os._test_contents(output), os._test_writes(output)
end

function print_conversion_failure(): (boolean, string, integer)
  str._test_reset()
  local output = os._test_output()
  os.stdout = output
  local failed = false
  do
    io.print("before", "!conversion-error!", "after")
  catch
    failed = error == "conversion failure"
  end
  return failed, str._test_conversions(), os._test_writes(output)
end

function print_uses_current_stdout(): (string, string)
  local first = os._test_output()
  local second = os._test_output()
  os.stdout = first
  io.print("one")
  os.stdout = second
  io.print("two")
  return os._test_contents(first), os._test_contents(second)
end
]]

describe("titan.io exact print host boundary", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("io")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.refresh_private_runtime(workspace)
        async_stdlib.write_source(workspace, "titan.string", STRING_SUPPORT)
        async_stdlib.compile(workspace, "titan.string", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.string")
        async_stdlib.write_source(workspace, "titan.os", OS_SUPPORT)
        async_stdlib.compile(workspace, "titan.os", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.os")
        async_stdlib.write_source(
            workspace, "titan.io", async_stdlib.read("titan/io.titan"))
        async_stdlib.compile(workspace, "titan.io", {
            layout = layout,
            cppflags = "",
        })
        async_stdlib.register_exact_provider(layout, "titan.io")
        async_stdlib.write_source(workspace, "io_probe", PROBE_SOURCE)
        async_stdlib.compile(workspace, "io_probe", {
            layout = layout,
            cppflags = "",
        })
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
            "TITAN_PATH_0_22=" .. quote(workspace),
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

    it("converts left to right and emits exactly one current-stdout write",
    function()
        run([[
local probe = require "io_probe"

local conversions, output, writes = probe.print_values()
assert(conversions == "first|second|third")
assert(output == "<first>\t<second>\t<third>\n")
assert(writes == 1)

local empty, empty_writes = probe.print_empty()
assert(empty == "\n" and empty_writes == 1)

local failed, attempted, failure_writes = probe.print_conversion_failure()
assert(failed and attempted == "before|!conversion-error!")
assert(failure_writes == 0)

local first, second = probe.print_uses_current_stdout()
assert(first == "<one>\n" and second == "<two>\n")
]])
    end)
end)

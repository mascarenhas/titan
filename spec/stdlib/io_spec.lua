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

local record TrackingReader
  local input: {string}
  local position: integer
  local reads: integer
  local closes: integer
  local fail_read_at: integer
  local fail_close: boolean
  local closed: boolean
end

local function TrackingReader:read(): string?
  raise "io.lines called Reader:read"
end

local function TrackingReader:read_until(delimiter: string,
                                         chop: boolean?): string?
  if delimiter ~= "\n" or not chop then
    raise "io.lines changed its delimiter contract"
  end
  if self.closed then return nil end
  self.reads = self.reads + 1
  if self.reads == self.fail_read_at then raise "read failure" end
  self.position = self.position + 1
  if self.position > #self.input then return nil end
  return self.input[self.position]
end

local function TrackingReader:close()
  if self.closed then return end
  self.closes = self.closes + 1
  if self.fail_close then raise "close failure" end
  self.closed = true
end

local function tracking(input: {string}, fail_read_at: integer,
                        fail_close: boolean): TrackingReader
  return TrackingReader.new(
    input, 0, 0, 0, fail_read_at, fail_close, false)
end

function exhaustion(): (string, string, string, integer, integer)
  local reader = tracking({ "alpha", "", "omega" }, -1, false)
  local output: {string} = {}
  for line: string in io.lines(reader) do
    output[#output + 1] = line
  end
  return output[1] as string, output[2] as string, output[3] as string,
         reader.reads, reader.closes
end

function break_close(): (integer, integer)
  local reader = tracking({ "first", "second" }, -1, false)
  for _line: string in io.lines(reader) do
    break
  end
  return reader.reads, reader.closes
end

function body_error_close(): integer
  local reader = tracking({ "line" }, -1, false)
  do
    for _line: string in io.lines(reader) do
      raise "body failure"
    end
  catch
    if error ~= "body failure" then raise end
  end
  return reader.closes
end

function read_error_close(): integer
  local reader = tracking({ "first", "second" }, 2, false)
  do
    for _line: string in io.lines(reader) do
    end
  catch
    if error ~= "read failure" then raise end
  end
  return reader.closes
end

local function return_from_loop(reader: TrackingReader): string
  for line: string in io.lines(reader) do
    return line
  end
  return ""
end

function return_close(): (string, integer)
  local reader = tracking({ "returned" }, -1, false)
  return return_from_loop(reader), reader.closes
end

function close_error_retries(): (boolean, integer)
  local reader = tracking({}, -1, true)
  local matched = false
  do
    for _line: string in io.lines(reader) do
    end
  catch
    matched = error == "close failure"
  end
  return matched, reader.closes
end

function tuple_and_manual_close(): (boolean, integer)
  local reader = tracking({ "manual", "must-not-be-read" }, -1, false)
  local next_line, state, initial, close = io.lines(reader)
  local line: string? = next_line(state)
  close(state)
  close(state)
  local after_close: string? = next_line(state)
  return initial == nil and line == "manual" and not after_close,
         reader.closes
end

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

describe("titan.io lines", function()
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

    it("iterates lines and reaches an idempotent terminal close", function()
        run([[
local probe = require "io_probe"

local first, empty, last, reads, closes = probe.exhaustion()
assert(first == "alpha" and empty == "" and last == "omega")
assert(reads == 4 and closes == 1)

reads, closes = probe.break_close()
assert(reads == 1 and closes == 1)
assert(probe.body_error_close() == 1)
assert(probe.read_error_close() == 1)

local returned, return_closes = probe.return_close()
assert(returned == "returned" and return_closes == 1)

local matched, close_error_calls = probe.close_error_retries()
assert(matched and close_error_calls == 2)

local shape, manual_closes = probe.tuple_and_manual_close()
assert(shape and manual_closes == 1)
]])
    end)

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

local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"
local os_support = require "spec.support.os_test_support"

local NATIVE_FIXTURES = async_stdlib.repo ..
    "/spec/fixtures/stdlib/native"

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function append_shell_words(argv, words, label)
    local parsed, err = cdriver.split_shell_words(words or "")
    assert.is_table(parsed, label .. ": " .. tostring(err))
    for _, word in ipairs(parsed) do argv[#argv + 1] = word end
end

local function compile_stdio_probe(workspace)
    local object = workspace .. "/uv_stdio_probe.o"
    local argv = {"env", "CCACHE_DISABLE=1"}
    append_shell_words(argv, os.getenv("CC") or "cc", "CC")
    for _, word in ipairs({
        "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror", "-fPIC",
        "-I" .. NATIVE_FIXTURES,
        "-c", NATIVE_FIXTURES .. "/uv_stdio_probe.c", "-o", object,
    }) do
        argv[#argv + 1] = word
    end
    append_shell_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
                       "TITAN_TEST_EXTRA_CFLAGS")
    for index, word in ipairs(argv) do argv[index] = shell_quote(word) end
    local ok, _, output =
        async_stdlib.run(table.concat(argv, " "), workspace)
    assert.truthy(ok, output)
    return object
end

local PROCESS_STDIO_CASES = [====[
local probe = foreign import "uv_stdio_probe.h"
local async = import "async"
local system = import "os"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function required_input(candidate: system.InputStream?,
                              label: string): system.InputStream
  if not candidate then raise label .. " was not captured" end
  return candidate as system.InputStream
end

local function required_output(candidate: system.OutputStream?,
                               label: string): system.OutputStream
  if not candidate then raise label .. " was not captured" end
  return candidate as system.OutputStream
end

local function read_all(stream: system.InputStream): string
  local result = ""
  while true do
    local chunk? = stream:read()
    if not chunk then return result end
    result = result .. (chunk as string)
  end
end

local function normal(process: system.Process, label: string)
  local status = process:wait()
  check(status.code == 0 and status.signal_number == 0,
        label .. " did not exit normally")
end

local function setup(mode: integer)
  check(probe.titan_uv_test_stdio_setup(mode) == 0,
        probe.titan_uv_test_stdio_failure() as string)
end

local function finish(nonblocking_mask: integer): (string, string)
  check(probe.titan_uv_test_stdio_finish(nonblocking_mask) == 0,
        probe.titan_uv_test_stdio_failure() as string)
  return probe.titan_uv_test_stdio_output(1) as string,
         probe.titan_uv_test_stdio_output(2) as string
end

function result(): string
  return outcome
end

function captured_stdout(): string
  return probe.titan_uv_test_stdio_output(1) as string
end

function start_parent_inheritance(): async.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return async.run(function (): value
    local process = system.spawn(
        "/bin/sh", {"-c", ":"},
        system.with_parent_stdin, system.with_parent_stdout,
        system.with_parent_stderr)
    check(not process.stdin and not process.stdout and not process.stderr,
          "inherited descriptors exposed captured endpoints")
    normal(process, "inherited low-level child")
    outcome = "parent-inheritance-ready"
    return nil
  end)
end

function finish_parent_inheritance()
  finish(0)
  outcome = "parent-inheritance-ok"
end

function start_parent_pipes(): async.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return async.run(function (): value
    check(not system.stdin:is_tty() and
          not system.stdout:is_tty() and
          not system.stderr:is_tty(),
          "pipe parent stdio was misclassified")
    check(read_all(system.stdin) == "parent-pipe-input",
          "parent stdin changed bytes")
    system.stdout:write("pipe-stdout")
    system.stderr:write("pipe-stderr")
    outcome = "parent-pipes-ready"
    return nil
  end)
end

function finish_parent_pipes()
  local output, diagnostics = finish(7)
  check(output == "pipe-stdout" and diagnostics == "pipe-stderr",
        "parent pipe output changed")
  outcome = "parent-pipes-ok"
end

local function reject_parent_stdout(mode: integer,
                                    expected: string): async.Task
  outcome = "running"
  setup(mode)
  return async.run(function (): value
    local warm = system.spawn("/bin/sh", {"-c", ":"})
    required_output(warm.stdin, "warm stdin"):close()
    local warm_stdout = required_input(warm.stdout, "warm stdout")
    local warm_stderr = required_input(warm.stderr, "warm stderr")
    read_all(warm_stdout)
    read_all(warm_stderr)
    normal(warm, "warm child")
    warm_stdout:close()
    warm_stderr:close()
    async.yield()

    local before = probe.titan_uv_test_stdio_open_fd_count()
    check(before >= 0, "could not count descriptors before rejection")
    local rejected = false
    do
      local process = system.spawn(
          "/bin/sh", {"-c", ":"}, system.with_parent_stdout)
      if process.stdin then
        (process.stdin as system.OutputStream):close()
      end
      if process.stdout then
        (process.stdout as system.InputStream):close()
      end
      if process.stderr then
        (process.stderr as system.InputStream):close()
      end
      process:wait()
    catch
      rejected = true
    end
    check(rejected, "unsupported parent stdout was accepted")
    check(probe.titan_uv_test_stdio_open_fd_count() == before,
          "parent stdout rejection leaked a descriptor")
    outcome = expected
    return nil
  end)
end

function start_parent_file_rejection(): async.Task
  return reject_parent_stdout(probe.TITAN_UV_TEST_STDIO_FILE_STDOUT,
                              "parent-file-rejected")
end

function start_parent_socket_rejection(): async.Task
  return reject_parent_stdout(probe.TITAN_UV_TEST_STDIO_SOCKET_STDOUT,
                              "parent-socket-rejected")
end

function finish_parent_rejection()
  finish(0)
end

function start_parent_tty(): async.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_TTY_SLAVE)
  return async.run(function (): value
    check(system.stdout:is_tty(),
          "PTY stdout was not classified as a TTY")
    system.stdout:write("tty-output")
    outcome = "parent-tty-ready"
    return nil
  end)
end

function finish_parent_tty()
  local output, _diagnostics = finish(0)
  check(output == "tty-output", "TTY output changed")
  outcome = "parent-tty-ok"
end
]====]

describe("uv process and stdio adapter", function()
    local workspace

    setup(function()
        workspace = os_support.workspace("uv-process-stdio-direct")
        local probe = compile_stdio_probe(workspace)
        os_support.write_source(workspace, "uv_process_stdio_cases",
                                PROCESS_STDIO_CASES)
        os_support.compile(workspace, "uv_process_stdio_cases", {
            cppflags = "-I" .. NATIVE_FIXTURES,
            extra_objects = {probe},
        })
    end)

    teardown(function()
        os_support.cleanup(workspace)
    end)

    local function run(source)
        local ok, status, output =
            os_support.run_lua_source(workspace, source)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end

    local function run_parent(start_name, finish_name, expected)
        run(([==[
local async = require "titan.async"
local cases = require "uv_process_stdio_cases"
local task = assert(cases.%s())
local loop_ok, loop_error = pcall(async.loop)
local finish_ok, finish_error = pcall(cases.%s)
if not loop_ok then error(loop_error, 0) end
if not finish_ok then
  local captured = cases.captured_stdout()
  error(("%%s\ncaptured stdout (%%d bytes): %%q"):format(
        tostring(finish_error), #captured, captured), 0)
end
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(cases.result() == %q, cases.result())
]==]):format(start_name, finish_name, expected))
    end

    it("classifies and transfers parent pipe stdio", function()
        run_parent("start_parent_pipes", "finish_parent_pipes",
                   "parent-pipes-ok")
    end)

    it("inherits only prepared parent streams", function()
        run_parent("start_parent_inheritance",
                   "finish_parent_inheritance", "parent-inheritance-ok")
    end)

    it("classifies and transfers a portable pseudo-terminal", function()
        run_parent("start_parent_tty", "finish_parent_tty",
                   "parent-tty-ok")
    end)

    it("rejects regular-file parent stdio without leaking", function()
        run_parent("start_parent_file_rejection",
                   "finish_parent_rejection", "parent-file-rejected")
    end)

    it("rejects socket parent stdio without leaking", function()
        run_parent("start_parent_socket_rejection",
                   "finish_parent_rejection", "parent-socket-rejected")
    end)
end)

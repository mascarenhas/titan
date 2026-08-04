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
local uv = import "uv"

local outcome = "not-run"

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function configured(status: integer, label: string)
  check(status == 0, label .. " spawn option failed")
end

local function default_config(): uv.uv_spawn_config
  local config = uv._os_spawn_config_new()
  configured(uv._os_spawn_config_with_stdin(config), "stdin")
  configured(uv._os_spawn_config_with_stdout(config), "stdout")
  configured(uv._os_spawn_config_with_stderr(config), "stderr")
  return config
end

local function required(candidate: uv.uv_stdio_t?,
                        label: string): uv.uv_stdio_t
  if not candidate then raise label .. " was not captured" end
  return candidate as uv.uv_stdio_t
end

local function read_all(stdio: uv.uv_stdio_t): string
  local result = ""
  for chunk in uv._os_stdio_read, stdio do result = result .. chunk end
  return result
end

local function normal(process: uv.uv_process_t, label: string)
  local code, signal_number = uv._os_process_wait(process)
  check(code == 0 and signal_number == 0,
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

function start_processes(child: string): uv.Task
  outcome = "running"
  return uv._run(function (): value
    local process, raw_stdin?, raw_stdout?, raw_stderr? =
      uv._os_process_spawn_with_config(
        child, {"echo"}, default_config())
    local stdin = required(raw_stdin, "stdin")
    local stdout = required(raw_stdout, "stdout")
    local stderr = required(raw_stderr, "stderr")
    local payload = "low\0level\nstream"
    uv._os_stdio_write(stdin, payload)
    uv._os_stdio_close(stdin)
    check(read_all(stdout) == payload,
          "low-level process stream changed binary bytes")
    check(read_all(stderr) == "", "low-level echo child wrote stderr")
    normal(process, "low-level echo")
    uv._os_stdio_close(stdout)
    uv._os_stdio_close(stderr)

    local merged_config = default_config()
    configured(uv._os_spawn_config_with_merged_output(merged_config),
               "merged output")
    local merged, merged_stdin?, raw_merged_stdout?, raw_merged_stderr? =
      uv._os_process_spawn_with_config(
        child, {"dual", "32"}, merged_config)
    uv._os_stdio_close(required(merged_stdin, "merged stdin"))
    local merged_stdout = required(raw_merged_stdout, "merged stdout")
    local merged_stderr = required(raw_merged_stderr, "merged stderr")
    check(merged_stdout == merged_stderr,
          "merged low-level output used two owners")
    check(#read_all(merged_stdout) == 64,
          "merged low-level output returned the wrong byte count")
    normal(merged, "merged low-level child")

    local half_merged_config = default_config()
    configured(uv._os_spawn_config_with_merged_output(half_merged_config),
               "half-merged initial output")
    configured(uv._os_spawn_config_with_stdout(half_merged_config),
               "half-merged final stdout")
    local half_merged, half_merged_stdin?, raw_half_stdout?,
          raw_half_stderr? = uv._os_process_spawn_with_config(
      child, {"early-output-exit"}, half_merged_config)
    uv._os_stdio_close(required(half_merged_stdin, "half-merged stdin"))
    local half_stdout = required(raw_half_stdout, "half-merged stdout")
    local half_stderr = required(raw_half_stderr, "half-merged stderr")
    check(half_stdout ~= half_stderr,
          "replacing one merged output kept one shared owner")
    check(read_all(half_stdout) == "early\0stdout" and
          read_all(half_stderr) == "early\0stderr",
          "half-merged output changed or retained the child endpoint")
    local half_code, half_signal = uv._os_process_wait(half_merged)
    check(half_code == 23 and half_signal == 0,
          "half-merged process status changed")

    local separate_config = default_config()
    configured(uv._os_spawn_config_with_merged_output(separate_config),
               "initial merge")
    configured(uv._os_spawn_config_with_stdout(separate_config),
               "final stdout capture")
    configured(uv._os_spawn_config_with_stderr(separate_config),
               "final stderr capture")
    local separate, separate_stdin?, raw_separate_stdout?,
          raw_separate_stderr? = uv._os_process_spawn_with_config(
      child, {"early-output-exit"}, separate_config)
    uv._os_stdio_close(required(separate_stdin, "separate stdin"))
    local separate_stdout = required(
      raw_separate_stdout, "separate stdout")
    local separate_stderr = required(
      raw_separate_stderr, "separate stderr")
    check(separate_stdout ~= separate_stderr,
          "final separate captures retained merged identity")
    check(read_all(separate_stdout) == "early\0stdout" and
          read_all(separate_stderr) == "early\0stderr",
          "final separate captures changed output")
    local code, signal_number = uv._os_process_wait(separate)
    check(code == 23 and signal_number == 0,
          "low-level process status changed")

    outcome = "processes-ok"
    return nil
  end)
end

function start_parent_inheritance(): uv.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return uv._run(function (): value
    local config = default_config()
    configured(uv._os_spawn_config_with_parent_stdin(config),
               "parent stdin")
    configured(uv._os_spawn_config_with_parent_stdout(config),
               "parent stdout")
    configured(uv._os_spawn_config_with_parent_stderr(config),
               "parent stderr")
    local process, inherited_stdin?, inherited_stdout?, inherited_stderr? =
      uv._os_process_spawn_with_config(
        "/bin/sh", {"-c", ":"}, config)
    check(not inherited_stdin and not inherited_stdout and
          not inherited_stderr,
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

function start_parent_pipes(): uv.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return uv._run(function (): value
    local input = uv._os_parent_stdin()
    local output = uv._os_parent_stdout()
    local diagnostics = uv._os_parent_stderr()
    check(not uv._os_stdio_is_tty(input) and
          not uv._os_stdio_is_tty(output) and
          not uv._os_stdio_is_tty(diagnostics),
          "pipe parent stdio was misclassified")
    check(read_all(input) == "parent-pipe-input",
          "parent stdin changed bytes")
    uv._os_stdio_write(output, "pipe-stdout")
    uv._os_stdio_write(diagnostics, "pipe-stderr")
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
                                    expected: string): uv.Task
  outcome = "running"
  setup(mode)
  return uv._run(function (): value
    local before = probe.titan_uv_test_stdio_open_fd_count()
    check(before >= 0, "could not count descriptors before rejection")
    local config = uv._os_spawn_config_new()
    local status = uv._os_spawn_config_with_parent_stdout(config)
    uv._os_spawn_config_close(config)
    check(status < 0, "unsupported parent stdout was accepted")
    check(probe.titan_uv_test_stdio_open_fd_count() == before,
          "parent stdout rejection leaked a descriptor")
    outcome = expected
    return nil
  end)
end

function start_parent_file_rejection(): uv.Task
  return reject_parent_stdout(probe.TITAN_UV_TEST_STDIO_FILE_STDOUT,
                              "parent-file-rejected")
end

function start_parent_socket_rejection(): uv.Task
  return reject_parent_stdout(probe.TITAN_UV_TEST_STDIO_SOCKET_STDOUT,
                              "parent-socket-rejected")
end

function finish_parent_rejection()
  finish(0)
end

function start_parent_tty(): uv.Task
  outcome = "running"
  setup(probe.TITAN_UV_TEST_STDIO_TTY_SLAVE)
  return uv._run(function (): value
    local output = uv._os_parent_stdout()
    check(uv._os_stdio_is_tty(output),
          "PTY stdout was not classified as a TTY")
    uv._os_stdio_write(output, "tty-output")
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
    local child

    setup(function()
        workspace = os_support.workspace("uv-process-stdio-direct")
        child = os_support.process_child(workspace)
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

    it("submits process calls and applies final stdio choices", function()
        run(([==[
local async = require "titan.async"
local cases = require "uv_process_stdio_cases"
local task = assert(cases.start_processes(%q))
async.loop()
assert(task:status():as_string() == "succeeded", task:status():as_string())
assert(cases.result() == "processes-ok", cases.result())
]==]):format(child))
    end)

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

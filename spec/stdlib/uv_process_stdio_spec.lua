local cdriver = require "c-parser.cdriver"
local async_stdlib = require "spec.support.async_stdlib"

local NATIVE_FIXTURES = async_stdlib.repo .. "/spec/fixtures/stdlib/native"

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
    local argv = { "env", "CCACHE_DISABLE=1" }
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
    local ok, _, output = async_stdlib.run(table.concat(argv, " "), workspace)
    assert.truthy(ok, output)
    return object
end

local CASES = [====[
local uv = import "uv"
local lua = foreign import "lua.h"
local probe = foreign import "uv_stdio_probe.h"

local retained_stdout: uv.uv_stdio_t? = nil
local retained_config: uv.uv_spawn_config? = nil

local function check(condition: boolean, message: string)
  if not condition then raise message end
end

local function configured(status: integer, label: string)
  check(status == 0, label .. " spawn option failed")
end

local function default_spawn_config(): uv.uv_spawn_config
  local config = uv._os_spawn_config_new()
  configured(uv._os_spawn_config_with_stdin(config), "default stdin")
  configured(uv._os_spawn_config_with_stdout(config), "default stdout")
  configured(uv._os_spawn_config_with_stderr(config), "default stderr")
  return config
end

local function failure(): string
  return probe.titan_uv_test_stdio_failure() as string
end

local function setup(mode: integer)
  check(probe.titan_uv_test_stdio_setup(mode) == 0, failure())
end

local function finish(nonblocking_mask: integer): (string, string)
  check(probe.titan_uv_test_stdio_finish(nonblocking_mask) == 0,
        failure())
  return probe.titan_uv_test_stdio_output(1) as string,
         probe.titan_uv_test_stdio_output(2) as string
end

local function read_stdio_all(stdio: uv.uv_stdio_t): string
  local result = ""
  for chunk in uv._os_stdio_read, stdio do
    result = result .. chunk
  end
  return result
end

local function close_optional(stream: uv.uv_stdio_t?)
  if stream then uv._os_stdio_close(stream) end
end

local function check_wait(process: uv.uv_process_t, label: string)
  local code, signal_number = uv._os_process_wait(process)
  check(code == 0 and signal_number == 0, label .. " child failed")
end

local function drain_optional(stream: uv.uv_stdio_t?): string
  if not stream then return "" end
  return read_stdio_all(stream)
end

function open_fd_count(): integer
  return probe.titan_uv_test_stdio_open_fd_count() as integer
end

function schedule_noop(): uv.Task
  return uv._run(function (): value
    return nil
  end)
end

function schedule_pipe_stdio(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return uv._run(function (): value
    local input = uv._os_parent_stdin()
    local output = uv._os_parent_stdout()
    local diagnostics = uv._os_parent_stderr()
    check(uv._os_stdio_kind(input) == "stream" and
          uv._os_stdio_kind(output) == "stream" and
          uv._os_stdio_kind(diagnostics) == "stream",
          "pipe stdio was not classified as a stream")
    check(not uv._os_stdio_is_tty(input) and
          not uv._os_stdio_is_tty(output) and
          not uv._os_stdio_is_tty(diagnostics),
          "pipe stdio was classified as a TTY")
    check(read_stdio_all(input) == "parent-pipe-input",
          "parent pipe stdin changed bytes")
    uv._os_stdio_write(output, "pipe-stdout")
    uv._os_stdio_write(diagnostics, "pipe-stderr")
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    return nil
  end)
end

function finish_pipe_stdio()
  local output, diagnostics = finish(7)
  check(output == "pipe-stdout", "parent pipe stdout changed bytes")
  check(diagnostics == "pipe-stderr", "parent pipe stderr changed bytes")
end

function schedule_file_stdout_rejection(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_FILE_STDOUT)
  return uv._run(function (): value
    local rejected = false
    do
      uv._os_parent_stdout()
    catch
      local failure = error as uv.Error
      check(failure.operation == "parent.stdout.classify",
            "regular stdout reported the wrong operation")
      rejected = true
    end
    check(rejected, "regular stdout was accepted as process stdio")
    return nil
  end)
end

function finish_file_stdout_rejection()
  local output, _diagnostics = finish(0)
  check(output == "", "rejected regular stdout changed bytes")
end

function schedule_socket_stdout_rejection(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_SOCKET_STDOUT)
  return uv._run(function (): value
    local rejected = false
    do
      uv._os_parent_stdout()
    catch
      local failure = error as uv.Error
      check(failure.operation == "parent.stdout.classify",
            "TCP stdout reported the wrong operation")
      rejected = true
    end
    check(rejected, "TCP socket stdout was accepted as process stdio")
    return nil
  end)
end

function finish_socket_stdout_rejection()
  local output, _diagnostics = finish(0)
  check(output == "", "rejected TCP stdout changed bytes")
end

function schedule_tty_stdout(master: boolean): uv.Task
  local mode = probe.TITAN_UV_TEST_STDIO_TTY_SLAVE
  if master then mode = probe.TITAN_UV_TEST_STDIO_TTY_MASTER end
  setup(mode)
  return uv._run(function (): value
    local output = uv._os_parent_stdout()
    check(uv._os_stdio_kind(output) == "tty" and
          uv._os_stdio_is_tty(output),
          "PTY stdout was not classified as a TTY")
    if master then
      uv._os_stdio_write(output, "tty-master")
    else
      uv._os_stdio_write(output, "tty-slave")
    end
    return nil
  end)
end

function finish_tty_stdout(master: boolean)
  local output, _diagnostics = finish(0)
  if master then
    check(output == "tty-master",
          "TTY fallback changed bytes to '" .. output .. "'")
  else
    check(output == "tty-slave",
          "slave TTY changed bytes to '" .. output .. "'")
  end
end

function schedule_cancelled_parent_read(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_BLOCKED_STDIN)
  return uv._run(function (): value
    local input = uv._os_parent_stdin()
    local reader = uv._run(function (): value
      return uv._os_stdio_read(input)
    end)
    uv._yield()
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    reader:cancel("cancel-parent-read")
    local caught = false
    do
      reader:join()
    catch
      local cancelled = error as uv.Cancelled
      check(cancelled.reason == "cancel-parent-read",
            "parent-read cancellation reason changed")
      caught = true
    end
    check(caught and reader:status() == "cancelled",
          "blocked parent read did not cancel")
    return nil
  end)
end

function finish_cancelled_parent_read()
  finish(1)
end

function schedule_generation_one(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_OUTPUT_PIPES)
  return uv._run(function (): value
    retained_stdout = uv._os_parent_stdout()
    local config = uv._os_spawn_config_new()
    retained_config = config
    configured(uv._os_spawn_config_with_merged_output(config),
               "retained merged config")
    uv._os_stdio_write(retained_stdout as uv.uv_stdio_t, "generation-one")
    return nil
  end)
end

function schedule_generation_two(): uv.Task
  return uv._run(function (): value
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
    local stale_config = retained_config as uv.uv_spawn_config
    check(uv._os_spawn_config_with_stdin(stale_config) < 0,
          "old SpawnConfig survived a Runtime generation")
    local current = uv._os_parent_stdout()
    check(current ~= stale, "new Runtime reused the old stdio facade")
    uv._os_stdio_write(current, "generation-two")
    return nil
  end)
end

function finish_generations()
  local output, _diagnostics = finish(2)
  check(output == "generation-onegeneration-two",
        "sequential Runtime generations changed output")
  retained_stdout = nil
  retained_config = nil
end

local function check_streams(process: uv.uv_process_t,
                             stdin_present: boolean,
                             stdout_present: boolean,
                             stderr_present: boolean):
                             (uv.uv_stdio_t?, uv.uv_stdio_t?, uv.uv_stdio_t?)
  local input? = uv._os_process_stdin(process)
  local output? = uv._os_process_stdout(process)
  local diagnostics? = uv._os_process_stderr(process)
  check((not not input) == stdin_present and
        (not not output) == stdout_present and
        (not not diagnostics) == stderr_present,
        "spawn configuration exposed the wrong optional endpoints")
  return input, output, diagnostics
end

function schedule_inherited_tty_stdout(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_TTY_SLAVE)
  return uv._run(function (): value
    local config = default_spawn_config()
    configured(uv._os_spawn_config_with_parent_stdout(config),
               "inherited TTY stdout")
    local process = uv._os_process_spawn_with_config(
        "/bin/sh", { "-c", "printf inherited-tty" }, config)
    local input?, output?, diagnostics? = check_streams(
        process, true, false, true)
    close_optional(input)
    check(not output and drain_optional(diagnostics) == "",
          "inherited TTY exposed or changed captured streams")
    check_wait(process, "inherited TTY")
    return nil
  end)
end

function finish_inherited_tty_stdout()
  local output, diagnostics = finish(0)
  check(output == "inherited-tty",
        "inherited TTY changed child bytes to '" .. output .. "'")
  check(diagnostics == "", "inherited TTY child wrote unexpected stderr")
end

function schedule_inherited_endpoints(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_PIPE_ALL)
  return uv._run(function (): value
    local config = default_spawn_config()
    configured(uv._os_spawn_config_with_parent_stdin(config), "parent stdin")
    configured(uv._os_spawn_config_with_parent_stdout(config), "parent stdout")
    configured(uv._os_spawn_config_with_parent_stderr(config), "parent stderr")
    local process = uv._os_process_spawn_with_config("/bin/cat", {}, config)
    check_streams(process, false, false, false)
    check_wait(process, "fully inherited")
    return nil
  end)
end

function finish_inherited_endpoints()
  local output, diagnostics = finish(0)
  check(output == "parent-pipe-input",
        "inherited stdin/stdout changed bytes")
  check(diagnostics == "", "inherited child wrote unexpected stderr")
end

function schedule_spawn_config_ordering(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_OUTPUT_PIPES)
  return uv._run(function (): value
    local rejected = default_spawn_config()
    -- Creating the first native handle may lazily initialize libuv's loop
    -- backend. Measure after setup so those Runtime-owned descriptors are not
    -- mistaken for abandoned SpawnConfig endpoints.
    local descriptors_before =
      probe.titan_uv_test_stdio_open_fd_count() as integer
    configured(uv._os_spawn_config_with_merged_output(rejected),
               "rejected merged output")
    configured(uv._os_spawn_config_with_merged_output(rejected),
               "repeated rejected merged output")
    check(probe.titan_uv_test_stdio_open_fd_count() as integer ==
            descriptors_before + 2,
          "merged option deferred its pipe setup until spawn")
    local rejected_status = false
    do
      uv._os_spawn_config_error(rejected, -1)
    catch
      rejected_status = true
    end
    check(rejected_status and
          probe.titan_uv_test_stdio_open_fd_count() as integer ==
            descriptors_before,
          "rejected spawn configuration leaked descriptors")

    -- A later merge forces stdout back to capture and publishes one owner.
    local parent_then_merge = default_spawn_config()
    configured(uv._os_spawn_config_with_parent_stdout(parent_then_merge),
               "parent before merge")
    configured(uv._os_spawn_config_with_parent_stdout(parent_then_merge),
               "repeated parent before merge")
    configured(uv._os_spawn_config_with_merged_output(parent_then_merge),
               "merge after parent")
    configured(uv._os_spawn_config_with_merged_output(parent_then_merge),
               "repeated merge after parent")
    local merged = uv._os_process_spawn_with_config(
        "/bin/sh", { "-c", "printf A; printf B >&2" }, parent_then_merge)
    local input?, output?, diagnostics? = check_streams(
        merged, true, true, true)
    check(output == diagnostics, "merged streams did not share one facade")
    close_optional(input)
    check(read_stdio_all(output as uv.uv_stdio_t) == "AB",
          "parent-then-merge changed output")
    check(not uv._os_stdio_read(diagnostics as uv.uv_stdio_t),
          "merged EOF was not shared")
    check_wait(merged, "parent-then-merge")

    -- A later parent-stdout choice clears the stale merge relation and leaves
    -- stderr as its own capture.
    local merge_then_parent = default_spawn_config()
    configured(uv._os_spawn_config_with_merged_output(merge_then_parent),
               "merge before parent")
    configured(uv._os_spawn_config_with_parent_stdout(merge_then_parent),
               "parent after merge")
    configured(uv._os_spawn_config_with_parent_stdout(merge_then_parent),
               "repeated parent after merge")
    local split = uv._os_process_spawn_with_config(
        "/bin/sh", { "-c", "printf C; printf D >&2" }, merge_then_parent)
    local split_input?, split_output?, split_error? = check_streams(
        split, true, false, true)
    close_optional(split_input)
    check(not split_output and drain_optional(split_error) == "D",
          "merge-then-parent did not restore separate stderr capture")
    check_wait(split, "merge-then-parent")

    -- Repeated capture choices remain declarative and allocate one final set.
    local repeated_capture = default_spawn_config()
    configured(uv._os_spawn_config_with_parent_stdout(repeated_capture),
               "parent before capture")
    configured(uv._os_spawn_config_with_stdout(repeated_capture),
               "capture after parent")
    configured(uv._os_spawn_config_with_stdout(repeated_capture),
               "repeated capture after parent")
    local captured = uv._os_process_spawn_with_config(
        "/bin/sh", { "-c", "printf E" }, repeated_capture)
    check(uv._os_spawn_config_with_stdout(repeated_capture) < 0,
          "consumed spawn configuration accepted another option")
    local captured_input?, captured_output?, captured_error? = check_streams(
        captured, true, true, true)
    close_optional(captured_input)
    check(drain_optional(captured_output) == "E" and
          drain_optional(captured_error) == "",
          "repeated capture changed streams")
    check_wait(captured, "repeated capture")

    -- The same last-option rule applies independently to stderr.
    local merge_then_stderr = default_spawn_config()
    configured(uv._os_spawn_config_with_merged_output(merge_then_stderr),
               "merge before parent stderr")
    configured(uv._os_spawn_config_with_parent_stderr(merge_then_stderr),
               "parent stderr after merge")
    configured(uv._os_spawn_config_with_parent_stderr(merge_then_stderr),
               "repeated parent stderr after merge")
    local inherited_error = uv._os_process_spawn_with_config(
        "/bin/sh", { "-c", "printf G; printf F >&2" }, merge_then_stderr)
    local error_input?, error_output?, error_stream? = check_streams(
        inherited_error, true, true, false)
    close_optional(error_input)
    check(drain_optional(error_output) == "G" and not error_stream,
          "merge-then-parent-stderr retained a stale merge")
    check_wait(inherited_error, "merge-then-parent-stderr")
    return nil
  end)
end

function finish_spawn_config_ordering()
  local output, diagnostics = finish(0)
  check(output == "C", "parent stdout inheritance changed bytes")
  check(diagnostics == "F", "parent stderr inheritance changed bytes")
end

function schedule_multiple_borrowing_children(): uv.Task
  setup(probe.TITAN_UV_TEST_STDIO_OUTPUT_PIPES)
  return uv._run(function (): value
    local output = uv._os_parent_stdout()
    uv._os_stdio_write(output, "parent-before")
    for index = 1, 2 do
      local config = default_spawn_config()
      configured(uv._os_spawn_config_with_parent_stdout(config),
                 "borrowing parent stdout")
      local child = uv._os_process_spawn_with_config(
          "/bin/sh", { "-c", "printf child-" .. index }, config)
      local input?, child_output?, diagnostics? = check_streams(
          child, true, false, true)
      close_optional(input)
      check(not child_output and drain_optional(diagnostics) == "",
            "borrowing child exposed or changed stdout")
      check_wait(child, "borrowing")
    end
    -- libuv makes inherited child stdio blocking on the shared open-file
    -- description. Parent stream writes remain valid and may complete
    -- synchronously under that documented policy.
    uv._os_stdio_write(output, "parent-after")
    return nil
  end)
end

function finish_multiple_borrowing_children()
  local output, diagnostics = finish(0)
  check(output == "parent-beforechild-1child-2parent-after",
        "multiple children damaged or closed borrowed stdout")
  check(diagnostics == "", "borrowing children wrote unexpected stderr")
end

function schedule_merged_reader_lock(): uv.Task
  return uv._run(function (): value
    local config = default_spawn_config()
    configured(uv._os_spawn_config_with_merged_output(config),
               "merged reader")
    local process = uv._os_process_spawn_with_config("/bin/cat", {}, config)
    local input?, output?, diagnostics? = check_streams(
        process, true, true, true)
    local output = output as uv.uv_stdio_t
    local diagnostics = diagnostics as uv.uv_stdio_t
    check(output == diagnostics, "merged output did not share identity")
    local reader = uv._run(function (): value
      return uv._os_stdio_read(output)
    end)
    uv._yield()
    local locked = false
    do
      uv._os_stdio_read(diagnostics)
    catch
      check(error == "process pipe already has a waiting reader",
            "merged second reader reported the wrong error")
      locked = true
    end
    check(locked, "merged facade admitted two readers")
    lua.lua_gc(L, lua.LUA_GCGEN)
    lua.lua_gc(L, lua.LUA_GCCOLLECT)
    uv._os_stdio_write(input as uv.uv_stdio_t, "merged-reader")
    uv._os_stdio_close(input as uv.uv_stdio_t)
    check(reader:join() == "merged-reader",
          "merged reader changed child output")
    check(not uv._os_stdio_read(diagnostics), "merged EOF was not sticky")
    check_wait(process, "merged-reader")
    return nil
  end)
end
]====]

describe("uv process configuration and parent stdio", function()
    local workspace
    local layout

    setup(function()
        workspace = async_stdlib.workspace("process-stdio")
        layout = async_stdlib.exact_layout(workspace)
        async_stdlib.prepare_async_core(workspace, layout)
        async_stdlib.write_source(workspace, "uv_process_stdio_cases", CASES)
        local cppflags = async_stdlib.host_libuv_config()
        cppflags = cppflags .. " -I" .. NATIVE_FIXTURES
        local object = compile_stdio_probe(workspace)
        async_stdlib.compile(workspace, "uv_process_stdio_cases", {
            layout = layout,
            cppflags = cppflags,
            extra_objects = { object },
        })
    end)

    teardown(function() async_stdlib.cleanup(workspace) end)

    local function run_lua(source)
        local prelude = [==[
local function uv_stdio_fd_baseline(uv, cases)
    -- Libuv lazily creates process-global descriptors on the first loop run.
    -- Warm that state before comparing per-Runtime descriptor ownership.
    local warm = assert(cases.schedule_noop())
    uv._loop()
    assert(warm:join() == nil)
    return assert(cases.open_fd_count())
end

local function uv_stdio_run_and_finish(uv, task, finish)
    local ok, err = pcall(function()
        uv._loop()
        assert(task:join() == nil)
    end)
    local finish_ok, finish_err = true, nil
    if finish then
        finish_ok, finish_err = pcall(finish)
    end
    if not ok then error(err, 0) end
    if not finish_ok then error(finish_err, 0) end
end
]==]
        local ok, status, output = async_stdlib.run_lua_source(
            workspace, prelude .. source, { layout = layout })
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
    end

    it("keeps descriptor duplication in Titan with header-only facts",
    function()
        local header = async_stdlib.read(
            async_stdlib.repo .. "/titan-runtime/titan/uv.h")
        local native = async_stdlib.read(
            async_stdlib.repo .. "/titan-runtime/titan_uv.c")
        local process = async_stdlib.read(
            async_stdlib.repo .. "/titan/uv/process.titan")
        assert.truthy(header:find(
            "TITAN_UVSHIM_HAS_F_DUPFD_CLOEXEC", 1, true))
        assert.truthy(header:find(
            "TITAN_UVSHIM_F_DUPFD_CLOEXEC", 1, true))
        assert.is_nil(native:find("titan_uvshim_dup_cloexec", 1, true))
        assert.is_nil(process:find("titan_uvshim_dup_cloexec", 1, true))
        assert.truthy(process:find("cfcntl.fcntl", 1, true))
        assert.truthy(process:find("cunistd.dup", 1, true))
    end)

    it("wraps pipe stdio without transferring fd ownership", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_pipe_stdio())
uv_stdio_run_and_finish(uv, task, cases.finish_pipe_stdio)
local current = assert(cases.open_fd_count())
assert(current == baseline,
       "pipe stdio descriptor count changed: " .. baseline .. " -> " .. current)
]==])
    end)

    it("rejects regular files as process stdio handles", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_file_stdout_rejection())
uv_stdio_run_and_finish(uv, task, cases.finish_file_stdout_rejection)
assert(cases.open_fd_count() == baseline,
       "rejected file stdio leaked descriptors")
]==])
    end)

    it("rejects TCP sockets as process stdio handles", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_socket_stdout_rejection())
uv_stdio_run_and_finish(uv, task, cases.finish_socket_stdout_rejection)
assert(cases.open_fd_count() == baseline,
       "rejected TCP stdio leaked descriptors")
]==])
    end)

    it("reopens slave TTYs and honors libuv's master fallback", function()
        for _, master in ipairs({ false, true }) do
            run_lua(([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_tty_stdout(%s))
uv_stdio_run_and_finish(uv, task, function()
    cases.finish_tty_stdout(%s)
end)
assert(cases.open_fd_count() == baseline, "TTY stdio leaked descriptors")
]==]):format(tostring(master), tostring(master)))
        end
    end)

    it("inherits the classified TTY stream rather than its raw fd", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_inherited_tty_stdout())
uv_stdio_run_and_finish(uv, task, cases.finish_inherited_tty_stdout)
assert(cases.open_fd_count() == baseline,
       "inherited TTY stdio leaked descriptors")
]==])
    end)

    it("detaches a cancelled parent read and drains shutdown", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_cancelled_parent_read())
uv_stdio_run_and_finish(uv, task, cases.finish_cancelled_parent_read)
assert(cases.open_fd_count() == baseline,
       "cancelled parent read leaked descriptors")
]==])
    end)

    it("rebinds parent stdio across Runtime generations", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local first = assert(cases.schedule_generation_one())
local ok, err = pcall(function()
    uv._loop()
    assert(first:join() == nil)
    local second = assert(cases.schedule_generation_two())
    uv._loop()
    assert(second:join() == nil)
end)
local finish_ok, finish_err = pcall(cases.finish_generations)
if not ok then error(err, 0) end
if not finish_ok then error(finish_err, 0) end
assert(cases.open_fd_count() == baseline,
       "sequential Runtime generations leaked descriptors")
]==])
    end)

    it("exposes nil endpoints for directly inherited descriptors", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_inherited_endpoints())
uv_stdio_run_and_finish(uv, task, cases.finish_inherited_endpoints)
assert(cases.open_fd_count() == baseline,
       "inherited stdio leaked descriptors")
]==])
    end)

    it("applies repeated spawn choices in final-option order", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_spawn_config_ordering())
uv_stdio_run_and_finish(uv, task, cases.finish_spawn_config_ordering)
assert(cases.open_fd_count() == baseline,
       "spawn configuration leaked descriptors")
]==])
    end)

    it("keeps parent stdio alive across multiple borrowing children",
    function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_multiple_borrowing_children())
uv_stdio_run_and_finish(uv, task, cases.finish_multiple_borrowing_children)
assert(cases.open_fd_count() == baseline,
       "borrowing children leaked descriptors")
]==])
    end)

    it("uses one owner and one reader lock for merged output", function()
        run_lua([==[
local uv = require "titan.uv"
local cases = require "uv_process_stdio_cases"
local baseline = uv_stdio_fd_baseline(uv, cases)
local task = assert(cases.schedule_merged_reader_lock())
uv_stdio_run_and_finish(uv, task, nil)
assert(cases.open_fd_count() == baseline,
       "merged process output leaked descriptors")
]==])
    end)
end)

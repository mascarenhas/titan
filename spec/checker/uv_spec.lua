local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local stdlib_checker = require "spec.support.stdlib_checker"

local function configure_foreign_headers()
    local cppflags = { "-Ilibuv-v1.52.1/include" }
    local uname = assert(io.popen("uname -s"))
    local host = assert(uname:read("*l"))
    uname:close()
    if host == "Linux" then table.insert(cppflags, "-D_GNU_SOURCE") end
    checker.configure_foreign_c({
        compiler = os.getenv("CC") or "cc",
        language_mode = "c99",
        cppflags = cppflags,
        compiler_include_dirs = { "titan-runtime", "lua-5.5.0/src" },
    })
end

local function check_uv()
    types.registry = {}
    driver.imported = {}
    return stdlib_checker.source_uv()
end

local function signature(modtype, name)
    local member = assert(modtype.members[name], "missing member " .. name)
    return types.tostring(member.type)
end

local function sorted_keys(table_value)
    local keys = {}
    for key in pairs(table_value) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    return keys
end

describe("uv public interface", function()
    setup(configure_foreign_headers)

    teardown(function()
        checker.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
    end)

    it("locks the public surface and keeps native controls private", function()
        local modtype = check_uv()
        assert.same({
            "Cancelled", "Error", "Task", "_fs_close", "_fs_flush",
            "_fs_is_closed", "_fs_list", "_fs_mkdir", "_fs_open",
            "_fs_read", "_fs_rename", "_fs_rmdir", "_fs_stat",
            "_fs_unlink", "_fs_write", "_net_accept", "_net_close",
            "_net_connect", "_net_eof_error", "_net_find",
            "_net_is_closed", "_net_listen", "_net_read",
            "_net_shutdown", "_net_slice", "_net_write", "_os_chdir",
            "_os_communicate", "_os_cwd", "_os_exepath", "_os_getenv",
            "_os_homedir",
            "_os_hostname", "_os_pid", "_os_ppid",
            "_os_process_close_stdin", "_os_process_kill",
            "_os_process_read_stderr", "_os_process_read_stdout",
            "_os_process_spawn", "_os_process_wait",
            "_os_process_write_stdin", "_os_setenv", "_os_signal_name",
            "_os_tmpdir", "_os_unsetenv", "_os_wait_signal", "_sleep",
            "_ticker", "_ticker_close", "_ticker_tick", "_yield", "loop",
            "run", "uv_file", "uv_process_t", "uv_tcp_t", "uv_timer_t",
            "version",
        }, sorted_keys(modtype.members))

        assert.equals("(() -> value) -> uv.Task", signature(modtype, "run"))
        assert.equals("() -> ()", signature(modtype, "loop"))
        assert.equals("() -> string", signature(modtype, "version"))
        assert.equals("(string) -> (integer, string, integer, integer, integer)",
            signature(modtype, "_fs_stat"))
        assert.equals("(string, string) -> uv.uv_file",
            signature(modtype, "_fs_open"))
        assert.equals("(uv.uv_file, integer) -> string?",
            signature(modtype, "_fs_read"))
        assert.equals("(uv.uv_file, string) -> integer",
            signature(modtype, "_fs_write"))
        assert.equals("(uv.uv_file) -> ()", signature(modtype, "_fs_flush"))
        assert.equals("(uv.uv_file) -> ()", signature(modtype, "_fs_close"))
        assert.equals("(uv.uv_file) -> boolean",
            signature(modtype, "_fs_is_closed"))
        assert.equals("(string) -> ()", signature(modtype, "_fs_mkdir"))
        assert.equals("(string) -> ()", signature(modtype, "_fs_unlink"))
        assert.equals("(string) -> ()", signature(modtype, "_fs_rmdir"))
        assert.equals("(string, string) -> ()",
            signature(modtype, "_fs_rename"))
        assert.equals("(string) -> { string }", signature(modtype, "_fs_list"))
        assert.equals("(string, integer) -> uv.uv_tcp_t",
            signature(modtype, "_net_connect"))
        assert.equals("(string, integer, integer) -> uv.uv_tcp_t",
            signature(modtype, "_net_listen"))
        assert.equals("(uv.uv_tcp_t, integer) -> string?",
            signature(modtype, "_net_read"))
        assert.equals("(uv.uv_tcp_t, string) -> ()",
            signature(modtype, "_net_write"))
        assert.equals("(uv.uv_tcp_t) -> ()",
            signature(modtype, "_net_shutdown"))
        assert.equals("(uv.uv_tcp_t) -> uv.uv_tcp_t",
            signature(modtype, "_net_accept"))
        assert.equals("(uv.uv_tcp_t) -> ()",
            signature(modtype, "_net_close"))
        assert.equals("(uv.uv_tcp_t) -> boolean",
            signature(modtype, "_net_is_closed"))
        assert.equals("(string, string) -> integer",
            signature(modtype, "_net_find"))
        assert.equals("(string, integer, integer) -> string",
            signature(modtype, "_net_slice"))
        assert.equals("(string, string, string) -> uv.Error",
            signature(modtype, "_net_eof_error"))
        assert.equals("(string) -> string?",
            signature(modtype, "_os_getenv"))
        assert.equals("(string, string) -> ()",
            signature(modtype, "_os_setenv"))
        assert.equals("(string) -> ()", signature(modtype, "_os_unsetenv"))
        assert.equals("() -> string", signature(modtype, "_os_cwd"))
        assert.equals("(string) -> ()", signature(modtype, "_os_chdir"))
        assert.equals(
            "(string, { string }, string?) -> (string, string, integer, integer)",
            signature(modtype, "_os_communicate"))
        for _, name in ipairs({
            "_os_homedir", "_os_tmpdir", "_os_hostname", "_os_exepath",
        }) do
            assert.equals("() -> string", signature(modtype, name))
        end
        assert.equals("() -> integer", signature(modtype, "_os_pid"))
        assert.equals("() -> integer", signature(modtype, "_os_ppid"))
        assert.equals("(string) -> string",
            signature(modtype, "_os_wait_signal"))
        assert.equals("(integer) -> string?",
            signature(modtype, "_os_signal_name"))
        assert.equals("(string, { string }) -> uv.uv_process_t",
            signature(modtype, "_os_process_spawn"))
        assert.equals("(uv.uv_process_t) -> (integer, integer)",
            signature(modtype, "_os_process_wait"))
        assert.equals("(uv.uv_process_t, string) -> ()",
            signature(modtype, "_os_process_kill"))
        assert.equals("(uv.uv_process_t, string) -> ()",
            signature(modtype, "_os_process_write_stdin"))
        assert.equals("(uv.uv_process_t) -> ()",
            signature(modtype, "_os_process_close_stdin"))
        assert.equals("(uv.uv_process_t, integer) -> string?",
            signature(modtype, "_os_process_read_stdout"))
        assert.equals("(uv.uv_process_t, integer) -> string?",
            signature(modtype, "_os_process_read_stderr"))
        assert.equals("(integer) -> ()", signature(modtype, "_sleep"))
        assert.equals("() -> ()", signature(modtype, "_yield"))
        assert.equals("(integer) -> uv.uv_timer_t",
            signature(modtype, "_ticker"))
        assert.equals("(uv.uv_timer_t) -> boolean",
            signature(modtype, "_ticker_tick"))
        assert.equals("(uv.uv_timer_t) -> ()",
            signature(modtype, "_ticker_close"))
        for _, name in ipairs({
            "Loop", "Runtime", "TimerControl", "DriveControl", "Request",
            "FsConstants", "Bytes", "Text", "Buffer", "Dirent",
            "FsStatResult", "FsOperation", "FsControl", "uv_fs_t",
            "TickerState", "SignalSpec", "SignalControl", "uv_signal_t",
            "ProcessControl", "PipeControl", "ProcessOperation",
            "ProcessRequestControl", "ProcessExitResult", "HelperGroup",
            "uv_pipe_t",
            "uv_pipe_write_t", "uv_process_grace_t",
            "timer_dispatch", "fs_dispatch", "signal_dispatch",
            "process_dispatch", "pipe_dispatch", "pipe_write_dispatch",
            "process_grace_dispatch",
            "UV_TAG", "active_runtime",
        }) do
            assert.falsy(modtype.members[name], name .. " leaked")
        end

        local task = assert(types.registry["uv.Task"])
        assert.equals(27, task.nfields)
        assert.equals(27, #task.fields)
        for _, field in ipairs(task.fields) do assert.is_true(field.islocal) end
        assert.same({ "cancel", "join", "status" }, sorted_keys(task.methods))

        local owner = assert(types.registry["uv.uv_timer_t"])
        assert.equals(8, owner.nfields)
        assert.equals(8, #owner.fields)
        for _, field in ipairs(owner.fields) do assert.is_true(field.islocal) end

        local signal = assert(types.registry["uv.uv_signal_t"])
        assert.equals(8, signal.nfields)
        assert.equals(8, #signal.fields)
        for _, field in ipairs(signal.fields) do
            assert.is_true(field.islocal)
        end

        local process = assert(types.registry["uv.uv_process_t"])
        assert.equals(8, process.nfields)
        assert.equals(8, #process.fields)
        for _, field in ipairs(process.fields) do
            assert.is_true(field.islocal)
        end

        local file = assert(types.registry["uv.uv_file"])
        assert.equals(15, file.nfields)
        assert.equals(15, #file.fields)
        for _, field in ipairs(file.fields) do assert.is_true(field.islocal) end

        local err = assert(types.registry["uv.Error"])
        assert.equals(5, err.nfields)
        assert.equals(5, #err.fields)
        for _, field in ipairs(err.fields) do assert.falsy(field.islocal) end

        local cancelled = assert(types.registry["uv.Cancelled"])
        assert.equals(1, cancelled.nfields)
        assert.equals("reason", cancelled.fields[1].name)
        assert.falsy(cancelled.fields[1].islocal)

        local serialized = types.serialize(modtype)
        assert.not_match("uv_loop_t", serialized, 1, true)
        assert.not_match("uv_timer_t %*", serialized)
        assert.not_match("uv_fs_t", serialized, 1, true)
        assert.not_match("uv_signal_t", serialized, 1, true)
        assert.not_match("uv_process_t %*", serialized)
        assert.not_match("TimerControl", serialized, 1, true)
        assert.not_match("SignalControl", serialized, 1, true)
        assert.not_match("ProcessControl", serialized, 1, true)
        assert.not_match("PipeControl", serialized, 1, true)
        assert.not_match("Request", serialized, 1, true)
        assert.not_match("dispatcher", serialized, 1, true)
        assert.truthy(serialized:find(
            "Record('uv.Task',{},{", 1, true), serialized)
    end)

    it("permits public error construction but not opaque native/Task forging",
    function()
        local function check_consumer(consumer)
            types.registry = {}
            driver.imported = {}
            local _, errors = checker.checkimport("consumer",
                driver.tableloader({
                    consumer = consumer,
                }, stdlib_checker.uv_imported(), {}))
            return table.concat(errors, "\n")
        end

        local private = check_consumer([[
            local uv = import "uv"
            function bad_task(): uv.Task return uv.Task.new() end
            function bad_owner(): uv.uv_timer_t return uv.uv_timer_t.new() end
            function bad_process(): uv.uv_process_t
              return uv.uv_process_t.new()
            end
            function bad_file(): uv.uv_file return uv.uv_file.new() end
            function bad_process_literal(): uv.uv_process_t return {} end
            function bad_process_field(process: uv.uv_process_t): value
              return process.handle
            end
            function bad_task_literal(): uv.Task return {} end
        ]])
        assert.match("invalid record function 'new'", private)
        assert.match("cannot construct record type 'uv%.uv_process_t' outside module 'uv' because it has local fields",
            private)
        assert.match("field 'handle' not found in record 'uv%.uv_process_t'",
            private)
        assert.match("cannot construct record type 'uv%.Task' outside module 'uv' because it has local fields",
            private)

        local errors = check_consumer([[
            local uv = import "uv"
            function good(): uv.Error
              return uv.Error.new(-1, "E", "message", "operation", nil)
            end
            function cancelled(): uv.Cancelled
              return uv.Cancelled.new("reason")
            end
        ]])
        assert.equals("", errors)
    end)
end)

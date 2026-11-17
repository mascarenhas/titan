require "titan-compiler.coder.core"
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"
local cdriver = require "c-parser.cdriver"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local browser_checks = dofile("scripts/browser_stdlib.lua")
local browser_fixtures = require "spec.support.browser_fixtures"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local module_symbols = require "spec.support.module_symbols"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local source_inventory = require "spec.support.source_inventory"
local staticmetadata = require "titan-compiler.staticmetadata"
local stdlib_objects = require "spec.support.stdlib_objects"
local _, close_contexts, resolver_options =
    require("spec.support.resolver_contexts")(driver)
after_each(close_contexts)

local UV_MAIN_SOURCE = "titan/uv/uv.native.titan"
local STDLIB_TYPES_FIXTURE =
"spec/fixtures/stdlib/titan_stdlib_types.lua"
local UV_TYPES_FIXTURE =
"spec/fixtures/libuv/titan_uv_types.lua"
local STDLIB_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "path", "peg", "string", "math", "lua", "iteration", "gc",
    "test", "reflect", "sqlite3", "json", "protobuf", "transfer", "thread",
}
local STDLIB_ROOTS = {
    "titan.coroutine", "titan.uv", "titan.async", "titan.timer",
    "titan.io", "titan.fs", "titan.net", "titan.ssl", "titan.url",
    "titan.http", "titan.websocket", "titan.os", "titan.path", "titan.peg", "titan.string", "titan.math",
    "titan.lua", "titan.iteration", "titan.gc", "titan.test", "titan.reflect",
    "titan.sqlite3", "titan.json", "titan.protobuf", "titan.transfer", "titan.thread",
}
local LPEGLABEL_INCLUDE =
    "-I" .. lfs.currentdir() .. "/vendor/lpeglabel"
local LLHTTP_NATIVE_INCLUDE =
    "-I" .. lfs.currentdir() .. "/llhttp-release-v9.4.3/include"
local SQLITE3_NATIVE_INCLUDE =
    "-I" .. lfs.currentdir() .. "/sqlite-autoconf-3530400"
local BUNDLED_OPENSSL_INCLUDES = table.concat({
    "-I" .. lfs.currentdir() .. "/openssl-build/include",
    "-I" .. lfs.currentdir() .. "/openssl-3.5.7/include",
    "-DOPENSSL_API_COMPAT=30000",
}, " ")
local HTTP_SSL_BUNDLED_PAYLOAD = table.concat({
    "llhttp-build/libtitan-llhttp.a",
    "sqlite3-build/libtitan-sqlite3.a",
    "openssl-build/libssl.a",
    "openssl-build/libcrypto.a",
}, " ")
local HTTP_SSL_SYSTEM_PAYLOAD =
    "llhttp-build/libtitan-llhttp.a sqlite3-build/libtitan-sqlite3.a"
local HTTP_FOREIGN_CALLBACKS = {
    { name = "llhttp_url_cb",    field = "url_callback", setting = "on_url" },
    { name = "llhttp_status_cb", field = "status_callback", setting = "on_status" },
    {
        name = "llhttp_header_field_cb",
        field = "header_field_callback",
        setting = "on_header_field"
    },
    {
        name = "llhttp_header_value_cb",
        field = "header_value_callback",
        setting = "on_header_value"
    },
    {
        name = "llhttp_header_value_complete_cb",
        field = "header_value_complete_callback",
        setting = "on_header_value_complete",
        no_data = true
    },
    {
        name = "llhttp_headers_complete_cb",
        field = "headers_complete_callback",
        setting = "on_headers_complete",
        no_data = true
    },
    { name = "llhttp_body_cb", field = "body_callback", setting = "on_body" },
    {
        name = "llhttp_message_complete_cb",
        field = "message_complete_callback",
        setting = "on_message_complete",
        no_data = true
    },
}
local STDLIB_CONTAINER = "titan.so"
local INSTALLED_STDLIB_CONTAINER = platform.windows and "titan.dll" or STDLIB_CONTAINER
local STDLIB_STATIC_ARCHIVE = "titan.a"
-- Reviewed loop callback ABI and native-only entry inventory. New entries require review.
local UV_FOREIGN_CALLBACKS = {
    { name = "getaddrinfo_callback", source = "titan/uv/dns.titan",
      record = "getaddrinfo_t", field = "handler", handler = "getaddrinfo_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer, result)" },
    { name = "getnameinfo_callback", source = "titan/uv/dns.titan",
      record = "getnameinfo_t", field = "handler", handler = "getnameinfo_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer, hostname, service)" },
    { name = "process_callback", source = "titan/uv/process.titan",
      record = "process_t", field = "handler", handler = "process_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, exit_status as lua_Integer, term_signal as lua_Integer)" },
    { name = "process_close_callback", source = "titan/uv/process.titan",
      record = "process_t", field = "close_handler", handler = "process_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "tcp_connection_callback", source = "titan/uv/stream_owners.titan",
      record = "tcp_t", field = "connection_handler", handler = "tcp_connection_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "tcp_alloc_callback", source = "titan/uv/stream_owners.titan",
      record = "tcp_t", field = "alloc_handler", handler = "tcp_alloc_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, suggested_size as lua_Integer, output)" },
    { name = "tcp_read_callback", source = "titan/uv/stream_owners.titan",
      record = "tcp_t", field = "read_handler", handler = "tcp_read_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, nread as lua_Integer, buffer)" },
    { name = "tcp_close_callback", source = "titan/uv/stream_owners.titan",
      record = "tcp_t", field = "close_handler", handler = "tcp_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "pipe_connection_callback", source = "titan/uv/stream_owners.titan",
      record = "pipe_t", field = "connection_handler", handler = "pipe_connection_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "pipe_alloc_callback", source = "titan/uv/stream_owners.titan",
      record = "pipe_t", field = "alloc_handler", handler = "pipe_alloc_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, suggested_size as lua_Integer, output)" },
    { name = "pipe_read_callback", source = "titan/uv/stream_owners.titan",
      record = "pipe_t", field = "read_handler", handler = "pipe_read_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, nread as lua_Integer, buffer)" },
    { name = "pipe_close_callback", source = "titan/uv/stream_owners.titan",
      record = "pipe_t", field = "close_handler", handler = "pipe_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "tty_alloc_callback", source = "titan/uv/stream_owners.titan",
      record = "tty_t", field = "alloc_handler", handler = "tty_alloc_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, suggested_size as lua_Integer, output)" },
    { name = "tty_read_callback", source = "titan/uv/stream_owners.titan",
      record = "tty_t", field = "read_handler", handler = "tty_read_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, nread as lua_Integer, buffer)" },
    { name = "tty_close_callback", source = "titan/uv/stream_owners.titan",
      record = "tty_t", field = "close_handler", handler = "tty_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "network_connect_callback", source = "titan/uv/stream_owners.titan",
      record = "connect_t", field = "handler", handler = "connect_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "network_write_callback", source = "titan/uv/stream_owners.titan",
      record = "write_t", field = "handler", handler = "write_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "network_shutdown_callback", source = "titan/uv/stream_owners.titan",
      record = "shutdown_t", field = "handler", handler = "shutdown_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "udp_alloc_callback", source = "titan/uv/udp.titan",
      record = "udp_t", field = "alloc_handler", handler = "udp_allocate", owner = "owner",
      call = "entry(L, module, handler, owner, loop, suggested, output)" },
    { name = "udp_recv_callback", source = "titan/uv/udp.titan",
      record = "udp_t", field = "recv_handler", handler = "udp_receive", owner = "owner",
      call = "entry(L, module, handler, owner, loop, nread, buffer, address, flags)" },
    { name = "udp_close_callback", source = "titan/uv/udp.titan",
      record = "udp_t", field = "close_handler", handler = "udp_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "udp_send_callback", source = "titan/uv/udp.titan",
      record = "udp_send_t", field = "handler", handler = "udp_sent", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status)" },
    { name = "timer_callback", source = "titan/uv/uv.native.titan",
      record = "timer_t", field = "handler", handler = "timer_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "timer_close_callback", source = "titan/uv/uv.native.titan",
      record = "timer_t", field = "close_handler", handler = "timer_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "fs_callback", source = "titan/uv/uv.native.titan",
      record = "fs_t", field = "handler", handler = "fs_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "work_after_callback", source = "titan/uv/uv.native.titan",
      record = "work_t", field = "handler", handler = "work_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer)" },
    { name = "walk_callback", source = "titan/uv/uv.native.titan",
      record = "loop_t", field = "walk_handler", handler = "walk_deliver", owner = "loop",
      call = "entry(L, module, handler, loop, native)" },
    { name = "idle_callback", source = "titan/uv/uv.native.titan",
      record = "idle_t", field = "handler", handler = "idle_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "idle_close_callback", source = "titan/uv/uv.native.titan",
      record = "idle_t", field = "close_handler", handler = "idle_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "prepare_callback", source = "titan/uv/uv.native.titan",
      record = "prepare_t", field = "handler", handler = "prepare_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "prepare_close_callback", source = "titan/uv/uv.native.titan",
      record = "prepare_t", field = "close_handler", handler = "prepare_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "check_callback", source = "titan/uv/uv.native.titan",
      record = "check_t", field = "handler", handler = "check_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "check_close_callback", source = "titan/uv/uv.native.titan",
      record = "check_t", field = "close_handler", handler = "check_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "async_callback", source = "titan/uv/uv.native.titan",
      record = "async_t", field = "handler", handler = "async_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "async_close_callback", source = "titan/uv/uv.native.titan",
      record = "async_t", field = "close_handler", handler = "async_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "signal_callback", source = "titan/uv/uv.native.titan",
      record = "signal_t", field = "handler", handler = "signal_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, signum as lua_Integer)" },
    { name = "signal_close_callback", source = "titan/uv/uv.native.titan",
      record = "signal_t", field = "close_handler", handler = "signal_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "poll_callback", source = "titan/uv/uv.native.titan",
      record = "poll_t", field = "handler", handler = "poll_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer, events as lua_Integer)" },
    { name = "poll_close_callback", source = "titan/uv/uv.native.titan",
      record = "poll_t", field = "close_handler", handler = "poll_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "random_callback", source = "titan/uv/uv.native.titan",
      record = "random_t", field = "handler", handler = "random_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer, buflen as lua_Integer)" },
    { name = "fs_event_callback", source = "titan/uv/uv.native.titan",
      record = "fs_event_t", field = "handler", handler = "fs_event_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, filename, events as lua_Integer, status as lua_Integer)" },
    { name = "fs_event_close_callback", source = "titan/uv/uv.native.titan",
      record = "fs_event_t", field = "close_handler", handler = "fs_event_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
    { name = "fs_poll_callback", source = "titan/uv/uv.native.titan",
      record = "fs_poll_t", field = "handler", handler = "fs_poll_deliver", owner = "owner",
      call = "entry(L, module, handler, owner, loop, status as lua_Integer, prev, curr)" },
    { name = "fs_poll_close_callback", source = "titan/uv/uv.native.titan",
      record = "fs_poll_t", field = "close_handler", handler = "fs_poll_closed", owner = "owner",
      call = "entry(L, module, handler, owner, loop)" },
}
-- Direct-call helpers may be inline, but each callback retains one canonical
-- out-of-line address in the module's complete native object set.
local UV_NATIVE_ENTRIES = {
    { name = "consume_spawn_pipes", source = "titan/uv/process.titan" },
    { name = "external_wake_drop_target_locked", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_free_core", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_unlink_pending", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_detach", source = "titan/uv/external_wake.titan" },
    { name = "native_external_wake_retain", source = "titan/uv/external_wake.titan" },
    { name = "native_external_wake_release", source = "titan/uv/external_wake.titan" },
    { name = "native_external_wake_notify", source = "titan/uv/external_wake.titan" },
    { name = "native_external_wake_unregister", source = "titan/uv/external_wake.titan" },
    { name = "native_external_wake_is_notified", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_reserve_native", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_activate_native", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_unregister_native", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_drain_native", source = "titan/uv/external_wake.titan" },
    { name = "external_wake_begin_close", source = "titan/uv/external_wake.titan" },
    { name = "native_mutex_lock", source = "titan/uv/sync.titan" },
    { name = "native_mutex_trylock", source = "titan/uv/sync.titan" },
    { name = "native_mutex_unlock", source = "titan/uv/sync.titan" },
    { name = "native_mutex_destroy", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_rdlock", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_tryrdlock", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_rdunlock", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_wrlock", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_trywrlock", source = "titan/uv/sync.titan" },
    { name = "native_rwlock_wrunlock", source = "titan/uv/sync.titan" },
    { name = "native_sem_post", source = "titan/uv/sync.titan" },
    { name = "native_sem_wait", source = "titan/uv/sync.titan" },
    { name = "native_sem_trywait", source = "titan/uv/sync.titan" },
    { name = "native_cond_signal", source = "titan/uv/sync.titan" },
    { name = "native_cond_broadcast", source = "titan/uv/sync.titan" },
    { name = "native_barrier_wait", source = "titan/uv/sync.titan" },
    { name = "native_cond_wait", source = "titan/uv/sync.titan" },
    { name = "native_cond_timedwait", source = "titan/uv/sync.titan" },
    { name = "native_key_get", source = "titan/uv/sync.titan" },
    { name = "native_key_set", source = "titan/uv/sync.titan" },
    { name = "native_once", source = "titan/uv/sync.titan" },
    { name = "native_thread_join", source = "titan/uv/threading.titan" },
    { name = "native_thread_detach", source = "titan/uv/threading.titan" },
    { name = "work_worker_callback", source = "titan/uv/uv.native.titan" },
    { name = "async_send_native", source = "titan/uv/uv.native.titan" },
}
local LEGACY_UV_CALLBACKS = {
    "titan_uvshim_signal_cb",
    "titan_uvshim_process_exit_cb",
    "titan_uvshim_getaddrinfo_cb",
    "titan_uvshim_connect_cb",
    "titan_uvshim_write_cb",
    "titan_uvshim_shutdown_cb",
    "titan_uvshim_alloc_cb",
    "titan_uvshim_read_cb",
    "titan_uvshim_connection_cb",
    "titan_uvshim_close_cb",
    "titan_uvshim_walk_cb",
    "titan_uvshim_timer_cb",
    "titan_uvshim_fs_cb",
}
local DIRECT_LIBUV_CALLS = {
    "uv_accept",
    "uv_close",
    "uv_freeaddrinfo",
    "uv_fs_get_result",
    "uv_fs_get_statbuf",
    "uv_getaddrinfo",
    "uv_handle_set_data",
    "uv_is_closing",
    "uv_listen",
    "uv_pipe_init",
    "uv_queue_work",
    "uv_read_start",
    "uv_read_stop",
    "uv_req_set_data",
    "uv_shutdown",
    "uv_signal_init",
    "uv_signal_start_oneshot",
    "uv_tcp_init_ex",
    "uv_tcp_bind",
    "uv_tcp_connect",
    "uv_translate_sys_error",
    "uv_spawn",
    "uv_walk",
    "uv_write2",
    "uv_fs_event_init",
    "uv_fs_event_start",
    "uv_fs_event_stop",
    "uv_fs_get_ptr",
    "uv_fs_realpath",
    "uv_fs_req_cleanup",
    "uv_handle_get_data",
    "uv_handle_get_loop",
    "uv_loop_get_data",
    "uv_req_get_data",
}
-- The conditional policy reads and updates the inherited action directly; its
-- one external host call remains visible in the generated object.
local SIGPIPE_EXTERNAL_HOST_CALLS = {
    "sigaction",
}
local RETIRED_UV_WRAPPERS = {
    "titan_uvshim_getaddrinfo_cancel",
    "titan_uvshim_addrinfo_free",
    "titan_uvshim_tcp_init",
    "titan_uvshim_tcp_close",
    "titan_uvshim_tcp_listen",
    "titan_uvshim_tcp_accept",
    "titan_uvshim_tcp_read_start",
    "titan_uvshim_tcp_read_stop",
    "titan_uvshim_tcp_write_start",
    "titan_uvshim_tcp_shutdown_start",
    "titan_uvshim_pipe_init",
    "titan_uvshim_pipe_read_start",
    "titan_uvshim_pipe_read_stop",
    "titan_uvshim_pipe_write_start",
    "titan_uvshim_pipe_close",
    "titan_uvshim_process_close",
    "titan_uvshim_timer_set_data",
    "titan_uvshim_timer_is_closing",
    "titan_uvshim_timer_close",
    "titan_uvshim_fs_set_data",
    "titan_uvshim_fs_cancel",
    "titan_uvshim_signal_init",
    "titan_uvshim_signal_start_oneshot",
    "titan_uvshim_signal_close",
}
local RETIRED_UV_HELPERS = {
    "titan_uvshim_process_spawn",
    "titan_uvshim_error_eio",
    "titan_uvshim_error_eof",
    "titan_uvshim_error_ecanceled",
    "titan_uvshim_error_eaddrnotavail",
    "titan_uvshim_error_einval",
    "titan_uvshim_error_enobufs",
    "titan_uvshim_error_enoent",
    "titan_uvshim_error_esrch",
    "titan_uvshim_signal_number",
    "titan_uvshim_signal_name",
    "titan_uvshim_buf_max_length",
    "titan_uvshim_buf_init_const",
    "titan_uvshim_buf_init_slice",
    "titan_uvshim_bytes_copy",
    "titan_uvshim_bytes_find",
    "titan_uvshim_bytes_slice_copy",
    "titan_uvshim_text_copy",
    "titan_uvshim_stat_extract",
}
local RETIRED_NETWORK_HELPERS = {
    "titan_uvshim_format_port",
    "titan_uvshim_getaddrinfo_start",
    "titan_uvshim_addrinfo_is_usable",
    "titan_uvshim_addrinfo_count",
    "titan_uvshim_addrinfo_copy",
    "titan_uvshim_address_at",
    "titan_uvshim_tcp_bind",
    "titan_uvshim_tcp_connect_start",
}
local FFI_RETIRED_HELPERS = {
    "titan_uvshim_ignore_sigpipe_if_default",
    "titan_uvshim_dup_cloexec",
}

local function installed_stdlib_container()
    local prefix = installed_prefix.active()
    return prefix .. "/lib/titan/0.6/" .. INSTALLED_STDLIB_CONTAINER
end

local function installed_stdlib_archive()
    local prefix = installed_prefix.active()
    return prefix .. "/lib/titan/0.6/" .. STDLIB_STATIC_ARCHIVE
end

local function quote(word)
    local quoted = assert(cdriver.shell_quote(word))
    return quoted
end

local function run_argv(argv)
    if platform.windows then
        -- These queries exercise Bash recipes, including those from the Unix
        -- Makefile. Native GNU Make otherwise selects cmd.exe on Windows.
        for _, word in ipairs(argv) do
            if word == "make" then
                argv = { table.unpack(argv) }
                argv[#argv + 1] = "SHELL=bash.exe"
                break
            end
        end
    end
    local result = compiler_io.new_sync():run(argv)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.ok, output, result.why, result.status
end

local function compiler_argv(...)
    local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function tool_argv(environment, fallback, ...)
    local argv = assert(cdriver.split_shell_words(
        os.getenv(environment) or fallback))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function compile_archive_objects(source, objects)
    write_file(source, "int titan_archive_fixture(void) { return 0; }\n")
    for _, object in ipairs(objects) do
        local ok, output, why, code = run_argv(compiler_argv(
            "-c", source, "-o", object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local parsed_sources = {}

local function parsed_source(path)
    local ast = parsed_sources[path]
    if ast then return ast end
    local err
    ast, err = parser.parse(path, read_file(path))
    assert.truthy(ast, path .. ": " .. tostring(err and err.label))
    parsed_sources[path] = ast
    return ast
end

-- One `<module>.titan.h` per module whose selected source declares a foreign
-- function. An inactive variant is never a selected source, so it cannot
-- predict a header. `root` names the prefix of a fixture tree whose paths are
-- absolute.
local function predicted_foreign_headers(sources, root)
    local expected = {}
    local prefix = root and (root .. "/") or ""
    for _, source in ipairs(sources) do
        local relative = source
        if prefix ~= "" then
            assert(source:sub(1, #prefix) == prefix,
                "fixture source outside its root: " .. source)
            relative = source:sub(#prefix + 1)
        end
        local module = assert(relative:match("^titan/([^/.]+)"))
        for _, node in ipairs(parsed_source(source)) do
            if node._tag == "Ast.TopLevelForeignFunc" then
                local stem = relative:match("^(titan/[^/]+/)[^/]+[.]titan$")
                stem = stem and (stem .. module) or ("titan/" .. module)
                expected["out/" .. stem .. ".titan.h"] = true
            end
        end
    end
    return expected
end

local function public_declarations(path)
    local declarations = {}
    for _, node in ipairs(parsed_source(path)) do
        if not node.islocal then
            local tag = node._tag
            local name
            if tag == "Ast.TopLevelRecord" or
                tag == "Ast.TopLevelUnion" or
                tag == "Ast.TopLevelFunc" then
                name = node.name
            elseif tag == "Ast.TopLevelVar" then
                name = node.decl.name
            elseif tag == "Ast.TopLevelTypeAlias" then
                name = node.name
            elseif tag == "Ast.TopLevelMethod" then
                name = node.class .. ":" .. node.name
            elseif tag == "Ast.TopLevelStatic" then
                name = node.class .. "." .. node.name
            end
            if name then declarations[#declarations + 1] = name end
        end
    end
    return declarations
end

local function local_record_declarations(path)
    local records = {}
    for _, node in ipairs(parsed_source(path)) do
        if node._tag == "Ast.TopLevelRecord" and node.islocal then
            records[#records + 1] = node.name
        end
    end
    return records
end

local function local_union_declarations(path)
    local unions = {}
    for _, node in ipairs(parsed_source(path)) do
        if node._tag == "Ast.TopLevelUnion" and node.islocal then
            unions[#unions + 1] = node.name
        end
    end
    return unions
end

local makefile_words = source_inventory.makefile_words
local makefile_target_export_words = source_inventory.makefile_target_export_words

-- Sorted paths of an inventory domain, which the loader builds in discovery
-- order rather than in its declaring list's order.
local function sorted_paths(items)
    local paths = {}
    for _, item in ipairs(items) do paths[#paths + 1] = item.path end
    table.sort(paths)
    return paths
end

-- Sorted spec paths a CI partition file declares; comments and blank lines
-- do not declare entries.
local function declared_spec_paths(filename)
    local paths = {}
    for line in (read_file(filename) .. "\n"):gmatch("(.-)\n") do
        local declared = line:match("^%s*(.-)%s*$")
        if declared ~= "" and declared:sub(1, 1) ~= "#" then
            paths[#paths + 1] = declared
        end
    end
    table.sort(paths)
    return paths
end

local stdlib_source_files = source_inventory.stdlib_source_files
local audited_stdlib_sources = source_inventory.audited_stdlib_sources

-- The host's own source label, which selects a family's variant. A native
-- host without an OS label selects `native` first and the default last.
local host_label
local function host_source_label()
    if host_label then return host_label end
    if platform.windows then
        host_label = "windows"
    else
        local pipe = io.popen("uname -s 2>/dev/null")
        local uname = pipe and pipe:read("*l")
        if pipe then pipe:close() end
        if uname == "Linux" then host_label = "linux"
        elseif uname == "Darwin" then host_label = "darwin"
        else host_label = "native" end
    end
    return host_label
end

-- Group an inventory into one family per logical filename. A variant is its
-- own declaration beside the default it replaces; the compiler owns the
-- spelling rule and the selection rows, so the audit asks it instead of
-- keeping a second copy.
local function source_families(sources)
    local families, by_logical = {}, {}
    for _, source in ipairs(sources) do
        local directory, basename = source:match("^(.*/)([^/]+)$")
        local logical, label = driver.classify_source_filename(basename)
        local path = logical and label and ((directory or "") .. logical) or source
        local family = by_logical[path]
        if not family then
            family = { logical = path, files = {} }
            by_logical[path] = family
            families[#families + 1] = family
        end
        family.files[#family.files + 1] = { path = source, label = label }
    end
    return families
end

-- The file one compiled module reads: the most specific declared variant that
-- applies to the host, then `native`, then the default. A target-only family
-- with no applicable member selects nothing.
local function selected_host_source(family)
    local by_label, default = {}, nil
    for _, entry in ipairs(family.files) do
        if entry.label then by_label[entry.label] = entry.path
        else default = entry.path end
    end
    for _, label in ipairs(driver.target_selection_labels(host_source_label())) do
        if by_label[label] then return by_label[label] end
    end
    return default
end

-- One selected file per family: the output-predicting audits' view, which
-- never sees an inactive variant.
local function host_selected_sources(sources)
    local selected = {}
    for _, family in ipairs(source_families(sources)) do
        local path = selected_host_source(family)
        if path then selected[#selected + 1] = path end
    end
    return selected
end

local function titan_sources_in(directory, prefix)
    local sources = {}
    for entry in lfs.dir(directory) do
        local path = directory .. "/" .. entry
        if entry:match("%.titan$") and
            lfs.attributes(path, "mode") == "file" then
            sources[#sources + 1] = (prefix or (directory .. "/")) .. entry
        end
    end
    table.sort(sources)
    return sources
end

-- A folder file the inventory never declares. Every variant spelling counts:
-- an unlisted variant is a missing declaration, not a file to ignore.
local function undeclared_folder_sources(declared, directory, prefix)
    local listed, undeclared = {}, {}
    for _, source in ipairs(declared) do listed[source] = true end
    for _, source in ipairs(titan_sources_in(directory, prefix)) do
        if not listed[source] then undeclared[#undeclared + 1] = source end
    end
    return undeclared
end

local function discovered_uv_sources(directory, prefix)
    return titan_sources_in(directory or "titan/uv", prefix or "titan/uv/")
end

local function discovered_http_sources()
    return titan_sources_in("titan/http", "titan/http/")
end

local function discovered_async_sources()
    return titan_sources_in("titan/async", "titan/async/")
end

-- Every titan.async folder file, concatenated: a source contract may live in
-- the main or in any contributor.
local function async_sources_text()
    local texts = {}
    for _, source in ipairs(discovered_async_sources()) do
        texts[#texts + 1] = read_file(source)
    end
    return table.concat(texts, "\n")
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function archive_object_members(output)
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        if member ~= "__.SYMDEF" and
            member ~= "__.SYMDEF SORTED" and
            member ~= "__.SYMDEF_64" and
            member ~= "__.SYMDEF_64 SORTED" then
            table.insert(members, member)
        end
    end
    return members
end

local function nm_has_symbol(output, expected)
    for line in output:gmatch("[^\r\n]+") do
        local symbol = line:match("(%S+)%s*$")
        if symbol == expected or symbol == "_" .. expected or
           platform.windows and symbol == "__imp_" .. expected then return true end
    end
    return false
end

local function make_temp_dir()
    local path = assert(compiler_io.new_sync():tmpname())
    if platform.windows then path = path:gsub("\\", "/") end
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    path = assert(compiler_io.new_sync():realpath(path))
    if platform.windows then path = path:gsub("\\", "/") end
    return path
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

-- Unix tests inspect the prepared checkout's objects. A source-only
-- Windows rock test owns equivalent generated units in a private source tree;
-- the installed canonical provider and SDK remain read-only.
local windows_object_root
local function stdlib_artifact(relative)
    if not platform.windows then return "out/" .. relative end
    if not windows_object_root then
        local root = make_temp_dir()
        local compiled, compile_error = xpcall(function()
            local function copy_sources(source, destination)
                assert(lfs.mkdir(destination))
                for name in lfs.dir(source) do
                    if name ~= "." and name ~= ".." then
                        local input, output = paths.join(source, name), paths.join(destination, name)
                        if lfs.attributes(input, "mode") == "directory" then
                            copy_sources(input, output)
                        elseif name:match("[.]titan$") or (name:match("[.]h$") and
                                not name:match("[.]titan[.]h$") and not name:match("[.]ffi[.]h$")) then
                            write_file(output, read_file(input))
                        end
                    end
                end
            end
            copy_sources("titan", paths.join(root, "titan"))
            local prefix = installed_prefix.active()
            local cppflags = (os.getenv("TITAN_EXTRA_CPPFLAGS") or "") ..
                ' -DUSING_UV_SHARED=1 -I"' .. paths.to_slash(paths.join(prefix, "include")) .. '"' ..
                ' -I"' .. paths.to_slash(paths.join(lfs.currentdir(), "vendor", "lpeglabel")) .. '"'
            local argv = {
                "env.exe", "TITAN_ROOT=" .. prefix, "TITAN_RUNTIME_PREBUILT=1",
                "TITAN_EXTRA_CPPFLAGS=" .. cppflags,
                paths.join(prefix, "bin", "titanc.exe"),
                "--output", root .. "/out", "--source-first", "-c", "--tree", root,
                "titan.uv", "titan.async", "titan.timer", "titan.fs", "titan.net", "titan.os", "titan.sqlite3",
            }
            local ok, output = run_argv(argv)
            assert.truthy(ok, output)
        end, debug.traceback)
        if not compiled then
            remove_tree(root)
            error(compile_error, 0)
        end
        windows_object_root = root
    end
    return paths.join(windows_object_root, "out", relative)
end

-- GNU Make executes recipe lines containing $(MAKE) even under -n. Keep these
-- command-contract tests independent of the checkout's prepared state by
-- replacing every stdlib build prerequisite class with one isolated file.
-- MAKE=false is a second guard: a newly introduced recursive dependency makes
-- the spec fail instead of installing or rebuilding anything.
local function run_stdlib_dry_make(argv)
    local root = make_temp_dir()
    local prepared = root .. "/prepared"
    write_file(prepared, "prepared for a read-only Make dry run\n")

    local openssl_selected = false
    for _, argument in ipairs(argv) do
        if argument:match("^OPENSSL_MODE=") then openssl_selected = true end
    end
    if not openssl_selected then table.insert(argv, "OPENSSL_MODE=bundled") end
    table.insert(argv, "PREFIX=" .. root)
    -- These synthetic command contracts inspect the checkout compiler and SDK
    -- inputs, independently of any installed provider in the caller's prefix.
    table.insert(argv, "STDLIB_USE_INSTALLED_RUNTIME=0")
    table.insert(argv, "MAKE=false")
    -- Ambient worker caps (TITAN_JOBS=1) must not change the command contract.
    table.insert(argv, "TITAN_JOBS=4")
    for _, variable in ipairs({
        "STDLIB_TOOL_PREREQS",
        "STDLIB_PLATFORM_PREREQS",
        "STDLIB_NATIVE_PREREQS",
        "STDLIB_RUNTIME_ARCHIVE_PREREQ",
        "STDLIB_BOOTSTRAP_PREREQ",
    }) do
        table.insert(argv, variable .. "=" .. prepared)
    end

    local ok, output, why, code
    local ran, run_error = pcall(function()
        ok, output, why, code = run_argv(argv)
    end)
    os.remove(prepared)
    assert.truthy(lfs.rmdir(root))
    if not ran then error(run_error, 0) end
    return ok, output, why, code
end

local function run_make(host)
    return run_argv({
        "make", "--no-print-directory", "-s", "HOST_OS=" .. host,
        "--old-file=libuv-build/libuv.a", "libuv-config",
    })
end

local function run_uv_dry_run(host, source, openssl_mode, openssl_pkg_config)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", source or UV_MAIN_SOURCE,
        "HOST_OS=" .. (host or "Linux"),
        "CC=ccache cc",
        "AR=review-ar",
        "RANLIB=review-ranlib",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "OPENSSL_MODE=" .. (openssl_mode or "bundled"),
        "stdlib",
    }
    if openssl_pkg_config then
        table.insert(argv, #argv,
            "OPENSSL_PKG_CONFIG=" .. openssl_pkg_config)
    end
    return run_stdlib_dry_make(argv)
end

local function count_plain(haystack, needle)
    local count = 0
    local position = 1
    while true do
        local first, last = haystack:find(needle, position, true)
        if not first then return count end
        count = count + 1
        position = last + 1
    end
end

local function assert_ordered(source, ...)
    local position = 1
    for _, needle in ipairs({ ... }) do
        local found = source:find(needle, position, true)
        assert.truthy(found, "missing or out-of-order source anchor: " ..
            needle)
        position = found + #needle
    end
end

local function stdlib_command(output)
    local normalized = output:gsub("\\\r\n", " "):gsub("\\\n", " ")
        :gsub("%s+", " ")
    local link = assert(normalized:find(
        " --source-first --incremental -j4 " ..
        table.concat(STDLIB_ROOTS, " "), 1, true), normalized)
    local first = 1
    for position in normalized:sub(1, link):gmatch("()CC='ccache cc'") do
        first = position
    end
    return normalized:sub(first), normalized
end

describe("libuv Makefile configuration", function()
    teardown(function()
        if windows_object_root then remove_tree(windows_object_root) end
    end)
    it("uses O3 with Linux fat LTO for both compilers and preserves explicit flags", function()
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local print_makefile = root .. "/flags.mk"
            write_file(print_makefile,
                "print-titan-flags:\n\t@printf '%s\\n' '$(CFLAGS)'\n")
            -- The executable called gcc is Apple Clang on macOS. Supply exact
            -- macro identities through a configured command with arguments.
            local compiler_probe = root .. "/compiler-probe.sh"
            write_file(compiler_probe, [[
case "$1" in
  gcc) printf '#define __GNUC__ 16\n' ;;
  clang) printf '#define __GNUC__ 4\n#define __clang__ 1\n' ;;
esac
]])
            local function flags(host, compiler, override, profile)
                -- This standalone query runs through a Lua pipe without the
                -- parent Make jobserver descriptors. Isolate its settings so
                -- stale coordination flags cannot prepend a warning to stdout.
                local argv = { "env", "-u", "TITAN_BUILD_PROFILE", "-u", "CFLAGS", "-u", "MAKEFLAGS",
                    "-u", "MFLAGS", "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL",
                    "-u", "MAKEOVERRIDES", "make", "--no-print-directory", "-s", "-f", "Makefile",
                    "-f", print_makefile, "HOST_OS=" .. host,
                    "CC=sh " .. assert(cdriver.shell_quote(compiler_probe)) .. " " .. compiler,
                    "print-titan-flags" }
                if override then argv[#argv + 1] = "CFLAGS=" .. override end
                if profile then argv[#argv + 1] = "TITAN_BUILD_PROFILE=" .. profile end
                local ok, output = run_argv(argv)
                assert.truthy(ok, output)
                return output
            end
            for _, compiler in ipairs({ "gcc", "clang" }) do
                local linux = flags("Linux", compiler)
                assert.matches("-O3 -flto=auto -ffat-lto-objects", linux, 1, true)
                local debug_flags = compiler == "gcc" and
                    " -g1\n" or
                    " -gline-tables-only -fdebug-info-for-profiling\n"
                assert.matches(debug_flags, linux, 1, true)
                local darwin = flags("Darwin", compiler)
                assert.matches("-O3", darwin, 1, true)
                assert.matches(debug_flags, darwin, 1, true)
                assert.falsy(darwin:find("-flto", 1, true), darwin)
                assert.falsy(darwin:find("-ffat-lto-objects", 1, true), darwin)
                assert.falsy(linux:find("-fno-lto", 1, true), linux)
                for _, host in ipairs({ "Linux", "Darwin", "Windows" }) do
                    local validation = flags(host, compiler, nil, "validation")
                    assert.matches("-O0 -fno-lto", validation, 1, true)
                    assert.falsy(validation:find("-O3", 1, true), validation)
                    assert.falsy(validation:find("-flto", 1, true), validation)
                    assert.falsy(validation:find("-ffat-lto-objects", 1, true), validation)
                    assert.matches(" -g\n", validation, 1, true)
                end
            end
            assert.equal("-O1 -DCUSTOM_DEFAULTS=1\n",
                flags("Linux", "gcc", "-O1 -DCUSTOM_DEFAULTS=1"))
            local valid, diagnostic = run_argv({ "make", "--no-print-directory", "-s", "-f", "Makefile",
                "-f", print_makefile, "TITAN_BUILD_PROFILE=production validation", "print-titan-flags" })
            assert.is_false(valid)
            assert.matches("TITAN_BUILD_PROFILE must be production or validation", diagnostic, 1, true)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("keeps validation host tools optimized while Titan payloads remain O0", function()
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local probe = root .. "/host-flags.mk"
            write_file(probe, "host-flags:\n\t@printf '%s\\n' " ..
                "'$(CFLAGS)' '$(LUA_MYCFLAGS)' '$(LUA_MYLDFLAGS)' " ..
                "'$(ROCK_CFLAGS)' " ..
                "'$(LPEGLABEL_BUILD_CFLAGS)'\n")
            local ok, output = run_argv({"env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "MAKEOVERRIDES", "-u", "CFLAGS", "-u", "LUA_MYCFLAGS",
                "-u", "LUA_MYLDFLAGS", "-u", "ROCK_CFLAGS",
                "-u", "LPEGLABEL_BUILD_CFLAGS", "make", "--no-print-directory",
                "-s", "-f", "Makefile", "-f", probe, "host-flags",
                "TITAN_BUILD_PROFILE=validation"})
            assert.truthy(ok, output)
            local rows = {}
            for row in output:gmatch("[^\n]+") do rows[#rows + 1] = row end
            assert.matches("-O0 -fno-lto", rows[1], 1, true)
            assert.same({"-O2 -fno-lto", "-O2 -fno-lto",
                "-O2 -fPIC -O0 -fno-lto",
                "-O2 -fno-lto"},
                {table.unpack(rows, 2)})
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("expands the selected Busted executable before preserving caller command bytes", function()
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local print_makefile = root .. "/busted-command.mk"
            write_file(print_makefile, "print-busted-command:\n\t@printf '%s\\n' $(call make_shell_quote_value,BUSTED)\n")
            local function query(...)
                local argv = { "env", "-u", "BUSTED", "-u", "TITAN_BUILD_PROFILE", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "make", "--no-print-directory", "-s", "-f", "Makefile", "-f", print_makefile, "PREFIX=" .. root, "print-busted-command" }
                for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
                local ok, output = run_argv(argv)
                assert.truthy(ok, output)
                return output
            end
            assert.equal("busted\n", query())
            assert.equal(root .. "/bin/busted\n", query("TITAN_BUILD_PROFILE=validation"))
            assert.equal("wrapper $(literal) command\n", query("TITAN_BUILD_PROFILE=validation", "BUSTED=wrapper $(literal) command"))
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("isolates Windows validation SDKs and preserves production native defaults", function()
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local print_makefile = root .. "/windows-profile.mk"
            write_file(print_makefile, table.concat({
                "print-windows-profile:",
                "\t@printf '%s\\n' '$(TITAN_BUILD_PROFILE)' '$(LUA_CFLAGS)' '$(LUA_LDFLAGS)' '$(NATIVE_CFLAGS)' '$(NATIVE_LDFLAGS)' '$(RUNTIME_CFLAGS)' '$(RUNTIME_LDFLAGS)' '$(COMPILER_DEPS_CFLAGS)' '$(COMPILER_DEPS_LDFLAGS)' '$(PREFIX)' '$(WINDOWS_BUILD_ROOT)' ",
                "\t@test \"$$TITAN_BUILD_PROFILE\" = '$(TITAN_BUILD_PROFILE)'", "",
            }, "\n"))
            local function query(...)
                local argv = { "env", "-u", "TITAN_BUILD_PROFILE", "-u", "PREFIX", "-u", "WINDOWS_BUILD_ROOT",
                    "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                    "make", "--no-print-directory", "-s", "-f", "Makefile.win", "-f", print_makefile, "print-windows-profile" }
                for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
                return run_argv(argv)
            end
            local ok, production = query()
            assert.truthy(ok, production)
            assert.matches("production\n-O2 -Wall -Wextra\n\n-O2\n\n-O2 -Wall -Wextra\n\n-O2\n\n", production, 1, true)
            assert.matches("/.windows-sdk\n", production, 1, true)
            assert.matches("/out/windows\n", production, 1, true)
            for _, selection in ipairs({ "TITAN_BUILD_PROFILE=validation", "MAKECMDGOALS=compiler-check", "MAKECMDGOALS=titan-stdlib-test", "MAKECMDGOALS=rock-test" }) do
                local valid, validation = query(selection)
                assert.truthy(valid, validation)
                assert.matches("validation\n-O2 -fno-lto -Wall -Wextra\n-O2 -fno-lto\n-O0 -fno-lto\n-O0 -fno-lto\n-O0 -fno-lto -Wall -Wextra\n-O0 -fno-lto\n-O2 -fno-lto\n-O2 -fno-lto\n", validation, 1, true)
                assert.matches("/.windows-sdk-validation\n", validation, 1, true)
                assert.matches("/out/windows-validation\n", validation, 1, true)
            end
            local overridden, explicit = query("TITAN_BUILD_PROFILE=validation", "LUA_CFLAGS=-O1 -DUSER=1", "RUNTIME_LDFLAGS=-Wl,caller", "PREFIX=/caller/sdk", "WINDOWS_BUILD_ROOT=/caller/build")
            assert.truthy(overridden, explicit)
            assert.matches("validation\n-O1 -DUSER=1\n", explicit, 1, true)
            assert.matches("-Wl,caller\n", explicit, 1, true)
            assert.matches("/caller/sdk\n/caller/build\n", explicit, 1, true)
            local valid, diagnostic = query("TITAN_BUILD_PROFILE=production validation")
            assert.is_false(valid)
            assert.matches("TITAN_BUILD_PROFILE must be production or validation", diagnostic, 1, true)
            assert.matches("etc/titan/build-profile", read_file("Makefile.win"), 1, true)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("checks portable Windows profile argv and rejects invalid test entry profiles", function()
        local ok, output = run_argv({ "bash", "spec/support/check_windows_build_profile.sh" })
        assert.truthy(ok, output)
        assert.matches("strict validation and idempotent flag propagation passed", output, 1, true)
        for _, script in ipairs({ "spec/support/run_rock_tests.sh", "spec/support/ci_test_groups.sh" }) do
            for _, profile in ipairs({ "", "production validation", "optimized" }) do
                local accepted, diagnostic = run_argv({ "env", "TITAN_BUILD_PROFILE=" .. profile, "bash", script })
                assert.is_false(accepted)
                assert.matches("TITAN_BUILD_PROFILE must be production or validation", diagnostic, 1, true)
            end
        end
    end)

    it("keeps public stdlib imports without a second Make module graph", function()
        assert.equal(26, #makefile_words("STDLIB_ROOTS"))
        assert.same(STDLIB_ROOTS, makefile_words("STDLIB_ROOTS"))
        local makefile = read_file("Makefile")
        for _, retired in ipairs({
            "STDLIB_IMPORTS_", "define stdlib_object_rule",
            "CHECK_TITAN_PARTS_COMPANION", "STDLIB_C_PARTS_STAMP",
            "STDLIB_COMPILER_PREREQS", "TITAN_MAKE_GRAPH_RECURSE",
        }) do
            assert.falsy(makefile:find(retired, 1, true), retired)
        end
        for _, source in ipairs(audited_stdlib_sources()) do
            for _, node in ipairs(parsed_source(source)) do
                if node._tag == "Ast.TopLevelImport" then
                    assert.is_false(node.source_required,
                        source .. " requires a producer's private source")
                end
            end
        end
    end)

    it("keeps every compiler-selected browser stdlib source free of absent-module imports", function()
        if platform.windows then pending("browser source resolution requires a supported host"); return end
        assert.same(makefile_words("BROWSER_STDLIB_ROOTS"), assert(browser_checks.browser_roots(compiler_io.new_sync())))
        local descriptor = assert(driver._browser_target.import(browser_fixtures.descriptor()))
        local context = driver._new_resolver_context({ target = "browser" }, descriptor)
        local called, ok, err = pcall(browser_checks.check_sources, context, ".")
        local closed, close_error = driver.close_resolver_context(context)
        assert.is_true(called, ok)
        assert.is_true(closed, close_error)
        assert.truthy(ok, err)
    end)

    it("keeps the browser status inventory's module rows equal to the Make roots", function()
        local delivered, native = {}, {}
        for _, row in ipairs(browser_checks.status_inventory.modules) do
            if row[2] ~= "absent" then delivered[#delivered + 1] = row[1] end
            if row[2] ~= "browser-only" then native[#native + 1] = row[1] end
        end
        local roots, all = makefile_words("BROWSER_STDLIB_ROOTS"), makefile_words("STDLIB_ROOTS")
        for _, list in ipairs({ delivered, native, roots, all }) do table.sort(list) end
        assert.same(roots, delivered)
        assert.same(all, native)
    end)

    it("gates identical SDK reinstalls on certified module, native and final hits", function()
        local linux = read_file(".github/workflows/ci.yml")
        local macos = read_file(".github/workflows/macos.yml")
        for _, contract in ipairs({
            { linux, "Certify identical SDK reinstall without coverage compilation or linking",
                "make titan-native-coverage-build TITAN_VERBOSE=1" },
            { linux, "Certify identical SDK reinstall without sanitizer compilation or linking",
                "make titan-stdlib-test-build TITAN_VERBOSE=1" },
            { macos, "Run complete macOS tests without coverage",
                "make titan-stdlib-test-build TITAN_VERBOSE=1" },
        }) do
            local start = assert(contract[1]:find("- name: " .. contract[2], 1, true))
            local finish = contract[1]:find("\n      - name:", start + 1, true) or #contract[1] + 1
            local gate = contract[1]:sub(start, finish - 1)
            assert_ordered(gate, "luarocks make --force", contract[3],
                "grep -Eq '^Titan object hit '", "grep -Eq '^Titan native hit '",
                "grep -Eq '^Titan link hit '",
                "if grep -Eq '^Titan (object|native|link) miss |os_process_host_child[.]c'",
                "exit 1")
            if contract[2] == "Certify identical SDK reinstall without sanitizer compilation or linking" then
                assert_ordered(gate,
                    "ci_sanitizer_capture.sh identical-reinstall",
                    "env TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT= luarocks make --force",
                    'cmp "$TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT/provider.so"',
                    '"$PREFIX/lib/titan/0.6/titan.so"',
                    "ci_sanitizer_capture.sh native-stdlib-identical-reinstall")
            end
        end
    end)

    for _, consumer in ipairs({ "async", "io" }) do
        it("composes source " .. consumer .. " with a compiled-only public producer", function()
            local root = make_temp_dir()
            local tested, failure = xpcall(function()
                assert(lfs.mkdir(root .. "/titan"))
                -- The consumer's selected sources and the headers they import,
                -- at their checkout-relative paths; async is a folder module.
                local inputs = { "titan/" .. consumer .. ".titan" }
                if consumer == "async" then
                    assert(lfs.mkdir(root .. "/titan/async"))
                    inputs = discovered_async_sources()
                    for _, header in ipairs({
                        "titan/async/async_receiver_native.h",
                        "titan/async/async_signal_platform.h", "titan/transfer_native.h",
                    }) do
                        inputs[#inputs + 1] = header
                    end
                end
                for _, input in ipairs(inputs) do
                    write_file(root .. "/" .. input, read_file(input))
                end
                if consumer == "async" then
                    write_file(root .. "/producer_composition_app.titan", [[
local async = import "async"
function main(_args: {string}): integer
  local task = async.run<|integer, value|>(function (): integer
    async.yield()
    return 42
  end)
  async.loop()
  local succeeded, result? = task:status():has_succeeded()
  if succeeded and result == 42 then return 0 end
  return 1
end
]])
                else
                    write_file(root .. "/producer_composition_app.titan", [[
local io = import "io"
function main(_args: {string}): integer
  io.print("compiled-only OS")
  return 0
end
]])
                end
                local producer = consumer == "async" and "coroutine" or "os"
                assert.is_nil(driver.resolve_source(resolver_options().context,
                    "titan." .. producer, root))
                local prefix = installed_prefix.active()
                local executable_suffix = platform.windows and ".exe" or ""
                -- Source async owns its POSIX signal policy; use the same
                -- feature selection as the Unix stdlib build, not inherited
                -- coroutine/minicoro headers.
                local cppflags = os.getenv("TITAN_EXTRA_CPPFLAGS") or ""
                if not platform.windows then cppflags = cppflags .. " -D_GNU_SOURCE" end
                -- The installed compiler: the retained titanc script through
                -- the SDK's Lua, or the native titanc.exe on Windows.
                local argv = {
                    platform.windows and "env.exe" or "env",
                    "TITAN_EXTRA_CPPFLAGS=" .. cppflags,
                }
                if platform.windows then
                    argv[#argv + 1] = prefix .. "/bin/titanc" .. executable_suffix
                else
                    argv[#argv + 1] = prefix .. "/bin/lua"
                    argv[#argv + 1] = prefix .. "/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc"
                end
                for _, argument in ipairs({ "--tree", root, "--output", root .. "/out",
                        "--source-first" }) do
                    argv[#argv + 1] = argument
                end
                if consumer == "async" then argv[#argv + 1] = "--no-uv-bootstrap" end
                argv[#argv + 1] = "titan." .. consumer
                argv[#argv + 1] = "producer_composition_app"
                local compiled, output = run_argv(argv)
                assert.truthy(compiled, output)
                local generated = consumer == "async" and "titan/async/async.c" or "titan/io.c"
                assert.truthy(file_exists(root .. "/out/" .. generated), generated)
                assert.falsy(file_exists(root .. "/out/titan/" .. producer .. ".c"),
                    "producer was compiled from source instead of its public provider")
                local program = root .. "/out/" ..
                    (platform.windows and "bin/producer_composition_app.exe" or "producer_composition_app")
                -- This fixture does not exercise the runtime's default search.
                -- Name the installed SDK's provider directory for the child,
                -- keeping the default search after `;;`, on both platforms.
                local child = { platform.windows and "env.exe" or "env" }
                if platform.windows then
                    child[#child + 1] = "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6"
                end
                child[#child + 1] = "TITAN_PATH_0_6=" .. prefix .. "/lib/titan/0.6;;"
                child[#child + 1] = program
                local ran, result = run_argv(child)
                assert.truthy(ran, result)
                if consumer == "io" then assert.equal("compiled-only OS\n", result) end
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(failure, 0) end
        end)
    end

    it("requires source foreign headers only for modules declaring foreign functions", function()
        local expected = predicted_foreign_headers(
            host_selected_sources(stdlib_source_files()))
        local actual = {}
        for _, path in ipairs(makefile_words("STDLIB_GENERATED_FOREIGN_HEADERS")) do
            if path:match("[.]titan[.]h$") then actual[path] = true end
        end
        assert.same(expected, actual)
    end)

    it("predicts output from the host's selected variant, not a listed variant", function()
        local root = make_temp_dir()
        local tested, test_error = pcall(function()
            local sources = {}
            for _, fixture in ipairs({
                { "titan/fam/fam.titan", false },
                { "titan/fam/fam.native.titan", true },
                { "titan/fam2/fam2.windows.titan", true },
                { "titan/plain/plain.titan", true },
                { "titan/plain/plain.native.titan", false },
            }) do
                local path, foreign = fixture[1], fixture[2]
                local parent = path:match("^(.*)/")
                assert.truthy(run_argv({ "mkdir", "-p", root .. "/" .. parent }))
                write_file(root .. "/" .. path, foreign and
                    'foreign import "fixture.h"\n\n' ..
                    "foreign function fixture_entry(raw: *void)\n" ..
                    "  if raw == nil then return end\nend\n" or
                    "function fixture_marker(): integer\n  return 0\nend\n")
                sources[#sources + 1] = root .. "/" .. path
            end
            local selected = {}
            for _, family in ipairs(source_families(sources)) do
                local path = selected_host_source(family)
                if path then selected[#selected + 1] = path end
            end
            local predicted = predicted_foreign_headers(selected, root)
            -- `native` applies to every native host; the Windows-only family
            -- exists only there; the otherwise-foreign default is replaced.
            assert.is_true(predicted["out/titan/fam/fam.titan.h"])
            assert.equal(host_source_label() == "windows",
                predicted["out/titan/fam2/fam2.titan.h"] == true)
            assert.is_nil(predicted["out/titan/plain/plain.titan.h"])
        end)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("audits every declared variant and fails on an unlisted folder variant",
        function()
            local root = make_temp_dir()
            local tested, test_error = pcall(function()
                write_file(root .. "/Makefile", table.concat({
                    "UV_TITAN_SOURCES := titan/uv/tcp.titan titan/uv/tcp.linux.titan",
                    "STDLIB_TITAN_SOURCES := $(UV_TITAN_SOURCES) " ..
                    "titan/sample.titan titan/sample.native.titan",
                    "",
                }, "\n"))
                local files = stdlib_source_files(root .. "/Makefile")
                assert.same({
                    "titan/uv/tcp.titan", "titan/uv/tcp.linux.titan",
                    "titan/sample.titan", "titan/sample.native.titan",
                }, files)
                local families = source_families(files)
                assert.equal(2, #families)
                assert.equal("titan/uv/tcp.titan", families[1].logical)
                assert.equal("titan/sample.titan", families[2].logical)
                local expected = {
                    linux = "titan/uv/tcp.linux.titan",
                    darwin = "titan/uv/tcp.titan",
                    windows = "titan/uv/tcp.titan",
                    native = "titan/uv/tcp.titan",
                }
                assert.equal(expected[host_source_label()],
                    selected_host_source(families[1]))
                assert.equal("titan/sample.native.titan",
                    selected_host_source(families[2]))

                local folder = root .. "/titan/uv"
                assert.truthy(run_argv({ "mkdir", "-p", folder }))
                for _, name in ipairs({ "tcp.titan", "tcp.linux.titan",
                        "tcp.browser.titan" }) do
                    write_file(folder .. "/" .. name, "")
                end
                local declared = {
                    "titan/uv/tcp.titan", "titan/uv/tcp.browser.titan",
                }
                assert.same({ "titan/uv/tcp.linux.titan" },
                    undeclared_folder_sources(declared, folder, "titan/uv/"))
                declared[#declared + 1] = "titan/uv/tcp.linux.titan"
                assert.same({}, undeclared_folder_sources(declared, folder,
                    "titan/uv/"))
            end)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("always invokes one compiler for each complete stdlib target without deleting objects", function()
        if platform.windows then pending("Unix Make command contract"); return end
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            local ok, output = run_argv({ "mkdir", "-p", root .. "/scripts",
                root .. "/spec/support", root .. "/out/titan" })
            assert.truthy(ok, output)
            for _, path in ipairs({ "Makefile", "scripts/install_compiler.mk",
                    "spec/support/stdlib_test_modules.mk" }) do
                write_file(root .. "/" .. path, read_file(path))
            end
            write_file(root .. "/prepared", "native dependencies\n")
            write_file(root .. "/out/titan/math.o", "retained object\n")
            write_file(root .. "/record-compiler", [[#!/bin/sh
set -eu
test "$(cat out/titan/math.o)" = "retained object"
printf '%s\n' "$*" >> calls
printf 'target=[%s]\n' "${TITAN_TARGET-<unset>}" >> environment
]])
            -- An ambient target selection must never reach the compiler; the
            -- stdlib recipes clear it themselves.
            local arguments = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                "TITAN_TARGET=bogus",
                "make", "--no-print-directory", "-s", "-C", root,
                "PREFIX=" .. root, "TITAN_JOBS=4", "MAKE=false",
                "STDLIB_USE_INSTALLED_RUNTIME=0", "OPENSSL_MODE=system",
                "OPENSSL_PKG_CONFIG=true", "STDLIB_TITANC=sh ./record-compiler",
                "STDLIB_NATIVE_PREREQS=prepared", "STDLIB_TOOL_PREREQS=prepared",
                "STDLIB_PLATFORM_PREREQS=prepared", "STDLIB_BOOTSTRAP_PREREQ=prepared",
                "STDLIB_RUNTIME_ARCHIVE_PREREQ=prepared", "STDLIB_EXTRA_OBJECTS=first.o second.a" }
            for _, target in ipairs({ "stdlib", "stdlib-objects" }) do
                local expected = "--output out --source-first --incremental -j4 " ..
                    (target == "stdlib-objects" and "-c " or "") ..
                    table.concat(STDLIB_ROOTS, " ") ..
                    (target == "stdlib" and " -X first.o second.a" or "") .. "\n"
                for _ = 1, 2 do
                    write_file(root .. "/calls", "")
                    write_file(root .. "/environment", "")
                    local argv = { table.unpack(arguments) }
                    argv[#argv + 1] = target
                    local built, log = run_argv(argv)
                    assert.truthy(built, log)
                    assert.equal(expected, read_file(root .. "/calls"))
                    assert.equal("target=[<unset>]\n",
                        read_file(root .. "/environment"), target)
                    assert.equal("retained object\n", read_file(root .. "/out/titan/math.o"))
                end
                for _, mode in ipairs({ "-n", "-q", "-t" }) do
                    write_file(root .. "/calls", "")
                    local argv = { table.unpack(arguments) }
                    argv[#argv + 1], argv[#argv + 2] = mode, target
                    local safe, log, _, status = run_argv(argv)
                    if mode == "-q" then assert.is_false(safe); assert.equal(1, status, log)
                    else assert.truthy(safe, log) end
                    assert.equal("", read_file(root .. "/calls"), mode)
                    assert.equal("retained object\n", read_file(root .. "/out/titan/math.o"))
                end
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("installs built compiler, SDK and stdlib without compilation and reuses the deployed SDK", function()
            if platform.windows then
                pending("Unix Make publication and static Lua SDK")
                return
            end
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local prefix = root .. "/prefix"
            local inputs = {
                "Makefile", "prepared", "LICENSE", "THIRD_PARTY_NOTICES.md",
                "scripts/install_compiler.mk",
                "scripts/titan_install.lua", "scripts/titan-uninstall",
                "spec/support/stdlib_test_modules.mk",
                "titanc", "titan-compiler/driver.lua",
                "titan-compiler/build.lua", "titan-compiler/build_worker.lua",
                "titan-compiler/incremental.lua", "titan-compiler/depfile.lua",
                "titan-compiler/linkcertificate.lua", "titan-compiler/nativeinputs.lua",
                "titan-compiler/testroots.lua",
                "titan/math.titan", "prefix/bin/lua", "prefix/bin/titanc",
                "prefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc",
                "prefix/share/lua/5.5/titan-compiler/driver.lua",
                "prefix/include/minicoro.h", "prefix/include/titan.h",
                "prefix/include/transfer.h",
                "prefix/include/titan/ffi.h", "prefix/include/titan/browser.h",
                "prefix/src/lua-5.5.1/lua.h", "prefix/src/lua-5.5.1/lobject.h",
                "prefix/src/lua-5.5.1/lua.c",
                "prefix/lib/titan/0.6/libtitan.a",
                "prefix/lib/libbacktrace.a", "prefix/lib/liblua.a",
                "native/include/uv.h", "native/include/uv/version.h",
                "native/llhttp.h", "native/sqlite3.h",
            }
            for _, path in ipairs(inputs) do
                local parent = path:match("^(.*)/")
                if parent then
                    local ok, output = run_argv({ "mkdir", "-p", root .. "/" .. parent })
                    assert.truthy(ok, output)
                end
                write_file(root .. "/" .. path, "fixture input\n")
            end
            write_file(root .. "/Makefile", read_file("Makefile"))
            write_file(root .. "/scripts/install_compiler.mk",
                read_file("scripts/install_compiler.mk"))
            write_file(root .. "/spec/support/stdlib_test_modules.mk",
                read_file("spec/support/stdlib_test_modules.mk"))
            -- The built `titan` support module is a Make-owned input here.
            local support_module = "titan-runtime/bootstrap/titan.so"
            assert.truthy(lfs.mkdir(root .. "/titan-runtime"))
            assert.truthy(lfs.mkdir(root .. "/titan-runtime/bootstrap"))
            write_file(root .. "/" .. support_module, "support module\n")
            write_file(prefix .. "/bin/titanc", [[#!/bin/sh
set -eu
test "$TITAN_RUNTIME_PREBUILT" = 1
test "$TITAN_ROOT" = "$PWD/prefix"
test "$1 $2" = "--output out"
shift 2
mkdir -p out/titan
test "$*" = "--source-first --incremental -j4 titan.math -X"
printf 'invoke\n' >> build.log
for output in out/titan/math.o out/titan/math.c out/titan/math.ffi.h \
    out/titan.so out/titan.a; do
    if test ! -f "$output"; then printf 'provider\n' > "$output"; fi
done
]])
            write_file(prefix .. "/bin/lua", "#!/bin/sh\nexit 0\n")
            local ok, output = run_argv({
                "chmod", "+x", prefix .. "/bin/lua", prefix .. "/bin/titanc",
            })
            assert.truthy(ok, output)
            write_file(root .. "/build.log", "")
            -- An explicit cap keeps -j4 independent of the host Make's
            -- default job policy, which is serial before GNU Make 4.2.
            local arguments = {
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
                "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "-u", "MAKE",
                "-u", "ROCKS_TREE", "-u", "TITAN_ROOT",
                "-u", "TITANC", "-u", "STDLIB_TITANC", "-u", "TITAN_LUA",
                "-u", "ROCK_TITANC", "-u", "TITAN_JOBS",
                "-u", "ROCK_LUA", "-u", "STDLIB_USE_INSTALLED_RUNTIME",
                "make", "--no-print-directory", "-s", "-C", root, "TITAN_JOBS=4",
                "PREFIX=" .. prefix, "HOST_OS=Linux",
                "STDLIB_PLATFORM_PREREQS=prepared",
                "OPENSSL_MODE=system",
                "OPENSSL_PKG_CONFIG=true",
                "STDLIB_MODULES=math", "STDLIB_ROOTS=titan.math",
                "STDLIB_TITAN_SOURCES=titan/math.titan",
                "STDLIB_LICENSES=prepared",
                "STDLIB_EXTRA_OBJECTS=",
                "TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT=",
            }
            local function build(target, ...)
                local argv = { table.unpack(arguments) }
                argv[#argv + 1] = target
                for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
                local succeeded, log = run_argv(argv)
                assert.truthy(succeeded, log)
                local actions = read_file(root .. "/build.log")
                write_file(root .. "/build.log", "")
                return actions, log
            end
            assert.equal("invoke\n", build("stdlib"))
            local old = os.time() - 30
            assert(lfs.touch(root .. "/titan/math.titan", old + 20, old + 20))
            for _, path in ipairs({ "out/titan.so", "out/titan.a" }) do
                assert(lfs.touch(root .. "/" .. path, old + 10, old + 10))
            end
            -- Publication must copy the completed image even when its sources
            -- are newer. The install phase must never re-enter compilation.
            assert.equal("", build("publish-stdlib"))
            for _, path in ipairs(inputs) do
                if path:match("^prefix/") or path:match("^native/") then
                    assert(lfs.touch(root .. "/" .. path, old, old))
                end
            end
            local installation = root .. "/installed"
            local install_arguments = {
                "PREFIX=" .. installation, "STDLIB_TITANC=false",
                "TITAN_RUNTIME_LIB=" .. prefix .. "/lib/titan/0.6/libtitan.a",
                "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. prefix .. "/src/lua-5.5.1",
                "TITAN_RUNTIME_LUA_LIB=" .. prefix .. "/lib/liblua.a",
                "LIBBT_LIB=" .. prefix .. "/lib/libbacktrace.a",
                "TITAN_SDK_ROOT_HEADERS=" .. prefix .. "/include/minicoro.h " ..
                    prefix .. "/include/titan.h " .. prefix .. "/include/transfer.h",
                "TITAN_SDK_NAMESPACED_HEADERS=" .. prefix .. "/include/titan/ffi.h " ..
                    prefix .. "/include/titan/browser.h",
                "LIBUV_SRC_DIR=native", "LLHTTP_HEADER=native/llhttp.h",
                "SQLITE3_HEADER=native/sqlite3.h",
                "--old-file=" .. support_module,
            }
            assert.equal("", build("install", table.unpack(install_arguments)))
            for _, copy in ipairs({
                { "titanc", "bin/titanc" },
                { "titan-compiler/driver.lua", "share/lua/5.5/titan-compiler/driver.lua" },
                { "prefix/lib/titan/0.6/libtitan.a", "lib/titan/0.6/libtitan.a" },
                { "prefix/lib/libbacktrace.a", "lib/libbacktrace.a" },
                { "prefix/lib/liblua.a", "lib/liblua.a" },
                { "prefix/include/transfer.h", "include/transfer.h" },
                { "prefix/include/titan/browser.h", "include/titan/browser.h" },
                { "prefix/src/lua-5.5.1/lua.c", "src/lua-5.5.1/lua.c" },
                { "native/include/uv.h", "include/uv.h" },
                { "native/include/uv/version.h", "include/uv/version.h" },
                { "native/llhttp.h", "include/llhttp.h" },
                { "native/sqlite3.h", "include/sqlite3.h" },
                { "out/titan.so", "lib/titan/0.6/titan.so" },
                { "out/titan.a", "lib/titan/0.6/titan.a" },
                { support_module, "lib/lua/5.5/titan.so" },
            }) do
                assert.equal(read_file(root .. "/" .. copy[1]),
                    read_file(installation .. "/" .. copy[2]), copy[2])
                if copy[1]:match("^prefix/") or copy[1]:match("^native/") then
                    assert.equal(lfs.attributes(root .. "/" .. copy[1], "modification"),
                        lfs.attributes(installation .. "/" .. copy[2], "modification"), copy[2])
                end
            end
            assert.equal("rwxr-xr-x", lfs.attributes(
                installation .. "/lib/lua/5.5/titan.so", "permissions"))
            assert.is_nil(lfs.symlinkattributes(installation .. "/share/lua/5.5/titan"))
            for _, source in ipairs(source_inventory.lua_files(root .. "/titan-compiler")) do
                local relative = source:sub(#root + 2)
                assert.equal(read_file(source),
                    read_file(installation .. "/share/lua/5.5/" .. relative), relative)
            end
            assert.equal(read_file(root .. "/out/titan.so"),
                read_file(prefix .. "/lib/titan/0.6/titan.so"))
            assert.equal(read_file(root .. "/out/titan.a"),
                read_file(prefix .. "/lib/titan/0.6/titan.a"))
            assert.is_nil(lfs.symlinkattributes(prefix .. "/share/lua/5.5/titan"))
            assert.is_nil(lfs.symlinkattributes(
                prefix .. "/share/titan/0.6/src/titan/test.titan"))
            local private = root .. "/private rock"
            local staged_arguments = { table.unpack(install_arguments) }
            for _, option in ipairs({
                "INST_PREFIX=" .. private, "INST_BINDIR=" .. private .. "/bin",
                "INST_LUADIR=" .. private .. "/lua", "INST_CONFDIR=" .. private .. "/conf",
                "INST_LIBDIR=" .. private .. "/lib",
            }) do staged_arguments[#staged_arguments + 1] = option end
            local installed_time = lfs.attributes(
                installation .. "/lib/titan/0.6/titan.so", "modification")
            assert.equal("", build("install", table.unpack(staged_arguments)))
            assert.equal(read_file(root .. "/out/titan.so"),
                read_file(private .. "/titan-sdk/lib/titan/0.6/titan.so"))
            assert.equal(read_file(prefix .. "/lib/liblua.a"),
                read_file(private .. "/titan-sdk/lib/liblua.a"))
            -- LuaRocks deploys and owns the staged support module like any
            -- other native Lua module; no Lua shims are staged beside it.
            assert.equal(read_file(root .. "/" .. support_module),
                read_file(private .. "/lib/titan.so"))
            assert.is_nil(lfs.symlinkattributes(private .. "/lua/titan"))
            assert.equal(read_file(root .. "/scripts/titan_install.lua"),
                read_file(private .. "/installer/titan_install.lua"))
            assert.equal(read_file(root .. "/scripts/titan-uninstall"),
                read_file(private .. "/bin/titan-uninstall"))
            assert.is_nil(lfs.attributes(private .. "/titan-sdk/share/lua"))
            assert.equal(installed_time, lfs.attributes(
                installation .. "/lib/titan/0.6/titan.so", "modification"))
            local outputs = { "out/titan/math.o", "out/titan/math.c", "out/titan/math.ffi.h",
                "out/titan.so", "out/titan.a" }
            for _, path in ipairs(outputs) do
                assert(lfs.touch(root .. "/" .. path, old + 1, old + 1))
            end
            -- Make always schedules certification, including after publication
            -- refreshed only SDK/compiler/provider timestamps. It never deletes
            -- objects; the compiler, not Make, decides whether bytes changed.
            for _, changed in ipairs({
                "prefix/bin/titanc",
                "prefix/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc",
                "prefix/share/lua/5.5/titan-compiler/driver.lua",
                "prefix/include/titan.h", "prefix/include/transfer.h",
                "prefix/lib/titan/0.6/libtitan.a",
            }) do
                assert(lfs.touch(root .. "/" .. changed, old + 2, old + 2))
                assert.equal("invoke\n", build("stdlib"), changed)
                for _, path in ipairs(outputs) do
                    assert.equal(old + 1, lfs.attributes(root .. "/" .. path, "modification"))
                end
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("keeps the exact native owner audit separate from compiler discovery", function()
        local manifest = "spec/support/stdlib_test_modules.mk"
        local program_root = makefile_words("TITAN_STDLIB_TEST_PROGRAM_ROOT", manifest)[1]
        local roots, seen = {}, {}
        for _, entry in ipairs(makefile_words("TITAN_STDLIB_TEST_ROOTS", manifest)) do
            local module = entry == "$(TITAN_STDLIB_TEST_PROGRAM_ROOT)" and program_root or entry
            assert.falsy(seen[module], "duplicate native owner " .. module)
            seen[module], roots[#roots + 1] = true, module
        end
        assert.equal("test.tests", roots[1])
        local driver = require "titan-compiler.driver"
        local testroots = require "titan-compiler.testroots"
        local tree = paths.join(lfs.currentdir(), "spec/stdlib/titan")
        local context = driver.new_resolver_context({ io = compiler_io.new_sync() })
        local ok, discovered, detail = pcall(testroots.discover, context,
            { tree }, {}, {}, tree)
        assert.truthy(driver.close_resolver_context(context))
        assert.truthy(ok, discovered)
        assert.truthy(discovered, detail)
        table.sort(roots)
        assert.same(roots, discovered, "discovery must select exactly the audited owners")
        for _, retired in ipairs({ "TITAN_TEST_MODULES", "TITAN_TEST_SOURCES_",
                "TITAN_TEST_IMPORTS_", "TITAN_TEST_C_INPUTS_", "TITAN_TEST_FOREIGN_" }) do
            assert.falsy(read_file(manifest):find(retired, 1, true), retired)
        end
        assert.truthy(read_file("Makefile.win"):find("include " .. manifest, 1, true))
        assert.falsy(lfs.attributes("spec/support/windows_stdlib_modules.tsv"))
        assert.falsy(lfs.attributes("spec/support/windows_stdlib_cases.txt"))
    end)

    it("validates complete native reports and narrowly classified skips", function()
        local validate, final_counts, validate_union =
            assert(loadfile("spec/support/check_stdlib_test_output.lua"))()
        local roots = { "first.tests", "second.tests" }
        local output = table.concat({
            "[==========] Running Titan tests.",
            "[ RUN      ] first.tests.test_value",
            "[       OK ] first.tests.test_value (1.25 ms)",
            "[ RUN      ] second.tests.test_optional",
            "[  SKIPPED ] second.tests.test_optional.child (parent skipped: capability: locale unavailable) (0.00 ms)",
            "[  SKIPPED ] second.tests.test_optional (capability: locale unavailable) (2.50 ms)",
            "[----------] first.tests (1.25 ms total)",
            "[----------] second.tests (2.50 ms total)",
            "[==========] 3 tests ran. (4.00 ms total)",
            "[  PASSED  ] 1 test.",
            "[  SKIPPED ] 2 tests.",
        }, "\n")
        local result, err = validate(output, roots, false)
        assert.truthy(result, err)
        assert.equal(3, result.count)
        assert.equal(2, result.owners)
        assert.equal(2, result.categories.capability)
        assert.equal(400, result.elapsed)
        assert.same({ ["first.tests"] = 125, ["second.tests"] = 250 }, result.owner_times)
        local crlf = output:gsub("\n", "\r\n")
        local crlf_result, crlf_error = validate(crlf, roots, false)
        assert.truthy(crlf_result, crlf_error)
        assert.same(result, crlf_result)
        assert.same(final_counts(output), final_counts(crlf))
        local function rejects(contents, expected, inventory)
            local accepted, message = validate(contents, inventory or roots, false)
            assert.is_nil(accepted)
            assert.truthy(message:find(expected, 1, true), message)
        end
        rejects(output:gsub("\n", "\r\r\n"), "malformed native run timing")
        rejects(output:gsub("1%.25 ms%)", "1.2\r5 ms)"), "malformed native case timing")
        assert.is_nil(final_counts(output:gsub("\n", "\r\r\n")))
        assert.is_nil(validate(output .. "\r", roots, false))
        assert.is_nil(final_counts(output .. "\r"))
        rejects(output:gsub("capability: locale unavailable", "no locale"), "unclassified native skip")
        rejects(output:gsub("capability:", "portability:"), "unfinished portability skips")
        rejects(output:gsub("3 tests ran", "4 tests ran"), "summary differs")
        rejects(output .. "\n[       OK ] first.tests.test_value (1.25 ms)", "duplicate native result")
        rejects(output .. "\n[ RUN      ] first.tests.test_unfinished", "did not finish")
        rejects(output .. "\n[  FAILED  ] first.tests.test_value", "native test failure")
        rejects(output, "native root did not execute", { "first.tests", "second.tests", "third.tests" })
        rejects("[==========] Running Titan tests.\n[==========] 0 tests ran. (0.00 ms total)\n[  PASSED  ] 0 tests.",
            "selected no cases")
        assert.truthy(validate(output, { "first.tests", "second.tests", "third.tests" }, true))
        assert.same({ count = 3, passed = 1, skipped = 2, failed = 0, elapsed = 400,
            owner_times = { ["first.tests"] = 125, ["second.tests"] = 250 } }, final_counts(output))
        local failed = output:gsub("%[       OK %] first.tests.test_value",
            "[  FAILED  ] first.tests.test_value"):gsub("1 test%.", "0 tests.") ..
            "\n[  FAILED  ] 1 test.\n[  FAILED  ] first.tests.test_value"
        rejects(failed, "native test failure")
        assert.same({ count = 3, passed = 0, skipped = 2, failed = 1, elapsed = 400,
            owner_times = { ["first.tests"] = 125, ["second.tests"] = 250 } }, final_counts(failed))
        assert.is_nil(final_counts(failed:gsub("%[==========%] 3 tests ran%. %([^\n]+%)\n", "")))
        assert.is_nil(final_counts(failed .. "\n[  FAILED  ] 1 test."))
        assert.is_nil(final_counts("[==========] Running Titan tests.\n[ RUN      ] first.tests.test_value"))

        for _, suffix in ipairs({
            "", " (-1.25 ms)", " (1.2 ms)", " (1.250 ms)", " (nan ms)",
            " (inf ms)", " (1e2 ms)", " (1,25 ms)", " (1.25 ms total)",
            " (1.25 ms) trailing", " (999999999999999999999999999999.00 ms)",
        }) do
            local malformed = output:gsub(
                "(%[       OK %] first.tests.test_value) %(1%.25 ms%)",
                function(prefix) return prefix .. suffix end)
            rejects(malformed, "malformed native case timing")
        end
        rejects(output:gsub("child %((.-)%) %(0%.00 ms%)",
            "child (%1) (0.01 ms)"), "uninvoked native child has nonzero timing")
        rejects(output:gsub("%[----------%] first.tests %(1%.25 ms total%)\n", ""),
            "missing native owner timing")
        rejects(output .. "\n[----------] first.tests (1.25 ms total)",
            "duplicate native owner timing")
        rejects(output:gsub("%[----------%] first.tests %(1%.25 ms total%)",
            "[----------] first.tests (1.26 ms total)"), "owner timing differs")
        rejects(output:gsub("%[==========%] 3 tests ran%. %(4%.00 ms total%)",
            "[==========] 3 tests ran."), "malformed native run timing")
        rejects(output:gsub("%[==========%] 3 tests ran%. %(4%.00 ms total%)",
            "[==========] 3 tests ran. (0.01 ms total)"), "run timing is shorter")
        rejects(output .. "\n[----------] unknown.tests (0.00 ms total)",
            "timing outside native root inventory")
        rejects(output .. "\n[----------] third.tests (0.00 ms total)",
            "timing for unexecuted native owner",
            { "first.tests", "second.tests", "third.tests" })
        assert.is_nil(final_counts(output:gsub("ran%. %(4%.00 ms total%)", "ran.")))

        local group_one_out = table.concat({
            "[==========] Running Titan tests.",
            "[ RUN      ] first.tests.test_value",
            "[       OK ] first.tests.test_value (1.25 ms)",
            "[----------] first.tests (1.25 ms total)",
            "[==========] 1 test ran. (1.50 ms total)",
            "[  PASSED  ] 1 test.",
        }, "\n")
        local group_two_out = table.concat({
            "[==========] Running Titan tests.",
            "[ RUN      ] second.tests.test_optional",
            "[  SKIPPED ] second.tests.test_optional.child (parent skipped: capability: locale unavailable) (0.00 ms)",
            "[  SKIPPED ] second.tests.test_optional (capability: locale unavailable) (2.50 ms)",
            "[----------] second.tests (2.50 ms total)",
            "[==========] 2 tests ran. (2.60 ms total)",
            "[  PASSED  ] 0 tests.",
            "[  SKIPPED ] 2 tests.",
        }, "\n")
        local union_ok, union_err = validate_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
            { id = "guarded", owners = { "second.tests" }, contents = group_two_out },
        }, roots)
        assert.truthy(union_ok, union_err)
        assert.equal(3, union_ok.count)
        assert.equal(1, union_ok.passed)
        assert.equal(2, union_ok.skipped)
        assert.equal(2, union_ok.owners)
        assert.same(result.cases, union_ok.cases)
        assert.same(result.owner_times, union_ok.owner_times)
        assert.equal(150, union_ok.group_results[1].result.elapsed)
        assert.equal(260, union_ok.group_results[2].result.elapsed)

        local report_root = make_temp_dir()
        local reported, report_error = xpcall(function()
            write_file(report_root .. "/roots", table.concat(roots, "\n"))
            write_file(report_root .. "/first-roots", "first.tests\n")
            write_file(report_root .. "/second-roots", "second.tests\n")
            write_file(report_root .. "/first-log", group_one_out)
            write_file(report_root .. "/second-log", group_two_out)
            local argv = {
                installed_prefix.active() .. "/bin/" .. (platform.windows and "lua.exe" or "lua"),
                "spec/support/check_stdlib_test_output.lua", "--union", report_root .. "/roots",
                "1", report_root .. "/first-log", report_root .. "/first-roots",
                "guarded", report_root .. "/second-log", report_root .. "/second-roots",
            }
            local ok, report = run_argv(argv)
            assert.truthy(ok, report)
            for _, expected in ipairs({
                "Native stdlib group 1 report: selected=1 passed=1 skipped=0 failed=0. (1.50 ms total)",
                "Native stdlib group guarded report: selected=2 passed=0 skipped=2 failed=0. (2.60 ms total)",
                "Native stdlib owner first.tests report: (1.25 ms total).",
                "Native stdlib owner second.tests report: (2.50 ms total).",
            }) do
                assert.truthy(report:find(expected, 1, true), report)
            end
            write_file(report_root .. "/first-log",
                group_one_out:gsub("%[       OK %]", "[  FAILED  ]"):
                    gsub("%[  PASSED  %] 1 test%.", "[  PASSED  ] 0 tests.") ..
                    "\n[  FAILED  ] 1 test.\n[  FAILED  ] first.tests.test_value")
            ok, report = run_argv(argv)
            assert.falsy(ok)
            assert.truthy(report:find(
                "Native stdlib group 1 report: selected=1 passed=0 skipped=0 failed=1. (1.50 ms total)",
                1, true), report)
            assert.truthy(report:find(
                "Native stdlib owner first.tests report: (1.25 ms total).", 1, true), report)
        end, debug.traceback)
        remove_tree(report_root)
        if not reported then error(report_error, 0) end

        local empty_out = "[==========] Running Titan tests.\n[==========] 0 tests ran. (0.00 ms total)\n[  PASSED  ] 0 tests."
        local filtered_union, filtered_err = validate_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
            { id = "2", owners = { "second.tests" }, contents = empty_out },
        }, roots, true)
        assert.truthy(filtered_union, filtered_err)
        assert.equal(1, filtered_union.count)
        assert.equal(1, filtered_union.owners)
        assert.is_nil(validate(empty_out, roots, true), "a wholly empty filtered suite must still fail")
        local empty_union, empty_err = validate_union({
            { id = "1", owners = { "first.tests" }, contents = empty_out },
            { id = "2", owners = { "second.tests" }, contents = empty_out },
        }, roots, true)
        assert.is_nil(empty_union)
        assert.truthy(empty_err:find("selected no cases", 1, true), empty_err)
        local unfinished, unfinished_err = validate_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
            { id = "2", owners = { "second.tests" },
                contents = empty_out .. "\n[ RUN      ] second.tests.test_unfinished" },
        }, roots, true)
        assert.is_nil(unfinished)
        assert.truthy(unfinished_err:find("did not finish", 1, true), unfinished_err)

        local function rejects_union(groups, expected, all_roots)
            local accepted, message = validate_union(groups, all_roots or roots)
            assert.is_nil(accepted)
            assert.truthy(message:find(expected, 1, true), message)
        end
        rejects_union({
            { id = "1", owners = { "first.tests", "second.tests" }, contents = group_one_out },
        }, "native root did not execute: second.tests")
        rejects_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
        }, "native root did not execute: second.tests")
        rejects_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
            { id = "2", owners = { "first.tests", "second.tests" }, contents = output },
        }, "duplicate planned native owner: first.tests")
        rejects_union({
            { id = "1", owners = {}, contents = group_one_out },
        }, "empty native owner group")
        rejects_union({
            { id = "1", owners = { "first.tests" }, contents = group_one_out },
            { id = "2", owners = { "second.tests" }, contents = group_one_out },
        }, "group 2: result outside native root inventory")
        rejects_union({
            { id = "foreign", owners = { "third.tests" }, contents = group_one_out },
        }, "planned owner outside native root inventory: third.tests")
        rejects_union({}, "empty native parallel group list")
        rejects_union(nil, "empty native parallel group list")
        -- Distinct, overlapping logical roots can each scope the same case.
        local shared_case_out = group_one_out:gsub("first%.tests%.test_value",
            "first.tests.test_nested.test_value")
        local nested_case_out = shared_case_out:gsub(
            "%[----------%] first.tests ", "[----------] first.tests.test_nested ")
        rejects_union({
            { id = "outer", owners = { "first.tests" }, contents = shared_case_out },
            { id = "nested", owners = { "first.tests.test_nested" }, contents = nested_case_out },
        }, "duplicate native case across groups", {"first.tests", "first.tests.test_nested"})
    end)

    it("always certifies one complete native aggregate and keeps runtime filters out of selection", function()
        if platform.windows then pending("Unix Make aggregate command contract"); return end
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            local ok, output = run_argv({ "mkdir", "-p", root .. "/scripts",
                root .. "/spec/support", root .. "/out/tests/test", root .. "/lib/titan/0.6" })
            assert.truthy(ok, output)
            for _, path in ipairs({ "Makefile", "scripts/install_compiler.mk",
                    "spec/support/stdlib_test_modules.mk" }) do
                write_file(root .. "/" .. path, read_file(path))
            end
            write_file(root .. "/prepared", "native fixtures\n")
            write_file(root .. "/lib/titan/0.6/titan.so", "installed provider\n")
            write_file(root .. "/out/tests/test/tests.o", "retained object\n")
            write_file(root .. "/record-compiler", [[#!/bin/sh
set -eu
test "$(cat test/tests.o)" = "retained object"
printf '%s\n' "$*" >> ../../calls
printf 'target=[%s]\n' "${TITAN_TARGET-<unset>}" >> ../../environment
]])
            local arguments = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                "TITAN_TARGET=bogus",
                "make", "--no-print-directory", "-s", "-C", root,
                "PREFIX=" .. root, "TITAN_JOBS=4", "MAKE=false",
                "TEST_LUA=true", "TEST_TITANC=sh ../../record-compiler",
                "TITAN_TEST_INSTALL_ROOT=" .. root, "TITAN_TEST_FIXTURE_OUTPUTS=prepared" }
            local tree = root .. "/spec/stdlib/titan"
            for _, target in ipairs({ "titan-stdlib-test-build", "titan-stdlib-test-objects" }) do
                -- -c rejects the link-phase bootstrap option.
                local expected = "--output . --test --incremental " ..
                    (target == "titan-stdlib-test-build" and "--no-uv-bootstrap " or "") .. "-j4 " ..
                    (target == "titan-stdlib-test-objects" and "-c " or "") ..
                    "--tree " .. tree .. " --test-dir " .. tree .. " " ..
                    (target == "titan-stdlib-test-build" and
                        "--exe " .. root .. "/out/tests/test/tests " or "") .. "test.tests"
                for _, name in ipairs({ "async_foreign_work", "fs_fixture", "uv_stdio_probe" }) do
                    expected = expected .. " --c-source " .. root .. "/spec/fixtures/stdlib/native/" .. name .. ".c"
                end
                for _, filter in ipairs({ "", "TITAN_FILTER=runtime-only" }) do
                    write_file(root .. "/calls", "")
                    write_file(root .. "/environment", "")
                    local argv = { table.unpack(arguments) }
                    argv[#argv + 1] = target
                    if filter ~= "" then argv[#argv + 1] = filter end
                    local built, log = run_argv(argv)
                    assert.truthy(built, log)
                    assert.equal(expected .. "\n", read_file(root .. "/calls"))
                    assert.equal("target=[<unset>]\n",
                        read_file(root .. "/environment"), target)
                end
                for _, mode in ipairs({ "-n", "-q", "-t" }) do
                    write_file(root .. "/calls", "")
                    local argv = { table.unpack(arguments) }
                    argv[#argv + 1], argv[#argv + 2] = mode, target
                    local safe, log, _, status = run_argv(argv)
                    if mode == "-q" then assert.is_false(safe); assert.equal(1, status, log)
                    else assert.truthy(safe, log) end
                    assert.equal("", read_file(root .. "/calls"), mode)
                end
            end
            local makefile = read_file("Makefile")
            for _, retired in ipairs({ "TITAN_TEST_COMPILER_PREREQS", "TITAN_TEST_PROVIDER_PREREQS",
                    "TITAN_TEST_C_PARTS_STAMP", "define titan_test_object_rule", "stale=0" }) do
                assert.falsy(makefile:find(retired, 1, true), retired)
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("clears an ambient target selection for the coverage and fixture recipes",
        function()
            if platform.windows then
                pending("Unix Make command contracts")
                return
            end
            local root = make_temp_dir()
            local tested, failure = xpcall(function()
                local ok, output = run_argv({ "mkdir", "-p", root .. "/scripts",
                    root .. "/spec/support",
                    root .. "/spec/fixtures/stdlib/native",
                    root .. "/lib/titan/0.6", root .. "/build" })
                assert.truthy(ok, output)
                for _, path in ipairs({ "Makefile", "scripts/install_compiler.mk",
                        "spec/support/stdlib_test_modules.mk" }) do
                    write_file(root .. "/" .. path, read_file(path))
                end
                write_file(root .. "/lib/titan/0.6/titan.so",
                    "installed provider\n")
                write_file(root .. "/spec/fixtures/stdlib/native/" ..
                    "uv_stdio_probe.c", "int titan_fixture;\n")
                local recorded = "printf 'target=[%s]\\n' " ..
                    "\"${TITAN_TARGET-<unset>}\" >> " .. root .. "/environment\n"
                write_file(root .. "/record-compiler", "#!/bin/sh\nset -eu\n" ..
                    recorded)
                write_file(root .. "/record-native-compiler",
                    "#!/bin/sh\nset -eu\n" .. recorded ..
                    "mkdir -p " .. root .. "/native\n" ..
                    ": > " .. root .. "/native/uv_stdio_probe.o\n" ..
                    "printf '%s\\n' " .. root .. "/native/uv_stdio_probe.o\n")
                local function target_argv(compiler, target)
                    return { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                        "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL",
                        "-u", "MAKEOVERRIDES", "TITAN_TARGET=bogus",
                        "make", "--no-print-directory", "-s", "-C", root,
                        "PREFIX=" .. root, "TITAN_JOBS=4", "MAKE=false",
                        "TEST_LUA=true", "TITAN_TEST_INSTALL_ROOT=" .. root,
                        "STDLIB_NATIVE_PREREQS=", "TITAN_TEST_FIXTURE_OUTPUTS=",
                        "TITAN_TEST_BUILD_DIR=" .. root .. "/build",
                        "TITAN_COVERAGE_BUILD_DIR=" .. root .. "/coverage",
                        "TEST_TITANC=sh " .. root .. "/" .. compiler, target }
                end
                for _, recipe in ipairs({
                    { "record-compiler", "titan-native-coverage-build" },
                    { "record-native-compiler",
                        root .. "/build/uv_stdio_probe.o" },
                }) do
                    write_file(root .. "/environment", "")
                    local built, log = run_argv(
                        target_argv(recipe[1], recipe[2]))
                    assert.truthy(built, log)
                    assert.equal("target=[<unset>]\n",
                        read_file(root .. "/environment"), recipe[2])
                end
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(failure, 0) end
        end)

    it("builds a minimal aggregate through the real compile-only and final-link recipes", function()
        if platform.windows then pending("Unix Make aggregate command contract"); return end
        -- The recorder above pins argv text. Here the installed titanc
        -- validates both recipes' options and the final link reuses every
        -- object the compile-only target certified.
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            local prefix = installed_prefix.active()
            local native = root .. "/spec/fixtures/stdlib/native"
            local ok, output = run_argv({ "mkdir", "-p", root .. "/scripts",
                root .. "/spec/support", root .. "/spec/stdlib/titan/test", native })
            assert.truthy(ok, output)
            for _, path in ipairs({ "Makefile", "scripts/install_compiler.mk",
                    "spec/support/stdlib_test_modules.mk" }) do
                write_file(root .. "/" .. path, read_file(path))
            end
            write_file(root .. "/prepared", "native fixtures\n")
            write_file(root .. "/spec/stdlib/titan/test/tests.titan", [[
local test = import "test"

function test_minimal(_context: test.Context)
  test.assert(true)
end
]])
            for _, name in ipairs({ "async_foreign_work", "fs_fixture", "uv_stdio_probe" }) do
                write_file(native .. "/" .. name .. ".c", string.format(
                    "int titan_minimal_%s(void);\nint titan_minimal_%s(void) { return 0; }\n", name, name))
            end
            local arguments = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                "make", "--no-print-directory", "-C", root,
                "PREFIX=" .. root, "TITAN_JOBS=2", "MAKE=false", "TEST_LUA=true", "TITAN_VERBOSE=1",
                "TEST_TITANC=" .. quote(prefix .. "/bin/titanc"),
                "TITAN_TEST_INSTALL_ROOT=" .. prefix, "TITAN_TEST_FIXTURE_OUTPUTS=prepared" }
            local logs = {}
            for _, target in ipairs({ "titan-stdlib-test-objects", "titan-stdlib-test-build" }) do
                local argv = { table.unpack(arguments) }
                argv[#argv + 1] = target
                local built, log = run_argv(argv)
                assert.truthy(built, log)
                logs[target] = log
            end
            local objects_log, build_log = logs["titan-stdlib-test-objects"], logs["titan-stdlib-test-build"]
            assert.truthy(objects_log:find("Titan object miss test.tests:", 1, true), objects_log)
            assert.truthy(build_log:find("Titan object hit test.tests:", 1, true), build_log)
            assert.falsy(build_log:find("Titan object miss", 1, true), build_log)
            assert.falsy(build_log:find("Titan native miss", 1, true), build_log)
            local ran, result = run_argv({ root .. "/out/tests/test/tests" })
            assert.truthy(ran, result)
            assert.truthy(result:find("[  PASSED  ] 1 test.", 1, true), result)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("runs prepared native tests against the selected SDK, not a titanc on PATH", function()
        if platform.windows then pending("Unix Make native launch environment"); return end
        -- The aggregate resolves titan.test through the runtime's lazy SDK
        -- fallback, so the run target has to carry TITAN_ROOT. A titanc
        -- earlier on PATH must not decide which provider the suite loads.
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            local prefix = installed_prefix.active()
            local native = root .. "/spec/fixtures/stdlib/native"
            local tests = root .. "/out/tests"
            local ok, output = run_argv({ "mkdir", "-p", root .. "/scripts",
                root .. "/spec/support", root .. "/spec/stdlib/titan/test", native })
            assert.truthy(ok, output)
            for _, path in ipairs({ "Makefile", "scripts/install_compiler.mk",
                    "spec/support/stdlib_test_modules.mk",
                    "spec/support/run_with_timeout.sh",
                    "spec/support/check_stdlib_test_output.lua" }) do
                write_file(root .. "/" .. path, read_file(path))
            end
            write_file(root .. "/prepared", "native fixtures\n")
            write_file(root .. "/spec/stdlib/titan/test/tests.titan", [[
local test = import "test"

function test_selected_sdk(_context: test.Context)
  test.assert(true)
end
]])
            for _, name in ipairs({ "async_foreign_work", "fs_fixture", "uv_stdio_probe" }) do
                write_file(native .. "/" .. name .. ".c", string.format(
                    "int titan_minimal_%s(void);\nint titan_minimal_%s(void) { return 0; }\n", name, name))
            end
            local build = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                "-u", "TITAN_ROOT", "-u", "TITAN_PATH", "-u", "TITAN_PATH_0_6",
                "make", "--no-print-directory", "-C", root,
                "PREFIX=" .. root, "TITAN_JOBS=2", "MAKE=false", "TEST_LUA=true",
                "TEST_TITANC=" .. quote(prefix .. "/bin/titanc"),
                "TITAN_TEST_INSTALL_ROOT=" .. prefix, "TITAN_TEST_FIXTURE_OUTPUTS=prepared",
                "TITAN_TEST_BUILD_DIR=" .. tests, "titan-stdlib-test-build" }
            local built, build_log = run_argv(build)
            assert.truthy(built, build_log)

            -- A foreign titanc first on PATH records every default SDK query.
            local foreign = root .. "/foreign-bin"
            local calls = root .. "/foreign-titanc.calls"
            assert.truthy(run_argv({ "mkdir", "-p", foreign }))
            write_file(foreign .. "/titanc", string.format(
                "#!/bin/sh\nprintf '%%s\\n' \"$*\" >> %s\nexit 1\n", quote(calls)))
            assert.truthy(run_argv({ "chmod", "0755", foreign .. "/titanc" }))
            local path = foreign .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin")
            local function run_native(selection)
                return run_argv({ "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                    "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                    "-u", "TITAN_ROOT", "-u", "TITAN_PATH", "-u", "TITAN_PATH_0_6",
                    "-u", "TITANC", "-u", "LUA_PATH", "-u", "LUA_CPATH",
                    "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
                    "PATH=" .. path, "make", "--no-print-directory", "-C", root,
                    "PREFIX=" .. root, "TITAN_JOBS=2", "MAKE=false",
                    "TEST_LUA=" .. quote(prefix .. "/bin/lua"),
                    "TITAN_TEST_INSTALL_ROOT=" .. selection,
                    "TITAN_STDLIB_TEST_ROOTS=test.tests",
                    "TITAN_TEST_BUILD_DIR=" .. tests,
                    "TITAN_TEST_RUN_LOG=" .. root .. "/run.log",
                    "TITAN_TEST_RUN_ROOTS=" .. root .. "/run-roots.txt",
                    "TITAN_TEST_TIMEOUT=120", "titan-stdlib-test-run" })
            end

            -- Control: without a selected SDK the aggregate queries PATH, so
            -- the fixture really depends on the selection the run supplies.
            write_file(calls, "")
            local unselected, unselected_log = run_native("")
            assert.falsy(unselected, unselected_log)
            local control_calls = read_file(calls)
            assert.truthy(control_calls ~= "", unselected_log)
            assert.truthy(control_calls:find("--print-root", 1, true), control_calls)

            write_file(calls, "")
            local selected, selected_log = run_native(prefix)
            assert.truthy(selected, selected_log)
            assert.truthy(selected_log:find("[  PASSED  ] 1 test.", 1, true), selected_log)
            assert.truthy(selected_log:find(
                "Native stdlib gate: selected=1 passed=1", 1, true), selected_log)
            assert.equal("", lfs.attributes(calls) and read_file(calls) or "", selected_log)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("prepares every fixed child object from scratch and preserves unchanged publications", function()
        if platform.windows then pending("Unix Make native fixture preparation"); return end
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            assert.truthy(run_argv({ "mkdir", "-p", root .. "/out/tests",
                root .. "/lib/titan/0.6", root .. "/spec/fixtures/stdlib/native" }))
            write_file(root .. "/lib/titan/0.6/titan.so", "installed provider\n")
            local fixtures = {
                { "uv_stdio_probe", "" },
                { "sqlite3_worker_fixture", "--cflag=-pthread " },
                { "ssl_allocator_fixture", "--cflag=-pthread " },
                { "ssl_error_strings", "" },
                { "os_descriptor_limit", "" },
                { "transfer_alloc_fault", "--cflag=-pthread -I titan " },
                { "uv_sync_alloc_fault", "--cflag=-pthread " },
                { "thread_retirement_fault", "--cflag=-pthread " },
            }
            write_file(root .. "/record-compiler", [[#!/bin/sh
set -eu
printf '%s\n' "$*" >> calls
test "$1 $2 $3" = "-c --incremental --output"
mkdir -p "$4/.native"
directory=$(pwd -P)
object="$4/.native/${directory##*/}.o"
printf 'unchanged native object\n' > "$object"
printf '%s/%s\n' "$directory" "$object"
]])
            local base = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES",
                "make", "--no-print-directory", "-s", "-C", root,
                "-f", lfs.currentdir() .. "/Makefile", "PREFIX=" .. root,
                "TITAN_JOBS=4", "TEST_LUA=true", "TEST_TITANC=sh ./record-compiler",
                "TITAN_BUILD_PROFILE=validation", "HOST_OS=Linux",
                "TITAN_TEST_INSTALL_ROOT=" .. root }
            write_file(root .. "/fixture-outputs.mk",
                "print-fixture-objects:\n\t@printf '%s\\n' $(filter %.o,$(TITAN_TEST_FIXTURE_OUTPUTS))\n")
            local query = { table.unpack(base) }
            for _, argument in ipairs({ "-f", root .. "/fixture-outputs.mk", "print-fixture-objects" }) do
                query[#query + 1] = argument
            end
            local listed, outputs = run_argv(query)
            assert.truthy(listed, outputs)
            local expected_objects, actual_objects = {}, {}
            for _, fixture in ipairs(fixtures) do
                expected_objects["out/tests/" .. fixture[1] .. ".o"] = true
            end
            for path in outputs:gmatch("[^\n]+") do actual_objects[path] = true end
            assert.same(expected_objects, actual_objects,
                "the complete aggregate build must prepare every fixed child object")
            for _, fixture in ipairs(fixtures) do
                local name, flags = fixture[1], fixture[2]
                write_file(root .. "/spec/fixtures/stdlib/native/" .. name .. ".c", "authored C\n")
                local fixed = root .. "/out/tests/" .. name .. ".o"
                local expected = "-c --incremental --output out/tests/native/" .. name .. ".o -j4 --print-c-objects " ..
                    "--cflag=-std=c99 --cflag=-Wall --cflag=-Wextra --cflag=-Werror --cflag=-fPIC " ..
                    "-I spec/fixtures/stdlib/native " .. flags ..
                    "--c-source spec/fixtures/stdlib/native/" .. name .. ".c\n"
                local function prepare(mode)
                    write_file(root .. "/calls", "")
                    local argv = { table.unpack(base) }
                    if mode ~= "" then argv[#argv + 1] = mode end
                    argv[#argv + 1] = "out/tests/" .. name .. ".o"
                    local ok, output, _, status = run_argv(argv)
                    if mode == "-q" then assert.is_false(ok); assert.equal(1, status, output)
                    else assert.truthy(ok, output) end
                    assert.equal(mode == "" and expected or "", read_file(root .. "/calls"))
                end
                assert.falsy(file_exists(fixed), "fresh fixture output unexpectedly exists: " .. name)
                prepare("")
                assert.equal("unchanged native object\n", read_file(fixed))
                local old = os.time() - 30
                assert(lfs.touch(fixed, old, old))
                for _, mode in ipairs({ "", "", "-n", "-q", "-t" }) do
                    prepare(mode)
                    assert.equal(old, lfs.attributes(fixed, "modification"), name)
                end
            end
            -- A moved checkout retains native nodes keyed by its former
            -- canonical source path. Only the path printed by this invocation
            -- identifies the current object; enumeration is not a selector.
            local previous = root
            local previous_leaf = assert(root:match("[^/]+$"))
            for _, fixture in ipairs(fixtures) do
                write_file(root .. "/out/tests/native/" .. fixture[1] ..
                    ".o/.native/" .. previous_leaf .. ".o", "retired canonical-path node\n")
            end
            local moved = root .. "-moved"
            assert(os.rename(root, moved))
            root = moved
            for index, argument in ipairs(base) do
                local first, last = argument:find(previous, 1, true)
                if first then
                    base[index] = argument:sub(1, first - 1) .. root .. argument:sub(last + 1)
                end
            end
            for _, fixture in ipairs(fixtures) do
                local name = fixture[1]
                local fixed = root .. "/out/tests/" .. name .. ".o"
                assert(os.remove(fixed))
                local argv = { table.unpack(base) }
                argv[#argv + 1] = "out/tests/" .. name .. ".o"
                local ok, output = run_argv(argv)
                assert.truthy(ok, output)
                assert.equal("unchanged native object\n", read_file(fixed), name)
                assert.equal("retired canonical-path node\n", read_file(root ..
                    "/out/tests/native/" .. name .. ".o/.native/" .. previous_leaf .. ".o"), name)
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("keeps private runtime refreshes off shared dependency recipes",
        function()
            if platform.windows then
                pending("Unix private runtime Make recipes and libbacktrace archive")
                return
            end
            local workspace = async_stdlib.workspace("runtime-refresh")
            local tested, test_error = pcall(function()
                local command =
                    async_stdlib.private_runtime_make_command(workspace, true)
                local libbacktrace_archive = lfs.currentdir() ..
                    "/libbacktrace/.libs/libbacktrace.a"
                local libuv_archive =
                    lfs.currentdir() .. "/libuv-build/libuv.a"
                local lua_source = workspace .. "/lua-5.5.1"
                local prefix = installed_prefix.active()
                for _, header in ipairs({ "lua.h", "lobject.h" }) do
                    assert.equal(read_file(prefix .. "/src/lua-5.5.1/" .. header),
                        read_file(lua_source .. "/" .. header), header)
                end
                assert.equal(read_file(prefix .. "/lib/liblua.a"),
                    read_file(lua_source .. "/liblua.a"))
                assert.truthy(command:find(
                        "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. quote(lua_source),
                        1, true), command)
                assert.truthy(command:find(
                        "TITAN_RUNTIME_LUA_LIB=" .. quote(lua_source .. "/liblua.a"),
                        1, true), command)
                assert.truthy(command:find(
                        "--old-file=" .. quote(libbacktrace_archive), 1, true),
                    command)
                assert.truthy(command:find(
                        "--old-file=" .. quote(libuv_archive), 1, true),
                    command)

                local before = {
                    lfs.attributes(libbacktrace_archive, "modification"),
                    lfs.attributes(libuv_archive, "modification"),
                }
                local ok, _, output = async_stdlib.run(command, workspace)
                assert.truthy(ok, output)
                assert.same(before, {
                    lfs.attributes(libbacktrace_archive, "modification"),
                    lfs.attributes(libuv_archive, "modification"),
                })
            end)
            async_stdlib.cleanup(workspace)
            if not tested then error(test_error, 0) end
        end)

    it("keeps the reviewed uv source list equal to the folder ensemble",
        function()
            local listed = makefile_words("UV_TITAN_SOURCES")
            assert.equal(UV_MAIN_SOURCE, listed[1])
            local normalized = {}
            local seen = {}
            for _, source in ipairs(listed) do
                assert.falsy(seen[source], "duplicate UV_TITAN_SOURCES member " ..
                    source)
                seen[source] = true
                normalized[#normalized + 1] = source
            end
            table.sort(normalized)
            assert.same(discovered_uv_sources(), normalized)
            assert.same({}, undeclared_folder_sources(listed, "titan/uv",
                "titan/uv/"))
            assert.same({
                "titan/uv/address-native.h",
                "titan/uv/callback.h",
                "titan/uv/data_native.h",
                "titan/uv/external-wake-native.h",
                "titan/uv/fd-native.h",
                "titan/uv/network-native.h",
                "titan/uv/platform-constants.h",
                "titan/uv/sync_storage.h",
                "titan/uv/thread-native.h",
                "titan/uv/transfer-native.h",
                "titan/uv/utility_bits.h",
                "titan/uv/version-native.h",
                "titan/uv/work-data.h",
            }, makefile_words("UV_TITAN_HEADERS"))
        end)

    it("keeps inherited SIGPIPE policy in async and argc/argv setup in public UV", function()
        local async = async_sources_text()
        for _, contract in ipairs({
            'foreign import "async_signal_platform.h"',
            "local native_error = ffi.titan_async_ignore_sigpipe_if_default()",
            "if native_error ~= 0 then",
            'check_status(uv.translate_sys_error(native_error), "runtime.sigpipe")',
            "uv.setup_process_args()",
        }) do assert.truthy(async:find(contract, 1, true), contract) end
        local platform = read_file("titan/async/async_signal_platform.h")
        assert_ordered(platform, "#else", "struct sigaction current;",
            "if (sigaction(SIGPIPE, NULL, &current) != 0)", "return errno;",
            "if (current.sa_handler != SIG_DFL)", "return 0;",
            "current.sa_handler = SIG_IGN;",
            "if (sigaction(SIGPIPE, &current, NULL) != 0)", "return errno;")
        for _, forbidden in ipairs({"sigemptyset", "uv.h", "uv_translate_sys_error"}) do
            assert.falsy(platform:find(forbidden, 1, true), forbidden)
        end
        local startup = read_file("titan/uv/startup.titan")
        assert_ordered(startup, "function setup_process_args(): boolean",
            "if process_args_ready then return true end",
            "ffi.TITAN_MAIN_ARGC_KEY", "if ffi.lua_type(L, -1) == ffi.LUA_TNIL then return false end",
            "ffi.TITAN_MAIN_ARGV_KEY", "ffi.uv_setup_args(argc, argv)",
            "ffi.lua_pushlightuserdata(L, configured)", "ffi.TITAN_MAIN_ARGV_KEY",
            "process_args_ready = true")
        for _, path in ipairs(discovered_uv_sources()) do
            assert.falsy(read_file(path):find("sigaction", 1, true), path)
        end
    end)

    it("keeps public UV independent of Task policy and owns nominal async types in async", function()
        local async_exports = {}
        for _, source in ipairs(discovered_async_sources()) do
            for _, name in ipairs(public_declarations(source)) do async_exports[name] = true end
        end
        for _, name in ipairs({"Error", "OperationError", "ResumeToken", "CancellationReason",
                "TaskStatus", "Task", "Completion", "TransferValue", "checkpoint",
                "await_with", "await_cancellable_with", "await_cleanup_with",
                "await", "await_cancellable", "await_cleanup",
                "BufferedSubscription", "CoalescingSubscription"}) do
            assert.truthy(async_exports[name], name)
        end
        local uv_exports = {}
        for _, path in ipairs(discovered_uv_sources()) do
            for _, name in ipairs(public_declarations(path)) do uv_exports[name] = true end
            for _, node in ipairs(parsed_source(path)) do
                if node._tag == "Ast.TopLevelImport" then
                    assert.not_equal("titan.async", node.modname, path)
                end
            end
            for _, forbidden in ipairs({"record Task", "record Runtime", "record Call",
                    "ResumeToken", "CancellationReason", "TaskStatus"}) do
                assert.falsy(read_file(path):find(forbidden, 1, true), path .. ": " .. forbidden)
            end
        end
        for _, name in ipairs({"loop_t", "handle_t", "req_t", "buf_t", "timer_t", "fs_t",
                "work_t", "tcp_t", "process_t", "run", "close", "cancel", "queue_work"}) do
            assert.truthy(uv_exports[name], name)
        end
        for _, name in ipairs({"Error", "OperationError", "Task", "Runtime", "Call", "TransferValue"}) do
            assert.falsy(uv_exports[name], name)
        end
    end)

    it("keeps generic Tasks and ordinary, cancellable and cleanup waits in async", function()
        local async = async_sources_text()
        for _, contract in ipairs({
            "record ResumeToken", "const source: string?", "union CancellationReason<|B|>",
            "union TaskStatus<|A, B|>", "record Task<|A, B|>", "local record Runtime",
            "function run<|A, B|>(func: function (): (A)): Task<|A, B|>",
            "function running(): Task<|value, value|>",
            "function await<|T, E|>", "function await_cancellable<|T, E|>",
            "function await_cleanup<|T, E|>", "function (value, string): ()",
            "function Task:resume(token: ResumeToken)",
            "Task resume token mismatch (expected source: ",
            "type SuspendCancelAction = function (): ()",
            "function suspend(token: ResumeToken, cancel_action: (function (): ())?)",
            "function channel<|T|>(size: integer?):",
            "ResumeToken(\"channel\")",
            "local transfer: {T} = {}",
            "local send: function (T): ()",
            "local receive: function (): (T)",
            "channel<|string|>(size)",
            "union AnyTwoResult<|A1, A2|>",
            "union AnyFiveResult<|A1, A2, A3, A4, A5|>",
            "union RaceTwoResult<|A1, B1, A2, B2|>",
            "union RaceFiveResult<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>",
            "union AllTwoError<|A1, B1, A2, B2|>",
            "union AllFiveError<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>",
            "function any_two<|A1, B1, A2, B2|>(",
            "function any_five<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>(",
            "function race_two<|A1, B1, A2, B2|>(",
            "function race_five<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>(",
            "function all_two<|A1, B1, A2, B2|>(",
            "function all_five<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>(",
            "function join<|A, B|>(task: Task<|A, B|>): TaskStatus<|A, B|>",
            "function join_five<|A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5|>(",
        }) do
            assert.truthy(async:find(contract, 1, true), contract)
        end
        -- run_foreign is the last declaration of its native contributor.
        local foreign = read_file("titan/async/foreign.native.titan")
        local foreign_start = assert(foreign:find("function run_foreign(", 1, true))
        local work = foreign:sub(foreign_start)
        assert_ordered(work, 'if not f then raise "async.run_foreign callback must not be NULL" end',
            "uv.work_t.new()", "await_with<|ForeignWork, value, OperationError|>")
        assert.truthy(async:find("uv.queue_work(current_loop()", 1, true))
        assert.falsy(work:find("await_cancellable", 1, true), work)
        assert.falsy(async:find("type Task = uv.", 1, true), async)
        local http = read_file("titan/http/server.native.titan")
        assert.truthy(http:find("async.run<|Request?, value|>(", 1, true), http)
        assert.truthy(http:find("async.run(function (): nil", 1, true), http)
    end)

    it("keeps the reviewed HTTP source list equal to the folder ensemble",
        function()
            local listed = makefile_words("STDLIB_HTTP_SOURCES")
            assert.equal("titan/http/http.titan", listed[1])
            local normalized = {}
            local seen = {}
            for _, source in ipairs(listed) do
                assert.falsy(seen[source],
                    "duplicate STDLIB_HTTP_SOURCES member " .. source)
                seen[source] = true
                normalized[#normalized + 1] = source
            end
            table.sort(normalized)
            assert.same(discovered_http_sources(), normalized)
        end)

    it("pins the private llhttp and OpenSSL build inputs", function()
        assert.same({ "9.4.3" }, makefile_words("LLHTTP_VERSION"))
        assert.same({
            "1eb813c7437b31a87496a1cd3ed79f00746720f5e7e29c79b42c02cb69f36c39",
        }, makefile_words("LLHTTP_SHA256"))
        assert.same({ "llhttp.c", "http.c", "api.c" },
            makefile_words("LLHTTP_SOURCE_NAMES"))
        assert.same({ "-std=c99", "-fPIC", "-fvisibility=hidden" },
            makefile_words("LLHTTP_CFLAGS"))
        assert.same({ "3.5.7" }, makefile_words("OPENSSL_VERSION"))
        assert.same({ "3.0.0" }, makefile_words("OPENSSL_MIN_VERSION"))
        assert.same({
            "a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8",
        }, makefile_words("OPENSSL_SHA256"))
        assert.same({
            "--api=3.0", "no-shared", "no-pinshared", "no-atexit",
            "no-apps", "no-tests", "no-docs", "no-legacy", "no-comp",
            "no-dso", "no-module", "no-quic", "no-zlib", "no-zstd",
            "no-brotli", "no-autoload-config",
            "$(OPENSSL_EXTRA_CONFIGURE_FLAGS)",
        }, makefile_words("OPENSSL_CONFIGURE_FLAGS"))
        assert.same({ "$(if", "$(filter", "validation,$(TITAN_BUILD_PROFILE)),$(TITAN_VALIDATION_FLAGS),-O2)", "-g", "-fPIC", "-fvisibility=hidden" },
            makefile_words("OPENSSL_REQUIRED_CFLAGS"))
        local makefile = read_file("Makefile")
        for _, contract in ipairs({
            "llhttp: $(LLHTTP_ARCHIVE)",
            "$(LLHTTP_CFLAGS) $(TITAN_EXTRA_CFLAGS) " ..
            "$(LLHTTP_BUILD_CFLAGS)",
            "openssl: $(OPENSSL_LIBS)",
            "$(OPENSSL_PKG_CONFIG) --atleast-version=" ..
            "\"$(OPENSSL_MIN_VERSION)\" openssl",
            "CFLAGS=$(call make_shell_quote,$(OPENSSL_REQUIRED_CFLAGS) " ..
            "$(OPENSSL_BUILD_CFLAGS))",
            "install: install-compiler publish-titan-sdk publish-stdlib",
            "clean-llhttp:", "clean-openssl:",
            "clean-libuv clean-llhttp clean-sqlite3 clean-openssl",
        }) do
            assert.truthy(makefile:find(contract, 1, true), contract)
        end
        assert.falsy(makefile:find("TITAN_SSLSHIM", 1, true), makefile)
        assert.falsy(makefile:find("titan/ssl/native", 1, true), makefile)
        assert.falsy(makefile:find("STDLIB_SSL_INTEGRATION_HEADER", 1, true),
            makefile)
        assert.is_nil(lfs.attributes("titan/ssl"),
            "the retired SSL integration-header directory still exists")
    end)

    it("builds the exact three-member private llhttp archive", function()
            if platform.windows then
                pending("Unix private llhttp archive; Windows consumes the native llhttp DLL SDK")
                return
            end
        local archive = "llhttp-build/libtitan-llhttp.a"
        assert.truthy(file_exists(archive), "run make llhttp first")
        local ok, output, why, code = run_argv(tool_argv(
            "AR", "ar", "t", archive))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.same({ "llhttp.o", "http.o", "api.o" },
            archive_object_members(output))

        ok, output, why, code = run_argv(tool_argv("NM", "nm", "-g", archive))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(nm_has_symbol(output, "llhttp_execute"), output)
    end)

    it("pins the serialized SQLite amalgamation build inputs", function()
        assert.same({ "3.53.4" }, makefile_words("SQLITE3_VERSION"))
        assert.same({ "3530400" }, makefile_words("SQLITE3_RELEASE"))
        assert.same({
            "0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c",
        }, makefile_words("SQLITE3_SHA256"))
        assert.same({
            "-std=c99", "-fPIC", "-fvisibility=hidden", "-DSQLITE_THREADSAFE=1",
        }, makefile_words("SQLITE3_CFLAGS"))
    end)

    it("builds the pinned serialized SQLite amalgamation as private payload", function()
        if platform.windows then
            pending("Unix private SQLite archive; Windows consumes the native SQLite DLL SDK")
            return
        end
        local archive = "sqlite3-build/libtitan-sqlite3.a"
        local ok, output = run_argv(tool_argv("AR", "ar", "t", archive))
        assert.truthy(ok, output)
        assert.same({ "sqlite3.o" }, archive_object_members(output))

        local root = make_temp_dir()
        local source, executable = root .. "/sqlite-build.c", root .. "/sqlite-build"
        local tested, test_error = pcall(function()
            write_file(source, [[#include "sqlite3.h"
int main(void) {
    return sqlite3_threadsafe() != 1 || sqlite3_libversion_number() != 3053004;
}
]])
            local argv = compiler_argv("-std=c99", SQLITE3_NATIVE_INCLUDE,
                source, "-o", executable, archive, "-lpthread", "-lm")
            local host_ok, host = run_argv({ "uname", "-s" })
            assert.truthy(host_ok, host)
            if host:match("^%s*Linux%s*$") then argv[#argv + 1] = "-ldl" end
            for _, name in ipairs({ "TITAN_EXTRA_CFLAGS", "TITAN_EXTRA_LDFLAGS" }) do
                for _, flag in ipairs(assert(cdriver.split_shell_words(
                        os.getenv(name) or ""))) do
                    argv[#argv + 1] = flag
                end
            end
            ok, output = run_argv(argv)
            assert.truthy(ok, output)
            ok, output = run_argv({ executable })
            assert.truthy(ok, output)
        end)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("keeps trusted Lua value bridges inline in the FFI header", function()
        local header = read_file("titan-runtime/titan/ffi.h")
        for _, name in ipairs({
            "lua_totvalue",
            "lua_pushtvalue",
            "lua_togco",
            "titan_newthread",
            "lmacro_thvalue",
            "lmacro_uvalue",
            "lmacro_clCvalue",
            "lmacro_pvalue",
        }) do
            assert.truthy(header:match(
                "static inline [^\n]-" .. name .. "%s*%("), name)
        end
        assert.falsy(header:find("titan_ffi_pushudata", 1, true), header)

        local runtime = read_file("titan-runtime/titan.c")
        for _, signature in ipairs({
            "TValue lua_totvalue(",
            "void lua_pushtvalue(",
            "void *lua_togco(",
            "lua_State *titan_newthread(",
        }) do
            assert.falsy(runtime:find(signature, 1, true), signature)
        end
    end)

    it("keeps HTTP parser storage, callbacks, and policy in Titan", function()
        local path = "titan/http/parser.native.titan"
        local native = read_file(path)
        local ast, parse_error = parser.parse(path, native)
        assert.truthy(ast, parse_error and parser.error_to_string(parse_error))
        local declarations = {}
        for _, node in ipairs(ast) do
            if node._tag == "Ast.TopLevelForeignFunc" then
                declarations[#declarations + 1] = node.name
            end
        end
        local expected = {}
        for _, callback in ipairs(HTTP_FOREIGN_CALLBACKS) do
            expected[#expected + 1] = callback.name
            local marker = "foreign function " .. callback.name .. "("
            local first = assert(native:find(marker, 1, true), marker)
            local last = assert(native:find("\nend", first, true), marker)
            local body = native:sub(first, last)
            assert.truthy(body:find(
                'ffi.titan_record_field(owner, "Parser", "' ..
                callback.field .. '")', 1, true), body)
            assert.truthy(body:find(
                'ffi.titan_record_field(owner, "Parser", "callback_state")',
                1, true), body)
            assert.falsy(body:find("owner.uv[", 1, true), body)
            assert.truthy(body:find("callback.upvalue[0]", 1, true), body)
            assert.truthy(body:find("callback.upvalue[2]", 1, true), body)
            assert.falsy(body:find(
                "titan_ffi_pushudata", 1, true), body)
            assert.truthy(body:find("ffi.lua_settop(L, top)", 1, true), body)
            local call = callback.no_data and
                "entry(L, module, callback, owner)" or
                "entry(L, module, callback, owner, data, length)"
            assert.truthy(body:find("local result = " .. call, 1, true), body)
            assert.truthy(body:find("return result", 1, true), body)
            assert.truthy(native:find(
                "settings." .. callback.setting .. " = " .. callback.name,
                1, true), callback.name)
        end
        assert.same(expected, declarations)

        assert.truthy(native:find("local events: {Event}", 1, true), native)
        -- The caller's argument roots `input`; nothing is pushed to root it.
        assert.falsy(native:find("ffi.lua_pushtvalue(", 1, true), native)
        assert.truthy(native:find(
            "ffi.lua_checkstack(L, ffi.LUA_MINSTACK)", 1, true), native)
        assert.truthy(native:find(
            "ffi.llhttp_execute(", 1, true), native)
        assert.truthy(native:find(
            "ffi.llhttp_finish(", 1, true), native)
        assert.truthy(native:find(
            "ffi.llhttp_get_error_pos(", 1, true), native)
    end)

    it("defines the exact libuv callbacks in generated Titan code",
        function()
            local declarations, contents, expected = {}, {}, {}
            for _, path in ipairs(discovered_uv_sources()) do
                contents[#contents + 1] = read_file(path)
                for _, node in ipairs(parsed_source(path)) do
                    if node._tag == "Ast.TopLevelForeignFunc" then
                        declarations[#declarations + 1] = node.name
                    end
                end
            end
            for _, callback in ipairs(UV_FOREIGN_CALLBACKS) do
                expected[#expected + 1] = callback.name
                local source = read_file(callback.source)
                local first = assert(source:find("foreign function " .. callback.name .. "(", 1, true))
                local last = assert(source:find("\nend", first, true))
                local body = source:sub(first, last):gsub("%s+", " ")
                assert.truthy(body:find('ffi.titan_record_field(' .. callback.owner .. ', "' ..
                    callback.record .. '", "' .. callback.field .. '")', 1, true), body)
                assert.truthy(body:find("handler.upvalue[0]", 1, true), body)
                assert.truthy(body:find("handler.upvalue[2]", 1, true), body)
                assert.truthy(body:find('ffi.titan_record_field(loop, "loop_t", "state")', 1, true), body)
                assert_ordered(body, "local top = ffi.lua_gettop(L)",
                    "ffi.titan_uv_push_owner(L, owner)", callback.call, "ffi.lua_settop(L, top)")
                local handler_first = assert(source:find("local function " .. callback.handler .. "(", 1, true))
                local handler_last = assert(source:find("\nend", handler_first, true))
                local handler = source:sub(handler_first, handler_last)
                assert_ordered(handler, "\ncatch", "if loop.failure_count == 0 then",
                    "loop.failure_error = error", "loop.failure_trace = traceback",
                    "loop.failure_count = loop.failure_count + 1", "ffi.uv_stop(loop.native)")
                assert.truthy(source:find(callback.field .. " = " .. callback.handler, 1, true), callback.name)
                -- A handler local roots what the handler clears; the
                -- trampoline pushes only the owner.
                for _, forbidden in ipairs({"owner.uv[", "titan_ffi_pushudata",
                        "ffi.lua_pushtvalue(", "async.", "Task"}) do
                    assert.falsy(body:find(forbidden, 1, true), body)
                end
            end
            for _, entry in ipairs(UV_NATIVE_ENTRIES) do
                expected[#expected + 1] = entry.name
                local source = read_file(entry.source)
                local first = assert(source:find("foreign function " .. entry.name .. "(", 1, true))
                local last = assert(source:find("\nend", first, true))
                local body = source:sub(first, last)
                for _, forbidden in ipairs({"ffi.lua_", "ffi.titan_ffi_", "ffi.titan_uv_push_owner",
                        "upvalue[", "entry(L", "async.", "Task"}) do
                    assert.falsy(body:find(forbidden, 1, true), body)
                end
                if entry.name == "work_worker_callback" then
                    assert.truthy(body:find("local storage = request.data as *titan_uv_work_data", 1, true))
                    assert.truthy(body:find("worker(storage.arg)", 1, true))
                    for _, forbidden in ipairs({"ffi.titan_record_field", "ffi.uv_req_get_data", "ffi.uv_loop_get_data"}) do
                        assert.falsy(body:find(forbidden, 1, true), body)
                    end
                end
            end
            table.sort(expected)
            table.sort(declarations)
            assert.same(expected, declarations)
            local all_sources = table.concat(contents, "\n")
            for _, legacy in ipairs(LEGACY_UV_CALLBACKS) do
                assert.falsy(all_sources:find(legacy, 1, true), legacy)
            end
            assert.is_nil(lfs.attributes("titan-runtime/titan_uv.c"))
            assert.is_nil(lfs.attributes("titan-runtime/titan/uv.h"),
                "the retired libuv shim header still exists")

            local makefile = read_file("Makefile")
            for _, retired in ipairs({
                "UV_O", "UV_CONFIG_STAMP", "titan_uv.c", "titan_uv.o",
            }) do
                assert.falsy(makefile:find(retired, 1, true), retired)
            end

        end)

    it("keeps native UV symbols and callback entrypoints in the canonical provider", function()
            local logical_object = stdlib_artifact("titan/uv/uv.o")
            assert.truthy(file_exists(logical_object), logical_object)
            local symbols = module_symbols.collect(logical_object, run_argv)
            local output = symbols.defined_text
            local entries = {}
            for _, entry in ipairs(UV_FOREIGN_CALLBACKS) do entries[#entries + 1] = entry end
            for _, entry in ipairs(UV_NATIVE_ENTRIES) do entries[#entries + 1] = entry end
            local foreign_header = read_file(stdlib_artifact("titan/uv/uv.titan.h"))
            for _, callback in ipairs(entries) do
                local c_name = coder_names._foreign_func_name("titan.uv", callback.name)
                local symbol = coder_names._linkage_symbol_name(c_name)
                assert.truthy(nm_has_symbol(output, symbol), symbol)
                if callback.inline then
                    c_name = coder_names._foreign_inline_name("titan.uv", callback.name)
                    -- Require the direct-call body, not just its prototype.
                    local defined = false
                    for line in foreign_header:gmatch("[^\r\n]+") do
                        if line:match("^static inline ") and
                                line:find(c_name .. "(", 1, true) and line:match("{%s*$") then
                            defined = true
                        end
                    end
                    assert.truthy(defined, "missing inline definition: " .. c_name)
                end
            end

            output = symbols.undefined_text
            for _, legacy in ipairs(LEGACY_UV_CALLBACKS) do
                assert.falsy(nm_has_symbol(output, legacy),
                    logical_object .. ": " .. legacy)
            end
            for _, function_name in ipairs(DIRECT_LIBUV_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
            end
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.falsy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
            end
            local async_output = module_symbols.collect(
                stdlib_artifact("titan/async/async.o"), run_argv).undefined_text
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.equal(not platform.windows,
                    nm_has_symbol(async_output, function_name), function_name)
            end
            for _, retired in ipairs({
                RETIRED_UV_WRAPPERS, RETIRED_UV_HELPERS,
                RETIRED_NETWORK_HELPERS, FFI_RETIRED_HELPERS,
            }) do
                for _, symbol in ipairs(retired) do
                    assert.falsy(nm_has_symbol(output, symbol),
                        logical_object .. ": " .. symbol)
                end
            end

        end)

    it("keeps native UV symbols and callbacks in the installed static provider", function()
            if platform.windows then
                pending("Windows has DLL providers and no Titan static-provider archive")
                return
            end
            local archive = installed_stdlib_archive()
            assert.truthy(file_exists(archive), archive)
            local ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-u", archive))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, legacy in ipairs(LEGACY_UV_CALLBACKS) do
                assert.falsy(nm_has_symbol(output, legacy), legacy)
            end
            for _, function_name in ipairs(DIRECT_LIBUV_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name), function_name)
            end
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name), function_name)
            end
            for _, retired in ipairs({
                RETIRED_UV_WRAPPERS, RETIRED_UV_HELPERS,
                RETIRED_NETWORK_HELPERS, FFI_RETIRED_HELPERS,
            }) do
                for _, symbol in ipairs(retired) do
                    assert.falsy(nm_has_symbol(output, symbol), symbol)
                end
            end
        end)

    it("keeps domain callbacks above public UV and raw libuv symbols inside its binding", function()
        local audited, modules = audited_stdlib_sources(), {"async", "timer", "fs", "net", "os", "sqlite3"}
        local native_objects = {}
        for _, module in ipairs(modules) do native_objects[module] = true end
        for _, row in ipairs(browser_checks.status_inventory.modules) do
            if row[2] == "browser-only" then modules[#modules + 1] = row[1]:sub(7) end
        end
        for _, module in ipairs(modules) do
            for _, path in ipairs(audited) do
                if path:match("^titan/([^/.]+)") == module then
                    local source = read_file(path)
                    assert.falsy(source:find('foreign import "uv.h"', 1, true), path)
                    assert.falsy(source:find("ffi.uv_", 1, true), path)
                    for _, node in ipairs(parsed_source(path)) do
                        if node._tag == "Ast.TopLevelImport" then
                            assert.falsy(node.modname:match("^titan%.uv%."), path .. ": " .. node.modname)
                            assert.falsy(node.modname:match("^titan%.async%."), path .. ": " .. node.modname)
                        end
                    end
                end
            end
            -- Browser-only modules have no native object; the browser
            -- closure check rejects uv symbols in the browser provider.
            if native_objects[module] then
                local object = stdlib_artifact((paths.to_slash(stdlib_objects.object(
                    resolver_options().context, "titan." .. module, ".", ".")):gsub("^%./", "")))
                local output = module_symbols.collect(object, run_argv).undefined_text
                for symbol in output:gmatch("[^\r\n]+") do
                    assert.falsy(symbol:match("%s_?uv_[%w_]+$"), object .. ": " .. symbol)
                end
            end
        end
        assert.same({}, (function ()
            local entries = {}
            for _, node in ipairs(parsed_source("titan/fs.native.titan")) do
                if node._tag == "Ast.TopLevelForeignFunc" then entries[#entries + 1] = node.name end
            end
            return entries
        end)())
        assert.falsy(read_file("Makefile"):find("titan/fs.titan.h", 1, true))
    end)

    -- spec/support/check_windows_stdlib.lua derives its objects with the same
    -- helper; a cold build has no flat object left behind by a folder split.
    it("finds every stdlib object where the Windows stdlib check derives it", function()
        if platform.windows then
            pending("the Windows stdlib-check gate reads its own build tree")
            return
        end
        local objectmetadata = require "titan-compiler.objectmetadata"
        local context = resolver_options().context
        for _, module in ipairs(STDLIB_MODULES) do
            local modname = "titan." .. module
            local object = stdlib_objects.object(context, modname, ".", "out")
            local entry, err = objectmetadata.read(read_file(object), object)
            assert.truthy(entry and entry.type, err)
            assert.equal(modname, entry.type.name, object)
        end
    end)

    it("keeps filesystem request cleanup before settlement and watchers on scoped generic batches", function()
        local source = read_file("titan/fs.native.titan")
        local first = assert(source:find("local function file_completed<|T|>", 1, true))
        local last = assert(source:find("local function start_file<|T|>", first, true))
        local completed = source:sub(first, last - 1)
        assert_ordered(completed, "local done = operation.done", "local number = operation.number",
            "request:set_data(nil)", "operation.done = nil",
            "local copied = operation.decode(request, result)", "uv.fs_req_cleanup(request)",
            "done:resolve(number, copied)")
        assert_ordered(completed, "done:fatal(number, error, traceback)", "raise")
        assert_ordered(source, "local function perform<|T|>",
            "FileOperation<|T|>(uv.fs_t.new(), submit, decode, nil, 0)",
            "async.await_with<|FileOperation<|T|>, T, integer|>(context, start_file)")
        assert_ordered(source, "function realpath(path: string): string",
            'perform<|string|>("fs.realpath"', "uv.fs_realpath(loop, request, path, callback)",
            "uv.fs_get_string(request)")
        assert_ordered(source, "local function watch_closed(handle: uv.handle_t)",
            "local number = registration.close_number", "registration.close_done = nil",
            "uv.handle_set_data(handle, nil)", "done:resolve(number, true)")
        assert_ordered(source, "local function start_watch_close(",
            "uv.close(registration.view, watch_closed)",
            "local function WatchRegistration:close(wait: boolean)",
            "async.await_cleanup_with<|WatchRegistration, boolean, integer|>(self, start_watch_close)")
        assert_ordered(source, "local function Watcher:retire_registration(",
            "defer registration:close(true)", "self:remove_registration(registration)")
        assert.truthy(source:find("async.BufferedSubscription<|WatcherNotification, integer|>", 1, true))
        local poll_start = assert(source:find("function Watcher:poll(): {WatcherEvent}", 1, true))
        local poll = source:sub(poll_start)
        assert_ordered(poll, "self:begin_poll()", "defer self:finish_poll()",
            "self.subscription:drain_pending()", "self.subscription:next_batch()",
            "self:drain_notifications(notifications)")
        assert.equal(1, count_plain(poll, "self.subscription:next_batch()"))
        assert.falsy(poll:find("while ", 1, true), poll)
    end)

    it("keeps the reviewed standard-library roots and sources exact",
        function()
            assert.same(STDLIB_MODULES, makefile_words("STDLIB_MODULES"))
            assert.same(STDLIB_ROOTS, makefile_words("STDLIB_ROOTS"))
            assert.same({ "titan/string/format_native.h" },
                makefile_words("STRING_TITAN_HEADERS"))
            assert.same({ "titan/lua/lua.titan", "titan/lua/background.native.titan",
                "titan/lua/loading.browser.titan", "titan/lua/loading.native.titan", "titan/lua/worker.titan" },
                makefile_words("LUA_TITAN_SOURCES"))
            assert.same({}, undeclared_folder_sources(
                makefile_words("LUA_TITAN_SOURCES"), "titan/lua", "titan/lua/"))
            assert.same({ "titan/lua/native.h" },
                makefile_words("LUA_TITAN_HEADERS"))
            assert.same({
                "titan/thread/thread.native.titan", "titan/thread/channel.titan",
                "titan/thread/group.titan", "titan/thread/spawn.titan",
            }, makefile_words("THREAD_TITAN_SOURCES"))
            assert.same({ "titan/thread/native.h" },
                makefile_words("THREAD_TITAN_HEADERS"))
            assert.same({
                "titan/async/async.titan",
                "titan/async/external.native.titan", "titan/async/external.browser.titan",
                "titan/async/foreign.native.titan", "titan/async/receiver.native.titan",
                "titan/async/runtime.native.titan", "titan/async/runtime.browser.titan",
            }, makefile_words("ASYNC_TITAN_SOURCES"))
            assert.same({}, undeclared_folder_sources(
                makefile_words("ASYNC_TITAN_SOURCES"), "titan/async", "titan/async/"))
            assert.same({
                "titan/async/async_receiver_native.h",
                "titan/async/async_signal_platform.h",
            }, makefile_words("ASYNC_TITAN_HEADERS"))
            assert.same({
                "titan/os/os.titan",
                "titan/os/clock.native.titan", "titan/os/clock.browser.titan",
                "titan/os/environment.native.titan", "titan/os/environment.browser.titan",
                "titan/os/process.native.titan", "titan/os/process.browser.titan",
                "titan/os/stdio.native.titan", "titan/os/stdio.browser.titan",
            }, makefile_words("OS_TITAN_SOURCES"))
            assert.same({}, undeclared_folder_sources(
                makefile_words("OS_TITAN_SOURCES"), "titan/os", "titan/os/"))
            assert.same({
                "titan/os/os_platform.h", "titan/os/os_environment.h",
                "titan/os/environment.browser.h",
            }, makefile_words("OS_TITAN_HEADERS"))
            assert.same({
                "$(LPEGLABEL_ARCHIVE)",
                "$(LIBUV_EXTRA_OBJECTS)", "$(LLHTTP_ARCHIVE)",
                "$(SQLITE3_ARCHIVE)", "$(OPENSSL_EXTRA_OBJECTS)",
            }, makefile_words("STDLIB_EXTRA_OBJECTS"))
            assert.same({ "$(LPEGLABEL_CPPFLAGS)" },
                makefile_words("STDLIB_LPEGLABEL_CPPFLAGS"))
            assert.same({ "$(LLHTTP_CPPFLAGS)" },
                makefile_words("STDLIB_HTTP_CPPFLAGS"))
            assert.same({ "$(SQLITE3_CPPFLAGS)" },
                makefile_words("STDLIB_SQLITE3_CPPFLAGS"))
            assert.same({ "$(OPENSSL_CPPFLAGS)" },
                makefile_words("STDLIB_OPENSSL_CPPFLAGS"))
            assert.same({
                "LICENSES/libuv-LICENSE", "LICENSES/libuv-LICENSE-extra",
                "LICENSES/libuv-tree-LICENSE", "LICENSES/libuv-inet-LICENSE",
                "LICENSES/lpeglabel-LICENSE", "LICENSES/lpeg-LICENSE",
                "LICENSES/lpeg-patterns-LICENSE",
                "LICENSES/ta-regex-LICENSE", "LICENSES/lua-LICENSE",
                "LICENSES/llhttp-LICENSE", "LICENSES/sqlite3-LICENSE",
                "LICENSES/openssl-LICENSE", "LICENSES/go-LICENSE",
                "LICENSES/libbacktrace-LICENSE",
            }, makefile_words("STDLIB_LICENSES"))
            assert.same({ "out/" .. STDLIB_CONTAINER },
                makefile_words("STDLIB_CONTAINER"))

            assert.same({
                "titan/coroutine.titan",
                "titan/uv/uv.native.titan",
                "titan/uv/address.titan",
                "titan/uv/callbacks.titan",
                "titan/uv/capabilities.titan",
                "titan/uv/constants.titan",
                "titan/uv/data.titan",
                "titan/uv/dll.titan",
                "titan/uv/dns.titan",
                "titan/uv/external_wake.titan",
                "titan/uv/fd.titan",
                "titan/uv/identifiers.titan",
                "titan/uv/pipe_tty.titan",
                "titan/uv/platform_constants.titan",
                "titan/uv/process.titan",
                "titan/uv/startup.titan",
                "titan/uv/stream_ops.titan",
                "titan/uv/stream_owners.titan",
                "titan/uv/sync.titan",
                "titan/uv/tcp.titan",
                "titan/uv/threading.titan",
                "titan/uv/transfer.titan",
                "titan/uv/udp.titan",
                "titan/uv/utilities.titan",
                "titan/async/async.titan",
                "titan/async/external.native.titan", "titan/async/external.browser.titan",
                "titan/async/foreign.native.titan", "titan/async/receiver.native.titan",
                "titan/async/runtime.native.titan", "titan/async/runtime.browser.titan",
                "titan/timer.native.titan", "titan/timer.browser.titan", "titan/io.titan", "titan/fs.native.titan",
                "titan/net.native.titan", "titan/ssl.native.titan", "titan/url.titan",
                "titan/http/http.titan", "titan/http/client.native.titan", "titan/http/client.browser.titan",
                "titan/http/native_imports.native.titan",
                "titan/http/headers.titan", "titan/http/options.titan", "titan/http/parser.native.titan",
                "titan/http/pool.native.titan", "titan/http/server.native.titan",
                "titan/http/transfer.native.titan", "titan/http/upgrade.native.titan",
                "titan/websocket/websocket.native.titan", "titan/websocket/handshake.native.titan",
                "titan/websocket/connection.native.titan", "titan/websocket/frames.native.titan",
                "titan/websocket/types.titan", "titan/websocket/utf8.titan", "titan/websocket/crypto.native.titan",
                "titan/websocket/websocket.browser.titan", "titan/websocket/client.browser.titan",
                "titan/os/os.titan",
                "titan/os/clock.native.titan", "titan/os/clock.browser.titan",
                "titan/os/environment.native.titan", "titan/os/environment.browser.titan",
                "titan/os/process.native.titan", "titan/os/process.browser.titan",
                "titan/os/stdio.native.titan", "titan/os/stdio.browser.titan",
                "titan/path.titan",
                "titan/peg/peg.titan",
                "titan/peg/combinators.titan", "titan/peg/native.titan",
                "titan/peg/relabel.titan",
                "titan/peg/relabel_parser.titan",
                "titan/string/string.titan",
                "titan/string/bytes.titan", "titan/string/format.titan",
                "titan/string/pack.titan", "titan/string/regex_api.titan",
                "titan/string/regex_compile.titan",
                "titan/string/regex_parser.titan",
                "titan/math.titan", "titan/lua/lua.titan", "titan/lua/background.native.titan",
                "titan/lua/loading.browser.titan", "titan/lua/loading.native.titan", "titan/lua/worker.titan",
                "titan/iteration.titan", "titan/gc.titan", "titan/test.titan",
                "titan/reflect.titan",
                "titan/sqlite3/sqlite3.native.titan", "titan/sqlite3/bindings.titan",
                "titan/sqlite3/row.titan", "titan/sqlite3/worker.titan",
                "titan/json/json.titan", "titan/json/parser.titan",
                "titan/json/decoder.titan", "titan/json/writer.titan",
                "titan/json/numbers.titan",
                "titan/protobuf/protobuf.titan", "titan/protobuf/encoder.titan",
                "titan/protobuf/decoder.titan", "titan/protobuf/portable.titan",
                "titan/protobuf/schema.titan",
                "titan/protobuf/trace.titan",
                "titan/transfer.titan",
                "titan/thread/thread.native.titan", "titan/thread/channel.titan",
                "titan/thread/group.titan", "titan/thread/spawn.titan",
            }, stdlib_source_files())
        end)

    it("keeps titan.gc as the sole stdlib lua_setmetatable owner",
        function()
            local callers = {}
            for _, source in ipairs(audited_stdlib_sources()) do
                if read_file(source):find(
                        "ffi.lua_setmetatable", 1, true) then
                    callers[#callers + 1] = source
                end
            end
            assert.same({ "titan/gc.titan" }, callers)
        end)

    it("uses ordinary public module imports for async domains", function()
        for _, source in ipairs(audited_stdlib_sources()) do
            for _, node in ipairs(parsed_source(source)) do
                if node._tag == "Ast.TopLevelImport" then
                    assert.falsy(node.modname:match("^titan%.uv%."), source .. ": " .. node.modname)
                    assert.falsy(node.modname:match("^titan%.async%."), source .. ": " .. node.modname)
                end
            end
        end
        for _, source in ipairs({"titan/async/runtime.native.titan", "titan/timer.native.titan", "titan/fs.native.titan",
                "titan/net.native.titan", "titan/os/stdio.native.titan"}) do
            local imports = {}
            for _, node in ipairs(parsed_source(source)) do
                if node._tag == "Ast.TopLevelImport" then imports[node.modname] = true end
            end
            assert.truthy(imports["titan.uv"], source)
        end
    end)

    -- Scheduling and sleep ownership are executable native contracts in the
    -- async.tests task and fatal contributors and timer/tests.
    -- The old source-string test required one timer/close callback per wake;
    -- the Runtime now owns one shared wake and an intrusive FIFO.

    it("retires explicit suspension and the exact Wait before terminal listeners", function()
        local task = read_file("titan/async/async.titan")
        local first = assert(task:find("local function clear_suspension(task: Task)", 1, true))
        local last = assert(task:find("\nend", first, true))
        local clear = task:sub(first, last - 1)
        for _, assignment in ipairs({"task.suspended = false", "task.resume_token = nil",
                "task.resume_pending = false", "task.suspend_cancel = nil"}) do
            assert.truthy(clear:find(assignment, 1, true), assignment)
        end
        first = assert(task:find("local function finish_task(task: Task, state: TaskStatus)", 1, true))
        last = assert(task:find("\nend", first, true))
        local finish = task:sub(first, last - 1)
        assert_ordered(finish, "clear_suspension(task)", "wait.phase = WAIT_RETIRED",
            "task.wait = nil", "task.state = state", "listeners[index].live = false",
            "listeners[index].listener(state)", "task.runtime.tasks[task.root_index] = nil")
    end)

    it("keeps SSL path loading high-level and PEM owners private", function()
        local ssl = read_file("titan/ssl.native.titan")
        local openssl_headers = {}
        for header in ssl:gmatch(
            'foreign import "openssl/([^"]+)"') do
            openssl_headers[#openssl_headers + 1] = header
        end
        assert.same({ "err.h", "x509v3.h", "pem.h", "ssl.h" },
            openssl_headers)
        assert.truthy(ssl:find(
            "explicit_client_context(fs.read_file(ca_file))", 1, true), ssl)
        assert.truthy(ssl:find(
            "local certificate_data = fs.read_file", 1, true), ssl)
        assert.truthy(ssl:find(
            "private_key_data = fs.read_file", 1, true), ssl)
        assert.truthy(ssl:find(
                "local default_client_context: foreign *SSL_CTX", 1, true),
            ssl)
        assert.truthy(ssl:find(
            "local default_client_context_owner: " ..
            "DefaultClientContextOwner?", 1, true), ssl)
        assert.truthy(ssl:find(
            "local function finalize_default_client_context(" ..
            "\n    owner: DefaultClientContextOwner)", 1, true), ssl)
        assert.truthy(ssl:find(
            "gc.finalizable<|DefaultClientContextOwner|>(" ..
            "\n      owner, finalize_default_client_context)",
            1, true), ssl)
        assert.falsy(ssl:find(
            "as DefaultClientContextOwner", 1, true), ssl)
        assert.truthy(ssl:find(
                "ffi.SSL_CTX_set_default_verify_paths(context)", 1, true),
            ssl)
        assert.truthy(ssl:find(
            "ffi.SSL_CTX_up_ref(context)", 1, true), ssl)
        for _, retired in ipairs({
            "SSL_CTX_load_verify_locations",
            "SSL_CTX_use_certificate_chain_file",
            "SSL_CTX_use_PrivateKey_file",
        }) do
            assert.falsy(ssl:find(retired, 1, true), retired)
        end
        assert.truthy(ssl:find('local uv = import "uv"', 1, true), ssl)
        assert.falsy(ssl:find('foreign import "uv.h"', 1, true), ssl)
        assert.falsy(ssl:find('uv.fs_', 1, true), ssl)
        assert.falsy(ssl:find('foreign import "lua.h"', 1, true), ssl)

        assert.same({
            "DefaultClientContextOwner", "ProgressWait", "Operation",
            "CleanupWait", "ChildDrain", "PemBlock",
            "CertificateResult", "PrivateKeyResult",
        }, local_record_declarations("titan/ssl.native.titan"))
        assert.same({ "OperationResult" },
            local_union_declarations("titan/ssl.native.titan"))
        local public = {}
        for _, name in ipairs(public_declarations("titan/ssl.native.titan")) do
            public[name] = true
        end
        for _, helper in ipairs({
            "DefaultClientContextOwner", "ProgressWait", "Operation",
            "CleanupWait", "ChildDrain", "OperationResult", "PemBlock",
            "CertificateResult", "PrivateKeyResult",
        }) do
            assert.falsy(public[helper], helper .. " leaked into ssl ABI")
        end
    end)

    it("keeps listener defaults in the high-level facades", function()
        local net = read_file("titan/net.native.titan")
        assert.truthy(net:find(
            "local actual_backlog = 128", 1, true), net)

        local ssl = read_file("titan/ssl.native.titan")
        assert.truthy(ssl:find(
                "local actual_private_key_file = certificate_file", 1, true),
            ssl)

        local http = read_file("titan/http/server.native.titan")
        assert.truthy(http:find("local actual_port = 80", 1, true), http)
        assert.truthy(http:find("local actual_port = 443", 1, true), http)
    end)

    it("cleans every standard module C environment header", function()
        local root = make_temp_dir()
        local tested, ok, output = pcall(function()
            local fragment = root .. "/inventory.mk"
            write_file(fragment, ".PHONY: __titan_header_inventory\n" ..
                "__titan_header_inventory:\n\t@printf '%s\\n' " ..
                "$(STDLIB_GENERATED_FOREIGN_HEADERS)\n")
            -- Keep the query independent of inherited jobserver descriptors
            -- and use a Makefile fragment supported by macOS's older Make.
            return run_argv({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "make", "--no-print-directory", "-s", "MAKE=false",
                "-f", "Makefile", "-f", fragment,
                "__titan_header_inventory",
            })
        end)
        remove_tree(root)
        assert.truthy(tested, ok)
        assert.truthy(ok, output)
        local expected = {}
        local context = resolver_options().context
        for _, module in ipairs(STDLIB_MODULES) do
            local source = assert(driver.resolve_source(context, "titan." .. module, "."))
            assert.truthy(file_exists(source.main), source.main)
            local stem = paths.to_slash(source.native_output):gsub("^%./", ""):gsub("[.]titan$", "")
            expected[#expected + 1] = "out/" .. stem .. ".ffi.h"
        end
        for _, header in ipairs({
            "titan/coroutine.titan.h", "titan/transfer.titan.h",
            "titan/uv/uv.titan.h", "titan/async/async.titan.h", "titan/http/http.titan.h",
            "titan/sqlite3/sqlite3.titan.h", "titan/lua/lua.titan.h",
            "titan/protobuf/protobuf.titan.h", "titan/thread/thread.titan.h",
        }) do
            expected[#expected + 1] = "out/" .. header
        end
        local actual = {}
        for header in output:gmatch("[^\r\n]+") do
            actual[#actual + 1] = header
        end
        table.sort(expected)
        table.sort(actual)
        assert.same(expected, actual)
        local makefile = read_file("Makefile")
        assert.truthy(makefile:find(
            "rm -f $(STDLIB_GENERATED_FOREIGN_HEADERS)", 1, true))
    end)

    it("parses titan.io as seven ordered Interfaces plus public helpers",
        function()
            local function source_type_name(typ)
                if typ._tag == "Ast.TypeString" then return "string" end
                if typ._tag == "Ast.TypeBoolean" then return "boolean" end
                if typ._tag == "Ast.TypeOption" then
                    return source_type_name(typ.basetype) .. "?"
                end
                error("unexpected titan.io source type " .. tostring(typ._tag))
            end

            local path = "titan/io.titan"
            local source = read_file(path)
            local ast, parse_error = parser.parse(path, source)
            assert.truthy(ast, parse_error and parse_error.label)

            local interfaces = {}
            for _, node in ipairs(ast) do
                if node._tag == "Ast.TopLevelInterface" then
                    local methods = {}
                    for _, method in ipairs(node.methods) do
                        local params = {}
                        for _, param in ipairs(method.params) do
                            params[#params + 1] =
                                param.name .. ":" ..
                                source_type_name(param.type)
                        end
                        local results = {}
                        for _, result in ipairs(method.rettypes) do
                            results[#results + 1] = source_type_name(result)
                        end
                        methods[#methods + 1] = {
                            name = method.name,
                            params = params,
                            results = results,
                        }
                    end
                    interfaces[#interfaces + 1] = {
                        name = node.name,
                        methods = methods,
                    }
                end
            end

            local read = {
                { name = "read", params = {}, results = { "string?" } },
                {
                    name = "read_until",
                    params = { "delimiter:string", "chop:boolean?" },
                    results = { "string?" },
                },
            }
            local write = {
                {
                    name = "write",
                    params = { "data:string" },
                    results = {},
                },
            }
            local close = {
                { name = "close", params = {}, results = {} },
            }
            local function combined_methods(...)
                local result = {}
                for _, group in ipairs({ ... }) do
                    for _, method in ipairs(group) do
                        result[#result + 1] = method
                    end
                end
                return result
            end
            assert.same({
                { name = "Reader", methods = combined_methods(read) },
                { name = "Writer", methods = combined_methods(write) },
                { name = "Closer", methods = combined_methods(close) },
                {
                    name = "ReaderWriter",
                    methods = combined_methods(read, write),
                },
                {
                    name = "ReaderCloser",
                    methods = combined_methods(read, close),
                },
                {
                    name = "WriterCloser",
                    methods = combined_methods(write, close),
                },
                {
                    name = "ReaderWriterCloser",
                    methods = combined_methods(read, write, close),
                },
            }, interfaces)
            assert.same({
                "print", "lines",
            }, public_declarations(path))
        end)

    it("retains public path documentation in serialized module metadata", function()
        local driver = require "titan-compiler.driver"
        local types = require "titan-compiler.types"
        local previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
        local loader
        local completed, failure = xpcall(function()
            local filename = assert(compiler_io.new_sync():realpath("titan/path.titan"))
            loader = driver.defaultloader({}, resolver_options({ analysis_only = true, source_roots = { ["titan.path"] = true },
            source_overrides = { ["titan.path"] = {
                kind = "generated", main = filename, files = { filename },
                contents = { [filename] = read_file(filename) },
            } }, }))
            local loaded, module, errors = loader("titan.path")
            assert.truthy(loaded, module)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            local serialized = types.serialize(module)
            local restored = assert(driver.decode_module_interface(serialized,
                "titan.path", "path documentation metadata"))
            assert.equal("Manipulate native filesystem path spelling without performing I/O.",
                restored._documentation.summary)
            assert.same(module._documentation, restored._documentation)
            local names = { "separator", "normalize", "basename", "dirname",
                "extension", "is_absolute", "join", "split", "to_slash",
                "from_slash", "volume" }
            assert.equal(#names, #restored.members)
            for _, name in ipairs(names) do
                local documentation = assert(restored.members[name]._documentation,
                    "missing path documentation for " .. name)
                assert.not_equal("", documentation.summary, name)
                assert.not_equal("", documentation.description, name)
                assert.same(module.members[name]._documentation, documentation, name)
                local usage, parameters, results = 0, 0, 0
                for _, tag in ipairs(documentation.tags) do
                    if tag.name == "usage" then usage = usage + 1 end
                    if tag.name == "param" then parameters = parameters + 1 end
                    if tag.name == "return" then results = results + 1 end
                end
                assert.equal(2, usage, name)
                assert.equal(name == "separator" and 0 or 1, parameters, name)
                assert.equal(name == "separator" and 0 or name == "split" and 2 or 1,
                    results, name)
            end
            local fixture = assert(loadfile(STDLIB_TYPES_FIXTURE))()
            assert.equal(fixture.path, serialized,
                "path's serialized public documentation fixture is stale")
        end, debug.traceback)
        local closed, close_error = true
        if loader then closed, close_error = driver.close_loader(loader) end
        driver.imported, types.registry = previous_imported, previous_registry
        assert.truthy(completed, failure)
        assert.truthy(closed, close_error)
    end)

    it("pins current metadata for all twenty-six standard modules",
        function()
            local expected = assert(loadfile(STDLIB_TYPES_FIXTURE))()
            local expected_uv = assert(loadfile(UV_TYPES_FIXTURE))()
            assert.equal(26, #STDLIB_ROOTS)
            assert.equal(expected.uv, expected_uv,
                "standalone titan.uv metadata fixture is stale")

            local driver = require "titan-compiler.driver"
            local types = require "titan-compiler.types"
            local transfer = assert(driver.decode_module_interface(
                expected.transfer, "titan.transfer", STDLIB_TYPES_FIXTURE))
            assert.equal(expected.transfer, types.serialize(transfer))

            for _, record_name in ipairs({
                "ChannelReader", "ChannelWriter", "Completion", "Receiver",
            }) do
                local qualified = "titan.async." .. record_name
                assert.truthy(expected.async:find(
                        "Record('" .. qualified .. "',{},{},{", 1, true),
                    record_name .. " is missing from async metadata")
                assert.falsy(expected.async:find(
                        "Field('" .. qualified .. "'", 1, true),
                    record_name .. " exposed a local field")
                assert.falsy(expected.async:find(
                        "StaticMethod('" .. qualified .. "', 'new'", 1, true),
                    record_name .. " exposed its local constructor")
            end

            local support = require "titan"
            local container = installed_stdlib_container()
            local wanted = {}
            for _, root in ipairs(STDLIB_ROOTS) do
                local name = assert(root:match("^titan%.(.+)$"))
                wanted[name] = true
                assert.truthy(expected[name],
                    "missing standard-library type fixture " .. name)
                local types_function, load_error = support._loadlib(
                    container, "titan_" .. name .. "_types")
                assert.truthy(types_function, load_error)
                assert.equal(expected[name], assert(types_function()), root)
            end
            for name in pairs(expected) do
                assert.truthy(wanted[name],
                    "unexpected standard-library type fixture " .. name)
            end
        end)

    -- The provider carries only the standard modules. The `titan` support
    -- module is a separate lib/lua/5.5 native module.
    it("exports twenty-six DSO openers and no support opener",
        function()
            assert.equal(26, #STDLIB_MODULES)
            assert.equal(26, #STDLIB_ROOTS)

            local container = installed_stdlib_container()
            local ok, output, why, code
            if platform.windows then
                ok, output, why, code = run_argv({
                    "llvm-readobj", "--coff-exports", container,
                })
            else
                ok, output, why, code = run_argv(tool_argv(
                    "NM", "nm", "-g", container))
            end
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local wanted = {}
            for _, module in ipairs(STDLIB_MODULES) do
                wanted["luaopen_titan_" .. module] = true
            end
            local found = {}
            for line in output:gmatch("[^\r\n]+") do
                local symbol = platform.windows and line:match("^%s*Name: (%S+)%s*$")
                    or not platform.windows and line:match("(%S+)%s*$")
                if symbol and symbol:sub(1, 1) == "_" then
                    symbol = symbol:sub(2)
                end
                if symbol and (symbol == "luaopen_titan" or
                        symbol:match("^luaopen_titan_")) then
                    assert.truthy(wanted[symbol],
                        "unexpected Titan opener " .. symbol)
                    found[symbol] = true
                end
            end
            assert.equal(26, (function()
                local count = 0
                for _ in pairs(found) do count = count + 1 end
                return count
            end)())
            assert.same(wanted, found)
        end)

    it("keeps bundled SSL, HTTP, and SQLite implementation symbols private", function()
        local argv
        if platform.windows then
            argv = { "llvm-readobj", "--coff-exports", installed_stdlib_container() }
        else
            local host_ok, host_output, host_why, host_code =
                run_argv({ "uname", "-s" })
            assert.truthy(host_ok, host_output .. "\n(" ..
                tostring(host_why) .. ", " .. tostring(host_code) .. ")")
            local nm_flags = host_output:match("^%s*Darwin%s*$") and
                { "-gU" } or { "-D", "-g" }
            argv = tool_argv("NM", "nm")
            for _, flag in ipairs(nm_flags) do argv[#argv + 1] = flag end
            argv[#argv + 1] = installed_stdlib_container()
        end
        local ok, output, why, code = run_argv(argv)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local private_symbols = {
            "llhttp_execute", "SSL_do_handshake", "BIO_read",
            "sqlite3_open_v2", "sqlite3_prepare_v2", "sqlite3_step",
        }
        for _, symbol in ipairs(private_symbols) do
            assert.falsy(nm_has_symbol(output, symbol),
                "private symbol is exported: " .. symbol)
        end
    end)

    it("pins the public fs facade and its portable location bridges",
        function()
            local path = "titan/fs.native.titan"
            assert.same({
                "File", "Stat", "Stat.new", "open", "File:read",
                "File:read_until", "File:write", "File:flush",
                "File:close", "File:is_closed", "File:to_transfer_payload",
                "File.from_transfer_payload", "read_file",
                "write_file", "stat", "lstat", "tmpname", "tmpdir",
                "homedir", "pwd", "chdir", "mkdir", "unlink", "rmdir",
                "rename", "list", "realpath", "Watcher", "WatcherEvent",
                "WatcherEvent.created", "WatcherEvent.deleted",
                "WatcherEvent.modified", "WatcherEvent.error", "watcher",
                "Watcher:watch", "Watcher:stop", "Watcher:is_watching",
                "Watcher:clear", "Watcher:poll",
            }, public_declarations(path))
            local source = read_file(path)
            assert.truthy(source:find(
                "function stat(path: string): Stat?", 1, true))
            assert.truthy(source:find(
                "function lstat(path: string): Stat?", 1, true))
            assert_ordered(source,
                "function tmpname(): string",
                'local template = sized_path("fs.tmpname", uv.os_tmpdir)',
                'defer file:close_with("fs.tmpname.close")',
                "return uv.fs_mkstemp(loop, request, template, callback)",
                "return uv.fs_get_path(request) as string",
                "function tmpdir(): string",
                'return sized_path("os.tmpdir", uv.os_tmpdir)',
                "function homedir(): string",
                'return sized_path("os.homedir", uv.os_homedir)',
                "function pwd(): string",
                'return sized_path("fs.pwd", uv.cwd)',
                "function chdir(path: string)",
                'check_status(uv.chdir(checked_path(path, "fs.chdir")), "fs.chdir")')
        end)

    it("pins the public native os process and stdio facade", function()
        local expected = {
            "Date", "Date.new", "ExitStatus", "ExitStatus.new",
            "SpawnConfig", "SpawnOption",
            "InputStream", "OutputStream", "Process", "InputOutputStream", "stdin", "stdout",
            "stderr", "clock", "difftime", "date", "setlocale", "time",
            "getenv", "setenv", "unsetenv", "cwd", "chdir", "homedir",
            "tmpdir", "hostname", "exepath", "pid", "ppid",
            "with_stdin", "with_stdout", "with_stderr",
            "with_parent_stdin", "with_parent_stdout", "with_parent_stderr",
            "with_merged_output", "with_env", "spawn", "Process:wait",
            "Process:kill", "Process:is_running", "OutputStream:write",
            "OutputStream:shutdown",
            "OutputStream:close", "OutputStream:is_tty",
            "OutputStream:kind", "InputStream:read",
            "InputStream:read_until", "InputStream:close",
            "InputStream:is_tty", "InputStream:kind", "exit",
            "wait_signal",
            "OutputStream.discard_transfer_payload", "InputStream.discard_transfer_payload",
            "OutputStream:to_transfer_payload", "OutputStream.from_transfer_payload",
            "InputStream:to_transfer_payload", "InputStream.from_transfer_payload",
            "InputOutputStream:read", "InputOutputStream:read_until",
            "InputOutputStream:write", "InputOutputStream:wait",
            "InputOutputStream:close", "InputOutputStream:to_transfer_payload",
            "InputOutputStream.from_transfer_payload", "popen",
        }
        local actual = {}
        for _, source in ipairs(host_selected_sources(
                makefile_words("OS_TITAN_SOURCES"))) do
            for _, name in ipairs(public_declarations(source)) do
                actual[#actual + 1] = name
            end
            assert.falsy(read_file(source):find("os_stdio_is_closed", 1, true))
        end
        table.sort(expected)
        table.sort(actual)
        assert.same(expected, actual)
    end)

    it("centralizes every peg and string export in the folder main",
        function()
            assert.same({
                "Pattern", "Match", "Rule", "Locale", "Locale.new", "Definition",
                "Pattern:match", "Match:values", "rule", "grammar", "locale",
                "set_max_stack", "version", "literal", "any", "succeed",
                "fail", "runtime", "set", "ranges", "utf_range",
                "variable", "behind", "throw", "sequence", "choice",
                "difference", "lookahead", "negative", "at_least",
                "at_most", "zero_or_more", "one_or_more", "optional",
                "capture", "constant", "match_time", "back_capture",
                "argument", "position", "substitution", "table_capture",
                "fold_capture", "group", "select_capture",
                "template_capture", "query_capture", "function_capture",
                "line_column", "define", "define_value", "compile",
                "match", "gsub", "update_locale",
            }, public_declarations("titan/peg/peg.titan"))
            for _, contributor in ipairs({
                "combinators", "native",
                "relabel", "relabel_parser",
            }) do
                assert.same({}, public_declarations(
                    "titan/peg/" .. contributor .. ".titan"))
            end

            assert.same({
                "Span", "Span.new", "RegexMatch", "Regex",
                "StringReader", "StringWriter", "len", "sub",
                "reverse", "lower", "upper", "rep", "byte", "char",
                "tostring", "reader", "StringReader:read",
                "StringReader:read_until", "StringReader:close", "writer",
                "StringWriter:write", "StringWriter:drain",
                "StringWriter:close", "find", "format", "pack", "packsize",
                "unpack", "compile_regex", "Regex:source",
                "Regex:group_count", "Regex:match", "Regex:gmatch",
                "Regex:gsub", "RegexMatch:span", "RegexMatch:group_count",
                "RegexMatch:group_span", "RegexMatch:whole",
                "RegexMatch:group", "RegexMatch:values", "match",
                "gmatch", "matches", "split", "gsub",
            }, public_declarations("titan/string/string.titan"))
            for _, contributor in ipairs({
                "bytes", "format", "pack",
                "regex_api", "regex_compile", "regex_parser",
            }) do
                assert.same({}, public_declarations(
                    "titan/string/" .. contributor .. ".titan"))
            end
        end)

    it("keeps the regex AST union and parser state private",
        function()
            assert.same({
                "RegexCompileState",
            }, local_record_declarations(
                "titan/string/regex_compile.titan"))
            assert.same({
                "ParsedRegex",
                "RegexQuantifier", "RegexClassItem", "RegexParseFrame",
                "RegexParseState",
            }, local_record_declarations(
                "titan/string/regex_parser.titan"))
            assert.same({
                "RegexNode",
            }, local_union_declarations(
                "titan/string/regex_parser.titan"))
        end)

    it("passes native tools through the standard-library build",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            for _, contract in ipairs({
                "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
                "STDLIB_COMPILER_ENV = CC=$(call make_shell_quote,$(CC))",
                "AR=$(call make_shell_quote,$(AR)) " ..
                "RANLIB=$(call make_shell_quote,$(RANLIB))",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end

            file = assert(io.open("titan-0.6.0-1.rockspec", "rb"))
            local rockspec = file:read("*a")
            file:close()
            for _, contract in ipairs({
                'AR = "$(AR)"',
                'RANLIB = "$(RANLIB)"',
            }) do
                assert.truthy(rockspec:find(contract, 1, true), contract)
            end
        end)

    it("uses initialized Lua sources and the checkout support module",
        function()
            local makefile = read_file("Makefile")
            for _, contract in ipairs({
                "LUA_SOURCE_READY := $(LUA_DIR)/src/lua.h",
                "git submodule update --init",
                'package.cpath="./titan-runtime/bootstrap/?.so;" .. package.cpath',
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            assert.falsy(makefile:find(
                'strcmp(sym, "luaopen_titan_uv")', 1, true), makefile)
            for _, forbidden in ipairs({ "LUA_EXTRACTED", "LUA_TARBALL",
                    "LUA_PATCH_FILE", 'git apply --directory="$(LUA_DIR)"' }) do
                assert.falsy(makefile:find(forbidden, 1, true), forbidden)
            end
        end)

    it("keys every runtime object and archive member to the selected Lua SDK",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            for _, contract in ipairs({
                "TITAN_RUNTIME_LUA_SOURCE_PATH ?= $(LUA_SDK_SOURCE_PATH)",
                "AR=$(call make_shell_quote,$(LUA_AR))",
                "RANLIB=$(call make_shell_quote,$(LUA_RANLIB))",
                "$(TITAN_RUNTIME_LUA_HEADERS) | " ..
                "$(TITAN_RUNTIME_LUA_LIB) $(LIBBT_LIB)",
                "$(wildcard $(LPEGLABEL_LUA_HEADERS)) $(LUA_SDK_PREREQ)",
                "$(wildcard $(ROCK_LUA_HEADERS)) $(LUA_SDK_PREREQ)",
                "LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)",
                "STDLIB_NATIVE_PREREQS := $(TITAN_RUNTIME_OBJECTS)",
                "$(STDLIB_EXTRA_OBJECTS)",
                "STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)",
                'rm -f "$$rocks_tree/lib/libtitan.a"',
                'install -p -m 0644 "$(TITAN_RUNTIME_LIB)" ' ..
                '"$$version_dir/libtitan.a"',
                "rm -f $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_QUALIFIED_SOS) " ..
                "$(STDLIB_SOS)",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            assert.falsy(makefile:find(
                "UV_CONFIG_STAMP := $(LIBUV_BUILD_DIR)/", 1, true), makefile)
            local _, prepared_count = makefile:gsub(
                "TITAN_RUNTIME_PREBUILT=1", "")
            -- Compilation, snapshots, and publication share this environment.
            assert.equal(1, prepared_count, makefile)

            file = assert(io.open("titan-compiler/driver.lua", "rb"))
            local driver_source = file:read("*a")
            file:close()
            assert.truthy(driver_source:find(
                    'platform.getenv("TITAN_RUNTIME_PREBUILT") ~= "1"', 1, true),
                driver_source)
            local _, include_count = makefile:gsub(
                "%-I %$%(TITAN_RUNTIME_LUA_SOURCE_PATH%)", "")
            assert.equal(3, include_count, makefile)
        end)

    -- The support module is ltitanlib plus the shared path code, linked as a
    -- loadable Lua bundle on macOS; it never carries the runtime archive and
    -- exports only luaopen_titan.
    it("links the titan support module from its two objects as a Lua bundle",
        function()
            if platform.windows then
                pending("macOS bundle linker recipe and Unix Lua SDK")
                return
            end
            local ok, output, why, code = run_argv({
                "make", "--no-print-directory", "-Bn",
                "HOST_OS=Darwin", "TITAN_EXTRA_LDFLAGS=",
                "LUA_INSTALL_STAMP=/dev/null", "--old-file=/dev/null",
                "titan-runtime/bootstrap/titan.so",
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local normalized = output:gsub("%s+", " ")
            -- Match the loadable-bundle link and its inputs, not the exact
            -- flag list: the export restriction belongs to the installed
            -- module's behavior test.
            local link = assert(normalized:match(
                '%-bundle %-undefined dynamic_lookup[^;]-%-o "%$tmp" ([^;]*);'),
                normalized)
            -- Make prints the recipe's line continuations verbatim.
            local inputs = {}
            for word in link:gmatch("%S+") do
                if word ~= "\\" then inputs[#inputs + 1] = word end
            end
            assert.same({ "titan-runtime/ltitanlib.o", "titan-runtime/titan_path.o" },
                inputs)
            assert.falsy(normalized:find('-shared -o "$tmp"', 1, true), normalized)
            -- A direct support build must not rebuild unrelated native
            -- dependencies (libbacktrace, the runtime archive).
            assert.falsy(normalized:find("libbacktrace", 1, true), normalized)
        end)

    it("installs the compiler SDK without building standard-library dependencies", function()
        if platform.windows then
            pending("Unix compiler SDK Make target; Windows uses its native builder")
            return
        end
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            for _, directory in ipairs({ "titan-compiler", "lua-source" }) do
                assert(lfs.mkdir(root .. "/" .. directory))
            end
            local fixtures = {
                ["titan-compiler/fixture.lua"] = "return true\n",
                ["titanc"] = "#!/bin/sh\nexit 0\n",
                ["THIRD_PARTY_NOTICES.md"] = "notices\n",
                ["LICENSE"] = "license\n",
                ["fixture.h"] = "runtime header\n",
                ["ffi.h"] = "ffi header\n",
                ["lua-source/lua.c"] = "Lua source\n",
                ["lua-source/lua.h"] = "Lua header\n",
                ["lua-source/liblua.a"] = "Lua archive\n",
                ["libtitan.a"] = "runtime archive\n",
                ["libbacktrace.a"] = "backtrace archive\n",
                ["bootstrap/titan.so"] = "support module\n",
                ["prepared"] = "prepared SDK inputs\n",
                ["fixture.mk"] = "all stdlib libuv lpeglabel openssl llhttp sqlite3:\n" ..
                    "\t@echo unexpected stdlib dependency >&2; exit 91\n",
            }
            assert(lfs.mkdir(root .. "/bootstrap"))
            for name, contents in pairs(fixtures) do
                write_file(root .. "/" .. name, contents)
            end
            local prefix = root .. "/sdk"
            local ok, output = run_argv({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "make", "--no-print-directory", "-s", "-j1", "-C", root,
                "-f", lfs.currentdir() .. "/Makefile", "-f", "fixture.mk",
                "PREFIX=" .. prefix, "ROCKS_TREE=" .. prefix,
                "HOST_OS=Linux", "OPENSSL_MODE=bundled", "TITAN_BUILD_PROFILE=validation",
                "TITAN_RUNTIME_SDK_PREREQS=prepared", "TITAN_RUNTIME_LIB=libtitan.a",
                "TITAN_SUPPORT_MODULE=bootstrap/titan.so", "LIBBT_LIB=libbacktrace.a",
                "TITAN_RUNTIME_LUA_SOURCE_PATH=lua-source",
                "TITAN_RUNTIME_LUA_LIB=lua-source/liblua.a",
                "TITAN_SDK_ROOT_HEADERS=fixture.h", "TITAN_SDK_NAMESPACED_HEADERS=ffi.h",
                "--old-file=bootstrap/titan.so", "MAKE=false", "install-compiler-sdk",
            })
            assert.truthy(ok, output)
            for source, destination in pairs({
                ["titan-compiler/fixture.lua"] = "share/lua/5.5/titan-compiler/fixture.lua",
                titanc = "bin/titanc", ["THIRD_PARTY_NOTICES.md"] = "etc/THIRD_PARTY_NOTICES.md",
                ["libtitan.a"] = "lib/titan/0.6/libtitan.a",
                ["libbacktrace.a"] = "lib/libbacktrace.a",
                ["bootstrap/titan.so"] = "lib/lua/5.5/titan.so",
                ["fixture.h"] = "include/fixture.h", ["ffi.h"] = "include/titan/ffi.h",
                ["lua-source/lua.c"] = "src/lua-5.5.1/lua.c",
                ["lua-source/lua.h"] = "src/lua-5.5.1/lua.h",
                ["lua-source/liblua.a"] = "lib/liblua.a",
            }) do
                assert.equal(fixtures[source], read_file(prefix .. "/" .. destination), destination)
            end
            assert.equal("validation\n", read_file(prefix .. "/etc/titan/build-profile"))
            assert.falsy(lfs.attributes(prefix .. "/lib/titan/0.6/titan.so"))
            assert.falsy(lfs.attributes(prefix .. "/lib/titan/0.6/titan.a"))
            assert.falsy(lfs.attributes(prefix .. "/share/lua/5.5/titan"))
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)


    it("builds the pinned libuv source through CMake", function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        assert.truthy(makefile:find(
            "$(LIBUV_LIB): $(LIBUV_EXTRACTED)",
            1, true), makefile)
        assert.falsy(makefile:find(
                "$(LIBUV_LIB): $(LIBUV_EXTRACTED) Makefile", 1, true),
            makefile)
        assert.truthy(makefile:find(
            '\n\t+$(RECURSIVE_WRAPPER_GUARD) cmake --build ' ..
            '"$(LIBUV_BUILD_DIR)" --target uv_a',
            1, true), makefile)
    end)


    it("uses bundled headers, payload and Linux feature macros",
        function()
            local ok, output, why, code = run_make("Linux")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.truthy(output:find(
                "LIBUV_CPPFLAGS=-Ilibuv-v1.53.0/include -D_GNU_SOURCE", 1, true), output)
            assert.truthy(output:find(
                "LIBUV_LDFLAGS=-lpthread -lrt",
                1, true), output)
        end)

    it("does not add the Linux-only macro on macOS", function()
        local ok, output, why, code = run_make("Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-Ilibuv-v1.53.0/include",
            1, true), output)
        assert.falsy(output:find("-D_GNU_SOURCE", 1, true), output)
    end)

    it("rejects obsolete libuv mode selection before any build", function()
        for _, mode in ipairs({ "system", "bundled" }) do
            local ok, output = run_argv({
                "make", "--no-print-directory", "LIBUV_MODE=" .. mode,
                "help",
            })
            assert.falsy(ok, output)
            assert.truthy(output:find(
                "LIBUV_MODE is no longer supported; Titan always bundles patched libuv",
                1, true), output)
        end
    end)

    it("defaults only OpenSSL to its system provider", function()
        for _, inherited in ipairs({
            {},
            {
                "OPENSSL_MODE=bundled",
                "MAKEFLAGS=-j --jobserver-auth=998,999 -- OPENSSL_MODE=bundled",
                "MFLAGS=-j --jobserver-auth=998,999",
                "GNUMAKEFLAGS=--warn-undefined-variables",
                "MAKELEVEL=1", "MAKEOVERRIDES=OPENSSL_MODE=bundled",
            },
        }) do
            local argv = { "env", table.unpack(inherited) }
            -- This standalone defaults query cannot use a parent Make
            -- jobserver through the Lua pipe or inherit its command overrides.
            for _, argument in ipairs({
                "env", "-u", "OPENSSL_MODE", "-u", "MAKEFLAGS",
                "-u", "MFLAGS", "-u", "GNUMAKEFLAGS", "-u", "MAKELEVEL",
                "-u", "MAKEOVERRIDES", "make", "--no-print-directory", "-s",
                "--eval=print-native-policy: ; @echo $(OPENSSL_MODE) $(LIBUV_EXTRA_OBJECTS) $(LLHTTP_ARCHIVE) $(SQLITE3_ARCHIVE)",
                "print-native-policy",
            }) do
                argv[#argv + 1] = argument
            end
            local ok, output = run_argv(argv)
            assert.truthy(ok, output)
            assert.equal("system libuv-build/libuv.a llhttp-build/libtitan-llhttp.a " ..
                "sqlite3-build/libtitan-sqlite3.a\n", output)
        end
    end)

    it("builds one provider pair with native support and one libuv policy",
        function()
            if platform.windows then
                pending("Unix Make paired DSO/static-provider linker recipes")
                return
            end
            local ok, output, why, code = run_uv_dry_run()
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local command, normalized = stdlib_command(output)
            assert.truthy(command:find(
                    "./titanc --lua ", 1, true),
                command)
            assert.equal(1, count_plain(command,
                "-X lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            -- The provider never links the `titan` support module.
            assert.falsy(command:find("ltitanlib.o", 1, true), command)
            assert.truthy(command:find([[CC='ccache cc']], 1, true), command)
            assert.truthy(command:find([[AR='review-ar']], 1, true), command)
            assert.truthy(command:find([[RANLIB='review-ranlib']], 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. LLHTTP_NATIVE_INCLUDE .. " " ..
                SQLITE3_NATIVE_INCLUDE .. " " .. BUNDLED_OPENSSL_INCLUDES ..
                " -Ilibuv-v1.53.0/include -D_GNU_SOURCE'",
                1, true), command)
            assert.truthy(command:find(
                [[TITAN_EXTRA_CFLAGS='-DUSER_C=1 -fno-strict-aliasing']],
                1, true), command)
            local bundled_flags =
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lrt -lpthread']]
            assert.equal(1, count_plain(command, bundled_flags), command)
            assert.equal(1, count_plain(command, "libuv-build/libuv.a"), command)

            ok, output, why, code = run_uv_dry_run("Darwin")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            command = stdlib_command(output)
            assert.equal(1, count_plain(command,
                    "-X lpeglabel-build/libtitan-lpeglabel.a " ..
                    "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD),
                command)
            assert.equal(1, count_plain(command,
                    [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lpthread']]),
                command)
        end)

    it("keeps system OpenSSL as ordered final-link inputs", function()
            if platform.windows then
                pending("Unix Make pkg-config and static-provider linker recipes")
                return
            end
        local root = make_temp_dir()
        local fake_pkg_config = root .. "/pkg-config"
        write_file(fake_pkg_config, [[#!/bin/sh
case "$1" in
    --exists|--atleast-version=*) exit 0 ;;
    --modversion) echo 3.5.7 ;;
    --cflags) echo "-I/opt/openssl/include -DOPENSSL_FAKE_PKG=1" ;;
    --libs) echo "-L/opt/openssl/lib -lssl -lcrypto" ;;
    *) echo "unexpected fake OpenSSL pkg-config arguments: $*" >&2; exit 2 ;;
esac
]])
        local ok, output, why, code = run_argv({
            "chmod", "+x", fake_pkg_config,
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local tested, test_error = xpcall(function()
            ok, output, why, code = run_uv_dry_run(
                "Linux", nil, "system", fake_pkg_config)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local command = stdlib_command(output)
            assert.equal(1, count_plain(command,
                "-X lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_SYSTEM_PAYLOAD), command)
            assert.falsy(command:find("openssl-build/libssl.a", 1, true),
                command)
            assert.falsy(command:find("openssl-build/libcrypto.a", 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. LLHTTP_NATIVE_INCLUDE .. " " ..
                SQLITE3_NATIVE_INCLUDE ..
                " -I/opt/openssl/include -DOPENSSL_FAKE_PKG=1 " ..
                "-DOPENSSL_API_COMPAT=30000 " ..
                "-Ilibuv-v1.53.0/include -D_GNU_SOURCE'", 1, true), command)
            assert.equal(1, count_plain(command,
                    [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lrt -L/opt/openssl/lib -lssl -lcrypto']]),
                command)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("rebuilds the same provider pair when any reviewed source changes",
        function()
            if platform.windows then
                pending("Unix Make paired-provider source dependency graph")
                return
            end
            local sources = {
                "titan/coroutine.titan",
                "titan/timer.native.titan", "titan/timer.browser.titan", "titan/io.titan", "titan/fs.native.titan",
                "titan/net.native.titan", "titan/ssl.native.titan", "titan/url.titan",
                "titan/path.titan",
                "titan/peg/peg.titan",
                "titan/peg/combinators.titan", "titan/peg/native.titan",
                "titan/peg/relabel.titan",
                "titan/peg/relabel_parser.titan",
                "titan/string/string.titan",
                "titan/string/bytes.titan", "titan/string/format.titan",
                "titan/string/pack.titan", "titan/string/regex_api.titan",
                "titan/string/regex_compile.titan",
                "titan/string/regex_parser.titan",
                "titan/math.titan",
                "titan/iteration.titan", "titan/gc.titan", "titan/test.titan",
            }
            for _, ensemble in ipairs({
                "UV_TITAN_SOURCES", "ASYNC_TITAN_SOURCES", "OS_TITAN_SOURCES", "STDLIB_HTTP_SOURCES",
                "SQLITE3_TITAN_SOURCES", "JSON_TITAN_SOURCES", "PROTOBUF_TITAN_SOURCES", "WEBSOCKET_TITAN_SOURCES", "LUA_TITAN_SOURCES",
                "THREAD_TITAN_SOURCES", "ASYNC_TITAN_HEADERS", "OS_TITAN_HEADERS", "SQLITE3_TITAN_HEADERS",
                "STRING_TITAN_HEADERS", "LUA_TITAN_HEADERS", "THREAD_TITAN_HEADERS",
            }) do
                for _, source in ipairs(makefile_words(ensemble)) do
                    sources[#sources + 1] = source
                end
            end
            for _, source in ipairs(sources) do
                assert.equal("file", lfs.attributes(source, "mode"), source)
                local ok, output, why, code =
                    run_uv_dry_run("Linux", source)
                assert.truthy(ok, source .. ": " .. output .. "\n(" ..
                    tostring(why) .. ", " .. tostring(code) .. ")")
                local command, normalized = stdlib_command(output)
                assert.equal(1, count_plain(command,
                    "./titanc --lua "), command)
                assert.truthy(command:find(
                    "-X lpeglabel-build/libtitan-lpeglabel.a " ..
                    "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD,
                    1, true), command)
                assert.falsy(normalized:find("titan/coroutine.so:", 1, true),
                    source .. ": " .. normalized)
            end
        end)


    it("retries LuaRocks dependency acquisition in one warm prefix",
        function()
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local fake = root .. "/fake-luarocks.sh"
                local counter = root .. "/attempts"
                write_file(fake, [==[#!/usr/bin/env bash
set -eu
counter_file=$1
success_on=$2
shift 2
if [[ $# -ne 2 || $1 != "spaced sentinel" ||
      $2 != "--literal=two words" ]]; then
    exit 74
fi
count=$(cat "$counter_file")
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
if [[ $count -lt $success_on ]]; then
    exit 73
fi
]==])

                local function run_case(success_on)
                    write_file(counter, "0\n")
                    return run_argv({
                        "env",
                        "TITAN_CI_LUAROCKS_RETRY_DELAY_SECONDS=0",
                        "bash",
                        "spec/support/ci_retry_luarocks_dependencies.sh",
                        "bash",
                        fake,
                        counter,
                        tostring(success_on),
                        "spaced sentinel",
                        "--literal=two words",
                    })
                end

                local ok, output, why, code = run_case(1)
                assert.truthy(ok, output)
                assert.equal("1\n", read_file(counter))

                ok, output, why, code = run_case(3)
                assert.truthy(ok, output)
                assert.equal("3\n", read_file(counter))
                assert.truthy(output:find("attempt 1/3, exit 73", 1, true),
                    output)
                assert.truthy(output:find("attempt 2/3, exit 73", 1, true),
                    output)

                ok, output, why, code = run_case(4)
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(73, code)
                assert.equal("3\n", read_file(counter))
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("selects checkout compiler edits through the real LuaRocks Busted launcher",
        function()
            if platform.windows then
                pending("Unix LuaRocks shell launcher and static runtime SDK resolution")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local prefix = installed_prefix.active()
                local launcher = prefix .. "/bin/busted"
                local installed_types =
                    prefix .. "/share/lua/5.5/titan-compiler/types.lua"
                local installed_contents = read_file(installed_types)
                local compiler = root .. "/titan-compiler"
                for _, directory in ipairs({ "titan-compiler", "c-parser" }) do
                    for _, source in ipairs(source_inventory.lua_files(directory)) do
                        local destination = root .. "/" .. source
                        local parent = assert(destination:match("^(.+)/[^/]+$"))
                        if not lfs.attributes(parent) then
                            local mkdir_ok, mkdir_output = run_argv({
                                "mkdir", "-p", parent,
                            })
                            assert.truthy(mkdir_ok, mkdir_output)
                        end
                        write_file(destination, read_file(source))
                    end
                end
                assert(lfs.mkdir(root .. "/titan-runtime"))
                write_file(root .. "/titan-runtime/titan.c",
                    "/* source checkout marker */\n")
                write_file(root .. "/Makefile", "# source checkout marker\n")
                assert(lfs.mkdir(root .. "/spec"))
                assert(lfs.mkdir(root .. "/spec/support"))
                write_file(root .. "/spec/support/checkout_busted.lua",
                    read_file("spec/support/checkout_busted.lua"))
                local local_types = compiler .. "/types.lua"
                local changed, replacements = read_file(
                    "titan-compiler/types.lua"):gsub(
                        'then return "integer"',
                        'then return "checkout-only-integer"', 1)
                assert.equal(1, replacements)
                write_file(local_types, changed)
                local report = root .. "/resolution.lua"
                write_file(root .. "/resolution_spec.lua", [==[
local assert = require "luassert"
local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"
local lpeglabel = require "lpeglabel"
assert.equal(5, lpeglabel.match(lpeglabel.P("kept"), "kept"))
local context = driver.new_resolver_context()
assert(driver.initialize_layout(context))
assert(driver.initialize_platform(context))
local runtime_inputs = driver.INSTALLED
    and driver.installed_link_inputs(driver.INSTALL_PATHS, driver.IS_DARWIN)
    or driver.source_link_inputs()
local fields = {
    cpath = package.cpath,
    root = driver.TITAN_ROOT,
    installed = driver.INSTALLED,
    source_checkout = driver.SOURCE_CHECKOUT,
    include = driver.INCLUDE_PATH,
    lua_source = driver.LUA_SOURCE_PATH,
    foreign_includes = table.concat(driver.foreign_include_dirs(), "\n"),
    runtime_inputs = table.concat(runtime_inputs, "\n"),
    provider = assert(package.searchpath("titan", package.cpath)),
    lpeglabel = assert(package.searchpath("lpeglabel", package.cpath)),
    behavior = types.tostring(types.Integer()),
    source = debug.getinfo(types.tostring, "S").source,
    driver_source = debug.getinfo(driver.installed_paths, "S").source,
    cdriver_source = debug.getinfo(cdriver.process_file, "S").source,
}
assert(driver.close_resolver_context(context))
local report = assert(io.open(os.getenv("TITAN_BUSTED_RESOLUTION_REPORT"), "wb"))
report:write("return {\n")
for key, value in pairs(fields) do
    report:write(string.format("[%q] = %q,\n", key, value))
end
assert(report:write("}\n"))
assert(report:close())
it("uses the edited checkout compiler", function()
    assert.equal("checkout-only-integer", fields.behavior)
    assert.equal("@./titan-compiler/types.lua", fields.source)
    assert.equal("@./titan-compiler/driver.lua", fields.driver_source)
    assert.equal("@./c-parser/cdriver.lua", fields.cdriver_source)
end)
it("checks installed Lua headers with the direct checkout checker", function()
    local parser = require "titan-compiler.parser"
    local checker = require "titan-compiler.checker"
    local source = [[
        foreign import "lua.h"
        local function stack_size(state: foreign *lua_State): integer
            return ffi.lua_gettop(state) as integer
        end
    ]]
    local ast = assert(parser.parse("installed_header.titan", source))
    local _, errors = checker.check(
        "installed_header", ast, source, "installed_header.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
end)
]==])
                local function run_fixture(profile, omit_root)
                    local argv = {
                        "bash", "-c",
                        'cd "$1" && shift && exec "$@"',
                        "titan-busted-resolution", root,
                        "env",
                        "-u", "LUA_PATH_5_5",
                        "-u", "LUA_CPATH",
                        "-u", "LUA_CPATH_5_5",
                        "-u", "TITAN_ROOT",
                    }
                    if not omit_root then
                        argv[#argv + 1] = "TITAN_ROOT=" .. prefix
                    end
                    for _, word in ipairs({
                        "LUA_PATH=./?.lua;./?/init.lua;;",
                        "TITAN_PROBE_CACHE_DISABLE=1",
                        "TITAN_BUSTED_RESOLUTION_REPORT=" .. report,
                        launcher, "resolution_spec.lua",
                    }) do
                        argv[#argv + 1] = word
                    end
                    if profile then
                        argv[#argv + 1] = "--run=" .. profile
                    end
                    return run_argv(argv)
                end

                -- The generated launcher puts the installed compiler before
                -- even an explicit checkout-first LUA_PATH.
                local ok, output, why, code = run_fixture()
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(1, code)
                local installed = assert(loadfile(report))()
                assert.equal("integer", installed.behavior)
                assert.equal("@" .. installed_types, installed.source)
                assert.equal("@" .. prefix ..
                    "/share/lua/5.5/titan-compiler/driver.lua",
                    installed.driver_source)
                assert.equal("@" .. prefix ..
                    "/share/lua/5.5/c-parser/cdriver.lua",
                    installed.cdriver_source)
                assert.is_true(installed.installed)
                assert.is_false(installed.source_checkout)
                assert.truthy(output:find("checkout-only-integer", 1, true),
                    output)

                write_file(root .. "/.busted", read_file(".busted"))
                ok, output, why, code = run_fixture()
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(1, code)
                assert.same(installed, assert(loadfile(report))())

                assert(os.remove(report))
                ok, output, why, code = run_fixture("checkout", true)
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(1, code)
                assert.truthy(output:find(
                    "checkout Busted profile requires TITAN_ROOT",
                    1, true), output)
                assert.falsy(file_exists(report))

                ok, output = run_fixture("checkout")
                assert.truthy(ok, output)
                local checkout = assert(loadfile(report))()
                assert.equal("checkout-only-integer", checkout.behavior)
                assert.equal("@./titan-compiler/types.lua", checkout.source)
                assert.equal("@./titan-compiler/driver.lua",
                    checkout.driver_source)
                assert.equal("@./c-parser/cdriver.lua", checkout.cdriver_source)
                for _, field in ipairs({
                    "cpath", "root", "installed", "source_checkout",
                    "include", "lua_source", "foreign_includes",
                    "runtime_inputs", "provider", "lpeglabel",
                }) do
                    assert.equal(installed[field], checkout[field], field)
                end
                assert.equal(prefix, checkout.root)
                assert.equal(prefix .. "/include", checkout.include)
                assert.equal(prefix .. "/src/lua-5.5.1", checkout.lua_source)
                -- Lua resolves its executable's physical prefix, whereas the
                -- LuaRocks launcher retains the configured path spelling.
                local prefix_ok, prefix_output = run_argv({
                    "sh", "-c", 'cd "$1" && pwd -P', "titan-prefix", prefix,
                })
                assert.truthy(prefix_ok, prefix_output)
                local physical_prefix = assert(prefix_output:match("^(.-)\n$"))
                assert.equal(physical_prefix .. "/lib/lua/5.5/titan.so",
                    checkout.provider)
                write_file(local_types,
                    'error("broken checkout compiler must propagate", 0)\n')
                assert(os.remove(report))
                ok, output, why, code = run_fixture("checkout")
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(1, code)
                assert.truthy(output:find(
                    "broken checkout compiler must propagate", 1, true),
                    output)
                assert.falsy(file_exists(report))
                assert.equal(installed_contents, read_file(installed_types))
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("forwards LuaRocks command arguments to Busted byte-for-byte",
        function()
            if platform.windows then
                pending("Unix Make test adapter and shell Busted launcher with newline argv")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local bin = root .. "/bin"
                local log = root .. "/argv"
                local make_log = root .. "/selected-make"
                local native_log = root .. "/native-phase"
                local selected_make = root .. "/selected make"
                local recursive_make = bin .. "/recursive-make"
                assert(lfs.mkdir(bin))
                local fake_busted = bin .. "/busted"
                write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_BUSTED_ARGV_LOG:?}"
printf '%s\0' "$@" > "$TITAN_BUSTED_ARGV_LOG"
exit 73
]==])
                -- rock-test keeps going after the failed Busted phase. Its
                -- recursive native build/run Make calls are recorded instead
                -- of building the complete aggregate in this checkout.
                write_file(selected_make, [==[#!/usr/bin/env bash
set -eu
printf 'selected\n' > "$TITAN_SELECTED_MAKE_LOG"
exec make MAKE="$TITAN_RECURSIVE_MAKE" "$@"
]==])
                write_file(recursive_make, [==[#!/usr/bin/env bash
set -eu
for argument do
    case "$argument" in
        titan-stdlib-test-build | titan-stdlib-test-run | titan-stdlib-test-run-parallel)
            printf '%s\n' "$argument" >> "$TITAN_NATIVE_PHASE_LOG"
            exit 0
            ;;
    esac
done
exec make "$@"
]==])
                local chmod_ok, chmod_output = run_argv({
                    "chmod", "+x", fake_busted, selected_make, recursive_make,
                })
                assert.truthy(chmod_ok, chmod_output)

                local ordinary = {
                    "--name=cost$bill",
                    "line one\nline two",
                    "tab\tvalue",
                    "",
                }
                local argv = {
                    "env",
                    "-u", "MAKEFLAGS",
                    "-u", "MFLAGS",
                    "-u", "MAKEOVERRIDES",
                    "-u", "EXTRA_TEST_FLAGS",
                    "-u", "TITAN_ROCK_TEST_INTERNAL",
                    "-u", "TITAN_ROCK_TEST_FORWARDED",
                    "-u", "TITAN_ROCK_TEST_ARGC",
                    "PATH=" .. bin .. ":" .. assert(os.getenv("PATH")),
                    "BUSTED=busted",
                    "TITAN_BUSTED_ARGV_LOG=" .. log,
                    "TITAN_SELECTED_MAKE_LOG=" .. make_log,
                    "TITAN_RECURSIVE_MAKE=" .. recursive_make,
                    "TITAN_NATIVE_PHASE_LOG=" .. native_log,
                    "bash",
                    "spec/support/run_rock_tests.sh",
                    "--make=" .. selected_make,
                }
                for _, argument in ipairs(ordinary) do
                    argv[#argv + 1] = argument
                end
                argv[#argv + 1] = "--busted-filter=focus$tail"
                argv[#argv + 1] = "--titan-filter=native$tail"
                argv[#argv + 1] = "--prefix=" ..
                    installed_prefix.active()
                local ok = run_argv(argv)
                assert.falsy(ok)
                assert.equal("selected\n", read_file(make_log))
                assert.equal("titan-stdlib-test-build\ntitan-stdlib-test-run\n",
                    read_file(native_log))

                local encoded = read_file(log)
                local actual = {}
                local offset = 1
                while offset <= #encoded do
                    local finish = assert(encoded:find("\0", offset, true))
                    actual[#actual + 1] = encoded:sub(offset, finish - 1)
                    offset = finish + 1
                end
                ordinary[#ordinary + 1] = "--filter=focus$tail"
                assert.same(ordinary, actual)
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("shards only the exact unfiltered Busted invocation", function()
            if platform.windows then
                pending("Unix shell Busted routing fixture; Windows uses native supervised compiler shards")
                return
            end
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local workspace = root .. "/workspace"
            local support = workspace .. "/spec/support"
            local bin = root .. "/bin"
            local mkdir_ok, mkdir_output = run_argv({
                "mkdir", "-p", support, bin,
            })
            assert.truthy(mkdir_ok, mkdir_output)
            write_file(support .. "/run_rock_tests.sh",
                read_file("spec/support/run_rock_tests.sh"))
            local integration_specs = {
                "spec/coder/native_coverage_spec.lua",
                "spec/stdlib_compiler_spec.lua",
            }
            write_file(support .. "/ci_stdlib_compiler_test_files.txt",
                "# Installed-stdlib compiler fixtures\n" ..
                table.concat(integration_specs, "\n") .. "\n")

            local fake_busted = bin .. "/busted"
            write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_ROUTING_ARGV_LOG:?}"
printf '%s\0' __TITAN_BUSTED_CALL__ "$@" >> "$TITAN_ROUTING_ARGV_LOG"
]==])
            write_file(support .. "/run_parallel_compiler_tests.sh", [==[
#!/usr/bin/env bash
set -eu
: "${TITAN_ROUTING_SHARD_LOG:?}"
printf 'sharded\n' > "$TITAN_ROUTING_SHARD_LOG"
printf '%s\0' __TITAN_SHARDS__ >> "$TITAN_ROUTING_ARGV_LOG"
]==])
            local chmod_ok, chmod_output = run_argv({
                "chmod", "+x", fake_busted,
                support .. "/run_rock_tests.sh",
                support .. "/run_parallel_compiler_tests.sh",
            })
            assert.truthy(chmod_ok, chmod_output)

            local function decoded_calls(path)
                local encoded = read_file(path)
                local calls, current = {}, nil
                local offset = 1
                while offset <= #encoded do
                    local finish = assert(encoded:find("\0", offset, true))
                    local argument = encoded:sub(offset, finish - 1)
                    offset = finish + 1
                    if argument == "__TITAN_BUSTED_CALL__" then
                        current = {}
                        calls[#calls + 1] = current
                    elseif argument == "__TITAN_SHARDS__" then
                        current = nil
                        calls[#calls + 1] = "sharded"
                    else
                        assert.truthy(current)
                        current[#current + 1] = argument
                    end
                end
                return calls
            end

            local stdlib_specs = {
                "retained-one", "retained-two", "retained-three",
                "retained-four", "retained-five", "retained-six",
                "retained-seven",
            }
            local argv_log = root .. "/argv"
            local shard_log = root .. "/shard"
            local function run_case(environment, arguments)
                os.remove(argv_log)
                os.remove(shard_log)
                local argv = {
                    "bash", "-c",
                    'cd "$1" && shift && exec "$@"',
                    "titan-routing-test", workspace,
                    "env",
                    "-u", "BUSTED_FILTER",
                    "-u", "TITAN_FILTER",
                    "-u", "TITAN_ROCK_TEST_FORWARDED",
                    "-u", "TITAN_ROCK_TEST_ARGC",
                    "-u", "TITAN_ROCK_TEST_ARG_0",
                    "-u", "TITAN_ROCK_TEST_ARG_1",
                    "BUSTED=" .. fake_busted,
                    "TITAN_ROCK_TEST_INTERNAL=1",
                    "TITAN_ROCK_TEST_STDLIB_SPECS=" ..
                    table.concat(stdlib_specs, " "),
                    "TITAN_ROUTING_ARGV_LOG=" .. argv_log,
                    "TITAN_ROUTING_SHARD_LOG=" .. shard_log,
                }
                for _, assignment in ipairs(environment or {}) do
                    argv[#argv + 1] = assignment
                end
                argv[#argv + 1] = "bash"
                argv[#argv + 1] = "spec/support/run_rock_tests.sh"
                for _, argument in ipairs(arguments or {}) do
                    argv[#argv + 1] = argument
                end
                return run_argv(argv)
            end

            local ok, output = run_case()
            assert.truthy(ok, output)
            assert.same({ "sharded" }, decoded_calls(argv_log))
            assert.equal("sharded\n", read_file(shard_log))

            ok, output = run_case({ "TITAN_FILTER=native$tail" })
            assert.truthy(ok, output)
            assert.same({ "sharded" }, decoded_calls(argv_log))
            assert.equal("sharded\n", read_file(shard_log))
            ok, output = run_case({ "BUSTED_FILTER=focus$tail" })
            assert.truthy(ok, output)
            assert.same({ { "--filter=focus$tail" } }, decoded_calls(argv_log))
            assert.falsy(lfs.attributes(shard_log))

            local direct = { "--name=cost$bill", "line one\nline two", "" }
            ok, output = run_case(nil, direct)
            assert.truthy(ok, output)
            assert.same({ direct }, decoded_calls(argv_log))
            assert.falsy(lfs.attributes(shard_log))

            local forwarded = { "spaced sentinel", "--literal=two words" }
            ok, output = run_case({
                "TITAN_ROCK_TEST_FORWARDED=1",
                "TITAN_ROCK_TEST_ARGC=2",
                "TITAN_ROCK_TEST_ARG_0=" .. forwarded[1],
                "TITAN_ROCK_TEST_ARG_1=" .. forwarded[2],
            })
            assert.truthy(ok, output)
            assert.same({ forwarded }, decoded_calls(argv_log))
            assert.falsy(lfs.attributes(shard_log))
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("selects both uncovered compiler domains exactly once without LuaCov",
        function()
            if platform.windows then
                pending("Unix CI shell Busted shard launcher")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local fake_busted = root .. "/busted"
                write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_SELECTOR_ARGV_LOG:?}"
printf '%s\0' "$@" > "$TITAN_SELECTOR_ARGV_LOG"
]==])
                local chmod_ok, chmod_output = run_argv({
                    "chmod", "+x", fake_busted,
                })
                assert.truthy(chmod_ok, chmod_output)

                local groups_helper = assert(loadfile(
                    "spec/support/compiler_test_groups.lua"))()
                local inventory = assert(groups_helper.load())

                local function selected(group, log)
                    local ok, output = run_argv({
                        "env",
                        "BUSTED=" .. fake_busted,
                        "TITAN_SELECTOR_ARGV_LOG=" .. log,
                        "bash", "spec/support/ci_test_groups.sh", group,
                    })
                    assert.truthy(ok, output)
                    assert.truthy(output:find(
                        "without LuaCov", 1, true), output)
                    local files = {}
                    local encoded = read_file(log)
                    local argv = {}
                    for argument in encoded:gmatch("([^%z]*)%z") do
                        argv[#argv + 1] = argument
                    end
                    assert.same({ "-o", "gtest", "-v" },
                        { argv[1], argv[2], argv[3] })
                    for index = 4, #argv do
                        assert.not_equal("-c", argv[index])
                        assert.truthy(argv[index]:match(
                            "^spec/.+_spec[.]lua$"), argv[index])
                        assert.falsy(files[argv[index]], argv[index])
                        files[argv[index]] = true
                    end
                    return files
                end

                local expected_stdlib, expected_complete = {}, {}
                for _, item in ipairs(inventory.stdlib) do
                    expected_stdlib[item.path] = true
                    expected_complete[item.path] = true
                end
                for _, item in ipairs(inventory.compiler) do
                    expected_complete[item.path] = true
                end
                assert.same(expected_stdlib, selected(
                    "stdlib-compiler-uncovered", root .. "/stdlib"))
                assert.same(expected_complete, selected(
                    "compiler-uncovered", root .. "/complete"))

                -- The former local-only uncovered shard selectors are gone:
                -- local runs plan per file from the same timing dataset.
                local ok, output, why, code = run_argv({
                    "env", "BUSTED=" .. fake_busted,
                    "TITAN_SELECTOR_ARGV_LOG=" .. root .. "/rejected",
                    "bash", "spec/support/ci_test_groups.sh",
                    "compiler-uncovered-shard-1",
                })
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(2, code)
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("runs covered and uncovered stress compiler tests in both domains",
        function()
            if platform.windows then
                pending("Unix CI LuaCov and shell Busted shard launcher")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local fake_busted = root .. "/busted"
                write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_SELECTOR_ARGV_LOG:?}"
printf '%s\0' __TITAN_BUSTED_CALL__ "$@" >> "$TITAN_SELECTOR_ARGV_LOG"
]==])
                local chmod_ok, chmod_output = run_argv({
                    "chmod", "+x", fake_busted,
                })
                assert.truthy(chmod_ok, chmod_output)

                local groups_helper = assert(loadfile(
                    "spec/support/compiler_test_groups.lua"))()
                local inventory = assert(groups_helper.load())
                local ci_plan = assert(groups_helper.plan_ci(
                    inventory, 4, "ci_covered"))
                local stdlib_plan = assert(groups_helper.plan_ci_stdlib(
                    inventory, 2, "ci_covered"))
                local selections = {}
                for shard = 1, 4 do
                    selections[shard] = { group = "compiler-shard-" .. shard,
                        files = ci_plan[shard].files }
                end
                local stdlib_files, stdlib_set = {}, {}
                for _, item in ipairs(inventory.stdlib) do
                    stdlib_files[#stdlib_files + 1] = item.path
                    stdlib_set[item.path] = true
                end
                selections[5] = { group = "stdlib-compiler", files = stdlib_files,
                    stdlib = true }
                -- The stdlib job's two workers partition that domain exactly.
                assert.equal(2, #stdlib_plan)
                local stdlib_union = {}
                for worker = 1, 2 do
                    local ordinary = 0
                    for _, item in ipairs(stdlib_plan[worker].items) do
                        assert.falsy(stdlib_union[item.path], item.path)
                        stdlib_union[item.path] = true
                        if not item.exclusive then ordinary = ordinary + 1 end
                    end
                    assert.is_true(ordinary > 0)
                    selections[5 + worker] = {
                        group = "stdlib-compiler-shard-" .. worker,
                        files = stdlib_plan[worker].files, stdlib = true }
                end
                assert.same(stdlib_set, stdlib_union)
                local stress = {}
                for _, item in ipairs(inventory.items) do
                    if item.stress then stress[item.path] = true end
                end

                local function has_argument(argv, expected_argument)
                    for _, argument in ipairs(argv) do
                        if argument == expected_argument then return true end
                    end
                    return false
                end

                local function decoded_calls(path)
                    local encoded = read_file(path)
                    local calls = {}
                    local current
                    local offset = 1
                    while offset <= #encoded do
                        local finish = assert(encoded:find(
                            "\0", offset, true))
                        local argument = encoded:sub(offset, finish - 1)
                        offset = finish + 1
                        if argument == "__TITAN_BUSTED_CALL__" then
                            current = {}
                            calls[#calls + 1] = current
                        else
                            assert.truthy(current)
                            current[#current + 1] = argument
                        end
                    end
                    return calls
                end

                for index, selection in ipairs(selections) do
                    local log = root .. "/shard-" .. index
                    local ok, output = run_argv({
                        "env",
                        "BUSTED=" .. fake_busted,
                        "TITAN_SELECTOR_ARGV_LOG=" .. log,
                        "bash", "spec/support/ci_test_groups.sh",
                        selection.group,
                    })
                    assert.truthy(ok, output)
                    assert.truthy(output:find("with LuaCov", 1, true), output)
                    assert.truthy(output:find(
                        "without LuaCov", 1, true), output)

                    local covered = {}
                    local uncovered_stress = {}
                    local covered_calls = 0
                    local stress_calls = 0
                    for _, argv in ipairs(decoded_calls(log)) do
                        local invocation_files = 0
                        local with_coverage = has_argument(argv, "-c")
                        if with_coverage then
                            covered_calls = covered_calls + 1
                            assert.truthy(has_argument(
                                argv, "--exclude-tags=stress"))
                            assert.falsy(has_argument(argv, "--tags=stress"))
                        else
                            stress_calls = stress_calls + 1
                            assert.truthy(has_argument(argv, "--tags=stress"))
                            assert.falsy(has_argument(
                                argv, "--exclude-tags=stress"))
                        end
                        for _, argument in ipairs(argv) do
                            if argument:match("^spec/.+_spec[.]lua$") then
                                invocation_files = invocation_files + 1
                                if with_coverage then
                                    assert.falsy(covered[argument], argument)
                                    covered[argument] = true
                                else
                                    assert.truthy(stress[argument], argument)
                                    assert.falsy(
                                        uncovered_stress[argument], argument)
                                    uncovered_stress[argument] = true
                                end
                            end
                        end
                        if selection.stdlib and with_coverage then
                            for _, isolated in ipairs({
                                "spec/coder/multi_module_libraries_spec.lua",
                                "spec/coder/native_coverage_spec.lua",
                                "spec/stdlib_compiler_spec.lua",
                            }) do
                                if has_argument(argv, isolated) then
                                    assert.equal(1, invocation_files, isolated)
                                end
                            end
                        end
                    end
                    assert.is_true(covered_calls > 0)

                    local expected_covered = {}
                    local expected_stress = {}
                    for _, path in ipairs(selection.files) do
                        expected_covered[path] = true
                        if stress[path] then expected_stress[path] = true end
                    end
                    if next(expected_stress) then
                        assert.is_true(stress_calls > 0)
                    else
                        assert.equal(0, stress_calls)
                    end
                    assert.same(expected_covered, covered)
                    assert.same(expected_stress, uncovered_stress)
                end

                -- Compiler shards, the installed-stdlib domain and its CI
                -- workers each split into ordinary and exclusive phases
                -- without changing their complete covered inventory.
                local exclusive_seen = {}
                for index, selection in ipairs(selections) do
                    local phase_files = {}
                    for _, phase in ipairs({ "ordinary", "exclusive" }) do
                        local log = root .. "/phase-" .. index .. "-" .. phase
                        local ok, output = run_argv({
                            "env", "BUSTED=" .. fake_busted,
                            "TITAN_SELECTOR_ARGV_LOG=" .. log,
                            "bash", "spec/support/ci_test_groups.sh",
                            selection.group, phase,
                        })
                        assert.truthy(ok, output)
                        local calls = lfs.attributes(log) and
                            decoded_calls(log) or {}
                        for _, argv in ipairs(calls) do
                            if has_argument(argv, "-c") then
                                for _, argument in ipairs(argv) do
                                    if argument:match("^spec/.+_spec[.]lua$") then
                                        assert.falsy(phase_files[argument], argument)
                                        phase_files[argument] = true
                                        assert.equal(phase == "exclusive",
                                            groups_helper.EXCLUSIVE_SPECS[argument] == true,
                                            argument)
                                        if phase == "exclusive" then
                                            exclusive_seen[argument] = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                    local expected_covered = {}
                    for _, path in ipairs(selection.files) do
                        expected_covered[path] = true
                    end
                    assert.same(expected_covered, phase_files)
                end
                for path in pairs(groups_helper.EXCLUSIVE_SPECS) do
                    if inventory.by_path[path] then
                        assert.truthy(exclusive_seen[path], path)
                    end
                end
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("runs every planned spec file once in isolated, bounded, keep-going workers",
        function()
            if platform.windows then
                pending("Unix compiler worker Make pool and process-group supervision")
                return
            end
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local workspace = root .. "/workspace"
            local support = workspace .. "/spec/support"
            local bin = root .. "/bin"
            local temporary_base = root .. "/runner-tmp"
            local state = root .. "/state"
            local mkdir_ok, mkdir_output = run_argv({
                "mkdir", "-p", support, workspace .. "/spec/coder", bin,
                temporary_base, state,
                workspace .. "/.git", workspace .. "/.lua",
                workspace .. "/.sdk-local/bin",
                workspace .. "/.sdk-local-sibling",
                workspace .. "/sdk[1]", workspace .. "/sdk*",
                workspace .. "/sdk1",
            })
            assert.truthy(mkdir_ok, mkdir_output)
            local lua = installed_prefix.active() .. "/bin/lua"
            -- The native build target counts as one more pool unit.
            write_file(workspace .. "/Makefile",
                "titan-stdlib-test-build:\n\t@bash " ..
                quote(bin .. "/native-build") .. "\n")
            write_file(workspace .. "/ordinary", "original\n")
            write_file(workspace .. "/.git/excluded", "git\n")
            write_file(workspace .. "/.lua/excluded", "lua\n")
            -- The selected SDK lives inside the checkout under an arbitrary
            -- name and is spelled through a symbolic link; workers still use
            -- it in place, so the snapshot must omit exactly that tree.
            write_file(workspace .. "/.sdk-local/bin/excluded", "sdk\n")
            write_file(workspace .. "/.sdk-local-sibling/kept", "kept\n")
            -- Selected SDKs named sdk[1] or sdk* would be tar patterns that
            -- also match sdk1, so such a prefix is copied and nothing is lost.
            for _, kept in ipairs({ "sdk[1]", "sdk*", "sdk1" }) do
                write_file(workspace .. "/" .. kept .. "/kept", "kept\n")
            end
            local prefix_link = root .. "/sdk-link"
            local link_ok, link_output = run_argv({
                "ln", "-s", workspace .. "/.sdk-local", prefix_link,
            })
            assert.truthy(link_ok, link_output)
            for _, name in ipairs({
                "run_parallel_compiler_tests.sh", "compiler_test_groups.lua",
            }) do
                write_file(support .. "/" .. name,
                    read_file("spec/support/" .. name))
            end
            local ordinary_files = {
                "spec/r1_spec.lua", "spec/r2_spec.lua", "spec/s1_spec.lua",
                "spec/c1_spec.lua", "spec/c2_spec.lua", "spec/c3_spec.lua",
                "spec/c4_spec.lua", "spec/c5_spec.lua",
            }
            local exclusive_files = {
                "spec/coder/jobserver_spec.lua",
                "spec/coder/parallel_compilation_spec.lua",
            }
            for _, list in ipairs({ ordinary_files, exclusive_files }) do
                for _, path in ipairs(list) do
                    write_file(workspace .. "/" .. path, "-- fixture\n")
                end
            end
            write_file(support .. "/ci_stdlib_compiler_test_files.txt",
                "spec/s1_spec.lua\n")
            write_file(support .. "/ci_compiler_stress_files.txt", "# none\n")
            write_file(support .. "/ci_compiler_test_groups.txt", table.concat({
                "# Schema: titan-busted-timings-v2",
                "retained spec/r1_spec.lua 9.0 -",
                "retained spec/r2_spec.lua 3.0 -",
                "stdlib spec/s1_spec.lua 7.0 -",
                "compiler spec/c1_spec.lua 8.0 8.0",
                "compiler spec/c2_spec.lua 6.0 6.0",
                "compiler spec/c3_spec.lua 5.0 5.0",
                "compiler spec/c4_spec.lua 4.0 4.0",
                "compiler spec/c5_spec.lua 2.0 2.0",
                "compiler spec/coder/jobserver_spec.lua 3.0 -",
                "compiler spec/coder/parallel_compilation_spec.lua 3.0 -",
                "",
            }, "\n"))

            local common = [==[
state=${TITAN_FIXTURE_STATE:?}
expected_max=${TITAN_FIXTURE_EXPECTED_MAX:?}
acquire_lock() {
    while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done
}
release_lock() {
    rmdir "$state/lock"
}
enter_unit() {
    acquire_lock
    active=$(($(cat "$state/active") + 1))
    printf '%s\n' "$active" > "$state/active"
    if (( active > $(cat "$state/maximum") )); then
        printf '%s\n' "$active" > "$state/maximum"
    fi
    release_lock
}
leave_unit() {
    acquire_lock
    printf '%s\n' "$(($(cat "$state/active") - 1))" > "$state/active"
    printf '%s\n' "$1" >> "$state/finished"
    release_lock
}
# Hold the first wave until every permitted pool unit is occupied, making
# the concurrency observation deterministic even on a heavily loaded host.
barrier() {
    local deadline=$((SECONDS + 5))
    while (( $(cat "$state/maximum") < expected_max )); do
        if (( SECONDS >= deadline )); then
            echo "fixture concurrency barrier timed out" >&2
            exit 78
        fi
        sleep 0.01
    done
}
hang() {
    (
        trap '' TERM
        while :; do sleep 1; done
    ) &
    printf '%s\n' "$!" >> "$state/term-ignoring-descendants"
    wait "$!"
    exit 81
}
]==]
            write_file(bin .. "/native-build", "#!/usr/bin/env bash\nset -u\n" ..
                common .. [==[
enter_unit
echo "fixture native build running"
printf '1\n' > "$state/native-active"
barrier
if [[ ${TITAN_FIXTURE_NATIVE_HANG:-} == 1 ]]; then hang; fi
sleep 0.3
printf '0\n' > "$state/native-active"
printf 'native-built\n' > "$state/native-built"
leave_unit native-build
exit "${TITAN_FIXTURE_NATIVE_STATUS:-0}"
]==])
            local fake_busted = bin .. "/busted"
            write_file(fake_busted, "#!/usr/bin/env bash\nset -u\n" ..
                common .. [==[
[[ $# == 4 && $1 == -o && $2 == gtest && $3 == -v ]] || exit 70
test_file=$4
[[ $PWD != "$TITAN_FIXTURE_ORIGINAL" ]] || exit 72
[[ ! -e .git && ! -e .lua ]] || exit 73
[[ -z ${TITAN_FIXTURE_OMITTED:-} || ! -e $TITAN_FIXTURE_OMITTED ]] || exit 73
for kept in .sdk-local-sibling 'sdk[1]' 'sdk*' sdk1; do
    [[ $(cat "$kept/kept" 2>/dev/null) == kept ]] || exit 82
done
[[ $(cat ordinary) == original ]] || exit 74
[[ $TITAN_SOURCE_GIT_ROOT == "$TITAN_FIXTURE_ORIGINAL" ]] || exit 76
[[ -d $TMPDIR && $CCACHE_TEMPDIR == "$TMPDIR/ccache" &&
   -d $CCACHE_TEMPDIR ]] || exit 77
# A previous file in this checkout must not leave root artifacts behind.
[[ ! -e leftover.c && ! -e leftover.parts ]] || exit 83

exclusive=0
case "$test_file" in
    spec/coder/jobserver_spec.lua | spec/coder/parallel_compilation_spec.lua)
        exclusive=1 ;;
esac
# Ordinary workers keep nested Make/Titan work at one job. Exclusive files
# run alone and own their caps, so no inherited Make job policy reaches them.
if (( exclusive != 0 )); then
    [[ -z ${MAKEFLAGS+set} && -z ${MFLAGS+set} && -z ${MAKELEVEL+set} &&
       -z ${TITAN_JOBS+set} ]] || exit 75
else
    [[ $MAKEFLAGS == -j1 && $TITAN_JOBS == 1 ]] || exit 75
fi
enter_unit
acquire_lock
printf '%s\t%s\t%s\n' "$test_file" "$PWD" "$TMPDIR" >> "$state/observations"
if (( exclusive != 0 )); then
    ordinary_done=$(grep -c '^spec/[a-z0-9]*_spec[.]lua$' "$state/finished" || true)
    if [[ $(cat "$state/active") != 1 || $(cat "$state/native-active") != 0 ||
          $ordinary_done != "$TITAN_FIXTURE_ORDINARY_TOTAL" ]]; then
        printf '%s\n' "$test_file" >> "$state/exclusive-overlap"
    fi
fi
release_lock
if (( exclusive == 0 )); then barrier; fi

if [[ ${TITAN_FIXTURE_KILL_WRAPPER_FILE:-} == "$test_file" ]]; then
    # The launcher makes each shard's Busted runner a process-group leader.
    # Kill only that leader so it cannot record its status; leave this file
    # alive for the wrapper's dead-shard cleanup path.
    leader=$(ps -o pgid= -p $$ | tr -d ' ')
    [[ $leader =~ ^[0-9]+$ ]] || exit 79
    printf '%s\n' "$leader" > "$state/killed-wrapper"
    kill -KILL "$leader"
    sleep 30
    exit 80
fi
if [[ ${TITAN_FIXTURE_HANG_FILE:-} == "$test_file" ]]; then hang; fi

printf 'fixture-output %s\n' "$test_file"
touch "worker-mutated" leftover.c leftover.parts
sleep 0.1
leave_unit "$test_file"
if [[ ${TITAN_FIXTURE_FAIL_FILE:-} == "$test_file" ]]; then exit 23; fi
]==])
            local chmod_ok, chmod_output = run_argv({
                "chmod", "+x", fake_busted, bin .. "/native-build",
            })
            assert.truthy(chmod_ok, chmod_output)

            local function reset_state()
                for _, name in ipairs({
                    "observations", "finished", "killed-wrapper",
                    "term-ignoring-descendants", "exclusive-overlap",
                    "native-built",
                }) do
                    os.remove(state .. "/" .. name)
                end
                write_file(state .. "/active", "0\n")
                write_file(state .. "/maximum", "0\n")
                write_file(state .. "/native-active", "0\n")
                write_file(state .. "/observations", "")
                write_file(state .. "/finished", "")
            end

            local function fixture_environment(expected_max, extra)
                local environment = {
                    "PATH=" .. bin .. ":" .. assert(os.getenv("PATH")),
                    "BUSTED=busted",
                    "LUA=" .. lua,
                    "PREFIX=" .. prefix_link,
                    "TITAN_FIXTURE_OMITTED=.sdk-local",
                    "TMPDIR=" .. temporary_base,
                    "TITAN_FIXTURE_STATE=" .. state,
                    "TITAN_FIXTURE_ORIGINAL=" .. workspace,
                    "TITAN_FIXTURE_EXPECTED_MAX=" .. tostring(expected_max),
                    "TITAN_FIXTURE_ORDINARY_TOTAL=" .. tostring(#ordinary_files),
                    "TITAN_ROCK_TEST_STDLIB_SPECS=spec/r1_spec.lua spec/r2_spec.lua",
                }
                for _, assignment in ipairs(extra or {}) do
                    environment[#environment + 1] = assignment
                end
                return environment
            end

            local function run_case(expected_max, extra, bounded)
                reset_state()
                local argv = {}
                if bounded then
                    argv = {
                        "bash", lfs.currentdir() .. "/spec/support/run_with_timeout.sh",
                        "8",
                    }
                end
                for _, argument in ipairs({
                    "bash", "-c", 'cd "$1" && shift && exec "$@"',
                    "titan-parallel-test", workspace,
                    "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
                    "-u", "TITAN_JOBS", "-u", "TITAN_ROCK_TEST_JOBS",
                    "-u", "TITAN_ROCK_TEST_BUILD_NATIVE",
                    "-u", "TITAN_ROCK_TEST_NATIVE_STATUS",
                }) do
                    argv[#argv + 1] = argument
                end
                for _, assignment in ipairs(fixture_environment(expected_max, extra)) do
                    argv[#argv + 1] = assignment
                end
                argv[#argv + 1] = "bash"
                argv[#argv + 1] = "spec/support/run_parallel_compiler_tests.sh"
                return run_argv(argv)
            end

            local function assert_temporary_base_empty()
                for entry in lfs.dir(temporary_base) do
                    assert.truthy(entry == "." or entry == "..", entry)
                end
            end

            local function assert_complete_run(expected_max, workers, output)
                assert.equal(tostring(expected_max) .. "\n",
                    read_file(state .. "/maximum"))
                assert.falsy(lfs.attributes(state .. "/exclusive-overlap"),
                    output)
                local roots, seen = {}, {}
                local count = 0
                for line in read_file(state .. "/observations"):gmatch("[^\n]+") do
                    local file, worker, tmpdir = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
                    assert.truthy(file, line)
                    assert.falsy(seen[file], line)
                    seen[file] = true
                    count = count + 1
                    assert.not_equal(workspace, worker)
                    -- One checkout and TMPDIR belong to one shard.
                    assert.truthy(roots[worker] == nil or roots[worker] == tmpdir, line)
                    roots[worker] = tmpdir
                    assert.truthy(output:find("fixture-output " .. file, 1, true),
                        output)
                end
                assert.equal(#ordinary_files + #exclusive_files, count)
                local checkout_count = 0
                for _ in pairs(roots) do checkout_count = checkout_count + 1 end
                -- Ordinary shards plus the exclusive shard.
                assert.equal(workers + 1, checkout_count)
                assert.falsy(lfs.attributes(workspace .. "/worker-mutated"))
                assert.falsy(lfs.attributes(workspace .. "/leftover.c"))
                assert.equal("original\n", read_file(workspace .. "/ordinary"))
                assert_temporary_base_empty()
            end

            -- Default: four LPT shards in one fresh four-slot pool; the two
            -- exclusive files run alone afterwards.
            local ok, output = run_case(4)
            assert.truthy(ok, output)
            assert_complete_run(4, 4, output)
            assert.truthy(output:find(
                "Per-file Busted summary: passed=10 failed=0 total=10", 1, true), output)
            assert.truthy(output:find("All 5 compiler shards passed", 1, true), output)

            for _, patterned in ipairs({ "sdk[1]", "sdk*" }) do
                ok, output = run_case(4, {
                    "PREFIX=" .. workspace .. "/" .. patterned,
                    "TITAN_FIXTURE_OMITTED=",
                })
                assert.truthy(ok, output)
                assert_complete_run(4, 4, output)
            end

            -- More shards than the pool: TITAN_ROCK_TEST_JOBS chooses the
            -- partition, TITAN_JOBS the shared budget.
            ok, output = run_case(2, { "TITAN_ROCK_TEST_JOBS=4", "TITAN_JOBS=2" })
            assert.truthy(ok, output)
            assert_complete_run(2, 4, output)
            ok, output = run_case(2, { "TITAN_ROCK_TEST_JOBS=2" })
            assert.truthy(ok, output)
            assert_complete_run(2, 2, output)

            -- The native build joins the same pool instead of adding units,
            -- and the caller receives its status. Three workers are the
            -- default when the build shares the pool.
            local native_status = root .. "/native.status"
            os.remove(native_status)
            ok, output = run_case(3, {
                "TITAN_JOBS=3", "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                "TITAN_ROCK_TEST_NATIVE_STATUS=" .. native_status,
            })
            assert.truthy(ok, output)
            assert_complete_run(3, 3, output)
            assert.equal("native-built\n", read_file(state .. "/native-built"))
            assert.equal("0\n", read_file(native_status))
            assert.truthy(output:find("[native build] ", 1, true), output)

            -- A failed native build is reported to the caller, which owns
            -- the native phase; Busted shards still complete.
            ok, output = run_case(3, {
                "TITAN_JOBS=3", "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                "TITAN_ROCK_TEST_NATIVE_STATUS=" .. native_status,
                "TITAN_FIXTURE_NATIVE_STATUS=7",
            })
            assert.truthy(ok, output)
            assert.matches("^[1-9][0-9]*\n$", read_file(native_status))
            assert_complete_run(3, 3, output)

            -- Without TITAN_JOBS, which the Makefile omits on GNU Make before
            -- 4.2, the seeded pool holds every worker plus the native build.
            os.remove(native_status)
            ok, output = run_case(4, {
                "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                "TITAN_ROCK_TEST_NATIVE_STATUS=" .. native_status,
            })
            assert.truthy(ok, output)
            assert_complete_run(4, 3, output)
            assert.equal("native-built\n", read_file(state .. "/native-built"))
            assert.equal("0\n", read_file(native_status))
            ok, output = run_case(5, { "TITAN_ROCK_TEST_JOBS=5" })
            assert.truthy(ok, output)
            assert_complete_run(5, 5, output)

            -- An explicit serial Make policy stays serial.
            ok, output = run_case(1, { "MAKEFLAGS=-j1", "TITAN_JOBS=4",
                "TITAN_ROCK_TEST_BUILD_NATIVE=1" })
            assert.truthy(ok, output)
            assert_complete_run(1, 3, output)

            -- A parent Make pool is joined, never multiplied: TITAN_JOBS=8
            -- alone does not override the inherited three-slot server.
            local parent_styles = { {} }
            local help_ok, help = run_argv({ "make", "--help" })
            if help_ok and help:find("--jobserver-style", 1, true) then
                parent_styles[#parent_styles + 1] = { "--jobserver-style=pipe" }
            end
            write_file(root .. "/parent.mk",
                "all:\n\t+@cd " .. quote(workspace) ..
                " && bash spec/support/run_parallel_compiler_tests.sh\n")
            for _, style in ipairs(parent_styles) do
                reset_state()
                local argv = {
                    "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
                    "-u", "TITAN_ROCK_TEST_JOBS",
                }
                for _, assignment in ipairs(fixture_environment(3, {
                    "TITAN_JOBS=8", "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                })) do
                    argv[#argv + 1] = assignment
                end
                for _, word in ipairs({
                    "make", "--no-print-directory", "-j3",
                }) do
                    argv[#argv + 1] = word
                end
                for _, word in ipairs(style) do argv[#argv + 1] = word end
                argv[#argv + 1] = "-f"
                argv[#argv + 1] = root .. "/parent.mk"
                ok, output = run_argv(argv)
                assert.truthy(ok, output)
                assert_complete_run(3, 3, output)
                assert.equal("native-built\n", read_file(state .. "/native-built"))
            end

            -- An early failing file does not stop its shard or the others;
            -- the summary names it and the run fails at the end.
            local why, code
            ok, output, why, code = run_case(4, {
                "TITAN_FIXTURE_FAIL_FILE=spec/c5_spec.lua",
            })
            assert.falsy(ok, output)
            assert.equal("exit", why)
            assert.equal(1, code)
            assert_complete_run(4, 4, output)
            assert.truthy(output:find(
                "Per-file Busted summary: passed=9 failed=1 total=10", 1, true), output)
            assert.truthy(output:find(
                "FAILED spec file: spec/c5_spec.lua", 1, true), output)

            -- A shard whose Busted group dies before recording its status
            -- fails promptly; its unreported files are named.
            local started = os.time()
            ok, output, why, code = run_case(1, {
                "TITAN_ROCK_TEST_JOBS=1",
                "TITAN_FIXTURE_KILL_WRAPPER_FILE=spec/c1_spec.lua",
            }, true)
            assert.falsy(ok, output)
            assert.equal("exit", why)
            assert.equal(1, code)
            assert.is_true(os.time() - started < 8, output)
            assert.truthy(lfs.attributes(state .. "/killed-wrapper", "mode"), output)
            assert.truthy(output:find("exited before recording its status", 1, true),
                output)
            assert.truthy(output:find(
                "planned spec file did not report a result", 1, true), output)
            assert_temporary_base_empty()

            -- TERM drains the Make work graph, the native build, and every
            -- shard, including descendants that ignore TERM.
            reset_state()
            os.remove(native_status)
            local interruption = {
                "bash", lfs.currentdir() .. "/spec/support/run_with_timeout.sh", "15",
                "bash", "-c", [==[
workspace=$1
state=$2
shift 2
cd "$workspace" || exit 90
env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS "$@" \
    bash spec/support/run_parallel_compiler_tests.sh &
runner=$!
deadline=$((SECONDS + 8))
while (( $(cat "$state/term-ignoring-descendants" 2>/dev/null | wc -l) < 2 )); do
    if ! kill -0 "$runner" 2>/dev/null; then
        wait "$runner" || true
        echo "parallel launcher exited before starting descendants" >&2
        exit 91
    fi
    if (( SECONDS >= deadline )); then
        kill -TERM "$runner" 2>/dev/null || true
        wait "$runner" || true
        echo "timed out waiting for TERM fixture descendants" >&2
        exit 92
    fi
    sleep 0.01
done
kill -TERM "$runner"
runner_status=0
wait "$runner" || runner_status=$?
if (( runner_status != 143 )); then
    echo "parallel launcher TERM status was $runner_status" >&2
    exit 93
fi
deadline=$((SECONDS + 4))
while read -r descendant; do
    while kill -0 "$descendant" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            echo "TERM-ignoring descendant survived launcher cleanup" >&2
            exit 94
        fi
        sleep 0.01
    done
done < "$state/term-ignoring-descendants"
]==], "titan-parallel-interruption", workspace, state,
            }
            for _, assignment in ipairs(fixture_environment(2, {
                "TITAN_ROCK_TEST_JOBS=1", "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                "TITAN_ROCK_TEST_NATIVE_STATUS=" .. native_status,
                "TITAN_FIXTURE_HANG_FILE=spec/c1_spec.lua",
                "TITAN_FIXTURE_NATIVE_HANG=1",
            })) do
                interruption[#interruption + 1] = assignment
            end
            ok, output, why, code = run_argv(interruption)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.falsy(lfs.attributes(native_status), output)
            assert_temporary_base_empty()

            for _, invalid in ipairs({
                { "TITAN_ROCK_TEST_JOBS=0", "TITAN_ROCK_TEST_JOBS must be a positive integer" },
                { "TITAN_ROCK_TEST_JOBS=-1", "TITAN_ROCK_TEST_JOBS must be a positive integer" },
                { "TITAN_ROCK_TEST_JOBS=invalid", "TITAN_ROCK_TEST_JOBS must be a positive integer" },
                { "TITAN_JOBS=0", "TITAN_JOBS must be a positive integer" },
            }) do
                ok, output, why, code = run_argv({
                    "bash", "-c", 'cd "$1" && shift && exec "$@"',
                    "titan-parallel-validation", workspace,
                    "env", invalid[1],
                    "bash", "spec/support/run_parallel_compiler_tests.sh",
                })
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(2, code)
                assert.truthy(output:find(invalid[2], 1, true), output)
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("launches the Windows exclusive compiler shard first and alone",
        function()
            -- The real Windows route needs CLANG64, cygpath, and the native
            -- Job Object supervisor. Drive the launcher's own launch-order
            -- and admission functions with stub shards that finish oldest-first.
            local launcher = read_file(
                "spec/support/run_parallel_compiler_tests.sh")
            local function shell_function(name)
                local start = assert(launcher:find(
                    "\n    " .. name .. "() {\n", 1, true), name)
                local _, finish = assert(launcher:find("\n    }\n", start, true))
                return launcher:sub(start + 1, finish)
            end
            local harness = table.concat({ [==[
set -u
exclusive_shard=$1
jobs=$2
shift 2
ordinary_shards=("$@")
worker_pids=()
running=()
schedule=()
active=0
launched=0
completed=0
]==], shell_function("windows_launch_order"),
                shell_function("windows_may_launch"), [==[
windows_launch_order
total_shards=${#launch_order[@]}
while (( completed < total_shards )); do
    while (( launched < total_shards )) &&
          windows_may_launch "${launch_order[$launched]}"; do
        shard=${launch_order[$launched]}
        worker_pids[$shard]=1
        running+=("$shard")
        schedule+=("start $shard")
        launched=$((launched + 1))
        active=$((active + 1))
    done
    if (( ${#running[@]} == 0 )); then
        echo "scheduler admitted no shard" >&2
        exit 1
    fi
    finished=${running[0]}
    running=("${running[@]:1}")
    unset 'worker_pids[$finished]'
    schedule+=("finish $finished")
    active=$((active - 1))
    completed=$((completed + 1))
done
printf '%s\n' "${schedule[@]}"
]==] })

            local function schedule(exclusive, jobs, ordinary)
                local argv = {
                    "bash", "-c", harness, "titan-launch-order",
                    exclusive, tostring(jobs),
                }
                for _, shard in ipairs(ordinary) do argv[#argv + 1] = shard end
                local ok, output, why, code = run_argv(argv)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                local events = {}
                for line in output:gmatch("[^\n]+") do
                    events[#events + 1] = line
                end
                return table.concat(events, ", ")
            end

            -- The exclusive shard (planned last) runs alone first; the
            -- ordinary shards then share the worker bound.
            assert.equal("start 5, finish 5, start 1, start 2, start 3, start 4, " ..
                "finish 1, finish 2, finish 3, finish 4",
                schedule("5", 4, { "1", "2", "3", "4" }))
            assert.equal("start 4, finish 4, start 1, start 2, finish 1, " ..
                "start 3, finish 2, finish 3", schedule("4", 2, { "1", "2", "3" }))
            assert.equal("start 3, finish 3, start 1, finish 1, start 2, finish 2",
                schedule("3", 1, { "1", "2" }))
            -- Without an exclusive shard every permitted slot fills in order.
            assert.equal("start 1, start 2, finish 1, start 3, finish 2, finish 3",
                schedule("", 2, { "1", "2", "3" }))
        end)

    it("bounds TERM-ignoring descendants for every command exit path",
        function()
            if platform.windows then
                pending("POSIX process groups and TERM/KILL signal supervision")
                return
            end
            local function run_case(command, expected_ok, expected_code, expected_why)
                local started = os.time()
                local ok, output, why, code = run_argv({
                    "bash",
                    "spec/support/run_with_timeout.sh",
                    "1",
                    "bash",
                    "-c",
                    command,
                })
                local elapsed = os.time() - started
                assert.equal(expected_ok, ok, output)
                if expected_code then
                    assert.equal(expected_why or "exit", why)
                    assert.equal(expected_code, code)
                end
                assert.is_true(elapsed < 10,
                    "timeout supervisor leaked its output pipe for " ..
                    tostring(elapsed) .. " seconds")
            end

            run_case('exit 7', false, 7)
            run_case('kill -TERM "$$"', false, 15, "signal")
            run_case('(trap "" TERM; sleep 12) & wait', false, 124)
            run_case('(trap "" TERM; sleep 12) & exit 0', true)
        end)

    it("owns provider publication and exact cleanup without a Make link stamp",
        function()
            local makefile = read_file("Makefile")
            for _, contract in ipairs({
                "STDLIB_STATIC_ARCHIVE := $(TITAN_OUTPUT_DIR)/" .. STDLIB_STATIC_ARCHIVE,
                "STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) " ..
                "$(STDLIB_STATIC_ARCHIVE)",
                "include $(TITAN_MAKEFILE_DIR)scripts/install_compiler.mk",
                "stdlib: $(STDLIB_NATIVE_PREREQS) $(STDLIB_TOOL_PREREQS)",
                "AR=$(call make_shell_quote,$(AR))",
                "RANLIB=$(call make_shell_quote,$(RANLIB))",
                "CLANG_FORMAT ?= clang-format",
                "TITAN_NO_LINE_DIRECTIVES ?=",
                "RECURSIVE_WRAPPER_GUARD = titan_mode=; set -f; set -- $$MAKEFLAGS; set +f;",
                "export CLANG_FORMAT TITAN_EXTRA_CPPFLAGS " ..
                "TITAN_EXTRA_CFLAGS \\\n\t" ..
                "TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES",
                "STDLIB_INSTALL_STAGE       ?= $(abspath $(TITAN_OUTPUT_DIR))",
                "TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT ?=",
                "install-stdlib: stdlib",
                "stage=$(call make_shell_quote,$(STDLIB_INSTALL_STAGE))",
                "install -p -m 0644 THIRD_PARTY_NOTICES.md",
                "install -p -m 0644 $(STDLIB_LICENSES)",
                '$(STDLIB_COMPILER_ENV) "$(TITAN_LUA)" -E',
                "rm -f $(STDLIB_PROVIDER_OUTPUTS)",
                "rm -rf $(STDLIB_CONTAINER).dSYM",
                "include $(TITAN_TEST_MODULE_MANIFEST)",
                "TITAN_TEST_EXECUTABLE := $(TITAN_TEST_BUILD_DIR)/" ..
                "$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)",
                "\nbusted-test:",
                "\nstdlib-busted-test:",
                "\ntitan-stdlib-test-build:",
                "\ntitan-stdlib-test-run:",
                "\ntitan-stdlib-test: titan-stdlib-test-build",
                "\nstdlib-test: stdlib-busted-test",
                "\nrock-test: ## Run retained Busted specs, then native Titan stdlib tests",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            local _, recursive_test_count = makefile:gsub(
                "\n\t%+%$%(RECURSIVE_WRAPPER_GUARD%) unset LUA_PATH " ..
                "LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
                "")
            assert.equal(2, recursive_test_count, makefile)
            assert.falsy(makefile:find("rock-post-install:", 1, true))
            assert.truthy(read_file("scripts/install_compiler.mk"):find(
                "TITAN_COMPILER_LUA := " ..
                "$(wildcard titan-compiler/*.lua \\\n\t" ..
                "titan-compiler/checker/*.lua " ..
                "titan-compiler/coder/*.lua c-parser/*.lua)", 1, true))
            local publisher_start = assert(makefile:find(
                "install-stdlib publish-stdlib:", 1, true))
            local publisher_end = assert(makefile:find(
                "\n# Compatibility name", publisher_start, true))
            local publisher = makefile:sub(publisher_start, publisher_end - 1)
            for _, contract in ipairs({
                "if test -n $(call make_shell_quote,$(strip " ..
                "$(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))); then",
                '"$(CURDIR)/spec/support/' ..
                'ci_asan_generated_c_context.lua"',
                "snapshot",
                "$(call make_shell_quote,$(strip " ..
                "$(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT)))",
                '"$$stage/titan.so" "$$stage/titan"',
                '"$(TITAN_CANONICAL_PROVIDER_SO)"',
                '"$(CURDIR)/titan"',
            }) do
                assert.truthy(publisher:find(contract, 1, true),
                    contract)
            end
            local diagnostic_snapshot = assert(publisher:find(
                '"$(CURDIR)/spec/support/' ..
                'ci_asan_generated_c_context.lua"', 1, true))
            local publication = assert(publisher:find(
                'install -p -m 0755 "$$stage/titan.so"', diagnostic_snapshot, true))
            assert.is_true(diagnostic_snapshot < publication,
                "diagnostic snapshot must preserve the built provider " ..
                "before publication")
            assert.falsy(makefile:find("-Wl,--whole-archive", 1, true), makefile)
            assert.falsy(makefile:find("-Wl,-force_load", 1, true), makefile)
            assert.falsy(makefile:find("rm -f *.a", 1, true), makefile)
            assert.falsy(makefile:find("rm -f titan/*.lua", 1, true), makefile)
            assert.falsy(makefile:find("rm -f titan/uv/*.lua", 1, true),
                makefile)
            assert.falsy(makefile:find(
                "run_titan_stdlib_test_groups.sh", 1, true), makefile)
            assert.falsy(makefile:find(
                "run_titan_stdlib_tests.sh", 1, true), makefile)
            local native_run_start = assert(makefile:find(
                "\ntitan-stdlib-test-run:", 1, true))
            local native_run_end = assert(makefile:find(
                "\ntitan-stdlib-test:", native_run_start, true))
            local native_run = makefile:sub(native_run_start, native_run_end - 1)
            assert.truthy(native_run:find('2>&1 | tee "$$log"', 1, true), native_run)
            assert.truthy(native_run:find("spec/support/check_stdlib_test_output.lua", 1, true), native_run)
            assert.falsy(native_run:find("output=$$(", 1, true), native_run)

            local snapshot = read_file("spec/support/ci_stdlib_snapshot.sh")
            for _, contract in ipairs({
                'static_archive=${provider%.so}.a',
                '"$static_archive"',
                'rm -f "$static_archive"',
                'write_manifest "$manifest" "${artifacts[@]}"',
                'cmp -s "$manifest" "$restored_manifest"',
            }) do
                assert.truthy(snapshot:find(contract, 1, true), contract)
            end

            local mode_smoke =
                read_file("spec/support/ci_dependency_mode_smoke.sh")
            for _, contract in ipairs({
                'RUNTIME_ARCHIVE="$LIBRARY_ROOT/libtitan.a"',
                'test ! -e "$PREFIX/lib/libtitan.a"',
                'local async = import "async"',
                'local timer = import "timer"',
                'local titan_io = import "io"',
                'local fs = import "fs"',
                'local net = import "net"',
                'local ssl = import "ssl"',
                'local url = import "url"',
                'local http = import "http"',
                'local websocket = import "websocket"',
                'local qualified_websocket = import "titan.websocket"',
                'local system = import "os"',
                'local peg = import "peg"',
                'local strings = import "string"',
                '#peg.version() > 0',
                'strings.len("static\\0string") == 13',
                'local found = strings.match("static42", "([0-9]+)")',
                'strings.find("static\\0string", "\\0str")',
                'local math = import "math"',
                'local lua = import "lua"',
                'local iteration = import "iteration"',
                'local gc = import "gc"',
                'local testing = import "test"',
                'not testing.testing() and not testing.verbose()',
                "local peer = async.run<|value, value|>(",
                "timer.sleep(0)",
                "fs.write_file(marker,",
                "local metadata = fs.stat(marker)",
                "local merged = system.popen(",
                "static-process-stdoutstatic-process-stderr",
                "local process = system.spawn(",
                "system.with_stdin, system.with_stdout, " ..
                "system.with_stderr",
                "local process_input? = process.stdin",
                "local process_output? = process.stdout",
                "local process_diagnostics? = process.stderr",
                "local writer: titan_io.WriterCloser =",
                "local reader: titan_io.Reader = process_output as " ..
                "system.InputStream",
                "process:is_running()",
                'writer:write(process_payload .. "\\n")',
                'reader:read_until("\\n", true) == process_payload',
                'net.connect("127.0.0.1", port)',
                'ssl.Error.new(',
                'url.parse("https://localhost:8443/static?q=1")',
                "system.exepath()",
                '"$OPENSSL_PKG_CONFIG" --cflags openssl',
                '"$OPENSSL_PKG_CONFIG" --libs openssl',
                "has_openssl_dependency",
                "defines_ssl_do_handshake",
                "has_public_lpeglabel_symbol",
                "has_unprefixed_lpeglabel_definition",
                "require_no_lpeglabel_dependency",
                '"$executable" "$marker" "$TITAN_PROCESS_SMOKE_CHILD"',
                'if ! defines_uv_version "$executable"',
                "OPENSSL_MODE=system",
            }) do
                assert.truthy(mode_smoke:find(contract, 1, true), contract)
            end
            assert.falsy(mode_smoke:find("communicate", 1, true))

            local process_smoke =
                read_file("spec/fixtures/libuv/os_production_smoke.lua")
            for _, contract in ipairs({
                'local system = require "titan.os"',
                "local merged = system.popen(",
                "mode .. \"-stdout\" .. mode .. \"-stderr\"",
                "system.with_stdin, system.with_stdout,",
                "local writer = assert(detached.stdin)",
                "local reader = assert(detached.stdout)",
                "local error_reader = assert(detached.stderr)",
                "assert(detached:is_running())",
                "assert(not exited:is_running())",
                "assert(not signalled:is_running())",
            }) do
                assert.truthy(process_smoke:find(contract, 1, true), contract)
            end
            assert.falsy(process_smoke:find("communicate", 1, true))

            local provider_smoke =
                read_file("spec/fixtures/libuv/stdlib_provider_smoke.lua")
            for _, contract in ipairs({
                'local builtin_io = require "io"',
                'local titan_io = require "titan.io"',
                'local ssl = require "titan.ssl"',
                'local url = require "titan.url"',
                'local http = require "titan.http"',
                'local websocket = require "titan.websocket"',
                'local math = require "titan.math"',
                'local lua = require "titan.lua"',
                'local iteration = require "titan.iteration"',
                'local gc = require "titan.gc"',
                'local testing = require "titan.test"',
                'assert(not testing.testing())',
                'local found = strings.match("regex42", "([0-9]+)")',
                'strings.find("a\\0b", "\\0b")',
                'assert(require "io" == builtin_io)',
                'gc.paused()',
            }) do
                assert.truthy(provider_smoke:find(contract, 1, true), contract)
            end

            local linux_workflow = read_file(".github/workflows/ci.yml")
            local macos_workflow = read_file(".github/workflows/macos.yml")
            -- Retain aggregate contracts across the independently triggered lanes.
            local workflow = linux_workflow .. "\n" .. macos_workflow
            local function count_literal(text, needle)
                local count = 0
                local offset = 1
                while true do
                    local first = text:find(needle, offset, true)
                    if not first then return count end
                    count = count + 1
                    offset = first + #needle
                end
            end
            local function named_job(text, name)
                local marker = "\n  " .. name .. ":"
                local first = assert(text:find(marker, 1, true), name)
                local start = first + #marker
                local finish = text:find("\n  [%w_-]+:%s*\n", start)
                    or (#text + 1)
                return text:sub(start, finish - 1)
            end
            local function named_step(job, name)
                local marker = "\n      - name: " .. name
                local first = assert(job:find(marker, 1, true), name)
                local finish = job:find(
                        "\n      - name:", first + #marker, true)
                    or (#job + 1)
                return job:sub(first, finish - 1)
            end
            local function step_containing(job, needle)
                local selected
                for first in job:gmatch("()\n      %- [^\n]*\n") do
                    local finish = job:find("\n      - ", first + 1, true) or (#job + 1)
                    local step = job:sub(first, finish - 1)
                    if step:find(needle, 1, true) then
                        assert.is_nil(selected, "duplicate step containing " .. needle)
                        selected = step
                    end
                end
                return assert(selected, "missing step containing " .. needle)
            end
            local function assert_codecov_upload(job, upload_name, upload_path, flag)
                assert.equal(1, count_literal(job, "contents: read"), job)
                assert.equal(1, count_literal(job, "id-token: write"), job)
                job = step_containing(job, "\n          name: " .. upload_name .. "\n")
                assert.equal(1,
                    count_literal(job, "codecov/codecov-action@v7"), job)
                assert.equal(1,
                    count_literal(job, "fail_ci_if_error: true"), job)
                assert.equal(1,
                    count_literal(job, "files: " .. upload_path), job)
                assert.equal(1, count_literal(job, "flags: " .. flag), job)
                assert.equal(1, count_literal(job,
                    "\n          name: " .. upload_name .. "\n"), job)
                assert.equal(1, count_literal(job, "use_oidc: true"), job)
                assert.falsy(job:find("\n%s+token:", 1), job)
            end

            local build_job = named_job(linux_workflow, "build-compiler")
            local compiler_job = named_job(linux_workflow, "test-linux-compiler")
            local browser_job = named_job(linux_workflow, "browser-toolchain")
            local browser_stdlib_job = named_job(linux_workflow, "browser-stdlib")
            local playwright_job = named_job(linux_workflow, "browser-playwright")
            local native_coverage_job = named_job(linux_workflow, "native-coverage")
            local macos_job = named_job(macos_workflow, "test-macos")
            local sanitizer_job = named_job(linux_workflow, "sanitizer")

            assert.equal(1, count_literal(linux_workflow, "\n  push:"),
                linux_workflow)
            assert.falsy(linux_workflow:find("workflow_dispatch", 1, true),
                linux_workflow)
            local macos_events = assert(macos_workflow:match("\non:(.-)\nenv:"))
            assert.truthy(macos_events:match("^%s*workflow_dispatch:%s*$"),
                macos_events)
            assert.equal(7, count_literal(linux_workflow,
                "if: github.event_name == 'push'"), linux_workflow)
            assert.equal(1, count_literal(macos_workflow,
                "if: github.event_name == 'workflow_dispatch'"), macos_workflow)
            assert.equal(7, count_literal(linux_workflow, "\n    runs-on:"),
                linux_workflow)
            assert.equal(1, count_literal(macos_workflow, "\n    runs-on:"),
                macos_workflow)
            for _, job_name in ipairs({
                "build-compiler", "test-linux-compiler", "browser-toolchain",
                "browser-stdlib",
                "browser-playwright", "native-coverage", "sanitizer",
            }) do
                assert.equal(1, count_literal(linux_workflow,
                    "\n  " .. job_name .. ":"), job_name)
                assert.falsy(macos_workflow:find(
                    "\n  " .. job_name .. ":", 1, true), job_name)
            end
            assert.equal(1, count_literal(browser_job,
                "\n    name: browser target real toolchain (ubuntu-24.04, emsdk 6.0.13, Node 26)\n"),
                browser_job)
            assert.equal(1, count_literal(browser_stdlib_job,
                "\n    name: browser SDK and core stdlib ${{ matrix.shard }} (ubuntu-24.04, emsdk 6.0.13, Node 26)\n"),
                browser_stdlib_job)
            assert.equal(1, count_literal(macos_workflow, "\n  test-macos:"),
                macos_workflow)
            assert.falsy(linux_workflow:find("\n  test-macos:", 1, true),
                linux_workflow)
            assert.falsy(macos_job:find("\n    needs:", 1, true), macos_job)
            assert.equal(1, count_literal(macos_workflow,
                'TITAN_ABI_VERSION: "2"'), macos_workflow)
            for _, removed in ipairs({
                "\n  test-linux-stdlib:", "\n  compiler-coverage:",
                "prepare-linux", "test-linux-library", "ubuntu-slim",
                "compiler-core", "compiler-heavy", "library-serial",
                "library-uv-fs", "library-net-os", "library-peg-string",
                "ci_test_groups.sh libraries",
                "run_titan_stdlib_test_groups.sh",
                "run_titan_stdlib_tests.sh",
            }) do
                assert.falsy(workflow:find(removed, 1, true), removed)
            end
            assert.falsy(workflow:find("awk", 1, true), workflow)
            assert.equal(5, count_literal(workflow,
                "codecov/codecov-action@v7"), workflow)
            assert.equal(4, count_literal(workflow,
                "id-token: write"), workflow)
            assert.equal(4, count_literal(workflow,
                'luacov "titan%-compiler/"'), workflow)
            assert.falsy(workflow:find("CODECOV_TOKEN", 1, true), workflow)

            for _, contract in ipairs({
                "name: compiler dependencies (ubuntu-24.04)",
                "runs-on: ubicloud-standard-2", "timeout-minutes: 30",
                "contents: read", "\n      CC: gcc-14\n",
                "\n      LUA_CC: gcc-14\n", "make lua luarocks",
                "luarocks make --only-deps", "luarocks test --prepare",
                "make install-compiler-sdk",
                'test -f "$PREFIX/lib/titan/0.6/libtitan.a"',
                'test ! -e "$PREFIX/lib/titan/0.6/titan.a"',
            }) do
                assert.equal(1, count_literal(build_job, contract), contract)
            end
            for _, forbidden in ipairs({
                "\n    needs:", "id-token: write", "codecov/codecov-action",
                "actions/download-artifact", "make stdlib", "make libuv",
                "make llhttp", "make sqlite3", "make openssl",
                "luarocks make --force", "C-probe results",
            }) do
                assert.falsy(build_job:find(forbidden, 1, true), forbidden)
            end
            assert.equal(2, count_literal(build_job, "-gcc14-prefix-"), build_job)
            for _, cache in ipairs({ "libuv", "llhttp", "sqlite3", "openssl" }) do
                assert.equal(2, count_literal(native_coverage_job,
                    "-gcc14-" .. cache .. "-"), cache)
            end
            assert.falsy(makefile:find(
                    "$(sort $(wildcard spec/stdlib/*_spec.lua))", 1, true),
                makefile)
            assert.falsy(makefile:find("STDLIB_BOUNDARY_TESTS", 1, true),
                makefile)
            for _, brittle_cleanup in ipairs({
                "test_runner_fixture__test_support.c",
                "test_runner_collision__test_runner.c",
                "nested/tests__main__test_entrypoint.c",
            }) do
                assert.falsy(makefile:find(brittle_cleanup, 1, true),
                    brittle_cleanup)
            end
            local clean_start = assert(makefile:find(
                "\nclean: ## Remove generated build/test artifacts", 1, true))
            local clean_finish = assert(makefile:find(
                "\nclean-lua:", clean_start, true))
            local clean_recipe = makefile:sub(clean_start, clean_finish - 1)
            assert.truthy(clean_recipe:find(
                "bash spec/support/clean_generated_test_artifacts.sh", 1, true))
            assert.falsy(clean_recipe:find("TITAN_LEGACY_SOURCE_OUTPUTS", 1, true))
            local generated_cleanup = read_file(
                "spec/support/clean_generated_test_artifacts.sh")
            for _, cleanup_pattern in ipairs({
                "*__test_support.*", "*__test_runner.*",
                "*__test_entrypoint.*", "test_runner_*",
            }) do
                assert.truthy(generated_cleanup:find(
                    cleanup_pattern, 1, true), cleanup_pattern)
            end
            for _, native_build_contract in ipairs({
                "async_foreign_work.h", "spec/fixtures/stdlib/native/async_foreign_work.c",
                "spec/fixtures/stdlib/native/fs_fixture.c", "uv_stdio_probe.h",
                "spec/fixtures/stdlib/native/uv_stdio_probe.c",
                "sqlite3_worker_fixture",
                "spec/fixtures/stdlib/native/os_process_host_child.c",
                "--c-source $(call make_shell_quote,$(abspath $(source)))",
            }) do
                assert.truthy(makefile:find(
                    native_build_contract, 1, true), native_build_contract)
            end
            assert.falsy(read_file(
                "spec/stdlib/titan/uv/runtime_tests.titan"):find(
                "${CC:-cc}", 1, true))
            assert.falsy(read_file(
                "spec/stdlib/titan/os/process_tests/" ..
                "host_process_test.titan"):find("${CC:-cc}", 1, true))
            for entry in lfs.dir("spec") do
                assert.falsy(entry:match("_boundary_spec[.]lua$"), entry)
            end
            local function assert_no_stdlib_lua(directory)
                for entry in lfs.dir(directory) do
                    if entry ~= "." and entry ~= ".." then
                        local path = directory .. "/" .. entry
                        local mode = assert(lfs.attributes(path, "mode"))
                        if mode == "directory" then
                            assert_no_stdlib_lua(path)
                        else
                            assert.falsy(entry:match("[.]lua$"), path)
                        end
                    end
                end
            end
            assert_no_stdlib_lua("spec/stdlib")
            local packaging_step = named_step(native_coverage_job,
                "Run retained runtime and packaging specs")
            for _, contract in ipairs({
                'TITAN_EXTRA_CFLAGS: "-O0 -fno-lto"',
                'TITAN_TEST_EXTRA_CFLAGS: "-O0 -fno-lto"',
                'TITAN_EXTRA_LDFLAGS: "-fno-lto"',
                'TITAN_TEST_EXTRA_LDFLAGS: "-fno-lto"',
                'make stdlib-busted-test EXTRA_TEST_FLAGS="-o gtest -v"',
            }) do
                assert.equal(1, count_literal(packaging_step, contract), contract)
            end
            assert.falsy(native_coverage_job:find("make stdlib-test", 1, true))
            assert.falsy(native_coverage_job:find("make titan-stdlib-test", 1, true))
            assert.truthy(native_coverage_job:find(
                'static_archive="${provider%.so}.a"', 1, true))
            for _, contract in ipairs({
                "archive: false", "--exclude='./.git'",
                "--exclude='./libbacktrace/.git'",
                "--exclude='./.lua/var/cache/titan-probes'",
                "prepared tree contains the independent C-probe cache",
                "grep -E '^\\./\\.lua/var/cache/titan-probes(/|$)' >/dev/null",
            }) do
                assert.truthy(build_job:find(contract, 1, true), contract)
            end
            local build_index = assert(build_job:find(
                "- name: Build and install the compiler SDK without the stdlib", 1, true))
            local pack_index = assert(build_job:find(
                "- name: Pack prepared Linux tree", build_index, true))
            local upload_index = assert(build_job:find(
                "- name: Upload prepared Linux tree", pack_index, true))
            assert.is_true(build_index < pack_index and pack_index < upload_index)

            assert.equal(13, count_literal(workflow,
                "uses: ubicloud/cache@v4"), workflow)
            assert.equal(2, count_literal(workflow,
                "uses: ubicloud/cache/restore@v4"), workflow)
            assert.equal(2, count_literal(workflow,
                "uses: ubicloud/cache/save@v4"), workflow)
            assert.equal(4, count_literal(workflow,
                "path: .lua/var/cache/titan-probes/2"), workflow)
            assert.falsy(workflow:find("TITAN_PROBE_CACHE_IDENTITY", 1, true))
            assert.equal(7, count_literal(workflow,
                "TITAN_PREFIX: ${{ github.workspace }}/.lua"), workflow)
            -- Keep the existing regular cache identity when moving its owner.
            assert.truthy(native_coverage_job:find("-test-linux-stdlib-", 1, true))
            for _, job in ipairs({
                build_job, compiler_job, browser_job, browser_stdlib_job,
                playwright_job, sanitizer_job,
            }) do
                assert.falsy(job:find("-test-linux-stdlib-", 1, true))
            end
            assert.truthy(sanitizer_job:find("-sanitizer-", 1, true))
            assert.truthy(macos_job:find("-test-macos-", 1, true))
            assert.equal(3, count_literal(workflow, "-${{ github.sha }}"), workflow)
            assert.equal(3, count_literal(workflow,
                "          key: titan-probes-2-"), workflow)

            local regular_cache_step = named_step(native_coverage_job,
                "Restore regular Linux C-probe results")
            for _, contract in ipairs({
                "id: regular-probe-cache", "uses: ubicloud/cache/restore@v4",
                "-test-linux-stdlib-",
            }) do
                assert.truthy(regular_cache_step:find(contract, 1, true), contract)
            end
            local regular_save_step = named_step(native_coverage_job,
                "Save regular Linux C-probe results")
            assert.truthy(regular_save_step:find("uses: ubicloud/cache/save@v4", 1, true))
            assert.truthy(regular_save_step:find(
                "${{ steps.regular-probe-cache.outputs.cache-primary-key }}", 1, true))
            local rock_install = named_step(native_coverage_job,
                "Build and install the rock")
            local install_index = assert(rock_install:find("luarocks make --force", 1, true))
            for _, temporary_copy in ipairs({
                'rm -f "$PREFIX/bin/titanc"',
                'rm -rf "$PREFIX/share/lua/5.5/titan-compiler"',
                '"$PREFIX/share/lua/5.5/c-parser"',
            }) do
                assert.is_true(assert(rock_install:find(temporary_copy, 1, true)) < install_index)
            end
            assert.falsy(rock_install:find('rm -rf "$PREFIX/share/lua/5.5"', 1, true))
            local previous = 0
            for _, step in ipairs({
                "Restore regular Linux C-probe results",
                "Build and install the rock",
                "Run retained runtime and packaging specs",
                "Run compiler integrations that require the installed stdlib",
                "Build complete production stdlib inventory with coverage",
                "Run complete covered aggregate with fresh counters",
                "Smoke-test bundled dependency source image",
                "Save regular Linux C-probe results",
                "Canary source-rock installation with system OpenSSL",
                "Upload stdlib compiler integration coverage to Codecov",
                "Upload native stdlib line coverage to Codecov",
            }) do
                local index = assert(native_coverage_job:find(
                    "- name: " .. step, 1, true), step)
                assert.is_true(previous < index, step)
                previous = index
            end

            assert.equal(1, count_literal(compiler_job,
                    "name: compiler/language shards ${{ matrix.shard-pair }} " ..
                    "(ubuntu-24.04, LuaCov)"),
                compiler_job)
            assert.equal(1, count_literal(compiler_job,
                'shard-pair: ["1-2", "3-4"]'), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "fail-fast: false"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "needs: build-compiler"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "runs-on: ubicloud-standard-2"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "timeout-minutes: 45"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "\n      CC: gcc-14\n"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "actions/download-artifact@v8"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "name: titan-linux-prepared.tar.gz"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "ci_parallel_compiler_tests.sh"), compiler_job)
            assert.truthy(compiler_job:find(
                'ci_parallel_compiler_tests.sh "${{ matrix.shard-pair }}"',
                1, true), compiler_job)
            assert.falsy(compiler_job:find(
                "ci_test_groups.sh compiler", 1, true), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                'TITAN_EXTRA_CFLAGS: "-O0 -fno-lto"'), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                'TITAN_EXTRA_LDFLAGS: "-fno-lto"'), compiler_job)
            assert.falsy(compiler_job:find(
                "ci_stdlib_snapshot.sh", 1, true), compiler_job)
            local compiler_unpack_index = assert(compiler_job:find(
                "- name: Restore prepared Linux tree and environment",
                1, true))
            local compiler_tests_index = assert(compiler_job:find(
                "- name: Run two isolated compiler shards with covered " ..
                "and stress invocations",
                compiler_unpack_index, true))
            assert.is_true(compiler_unpack_index < compiler_tests_index)
            local compiler_upload_index = assert(compiler_job:find(
                "- name: Upload compiler pair coverage",
                compiler_tests_index, true))
            assert.is_true(compiler_tests_index < compiler_upload_index)
            local compiler_upload = named_step(
                compiler_job, "Upload compiler pair coverage")
            for _, required in ipairs({
                "actions/upload-artifact@v7",
                "name: titan-compiler-coverage-${{ matrix.shard-pair }}",
                "path: |\n            luacov.stats.out\n            luacov.codecov.out",
                "if-no-files-found: error",
                "overwrite: true",
            }) do
                assert.truthy(compiler_upload:find(required, 1, true), required)
            end
            assert.falsy(compiler_job:find("continue-on-error", 1, true))
            assert_codecov_upload(compiler_job,
                "compiler-${{ matrix.shard-pair }}", "./luacov.codecov.out", "compiler")
            assert.falsy(compiler_job:find("native-stdlib", 1, true))
            assert.falsy(linux_workflow:find("merge_luacov_stats.lua", 1, true))
            assert.falsy(compiler_job:find(
                "C-probe results", 1, true))
            assert.truthy(read_file(
                "spec/support/ci_test_groups.sh"):find(
                "TITAN_PROBE_CACHE_DISABLE=1", 1, true))
            local compiler_groups = read_file(
                "spec/support/ci_test_groups.sh")
            for _, required in ipairs({
                "ci_compiler_stress_files.txt",
                "compiler_stress_tests=()",
                "compiler_unit_stress_tests=()",
                "compiler_isolated_stress_tests=()",
                "run_compiler_stress",
                "run_isolated_compiler_stress",
                "--exclude-tags=stress",
                "--tags=stress",
            }) do
                assert.truthy(compiler_groups:find(required, 1, true),
                    required)
            end
            assert.equal(5, count_literal(workflow,
                "TITAN_PROBE_CACHE_DISABLE=1"), workflow)
            local compiler_report = named_step(compiler_job,
                "Generate compiler coverage report")
            for _, contract in ipairs({
                'luacov "titan%-compiler/" "titanc$"',
                "lua spec/support/prepare_codecov_report.lua",
                "luacov.report.out luacov.codecov.out",
            }) do
                assert.equal(1, count_literal(compiler_report, contract), contract)
            end
            assert.falsy(compiler_report:find("grep -Fxq titanc.lua", 1, true))
            assert.truthy(read_file(".codecov.yml"):find(
                '"^titanc[.]lua$::titanc"', 1, true))

            for _, job in ipairs({ browser_job, browser_stdlib_job }) do
                for _, contract in ipairs({
                    "\n    needs: build-compiler\n", "runs-on: ubicloud-standard-4",
                    "timeout-minutes: 60",
                    'TITAN_EMSDK_VERSION: "6.0.13"',
                    "emsdk-${{ env.TITAN_EMSDK_VERSION }}-v1",
                    "git clone --depth 1 https://github.com/emscripten-core/emsdk.git",
                    '"$TITAN_EMSDK_ROOT/emsdk" install "$TITAN_EMSDK_VERSION"',
                    '"$TITAN_EMSDK_ROOT/emsdk" activate "$TITAN_EMSDK_VERSION"',
                    'TITAN_CHROME_VERSION: "156.0.8078.80"',
                    "547dcd374e02961bf998f6046a267644f8502225c36bb78ca307dab32a0b3eb4",
                    "chrome-headless-shell-${{ env.TITAN_CHROME_VERSION }}-${{ env.TITAN_CHROME_SHA256 }}-v1",
                    "sha256sum -c --strict -",
                    "python3 scripts/browser_extract_zip.py",
                    "browser-chrome-sandbox.log", "df -h /dev/shm",
                    'sudo sysctl -w "$key=0"',
                    'rm -f "$PREFIX/bin/titanc"',
                    'rm -rf "$PREFIX/share/lua/5.5/titan-compiler"',
                    "actions/download-artifact@v8",
                    "name: titan-linux-prepared.tar.gz",
                    'echo "$PWD/.lua/bin" >> "$GITHUB_PATH"',
                    'make lua-browser PREFIX="$PREFIX"',
                    '"$PREFIX/bin/luarocks" make',
                    'make browser-sdk PREFIX="$PREFIX"',
                    "titan-browser-library.js titan-browser-bridge.js titan-browser-trace.js",
                    'test -z "${EMSDK:-}"', "! command -v emcc",
                    'TITAN_PROBE_CACHE_DISABLE: "1"', "if: failure()",
                }) do
                    assert.equal(1, count_literal(job, contract), contract)
                end
                local previous = 0
                for _, command in ipairs({
                    'tar -xzf "$RUNNER_TEMP/titan-linux-prepared.tar.gz"',
                    '"$TITAN_EMSDK_ROOT/emsdk" install "$TITAN_EMSDK_VERSION"',
                    'node_bin=$(command -v node)',
                    "python3 scripts/browser_extract_zip.py",
                    "grep -q 'id=\"sandbox\"' \"$log\"",
                    'make lua-browser PREFIX="$PREFIX"',
                    '"$PREFIX/bin/luarocks" make',
                    'make browser-sdk PREFIX="$PREFIX"',
                    "gate_specs", '"$PREFIX/bin/busted" -c -o gtest -v',
                    'luacov "titan%-compiler/" "titanc$"',
                    "lua spec/support/prepare_codecov_report.lua",
                    "codecov/codecov-action@v7",
                }) do
                    previous = assert(job:find(command, previous + 1, true), command)
                end
                local gate = step_containing(job, '"$PREFIX/bin/busted" -c -o gtest -v')
                assert.equal(1, count_literal(gate,
                    "TITAN_ROOT: ${{ github.workspace }}/.lua"), gate)
                assert.equal(1, count_literal(gate,
                    'TITAN_REQUIRE_BROWSER_TOOLCHAIN: "1"'), gate)
                assert.truthy(gate:find('[[ ! -f $gate_spec ]]', 1, true), gate)
                assert.truthy(gate:find('"${gate_specs[@]}"', 1, true), gate)
                -- All browser runners reinstall the native compiler without Emscripten
                -- and must retire every unregistered preparation copy.
                local rocks = step_containing(job, '"$PREFIX/bin/luarocks" make')
                for _, contract in ipairs({
                    'test -z "${EMSDK:-}"', "! command -v emcc",
                    'rm -rf "$PREFIX/share/lua/5.5/c-parser"',
                }) do
                    assert.truthy(rocks:find(contract, 1, true), contract)
                end
                -- A re-pinned ZIP digest must invalidate either job's cache.
                local chrome_cache = step_containing(job,
                    "path: ${{ env.TITAN_CHROME_ROOT }}")
                assert.truthy(chrome_cache:find(
                    "${{ env.TITAN_CHROME_SHA256 }}", 1, true), chrome_cache)
                assert.falsy(chrome_cache:find("restore-keys:", 1, true),
                    chrome_cache)
                -- Extract only the verified pinned ZIP, in the step that
                -- installs Chrome for either job.
                local chrome_install = step_containing(job,
                    "python3 scripts/browser_extract_zip.py")
                local verified = assert(chrome_install:find(
                    "sha256sum -c --strict -", 1, true), chrome_install)
                assert.truthy(chrome_install:find(
                    "python3 scripts/browser_extract_zip.py", verified, true),
                    chrome_install)
                -- Keep Chrome sandboxed in both jobs; qualify the host
                -- restriction and record the launch proof in its own step.
                local sandbox = step_containing(job,
                    "key=kernel.apparmor_restrict_unprivileged_userns")
                for _, contract in ipairs({
                    "key=kernel.apparmor_restrict_unprivileged_userns",
                    "clone=/proc/sys/kernel/unprivileged_userns_clone",
                    "df -h /dev/shm", 'sysctl -n "$key" 2>/dev/null',
                    'if [ "$state" != "0" ]',
                    "browser-chrome-sandbox.log", "--dump-dom",
                }) do
                    assert.truthy(sandbox:find(contract, 1, true), contract)
                end
                assert.falsy(job:find("--no-sandbox", 1, true), job)
                assert.falsy(job:find("TITAN_BROWSER_ROOT_NO_SANDBOX", 1, true),
                    job)
            end
            local stdlib_matrix = assert(browser_stdlib_job:match(
                "\n    strategy:\n(.-)\n    permissions:"))
            assert.truthy(stdlib_matrix:find("fail-fast: false", 1, true))
            assert.falsy(stdlib_matrix:find("max-parallel:", 1, true))
            local stdlib_shards = {}
            local suite_shards = 0
            for first, name in stdlib_matrix:gmatch("()\n          %- shard: ([%w_-]+)") do
                local finish = stdlib_matrix:find("\n          - shard:", first + 1, true)
                    or (#stdlib_matrix + 1)
                local shard = stdlib_matrix:sub(first, finish - 1)
                assert.is_nil(stdlib_shards[name], "duplicate browser stdlib shard " .. name)
                stdlib_shards[name] = assert(shard:match("\n            gate%-specs: >%-\n(.*)"))
                local suite = assert(shard:match("\n            stdlib%-suite: (%w+)\n"))
                assert.is_true(suite == "true" or suite == "false", suite)
                if suite == "true" then
                    suite_shards = suite_shards + 1
                    assert.equal("sdk", name)
                end
            end
            assert.equal(1, suite_shards)
            local stdlib_gate_step = step_containing(browser_stdlib_job,
                '"$PREFIX/bin/busted" -c -o gtest -v')
            assert.truthy(stdlib_gate_step:find(
                "TITAN_BROWSER_GATE_SPECS: ${{ matrix.gate-specs }}", 1, true))
            assert.truthy(stdlib_gate_step:find(
                'read -r -a gate_specs <<< "$TITAN_BROWSER_GATE_SPECS"', 1, true))
            assert_codecov_upload(browser_job, "browser", "./luacov.codecov.out", "compiler")
            assert_codecov_upload(browser_stdlib_job, "browser-stdlib-${{ matrix.shard }}",
                "./luacov.codecov.out", "compiler")
            assert.truthy(browser_stdlib_job:find(
                "name: browser-stdlib-${{ matrix.shard }}-failure", 1, true))
            local all_gate_specs = {}
            for _, group in ipairs({
                { array = assert(step_containing(browser_job, "gate_specs=("):match(
                    "gate_specs=%((.-)\n          %)")), specs = {
                    "spec/wasm_toolchain_spec.lua",
                    "spec/coder/browser_toolchain_spec.lua",
                    "spec/browser_trace_map_spec.lua",
                    "spec/coder/browser_trace_entries_spec.lua",
                    "spec/coder/browser_budgets_spec.lua",
                } },
                { array = assert(stdlib_shards.sdk), specs = {
                    "spec/coder/browser_bridge_spec.lua",
                    "spec/coder/browser_stdlib_gate_spec.lua",
                    "spec/coder/browser_entry_gate_spec.lua",
                    "spec/coder/browser_images_spec.lua",
                    "spec/coder/browser_net_spec.lua",
                    "spec/minicoro_spec.lua",
                    "spec/coder/browser_fixtures_spec.lua",
                    "spec/coder/browser_providers_spec.lua",
                } },
                { array = assert(stdlib_shards.scheduler), specs = {
                    "spec/coder/browser_scheduler_spec.lua",
                    "spec/coder/browser_incremental_spec.lua",
                    "spec/browser_sdk_spec.lua",
                    "spec/coder/browser_stdlib_closure_spec.lua",
                    "spec/coder/browser_protocol_spec.lua",
                } },
            }) do
                local actual = {}
                for path in group.array:gmatch("spec/[%w_/-]+_spec%.lua") do
                    assert.is_nil(actual[path], "duplicate gate spec " .. path)
                    assert.is_nil(all_gate_specs[path], "gate spec in multiple runners: " .. path)
                    actual[path], all_gate_specs[path] = true, true
                end
                for _, path in ipairs(group.specs) do
                    assert.is_true(actual[path], "missing gate spec " .. path)
                    actual[path] = nil
                end
                assert.is_nil(next(actual), "unexpected gate spec")
            end
            stdlib_shards.sdk, stdlib_shards.scheduler = nil, nil
            assert.is_nil(next(stdlib_shards), "unexpected browser stdlib shard")
            for _, contract in ipairs({
                "browser-loader.log", "browser-guard.log",
                '"$TITAN_NODE" --test spec/browser/runner.test.mjs',
                "--js-test spec/browser/loader.test.mjs",
            }) do
                assert.equal(1, count_literal(browser_job, contract), contract)
                assert.falsy(browser_stdlib_job:find(contract, 1, true), contract)
            end
            assert.falsy(browser_job:find("make titan-stdlib-browser-test", 1, true))
            assert.falsy(browser_job:find("out/browser-stdlib/", 1, true),
                browser_job)
            local stdlib_sdk = assert(browser_stdlib_job:find(
                'make browser-sdk PREFIX="$PREFIX"', 1, true))
            local stdlib_suite = assert(browser_stdlib_job:find(
                "make titan-stdlib-browser-test", stdlib_sdk, true))
            local stdlib_gate = assert(browser_stdlib_job:find("read -r -a gate_specs", stdlib_suite, true))
            assert.is_true(stdlib_sdk < stdlib_suite and stdlib_suite < stdlib_gate)
            assert.truthy(named_step(browser_stdlib_job,
                "Run complete browser core stdlib suite under Node and Chromium"):find(
                "if: matrix.stdlib-suite", 1, true))
            assert.truthy(browser_stdlib_job:find("out/browser-net/**", 1, true))
            assert.falsy(linux_workflow:find("HigherRendererMemoryLimit", 1, true))
            assert.falsy(browser_stdlib_job:find("titan-stdlib-chrome", 1, true))
            for _, job in ipairs({ browser_job, browser_stdlib_job, playwright_job }) do
                assert.truthy(job:find('TITAN_NODE_VERSION: "26.13.0"', 1, true))
                local install_node = named_step(job, "Install the pinned Node 26 runtime")
                assert.truthy(install_node:find("uses: actions/setup-node@v6", 1, true))
                assert.truthy(install_node:find(
                    "node-version: ${{ env.TITAN_NODE_VERSION }}", 1, true))
                local browser_node = named_step(job, "Select and qualify Node 26")
                for _, contract in ipairs({
                    'node_bin=$(command -v node)',
                    'test "$version" = "v$TITAN_NODE_VERSION"',
                    "WebAssembly.promising", "WebAssembly.Suspending",
                    'echo "TITAN_NODE=$node_bin" >> "$GITHUB_ENV"',
                }) do
                    assert.truthy(browser_node:find(contract, 1, true), contract)
                end
            end
            local browser_gate_index = assert(browser_job:find("gate_specs=(", 1, true))
            local browser_runner_index = assert(browser_job:find(
                '"$TITAN_NODE" --test spec/browser/runner.test.mjs', browser_gate_index, true))
            local browser_upload_index = assert(browser_job:find(
                "name: browser-toolchain-failure", browser_runner_index, true))
            assert.is_true(browser_gate_index < browser_runner_index and
                browser_runner_index < browser_upload_index)
            local node_trace_gate = named_step(browser_job,
                "Build and run the browser trace gate under Node")
            assert.equal(1, count_literal(node_trace_gate,
                "TITAN_ROOT: ${{ github.workspace }}/.lua"), node_trace_gate)
            local browser_loader = named_step(browser_job,
                "Run the portable loader suite under Node and Chromium")
            assert.truthy(browser_loader:find("for engine in node chromium",
                1, true), browser_loader)
            local browser_coverage_index = assert(browser_job:find(
                "codecov/codecov-action@v7", browser_gate_index, true))
            assert.is_true(browser_coverage_index <
                assert(browser_job:find("--js-test spec/browser/loader.test.mjs",
                    browser_coverage_index, true)))
            local browser_guard = named_step(browser_job,
                "Run the optimized guard suite under Node and Chromium")
            assert.truthy(browser_guard:find("optimized-guard.mjs", 1, true),
                browser_guard)
            local browser_guard_build = named_step(browser_job,
                "Build the portable loader images for both assertion profiles")
            assert.truthy(browser_guard_build:find("--ldflag=-Os", 1, true),
                browser_guard_build)

            local trace_units = named_step(browser_job,
                "Run the browser trace adapter and supervisor units")
            for _, contract in ipairs({
                'for assertions in 2 0; do',
                'spec/fixtures/browser_trace_adapter/lifecycle.c',
                'spec/fixtures/browser_trace_adapter/filter.c titan-runtime/titan.c',
                'TITAN_BROWSER_TRACE_LIFECYCLE_IMAGE="$output/lifecycle-$assertions.mjs"',
                'TITAN_BROWSER_TRACE_FILTER_IMAGE="$output/filter-$assertions.mjs"',
                '"$TITAN_NODE" --test spec/browser/trace-adapter.test.mjs',
                'spec/browser/playwright-runner.test.mjs',
            }) do
                assert.truthy(trace_units:find(contract, 1, true),
                    "missing compiled trace unit contract " .. contract)
            end
            assert.equal(2, count_literal(trace_units,
                '-sASSERTIONS="$assertions"'), trace_units)

            for _, contract in ipairs({
                "needs: build-compiler", "runs-on: ubicloud-standard-4",
                "timeout-minutes: 60",
                "profile: [validation, production]",
                "engine: [chromium, firefox, webkit]",
                'TITAN_PLAYWRIGHT_VERSION: "1.64.1"',
                'TITAN_VITE_VERSION: "8.3.6"',
                "TITAN_VITE_ROOT:",
                "PLAYWRIGHT_BROWSERS_PATH:",
                "emsdk-${{ env.TITAN_EMSDK_VERSION }}-v1",
                "playwright-${{ env.TITAN_PLAYWRIGHT_VERSION }}-${{ matrix.engine }}-v1",
                "spec/browser/build-trace.lua",
                "spec/browser/build-bridge.lua",
                "${{ env.TITAN_BRIDGE_OUTPUT }}",
                "${{ env.TITAN_NET_OUTPUT }}",
                "spec/browser/build-net.lua",
                "${{ env.TITAN_DELIVERY_OUTPUT }}",
                "spec/browser/build-delivery.lua",
                "spec/fixtures/browser_delivery/hosted.mjs",
                "spec/fixtures/browser_net/run.mjs",
                "spec/browser/playwright-run.mjs",
                "spec/browser/playwright-runner.test.mjs",
                "--allow-degraded-trace",
                "manifest.degradedCases",
                "result.status !== 1",
                "result.stdout.length !== 0",
                "degraded browser trace:",
                "ordinary initialization failure before Lua/main",
                "browser-playwright-${{ matrix.profile }}-${{ matrix.engine }}",
            }) do
                assert.truthy(playwright_job:find(contract, 1, true), contract)
            end
            local bridge_build = named_step(playwright_job,
                "Build the portable bridge gate for both assertion modes")
            assert.falsy(bridge_build:find("if:", 1, true), bridge_build)
            assert.truthy(bridge_build:find(
                'lua -E spec/browser/build-bridge.lua "$TITAN_BRIDGE_OUTPUT"', 1, true))
            local bridge_gate = named_step(playwright_job,
                "Run the persistent bridge and opaque-Promise diagnostics")
            assert.falsy(bridge_gate:find("if:", 1, true), bridge_gate)
            for _, contract in ipairs({
                "for (const assertions of [2, 0])",
                "['integration.mjs', 0,",
                "`assertions-${assertions}/public-states.mjs`",
                "status === 0 ? images : images.slice(0, 1)",
                "['unhandled.mjs', 74,",
                "['unhandled-result.mjs', 74,",
                "['poison-retirement.mjs', 70, 'poison-retirement-complete']",
                "const pages = engine === 'node' ? [] : [",
                "['counter.mjs', 0, 'COUNTER {\"verdict\":\"PASS\"']",
                "['responsive.mjs', 0, 'RESPONSIVE {\"verdict\":\"PASS\"']",
                "pages.some(([page]) => page === script) ? [`assertions-${assertions}/${script}`]",
                "!receipt.includes(marker)",
                "process.env.TITAN_BUILD_PROFILE === 'production' && engines[0] === 'chromium'",
                "engines.push('node')",
                "result.status !== status",
                "browser-playwright-bridge.log",
            }) do
                assert.truthy(bridge_gate:find(contract, 1, true), contract)
            end
            -- integration.mjs requires its third image; the CI builder makes it
            -- exactly as browser_bridge_spec.lua does.
            local bridge_builder = read_file("spec/browser/build-bridge.lua")
            assert.truthy(bridge_builder:find(
                '{name="public-states", owner="browser.public_state_tests", testing=true,', 1, true), bridge_builder)
            local net_build = named_step(playwright_job,
                "Build the live browser HTTP and WebSocket client fixtures")
            assert.falsy(net_build:find("if:", 1, true), net_build)
            assert.truthy(net_build:find(
                'lua -E spec/browser/build-net.lua "$TITAN_NET_OUTPUT"', 1, true))
            local net_python = named_step(playwright_job,
                "Verify Python for Chromium HTTPS trust")
            assert.truthy(net_python:find("if: matrix.engine == 'chromium'", 1, true))
            assert.truthy(net_python:find("run: python3 --version", 1, true))
            local net_gate = named_step(playwright_job,
                "Run live HTTP, HTTPS, and WebSocket clients on the managed engine")
            assert.falsy(net_gate:find("if:", 1, true), net_gate)
            for _, contract in ipairs({
                '"$TITAN_NODE" spec/fixtures/browser_net/run.mjs',
                '--root "$TITAN_NET_OUTPUT" --engine "$TITAN_TRACE_ENGINE"',
                '--sdk "$PREFIX/lib/titan-browser/0.6"',
                '--runner "$PWD/spec/browser/playwright-run.mjs" --repository "$PWD" --persistent-webkit',
                "browser-playwright-net.log",
            }) do
                assert.truthy(net_gate:find(contract, 1, true), contract)
            end
            local _, persistent_steps = playwright_job:gsub("%-%-persistent%-webkit", "")
            assert.equals(1, persistent_steps, "only browser-net uses a persistent WebKit context")
            local vite_install = named_step(playwright_job,
                "Install the pinned Vite deployment dependency")
            assert.truthy(vite_install:find("if: matrix.engine == 'chromium'", 1, true))
            assert.truthy(vite_install:find(
                'PATH="${TITAN_NODE%/*}:$PATH" npm install --prefix "$TITAN_VITE_ROOT"', 1, true))
            assert.truthy(vite_install:find('"vite@$TITAN_VITE_VERSION"', 1, true))
            local docs_gate = named_step(playwright_job,
                "Run the browser chapter's documented page, server and Vite examples")
            for _, contract in ipairs({
                "if: matrix.engine == 'chromium'",
                'TITAN_REQUIRE_BROWSER_TOOLCHAIN: "1"',
                'TITAN_REQUIRE_BROWSER_DEPLOYMENT: "1"',
                'TITAN_PROBE_CACHE_DISABLE: "1"',
                'source "$TITAN_EMSDK_ROOT/emsdk_env.sh"',
                '"$PREFIX/bin/busted" -o gtest -v spec/coder/browser_docs_spec.lua',
                "browser-playwright-docs.log",
            }) do
                assert.truthy(docs_gate:find(contract, 1, true), contract)
            end
            -- The complete application: every cell builds it by its section's
            -- commands and runs the hosted test; production cells keep records.
            local delivery_build = named_step(playwright_job,
                "Build the browser chapter's complete application and its server")
            assert.falsy(delivery_build:find("if:", 1, true), delivery_build)
            assert.truthy(delivery_build:find(
                'lua -E spec/browser/build-delivery.lua "$TITAN_DELIVERY_OUTPUT"', 1, true), delivery_build)
            local hosted = named_step(playwright_job, "Run the complete application's hosted deployment test")
            assert.falsy(hosted:find("if:", 1, true), hosted)
            for _, contract in ipairs({
                '"$TITAN_NODE" spec/fixtures/browser_delivery/hosted.mjs --engine "$TITAN_TRACE_ENGINE"',
                '--root "$TITAN_DELIVERY_OUTPUT" "${records[@]}"',
                'if [ "$TITAN_BUILD_PROFILE" = production ]; then',
                'records=(--records "$PWD/out/browser-records/playwright-$TITAN_TRACE_ENGINE.json")',
            }) do
                assert.truthy(hosted:find(contract, 1, true), contract)
            end
            local delivery_node = named_step(playwright_job, "Run the complete application under Node")
            assert.truthy(delivery_node:find("if: matrix.engine == 'chromium'", 1, true), delivery_node)
            assert.truthy(delivery_node:find(
                '--root "$TITAN_DELIVERY_OUTPUT" --js-test "$TITAN_DELIVERY_OUTPUT/dod.test.mjs"', 1, true),
                delivery_node)
            local records = named_step(playwright_job, "Upload browser records")
            for _, contract in ipairs({
                "if: always() && matrix.profile == 'production'",
                "name: browser-records-playwright-${{ matrix.engine }}",
                "path: out/browser-records/",
            }) do
                assert.truthy(records:find(contract, 1, true), contract)
            end
            -- Every validation cell runs the stdlib aggregate on its engine,
            -- last, so that failing cases leave the earlier gates' receipts.
            local playwright_suite = named_step(playwright_job,
                "Run the complete browser core stdlib suite on the managed engine")
            for _, contract in ipairs({
                "if: matrix.profile == 'validation'",
                'make titan-stdlib-browser-test PREFIX="$PREFIX" TITAN_BROWSER_TEST_ENGINES="$TITAN_TRACE_ENGINE"',
                'TITAN_BROWSER_TEST_RUNNER="\\"$TITAN_NODE\\" spec/browser/playwright-run.mjs --image --sdk',
                'tee "$RUNNER_TEMP/browser-playwright-stdlib.log"',
            }) do
                assert.truthy(playwright_suite:find(contract, 1, true), contract)
            end
            assert.equal(1, count_literal(playwright_job, "make titan-stdlib-browser-test"), playwright_job)
            local _, later = playwright_job:match("()%- name: Run the complete browser core stdlib suite.-\n()%s*%- name:")
            assert.truthy(later and playwright_job:sub(later):match("^%s*%- name: Upload Playwright trace receipts"),
                "the stdlib aggregate is the last test step")
            assert.falsy(playwright_job:find("browser_deployment_spec", 1, true), playwright_job)
            assert.falsy(browser_job:find("TITAN_VITE_VERSION", 1, true))
            assert.falsy(browser_stdlib_job:find("TITAN_VITE_VERSION", 1, true))
            assert.falsy(browser_job:find("TITAN_PLAYWRIGHT_VERSION", 1, true),
                browser_job)
            assert.falsy(playwright_job:find("TITAN_CHROME_VERSION", 1, true),
                playwright_job)
            for _, step in ipairs({
                "Download prepared Linux tree",
                "Restore prepared Linux tree and environment",
            }) do
                local body = named_step(playwright_job, step)
                assert.truthy(body:find("if: matrix.profile == 'validation'",
                    1, true), body)
            end
            local production_bootstrap = named_step(playwright_job,
                "Bootstrap an independent production prefix")
            for _, contract in ipairs({
                "if: matrix.profile == 'production'",
                "test ! -e .ci-prepared-workspace",
                'test ! -e "$PREFIX"',
                "make lua luarocks",
                '"$PREFIX/bin/luarocks" make --only-deps',
                '"$PREFIX/bin/luarocks" test --prepare',
                "make libbacktrace",
            }) do
                assert.truthy(production_bootstrap:find(contract, 1, true),
                    contract)
            end
            assert.is_true(assert(playwright_job:find(
                "- name: Bootstrap an independent production prefix", 1, true)) <
                assert(playwright_job:find(
                "- name: Install the selected native compiler and SDK profile",
                1, true)), playwright_job)

            for _, contract in ipairs({
                "name: stdlib build, tests and coverage (ubuntu-24.04, GCC 14)",
                "needs: build-compiler", "runs-on: ubicloud-standard-4",
                'MAKEFLAGS: "-j4"', 'TITAN_JOBS: "4"',
                "timeout-minutes: 60", "\n      CC: gcc-14\n",
                "\n      GCOV: gcov-14\n", "gcc-14 clang-format python3-venv",
                "name: titan-linux-prepared.tar.gz",
                'pip" install -r scripts/titan-coverage-requirements.txt',
                "make titan-native-coverage-build TITAN_COVERAGE_GCOV=gcov-14",
                "Build complete production stdlib inventory with coverage",
            }) do
                assert.equal(1, count_literal(native_coverage_job, contract), contract)
            end
            assert.equal(1, count_literal(native_coverage_job,
                "actions/download-artifact@v8"), native_coverage_job)
            local integration_step = named_step(native_coverage_job,
                "Run compiler integrations that require the installed stdlib")
            local integration_previous = 0
            for _, contract in ipairs({
                "ci_stdlib_snapshot.sh save", "ci_parallel_compiler_tests.sh stdlib",
                "ci_stdlib_snapshot.sh restore", 'luacov "titan%-compiler/"',
                "lua spec/support/prepare_codecov_report.lua",
                "grep -Fxq titanc.lua luacov.codecov.out",
            }) do
                local index = assert(integration_step:find(contract, 1, true), contract)
                assert.is_true(integration_previous < index, contract)
                integration_previous = index
            end
            assert.falsy(integration_step:find("ci_test_groups.sh", 1, true),
                integration_step)
            local covered_run = named_step(native_coverage_job,
                "Run complete covered aggregate with fresh counters")
            assert.equal(1, count_literal(native_coverage_job,
                "make titan-native-coverage-run"), native_coverage_job)
            assert.falsy(covered_run:find("TITAN_FILTER", 1, true))
            assert.falsy(covered_run:find("TITAN_TEST_TIMEOUT=15", 1, true))
            local shutdown_run = named_step(sanitizer_job,
                "Check native Runtime shutdown deadline")
            assert.truthy(shutdown_run:find(
                "ci_sanitizer_capture.sh runtime-shutdown", 1, true))
            assert.truthy(shutdown_run:find("make titan-stdlib-test-run", 1, true))
            assert.truthy(shutdown_run:find(
                "TITAN_FILTER='test_runtime_shutdown_closes_native_handles_but_not_files$'",
                1, true))
            assert.truthy(shutdown_run:find("TITAN_TEST_TIMEOUT=15", 1, true))
            assert.is_true(assert(sanitizer_job:find(
                "- name: Build unified native stdlib sanitizer executable", 1, true)) <
                assert(sanitizer_job:find(
                    "- name: Check native Runtime shutdown deadline", 1, true)))
            local native_artifacts = named_step(native_coverage_job,
                "Retain local reports and collection evidence")
            for _, contract in ipairs({ "if: always()", "actions/upload-artifact@v7",
                "name: titan-native-line-coverage", "path: out/coverage",
                "include-hidden-files: true", "if-no-files-found: error" }) do
                assert.truthy(native_artifacts:find(contract, 1, true), contract)
            end
            assert.falsy(native_coverage_job:find("continue-on-error", 1, true))
            assert_codecov_upload(native_coverage_job,
                "compiler-stdlib", "./luacov.codecov.out", "compiler")
            assert_codecov_upload(native_coverage_job,
                "native-stdlib-lines", "out/coverage/report/coverage.info", "native-stdlib")
            local native_upload = named_step(native_coverage_job,
                "Upload native stdlib line coverage to Codecov")
            assert.truthy(native_upload:find("if: success()", 1, true), native_upload)
            local codecov_policy = read_file(".codecov.yml")
            assert.equal(2, count_literal(codecov_policy, "flags: [compiler]"), codecov_policy)
            assert.truthy(codecov_policy:find("  native-stdlib:\n    paths:\n      - titan/", 1, true),
                codecov_policy)

            assert.equal(1, count_literal(macos_job,
                "if: github.event_name == 'workflow_dispatch'"), macos_job)
            assert.falsy(macos_job:find(
                "if: github.event_name == 'push'", 1, true), macos_job)
            assert.equal(1, count_literal(macos_job,
                'MAKEFLAGS: "-j3"'), macos_job)
            assert.equal(1, count_literal(macos_job,
                'TITAN_JOBS: "3"'), macos_job)
            assert.equal(1, count_literal(macos_job,
                "make stdlib-test"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "make titan-stdlib-test-run"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "TITAN_TEST_TIMEOUT=15"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "ci_test_groups.sh compiler-uncovered"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "ci_stdlib_snapshot.sh save"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "ci_stdlib_snapshot.sh restore"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "ci_dependency_mode_smoke.sh"), macos_job)
            assert.falsy(macos_job:find('luacov "', 1, true), macos_job)
            assert.falsy(macos_job:find("id-token: write", 1, true),
                macos_job)
            assert.equal(2, count_literal(macos_job,
                "ci_retry_luarocks_dependencies.sh"), macos_job)
            assert.equal(2, count_literal(workflow,
                "ci_retry_luarocks_dependencies.sh"), workflow)
            assert.equal(1, count_literal(macos_job,
                "luarocks make --only-deps"), macos_job)
            assert.equal(2, count_literal(macos_job,
                "luarocks make --force"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "luarocks test --prepare"), macos_job)
            local macos_cache_index = assert(macos_job:find(
                "- name: Restore macOS C-probe results", 1, true))
            local macos_build_index = assert(macos_job:find(
                "- name: Build and install the rock", macos_cache_index,
                true))
            local macos_tests_index = assert(macos_job:find(
                "- name: Run complete macOS tests without coverage",
                macos_build_index, true))
            assert.is_true(macos_cache_index < macos_build_index)
            assert.is_true(macos_build_index < macos_tests_index)
            local sanitizer_cache_index = assert(sanitizer_job:find(
                "- name: Restore sanitizer C-probe results", 1, true))
            local sanitizer_build_index = assert(sanitizer_job:find(
                "- name: Build sanitizer-enabled Titan artifacts",
                sanitizer_cache_index, true))
            assert.is_true(sanitizer_cache_index < sanitizer_build_index)

            for _, contract in ipairs({
                'LLHTTP_VERSION: "9.4.3"',
                'OPENSSL_VERSION: "3.5.7"',
                "Cache bundled llhttp source and static build",
                "Cache bundled SQLite amalgamation and static build",
                "sqlite-autoconf-${{ env.SQLITE3_RELEASE }}.tar.gz",
                "Build the pinned private SQLite support",
                "run: make sqlite3",
                "llhttp-release-v${{ env.LLHTTP_VERSION }}.tar.gz",
                "Cache bundled OpenSSL source and static build",
                "openssl-${{ env.OPENSSL_VERSION }}.tar.gz",
                "Build the pinned private llhttp support",
                "Build the pinned bundled OpenSSL support",
                "run: make openssl",
                "Canary source-rock installation with system OpenSSL",
                "OPENSSL_MODE=system",
                "brew install cmake readline openssl@3 pkgconf",
                "test_ssl_http_fresh_process_sanitizer_composition$",
                "libssl-dev", "perl",
            }) do
                assert.truthy(workflow:find(contract, 1, true), contract)
            end
            for _, contract in ipairs({
                "gcc-14 clang-format python3-venv",
                'python3 -m venv "$RUNNER_TEMP/titan-compiler-coverage-tools"',
                'pip" install -r scripts/titan-coverage-requirements.txt',
                "clang-format --version",
                "TITAN_COVERAGE_TEST_CC: gcc-14",
                "TITAN_COVERAGE_TEST_GCOV: gcov-14",
                "TITAN_COVERAGE_TEST_GCOVR: ${{ runner.temp }}/titan-compiler-coverage-tools/bin/gcovr",
                'TITAN_COVERAGE_TEST_REQUIRED: "1"',
            }) do
                assert.equal(1, count_literal(compiler_job, contract), contract)
            end
            assert.equal(1, count_literal(native_coverage_job,
                'TITAN_COVERAGE_TEST_REQUIRED: "1"'), native_coverage_job)
            assert.equal(1, count_literal(native_coverage_job,
                "clang-format --version"), native_coverage_job)
            for _, ordinary_job in ipairs({ build_job, sanitizer_job, macos_job }) do
                assert.falsy(ordinary_job:find("clang-format", 1, true), ordinary_job)
            end
            assert.equal(1, count_literal(workflow,
                'MAKEFLAGS: "-j2"'), workflow)
            assert.equal(1, count_literal(workflow,
                'TITAN_JOBS: "2"'), workflow)
            assert.falsy(workflow:find("TITAN_SYSTEM_STATIC_LIBUV_ARCHIVE", 1, true))
            assert.truthy(workflow:find("OPENSSL_MODE: bundled", 1, true))
            assert.truthy(workflow:find(
                "--name='standalone-prefix source installation installs one " ..
                "matching Lua and Titan SDK before the standard images'",
                1, true), workflow)
            assert.truthy(workflow:find(
                "--name='standalone-prefix source installation loads direct " ..
                "libuv calls lazily for Titan and explicitly for Lua'",
                1, true), workflow)
            assert.truthy(workflow:find(
                'test ! -e "$PREFIX/share/titan/0.6/src/titan/test.titan"',
                1, true), workflow)
            assert.falsy(workflow:find(
                'test -f "$PREFIX/share/titan/0.6/src/titan/test.titan"',
                1, true), workflow)

            local groups = read_file("spec/support/ci_test_groups.sh")
            for _, retained in ipairs({
                "compiler_tests=()",
                "compiler_unit_tests=()",
                "compiler_isolated_coverage_tests=()",
                "run_isolated_compiler_coverage",
                '"$BUSTED" -c -o gtest -v --exclude-tags=stress ' ..
                    '"$test_file"',
                "compiler | compiler-shard-[1-4] | stdlib-compiler | stdlib-compiler-shard-[1-2])",
                "stdlib-compiler-shard-{1..2}",
                "compiler-uncovered | stdlib-compiler-uncovered)",
                "compiler-shard-{1..4}",
                "ci_compiler_test_groups.txt",
                "ci_stdlib_compiler_test_files.txt",
                'requested_domain=all',
                'requested_domain=stdlib',
            }) do
                assert.truthy(groups:find(retained, 1, true), retained)
            end
            for _, removed in ipairs({
                "compiler_core_tests", "compiler_heavy_tests",
                "library_serial_tests", "library_uv_fs_tests",
                "library_net_os_tests", "library_peg_string_tests",
                "run_library_group", "run_titan_stdlib_test_groups.sh",
                "compiler-core", "compiler-heavy", "library-serial",
                "library-uv-fs", "library-net-os", "library-peg-string",
                "libraries)", "Library ", "worker", "awk", "declare -A",
                "spec/*_boundary_spec.lua",
            }) do
                assert.falsy(groups:find(removed, 1, true), removed)
            end
            local uncovered_start = assert(groups:find(
                "compiler-uncovered | stdlib-compiler-uncovered)",
                1, true))
            local uncovered_finish = assert(groups:find(
                "\n        ;;", uncovered_start, true))
            local uncovered_group = groups:sub(
                uncovered_start, uncovered_finish - 1)
            assert.falsy(uncovered_group:find(" -c ", 1, true),
                uncovered_group)

            local local_parallel_compiler = read_file(
                "spec/support/run_parallel_compiler_tests.sh")
            for _, required in ipairs({
                "default_jobs=4",
                "default_jobs=3",
                "jobs=${TITAN_ROCK_TEST_JOBS:-$default_jobs}",
                "[[ ! $jobs =~ ^[1-9][0-9]*$ || ${#jobs} -gt 9 ]]",
                "tar --exclude='./.git'",
                "--exclude='./.lua'",
                -- Bash 3.2 rejects an empty "${array[@]}" under set -u.
                '${prefix_excludes[@]+"${prefix_excludes[@]}"}',
                'mkfifo "$completion_fifo"',
                'MAKEFLAGS=-j1',
                'TITAN_JOBS=1',
                "shard_job_policy='unset MAKEFLAGS MFLAGS MAKELEVEL TITAN_JOBS'",
                'CCACHE_TEMPDIR="$worker_root/tmp-$shard/ccache"',
                '-o gtest -v "\\$test_file"',
                'printf \'[compiler shard %s] %s\\n\'',
                "trap 'handle_signal 143' TERM",
                'kill -TERM -- "-$pid"',
                'kill -KILL -- "-$pid"',
                '"$temporary_base"/titan-rock-compiler-workers.*)',
            }) do
                assert.truthy(local_parallel_compiler:find(
                    required, 1, true), required)
            end
            for line in local_parallel_compiler:gmatch("[^\r\n]+") do
                local command = line:match("^%s*(.-)%s*$")
                if command:sub(1, 1) ~= "#" then
                    for _, unsupported in ipairs({
                        "wait -n", "declare -A", "mapfile", "readarray",
                    }) do
                        assert.falsy(command:find(
                            unsupported, 1, true), line)
                    end
                end
            end

            local parallel_compiler = read_file(
                "spec/support/ci_parallel_compiler_tests.sh")
            assert.equal(2, count_literal(parallel_compiler,
                "xargs -r -n1 -P2"), parallel_compiler)
            for _, required in ipairs({
                'shards=(1 2 3 4)',
                '1-2) shards=(1 2)',
                '3-4) shards=(3 4)',
                'group=compiler-shard-',
                'group=stdlib-compiler-shard-',
                'worker_jobs=1',
                'worker_jobs=2',
                'for shard in "${shards[@]}"',
                'mktemp -d "$runner_temp/titan-compiler-workers.XXXXXX"',
                'tar --exclude="./.lua" --exclude="./.git"',
                'cd "$worker" || exit 1',
                'rm -f luacov.stats.out luacov.report.out || exit 1',
                'mkdir -p .tmp || exit 1',
                'export TMPDIR="$PWD/.tmp"',
                'unset LUACOV_CONFIG',
                'MAKEFLAGS=-j$worker_jobs TITAN_JOBS=$worker_jobs',
                'env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS',
                '"$group$shard" "$phase"',
                'sed -u "s/^/[$label shard $shard] /"',
                'tee -a "$log"',
                'xargs -r -n1 -P1 bash -c "$run_shard_phase" _',
                'pipeline_status=("${PIPESTATUS[@]}")',
                "starting %s covered+stress shard",
                "finished %s covered+stress shard",
                "merge_luacov_stats.lua",
                "luacov.stats.out",
            }) do
                assert.truthy(parallel_compiler:find(required, 1, true),
                    required)
            end
            assert.falsy(parallel_compiler:find(
                "xargs -r -n1 -P4", 1, true), parallel_compiler)
            assert.falsy(parallel_compiler:find(
                    'cat "$worker_root/shard-$shard.log"', 1, true),
                parallel_compiler)

            local groups_helper = assert(loadfile(
                "spec/support/compiler_test_groups.lua"))()
            local inventory, inv_err = groups_helper.load()
            assert.truthy(inventory, inv_err)
            for _, meta_key in ipairs({ "schema", "host", "profile", "date", "compiler" }) do
                assert.truthy(inventory.metadata[meta_key], meta_key)
            end
            -- Each domain mirrors a separately maintained declaration: the
            -- Makefile's retained tests and the CI installed-provider list.
            -- Derive their membership instead of pinning inventory sizes that
            -- every added spec would have to re-pin here.
            local retained_declared = makefile_words("STDLIB_BUSTED_TESTS")
            table.sort(retained_declared)
            assert.same(sorted_paths(inventory.retained), retained_declared)
            -- Makefile.win repeats the retained list as its own per-target
            -- export for the native-first Busted phase; compare it with the
            -- declaration so the two cannot drift silently.
            local windows_retained = makefile_target_export_words("Makefile.win",
                "rock-test", "TITAN_ROCK_TEST_STDLIB_SPECS")
            table.sort(windows_retained)
            assert.same(retained_declared, windows_retained)
            assert.same(sorted_paths(inventory.stdlib),
                declared_spec_paths("spec/support/ci_stdlib_compiler_test_files.txt"))
            assert.equal(#inventory.items,
                #inventory.retained + #inventory.stdlib + #inventory.compiler)
            local assigned = {}
            for _, item in ipairs(inventory.items) do
                assert.falsy(assigned[item.path], item.path)
                assigned[item.path] = true
                assert.is_true(item.local_validation_seconds >= 0)
                assert.is_true(item.ci_covered_seconds >= 0)
            end
            assert.is_true(assigned["spec/coder/jobserver_spec.lua"])
            assert.is_true(assigned["spec/coder/split_units_spec.lua"])
            assert.equal("stdlib",
                inventory.by_path["spec/coder/split_units_spec.lua"].domain)
            assert.equal("compiler",
                inventory.by_path["spec/coder/unions_spec.lua"].domain)
            assert.equal("stdlib",
                inventory.by_path["spec/coder/unions_stdlib_spec.lua"].domain)
            local compiler_plan = assert(groups_helper.plan_ci(inventory))
            for _, shard in ipairs(compiler_plan) do
                for _, item in ipairs(shard.items) do
                    assert.not_equal("spec/coder/split_units_spec.lua", item.path)
                    assert.not_equal("spec/coder/unions_stdlib_spec.lua", item.path)
                end
            end
            -- The stdlib job's two workers split that domain exactly; the
            -- exclusive file runs alone after both LPT-balanced halves.
            local stdlib_plan = assert(groups_helper.plan_ci_stdlib(inventory))
            assert.equal(groups_helper.CI_STDLIB_WORKERS, #stdlib_plan)
            local stdlib_assigned, stdlib_count = {}, 0
            for _, worker in ipairs(stdlib_plan) do
                local ordinary = 0
                for _, item in ipairs(worker.items) do
                    assert.equal("stdlib", item.domain, item.path)
                    assert.falsy(stdlib_assigned[item.path], item.path)
                    stdlib_assigned[item.path] = true
                    stdlib_count = stdlib_count + 1
                    if not item.exclusive then ordinary = ordinary + 1 end
                end
                assert.is_true(ordinary > 0)
            end
            assert.equal(#inventory.stdlib, stdlib_count)
            assert.is_true(inventory.by_path[
                "spec/coder/build_coordination_spec.lua"].exclusive)
            -- The stress partition declares its own tagged specs; compare the
            -- inventory's stress domain against that declaration instead of
            -- pinning a size that every added stress spec would re-pin, as the
            -- retained and stdlib domains do.
            local stress_partition = read_file(
                "spec/support/ci_compiler_stress_files.txt")
            local stress_assigned = {}
            for line in stress_partition:gmatch("[^\n]+") do
                if line:sub(1, 1) ~= "#" then
                    assert.truthy(line:match("^spec/.+_spec[.]lua$"), line)
                    assert.falsy(stress_assigned[line], line)
                    assert.truthy(read_file(line):find(
                        "#stress", 1, true), line)
                    stress_assigned[line] = true
                end
            end
            local stress_items = {}
            for _, item in ipairs(inventory.items) do
                if item.stress then
                    stress_items[#stress_items + 1] = item
                end
            end
            assert.same(declared_spec_paths(
                "spec/support/ci_compiler_stress_files.txt"),
                sorted_paths(stress_items))

            assert.equal(1, count_literal(sanitizer_job,
                    "name: sanitizer (ubuntu-24.04, ASan+UBSan)"),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "runs-on: ubicloud-standard-4"), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'MAKEFLAGS: "-j4"'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'TITAN_JOBS: "4"'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "timeout-minutes: 75"), sanitizer_job)
            assert.falsy(sanitizer_job:find("id-token: write", 1, true),
                sanitizer_job)
            assert.falsy(sanitizer_job:find(
                "codecov/codecov-action", 1, true), sanitizer_job)
            assert.falsy(sanitizer_job:find(
                "actions/download-artifact", 1, true), sanitizer_job)
            assert.falsy(sanitizer_job:find("\n    needs:", 1, true),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                    'SANITIZER_FLAGS: "-O0 -fno-lto -g -fsanitize=address,undefined'),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'TITAN_EXTRA_CFLAGS: "-O0 -fno-lto -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'TITAN_EXTRA_LDFLAGS: "-O0 -fno-lto -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'LUA_MYCFLAGS: "-O1 -fno-lto -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            for _, contract in ipairs({
                'SANITIZER_NATIVE_CACHE_SCHEMA: "v4"',
                "CC: cc", "AR: ar", "RANLIB: ranlib",
                'SANITIZER_LUA_VERSION: "5.5.1"',
                'SANITIZER_LIBUV_VERSION: "1.53.0"',
                'SANITIZER_LIBUV_SHA256: "cb0d6dd2128d5a95bd242c6cc982a24f' ..
                'e608fa93da57b6b4ec763b0018c53e64"',
                'LIBUV_BUILD_PROFILE: "static-pic-debug-tests-off-' ..
                'asan-ubsan-v2"',
                'SANITIZER_LLHTTP_VERSION: "9.4.3"',
                'SANITIZER_LLHTTP_SHA256: "1eb813c7437b31a87496a1cd3ed79f007' ..
                '46720f5e7e29c79b42c02cb69f36c39"',
                'SANITIZER_OPENSSL_VERSION: "3.5.7"',
                'SANITIZER_OPENSSL_SHA256: "a8c0d28a529ca480f9f36cf5792e2cd2' ..
                '1984552a3c8e4aa11a24aa31aeac98e8"',
                "id: sanitizer-native-cache-key",
                'lua_revision="$(git rev-parse HEAD:lua-5.5.1)"',
                "sha256sum vendor/libuv/libuv-1.53.0-spawn-close.patch",
                "git ls-remote",
                "libbacktrace.git HEAD",
                'cc_target="$(cc -dumpmachine)"',
                'cc_version="$(cc -dumpfullversion -dumpversion)"',
                'system_packages="$(dpkg-query',
                "id: sanitizer-native-cache",
                "uses: ubicloud/cache/restore@v4",
                "path: |",
                "lua-${{ env.SANITIZER_LUA_VERSION }}",
                "libbacktrace",
                "libuv-v${{ env.SANITIZER_LIBUV_VERSION }}",
                "libuv-v${{ env.SANITIZER_LIBUV_VERSION }}.tar.gz",
                "llhttp-release-v${{ env.SANITIZER_LLHTTP_VERSION }}",
                "llhttp-release-v${{ env.SANITIZER_LLHTTP_VERSION }}.tar.gz",
                "sqlite-autoconf-${{ env.SANITIZER_SQLITE3_RELEASE }}",
                "sqlite-autoconf-${{ env.SANITIZER_SQLITE3_RELEASE }}.tar.gz",
                "test -f sqlite3-build/libtitan-sqlite3.a",
                "openssl-${{ env.SANITIZER_OPENSSL_VERSION }}",
                "openssl-${{ env.SANITIZER_OPENSSL_VERSION }}.tar.gz",
                "uses: ubicloud/cache/save@v4",
                "steps.sanitizer-native-cache.outputs.cache-primary-key",
                "steps.sanitizer-native-cache.outputs.cache-hit != 'true'",
                'test ! -e "$PREFIX/bin/luarocks"',
                -- The boundary check must tolerate a prefix where the Lua
                -- installation created no lib/titan tree at all.
                'if test -e "$PREFIX/lib/titan" || test -L "$PREFIX/lib/titan"; then',
                'find "$PREFIX/lib/titan" ! -type d -print -quit',
                'test -z "$titan_entries"',
                'test ! -e "$PREFIX/var/cache/titan-probes"',
            }) do
                assert.truthy(sanitizer_job:find(contract, 1, true), contract)
            end
            local sanitizer_native_restore_step = named_step(sanitizer_job,
                "Restore sanitizer native dependencies")
            local sanitizer_native_save_step = named_step(sanitizer_job,
                "Save sanitizer native dependencies")
            for _, forbidden in ipairs({
                "restore-keys:", "github.sha", "hashFiles(",
            }) do
                assert.falsy(sanitizer_native_restore_step:find(
                    forbidden, 1, true), sanitizer_native_restore_step)
            end
            local sanitizer_native_restore_paths = assert(
                sanitizer_native_restore_step:match(
                    "\n%s+path: |(.-)\n%s+key:"))
            local sanitizer_native_save_paths = assert(
                sanitizer_native_save_step:match(
                    "\n%s+path: |(.-)\n%s+key:"))
            assert.equal(sanitizer_native_restore_paths,
                sanitizer_native_save_paths)
            assert.truthy(sanitizer_native_restore_step:find(
                "titan%-sanitizer%-native%-%${{ env%." ..
                "SANITIZER_NATIVE_CACHE_SCHEMA }}%-%${{ runner%.os }}" ..
                "%-%${{ runner%.arch }}%-%${{ env%.TITAN_BUILD_PROFILE }}%-%${{ steps%." ..
                "sanitizer%-native%-cache%-key%.outputs%.digest }}"))
            for _, fingerprint in ipairs({
                "titan_abi=$TITAN_ABI_VERSION",
                "lua_revision=$lua_revision",
                "libuv_patch=$libuv_patch_sha256",
                "libuv_profile=$LIBUV_BUILD_PROFILE",
                "sqlite3=$SANITIZER_SQLITE3_VERSION:$SANITIZER_SQLITE3_SHA256",
                "sqlite3_cflags=$SQLITE3_BUILD_CFLAGS",
                "rock_cflags=${ROCK_CFLAGS:--O0 -fno-lto -fPIC}",
                "titan_cppflags=${TITAN_EXTRA_CPPFLAGS:-}",
                "titan_cflags=$TITAN_EXTRA_CFLAGS",
                "ld_version=$ld_version",
                "make_version=$make_version",
                "system_packages=$system_packages",
            }) do
                assert.truthy(sanitizer_job:find(fingerprint, 1, true),
                    fingerprint)
            end

            local sanitizer_install_index = assert(sanitizer_job:find(
                "- name: Install sanitizer build dependencies", 1, true))
            local sanitizer_identify_index = assert(sanitizer_job:find(
                "- name: Identify sanitizer native dependency cache",
                sanitizer_install_index, true))
            local sanitizer_restore_index = assert(sanitizer_job:find(
                "- name: Restore sanitizer native dependencies",
                sanitizer_identify_index, true))
            local sanitizer_native_build_index = assert(sanitizer_job:find(
                "- name: Build sanitizer-enabled native dependencies",
                sanitizer_restore_index, true))
            local sanitizer_native_validate_index = assert(sanitizer_job:find(
                "- name: Validate sanitizer native dependency boundary",
                sanitizer_native_build_index, true))
            local sanitizer_native_save_index = assert(sanitizer_job:find(
                "- name: Save sanitizer native dependencies",
                sanitizer_native_validate_index, true))
            local sanitizer_luarocks_index = assert(sanitizer_job:find(
                "- name: Install LuaRocks for the sanitizer Lua",
                sanitizer_native_save_index, true))
            assert.is_true(sanitizer_install_index < sanitizer_identify_index)
            assert.is_true(sanitizer_identify_index < sanitizer_restore_index)
            assert.is_true(sanitizer_restore_index <
                sanitizer_native_build_index)
            assert.is_true(sanitizer_native_build_index <
                sanitizer_native_validate_index)
            assert.is_true(sanitizer_native_validate_index <
                sanitizer_native_save_index)
            assert.is_true(sanitizer_native_save_index <
                sanitizer_luarocks_index)
            local sanitizer_native_build_step = named_step(sanitizer_job,
                "Build sanitizer-enabled native dependencies")
            assert.equal(1, count_literal(sanitizer_native_build_step,
                "make openssl lua libuv libbacktrace llhttp sqlite3"))
            assert.equal(0, count_literal(sanitizer_native_build_step,
                "grep -qx 'provider=system'"))
            for _, serial_capture in ipairs({
                "native-lua", "native-libbacktrace", "native-libuv",
                "native-llhttp", "native-sqlite3", "native-openssl",
            }) do
                assert.falsy(sanitizer_native_build_step:find(
                    serial_capture, 1, true), sanitizer_native_build_step)
            end

            assert.equal(2, count_literal(sanitizer_job,
                "make titan-stdlib-test-build"), sanitizer_job)
            assert.equal(43, count_literal(sanitizer_job,
                "make titan-stdlib-test-run"), sanitizer_job)
            for _, filter in ipairs({
                "TITAN_FILTER='test_lua_host_roots_coroutine_" ..
                "payloads_and_tags_across_gc$'",
                "TITAN_FILTER='test_timer_'",
                "TITAN_FILTER='test_lua_close_'",
                "TITAN_FILTER='test_unwind_'",
                "TITAN_FILTER='test_fs_'",
                "TITAN_FILTER='^uv%.task_tests%.'",
                "TITAN_FILTER='^uv%.runtime_tests%.'",
                "TITAN_FILTER='test_completion_'",
                "TITAN_FILTER='test_ready_queue_'",
                "TITAN_FILTER='wake_failure_'",
                "TITAN_FILTER='test_scalar_write_'",
                "TITAN_FILTER='test_concrete_'",
                "TITAN_FILTER='test_net_received_chunks_remain_immutable'",
                "TITAN_FILTER='test_net_overlapping_writes_'",
                "TITAN_FILTER='test_run_foreign_'",
                "TITAN_FILTER='test_receiver_'",
                "TITAN_FILTER='test_lua_independent_'",
                "TITAN_FILTER='test_signal_watcher_'",
                "TITAN_FILTER='test_ssl_http_fresh_process_sanitizer_composition$'",
                "TITAN_FILTER='test_ssl_simultaneous_large_duplex_preserves_bytes$'",
                "TITAN_FILTER='test_ssl_cancel_backpressured_write_aborts_before_native_drain$'",
                "TITAN_FILTER='^ssl[.]tests[.]test_ssl_drain_preserves_write_shutdown_failure$'",
                "TITAN_FILTER='test_upgrade_server_transfers_binary_excess_and_handler_lifetime$'",
                "TITAN_FILTER='test_upgrade_opening_cancellation_aborts_before_output_drain$'",
                "TITAN_FILTER='test_received_message_strings_survive_later_reads_and_forced_gc$'",
                "TITAN_FILTER='test_partial_utf8_message_cancellation_retires_ownership'",
                "TITAN_FILTER='test_admitted_idle_read_cancellation_terminalizes_ws_and_wss'",
                "TITAN_FILTER='test_close_interrupts_active_read_without_joining_its_caller$'",
                "TITAN_FILTER='test_shutdown_takes_receive_progress_after_reader_returns_data'",
                "TITAN_FILTER='test_stopped_socket_output_aborts_before_native_drain'",
                "TITAN_FILTER='^reflect%.tests%.'",
                "TITAN_FILTER='^sqlite3%.tests%.'",
                "TITAN_FILTER='^json%.tests%.test_mapping_" ..
                "allocated_constructor_arguments_survive_collection'",
                "TITAN_FILTER='^json%.tests%.test_parser_wide_fold_collections'",
                "TITAN_FILTER='^json%.tests%.test_parser_configured_nesting_boundary'",
                "TITAN_FILTER='^json%.tests%.test_parser_" ..
                "deep_mixed_containers_and_sibling_members'",
                "TITAN_FILTER='^json%.tests%.test_parser_" ..
                "peg_limit_is_independent_of_depth_option'",
                "TITAN_FILTER='^json%.tests%.test_core_float_range_tags_and_round_trips'",
                "TITAN_FILTER='^json%.tests%.test_mapping_.*native_numbers'",
                "TITAN_FILTER='test_peg_roots_and_releases_" ..
                "titan_callback_patterns$'",
                "TITAN_FILTER='test_regex_gc_rooting$'",
            }) do
                assert.equal(1, count_literal(sanitizer_job, filter), filter)
            end
            local nominal_sanitizer_step = named_step(sanitizer_job,
                "Run native nominal storage sanitizer gate")
            for _, required in ipairs({
                "ci_sanitizer_capture.sh nominal-storage",
                "spec/coder/nominal_storage_spec.lua",
                "spec/coder/native_optional_storage_spec.lua",
            }) do
                assert.equal(1, count_literal(nominal_sanitizer_step, required),
                    required)
            end
            local json_sanitizer_step = named_step(sanitizer_job,
                "Run native JSON sanitizer gate")
            for _, label in ipairs({
                "json-nesting", "json-nesting-mixed", "json-nesting-peg-limit",
            }) do
                assert.equal(1, count_literal(json_sanitizer_step,
                    "ci_sanitizer_capture.sh " .. label .. " "), label)
            end
            for _, ownership in ipairs({
                {
                    "Run native TLS/HTTP sanitizer gate", "TLS/HTTP",
                    {
                        "ssl-duplex", "ssl-backpressure", "ssl-drain-failure",
                        "http-upgrade-handoff", "http-upgrade-abort",
                    },
                },
                {
                    "Run native WebSocket ownership sanitizer gate", "WebSocket",
                    {
                        "websocket-message-gc", "websocket-partial-utf8",
                        "websocket-read-cancel", "websocket-active-close",
                        "websocket-receive-progress", "websocket-backpressure",
                    },
                },
            }) do
                local step = named_step(sanitizer_job, ownership[1])
                for _, label in ipairs(ownership[3]) do
                    assert.equal(1, count_literal(step,
                        "ci_sanitizer_capture.sh " .. label .. " "), label)
                    assert.equal(2, count_literal(step, label), label)
                end
                assert.truthy(step:find(
                    [[grep -Eq $'^\\[==========\\] [1-9][0-9]* tests? ran\\. \\([0-9]+\\.[0-9]{2} ms total\\)\r?$']],
                    1, true), step)
                assert.truthy(step:find(
                    '"$TITAN_SANITIZER_LOG_DIR/$ownership_log.log"',
                    1, true), step)
                assert.truthy(step:find(ownership[2] ..
                    " ownership sanitizer filter ran no tests:",
                    1, true), step)
                assert.truthy(step:find("exit 1", 1, true), step)
            end
            local teardown_step = named_step(sanitizer_job,
                "Run native teardown and unwinding sanitizer gate")
            for _, label in ipairs({ "lua-close-teardown", "coroutine-unwind" }) do
                assert.equal(1, count_literal(teardown_step,
                    "ci_sanitizer_capture.sh " .. label .. " "), label)
                assert.equal(2, count_literal(teardown_step, label), label)
            end
            for _, required in ipairs({
                [[grep -Eq $'^\\[==========\\] [1-9][0-9]* tests? ran\\. \\([0-9]+\\.[0-9]{2} ms total\\)\r?$']],
                '"$TITAN_SANITIZER_LOG_DIR/$teardown_log.log"',
                "Teardown sanitizer filter ran no tests:",
                "exit 1",
            }) do
                assert.truthy(teardown_step:find(required, 1, true), required)
            end
            local probe_step = named_step(sanitizer_job,
                "Check ASan fake-stack placement of setjmp frames")
            assert.equal(2, count_literal(probe_step,
                "bash spec/support/ci_sanitizer_capture.sh"), probe_step)
            for _, required in ipairs({
                'ci_sanitizer_capture.sh asan-fake-stack-probe-build \\\n' ..
                '            "$CC" $SANITIZER_FLAGS spec/support/asan_fake_stack_probe.c',
                'ci_sanitizer_capture.sh asan-fake-stack-probe \\\n' ..
                '            "$probe"',
            }) do
                assert.equal(1, count_literal(probe_step, required), required)
            end
            assert.truthy(read_file("spec/support/asan_fake_stack_probe.c"):find(
                "__asan_addr_is_in_fake_stack(fake_stack, &buffer", 1, true))
            assert.is_true(assert(sanitizer_job:find(
                    "- name: Check ASan fake-stack placement of setjmp frames", 1, true)) <
                assert(sanitizer_job:find(
                    "- name: Run native teardown and unwinding sanitizer gate", 1, true)))
            assert.truthy(sanitizer_job:find(
                "detect_stack_use_after_return=1", 1, true), sanitizer_job)
            for _, removed in ipairs({
                "spec/stdlib/uv_native_handles_spec.lua",
                "spec/stdlib/uv_tasks_spec.lua",
                "spec/stdlib/uv_bootstrap_spec.lua",
                "spec/coroutine_runtime_boundary_spec.lua",
                "spec/ssl_http_sanitizer_boundary_spec.lua",
            }) do
                assert.falsy(sanitizer_job:find(removed, 1, true),
                    sanitizer_job)
            end
            assert.truthy(sanitizer_job:find(
                "bash spec/support/ci_peg_string_sanitizer_smoke.sh",
                1, true), sanitizer_job)

            local asan_options = assert(sanitizer_job:match(
                '\n%s+ASAN_OPTIONS:%s+"([^"\n]+)"'))
            assert.truthy(asan_options:find(
                "stack_trace_format='    #%n %p %F %S (%m+%o) %b'",
                1, true), asan_options)
            assert.truthy(sanitizer_job:find(
                    "TITAN_SANITIZER_LOG_DIR=$RUNNER_TEMP/", 1, true),
                sanitizer_job)
            assert.truthy(sanitizer_job:find(
                    "TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT=$RUNNER_TEMP/", 1, true),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'cmp "$snapshot_provider" "$provider"'), sanitizer_job)
            local capture_script =
            "bash spec/support/ci_sanitizer_capture.sh"
            for _, contract in ipairs({
                {
                    "Build sanitizer-enabled native dependencies",
                    {
                        "make openssl lua libuv libbacktrace llhttp sqlite3",
                    },
                },
                {
                    "Install LuaRocks for the sanitizer Lua",
                    { "make luarocks", "build lpeglabel", "build luafilesystem" },
                },
                {
                    "Activate the sanitizer Titan prefix",
                    { '"$PREFIX/bin/luarocks" install' },
                },
                {
                    "Build sanitizer-enabled Titan artifacts",
                    { "luarocks make --force" },
                },
                {
                    "Build unified native stdlib sanitizer executable",
                    { "make titan-stdlib-test-build" },
                },
                {
                    "Certify identical SDK reinstall without sanitizer compilation or linking",
                    { "luarocks make --force", "make titan-stdlib-test-build" },
                },
                {
                    "Check native Runtime shutdown deadline",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run dense Array and value transfer sanitizer gate",
                    { ".lua/bin/busted", "make titan-stdlib-test-run" },
                },
                {
                    "Run immediate function compiler sanitizer gate",
                    { ".lua/bin/busted" },
                },
                {
                    "Run native nominal storage sanitizer gate",
                    { ".lua/bin/busted" },
                },
                {
                    "Run native coroutine sanitizer gate",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run native async sanitizer gate (timer-fs)",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run native async sanitizer gate (core-uv)",
                    { ".lua/bin/busted", "make titan-stdlib-test-run" },
                },
                {
                    "Run native SQLite sanitizer gate",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run native JSON sanitizer gate",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run native TLS/HTTP sanitizer gate",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run native WebSocket ownership sanitizer gate",
                    { "make titan-stdlib-test-run" },
                },
                {
                    "Run PEG/regex native sanitizer gate",
                    {
                        "make titan-stdlib-test-run",
                        "bash spec/support/ci_peg_string_" ..
                        "sanitizer_smoke.sh",
                    },
                },
                {
                    "Build sanitizer child-process smoke fixture",
                    { ".lua/bin/lua -e" },
                },
                {
                    "Run sanitized net/OS production smokes",
                    { ".lua/bin/lua spec/fixtures/libuv/" },
                },
            }) do
                local step = named_step(sanitizer_job, contract[1])
                local command_count = 0
                for _, command in ipairs(contract[2]) do
                    command_count = command_count +
                        count_literal(step, command)
                end
                assert.is_true(command_count > 0, step)
                assert.equal(command_count,
                    count_literal(step, capture_script), step)
            end
            local diagnostic_step_start = assert(sanitizer_job:find(
                "- name: Report generated C context for sanitizer failure",
                1, true))
            local diagnostic_step = sanitizer_job:sub(diagnostic_step_start)
            for _, contract in ipairs({
                "if: ${{ failure() && !cancelled() }}",
                "continue-on-error: true",
                '"$PREFIX/bin/lua" -E',
                "spec/support/ci_asan_generated_c_context.lua report",
                '"$TITAN_SANITIZER_LOG_DIR"',
                '"$TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT"',
            }) do
                assert.truthy(diagnostic_step:find(contract, 1, true),
                    contract)
            end
            assert.falsy(sanitizer_job:find(
                "TITAN_NO_LINE_DIRECTIVES", 1, true), sanitizer_job)
            assert.falsy(sanitizer_job:find(
                "--no-line-directives", 1, true), sanitizer_job)
        end)

    it("cleans only exact recorded object parts and reserved test outputs", function()
        if platform.windows then pending("Unix generated-artifact cleanup"); return end
        local objectmetadata = require "titan-compiler.objectmetadata"
        local types = require "titan-compiler.types"
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            assert.truthy(run_argv({ "mkdir", "-p", root .. "/spec/nested with spaces",
                root .. "/future/deep/suite.dSYM", root .. "/.titan-tests", root .. "/titan/folder" }))
            local removed = {}
            for _, fixture in ipairs({
                { "in_memory_fixture", 3 }, { "in_memory_unsplit", 1 },
                { "spec/nested with spaces/generated", 2 }, { "titan/folder/folder", 2 },
            }) do
                local stem, count = fixture[1], fixture[2]
                local module = types.Module("cleanup.fixture", {}, {})
                module._source = true
                module.source_members, module.source_type_members = {}, {}
                local native = { parts_version = 1, parts = {},
                    private_header = count > 1 and ".priv.h" or nil }
                for index = 0, count - 1 do
                    local suffix = index == 0 and "" or ".part" .. index
                    native.parts[#native.parts + 1] = {
                        index = index, c_suffix = suffix .. ".c", object_suffix = suffix .. ".o" }
                    for _, extension in ipairs({ ".c", ".o" }) do
                        local path = stem .. suffix .. extension
                        write_file(root .. "/" .. path, "generated\n")
                        removed[#removed + 1] = path
                    end
                end
                if count > 1 then
                    write_file(root .. "/" .. stem .. ".priv.h", "generated header\n")
                    removed[#removed + 1] = stem .. ".priv.h"
                end
                local payload = assert(objectmetadata.encode({
                    kind = "source", type = module, filename = "cleanup/fixture.titan",
                    source_files = { "cleanup/fixture.titan" }, deps = {},
                }, native))
                local source = root .. "/" .. stem .. ".metadata.c"
                write_file(source, assert(objectmetadata.render(payload, "cleanup_source_record")))
                local ok, output = run_argv(compiler_argv("-c", source, "-o", root .. "/" .. stem .. ".o"))
                assert.truthy(ok, output)
                os.remove(source)
                -- A similarly named but unrecorded part is not owned.
                write_file(root .. "/" .. stem .. ".part19.o", "authored part\n")
            end
            local preserved = {
                ["spec/native_fixture.c"] = "authored C\n",
                ["spec/native_fixture.o"] = "authored object\n",
                ["invalid.o"] = "not an object record\n",
                ["invalid.part1.c"] = "unowned part\n",
                ["spec/orphan.titan"] = "module orphan\n",
                ["spec/orphan.part1.c"] = "no committed primary\n",
                ["spec/orphan.priv.h"] = "/* Generated by Titan: module private declarations. */\n",
                ["spec/authored.ffi.h"] = "authored header\n",
                [".titan-tests/keep"] = "owned output\n",
            }
            for path, bytes in pairs(preserved) do write_file(root .. "/" .. path, bytes) end
            for path, bytes in pairs({
                ["future/deep/suite"] = "test executable\n",
                ["future/deep/suite__test_runner.c"] = "reserved runner\n",
                ["future/deep/suite.dSYM/marker"] = "symbols\n",
                ["spec/generated.ffi.h"] = "/* Generated by Titan: module C declaration environment. */\n",
            }) do
                write_file(root .. "/" .. path, bytes)
                removed[#removed + 1] = path
            end
            local script = lfs.currentdir() .. "/spec/support/clean_generated_test_artifacts.sh"
            local ok, output = run_argv({ "bash", "-c", 'cd "$1" && exec bash "$2" --keep-output',
                "cleanup-test", root, script })
            assert.truthy(ok, output)
            for _, path in ipairs(removed) do assert.falsy(file_exists(root .. "/" .. path), path) end
            for path, bytes in pairs(preserved) do assert.equal(bytes, read_file(root .. "/" .. path), path) end
            for _, stem in ipairs({ "in_memory_fixture", "in_memory_unsplit", "spec/nested with spaces/generated", "titan/folder/folder" }) do
                assert.equal("authored part\n", read_file(root .. "/" .. stem .. ".part19.o"))
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)


    it("partitions every spec file for any worker count N with LPT, isolates the exclusive files, and validates the union",
        function()
            local groups = assert(loadfile(
                "spec/support/compiler_test_groups.lua"))()
            local inventory, err = groups.load()
            assert.truthy(inventory, err)
            -- The classified union is exactly the discovered spec files.
            local discovered = {}
            for _, path in ipairs(source_inventory.lua_files("spec")) do
                if path:match("_spec%.lua$") then discovered[path] = true end
            end
            local classified = {}
            for _, item in ipairs(inventory.items) do
                assert.falsy(classified[item.path], item.path)
                classified[item.path] = true
            end
            assert.same(discovered, classified)
            local expected_exclusive = {}
            for path in pairs(groups.EXCLUSIVE_SPECS) do
                if classified[path] then
                    expected_exclusive[#expected_exclusive + 1] = path
                end
            end
            table.sort(expected_exclusive)
            assert.same({
                "spec/coder/build_coordination_spec.lua",
                "spec/coder/build_scheduler_spec.lua",
                "spec/coder/jobserver_spec.lua",
                "spec/coder/parallel_compilation_spec.lua",
            }, expected_exclusive)

            local previous
            for _, n in ipairs({ 1, 2, 3, 4, 5, 6, 8, 12 }) do
                local plan, plan_err = groups.plan_local(
                    inventory, n, "local_validation")
                assert.truthy(plan, plan_err)
                assert.equal(n, plan.requested_jobs)
                assert.equal(n, plan.effective_jobs)
                local exclusive_files = { table.unpack(plan.exclusive_files) }
                table.sort(exclusive_files)
                assert.same(expected_exclusive, exclusive_files)
                local seen = {}
                for _, path in ipairs(expected_exclusive) do seen[path] = true end
                local count = #expected_exclusive
                local loads = {}
                for _, worker in ipairs(plan.workers) do
                    assert.is_true(#worker.files > 0)
                    for _, file in ipairs(worker.files) do
                        assert.falsy(groups.EXCLUSIVE_SPECS[file], file)
                        assert.falsy(seen[file], file)
                        seen[file] = true
                        count = count + 1
                    end
                    loads[#loads + 1] = worker.load
                end
                assert.same(classified, seen)
                assert.equal(#inventory.items, count)
                -- LPT bound: no worker exceeds the lightest one by more than
                -- the largest single ordinary file.
                local largest = 0
                for _, item in ipairs(inventory.items) do
                    if not item.exclusive then
                        largest = math.max(largest, item.local_validation_seconds)
                    end
                end
                table.sort(loads)
                assert.is_true(loads[#loads] - loads[1] <= largest + 1e-9)
                -- Deterministic: the same inputs yield the same plan.
                local again = assert(groups.plan_local(inventory, n, "local_validation"))
                for index, worker in ipairs(plan.workers) do
                    assert.same(worker.files, again.workers[index].files)
                end
                previous = plan
            end
            assert.truthy(previous)

            -- Capping empty workers when requested N exceeds available ordinary work.
            local small_workers, small_eff = groups.partition_lpt({
                { path = "spec/a_spec.lua", local_validation_seconds = 5.0 },
                { path = "spec/b_spec.lua", local_validation_seconds = 2.0 },
            }, 6, "local_validation")
            assert.truthy(small_workers)
            assert.equal(2, small_eff)
            assert.equal(2, #small_workers)

            for _, invalid_n in ipairs({ 0, -1, 1.5, "0", "abc", "" }) do
                local bad = groups.plan_local(inventory, invalid_n)
                assert.is_nil(bad)
            end

            -- Reject old fixed shard IDs, duplicates, missing files, and domain overlap.
            local function check_rejects(overrides, expected_substring)
                local ok_inv, load_err = groups.load(overrides)
                assert.is_nil(ok_inv)
                assert.truthy(load_err:find(expected_substring, 1, true),
                    load_err)
            end
            check_rejects({
                discovered_files = { "spec/a_spec.lua" },
                retained_files = {},
                read_file = function(path)
                    if path == "p.txt" then return "1 spec/a_spec.lua 1.0\n" end
                    return ""
                end,
                partition_file = "p.txt",
                stdlib_file = "s.txt",
                stress_file = "st.txt",
            }, "invalid compiler partition row")
            check_rejects({
                discovered_files = { "spec/a_spec.lua" },
                retained_files = {},
                read_file = function(path)
                    if path == "p.txt" then
                        return "compiler spec/a_spec.lua 1.0\ncompiler spec/a_spec.lua 2.0\n"
                    end
                    return ""
                end,
                partition_file = "p.txt",
                stdlib_file = "s.txt",
                stress_file = "st.txt",
            }, "duplicate compiler partition entry")
            check_rejects({
                discovered_files = { "spec/a_spec.lua" },
                retained_files = {},
                read_file = function(path)
                    if path == "p.txt" then return "compiler spec/a_spec.lua 1.0 -\n" end
                    if path == "s.txt" then return "spec/a_spec.lua\n" end
                    return ""
                end,
                partition_file = "p.txt",
                stdlib_file = "s.txt",
                stress_file = "st.txt",
            }, "compiler spec appears in both partitions")
        end)

    it("drains all files and workers after an early spec failure and reports per-file summaries",
        function()
            if platform.windows then
                pending("Unix Make work-graph and shell keep-going fixture")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local workspace = root .. "/workspace"
                local support = workspace .. "/spec/support"
                local coder = workspace .. "/spec/coder"
                local state = root .. "/state"
                local tmp_base = root .. "/tmp"
                local ok, output = run_argv({
                    "mkdir", "-p", support, coder, state, tmp_base,
                })
                assert.truthy(ok, output)
                write_file(state .. "/active", "0\n")
                write_file(workspace .. "/Makefile",
                    "titan-stdlib-test-build:\n\t@printf 'native-built\\n' > " ..
                    quote(state .. "/native-built") .. "\n")
                for _, name in ipairs({
                    "run_rock_tests.sh",
                    "run_parallel_compiler_tests.sh",
                    "compiler_test_groups.lua",
                    "ci_test_groups.sh",
                }) do
                    write_file(support .. "/" .. name,
                        read_file("spec/support/" .. name))
                end
                ok, output = run_argv({
                    "chmod", "+x",
                    support .. "/run_rock_tests.sh",
                    support .. "/run_parallel_compiler_tests.sh",
                    support .. "/ci_test_groups.sh",
                })
                assert.truthy(ok, output)

                local function make_spec(rel_path, body)
                    write_file(workspace .. "/" .. rel_path, body)
                end
                local record_snippet = function(label, should_fail)
                    return string.format([=[
local state = %q
describe(%q, function()
    it("runs", function()
        local f = assert(io.open(state .. "/ran-" .. %q, "wb"))
        f:write("1\n")
        f:close()
        %s
    end)
end)
]=], state, label, label, should_fail and 'error("deliberate early failure")' or "assert.is_true(true)")
                end

                make_spec("spec/retained_fail_spec.lua",
                    record_snippet("retained_fail", true))
                make_spec("spec/retained_pass_spec.lua",
                    record_snippet("retained_pass", false))
                make_spec("spec/stdlib_one_spec.lua",
                    record_snippet("stdlib_one", false))
                make_spec("spec/compiler_a_spec.lua",
                    record_snippet("compiler_a", false))
                make_spec("spec/compiler_b_spec.lua",
                    record_snippet("compiler_b", false))
                make_spec("spec/compiler_c_spec.lua",
                    record_snippet("compiler_c", false))
                make_spec("spec/coder/parallel_compilation_spec.lua",
                    record_snippet("exclusive_parallel", false))

                write_file(support .. "/ci_stdlib_compiler_test_files.txt",
                    "spec/stdlib_one_spec.lua\n")
                write_file(support .. "/ci_compiler_stress_files.txt", "# none\n")
                write_file(support .. "/ci_compiler_test_groups.txt", table.concat({
                    "# Schema: titan-busted-timings-v2",
                    "# Host: fixture",
                    "# Profile: validation",
                    "# Date: 2026-10-24",
                    "# Compiler: gcc",
                    "retained spec/retained_fail_spec.lua 10.0 -",
                    "retained spec/retained_pass_spec.lua 8.0 -",
                    "stdlib spec/stdlib_one_spec.lua 7.0 -",
                    "compiler spec/compiler_a_spec.lua 6.0 6.0",
                    "compiler spec/compiler_b_spec.lua 5.0 5.0",
                    "compiler spec/compiler_c_spec.lua 4.0 4.0",
                    "compiler spec/coder/parallel_compilation_spec.lua 3.0 3.0",
                    "",
                }, "\n"))

                local prefix = installed_prefix.active()
                local why, code
                ok, output, why, code = run_argv({
                    "bash", "-c",
                    'cd "$1" && shift && exec "$@"',
                    "titan-keep-going-fixture", workspace,
                    "env",
                    "-u", "BUSTED_FILTER",
                    "-u", "TITAN_FILTER",
                    "-u", "TITAN_ROCK_TEST_FORWARDED",
                    "-u", "TITAN_ROCK_TEST_ARGC",
                    "PREFIX=" .. prefix,
                    "LUA=" .. prefix .. "/bin/lua",
                    "BUSTED=" .. prefix .. "/bin/busted",
                    "TMPDIR=" .. tmp_base,
                    "TITAN_ROCK_TEST_JOBS=5",
                    "TITAN_ROCK_TEST_BUILD_NATIVE=1",
                    "TITAN_ROCK_TEST_INTERNAL=1",
                    "TITAN_ROCK_TEST_STDLIB_SPECS=spec/retained_fail_spec.lua spec/retained_pass_spec.lua",
                    "bash", "spec/support/run_rock_tests.sh",
                })
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(1, code)
                for _, label in ipairs({
                    "retained_fail", "retained_pass", "stdlib_one",
                    "compiler_a", "compiler_b", "compiler_c",
                    "exclusive_parallel",
                }) do
                    assert.equal("1\n", read_file(state .. "/ran-" .. label), label)
                end
                assert.equal("native-built\n", read_file(state .. "/native-built"))
                assert.truthy(output:find(
                    "Per-file Busted summary: passed=6 failed=1 total=7", 1, true),
                    output)
                assert.truthy(output:find(
                    "FAILED spec file: spec/retained_fail_spec.lua", 1, true),
                    output)
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("accepts timed sanitizer summaries and rejects empty or malformed selections", function()
        if platform.windows then pending("Unix sanitizer grep guard"); return end
        local patterns = {}
        for pattern in read_file(".github/workflows/ci.yml"):gmatch("grep %-Eq (%$'[^']+')") do
            if pattern:find("==========", 1, true) then patterns[#patterns + 1] = pattern end
        end
        assert.equal(4, #patterns)
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            local path = root .. "/summary.log"
            for _, pattern in ipairs(patterns) do
                for _, example in ipairs({
                    { "[==========] 1 test ran. (0.00 ms total)", true },
                    { "[==========] 12 tests ran. (123.45 ms total)", true },
                    { "[==========] 1 test ran. (0.00 ms total)\r", true },
                    { "[==========] 12 tests ran. (123.45 ms total)\r", true },
                    { "[==========] 1 test ran. (1.00 ms total)\r\r", false },
                    { "[==========] 1 test ran. (1.0\r0 ms total)", false },
                    { "[==========] 1 test ran. (1.00 ms total)\t", false },
                    { "[==========] 1 test ran. (1.00 ms total)\v", false },
                    { "[==========] 1 test ran. (1.00 ms total)\f", false },
                    { "[==========] 0 tests ran. (0.00 ms total)", false },
                    { "[==========] 1 test ran.", false },
                    { "[==========] 1 test ran. (-1.00 ms total)", false },
                    { "[==========] 1 test ran. (1.0 ms total)", false },
                    { "[==========] 1 test ran. (1.000 ms total)", false },
                    { "[==========] 1 test ran. (nan ms total)", false },
                    { "[==========] 1 test ran. (1e2 ms total)", false },
                    { "[==========] 1 test ran. (1.00 ms)", false },
                    { "[==========] 1 test ran. (1.00 ms total) trailing", false },
                }) do
                    write_file(path, example[1] .. "\n")
                    local ok, output = run_argv({
                        "bash", "-c", "grep -Eq " .. pattern .. ' "$1"',
                        "sanitizer-summary", path,
                    })
                    assert.equal(example[2], ok, example[1] .. "\n" .. output)
                end
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end)

    it("runs parallel native stdlib owner groups, guards timing-sensitive owners, and audits the union",
        function()
            if platform.windows then
                pending("Unix parallel native stdlib runner")
                return
            end
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local state = root .. "/state"
                local tmp_base = root .. "/tmp"
                local ok, output = run_argv({ "mkdir", "-p", state, tmp_base })
                assert.truthy(ok, output)
                write_file(state .. "/active", "0\n")
                write_file(state .. "/max-ordinary", "0\n")
                write_file(state .. "/guarded-overlap", "0\n")
                write_file(state .. "/ordinary-done", "0\n")

                local fake_exe = root .. "/fake-stdlib-tests"
                write_file(fake_exe, string.format([=[#!/usr/bin/env bash
set -u
state=%q
acquire() { while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done; }
release() { rmdir "$state/lock"; }

owners=()
is_guarded=0
for arg in "$@"; do
    case "$arg" in
        --filter=^alpha\[.\]tests\[.\]test_) owners+=(alpha.tests) ;;
        --filter=^beta\[.\]tests\[.\]test_) owners+=(beta.tests) ;;
        --filter=^http\[.\]tests\[.\]test_) owners+=(http.tests); is_guarded=1 ;;
    esac
done

acquire
active=$(cat "$state/active")
active=$((active + 1))
printf '%%s\n' "$active" > "$state/active"
if (( is_guarded != 0 )); then
    if (( active > 1 )) || [[ $(cat "$state/ordinary-done") != 2 ]]; then
        printf '1\n' > "$state/guarded-overlap"
    fi
else
    max_ord=$(cat "$state/max-ordinary")
    if (( active > max_ord )); then printf '%%s\n' "$active" > "$state/max-ordinary"; fi
fi
release

sleep 0.1

printf '[==========] Running Titan tests.\n'
count=0
for owner in "${owners[@]}"; do
    printf '[ RUN      ] %%s.test_case\n' "$owner"
    if [[ ${FAKE_FAIL_OWNER:-} == "$owner" ]]; then
        printf '[  FAILED  ] %%s.test_case (1.00 ms)\n[----------] %%s (1.00 ms total)\n' "$owner" "$owner"
        acquire
        active=$(cat "$state/active")
        printf '%%s\n' "$((active - 1))" > "$state/active"
        if (( is_guarded == 0 )); then
            done_count=$(cat "$state/ordinary-done")
            printf '%%s\n' "$((done_count + 1))" > "$state/ordinary-done"
        fi
        release
        printf '[==========] %%s tests ran. (%%s.00 ms total)\n[  PASSED  ] %%s tests.\n[  FAILED  ] 1 test.\n[  FAILED  ] %%s.test_case\n' "$((count + 1))" "$((count + 1))" "$count" "$owner"
        exit 1
    fi
    printf '[       OK ] %%s.test_case (1.00 ms)\n[----------] %%s (1.00 ms total)\n' "$owner" "$owner"
    count=$((count + 1))
done
printf '[==========] %%s tests ran. (%%s.00 ms total)\n' "$count" "$count"
printf '[  PASSED  ] %%s tests.\n' "$count"

acquire
active=$(cat "$state/active")
printf '%%s\n' "$((active - 1))" > "$state/active"
if (( is_guarded == 0 )); then
    done_count=$(cat "$state/ordinary-done")
    printf '%%s\n' "$((done_count + 1))" > "$state/ordinary-done"
fi
release
# A complete passing report does not prove a successful process.
for owner in "${owners[@]}"; do
    if [[ ${FAKE_EXIT_AFTER_REPORT_OWNER:-} == "$owner" ]]; then exit 7; fi
    if [[ ${FAKE_HANG_AFTER_REPORT_OWNER:-} == "$owner" ]]; then sleep 60; fi
done
]=], state))
                ok, output = run_argv({ "chmod", "+x", fake_exe })
                assert.truthy(ok, output)

                local prefix = installed_prefix.active()
                local log = root .. "/stdout.log"
                local roots_file = root .. "/roots.txt"
                local function run_groups(extra)
                    write_file(state .. "/active", "0\n")
                    write_file(state .. "/ordinary-done", "0\n")
                    write_file(state .. "/guarded-overlap", "0\n")
                    local argv = {
                        "env",
                        "TMPDIR=" .. tmp_base,
                        "TEST_LUA=" .. prefix .. "/bin/lua",
                        "TITAN_TEST_EXECUTABLE=" .. fake_exe,
                        "TITAN_TEST_JOBS=2",
                        "TITAN_TEST_RUN_LOG=" .. log,
                        "TITAN_TEST_RUN_ROOTS=" .. roots_file,
                        "TITAN_STDLIB_TEST_ROOTS=alpha.tests beta.tests http.tests",
                    }
                    for _, assignment in ipairs(extra or {}) do
                        argv[#argv + 1] = assignment
                    end
                    argv[#argv + 1] = "bash"
                    argv[#argv + 1] = "spec/support/run_parallel_stdlib_tests.sh"
                    local ran_ok, ran_output, why, code = run_argv(argv)
                    assert.equal("0\n", read_file(state .. "/guarded-overlap"), ran_output)
                    return ran_ok, ran_output, why, code
                end
                local passing_gate =
                    "Native stdlib gate: selected=3 passed=3 skipped=0 failed=0 owners=3/3 groups=3."
                ok, output = run_groups()
                assert.truthy(ok, output)
                assert.truthy(output:find(passing_gate, 1, true), output)

                -- Keep-going across native groups when an ordinary group fails:
                local fail_ok, fail_out = run_groups({ "FAKE_FAIL_OWNER=alpha.tests" })
                assert.falsy(fail_ok, fail_out)
                assert.truthy(fail_out:find("beta.tests.test_case", 1, true), fail_out)
                assert.truthy(fail_out:find("http.tests.test_case", 1, true), fail_out)

                -- The supervised process status decides a group even after a
                -- complete passing report: a nonzero exit or a timeout fails
                -- the run while the other ordinary group and the guarded
                -- phase still execute and the union audit still passes.
                for _, case in ipairs({
                    { { "FAKE_EXIT_AFTER_REPORT_OWNER=alpha.tests" }, "7" },
                    { { "FAKE_HANG_AFTER_REPORT_OWNER=alpha.tests", "TITAN_TEST_TIMEOUT=3" },
                        "124" },
                }) do
                    local case_ok, case_out, why, code = run_groups(case[1])
                    assert.falsy(case_ok, case_out)
                    assert.equal("exit", why, case_out)
                    assert.equal(1, code, case_out)
                    assert.truthy(case_out:find("alpha.tests.test_case", 1, true), case_out)
                    assert.truthy(case_out:find("beta.tests.test_case", 1, true), case_out)
                    assert.truthy(case_out:find("http.tests.test_case", 1, true), case_out)
                    assert.truthy(case_out:find(passing_gate, 1, true), case_out)
                    assert.truthy(case_out:match("native stdlib group %d+ failed: " ..
                        case[2] .. "\n"), case_out)
                end
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    -- GNU Make's version as major * 100 + minor (3.81 is 381), or nil.
    local function gnu_make_version(program)
        local ok, output = run_argv({ program, "--version" })
        local major, minor = output:match("^GNU Make (%d+)%.(%d+)")
        if not (ok and major) then return nil end
        return tonumber(major) * 100 + tonumber(minor)
    end

    -- GNU Make before 4.2 never shows -jN in MAKEFLAGS. macOS ships 3.81 as
    -- /usr/bin/make; TITAN_TEST_LEGACY_MAKE may name another such binary.
    local function legacy_gnu_make()
        local configured = os.getenv("TITAN_TEST_LEGACY_MAKE")
        if configured and configured ~= "" then
            local version = gnu_make_version(configured)
            assert(version and version < 402,
                "TITAN_TEST_LEGACY_MAKE is not GNU Make before 4.2: " .. configured)
            return configured
        end
        local version = gnu_make_version("/usr/bin/make")
        if version and version < 402 then return "/usr/bin/make" end
        return nil
    end

    -- Whether rock-test's Busted command passes TITAN_JOBS to the runner.
    local function busted_command_passes_jobs(make_program, environment, root)
        local probe = root .. "/busted-command.mk"
        write_file(probe, "print-busted-command:\n\t@printf '%s\\n' " ..
            "'$(subst ','\"'\"',$(ROCK_TEST_BUSTED))'\n")
        local argv = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
            "-u", "TITAN_JOBS" }
        for _, word in ipairs(environment) do argv[#argv + 1] = word end
        for _, word in ipairs({
            make_program, "--no-print-directory", "-s", "-f", "Makefile",
            "-f", probe, "TEST_LUA=false", "print-busted-command",
        }) do
            argv[#argv + 1] = word
        end
        local ok, output = run_argv(argv)
        assert.truthy(ok, output)
        return output:find(" TITAN_JOBS=", 1, true) ~= nil, output
    end

    -- One compiler owns graph parallelism. Make supplies the inherited pool,
    -- while this fixture records only the recipe's cap and descriptor lifetime.
    local function with_stdlib_pool_fixture(make_program, body)
        local root = make_temp_dir()
        local tested, failure = xpcall(function()
            write_file(root .. "/prepared", "native dependencies\n")
            write_file(root .. "/titanc", [==[#!/usr/bin/env bash
set -eu
jobs=
for word in "$@"; do case $word in -j*) jobs=$word ;; esac; done
test -n "$jobs"
auth=
for word in ${MAKEFLAGS:-}; do
    case $word in --) break ;; --jobserver-auth=*|--jobserver-fds=*) auth=${word#*=} ;; esac
done
pool=none
if [[ -n $auth ]]; then
    pool=unusable
    case $auth in
        fifo:*) [[ -p ${auth#fifo:} ]] && pool=usable ;;
        *,*) { true <&"${auth%%,*}" && true >&"${auth#*,}"; } 2>/dev/null && pool=usable ;;
    esac
fi
printf '%s %s %s\n' "$jobs" "$pool" "${TITAN_C_PARTS:-default}" >> "$TITAN_FIXTURE_LOG"
]==])
            assert.truthy(run_argv({ "chmod", "+x", root .. "/titanc" }))
            local function build(environment, flags)
                write_file(root .. "/calls", "")
                local argv = { "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "GNUMAKEFLAGS",
                    "-u", "MAKELEVEL", "-u", "MAKEOVERRIDES", "-u", "TITAN_JOBS",
                    "-u", "TITAN_C_PARTS", "TITAN_FIXTURE_LOG=" .. root .. "/calls" }
                for _, word in ipairs(environment or {}) do argv[#argv + 1] = word end
                argv[#argv + 1] = make_program
                for _, word in ipairs(flags or {}) do argv[#argv + 1] = word end
                for _, word in ipairs({ "--no-print-directory", "-s", "-f", "Makefile",
                    "PREFIX=" .. root, "TEST_LUA=false", "STDLIB_TITANC=" .. root .. "/titanc",
                    "STDLIB_USE_INSTALLED_RUNTIME=0", "STDLIB_NATIVE_PREREQS=" .. root .. "/prepared",
                    "STDLIB_TOOL_PREREQS=", "STDLIB_PLATFORM_PREREQS=",
                    "STDLIB_RUNTIME_ARCHIVE_PREREQ=", "STDLIB_BOOTSTRAP_PREREQ=", "stdlib-objects" }) do
                    argv[#argv + 1] = word
                end
                local ok, output = run_argv(argv)
                assert.truthy(ok, output)
                return read_file(root .. "/calls")
            end
            body(root, build)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(failure, 0) end
    end

    it("passes the local cap and inherited Make pool to one compiler without graph recursion", function()
        if platform.windows then pending("Unix GNU Make recipe policy"); return end
        local version = gnu_make_version("make")
        if not version or version < 402 then pending("GNU Make 4.2+ unavailable"); return end
        with_stdlib_pool_fixture("make", function(root, build)
            assert.equal("-j4 none default\n", build())
            assert.equal("-j2 none default\n", build({ "TITAN_JOBS=2" }))
            assert.equal("-j4 none default\n", build({}, { "-j1" }))
            assert.equal("-j8 usable default\n", build({ "TITAN_JOBS=8" }, { "-j3" }))
            -- C-part policy is a compiler input, never a Make invalidation stamp.
            assert.equal("-j4 none 8\n", build({ "TITAN_C_PARTS=8" }))
            assert.equal("-j4 none 8\n", build({ "TITAN_C_PARTS=8" }))
            local passes, command = busted_command_passes_jobs("make", {}, root)
            assert.is_true(passes, command)
        end)
    end)

    it("keeps old Make serial defaults while preserving explicit local caps", function()
        if platform.windows then pending("Unix GNU Make recipe policy"); return end
        local legacy = legacy_gnu_make()
        if not legacy then pending("GNU Make before 4.2 unavailable"); return end
        with_stdlib_pool_fixture(legacy, function(root, build)
            assert.equal("-j1 none default\n", build())
            assert.equal("-j1 none default\n", build({}, { "-j1" }))
            assert.equal("-j4 none default\n", build({ "TITAN_JOBS=4" }))
            assert.equal("-j8 usable default\n", build({ "TITAN_JOBS=8" }, { "-j3" }))
            for _, case in ipairs({ { {}, false }, { { "TITAN_JOBS=4" }, true } }) do
                local passes, command = busted_command_passes_jobs(legacy, case[1], root)
                assert.equal(case[2], passes, command)
            end
        end)
    end)

    it("keeps Make recipes portable to GNU Make 3.81 and guards every titanc launch",
        function()
            local makefile = read_file("Makefile")
            -- Constructs introduced after GNU Make 3.81 (macOS /usr/bin/make).
            for _, forbidden in ipairs({
                "%$%(file ", "%$%(let ", "%$%(intcmp ", "%$%(guile ",
                "\n[%w_]+%s*!=", "\n[%w_]+%s*::=", "\n%.ONESHELL", "\n%.WAIT",
                "\nundefine ", "\n%.RECIPEPREFIX", "\n%.EXTRA_PREREQS",
                "\n%.NOTINTERMEDIATE", "\nprivate ", "&:", "\ndefine [%w_]+%s*=",
                "%-%-jobserver%-style",
            }) do
                assert.falsy(makefile:find(forbidden), forbidden)
            end
            -- Every recipe line that launches titanc directly or through a
            -- variable is a `+` line whose first command is the
            -- dry-run/query/touch guard, so those modes do no other work.
            local logical = makefile:gsub("\\\n", " ")
            local launches = 0
            for line in logical:gmatch("[^\n]+") do
                if line:match("^\t") and (line:find("%$%$?%(STDLIB_TITANC%)%s+%-") or
                        line:find("%$%$?%(TEST_TITANC%)%s+%-")) then
                    launches = launches + 1
                    assert.truthy(line:match(
                        "^\t[@-]*%+[@-]*%$%$?%(RECURSIVE_WRAPPER_GUARD%) "), line)
                    assert.truthy(line:find("-j$$(TITAN_JOBS)", 1, true) or
                        line:find("-j$(TITAN_JOBS)", 1, true), line)
                end
            end
            assert.is_true(launches >= 5)

            if platform.windows then return end
            -- The guard recognizes GNU Make 4 and 3.81 MAKEFLAGS spellings.
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local probe = root .. "/probe.mk"
                write_file(probe, table.concat({
                    "print-snippets:",
                    "\t@printf '%s\\n' '$(subst ','\"'\"',$(RECURSIVE_WRAPPER_GUARD))' > " ..
                        quote(root .. "/guard.sh"),
                    "",
                }, "\n"))
                local ok, output = run_argv({
                    "env", "-u", "MAKEFLAGS", "-u", "MAKELEVEL", "-u", "TITAN_JOBS",
                    "make", "--no-print-directory", "-s", "-f", "Makefile", "-f", probe,
                    "TEST_LUA=false", "TITAN_JOBS=4", "print-snippets",
                })
                assert.truthy(ok, output)
                local guard = read_file(root .. "/guard.sh"):gsub("\n$", "")
                local function run_snippet(snippet, makeflags, tail)
                    local ran_ok, ran_output, why, code = run_argv({
                        "env", "MAKEFLAGS=" .. makeflags, "sh", "-c", snippet .. " " .. tail,
                    })
                    return ran_ok, ran_output, why, code
                end
                for _, case in ipairs({
                    { "", "run" },
                    { "kn --no-print-directory", 0 },
                    { " --no-print-directory -nk", 0 },
                    { " --no-print-directory -q", 1 },
                    { "t", 0 },
                    { "PREFIX=/tmp/titan-input", "run" },
                    { " -Onone --no-print-directory", "run" },
                    { " -I/tmp/include --no-print-directory", "run" },
                    { "s -j4 --jobserver-auth=fifo:/tmp/GMfifo1 -- MODE=nqt", "run" },
                }) do
                    local ran_ok, ran_output, why, code =
                        run_snippet(guard, case[1], "echo ran")
                    if case[2] == "run" then
                        assert.truthy(ran_ok, case[1] .. ": " .. ran_output)
                        assert.equal("ran\n", ran_output, case[1])
                    else
                        assert.equal("exit", why, case[1])
                        assert.equal(case[2], code, case[1])
                        assert.equal("", ran_output, case[1])
                    end
                end

                -- The coverage build's guard precedes its `cd`: dry-run,
                -- query, and touch modes need no coverage directory and
                -- launch nothing, while a real build still compiles there.
                local launches_file = root .. "/coverage-launches"
                local recorder = root .. "/coverage-titanc"
                write_file(recorder, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" >> " ..
                    quote(launches_file) .. "\n")
                assert.truthy(run_argv({ "chmod", "+x", recorder }))
                local coverage_dir = root .. "/absent/coverage"
                local sdk = root .. "/sdk"
                assert.truthy(run_argv({ "mkdir", "-p", sdk .. "/lib/titan/0.6" }))
                write_file(sdk .. "/lib/titan/0.6/titan.so", "installed provider\n")
                local function coverage_build(mode)
                    local argv = {
                        "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKELEVEL",
                        "make", "--no-print-directory",
                    }
                    if mode then argv[#argv + 1] = mode end
                    for _, word in ipairs({
                        "STDLIB_NATIVE_PREREQS=", "TITAN_TEST_FIXTURE_OUTPUTS=",
                        "TEST_LUA=false", "TEST_TITANC=" .. recorder,
                        "TITAN_TEST_INSTALL_ROOT=" .. sdk, "TITAN_TEST_BUILD_DIR=" .. root .. "/tests",
                        "TITAN_COVERAGE_BUILD_DIR=" .. coverage_dir,
                        "titan-native-coverage-build",
                    }) do
                        argv[#argv + 1] = word
                    end
                    return run_argv(argv)
                end
                for _, mode in ipairs({ "-n", "-t", "-q" }) do
                    local ran_ok, ran_output = coverage_build(mode)
                    assert.equal(mode ~= "-q", ran_ok, mode .. ": " .. ran_output)
                    assert.is_nil(lfs.attributes(coverage_dir), mode)
                    assert.is_nil(lfs.attributes(launches_file), mode)
                end
                assert.is_nil(lfs.attributes("titan-native-coverage-build"))
                local built_ok, built_output = coverage_build(nil)
                assert.truthy(built_ok, built_output)
                assert.equal(coverage_dir .. "\n", read_file(launches_file))
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)
end)

describe("Windows libbacktrace allocator receipts", function()
    local function run_controls(mode, expected)
        if platform.windows then
            pending("Unix mock-tool controls; native CLANG64 source/build and allocator harness own Windows validation")
            return
        end
        local ok, output = run_argv({
            "perl", "spec/support/check_windows_libbacktrace_allocator.pl",
            lfs.currentdir(), mode,
        })
        assert.truthy(ok, output)
        assert.truthy(output:find(expected, 1, true), output)
    end

    it("upgrades completed sources and verifies immutable preparation receipts", function()
        run_controls("prepare", "Windows allocator source preparation controls passed.")
    end)

    it("fences cached allocator objects and publishes only successful verified builds", function()
        run_controls("build", "Windows allocator archive-build controls passed.")
    end)

    it("forces verified alloc.c through native O0 and O2 controls without replacing the host mmap archive", function()
        run_controls("native", "Forced alloc.c native controls passed without replacing the host mmap archive.")
    end)
end)

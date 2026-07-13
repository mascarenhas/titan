local lfs = require "lfs"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function run_command(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok = pipe:close()
    return ok == true or ok == 0, output
end

local function shell_command_words(command)
    local words, err = cdriver.split_shell_words(command)
    assert.is_table(words, err)
    assert.is_true(#words > 0, "compiler command must not be empty")
    for i, word in ipairs(words) do
        words[i] = shell_quote(word)
    end
    return table.concat(words, " ")
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function bundled_libuv_config()
    local makefile = read_file("Makefile")
    local version = assert(makefile:match(
        "LIBUV_VERSION%s*:=%s*([%w%.%-]+)"))
    local source_dir = "libuv-v" .. version
    local build_dir = assert(makefile:match(
        "LIBUV_BUILD_DIR%s*:=%s*([%w%._/%-]+)"))
    local archive = assert(makefile:match(
        "LIBUV_BUNDLED_LIB%s*:=%s*([^\r\n]+)")):match("^%s*(.-)%s*$")
    archive = archive:gsub("%$%(LIBUV_BUILD_DIR%)", build_dir)
    assert.truthy(lfs.attributes(source_dir .. "/include/uv.h"),
        "bundled libuv headers are missing; run 'make libuv'")
    assert.truthy(lfs.attributes(archive),
        "bundled libuv archive is missing; run 'make libuv'")

    local uname_ok, host_os = run_command("uname -s")
    assert.truthy(uname_ok, host_os)
    host_os = assert(host_os:match("([^\r\n]+)"))
    local cppflags = shell_quote("-I" .. source_dir .. "/include")
    local ldflags = "-lpthread"
    if host_os == "Linux" then
        cppflags = cppflags .. " -D_GNU_SOURCE"
        ldflags = ldflags .. " -ldl -lrt"
    end
    return {
        CPPFLAGS = cppflags,
        CPPFLAGS_ARGV = host_os == "Linux"
            and { "-I" .. source_dir .. "/include", "-D_GNU_SOURCE" }
            or { "-I" .. source_dir .. "/include" },
        CFLAGS = "-fno-strict-aliasing",
        EXTRA_OBJECTS = shell_quote(archive),
        LDFLAGS = ldflags,
        HOST_OS = host_os,
    }
end

describe("native libuv shim", function()
    local executable
    local shared_object

    setup(function()
        executable = os.tmpname() .. "-titan-uv-shim"
        shared_object = os.tmpname() .. "-titan-uv-pic.so"
    end)

    teardown(function()
        if executable and lfs.attributes(executable) then
            os.remove(executable)
        end
        if shared_object and lfs.attributes(shared_object) then
            os.remove(shared_object)
        end
    end)

    it("uses only public libuv accessors and direct native dispatch", function()
        local source = read_file("titan-runtime/titan_uv.c")
        assert.not_match("lua_pcall", source, 1, true)
        assert.not_match("luaD_call", source, 1, true)
        assert.not_match("%-%>data", source)
        assert.not_match("timer%-%>", source)
        assert.not_match("handle%-%>", source)
        assert.not_match("req%-%>", source)
        assert.not_match("pipe%-%>", source)
        assert.not_match("process%-%>", source)
        assert.not_match("strlen", source, 1, true)
        assert.not_match("memmem", source, 1, true)
        assert.match("uv_handle_set_data", source, 1, true)
        assert.match("uv_handle_get_data", source, 1, true)
        assert.match("uv_req_set_data", source, 1, true)
        assert.match("uv_req_get_data", source, 1, true)
        assert.match("uv_close", source, 1, true)
        assert.match("uv_is_closing", source, 1, true)
        assert.match("uv_fs_get_result", source, 1, true)
        assert.match("UV_ENOSYS", source, 1, true)
        assert.match("uv_buf_init", source, 1, true)
        assert.match("titan_uvshim_bytes_find", source, 1, true)
        assert.match("titan_uvshim_bytes_slice_copy", source, 1, true)
        assert.match("uv_getaddrinfo", source, 1, true)
        assert.match("uv_freeaddrinfo", source, 1, true)
        assert.match("uv_tcp_init", source, 1, true)
        assert.match("uv_tcp_bind", source, 1, true)
        assert.match("uv_tcp_close_reset", source, 1, true)
        assert.match("uv_tcp_getsockname", source, 1, true)
        assert.match("uv_listen", source, 1, true)
        assert.match("uv_accept", source, 1, true)
        assert.match("uv_read_start", source, 1, true)
        assert.match("uv_read_stop", source, 1, true)
        assert.match("uv_tcp_connect", source, 1, true)
        assert.match("uv_write", source, 1, true)
        assert.match("uv_shutdown", source, 1, true)
        assert.match("uv_signal_init", source, 1, true)
        assert.match("uv_signal_start_oneshot", source, 1, true)
        assert.match("uv_signal_stop", source, 1, true)
        assert.match("TITAN_UV_EVENT_SIGNAL", source, 1, true)
        assert.match("uv_pipe%s*%(", source)
        assert.match("uv_pipe_init", source, 1, true)
        assert.match("uv_pipe_open", source, 1, true)
        assert.match("return UV_EBUSY", source, 1, true)
        assert.match("uv_spawn", source, 1, true)
        assert.match("UV_INHERIT_FD", source, 1, true)
        assert.not_match("UV_CREATE_PIPE", source, 1, true)
        assert.match("uv_process_kill", source, 1, true)
        assert.match("uv_process_get_pid", source, 1, true)
        assert.match("TITAN_UV_EVENT_PROCESS_EXIT", source, 1, true)
        local native_probe = read_file("spec/fixtures/uv/shim_probe.c")
        assert.match("uv_fs_close", native_probe, 1, true)
        assert.match("uv_fs_req_cleanup", native_probe, 1, true)
        assert.match("titan_uvshim_size_as_int64", source, 1, true)
        assert.match("titan_uvshim_status_is_enobufs", source, 1, true)
        assert.match("titan_uvshim_status_is_enoent", source, 1, true)
        assert.not_match("fork%s*%(", source)
        assert.not_match("waitpid%s*%(", source)
        assert.not_match("[^%w_]wait%s*%(", source)
        assert.not_match("[^%w_]pipe%s*%(", source)
        assert.not_match("[^%w_]kill%s*%(", source)
        assert.not_match("[^%w_]close%s*%(", source)
        assert.not_match("[^%w_]dup2?%s*%(", source)
        assert.not_match("[^%w_]open%s*%(", source)
        for _, name in ipairs({
            "getenv", "setenv", "unsetenv", "getcwd", "chdir",
            "gethostname", "readlink", "realpath",
        }) do
            assert.not_match("[^%w_]" .. name .. "%s*%(", source)
        end
        local private_header = read_file("titan-runtime/titan/uv.h")
        local titan_source = read_file("titan/uv.titan")
        assert.match("#include <signal.h>", source, 1, true)
        assert.not_match("signal.h", private_header, 1, true)
        assert.not_match("signal.h", titan_source, 1, true)
        assert.falsy(private_header:match("[^%w_]SIG[A-Z0-9_]+"))
        assert.falsy(titan_source:match("[^%w_]SIG[A-Z0-9_]+"))
        assert.match("sizeof%(titan_uvshim_address%)", source)
        assert.match("sizeof%(struct sockaddr_storage%)", source)
        assert.match("dispatch%(L, M, NULL, owner, event_kind, result, size, pointer%)",
            source)
    end)

    it("preserves libuv types across the public and private Titan FFI imports", function()
        local config = bundled_libuv_config()
        checker.configure_foreign_c({
            compiler = os.getenv("CC") or "cc",
            language_mode = "c99",
            cppflags = config.CPPFLAGS_ARGV,
            compiler_include_dirs = {
                "titan-runtime",
                "lua-5.5.0/src",
            },
        })

        local ok, result = pcall(function()
            types.registry = {}
            driver.imported = {}
            local source = [[
                local uv = foreign import "uv.h"
                local lua = foreign import "lua.h"
                local ffi = foreign import "titan/ffi.h"
                local shim = foreign import "titan/uv.h"

                local function layout(timer: *uv.uv_timer_t,
                                      req: *uv.uv_fs_t,
                                      dns: *uv.uv_getaddrinfo_t,
                                      tcp: *uv.uv_tcp_t,
                                      signal: *uv.uv_signal_t,
                                      pipe: *uv.uv_pipe_t,
                                      process: *uv.uv_process_t,
                                      connect: *uv.uv_connect_t,
                                      write: *uv.uv_write_t,
                                      owner: ffi.titan_ffi_void_ptr): integer
                    local loop_storage: *uv.uv_loop_t = lua.lua_newuserdatauv(
                        L, uv.uv_loop_t.sizeof, 0)
                    local timer_storage: *uv.uv_timer_t = lua.lua_newuserdatauv(
                        L, uv.uv_timer_t.sizeof, 0)
                    local fs_storage: *uv.uv_fs_t = lua.lua_newuserdatauv(
                        L, uv.uv_fs_t.sizeof, 0)
                    local dns_storage: *uv.uv_getaddrinfo_t =
                        lua.lua_newuserdatauv(
                            L, uv.uv_getaddrinfo_t.sizeof, 0)
                    local tcp_storage: *uv.uv_tcp_t = lua.lua_newuserdatauv(
                        L, uv.uv_tcp_t.sizeof, 0)
                    local signal_storage: *uv.uv_signal_t =
                        lua.lua_newuserdatauv(
                            L, uv.uv_signal_t.sizeof, 0)
                    local pipe_storage: *uv.uv_pipe_t =
                        lua.lua_newuserdatauv(L, uv.uv_pipe_t.sizeof, 0)
                    local process_storage: *uv.uv_process_t =
                        lua.lua_newuserdatauv(L, uv.uv_process_t.sizeof, 0)
                    local connect_storage: *uv.uv_connect_t =
                        lua.lua_newuserdatauv(L, uv.uv_connect_t.sizeof, 0)
                    local write_storage: *uv.uv_write_t =
                        lua.lua_newuserdatauv(L, uv.uv_write_t.sizeof, 0)
                    local shutdown_storage: *uv.uv_shutdown_t =
                        lua.lua_newuserdatauv(L, uv.uv_shutdown_t.sizeof, 0)
                    local buffer_storage: *uv.uv_buf_t =
                        lua.lua_newuserdatauv(L, uv.uv_buf_t.sizeof, 0)
                    local dirent_storage: *uv.uv_dirent_t =
                        lua.lua_newuserdatauv(L, uv.uv_dirent_t.sizeof, 0)
                    local address_storage: *shim.titan_uvshim_address =
                        lua.lua_newuserdatauv(
                            L, shim.titan_uvshim_address.sizeof, 0)
                    local argv: *shim.titan_uvshim_char_ptr =
                        lua.lua_newuserdatauv(
                            L, shim.titan_uvshim_char_ptr.sizeof * 2, 0)
                    local endpoints = ffi.titan_ffi_int.new_array(
                        shim.TITAN_UV_STDIO_ENDPOINT_COUNT)
                    local fillers = ffi.titan_ffi_int.new_array(
                        shim.TITAN_UV_STDIO_FILLER_CAPACITY)
                    local size = uv.size_t.new_array(1)
                    size[0] = 256 as uv.size_t
                    shim.titan_uvshim_timer_set_data(timer, owner)
                    shim.titan_uvshim_fs_set_data(req, owner)
                    shim.titan_uvshim_getaddrinfo_start(
                        nil, dns, owner, "127.0.0.1", 80)
                    shim.titan_uvshim_tcp_init(nil, tcp, owner)
                    shim.titan_uvshim_tcp_connect_start(
                        connect, tcp, owner, address_storage, 0)
                    shim.titan_uvshim_signal_init(nil, signal, owner)
                    shim.titan_uvshim_signal_start_oneshot(
                        signal, shim.titan_uvshim_signal_number("usr1"))
                    shim.titan_uvshim_signal_stop(signal)
                    shim.titan_uvshim_stdio_pipes(endpoints, fillers)
                    shim.titan_uvshim_pipe_init(nil, pipe, owner)
                    shim.titan_uvshim_pipe_open(
                        pipe, endpoints,
                        shim.TITAN_UV_STDIO_STDIN_PARENT
                            as ffi.titan_ffi_int)
                    shim.titan_uvshim_pipe_read_start(pipe)
                    shim.titan_uvshim_pipe_read_stop(pipe)
                    shim.titan_uvshim_pipe_write_start(
                        write, pipe, owner, nil)
                    shim.titan_uvshim_pipe_is_closing(pipe)
                    shim.titan_uvshim_pipe_close(pipe)
                    shim.titan_uvshim_process_spawn(
                        nil, process, owner, argv, endpoints)
                    shim.titan_uvshim_process_kill(process, 15)
                    shim.titan_uvshim_process_get_pid(process)
                    shim.titan_uvshim_process_is_closing(process)
                    shim.titan_uvshim_process_close(process)
                    shim.titan_uvshim_status_is_esrch(-1)
                    shim.titan_uvshim_error_einval()
                    shim.titan_uvshim_size_as_int64(size[0])
                    shim.titan_uvshim_status_is_enobufs(-1)
                    shim.titan_uvshim_status_is_enoent(-1)
                    uv.uv_timer_start(timer, shim.titan_uvshim_timer_cb, 0, 0)
                    uv.uv_fs_stat(nil, req, ".", shim.titan_uvshim_fs_cb)
                    if loop_storage and timer_storage and fs_storage and
                        dns_storage and tcp_storage and signal_storage and
                        pipe_storage and process_storage and connect_storage and
                        write_storage and shutdown_storage and buffer_storage and
                        dirent_storage and address_storage and argv then
                        return uv.uv_loop_t.alignof
                            + uv.uv_timer_t.alignof + uv.uv_fs_t.alignof
                            + uv.uv_getaddrinfo_t.alignof
                            + uv.uv_tcp_t.alignof
                            + uv.uv_signal_t.alignof
                            + uv.uv_pipe_t.alignof
                            + uv.uv_process_t.alignof
                            + uv.uv_connect_t.alignof
                            + uv.uv_write_t.alignof
                            + uv.uv_shutdown_t.alignof
                            + uv.uv_buf_t.alignof
                            + uv.uv_dirent_t.alignof
                            + shim.titan_uvshim_address.alignof
                            + shim.titan_uvshim_char_ptr.alignof
                    end
                    return 0
                end
            ]]
            local ast, parse_errors = parser.parse("(libuv FFI probe)", source)
            assert.truthy(ast, parse_errors and table.concat(parse_errors, "\n"))
            local _, errors = checker.check("uv_shim_ffi_probe", ast, source,
                "(libuv FFI probe)", driver.tableloader({}))
            assert.equals(0, #errors, table.concat(errors, "\n"))
            return coder.generate("uv_shim_ffi_probe", ast, {})
        end)
        driver.configure_foreign_c()
        types.registry = {}
        driver.imported = {}
        assert.truthy(ok, result)

        local public_include = assert(result:find("#include <uv.h>", 1, true))
        local shim_include = assert(result:find(
            "#include <titan/uv.h>", 1, true))
        assert.is_true(public_include < shim_include)
        assert.match("sizeof%(uv_loop_t%)", result)
        assert.match("sizeof%(uv_timer_t%)", result)
        assert.match("sizeof%(uv_fs_t%)", result)
        assert.match("sizeof%(uv_getaddrinfo_t%)", result)
        assert.match("sizeof%(uv_tcp_t%)", result)
        assert.match("sizeof%(uv_signal_t%)", result)
        assert.match("sizeof%(uv_pipe_t%)", result)
        assert.match("sizeof%(uv_process_t%)", result)
        assert.match("sizeof%(uv_connect_t%)", result)
        assert.match("sizeof%(uv_write_t%)", result)
        assert.match("sizeof%(uv_shutdown_t%)", result)
        assert.match("sizeof%(uv_buf_t%)", result)
        assert.match("sizeof%(uv_dirent_t%)", result)
        assert.match("sizeof%(titan_uvshim_address%)", result)
        assert.match("sizeof%(titan_uvshim_char_ptr%)", result)
        assert.match("_Alignof%(uv_loop_t%)", result)
        assert.match("_Alignof%(uv_timer_t%)", result)
        assert.match("_Alignof%(uv_fs_t%)", result)
        assert.match("_Alignof%(uv_getaddrinfo_t%)", result)
        assert.match("_Alignof%(uv_tcp_t%)", result)
        assert.match("_Alignof%(uv_signal_t%)", result)
        assert.match("_Alignof%(uv_pipe_t%)", result)
        assert.match("_Alignof%(uv_process_t%)", result)
        assert.match("_Alignof%(uv_connect_t%)", result)
        assert.match("_Alignof%(uv_write_t%)", result)
        assert.match("_Alignof%(uv_shutdown_t%)", result)
        assert.match("_Alignof%(uv_buf_t%)", result)
        assert.match("_Alignof%(uv_dirent_t%)", result)
        assert.match("_Alignof%(titan_uvshim_address%)", result)
        assert.match("_Alignof%(titan_uvshim_char_ptr%)", result)
        assert.match("%(%(uv_loop_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_timer_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_fs_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_getaddrinfo_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_tcp_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_signal_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_pipe_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_process_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_connect_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_write_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_shutdown_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_buf_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(uv_dirent_t %*%)%(lua_newuserdatauv", result)
        assert.match("%(%(titan_uvshim_address %*%)%(lua_newuserdatauv",
            result)
        assert.match("%(%(titan_uvshim_char_ptr %*%)%(lua_newuserdatauv",
            result)
        assert.match("%(%(uv_timer_cb%)%(titan_uvshim_timer_cb%)%)", result)
        assert.match("%(%(uv_fs_cb%)%(titan_uvshim_fs_cb%)%)", result)
    end)

    it("links the bundled archive into a PIC shared object", function()
        local config = bundled_libuv_config()
        local cc = shell_command_words(os.getenv("CC") or "cc")
        local shared_flags = "-shared"
        if config.HOST_OS == "Darwin" then
            shared_flags = shared_flags .. " -undefined dynamic_lookup"
        end
        local command = table.concat({
            "CCACHE_DISABLE=1", cc,
            "--std=c99 -O2 -Wall -Wextra -Werror -fPIC", shared_flags,
            config.CPPFLAGS,
            "spec/fixtures/uv/pic_probe.c",
            config.EXTRA_OBJECTS,
            config.LDFLAGS,
            "-o", shell_quote(shared_object),
        }, " ")
        local compile_ok, compile_output = run_command(command)
        assert.truthy(compile_ok, compile_output)

        local inspect_command
        if config.HOST_OS == "Linux" then
            local has_readelf = run_command("command -v readelf")
            inspect_command = has_readelf
                and "readelf -d " .. shell_quote(shared_object)
                or "ldd " .. shell_quote(shared_object)
        elseif config.HOST_OS == "Darwin" then
            inspect_command = "otool -L " .. shell_quote(shared_object)
        end
        if inspect_command then
            local inspect_ok, dependencies = run_command(inspect_command)
            assert.truthy(inspect_ok, dependencies)
            assert.not_match("libuv", dependencies:lower(), 1, true)
        end
    end)

    it("runs timer, filesystem, DNS, TCP, signal, process, pipe, OS, layout, and buffer probes", function()
        local config = bundled_libuv_config()
        local cc = shell_command_words(os.getenv("CC") or "cc")
        local lua_system_libs = "-lm"
        if config.HOST_OS == "Linux" then
            lua_system_libs = lua_system_libs .. " -ldl"
        end
        local command = table.concat({
            "CCACHE_DISABLE=1",
            cc,
            "--std=c99 -O2 -Wall -Wextra -Werror -fno-strict-aliasing",
            config.CPPFLAGS,
            config.CFLAGS,
            "-Ilua-5.5.0/src -Ititan-runtime",
            "titan-runtime/titan_uv.c",
            "spec/fixtures/uv/shim_probe.c",
            "lua-5.5.0/src/liblua.a",
            config.EXTRA_OBJECTS,
            config.LDFLAGS,
            lua_system_libs,
            "-o", shell_quote(executable),
        }, " ")
        local compile_ok, compile_output = run_command(command)
        assert.truthy(compile_ok, compile_output)

        local inspect_command
        if config.HOST_OS == "Linux" then
            local has_readelf = run_command("command -v readelf")
            inspect_command = has_readelf
                and "readelf -d " .. shell_quote(executable)
                or "ldd " .. shell_quote(executable)
        elseif config.HOST_OS == "Darwin" then
            inspect_command = "otool -L " .. shell_quote(executable)
        end
        if inspect_command then
            local inspect_ok, dependencies = run_command(inspect_command)
            assert.truthy(inspect_ok, dependencies)
            assert.not_match("libuv", dependencies:lower(), 1, true)
        end

        local run_ok, run_output = run_command(shell_quote(executable))
        assert.truthy(run_ok, run_output)
        assert.match("libuv shim probe passed", run_output, 1, true)
    end)
end)

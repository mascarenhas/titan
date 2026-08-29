require "titan-compiler.coder.core"
local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"
local cdriver = require "c-parser.cdriver"
local coder = require "titan-compiler.coder"
local coder_names = require "titan-compiler.coder.names"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"

local PKG_CONFIG = "sh spec/fixtures/libuv/fake-pkg-config.sh"
local UV_MAIN_SOURCE = "titan/uv/uv.titan"
local STDLIB_TYPES_FIXTURE =
"spec/fixtures/stdlib/titan_stdlib_types.lua"
local UV_TYPES_FIXTURE =
"spec/fixtures/libuv/titan_uv_types.lua"
local STDLIB_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "os", "peg", "string", "math", "lua", "iteration", "gc",
    "test",
}
local STDLIB_ROOTS = {
    "titan.coroutine", "titan.uv", "titan.async", "titan.timer",
    "titan.io", "titan.fs", "titan.net", "titan.ssl", "titan.url",
    "titan.http", "titan.os", "titan.peg", "titan.string", "titan.math",
    "titan.lua", "titan.iteration", "titan.gc", "titan.test",
}
local STDLIB_SHIMS = {
    "titan/coroutine.lua", "titan/uv.lua", "titan/async.lua",
    "titan/timer.lua", "titan/io.lua", "titan/fs.lua", "titan/net.lua",
    "titan/ssl.lua", "titan/url.lua", "titan/http.lua", "titan/os.lua",
    "titan/peg.lua", "titan/string.lua", "titan/math.lua", "titan/lua.lua",
    "titan/iteration.lua", "titan/gc.lua", "titan/test.lua",
}
local LPEGLABEL_INCLUDE =
    "-I" .. lfs.currentdir() .. "/vendor/lpeglabel"
local LLHTTP_NATIVE_INCLUDE =
    "-I" .. lfs.currentdir() .. "/llhttp-release-v9.4.3/include"
local BUNDLED_OPENSSL_INCLUDES = table.concat({
    "-I" .. lfs.currentdir() .. "/openssl-build/include",
    "-I" .. lfs.currentdir() .. "/openssl-3.5.7/include",
    "-DOPENSSL_API_COMPAT=30000",
}, " ")
local HTTP_SSL_BUNDLED_PAYLOAD = table.concat({
    "llhttp-build/libtitan-llhttp.a",
    "openssl-build/libssl.a",
    "openssl-build/libcrypto.a",
}, " ")
local HTTP_SSL_SYSTEM_PAYLOAD = "llhttp-build/libtitan-llhttp.a"
local HTTP_FOREIGN_CALLBACKS = {
    { name = "llhttp_url_cb",    slot = 3, setting = "on_url" },
    { name = "llhttp_status_cb", slot = 4, setting = "on_status" },
    {
        name = "llhttp_header_field_cb",
        slot = 5,
        setting = "on_header_field"
    },
    {
        name = "llhttp_header_value_cb",
        slot = 6,
        setting = "on_header_value"
    },
    {
        name = "llhttp_header_value_complete_cb",
        slot = 7,
        setting = "on_header_value_complete",
        no_data = true
    },
    {
        name = "llhttp_headers_complete_cb",
        slot = 8,
        setting = "on_headers_complete",
        no_data = true
    },
    { name = "llhttp_body_cb", slot = 9, setting = "on_body" },
    {
        name = "llhttp_message_complete_cb",
        slot = 10,
        setting = "on_message_complete",
        no_data = true
    },
}
local STDLIB_CONTAINER = "titan.so"
local STDLIB_STATIC_ARCHIVE = "titan.a"
local UV_FOREIGN_CALLBACKS = {
    {
        name = "uv_fs_cb",
        source = "titan/uv/file.titan",
        slot = 1,
        call = "entry(L, module, callback, owner)"
    },
    {
        name = "uv_signal_cb",
        source = "titan/uv/os.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, signum as lua.lua_Integer)"
    },
    {
        name = "uv_process_exit_cb",
        source = "titan/uv/process.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, " ..
            "exit_status as lua.lua_Integer, term_signal as lua.lua_Integer)"
    },
    {
        name = "uv_write_cb",
        source = "titan/uv/runtime.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer)"
    },
    {
        name = "uv_alloc_cb",
        source = "titan/uv/runtime.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, suggested_size, " ..
            "buf as *void)"
    },
    {
        name = "uv_read_cb",
        source = "titan/uv/runtime.titan",
        slot = 2,
        call = "entry(L, module, callback, owner, nread as lua.lua_Integer)"
    },
    {
        name = "uv_close_cb",
        source = "titan/uv/runtime.titan",
        slot = 1,
        call = "entry(L, module, callback, owner)"
    },
    {
        name = "uv_walk_cb",
        source = "titan/uv/runtime.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, " ..
            "handle as *void)"
    },
    {
        name = "uv_timer_cb",
        source = "titan/uv/task.titan",
        slot = 1,
        call = "entry(L, module, callback, owner)"
    },
    {
        name = "uv_getaddrinfo_cb",
        source = "titan/uv/tcp.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer, " ..
            "result as *void)"
    },
    {
        name = "uv_connect_cb",
        source = "titan/uv/tcp.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer)"
    },
    {
        name = "uv_shutdown_cb",
        source = "titan/uv/tcp.titan",
        slot = 1,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer)"
    },
    {
        name = "uv_connection_cb",
        source = "titan/uv/tcp.titan",
        slot = 3,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer)"
    },
    {
        name = "uv_work_cb",
        source = "titan/uv/work.titan",
        worker = true,
    },
    {
        name = "uv_after_work_cb",
        source = "titan/uv/work.titan",
        slot = 2,
        call = "entry(L, module, callback, owner, status as lua.lua_Integer)"
    },
}
local FS_FOREIGN_CALLBACKS = {
    {
        name = "fs_realpath_cb",
        slot = 1,
        call = "entry(L, module, callback, owner)"
    },
    {
        name = "fs_watcher_event_cb",
        slot = 1,
        call = "entry(L, module, callback, owner, filename, " ..
            "events as lua.lua_Integer, status as lua.lua_Integer)"
    },
}
local FS_DIRECT_LIBUV_CALLS = {
    "uv_fs_event_init",
    "uv_fs_event_start",
    "uv_fs_event_stop",
    "uv_fs_get_ptr",
    "uv_fs_get_result",
    "uv_fs_realpath",
    "uv_fs_req_cleanup",
    "uv_handle_get_data",
    "uv_handle_get_loop",
    "uv_handle_set_data",
    "uv_loop_get_data",
    "uv_req_get_data",
    "uv_req_set_data",
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
    "uv_tcp_init",
    "uv_tcp_bind",
    "uv_tcp_connect",
    "uv_translate_sys_error",
    "uv_spawn",
    "uv_walk",
    "uv_write",
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

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

local function installed_stdlib_container()
    local prefix = assert(prefix_from_cpath(package.cpath),
        "cannot find the active Lua prefix in package.cpath")
    return prefix .. "/lib/titan/0.6/" .. STDLIB_CONTAINER
end

local function installed_stdlib_archive()
    local prefix = assert(prefix_from_cpath(package.cpath),
        "cannot find the active Lua prefix in package.cpath")
    return prefix .. "/lib/titan/0.6/" .. STDLIB_STATIC_ARCHIVE
end

local function quote(word)
    local quoted = assert(cdriver.shell_quote(word))
    return quoted
end

local function run_argv(argv)
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local pipe = assert(io.popen(table.concat(words, " ") .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
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

local function makefile_words(name)
    local values = {}
    local collecting = false
    local found = false
    for line in (read_file("Makefile") .. "\n"):gmatch("(.-)\n") do
        local value
        if collecting then
            value = line
        else
            value = line:match("^" .. name .. "%s*:=%s*(.*)$")
            if value then found = true end
        end
        if value then
            local continued = value:match("\\%s*$") ~= nil
            value = value:gsub("\\%s*$", "")
            for word in value:gmatch("%S+") do values[#values + 1] = word end
            collecting = continued
            if not collecting then break end
        end
    end
    assert.truthy(found, "missing Makefile variable " .. name)
    assert.falsy(collecting, "unterminated Makefile variable " .. name)
    return values
end

local function discovered_uv_sources()
    local sources = {}
    for entry in lfs.dir("titan/uv") do
        local path = "titan/uv/" .. entry
        if entry:match("%.titan$") and
            lfs.attributes(path, "mode") == "file" then
            sources[#sources + 1] = path
        end
    end
    table.sort(sources)
    return sources
end

local function discovered_http_sources()
    local sources = {}
    for entry in lfs.dir("titan/http") do
        local path = "titan/http/" .. entry
        if entry:match("%.titan$") and
            lfs.attributes(path, "mode") == "file" then
            sources[#sources + 1] = path
        end
    end
    table.sort(sources)
    return sources
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
        if symbol == expected or symbol == "_" .. expected then return true end
    end
    return false
end

local function make_temp_dir()
    local path = assert(os.tmpname())
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
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

-- GNU Make executes recipe lines containing $(MAKE) even under -n. Keep these
-- command-contract tests independent of the checkout's prepared state by
-- replacing every stdlib build prerequisite class with one isolated file.
-- MAKE=false is a second guard: a newly introduced recursive dependency makes
-- the spec fail instead of installing or rebuilding anything.
local function run_stdlib_dry_make(argv)
    local root = make_temp_dir()
    local prepared = root .. "/prepared"
    write_file(prepared, "prepared for a read-only Make dry run\n")

    table.insert(argv, "PREFIX=" .. root)
    table.insert(argv, "MAKE=false")
    for _, variable in ipairs({
        "STDLIB_TOOL_PREREQS",
        "STDLIB_PLATFORM_PREREQS",
        "STDLIB_NATIVE_PREREQS",
        "STDLIB_RUNTIME_ARCHIVE_PREREQ",
        "STDLIB_BOOTSTRAP_PREREQ",
        "STDLIB_NATIVE_IDENTITY_PREREQS",
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

local function run_make(host, environment)
    local argv = {
        "make", "--no-print-directory", "-s", "LIBUV_MODE=system",
        "HOST_OS=" .. host, "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "libuv-config",
    }
    local words = {}
    for _, word in ipairs(argv) do table.insert(words, quote(word)) end
    local command = table.concat(words, " ")
    if environment then command = environment .. " " .. command end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function run_uv_dry_run(mode, host, source, openssl_mode,
                              openssl_pkg_config)
    local argv = {
        "make", "--no-print-directory", "-n",
        "-W", source or UV_MAIN_SOURCE,
        "LIBUV_MODE=" .. mode,
        "HOST_OS=" .. (host or "Linux"),
        "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
        "CC=ccache cc",
        "AR=review-ar",
        "RANLIB=review-ranlib",
        "TITAN_EXTRA_CPPFLAGS=-DUSER_CPP=1",
        "TITAN_EXTRA_CFLAGS=-DUSER_C=1",
        "TITAN_EXTRA_LDFLAGS=-Wl,user-link",
        "stdlib",
    }
    if openssl_mode then
        table.insert(argv, #argv, "OPENSSL_MODE=" .. openssl_mode)
    end
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
    local first = assert(normalized:find("CC='ccache cc'", 1, true),
        normalized)
    local last = assert(normalized:find("; for output in", first, true),
        normalized)
    return normalized:sub(first, last - 1), normalized
end

describe("libuv Makefile configuration", function()
    it("keeps private runtime refreshes off shared dependency recipes",
        function()
            local workspace = async_stdlib.workspace("runtime-refresh")
            local tested, test_error = pcall(function()
                local command =
                    async_stdlib.private_runtime_make_command(workspace, true)
                local libbacktrace_archive = lfs.currentdir() ..
                    "/libbacktrace/.libs/libbacktrace.a"
                local libuv_archive =
                    lfs.currentdir() .. "/libuv-build/libuv.a"
                assert.truthy(command:find(
                        "--old-file=" .. quote(libbacktrace_archive), 1, true),
                    command)
                assert.truthy(command:find(
                        "--old-file=" .. quote(libuv_archive), 1, true),
                    command)

                local ok, _, output = async_stdlib.run(command, workspace)
                assert.truthy(ok, output)
                assert.falsy(output:find(
                    "libbacktrace/.titan-build-config", 1, true), output)
                assert.falsy(output:find(
                    ".titan-libuv-build-config", 1, true), output)
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
        end)

    it("changes only an inherited default SIGPIPE disposition", function()
        local uv = read_file(UV_MAIN_SOURCE)
        for _, contract in ipairs({
            "local current = Sigaction.new()",
            "csignal.sigaction(csignal.SIGPIPE, nil, current)",
            "if current.sa_handler ~= csignal.SIG_DFL then return 0 end",
            "current.sa_handler = csignal.SIG_IGN",
            "csignal.sigaction(csignal.SIGPIPE, current, nil)",
        }) do
            assert.truthy(uv:find(contract, 1, true), contract)
        end
        assert.falsy(uv:find("Sigset", 1, true), uv)
        assert.falsy(uv:find("sigemptyset", 1, true), uv)
    end)

    it("keeps only async's nominal dependencies public in uv", function()
        assert.same({
            "Error", "Error.new", "OperationError", "OperationError.new",
        }, public_declarations("titan/uv/uv.titan"))
        assert.same({
            "ResumeToken", "ResumeToken.new",
            "CancellationReason", "CancellationReason.simple",
            "CancellationReason.complex", "TaskStatus", "TaskStatus.ready",
            "TaskStatus.running", "TaskStatus.waiting",
            "TaskStatus.succeeded", "TaskStatus.failed",
            "TaskStatus.cancelled", "TaskStatus:as_string",
            "TaskStatus:has_finished", "TaskStatus:has_succeeded",
            "TaskStatus:has_failed", "TaskStatus:has_cancelled", "Task",
            "Task:status", "Task:add_terminal_listener",
            "Task:cancel", "Task:resume",
        }, public_declarations("titan/uv/task.titan"))
        for _, contributor in ipairs({
            "file", "os", "process", "runtime", "tcp", "work",
        }) do
            assert.same({}, public_declarations(
                "titan/uv/" .. contributor .. ".titan"))
        end
    end)

    it("keeps generic Tasks over an all-value uv Runtime", function()
        local task = read_file("titan/uv/task.titan")
        for _, contract in ipairs({
            "record ResumeToken",
            "const source: string?",
            "union CancellationReason<B>",
            "union TaskStatus<A, B>",
            "record Task<A, B>",
            "local record TerminalRegistration<A, B>",
            "listener: (TaskStatus<A, B>) -> ()): () -> ()",
            "local record SuspendCall",
            "local token: ResumeToken",
            "local cancel_action: CancelAction?",
            "local resume_token: ResumeToken?",
            "function Task:resume(token: ResumeToken)",
            "Task resume token mismatch (expected source: ",
            "local function resume_task_from_callback(task: Task, " ..
            "failed: boolean,",
            "local function suspend(token: ResumeToken, " ..
            "cancel_action: CancelAction?)",
            "local function run_internal(func: () -> value): " ..
            "Task<value, value>",
            "Task<value, value>.new(",
        }) do
            assert.truthy(task:find(contract, 1, true), contract)
        end
        assert.falsy(task:find("remove_terminal_listener", 1, true), task)

        local async = read_file("titan/async.titan")
        for _, contract in ipairs({
            "function run<A, B>(func: () -> A): Task<A, B>",
            "function run_foreign(f: foreign (*void) -> (), arg: *void)",
            "function running(): Task<value, value>",
            "type ResumeToken = uv.ResumeToken",
            "type SuspendCancelAction = () -> ()",
            "function suspend(token: ResumeToken,",
            "cancel_action: SuspendCancelAction?)",
            "function channel<T>(size: integer?):",
            "ResumeToken.new(\"channel\")",
            "local transfer: {T} = {}",
            "local send: (T) -> ()",
            "local receive: () -> T",
            "channel<string>(size)",
            "union AnyTwoResult<A1, A2>",
            "union AnyFiveResult<A1, A2, A3, A4, A5>",
            "union RaceTwoResult<A1, B1, A2, B2>",
            "union RaceFiveResult<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>",
            "union AllTwoError<A1, B1, A2, B2>",
            "union AllFiveError<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>",
            "function any_two<A1, B1, A2, B2>(",
            "function any_five<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>(",
            "function race_two<A1, B1, A2, B2>(",
            "function race_five<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>(",
            "function all_two<A1, B1, A2, B2>(",
            "function all_five<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>(",
            "function join<A, B>(task: Task<A, B>): TaskStatus<A, B>",
            "function join_five<A1, B1, A2, B2, A3, B3, " ..
            "A4, B4, A5, B5>(",
        }) do
            assert.truthy(async:find(contract, 1, true), contract)
        end

        local work = read_file("titan/uv/work.titan")
        assert.truthy(work:find(
            'if status == 0 then return nil end', 1, true))
        assert.falsy(work:find(
            'submitted(task, status, "async.run_foreign")', 1, true))

        local http = read_file("titan/http/server.titan")
        assert.truthy(http:find(
            "async.run<Request?, value>(", 1, true), http)
        assert.truthy(http:find(
            "async.run(function (): nil", 1, true), http)
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
        assert.same({ "-O2", "-g", "-fPIC", "-fvisibility=hidden" },
            makefile_words("OPENSSL_REQUIRED_CFLAGS"))
        local makefile = read_file("Makefile")
        for _, contract in ipairs({
            "llhttp: $(LLHTTP_ARCHIVE)",
            "$(LLHTTP_ARCHIVE): FORCE $(LLHTTP_OBJECTS) " ..
            "$(LLHTTP_ARCHIVE_CONFIG)",
            "expected=\"$$(printf '%s\\n' $(notdir " ..
            "$(LLHTTP_OBJECTS)))\"",
            "LLHTTP_BUILD_CFLAGS=$(LLHTTP_BUILD_CFLAGS)",
            "$(LLHTTP_CFLAGS) $(TITAN_EXTRA_CFLAGS) " ..
            "$(LLHTTP_BUILD_CFLAGS)",
            "openssl: $(OPENSSL_LIBS)",
            "$(OPENSSL_PKG_CONFIG) --atleast-version=" ..
            "\"$(OPENSSL_MIN_VERSION)\" openssl",
            "CFLAGS=$(call make_shell_quote,$(OPENSSL_REQUIRED_CFLAGS) " ..
            "$(OPENSSL_BUILD_CFLAGS))",
            "OPENSSL_CONFIGURE_FLAGS=$(OPENSSL_CONFIGURE_FLAGS)",
            "rock-post-install: scripts/stdlib_installer.lua " ..
            "$(STDLIB_EXTRA_OBJECTS) openssl",
            "clean-llhttp:", "clean-openssl:",
            "clean-libuv clean-llhttp clean-openssl",
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
        local path = "titan/http/native.titan"
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
                "owner.uv[" .. callback.slot .. "].uv", 1, true), body)
            assert.truthy(body:find("owner.uv[2].uv", 1, true), body)
            assert.falsy(body:find(
                "titan_ffi_pushudata", 1, true), body)
            assert.truthy(body:find("lua.lua_settop(L, top)", 1, true), body)
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
        assert.truthy(native:find(
            "ffi.lua_pushtvalue(L, input)", 1, true), native)
        assert.truthy(native:find(
            "lua.lua_checkstack(L, lua.LUA_MINSTACK)", 1, true), native)
        assert.truthy(native:find(
            "llhttp.llhttp_execute(", 1, true), native)
        assert.truthy(native:find(
            "llhttp.llhttp_finish(", 1, true), native)
        assert.truthy(native:find(
            "llhttp.llhttp_get_error_pos(", 1, true), native)
    end)

    it("defines the exact libuv callbacks in generated Titan code",
        function()
            local declarations = {}
            local contents = {}
            local seen_sources = {}
            for _, callback in ipairs(UV_FOREIGN_CALLBACKS) do
                if not seen_sources[callback.source] then
                    seen_sources[callback.source] = true
                    local source = read_file(callback.source)
                    contents[#contents + 1] = source
                    local ast, parse_error = parser.parse(
                        callback.source, source)
                    assert.truthy(ast, parse_error and
                        parser.error_to_string(parse_error))
                    for _, node in ipairs(ast) do
                        if node._tag == "Ast.TopLevelForeignFunc" then
                            declarations[#declarations + 1] = node.name
                        end
                    end
                end
                local source = read_file(callback.source)
                local marker = "foreign function " .. callback.name .. "("
                local first = assert(source:find(marker, 1, true), marker)
                local last = assert(source:find("\nend", first, true), marker)
                local body = source:sub(first, last):gsub("%s+", " ")
                if callback.worker then
                    for _, contract in ipairs({
                        "libuv.uv_req_get_data",
                        "carrier[1] as WorkFunction",
                        "local arg = carrier[2]",
                        "f(arg)",
                    }) do
                        assert.truthy(body:find(contract, 1, true), body)
                    end
                    for _, forbidden in ipairs({
                        "carrier[0]", "owner.uv", "callback.upvalue",
                        "libuv.uv_loop_get_data", "lua.", "ffi.",
                    }) do
                        assert.falsy(body:find(forbidden, 1, true), body)
                    end
                else
                    assert.truthy(body:find(
                        "owner.uv[" .. callback.slot .. "].uv", 1, true), body)
                    assert.truthy(body:find(
                        "callback.upvalue[0]", 1, true), body)
                    assert.truthy(body:find(
                        "callback.upvalue[2]", 1, true), body)
                    assert.truthy(body:find(
                        "libuv.uv_loop_get_data", 1, true), body)
                    assert.falsy(body:find(
                        "titan_ffi_pushudata", 1, true), body)
                    assert.truthy(body:find(
                        callback.call, 1, true), body)
                    assert.truthy(body:find(
                        "lua.lua_settop(L, top)", 1, true), body)
                end
            end
            local expected = {}
            for _, callback in ipairs(UV_FOREIGN_CALLBACKS) do
                expected[#expected + 1] = callback.name
            end
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
            assert.same({ "$(RUNTIME_O)", "$(MINICORO_O)" },
                makefile_words("TITAN_RUNTIME_OBJECTS"))

            local logical_object = "titan/uv/uv.o"
            assert.truthy(file_exists(logical_object), logical_object)
            local ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", logical_object))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, callback in ipairs(UV_FOREIGN_CALLBACKS) do
                local symbol = coder_names._linkage_symbol_name(
                    coder_names._foreign_func_name("titan.uv", callback.name))
                assert.truthy(nm_has_symbol(output, symbol), symbol)
            end

            ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-u", logical_object))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, legacy in ipairs(LEGACY_UV_CALLBACKS) do
                assert.falsy(nm_has_symbol(output, legacy),
                    logical_object .. ": " .. legacy)
            end
            for _, function_name in ipairs(DIRECT_LIBUV_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
            end
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
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

            local archive = installed_stdlib_archive()
            assert.truthy(file_exists(archive), archive)
            ok, output, why, code = run_argv(tool_argv(
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

    it("defines the filesystem callbacks in the high-level module", function()
        local source_path = "titan/fs.titan"
        local source = read_file(source_path)
        local ast, parse_error = parser.parse(source_path, source)
        assert.truthy(ast, parse_error and
            parser.error_to_string(parse_error))
        local declarations = {}
        for _, node in ipairs(ast) do
            if node._tag == "Ast.TopLevelForeignFunc" then
                declarations[#declarations + 1] = node.name
            end
        end
        local expected = {}
        for _, callback in ipairs(FS_FOREIGN_CALLBACKS) do
            expected[#expected + 1] = callback.name
            local marker = "foreign function " .. callback.name .. "("
            local first = assert(source:find(marker, 1, true), marker)
            local last = assert(source:find("\nend", first, true), marker)
            local body = source:sub(first, last):gsub("%s+", " ")
            assert.truthy(body:find(
                "owner.uv[" .. callback.slot .. "].uv", 1, true), body)
            assert.truthy(body:find("callback.upvalue[0]", 1, true), body)
            assert.truthy(body:find("callback.upvalue[2]", 1, true), body)
            assert.truthy(body:find("libuv.uv_loop_get_data", 1, true), body)
            assert.truthy(body:find(callback.call, 1, true), body)
            assert.truthy(body:find("lua.lua_settop(L, top)", 1, true), body)
        end
        assert.same(expected, declarations)
        local _, condition_wakes = source:gsub(
            "uv%.resume_condition_waiter_from_callback%(", "")
        assert.equal(2, condition_wakes)
        assert.falsy(source:find(
            "uv.resume_task_from_callback", 1, true))

        local object = "titan/fs.o"
        assert.truthy(file_exists(object), object)
        local ok, output, why, code = run_argv(tool_argv("NM", "nm", object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, callback in ipairs(FS_FOREIGN_CALLBACKS) do
            local symbol = coder_names._linkage_symbol_name(
                coder_names._foreign_func_name("titan.fs", callback.name))
            assert.truthy(nm_has_symbol(output, symbol), symbol)
        end

        ok, output, why, code = run_argv(tool_argv("NM", "nm", "-u", object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, function_name in ipairs(FS_DIRECT_LIBUV_CALLS) do
            assert.truthy(nm_has_symbol(output, function_name),
                object .. ": " .. function_name)
        end

        local makefile = read_file("Makefile")
        assert.truthy(makefile:find("titan/fs.titan.h", 1, true))
    end)

    it("keeps filesystem explicit condition waits one-shot and scoped",
        function()
            local source = read_file("titan/fs.titan")

            local request_start = assert(source:find(
                "local record RealpathRequest", 1, true))
            local request_stop = assert(source:find(
                "\nend", request_start, true))
            local request = source:sub(request_start, request_stop - 1)
            assert.falsy(request:find("completed", 1, true), request)

            local realpath_start = assert(source:find(
                "function realpath(path: string): string", 1, true))
            local realpath_stop = assert(source:find(
                "\nlocal WATCHER_IDLE", realpath_start, true))
            local realpath = source:sub(realpath_start, realpath_stop - 1)
            assert_ordered(realpath,
                'local resume_token = uv.ResumeToken.new("fs.realpath")',
                "local cancel_action = function ()",
                "defer cancel_action()",
                "local status = libuv.uv_fs_realpath(",
                "uv.suspend(resume_token, cancel_action)")
            assert.equal(1, count_plain(realpath, "uv.suspend("), realpath)
            assert.falsy(realpath:find("while ", 1, true), realpath)

            local watcher_start = assert(source:find(
                "\nrecord Watcher\n", 1, true)) + 1
            local watcher_stop = assert(source:find(
                "\nend", watcher_start, true))
            local watcher = source:sub(watcher_start, watcher_stop - 1)
            assert.truthy(watcher:find(
                "local resume_token: uv.ResumeToken?", 1, true), watcher)

            local wake_start = assert(source:find(
                "local function Watcher:wake()", 1, true))
            local wake_stop = assert(source:find(
                "\nend", wake_start, true))
            local wake = source:sub(wake_start, wake_stop - 1)
            assert_ordered(wake,
                "local resume_token = self.resume_token",
                "self.waiter = nil",
                "self.resume_token = nil",
                "waiter:resume(resume_token)")

            local poll_start = assert(source:find(
                "function Watcher:poll(): {WatcherEvent}", 1, true))
            local poll = source:sub(poll_start)
            assert_ordered(poll,
                'local resume_token = uv.ResumeToken.new("fs.watcher")',
                "local cancel_action = function ()",
                "defer cancel_action()",
                "self.resume_token = resume_token",
                "self.waiter = task",
                "uv.suspend(resume_token, cancel_action)")
            assert.truthy(poll:find(
                "self.waiter == task and self.resume_token == resume_token",
                1, true), poll)
            assert.equal(1, count_plain(poll, "uv.suspend("), poll)
            assert.falsy(poll:find(
                "while #self.notifications", 1, true), poll)
        end)

    it("keeps the reviewed standard-library roots, sources, and shims exact",
        function()
            assert.same(STDLIB_MODULES, makefile_words("STDLIB_MODULES"))
            assert.same(STDLIB_ROOTS, makefile_words("STDLIB_ROOTS"))
            assert.same(STDLIB_SHIMS, makefile_words("STDLIB_SHIMS"))
            assert.same({
                "$(LTITANLIB_O)", "$(LPEGLABEL_ARCHIVE)",
                "$(LIBUV_EXTRA_OBJECTS)", "$(LLHTTP_ARCHIVE)",
                "$(OPENSSL_EXTRA_OBJECTS)",
            }, makefile_words("STDLIB_EXTRA_OBJECTS"))
            assert.same({
                "$(LPEGLABEL_ARCHIVE)", "$(LLHTTP_ARCHIVE)",
                "$(OPENSSL_EXTRA_OBJECTS)",
            }, makefile_words("STDLIB_NATIVE_IDENTITY_PREREQS"))
            assert.same({ "$(LPEGLABEL_CPPFLAGS)" },
                makefile_words("STDLIB_LPEGLABEL_CPPFLAGS"))
            assert.same({ "$(LLHTTP_CPPFLAGS)" },
                makefile_words("STDLIB_HTTP_CPPFLAGS"))
            assert.same({ "$(OPENSSL_CPPFLAGS)" },
                makefile_words("STDLIB_OPENSSL_CPPFLAGS"))
            assert.same({
                "LICENSES/libuv-LICENSE",
                "LICENSES/lpeglabel-LICENSE", "LICENSES/lpeg-LICENSE",
                "LICENSES/lpeg-patterns-LICENSE",
                "LICENSES/ta-regex-LICENSE", "LICENSES/lua-LICENSE",
                "LICENSES/llhttp-LICENSE", "LICENSES/openssl-LICENSE",
            }, makefile_words("STDLIB_LICENSES"))
            assert.same({ STDLIB_CONTAINER },
                makefile_words("STDLIB_CONTAINER"))

            local sources = makefile_words("STDLIB_TITAN_SOURCES")
            local expanded = {}
            local source_ensembles = {
                ["$(UV_TITAN_SOURCES)"] = "UV_TITAN_SOURCES",
                ["$(STDLIB_HTTP_SOURCES)"] = "STDLIB_HTTP_SOURCES",
            }
            for _, source in ipairs(sources) do
                local ensemble = source_ensembles[source]
                if ensemble then
                    for _, constituent in ipairs(makefile_words(ensemble)) do
                        expanded[#expanded + 1] = constituent
                    end
                else
                    expanded[#expanded + 1] = source
                end
            end
            assert.same({
                "titan/coroutine.titan",
                "titan/uv/uv.titan", "titan/uv/file.titan",
                "titan/uv/os.titan", "titan/uv/process.titan",
                "titan/uv/runtime.titan", "titan/uv/task.titan",
                "titan/uv/tcp.titan", "titan/uv/work.titan",
                "titan/async.titan",
                "titan/timer.titan", "titan/io.titan", "titan/fs.titan",
                "titan/net.titan", "titan/ssl.titan", "titan/url.titan",
                "titan/http/http.titan", "titan/http/client.titan",
                "titan/http/headers.titan", "titan/http/native.titan",
                "titan/http/server.titan",
                "titan/os.titan",
                "titan/peg/peg.titan",
                "titan/peg/combinators.titan", "titan/peg/native.titan",
                "titan/peg/relabel.titan",
                "titan/peg/relabel_parser.titan",
                "titan/string/string.titan",
                "titan/string/bytes.titan", "titan/string/format.titan",
                "titan/string/pack.titan", "titan/string/regex_api.titan",
                "titan/string/regex_compile.titan",
                "titan/string/regex_parser.titan",
                "titan/math.titan", "titan/lua.titan",
                "titan/iteration.titan", "titan/gc.titan", "titan/test.titan",
            }, expanded)
        end)

    it("keeps titan.gc as the sole stdlib lua_setmetatable owner",
        function()
            local callers = {}
            for _, source in ipairs(makefile_words("STDLIB_TITAN_SOURCES")) do
                if source ~= "$(UV_TITAN_SOURCES)" and
                    source ~= "$(STDLIB_HTTP_SOURCES)" then
                    if read_file(source):find(
                            "lua.lua_setmetatable", 1, true) then
                        callers[#callers + 1] = source
                    end
                end
            end
            assert.same({ "titan/gc.titan" }, callers)
        end)

    it("keeps parser-sugared standard-library imports short",
        function()
            local short = {
                "coroutine", "uv", "async", "timer", "io", "fs", "net",
                "ssl", "url", "http", "os", "peg", "string", "test",
                'math', 'gc', 'lua', 'iteration'
            }
            for _, source in ipairs(makefile_words("STDLIB_TITAN_SOURCES")) do
                if source ~= "$(UV_TITAN_SOURCES)" and
                    source ~= "$(STDLIB_HTTP_SOURCES)" then
                    local contents = read_file(source)
                    for _, module in ipairs(short) do
                        local long = 'import "titan.' .. module .. '"'
                        assert.falsy(contents:find(long, 1, true),
                            source .. " uses " .. long)
                    end
                end
            end

            for _, source in ipairs({
                "titan/async.titan", "titan/timer.titan",
                "titan/fs.titan", "titan/net.titan", "titan/os.titan",
            }) do
                local contents = read_file(source)
                assert.truthy(contents:find(
                    'import "uv.titan"', 1, true), source)
                assert.falsy(contents:find(
                    'import "uv"', 1, true), source)
                assert.falsy(contents:find(
                    'import "titan.uv.titan"', 1, true), source)
            end

            local ssl = read_file("titan/ssl.titan")
            for _, dependency in ipairs({ "async", "fs", "net", "string" }) do
                assert.truthy(ssl:find(
                    'import "' .. dependency .. '"', 1, true), dependency)
                assert.falsy(ssl:find(
                    'import "titan.' .. dependency .. '"', 1, true), dependency)
            end
            local http = read_file("titan/http/http.titan")
            for _, dependency in ipairs({
                "async", "io", "net", "ssl", "string", "url",
            }) do
                assert.truthy(http:find(
                    'import "' .. dependency .. '"', 1, true), dependency)
                assert.falsy(http:find(
                    'import "titan.' .. dependency .. '"', 1, true), dependency)
            end
            local url = read_file("titan/url.titan")
            for _, dependency in ipairs({ "peg", "string" }) do
                assert.truthy(url:find(
                    'import "' .. dependency .. '"', 1, true), dependency)
                assert.falsy(url:find(
                    'import "titan.' .. dependency .. '"', 1, true), dependency)
            end
        end)

    it("resumes one-shot timer Tasks only from close completion", function()
        local task_source = read_file("titan/uv/task.titan")
        local condition_start = assert(task_source:find(
            "local function resume_condition_waiter_from_callback(",
            1, true))
        local condition_stop = assert(task_source:find(
            "\nend", condition_start, true))
        local condition = task_source:sub(
            condition_start, condition_stop - 1)
        assert.matches("if task.resume_pending then return end",
            condition, 1, true)
        assert.matches(
            "resume_task_from_callback(task, false, nil)",
            condition, 1, true)
        assert.not_matches("ResumeToken", condition, 1, true)
        assert.not_matches("task:resume", condition, 1, true)

        local timer_start = assert(task_source:find(
            "local function start_timer(", 1, true))
        local timer_stop = assert(task_source:find(
            "\n-- Resume is meaningful only for an explicit async.suspend.",
            timer_start, true))
        local timer_body = task_source:sub(timer_start, timer_stop - 1)
        local completion_start = assert(timer_body:find(
            "local completion = function ()", 1, true))
        local callback_start = assert(timer_body:find(
            "local callback = function (owner: TimerOwner)", 1, true))
        local completion = timer_body:sub(
            completion_start, callback_start - 1)
        local timer_callback = timer_body:sub(callback_start)

        assert.matches("if terminal(task.state) then", completion, 1, true)
        assert.matches("task.resume_token = nil", completion, 1, true)
        assert.matches("task.resume_pending = false", completion, 1, true)
        assert.matches("resume_task_from_callback", completion, 1, true)
        assert.matches("begin_close", timer_callback, 1, true)
        assert.matches("owner.root_index, completion", timer_callback, 1,
            true)
        assert.not_matches("resume_task_from_callback", timer_callback, 1,
            true)

        local runtime_source = read_file("titan/uv/runtime.titan")
        local close_start = assert(runtime_source:find(
            "local function begin_close(", 1, true))
        local close_stop = assert(runtime_source:find(
            "\nlocal function close_handle(", close_start, true))
        local close_body = runtime_source:sub(close_start, close_stop - 1)
        local closing = assert(close_body:find(
            "libuv.uv_is_closing(handle)", 1, true))
        local root = assert(close_body:find(
            "root_handle(runtime, owner)", 1, true))
        local unroot = assert(close_body:find(
            "unroot_handle(runtime, owner.root_index)", 1, true))
        local complete = assert(close_body:find("completion()", 1, true))
        local submit = assert(close_body:find(
            "libuv.uv_close(handle, uv_close_cb)", 1, true))
        assert.is_true(closing < root)
        assert.is_true(unroot < complete)
        assert.is_true(complete < submit)
    end)

    it("retires explicit suspension before terminal listeners", function()
        local task = read_file("titan/uv/task.titan")
        local clear_start = assert(task:find(
            "local function clear_explicit_suspension(task: Task)",
            1, true))
        local clear_stop = assert(task:find("\nend", clear_start, true))
        local clear = task:sub(clear_start, clear_stop - 1)
        for _, assignment in ipairs({
            "task.suspended = false",
            "task.resume_token = nil",
            "task.resume_pending = false",
        }) do
            assert.matches(assignment, clear, 1, true)
        end

        local finish_start = assert(task:find(
            "local function finish_user_task(task: Task, state: TaskStatus)",
            1, true))
        local finish_stop = assert(task:find(
            "\n-- A cancellation request is authoritative", finish_start,
            true))
        local finish = task:sub(finish_start, finish_stop - 1)
        local retired = assert(finish:find(
            "clear_explicit_suspension(task)", 1, true))
        local notified = assert(finish:find(
            "notify_terminal(task, state)", 1, true))
        local unrooted = assert(finish:find(
            "retire_task(task, state)", 1, true))
        assert.is_true(retired < notified)
        assert.is_true(notified < unrooted)
    end)

    it("keeps SSL path loading high-level and PEM owners private", function()
        local ssl = read_file("titan/ssl.titan")
        local openssl_headers = {}
        for header in ssl:gmatch(
            'foreign import "openssl/([^"]+)"') do
            openssl_headers[#openssl_headers + 1] = header
        end
        assert.same({ "err.h", "x509v3.h", "pem.h", "ssl.h" },
            openssl_headers)
        assert.truthy(ssl:find(
            "local trust_data = fs.read_file", 1, true), ssl)
        assert.truthy(ssl:find(
            "local certificate_data = fs.read_file", 1, true), ssl)
        assert.truthy(ssl:find(
            "private_key_data = fs.read_file", 1, true), ssl)
        assert.truthy(ssl:find(
                "local default_client_context: *openssl.SSL_CTX", 1, true),
            ssl)
        assert.truthy(ssl:find(
            "local default_client_context_owner: " ..
            "DefaultClientContextOwner?", 1, true), ssl)
        assert.truthy(ssl:find(
            "local function finalize_default_client_context(" ..
            "\n    owner: DefaultClientContextOwner)", 1, true), ssl)
        assert.truthy(ssl:find(
            "gc.finalizable<DefaultClientContextOwner>(" ..
            "\n      owner, finalize_default_client_context)",
            1, true), ssl)
        assert.falsy(ssl:find(
            "as DefaultClientContextOwner", 1, true), ssl)
        assert.truthy(ssl:find(
                "openssl.SSL_CTX_set_default_verify_paths(context)", 1, true),
            ssl)
        assert.truthy(ssl:find(
            "openssl.SSL_CTX_up_ref(context)", 1, true), ssl)
        for _, retired in ipairs({
            "SSL_CTX_load_verify_locations",
            "SSL_CTX_use_certificate_chain_file",
            "SSL_CTX_use_PrivateKey_file",
        }) do
            assert.falsy(ssl:find(retired, 1, true), retired)
        end
        assert.falsy(ssl:find('import "uv"', 1, true), ssl)
        assert.falsy(ssl:find('foreign import "lua.h"', 1, true), ssl)

        assert.same({
            "DefaultClientContextOwner", "PemBlock",
            "CertificateResult", "PrivateKeyResult",
        }, local_record_declarations("titan/ssl.titan"))
        local public = {}
        for _, name in ipairs(public_declarations("titan/ssl.titan")) do
            public[name] = true
        end
        for _, helper in ipairs({
            "DefaultClientContextOwner", "PemBlock",
            "CertificateResult", "PrivateKeyResult",
        }) do
            assert.falsy(public[helper], helper .. " leaked into ssl ABI")
        end
    end)

    it("keeps listener defaults in the high-level facades", function()
        local net = read_file("titan/net.titan")
        assert.truthy(net:find(
            "local actual_backlog = 128", 1, true), net)

        local ssl = read_file("titan/ssl.titan")
        assert.truthy(ssl:find(
                "local actual_private_key_file = certificate_file", 1, true),
            ssl)

        local http = read_file("titan/http/server.titan")
        assert.truthy(http:find("local actual_port = 80", 1, true), http)
        assert.truthy(http:find("local actual_port = 443", 1, true), http)
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
                "InputOutputStream", "print", "lines",
                "InputOutputStream:read", "InputOutputStream:read_until",
                "InputOutputStream:write", "InputOutputStream:wait",
                "InputOutputStream:close", "popen",
            }, public_declarations(path))
        end)

    it("pins current metadata for all eighteen standard modules",
        function()
            local expected = assert(loadfile(STDLIB_TYPES_FIXTURE))()
            local expected_uv = assert(loadfile(UV_TYPES_FIXTURE))()
            assert.equal(18, #STDLIB_ROOTS)
            assert.equal(expected.uv, expected_uv,
                "standalone titan.uv metadata fixture is stale")

            for _, record_name in ipairs({
                "ChannelReader", "ChannelWriter",
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

    it("exports nineteen DSO openers for eighteen standard modules",
        function()
            assert.equal(18, #STDLIB_MODULES)
            assert.equal(18, #STDLIB_ROOTS)
            assert.equal(18, #STDLIB_SHIMS)

            local container = installed_stdlib_container()
            local ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-g", container))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local wanted = { luaopen_titan = true }
            for _, module in ipairs(STDLIB_MODULES) do
                wanted["luaopen_titan_" .. module] = true
            end
            local found = {}
            for line in output:gmatch("[^\r\n]+") do
                local symbol = line:match("(%S+)%s*$")
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
            assert.equal(19, (function()
                local count = 0
                for _ in pairs(found) do count = count + 1 end
                return count
            end)())
            assert.same(wanted, found)
        end)

    it("keeps bundled SSL and HTTP implementation symbols private", function()
        local host_ok, host_output, host_why, host_code =
            run_argv({ "uname", "-s" })
        assert.truthy(host_ok, host_output .. "\n(" ..
            tostring(host_why) .. ", " .. tostring(host_code) .. ")")
        local nm_flags = host_output:match("^%s*Darwin%s*$") and
            { "-gU" } or { "-D", "-g" }
        local argv = tool_argv("NM", "nm")
        for _, flag in ipairs(nm_flags) do argv[#argv + 1] = flag end
        argv[#argv + 1] = installed_stdlib_container()
        local ok, output, why, code = run_argv(argv)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local private_symbols = {
            "llhttp_execute", "SSL_do_handshake", "BIO_read",
        }
        for _, symbol in ipairs(private_symbols) do
            assert.falsy(nm_has_symbol(output, symbol),
                "private symbol is exported: " .. symbol)
        end
    end)

    it("pins the public fs facade and its portable location bridges",
        function()
            local path = "titan/fs.titan"
            assert.same({
                "File", "Stat", "Stat.new", "open", "File:read",
                "File:read_until", "File:write", "File:flush",
                "File:close", "File:is_closed", "read_file",
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
                "return uv.fs_tmpname()",
                "function tmpdir(): string",
                "return uv.os_tmpdir()",
                "function homedir(): string",
                "return uv.os_homedir()",
                "function pwd(): string",
                'return uv.current_directory("fs.pwd")',
                "function chdir(path: string)",
                'uv.change_directory(path, "fs.chdir")')
        end)

    it("pins the public os process and stdio facade", function()
        assert.same({
            "Date", "Date.new", "ExitStatus", "ExitStatus.new",
            "SpawnConfig", "SpawnOption",
            "InputStream", "OutputStream", "Process", "stdin", "stdout",
            "stderr", "clock", "difftime", "date", "setlocale", "time",
            "getenv", "setenv", "unsetenv", "cwd", "chdir", "homedir",
            "tmpdir", "hostname", "exepath", "pid", "ppid",
            "with_stdin", "with_stdout", "with_stderr",
            "with_parent_stdin", "with_parent_stdout", "with_parent_stderr",
            "with_merged_output", "spawn", "Process:wait", "Process:kill",
            "Process:is_running", "OutputStream:write",
            "OutputStream:close", "OutputStream:is_tty", "InputStream:read",
            "InputStream:read_until", "InputStream:close",
            "InputStream:is_tty", "exit",
            "wait_signal",
        }, public_declarations("titan/os.titan"))

        assert.falsy(read_file("titan/os.titan"):find(
            "os_stdio_is_closed", 1, true))
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

    it("keeps the regex AST union and its payload records private",
        function()
            assert.same({
                "RegexCompileState",
            }, local_record_declarations(
                "titan/string/regex_compile.titan"))
            assert.same({
                "RegexTextNode", "RegexChildrenNode", "RegexGroupNode",
                "RegexRepeatNode", "RegexBackreferenceNode", "ParsedRegex",
                "RegexQuantifier", "RegexClassItem", "RegexParseFrame",
                "RegexParseState",
            }, local_record_declarations(
                "titan/string/regex_parser.titan"))
            assert.same({
                "RegexNode",
            }, local_union_declarations(
                "titan/string/regex_parser.titan"))
        end)

    it("keeps LuaRocks on the native toolchain that prepared its prefix",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            for _, contract in ipairs({
                "LUAROCKS_CONFIG_POLICY := titan-system-tree-toolchain-v2",
                "TITAN_CONFIG_CC=$(call make_shell_quote,$(CC))",
                "TITAN_CONFIG_AR=$(call make_shell_quote,$(AR))",
                "TITAN_CONFIG_RANLIB=$(call make_shell_quote,$(RANLIB))",
                "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
                "export AR=$(call make_shell_quote,$(AR))",
                "export RANLIB=$(call make_shell_quote,$(RANLIB))",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end

            file = assert(io.open("titan-0.6.0-1.rockspec", "rb"))
            local rockspec = file:read("*a")
            file:close()
            for _, contract in ipairs({
                'AR = "$(AR)"',
                'RANLIB = "$(RANLIB)"',
                "unset LUA_PATH LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
            }) do
                assert.truthy(rockspec:find(contract, 1, true), contract)
            end
        end)

    it("reextracts pristine Lua and gives titanc exact shim ownership",
        function()
            local makefile = read_file("Makefile")
            for _, contract in ipairs({
                "LUA_EXTRACTED    := $(LUA_DIR)/.titan-extracted-v2",
                'rm -rf "$(LUA_DIR)"',
                "STDLIB_SHIMS := titan/coroutine.lua titan/uv.lua",
                'package.cpath="./titan-runtime/bootstrap/?.so;" .. package.cpath',
                "rm -f $(STDLIB_SHIMS)",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            local ignore = read_file(".gitignore")
            for _, shim in ipairs(STDLIB_SHIMS) do
                assert.truthy(ignore:find("/" .. shim, 1, true), shim)
            end
            assert.falsy(makefile:find(
                'strcmp(sym, "luaopen_titan_uv")', 1, true), makefile)
        end)

    it("keys every runtime object and archive member to the selected Lua SDK",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            for _, contract in ipairs({
                "TITAN_RUNTIME_LUA_SOURCE_PATH ?= $(LUA_DIR)/src",
                "TITAN_RUNTIME_LUA_LIB = " ..
                "$(TITAN_RUNTIME_LUA_SOURCE_PATH)/liblua.a",
                "TITAN_RUNTIME_LUA_SOURCE_PATH=" ..
                "$(TITAN_RUNTIME_LUA_SOURCE_PATH)",
                "LUA_AR=$(LUA_AR)",
                "LUA_RANLIB=$(LUA_RANLIB)",
                "$(RUNTIME_BUILD_CONFIG) | $(TITAN_RUNTIME_LUA_LIB) " ..
                "$(LIBBT_LIB)",
                "$(LTITANLIB_BUILD_CONFIG) $(LUA_INSTALL_STAMP)",
                "LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)",
                "MEMBERS=$(notdir $(TITAN_RUNTIME_OBJECTS))",
                "STDLIB_NATIVE_PREREQS := $(TITAN_RUNTIME_OBJECTS)",
                "$(STDLIB_EXTRA_OBJECTS)",
                "STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)",
                "STDLIB_CONFIG_STAMP := " ..
                "titan-runtime/.titan-stdlib-build-config",
                "STDLIB_COMPLETION_STAMP := " ..
                "titan-runtime/.titan-stdlib-complete",
                'rm -f "$$rocks_tree/lib/libtitan.a"',
                'install -m 0644 "$(TITAN_RUNTIME_LIB)" ' ..
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
            -- The checkout compiler, source installer validator, and private
            -- source-rock build all consume the already prepared runtime.
            assert.equal(3, prepared_count, makefile)

            file = assert(io.open("titan-compiler/driver.lua", "rb"))
            local driver_source = file:read("*a")
            file:close()
            assert.truthy(driver_source:find(
                    'os.getenv("TITAN_RUNTIME_PREBUILT") ~= "1"', 1, true),
                driver_source)
            local _, include_count = makefile:gsub(
                "%-I %$%(TITAN_RUNTIME_LUA_SOURCE_PATH%)", "")
            assert.equal(2, include_count, makefile)
        end)

    it("keeps the private Lua bootstrap separate from the runtime archive",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            local first = assert(makefile:find(
                "$(TITAN_BOOTSTRAP_SO): $(LTITANLIB_O)", 1, true))
            local last = assert(makefile:find(
                "\n\n# The active library path", first, true))
            local rule = makefile:sub(first, last - 1)
            assert.truthy(rule:find(
                "$(ROCK_LD) $(ROCK_LIBFLAG) -o \"$$tmp\" \"$<\"",
                1, true), rule)
            for _, forbidden in ipairs({
                "$(TITAN_RUNTIME_LIB)", "$(LIBBT_LIB)", "$(RUNTIME_O)",
                "$(MINICORO_O)", "$(UV_O)", "$(LPEGLABEL_ARCHIVE)",
            }) do
                assert.falsy(rule:find(forbidden, 1, true),
                    forbidden .. " in:\n" .. rule)
            end
        end)

    it("uses a loadable Lua bundle for the private macOS bootstrap",
        function()
            local ok, output, why, code = run_argv({
                "make", "--no-print-directory", "-Bn",
                "HOST_OS=Darwin", "TITAN_EXTRA_LDFLAGS=",
                "LUA_INSTALL_STAMP=/dev/null", "--old-file=/dev/null",
                "titan-runtime/bootstrap/titan.so",
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local normalized = output:gsub("%s+", " ")
            assert.truthy(normalized:find(
                '-bundle -undefined dynamic_lookup -o ' ..
                '"$tmp" "titan-runtime/ltitanlib.o"', 1, true), normalized)
            assert.falsy(normalized:find(
                '-shared -o "$tmp" "titan-runtime/ltitanlib.o"',
                1, true), normalized)
        end)

    it("ignores the BSD ranlib index when validating archive objects",
        function()
            local root = make_temp_dir()
            local archive = root .. "/libtitan.a"
            local config = root .. "/archive-build-config"
            local fake_ar = root .. "/ar-with-bsd-index"
            local build_log = root .. "/archive-builds"
            local objects = {
                root .. "/titan.o",
                root .. "/minicoro.o",
            }
            for _, object in ipairs(objects) do
                write_file(object, "isolated fake-archive fixture\n")
            end
            write_file(fake_ar, string.format([[#!/bin/sh
if test "$1" = t; then
  printf '%%s\n' '__.SYMDEF SORTED' titan.o minicoro.o
  exit 0
fi
if test "$1" = rcs; then
  printf 'build\n' >> %s
  : > "$2"
  exit 0
fi
exit 64
]], quote(build_log)))
            local ok, output, why, code = run_argv({ "chmod", "+x", fake_ar })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local make_archive = {
                "make", "--no-print-directory", "-s",
                "AR=" .. fake_ar,
                "RANLIB=true",
                "TITAN_RUNTIME_OBJECTS=" .. table.concat(objects, " "),
                "TITAN_RUNTIME_LIB=" .. archive,
                "RUNTIME_ARCHIVE_CONFIG=" .. config,
                archive,
            }
            local ran, run_error = pcall(function()
                ok, output, why, code = run_argv(make_archive)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\n", read_file(build_log))

                local aged = { "touch", "-t", "200001010000" }
                for _, path in ipairs(objects) do aged[#aged + 1] = path end
                aged[#aged + 1] = config
                ok, output, why, code = run_argv(aged)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                ok, output, why, code = run_argv({
                    "touch", "-t", "200101010000", archive,
                })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")

                write_file(build_log, "")
                ok, output, why, code = run_argv(make_archive)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("", read_file(build_log))
            end)
            for _, path in ipairs({
                archive, config, config .. ".tmp", fake_ar, build_log,
                objects[1], objects[2],
            }) do
                os.remove(path)
            end
            assert.truthy(lfs.rmdir(root))
            if not ran then error(run_error, 0) end
        end)

    it("keys the bundled archive on effective build inputs", function()
        local file = assert(io.open("Makefile", "rb"))
        local makefile = file:read("*a")
        file:close()
        assert.truthy(makefile:find(
            "$(LIBUV_LIB): $(LIBUV_EXTRACTED) $(LIBUV_BUILD_CONFIG)",
            1, true), makefile)
        assert.falsy(makefile:find(
                "$(LIBUV_LIB): $(LIBUV_EXTRACTED) Makefile", 1, true),
            makefile)
        assert.truthy(makefile:find(
            '\n\t+$(RECURSIVE_WRAPPER_GUARD) cmake --build ' ..
            '"$(LIBUV_BUILD_DIR)" --target uv_a',
            1, true), makefile)
        for _, input in ipairs({
            "LIBUV_VERSION=$(LIBUV_VERSION)",
            "LIBUV_BUILD_PROFILE=$(LIBUV_BUILD_PROFILE)",
            "LIBUV_BUILD_TYPE=$(LIBUV_BUILD_TYPE)",
            "LIBUV_CMAKE_FLAGS=$(LIBUV_CMAKE_FLAGS)",
            "LIBUV_BUILD_CFLAGS=$(LIBUV_BUILD_CFLAGS)",
        }) do
            assert.truthy(makefile:find(input, 1, true), input)
        end
    end)

    it("recreates the CMake build tree only when its configuration changes",
        function()
            local build_dir = make_temp_dir()
            local config = build_dir .. "/.titan-libuv-build-config"
            local sentinel = build_dir .. "/configured-output"

            local function configure(cc, generator)
                return run_argv({
                    "make", "--no-print-directory", "-s",
                    "LIBUV_BUILD_DIR=" .. build_dir,
                    "CC=" .. cc,
                    "AR=review-ar",
                    "RANLIB=review-ranlib",
                    "CMAKE_GENERATOR=" .. generator,
                    config,
                })
            end

            local tested, test_error = pcall(function()
                write_file(sentinel, "stale configured output\n")

                local ok, output, why, code =
                    configure("review-cc-a", "Review A")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.falsy(file_exists(sentinel))
                assert.truthy(file_exists(config))

                write_file(sentinel, "current configured output\n")
                ok, output, why, code = configure("review-cc-a", "Review A")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.truthy(file_exists(sentinel),
                    "an unchanged configuration must preserve the CMake tree")

                ok, output, why, code = configure("review-cc-b", "Review A")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.falsy(file_exists(sentinel),
                    "a compiler change must discard the cached CMake tree")

                write_file(sentinel, "old generator output\n")
                ok, output, why, code = configure("review-cc-b", "Review B")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.falsy(file_exists(sentinel),
                    "a generator change must discard the cached CMake tree")
            end)

            os.remove(sentinel)
            os.remove(config)
            assert.truthy(lfs.rmdir(build_dir))
            if not tested then error(test_error, 0) end
        end)

    it("preserves complete pkg-config flags and Linux feature macros",
        function()
            local ok, output, why, code = run_make("Linux")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.truthy(output:find(
                "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1 " ..
                "-D_GNU_SOURCE", 1, true), output)
            assert.truthy(output:find(
                "LIBUV_LDFLAGS=-L/opt/libuv/lib -luv -pthread -ldl -lrt",
                1, true), output)
        end)

    it("does not add the Linux-only macro on macOS", function()
        local ok, output, why, code = run_make("Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(
            "LIBUV_CPPFLAGS=-I/opt/libuv/include -DUV_FAKE_PKG=1",
            1, true), output)
        assert.falsy(output:find("-D_GNU_SOURCE", 1, true), output)
    end)

    it("fails early with platform package instructions when libuv is absent",
        function()
            local ok, output = run_make("Linux", "env FAKE_LIBUV_MISSING=1")
            assert.falsy(ok, output)
            assert.truthy(output:find("cannot find the libuv development package",
                1, true), output)
            assert.truthy(output:find("libuv1-dev", 1, true), output)
            assert.truthy(output:find("libuv-devel", 1, true), output)
            assert.truthy(output:find("brew install libuv pkgconf", 1, true),
                output)
        end)

    it("builds one provider pair with native support and one libuv policy",
        function()
            local ok, output, why, code = run_uv_dry_run("bundled")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local command, normalized = stdlib_command(output)
            assert.truthy(command:find(
                    "./titanc " .. table.concat(STDLIB_ROOTS, " "), 1, true),
                command)
            assert.equal(1, count_plain(command,
                "-X titan-runtime/ltitanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            assert.truthy(command:find([[CC='ccache cc']], 1, true), command)
            assert.truthy(command:find([[AR='review-ar']], 1, true), command)
            assert.truthy(command:find([[RANLIB='review-ranlib']], 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. LLHTTP_NATIVE_INCLUDE .. " " ..
                BUNDLED_OPENSSL_INCLUDES ..
                " -Ilibuv-v1.52.1/include -D_GNU_SOURCE'",
                1, true), command)
            assert.truthy(command:find(
                [[TITAN_EXTRA_CFLAGS='-DUSER_C=1 -fno-strict-aliasing']],
                1, true), command)
            local bundled_flags =
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lrt -lpthread']]
            assert.equal(1, count_plain(command, bundled_flags), command)
            assert.equal(1, count_plain(command, "libuv-build/libuv.a"), command)

            ok, output, why, code = run_uv_dry_run("system")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            command, normalized = stdlib_command(output)
            assert.truthy(command:find(
                    "./titanc " .. table.concat(STDLIB_ROOTS, " "), 1, true),
                command)
            assert.equal(1, count_plain(command,
                "-X titan-runtime/ltitanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                HTTP_SSL_BUNDLED_PAYLOAD), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            assert.falsy(command:find("libuv-build/libuv.a", 1, true), command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. LLHTTP_NATIVE_INCLUDE .. " " ..
                BUNDLED_OPENSSL_INCLUDES ..
                " -I/opt/libuv/include -DUV_FAKE_PKG=1 -D_GNU_SOURCE'",
                1, true), command)
            local system_flags =
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -L/opt/libuv/lib -luv -pthread -ldl -lrt -lpthread']]
            assert.equal(1, count_plain(command, system_flags), command)
            assert.equal(1, count_plain(command, " -luv "), command)

            ok, output, why, code = run_uv_dry_run("bundled", "Darwin")
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            command = stdlib_command(output)
            assert.equal(1, count_plain(command,
                    "-X titan-runtime/ltitanlib.o " ..
                    "lpeglabel-build/libtitan-lpeglabel.a " ..
                    "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD),
                command)
            assert.equal(1, count_plain(command,
                    [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lpthread']]),
                command)
        end)

    it("keeps system OpenSSL as ordered final-link inputs", function()
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
                "bundled", "Linux", nil, "system", fake_pkg_config)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local command = stdlib_command(output)
            assert.equal(1, count_plain(command,
                "-X titan-runtime/ltitanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_SYSTEM_PAYLOAD), command)
            assert.falsy(command:find("openssl-build/libssl.a", 1, true),
                command)
            assert.falsy(command:find("openssl-build/libcrypto.a", 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. LLHTTP_NATIVE_INCLUDE ..
                " -I/opt/openssl/include -DOPENSSL_FAKE_PKG=1 " ..
                "-DOPENSSL_API_COMPAT=30000 " ..
                "-Ilibuv-v1.52.1/include -D_GNU_SOURCE'", 1, true), command)
            assert.equal(1, count_plain(command,
                    [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lrt -L/opt/openssl/lib -lssl -lcrypto']]),
                command)
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("rebuilds the same provider pair when any reviewed source changes",
        function()
            local sources = {
                "titan/coroutine.titan", "titan/async.titan",
                "titan/timer.titan", "titan/io.titan", "titan/fs.titan",
                "titan/net.titan", "titan/ssl.titan", "titan/url.titan",
                "titan/http/http.titan", "titan/http/client.titan",
                "titan/http/headers.titan", "titan/http/native.titan",
                "titan/http/server.titan",
                "titan/os.titan",
                "titan/peg/peg.titan",
                "titan/peg/combinators.titan", "titan/peg/native.titan",
                "titan/peg/relabel.titan",
                "titan/peg/relabel_parser.titan",
                "titan/string/string.titan",
                "titan/string/bytes.titan", "titan/string/format.titan",
                "titan/string/pack.titan", "titan/string/regex_api.titan",
                "titan/string/regex_compile.titan",
                "titan/string/regex_parser.titan",
                "titan/math.titan", "titan/lua.titan",
                "titan/iteration.titan", "titan/gc.titan", "titan/test.titan",
            }
            for _, source in ipairs(makefile_words("UV_TITAN_SOURCES")) do
                sources[#sources + 1] = source
            end
            for _, source in ipairs(sources) do
                local ok, output, why, code =
                    run_uv_dry_run("bundled", "Linux", source)
                assert.truthy(ok, source .. ": " .. output .. "\n(" ..
                    tostring(why) .. ", " .. tostring(code) .. ")")
                local command, normalized = stdlib_command(output)
                assert.equal(1, count_plain(command,
                    "./titanc " .. table.concat(STDLIB_ROOTS, " ")), command)
                assert.truthy(command:find(
                    "-X titan-runtime/ltitanlib.o " ..
                    "lpeglabel-build/libtitan-lpeglabel.a " ..
                    "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD,
                    1, true), command)
                assert.falsy(normalized:find("titan/coroutine.so:", 1, true),
                    source .. ": " .. normalized)
            end
        end)

    it("keeps a valid warm pair and repairs missing or corrupt outputs",
        function()
            local root = make_temp_dir()
            local source = root .. "/metadata.c"
            local object = root .. "/metadata.o"
            local fixture_archive = root .. "/fixture.a"
            local fixture_provider = root .. "/fixture.so"
            local fixture_shim = root .. "/fixture.lua"
            local provider = root .. "/provider.so"
            local static_archive = root .. "/provider.a"
            local shim = root .. "/fixture-module.lua"
            local config = root .. "/stdlib.config"
            local completion = root .. "/stdlib.complete"
            local prepared = root .. "/prepared"
            local llhttp_build_config = root .. "/llhttp-build.config"
            local llhttp_archive_config = root .. "/llhttp-archive.config"
            local llhttp_archive = root .. "/llhttp.a"
            local fake_titanc = root .. "/fake-titanc"
            local build_log = root .. "/build.log"

            local payload = assert(staticmetadata.render(
                "fixture.module", "2", "{}"))
            local initializer = assert(staticmetadata.c_initializer(payload))
            write_file(source, string.format([[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#else
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#endif
TITAN_META_SECTION
static const unsigned char fixture_metadata[] = %s;
int fixture_native_payload(void) { return 1; }
]], initializer))

            local compile = { "env", "CCACHE_DISABLE=1" }
            for _, word in ipairs(compiler_argv("-c", source, "-o", object)) do
                compile[#compile + 1] = word
            end
            local ok, output, why, code = run_argv(compile)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            ok, output, why, code =
                run_argv({ "ar", "rcs", fixture_archive, object })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            write_file(fixture_provider, "fixture provider\n")
            write_file(fixture_shim, "fixture shim\n")
            write_file(prepared, "prepared\n")
            for _, input in ipairs({
                llhttp_build_config, llhttp_archive_config, llhttp_archive,
            }) do
                write_file(input, "prepared native identity\n")
            end
            write_file(build_log, "")
            write_file(fake_titanc, string.format([[#!/bin/sh
set -eu
cp %s %s
cp %s %s
cp %s %s
printf 'build\n' >> %s
]], quote(fixture_provider), quote(provider),
                quote(fixture_archive), quote(static_archive),
                quote(fixture_shim), quote(shim), quote(build_log)))
            ok, output, why, code = run_argv({ "chmod", "+x", fake_titanc })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            local prefix = assert(prefix_from_cpath(package.cpath))
            local function run_fixture_make(ar)
                return run_argv({
                    "make", "--no-print-directory", "-s",
                    "HOST_OS=Linux",
                    "LIBUV_MODE=system",
                    "LIBUV_PKG_CONFIG=" .. PKG_CONFIG,
                    "PREFIX=" .. root,
                    "TITAN_LUA=" .. prefix .. "/bin/lua",
                    "TITANC=" .. fake_titanc,
                    "AR=" .. ar,
                    "RANLIB=review-ranlib",
                    "STDLIB_ROOTS=fixture.module",
                    "STDLIB_TITAN_SOURCES=" .. prepared,
                    "STDLIB_SHIMS=" .. shim,
                    "STDLIB_CONTAINER=" .. provider,
                    "STDLIB_STATIC_ARCHIVE=" .. static_archive,
                    "STDLIB_CONFIG_STAMP=" .. config,
                    "STDLIB_COMPLETION_STAMP=" .. completion,
                    "STDLIB_EXTRA_OBJECTS=",
                    "STDLIB_NATIVE_IDENTITY_PREREQS=",
                    "LLHTTP_BUILD_CONFIG=" .. llhttp_build_config,
                    "LLHTTP_ARCHIVE_CONFIG=" .. llhttp_archive_config,
                    "LLHTTP_ARCHIVE=" .. llhttp_archive,
                    "OPENSSL_EXTRA_OBJECTS=",
                    "STDLIB_SOS=",
                    "STDLIB_QUALIFIED_SOS=",
                    "TITAN_COMPILER_LUA=",
                    "STDLIB_TOOL_PREREQS=" .. prepared,
                    "STDLIB_PLATFORM_PREREQS=" .. prepared,
                    "STDLIB_NATIVE_PREREQS=" .. prepared,
                    "STDLIB_RUNTIME_ARCHIVE_PREREQ=" .. prepared,
                    "STDLIB_BOOTSTRAP_PREREQ=" .. prepared,
                    "stdlib",
                })
            end

            local tested, test_error = pcall(function()
                ok, output, why, code = run_fixture_make("review-ar-a")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\n", read_file(build_log))
                local provider_mtime =
                    assert(lfs.attributes(provider, "modification"))
                local archive_mtime =
                    assert(lfs.attributes(static_archive, "modification"))

                ok, output, why, code = run_fixture_make("review-ar-a")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\n", read_file(build_log))
                assert.equal(provider_mtime,
                    lfs.attributes(provider, "modification"))
                assert.equal(archive_mtime,
                    lfs.attributes(static_archive, "modification"))

                ok, output, why, code = run_fixture_make("review-ar-b")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\nbuild\n", read_file(build_log))

                write_file(static_archive, "corrupt archive\n")
                ok, output, why, code = run_fixture_make("review-ar-b")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\nbuild\nbuild\n", read_file(build_log))
                assert.truthy(staticmetadata.scan_archive(static_archive, {
                    expected_abi = "2",
                }))

                assert.truthy(os.remove(provider))
                ok, output, why, code = run_fixture_make("review-ar-b")
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal("build\nbuild\nbuild\nbuild\n",
                    read_file(build_log))
                assert.equal("file", lfs.symlinkattributes(provider, "mode"))
                assert.equal("file",
                    lfs.symlinkattributes(static_archive, "mode"))
            end)

            remove_tree(root)
            if not tested then error(test_error, 0) end
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

    it("forwards LuaRocks command arguments to Busted byte-for-byte",
        function()
            local root = make_temp_dir()
            local tested, test_error = xpcall(function()
                local bin = root .. "/bin"
                local log = root .. "/argv"
                assert(lfs.mkdir(bin))
                local fake_busted = bin .. "/busted"
                write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_BUSTED_ARGV_LOG:?}"
printf '%s\0' "$@" > "$TITAN_BUSTED_ARGV_LOG"
exit 73
]==])
                local chmod_ok, chmod_output = run_argv({
                    "chmod", "+x", fake_busted,
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
                    "bash",
                    "spec/support/run_rock_tests.sh",
                }
                for _, argument in ipairs(ordinary) do
                    argv[#argv + 1] = argument
                end
                argv[#argv + 1] = "--busted-filter=focus$tail"
                argv[#argv + 1] = "--titan-filter=native$tail"
                local ok = run_argv(argv)
                assert.falsy(ok)

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

            local fake_busted = bin .. "/busted"
            write_file(fake_busted, [==[#!/usr/bin/env bash
set -eu
: "${TITAN_ROUTING_ARGV_LOG:?}"
printf '%s\0' "$@" > "$TITAN_ROUTING_ARGV_LOG"
]==])
            write_file(support .. "/run_parallel_compiler_tests.sh", [==[
#!/usr/bin/env bash
set -eu
: "${TITAN_ROUTING_SHARD_LOG:?}"
printf 'sharded\n' > "$TITAN_ROUTING_SHARD_LOG"
]==])
            local chmod_ok, chmod_output = run_argv({
                "chmod", "+x", fake_busted,
                support .. "/run_rock_tests.sh",
                support .. "/run_parallel_compiler_tests.sh",
            })
            assert.truthy(chmod_ok, chmod_output)

            local function decoded_argv(path)
                local encoded = read_file(path)
                local argv = {}
                local offset = 1
                while offset <= #encoded do
                    local finish = assert(encoded:find("\0", offset, true))
                    argv[#argv + 1] = encoded:sub(offset, finish - 1)
                    offset = finish + 1
                end
                return argv
            end

            local stdlib_specs = {
                "retained-one", "retained-two", "retained-three",
                "retained-four", "retained-five", "retained-six",
                "retained-seven", "retained-eight",
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
            assert.same(stdlib_specs, decoded_argv(argv_log))
            assert.equal("sharded\n", read_file(shard_log))

            ok, output = run_case({ "TITAN_FILTER=native$tail" })
            assert.truthy(ok, output)
            assert.same(stdlib_specs, decoded_argv(argv_log))
            assert.equal("sharded\n", read_file(shard_log))

            ok, output = run_case({ "BUSTED_FILTER=focus$tail" })
            assert.truthy(ok, output)
            assert.same({ "--filter=focus$tail" }, decoded_argv(argv_log))
            assert.falsy(lfs.attributes(shard_log))

            local direct = { "--name=cost$bill", "line one\nline two", "" }
            ok, output = run_case(nil, direct)
            assert.truthy(ok, output)
            assert.same(direct, decoded_argv(argv_log))
            assert.falsy(lfs.attributes(shard_log))

            local forwarded = { "spaced sentinel", "--literal=two words" }
            ok, output = run_case({
                "TITAN_ROCK_TEST_FORWARDED=1",
                "TITAN_ROCK_TEST_ARGC=2",
                "TITAN_ROCK_TEST_ARG_0=" .. forwarded[1],
                "TITAN_ROCK_TEST_ARG_1=" .. forwarded[2],
            })
            assert.truthy(ok, output)
            assert.same(forwarded, decoded_argv(argv_log))
            assert.falsy(lfs.attributes(shard_log))
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("selects every uncovered compiler shard exactly once without LuaCov",
        function()
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

                local expected = { {}, {}, {}, {} }
                for line in read_file(
                    "spec/support/ci_compiler_test_groups.txt"):
                gmatch("[^\r\n]+") do
                    local shard, path = line:match("^([1-4])%s+(%S+)")
                    if shard then
                        local paths = expected[tonumber(shard)]
                        paths[#paths + 1] = path
                    end
                end

                local seen = {}
                local total = 0
                for shard = 1, 4 do
                    local log = root .. "/shard-" .. shard
                    local ok, output = run_argv({
                        "env",
                        "BUSTED=" .. fake_busted,
                        "TITAN_SELECTOR_ARGV_LOG=" .. log,
                        "bash", "spec/support/ci_test_groups.sh",
                        "compiler-uncovered-shard-" .. shard,
                    })
                    assert.truthy(ok, output)
                    assert.truthy(output:find(
                        "without LuaCov", 1, true), output)

                    local encoded = read_file(log)
                    local argv = {}
                    local offset = 1
                    while offset <= #encoded do
                        local finish = assert(encoded:find(
                            "\0", offset, true))
                        argv[#argv + 1] = encoded:sub(offset, finish - 1)
                        offset = finish + 1
                    end
                    assert.same({ "-o", "gtest", "-v" },
                        { argv[1], argv[2], argv[3] })
                    for _, argument in ipairs(argv) do
                        assert.not_equal("-c", argument)
                    end

                    local actual = {}
                    for index = 4, #argv do
                        local path = argv[index]
                        assert.falsy(seen[path], path)
                        seen[path] = true
                        actual[#actual + 1] = path
                        total = total + 1
                    end
                    table.sort(actual)
                    table.sort(expected[shard])
                    assert.same(expected[shard], actual)
                end
                local expected_total = 0
                for shard = 1, 4 do
                    expected_total = expected_total + #expected[shard]
                end
                assert.equal(expected_total, total)
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("runs covered and uncovered stress compiler tests in each shard",
        function()
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

                local expected = { {}, {}, {}, {} }
                for line in read_file(
                    "spec/support/ci_compiler_test_groups.txt"):
                gmatch("[^\r\n]+") do
                    local shard, path = line:match("^([1-4])%s+(%S+)")
                    if shard then
                        local paths = expected[tonumber(shard)]
                        paths[#paths + 1] = path
                    end
                end
                local stress = {}
                for line in read_file(
                    "spec/support/ci_compiler_stress_files.txt"):
                gmatch("[^\r\n]+") do
                    if line:sub(1, 1) ~= "#" then stress[line] = true end
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

                for shard = 1, 4 do
                    local log = root .. "/shard-" .. shard
                    local ok, output = run_argv({
                        "env",
                        "BUSTED=" .. fake_busted,
                        "TITAN_SELECTOR_ARGV_LOG=" .. log,
                        "bash", "spec/support/ci_test_groups.sh",
                        "compiler-shard-" .. shard,
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
                    end
                    assert.is_true(covered_calls > 0)

                    local expected_covered = {}
                    local expected_stress = {}
                    for _, path in ipairs(expected[shard]) do
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
            end, debug.traceback)
            remove_tree(root)
            if not tested then error(test_error, 0) end
        end)

    it("isolates and bounds all four local compiler workers", function()
        local root = make_temp_dir()
        local tested, test_error = xpcall(function()
            local workspace = root .. "/workspace"
            local support = workspace .. "/spec/support"
            local bin = root .. "/bin"
            local temporary_base = root .. "/runner-tmp"
            local state = root .. "/state"
            local mkdir_ok, mkdir_output = run_argv({
                "mkdir", "-p", support, bin, temporary_base, state,
                workspace .. "/.git", workspace .. "/.lua",
            })
            assert.truthy(mkdir_ok, mkdir_output)
            write_file(workspace .. "/Makefile", "all:\n\t@true\n")
            write_file(workspace .. "/ordinary", "original\n")
            write_file(workspace .. "/.git/excluded", "git\n")
            write_file(workspace .. "/.lua/excluded", "lua\n")
            write_file(support .. "/run_parallel_compiler_tests.sh",
                read_file("spec/support/run_parallel_compiler_tests.sh"))

            local fake_busted = bin .. "/busted"
            write_file(fake_busted, [==[#!/usr/bin/env bash
exit 0
]==])
            write_file(support .. "/ci_test_groups.sh", [==[#!/usr/bin/env bash
set -u

state=${TITAN_FIXTURE_STATE:?}
expected_max=${TITAN_FIXTURE_EXPECTED_MAX:?}
group=${1:-}
case "$group" in
    compiler-uncovered-shard-[1-4]) shard=${group##*-} ;;
    *) echo "unexpected fixture group: $group" >&2; exit 71 ;;
esac

[[ $PWD != "$TITAN_FIXTURE_ORIGINAL" ]] || exit 72
[[ ! -e .git && ! -e .lua ]] || exit 73
[[ $(cat ordinary) == original ]] || exit 74
[[ $MAKEFLAGS == -j1 && $TITAN_JOBS == 1 ]] || exit 75
case "$BUSTED" in /*) ;; *) exit 76 ;; esac
[[ -d $TMPDIR ]] || exit 77
[[ $CCACHE_TEMPDIR == "$TMPDIR/ccache" &&
   -d $CCACHE_TEMPDIR ]] || exit 78

acquire_lock() {
    while ! mkdir "$state/lock" 2>/dev/null; do sleep 0.01; done
}
release_lock() {
    rmdir "$state/lock"
}

acquire_lock
active=$(cat "$state/active")
active=$((active + 1))
printf '%s\n' "$active" > "$state/active"
maximum=$(cat "$state/maximum")
if [[ $active -gt $maximum ]]; then
    printf '%s\n' "$active" > "$state/maximum"
fi
printf '%s\t%s\t%s\t%s\n' "$shard" "$PWD" "$TMPDIR" "$BUSTED" \
    >> "$state/observations"
release_lock

# Hold the first wave until every permitted slot is occupied, making the
# concurrency observation deterministic even on a heavily loaded host.
barrier_deadline=$((SECONDS + 5))
while [[ $(cat "$state/maximum") -lt $expected_max ]]; do
    if [[ $SECONDS -ge $barrier_deadline ]]; then
        echo "fixture concurrency barrier timed out" >&2
        exit 78
    fi
    sleep 0.01
done

if [[ ${TITAN_FIXTURE_KILL_WRAPPER_SHARD:-} == "$shard" ]]; then
    # The launcher makes the worker wrapper the process-group leader. Kill
    # only that leader so it cannot send its ordinary FIFO completion record;
    # leave this selector alive for the parent's dead-worker cleanup path.
    wrapper=$(ps -o pgid= -p $$ | tr -d ' ')
    [[ $wrapper =~ ^[0-9]+$ ]] || exit 79
    printf '%s\n' "$wrapper" > "$state/killed-wrapper"
    kill -KILL "$wrapper"
    sleep 30
    exit 80
fi

if [[ ${TITAN_FIXTURE_HANG_SHARD:-} == "$shard" ]]; then
    (
        trap '' TERM
        while :; do sleep 1; done
    ) &
    descendant=$!
    printf '%s\n' "$descendant" > "$state/term-ignoring-descendant"
    wait "$descendant"
    exit 81
fi

printf 'fixture-output-%s\n' "$shard"
touch "worker-mutated-$shard"
sleep 0.1

acquire_lock
active=$(cat "$state/active")
printf '%s\n' "$((active - 1))" > "$state/active"
printf '%s\n' "$shard" >> "$state/finished"
release_lock

if [[ ${TITAN_FIXTURE_FAIL_SHARD:-} == "$shard" ]]; then exit 23; fi
]==])
            local chmod_ok, chmod_output = run_argv({
                "chmod", "+x", fake_busted,
                support .. "/run_parallel_compiler_tests.sh",
                support .. "/ci_test_groups.sh",
            })
            assert.truthy(chmod_ok, chmod_output)

            local function reset_state()
                for _, name in ipairs({
                    "active", "maximum", "observations", "finished",
                    "killed-wrapper", "term-ignoring-descendant",
                }) do
                    os.remove(state .. "/" .. name)
                end
                write_file(state .. "/active", "0\n")
                write_file(state .. "/maximum", "0\n")
                write_file(state .. "/observations", "")
                write_file(state .. "/finished", "")
            end

            local function run_case(jobs, fail_shard, extra_environment,
                                    bounded)
                reset_state()
                local argv = {}
                if bounded then
                    argv[#argv + 1] = "bash"
                    argv[#argv + 1] = lfs.currentdir() ..
                        "/spec/support/run_with_timeout.sh"
                    argv[#argv + 1] = "8"
                end
                for _, argument in ipairs({
                    "bash", "-c",
                    'cd "$1" && shift && exec "$@"',
                    "titan-parallel-test", workspace,
                    "env", "-u", "TITAN_ROCK_TEST_JOBS",
                    "-u", "TITAN_FIXTURE_KILL_WRAPPER_SHARD",
                    "-u", "TITAN_FIXTURE_HANG_SHARD",
                    "PATH=" .. bin .. ":" .. assert(os.getenv("PATH")),
                    "BUSTED=busted",
                    "TMPDIR=" .. temporary_base,
                    "TITAN_FIXTURE_STATE=" .. state,
                    "TITAN_FIXTURE_ORIGINAL=" .. workspace,
                    "TITAN_FIXTURE_EXPECTED_MAX=" .. tostring(jobs or 4),
                }) do
                    argv[#argv + 1] = argument
                end
                if jobs then
                    argv[#argv + 1] =
                        "TITAN_ROCK_TEST_JOBS=" .. tostring(jobs)
                end
                if fail_shard then
                    argv[#argv + 1] =
                        "TITAN_FIXTURE_FAIL_SHARD=" .. tostring(fail_shard)
                else
                    argv[#argv + 1] = "TITAN_FIXTURE_FAIL_SHARD="
                end
                for _, assignment in ipairs(extra_environment or {}) do
                    argv[#argv + 1] = assignment
                end
                argv[#argv + 1] = "bash"
                argv[#argv + 1] =
                "spec/support/run_parallel_compiler_tests.sh"
                return run_argv(argv)
            end

            local function assert_temporary_base_empty()
                for entry in lfs.dir(temporary_base) do
                    assert.truthy(entry == "." or entry == "..", entry)
                end
            end

            local function assert_complete_run(expected_max, output)
                assert.equal(tostring(expected_max) .. "\n",
                    read_file(state .. "/maximum"))
                local roots = {}
                local temporary_directories = {}
                local observed_shards = {}
                for line in read_file(state .. "/observations"):
                gmatch("[^\r\n]+") do
                    local shard, worker, tmpdir, busted =
                        line:match("^(%d)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
                    assert.truthy(shard, line)
                    assert.falsy(observed_shards[shard], line)
                    assert.falsy(roots[worker], line)
                    assert.falsy(temporary_directories[tmpdir], line)
                    observed_shards[shard] = true
                    roots[worker] = true
                    temporary_directories[tmpdir] = true
                    assert.not_equal(workspace, worker)
                    assert.equal(fake_busted, busted)
                end
                local finished = {}
                for shard in read_file(state .. "/finished"):
                gmatch("[^\r\n]+") do
                    finished[shard] = true
                end
                for shard = 1, 4 do
                    local label = tostring(shard)
                    assert.truthy(observed_shards[label], label)
                    assert.truthy(finished[label], label)
                    assert.truthy(output:find(
                        "[compiler shard " .. label .. "] " ..
                        "fixture-output-" .. label, 1, true), output)
                    assert.truthy(output:find(
                        "===== finished compiler shard " .. label ..
                        ": status=", 1, true), output)
                    assert.falsy(lfs.attributes(
                        workspace .. "/worker-mutated-" .. label))
                end
                assert.equal(4, (function()
                    local count = 0
                    for _ in pairs(roots) do count = count + 1 end
                    return count
                end)())
                assert.equal(4, (function()
                    local count = 0
                    for _ in pairs(temporary_directories) do
                        count = count + 1
                    end
                    return count
                end)())
                assert.equal("original\n", read_file(
                    workspace .. "/ordinary"))
                assert_temporary_base_empty()
            end

            local function run_interruption_case()
                reset_state()
                return run_argv({
                    "bash", lfs.currentdir() ..
                "/spec/support/run_with_timeout.sh", "10",
                    "bash", "-c", [==[
workspace=$1
state=$2
temporary_base=$3
bin=$4
cd "$workspace" || exit 90
env PATH="$bin:$PATH" \
    BUSTED=busted \
    TMPDIR="$temporary_base" \
    TITAN_ROCK_TEST_JOBS=1 \
    TITAN_FIXTURE_STATE="$state" \
    TITAN_FIXTURE_ORIGINAL="$workspace" \
    TITAN_FIXTURE_EXPECTED_MAX=1 \
    TITAN_FIXTURE_FAIL_SHARD= \
    TITAN_FIXTURE_HANG_SHARD=1 \
    bash spec/support/run_parallel_compiler_tests.sh &
runner=$!
deadline=$((SECONDS + 5))
while [[ ! -s $state/term-ignoring-descendant ]]; do
    if ! kill -0 "$runner" 2>/dev/null; then
        wait "$runner" || true
        echo "parallel launcher exited before starting descendant" >&2
        exit 91
    fi
    if [[ $SECONDS -ge $deadline ]]; then
        kill -TERM "$runner" 2>/dev/null || true
        wait "$runner" || true
        echo "timed out waiting for TERM fixture descendant" >&2
        exit 92
    fi
    sleep 0.01
done
descendant=$(cat "$state/term-ignoring-descendant")
kill -TERM "$runner"
runner_status=0
wait "$runner" || runner_status=$?
if [[ $runner_status -ne 143 ]]; then
    echo "parallel launcher TERM status was $runner_status" >&2
    exit 93
fi
deadline=$((SECONDS + 4))
while kill -0 "$descendant" 2>/dev/null; do
    if [[ $SECONDS -ge $deadline ]]; then
        echo "TERM-ignoring descendant survived launcher cleanup" >&2
        exit 94
    fi
    sleep 0.01
done
]==], "titan-parallel-interruption", workspace, state,
                    temporary_base, bin,
                })
            end

            local ok, output = run_case()
            assert.truthy(ok, output)
            assert_complete_run(4, output)
            assert.truthy(output:find(
                "All four compiler shards passed", 1, true), output)

            ok, output = run_case(2)
            assert.truthy(ok, output)
            assert_complete_run(2, output)

            local why, code
            ok, output, why, code = run_case(nil, 2)
            assert.falsy(ok, output)
            assert.equal("exit", why)
            assert.equal(1, code)
            assert_complete_run(4, output)
            assert.truthy(output:find(
                "compiler shard 2 failed: 23", 1, true), output)

            local started = os.time()
            ok, output, why, code = run_case(1, nil, {
                "TITAN_FIXTURE_KILL_WRAPPER_SHARD=1",
            }, true)
            assert.falsy(ok, output)
            assert.equal("exit", why)
            assert.equal(1, code)
            assert.is_true(os.time() - started < 8, output)
            assert.truthy(lfs.attributes(
                state .. "/killed-wrapper", "mode"), output)
            assert.truthy(output:find(
                "compiler shard 1", 1, true), output)
            assert_temporary_base_empty()

            ok, output, why, code = run_interruption_case()
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.truthy(lfs.attributes(
                state .. "/term-ignoring-descendant", "mode"), output)
            assert_temporary_base_empty()

            for _, invalid in ipairs({ "0", "5", "invalid" }) do
                ok, output, why, code = run_argv({
                    "bash", "-c",
                    'cd "$1" && shift && exec "$@"',
                    "titan-parallel-validation", workspace,
                    "env",
                    "TITAN_ROCK_TEST_JOBS=" .. invalid,
                    "bash", "spec/support/run_parallel_compiler_tests.sh",
                })
                assert.falsy(ok, output)
                assert.equal("exit", why)
                assert.equal(2, code)
                assert.truthy(output:find(
                    "must be an integer from 1 through 4", 1, true), output)
            end
        end, debug.traceback)
        remove_tree(root)
        if not tested then error(test_error, 0) end
    end)

    it("bounds TERM-ignoring descendants for every command exit path",
        function()
            local function run_case(command, expected_ok, expected_code)
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
                    assert.equal("exit", why)
                    assert.equal(expected_code, code)
                end
                assert.is_true(elapsed < 10,
                    "timeout supervisor leaked its output pipe for " ..
                    tostring(elapsed) .. " seconds")
            end

            run_case('(trap "" TERM; sleep 12) & wait', false, 124)
            run_case('(trap "" TERM; sleep 12) & exit 0', true)
        end)

    it("owns the provider pair through one stamp and exact cleanup",
        function()
            local makefile = read_file("Makefile")
            for _, contract in ipairs({
                "STDLIB_STATIC_ARCHIVE := " .. STDLIB_STATIC_ARCHIVE,
                "STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) " ..
                "$(STDLIB_STATIC_ARCHIVE)",
                "STDLIB_EXTRA_OBJECTS := $(LTITANLIB_O) " ..
                "$(LPEGLABEL_ARCHIVE)",
                "STDLIB_NATIVE_IDENTITY_PREREQS := $(LPEGLABEL_ARCHIVE)",
                "TITAN_COMPILER_LUA := " ..
                "$(wildcard titan-compiler/*.lua \\\n\t" ..
                "titan-compiler/checker/*.lua " ..
                "titan-compiler/coder/*.lua c-parser/*.lua)",
                "STDLIB_EMBEDDED_FORMAT_INPUTS := " ..
                "titan-compiler/staticmetadata.lua \\\n\t" ..
                "titan-compiler/coder.lua " ..
                "$(wildcard titan-compiler/coder/*.lua)",
                "$(STDLIB_COMPLETION_STAMP): FORCE $(STDLIB_TITAN_SOURCES)",
                "$(TITAN_COMPILER_LUA) Makefile $(STDLIB_CONFIG_STAMP)",
                "$(STDLIB_CONFIG_STAMP): FORCE",
                'rm -f "$(STDLIB_COMPLETION_STAMP)"',
                "STDLIB_STATIC_ARCHIVE=$(STDLIB_STATIC_ARCHIVE)",
                "STDLIB_EXTRA_OBJECTS=$(STDLIB_EXTRA_OBJECTS)",
                "STDLIB_EMBEDDED_FORMAT_INPUTS=" ..
                "$(STDLIB_EMBEDDED_FORMAT_INPUTS)",
                "AR=$(call make_shell_quote,$(AR))",
                "RANLIB=$(call make_shell_quote,$(RANLIB))",
                "CLANG_FORMAT ?= clang-format",
                "TITAN_NO_LINE_DIRECTIVES ?=",
                "RECURSIVE_WRAPPER_GUARD = flags=$${MAKEFLAGS%% *}; " ..
                'case "$$flags" in -*) ;; *q*) exit 1 ;; ' ..
                "*n*|*t*) exit 0 ;; esac;",
                "export CLANG_FORMAT TITAN_EXTRA_CPPFLAGS " ..
                "TITAN_EXTRA_CFLAGS \\\n\t" ..
                "TITAN_EXTRA_LDFLAGS TITAN_NO_LINE_DIRECTIVES",
                "TITAN_NO_LINE_DIRECTIVES=$(TITAN_NO_LINE_DIRECTIVES)",
                "for output in $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS)",
                "STDLIB_UV_LDFLAGS=$(STDLIB_UV_LDFLAGS)",
                "validate_archive()",
                "STDLIB_INSTALL_STAGE       ?= $(CURDIR)",
                "TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT ?=",
                "install-stdlib: stdlib",
                "install-stdlib publish-stdlib: " ..
                "scripts/stdlib_installer.lua",
                "stage=$(call make_shell_quote,$(STDLIB_INSTALL_STAGE))",
                "install -m 0644 THIRD_PARTY_NOTICES.md",
                "install -m 0644 $(STDLIB_LICENSES)",
                '"$(TITAN_LUA)" -E "$(CURDIR)/scripts/stdlib_installer.lua"',
                "rm -f $(STDLIB_PROVIDER_OUTPUTS)",
                "rm -f $(STDLIB_SHIMS)",
                "rm -f titan/peg/peg.c titan/peg/peg.o",
                "rm -f titan/string/string.c titan/string/string.o",
                "rm -rf $(STDLIB_CONTAINER).dSYM",
                "examples/utils.a examples/artisanal.a examples/sdl_quit.a",
                "testfiles/selection_sort.a testfiles/sieve.a",
                "TITAN_STDLIB_TEST_PROGRAM_ROOT := test.tests",
                "TITAN_STDLIB_TEST_PROGRAM_OUTPUT := test/tests",
                "TITAN_STDLIB_TEST_ROOTS := " ..
                "$(TITAN_STDLIB_TEST_PROGRAM_ROOT)",
                "TITAN_TEST_EXECUTABLE := $(TITAN_TEST_BUILD_DIR)/" ..
                "$(TITAN_STDLIB_TEST_PROGRAM_OUTPUT)",
                "\nbusted-test:",
                "\nstdlib-busted-test:",
                "\ntitan-stdlib-test-build:",
                "\ntitan-stdlib-test-run:",
                "\ntitan-stdlib-test: titan-stdlib-test-build",
                "\nstdlib-test: stdlib-busted-test",
                "\nrock-test: busted-test",
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            local _, recursive_test_count = makefile:gsub(
                "\n\t%+%$%(RECURSIVE_WRAPPER_GUARD%) unset LUA_PATH " ..
                "LUA_CPATH LUA_PATH_5_5 LUA_CPATH_5_5",
                "")
            assert.equal(2, recursive_test_count, makefile)
            local stdlib_config_start = assert(makefile:find(
                "$(STDLIB_CONFIG_STAMP): FORCE", 1, true))
            local stdlib_config_end = assert(makefile:find(
                "\n$(STDLIB_COMPLETION_STAMP): FORCE",
                stdlib_config_start, true))
            local stdlib_config = makefile:sub(
                stdlib_config_start, stdlib_config_end - 1)
            assert.falsy(stdlib_config:find(
                "CLANG_FORMAT=$(CLANG_FORMAT)", 1, true), stdlib_config)
            assert.truthy(stdlib_config:find(
                "TITAN_NO_LINE_DIRECTIVES=$(TITAN_NO_LINE_DIRECTIVES)",
                1, true), stdlib_config)
            local rock_post_install_start = assert(makefile:find(
                "rock-post-install:", 1, true))
            local rock_post_install_end = assert(makefile:find(
                "\n# Compatibility name", rock_post_install_start, true))
            local rock_post_install = makefile:sub(
                rock_post_install_start, rock_post_install_end - 1)
            for _, contract in ipairs({
                "if test -n $(call make_shell_quote,$(strip " ..
                "$(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT))); then",
                '"$(CURDIR)/spec/support/' ..
                'ci_asan_generated_c_context.lua"',
                "snapshot",
                "$(call make_shell_quote,$(strip " ..
                "$(TITAN_STDLIB_DIAGNOSTIC_SNAPSHOT)))",
                '"$$stage/titan.so" "$(CURDIR)/titan" ' ..
                '"$$version_dir/titan.so"',
                '"$(CURDIR)/titan"',
            }) do
                assert.truthy(rock_post_install:find(contract, 1, true),
                    contract)
            end
            local diagnostic_snapshot = assert(rock_post_install:find(
                '"$(CURDIR)/spec/support/' ..
                'ci_asan_generated_c_context.lua"', 1, true))
            local publication = assert(rock_post_install:find(
                '"$(ROCK_LUA)" -E "$(CURDIR)/scripts/' ..
                'stdlib_installer.lua"', diagnostic_snapshot, true))
            assert.is_true(diagnostic_snapshot < publication,
                "diagnostic snapshot must preserve the private stage " ..
                "before publication")
            assert.falsy(makefile:find("-Wl,--whole-archive", 1, true), makefile)
            assert.falsy(makefile:find("-Wl,-force_load", 1, true), makefile)
            assert.falsy(makefile:find("rm -f *.a", 1, true), makefile)
            assert.falsy(makefile:find("examples/*.a", 1, true), makefile)
            assert.falsy(makefile:find("testfiles/*.a", 1, true), makefile)
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
            assert.truthy(native_run:find("2>&1 | cat", 1, true), native_run)
            assert.falsy(native_run:find("output=$$(", 1, true), native_run)

            local examples_makefile = read_file("examples/Makefile")
            assert.truthy(examples_makefile:find(
                "utils.so and utils.a", 1, true), examples_makefile)
            assert.truthy(examples_makefile:find(
                "rm -f *.c *.o *.so utils.a artisanal.a sdl_quit.a sdl_demo",
                1, true), examples_makefile)
            assert.falsy(examples_makefile:find("*.a", 1, true),
                examples_makefile)

            local snapshot = read_file("spec/support/ci_stdlib_snapshot.sh")
            for _, contract in ipairs({
                'static_archive=${provider%.so}.a',
                '"$static_archive"',
                'rm -f "$static_archive"',
                'write_manifest "$manifest" "${artifacts[@]}"',
                'cmp -s "$manifest" "$restored_manifest"',
                '"$shim_dir/peg.lua" "$shim_dir/string.lua"',
                '"$shim_dir/math.lua" "$shim_dir/lua.lua"',
                '"$shim_dir/iteration.lua" "$shim_dir/gc.lua" "$shim_dir/test.lua"',
                'test_source=$prefix_rel/share/titan/0.6/src/titan/test.titan',
                '"$test_source"',
                'rm -f "$test_source"',
                '"$shim_dir/io.lua"',
                '"$shim_dir/fs.lua" "$shim_dir/net.lua" "$shim_dir/ssl.lua"',
                '"$shim_dir/url.lua" "$shim_dir/http.lua" "$shim_dir/os.lua"',
            }) do
                assert.truthy(snapshot:find(contract, 1, true), contract)
            end

            local mode_smoke =
                read_file("spec/support/ci_libuv_mode_smoke.sh")
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
                "local peer = async.run<value, value>(",
                "timer.sleep(0)",
                "fs.write_file(marker,",
                "local metadata = fs.stat(marker)",
                "local merged = titan_io.popen(",
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
                '"$LIBUV_PKG_CONFIG" --static --libs libuv',
                '"$libdir/libuv.a" "$libdir/libuv_a.a"',
                "TITAN_SYSTEM_STATIC_LIBUV_ARCHIVE",
                "must name an absolute regular nonlink file",
                '"$OPENSSL_PKG_CONFIG" --cflags openssl',
                '"$OPENSSL_PKG_CONFIG" --libs openssl',
                "has_openssl_dependency",
                "defines_ssl_do_handshake",
                "driver.compile_archive_validation_image(",
                "build_static_system_provider_image",
                'if ! defines_uv_version "$static_provider"',
                'if defines_uv_version "$STATIC_ARCHIVE"',
                "has_public_lpeglabel_symbol",
                "has_unprefixed_lpeglabel_definition",
                "require_no_lpeglabel_dependency",
                "build_and_run_static_titan system-static",
                '"$executable" "$marker" "$TITAN_PROCESS_SMOKE_CHILD"',
                'if ! defines_uv_version "$executable"',
                'if defines_uv_version "$STATIC_ARCHIVE"',
                "LIBUV_MODE=system OPENSSL_MODE=system",
            }) do
                assert.truthy(mode_smoke:find(contract, 1, true), contract)
            end
            assert.falsy(mode_smoke:find("communicate", 1, true))

            local process_smoke =
                read_file("spec/fixtures/libuv/os_production_smoke.lua")
            for _, contract in ipairs({
                'local titan_io = require "titan.io"',
                "local merged = titan_io.popen(",
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

            local workflow = read_file(".github/workflows/ci.yml")
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
            local function named_step(job, name)
                local marker = "\n      - name: " .. name
                local first = assert(job:find(marker, 1, true), name)
                local finish = job:find(
                        "\n      - name:", first + #marker, true)
                    or (#job + 1)
                return job:sub(first, finish - 1)
            end
            local function assert_codecov_job(job, upload_name)
                assert.equal(1, count_literal(job, "contents: read"), job)
                assert.equal(1, count_literal(job, "id-token: write"), job)
                assert.equal(1,
                    count_literal(job, "codecov/codecov-action@v7"), job)
                assert.equal(1,
                    count_literal(job, "fail_ci_if_error: true"), job)
                assert.equal(1,
                    count_literal(job, "files: ./luacov.report.out"), job)
                assert.equal(1, count_literal(job,
                    "\n          name: " .. upload_name .. "\n"), job)
                assert.equal(1, count_literal(job, "use_oidc: true"), job)
                assert.falsy(job:find("\n%s+token:", 1), job)
            end

            local stdlib_job = assert(workflow:match(
                "\n  test%-linux%-stdlib:(.-)" ..
                "\n  test%-linux%-compiler:"))
            local compiler_job = assert(workflow:match(
                "\n  test%-linux%-compiler:(.-)\n  # macOS"))
            local macos_job = assert(workflow:match(
                "\n  test%-macos:(.-)\n  sanitizer:"))
            local sanitizer_job = assert(workflow:match(
                "\n  sanitizer:(.*)"))

            assert.equal(3, count_literal(workflow,
                "if: github.event_name == 'push'"), workflow)
            assert.equal(1, count_literal(workflow,
                "if: github.event_name == 'workflow_dispatch'"), workflow)
            assert.equal(4, count_literal(workflow, "\n    runs-on:"),
                workflow)
            for _, job_name in ipairs({
                "test-linux-stdlib", "test-linux-compiler", "test-macos",
                "sanitizer",
            }) do
                assert.equal(1, count_literal(workflow,
                    "\n  " .. job_name .. ":"), job_name)
            end
            for _, removed in ipairs({
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
            assert.equal(1, count_literal(workflow,
                "codecov/codecov-action@v7"), workflow)
            assert.equal(1, count_literal(workflow,
                "id-token: write"), workflow)
            assert.equal(1, count_literal(workflow,
                'luacov "titan%-compiler/"'), workflow)
            assert.falsy(workflow:find("CODECOV_TOKEN", 1, true), workflow)

            assert.equal(1, count_literal(stdlib_job,
                    "name: stdlib (ubuntu-24.04, build+all-no-coverage)"),
                stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "runs-on: ubicloud-standard-2"), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "timeout-minutes: 30"), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "contents: read"), stdlib_job)
            assert.falsy(stdlib_job:find("id-token: write", 1, true),
                stdlib_job)
            assert.falsy(stdlib_job:find("codecov/codecov-action", 1, true),
                stdlib_job)
            assert.falsy(stdlib_job:find('luacov "', 1, true),
                stdlib_job)
            assert.falsy(stdlib_job:find(" -c -o gtest", 1, true),
                stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "make stdlib-test"), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "make titan-stdlib-test-run"), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                "TITAN_TEST_TIMEOUT=15"), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                    "test_runtime_shutdown_closes_native_handles_but_not_files$"),
                stdlib_job)
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
            assert.is_true(assert(clean_recipe:find(
                "bash spec/support/clean_generated_test_artifacts.sh",
                1, true)) < assert(clean_recipe:find(
                "rm -f titan/*.c titan/*.o", 1, true)))
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
                "spec/fixtures/stdlib/native/async_foreign_work.h",
                "spec/fixtures/stdlib/native/async_foreign_work.c",
                "spec/fixtures/stdlib/native/uv_stdio_probe.h",
                "spec/fixtures/stdlib/native/uv_stdio_probe.c",
                "spec/fixtures/stdlib/native/os_process_host_child.c",
                "-X async_foreign_work.o uv_stdio_probe.o",
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
            for _, retained in ipairs({
                "spec/asan_generated_c_context_spec.lua",
                "spec/dense_array_runtime_spec.lua",
                "spec/libuv_build_spec.lua",
                "spec/lpeglabel_build_spec.lua",
                "spec/minicoro_spec.lua",
                "spec/readline_build_spec.lua",
                "spec/rockspec_spec.lua",
                "spec/stdlib_installer_spec.lua",
            }) do
                assert.truthy(makefile:find(retained, 1, true), retained)
            end
            assert.equal(1, count_literal(stdlib_job,
                'TITAN_EXTRA_CFLAGS: "-O0"'), stdlib_job)
            assert.equal(1, count_literal(stdlib_job,
                'TITAN_TEST_EXTRA_CFLAGS: "-O0"'), stdlib_job)
            assert.truthy(stdlib_job:find(
                'static_archive="${provider%.so}.a"', 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "ci_libuv_mode_smoke.sh bundled", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "ci_libuv_mode_smoke.sh system", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "LIBUV_MODE=system OPENSSL_MODE=system", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "archive: false", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "--exclude='./.git'", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "--exclude='./libbacktrace/.git'", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                    "--exclude='./.lua/var/cache/titan-probes'", 1, true),
                stdlib_job)
            assert.truthy(stdlib_job:find(
                "prepared tree contains the independent C-probe cache",
                1, true), stdlib_job)
            assert.falsy(stdlib_job:find("grep -Eq", 1, true), stdlib_job)
            assert.truthy(stdlib_job:find(
                "grep -E '^\\./\\.lua/var/cache/titan-probes(/|$)' " ..
                ">/dev/null", 1, true), stdlib_job)

            assert.equal(6, count_literal(workflow,
                "uses: ubicloud/cache@v4"), workflow)
            assert.equal(2, count_literal(workflow,
                "uses: ubicloud/cache/restore@v4"), workflow)
            assert.equal(2, count_literal(workflow,
                "uses: ubicloud/cache/save@v4"), workflow)
            assert.equal(4, count_literal(workflow,
                "path: .lua/var/cache/titan-probes/" ..
                "${{ env.TITAN_ABI_VERSION }}"), workflow)
            assert.equal(3, count_literal(workflow,
                "TITAN_PROBE_CACHE_IDENTITY=gha-v3:"), workflow)
            assert.equal(3, count_literal(workflow,
                "TITAN_PREFIX: ${{ github.workspace }}/.lua"), workflow)
            assert.falsy(workflow:find(
                "ci_probe_cache_identity.sh", 1, true), workflow)
            assert.truthy(stdlib_job:find("linux-regular-v1", 1, true))
            assert.falsy(compiler_job:find("linux-regular-v1", 1, true))
            assert.falsy(sanitizer_job:find("linux-regular-v1", 1, true))
            assert.truthy(sanitizer_job:find(
                "linux-asan-ubsan-v1", 1, true))
            assert.truthy(macos_job:find("macos-15-full-v1", 1, true))
            assert.equal(3, count_literal(workflow,
                "-${{ github.sha }}"), workflow)
            assert.equal(3, count_literal(workflow,
                "          key: titan-probe-success-v1-"), workflow)

            local regular_cache_step = named_step(
                stdlib_job, "Restore regular Linux C-probe success markers")
            assert.falsy(regular_cache_step:find(
                "-test-linux-compiler-", 1, true))
            assert.truthy(regular_cache_step:find(
                "-test-linux-stdlib-", 1, true))
            local regular_cache_index = assert(stdlib_job:find(
                "- name: Restore regular Linux C-probe success markers", 1, true))
            assert.truthy(regular_cache_step:find(
                "id: regular-probe-cache", 1, true))
            assert.truthy(regular_cache_step:find(
                "uses: ubicloud/cache/restore@v4", 1, true))
            local regular_build_index = assert(stdlib_job:find(
                "- name: Build and install the rock", regular_cache_index,
                true))
            assert.is_true(regular_cache_index < regular_build_index,
                stdlib_job)

            local pack_index = assert(stdlib_job:find(
                "- name: Pack prepared Linux tree", 1, true))
            local tests_index = assert(stdlib_job:find(
                "- name: Run all stdlib/runtime tests without coverage",
                pack_index, true))
            local bundled_index = assert(stdlib_job:find(
                "- name: Smoke-test bundled libuv source image",
                tests_index, true))
            local regular_save_index = assert(stdlib_job:find(
                "- name: Save regular Linux C-probe success markers",
                bundled_index, true))
            local regular_save_step = named_step(
                stdlib_job, "Save regular Linux C-probe success markers")
            assert.truthy(regular_save_step:find(
                "uses: ubicloud/cache/save@v4", 1, true))
            assert.truthy(regular_save_step:find(
                "${{ steps.regular-probe-cache.outputs.cache-primary-key }}",
                1, true))
            local system_index = assert(stdlib_job:find(
                "- name: Canary source-rock installation with system " ..
                "libuv and OpenSSL", regular_save_index, true))
            local upload_index = assert(stdlib_job:find(
                "- name: Upload prepared Linux tree", system_index, true))
            assert.is_true(pack_index < tests_index, stdlib_job)
            assert.is_true(tests_index < bundled_index, stdlib_job)
            assert.is_true(bundled_index < regular_save_index, stdlib_job)
            assert.is_true(regular_save_index < system_index, stdlib_job)
            assert.is_true(system_index < upload_index, stdlib_job)

            assert.equal(1, count_literal(compiler_job,
                    "name: compiler/language (ubuntu-24.04, LuaCov)"),
                compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "needs: test-linux-stdlib"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "runs-on: ubicloud-standard-2"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "timeout-minutes: 30"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "actions/download-artifact@v8"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "name: titan-linux-prepared.tar.gz"), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                "ci_parallel_compiler_tests.sh"), compiler_job)
            assert.falsy(compiler_job:find(
                "ci_test_groups.sh compiler", 1, true), compiler_job)
            assert.equal(1, count_literal(compiler_job,
                'TITAN_EXTRA_CFLAGS: "-O0"'), compiler_job)
            assert.falsy(compiler_job:find(
                "ci_stdlib_snapshot.sh", 1, true), compiler_job)
            local compiler_unpack_index = assert(compiler_job:find(
                "- name: Restore prepared Linux tree and environment",
                1, true))
            local compiler_tests_index = assert(compiler_job:find(
                "- name: Run four isolated compiler shards with covered " ..
                "and stress invocations",
                compiler_unpack_index, true))
            assert.is_true(compiler_unpack_index < compiler_tests_index)
            assert.falsy(compiler_job:find(
                "C-probe success markers", 1, true))
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
            assert.equal(3, count_literal(workflow,
                "TITAN_PROBE_CACHE_DISABLE=1"), workflow)
            assert_codecov_job(compiler_job, "compiler")

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
                "ci_libuv_mode_smoke.sh"), macos_job)
            assert.falsy(macos_job:find('luacov "', 1, true), macos_job)
            assert.falsy(macos_job:find("id-token: write", 1, true),
                macos_job)
            assert.equal(2, count_literal(macos_job,
                "ci_retry_luarocks_dependencies.sh"), macos_job)
            assert.equal(2, count_literal(workflow,
                "ci_retry_luarocks_dependencies.sh"), workflow)
            assert.equal(1, count_literal(macos_job,
                "luarocks make --only-deps"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "luarocks make --force"), macos_job)
            assert.equal(1, count_literal(macos_job,
                "luarocks test --prepare"), macos_job)
            local macos_cache_index = assert(macos_job:find(
                "- name: Restore macOS C-probe success markers", 1, true))
            local macos_build_index = assert(macos_job:find(
                "- name: Build and install the rock", macos_cache_index,
                true))
            local macos_tests_index = assert(macos_job:find(
                "- name: Run complete macOS tests without coverage",
                macos_build_index, true))
            assert.is_true(macos_cache_index < macos_build_index)
            assert.is_true(macos_build_index < macos_tests_index)
            local sanitizer_cache_index = assert(sanitizer_job:find(
                "- name: Restore sanitizer C-probe success markers", 1, true))
            local sanitizer_build_index = assert(sanitizer_job:find(
                "- name: Build sanitizer-enabled Titan artifacts",
                sanitizer_cache_index, true))
            assert.is_true(sanitizer_cache_index < sanitizer_build_index)

            for _, contract in ipairs({
                'LLHTTP_VERSION: "9.4.3"',
                'OPENSSL_VERSION: "3.5.7"',
                "Cache bundled llhttp source and static build",
                "llhttp-release-v${{ env.LLHTTP_VERSION }}.tar.gz",
                "Cache bundled OpenSSL source and static build",
                "openssl-${{ env.OPENSSL_VERSION }}.tar.gz",
                "Build the pinned private llhttp support",
                "Build the pinned bundled OpenSSL support",
                "run: make openssl",
                "Canary source-rock installation with system libuv and OpenSSL",
                "LIBUV_MODE=system OPENSSL_MODE=system",
                "OPENSSL_MODE=system",
                "brew install cmake libuv openssl@3 pkgconf",
                "test_ssl_http_fresh_process_sanitizer_composition$",
                "libssl-dev", "perl",
            }) do
                assert.truthy(workflow:find(contract, 1, true), contract)
            end
            assert.equal(0, count_literal(workflow, "clang-format"), workflow)
            assert.equal(1, count_literal(workflow,
                'MAKEFLAGS: "-j2"'), workflow)
            assert.equal(1, count_literal(workflow,
                'TITAN_JOBS: "2"'), workflow)
            assert.equal(2, select(2, workflow:gsub(
                'TITAN_SYSTEM_STATIC_LIBUV_ARCHIVE=' ..
                '"%$GITHUB_WORKSPACE/libuv%-build/libuv[.]a"', "")))
            assert.truthy(workflow:find(
                "--name='standalone-prefix source installation installs one " ..
                "matching Lua and Titan SDK before the standard images'",
                1, true), workflow)
            assert.truthy(workflow:find(
                "--name='standalone-prefix source installation loads direct " ..
                "libuv calls lazily for Titan and explicitly for Lua'",
                1, true), workflow)
            assert.truthy(workflow:find(
                "for module in coroutine uv async timer io fs net ssl url " ..
                "http os peg string math lua iteration gc test; do",
                1, true), workflow)
            assert.truthy(workflow:find(
                "share/titan/0.6/src/titan/test.titan", 1, true), workflow)

            local groups = read_file("spec/support/ci_test_groups.sh")
            for _, retained in ipairs({
                "compiler_tests=()",
                "compiler_unit_tests=()",
                "compiler_isolated_coverage_tests=()",
                "spec/asan_generated_c_context_spec.lua",
                "spec/dense_array_runtime_spec.lua",
                "spec/libuv_build_spec.lua",
                "spec/lpeglabel_build_spec.lua",
                "spec/minicoro_spec.lua",
                "spec/readline_build_spec.lua",
                "spec/rockspec_spec.lua",
                "spec/stdlib_installer_spec.lua",
                "run_isolated_compiler_coverage",
                '"$BUSTED" -c -o gtest -v --exclude-tags=stress ' ..
                    '"$test_file"',
                "compiler | compiler-shard-[1-4])",
                "compiler-uncovered | compiler-uncovered-shard-[1-4])",
                "compiler-shard-{1..4}",
                "compiler-uncovered-shard-{1..4}",
                "ci_compiler_test_groups.txt",
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
                "compiler-uncovered | compiler-uncovered-shard-[1-4])",
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
                "jobs=${TITAN_ROCK_TEST_JOBS:-4}",
                "[[ ! $jobs =~ ^[1-4]$ ]]",
                "tar --exclude='./.git'",
                "--exclude='./.lua'",
                'mkfifo "$completion_fifo"',
                'MAKEFLAGS=-j1',
                'TITAN_JOBS=1',
                'CCACHE_TEMPDIR="$worker_root/tmp-$shard/ccache"',
                '"compiler-uncovered-shard-$shard"',
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
                'mktemp -d "$runner_temp/titan-compiler-workers.XXXXXX"',
                'tar --exclude="./.lua" --exclude="./.git"',
                'cd "$worker" || exit 1',
                'rm -f luacov.stats.out luacov.report.out || exit 1',
                'mkdir -p .tmp || exit 1',
                'export TMPDIR="$PWD/.tmp"',
                'unset LUACOV_CONFIG',
                'MAKEFLAGS=-j1',
                'TITAN_JOBS=1',
                '"compiler-shard-$shard"',
                'sed -u "s/^/[compiler shard $shard] /"',
                'tee "$log"',
                'pipeline_status=("${PIPESTATUS[@]}")',
                "starting compiler covered+stress shard",
                "finished compiler covered+stress shard",
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

            local partition = read_file(
                "spec/support/ci_compiler_test_groups.txt")
            local assigned = {}
            local assigned_count = 0
            local shard_counts = { 0, 0, 0, 0 }
            for line in partition:gmatch("[^\n]+") do
                if line:sub(1, 1) ~= "#" then
                    local shard, filename, seconds = line:match(
                        "^([1-4]) (spec/.+_spec[.]lua) ([0-9.]+)$")
                    assert.truthy(shard, line)
                    assert.falsy(assigned[filename], filename)
                    assigned[filename] = true
                    assigned_count = assigned_count + 1
                    shard = tonumber(shard)
                    shard_counts[shard] = shard_counts[shard] + 1
                    assert.is_true(tonumber(seconds) >= 0)
                end
            end
            assert.same({ 30, 29, 30, 28 }, shard_counts)
            assert.equal(117, assigned_count)

            local stress_partition = read_file(
                "spec/support/ci_compiler_stress_files.txt")
            local stress_assigned = {}
            local stress_count = 0
            for line in stress_partition:gmatch("[^\n]+") do
                if line:sub(1, 1) ~= "#" then
                    assert.truthy(line:match("^spec/.+_spec[.]lua$"), line)
                    assert.falsy(stress_assigned[line], line)
                    assert.truthy(assigned[line], line)
                    assert.truthy(read_file(line):find(
                        "#stress", 1, true), line)
                    stress_assigned[line] = true
                    stress_count = stress_count + 1
                end
            end
            assert.equal(8, stress_count)

            assert.equal(1, count_literal(sanitizer_job,
                    "name: sanitizer (ubuntu-24.04, ASan+UBSan)"),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "runs-on: ubicloud-standard-2"), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "timeout-minutes: 35"), sanitizer_job)
            assert.falsy(sanitizer_job:find("id-token: write", 1, true),
                sanitizer_job)
            assert.falsy(sanitizer_job:find(
                "codecov/codecov-action", 1, true), sanitizer_job)
            assert.falsy(sanitizer_job:find(
                "actions/download-artifact", 1, true), sanitizer_job)
            assert.falsy(sanitizer_job:find("\n    needs:", 1, true),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                    'SANITIZER_FLAGS: "-O0 -g -fsanitize=address,undefined'),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'TITAN_EXTRA_CFLAGS: "-O0 -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'LUA_MYCFLAGS: "-fPIC -O1 -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            for _, contract in ipairs({
                'SANITIZER_NATIVE_CACHE_SCHEMA: "v1"',
                "CC: cc", "AR: ar", "RANLIB: ranlib",
                'SANITIZER_LUA_VERSION: "5.5.1"',
                'SANITIZER_LIBUV_VERSION: "1.52.1"',
                'SANITIZER_LIBUV_SHA256: "66d511b9e6e334c0e62279eb234fbfb2b' ..
                '3110b1479c09b95b44c7afca8cff9e7"',
                'LIBUV_BUILD_PROFILE: "static-pic-debug-tests-off-' ..
                'asan-ubsan-v1"',
                'SANITIZER_LLHTTP_VERSION: "9.4.3"',
                'SANITIZER_LLHTTP_SHA256: "1eb813c7437b31a87496a1cd3ed79f007' ..
                '46720f5e7e29c79b42c02cb69f36c39"',
                'SANITIZER_OPENSSL_VERSION: "3.5.7"',
                'SANITIZER_OPENSSL_SHA256: "a8c0d28a529ca480f9f36cf5792e2cd2' ..
                '1984552a3c8e4aa11a24aa31aeac98e8"',
                "id: sanitizer-native-cache-key",
                "git ls-remote",
                "libbacktrace.git HEAD",
                'cc_target="$(cc -dumpmachine)"',
                'cc_version="$(cc -dumpfullversion -dumpversion)"',
                'system_packages="$(dpkg-query',
                "id: sanitizer-native-cache",
                "uses: ubicloud/cache/restore@v4",
                "path: |",
                "lua-${{ env.SANITIZER_LUA_VERSION }}",
                "lua-${{ env.SANITIZER_LUA_VERSION }}.tar.gz",
                "libbacktrace",
                "libuv-v${{ env.SANITIZER_LIBUV_VERSION }}",
                "libuv-v${{ env.SANITIZER_LIBUV_VERSION }}.tar.gz",
                "llhttp-release-v${{ env.SANITIZER_LLHTTP_VERSION }}",
                "llhttp-release-v${{ env.SANITIZER_LLHTTP_VERSION }}.tar.gz",
                "openssl-${{ env.SANITIZER_OPENSSL_VERSION }}",
                "openssl-${{ env.SANITIZER_OPENSSL_VERSION }}.tar.gz",
                "uses: ubicloud/cache/save@v4",
                "steps.sanitizer-native-cache.outputs.cache-primary-key",
                "steps.sanitizer-native-cache.outputs.cache-hit != 'true'",
                'test ! -e "$PREFIX/bin/luarocks"',
                'test ! -e "$PREFIX/lib/titan"',
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
                "%-%${{ runner%.arch }}%-%${{ steps%." ..
                "sanitizer%-native%-cache%-key%.outputs%.digest }}"))
            for _, fingerprint in ipairs({
                "titan_abi=$TITAN_ABI_VERSION",
                "libuv_profile=$LIBUV_BUILD_PROFILE",
                "rock_cflags=${ROCK_CFLAGS:--O2 -fPIC}",
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
                "make openssl lua libuv libbacktrace llhttp"))
            assert.equal(1, count_literal(sanitizer_native_build_step,
                "grep -qx 'provider=system'"))
            for _, serial_capture in ipairs({
                "native-lua", "native-libbacktrace", "native-libuv",
                "native-llhttp", "native-openssl",
            }) do
                assert.falsy(sanitizer_native_build_step:find(
                    serial_capture, 1, true), sanitizer_native_build_step)
            end

            assert.equal(1, count_literal(sanitizer_job,
                "make titan-stdlib-test-build"), sanitizer_job)
            assert.equal(9, count_literal(sanitizer_job,
                "make titan-stdlib-test-run"), sanitizer_job)
            for _, filter in ipairs({
                "TITAN_FILTER='test_lua_host_roots_coroutine_" ..
                "payloads_and_tags_across_gc$'",
                "TITAN_FILTER='test_timer_'",
                "TITAN_FILTER='test_fs_'",
                "TITAN_FILTER='^uv%.task_tests%.'",
                "TITAN_FILTER='^uv%.runtime_tests%.'",
                "TITAN_FILTER='test_run_foreign_'",
                "TITAN_FILTER='test_ssl_http_fresh_process_sanitizer_composition$'",
                "TITAN_FILTER='test_peg_roots_and_releases_" ..
                "titan_callback_patterns$'",
                "TITAN_FILTER='test_regex_gc_rooting$'",
            }) do
                assert.equal(1, count_literal(sanitizer_job, filter), filter)
            end
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
                        "make openssl lua libuv libbacktrace llhttp",
                    },
                },
                {
                    "Install LuaRocks for the sanitizer Lua",
                    { "make luarocks" },
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
                    "Run dense Array runtime sanitizer gate",
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
                    "Run native TLS/HTTP sanitizer gate",
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

    it("cleans arbitrary test outputs without Git or per-test names",
        function()
            local root = make_temp_dir()
            local success, failure = xpcall(function()
                for _, directory in ipairs({
                    "spec", "future", "future/deep",
                    "future/deep/suite.dSYM",
                    "test_runner_future_case", ".titan-tests",
                }) do
                    assert.truthy(lfs.mkdir(root .. "/" .. directory))
                end
                local files = {
                    ["spec/native_fixture.c"] = "author written\n",
                    ["spec/generated_fixture.titan"] =
                    "module generated_fixture\n",
                    ["spec/generated_fixture.c"] = "generated C\n",
                    ["spec/generated_fixture.o"] = "generated object\n",
                    ["future/deep/suite"] = "executable\n",
                    ["future/deep/suite__test_support.c"] = "generated C\n",
                    ["future/deep/suite__test_runner.o"] =
                    "generated object\n",
                    ["future/deep/suite__test_entrypoint.titan"] =
                    "collision fixture\n",
                    ["future/deep/suite.dSYM/marker"] = "dSYM\n",
                    ["test_runner_future_case/source.titan"] =
                    "interrupted fixture\n",
                    [".titan-tests/keep"] = "owned output\n",
                }
                for path, contents in pairs(files) do
                    write_file(root .. "/" .. path, contents)
                end

                local script = lfs.currentdir() ..
                    "/spec/support/clean_generated_test_artifacts.sh"
                local clean_ok, output, why, code = run_argv({
                    "bash", "-c", 'cd "$1" && exec "$2" --keep-output',
                    "cleanup-test", root, script,
                })
                assert.truthy(clean_ok, output .. "\n(" .. tostring(why) ..
                    ", " .. tostring(code) .. ")")

                for _, removed in ipairs({
                    "spec/generated_fixture.c",
                    "spec/generated_fixture.o",
                    "future/deep/suite",
                    "future/deep/suite__test_support.c",
                    "future/deep/suite__test_runner.o",
                    "future/deep/suite__test_entrypoint.titan",
                    "future/deep/suite.dSYM/marker",
                    "test_runner_future_case/source.titan",
                }) do
                    assert.falsy(file_exists(root .. "/" .. removed), removed)
                end
                assert.is_nil(lfs.attributes(root .. "/future"))
                assert.is_nil(lfs.attributes(
                    root .. "/test_runner_future_case"))
                assert.equal("author written\n",
                    read_file(root .. "/spec/native_fixture.c"))
                assert.equal("module generated_fixture\n",
                    read_file(root .. "/spec/generated_fixture.titan"))
                assert.equal("owned output\n",
                    read_file(root .. "/.titan-tests/keep"))
            end, debug.traceback)
            remove_tree(root)
            assert.truthy(success, failure)
        end)
end)

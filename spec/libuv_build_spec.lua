local assert = require "luassert"
local async_stdlib = require "spec.support.async_stdlib"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"

local PKG_CONFIG = "sh spec/fixtures/libuv/fake-pkg-config.sh"
local UV_MAIN_SOURCE = "titan/uv/uv.titan"
local STDLIB_TYPES_FIXTURE =
"spec/fixtures/stdlib/titan_stdlib_types.lua"
local STDLIB_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "os", "peg", "string", "math", "lua", "iter", "gc",
    "test",
}
local STDLIB_ROOTS = {
    "titan.coroutine", "titan.uv", "titan.async", "titan.timer",
    "titan.io", "titan.fs", "titan.net", "titan.ssl", "titan.url",
    "titan.http", "titan.os", "titan.peg", "titan.string", "titan.math",
    "titan.lua", "titan.iter", "titan.gc", "titan.test",
}
local STDLIB_SHIMS = {
    "titan/coroutine.lua", "titan/uv.lua", "titan/async.lua",
    "titan/timer.lua", "titan/io.lua", "titan/fs.lua", "titan/net.lua",
    "titan/ssl.lua", "titan/url.lua", "titan/http.lua", "titan/os.lua",
    "titan/peg.lua", "titan/string.lua", "titan/math.lua", "titan/lua.lua",
    "titan/iter.lua", "titan/gc.lua", "titan/test.lua",
}
local LPEGLABEL_INCLUDE =
    "-I" .. lfs.currentdir() .. "/vendor/lpeglabel"
local HTTP_NATIVE_INCLUDE =
    "-I" .. lfs.currentdir() .. "/titan/http/native"
local LLHTTP_NATIVE_INCLUDE =
    "-I" .. lfs.currentdir() .. "/llhttp-release-v9.4.3/include"
local BUNDLED_OPENSSL_INCLUDES = table.concat({
    "-I" .. lfs.currentdir() .. "/openssl-build/include",
    "-I" .. lfs.currentdir() .. "/openssl-3.5.7/include",
    "-DOPENSSL_API_COMPAT=30000",
}, " ")
local HTTP_SSL_BUNDLED_PAYLOAD = table.concat({
    "llhttp-build/titan_httpshim.o",
    "llhttp-build/libtitan-llhttp.a",
    "openssl-build/libssl.a",
    "openssl-build/libcrypto.a",
}, " ")
local HTTP_SSL_SYSTEM_PAYLOAD = table.concat({
    "llhttp-build/titan_httpshim.o",
    "llhttp-build/libtitan-llhttp.a",
}, " ")
local HTTP_PARSER_CALLBACKS = {
    "titan_httpshim_url_cb",
    "titan_httpshim_status_cb",
    "titan_httpshim_header_field_cb",
    "titan_httpshim_header_value_cb",
    "titan_httpshim_header_value_complete_cb",
    "titan_httpshim_headers_complete_cb",
    "titan_httpshim_body_cb",
    "titan_httpshim_message_complete_cb",
}
local STDLIB_CONTAINER = "titan.so"
local STDLIB_STATIC_ARCHIVE = "titan.a"
local DIRECT_CALLBACKS = {
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
local PROVIDER_CALLBACK_REFERENCES = {
    "titan_uvshim_timer_cb",
    "titan_uvshim_fs_cb",
    "titan_uvshim_signal_cb",
    "titan_uvshim_process_exit_cb",
    "titan_uvshim_write_cb",
    "titan_uvshim_shutdown_cb",
    "titan_uvshim_alloc_cb",
    "titan_uvshim_read_cb",
    "titan_uvshim_connection_cb",
    "titan_uvshim_close_cb",
    "titan_uvshim_walk_cb",
    "titan_uvshim_getaddrinfo_cb",
    "titan_uvshim_connect_cb",
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
-- Darwin may lower sigemptyset entirely through the system header, leaving no
-- undefined object symbol. Its direct generated-C call is asserted below.
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
    return prefix .. "/lib/titan/0.22/" .. STDLIB_CONTAINER
end

local function installed_stdlib_archive()
    local prefix = assert(prefix_from_cpath(package.cpath),
        "cannot find the active Lua prefix in package.cpath")
    return prefix .. "/lib/titan/0.22/" .. STDLIB_STATIC_ARCHIVE
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

    it("keeps only async's nominal dependencies public in uv", function()
        assert.same({
            "Error", "Error.new", "OperationError", "OperationError.new",
        }, public_declarations("titan/uv/uv.titan"))
        assert.same({
            "CancellationReason", "CancellationReason.simple",
            "CancellationReason.complex", "TaskStatus", "TaskStatus.ready",
            "TaskStatus.running", "TaskStatus.waiting",
            "TaskStatus.succeeded", "TaskStatus.failed",
            "TaskStatus.cancelled", "TaskStatus:as_string",
            "TaskStatus:has_finished", "TaskStatus:has_succeeded",
            "TaskStatus:has_failed", "TaskStatus:has_cancelled", "Task",
            "Task:status", "Task:add_terminal_listener",
            "Task:remove_terminal_listener", "Task:cancel", "Task:resume",
        }, public_declarations("titan/uv/task.titan"))
        for _, contributor in ipairs({
            "file", "os", "process", "runtime", "tcp",
        }) do
            assert.same({}, public_declarations(
                "titan/uv/" .. contributor .. ".titan"))
        end
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
        assert.same({ "titan/http/native/titan_httpshim.c" },
            makefile_words("TITAN_HTTPSHIM_SOURCE"))
        assert.same({ "titan/http/native/titan_httpshim.h" },
            makefile_words("TITAN_HTTPSHIM_HEADER"))
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
            "llhttp: $(TITAN_HTTPSHIM_O) $(LLHTTP_ARCHIVE)",
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
        assert.truthy(file_exists("llhttp-build/titan_httpshim.o"),
            "run make llhttp first")
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
        for _, callback in ipairs(HTTP_PARSER_CALLBACKS) do
            assert.falsy(nm_has_symbol(output, callback), callback)
        end
    end)

    it("keeps HTTP parser storage and policy in Titan", function()
        local header = read_file("titan/http/native/titan_httpshim.h")
        local source = read_file("titan/http/native/titan_httpshim.c")
        local native = read_file("titan/http/native.titan")
        local declarations = {}
        for name in header:gmatch("(titan_httpshim_[%w_]+)%s*%(") do
            declarations[#declarations + 1] = name
        end
        assert.same(HTTP_PARSER_CALLBACKS, declarations)

        for _, forbidden in ipairs({
            "malloc(", "calloc(", "realloc(", "free(", "memcpy(",
            "titan_httpshim_event", "arena", "llhttp_execute(",
            "llhttp_finish(", "HPE_",
        }) do
            assert.falsy(source:find(forbidden, 1, true), forbidden)
            assert.falsy(header:find(forbidden, 1, true), forbidden)
        end

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
        assert.falsy(native:find("titan_httpshim_event", 1, true), native)

        local object = "llhttp-build/titan_httpshim.o"
        assert.truthy(file_exists(object), "run make llhttp first")
        local ok, output, why, code = run_argv(tool_argv(
            "NM", "nm", "-g", object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, callback in ipairs(HTTP_PARSER_CALLBACKS) do
            assert.truthy(nm_has_symbol(output, callback), callback)
        end
        for _, retired in ipairs({
            "titan_httpshim_parser_new", "titan_httpshim_parser_free",
            "titan_httpshim_execute", "titan_httpshim_finish",
            "titan_httpshim_event_count", "titan_httpshim_event_data_at",
        }) do
            assert.falsy(nm_has_symbol(output, retired), retired)
        end
    end)

    it("exports callbacks and records direct libuv archive references",
    function()
            local runtime_object = "titan-runtime/titan_uv.o"
            assert.truthy(file_exists(runtime_object), runtime_object)
            local ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-g", runtime_object))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, callback in ipairs(DIRECT_CALLBACKS) do
                assert.truthy(nm_has_symbol(output, callback), callback)
            end
            assert.falsy(nm_has_symbol(output, "uv_fs_get_result"),
                "filesystem result extraction belongs in Titan")
            for _, wrapper in ipairs(RETIRED_UV_WRAPPERS) do
                assert.falsy(nm_has_symbol(output, wrapper), wrapper)
            end
            for _, helper in ipairs(RETIRED_UV_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end
            for _, helper in ipairs(RETIRED_NETWORK_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end
            for _, helper in ipairs(FFI_RETIRED_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end

            local logical_object = "titan/uv/uv.o"
            assert.truthy(file_exists(logical_object), logical_object)
            ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-u", logical_object))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, callback in ipairs(PROVIDER_CALLBACK_REFERENCES) do
                assert.truthy(nm_has_symbol(output, callback),
                    logical_object .. ": " .. callback)
            end
            for _, function_name in ipairs(DIRECT_LIBUV_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
            end
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name),
                    logical_object .. ": " .. function_name)
            end
            for _, wrapper in ipairs(RETIRED_UV_WRAPPERS) do
                assert.falsy(nm_has_symbol(output, wrapper),
                    logical_object .. ": " .. wrapper)
            end
            for _, helper in ipairs(RETIRED_UV_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper),
                    logical_object .. ": " .. helper)
            end
            for _, helper in ipairs(RETIRED_NETWORK_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper),
                    logical_object .. ": " .. helper)
            end
            for _, helper in ipairs(FFI_RETIRED_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper),
                    logical_object .. ": " .. helper)
            end

            local archive = installed_stdlib_archive()
            assert.truthy(file_exists(archive), archive)
            ok, output, why, code = run_argv(tool_argv(
                "NM", "nm", "-u", archive))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, callback in ipairs(PROVIDER_CALLBACK_REFERENCES) do
                assert.truthy(nm_has_symbol(output, callback), callback)
            end
            for _, function_name in ipairs(DIRECT_LIBUV_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name), function_name)
            end
            for _, function_name in ipairs(SIGPIPE_EXTERNAL_HOST_CALLS) do
                assert.truthy(nm_has_symbol(output, function_name), function_name)
            end
            for _, wrapper in ipairs(RETIRED_UV_WRAPPERS) do
                assert.falsy(nm_has_symbol(output, wrapper), wrapper)
            end
            for _, helper in ipairs(RETIRED_UV_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end
            for _, helper in ipairs(RETIRED_NETWORK_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end
            for _, helper in ipairs(FFI_RETIRED_HELPERS) do
                assert.falsy(nm_has_symbol(output, helper), helper)
            end
        end)

    it("keeps the reviewed standard-library roots, sources, and shims exact",
        function()
            assert.same(STDLIB_MODULES, makefile_words("STDLIB_MODULES"))
            assert.same(STDLIB_ROOTS, makefile_words("STDLIB_ROOTS"))
            assert.same(STDLIB_SHIMS, makefile_words("STDLIB_SHIMS"))
            assert.same({
                "$(TITANLIB_O)", "$(LPEGLABEL_ARCHIVE)",
                "$(LIBUV_EXTRA_OBJECTS)", "$(TITAN_HTTPSHIM_O)",
                "$(LLHTTP_ARCHIVE)", "$(OPENSSL_EXTRA_OBJECTS)",
            }, makefile_words("STDLIB_EXTRA_OBJECTS"))
            assert.same({
                "$(LPEGLABEL_ARCHIVE)", "$(TITAN_HTTPSHIM_O)",
                "$(LLHTTP_ARCHIVE)", "$(OPENSSL_EXTRA_OBJECTS)",
            },
                makefile_words("STDLIB_NATIVE_IDENTITY_PREREQS"))
            assert.same({ "$(LPEGLABEL_CPPFLAGS)" },
                makefile_words("STDLIB_LPEGLABEL_CPPFLAGS"))
            assert.same({ "$(TITAN_HTTPSHIM_CPPFLAGS)", "$(LLHTTP_CPPFLAGS)" },
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
                "titan/uv/tcp.titan", "titan/async.titan",
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
                "titan/iter.titan", "titan/gc.titan", "titan/test.titan",
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
        for _, dependency in ipairs({ "titan.math" }) do
            assert.truthy(http:find(
                'import "' .. dependency .. '"', 1, true), dependency)
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
        local unroot = assert(close_body:find(
            "unroot_handle(runtime, owner.root_index)", 1, true))
        local complete = assert(close_body:find("completion()", 1, true))
        local submit = assert(close_body:find(
            "libuv.uv_close(handle, shim.titan_uvshim_close_cb)", 1, true))
        assert.is_true(unroot < complete)
        assert.is_true(complete < submit)
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
            "gc.finalizable(owner, finalize_default_client_context)",
            1, true), ssl)
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
            assert.equal(18, #STDLIB_ROOTS)

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
        for _, callback in ipairs(HTTP_PARSER_CALLBACKS) do
            private_symbols[#private_symbols + 1] = callback
        end
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
                "rename", "list",
            }, public_declarations(path))
            assert_ordered(read_file(path),
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

            file = assert(io.open("titan-dev-1.rockspec", "rb"))
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
                "$(UV_CONFIG_STAMP) $(RUNTIME_BUILD_CONFIG)",
                "LIBUV_PROVIDER_LDFLAGS=$(LIBUV_PROVIDER_LDFLAGS)",
                "MEMBERS=$(notdir $(TITAN_RUNTIME_OBJECTS))",
                "UV_CONFIG_STAMP := titan-runtime/.titan-uv-build-config",
                "STDLIB_NATIVE_PREREQS := $(TITAN_RUNTIME_OBJECTS)",
                "$(STDLIB_EXTRA_OBJECTS)",
                "STDLIB_RUNTIME_ARCHIVE_PREREQ := $(TITAN_RUNTIME_LIB)",
                "STDLIB_CONFIG_STAMP := " ..
                "titan-runtime/.titan-stdlib-build-config",
                "STDLIB_COMPLETION_STAMP := " ..
                "titan-runtime/.titan-stdlib-complete",
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
            assert.is_true(include_count >= 3, tostring(include_count))
        end)

    it("keeps the private Lua bootstrap separate from the runtime archive",
        function()
            local file = assert(io.open("Makefile", "rb"))
            local makefile = file:read("*a")
            file:close()
            local first = assert(makefile:find(
                "$(TITAN_BOOTSTRAP_SO): $(TITANLIB_O)", 1, true))
            local last = assert(makefile:find(
                "\n\n# The active ABI path", first, true))
            local rule = makefile:sub(first, last - 1)
            assert.truthy(rule:find(
                "$(ROCK_LD) $(ROCK_LIBFLAG) -o \"$$tmp\" \"$<\"",
                1, true), rule)
            for _, forbidden in ipairs({
                "$(TITAN_RUNTIME_LIB)", "$(LIBBT_LIB)", "$(RUNTIME_O)",
                "$(CORO_O)", "$(UV_O)", "$(LPEGLABEL_ARCHIVE)",
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
                "titan-runtime/bootstrap/titan.so",
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local normalized = output:gsub("%s+", " ")
            assert.truthy(normalized:find(
                '-bundle -undefined dynamic_lookup -o ' ..
                '"$tmp" "titan-runtime/titanlib.o"', 1, true), normalized)
            assert.falsy(normalized:find(
                '-shared -o "$tmp" "titan-runtime/titanlib.o"',
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
                root .. "/titan_coro.o",
                root .. "/titan_uv.o",
            }
            for _, object in ipairs(objects) do
                write_file(object, "isolated fake-archive fixture\n")
            end
            write_file(fake_ar, string.format([[#!/bin/sh
if test "$1" = t; then
  printf '%%s\n' '__.SYMDEF SORTED' titan.o titan_coro.o titan_uv.o
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
                objects[1], objects[2], objects[3],
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
                "-X titan-runtime/titanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_BUNDLED_PAYLOAD), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            assert.truthy(command:find([[CC='ccache cc']], 1, true), command)
            assert.truthy(command:find([[AR='review-ar']], 1, true), command)
            assert.truthy(command:find([[RANLIB='review-ranlib']], 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. HTTP_NATIVE_INCLUDE .. " " ..
                LLHTTP_NATIVE_INCLUDE .. " " .. BUNDLED_OPENSSL_INCLUDES ..
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
                "-X titan-runtime/titanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                HTTP_SSL_BUNDLED_PAYLOAD), command)
            assert.falsy(command:find("titan_uv.o", 1, true), command)
            assert.falsy(command:find("libuv-build/libuv.a", 1, true), command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. HTTP_NATIVE_INCLUDE .. " " ..
                LLHTTP_NATIVE_INCLUDE .. " " .. BUNDLED_OPENSSL_INCLUDES ..
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
                    "-X titan-runtime/titanlib.o " ..
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
                "-X titan-runtime/titanlib.o " ..
                "lpeglabel-build/libtitan-lpeglabel.a " ..
                "libuv-build/libuv.a " .. HTTP_SSL_SYSTEM_PAYLOAD), command)
            assert.falsy(command:find("openssl-build/libssl.a", 1, true),
                command)
            assert.falsy(command:find("openssl-build/libcrypto.a", 1, true),
                command)
            assert.truthy(command:find(
                "TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 " ..
                LPEGLABEL_INCLUDE .. " " .. HTTP_NATIVE_INCLUDE .. " " ..
                LLHTTP_NATIVE_INCLUDE ..
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
                "titan/iter.titan", "titan/gc.titan", "titan/test.titan",
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
                    "-X titan-runtime/titanlib.o " ..
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
            local httpshim_object = root .. "/httpshim.o"
            local llhttp_archive = root .. "/llhttp.a"
            local fake_titanc = root .. "/fake-titanc"
            local build_log = root .. "/build.log"

            local payload = assert(staticmetadata.render(
                "fixture.module", "0.22", "{}"))
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
                llhttp_build_config, llhttp_archive_config, httpshim_object,
                llhttp_archive,
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
                    "TITAN_HTTPSHIM_O=" .. httpshim_object,
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
                    expected_abi = "0.22",
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

    it("owns the provider pair through one stamp and exact cleanup",
        function()
            local makefile = read_file("Makefile")
            for _, contract in ipairs({
                "STDLIB_STATIC_ARCHIVE := " .. STDLIB_STATIC_ARCHIVE,
                "STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) " ..
                "$(STDLIB_STATIC_ARCHIVE)",
                "STDLIB_EXTRA_OBJECTS := $(TITANLIB_O) " ..
                "$(LPEGLABEL_ARCHIVE)",
                "STDLIB_NATIVE_IDENTITY_PREREQS := $(LPEGLABEL_ARCHIVE)",
                "TITAN_COMPILER_LUA := " ..
                "$(wildcard titan-compiler/*.lua c-parser/*.lua)",
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
                "TITAN_NO_LINE_DIRECTIVES ?=",
                "export TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_CFLAGS " ..
                "TITAN_EXTRA_LDFLAGS \\\n\tTITAN_NO_LINE_DIRECTIVES",
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
            }) do
                assert.truthy(makefile:find(contract, 1, true), contract)
            end
            local stdlib_config_start = assert(makefile:find(
                "$(STDLIB_CONFIG_STAMP): FORCE", 1, true))
            local stdlib_config_end = assert(makefile:find(
                "\n$(STDLIB_COMPLETION_STAMP): FORCE",
                stdlib_config_start, true))
            local stdlib_config = makefile:sub(
                stdlib_config_start, stdlib_config_end - 1)
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
                    '"$$abi_dir/titan.so"',
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
                '"$shim_dir/iter.lua" "$shim_dir/gc.lua" "$shim_dir/test.lua"',
                'test_source=$prefix_rel/share/titan/0.22/src/titan/test.titan',
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
                'local math = import "titan.math"',
                'local lua = import "titan.lua"',
                'local iter = import "titan.iter"',
                'local gc = import "titan.gc"',
                'local testing = import "test"',
                'not testing.testing() and not testing.verbose()',
                "local peer = async.run(",
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
                'local iter = require "titan.iter"',
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
            assert.truthy(workflow:find(
                'static_archive="${provider%.so}.a"', 1, true), workflow)
            assert.truthy(workflow:find(
                "PEG/string/math/Lua/iter/GC groups", 1, true), workflow)
            assert.truthy(workflow:find(
                "Run serial, net/SSL/URL/HTTP/OS, and " ..
                    "PEG/string/math/Lua/iter/GC " ..
                    "library tests without coverage", 1, true), workflow)
            assert.truthy(workflow:find(
                "ci_libuv_mode_smoke.sh system", 1, true), workflow)
            assert.truthy(workflow:find(
                "ci_test_groups.sh library-peg-string", 1, true), workflow)
            for _, contract in ipairs({
                'LLHTTP_VERSION: "9.4.3"',
                'OPENSSL_VERSION: "3.5.7"',
                "Cache bundled llhttp source and static build",
                "llhttp-release-v${{ env.LLHTTP_VERSION }}.tar.gz",
                "Cache bundled OpenSSL source and static build",
                "openssl-${{ env.OPENSSL_VERSION }}.tar.gz",
                "Build the pinned private llhttp support",
                "Build the pinned bundled OpenSSL support",
                "run: make -j2 openssl",
                "Canary source-rock installation with system libuv and OpenSSL",
                "LIBUV_MODE=system OPENSSL_MODE=system",
                "OPENSSL_MODE=system",
                "brew install cmake libuv openssl@3 pkgconf",
                "spec/stdlib/ssl_http_sanitizer_spec.lua",
                "streams a fragmented HTTPS request through TLS and llhttp",
                "libssl-dev", "perl",
            }) do
                assert.truthy(workflow:find(contract, 1, true), contract)
            end
            assert.truthy(workflow:find(
                "for module in coroutine uv async timer io fs net ssl url http os peg string math lua iter gc test; do",
                1, true), workflow)
            assert.truthy(workflow:find(
                'share/titan/0.22/src/titan/test.titan', 1, true), workflow)
            assert.truthy(workflow:find(
                "--name='titan.peg GC roots patterns and callbacks across " ..
                "repeated collections'", 1, true), workflow)
            assert.truthy(workflow:find(
                "run_titan_stdlib_tests.sh string", 1, true), workflow)
            assert.truthy(workflow:find(
                "--filter='test_regex_gc_rooting$'", 1, true), workflow)
            assert.truthy(workflow:find(
                "bash spec/support/ci_peg_string_sanitizer_smoke.sh",
                1, true), workflow)

            local groups = read_file("spec/support/ci_test_groups.sh")
            for _, pattern in ipairs({
                "spec/stdlib/ssl*_spec.lua",
                "spec/stdlib/url*_spec.lua",
                "spec/stdlib/http*_spec.lua",
            }) do
                assert.truthy(groups:find(pattern, 1, true), pattern)
            end
            assert.truthy(groups:find(
                "net/SSL/URL/HTTP/OS spec files", 1, true), groups)
            assert.truthy(groups:find("library-peg-string)", 1, true), groups)
            assert.truthy(groups:find(
                "PEG/string/math/Lua/iter/GC spec files without LuaCov",
                1, true), groups)
            assert.truthy(groups:find(
                "Library PEG/string/math/Lua/iter/GC worker",
                1, true), groups)
            assert.falsy(groups:find(
                "PEG/string spec files without LuaCov", 1, true), groups)
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
            local prepare_job = assert(workflow:match(
                "\n  prepare%-linux:(.-)\n  test%-linux%-library:"))
            local library_job = assert(workflow:match(
                "\n  test%-linux%-library:(.-)\n  test%-linux:"))
            local heavy_job = assert(workflow:match(
                "\n  test%-linux:(.-)\n  test%-macos:"))
            local macos_job = assert(workflow:match(
                "\n  test%-macos:(.-)\n  sanitizer:"))
            local sanitizer_job = assert(workflow:match(
                "\n  sanitizer:(.*)"))
            local function count_literal(text, needle)
                local count = 0
                local offset = 1
                while true do
                    local start = text:find(needle, offset, true)
                    if not start then return count end
                    count = count + 1
                    offset = start + #needle
                end
            end
            local function named_step(job, name)
                local marker = "\n      - name: " .. name
                local start = assert(job:find(marker, 1, true), name)
                local finish = job:find(
                    "\n      - name:", start + #marker, true)
                    or (#job + 1)
                return job:sub(start, finish - 1)
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
                assert.equal(1,
                    count_literal(job, "name: " .. upload_name), job)
                assert.equal(1, count_literal(job, "use_oidc: true"), job)
                assert.falsy(job:find("\n%s+token:", 1), job)
            end
            assert_codecov_job(prepare_job, "compiler-core")
            assert_codecov_job(heavy_job, "compiler-heavy")
            assert.equal(1, count_literal(prepare_job,
                "runs-on: ubuntu-24.04"), prepare_job)
            assert.equal(1, count_literal(prepare_job,
                "timeout-minutes: 30"), prepare_job)
            assert.equal(1, count_literal(library_job,
                "needs: prepare-linux"), library_job)
            assert.equal(1, count_literal(heavy_job,
                "needs: prepare-linux"), heavy_job)
            assert.equal(1, count_literal(library_job,
                "runs-on: ubuntu-24.04"), library_job)
            assert.equal(1, count_literal(library_job,
                "timeout-minutes: 30"), library_job)
            assert.equal(1, count_literal(library_job,
                "name: test (ubuntu-24.04, library-uv-fs)"), library_job)
            assert.equal(0, count_literal(library_job, "ubuntu-slim"),
                library_job)
            assert.equal(1, count_literal(heavy_job,
                "runs-on: ubuntu-slim"), heavy_job)
            assert.equal(1, count_literal(library_job,
                "contents: read"), library_job)
            assert.equal(1, count_literal(library_job,
                "ci_test_groups.sh library-uv-fs"), library_job)
            assert.equal(1, count_literal(library_job,
                "actions/download-artifact@v8"), library_job)
            assert.equal(1, count_literal(heavy_job,
                "actions/download-artifact@v8"), heavy_job)
            assert.falsy(library_job:find("id-token: write", 1, true),
                library_job)
            assert.falsy(library_job:find(
                "codecov/codecov-action", 1, true), library_job)
            assert.falsy(library_job:find(
                "ci_test_groups.sh compiler-heavy", 1, true), library_job)
            assert.falsy(heavy_job:find(
                "ci_test_groups.sh library-uv-fs", 1, true), heavy_job)
            assert.equal(1, count_literal(prepare_job,
                'TITAN_EXTRA_CFLAGS: "-O1"'), prepare_job)
            assert.equal(1, count_literal(heavy_job,
                'TITAN_EXTRA_CFLAGS: "-O0"'), heavy_job)
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
            assert.equal(1, count_literal(sanitizer_job,
                    'SANITIZER_FLAGS: "-O0 -g -fsanitize=address,undefined'),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'TITAN_EXTRA_CFLAGS: "-O0 -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'LUA_MYCFLAGS: "-fPIC -O1 -g ' ..
                '-fsanitize=address,undefined'), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "runs-on: ubuntu-24.04"), sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                "timeout-minutes: 30"), sanitizer_job)
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
            assert.truthy(sanitizer_job:find(
                "bash spec/support/ci_sanitizer_capture.sh", 1, true),
                sanitizer_job)
            assert.equal(1, count_literal(sanitizer_job,
                'cmp "$snapshot_provider" "$provider"'), sanitizer_job)
            local capture_script =
                "bash spec/support/ci_sanitizer_capture.sh"
            for _, contract in ipairs({
                {
                    "Build sanitizer-enabled native dependencies",
                    {
                        "make lua",
                        "make libbacktrace",
                        "make libuv",
                        "make llhttp",
                        "make -j2 openssl",
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
                    "Run dense Array runtime sanitizer gate",
                    { ".lua/bin/busted" },
                },
                {
                    "Run native async sanitizer gate (timer-fs)",
                    { "run_titan_stdlib_tests.sh" },
                },
                {
                    "Run native async sanitizer gate (core-uv)",
                    { ".lua/bin/busted", "run_titan_stdlib_tests.sh" },
                },
                {
                    "Run coroutine transfer sanitizer gate",
                    { ".lua/bin/busted" },
                },
                {
                    "Run TLS/HTTP sanitizer boundary",
                    { ".lua/bin/busted" },
                },
                {
                    "Run PEG/regex native sanitizer gate",
                    {
                        ".lua/bin/busted",
                        "run_titan_stdlib_tests.sh",
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
            assert.falsy(workflow:find("CODECOV_TOKEN", 1, true), workflow)
        end)
end)

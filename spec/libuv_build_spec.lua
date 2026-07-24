local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local staticmetadata = require "titan-compiler.staticmetadata"

local PKG_CONFIG = "sh spec/fixtures/libuv/fake-pkg-config.sh"
local UV_MAIN_SOURCE = "titan/uv/uv.titan"
local STDLIB_TYPES_BASELINE =
    "spec/fixtures/stdlib/titan_stdlib_types.lua"
local STDLIB_ROOTS = {
    "titan.coroutine", "titan.uv", "titan.async", "titan.timer",
    "titan.fs", "titan.net", "titan.os",
}
local STDLIB_SHIMS = {
    "titan/coroutine.lua", "titan/uv.lua", "titan/async.lua",
    "titan/timer.lua", "titan/fs.lua", "titan/net.lua", "titan/os.lua",
}
local STDLIB_CONTAINER = "titan.so"
local STDLIB_STATIC_ARCHIVE = "titan.a"
local PHASE8_CALLBACKS = {
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
    "titan_uvshim_timer_cb",
    "titan_uvshim_fs_cb",
}
local PHASE8_PROVIDER_CALLBACKS = {
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
    "titan_uvshim_getaddrinfo_cb",
    "titan_uvshim_connect_cb",
}
local PHASE8_PUBLIC_LIBUV_CALLS = {
    "uv_accept",
    "uv_cancel",
    "uv_close",
    "uv_freeaddrinfo",
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
    "uv_spawn",
    "uv_write",
}
local PHASE8_RETIRED_WRAPPERS = {
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
local PHASE9_RETIRED_HELPERS = {
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
    "titan_uvshim_buf_init",
    "titan_uvshim_buf_init_slice",
    "titan_uvshim_bytes_copy",
    "titan_uvshim_bytes_find",
    "titan_uvshim_bytes_slice_copy",
    "titan_uvshim_text_copy",
    "titan_uvshim_stat_extract",
}
local PHASE10_RETIRED_HELPERS = {
    "titan_uvshim_format_port",
    "titan_uvshim_getaddrinfo_start",
    "titan_uvshim_addrinfo_is_usable",
    "titan_uvshim_addrinfo_count",
    "titan_uvshim_addrinfo_copy",
    "titan_uvshim_address_at",
    "titan_uvshim_tcp_bind",
    "titan_uvshim_tcp_connect_start",
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
    return prefix .. "/lib/titan/0.18/" .. STDLIB_CONTAINER
end

local function installed_stdlib_archive()
    local prefix = assert(prefix_from_cpath(package.cpath),
        "cannot find the active Lua prefix in package.cpath")
    return prefix .. "/lib/titan/0.18/" .. STDLIB_STATIC_ARCHIVE
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
    assert.truthy(ast, err and err.label)
    parsed_sources[path] = ast
    return ast
end

local function public_declarations(path)
    local declarations = {}
    for _, node in ipairs(parsed_source(path)) do
        if not node.islocal then
            local tag = node._tag
            local name
            if tag == "Ast.TopLevelRecord" or tag == "Ast.TopLevelFunc" then
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

local function run_uv_dry_run(mode, host, source)
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

local function source_line_number(source, needle)
    local offset = assert(source:find(needle, 1, true),
        "missing source statement: " .. needle)
    local _, newlines = source:sub(1, offset - 1):gsub("\n", "\n")
    return newlines + 1
end

local function replace_plain(source, old, new)
    local pieces = {}
    local position = 1
    while true do
        local first, last = source:find(old, position, true)
        if not first then
            pieces[#pieces + 1] = source:sub(position)
            return table.concat(pieces)
        end
        pieces[#pieces + 1] = source:sub(position, first - 1)
        pieces[#pieces + 1] = new
        position = last + 1
    end
end

local function prepared_uv_c()
    local path = "titan/uv/uv.c"
    assert.equal("file", lfs.attributes(path, "mode"),
        path .. " must be prepared by the current source-rock build")
    local generated = read_file(path)
    -- The source-only post-install compiles through an absolute --tree,
    -- whereas checkout `make stdlib` uses ".". Normalize only that spelling;
    -- every line number and generated operation remains the prepared output.
    local source_prefix = generated:match(
        '#line %d+ "([^"]*titan/uv/)process%.titan"')
    assert.truthy(source_prefix,
        "prepared titan.uv C has no process.titan source directives")
    if source_prefix ~= "./titan/uv/" then
        generated = replace_plain(
            generated, '"' .. source_prefix, '"./titan/uv/')
    end
    return generated
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

local function generated_function(source, name)
    local position = 1
    local first
    local next_definition
    while position <= #source do
        local newline = source:find("\n", position, true) or (#source + 1)
        local line = source:sub(position, newline - 1)
        local definition = not line:match("^%s") and
            line:find("_titan(", 1, true) and line:match("{%s*$")
        if definition then
            if first then
                next_definition = position
                break
            elseif line:find(name .. "(", 1, true) then
                first = position
            end
        end
        position = newline + 1
    end
    assert.truthy(first, "missing generated function " .. name)
    return source:sub(first, (next_definition or (#source + 1)) - 1)
end

local function matching_c_brace(source, opening)
    assert.equal("{", source:sub(opening, opening))
    local depth = 0
    for position = opening, #source do
        local byte = source:sub(position, position)
        if byte == "{" then
            depth = depth + 1
        elseif byte == "}" then
            depth = depth - 1
            if depth == 0 then return position end
        end
    end
    error("unmatched generated-C brace at byte " .. opening, 0)
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

    it("owns every migrated libuv operation in Titan source",
       function()
        local sources = {}
        for _, path in ipairs(discovered_uv_sources()) do
            sources[path] = read_file(path)
        end
        local runtime = read_file("titan-runtime/titan_uv.c")
        local header = read_file("titan-runtime/titan/uv.h")

        for _, wrapper in ipairs(PHASE8_RETIRED_WRAPPERS) do
            assert.falsy(runtime:find(wrapper, 1, true), wrapper)
            assert.falsy(header:find(wrapper, 1, true), wrapper)
            for path, source in pairs(sources) do
                assert.falsy(source:find(wrapper, 1, true),
                    path .. ": " .. wrapper)
            end
        end
        for _, helper in ipairs(PHASE9_RETIRED_HELPERS) do
            assert.falsy(runtime:find(helper, 1, true), helper)
            assert.falsy(header:find(helper, 1, true), helper)
            for path, source in pairs(sources) do
                assert.falsy(source:find(helper, 1, true),
                    path .. ": " .. helper)
            end
        end
        for _, helper in ipairs(PHASE10_RETIRED_HELPERS) do
            assert.falsy(runtime:find(helper, 1, true), helper)
            assert.falsy(header:find(helper, 1, true), helper)
            for path, source in pairs(sources) do
                assert.falsy(source:find(helper, 1, true),
                    path .. ": " .. helper)
            end
        end

        local all_sources = {}
        for _, path in ipairs(discovered_uv_sources()) do
            all_sources[#all_sources + 1] = sources[path]
        end
        local combined = table.concat(all_sources, "\n")
        for _, function_name in ipairs(PHASE8_PUBLIC_LIBUV_CALLS) do
            assert.truthy(combined:find("libuv." .. function_name, 1, true),
                function_name)
        end

        assert_ordered(sources["titan/uv/file.titan"],
            "link_fs_owner(runtime, owner)",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "lua.lua_settop(L, top)")
        assert_ordered(sources["titan/uv/os.titan"],
            "local status = libuv.uv_signal_init",
            "libuv.uv_handle_set_data(owner.handle, pointer)",
            "owner.metadata.lifecycle = OWNER_ACTIVE",
            "status = libuv.uv_signal_start_oneshot")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local status = libuv.uv_tcp_init",
            "libuv.uv_handle_set_data(tcp.handle, pointer)",
            "tcp.metadata.lifecycle = TCP_INITIALIZED")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local owner, pointer = allocate_write_owner",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "status = libuv.uv_write")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local owner, pointer = allocate_shutdown_owner",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "status = libuv.uv_shutdown")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local service_pointer = format_port(port, service)",
            "local hints: libuv.addrinfo",
            "local owner, pointer = allocate_dns_owner",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "local status = libuv.uv_getaddrinfo")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local copy_length = entry.ai_addrlen as cstring.size_t",
            "local destination = data + copied",
            "cstring.memcpy(destination.bytes, entry.ai_addr, copy_length)")
        assert_ordered(sources["titan/uv/tcp.titan"],
            "local address =\n          address_cell.bytes as const *libuv.sockaddr",
            "local owner, pointer = allocate_connect_owner",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "local status = libuv.uv_tcp_connect")
        assert_ordered(sources["titan/uv/process.titan"],
            "local status = libuv.uv_pipe_init",
            "libuv.uv_handle_set_data(stdin_pipe.handle, stdin_pointer)",
            "stdin_pipe.metadata.lifecycle = PIPE_INITIALIZED",
            "status = libuv.uv_pipe_init",
            "libuv.uv_handle_set_data(stdout_pipe.handle, stdout_pointer)",
            "stdout_pipe.metadata.lifecycle = PIPE_INITIALIZED",
            "status = libuv.uv_pipe_init",
            "libuv.uv_handle_set_data(stderr_pipe.handle, stderr_pointer)",
            "stderr_pipe.metadata.lifecycle = PIPE_INITIALIZED",
            'failed_operation = "process.spawn"',
            "status = libuv.uv_spawn",
            "libuv.uv_handle_set_data(process.handle, process_pointer)",
            "process_control.lifecycle = PROCESS_SPAWNED")
        assert.truthy(sources["titan/uv/uv.titan"]:find(
            'foreign import "string.h"', 1, true))
        assert.truthy(sources["titan/uv/uv.titan"]:find(
            'foreign import "limits.h"', 1, true))
        assert.truthy(sources["titan/uv/os.titan"]:find(
            'foreign import "signal.h"', 1, true))
        assert.truthy(sources["titan/uv/file.titan"]:find(
            'foreign import "sys/stat.h"', 1, true))
        assert.truthy(sources["titan/uv/runtime.titan"]:find(
            "cstring.memcpy", 1, true))
        assert.truthy(sources["titan/uv/runtime.titan"]:find(
            "cstring.memcmp", 1, true))
        assert.truthy(runtime:find(
            "\nint titan_uvshim_ignore_sigpipe_if_default(", 1, true))
        assert.truthy(header:find(
            "int titan_uvshim_ignore_sigpipe_if_default(", 1, true))
        assert.truthy(sources["titan/uv/uv.titan"]:find(
            "shim.titan_uvshim_ignore_sigpipe_if_default()", 1, true))
        assert_ordered(sources["titan/uv/process.titan"],
            "local owner, pointer = allocate_pipe_write_owner",
            "libuv.uv_req_set_data(owner.handle, pointer)",
            "status = libuv.uv_write")
        assert_ordered(sources["titan/uv/task.titan"],
            "owner.metadata.lifecycle = OWNER_ACTIVE",
            "libuv.uv_handle_set_data(owner.handle, pointer)",
            "status = libuv.uv_timer_start")
    end)

    it("emits the migrated validation, aggregate, and submit order in C",
       function()
        local generated = prepared_uv_c()
        local process_source = read_file("titan/uv/process.titan")
        local process_lifecycle_line = source_line_number(process_source,
            "process_control.lifecycle = PROCESS_SPAWNED")
        local spawn_status_line = source_line_number(process_source,
            "local spawn_status = status as integer")

        local process =
            generated_function(generated, "titan_uv_arm_process_spawn_titan")
        assert.match(
            "uv_process_options_t _local_options_%d+ = %{0%};", process)
        assert.match(
            "uv_stdio_container_t _local_stdio_%d+%[3%] = %{0%};",
            process)
        assert_ordered(process,
            "uv_spawn(",
            "uv_handle_set_data(",
            ('#line %d "./titan/uv/process.titan"'):format(
                process_lifecycle_line),
            "setivalue(",
            ('#line %d "./titan/uv/process.titan"'):format(
                spawn_status_line))

        local find =
            generated_function(generated, "titan_uv__bytes_find_titan")
        assert_ordered(find,
            '#line 65 "./titan/uv/runtime.titan"',
            "return _tmp_3;",
            '#line 66 "./titan/uv/runtime.titan"',
            "return _tmp_4;",
            '#line 68 "./titan/uv/runtime.titan"',
            "getstr(_param_haystack)",
            "intop(-, _local_haystack_length_1, _local_needle_length_1)",
            "memcmp(")

        local slice =
            generated_function(generated, "titan_uv__bytes_slice_titan")
        assert_ordered(slice,
            "if((_param_length>0))",
            "getstr(_param_data)",
            "memcpy(")

        local copy_text =
            generated_function(generated, "titan_uv_copy_text_titan")
        assert_ordered(copy_text,
            "if((_local_length_1>0))",
            "memcpy(",
            '#line 283 "./titan/uv/runtime.titan"',
            "_tmp_19[_tmp_20] = _tmp_21;")

        local stream = generated_function(
            generated, "titan_uv_allocate_stream_bytes_titan")
        assert_ordered(stream,
            "UINT_MAX",
            '#line 338 "./titan/uv/runtime.titan"',
            "((lua_Integer)_param_size)")

        local usable =
            generated_function(generated, "titan_uv_usable_address_titan")
        assert.truthy(usable:find(
            "sizeof(struct sockaddr_storage)", 1, true))
        local copy =
            generated_function(generated, "titan_uv_copy_addresses_titan")
        local call = "titan_uv_usable_address_titan(L, _mod"
        local first = assert(copy:find(call, 1, true))
        local second = assert(copy:find(call, first + #call, true))
        local guard = assert(copy:find("if(", second, true))
        local opening = assert(copy:find("{", guard, true))
        local closing = matching_c_brace(copy, opening)
        local cast = assert(copy:find("((size_t)(", second, true))
        local memcpy = assert(copy:find("memcpy(", cast, true))
        assert.is_true(second < guard and guard < cast and cast < memcpy and
            memcpy < closing)

        local dns =
            generated_function(generated, "titan_uv_start_dns_titan")
        assert.match("titan_ffi_char _local_service_%d+%[6%] = %{0%};",
            dns)
        assert.match("struct addrinfo _local_hints_%d+ = %{0%};", dns)
        assert_ordered(dns,
            "titan_uv_format_port_titan(",
            "titan_uv_allocate_dns_owner_titan(",
            "uv_req_set_data(",
            "uv_getaddrinfo(")
    end)

    it("declares and defines every direct callback trampoline", function()
        local runtime = read_file("titan-runtime/titan_uv.c")
        local header = read_file("titan-runtime/titan/uv.h")
        for _, callback in ipairs(PHASE8_CALLBACKS) do
            assert.truthy(header:find(callback .. "(", 1, true), callback)
            assert.truthy(runtime:find("\nvoid " .. callback .. "(", 1, true),
                callback)
            assert.falsy(runtime:find("static void " .. callback .. "(",
                1, true), callback)
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
        for _, callback in ipairs(PHASE8_CALLBACKS) do
            assert.truthy(nm_has_symbol(output, callback), callback)
        end
        for _, wrapper in ipairs(PHASE8_RETIRED_WRAPPERS) do
            assert.falsy(nm_has_symbol(output, wrapper), wrapper)
        end
        for _, helper in ipairs(PHASE9_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper), helper)
        end
        for _, helper in ipairs(PHASE10_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper), helper)
        end

        local logical_object = "titan/uv/uv.o"
        assert.truthy(file_exists(logical_object), logical_object)
        ok, output, why, code = run_argv(tool_argv(
            "NM", "nm", "-u", logical_object))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, callback in ipairs(PHASE8_PROVIDER_CALLBACKS) do
            assert.truthy(nm_has_symbol(output, callback),
                logical_object .. ": " .. callback)
        end
        for _, function_name in ipairs(PHASE8_PUBLIC_LIBUV_CALLS) do
            assert.truthy(nm_has_symbol(output, function_name),
                logical_object .. ": " .. function_name)
        end
        for _, wrapper in ipairs(PHASE8_RETIRED_WRAPPERS) do
            assert.falsy(nm_has_symbol(output, wrapper),
                logical_object .. ": " .. wrapper)
        end
        for _, helper in ipairs(PHASE9_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper),
                logical_object .. ": " .. helper)
        end
        for _, helper in ipairs(PHASE10_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper),
                logical_object .. ": " .. helper)
        end

        local archive = installed_stdlib_archive()
        assert.truthy(file_exists(archive), archive)
        ok, output, why, code = run_argv(tool_argv(
            "NM", "nm", "-u", archive))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        for _, callback in ipairs(PHASE8_PROVIDER_CALLBACKS) do
            assert.truthy(nm_has_symbol(output, callback), callback)
        end
        for _, function_name in ipairs(PHASE8_PUBLIC_LIBUV_CALLS) do
            assert.truthy(nm_has_symbol(output, function_name), function_name)
        end
        for _, wrapper in ipairs(PHASE8_RETIRED_WRAPPERS) do
            assert.falsy(nm_has_symbol(output, wrapper), wrapper)
        end
        for _, helper in ipairs(PHASE9_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper), helper)
        end
        for _, helper in ipairs(PHASE10_RETIRED_HELPERS) do
            assert.falsy(nm_has_symbol(output, helper), helper)
        end
    end)

    it("keeps the reviewed standard-library roots, sources, and shims exact",
       function()
        assert.same(STDLIB_ROOTS, makefile_words("STDLIB_ROOTS"))
        assert.same(STDLIB_SHIMS, makefile_words("STDLIB_SHIMS"))
        assert.same({ STDLIB_CONTAINER },
            makefile_words("STDLIB_CONTAINER"))

        local sources = makefile_words("STDLIB_TITAN_SOURCES")
        local expanded = {}
        for _, source in ipairs(sources) do
            if source == "$(UV_TITAN_SOURCES)" then
                for _, uv_source in ipairs(makefile_words("UV_TITAN_SOURCES")) do
                    expanded[#expanded + 1] = uv_source
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
            "titan/timer.titan", "titan/fs.titan", "titan/net.titan",
            "titan/os.titan",
        }, expanded)
    end)

    it("preserves all seven pre-bundle interfaces inside the combined image",
       function()
        local expected = assert(loadfile(STDLIB_TYPES_BASELINE))()
        assert.equal(7875, #expected.uv)

        local support = require "titan"
        local container = installed_stdlib_container()
        for _, root in ipairs(STDLIB_ROOTS) do
            local name = assert(root:match("^titan%.(.+)$"))
            local types_function, load_error = support._loadlib(
                container, "titan_" .. name .. "_types")
            assert.truthy(types_function, load_error)
            assert.equal(expected[name], assert(types_function()), root)
        end
    end)

    it("keeps every uv export with its semantic contributor", function()
        assert.same({}, public_declarations(UV_MAIN_SOURCE))
        assert.same({
            "uv_file", "_fs_open", "_fs_read", "_fs_write", "_fs_flush",
            "_fs_is_closed", "_fs_close", "_fs_stat", "_fs_mkdir",
            "_fs_unlink", "_fs_rmdir", "_fs_rename", "_fs_list",
        }, public_declarations("titan/uv/file.titan"))
        assert.same({
            "_os_getenv", "_os_setenv", "_os_unsetenv", "_os_cwd",
            "_os_chdir", "_os_homedir", "_os_tmpdir", "_os_hostname",
            "_os_exepath", "_os_pid", "_os_ppid", "_os_wait_signal",
            "_os_signal_name",
        }, public_declarations("titan/uv/os.titan"))
        assert.same({
            "uv_process_t", "_os_process_spawn", "_os_process_wait",
            "_os_process_kill", "_os_process_write_stdin",
            "_os_process_close_stdin", "_os_process_read_stdout",
            "_os_process_read_stderr", "_os_process_read_error_is",
            "_os_communicate",
        }, public_declarations("titan/uv/process.titan"))
        assert.same({
            "Error", "Error.new", "_bytes_find", "_bytes_slice", "_loop",
            "_version",
        }, public_declarations("titan/uv/runtime.titan"))
        assert.same({
            "Cancelled", "Cancelled.new", "uv_timer_t", "Task", "_run",
            "Task:status", "Task:cancel", "Task:join", "_sleep", "_yield",
            "_ticker", "_ticker_tick", "_ticker_close",
        }, public_declarations("titan/uv/task.titan"))
        assert.same({
            "uv_tcp_t", "_net_connect", "_net_listen", "_net_read",
            "_net_read_error_is", "_net_write", "_net_shutdown",
            "_net_accept", "_net_close", "_net_is_closed",
            "_net_eof_error",
        }, public_declarations("titan/uv/tcp.titan"))
    end)

    it("keeps every private uv record with its semantic contributor",
       function()
        assert.same({}, local_record_declarations(UV_MAIN_SOURCE))
        assert.same({
            "FsConstants", "Dirent", "FsStatResult", "FsOperation",
            "FsControl", "uv_fs_t",
        }, local_record_declarations("titan/uv/file.titan"))
        assert.same({
            "SignalSpec", "SignalControl", "uv_signal_t",
        }, local_record_declarations("titan/uv/os.titan"))
        assert.same({
            "ProcessControl", "PipeControl", "ProcessOperation",
            "ProcessRequestControl", "ProcessExitResult", "HelperGroup",
            "uv_pipe_t", "uv_pipe_write_t", "uv_process_grace_t",
        }, local_record_declarations("titan/uv/process.titan"))
        assert.same({
            "Loop", "Runtime", "Bytes", "SizedBytes", "Text", "Buffer",
        }, local_record_declarations("titan/uv/runtime.titan"))
        assert.same({
            "TimerControl", "DriveControl", "Request", "TickerState",
        }, local_record_declarations("titan/uv/task.titan"))
        assert.same({
            "AddressList", "NetOperation", "NetRequestControl",
            "TcpControl", "uv_getaddrinfo_t", "uv_connect_t", "uv_write_t",
            "uv_shutdown_t",
        }, local_record_declarations("titan/uv/tcp.titan"))
    end)

    it("keeps the private FS constants instance beside its record", function()
        local main_ast = parsed_source(UV_MAIN_SOURCE)
        for _, node in ipairs(main_ast) do
            assert.falsy(node._tag == "Ast.TopLevelVar" and
                node.decl.name == "FS")
        end

        local file_ast = parsed_source("titan/uv/file.titan")
        local record_index, fs_index
        for index, node in ipairs(file_ast) do
            if node._tag == "Ast.TopLevelRecord" and
               node.name == "FsConstants" then
                record_index = index
            elseif node._tag == "Ast.TopLevelVar" and
                   node.decl.name == "FS" then
                fs_index = index
                assert.is_true(node.islocal)
            end
        end
        assert.truthy(record_index)
        assert.equal(record_index + 2, fs_index)
        local constructor = file_ast[record_index + 1]
        assert.equal("Ast.TopLevelStatic", constructor._tag)
        assert.equal("FsConstants", constructor.class)
        assert.equal("new", constructor.name)
        assert.is_true(constructor._record_constructor)
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
            "$(LIBUV_EXTRA_OBJECTS) $(TITANLIB_O)",
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
            "$(CORO_O)", "$(UV_O)",
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

    it("repairs a newer runtime archive with an extra member", function()
        local root = make_temp_dir()
        local archive = root .. "/libtitan.a"
        local config = root .. "/archive-build-config"
        local source = root .. "/archive-fixture.c"
        local objects = {
            root .. "/titan.o",
            root .. "/titan_coro.o",
            root .. "/titan_uv.o",
        }
        local make_archive = {
            "make", "--no-print-directory", "-s",
            "TITAN_RUNTIME_OBJECTS=" .. table.concat(objects, " "),
            "TITAN_RUNTIME_LIB=" .. archive,
            "RUNTIME_ARCHIVE_CONFIG=" .. config,
            archive,
        }
        local stale = root .. "/stale.o"
        local ran, run_error = pcall(function()
            compile_archive_objects(source, objects)

            local ok, output, why, code = run_argv(make_archive)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            write_file(stale, "stale archive member\n")
            ok, output, why, code = run_argv({ "ar", "q", archive, stale })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            local repaired, repair_output, repair_why, repair_code =
                run_argv(make_archive)
            assert.truthy(repaired, repair_output .. "\n(" ..
                tostring(repair_why) .. ", " ..
                tostring(repair_code) .. ")")
            ok, output, why, code = run_argv({ "ar", "t", archive })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.same({ "titan.o", "titan_coro.o", "titan_uv.o" },
                archive_object_members(output))
        end)
        for _, path in ipairs({
            stale, archive, config, config .. ".tmp", source,
            objects[1], objects[2], objects[3],
        }) do
            os.remove(path)
        end
        assert.truthy(lfs.rmdir(root))
        if not ran then error(run_error, 0) end
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
            "-X titan-runtime/titanlib.o libuv-build/libuv.a"), command)
        assert.falsy(command:find("titan_uv.o", 1, true), command)
        assert.truthy(command:find([[CC='ccache cc']], 1, true), command)
        assert.truthy(command:find([[AR='review-ar']], 1, true), command)
        assert.truthy(command:find([[RANLIB='review-ranlib']], 1, true),
            command)
        assert.truthy(command:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -Ilibuv-v1.52.1/include -D_GNU_SOURCE']],
            1, true), command)
        assert.truthy(command:find(
            [[TITAN_EXTRA_CFLAGS='-DUSER_C=1 -fno-strict-aliasing']],
            1, true), command)
        local bundled_flags =
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread -lrt']]
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
            "-X titan-runtime/titanlib.o"), command)
        assert.falsy(command:find("titan_uv.o", 1, true), command)
        assert.falsy(command:find("libuv-build/libuv.a", 1, true), command)
        assert.truthy(command:find(
            [[TITAN_EXTRA_CPPFLAGS='-DUSER_CPP=1 -I/opt/libuv/include -DUV_FAKE_PKG=1 -D_GNU_SOURCE']],
            1, true), command)
        local system_flags =
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -L/opt/libuv/lib -luv -pthread -ldl -lrt']]
        assert.equal(1, count_plain(command, system_flags), command)
        assert.equal(1, count_plain(command, " -luv "), command)

        ok, output, why, code = run_uv_dry_run("bundled", "Darwin")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        command = stdlib_command(output)
        assert.equal(1, count_plain(command,
            [[-X titan-runtime/titanlib.o libuv-build/libuv.a]]),
            command)
        assert.equal(1, count_plain(command,
            [[TITAN_EXTRA_LDFLAGS='-Wl,user-link -lpthread']]),
            command)
    end)

    it("rebuilds the same provider pair when any reviewed source changes",
       function()
        local sources = {
            "titan/coroutine.titan", "titan/async.titan",
            "titan/timer.titan", "titan/fs.titan", "titan/net.titan",
            "titan/os.titan",
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
                "-X titan-runtime/titanlib.o libuv-build/libuv.a",
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
        local fake_titanc = root .. "/fake-titanc"
        local build_log = root .. "/build.log"

        local payload = assert(staticmetadata.render(
            "fixture.module", "0.18", "{}"))
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
                expected_abi = "0.18",
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
                "$(LIBUV_EXTRA_OBJECTS)",
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
            "for output in $(STDLIB_PROVIDER_OUTPUTS) $(STDLIB_SHIMS)",
            "STDLIB_UV_LDFLAGS=$(STDLIB_UV_LDFLAGS)",
            "validate_archive()",
            "rm -f $(STDLIB_PROVIDER_OUTPUTS)",
            "rm -f $(STDLIB_SHIMS)",
            "rm -rf $(STDLIB_CONTAINER).dSYM",
            "examples/utils.a examples/artisanal.a examples/sdl_quit.a",
            "testfiles/selection_sort.a testfiles/sieve.a",
        }) do
            assert.truthy(makefile:find(contract, 1, true), contract)
        end
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
        }) do
            assert.truthy(snapshot:find(contract, 1, true), contract)
        end

        local mode_smoke =
            read_file("spec/support/ci_libuv_mode_smoke.sh")
        for _, contract in ipairs({
            'local async = import "async"',
            'local timer = import "timer"',
            'local fs = import "fs"',
            'local net = import "net"',
            'local system = import "os"',
            "local peer = async.run(",
            "timer.sleep(0)",
            "fs.write_file(marker,",
            "local metadata = fs.stat(marker)",
            "system.communicate(process_child, process_args, process_payload)",
            'net.connect("127.0.0.1", port)',
            "system.exepath()",
            '"$LIBUV_PKG_CONFIG" --static --libs libuv',
            '"$libdir/libuv.a" "$libdir/libuv_a.a"',
            "TITAN_SYSTEM_STATIC_LIBUV_ARCHIVE",
            "must name an absolute regular nonlink file",
            "driver.compile_archive_validation_image(",
            "build_static_system_provider_image",
            'if ! defines_uv_version "$static_provider"',
            'if defines_uv_version "$STATIC_ARCHIVE"',
            "build_and_run_static_titan system-static",
            '"$executable" "$marker" "$TITAN_PROCESS_SMOKE_CHILD"',
            'if ! defines_uv_version "$executable"',
            'if defines_uv_version "$STATIC_ARCHIVE"',
        }) do
            assert.truthy(mode_smoke:find(contract, 1, true), contract)
        end

        local workflow = read_file(".github/workflows/ci.yml")
        assert.truthy(workflow:find(
            'static_archive="${provider%.so}.a"', 1, true), workflow)
        assert.truthy(workflow:find(
            "ci_libuv_mode_smoke.sh system", 1, true), workflow)
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
            "\n  prepare%-linux:(.-)\n  test%-linux:"))
        local heavy_job = assert(workflow:match(
            "\n  test%-linux:(.-)\n  test%-macos:"))
        local macos_job = assert(workflow:match(
            "\n  test%-macos:(.-)\n  sanitizer:"))
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
        assert.falsy(workflow:find("CODECOV_TOKEN", 1, true), workflow)
    end)
end)

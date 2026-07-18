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

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

local function installed_stdlib_container()
    local prefix = assert(prefix_from_cpath(package.cpath),
        "cannot find the active Lua prefix in package.cpath")
    return prefix .. "/lib/titan/0.16/" .. STDLIB_CONTAINER
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

local function public_declarations(path)
    local ast, err = parser.parse(path, read_file(path))
    assert.truthy(ast, err and err.label)
    local declarations = {}
    for _, node in ipairs(ast) do
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
    local ast, err = parser.parse(path, read_file(path))
    assert.truthy(ast, err and err.label)
    local records = {}
    for _, node in ipairs(ast) do
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
        local main_ast = assert(parser.parse(UV_MAIN_SOURCE,
            read_file(UV_MAIN_SOURCE)))
        for _, node in ipairs(main_ast) do
            assert.falsy(node._tag == "Ast.TopLevelVar" and
                node.decl.name == "FS")
        end

        local file_ast = assert(parser.parse("titan/uv/file.titan",
            read_file("titan/uv/file.titan")))
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
            "fixture.module", "0.16", "{}"))
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
                expected_abi = "0.16",
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

    it("owns the provider pair through one stamp and exact cleanup",
       function()
        local makefile = read_file("Makefile")
        for _, contract in ipairs({
            "STDLIB_STATIC_ARCHIVE := " .. STDLIB_STATIC_ARCHIVE,
            "STDLIB_PROVIDER_OUTPUTS := $(STDLIB_CONTAINER) " ..
                "$(STDLIB_STATIC_ARCHIVE)",
            "STDLIB_EXTRA_OBJECTS := $(TITANLIB_O) " ..
                "$(LIBUV_EXTRA_OBJECTS)",
            "$(STDLIB_COMPLETION_STAMP): FORCE $(STDLIB_TITAN_SOURCES)",
            "$(STDLIB_CONFIG_STAMP): FORCE",
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
        assert.falsy(workflow:find("CODECOV_TOKEN", 1, true), workflow)
    end)
end)

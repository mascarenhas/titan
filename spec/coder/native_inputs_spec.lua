local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local incremental = require "titan-compiler.incremental"
local native = require "titan-compiler.nativeinputs"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local process = require "titan-compiler.process"
local temporary = require "spec.support.temporary"

local function context() return { io = compiler_io.new_sync() } end
local function write(path, bytes) assert(context().io:write_file(path, bytes)) end
local function remove(path)
    local kind = lfs.symlinkattributes(path, "mode")
    if kind == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif kind then assert(os.remove(path)) end
end

describe("normalized native inputs", function()
    it("orders defaults before environment before CLI and retains repeated flags", function()
        local normalized = assert(native.normalize({
            defaults = { cppflags = { "-DVALUE=0" }, cflags = { "-O0" }, ldflags = { "-Wl,default" } },
            env = { TITAN_EXTRA_CPPFLAGS = { "-DVALUE=1" }, TITAN_EXTRA_CFLAGS = { "-O1" },
                TITAN_EXTRA_LDFLAGS = { "-Lambient" } },
            cli = { ordered = {
                { kind = "define", value = "VALUE=2" }, { kind = "cflag", value = "-O2" },
                { kind = "include", value = "space Ω/include" }, { kind = "define", value = "VALUE=3" },
                { kind = "ldflag", value = "-Wl,--start-group" }, { kind = "library", value = "a,b" },
                { kind = "library", value = "a" }, { kind = "ldflag", value = "-Wl,--end-group" },
                { kind = "libdir", value = "space Ω/lib" },
            }, c_sources = { "first.c", "second.c" }, exe = "outside/bin/my app" },
        }))
        assert.same({ "-DVALUE=0", "-O0", "-DVALUE=1", "-O1", "-DVALUE=2", "-O2",
            "-Ispace Ω/include", "-DVALUE=3" }, normalized.compile_argv)
        assert.same({ "-Wl,default", "-Lambient", "-Wl,--start-group", "-la", "-lb", "-la",
            "-Wl,--end-group", "-Lspace Ω/lib" }, normalized.link_argv)
        assert.same({ "a", "b", "a" }, normalized.libraries)
        assert.same({ "first.c", "second.c" }, normalized.c_sources)
        assert.equal("outside/bin/my app", normalized.exe)
    end)

    it("tokenizes ambient strings once and keeps an explicit argument indivisible", function()
        local normalized = assert(native.normalize({ env = { TITAN_EXTRA_CPPFLAGS = '-I"space Ω/include"' },
            cli = { ordered = { { kind = "cflag", value = "-DNAME=one two" } } } }))
        assert.same({ "-Ispace Ω/include", "-DNAME=one two" }, normalized.compile_argv)
        assert.is_nil(native.normalize({ env = { TITAN_EXTRA_CFLAGS = "'unterminated" } }))
    end)

    it("separates pure link changes from compilation policy", function()
        local before = assert(native.normalize({ cli = { ordered = { { kind = "include", value = "inc" } } } }))
        local after = assert(native.normalize({ cli = { ordered = { { kind = "include", value = "inc" },
            { kind = "libdir", value = "lib" }, { kind = "library", value = "m" },
            { kind = "ldflag", value = "-pthread" } }, exe = "other" } }))
        assert.same(before.compile_argv, after.compile_argv)
        assert.same(before.cppflags, after.cppflags)
        assert.same(before.cflags, after.cflags)
        assert.not_same(before.link_argv, after.link_argv)
    end)
end)

describe("certified app-owned C sources", function()
    local root, source, header, phases
    local function build(extra, incremental_mode, sources, on_run, overrides)
        local ctx = context()
        local argv = assert(cdriver.split_shell_words(driver.CC))
        for _, flag in ipairs({ "-std=c99", "-fPIC", "-I" .. root }) do argv[#argv + 1] = flag end
        for _, flag in ipairs(extra or {}) do argv[#argv + 1] = flag end
        local request = { sources = sources or { source }, output_root = root,
            compile_argv = argv, toolchain = "test-selected-toolchain", incremental = incremental_mode ~= false,
            run = function(command, phase)
                phases[#phases + 1] = phase
                local result = ctx.io:run(command)
                if on_run then on_run(phase, result) end
                return result
            end,
        }
        for key, value in pairs(overrides or {}) do request[key] = value end
        return native.compile(ctx, request)
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        source, header, phases = root .. "/helper Ω.c", root .. "/value.h", {}
        write(header, "#define VALUE 41\n")
        write(source, '#include "value.h"\nint helper(void) { return VALUE + 1; }\n')
    end)
    after_each(function() remove(root) end)

    it("preprocesses every invocation but compiles an unchanged node only once", function()
        local first = assert(build())[1]
        assert.is_false(first.hit)
        local old = os.time() - 60
        assert(lfs.touch(first.path, old, old))
        phases = {}
        local second = assert(build())[1]
        assert.is_true(second.hit)
        assert.equal(first.path, second.path)
        assert.equal(first.identity, second.identity)
        assert.equal(old, lfs.attributes(second.path, "modification"))
        assert.same({ "native-preprocess" }, phases)
    end)

    it("retires invocation scratch after publication, hits and native failures", function()
        local function clean()
            for name in lfs.dir(root .. "/.native") do
                if name ~= "." and name ~= ".." then
                    assert.truthy(name:match("^[0-9a-f]+%.o$") or name:match("^[0-9a-f]+%.record$"),
                        "retained native scratch: " .. name)
                end
            end
        end
        local first = assert(build())[1]
        clean()
        assert.is_true(assert(build())[1].hit)
        clean()
        write(source, "int helper(void) { return invalid; }\n")
        assert.is_nil(build())
        clean()
        write(source, '#include "missing_native_input.h"\n')
        assert.is_nil(build())
        clean()
        assert.equal("file", lfs.attributes(first.path, "mode"))
        assert.equal("file", lfs.attributes(first.path:gsub("%.o$", ".record"), "mode"))
    end)

    it("retires preprocessing scratch before propagating cancellation", function()
        local signal = {}
        local ok, err = pcall(function()
            build(nil, true, nil, function(phase)
                if phase == "native-preprocess" then error(signal, 0) end
            end)
        end)
        assert.is_false(ok)
        assert.equal(signal, err)
        for name in lfs.dir(root .. "/.native") do
            assert.truthy(name == "." or name == "..", "retained cancelled native scratch: " .. name)
        end
    end)

    it("recompiles changed source and transitive header bytes with preserved mtimes", function()
        local first = assert(build())[1]
        local old = lfs.attributes(header, "modification")
        write(header, "#define VALUE 42\n")
        assert(lfs.touch(header, old, old))
        local second = assert(build())[1]
        assert.is_false(second.hit)
        assert.not_equal(first.identity, second.identity)
        old = lfs.attributes(source, "modification")
        write(source, '#include "value.h"\nint helper(void) { return VALUE + 2; }\n')
        assert(lfs.touch(source, old, old))
        assert.is_false(assert(build())[1].hit)
    end)

    it("certifies forced headers and computed includes using native preprocessing", function()
        write(root .. "/forced.h", '#define HEADER "value.h"\n')
        write(source, '#include HEADER\nint helper(void) { return VALUE; }\n')
        local first = assert(build({ "-include", root .. "/forced.h" }))[1]
        assert.is_true(assert(build({ "-include", root .. "/forced.h" }))[1].hit)
        write(root .. "/other.h", "#define VALUE 84\n")
        write(root .. "/forced.h", '#define HEADER "other.h"\n')
        local changed = assert(build({ "-include", root .. "/forced.h" }))[1]
        assert.is_false(changed.hit)
        assert.not_equal(first.identity, changed.identity)
    end)

    it("detects presence-query changes without a previously positive dependency", function()
        write(source, [[
#if __has_include("optional.h")
int helper(void) { return 1; }
#else
int helper(void) { return 2; }
#endif
]])
        local first = assert(build())[1]
        write(root .. "/optional.h", "/* presence alone changes code */\n")
        local second = assert(build())[1]
        assert.is_false(second.hit)
        assert.not_equal(first.identity, second.identity)
        assert(os.remove(root .. "/optional.h"))
        assert.is_false(assert(build())[1].hit)
    end)

    it("deduplicates canonical aliases while preserving first-source order", function()
        local second = root .. "/second.c"
        write(second, "int second(void) { return 2; }\n")
        local objects = assert(build(nil, true, { source, second, source, root .. "/./helper Ω.c" }))
        assert.equal(2, #objects)
        assert.equal(source, objects[1].source)
        assert.equal(second, objects[2].source)
        if not platform.windows then
            assert(lfs.link(source, root .. "/alias.c", true))
            assert.equal(1, #assert(build(nil, true, { source, root .. "/alias.c" })))
        end
    end)

    it("uses distinct deterministic identities for same-basename sources", function()
        assert(lfs.mkdir(root .. "/other"))
        local second = root .. "/other/helper Ω.c"
        write(second, "int other(void) { return 7; }\n")
        local objects = assert(build(nil, true, { source, second }))
        assert.not_equal(objects[1].path, objects[2].path)
        local again = assert(build(nil, true, { source, second }))
        assert.equal(objects[1].path, again[1].path)
        assert.equal(objects[2].path, again[2].path)
    end)

    it("repairs missing and tampered objects and invalid sidecars", function()
        local first = assert(build())[1]
        write(first.path, "not an object")
        assert.is_false(assert(build())[1].hit)
        assert(os.remove(first.path))
        assert.is_false(assert(build())[1].hit)
        write(first.path:gsub("%.o$", ".record"), "untrusted executable text")
        assert.is_false(assert(build())[1].hit)
    end)

    it("forces native compilation for a non-incremental request", function()
        assert(build())
        phases = {}
        assert.is_false(assert(build(nil, false))[1].hit)
        assert.same({ "native-preprocess", "native-compile" }, phases)
    end)

    for _, publisher in ipairs({ "native", "coordinator" }) do
        it("builds an uncertified Windows toolchain through " .. publisher .. " publication without accepting a record", function()
            if not platform.windows then pending("Windows toolchain-selection uncertainty"); return end
            local first = assert(build())[1]
            local sidecar = first.path:gsub("%.o$", ".record")
            assert.equal("file", lfs.attributes(sidecar, "mode"))
            local options = { toolchain = {
                compiler_argv = assert(cdriver.split_shell_words(driver.CC)),
                preprocessor_identity = "#define __TEST_COMPILER__ 1\n",
                banner = "opaque native compiler",
                stage_tools = { root .. "/opaque-stage" },
            } }
            local publications = 0
            if publisher == "coordinator" then
                local filesystem = context().io
                options.publish = function(publication)
                    publications = publications + 1
                    assert.is_false(publication.cacheable)
                    assert.is_nil(publication.metadata)
                    for _, path in ipairs({ publication.object, publication.record }) do
                        if filesystem:lstat(path) then assert(filesystem:unlink(path)) end
                    end
                    return filesystem:rename(publication.staged, publication.object)
                end
            end
            for _ = 1, 2 do
                phases = {}
                local object = assert(build(nil, true, nil, nil, options))[1]
                assert.equal(first.path, object.path)
                assert.is_false(object.cacheable)
                assert.is_false(object.hit)
                assert.same({ "native-preprocess", "native-compile" }, phases)
                assert.equal("file", lfs.attributes(object.path, "mode"))
                assert.is_nil(lfs.symlinkattributes(sidecar))
            end
            assert.equal(publisher == "coordinator" and 2 or 0, publications)
        end)
    end

    it("preserves toolchain metadata I/O failures and cancellation before native compilation", function()
        for _, failure in ipairs({ "toolchain metadata failed", {} }) do
            local ctx = context()
            function ctx.io:stat()
                if type(failure) == "string" then return nil, failure end
                error(failure, 0)
            end
            ctx.io.lstat = ctx.io.stat
            function ctx.io:run() error("failed toolchain metadata must not start compilation") end
            local request = { sources = { source }, output_root = root,
                compile_argv = { "selected-compiler" }, incremental = true,
                toolchain = { compiler_argv = { "selected-compiler" }, stage_tools = {},
                    banner = "clang version 22.1.8", preprocessor_identity = "#define __clang__ 1\n" } }
            if type(failure) == "string" then
                local objects, err = native.compile(ctx, request)
                assert.is_nil(objects)
                assert.matches(failure, err, 1, true)
            else
                local ok, err = pcall(native.compile, ctx, request)
                assert.is_false(ok)
                assert.equal(failure, err)
            end
        end
    end)

    it("leaves no accepted new record after a compiler failure", function()
        local first = assert(build())[1]
        write(source, "int helper(void) { return invalid; }\n")
        local objects = build()
        assert.is_nil(objects)
        write(source, "int helper(void) { return 7; }\n")
        assert.is_false(assert(build())[1].hit)
        assert.equal(first.path, assert(build())[1].path)
    end)

    it("rejects an observed header edit during native compilation", function()
        local changed = false
        local objects, err = build(nil, true, nil, function(phase)
            if phase == "native-compile" then
                changed = true
                write(header, "#define VALUE 99\n")
            end
        end)
        assert.is_true(changed)
        assert.is_nil(objects)
        assert.matches("native dependency changed during compilation", err, 1, true)
        local accepted = assert(build())[1]
        assert.is_false(accepted.hit)
    end)
end)

describe("opaque native C policy", function()
    it("does not reuse an object whose compiler options come from a response file", function()
        local root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        local ok, err = pcall(function()
            write(root .. "/helper.c", "int helper(void) { return VALUE; }\n")
            write(root .. "/flags", "-DVALUE=1\n")
            local command = assert(cdriver.split_shell_words(driver.CC))
            command[#command + 1] = "@" .. root .. "/flags"
            local request = { sources = { root .. "/helper.c" }, output_root = root,
                compile_argv = command, toolchain = "selected-toolchain", incremental = true }
            local first = assert(native.compile(context(), request))[1]
            local second = assert(native.compile(context(), request))[1]
            assert.is_false(first.cacheable)
            assert.is_false(second.hit)
            write(root .. "/flags", "-DVALUE=2\n")
            local third = assert(native.compile(context(), request))[1]
            assert.is_false(third.hit)
            assert.not_equal(first.identity, third.identity)
        end)
        remove(root)
        assert.is_true(ok, tostring(err))
    end)
end)

describe("native C object path CLI", function()
    local root, sources, first, second, prefix, repository
    local function read(path) return assert(context().io:read_file(path)) end
    local function invoke(arguments, environment)
        local argv = {
            platform.windows and "env.exe" or "env",
            "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1",
            "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. prefix,
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
            "TITAN_EXTRA_LDFLAGS=",
        }
        for name, value in pairs(environment or {}) do argv[#argv + 1] = name .. "=" .. value end
        for _, value in ipairs({
            prefix .. "/bin/lua" .. (platform.windows and ".exe" or ""), "-E", "-e",
            string.format("package.path=%q..package.path; package.cpath=%q..package.cpath",
                repository .. "/?.lua;" .. repository .. "/?/init.lua;",
                repository .. "/titan-runtime/bootstrap/?" ..
                    (platform.windows and ".dll" or ".so") .. ";"),
            repository .. "/titanc",
        }) do argv[#argv + 1] = value end
        for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
        local stdout, stderr = root .. "/stdout", root .. "/stderr"
        local batch = process.new_batch()
        local child, err = batch:spawn(argv, stdout, stderr, 1)
        if not child then
            batch:close()
            error(err, 0)
        end
        local ok, why, status = child:wait()
        assert(batch:close())
        return { ok = ok == true, why = why, status = status,
            stdout = read(stdout):gsub("\r\n", "\n"),
            stderr = read(stderr):gsub("\r\n", "\n") }
    end
    local function objects(output, arguments)
        local argv = { "-c", "--incremental", "--print-c-objects", "-v", "--output", output }
        for _, source in ipairs(arguments) do
            argv[#argv + 1] = "--c-source"
            argv[#argv + 1] = source
        end
        local result = invoke(argv)
        assert.is_true(result.ok, result.stderr)
        assert.equal("exit", result.why, result.stderr)
        assert.equal(0, result.status, result.stderr)
        local paths = {}
        for line in result.stdout:gmatch("([^\n]+)\n") do
            assert.is_true(platform.is_absolute(line), result.stdout)
            assert.matches("%.o$", line)
            assert.equal("file", lfs.attributes(line, "mode"))
            paths[#paths + 1] = line
        end
        assert.equal(table.concat(paths, "\n") .. "\n", result.stdout)
        return paths, result
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); assert(lfs.mkdir(root))
        root = assert(context().io:realpath(root))
        sources = root .. "/C sources Ω"
        assert(lfs.mkdir(sources))
        first, second = sources .. "/first helper.c", sources .. "/second helper Ω.c"
        write(first, "int first_helper(void) { return 17; }\n")
        write(second, "int second_helper(void) { return 29; }\n")
        prefix = require("spec.support.installed_prefix").active()
        repository = assert(lfs.currentdir())
        if platform.windows then repository = assert(platform.path.normalize(repository)) end
    end)
    after_each(function() remove(root) end)

    it("prints current returned paths in argument order and preserves duplicates across warm builds", function()
        local output = root .. "/build objects Ω"
        assert(lfs.mkdir(output))
        assert(lfs.mkdir(output .. "/.native"))
        local stale = output .. "/.native/unrelated-stale.o"
        write(stale, "unrelated retained object\n")
        local arguments = { first, second, first, sources .. "/./first helper.c" }
        local paths, cold = objects(output, arguments)
        assert.equal(4, #paths)
        assert.not_equal(paths[1], paths[2])
        assert.same({ paths[1], paths[2], paths[1], paths[1] }, paths)
        assert.matches("Titan native miss " .. first, cold.stderr, 1, true)
        assert.matches("Titan native miss " .. second, cold.stderr, 1, true)
        for _, path in ipairs(paths) do assert.not_equal(stale, path) end
        assert.equal("unrelated retained object\n", read(stale))

        local sentinel, before = 946684800, {}
        for _, path in ipairs({ paths[1], paths[2], stale }) do
            assert(lfs.touch(path, sentinel, sentinel))
            before[path] = { bytes = read(path), modified = assert(lfs.attributes(path)).modification }
        end
        local warm_paths, warm = objects(output, arguments)
        assert.same(paths, warm_paths)
        assert.matches("Titan native hit " .. first, warm.stderr, 1, true)
        assert.matches("Titan native hit " .. second, warm.stderr, 1, true)
        assert.is_nil(warm.stderr:find("Titan native miss ", 1, true), warm.stderr)
        for line in warm.stderr:gmatch("[^\n]+") do
            local command = cdriver.split_shell_words(line)
            for _, argument in ipairs(command or {}) do
                assert.not_equal("-c", argument, "native compilation during warm reuse: " .. line)
            end
        end
        for path, snapshot in pairs(before) do
            assert.equal(snapshot.bytes, read(path))
            assert.equal(snapshot.modified, assert(lfs.attributes(path)).modification)
        end

        -- Bind each printed slot to its requested source without predicting
        -- the compiler's object naming scheme or discovering it by glob.
        local first_only = objects(output, { first })
        local second_only = objects(output, { second })
        assert.same({ paths[1] }, first_only)
        assert.same({ paths[2] }, second_only)
        assert.equal("unrelated retained object\n", read(stale))
    end)

    for _, kind in ipairs({ "C-only", "mixed" }) do
        it("builds an uncertified Windows compiler prefix in " .. kind .. " mode without reuse", function()
            if not platform.windows then pending("Windows compiler-prefix uncertainty"); return end
            local compiler = assert(cdriver.split_shell_words(driver.CC))
            if compiler[1] == "exec" then table.remove(compiler, 1) end
            local identity, admitted = incremental.physical_executable(context(), compiler)
            assert.truthy(identity, admitted)
            compiler[1] = admitted
            local wrapper, wrapper_source = root .. "/ccache.exe", root .. "/compiler-prefix.c"
            write(wrapper_source, [[
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
int wmain(int argc, wchar_t **argv) {
    if (argc < 2) return 126;
    const wchar_t *events = _wgetenv(L"TITAN_TEST_CC_EVENTS");
    if (!events) return 125;
    FILE *stream = _wfopen(events, L"ab");
    if (!stream) return 125;
    int phase = 'L';
    for (int i = 2; i < argc; ++i) {
        if (wcscmp(argv[i], L"-E") == 0) phase = 'P';
        if (wcscmp(argv[i], L"-c") == 0) { phase = 'C'; break; }
        if (wcscmp(argv[i], L"-###") == 0) { phase = 'Q'; break; }
    }
    int logged = fputc(phase, stream) != EOF && fputc('\n', stream) != EOF;
    if (fclose(stream) != 0 || !logged) return 125;

    /* Preserve the actual UTF-16 argument quoting supplied by libuv; remove
       only this executable's argv[0], whose path cannot contain a quote. */
    const wchar_t *command = GetCommandLineW();
    while (*command == L' ' || *command == L'\t') ++command;
    if (*command == L'"') {
        ++command;
        while (*command && *command != L'"') ++command;
        if (*command) ++command;
    } else {
        while (*command && *command != L' ' && *command != L'\t') ++command;
    }
    while (*command == L' ' || *command == L'\t') ++command;
    wchar_t *child_command = _wcsdup(command);
    if (!child_command) return 125;
    STARTUPINFOW startup;
    GetStartupInfoW(&startup);
    startup.cb = sizeof(startup);
    startup.dwFlags |= STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION child;
    BOOL started = CreateProcessW(argv[1], child_command, NULL, NULL, TRUE, 0,
        NULL, NULL, &startup, &child);
    free(child_command);
    if (!started) return 126;
    CloseHandle(child.hThread);
    DWORD status = 126;
    BOOL finished = WaitForSingleObject(child.hProcess, INFINITE) == WAIT_OBJECT_0 &&
        GetExitCodeProcess(child.hProcess, &status);
    CloseHandle(child.hProcess);
    return finished ? (int)status : 126;
}
]])
            local command = { table.unpack(compiler) }
            for _, word in ipairs({ "-std=c99", "-O0", "-fno-lto", "-municode", wrapper_source, "-o", wrapper }) do
                command[#command + 1] = word
            end
            local built = context().io:run(command)
            assert.is_true(built.started and built.ok, built.output or built.diagnostic)
            assert.equal("MZ", read(wrapper):sub(1, 2))
            local words, quoted = { wrapper }, {}
            for _, word in ipairs(compiler) do words[#words + 1] = word end
            for _, word in ipairs(words) do quoted[#quoted + 1] = string.format("%q", word) end
            local configured = table.concat(quoted, " ")
            assert.same(words, assert(cdriver.split_shell_words(configured)))
            local events, output = root .. "/compiler-events", root .. "/uncertified build"
            local environment = { CC = configured, TITAN_TEST_CC_EVENTS = events }
            local arguments = { "--incremental", "-v", "--jobs", kind == "mixed" and "2" or "1",
                "--output", output, "--c-source", first }
            local executable
            if kind == "C-only" then
                arguments[#arguments + 1], arguments[#arguments + 2] = "-c", "--print-c-objects"
            else
                write(root .. "/first_helper.h", "int first_helper(void);\n")
                write(root .. "/uncertified_dep.titan", [[
foreign import "first_helper.h"
local function native_value(): integer
    return ffi.first_helper() - 17
end
]])
                write(root .. "/uncertified_main.titan", [[
local dependency = import "uncertified_dep.titan"
function main(args: {string}): integer
    return dependency.native_value()
end
]])
                executable = root .. "/uncertified-program.exe"
                for _, word in ipairs({ "--tree", root, "--exe", executable, "uncertified_main" }) do
                    arguments[#arguments + 1] = word
                end
            end
            local function assert_staging_retired(directory)
                for name in lfs.dir(directory) do
                    if name ~= "." and name ~= ".." then
                        local filename = directory .. "/" .. name
                        assert.is_nil(name:find(".stage.tmp.", 1, true),
                            "retained Windows image staging: " .. filename)
                        if lfs.symlinkattributes(filename, "mode") == "directory" then
                            assert_staging_retired(filename)
                        end
                    end
                end
            end
            local function no_link_records(directory)
                if not lfs.symlinkattributes(directory) then return end
                for name in lfs.dir(directory) do
                    if name ~= "." and name ~= ".." then
                        local path = directory .. "/" .. name
                        assert.not_equal("record", name, path)
                        if lfs.symlinkattributes(path, "mode") == "directory" then no_link_records(path) end
                    end
                end
            end
            local object, sentinel = nil, 946684800
            for attempt = 1, 2 do
                write(events, "")
                local result = invoke(arguments, environment)
                assert.is_true(result.ok, result.stderr)
                assert.equal("exit", result.why, result.stderr)
                assert.equal(0, result.status, result.stderr)
                assert.matches("Titan native miss " .. first, result.stderr, 1, true)
                assert.is_nil(result.stderr:find("Titan native hit ", 1, true), result.stderr)
                assert.is_nil(result.stderr:find("Titan link hit ", 1, true), result.stderr)
                assert.matches("C\n", read(events), 1, true)
                if kind == "C-only" then
                    local current = assert(result.stdout:match("^([^\n]+)\n$"), result.stdout)
                    assert.is_true(platform.is_absolute(current))
                    if object then assert.equal(object, current) end
                    object = current
                    assert.is_nil(lfs.symlinkattributes(object:gsub("%.o$", ".record")))
                else
                    assert.matches("Titan link miss ", result.stderr, 1, true)
                    assert.matches("L\n", read(events), 1, true)
                    object = output .. "/uncertified_main.o"
                    local ran = context().io:run({ executable })
                    assert.is_true(ran.started and ran.ok, ran.output or ran.diagnostic)
                    assert.equal(0, ran.status)
                    for name in lfs.dir(output .. "/.native") do
                        assert.is_nil(name:match("%.record$"), name)
                    end
                    no_link_records(output .. "/.titan-links")
                    local dependency = output .. "/uncertified_dep.o"
                    assert.equal("file", lfs.attributes(dependency, "mode"))
                    if attempt == 1 then assert(lfs.touch(dependency, sentinel, sentinel))
                    else assert.not_equal(sentinel, lfs.attributes(dependency, "modification")) end
                    assert_staging_retired(output)
                    assert_staging_retired(assert(platform.parent(executable)))
                end
                assert.equal("file", lfs.attributes(object, "mode"))
                if attempt == 1 then assert(lfs.touch(object, sentinel, sentinel))
                else assert.not_equal(sentinel, lfs.attributes(object, "modification")) end
            end
        end)
    end

    it("retires Windows image staging and self-heals abandoned stages before a final hit", function()
        if not platform.windows then pending("Windows image staging retirement"); return end
        local output, launchers = root .. "/clean build Ω", root .. "/launchers"
        local executable = launchers .. "/cleanup-app.exe"
        write(root .. "/first_helper.h", "int first_helper(void);\n")
        write(root .. "/cleanup_main.titan", [[
foreign import "first_helper.h"
function main(args: {string}): integer
    return ffi.first_helper() - 17
end
]])
        local arguments = { "--incremental", "-v", "--jobs", "2",
            "--tree", root, "--output", output, "--exe", executable,
            "--c-source", first, "cleanup_main" }
        local cold = invoke(arguments)
        assert.is_true(cold.ok, cold.stderr)
        assert.equal("exit", cold.why, cold.stderr)
        assert.equal(0, cold.status, cold.stderr)
        local images = assert(driver.windows_program_paths("cleanup_main", executable, nil, output))
        assert.equal("file", lfs.attributes(images.provider, "mode"))
        assert.equal("file", lfs.attributes(images.executable, "mode"))
        local function inventory()
            local entries = {}
            local function visit(directory, relative)
                for name in lfs.dir(directory) do
                    if name ~= "." and name ~= ".." then
                        local filename = directory .. "/" .. name
                        local kind = assert(lfs.symlinkattributes(filename, "mode"))
                        assert.is_nil(name:find(".stage.tmp.", 1, true),
                            "retained Windows image staging: " .. filename)
                        local member = relative .. "/" .. name
                        entries[#entries + 1] = kind .. ":" .. member
                        if kind == "directory" then visit(filename, member) end
                    end
                end
            end
            visit(output, "output")
            visit(launchers, "launchers")
            table.sort(entries)
            return entries
        end
        local expected = inventory()
        local provider_bytes, executable_bytes = read(images.provider), read(images.executable)
        local sentinel = 946684800
        assert(lfs.touch(images.provider, sentinel, sentinel))
        assert(lfs.touch(images.executable, sentinel, sentinel))
        local abandoned_provider, provider_directory = assert(driver.staged_library_output(images.provider))
        local abandoned_launcher, launcher_directory = assert(driver.staged_library_output(images.executable))
        write(abandoned_provider, provider_bytes)
        assert(driver.validate_library_image_fresh(
            abandoned_provider, nil, { "cleanup_main" }, false))
        local accepted, validation_error = driver.validate_library_image_fresh(
            abandoned_provider, nil, { "cleanup_missing" }, false)
        assert.is_nil(accepted)
        assert.matches("cleanup_missing", validation_error, 1, true)
        write(abandoned_provider .. ".def", "abandoned export inventory\n")
        write(abandoned_launcher, "abandoned launcher transaction\n")
        local warm = invoke(arguments)
        assert.is_true(warm.ok, warm.stderr)
        assert.equal("exit", warm.why, warm.stderr)
        assert.equal(0, warm.status, warm.stderr)
        assert.matches("Titan native hit " .. first, warm.stderr, 1, true)
        assert.matches("Titan link hit " .. images.executable, warm.stderr, 1, true)
        assert.is_nil(warm.stderr:find("Titan link miss ", 1, true), warm.stderr)
        assert.is_nil(lfs.symlinkattributes(provider_directory))
        assert.is_nil(lfs.symlinkattributes(launcher_directory))
        assert.same(expected, inventory())
        assert.equal(provider_bytes, read(images.provider))
        assert.equal(executable_bytes, read(images.executable))
        assert.equal(sentinel, lfs.attributes(images.provider, "modification"))
        assert.equal(sentinel, lfs.attributes(images.executable, "modification"))
        local ran = context().io:run({ images.executable })
        assert.is_true(ran.started and ran.ok, ran.output or ran.diagnostic)
        assert.equal(0, ran.status)
    end)

    -- An accepted input inside a matching stage directory is refused before
    -- any stage is retired, including the genuinely abandoned sibling.
    for _, case in ipairs({
        { name = "a declared native object", leaf = "helper.o" },
        { name = "an authored C source", leaf = "authored.c" },
        { name = "a Titan source", leaf = "protect_main.titan" },
        { name = "a local C header", leaf = "protect_header.h" },
        { name = "a header included only by a C source", leaf = "protect_native.h" },
        { name = "a raw native linker input", leaf = "link-helper.o" },
    }) do
        it("refuses Windows stale staging that contains " .. case.name .. " and keeps every stage", function()
            if not platform.windows then pending("Windows stale-staging protection"); return end
            local output, launchers = root .. "/protected build", root .. "/protected launchers"
            local executable = launchers .. "/protect-app.exe"
            local abandoned = executable .. ".stage.tmp.abandoned"
            local authored = executable .. ".stage.tmp.authored"
            assert(lfs.mkdir(launchers))
            assert(lfs.mkdir(abandoned))
            assert(lfs.mkdir(authored))
            write(abandoned .. "/protect-app.exe", "abandoned launcher transaction\n")
            local protected = authored .. "/" .. case.leaf
            local tree, main = root, "function main(args: {string}): integer\n    return 0\nend\n"
            local arguments = { "--incremental", "-v", "--output", output, "--exe", executable }
            if case.leaf == "helper.o" or case.leaf == "link-helper.o" then
                write(protected, read(objects(root .. "/object build", { first })[1]))
            elseif case.leaf == "authored.c" then
                write(protected, "int authored_helper(void) { return 3; }\n")
                arguments[#arguments + 1], arguments[#arguments + 2] = "--c-source", protected
            elseif case.leaf == "protect_main.titan" then
                tree = authored
            elseif case.leaf == "protect_native.h" then
                -- The C source lies outside every stage; only its native
                -- preprocessing run records the staged header.
                write(protected, "#define PROTECT_NATIVE_VALUE 5\n")
                local helper = root .. "/stage_helper.c"
                write(helper, '#include "' .. protected .. '"\n' ..
                    "int stage_helper(void) { return PROTECT_NATIVE_VALUE; }\n")
                arguments[#arguments + 1], arguments[#arguments + 2] = "--c-source", helper
            else
                write(protected, "int protect_value(void);\n")
                main = 'foreign import "' .. protected .. '"\n' .. main
            end
            write(tree .. "/protect_main.titan", main)
            for _, word in ipairs({ "--tree", tree, "protect_main" }) do
                arguments[#arguments + 1] = word
            end
            if case.leaf == "helper.o" then
                arguments[#arguments + 1], arguments[#arguments + 2] = "-X", protected
            elseif case.leaf == "link-helper.o" then
                -- Not an -X payload: only the prepared link policy resolves it.
                arguments[#arguments + 1] = "--ldflag=" .. protected
            end
            local bytes = read(protected)
            local result = invoke(arguments)
            assert.is_false(result.ok, result.stderr)
            assert.equal("exit", result.why, result.stderr)
            assert.not_equal(0, result.status, result.stderr)
            assert.matches("refusing to retire stale Windows staging", result.stderr, 1, true)
            assert.matches("protect-app.exe.stage.tmp.authored", result.stderr, 1, true)
            assert.equal(bytes, read(protected))
            assert.equal("directory", lfs.symlinkattributes(authored, "mode"))
            assert.equal("abandoned launcher transaction\n", read(abandoned .. "/protect-app.exe"))
            assert.is_nil(lfs.symlinkattributes(executable))
        end)
    end

    it("retires stale staging under a junction spelling of the held output lock", function()
        if not platform.windows then pending("Windows directory-junction output alias"); return end
        local real, alias = root .. "/real-output", root .. "/alias-output"
        assert(lfs.mkdir(real))
        local junction = context().io:run({ "cmd.exe", "/d", "/c", "mklink", "/J",
            (alias:gsub("/", "\\")), (real:gsub("/", "\\")) })
        if not (junction.started and junction.ok) or lfs.attributes(alias, "mode") ~= "directory" then
            pending("same-volume directory junction creation is unavailable: " ..
                tostring(junction.output or junction.diagnostic))
            return
        end
        local completed, failure = pcall(function()
            write(root .. "/alias_main.titan", "function main(args: {string}): integer\n    return 0\nend\n")
            -- One physical lock is held through the --output spelling; the
            -- executable's junction spelling deduplicates onto it.
            local executable = alias .. "/alias-app.exe"
            local arguments = { "--incremental", "-v", "--tree", root,
                "--output", real, "--exe", executable, "alias_main" }
            local cold = invoke(arguments)
            assert.is_true(cold.ok, cold.stderr)
            assert.equal("exit", cold.why, cold.stderr)
            assert.equal(0, cold.status, cold.stderr)
            assert.equal("file", lfs.attributes(real .. "/alias-app.exe", "mode"))
            local images = assert(driver.windows_program_paths("alias_main", executable, nil, real))
            local abandoned, directory = assert(driver.staged_library_output(images.executable))
            write(abandoned, "abandoned launcher transaction\n")
            local warm = invoke(arguments)
            assert.is_true(warm.ok, warm.stderr)
            assert.equal("exit", warm.why, warm.stderr)
            assert.equal(0, warm.status, warm.stderr)
            assert.is_nil(lfs.symlinkattributes(directory))
            local ran = context().io:run({ images.executable })
            assert.is_true(ran.started and ran.ok, ran.output or ran.diagnostic)
            assert.equal(0, ran.status)
        end)
        -- Removing the junction itself never touches its target's contents.
        local unlinked, unlink_error = lfs.rmdir(alias)
        assert(completed, failure)
        assert(unlinked, unlink_error)
    end)

    it("refuses stale staging while an opaque link policy hides a raw operand, then builds without stages", function()
        if not platform.windows then pending("Windows stale-staging protection"); return end
        local output, launchers = root .. "/opaque build", root .. "/opaque launchers"
        local executable = launchers .. "/opaque-app.exe"
        local abandoned = executable .. ".stage.tmp.abandoned"
        local authored = executable .. ".stage.tmp.authored"
        assert(lfs.mkdir(launchers))
        assert(lfs.mkdir(abandoned))
        assert(lfs.mkdir(authored))
        write(abandoned .. "/opaque-app.exe", "abandoned launcher transaction\n")
        local object = read(objects(root .. "/object build", { first })[1])
        local staged = authored .. "/link-helper.o"
        write(staged, object)
        -- A valid empty response file makes the native library policy opaque,
        -- so no policy inventory names the raw operand that follows it.
        local response = root .. "/empty.rsp"
        write(response, "")
        write(root .. "/opaque_main.titan", "function main(args: {string}): integer\n    return 0\nend\n")
        local function arguments(operand)
            return { "--incremental", "-v", "--output", output, "--exe", executable,
                "--tree", root, "opaque_main", "--ldflag=@" .. response, "--ldflag=" .. operand }
        end
        local refused = invoke(arguments(staged))
        assert.is_false(refused.ok, refused.stderr)
        assert.equal("exit", refused.why, refused.stderr)
        assert.not_equal(0, refused.status, refused.stderr)
        assert.matches("refusing to retire stale Windows staging", refused.stderr, 1, true)
        assert.matches("inventory is incomplete", refused.stderr, 1, true)
        assert.equal(object, read(staged))
        assert.equal("directory", lfs.symlinkattributes(authored, "mode"))
        assert.equal("abandoned launcher transaction\n", read(abandoned .. "/opaque-app.exe"))
        assert.is_nil(lfs.symlinkattributes(executable))

        -- With no stale stage, the same opaque policy is not a build rejection.
        local relocated = root .. "/link-helper.o"
        write(relocated, object)
        remove(authored)
        remove(abandoned)
        local built = invoke(arguments(relocated))
        assert.is_true(built.ok, built.stderr)
        assert.equal("exit", built.why, built.stderr)
        assert.equal(0, built.status, built.stderr)
        local ran = context().io:run({ executable })
        assert.is_true(ran.started and ran.ok, ran.output or ran.diagnostic)
        assert.equal(0, ran.status)
    end)

    for _, case in ipairs({
        { name = "requires compile-only mode before creating outputs",
            arguments = function() return { "--c-source", first } end },
        { name = "requires a C source before creating outputs",
            arguments = function() return { "-c" } end },
        { name = "rejects installation-root printing before creating outputs",
            arguments = function() return { "-c", "--c-source", first, "--print-root" } end },
        { name = "rejects AST printing before creating outputs",
            arguments = function() return { "-c", "--c-source", first, "--print-ast" } end },
    }) do
        it(case.name, function()
            local output = root .. "/uncreated output Ω"
            local argv = { "--print-c-objects", "-v", "--output", output }
            for _, argument in ipairs(case.arguments()) do argv[#argv + 1] = argument end
            local result = invoke(argv)
            assert.is_false(result.ok, result.stderr)
            assert.equal("exit", result.why, result.stderr)
            assert.not_equal(0, result.status, result.stderr)
            assert.equal("", result.stdout)
            assert.matches("--print-c-objects", result.stderr, 1, true)
            assert.is_nil(lfs.symlinkattributes(output))
        end)
    end

    describe("native output tool effective execution", function()
        for _, case in ipairs({
            { name = "execute-only ELF", mode = "111", selected = "first", readable = false },
            { name = "owner 0654", mode = "654", selected = "later", readable = true },
            { name = "owner 0401", mode = "401", selected = "later", readable = true },
        }) do
            it("certifies the actual non-root " .. case.name .. " producer and reuses source objects", function()
                if platform.windows then pending("POSIX ELF execution permissions"); return end
                local function run(argv)
                    local result = context().io:run(argv)
                    assert.is_true(result.started and result.ok, result.output or result.diagnostic)
                    return result
                end
                if run({ "uname", "-s" }).output:match("^%s*(.-)%s*$") ~= "Linux" then
                    pending("Linux ELF execution permissions"); return
                end
                local uid = tonumber(run({ "id", "-u" }).output)
                assert.is_number(uid)
                if uid == 0 then pending("requires a non-root effective user"); return end
                local directories = { first = root .. "/first tool", later = root .. "/later tool" }
                for _, directory in pairs(directories) do assert(lfs.mkdir(directory)) end
                local tool_name, events = "titan-permission-ar", root .. "/actual-archiver"
                local real_ar = assert(cdriver.split_shell_words(driver.AR))
                if real_ar[1] == "exec" then table.remove(real_ar, 1) end
                assert.not_equal(tool_name, real_ar[1])
                local function c_string(value)
                    return '"' .. value:gsub('[%z\1-\31\127-\255\\"]', function(byte)
                        return string.format("\\%03o", byte:byte())
                    end) .. '"'
                end
                local initializers = {}
                for index, word in ipairs(real_ar) do
                    initializers[#initializers + 1] = string.format(
                        "    child[%d] = (char *)%s;", index - 1, c_string(word))
                end
                local function executable_bytes(marker)
                    local source, executable = root .. "/archiver.c", root .. "/elf-" .. marker
                    write(source, string.format([[
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    static const char event[] = %s;
    int fd = open(%s, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return 125;
    ssize_t written = write(fd, event, sizeof(event) - 1);
    int closed = close(fd);
    if (written != (ssize_t)(sizeof(event) - 1) || closed != 0) return 125;
    char *child[argc + %d];
%s
    for (int i = 1; i < argc; ++i) child[%d + i] = argv[i];
    child[%d + argc] = 0;
    execvp(child[0], child);
    return 126;
}
]], c_string(marker .. "\n"), c_string(events), #real_ar,
                        table.concat(initializers, "\n"), #real_ar - 1, #real_ar - 1))
                    local argv = assert(cdriver.split_shell_words(driver.CC))
                    if argv[1] == "exec" then table.remove(argv, 1) end
                    for _, word in ipairs({ "-std=c99", "-O0", "-fno-lto", source, "-o", executable }) do
                        argv[#argv + 1] = word
                    end
                    run(argv)
                    local bytes = read(executable)
                    assert.equal("\127ELF", bytes:sub(1, 4))
                    return bytes
                end
                local binaries = { first = executable_bytes("first"), later = executable_bytes("later") }
                local candidates = { first = directories.first .. "/" .. tool_name,
                    later = directories.later .. "/" .. tool_name }
                local function install(which, replace)
                    local candidate = candidates[which]
                    local previous = replace and assert(lfs.attributes(candidate))
                    local staged = replace and candidate .. ".replacement" or candidate
                    write(staged, binaries[which] .. (replace and "\1" or "\0"))
                    run({ "chmod", which == "first" and case.mode or "755", staged })
                    if previous then
                        assert(lfs.touch(staged, previous.access, previous.modification))
                        assert(os.rename(staged, candidate))
                        local current = assert(lfs.attributes(candidate))
                        assert.equal(previous.modification, current.modification)
                        assert.equal(previous.size, current.size)
                    end
                    assert.equal(uid, lfs.attributes(candidate, "uid"))
                end
                install("first"); install("later")
                assert.equal(case.readable, context().io:readable(candidates.first))
                local output = root .. "/permission build"
                write(root .. "/permission_library.titan", "function value(): integer return 37 end\n")
                local environment = { AR = tool_name,
                    PATH = directories.first .. ":" .. directories.later .. ":" .. (platform.getenv("PATH") or "") }
                local arguments = { "--incremental", "-v", "--jobs", "1",
                    "--tree", root, "--output", output, "permission_library" }
                local function compile()
                    local result = invoke(arguments, environment)
                    assert.is_true(result.ok, result.stderr)
                    assert.equal("exit", result.why, result.stderr)
                    assert.equal(0, result.status, result.stderr)
                    return result
                end
                local function actual_producer()
                    local bytes = read(events)
                    assert.not_equal("", bytes)
                    for marker in bytes:gmatch("[^\n]+") do assert.equal(case.selected, marker, bytes) end
                end
                local cold = compile()
                assert.matches("Titan link miss ", cold.stderr, 1, true)
                actual_producer()
                local object, generated = output .. "/permission_library.o", output .. "/permission_library.c"
                local sentinel = 946684800
                assert(lfs.touch(object, sentinel, sentinel))
                local object_bytes, c_bytes = read(object), read(generated)
                local object_info = assert(lfs.attributes(object))
                local c_info = assert(lfs.attributes(generated))
                local function reused_object()
                    assert.equal(object_bytes, read(object))
                    assert.equal(c_bytes, read(generated))
                    local current = assert(lfs.attributes(object))
                    assert.equal(object_info.dev, current.dev)
                    assert.equal(object_info.ino, current.ino)
                    assert.equal(sentinel, current.modification)
                    local current_c = assert(lfs.attributes(generated))
                    assert.equal(c_info.dev, current_c.dev)
                    assert.equal(c_info.ino, current_c.ino)
                    assert.equal(c_info.modification, current_c.modification)
                end
                write(events, "")
                assert.matches("Titan link hit ", compile().stderr, 1, true)
                assert.equal("", read(events))
                reused_object()
                install(case.selected == "first" and "later" or "first", true)
                assert.matches("Titan link hit ", compile().stderr, 1, true)
                assert.equal("", read(events))
                reused_object()
                install(case.selected, true)
                assert.matches("Titan link miss ", compile().stderr, 1, true)
                actual_producer()
                reused_object()
                write(events, "")
                assert.matches("Titan link hit ", compile().stderr, 1, true)
                assert.equal("", read(events))
                reused_object()
            end)
        end
    end)
end)

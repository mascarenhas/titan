local temporary = require "spec.support.temporary"
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local installed_prefix = require "spec.support.installed_prefix"

local VENDOR = "vendor/lpeglabel"
local ARCHIVE = "lpeglabel-build/libtitan-lpeglabel.a"
local EXPECTED_MEMBERS = {
    "lplcap.o", "lplcode.o", "lplprint.o", "lpltree.o", "lplvm.o",
}
local EXPECTED_SYMBOLS = {
    titan_lpeglabel_checkaux = true,
    titan_lpeglabel_compile = true,
    titan_lpeglabel_finddyncap = true,
    titan_lpeglabel_fixedlen = true,
    titan_lpeglabel_getcaptures = true,
    titan_lpeglabel_hascaptures = true,
    titan_lpeglabel_lp_gc = true,
    titan_lpeglabel_match = true,
    titan_lpeglabel_numsiblings = true,
    titan_lpeglabel_open = true,
    titan_lpeglabel_realloccode = true,
    titan_lpeglabel_runtimecap = true,
    titan_lpeglabel_sizei = true,
    titan_lpeglabel_tocharset = true,
}
local EXPECTED_DEBUG_SYMBOLS = {
    titan_lpeglabel_printcaplist = true,
    titan_lpeglabel_printcharset = true,
    titan_lpeglabel_printinst = true,
    titan_lpeglabel_printktable = true,
    titan_lpeglabel_printpatt = true,
    titan_lpeglabel_printtree = true,
}

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function run(argv, cwd)
    local previous = cwd and assert(lfs.currentdir()) or nil
    if cwd then assert.truthy(lfs.chdir(cwd)) end
    local called, result = pcall(function()
        return compiler_io.new_sync():run(argv)
    end)
    if previous then assert.truthy(lfs.chdir(previous)) end
    assert.truthy(called, result)
    return result.ok, result.output or result.diagnostic or "",
        result.why, result.status
end

local function configured_argv(environment, fallback, ...)
    local argv = assert(cdriver.split_shell_words(
        os.getenv(environment) or fallback))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function make_directory(path)
    if lfs.symlinkattributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), path)
end

local function copy_tree(source, destination)
    local mode = assert(lfs.symlinkattributes(source, "mode"), source)
    if mode == "file" then
        make_directory(assert(destination:match("^(.+)/[^/]+$")))
        write_file(destination, read_file(source))
    elseif mode == "directory" then
        make_directory(destination)
        for name in lfs.dir(source) do
            if name ~= "." and name ~= ".." then
                copy_tree(source .. "/" .. name,
                    destination .. "/" .. name)
            end
        end
    else
        error("unsupported copied path type " .. tostring(mode))
    end
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function temporary_directory(label)
    local path = temporary.name("-titan-" .. label)
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local PREFIX = installed_prefix.active()
local windows_workspace

local function build_windows_parser(directory, debug_build)
    make_directory(directory)
    local objects = {}
    for _, member in ipairs(EXPECTED_MEMBERS) do
        local object = directory .. "/" .. member
        local argv = configured_argv("CC", "clang.exe", "-std=c99",
            "-O2", "-fno-lto", "-I", PREFIX .. "/src/lua-5.5.1",
            "-I", VENDOR, "-c", VENDOR .. "/" ..
            member:gsub("%.o$", ".c"), "-o", object)
        if debug_build then argv[#argv + 1] = "-DLPEG_DEBUG" end
        local ok, output = run(argv)
        assert.truthy(ok, output)
        objects[#objects + 1] = object
    end
    local archive = directory .. "/libtitan-lpeglabel.a"
    local argv = configured_argv("AR", "llvm-ar", "rcs", archive)
    for _, object in ipairs(objects) do argv[#argv + 1] = object end
    local ok, output = run(argv)
    assert.truthy(ok, output)
    return archive
end

local function make_lpeglabel(extra)
    local argv = {
        "env", "CCACHE_DISABLE=1",
        "make", "--no-print-directory",
        "PREFIX=" .. PREFIX,
    }
    for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
    argv[#argv + 1] = "lpeglabel"
    return run(argv)
end

local function ensure_archive()
    if platform.windows then
        if not windows_workspace then
            windows_workspace = temporary_directory("lpeglabel-native")
            ARCHIVE = build_windows_parser(windows_workspace)
        end
        return
    end
    local ok, output, why, code = make_lpeglabel()
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
    assert.equal("file", lfs.symlinkattributes(ARCHIVE, "mode"))
end

local function archive_members(path)
    local ok, output, why, code =
        run(configured_argv("AR", "ar", "t", path))
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        local leaf = assert(member:match("([^/]+)$"))
        if not leaf:match("^__%.SYMDEF") then members[#members + 1] = leaf end
    end
    return members
end

local function private_definitions(output, expected)
    local found = {}
    for line in output:gmatch("[^\r\n]+") do
        local kind, symbol = line:match("%s([A-Za-z])%s+([^%s]+)%s*$")
        if kind and kind:upper() ~= "U" then
            local reference = platform.windows and
                symbol:match("^%.refptr%.(.+)$")
            if reference then
                -- COFF read-only pointer slots reference the private definitions.
                assert.equal("R", kind:upper(), line)
                assert.truthy(expected[reference], line)
            else
                if symbol:sub(1, 1) == "_" then symbol = symbol:sub(2) end
                assert.truthy(symbol:match("^titan_lpeglabel_"), line)
                found[symbol] = true
            end
        end
    end
    return found
end

local function executable_script(path, contents)
    write_file(path, contents)
    local ok, output, why, code = run({ "chmod", "u+x", path })
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

describe("private vendored LPegLabel build", function()
    teardown(function()
        if windows_workspace then remove_tree(windows_workspace) end
    end)
    it("records the exact revision and keeps the namespace patch centralized",
        function()
            local upstream = read_file(VENDOR .. "/UPSTREAM.md")
            assert.truthy(upstream:find(
                "912b0b9e8641074408ffc2259e069b188e0c717b", 1, true))
            assert.truthy(upstream:find("v1.6.2-1", 1, true))
            assert.truthy(upstream:find(
                "5511d2704de4580c5b79b100c2daec5e" ..
                "773db58be9c2239e49ea2d9da2decf67", 1, true))

            local types = read_file(VENDOR .. "/lpltypes.h")
            assert.truthy(types:find(
                '#include "titan_lpeglabel_namespace.h"', 1, true))
            assert.truthy(types:find(
                '"titan.peg.lpeglabel.912b0b9e.pattern"', 1, true))
            assert.truthy(types:find(
                '"titan.peg.lpeglabel.912b0b9e.maxstack"', 1, true))
            assert.falsy(types:find('"lpeglabel-pattern"', 1, true))
            assert.falsy(types:find('"lpeglabel-maxstack"', 1, true))

            local namespace =
                read_file(VENDOR .. "/titan_lpeglabel_namespace.h")
            assert.truthy(namespace:find(
                "#define luaopen_lpeglabel titan_lpeglabel_open", 1, true))
            for name in pairs(EXPECTED_SYMBOLS) do
                if name ~= "titan_lpeglabel_open" then
                    assert.truthy(namespace:find(name, 1, true), name)
                end
            end
            for _, printer in ipairs({
                "printcaplist", "printcharset", "printinst", "printktable",
                "printpatt", "printtree",
            }) do
                assert.truthy(namespace:find(
                    "#define " .. printer .. " titan_lpeglabel_" .. printer,
                    1, true), printer)
            end
        end)

    it("builds one exact five-member archive with only private definitions",
        function()
            ensure_archive()
            assert.same(EXPECTED_MEMBERS, archive_members(ARCHIVE))

            local ok, output, why, code =
                run(configured_argv("NM", "nm", "-g", ARCHIVE))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.same(EXPECTED_SYMBOLS,
                private_definitions(output, EXPECTED_SYMBOLS))
            assert.falsy(output:find("luaopen_lpeglabel", 1, true), output)

            local host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
            if host_output:match("^%s*Linux%s*$") then
                local readelf = { "readelf", "-Ws" }
                for _, member in ipairs(EXPECTED_MEMBERS) do
                    readelf[#readelf + 1] = "lpeglabel-build/" .. member
                end
                ok, output, why, code = run(readelf)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                local hidden = {}
                for line in output:gmatch("[^\r\n]+") do
                    local visibility, section, symbol = line:match(
                        "GLOBAL%s+(%S+)%s+(%S+)%s+(%S+)%s*$")
                    if section and section ~= "UND" then
                        assert.equal("HIDDEN", visibility, line)
                        hidden[symbol] = true
                    end
                end
                assert.same(EXPECTED_SYMBOLS, hidden)
            end
        end)

    it("optimizes the parser after generic validation flags and retains sanitizer instrumentation", function()
        if platform.windows then
            pending("Unix Make parser profile and sanitizer configuration")
            return
        end
        local workspace = temporary_directory("lpeglabel-host-flags")
        local tested, test_error = xpcall(function()
            local function build(name, extra, parser, optimization)
                local build_dir = workspace .. "/" .. name
                local ok, output = make_lpeglabel({
                    "TITAN_BUILD_PROFILE=validation",
                    "LPEGLABEL_BUILD_DIR=" .. build_dir,
                    "TITAN_EXTRA_CFLAGS=" .. extra,
                    "LPEGLABEL_BUILD_CFLAGS=" .. parser,
                })
                assert.truthy(ok, output)
                local compiled = 0
                for line in output:gmatch("[^\r\n]+") do
                    if line:find(" -c ", 1, true) and line:find("lpl", 1, true) then
                        local flags = assert(cdriver.split_shell_words(line))
                        local effective
                        for _, flag in ipairs(flags) do
                            if flag:match("^%-O[0-3s]$") then effective = flag end
                            assert.falsy(flag:match("^%-flto"), line)
                        end
                        assert.equal(optimization, effective, line)
                        compiled = compiled + 1
                    end
                end
                assert.equal(5, compiled, output)
                return build_dir
            end
            build("ordinary", "-O0 -fno-lto", "-O2 -fno-lto", "-O2")
            local host_ok, host = run({"uname", "-s"})
            assert.truthy(host_ok, host)
            if host:match("^%s*Linux%s*$") then
                local instrumented = build("sanitizer",
                    "-O0 -fno-lto -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer",
                    "-O1 -fno-lto", "-O1")
                local ok, symbols = run(configured_argv("NM", "nm", "-u",
                    instrumented .. "/libtitan-lpeglabel.a"))
                assert.truthy(ok, symbols)
                assert.truthy(symbols:find("__asan_", 1, true), symbols)
                assert.truthy(symbols:find("__ubsan_", 1, true), symbols)
            end
        end, debug.traceback)
        remove_tree(workspace)
        if not tested then error(test_error, 0) end
    end)

    it("preserves archive mtimes on an unchanged warm build",
        function()
            if platform.windows then
                pending("Unix Make parser archive")
                return
            end
            ensure_archive()
            local paths = {
                ARCHIVE,
            }
            local before = {}
            for _, path in ipairs(paths) do
                before[path] = assert(lfs.attributes(path, "modification"))
            end
            local ok, output, why, code = make_lpeglabel()
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            for _, path in ipairs(paths) do
                assert.equal(before[path],
                    assert(lfs.attributes(path, "modification")), path)
            end
        end)


    it("prefixes every definition enabled by the debug build", function()
        local workspace = temporary_directory("lpeglabel-debug")
        local build = workspace .. "/build"
        local tested, test_error = xpcall(function()
            local ok, output, why, code
            if platform.windows then
                build_windows_parser(build, true)
            else
                ok, output, why, code = make_lpeglabel({
                    "LPEGLABEL_BUILD_DIR=" .. build,
                    "TITAN_EXTRA_CFLAGS=-DLPEG_DEBUG",
                })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
            end

            local expected = {}
            for symbol in pairs(EXPECTED_SYMBOLS) do expected[symbol] = true end
            for symbol in pairs(EXPECTED_DEBUG_SYMBOLS) do
                expected[symbol] = true
            end
            ok, output, why, code = run(configured_argv(
                "NM", "nm", "-g", build .. "/libtitan-lpeglabel.a"))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            assert.same(expected, private_definitions(output, expected))
        end, debug.traceback)
        remove_tree(workspace)
        if not tested then error(test_error, 0) end
    end)

    it("passes all pinned upstream suites through only the private opener",
        function()
            ensure_archive()
            local workspace = temporary_directory("lpeglabel-harness")
            local executable = workspace .. "/lpeglabel-private-harness" ..
                (platform.windows and ".exe" or "")
            local host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
            local host = assert(host_output:match("^%s*(%S+)"))

            local compile = configured_argv(
                "CC", "cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                "-I", PREFIX .. "/include", "-I", VENDOR,
                "spec/fixtures/stdlib/native/lpeglabel_private_harness.c",
                ARCHIVE, PREFIX .. "/lib/" ..
                    (platform.windows and "liblua55.a" or "liblua.a"))
            if not platform.windows then compile[#compile + 1] = "-lm" end
            if host == "Linux" then compile[#compile + 1] = "-ldl" end
            compile[#compile + 1] = "-o"
            compile[#compile + 1] = executable

            local tested, test_error = xpcall(function()
                local ok, output, why, code =
                    run({ "env", "CCACHE_DISABLE=1", table.unpack(compile) })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                for _, suite in ipairs({
                    "test.lua", "testlabel.lua", "testrelabelparser.lua",
                }) do
                    ok, output, why, code = run({
                        executable, VENDOR, VENDOR .. "/" .. suite,
                    })
                    assert.truthy(ok, suite .. ":\n" .. output .. "\n(" ..
                        tostring(why) .. ", " .. tostring(code) .. ")")
                end
            end, debug.traceback)
            remove_tree(workspace)
            if not tested then error(test_error, 0) end
        end)

    it("rejects impossible UTF-8 leads before reading continuations",
        function()
            ensure_archive()
            local workspace = temporary_directory("lpeglabel-utf8-guard")
            local executable = workspace .. "/lpeglabel-utf8-guard" ..
                (platform.windows and ".exe" or "")
            local compile = configured_argv(
                "CC", "cc", "-std=c99", "-Wall", "-Wextra",
                "-I", PREFIX .. "/include", "-I", VENDOR,
                "spec/fixtures/stdlib/native/lpeglabel_utf8_guard_harness.c",
                ARCHIVE, PREFIX .. "/lib/" ..
                    (platform.windows and "liblua55.a" or "liblua.a"))
            if not platform.windows then compile[#compile + 1] = "-lm" end
            local host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
            if host_output:match("^%s*Linux%s*$") then
                compile[#compile + 1] = "-ldl"
            end
            compile[#compile + 1] = "-o"
            compile[#compile + 1] = executable

            local tested, test_error = xpcall(function()
                local ok, output, why, code = run({
                    "env", "CCACHE_DISABLE=1", table.unpack(compile),
                })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                ok, output, why, code = run({ executable })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
            end, debug.traceback)
            remove_tree(workspace)
            if not tested then error(test_error, 0) end
        end)

    it("keeps generated payload private and cleanup exact", function()
        local makefile = read_file("Makefile")
        local gitignore = read_file(".gitignore")
        for _, contract in ipairs({
            "LPEGLABEL_ARCHIVE := " ..
            "$(LPEGLABEL_BUILD_DIR)/libtitan-lpeglabel.a",
            "LPEGLABEL_CFLAGS := -std=c99 -fPIC -fvisibility=hidden",
            "lpeglabel: $(LPEGLABEL_ARCHIVE)",
            "$(LUA_SDK_PREREQ)",
            "rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE)",
            'rmdir "$(LPEGLABEL_BUILD_DIR)" 2>/dev/null || true',
        }) do
            assert.truthy(makefile:find(contract, 1, true), contract)
        end
        assert.falsy(makefile:find(
            'rm -rf "$(LPEGLABEL_BUILD_DIR)"', 1, true), makefile)
        assert.truthy(gitignore:find("/lpeglabel-build/", 1, true))
        assert.falsy(makefile:find(
            "install -m 0644 $(LPEGLABEL_ARCHIVE)", 1, true), makefile)
        assert.falsy(makefile:find(
                "TITAN_RUNTIME_OBJECTS :=", 1, true) and
            makefile:find(
                "TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(MINICORO_O) " ..
                "$(LPEGLABEL", 1, true), makefile)
    end)
end)

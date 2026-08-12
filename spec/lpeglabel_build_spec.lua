local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

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
    local words = {}
    for index, word in ipairs(argv) do words[index] = quote(word) end
    local command = table.concat(words, " ")
    if cwd then command = "cd " .. quote(cwd) .. " && " .. command end
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
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
    local path = os.tmpname() .. "-titan-" .. label
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

local PREFIX = (os.getenv("PREFIX") or prefix_from_cpath(package.cpath) or "")
    :gsub("/+$", "")
assert.equal("/", PREFIX:sub(1, 1),
    "LPegLabel build specs require an absolute standalone Titan PREFIX")

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

local function executable_script(path, contents)
    write_file(path, contents)
    local ok, output, why, code = run({ "chmod", "u+x", path })
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

describe("private vendored LPegLabel build", function()
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
            local found = {}
            for line in output:gmatch("[^\r\n]+") do
                local kind, symbol = line:match("%s([A-Za-z])%s+([^%s]+)%s*$")
                if kind and kind:upper() ~= "U" then
                    if symbol:sub(1, 1) == "_" then symbol = symbol:sub(2) end
                    assert.truthy(symbol:match("^titan_lpeglabel_"), line)
                    found[symbol] = true
                end
            end
            assert.same(EXPECTED_SYMBOLS, found)
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

    it("preserves archive and stamp mtimes on an unchanged warm build",
        function()
            ensure_archive()
            local paths = {
                ARCHIVE,
                "lpeglabel-build/.titan-lpeglabel-build-config",
                "lpeglabel-build/.titan-lpeglabel-archive-config",
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

    it("detects same-mtime content changes and portable archive tools",
        function()
            local workspace = temporary_directory("lpeglabel-build")
            local vendor = workspace .. "/vendor"
            local build = workspace .. "/build"
            local ar_log = workspace .. "/ar.log"
            local ranlib_log = workspace .. "/ranlib.log"
            local ar_wrapper = workspace .. "/ar"
            local ranlib_wrapper = workspace .. "/ranlib"
            local original_ar =
                assert(cdriver.split_shell_words(os.getenv("AR") or "ar"))
            local original_ranlib =
                assert(cdriver.split_shell_words(os.getenv("RANLIB") or "ranlib"))

            local function command_string(argv)
                local words = {}
                for index, word in ipairs(argv) do words[index] = quote(word) end
                return table.concat(words, " ")
            end

            local tested, test_error = xpcall(function()
                copy_tree(VENDOR, vendor)
                write_file(ar_log, "")
                write_file(ranlib_log, "")
                executable_script(ar_wrapper, string.format([[#!/bin/sh
printf '%%s\n' "$*" >> %s
if [ "${1-}" = qDc ]; then
  shift
  set -- qc "$@"
fi
exec %s "$@"
]], quote(ar_log), command_string(original_ar)))
                executable_script(ranlib_wrapper, string.format([[#!/bin/sh
printf '%%s\n' "$*" >> %s
if [ "${1-}" = -D ]; then exit 64; fi
exec %s "$@"
]], quote(ranlib_log), command_string(original_ranlib)))

                local arguments = {
                    "LPEGLABEL_VENDOR_DIR=" .. vendor,
                    "LPEGLABEL_BUILD_DIR=" .. build,
                    "AR=" .. ar_wrapper,
                    "RANLIB=" .. ranlib_wrapper,
                }
                local ok, output, why, code = make_lpeglabel(arguments)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                local archive = build .. "/libtitan-lpeglabel.a"
                assert.same(EXPECTED_MEMBERS, archive_members(archive))
                local config =
                    read_file(build .. "/.titan-lpeglabel-archive-config")
                assert.truthy(config:find("AR_MODE=qc\n", 1, true), config)
                assert.truthy(config:find(
                    "RANLIB_MODE=ordinary\n", 1, true), config)
                assert.truthy(config:find("DETERMINISTIC=no\n", 1, true), config)
                assert.truthy(read_file(ar_log):find("qDc", 1, true))
                assert.truthy(read_file(ranlib_log):find("-D", 1, true))

                local archive_mtime =
                    assert(lfs.attributes(archive, "modification"))
                ok, output, why, code = make_lpeglabel(arguments)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.equal(archive_mtime,
                    assert(lfs.attributes(archive, "modification")))

                local extra_object = workspace .. "/extra.o"
                copy_tree(build .. "/lplcap.o", extra_object)
                local corrupt_argv = {}
                for _, word in ipairs(original_ar) do
                    corrupt_argv[#corrupt_argv + 1] = word
                end
                for _, word in ipairs({ "qc", archive, extra_object }) do
                    corrupt_argv[#corrupt_argv + 1] = word
                end
                ok, output, why, code = run(corrupt_argv)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.same({
                    "lplcap.o", "lplcode.o", "lplprint.o", "lpltree.o", "lplvm.o",
                    "extra.o",
                }, archive_members(archive))
                ok, output, why, code = make_lpeglabel(arguments)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.same(EXPECTED_MEMBERS, archive_members(archive))

                local header = vendor .. "/lpltypes.h"
                local header_mtime =
                    assert(lfs.attributes(header, "modification"))
                write_file(header, read_file(header) ..
                    "\n/* content-stamp invalidation probe */\n")
                assert.truthy(lfs.touch(header, header_mtime, header_mtime))
                ok, output, why, code = run({ "sleep", "1" })
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                ok, output, why, code = make_lpeglabel(arguments)
                assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                    tostring(code) .. ")")
                assert.truthy(assert(lfs.attributes(archive, "modification")) >
                    archive_mtime)
                assert.same(EXPECTED_MEMBERS, archive_members(archive))
            end, debug.traceback)
            remove_tree(workspace)
            if not tested then error(test_error, 0) end
        end)

    it("prefixes every definition enabled by the debug build", function()
        local workspace = temporary_directory("lpeglabel-debug")
        local build = workspace .. "/build"
        local tested, test_error = xpcall(function()
            local ok, output, why, code = make_lpeglabel({
                "LPEGLABEL_BUILD_DIR=" .. build,
                "TITAN_EXTRA_CFLAGS=-DLPEG_DEBUG",
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")

            local expected = {}
            for symbol in pairs(EXPECTED_SYMBOLS) do expected[symbol] = true end
            for symbol in pairs(EXPECTED_DEBUG_SYMBOLS) do
                expected[symbol] = true
            end
            ok, output, why, code = run(configured_argv(
                "NM", "nm", "-g", build .. "/libtitan-lpeglabel.a"))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local found = {}
            for line in output:gmatch("[^\r\n]+") do
                local kind, symbol =
                    line:match("%s([A-Za-z])%s+([^%s]+)%s*$")
                if kind and kind:upper() ~= "U" then
                    if symbol:sub(1, 1) == "_" then
                        symbol = symbol:sub(2)
                    end
                    assert.truthy(symbol:match("^titan_lpeglabel_"), line)
                    found[symbol] = true
                end
            end
            assert.same(expected, found)
        end, debug.traceback)
        remove_tree(workspace)
        if not tested then error(test_error, 0) end
    end)

    it("passes all pinned upstream suites through only the private opener",
        function()
            ensure_archive()
            local workspace = temporary_directory("lpeglabel-harness")
            local executable = workspace .. "/lpeglabel-private-harness"
            local host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
            local host = assert(host_output:match("^%s*(%S+)"))

            local compile = configured_argv(
                "CC", "cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                "-I", PREFIX .. "/include", "-I", VENDOR,
                "spec/fixtures/stdlib/native/lpeglabel_private_harness.c",
                ARCHIVE, PREFIX .. "/lib/liblua.a", "-lm")
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
            local executable = workspace .. "/lpeglabel-utf8-guard"
            local compile = configured_argv(
                "CC", "cc", "-std=c99", "-Wall", "-Wextra",
                "-I", PREFIX .. "/include", "-I", VENDOR,
                "spec/fixtures/stdlib/native/lpeglabel_utf8_guard_harness.c",
                ARCHIVE, PREFIX .. "/lib/liblua.a", "-lm")
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
            "$(LPEGLABEL_BUILD_CONFIG): FORCE $(LPEGLABEL_SOURCES) " ..
            "$(LPEGLABEL_HEADERS)",
            "$(LUA_INSTALL_STAMP)",
            "rm -f $(LPEGLABEL_OBJECTS) $(LPEGLABEL_ARCHIVE)",
            "$(LPEGLABEL_BUILD_CONFIG) $(LPEGLABEL_ARCHIVE_CONFIG)",
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
                "TITAN_RUNTIME_OBJECTS := $(RUNTIME_O) $(CORO_O) " ..
                "$(LPEGLABEL", 1, true), makefile)
    end)
end)

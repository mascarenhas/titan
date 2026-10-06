local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local FIXTURE = "spec/fixtures/driver_flags"
local APPLICATION = FIXTURE .. "/application"
local INCLUDE = FIXTURE .. "/include path"
local MODULE = "flagprobe"

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local prefix_lua = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. "/bin/lua") or nil
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua
    or "lua"

local function shell_command(argv)
    local quoted = {}
    for i, arg in ipairs(argv) do
        quoted[i] = assert(cdriver.shell_quote(arg))
    end
    return table.concat(quoted, " ")
end

local function run(argv)
    local pipe = assert(io.popen(shell_command(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local ENVIRONMENT_KEYS = {
    "CC",
    "CLANG_FORMAT",
    "CCACHE_DISABLE",
    "MAKE",
    "TITAN_RUNTIME_PREBUILT",
    "TITAN_EXTRA_CPPFLAGS",
    "TITAN_EXTRA_CFLAGS",
    "TITAN_EXTRA_LDFLAGS",
    "TITAN_JOBS",
}

local function titanc(overrides, ...)
    local environment = {
        CC = "cc",
        CLANG_FORMAT = "clang-format",
        CCACHE_DISABLE = "1",
        MAKE = "make",
        -- Preserve the shared runtime without replacing the Make used by GCC LTO.
        TITAN_RUNTIME_PREBUILT = "1",
        TITAN_EXTRA_CPPFLAGS = "",
        TITAN_EXTRA_CFLAGS = "",
        TITAN_EXTRA_LDFLAGS = "",
        TITAN_JOBS = "1",
    }
    for name, value in pairs(overrides or {}) do
        environment[name] = value
    end

    -- These subprocesses exercise source-checkout SDK selection even when
    -- Busted itself uses the installed SDK through its checkout profile.
    local argv = { "env", "-u", "TITAN_ROCKS_ROOT", "-u", "TITAN_BUILD_PROFILE" }
    if environment.TITAN_BUILD_PROFILE then
        table.insert(argv, "TITAN_BUILD_PROFILE=" .. environment.TITAN_BUILD_PROFILE)
    end
    for _, name in ipairs(ENVIRONMENT_KEYS) do
        table.insert(argv, name .. "=" .. environment[name])
    end
    table.insert(argv, LUA)
    table.insert(argv, "-e")
    table.insert(argv,
        [[package.path = "./?.lua;./?/init.lua;" .. package.path]])
    table.insert(argv, "./titanc")
    for _, arg in ipairs({ ... }) do table.insert(argv, arg) end
    return run(argv)
end

local ARTIFACTS = {
    MODULE .. ".so",
    MODULE .. ".a",
    MODULE .. ".lua",
    APPLICATION .. "/" .. MODULE .. ".c",
    APPLICATION .. "/" .. MODULE .. ".o",
    APPLICATION .. "/" .. MODULE .. ".ffi.h",
}

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function clean()
    for _, path in ipairs(ARTIFACTS) do os.remove(path) end
    remove_tree(MODULE .. ".so.dSYM")
end

local function command_lines(output, required)
    local lines = {}
    for line in output:gmatch("[^\n]+") do
        if line:find(required, 1, true) then table.insert(lines, line) end
    end
    return lines
end

describe("Titan driver generic build flags", function()
    local verbose_output

    setup(function()
        clean()
        local ok, output, why, code = titanc({
            CC = "env TITAN_DRIVER_CC_SENTINEL=present cc " ..
                "-DTITAN_DRIVER_CC_HONORED=1",
            CLANG_FORMAT = "sh -c 'exit 23' --",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
            TITAN_EXTRA_CFLAGS =
                "-DTITAN_DRIVER_COMPILE_ONLY_MARKER=1",
            TITAN_EXTRA_LDFLAGS = "-L" .. APPLICATION .. " " ..
                "-L'" .. INCLUDE .. "'",
        }, "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        verbose_output = output

        local ran, runtime_output, runtime_why, runtime_code = run({
            LUA,
            "-e",
            [[local m = require "flagprobe"; print(m.selected_branch())]],
        })
        assert.truthy(ran, runtime_output .. "\n(" ..
            tostring(runtime_why) .. ", " .. tostring(runtime_code) .. ")")
        assert.equal("42\n", runtime_output)
    end)

    teardown(clean)

    it("honors CC and gives foreign imports and C compilation the same CPP flags",
       function()
        local cc_prefix =
            "'env' 'TITAN_DRIVER_CC_SENTINEL=present' 'cc' " ..
            "'-DTITAN_DRIVER_CC_HONORED=1'"
        assert.truthy(verbose_output:find(cc_prefix, 1, true), verbose_output)

        local cpp_sequence = "'-iquote' '" .. INCLUDE .. "' " ..
            "'-DTITAN_DRIVER_CPP_BRANCH=37'"
        assert.truthy(verbose_output:find(cpp_sequence, 1, true),
            verbose_output)

        local generated = assert(io.open(
            APPLICATION .. "/" .. MODULE .. ".c", "rb"))
        local csource = generated:read("*a")
        generated:close()
        assert.truthy(csource:find('/' .. MODULE .. '.ffi.h"', 1, true), csource)
        local header = assert(io.open(
            APPLICATION .. "/" .. MODULE .. ".ffi.h", "rb"))
        local environment = header:read("*a")
        header:close()
        local include_root = lfs.currentdir() .. "/" .. INCLUDE .. "/"
        assert.truthy(environment:find(
            '#include "' .. include_root .. 'driver_flags_config.h"',
            1, true), environment)
        assert.truthy(environment:find(
            '#include "' .. include_root .. 'titan/ffi.h"',
            1, true), environment)
    end)

    it("keeps extra C flags in compile phases and ordered LD flags in the link phase",
       function()
        local marker = "'-DTITAN_DRIVER_COMPILE_ONLY_MARKER=1'"
        local compile_lines = command_lines(verbose_output, "'-c'")
        local link_lines = command_lines(verbose_output, "'-shared'")
        assert.is_true(#compile_lines >= 1, verbose_output)
        assert.equal(2, #link_lines, verbose_output)

        local marked_lines = command_lines(verbose_output, marker)
        assert.is_true(#marked_lines >= 1, verbose_output)
        for _, line in ipairs(marked_lines) do
            assert.truthy(line:find("'-c'", 1, true), line)
            assert.falsy(line:find("'-shared'", 1, true), line)
        end

        for _, link_line in ipairs(link_lines) do
            assert.truthy(link_line:find(
                "'titan-runtime/libtitan.a'", 1, true), link_line)
            assert.falsy(link_line:find(
                "'titan-runtime/titan.o'", 1, true), link_line)
            assert.falsy(link_line:find(marker, 1, true), link_line)
            assert.falsy(link_line:find("'-DTITAN_DRIVER_CPP_BRANCH=37'", 1,
                true), link_line)

            local first_ldflag = "'-L" .. APPLICATION .. "'"
            local second_ldflag = "'-L" .. INCLUDE .. "'"
            local first_at = assert(link_line:find(first_ldflag, 1, true),
                link_line)
            local second_at = assert(link_line:find(second_ldflag, 1, true),
                link_line)
            assert.is_true(first_at < second_at, link_line)
        end
    end)

    it("prints the complete effective native argv without a formatter", function()
        assert.equal(0, #command_lines(verbose_output, "clang-format"),
            verbose_output)
        assert.equal(0, #command_lines(verbose_output, "exit 23"),
            verbose_output)

        assert.truthy(verbose_output:find("'--std=c99'", 1, true),
            verbose_output)
        assert.truthy(verbose_output:find("'-iquote' '" .. INCLUDE .. "'", 1,
            true), verbose_output)
        assert.truthy(verbose_output:find(
            "'-DTITAN_DRIVER_COMPILE_ONLY_MARKER=1'", 1, true),
            verbose_output)
        assert.truthy(verbose_output:find("'-L" .. INCLUDE .. "'", 1,
            true), verbose_output)
    end)

    it("uses O3 everywhere and native-container LTO by default on Linux", function()
        local ok, platform = run({ "uname", "-s" })
        assert.truthy(ok, platform)
        local linux = platform:match("Linux") ~= nil
        local checked = 0
        for _, line in ipairs(command_lines(verbose_output, "'-O3'")) do
            if line:find("'-c'", 1, true) or line:find("'-shared'", 1, true) then
                checked = checked + 1
                assert.equal(linux, line:find("'-flto=auto'", 1, true) ~= nil, line)
                assert.equal(linux, line:find("'-ffat-lto-objects'", 1, true) ~= nil, line)
            end
        end
        assert.is_true(checked >= 3, verbose_output)
        for _, line in ipairs(command_lines(verbose_output, "'-shared'")) do
            assert.truthy(line:find("'-O3'", 1, true), line)
        end
    end)

    it("lets explicit compile and link flags disable optimization and LTO", function()
        local ok, output = titanc({
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
            TITAN_EXTRA_CFLAGS = "-O0 -fno-lto",
            TITAN_EXTRA_LDFLAGS = "-O0 -fno-lto",
        }, "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output)
        local checked = 0
        for line in output:gmatch("[^\n]+") do
            if line:find("'-c'", 1, true) or line:find("'-shared'", 1, true) then
                local baseline = line:find("'-O3'", 1, true)
                if baseline then
                    local override = assert(line:find("'-O0'", 1, true), line)
                    assert.is_true(baseline < override, line)
                    local disabled = assert(line:find("'-fno-lto'", 1, true), line)
                    local enabled = line:find("'-flto=auto'", 1, true)
                    assert.is_true(not enabled or enabled < disabled, line)
                    checked = checked + 1
                end
            end
        end
        assert.is_true(checked >= 3, output)
    end)

    it("uses validation defaults for compilation and linking before explicit overrides", function()
        local ok, output = titanc({
            TITAN_BUILD_PROFILE = "validation",
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
            TITAN_EXTRA_CFLAGS = "-O1",
            TITAN_EXTRA_LDFLAGS = "-O1",
        }, "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output)
        local checked = 0
        for line in output:gmatch("[^\n]+") do
            if line:find("'-c'", 1, true) or line:find("'-shared'", 1, true) then
                local baseline = line:find("'-O0'", 1, true)
                if baseline then
                    assert.is_true(baseline < assert(line:find("'-O1'", 1, true), line))
                    assert.truthy(line:find("'-fno-lto'", 1, true), line)
                    assert.falsy(line:find("'-O3'", 1, true), line)
                    assert.falsy(line:find("'-flto", 1, true), line)
                    assert.falsy(line:find("'-ffat-lto-objects'", 1, true), line)
                    checked = checked + 1
                end
            end
        end
        assert.is_true(checked >= 3, output)
        local invalid, diagnostic = titanc({ TITAN_BUILD_PROFILE = "production validation" }, MODULE)
        assert.is_false(invalid)
        assert.matches("TITAN_BUILD_PROFILE must be production or validation", diagnostic, 1, true)
    end)

    it("preserves an explicitly selected compiler random seed", function()
        local ok, output = titanc({
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
            TITAN_EXTRA_CFLAGS = "-frandom-seed=explicit-seed",
        }, "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output)
        assert.truthy(output:find("'-frandom-seed=explicit-seed'", 1, true), output)
        assert.falsy(output:find("'-frandom-seed=" .. MODULE .. "'", 1, true), output)
    end)

    for _, explicit in ipairs({ false, true }) do
        local selection = explicit and "selected by --lua" or "selected by default"
        it("builds the source runtime against the Lua tree " .. selection,
           function()
            local lua_source = "lua-5.5.1/src"
            local arguments = { "-v" }
            if explicit then
                lua_source = lfs.currentdir() .. "/" .. lua_source
                arguments[#arguments + 1] = "--lua"
                arguments[#arguments + 1] = lua_source
            end
            arguments[#arguments + 1] = "--tree"
            arguments[#arguments + 1] = APPLICATION
            arguments[#arguments + 1] = MODULE
            -- Inspect the runtime Make argv without rebuilding shared state.
            -- Disable LTO only here, because GCC also consumes this fake MAKE.
            local ok, output, why, code = titanc({
                MAKE = "true",
                TITAN_RUNTIME_PREBUILT = "0",
                CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
                TITAN_EXTRA_CPPFLAGS = "-I '" .. INCLUDE .. "' " ..
                    "-DTITAN_DRIVER_CPP_BRANCH=37",
                TITAN_EXTRA_CFLAGS = "-O0 -fno-lto",
                TITAN_EXTRA_LDFLAGS = "-fno-lto",
            }, table.unpack(arguments))
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local runtime_checks = command_lines(output,
                "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. lua_source)
            assert.equal(1, #runtime_checks, output)
            assert.truthy(runtime_checks[1]:find(
                "titan-runtime/libtitan.a", 1, true), runtime_checks[1])
        end)
    end
end)

describe("Titan generated-source pretty-printing", function()
    after_each(clean)

    local function formatter_failure_args()
        return {
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            CLANG_FORMAT = "sh -c 'exit 23' --",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
        }
    end

    it("does not invoke a failing formatter by default", function()
        local ok, output, why, code = titanc(formatter_failure_args(),
            "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.falsy(output:find("exit 23", 1, true), output)
        assert.truthy(output:find(
            "'-c' '" .. APPLICATION .. "/" .. MODULE .. ".c'", 1, true),
            output)
    end)

    it("uses the configured formatter when pretty-printing is requested",
       function()
        local arguments = formatter_failure_args()
        arguments.CLANG_FORMAT = "true"
        local ok, output, why, code = titanc(arguments,
            "-v", "--pretty-print", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local format_lines = command_lines(output, "'true' '-i'")
        assert.equal(2, #format_lines, output)
        assert.truthy(format_lines[1]:find(
            "'--style={BasedOnStyle: LLVM, IndentWidth: 4, " ..
                "SortIncludes: false}' '--' '" .. APPLICATION .. "/" ..
                MODULE .. ".ffi.h.format.tmp.", 1, true), format_lines[1])
        assert.truthy(format_lines[2]:find(
            "'--style={BasedOnStyle: LLVM, IndentWidth: 4, " ..
                "SortIncludes: false}' '--' '" .. APPLICATION .. "/" ..
                MODULE .. ".c'", 1, true), format_lines[2])
        assert.truthy(output:find(
            "'-c' '" .. APPLICATION .. "/" .. MODULE .. ".c'", 1, true),
            output)
    end)

    it("stops before compilation when opted-in formatting fails", function()
        local ok, output, why, code = titanc(formatter_failure_args(),
            "-v", "--pretty-print", "--tree", APPLICATION, MODULE)
        assert.falsy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local cfile = APPLICATION .. "/" .. MODULE .. ".c"
        local ofile = APPLICATION .. "/" .. MODULE .. ".o"
        local header = APPLICATION .. "/" .. MODULE .. ".ffi.h"
        assert.is_false(file_exists(cfile))
        assert.is_false(file_exists(ofile))
        assert.is_false(file_exists(header))
        assert.truthy(output:find(
            "failed to format generated file '" .. header .. ".format.tmp.", 1, true),
            output)
        assert.truthy(output:find("exit 23", 1, true), output)
        assert.falsy(output:find("'-c' '" .. cfile .. "'", 1, true),
            output)
    end)
end)

describe("Titan driver malformed build flags", function()
    after_each(clean)

    for _, variable in ipairs({
        "TITAN_EXTRA_CPPFLAGS",
        "TITAN_EXTRA_CFLAGS",
        "TITAN_EXTRA_LDFLAGS",
    }) do
        it("rejects malformed " .. variable .. " before invoking the toolchain",
           function()
            local overrides = { [variable] = "'unterminated" }
            local ok, output = titanc(overrides,
                "--tree", APPLICATION, MODULE)
            assert.falsy(ok, output)
            local expected = "invalid " .. variable ..
                ": unterminated single quote in shell words"
            assert.truthy(output:find(expected, 1, true), output)
            assert.falsy(output:find("'-c'", 1, true), output)
        end)
    end

    it("parses CLANG_FORMAT only when pretty-printing is requested", function()
        local malformed = {
            CLANG_FORMAT = "'unterminated",
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
        }
        local ok, output = titanc(malformed,
            "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output)

        clean()
        ok, output = titanc(malformed,
            "--pretty-print", "--tree", APPLICATION, MODULE)
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "invalid CLANG_FORMAT: unterminated single quote in shell words",
            1, true), output)
        assert.falsy(output:find("'-c'", 1, true), output)
    end)
end)

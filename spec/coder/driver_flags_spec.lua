local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"

local FIXTURE = "spec/fixtures/driver_flags"
local APPLICATION = FIXTURE .. "/application"
local INCLUDE = FIXTURE .. "/include path"
local MODULE = "flagprobe"
local FORMATTER = "driver_flags_formatter.lua"
local FORMATTER_LOG = "driver_flags_formatter_inputs.lua"
local CC = platform.windows and (os.getenv("CC") or "clang.exe") or "cc"
local FLAG_CC = CC .. " -DTITAN_DRIVER_CC_HONORED=1"

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local prefix_lua = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. (platform.windows and "/bin/lua.exe" or "/bin/lua")) or nil
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua
    or (platform.windows and "lua.exe" or "lua")

local function run(argv, options)
    local result = compiler_io.new_sync():run(argv, options)
    local output = result.output or result.diagnostic or ""
    if platform.windows then
        output = output:gsub("\r\n", "\n")
        -- Compare the argument spelling independently of cmd's caret quoting.
        output = output:gsub('%^"(.-)%^"', function(word)
            return assert(cdriver.shell_quote((word:gsub("%^(.)", "%1"))))
        end)
    end
    return result.ok, output, result.why, result.status
end

local function formatter(status)
    if not platform.windows then return status == 0 and "true" or "sh -c 'exit 23' --" end
    local file = assert(io.open(FORMATTER, "w"))
    file:write(([=[
local path = arg[#arg]
local input = assert(io.open(path, "rb"))
local contents = input:read("*a")
input:close()
local log = assert(io.open(%q, "ab"))
log:write(string.format("{ path = %%q, contents = %%q },\n", path, contents))
log:close()
os.exit(tonumber(arg[1]))
]=]):format(FORMATTER_LOG))
    file:close()
    return assert(cdriver.shell_quote(LUA)) .. " " .. FORMATTER .. " " .. status
end

local function formatter_inputs()
    local file = assert(io.open(FORMATTER_LOG, "rb"))
    local contents = file:read("*a")
    file:close()
    return assert(load("return {\n" .. contents .. "}",
        "@" .. FORMATTER_LOG, "t", {}))()
end

local function assert_formatted_header(input)
    local include_root = lfs.currentdir():gsub("\\", "/") .. "/" .. INCLUDE .. "/"
    assert.truthy(input.contents:find(
        '#include "' .. include_root .. 'driver_flags_config.h"',
        1, true), input.contents)
    assert.truthy(input.contents:find(
        '#include "' .. include_root .. 'titan/ffi.h"',
        1, true), input.contents)
    assert.falsy(input.contents:find('/' .. MODULE .. '.ffi.h"',
        1, true), input.contents)
end

local lua_workspace
local function fixture_lua_source()
    lua_workspace = lua_workspace or async_stdlib.workspace("driver-flags")
    return lua_workspace .. "/lua-5.5.1"
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
        CC = CC,
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
    local argv, options = {}, nil
    -- Windows owns its SDK in a separate native build tree; the checkout does
    -- not contain the Unix runtime archive selected by these probes on Unix.
    if platform.windows then
        environment.TITAN_BUILD_PROFILE = environment.TITAN_BUILD_PROFILE or false
        environment.TITAN_ROCKS_ROOT =
            require("spec.support.installed_prefix").active()
        options = { env = environment }
    else
        argv = { "env", "-u", "TITAN_BUILD_PROFILE" }
        argv[#argv + 1] = "-u"
        argv[#argv + 1] = "TITAN_ROCKS_ROOT"
        if environment.TITAN_BUILD_PROFILE then
            table.insert(argv, "TITAN_BUILD_PROFILE=" .. environment.TITAN_BUILD_PROFILE)
        end
        for _, name in ipairs(ENVIRONMENT_KEYS) do
            table.insert(argv, name .. "=" .. environment[name])
        end
    end
    table.insert(argv, LUA)
    table.insert(argv, "-e")
    table.insert(argv,
        [[package.path = "./?.lua;./?/init.lua;" .. package.path]])
    table.insert(argv, "./titanc")
    local arguments = { ... }
    if not platform.windows then
        local selected = false
        for _, argument in ipairs(arguments) do
            if argument == "--lua" or argument == "-u" then selected = true end
        end
        if not selected then
            table.insert(argv, "--lua")
            table.insert(argv, fixture_lua_source())
        end
    end
    for _, argument in ipairs(arguments) do table.insert(argv, argument) end
    return run(argv, options)
end

local ARTIFACTS = {
    MODULE .. (platform.windows and ".dll" or ".so"),
    MODULE .. ".a",
    MODULE .. ".lua",
    APPLICATION .. "/" .. MODULE .. ".c",
    APPLICATION .. "/" .. MODULE .. ".o",
    APPLICATION .. "/" .. MODULE .. ".ffi.h",
    APPLICATION .. "/" .. MODULE .. ".parts",
    APPLICATION .. "/" .. MODULE .. ".priv.h",
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
    os.remove(FORMATTER)
    os.remove(FORMATTER_LOG)
    if lua_workspace then
        async_stdlib.cleanup(lua_workspace)
        lua_workspace = nil
    end
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
            CC = (platform.windows and "env.exe" or "env") ..
                " TITAN_DRIVER_CC_SENTINEL=present " .. FLAG_CC,
            CLANG_FORMAT = formatter(23),
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
        if platform.windows then
            assert.truthy(verbose_output:find("'TITAN_DRIVER_CC_SENTINEL=present'", 1, true), verbose_output)
            assert.truthy(verbose_output:find("'-DTITAN_DRIVER_CC_HONORED=1'", 1, true), verbose_output)
        else
            assert.truthy(verbose_output:find(cc_prefix, 1, true), verbose_output)
        end

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
        local include_root = lfs.currentdir():gsub("\\", "/") .. "/" .. INCLUDE .. "/"
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
        assert.equal(platform.windows and 1 or 2, #link_lines, verbose_output)

        local marked_lines = command_lines(verbose_output, marker)
        assert.is_true(#marked_lines >= 1, verbose_output)
        for _, line in ipairs(marked_lines) do
            assert.truthy(line:find("'-c'", 1, true), line)
            assert.falsy(line:find("'-shared'", 1, true), line)
        end

        for _, link_line in ipairs(link_lines) do
            local runtime_archive = platform.windows and
                (require("spec.support.installed_prefix").active() .. "/lib/titan/" ..
                    driver.TITAN_LIBRARY_VERSION .. "/libtitan.a") or
                "titan-runtime/libtitan.a"
            assert.truthy(link_line:find(assert(cdriver.shell_quote(runtime_archive)), 1, true), link_line)
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

    it("uses O3 with backtrace debug info and native-container LTO on Linux", function()
        local probe = assert(cdriver.split_shell_words(CC))
        for _, word in ipairs({ "-dM", "-E", "-x", "c",
                platform.windows and "NUL" or "/dev/null" }) do
            probe[#probe + 1] = word
        end
        local probed, macros = run(probe)
        assert.truthy(probed, macros)
        local clang = macros:find("#define __clang__ ", 1, true) ~= nil
        local linux = false
        if not platform.windows then
            local ok, host = run({ "uname", "-s" })
            assert.truthy(ok, host)
            linux = host:match("Linux") ~= nil
        end
        local checked = 0
        for _, line in ipairs(command_lines(verbose_output, "'-O3'")) do
            if line:find("'-c'", 1, true) or line:find("'-shared'", 1, true) then
                checked = checked + 1
                assert.equal(linux, line:find("'-flto=auto'", 1, true) ~= nil, line)
                assert.equal(linux, line:find("'-ffat-lto-objects'", 1, true) ~= nil, line)
                if clang then
                    assert.truthy(line:find("'-gline-tables-only'", 1, true), line)
                    assert.truthy(line:find("'-fdebug-info-for-profiling'", 1, true), line)
                    assert.falsy(line:find("'-g1'", 1, true), line)
                else
                    assert.truthy(line:find("'-g1'", 1, true), line)
                    assert.falsy(line:find("'-gline-tables-only'", 1, true), line)
                end
                assert.falsy(line:find("'-g'", 1, true), line)
            end
        end
        assert.is_true(checked >= (platform.windows and 2 or 3), verbose_output)
        for _, line in ipairs(command_lines(verbose_output, "'-shared'")) do
            assert.truthy(line:find("'-O3'", 1, true), line)
        end
    end)

    it("preserves Titan function names and exact source lines with production debug info", function()
        local ok, output = run({ LUA, "-e", [[
            local m = require "flagprobe"
            local titan = require "titan"
            assert(not pcall(m.apply, function(n)
                return m.apply(function() return m.fail_with_traceback() end, n)
            end, 1))
            local trace = titan.backtrace()
            assert(trace:find("flagprobe.titan:11: in flagprobe.invalid_result", 1, true), trace)
            assert(trace:find("flagprobe.titan:15: in flagprobe.fail_with_traceback", 1, true), trace)
            local _, callers = trace:gsub("in flagprobe%.apply\n", "")
            assert(callers == 2, trace)
            print("OK")
        ]] })
        assert.truthy(ok, output)
        assert.equal("OK\n", output)
    end)

    it("lets explicit compile and link flags disable optimization and LTO", function()
        local ok, output = titanc({
            CC = FLAG_CC,
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
        assert.is_true(checked >= (platform.windows and 2 or 3), output)
    end)

    it("uses validation defaults for compilation and linking before explicit overrides", function()
        local ok, output = titanc({
            TITAN_BUILD_PROFILE = "validation",
            CC = FLAG_CC,
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
                    assert.truthy(line:find("'-g'", 1, true), line)
                    assert.falsy(line:find("'-g1'", 1, true), line)
                    assert.falsy(line:find("'-gline-tables-only'", 1, true), line)
                    checked = checked + 1
                end
            end
        end
        assert.is_true(checked >= (platform.windows and 2 or 3), output)
        local invalid, diagnostic = titanc({ TITAN_BUILD_PROFILE = "production validation" }, MODULE)
        assert.is_false(invalid)
        assert.matches("TITAN_BUILD_PROFILE must be production or validation", diagnostic, 1, true)
    end)

    it("preserves an explicitly selected compiler random seed", function()
        local ok, output = titanc({
            CC = FLAG_CC,
            TITAN_EXTRA_CPPFLAGS = "-iquote '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
            TITAN_EXTRA_CFLAGS = "-frandom-seed=explicit-seed",
        }, "-v", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output)
        assert.truthy(output:find("'-frandom-seed=explicit-seed'", 1, true), output)
        assert.falsy(output:find("'-frandom-seed=" .. MODULE .. "'", 1, true), output)
    end)

    for _, explicit in ipairs({ false, true }) do
        local selection = explicit and "selected by --lua" or "selected by the SDK fixture"
        it("builds the source runtime against the Lua tree " .. selection,
           function()
            if platform.windows then
                pending("Windows uses the installed DLL SDK; this probe selects the Unix checkout runtime Make target")
                return
            end
            local lua_source = fixture_lua_source()
            local arguments = { "-v" }
            if explicit then
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
            CC = FLAG_CC,
            CLANG_FORMAT = formatter(23),
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
        arguments.CLANG_FORMAT = formatter(0)
        local ok, output, why, code = titanc(arguments,
            "-v", "--pretty-print", "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local format_lines = command_lines(output, platform.windows and
            ("'" .. FORMATTER .. "' '0' '-i'") or "'true' '-i'")
        assert.equal(2, #format_lines, output)
        local style = "'--style={BasedOnStyle: LLVM, IndentWidth: 4, " ..
            "SortIncludes: false}' '--' "
        if platform.windows then
            local inputs = formatter_inputs()
            assert.equal(2, #inputs)
            assert_formatted_header(inputs[1])
            assert.equal(APPLICATION .. "/" .. MODULE .. ".c", inputs[2].path)
            assert.truthy(inputs[2].contents:find(
                '/' .. MODULE .. '.ffi.h"', 1, true), inputs[2].contents)
            assert.truthy(format_lines[1]:find(style ..
                assert(cdriver.shell_quote(inputs[1].path)), 1, true), format_lines[1])
        else
            assert.truthy(format_lines[1]:find(style .. "'" .. APPLICATION .. "/" ..
                MODULE .. ".ffi.h.format.tmp.", 1, true), format_lines[1])
        end
        assert.truthy(format_lines[2]:find(
            style .. "'" .. APPLICATION .. "/" ..
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
        if platform.windows then
            local inputs = formatter_inputs()
            assert.equal(1, #inputs)
            assert_formatted_header(inputs[1])
            assert.truthy(output:find(
                "failed to format generated file '" .. inputs[1].path .. "'",
                1, true), output)
        else
            assert.truthy(output:find(
                "failed to format generated file '" .. header .. ".format.tmp.", 1, true),
                output)
        end
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
            CC = FLAG_CC,
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

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
    "TITAN_EXTRA_CPPFLAGS",
    "TITAN_EXTRA_CFLAGS",
    "TITAN_EXTRA_LDFLAGS",
}

local function titanc(overrides, ...)
    local environment = {
        CC = "cc",
        CLANG_FORMAT = "clang-format",
        CCACHE_DISABLE = "1",
        MAKE = "make",
        TITAN_EXTRA_CPPFLAGS = "",
        TITAN_EXTRA_CFLAGS = "",
        TITAN_EXTRA_LDFLAGS = "",
    }
    for name, value in pairs(overrides or {}) do
        environment[name] = value
    end

    local argv = { "env" }
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
            -- The prepared checkout runtime is shared Make-owned state. Keep
            -- this compiler-flags test from feeding its sentinel CC back into
            -- Make's dependency configuration stamps; the real compile and
            -- foreign-import probe below still use that CC.
            MAKE = "true",
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
        local include_root = lfs.currentdir() .. "/" .. INCLUDE .. "/"
        assert.truthy(csource:find(
            '#include "' .. include_root .. 'driver_flags_config.h"',
            1, true), csource)
        assert.truthy(csource:find(
            '#include "' .. include_root .. 'titan/ffi.h"',
            1, true), csource)
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

        local runtime_checks = command_lines(verbose_output,
            "TITAN_RUNTIME_LUA_SOURCE_PATH=lua-5.5.1/src")
        assert.equal(1, #runtime_checks, verbose_output)
        assert.truthy(runtime_checks[1]:find(
            "titan-runtime/libtitan.a", 1, true), runtime_checks[1])
    end)

    it("builds the source runtime against the Lua tree selected by --lua",
       function()
        local lua_source = lfs.currentdir() .. "/lua-5.5.1/src"
        -- Explicit command-line roots are source-first. Supply this fixture's
        -- required foreign-import inputs instead of relying on the binary
        -- produced by setup to hide its source.
        local ok, output, why, code = titanc({
            MAKE = "true",
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            TITAN_EXTRA_CPPFLAGS = "-I '" .. INCLUDE .. "' " ..
                "-DTITAN_DRIVER_CPP_BRANCH=37",
        }, "-v",
            "--lua", lua_source, "--tree", APPLICATION, MODULE)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local runtime_checks = command_lines(output,
            "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. lua_source)
        assert.equal(1, #runtime_checks, output)
        assert.truthy(runtime_checks[1]:find(
            "titan-runtime/libtitan.a", 1, true), runtime_checks[1])
    end)
end)

describe("Titan generated-source pretty-printing", function()
    after_each(clean)

    local function formatter_failure_args()
        return {
            CC = "cc -DTITAN_DRIVER_CC_HONORED=1",
            CLANG_FORMAT = "sh -c 'exit 23' --",
            MAKE = "true",
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
        assert.equal(1, #format_lines, output)
        assert.truthy(format_lines[1]:find(
            "'--style={BasedOnStyle: LLVM, IndentWidth: 4, " ..
                "SortIncludes: false}' '--' '" .. APPLICATION .. "/" ..
                MODULE .. ".c'", 1, true), format_lines[1])
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
        assert.is_true(file_exists(cfile))
        assert.is_false(file_exists(ofile))
        assert.truthy(output:find(
            "failed to format generated file '" .. cfile .. "'", 1, true),
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
            MAKE = "true",
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

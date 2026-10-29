-- Coverage is an ordinary source build followed by direct executable execution.
local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local coverage = require "titan-compiler.coverage"
local driver = require "titan-compiler.driver"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local luacov_children = require "spec.support.luacov_children"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"

local ROOT = lfs.currentdir()
local PREFIX = installed_prefix.active()
local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
local CC = os.getenv("TITAN_COVERAGE_TEST_CC") or (platform.windows and "clang" or "gcc")
local GCOV = os.getenv("TITAN_COVERAGE_TEST_GCOV") or (platform.windows and "llvm-cov gcov" or "gcov")
local BACKEND = os.getenv("TITAN_COVERAGE_TEST_BACKEND") or (platform.windows and "llvm-gcov" or "gcc-gcov")
local REQUIRED = os.getenv("TITAN_COVERAGE_TEST_REQUIRED") == "1"
local io_strategy = compiler_io.new_sync()

local function write(filename, contents)
    local file = assert(io.open(filename, "wb"))
    assert(file:write(contents))
    assert(file:close())
end
local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local contents = assert(file:read("a"))
    assert(file:close())
    return contents
end
local function remove_tree(filename)
    if lfs.symlinkattributes(filename, "mode") == "link" then
        assert(os.remove(filename))
    elseif lfs.attributes(filename, "mode") == "directory" then
        for entry in lfs.dir(filename) do
            if entry ~= "." and entry ~= ".." then remove_tree(filename .. "/" .. entry) end
        end
        assert(lfs.rmdir(filename))
    elseif lfs.attributes(filename) then assert(os.remove(filename)) end
end
local function synthetic_file(output_root, relative)
    local found
    local links = output_root .. "/.titan-links"
    for key in lfs.dir(links) do
        if #key == 64 and key:match("^[0-9a-f]+$") then
            local filename = links .. "/" .. key .. "/synthetic/" .. relative
            if lfs.attributes(filename, "mode") == "file" then
                assert.is_nil(found, relative)
                found = filename
            end
        end
    end
    assert.truthy(found, "missing target-private synthetic file: " .. relative)
    return found
end
local function copy(from, to)
    if lfs.attributes(from, "mode") == "directory" then
        assert(lfs.mkdir(to))
        for entry in lfs.dir(from) do
            if entry ~= "." and entry ~= ".." then copy(from .. "/" .. entry, to .. "/" .. entry) end
        end
    else write(to, read(from)) end
end
local function run(argv)
    local result = io_strategy:run(argv, { stderr_to_stdout = true })
    return result.ok, result.output or result.diagnostic or ""
end
local function run_program(argv)
    -- Keep the default launcher-relative path for Windows application DLLs.
    local command = { "env", "TITAN_PATH_0_6=" ..
        PREFIX .. "/lib/titan/0.6;;" }
    if platform.windows then
        table.insert(command, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6")
    end
    for _, argument in ipairs(argv) do command[#command + 1] = argument end
    return run(command)
end
local checked_backend, backend_error
local function available(setup_only)
    if not checked_backend then
        local build, err = coverage.prepare({ CC = CC, EMIT_LINE_DIRECTIVES = true,
            split_shell_words = driver.split_shell_words },
            { coverage_backend = BACKEND, coverage_gcov = GCOV }, io_strategy)
        checked_backend, backend_error = true, not build and err or nil
    end
    if backend_error then
        if setup_only then return false end
        if REQUIRED or os.getenv("TITAN_COVERAGE_TEST_CC") or
            os.getenv("TITAN_COVERAGE_TEST_GCOV") or os.getenv("TITAN_COVERAGE_TEST_BACKEND") then
            assert.is_nil(backend_error, backend_error)
        end
        pending("native coverage tools unavailable: " .. backend_error)
    end
    return true
end

local PRODUCTION = [[function twice(number: integer): integer
  return number * 2
end
local function uncalled(): integer
  return 90
end
function other(): integer
  return 17
end
]]
local CHECKS = [[local test = import "test"
local calc = import "calc"
local mixed = import "mixed"
function test_twice(_context: test.Context)
  test.assert(calc.twice(21) == 42)
  test.assert(mixed.result() == 3)
end
function test_other(_context: test.Context)
  test.assert(calc.other() == 17)
end
]]

local workspace, children
local function compile(options, roots)
    local argv = { LUA, workspace .. "/frontend.lua" }
    for _, item in ipairs(options or {}) do argv[#argv + 1] = item end
    argv[#argv + 1], argv[#argv + 2] = "--tree", workspace
    for _, name in ipairs(roots or { "checks" }) do argv[#argv + 1] = name end
    local ok, output = run(argv)
    children:collect()
    return ok, output
end
local function coverage_options(...)
    local options = { "--test", "--coverage", "--coverage-backend", BACKEND,
        "--coverage-gcov", GCOV, "--coverage-root", workspace,
        "--coverage-output", workspace .. "/report" }
    for _, value in ipairs({...}) do options[#options + 1] = value end
    return options
end
local function executable()
    return workspace .. (platform.windows and "/bin/checks.exe" or "/checks")
end
local function execute(filter)
    local argv = { executable() }
    if filter then argv[#argv + 1] = "--filter=" .. filter end
    return run_program(argv)
end
local function annotated()
    return read(workspace .. "/report/coverage.gcov")
end
local function line_count(report, source, number)
    local active = false
    local total
    for text in report:gmatch("[^\r\n]+") do
        local name = text:match("^%s*[^:]+:%s*0:Source:(.*)$")
        if name then
            name = name:gsub("\\", "/")
            if not platform.is_absolute(name) then name = workspace .. "/" .. name end
            name = name:gsub("\\", "/"):gsub("/%./", "/")
            local expected = source:gsub("\\", "/")
            if platform.windows then name, expected = name:lower(), expected:lower() end
            active = name == expected
        end
        local count, line = text:match("^%s*([^:]+):%s*(%d+):")
        if active and tonumber(line) == number then
            total = (total or 0) + (tonumber(count:match("%d+")) or 0)
        end
    end
    return total
end

describe("native compile-and-run coverage", function()
    before_each(function()
        if not available(true) then return end
        workspace = temporary.name("-native-coverage")
        assert(lfs.mkdir(workspace))
        workspace = assert(io_strategy:realpath(workspace))
        local frontend = workspace .. "/tooling"
        assert(lfs.mkdir(frontend))
        for _, name in ipairs({ "titan-compiler", "c-parser", "titanc" }) do
            copy(ROOT .. "/" .. name, frontend .. "/" .. name)
        end
        children = luacov_children.new(ROOT, frontend, workspace .. "/child-luacov")
        write(workspace .. "/frontend.lua", "package.path = " .. string.format("%q", frontend .. "/?.lua;")
            .. " .. package.path\n" .. children:init_code() .. "\n"
            .. "local platform = require 'titan-compiler.platform'\nlocal getenv = platform.getenv\n"
            .. "local values = " .. string.format("{CC=%q,TITAN_ROOT=%q,TITAN_EXTRA_CFLAGS=%q,TITAN_EXTRA_CPPFLAGS='',TITAN_EXTRA_LDFLAGS='',TITAN_NO_LINE_DIRECTIVES='0',TITAN_PROBE_CACHE_DISABLE='1'}", CC, PREFIX, "-O2 -fno-lto")
            .. "\nplatform.getenv = function(name) if values[name] ~= nil then return values[name] end return getenv(name) end\n"
            .. "assert(require('lfs').chdir(" .. string.format("%q", workspace) .. "))\n"
            .. "dofile(" .. string.format("%q", frontend .. "/titanc") .. ")\n")
        write(workspace .. "/calc.titan", PRODUCTION)
        write(workspace .. "/checks.titan", CHECKS)
        write(workspace .. "/mixed.titan", [[local test = import "test"
function result(): integer return 3 end
function test_mixed(_context: test.Context) test.assert(true) end
]])
    end)
    after_each(function() if workspace then remove_tree(workspace); workspace = nil end end)

    it("selects source modules automatically, excludes entire test modules and retains zero-hit bodies", function()
        available()
        local ok, output = compile(coverage_options())
        assert.truthy(ok, output)
        assert.truthy(lfs.attributes(workspace .. "/.coverage/calc.gcno"))
        assert.is_nil(lfs.attributes(workspace .. "/.coverage/mixed.gcno"))
        assert.is_nil(lfs.attributes(workspace .. "/.coverage/checks.gcno"))
        ok, output = execute()
        assert.truthy(ok, output)
        assert.truthy(output:find("coverage", 1, true), output)
        local report = annotated()
        assert.is_true((line_count(report, workspace .. "/calc.titan", 2) or 0) > 0, report)
        assert.equal(0, line_count(report, workspace .. "/calc.titan", 5), report)
    end)

    it("keeps coverage objects, generated test runners and default reports inside the output tree", function()
        available()
        local output_root = workspace .. "/build output/nested"
        local options = { "--test", "--coverage", "--coverage-backend", BACKEND,
            "--coverage-gcov", GCOV, "--coverage-root", workspace, "-o", output_root }
        local ok, output = compile(options)
        assert.truthy(ok, output)
        assert.truthy(lfs.attributes(output_root .. "/.coverage/calc.gcno"))
        assert.truthy(lfs.attributes(synthetic_file(output_root,
            ".coverage/checks__test_runner.c")))
        assert.truthy(lfs.attributes(synthetic_file(output_root,
            "checks__test_entrypoint.c")))
        assert.is_nil(lfs.attributes(workspace .. "/.coverage"))
        assert.is_nil(lfs.attributes(workspace .. "/checks__test_entrypoint.c"))
        local program = platform.windows and
            assert(driver.windows_program_paths("checks", nil, nil, output_root)).executable or
            output_root .. "/checks"
        ok, output = run_program({ program })
        assert.truthy(ok, output)
        local report = read(output_root .. "/.coverage/report/coverage.gcov")
        assert.is_true((line_count(report, workspace .. "/calc.titan", 2) or 0) > 0, report)
        assert.truthy(lfs.attributes(output_root .. "/.coverage/calc.gcda"))
    end)

    it("resets previous counters on every direct execution", function()
        available()
        local ok, output = compile(coverage_options("--coverage-module", "calc"))
        assert.truthy(ok, output)
        ok, output = execute("test_other")
        assert.truthy(ok, output)
        assert.is_true((line_count(annotated(), workspace .. "/calc.titan", 8) or 0) > 0)
        ok, output = execute("test_twice")
        assert.truthy(ok, output)
        assert.equal(0, line_count(annotated(), workspace .. "/calc.titan", 8))
        assert.is_true((line_count(annotated(), workspace .. "/calc.titan", 2) or 0) > 0)
    end)

    it("reports and resets the complete split-module denominator across all parts", function()
        available()
        local frontend = workspace .. "/frontend.lua"
        write(frontend, "package.path = " .. string.format("%q", workspace .. "/tooling/?.lua;")
            .. " .. package.path\nrequire('titan-compiler.coder').DEFAULT_SPLIT_THRESHOLD = 1\n"
            .. read(frontend))
        local ok, output = compile(coverage_options(
            "--coverage-module", "calc", "--c-parts", "4"))
        assert.truthy(ok, output)
        for part = 0, 3 do
            local stem = workspace .. "/.coverage/calc"
                .. (part == 0 and "" or ".part" .. part)
            assert.truthy(lfs.attributes(stem .. ".gcno"), stem)
        end
        for _, run_case in ipairs({ { "test_other", 8, 2 }, { "test_twice", 2, 8 } }) do
            ok, output = execute(run_case[1])
            assert.truthy(ok, output)
            assert.matches("Titan executable lines: 1/3", output, 1, true)
            local report = annotated()
            assert.is_true((line_count(report, workspace .. "/calc.titan", run_case[2]) or 0) > 0, report)
            assert.equal(0, line_count(report, workspace .. "/calc.titan", run_case[3]))
            assert.equal(0, line_count(report, workspace .. "/calc.titan", 5))
            for part = 0, 3 do
                local stem = workspace .. "/.coverage/calc"
                    .. (part == 0 and "" or ".part" .. part)
                assert.truthy(lfs.attributes(stem .. ".gcda"), stem)
            end
        end
    end)

    it("preserves taken and bypassed foreign decision lines after pretty-printing", function()
        available()
        local formatter, formatter_output = run({ "clang-format", "--version" })
        if not formatter then
            if REQUIRED then assert.truthy(formatter, formatter_output) end
            pending("optional pretty-printing requires clang-format")
        end
        write(workspace .. "/calc.titan", [[foreign function decisions(input: int): int
  if input == 1 then
    return 10
  elseif input == 2 then
    return 20
  end
  repeat
    input = input - 1
  until input == 0
  return input
end
function choose(input: integer): integer
  return decisions(input)
end
]])
        write(workspace .. "/checks.titan", [[local test = import "test"
local calc = import "calc"
function test_early(_context: test.Context)
  test.assert(calc.choose(1) == 10)
end
function test_later(_context: test.Context)
  test.assert(calc.choose(2) == 20)
  test.assert(calc.choose(3) == 0)
end
]])
        local ok, output = compile(coverage_options("--pretty-print", "--coverage-module", "calc"))
        assert.truthy(ok, output)
        for _, run_case in ipairs({
            { filter = "test_early", covered = { 2, 3, 13 }, zero = { 4, 5, 8, 9, 10 } },
            { filter = "test_later", covered = { 2, 4, 5, 8, 9, 10, 13 }, zero = { 3 } },
        }) do
            ok, output = execute(run_case.filter)
            assert.truthy(ok, output)
            assert.matches("Titan executable lines: " .. #run_case.covered .. "/8", output, 1, true)
            local report = annotated()
            for _, line in ipairs(run_case.covered) do
                local count = line_count(report, workspace .. "/calc.titan", line)
                assert.is_true(count ~= nil and count > 0, "expected covered Titan line " .. line)
            end
            for _, line in ipairs(run_case.zero) do
                assert.equal(0, line_count(report, workspace .. "/calc.titan", line),
                    "expected zero-hit Titan line " .. line)
            end
        end
    end)

    it("rejects coverage library builds while preserving an ordinary provider", function()
        available()
        local options = { "--coverage", "--coverage-backend", BACKEND, "--coverage-gcov", GCOV }
        local provider = workspace .. (platform.windows and "/calc.dll" or "/calc.so")
        local ok, output = compile(options, { "calc" })
        assert.falsy(ok, output)
        assert.matches("--coverage requires a test or standalone executable", output, 1, true)
        assert.is_nil(lfs.attributes(provider))
        if not platform.windows then assert.is_nil(lfs.attributes(workspace .. "/calc.a")) end
        ok, output = compile({}, { "calc" })
        assert.truthy(ok, output)
        local ordinary = read(provider)
        local archive = not platform.windows and read(workspace .. "/calc.a")
        ok, output = compile(options, { "calc" })
        assert.falsy(ok, output)
        assert.matches("--coverage requires a test or standalone executable", output, 1, true)
        assert.equal(ordinary, read(provider))
        if archive then assert.equal(archive, read(workspace .. "/calc.a")) end
    end)

    it("optionally renders Titan-only line reports through gcovr", function()
        available()
        local gcovr = os.getenv("TITAN_COVERAGE_TEST_GCOVR")
        if not gcovr then pending("optional rich reports require TITAN_COVERAGE_TEST_GCOVR") end
        local ok, output = compile(coverage_options("--coverage-module", "calc",
            "--coverage-gcovr", gcovr, "--coverage-format", "html",
            "--coverage-format", "lcov", "--coverage-format", "cobertura"))
        assert.truthy(ok, output)
        ok, output = execute("test_twice")
        assert.truthy(ok, output)
        local trace = read(workspace .. "/report/lines.json")
        assert.matches("calc.titan", trace, 1, true)
        assert.is_nil(trace:find("mixed.titan", 1, true))
        assert.is_nil(trace:find("checks.titan", 1, true))
        assert.is_nil(trace:find("calc.c", 1, true))
        local lcov = read(workspace .. "/report/coverage.info")
        assert.matches("DA:5,0", lcov, 1, true)
        assert.is_nil(lcov:match("\nFN"))
        assert.is_nil(lcov:match("\nBR"))
        assert.is_nil(lcov:find(",None", 1, true))
        local html = read(workspace .. "/report/coverage.html")
        assert.matches("Titan executable-line coverage", html, 1, true)
        assert.is_nil(html:find('class="listOfFunctions"', 1, true))
        assert.is_nil(html:find(">Branches<", 1, true))
        assert.matches('filename="calc.titan"', read(workspace .. "/report/coverage.xml"), 1, true)
    end)

    it("unions repeated globs and diagnoses empty selections without importing unmatched modules", function()
        available()
        local ok, output = compile(coverage_options("--coverage-module", "ca?c", "--coverage-module", "mix*"))
        assert.truthy(ok, output)
        assert.is_nil(lfs.attributes(workspace .. "/.coverage/mixed.gcno"))
        ok, output = compile(coverage_options("--coverage-module", "absent.*"))
        assert.falsy(ok, output)
        assert.truthy(output:find("selection", 1, true), output)
    end)

    it("reconstructs the executable inventory from reused incremental objects", function()
        available()
        local ok, output = compile(coverage_options("--incremental", "-c"), { "calc" })
        assert.truthy(ok, output)
        local original = read(workspace .. "/.coverage/calc.o")
        ok, output = compile(coverage_options("--incremental", "--coverage-module", "calc"))
        assert.truthy(ok, output)
        assert.equal(original, read(workspace .. "/.coverage/calc.o"))
        ok, output = execute("test_twice")
        assert.truthy(ok, output)
        assert.is_true((line_count(annotated(), workspace .. "/calc.titan", 2) or 0) > 0)
    end)

    it("rebuilds only objects whose coverage selection changes in an incremental build", function()
        available()
        write(workspace .. "/helper.titan", "foreign function raw(): int\n  return 11\nend\n")
        write(workspace .. "/checks.titan", 'local helper = import "helper.titan"\n' ..
            CHECKS:gsub("test.assert%(calc.twice%(21%) == 42%)",
                "test.assert(calc.twice(21) == 42)\n  test.assert(helper.raw() == 11)"))
        local function measured(name)
            local bytes = read(workspace .. "/.coverage/" .. name .. ".o")
            local record = assert(require("titan-compiler.objectmetadata").read(bytes, name .. ".o"))
            return record.object_metadata.coverage.enabled
        end
        local ok, output = compile(coverage_options("--incremental", "--coverage-module", "calc"))
        assert.truthy(ok, output)
        assert.is_true(measured("calc")); assert.is_false(measured("helper"))
        local checks = read(workspace .. "/.coverage/checks.o")
        ok, output = compile(coverage_options("--incremental", "--coverage-module", "helper"))
        assert.truthy(ok, output)
        assert.is_false(measured("calc")); assert.is_true(measured("helper"))
        assert.equal(checks, read(workspace .. "/.coverage/checks.o"))
        ok, output = execute("test_twice")
        assert.truthy(ok, output)
        assert.is_true((line_count(annotated(), workspace .. "/helper.titan", 2) or 0) > 0)
        assert.is_nil(line_count(annotated(), workspace .. "/calc.titan", 2))
        ok, output = compile(coverage_options("--incremental", "--coverage-module", "calc"))
        assert.truthy(ok, output)
        assert.is_true(measured("calc")); assert.is_false(measured("helper"))
        ok, output = execute("test_twice")
        assert.truthy(ok, output)
        assert.is_true((line_count(annotated(), workspace .. "/calc.titan", 2) or 0) > 0)
    end)

    it("keeps ordinary and coverage objects separate across optimized release and coverage builds", function()
        available()
        local ok, output = compile({ "-c" }, { "calc" })
        assert.truthy(ok, output)
        local ordinary = read(workspace .. "/calc.o")
        ok, output = compile(coverage_options("--incremental", "--coverage-module", "calc"))
        assert.truthy(ok, output)
        assert.equal(ordinary, read(workspace .. "/calc.o"))
        local measured = read(workspace .. "/.coverage/calc.o")
        assert.is_not.equal(ordinary, measured)
        ok, output = execute()
        assert.truthy(ok, output)
        -- A coverage-only tree must also be safe for a later first release build.
        assert(os.remove(workspace .. "/calc.o"))
        assert(os.remove(workspace .. "/calc.c"))
        write(workspace .. "/release.titan", [[local calc = import "calc"
function main(_args: {string}): integer return calc.twice(21) - 42 end
]])
        ok, output = compile({ "--incremental" }, { "release" })
        assert.truthy(ok, output)
        assert.is_not.equal(measured, read(workspace .. "/calc.o"))
        assert.equal(measured, read(workspace .. "/.coverage/calc.o"))
        local binary = workspace .. (platform.windows and "/bin/release.exe" or "/release")
        ok, output = run_program({binary})
        assert.truthy(ok, output)
    end)

    it("keeps test failures failed without producing a success report", function()
        available()
        write(workspace .. "/checks.titan", CHECKS:gsub("== 42", "== 41"))
        local ok, output = compile(coverage_options("--coverage-module", "calc"))
        assert.truthy(ok, output)
        ok, output = execute("test_twice")
        assert.falsy(ok, output)
        assert.truthy(output:find("FAILED", 1, true), output)
        assert.is_nil(lfs.attributes(workspace .. "/report/coverage.gcov"))
    end)
end)

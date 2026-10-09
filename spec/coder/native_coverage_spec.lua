-- Real generated-C/gcov regressions. Coverage tools are optional for ordinary
-- compiler testing; configured coverage lanes must provide GCC/gcov and gcovr.
local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local temporary = require "spec.support.temporary"
local util = require "titan-compiler.util"

local ROOT = lfs.currentdir()
local PREFIX = installed_prefix.active()
local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
local CC = os.getenv("TITAN_COVERAGE_TEST_CC") or
    (lfs.attributes("/usr/bin/gcc") and "/usr/bin/gcc" or "gcc")
local GCOV = os.getenv("TITAN_COVERAGE_TEST_GCOV") or "gcov"
local GCOVR = os.getenv("TITAN_COVERAGE_TEST_GCOVR") or os.getenv("GCOVR") or "gcovr"
local HOST = ROOT .. "/titan-coverage"
local function run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.ok, result.output or result.diagnostic or ""
end

local function remove_tree(path)
    if lfs.symlinkattributes(path, "mode") == "link" then
        assert(os.remove(path))
    elseif lfs.attributes(path, "mode") == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
        end
        assert(lfs.rmdir(path))
    elseif lfs.attributes(path) then
        assert(os.remove(path))
    end
end

local function write(filename, code)
    assert.truthy(util.set_file_contents(filename, code))
end

local checked_backend
local function require_backend(pretty)
    if platform.windows then
        pending("GCC/gcov backend is unsupported by the Windows CLANG64 SDK")
    end
    if not checked_backend then
        local ok, output = run({ "python3", HOST, "probe", "--cc", CC,
            "--gcov", GCOV, "--gcovr", GCOVR })
        if not ok then
            if os.getenv("TITAN_COVERAGE_TEST_CC") or os.getenv("TITAN_COVERAGE_TEST_GCOVR") then
                assert.truthy(ok, output)
            end
            pending("native coverage tools unavailable: " .. output)
        end
        checked_backend = true
    end
    if pretty then
        local ok, output = run({ "clang-format", "--version" })
        if not ok then pending("optional clang-format unavailable: " .. output) end
    end
end

local PRODUCTION = [[local cleanup_count = 0 -- @initializer
local function touch()
  cleanup_count = cleanup_count + 1 -- @cleanup
end
local function condition(): boolean
  return true -- @rhsbody
end
local function fail(): integer
  raise "escaped" -- @raise
end
foreign function add_one(input: int): int
  return input + 1 -- @foreign
end
foreign function foreign_never(input: int): int
  return input + 2 -- @foreignnever
end
function run(take: boolean): integer
  local total = 0 -- @local
  for index = 1, 3 do -- @loop
    total = total + index -- @loopbody
  end
  repeat
    total = total + 1 -- @repeatbody
  until total >= 7 -- @until
  if take and
      condition() then -- @rhs
    total = 90 -- @untaken
  elseif total < 0 then -- @elseif
    total = 91 -- @elseifbody
  end
  total = add_one(total) -- @foreigncall
  do
    defer touch() -- @defer
    total = fail() -- @failcall
    total = 60 -- @afterfail
  catch
    total = total + 1 -- @catch
  end
  local callback: function(): integer = function(): integer -- @closure
    return total + 10 -- @closurebody
  end
  return callback() -- @return
end
function count(): integer
  return cleanup_count -- @count
end
function rethrow(): integer
  do
    fail() -- @reraisecall
  catch
    raise -- @reraise
  end
  return 4 -- @afterreraise
end
]]

local CHECKS = [[local test = import "test"
local lib = import "lib.titan"
function test_runtime(_context: test.Context)
  test.assert(lib.run(false) == 19)
  test.assert(lib.count() == 1)
  local caught = false
  do
    lib.rethrow()
  catch
    caught = true
  end
  test.assert(caught)
end
]]

local function tagged_lines(source)
    local result, number = {}, 0
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        local tag = line:match("%-%- @(%w+)")
        if tag then result[tag] = number end
    end
    return result
end

local function lcov(filename)
    local contents = assert(util.get_file_contents(filename))
    local files, current = {}, nil
    for line in contents:gmatch("[^\n]+") do
        local source = line:match("^SF:(.+)$")
        if source then current = {}; files[source] = current end
        local number, count = line:match("^DA:(%d+),(%d+)")
        if number then current[tonumber(number)] = tonumber(count) end
    end
    return files
end

local function compile(workspace, directory, pretty, extra, mode)
    local frontend = workspace .. "/tooling"
    local checkout = 'package.path = ' .. string.format("%q", frontend .. "/?.lua;")
        .. ' .. package.path'
    local argv = { "env", "PREFIX=" .. PREFIX, "TITAN_ROCKS_ROOT=" .. PREFIX,
        "CC=" .. CC, "TITAN_BUILD_PROFILE=validation", "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
        "TITAN_EXTRA_LDFLAGS=-fno-lto", "TITAN_NO_LINE_DIRECTIVES=0",
        LUA, "-e", checkout, frontend .. "/titanc", "--tree", workspace,
        "--coverage", directory, "--coverage-root", workspace,
        "--coverage-gcov", GCOV, "--coverage-module", "lib",
        "--coverage-module", "unused" }
    if not mode then argv[#argv + 1] = "--test" end
    if pretty then argv[#argv + 1] = "--pretty-print" end
    for _, arg in ipairs(extra or {}) do argv[#argv + 1] = arg end
    argv[#argv + 1] = mode == "library" and "lib" or
        mode == "application" and "app" or "checks"
    return run(argv)
end

local function report(directory, command)
    local host = directory:match("^(.*)/[^/]+$") .. "/tooling/titan-coverage"
    local ok, output = run({ "python3", host, "seal", "--manifest",
        directory .. "/build.json", "--cc", CC, "--gcov", GCOV, "--gcovr", GCOVR })
    assert.truthy(ok, output)
    local argv = { "python3", host, "run", "--manifest", directory .. "/build.json",
        "--run", directory .. "/run", "--" }
    for _, arg in ipairs(command) do argv[#argv + 1] = arg end
    ok, output = run(argv)
    assert.truthy(ok, output)
    ok, output = run({ "python3", host, "report", "--manifest",
        directory .. "/build.json", "--run", directory .. "/run",
        "--output", directory .. "/report", "--gcovr", GCOVR })
    assert.truthy(ok, output)
    return lcov(directory .. "/report/coverage.info")
end

local function fixture(body)
    local workspace = temporary.name("-native-coverage")
    assert(lfs.mkdir(workspace))
    assert(lfs.mkdir(workspace .. "/lib"))
    -- Build receipts include exact compiler bytes. Freeze this frontend for
    -- every incremental scenario, also isolating concurrent repository work.
    local function copy(from, to)
        if lfs.attributes(from, "mode") == "directory" then
            assert(lfs.mkdir(to))
            for entry in lfs.dir(from) do
                if entry ~= "." and entry ~= ".." then
                    copy(from .. "/" .. entry, to .. "/" .. entry)
                end
            end
        else
            write(to, assert(util.get_file_contents(from)))
        end
    end
    assert(lfs.mkdir(workspace .. "/tooling"))
    for _, entry in ipairs({ "titan-compiler", "c-parser", "titanc", "titan-coverage" }) do
        copy(ROOT .. "/" .. entry, workspace .. "/tooling/" .. entry)
    end
    write(workspace .. "/lib/lib.titan", PRODUCTION)
    write(workspace .. "/lib/extra.titan", "function extra(): integer\n  return 72\nend\n")
    write(workspace .. "/unused.titan", "function never(): integer\n  return 83\nend\n")
    write(workspace .. "/checks.titan", CHECKS)
    write(workspace .. "/app.titan", [[local lib = import "lib"
function main(args: {string}): integer
  if lib.run(false) == 19 then return 0 else return 2 end
end
]])
    write(workspace .. "/lib/lib.o", "ordinary object sentinel")
    write(workspace .. "/lib/lib.c", "ordinary C sentinel")
    local tested, err = xpcall(function() body(workspace) end, debug.traceback)
    remove_tree(workspace)
    if not tested then error(err, 0) end
end

describe("native Titan executable-line coverage", function()
    for _, pretty in ipairs({ false, true }) do
        it("reports exact taken and untaken source lines with pretty-print " .. tostring(pretty), function()
            require_backend(pretty)
            fixture(function(workspace)
                local directory = workspace .. "/coverage"
                local ok, output = compile(workspace, directory, pretty)
                assert.truthy(ok, output)
                local files = report(directory, { directory .. "/bin/checks" })
                assert.is_nil(files["checks.titan"])
                local expected = tagged_lines(PRODUCTION)
                local counts = assert(files["lib/lib.titan"])
                for _, tag in ipairs({ "initializer", "cleanup", "raise", "foreign", "local",
                    "loopbody", "repeatbody", "until", "elseif", "foreigncall", "defer",
                    "failcall", "catch", "closure", "closurebody", "return", "count",
                    "reraisecall", "reraise" }) do
                    assert.is_true((counts[expected[tag]] or 0) > 0,
                        "executed source line missing or uncovered: " .. tag)
                end
                for _, tag in ipairs({ "rhsbody", "foreignnever", "rhs", "untaken", "elseifbody",
                    "afterfail", "afterreraise" }) do
                    assert.equal(0, counts[expected[tag]], "unexecuted source line: " .. tag)
                end
                assert.equal(3, counts[expected.loopbody])
                assert.equal(1, counts[expected.repeatbody])
                assert.equal(1, counts[expected.closurebody])
                assert.same({ [2] = 0 }, files["lib/extra.titan"])
                assert.same({ [2] = 0 }, files["unused.titan"])
                assert.equal("ordinary object sentinel", util.get_file_contents(workspace .. "/lib/lib.o"))
                assert.equal("ordinary C sentinel", util.get_file_contents(workspace .. "/lib/lib.c"))
                local object = assert(util.get_file_contents(directory .. "/objects/lib.o"))
                ok, output = compile(workspace, directory, pretty, { "--incremental" })
                assert.truthy(ok, output)
                assert.equal(object, util.get_file_contents(directory .. "/objects/lib.o"))
                ok, output = compile(workspace, directory, not pretty)
                assert.is_false(ok)
                assert.matches("coverage build configuration changed", output)
            end)
        end)
    end

    it("links a compile-only test build incrementally without replacing coverage objects", function()
        require_backend(false)
        fixture(function(workspace)
            local directory = workspace .. "/coverage"
            local ok, output = compile(workspace, directory, false, { "-c" })
            assert.truthy(ok, output)
            local object = assert(util.get_file_contents(directory .. "/objects/lib.o"))
            assert.truthy(lfs.attributes(directory .. "/objects/lib.gcno"))
            ok, output = compile(workspace, directory, false, { "--incremental" })
            assert.truthy(ok, output)
            assert.equal(object, util.get_file_contents(directory .. "/objects/lib.o"))
            local files = report(directory, { directory .. "/bin/checks" })
            assert.same({ [2] = 0 }, files["lib/extra.titan"])
            assert.same({ [2] = 0 }, files["unused.titan"])
            local expected = tagged_lines(PRODUCTION)
            assert.equal(3, files["lib/lib.titan"][expected.loopbody])
        end)
    end)

    it("validates frontend and anchor receipts and rejects source directory aliases", function()
        require_backend(false)
        fixture(function(workspace)
            local ok, output = compile(workspace, workspace, false,
                { "--tree", workspace .. ";" .. ROOT })
            assert.is_false(ok)
            assert.matches("coverage output must be a separate build directory", output)
            assert.is_nil(lfs.attributes(workspace .. "/build.config"))
            assert(lfs.link(workspace, workspace .. "/source-alias", true))
            ok, output = compile(workspace, workspace .. "/source-alias", false)
            assert.is_false(ok)
            assert.matches("coverage output must be a separate build directory", output)
            local directory = workspace .. "/coverage"
            ok, output = compile(workspace, directory, false)
            assert.truthy(ok, output)
            local anchors_path = directory .. "/objects/lib.coverage-anchors"
            local anchors = assert(util.get_file_contents(anchors_path))
            assert.is_true(#anchors > 0)
            write(anchors_path, "")
            ok, output = compile(workspace, directory, false, { "--incremental" })
            assert.truthy(ok, output)
            assert.equal(anchors, util.get_file_contents(anchors_path))
            local frontend = workspace .. "/tooling/titanc"
            write(frontend, assert(util.get_file_contents(frontend)) .. "\n-- provenance regression\n")
            ok, output = compile(workspace, directory, false, { "--incremental" })
            assert.is_false(ok)
            assert.matches("coverage build configuration changed", output)
        end)
    end)

    it("collects loaded shared providers and ordinary application integration coverage", function()
        require_backend(false)
        fixture(function(workspace)
            local library = workspace .. "/library-coverage"
            local ok, output = compile(workspace, library, false, nil, "library")
            assert.truthy(ok, output)
            local load = 'package.path = ' .. string.format("%q", library .. "/shims/?.lua;")
                .. ' .. package.path; package.cpath = '
                .. string.format("%q", library .. "/?.so;") .. ' .. package.cpath; '
                .. 'local lib = require "lib"; assert(lib.run(false) == 19); '
                .. 'assert(lib.count() == 1); assert(not pcall(lib.rethrow))'
            local files = report(library, { LUA, "-e", load })
            local expected = tagged_lines(PRODUCTION)
            assert.equal(3, files["lib/lib.titan"][expected.loopbody])
            assert.equal(0, files["lib/lib.titan"][expected.afterreraise])
            assert.same({ [2] = 0 }, files["unused.titan"])
            local application = workspace .. "/app-coverage"
            ok, output = compile(workspace, application, false, nil, "application")
            assert.truthy(ok, output)
            files = report(application, { application .. "/bin/app" })
            assert.equal(3, files["lib/lib.titan"][expected.loopbody])
            assert.equal(0, files["lib/lib.titan"][expected.reraise])
            assert.is_nil(files["app.titan"])
        end)
    end)

    if platform.windows then
        it("rejects the unsupported backend before creating Windows artifacts", function()
            local output_directory = temporary.name("-unsupported-coverage")
            local checkout = 'package.path = ' .. string.format("%q", ROOT .. "/?.lua;")
                .. ' .. package.path'
            local ok, output = run({ LUA, "-e", checkout, ROOT .. "/titanc",
                "--coverage", output_directory, "--coverage-module", "missing", "missing" })
            assert.is_false(ok)
            assert.matches("unsupported by the Windows CLANG64 SDK", output)
            assert.is_nil(lfs.attributes(output_directory))
        end)
    end
end)

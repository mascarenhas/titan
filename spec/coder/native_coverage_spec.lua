-- Real generated-C/gcov regressions. Coverage tools are optional for ordinary
-- compiler testing; configured coverage lanes must provide GCC/gcov and gcovr.
local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local luacov_children = require "spec.support.luacov_children"
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
local child_coverage = {}
local REQUIRED = os.getenv("TITAN_COVERAGE_TEST_REQUIRED") == "1"
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
            if REQUIRED or os.getenv("TITAN_COVERAGE_TEST_CC") or os.getenv("TITAN_COVERAGE_TEST_GCOVR") then
                assert.truthy(ok, output)
            end
            pending("native coverage tools unavailable: " .. output)
        end
        checked_backend = true
    end
    if pretty then
        local ok, output = run({ "clang-format", "--version" })
        if not ok then
            if REQUIRED then assert.truthy(ok, output) end
            pending("optional clang-format unavailable: " .. output)
        end
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

local FOREIGN_DECISIONS = [[foreign function decide_raw(input: int): int
  if input == 1 then -- @firstcondition
    return 10 -- @firstbody
  elseif input == 2 then -- @secondcondition
    return 20 -- @secondbody
  elseif input == 3 then -- @thirdcondition
    return 30 -- @thirdbody
  end
  return 40 -- @fallback
end
foreign function cycle_raw(limit: int, skip: int): int
  local total = 0 -- @cycleinitial
  repeat -- @cyclerepeat
    total = total + 1 -- @cyclebody
    if skip ~= 0 then -- @skipcondition
      break -- @cyclebreak
    end
  until total >= limit -- @cycleuntil
  return total -- @cyclereturn
end
function decide(input: integer): integer
  return decide_raw(input)
end
function cycle(limit: integer, skip: integer): integer
  return cycle_raw(limit, skip)
end
]]

local FOREIGN_CHECKS = [[local test = import "test"
local lib = import "lib.titan"
function test_bypassed(_context: test.Context)
  test.assert(lib.decide(1) == 10)
  test.assert(lib.cycle(3, 1) == 1)
end
function test_evaluated(_context: test.Context)
  test.assert(lib.decide(1) == 10)
  test.assert(lib.decide(2) == 20)
  test.assert(lib.decide(4) == 40)
  test.assert(lib.cycle(3, 0) == 3)
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

local function frontend_run(workspace, arguments, environment, collect)
    local frontend = workspace .. "/tooling"
    local checkout = 'package.path = ' .. string.format("%q", frontend .. "/?.lua;")
        .. ' .. package.path'
    local coverage = collect ~= false and child_coverage[workspace]
    local child_init = coverage and coverage:init_code() or ""
    checkout = checkout .. "; " .. child_init
    local argv = { "env", "PREFIX=" .. PREFIX, "TITAN_ROCKS_ROOT=" .. PREFIX,
        "CC=" .. CC, "TITAN_BUILD_PROFILE=validation", "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
        "TITAN_EXTRA_LDFLAGS=-fno-lto", "TITAN_NO_LINE_DIRECTIVES=0" }
    for _, assignment in ipairs(environment or {}) do argv[#argv + 1] = assignment end
    for _, argument in ipairs({ LUA, "-e", checkout, frontend .. "/titanc" }) do
        argv[#argv + 1] = argument
    end
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    local ok, output = run(argv)
    if coverage then
        local collected = coverage:collect()
        assert.is_true(child_init == "" or collected == 1,
            "the compiler invocation did not produce its private LuaCov statistics")
    end
    return ok, output
end

local function compile(workspace, directory, pretty, extra, mode, collect)
    local argv = { "--tree", workspace,
        "--coverage", directory, "--coverage-root", workspace,
        "--coverage-gcov", GCOV, "--coverage-module", "lib",
        "--coverage-module", "unused" }
    if not mode then argv[#argv + 1] = "--test" end
    if pretty then argv[#argv + 1] = "--pretty-print" end
    for _, arg in ipairs(extra or {}) do argv[#argv + 1] = arg end
    argv[#argv + 1] = mode == "library" and "lib" or
        mode == "application" and "app" or "checks"
    return frontend_run(workspace, argv, nil, collect)
end

local function report(directory, command, label)
    local host = directory:match("^(.*)/[^/]+$") .. "/tooling/titan-coverage"
    local run_directory = directory .. "/" .. (label and label .. "-run" or "run")
    local report_directory = directory .. "/" .. (label and label .. "-report" or "report")
    local ok, output = run({ "python3", host, "seal", "--manifest",
        directory .. "/build.json", "--cc", CC, "--gcov", GCOV, "--gcovr", GCOVR })
    assert.truthy(ok, output)
    local argv = { "python3", host, "run", "--manifest", directory .. "/build.json",
        "--run", run_directory, "--" }
    for _, arg in ipairs(command) do argv[#argv + 1] = arg end
    ok, output = run(argv)
    assert.truthy(ok, output)
    ok, output = run({ "python3", host, "report", "--manifest",
        directory .. "/build.json", "--run", run_directory,
        "--output", report_directory, "--gcovr", GCOVR })
    assert.truthy(ok, output)
    return lcov(report_directory .. "/coverage.info")
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
    child_coverage[workspace] = luacov_children.new(ROOT, workspace .. "/tooling",
        workspace .. "/child-luacov")
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
    child_coverage[workspace] = nil
    remove_tree(workspace)
    if not tested then error(err, 0) end
end

describe("native Titan executable-line coverage", function()
    it("rejects invalid coverage ownership and tool settings before compilation", function()
        require_backend(false)
        fixture(function(workspace)
            local directory = workspace .. "/invalid-coverage"
            local function rejected(extra, diagnostic, environment, without_coverage)
                local arguments = { "--tree", workspace }
                if not without_coverage then
                    for _, argument in ipairs({ "--coverage", directory,
                        "--coverage-module", "lib", "--coverage-gcov", GCOV }) do
                        arguments[#arguments + 1] = argument
                    end
                end
                for _, argument in ipairs(extra) do arguments[#arguments + 1] = argument end
                arguments[#arguments + 1] = "checks"
                local ok, output = frontend_run(workspace, arguments, environment)
                assert.is_false(ok, output)
                assert.truthy(output:find(diagnostic, 1, true), output)
                assert.is_nil(lfs.attributes(directory .. "/build.config"))
                assert.is_nil(lfs.attributes(directory .. "/objects"))
            end
            rejected({ "--coverage-module", "lib" }, "require --coverage", nil, true)
            rejected({ "--coverage-backend", "llvm-gcov" }, "require --coverage", nil, true)
            rejected({ "--coverage-python", "python3" }, "require --coverage", nil, true)
            rejected({ "--no-line-directives" }, "requires source #line directives")
            rejected({ "--print-ast" }, "cannot be combined with --print-ast")
            rejected({ "--coverage-module", "../bad" }, "invalid --coverage-module name")
            rejected({ "--coverage-module", "titan.test" }, "test support cannot be a coverage module")
            rejected({ "--coverage-module", "titan.test.runner" }, "test support cannot be a coverage module")
            rejected({ "--coverage-source-map", "missing-separator" },
                "requires STAGED_DIRECTORY=TRACKED_DIRECTORY")
            rejected({ "--coverage-source-map", workspace .. "/missing=" .. workspace },
                workspace .. "/missing")
            rejected({ "--coverage-gcov", "'" }, "quote")
            rejected({}, "quote", { "CC='" })
            rejected({}, "coverage requires GCC 14 or newer", { "CC=false" })
            rejected({ "--coverage-gcov", "false" }, "coverage requires gcov matching GCC")
            rejected({}, "coverage flags must be owned by --coverage", { "TITAN_EXTRA_CFLAGS=--coverage" })
            rejected({ "--coverage-root", workspace .. "/missing-root" }, workspace .. "/missing-root")
            local ok, output = frontend_run(workspace, { "--tree", workspace,
                "--coverage", directory, "--coverage-gcov", GCOV, "checks" })
            assert.is_false(ok, output)
            assert.truthy(output:find("requires an explicit --coverage-module production inventory", 1, true), output)
            assert.is_nil(lfs.attributes(directory .. "/build.config"))
        end)
    end)

    it("merges isolated child LuaCov stats once and rejects changed frontend bytes", function()
        fixture(function(workspace)
            local frontend = workspace .. "/tooling"
            local parent_stats = workspace .. "/collector-parent.stats"
            local script = "package.path = " .. string.format("%q", ROOT .. "/?.lua;")
                .. " .. package.path\nlocal root = " .. string.format("%q", ROOT)
                .. "\nlocal frontend = " .. string.format("%q", frontend)
                .. "\nlocal workspace = " .. string.format("%q", workspace)
                .. "\nlocal lua = " .. string.format("%q", LUA) .. [[
local children = require "spec.support.luacov_children"
local runner = require "luacov.runner"
local ordinary = children.new(root, frontend, workspace .. "/ordinary-stats")
assert(ordinary:init_code() == "" and ordinary:collect() == 0)
assert(not require("lfs").attributes(workspace .. "/ordinary-stats"))
runner.init({ statsfile = workspace .. "/collector-parent.stats", runreport = false,
    include = { "titan%-compiler/", "titanc$" } })
local collector = children.new(root, frontend, workspace .. "/collector-stats")
local checkout = "package.path = " .. string.format("%q", frontend .. "/?.lua;")
    .. " .. package.path; " .. collector:init_code()
local result = require("titan-compiler.io").new_sync():run({lua, "-e", checkout,
    frontend .. "/titanc", "--help"})
assert(result.ok, result.output or result.diagnostic)
assert(collector:collect() == 1)
local first = assert(runner.data.titanc)
assert(first.max_hits > 0)
local hits = {}
for line, count in pairs(first) do hits[line] = count end
assert(collector:collect() == 0)
for line, count in pairs(hits) do assert(first[line] == count) end
local util = require "titan-compiler.util"
local filename = frontend .. "/titan-compiler/coverage.lua"
local original = assert(util.get_file_contents(filename))
assert(util.set_file_contents(filename, original .. "\n-- modified child\n"))
local ok, err = pcall(function() collector:init_code() end)
assert(not ok and err:find("copied frontend differs from tracked source", 1, true))
assert(util.set_file_contents(filename, original))
]]
            local ok, output = run({ LUA, "-e", script })
            assert.truthy(ok, output)
            local saved = assert(require("luacov.stats").load(parent_stats))
            assert.is_true(saved.titanc.max_hits > 0,
                "the parent exit-time save lost its merged child statistics")
            for filename in pairs(saved) do
                assert.is_nil(filename:find(frontend, 1, true),
                    "copied frontend path escaped exact source normalization")
            end
        end)
    end)

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

    for _, pretty in ipairs({ false, true }) do
        it("attributes evaluated and bypassed foreign decision lines with pretty-print " .. tostring(pretty), function()
            require_backend(pretty)
            fixture(function(workspace)
                write(workspace .. "/lib/lib.titan", FOREIGN_DECISIONS)
                write(workspace .. "/checks.titan", FOREIGN_CHECKS)
                local directory = workspace .. "/coverage"
                local ok, output = compile(workspace, directory, pretty)
                assert.truthy(ok, output)
                local expected = tagged_lines(FOREIGN_DECISIONS)
                local bypassed = report(directory,
                    { directory .. "/bin/checks", "--filter=test_bypassed" }, "bypassed")
                local counts = assert(bypassed["lib/lib.titan"])
                assert.equal(1, counts[expected.firstcondition])
                assert.equal(1, counts[expected.firstbody])
                assert.equal(0, counts[expected.secondcondition])
                assert.equal(0, counts[expected.thirdcondition])
                assert.equal(0, counts[expected.secondbody])
                assert.equal(0, counts[expected.thirdbody])
                assert.equal(0, counts[expected.fallback])
                assert.equal(1, counts[expected.cyclebody])
                assert.equal(1, counts[expected.cyclebreak])
                assert.equal(0, counts[expected.cycleuntil])
                assert.is_nil(counts[expected.cyclerepeat], "constant C backedge must not become an authored decision")
                local evaluated = report(directory,
                    { directory .. "/bin/checks", "--filter=test_evaluated" }, "evaluated")
                counts = assert(evaluated["lib/lib.titan"])
                assert.equal(3, counts[expected.firstcondition])
                assert.equal(1, counts[expected.firstbody])
                assert.equal(2, counts[expected.secondcondition])
                assert.equal(1, counts[expected.secondbody])
                assert.equal(1, counts[expected.thirdcondition])
                assert.equal(0, counts[expected.thirdbody])
                assert.equal(1, counts[expected.fallback])
                assert.equal(3, counts[expected.cyclebody])
                assert.equal(0, counts[expected.cyclebreak])
                assert.equal(3, counts[expected.cycleuntil])
                assert.is_nil(counts[expected.cyclerepeat])
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
            -- This invocation intentionally changes the compiler identity. Its
            -- source cannot be attributed to the byte-identical tracked CLI.
            ok, output = compile(workspace, directory, false, { "--incremental" }, nil, false)
            assert.is_false(ok)
            assert.matches("coverage build configuration changed", output)
        end)
    end)

    it("rejects changed source with an old sealed image and rebuilds despite equal timestamps", function()
        require_backend(false)
        fixture(function(workspace)
            local directory = workspace .. "/coverage"
            local ok, output = compile(workspace, directory, false)
            assert.truthy(ok, output)
            report(directory, { directory .. "/bin/checks" })
            local object = directory .. "/objects/lib.o"
            local notes = directory .. "/objects/lib.gcno"
            local old_object = assert(util.get_file_contents(object))
            local old_notes = assert(util.get_file_contents(notes))
            local old_receipt = assert(util.get_file_contents(directory .. "/objects/lib.coverage-receipt"))
            local source = workspace .. "/lib/lib.titan"
            write(source, (PRODUCTION:gsub("return input %+ 2", "return input + 3")))
            local timestamp = assert(lfs.attributes(object, "modification"))
            assert(lfs.touch(source, timestamp, timestamp))
            local host = workspace .. "/tooling/titan-coverage"
            ok, output = run({ "python3", host, "run", "--manifest", directory .. "/build.json",
                "--run", directory .. "/stale-run", "--", directory .. "/bin/checks" })
            assert.is_false(ok, output)
            assert.matches("source changed since coverage build", output, 1, true)
            assert.is_nil(lfs.attributes(directory .. "/stale-run"))
            assert.equal(old_object, util.get_file_contents(object))
            assert.equal(old_notes, util.get_file_contents(notes))
            ok, output = compile(workspace, directory, false, { "--incremental" })
            assert.truthy(ok, output)
            assert.not_equal(old_object, util.get_file_contents(object))
            assert.not_equal(old_receipt, util.get_file_contents(directory .. "/objects/lib.coverage-receipt"))
            local files = report(directory, { directory .. "/bin/checks" }, "replacement")
            assert.equal(0, files["lib/lib.titan"][tagged_lines(PRODUCTION).foreignnever])
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

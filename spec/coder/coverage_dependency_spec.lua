-- The coverage provider has no per-module dependency DAG. Rebuilding its
-- directory must therefore refresh callers of changed foreign helpers.
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

local function run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.ok, result.output or result.diagnostic or ""
end

local function write(filename, contents)
    assert.truthy(util.set_file_contents(filename, contents))
end

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

local function quote(value)
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function require_backend()
    if platform.windows then pending("GCC/gcov backend is unsupported by the Windows CLANG64 SDK") end
    local ok, output = run({ "python3", ROOT .. "/titan-coverage", "probe",
        "--cc", CC, "--gcov", GCOV })
    if not ok then
        if os.getenv("TITAN_COVERAGE_TEST_CC") or os.getenv("TITAN_COVERAGE_TEST_GCOV") then
            assert.truthy(ok, output)
        end
        pending("native coverage tools unavailable: " .. output)
    end
end

local function checks(expected)
    return [[local test = import "test"
local caller = import "caller"
function test_foreign_dependency(_context: test.Context)
  test.assert(caller.result() == ]] .. expected .. [[,
      "coverage caller retained the previous foreign helper body")
end
]]
end

describe("aggregate coverage dependency freshness", function()
    it("refreshes a selected caller when only its unselected foreign helper changes", function()
        require_backend()
        local workspace = temporary.name("-coverage-dependency")
        assert(lfs.mkdir(workspace))
        local tested, err = xpcall(function()
            local frontend = workspace .. "/tooling"
            assert(lfs.mkdir(frontend))
            for _, name in ipairs({ "titan-compiler", "c-parser", "titanc", "titan-coverage", "Makefile" }) do
                copy(ROOT .. "/" .. name, frontend .. "/" .. name)
            end
            assert(lfs.mkdir(frontend .. "/spec"))
            assert(lfs.mkdir(frontend .. "/spec/support"))
            copy(ROOT .. "/spec/support/stdlib_test_modules.mk",
                frontend .. "/spec/support/stdlib_test_modules.mk")
            copy(ROOT .. "/titan-coverage", workspace .. "/titan-coverage")
            write(frontend .. "/frontend.lua", "package.path = "
                .. string.format("%q", frontend .. "/?.lua;") .. " .. package.path\n"
                .. "dofile(" .. string.format("%q", frontend .. "/titanc") .. ")\n")
            write(workspace .. "/helper.titan", "foreign function amount(): int\n  return 3\nend\n")
            write(workspace .. "/caller.titan", [[local helper = import "helper.titan"
function result(): integer
  return helper.amount()
end
]])
            write(workspace .. "/checks.titan", checks(3))
            local directory = workspace .. "/coverage"
            local command = { "env", "PREFIX=" .. PREFIX, "TITAN_ROCKS_ROOT=" .. PREFIX,
                "TITAN_NO_LINE_DIRECTIVES=0", "TITAN_EXTRA_CPPFLAGS=",
                "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=", "CC=" .. CC,
                "make", "--no-print-directory", "-C", workspace, "-f", frontend .. "/Makefile",
                "titan-native-coverage-build", "STDLIB_NATIVE_PREREQS=",
                "TITAN_TEST_FIXTURE_OUTPUTS=", "TITAN_TEST_NATIVE_OBJECTS=",
                "STDLIB_ROOTS=caller", "TITAN_COVERAGE_MODULES=caller",
                "TITAN_STDLIB_TEST_ROOTS=checks", "TITAN_COVERAGE_OBJECTS=",
                "TITAN_STDLIB_TEST_PROGRAM_OUTPUT=checks",
                "TITAN_COVERAGE_TEST_SOURCE_ROOT=" .. workspace,
                "TITAN_COVERAGE_TEST_INPUTS=checks.titan", "TITAN_COVERAGE_CPPFLAGS=",
                "STDLIB_UV_LDFLAGS=", "STDLIB_OPENSSL_LDFLAGS=",
                "TITAN_COVERAGE_GCOV=" .. GCOV, "TITAN_COVERAGE_PYTHON=python3",
                "TITAN_COVERAGE_BUILD_DIR=" .. directory,
                "TEST_TITANC=" .. quote(LUA) .. " " .. quote(frontend .. "/frontend.lua") }
            local function build_and_run(name)
                local ok, output = run(command)
                assert.truthy(ok, output)
                assert.is_nil(lfs.attributes(directory .. "/objects/caller.gcda"),
                    "compiler metadata prototypes wrote counters beside the measured object")
                assert.truthy(lfs.attributes(directory .. "/preparation-counters" .. directory
                    .. "/objects/caller.gcda"),
                    "compiled-provider preparation did not retain its separate counters")
                ok, output = run({ "env", "TITAN_PATH_0_6=" .. directory,
                    "LUA_PATH_5_5=" .. directory .. "/shims/?.lua;" .. PREFIX
                        .. "/share/lua/5.5/?.lua;" .. PREFIX .. "/share/lua/5.5/?/init.lua;;",
                    "LUA_CPATH_5_5=" .. directory .. "/?.so;" .. PREFIX
                        .. "/lib/titan/0.6/?.so;" .. PREFIX .. "/lib/lua/5.5/?.so;;",
                    "python3", workspace .. "/titan-coverage", "run",
                    "--manifest", directory .. "/build.json", "--run", workspace .. "/" .. name,
                    "--timeout", "30", "--", directory .. "/consumer/checks" })
                assert.truthy(ok, output)
                local receipt = assert(util.get_file_contents(workspace .. "/" .. name .. "/run.json"))
                assert.truthy(receipt:find('"state": "complete"', 1, true), receipt)
            end
            build_and_run("before")
            local before = assert(util.get_file_contents(directory .. "/objects/caller.o"))
            write(workspace .. "/helper.titan", "foreign function amount(): int\n  return 7\nend\n")
            -- Update only the oracle and the dependency. The selected caller's
            -- source bytes and its output directory deliberately stay identical.
            write(workspace .. "/checks.titan", checks(7))
            build_and_run("after")
            assert.is_not.equal(before,
                assert(util.get_file_contents(directory .. "/objects/caller.o")))
            -- Lua children execute these provider shims. They are executable
            -- build inputs even though they add no measured Titan source lines.
            local shim = directory .. "/shims/caller.lua"
            local ok, output = run({ "python3", "-c", [[import json,sys
manifest=json.load(open(sys.argv[1], encoding="utf-8"))
assert any(item["path"] == sys.argv[2] and item.get("sha256")
           for item in manifest["link_inventory"]), "provider shim is not sealed"
]], directory .. "/build.json", shim })
            assert.truthy(ok, output)
            write(shim, assert(util.get_file_contents(shim)) .. "\n-- changed after sealing\n")
            ok, output = run({ "python3", workspace .. "/titan-coverage", "run",
                "--manifest", directory .. "/build.json", "--run", workspace .. "/tampered",
                "--", directory .. "/consumer/checks" })
            assert.falsy(ok, output)
            assert.truthy(output:find("linked input changed since coverage build", 1, true), output)
            ok, output = run({ "python3", workspace .. "/titan-coverage", "report",
                "--manifest", directory .. "/build.json", "--run", workspace .. "/after",
                "--output", workspace .. "/tampered-report" })
            assert.falsy(ok, output)
            assert.truthy(output:find("linked input changed since coverage build", 1, true), output)
        end, debug.traceback)
        remove_tree(workspace)
        if not tested then error(err, 0) end
    end)
end)

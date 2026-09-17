local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local FIXTURE = "spec/fixtures/test_runner"
local ROOT = "test_runner_fixture"
local DEPENDENCY = "test_runner_dependency"
local EDGE = "test_runner_edge"
local FOLDER = "test_runner_folder"
local PREFIXED = "titan.test.user"
local RUNNER_PREFIXED = "titan.test.runner.user"
local MUTATION = "test_runner_mutation"
local NESTED = "nested.tests"
local BOOTSTRAP = "test_runner_bootstrap"
local STATIC = "test_runner_static"

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local prefix_lua = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. "/bin/lua") or nil
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua or "lua"
local prefix_titanc = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. "/bin/titanc") or nil
local INSTALLED_TITANC = prefix_titanc and file_exists(prefix_titanc) and
    prefix_titanc or "titanc"

local function shell_command(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv)
    local pipe = assert(io.popen(shell_command(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

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

local ARTIFACTS = {
    ROOT,
    FIXTURE .. "/" .. ROOT .. ".c",
    FIXTURE .. "/" .. ROOT .. ".o",
    FIXTURE .. "/" .. DEPENDENCY .. ".c",
    FIXTURE .. "/" .. DEPENDENCY .. ".o",
    FIXTURE .. "/" .. EDGE .. ".c",
    FIXTURE .. "/" .. EDGE .. ".o",
    FIXTURE .. "/" .. FOLDER .. "/" .. FOLDER .. ".c",
    FIXTURE .. "/" .. FOLDER .. "/" .. FOLDER .. ".o",
    FIXTURE .. "/titan/test/user.c",
    FIXTURE .. "/titan/test/user.o",
    FIXTURE .. "/titan/test/runner/user.c",
    FIXTURE .. "/titan/test/runner/user.o",
    FIXTURE .. "/" .. MUTATION .. ".c",
    FIXTURE .. "/" .. MUTATION .. ".o",
    ROOT .. "__test_support.c",
    ROOT .. "__test_support.o",
    ROOT .. "__test_runner.c",
    ROOT .. "__test_runner.o",
    ROOT .. "__test_entrypoint.c",
    ROOT .. "__test_entrypoint.o",
}

local COLLISION_ARTIFACTS = {
    "test_runner_collision",
    "test_runner_collision.titan",
    "test_runner_collision.c",
    "test_runner_collision.o",
    "test_runner_collision__test_support.titan",
    "test_runner_collision__test_support.c",
    "test_runner_collision__test_support.o",
    "test_runner_collision__test_runner.titan",
    "test_runner_collision__test_runner.c",
    "test_runner_collision__test_runner.o",
    "test_runner_collision__test_entrypoint.titan",
    "test_runner_collision__test_entrypoint.c",
    "test_runner_collision__test_entrypoint.o",
}

local NESTED_ARTIFACTS = {
    FIXTURE .. "/nested/tests/tests.c",
    FIXTURE .. "/nested/tests/tests.o",
    "nested/tests__main",
    "nested/tests__main__test_support.c",
    "nested/tests__main__test_support.o",
    "nested/tests__main__test_runner.c",
    "nested/tests__main__test_runner.o",
    "nested/tests__main__test_entrypoint.c",
    "nested/tests__main__test_entrypoint.o",
}

local BOOTSTRAP_ARTIFACTS = {
    BOOTSTRAP,
    FIXTURE .. "/" .. BOOTSTRAP .. ".c",
    FIXTURE .. "/" .. BOOTSTRAP .. ".o",
    BOOTSTRAP .. "__entrypoint.c",
    BOOTSTRAP .. "__entrypoint.o",
}

local STATIC_ARTIFACTS = {
    STATIC,
    FIXTURE .. "/" .. STATIC .. ".c",
    FIXTURE .. "/" .. STATIC .. ".o",
    STATIC .. "__test_support.c",
    STATIC .. "__test_support.o",
    STATIC .. "__test_runner.c",
    STATIC .. "__test_runner.o",
    STATIC .. "__test_entrypoint.c",
    STATIC .. "__test_entrypoint.o",
}

local SUPPORT_ROOT_ARTIFACTS = {
    "titan/test",
    "titan/test__test_support.c",
    "titan/test__test_support.o",
    "titan/test__test_runner.c",
    "titan/test__test_runner.o",
    "titan/test__test_entrypoint.c",
    "titan/test__test_entrypoint.o",
}

local function remove_artifact(path)
    os.remove(path)
    local stem = path:match("^(.*)[.]c$")
    if stem then
        os.remove(stem .. ".ffi.h")
        os.remove(stem .. ".titan.h")
    end
end

local function clean_nested()
    for _, path in ipairs(NESTED_ARTIFACTS) do remove_artifact(path) end
    remove_tree("nested/tests__main.dSYM")
    lfs.rmdir("nested")
end

local function clean()
    for _, path in ipairs(ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(COLLISION_ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(BOOTSTRAP_ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(STATIC_ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(SUPPORT_ROOT_ARTIFACTS) do remove_artifact(path) end
    clean_nested()
    remove_tree(ROOT .. ".dSYM")
    remove_tree(BOOTSTRAP .. ".dSYM")
    remove_tree(STATIC .. ".dSYM")
    remove_tree("titan/test.dSYM")
    remove_artifact("test_runner_progname__entrypoint.c")
    os.remove("test_runner_progname__entrypoint.o")
    os.remove("test_runner_progname__main")
    remove_tree("test_runner_progname__main.dSYM")
    os.remove("test_runner_hierarchy.titan")
    remove_artifact("test_runner_hierarchy.c")
    os.remove("test_runner_hierarchy.o")
    remove_artifact("test_runner_hierarchy__test_support.c")
    os.remove("test_runner_hierarchy__test_support.o")
    remove_artifact("test_runner_hierarchy__test_runner.c")
    os.remove("test_runner_hierarchy__test_runner.o")
    remove_artifact("test_runner_hierarchy__test_entrypoint.c")
    os.remove("test_runner_hierarchy__test_entrypoint.o")
    os.remove("test_runner_hierarchy/child.titan")
    remove_artifact("test_runner_hierarchy/child.c")
    os.remove("test_runner_hierarchy/child.o")
    lfs.rmdir("test_runner_hierarchy")
    os.remove("url")
    remove_artifact("url__test_support.c")
    os.remove("url__test_support.o")
    remove_artifact("url__test_runner.c")
    os.remove("url__test_runner.o")
    remove_artifact("url__test_entrypoint.c")
    os.remove("url__test_entrypoint.o")
    remove_tree("url.dSYM")
end

local function compile_suite()
    return run({
        "env",
        "MAKE=true",
        "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        LUA,
        "-E",
        "-e",
        [[package.path = "./?.lua;./?/init.lua;" .. package.path; ]] ..
        [[package.cpath = "./titan-runtime/bootstrap/?.so;" .. package.cpath]],
        "./titanc",
        "--test",
        "--no-uv-bootstrap",
        "--verbose",
        "--tree", FIXTURE,
        ROOT, EDGE, FOLDER, PREFIXED, RUNNER_PREFIXED, MUTATION,
    })
end

local function compile_installed(root, ...)
    local argv = {
        "env",
        "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        INSTALLED_TITANC,
        "--test",
    }
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    argv[#argv + 1] = "--tree"
    argv[#argv + 1] = FIXTURE
    argv[#argv + 1] = root
    return run(argv)
end

local function working_titanc_arguments()
    return {
        "env",
        "MAKE=true",
        "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        LUA,
        "-E",
        "-e",
        [[package.path = "./?.lua;./?/init.lua;" .. package.path; ]] ..
        [[package.cpath = "./titan-runtime/bootstrap/?.so;" .. package.cpath]],
        "./titanc",
    }
end

local function run_suite(...)
    local argv = { "./" .. ROOT }
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    return run(argv)
end

local function assert_order(output, ...)
    local previous = 0
    for _, needle in ipairs({ ... }) do
        local position = assert(output:find(needle, previous + 1, true),
            "missing '" .. needle .. "' in:\n" .. output)
        assert.is_true(position > previous, output)
        previous = position
    end
end

local function compile_line(output, source)
    for line in output:gmatch("[^\n]+") do
        if line:find("'-c'", 1, true) and
           line:find(source, 1, true) then
            return line
        end
    end
    return nil
end

describe("native Titan test runner", function()
    describe("shared compiled suite", function()
        local compiler_output

        lazy_setup(function()
            clean()
            local ok, output, why, code = compile_suite()
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            compiler_output = output
        end)

        lazy_teardown(clean)

    it("builds one ordinary standalone with owned synthetic artifacts",
       function()
        assert.is_true(file_exists(ROOT))
        for _, path in ipairs(ARTIFACTS) do
            assert.is_true(file_exists(path), path)
        end
        assert.falsy(compiler_output:find("multiple main", 1, true),
            compiler_output)
    end)

    it("calls test-runner main directly when async bootstrap is disabled",
       function()
        local entrypoint = read_file(ROOT .. "__test_entrypoint.c")
        assert.truthy(entrypoint:find(
            "if (1 || lua_isnil(L, -1))", 1, true), entrypoint)
        assert.truthy(entrypoint:find(
            "lua_call(L, 1, 1);", 1, true), entrypoint)
    end)

    it("applies sibling-call preservation only to discovered test modules",
       function()
        local flag = "'-fno-optimize-sibling-calls'"
        local root_line = assert(compile_line(compiler_output,
            FIXTURE .. "/" .. ROOT .. ".c"), compiler_output)
        local dependency_line = assert(compile_line(compiler_output,
            FIXTURE .. "/" .. DEPENDENCY .. ".c"), compiler_output)
        local edge_line = assert(compile_line(compiler_output,
            FIXTURE .. "/" .. EDGE .. ".c"), compiler_output)
        local folder_line = assert(compile_line(compiler_output,
            FIXTURE .. "/" .. FOLDER .. "/" .. FOLDER .. ".c"),
            compiler_output)
        local prefixed_line = assert(compile_line(compiler_output,
            FIXTURE .. "/titan/test/user.c"), compiler_output)
        local support_line = assert(compile_line(compiler_output,
            ROOT .. "__test_support.c"), compiler_output)
        local runner_line = assert(compile_line(compiler_output,
            ROOT .. "__test_runner.c"), compiler_output)
        local entrypoint_line = assert(compile_line(compiler_output,
            ROOT .. "__test_entrypoint.c"), compiler_output)
        assert.truthy(root_line:find(flag, 1, true), root_line)
        assert.truthy(dependency_line:find(flag, 1, true), dependency_line)
        assert.truthy(edge_line:find(flag, 1, true), edge_line)
        assert.truthy(folder_line:find(flag, 1, true), folder_line)
        assert.truthy(prefixed_line:find(flag, 1, true), prefixed_line)
        assert.falsy(support_line:find(flag, 1, true), support_line)
        assert.falsy(runner_line:find(flag, 1, true), runner_line)
        assert.falsy(entrypoint_line:find(flag, 1, true), entrypoint_line)
    end)

    it("discovers the source closure in deterministic order and runs all phases",
       function()
        local ok, output, why, code = run_suite()
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(1, code)
        assert_order(output,
            "[ RUN      ] test_runner_dependency.test_dependency",
            "[ RUN      ] test_runner_fixture.test_cleanup",
            "[ RUN      ] test_runner_fixture.test_cleanup.child",
            "[       OK ] test_runner_fixture.test_cleanup.child",
            "[       OK ] test_runner_fixture.test_cleanup",
            "[ RUN      ] test_runner_fixture.test_cleanup_failure",
            "cleanup failed deliberately",
            "[  FAILED  ] test_runner_fixture.test_cleanup_failure",
            "[ RUN      ] test_runner_fixture.test_cleanup_followup",
            "[       OK ] test_runner_fixture.test_cleanup_followup")
        assert_order(output,
            "[ RUN      ] test_runner_fixture.test_parent_failure",
            "[  SKIPPED ] test_runner_fixture.test_parent_failure.not_run " ..
                "(parent failed)",
            "[  FAILED  ] test_runner_fixture.test_parent_failure")
        assert_order(output,
            "[ RUN      ] test_runner_fixture.test_parent_skip",
            "[  SKIPPED ] test_runner_fixture.test_parent_skip.not_run " ..
                "(parent skipped: parent skip reason)",
            "[  SKIPPED ] test_runner_fixture.test_parent_skip " ..
                "(parent skip reason)")
        assert_order(output,
            "[ RUN      ] test_runner_edge.test_executed_child_failure_isolated.fails",
            "[  FAILED  ] test_runner_edge.test_executed_child_failure_isolated.fails",
            "[ RUN      ] test_runner_edge.test_executed_child_failure_isolated.later",
            "[       OK ] test_runner_edge.test_executed_child_failure_isolated.later",
            "[       OK ] test_runner_edge.test_executed_child_failure_isolated")
        assert_order(output,
            "[ RUN      ] test_runner_fixture.test_pass",
            "[----------] test_runner_fixture.test_pass: fixture log",
            "[       OK ] test_runner_fixture.test_pass")
        assert.truthy(output:find("[==========] 43 tests ran.", 1, true), output)
        assert.truthy(output:find("[  PASSED  ] 26 tests.", 1, true), output)
        assert.truthy(output:find("[  SKIPPED ] 5 tests.", 1, true), output)
        assert.truthy(output:find("[  FAILED  ] 12 tests.", 1, true), output)
        assert.falsy(output:find("test_local_is_ignored", 1, true), output)
        assert.falsy(output:find("test_wrong_parameter", 1, true), output)
    end)

    it("uses Lua-pattern OR filters and omits nonmatching tests", function()
        local ok, output = run_suite(
            "-f", "test_dependency$", "--filter=test_pass$")
        assert.truthy(ok, output)
        assert_order(output,
            "[ RUN      ] test_runner_dependency.test_dependency",
            "[       OK ] test_runner_dependency.test_dependency",
            "[ RUN      ] test_runner_fixture.test_pass",
            "[       OK ] test_runner_fixture.test_pass")
        assert.truthy(output:find("[==========] 2 tests ran.", 1, true), output)
        assert.falsy(output:find("test_skip", 1, true), output)
    end)

    it("reports help and command-line errors with distinct statuses", function()
        local ok, output, why, code = run_suite("--help")
        assert.truthy(ok, output)
        assert.truthy(output:find("Usage:", 1, true), output)

        ok, output, why, code = run_suite("-f")
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(2, code)
        assert.truthy(output:find("-f requires a pattern", 1, true), output)

        ok, output, why, code = run_suite("--filter=[")
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(2, code)
        assert.truthy(output:find("invalid Lua pattern", 1, true), output)
    end)

    it("prints concise failures by default and raw frames when verbose",
       function()
        local ok, output = run_suite("--filter=test_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "test_runner_fixture.titan:", 1, true), output)
        assert.truthy(output:find(
            "in test_runner_fixture.test_failure: failed deliberately",
            1, true), output)
        assert.falsy(output:find("stack traceback:", 1, true), output)

        ok, output = run_suite("--verbose", "--filter=test_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find("stack traceback:\n\t", 1, true), output)
        assert.truthy(output:find(
            "in test_runner_fixture.test_failure", 1, true), output)
        assert.truthy(output:find(
            "in titan.test.runner.execute", 1, true), output)

        ok, output = run_suite("--filter=test_prefixed_location$")
        assert.truthy(ok, output)
        assert.truthy(output:find(
            "[       OK ] titan.test.user.test_prefixed_location",
            1, true), output)

        ok, output = run_suite(
            "--filter=test_runner_prefixed_location$")
        assert.truthy(ok, output)
        assert.truthy(output:find(
            "[       OK ] " ..
                "titan.test.runner.user.test_runner_prefixed_location",
            1, true), output)

        ok, output = run_suite(
            "--filter=test_location_after_lua_global_mutation$")
        assert.truthy(ok, output)
        assert.truthy(output:find(
            "[       OK ] " ..
                "test_runner_mutation." ..
                "test_location_after_lua_global_mutation",
            1, true), output)

        ok, output = run_suite(
            "--filter=test_failure_after_lua_global_mutation$")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "in test_runner_mutation.test_failure_after_lua_global_mutation: " ..
                "failure after Lua global mutation",
            1, true), output)
    end)

    it("enforces context phases and drains every cleanup", function()
        local ok, output = run_suite(
            "--filter=test_child_registers_parent_cleanup")
        assert.truthy(ok, output)
        assert_order(output,
            "[       OK ] " ..
                "test_runner_edge.test_child_registers_parent_cleanup.child",
            "[       OK ] " ..
                "test_runner_edge.test_child_registers_parent_cleanup")

        ok, output = run_suite("--filter=test_captured_parent")
        assert.falsy(ok, output)
        assert_order(output,
            "[ RUN      ] test_runner_edge.test_captured_parent",
            "[ RUN      ] test_runner_edge.test_captured_parent.misuse",
            "cannot register subtest after test body finishes",
            "[  FAILED  ] test_runner_edge.test_captured_parent.misuse",
            "[       OK ] test_runner_edge.test_captured_parent")

        ok, output = run_suite("--filter=test_all_cleanups_attempted")
        assert.falsy(ok, output)
        assert_order(output,
            "[  FAILED  ] test_runner_edge.test_all_cleanups_attempted",
            "[       OK ] " ..
                "test_runner_edge.test_all_cleanups_attempted_followup")

        ok, output = run_suite("--filter=test_primary_failure_survives_cleanup$")
        assert.falsy(ok, output)
        assert.truthy(output:find("primary body failure", 1, true), output)
        assert.falsy(output:find("secondary cleanup failure", 1, true), output)

        ok, output = run_suite("--filter=test_skip_cleanup_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find("cleanup overrides skip", 1, true), output)
        assert.falsy(output:find(
            "[  SKIPPED ] test_runner_edge.test_skip_cleanup_failure",
            1, true), output)
    end)

    it("preserves duplicate subtests and filters descendants independently",
       function()
        local ok, output = run_suite("--filter=test_duplicate_subtests")
        assert.truthy(ok, output)
        local _, occurrences = output:gsub(
            "%[ RUN      %] test_runner_edge%.test_duplicate_subtests%.same",
            "")
        assert.equal(2, occurrences)
        assert.truthy(output:find("[==========] 3 tests ran.", 1, true), output)

        ok, output = run_suite("--filter=test_nested_subtests$")
        assert.truthy(ok, output)
        assert.truthy(output:find("[==========] 1 test ran.", 1, true), output)
        assert.falsy(output:find(".child", 1, true), output)
    end)

    it("renders arbitrary raised values and keeps swallowed errors handled",
       function()
        local ok, output = run_suite("--filter=test_integer_error$")
        assert.falsy(ok, output)
        assert.truthy(output:find(": 17", 1, true), output)

        ok, output = run_suite("--filter=test_swallowed_markers$")
        assert.truthy(ok, output)
        assert.truthy(output:find(
            "[       OK ] test_runner_edge.test_swallowed_markers",
            1, true), output)
    end)

    it("discards test results and ignores an application main", function()
        local ok, output = run_suite("--filter=test_result$")
        assert.truthy(ok, output)
        assert.truthy(output:find(
            "[       OK ] test_runner_fixture.test_result", 1, true), output)
    end)
    end)

    describe("standalone compilation cases", function()
        setup(clean)
        teardown(clean)

    it("ignores an installed bootstrap only when explicitly disabled",
       function()
        local direct_argv = working_titanc_arguments()
        direct_argv[#direct_argv + 1] = "--no-uv-bootstrap"
        direct_argv[#direct_argv + 1] = "--tree"
        direct_argv[#direct_argv + 1] = FIXTURE
        direct_argv[#direct_argv + 1] = BOOTSTRAP
        local compiled, output = run(direct_argv)
        assert.truthy(compiled, output)

        local ok, direct_output, why, code = run({
            "./" .. BOOTSTRAP, "one", "two",
        })
        assert.falsy(ok, direct_output)
        assert.equal("exit", why)
        assert.equal(37, code)
        assert.falsy(direct_output:find("synthetic bootstrap invoked", 1, true),
            direct_output)

        local default_argv = working_titanc_arguments()
        default_argv[#default_argv + 1] = "--tree"
        default_argv[#default_argv + 1] = FIXTURE
        default_argv[#default_argv + 1] = BOOTSTRAP
        compiled, output = run(default_argv)
        assert.truthy(compiled, output)

        ok, output, why, code = run({ "./" .. BOOTSTRAP })
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(1, code)
        assert.truthy(output:find("synthetic bootstrap invoked", 1, true),
            output)
    end)

    it("rejects disabled async bootstrap for library output", function()
        local argv = working_titanc_arguments()
        argv[#argv + 1] = "--no-uv-bootstrap"
        argv[#argv + 1] = "--tree"
        argv[#argv + 1] = FIXTURE
        argv[#argv + 1] = DEPENDENCY
        local ok, output = run(argv)
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--no-uv-bootstrap is only valid when compiling a standalone executable",
            1, true), output)
    end)

    it("keeps an explicit canonical support root in logical outputs", function()
        local ok, output, why, code = compile_installed("titan.test")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.is_true(file_exists("titan/test"))
        local run_ok, run_output = run({ "./titan/test" })
        assert.truthy(run_ok, run_output)
        assert.truthy(run_output:find("[==========] 0 tests ran.", 1, true),
            run_output)
        assert.truthy(run_output:find("[  PASSED  ] 0 tests.", 1, true),
            run_output)
    end)

    it("falls back from an overlapping static provider to its DSO", function()
        local ok, output, why, code = compile_installed(STATIC, "--static")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local run_ok, run_output = run({
            "env", "LUA_CPATH_5_5=" .. package.cpath, "./" .. STATIC,
        })
        assert.truthy(run_ok, run_output)
        assert.truthy(run_output:find(
            "[       OK ] test_runner_static.test_static_fallback",
            1, true), run_output)
    end)

    it("rejects synthetic output collisions before generating C", function()
        local suite = "test_runner_collision"
        local owner_source = suite .. [[.titan]]
        local owner_contents = [[local test = import "test"
function test_collision(context: test.Context)
  test.assert(true)
end
]]
        local suffix = "__test_support"
        local colliding = suite .. suffix
        local colliding_source = colliding .. ".titan"
        assert(io.open(owner_source, "w")):write(owner_contents):close()
        assert(io.open(colliding_source, "w")):
            write("local marker: integer = 1\n"):close()

        local argv = working_titanc_arguments()
        argv[#argv + 1] = "--test"
        argv[#argv + 1] = suite
        argv[#argv + 1] = colliding
        local ok, output = run(argv)
        assert.falsy(ok, output)
        assert.truthy(output:find("aliases output", 1, true), output)
        assert.is_false(file_exists(suite .. ".c"))
        assert.is_false(file_exists(colliding .. ".c"))
        assert.is_false(file_exists(suite .. suffix .. ".o"))

        os.remove(owner_source)
        os.remove(colliding_source)
    end)

    it("rejects executable and source-output hierarchy collisions early",
       function()
        local root = "test_runner_hierarchy"
        local source = assert(io.open(root .. ".titan", "w"))
        source:write([[local test = import "test"
function test_root(context: test.Context)
  test.assert(true)
end
]])
        source:close()
        assert(lfs.mkdir(root))
        source = assert(io.open(root .. "/child.titan", "w"))
        source:write("local marker: integer = 1\n")
        source:close()

        local argv = working_titanc_arguments()
        argv[#argv + 1] = "--test"
        argv[#argv + 1] = root
        argv[#argv + 1] = root .. ".child"
        local ok, output = run(argv)
        assert.falsy(ok, output)
        assert.truthy(output:find("standalone executable", 1, true), output)
        assert.is_false(file_exists(root .. ".c"))
        assert.is_false(file_exists(root .. "/child.c"))
        assert.is_false(file_exists(root .. "__test_support.c"))

        os.remove(root .. ".titan")
        os.remove(root .. "/child.titan")
        lfs.rmdir(root)
    end)

    it("reports reserved shorthand owners as an ordinary compiler error",
       function()
        local workspace = os.tmpname()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local source = assert(io.open(workspace .. "/url.titan", "w"))
        source:write([[local test = import "test"
function test_owner(context: test.Context)
  test.assert(true)
end
]])
        source:close()

        local argv = working_titanc_arguments()
        argv[#argv + 1] = "--test"
        argv[#argv + 1] = "--tree"
        argv[#argv + 1] = workspace
        argv[#argv + 1] = "url"
        local ok, output = run(argv)
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "test owner module 'url' is reserved", 1, true), output)
        assert.falsy(output:find("stack traceback:", 1, true), output)
        assert.is_false(file_exists("url"))
        assert.is_false(file_exists("url__test_runner.c"))

        remove_tree(workspace)
    end)

    it("retains the logical program name for an ordinary folder main",
       function()
        local root = "test_runner_progname"
        local workspace = os.tmpname()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        assert(lfs.mkdir(workspace .. "/" .. root))
        local source = assert(io.open(
            workspace .. "/" .. root .. "/" .. root .. ".titan", "w"))
        source:write([[function main(args: {string}): integer
  raise "folder program boom"
end
]])
        source:close()

        local argv = working_titanc_arguments()
        argv[#argv + 1] = "--tree"
        argv[#argv + 1] = workspace
        argv[#argv + 1] = root
        local ok, output = run(argv)
        assert.truthy(ok, output)
        local executable = root .. "__main"
        local run_ok, run_output = run({ "./" .. executable })
        assert.falsy(run_ok, run_output)
        assert.truthy(run_output:find(
            root .. ": folder program boom", 1, true), run_output)
        assert.falsy(run_output:find(
            root .. "__main: folder program boom", 1, true), run_output)

        remove_tree(workspace)
    end)

    it("creates missing parents without deleting unrelated parent contents",
       function()
        assert(lfs.mkdir("nested"))
        local sentinel = assert(io.open("nested/README", "w"))
        sentinel:write("unrelated parent content\n")
        sentinel:close()
        local ok, output, why, code = compile_installed(NESTED)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local run_ok, run_output = run({ "./nested/tests__main" })
        assert.truthy(run_ok, run_output)
        assert.truthy(run_output:find(
            "[       OK ] nested.tests.test_nested_output", 1, true),
            run_output)
        clean_nested()
        local preserved = assert(io.open("nested/README", "r"))
        local preserved_contents = preserved:read("*a")
        preserved:close()
        assert.equal("unrelated parent content\n", preserved_contents)
        os.remove("nested/README")
        assert(lfs.rmdir("nested"))
    end)

    end)
end)

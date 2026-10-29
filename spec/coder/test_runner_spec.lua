local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"
local async_stdlib = require "spec.support.async_stdlib"
local objectmetadata = require "titan-compiler.objectmetadata"

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
    (os.getenv("PREFIX") .. (platform.windows and "/bin/lua.exe" or "/bin/lua")) or nil
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua or
    (platform.windows and "lua.exe" or "lua")
local prefix_titanc = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. (platform.windows and
        ("/lib/luarocks/rocks-5.5/titan/" .. driver.TITAN_VERSION .. "-1/bin/titanc") or
        "/bin/titanc")) or nil
local INSTALLED_TITANC = prefix_titanc and file_exists(prefix_titanc) and
    prefix_titanc or "titanc"

local function run(argv)
    local result = compiler_io.new_sync():run(argv)
    local output = result.output or result.diagnostic or ""
    if platform.windows then
        output = output:gsub("\r\n", "\n")
        output = output:gsub('%^"(.-)%^"', function(word)
            return assert(cdriver.shell_quote((word:gsub("%^(.)", "%1"))))
        end)
    end
    return result.ok, output, result.why, result.status
end

local function run_program(argv)
    local prefix = require("spec.support.installed_prefix").active()
    -- Retain launcher-relative application DLL lookup through the defaults.
    local command = { "env", "TITAN_PATH_0_6=" ..
        prefix .. "/lib/titan/0.6;;" }
    if platform.windows then
        table.insert(command, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6")
    end
    for _, argument in ipairs(argv) do command[#command + 1] = argument end
    return run(command)
end

local function executable(modname, unix_path)
    if platform.windows then
        return assert(driver.windows_program_paths(modname)).executable
    end
    return unix_path or modname:gsub("%.", "/")
end

local function clean_program(modname)
    if not platform.windows then return end
    local paths = assert(driver.windows_program_paths(modname))
    os.remove(paths.executable)
    os.remove(paths.provider)
    os.remove(paths.provider .. ".def")
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

local function synthetic_targets(output_root, owner)
    local targets = {}
    local links = output_root .. "/.titan-links"
    if lfs.attributes(links, "mode") ~= "directory" then return targets end
    for key in lfs.dir(links) do
        if #key == 64 and key:match("^[0-9a-f]+$") then
            local directory = links .. "/" .. key
            for _, suffix in ipairs({
                "__test_runner.c", "__test_entrypoint.c", "__entrypoint.c",
            }) do
                if file_exists(directory .. "/synthetic/" .. owner .. suffix) then
                    targets[#targets + 1] = directory
                    break
                end
            end
        end
    end
    return targets
end

local function synthetic_file(output_root, owner, suffix)
    local targets = synthetic_targets(output_root, owner)
    assert.equal(1, #targets, owner)
    return targets[1] .. "/synthetic/" .. owner .. suffix
end
local ARTIFACTS = {
    executable(ROOT),
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
}

local BOOTSTRAP_ARTIFACTS = {
    BOOTSTRAP,
    FIXTURE .. "/" .. BOOTSTRAP .. ".c",
    FIXTURE .. "/" .. BOOTSTRAP .. ".o",
}

local STATIC_ARTIFACTS = {
    STATIC,
    FIXTURE .. "/" .. STATIC .. ".c",
    FIXTURE .. "/" .. STATIC .. ".o",
}

local function remove_artifact(path)
    local stem = path:match("^(.*)[.]c$")
    if stem then
        local object = io.open(stem .. ".o", "rb")
        if object then
            local record = objectmetadata.read(object:read("*a"), stem .. ".o")
            object:close()
            local native = record and record.object_metadata
            if native and objectmetadata.validate_parts(native) then
                for _, part in ipairs(native.parts) do
                    os.remove(stem .. part.c_suffix)
                    os.remove(stem .. part.object_suffix)
                end
            end
        end
        os.remove(stem .. ".priv.h")
        os.remove(stem .. ".ffi.h")
        os.remove(stem .. ".titan.h")
        if platform.windows then
            os.remove(path .. ".manifest")
            os.remove(path .. ".rc")
            os.remove(path .. ".res")
        end
    end
    os.remove(path)
end

local function clean_nested()
    for _, path in ipairs(NESTED_ARTIFACTS) do remove_artifact(path) end
    remove_tree("nested/tests__main.dSYM")
    lfs.rmdir("nested")
    clean_program(NESTED)
end

local function clean()
    for _, path in ipairs(ARTIFACTS) do remove_artifact(path) end
    for _, output_root in ipairs({ FIXTURE, "." }) do
        for _, owner in ipairs({
            ROOT, "tests", BOOTSTRAP, STATIC, "test_runner_collision",
            "test_runner_progname", "test_runner_hierarchy", "url",
        }) do
            for _, directory in ipairs(synthetic_targets(output_root, owner)) do
                remove_tree(directory)
            end
        end
    end
    for _, path in ipairs(COLLISION_ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(BOOTSTRAP_ARTIFACTS) do remove_artifact(path) end
    for _, path in ipairs(STATIC_ARTIFACTS) do remove_artifact(path) end
    clean_nested()
    remove_tree(ROOT .. ".dSYM")
    remove_tree(BOOTSTRAP .. ".dSYM")
    remove_tree(STATIC .. ".dSYM")
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
    for _, modname in ipairs({ ROOT, BOOTSTRAP, STATIC,
            "test_runner_progname", "test_runner_hierarchy", "test_runner_collision", "url" }) do
        clean_program(modname)
    end
end

local lua_workspace
local function source_lua_arguments(argv)
    if platform.windows then
        table.insert(argv, 2, "TITAN_ROOT=" ..
            require("spec.support.installed_prefix").active())
    else
        -- The checkout profile's SDK override belongs to this Busted process,
        -- not these source-layout CLI probes, which deliberately pass --lua.
        table.insert(argv, 2, "-u")
        table.insert(argv, 3, "TITAN_ROOT")
        -- Source-checkout compilers need the matching installed Lua SDK, even
        -- when the checkout itself has never built Lua.
        lua_workspace = lua_workspace or async_stdlib.workspace("test-runner")
        argv[#argv + 1] = "--lua"
        argv[#argv + 1] = lua_workspace .. "/lua-5.5.1"
    end
    return argv
end

local function compile_suite()
    local argv = {
        "env",
        "TITAN_RUNTIME_PREBUILT=1",
        "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        LUA,
        "-E",
        "-e",
        [[package.path = "./?.lua;./?/init.lua;" .. package.path; ]] ..
        (platform.windows and "" or
            [[package.cpath = "./titan-runtime/bootstrap/?.so;" .. package.cpath]]),
        "./titanc",
        "--test",
        "--no-uv-bootstrap",
        "--verbose",
        "--tree", FIXTURE,
        ROOT, EDGE, FOLDER, PREFIXED, RUNNER_PREFIXED, MUTATION,
    }
    return run(source_lua_arguments(argv))
end

local function compile_installed(root, ...)
    local prefix = require("spec.support.installed_prefix").active()
    local argv = {
        "env",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_6=" .. prefix .. "/lib/titan/0.6",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
    }
    if platform.windows then
        argv[#argv + 1] = LUA
        argv[#argv + 1] = "-E"
    end
    argv[#argv + 1] = INSTALLED_TITANC
    argv[#argv + 1] = "--test"
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    argv[#argv + 1] = "--tree"
    argv[#argv + 1] = FIXTURE
    argv[#argv + 1] = root
    return run(argv)
end

local function working_titanc_arguments()
    return source_lua_arguments({
        "env",
        "TITAN_RUNTIME_PREBUILT=1",
        "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        LUA,
        "-E",
        "-e",
        [[package.path = "./?.lua;./?/init.lua;" .. package.path; ]] ..
        (platform.windows and "" or
            [[package.cpath = "./titan-runtime/bootstrap/?.so;" .. package.cpath]]),
        "./titanc",
    })
end

local function run_suite(...)
    local argv = { "./" .. executable(ROOT) }
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    return run_program(argv)
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

local function has_quoted_argument(line, argument)
    return line:find("'" .. argument .. "'", 1, true) or
        line:find('"' .. argument .. '"', 1, true)
end

local function compile_line(output, source)
    for line in output:gmatch("[^\n]+") do
        if has_quoted_argument(line, "-c") and
           line:find(source, 1, true) then
            return line
        end
    end
    return nil
end

describe("native Titan test runner", function()
    teardown(function()
        if lua_workspace then
            remove_tree(lua_workspace)
            lua_workspace = nil
        end
    end)
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
        assert.is_true(file_exists(executable(ROOT)))
        if platform.windows then
            assert.is_true(file_exists(assert(driver.windows_program_paths(ROOT)).provider))
        end
        for _, path in ipairs(ARTIFACTS) do
            assert.is_true(file_exists(path), path)
        end
        for _, suffix in ipairs({
            "__test_runner.c", "__test_runner.o",
            "__test_entrypoint.c", "__test_entrypoint.o",
        }) do
            local path = synthetic_file(FIXTURE, ROOT, suffix)
            assert.is_true(file_exists(path), path)
        end
        assert.is_false(file_exists(ROOT .. "__test_support.c"))
        assert.is_false(file_exists(ROOT .. "__test_support.o"))
        assert.falsy(compiler_output:find("multiple main", 1, true),
            compiler_output)
    end)

    it("calls test-runner main directly when async bootstrap is disabled",
       function()
        local entrypoint = read_file(
            synthetic_file(FIXTURE, ROOT, "__test_entrypoint.c"))
        assert.truthy(entrypoint:find(
            "if (1 || lua_isnil(L, -1))", 1, true), entrypoint)
        assert.truthy(entrypoint:find(
            "lua_call(L, 1, 1);", 1, true), entrypoint)
    end)

    it("applies sibling-call preservation only to discovered test modules",
       function()
        local flag = "-fno-optimize-sibling-calls"
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
        local runner_line = assert(compile_line(compiler_output,
            ROOT .. "__test_runner.c"), compiler_output)
        local entrypoint_line = assert(compile_line(compiler_output,
            ROOT .. "__test_entrypoint.c"), compiler_output)
        assert.truthy(has_quoted_argument(root_line, flag), root_line)
        assert.truthy(has_quoted_argument(dependency_line, flag), dependency_line)
        assert.truthy(has_quoted_argument(edge_line, flag), edge_line)
        assert.truthy(has_quoted_argument(folder_line, flag), folder_line)
        assert.truthy(has_quoted_argument(prefixed_line, flag), prefixed_line)
        assert.is_nil(compile_line(compiler_output, "titan/test.c"), compiler_output)
        assert.is_nil(compile_line(compiler_output, "__test_support.c"), compiler_output)
        assert.falsy(has_quoted_argument(runner_line, flag), runner_line)
        assert.falsy(has_quoted_argument(entrypoint_line, flag), entrypoint_line)
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
        assert.truthy(output:find("failed deliberately", 1, true), output)
        assert.truthy(output:find("[  FAILED  ] test_runner_fixture.test_failure", 1, true), output)
        assert.falsy(output:find("stack traceback:", 1, true), output)

        ok, output = run_suite("--verbose", "--filter=test_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find("stack traceback:\n\t", 1, true), output)

        ok, output = run_suite("--filter=test_failure_after_lua_global_mutation$")
        assert.falsy(ok, output)
        assert.truthy(output:find("failure after Lua global mutation", 1, true), output)
        assert.truthy(output:find("[  FAILED  ] test_runner_mutation.test_failure_after_lua_global_mutation", 1, true), output)
    end)

    it("attributes native failures and prefixed locations to their Titan source",
       function()
        local ok, output = run_suite("--filter=test_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find("test_runner_fixture.titan:", 1, true), output)
        assert.truthy(output:find("in test_runner_fixture.test_failure: failed deliberately", 1, true), output)
        ok, output = run_suite("--verbose", "--filter=test_failure$")
        assert.falsy(ok, output)
        assert.truthy(output:find("in test_runner_fixture.test_failure", 1, true), output)
        assert.truthy(output:find("in titan.test.execute", 1, true), output)

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

    it("executes every sorted case across registration batches and discards results",
       function()
        local workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local owner = "test_runner_batches"
        local source = { [[local test = import "test"
local gc = import "gc"
-- This shared counter intentionally verifies generated-runner execution order.
local executed = 0
]] }
        local expected = {}
        for index = 129, 1, -1 do
            local name = string.format("test_%03d", index)
            expected[index] = owner .. "." .. name
            source[#source + 1] = string.format([[
function %s(context: test.Context): ({string}, integer)
  gc.collect()
  executed = executed + 1
  test.assert(executed == %d, "generated runner changed case order")
  test.assert(context:name() == %q, "generated runner changed case name")
  return {context:name()}, executed
end
]], name, index, expected[index])
        end
        assert(io.open(workspace .. "/" .. owner .. ".titan", "w")):
            write(table.concat(source, "\n")):close()
        local output_root = workspace .. "/output"
        local argv = working_titanc_arguments()
        for _, argument in ipairs({ "--test", "--no-uv-bootstrap",
                "--tree", workspace, "--output", output_root, owner }) do
            argv[#argv + 1] = argument
        end
        local compiled, output = run(argv)
        local program = platform.windows and
            assert(driver.windows_program_paths(owner, nil, nil,
                output_root)).executable or output_root .. "/" .. owner
        local ran, run_output
        if compiled then ran, run_output = run_program({ program }) end
        remove_tree(workspace)
        assert.truthy(compiled, output)
        assert.truthy(ran, run_output)
        local observed = {}
        for name in run_output:gmatch("%[ RUN      %] ([^\n]+)") do
            observed[#observed + 1] = name
        end
        assert.same(expected, observed)
        assert.truthy(run_output:find("[==========] 129 tests ran.", 1, true),
            run_output)
        assert.truthy(run_output:find("[  PASSED  ] 129 tests.", 1, true),
            run_output)
    end)

    it("inherits source-owner headers for exported native fields", function()
        local workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local header = workspace .. "/native.h"
        assert(io.open(header, "w")):write([[
#ifndef TITAN_TEST_RUNNER_NATIVE_H
#define TITAN_TEST_RUNNER_NATIVE_H
typedef struct titan_test_runner_native { int count; } titan_test_runner_native;
static inline titan_test_runner_native titan_test_runner_make(void) {
    titan_test_runner_native value = { 27 };
    return value;
}
#endif
]]):close()
        assert(io.open(workspace .. "/native_owner.titan", "w")):write(
            "foreign import " .. string.format("%q", header) .. [[

local test = import "test"
record NativeBox
    item: foreign titan_test_runner_native
end
function test_native_owner(context: test.Context)
    local box = NativeBox.new(ffi.titan_test_runner_make())
    test.assert(box.item.count == 27)
end
]]):close()
        local output_root = workspace .. "/output"
        local argv = working_titanc_arguments()
        for _, argument in ipairs({ "--test", "--tree", workspace,
                "--output", output_root, "native_owner" }) do
            argv[#argv + 1] = argument
        end
        local ok, output = run(argv)
        local program = platform.windows and
            assert(driver.windows_program_paths("native_owner", nil, nil,
                output_root)).executable or output_root .. "/native_owner"
        local ran, run_output
        if ok then ran, run_output = run_program({ program }) end
        remove_tree(workspace)
        assert.truthy(ok, output)
        assert.truthy(ran, run_output)
        assert.truthy(run_output:find(
            "[       OK ] native_owner.test_native_owner", 1, true), run_output)
    end)

    it("ignores an installed bootstrap only when explicitly disabled",
       function()
        local direct_argv = working_titanc_arguments()
        direct_argv[#direct_argv + 1] = "--no-uv-bootstrap"
        direct_argv[#direct_argv + 1] = "--tree"
        direct_argv[#direct_argv + 1] = FIXTURE
        direct_argv[#direct_argv + 1] = BOOTSTRAP
        local compiled, output = run(direct_argv)
        assert.truthy(compiled, output)

        local ok, direct_output, why, code = run_program({
            "./" .. executable(BOOTSTRAP), "one", "two",
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

        ok, output, why, code = run_program({ "./" .. executable(BOOTSTRAP) })
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(1, code)
        assert.truthy(output:find("synthetic bootstrap invoked", 1, true),
            output)
    end)

    it("rejects executable destinations for library and compile-only output", function()
        for _, compile_only in ipairs({ false, true }) do
            local argv = working_titanc_arguments()
            argv[#argv + 1] = "--exe"
            argv[#argv + 1] = "custom"
            if compile_only then argv[#argv + 1] = "--compile-only" end
            argv[#argv + 1] = "--tree"
            argv[#argv + 1] = FIXTURE
            argv[#argv + 1] = DEPENDENCY
            local ok, output = run(argv)
            assert.falsy(ok, output)
            local expected = compile_only and
                "--exe cannot be combined with --compile-only" or
                "--exe is only valid when compiling a standalone or test executable"
            assert.truthy(output:find(expected, 1, true), output)
        end
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

    it("keeps explicit roots source-required without a test-support override", function()
        local ok, output, why, code = compile_installed("titan.test")
        assert.falsy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find("titan.test", 1, true), output)
        assert.is_false(file_exists("titan/test__test_support.c"))
    end)

    it("keeps the selected static standard provider for native tests", function()
        if platform.windows then
            pending("Windows supports DLL providers; Titan static archive linking is unsupported")
            return
        end
        local prefix = require("spec.support.installed_prefix").active()
        local archive = prefix .. "/lib/titan/0.6/titan.a"
        local provider_modified = lfs.attributes(archive, "modification")
        local ok, output, why, code = compile_installed(STATIC, "--static", "--verbose")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find(archive, 1, true), output)
        local generated = read_file(FIXTURE .. "/" .. STATIC .. ".c")
        assert.truthy(generated:find("extern Udata *titan_math_init(lua_State *L);",
            1, true), generated)
        assert.falsy(generated:find("TitanModuleProvider titan_math_provider;", 1, true),
            generated)
        assert.is_false(file_exists(STATIC .. "__test_support.c"))
        assert.equal(provider_modified, lfs.attributes(archive, "modification"))
        local run_ok, run_output = run({
            "env", "LUA_CPATH_5_5=" .. package.cpath, "./" .. STATIC,
        })
        assert.truthy(run_ok, run_output)
        assert.truthy(run_output:find(
            "[       OK ] test_runner_static.test_static_provider",
            1, true), run_output)
    end)

    it("isolates synthetic outputs from similarly named source modules", function()
        local suite = "test_runner_collision"
        local owner_source = suite .. [[.titan]]
        local owner_contents = [[local test = import "test"
function test_collision(context: test.Context)
  test.assert(true)
end
]]
        local suffix = "__test_runner"
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
        assert.truthy(ok, output)
        assert.is_true(file_exists(suite .. ".c"))
        assert.is_true(file_exists(colliding .. ".c"))
        assert.is_true(file_exists(colliding .. ".o"))
        local runner = synthetic_file(".", suite, "__test_runner.c")
        assert.not_equal(colliding .. ".c", runner)
        assert.is_true(file_exists(runner), runner)
        local ran, result = run_program({ "./" .. executable(suite) })
        assert.truthy(ran, result)
        assert.truthy(result:find(
            "[       OK ] " .. suite .. ".test_collision", 1, true), result)

        os.remove(owner_source)
        os.remove(colliding_source)
    end)

    it("validates executable and source-output hierarchies early",
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
        if platform.windows then
            -- Windows separates the launcher and provider from source outputs,
            -- so the Unix hierarchy collision is a valid native layout.
            assert.truthy(ok, output)
            assert.is_true(file_exists(executable(root)))
            assert.is_true(file_exists(assert(driver.windows_program_paths(root)).provider))
            local ran, run_output = run_program({ "./" .. executable(root) })
            assert.truthy(ran, run_output)
            assert.truthy(run_output:find("[       OK ] test_runner_hierarchy.test_root", 1, true), run_output)
        else
            assert.falsy(ok, output)
            assert.truthy(output:find("standalone executable", 1, true), output)
            assert.is_false(file_exists(root .. ".c"))
            assert.is_false(file_exists(root .. "/child.c"))
            assert.is_false(file_exists(root .. "__test_support.c"))
        end

        os.remove(root .. ".titan")
        os.remove(root .. "/child.titan")
        lfs.rmdir(root)
    end)

    it("reports reserved shorthand owners as an ordinary compiler error",
       function()
        local workspace = assert(compiler_io.new_sync():tmpname())
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
        local workspace = assert(compiler_io.new_sync():tmpname())
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
        local program = executable(root, root .. "__main")
        local run_ok, run_output = run_program({ "./" .. program })
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
        local run_ok, run_output = run_program({ "./" .. executable(NESTED, "nested/tests__main") })
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

local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"

local ROOT = lfs.currentdir()
local FIXTURE = ROOT .. "/spec/fixtures/parallel_compilation"
local FIXTURE_SOURCE_ROOT = FIXTURE .. "/src"
local WRAPPER = FIXTURE .. "/counting_cc.sh"
local LEAVES = { "one", "two", "three", "four" }
local MODULES = { "batch.one", "batch.two", "batch.three", "batch.four" }

local PREFIX = os.getenv("PREFIX")
if not PREFIX then
    for template in package.cpath:gmatch("[^;]+") do
        PREFIX = template:match("^(.*)/lib/lua/5[.]5/[?][.]so$")
        if PREFIX then break end
    end
end
local prefix_lua = PREFIX and (PREFIX .. "/bin/lua") or nil
local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua or "lua"

local function shell_command(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, directory)
    local command = shell_command(argv) .. " 2>&1"
    if directory then
        command = "cd " .. assert(cdriver.shell_quote(directory)) ..
            " && " .. command
    end
    local pipe = assert(io.popen(command, "r"))
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

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function copy_file(source, destination)
    local contents = read_file(source)
    local output = assert(io.open(destination, "wb"))
    assert(output:write(contents))
    assert(output:close())
end

local workspace_directory
local source_root
local state_directory
local function prepare_workspace()
    workspace_directory = assert(os.tmpname())
    os.remove(workspace_directory)
    assert(lfs.mkdir(workspace_directory))
    source_root = workspace_directory .. "/src"
    state_directory = workspace_directory .. "/state"
    assert(lfs.mkdir(source_root))
    assert(lfs.mkdir(source_root .. "/batch"))
    assert(lfs.mkdir(state_directory))
    for _, leaf in ipairs(LEAVES) do
        copy_file(FIXTURE_SOURCE_ROOT .. "/batch/" .. leaf .. ".titan",
            source_root .. "/batch/" .. leaf .. ".titan")
    end
end

local function titanc(
        environment_jobs, cli_jobs, failing_module, diagnostics)
    local local_path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;"
    local argv = { "env" }
    if environment_jobs then
        argv[#argv + 1] = "TITAN_JOBS=" .. environment_jobs
    else
        argv[#argv + 1] = "-u"
        argv[#argv + 1] = "TITAN_JOBS"
    end
    for _, argument in ipairs({
        "CC=" .. WRAPPER,
        "MAKE=true",
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PARALLEL_TEST_STATE=" .. state_directory,
        "TITAN_PARALLEL_TEST_DELAY=0.5",
        "TITAN_PARALLEL_TEST_EXPECTED=" ..
            (((cli_jobs or environment_jobs) == "4") and "4" or "1"),
        "TITAN_PARALLEL_TEST_DIAGNOSTICS=" .. (diagnostics or ""),
        "TITAN_PARALLEL_TEST_FAIL=" .. (failing_module or ""),
        "TITAN_ROCKS_ROOT=" .. assert(PREFIX,
            "parallel compilation spec requires the prepared Titan prefix"),
        "TITAN_RUNTIME_PREBUILT=1",
        LUA,
        "-e",
        "package.path = " .. string.format("%q", local_path) ..
            " .. package.path",
        ROOT .. "/titanc",
    }) do
        argv[#argv + 1] = argument
    end
    if cli_jobs then
        argv[#argv + 1] = "--jobs"
        argv[#argv + 1] = cli_jobs
    end
    argv[#argv + 1] = "--tree"
    argv[#argv + 1] = source_root
    for _, module in ipairs(MODULES) do argv[#argv + 1] = module end
    return run(argv, workspace_directory)
end

local function checked_requests()
    types.registry = {}
    local requests = {}
    for _, leaf in ipairs(LEAVES) do
        local modname = "batch." .. leaf
        local filename = source_root .. "/batch/" .. leaf .. ".titan"
        local source = read_file(filename)
        local ast, parse_err = parser.parse(filename, source)
        assert.truthy(ast, parse_err)
        local _, errors = checker.check(modname, ast, source, filename)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        requests[#requests + 1] = {
            modname = modname,
            mod = { ast = ast, filename = filename },
            static_deps = {},
        }
    end
    return requests
end

local function configure_counting_compiler(
        diagnostics, failing_module, expected)
    driver.CC = shell_command({
        "env",
        "TITAN_PARALLEL_TEST_STATE=" .. state_directory,
        "TITAN_PARALLEL_TEST_DELAY=0.5",
        "TITAN_PARALLEL_TEST_EXPECTED=" .. tostring(expected or 4),
        "TITAN_PARALLEL_TEST_DIAGNOSTICS=" .. (diagnostics or ""),
        "TITAN_PARALLEL_TEST_FAIL=" .. (failing_module or ""),
        WRAPPER,
    })
end

local function assert_four_overlapping_compiles(output)
    assert.equal("4\n", read_file(state_directory .. "/maximum"), output)
    local commands = read_file(state_directory .. "/commands")
    local count = 0
    for _ in commands:gmatch("[^\n]+") do count = count + 1 end
    assert.equal(4, count, commands)
    assert.is_true(file_exists(workspace_directory .. "/batch.so"))
    assert.is_true(file_exists(workspace_directory .. "/batch.a"))
end

describe("parallel generated-C compilation", function()
    local previous_cc
    local previous_stdout
    local previous_stderr
    local previous_tmpname
    local previous_popen
    local diagnostic_stream

    before_each(function()
        previous_cc = driver.CC
        previous_stdout = io.stdout
        previous_stderr = io.stderr
        previous_tmpname = os.tmpname
        previous_popen = io.popen
        prepare_workspace()
    end)
    after_each(function()
        driver.CC = previous_cc
        io.stdout = previous_stdout
        io.stderr = previous_stderr
        os.tmpname = previous_tmpname
        io.popen = previous_popen
        if diagnostic_stream and io.type(diagnostic_stream) == "file" then
            diagnostic_stream:close()
        end
        diagnostic_stream = nil
        types.registry = {}
        if workspace_directory then
            remove_tree(workspace_directory)
            workspace_directory = nil
            source_root = nil
            state_directory = nil
        end
    end)

    it("batches only the driver C object commands", function()
        configure_counting_compiler("reverse")
        local diagnostic_path = workspace_directory .. "/diagnostics"
        diagnostic_stream = assert(io.open(diagnostic_path, "w+b"))
        io.stderr = diagnostic_stream
        local requests = checked_requests()
        local results = driver.compile_modules(requests, 4, false)
        assert(io.stderr:flush())
        assert(io.stderr:seek("set", 0))
        local diagnostics = assert(io.stderr:read("*a"))
        assert(diagnostic_stream:close())
        diagnostic_stream = nil
        io.stderr = previous_stderr

        for _, result in ipairs(results) do
            assert.truthy(result.ok, result.err)
            assert.is_true(file_exists(result.libname))
        end
        local previous = 0
        for _, leaf in ipairs(LEAVES) do
            local position = assert(diagnostics:find(
                "parallel compiler diagnostic: " .. leaf, 1, true),
                diagnostics)
            assert.is_true(previous < position, diagnostics)
            previous = position
        end
        assert.equal("4\n", read_file(state_directory .. "/maximum"))

        local commands = read_file(state_directory .. "/commands")
        local cached = driver.compile_modules(requests, 4, false)
        for index, result in ipairs(cached) do
            assert.truthy(result.ok, result.err)
            assert.equal(results[index].libname, result.libname)
        end
        assert.equal(commands, read_file(state_directory .. "/commands"))
    end)

    it("keeps the driver one-job path serial", function()
        configure_counting_compiler(nil, nil, 1)
        local request = checked_requests()[1]
        local results = driver.compile_modules({ request }, 1, false)
        assert.truthy(results[1].ok, results[1].err)
        assert.equal("1\n", read_file(state_directory .. "/maximum"))

        request = checked_requests()[2]
        results = driver.compile_modules({ request }, 4, false)
        assert.truthy(results[1].ok, results[1].err)
        assert.equal("1\n", read_file(state_directory .. "/maximum"))
    end)

    it("handles serial cache hits and preparation failures", function()
        local cached_request = checked_requests()[1]
        cached_request.mod.compiled = source_root .. "/cached.o"
        cached_request.mod.native_references = { dependency = true }
        local cached = driver.compile_modules({ cached_request }, 1, false)
        assert.truthy(cached[1].ok, cached[1].err)
        assert.equal(cached_request.mod.compiled, cached[1].libname)
        assert.same({ dependency = true }, cached[1].native_references)

        local invalid = {
            modname = "not a logical module",
            mod = { ast = checked_requests()[1].mod.ast },
            static_deps = {},
        }
        local serial = driver.compile_modules({ invalid }, 1, false)
        assert.falsy(serial[1].ok)
        assert.truthy(tostring(serial[1].err):find(
            "invalid logical Titan module name", 1, true),
            tostring(serial[1].err))

        local parallel = driver.compile_modules({ invalid }, 4, false)
        assert.falsy(parallel[1].ok)
        assert.truthy(tostring(parallel[1].err):find(
            "invalid logical Titan module name", 1, true),
            tostring(parallel[1].err))
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("retains successful peer objects after a driver child fails", function()
        configure_counting_compiler(nil, "three")
        local diagnostic_path = workspace_directory .. "/diagnostics"
        diagnostic_stream = assert(io.open(diagnostic_path, "w+b"))
        io.stderr = diagnostic_stream
        local results = driver.compile_modules(checked_requests(), 4, false)
        assert(diagnostic_stream:close())
        diagnostic_stream = nil
        io.stderr = previous_stderr

        assert.truthy(results[1].ok, results[1].err)
        assert.truthy(results[2].ok, results[2].err)
        assert.falsy(results[3].ok)
        assert.equal("exit", results[3].err)
        assert.truthy(results[4].ok, results[4].err)
        assert.equal("4\n", read_file(state_directory .. "/maximum"))
        assert.falsy(file_exists(source_root .. "/batch/three.o"))
    end)

    it("rejects duplicate modules and aliased object outputs", function()
        local requests = checked_requests()
        local ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[1] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "duplicate compilation request", 1, true), tostring(failure))

        requests[2].mod.filename = requests[1].mod.filename
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        requests[2].mod.filename = source_root ..
            "/batch/../batch/one.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        local alias = source_root .. "/alias"
        assert(lfs.link(source_root .. "/batch", alias, true))
        requests = checked_requests()
        requests[2].mod.filename = alias .. "/one.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        requests[1].mod.filename = source_root ..
            "/batch/new/shared.titan"
        requests[2].mod.filename = alias .. "/new/shared.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        local dangling_output = source_root .. "/aliased-output.o"
        assert(lfs.link("batch/new/shared.o", dangling_output, true))
        requests = checked_requests()
        requests[1].mod.filename = source_root ..
            "/batch/new/shared.titan"
        requests[2].mod.filename = source_root .. "/aliased-output.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert(os.remove(dangling_output))
        assert(os.remove(alias))
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        requests[1].mod.filename = source_root .. "/Case.titan"
        requests[2].mod.filename = source_root .. "/case.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        copy_file(requests[1].mod.filename,
            source_root .. "/batch/one.o")
        assert(lfs.link(source_root .. "/batch/one.o",
            source_root .. "/batch/two.o"))
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, 4, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("bounds a self-referential object-output symlink", function()
        local request = checked_requests()[1]
        request.mod.filename = source_root .. "/loop.titan"
        assert(lfs.link("./loop.o", source_root .. "/loop.o", true))

        local results = driver.compile_modules({ request }, 4, false)
        assert.truthy(results[1].ok, results[1].err)
        assert.truthy(file_exists(source_root .. "/loop.o"))
    end)

    it("reaps an active batch when creating a later log fails", function()
        configure_counting_compiler(nil, nil, 3)
        local temporary_logs = {}
        local calls = 0
        os.tmpname = function()
            calls = calls + 1
            if calls == 3 then error("injected tmpname failure", 0) end
            local path = previous_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end

        local results = driver.compile_modules(checked_requests(), 4, false)
        os.tmpname = previous_tmpname
        assert.truthy(results[1].ok, results[1].err)
        assert.falsy(results[2].ok)
        assert.truthy(tostring(results[2].err):find(
            "injected tmpname failure", 1, true), tostring(results[2].err))
        assert.truthy(results[3].ok, results[3].err)
        assert.truthy(results[4].ok, results[4].err)
        assert.equal("3\n", read_file(state_directory .. "/maximum"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("cleans the first log when creating the second log fails", function()
        configure_counting_compiler(nil, nil, 3)
        local temporary_logs = {}
        local calls = 0
        os.tmpname = function()
            calls = calls + 1
            if calls == 2 then return nil end
            local path = previous_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end

        local results = driver.compile_modules(checked_requests(), 4, false)
        os.tmpname = previous_tmpname
        assert.falsy(results[1].ok)
        assert.truthy(tostring(results[1].err):find(
            "os.tmpname returned no path", 1, true), tostring(results[1].err))
        for index = 2, 4 do
            assert.truthy(results[index].ok, results[index].err)
        end
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("reports command-stream and process-launch failures", function()
        configure_counting_compiler()
        local temporary_logs = {}
        os.tmpname = function()
            local path = previous_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end
        io.stdout = {
            write = function() return nil, "injected command write failure" end,
            flush = function() return true end,
        }
        local results = driver.compile_modules(checked_requests(), 4, true)
        io.stdout = previous_stdout
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected command write failure", 1, true),
                tostring(result.err))
        end

        io.popen = function() error("injected popen exception", 0) end
        results = driver.compile_modules(checked_requests(), 4, false)
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected popen exception", 1, true), tostring(result.err))
        end

        io.popen = function() return nil, "injected unavailable popen" end
        results = driver.compile_modules(checked_requests(), 4, false)
        io.popen = previous_popen
        os.tmpname = previous_tmpname
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected unavailable popen", 1, true), tostring(result.err))
        end
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("reports nonthrowing diagnostic-stream failures", function()
        configure_counting_compiler("diagnostics")
        io.stderr = {
            write = function() return nil, "injected false write" end,
            flush = function() return true end,
        }
        local results = driver.compile_modules(checked_requests(), 4, false)
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected false write", 1, true), tostring(result.err))
        end

        io.stderr = {
            write = function() return true end,
            flush = function() return nil, "injected false flush" end,
        }
        results = driver.compile_modules(checked_requests(), 4, false)
        io.stderr = previous_stderr
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected false flush", 1, true), tostring(result.err))
        end
    end)

    it("prints only commands whose parallel launch is attempted", function()
        configure_counting_compiler(nil, nil, 3)
        local temporary_logs = {}
        local calls = 0
        os.tmpname = function()
            calls = calls + 1
            if calls == 1 then error("injected tmpname failure", 0) end
            local path = previous_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end
        local shown = {}
        io.stdout = {
            write = function(_, output)
                shown[#shown + 1] = output
                return true
            end,
            flush = function() return true end,
        }

        local results = driver.compile_modules(checked_requests(), 4, true)
        os.tmpname = previous_tmpname
        io.stdout = previous_stdout
        assert.falsy(results[1].ok)
        assert.truthy(tostring(results[1].err):find(
            "injected tmpname failure", 1, true), tostring(results[1].err))
        for index = 2, 4 do
            assert.truthy(results[index].ok, results[index].err)
        end
        local output = table.concat(shown)
        assert.falsy(output:find("/batch/one.c", 1, true), output)
        for _, leaf in ipairs({ "two", "three", "four" }) do
            assert.truthy(output:find(
                "/batch/" .. leaf .. ".c", 1, true), output)
        end
        assert.equal("3\n", read_file(state_directory .. "/maximum"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("reaps the batch and removes logs after a replay exception", function()
        configure_counting_compiler("diagnostics")
        local temporary_logs = {}
        os.tmpname = function()
            local path = previous_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end
        io.stderr = {
            write = function() error("injected replay failure", 0) end,
            flush = function() return true end,
        }

        local results = driver.compile_modules(checked_requests(), 4, false)
        os.tmpname = previous_tmpname
        io.stderr = previous_stderr
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected replay failure", 1, true), tostring(result.err))
        end
        assert.equal("0\n", read_file(state_directory .. "/active"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("uses one CLI compilation job by default", function()
        local ok, output, why, code = titanc(nil)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("1\n", read_file(state_directory .. "/maximum"), output)
        assert.is_true(file_exists(workspace_directory .. "/batch.so"))
        assert.is_true(file_exists(workspace_directory .. "/batch.a"))
    end)

    it("uses TITAN_JOBS as the concurrency bound", function()
        local ok, output, why, code = titanc("4")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_four_overlapping_compiles(output)
    end)

    it("lets --jobs override the environment", function()
        local ok, output, why, code = titanc("1", "4")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_four_overlapping_compiles(output)
    end)

    it("replays diagnostics in logical-module order", function()
        local ok, output, why, code = titanc("4", nil, nil, "reverse")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local previous = 0
        for _, leaf in ipairs({ "four", "one", "three", "two" }) do
            local position = assert(output:find(
                "parallel compiler diagnostic: " .. leaf, 1, true), output)
            assert.is_true(previous < position, output)
            previous = position
        end
        assert_four_overlapping_compiles(output)
    end)

    it("replays a failed compiler diagnostic and still reaps the batch",
       function()
        local ok, output = titanc("4", nil, "three")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "parallel compiler sentinel: three", 1, true), output)
        assert.equal("4\n", read_file(state_directory .. "/maximum"), output)
        assert.falsy(file_exists(workspace_directory .. "/batch.so"))
        assert.falsy(file_exists(source_root .. "/batch/three.o"))
        assert.is_true(file_exists(source_root .. "/batch/one.o"))
        assert.is_true(file_exists(source_root .. "/batch/two.o"))
        assert.is_true(file_exists(source_root .. "/batch/four.o"))
    end)

    it("rejects a malformed TITAN_JOBS value before code generation",
       function()
        local ok, output = titanc("four")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--jobs and TITAN_JOBS require a positive integer", 1, true),
            output)
        assert.falsy(file_exists(source_root .. "/batch/one.c"))
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("rejects a non-positive concurrency bound before code generation",
       function()
        local ok, output = titanc("4", "0")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--jobs and TITAN_JOBS require a positive integer", 1, true),
            output)
        assert.falsy(file_exists(source_root .. "/batch/one.c"))
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)
end)

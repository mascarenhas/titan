local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local filesystem = require "spec.support.filesystem"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local parser = require "titan-compiler.parser"
local platform = require "titan-compiler.platform"
local process = require "titan-compiler.process"
local types = require "titan-compiler.types"

local ROOT = lfs.currentdir()
if platform.windows then ROOT = assert(platform.path.normalize(ROOT)) end
local FIXTURE = ROOT .. "/spec/fixtures/parallel_compilation"
local FIXTURE_SOURCE_ROOT = FIXTURE .. "/src"
local WRAPPER = FIXTURE .. "/counting_cc.sh"
local JOBS = platform.windows and 2 or 4
local LEAVES = { "one", "two", "three", "four" }
local REFILL_LEAVES = {
    "one", "two", "three", "four", "five", "six", "seven", "eight",
}
local MODULES = { "batch.one", "batch.two", "batch.three", "batch.four" }

local PREFIX = installed_prefix.active()
local prefix_lua = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
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
    local previous = directory and assert(lfs.currentdir()) or nil
    if directory then assert(lfs.chdir(directory)) end
    local called, result = pcall(function()
        return compiler_io.new_sync():run(argv)
    end)
    if previous then assert(lfs.chdir(previous)) end
    assert.truthy(called, result)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.ok, output, result.why, result.status
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
    workspace_directory = assert(compiler_io.new_sync():tmpname())
    if platform.windows then
        workspace_directory = assert(platform.path.normalize(workspace_directory))
    end
    os.remove(workspace_directory)
    assert(lfs.mkdir(workspace_directory))
    source_root = workspace_directory .. "/src"
    state_directory = workspace_directory .. "/state"
    assert(lfs.mkdir(source_root))
    assert(lfs.mkdir(source_root .. "/batch"))
    assert(lfs.mkdir(state_directory))
    for _, leaf in ipairs(REFILL_LEAVES) do
        copy_file(FIXTURE_SOURCE_ROOT .. "/batch/" .. leaf .. ".titan",
            source_root .. "/batch/" .. leaf .. ".titan")
    end
end

local function titanc(
        environment_jobs, cli_jobs, failing_module, diagnostics,
        compiler, bounded)
    local local_path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;"
    -- An ambient parent Make pool would otherwise bound these fixtures.
    local argv = { "env", "-u", "MAKEFLAGS" }
    if environment_jobs then
        argv[#argv + 1] = "TITAN_JOBS=" .. environment_jobs
    else
        argv[#argv + 1] = "-u"
        argv[#argv + 1] = "TITAN_JOBS"
    end
    for _, argument in ipairs({
        "CC=" .. (compiler or (platform.windows and
            shell_command({ "bash", WRAPPER }) or WRAPPER)),
        "TITAN_EXTRA_CPPFLAGS=",
        "TITAN_EXTRA_CFLAGS=",
        "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PARALLEL_TEST_STATE=" .. state_directory,
        "TITAN_PARALLEL_TEST_DELAY=0.5",
        "TITAN_PARALLEL_TEST_EXPECTED=" .. tostring(math.min(
            tonumber(cli_jobs or environment_jobs) or 4, #MODULES)),
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
    if bounded then
        local bounded_argv = {
            ROOT .. "/spec/support/run_with_timeout.sh", "10",
        }
        for _, argument in ipairs(argv) do
            bounded_argv[#bounded_argv + 1] = argument
        end
        argv = bounded_argv
    end
    return run(argv, workspace_directory)
end

local function checked_requests(leaves)
    types.registry = {}
    local requests = {}
    for _, leaf in ipairs(leaves or LEAVES) do
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

local function requests_with_headers()
    local requests = checked_requests()
    local names, imported = {}, {}
    for _, request in ipairs(requests) do
        names[#names + 1] = request.modname
        imported[request.modname] = request.mod
    end
    local ok, err = driver.prepare_foreign_headers(names, imported, false)
    assert.truthy(ok, err)
    return requests
end

local function configure_counting_compiler(
        diagnostics, failing_module, expected, mode)
    local argv = {
        "env",
        "TITAN_PARALLEL_TEST_STATE=" .. state_directory,
        "TITAN_PARALLEL_TEST_DELAY=0.5",
        "TITAN_PARALLEL_TEST_EXPECTED=" .. tostring(expected or JOBS),
        "TITAN_PARALLEL_TEST_DIAGNOSTICS=" .. (diagnostics or ""),
        "TITAN_PARALLEL_TEST_FAIL=" .. (failing_module or ""),
        "TITAN_PARALLEL_TEST_MODE=" .. (mode or ""),
    }
    if platform.windows then argv[#argv + 1] = "bash" end
    argv[#argv + 1] = WRAPPER
    driver.CC = shell_command(argv)
end

local function assert_compiler_batch(output)
    assert.equal(tostring(JOBS) .. "\n",
        read_file(state_directory .. "/maximum"), output)
    local commands = read_file(state_directory .. "/commands")
    local count = 0
    for _ in commands:gmatch("[^\n]+") do count = count + 1 end
    assert.equal(4, count, commands)
    assert.is_true(file_exists(workspace_directory ..
        (platform.windows and "/batch.dll" or "/batch.so")))
    if not platform.windows then
        assert.is_true(file_exists(workspace_directory .. "/batch.a"))
    end
end

describe("parallel generated-C compilation", function()
    local previous_cc
    local previous_stdout
    local previous_stderr
    local previous_tmpname
    local previous_execute
    local previous_popen
    local previous_open
    local previous_new_sync
    local previous_new_batch
    local batch_overrides
    local diagnostic_stream

    local function original_compile_tmpname()
        if platform.windows then return previous_new_sync():tmpname() end
        return previous_tmpname()
    end

    local function override_tmpname(callback)
        if platform.windows then
            compiler_io.new_sync = function(...)
                local strategy = previous_new_sync(...)
                strategy.tmpname = function() return callback() end
                return strategy
            end
        else os.tmpname = callback end
    end

    local function restore_tmpname()
        os.tmpname = previous_tmpname
        compiler_io.new_sync = previous_new_sync
    end

    local function override_launch(callback)
        if platform.windows then batch_overrides.spawn = callback
        else io.popen = callback end
    end

    local function restore_launch()
        io.popen = previous_popen
        batch_overrides.spawn = nil
    end

    local function record_launches(launched)
        if platform.windows then
            override_launch(function(original, batch, argv, ...)
                launched[#launched + 1] = shell_command(argv)
                return original(batch, argv, ...)
            end)
        else
            override_launch(function(command, mode)
                launched[#launched + 1] = command
                return previous_popen(command, mode)
            end)
        end
    end

    -- The batch polls the real completion FIFO descriptor, so channel
    -- failures are injected through the shared FILE methods, for that one
    -- handle only.
    local file_methods = getmetatable(io.stdout).__index
    local replaced_file_methods = {}
    local function override_completion_file(callbacks)
        local completion
        io.open = function(path, mode)
            local file, open_err = previous_open(path, mode)
            if mode == "r+" and file then completion = file end
            return file, open_err
        end
        for name, callback in pairs(callbacks) do
            local original = file_methods[name]
            replaced_file_methods[name] = original
            file_methods[name] = function(file, ...)
                if file == completion then return callback(original, file, ...) end
                return original(file, ...)
            end
        end
    end

    local function restore_completion_file()
        for name, original in pairs(replaced_file_methods) do
            file_methods[name] = original
        end
        replaced_file_methods = {}
        io.open = previous_open
    end

    before_each(function()
        previous_cc = driver.CC
        previous_stdout = io.stdout
        previous_stderr = io.stderr
        previous_tmpname = os.tmpname
        previous_execute = os.execute
        previous_popen = io.popen
        previous_open = io.open
        previous_new_sync = compiler_io.new_sync
        previous_new_batch = process.new_batch
        batch_overrides = {}
        if platform.windows then
            process.new_batch = function(...)
                local batch, err = previous_new_batch(...)
                if not batch then return nil, err end
                for name, callback in pairs(batch_overrides) do
                    local original = batch[name]
                    batch[name] = function(self, ...)
                        return callback(original, self, ...)
                    end
                end
                return batch
            end
        end
        prepare_workspace()
    end)
    after_each(function()
        driver.CC = previous_cc
        io.stdout = previous_stdout
        io.stderr = previous_stderr
        restore_tmpname()
        os.execute = previous_execute
        restore_launch()
        restore_completion_file()
        process.new_batch = previous_new_batch
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
        local results = driver.compile_modules(requests, JOBS, false)
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
        assert.equal(tostring(JOBS) .. "\n",
            read_file(state_directory .. "/maximum"))

        local commands = read_file(state_directory .. "/commands")
        local cached = driver.compile_modules(requests, JOBS, false)
        for index, result in ipairs(cached) do
            assert.truthy(result.ok, result.err)
            assert.equal(results[index].libname, result.libname)
        end
        assert.equal(commands, read_file(state_directory .. "/commands"))
    end)

    it("launches larger generated units first", function()
        configure_counting_compiler()
        local launched = {}
        record_launches(launched)
        local results = driver.compile_modules(
            checked_requests(REFILL_LEAVES), JOBS, false)
        restore_launch()
        for _, result in ipairs(results) do
            assert.truthy(result.ok, result.err)
        end
        assert.truthy(launched[1]:find("/batch/eight.c", 1, true),
            table.concat(launched, "\n"))
    end)

    it("refills a slot as soon as any compiler finishes", function()
        configure_counting_compiler(nil, nil, JOBS, "refill")
        local launched = {}
        record_launches(launched)
        local results = driver.compile_modules(
            checked_requests(REFILL_LEAVES), JOBS, false)
        restore_launch()
        local slow_was_initial = false
        for index = 1, JOBS do
            if launched[index]:find("/batch/one.c", 1, true) then
                slow_was_initial = true
            end
        end
        assert.is_true(slow_was_initial, table.concat(launched, "\n"))
        for _, result in ipairs(results) do
            assert.truthy(result.ok, result.err)
            assert.is_true(file_exists(result.libname))
        end
        assert.equal(tostring(JOBS) .. "\n",
            read_file(state_directory .. "/maximum"))
        assert.equal("0\n", read_file(state_directory .. "/active"))
        assert.is_true(file_exists(
            state_directory .. "/refilled-before-slow-finished"))
        local commands = read_file(state_directory .. "/commands")
        local count = 0
        for _ in commands:gmatch("[^\n]+") do count = count + 1 end
        assert.equal(#REFILL_LEAVES, count, commands)
    end)

    it("keeps the driver one-job path serial", function()
        configure_counting_compiler(nil, nil, 1)
        local request = checked_requests()[1]
        local results = driver.compile_modules({ request }, 1, false)
        assert.truthy(results[1].ok, results[1].err)
        assert.equal("1\n", read_file(state_directory .. "/maximum"))

        request = checked_requests()[2]
        results = driver.compile_modules({ request }, JOBS, false)
        assert.truthy(results[1].ok, results[1].err)
        assert.equal("1\n", read_file(state_directory .. "/maximum"))
    end)

    it("handles serial cache hits and preparation failures", function()
        local cached_request = checked_requests()[1]
        cached_request.mod.compiled = source_root .. "/cached.o"
        cached_request.mod.compiled_objects = { cached_request.mod.compiled }
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

        local parallel = driver.compile_modules({ invalid }, JOBS, false)
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
        local results = driver.compile_modules(checked_requests(), JOBS, false)
        assert(diagnostic_stream:close())
        diagnostic_stream = nil
        io.stderr = previous_stderr

        assert.truthy(results[1].ok, results[1].err)
        assert.truthy(results[2].ok, results[2].err)
        assert.falsy(results[3].ok)
        assert.equal("exit", results[3].err)
        assert.truthy(results[4].ok, results[4].err)
        assert.equal(tostring(JOBS) .. "\n",
            read_file(state_directory .. "/maximum"))
        assert.falsy(file_exists(source_root .. "/batch/three.o"))
    end)

    it("schedules several parts per module and fails only the owning module",
       function()
        -- Synthetic prepared modules drive the scheduler directly. Each job
        -- sleeps, reports its label on stderr, and exits with its status.
        local previous_getenv = platform.getenv
        platform.getenv = function(name)
            if name == "MAKEFLAGS" then return nil end
            return previous_getenv(name)
        end
        finally(function() platform.getenv = previous_getenv end)
        local script = workspace_directory .. "/part_job.sh"
        local output = assert(io.open(script, "wb"))
        assert(output:write([[
sleep "$2"
echo "part diagnostic: $1" >&2
test "$3" = 0 || exit "$3"
: > "$4"
]]))
        assert(output:close())
        -- { leaf, { { cost_bytes, delay, status }, ... } } in part order.
        local modules = {
            { "one", { { 10, 0.3, 0 }, { 300, 0.4, 0 }, { 50, 0.1, 23 } } },
            { "two", { { 300, 0.2, 0 }, { 200, 0.1, 0 } } },
            { "three", { { 100, 0.2, 0 } } },
        }
        local prepared = {}
        for module_index, module in ipairs(modules) do
            local compilation = {
                modname = "batch." .. module[1],
                request_index = module_index,
                jobs = {},
            }
            for position, part in ipairs(module[2]) do
                local label = module[1] .. ".part" .. (position - 1)
                local object = workspace_directory .. "/" .. label .. ".o"
                compilation.jobs[position] = {
                    module_index = module_index,
                    part_index = position - 1,
                    c_path = workspace_directory .. "/" .. label .. ".c",
                    object_path = object,
                    temporary_object = object,
                    argv = { platform.windows and "bash" or "sh", script, label,
                        tostring(part[2]), tostring(part[3]), object },
                    cost_bytes = part[1],
                }
            end
            prepared[module_index] = compilation
        end

        local launched = {}
        record_launches(launched)
        local diagnostic_path = workspace_directory .. "/diagnostics"
        diagnostic_stream = assert(io.open(diagnostic_path, "w+b"))
        io.stderr = diagnostic_stream
        local results, cancelled = driver.run_prepared_compiles(prepared, 2, false)
        assert(io.stderr:flush())
        assert(io.stderr:seek("set", 0))
        local diagnostics = assert(io.stderr:read("*a"))
        assert(diagnostic_stream:close())
        diagnostic_stream = nil
        io.stderr = previous_stderr
        restore_launch()

        -- Largest cost first; equal costs keep module, then part, order.
        local expected_launches = {
            "one.part1", "two.part0", "two.part1", "three.part0",
            "one.part2", "one.part0",
        }
        assert.equal(#expected_launches, #launched, table.concat(launched, "\n"))
        for index, label in ipairs(expected_launches) do
            assert.truthy(launched[index]:find(label, 1, true),
                table.concat(launched, "\n"))
        end
        -- Completion order differs; diagnostics replay in module/part order.
        local previous = 0
        for _, label in ipairs({ "one.part0", "one.part1", "one.part2",
                "two.part0", "two.part1", "three.part0" }) do
            local position = assert(diagnostics:find(
                "part diagnostic: " .. label .. "\n", 1, true), diagnostics)
            assert.is_true(previous < position, diagnostics)
            previous = position
        end

        assert.is_nil(cancelled)
        assert.equal(3, #results)
        assert.is_nil(results[1].ok)
        assert.equal("exit", results[1].err)
        assert.equal(23, results[1].code)
        assert.equal(3, #results[1].jobs)
        assert.truthy(results[1].jobs[1].ok, results[1].jobs[1].err)
        assert.truthy(results[1].jobs[2].ok, results[1].jobs[2].err)
        assert.is_nil(results[1].jobs[3].ok)
        assert.equal(23, results[1].jobs[3].code)
        for index, count in pairs({ [2] = 2, [3] = 1 }) do
            assert.truthy(results[index].ok, results[index].err)
            assert.equal(count, #results[index].jobs)
        end
        assert.is_false(file_exists(workspace_directory .. "/one.part2.o"))
        assert.is_true(file_exists(workspace_directory .. "/one.part0.o"))
    end)

    it("batches split module parts and fails only the module of a failed part",
       function()
        local previous_getenv = platform.getenv
        platform.getenv = function(name)
            if name == "MAKEFLAGS" then return nil end
            return previous_getenv(name)
        end
        finally(function() platform.getenv = previous_getenv end)
        configure_counting_compiler("parts", "one.part1")
        local leaves = { "one", "two", "eight" }
        local requests = checked_requests(leaves)
        for _, request in ipairs(requests) do
            request.options = { c_parts = 3, split_threshold = 1 }
        end
        local diagnostic_path = workspace_directory .. "/diagnostics"
        diagnostic_stream = assert(io.open(diagnostic_path, "w+b"))
        io.stderr = diagnostic_stream
        local results = driver.compile_modules(requests, JOBS, false)
        assert(io.stderr:flush())
        assert(io.stderr:seek("set", 0))
        local diagnostics = assert(io.stderr:read("*a"))
        assert(diagnostic_stream:close())
        diagnostic_stream = nil
        io.stderr = previous_stderr

        -- Every part of every module is its own compiler process in one batch.
        local commands = read_file(state_directory .. "/commands")
        local parts = {}
        for _, leaf in ipairs(leaves) do
            parts[leaf] = {}
            for command in commands:gmatch("[^\n]+") do
                local part = command:match("/batch/" .. leaf .. "%.part(%d+)%.c")
                if part then
                    parts[leaf][#parts[leaf] + 1] = tonumber(part)
                elseif command:find("/batch/" .. leaf .. ".c", 1, true) then
                    parts[leaf][#parts[leaf] + 1] = 0
                end
            end
            table.sort(parts[leaf])
        end
        assert.is_true(#parts.one >= 2, commands)
        assert.is_true(#parts.eight >= 2, commands)
        assert.equal(tostring(JOBS) .. "\n",
            read_file(state_directory .. "/maximum"))

        -- Diagnostics replay in module, then part, order.
        local previous = 0
        for _, leaf in ipairs(leaves) do
            for _, part in ipairs(parts[leaf]) do
                local label = part == 0 and leaf or (leaf .. ".part" .. part)
                local position = assert(diagnostics:find(
                    "parallel compiler diagnostic: " .. label .. "\n", 1, true),
                    diagnostics)
                assert.is_true(previous < position, diagnostics)
                previous = position
            end
        end

        -- The failed part fails only its module, which publishes nothing.
        assert.falsy(results[1].ok)
        assert.equal("exit", results[1].err)
        assert.truthy(diagnostics:find("parallel compiler sentinel: one.part1", 1, true),
            diagnostics)
        for _, part in ipairs(parts.one) do
            assert.is_false(file_exists(driver.part_object_filename(
                source_root .. "/batch/one", part)))
        end
        assert.is_false(file_exists(source_root .. "/batch/one.parts"))
        for index = 2, 3 do
            local leaf = leaves[index]
            assert.truthy(results[index].ok, results[index].err)
            assert.equal(#parts[leaf], #results[index].objects)
            for _, object in ipairs(results[index].objects) do
                assert.is_true(file_exists(object), object)
            end
            assert.is_true(file_exists(source_root .. "/batch/" .. leaf .. ".parts"))
        end
    end)

    it("rejects duplicate modules and aliased object outputs", function()
        local requests = checked_requests()
        local ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[1] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "duplicate compilation request", 1, true), tostring(failure))

        requests[2].mod.filename = requests[1].mod.filename
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        requests[2].mod.filename = source_root ..
            "/batch/../batch/one.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

    end)

    it("rejects object-output symlink aliases", function()
        if platform.windows then
            pending("Windows uses lexical output paths")
            return
        end
        local available, message = filesystem.symlink_capability()
        if not available then
            pending(message)
            return
        end
        local requests, ok, failure
        local alias = source_root .. "/alias"
        assert(lfs.link(source_root .. "/batch", alias, true))
        requests = checked_requests()
        requests[2].mod.filename = alias .. "/one.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))

        requests = checked_requests()
        requests[1].mod.filename = source_root ..
            "/batch/new/shared.titan"
        requests[2].mod.filename = alias .. "/new/shared.titan"
        ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
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
            { requests[1], requests[2] }, JOBS, false)
        assert(os.remove(dangling_output))
        if platform.windows then
            assert(lfs.rmdir(alias))
        else
            assert(os.remove(alias))
        end
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))
    end)

    it("rejects object-output hardlink aliases", function()
        if platform.windows then
            pending("LuaFileSystem does not provide Windows file identity")
            return
        end
        local requests = checked_requests()
        copy_file(requests[1].mod.filename,
            source_root .. "/batch/one.o")
        assert(lfs.link(source_root .. "/batch/one.o",
            source_root .. "/batch/two.o"))
        local ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("rejects object-output paths that differ only by case", function()
        local requests = checked_requests()
        requests[1].mod.filename = source_root .. "/Case.titan"
        requests[2].mod.filename = source_root .. "/case.titan"
        local ok, failure = pcall(driver.compile_modules,
            { requests[1], requests[2] }, JOBS, false)
        assert.falsy(ok)
        assert.truthy(tostring(failure):find(
            "share object output", 1, true), tostring(failure))
    end)

    it("rejects a self-referential object-output symlink without replacing it", function()
        local available, message = filesystem.symlink_capability()
        if not available then
            pending(message)
            return
        end
        local request = checked_requests()[1]
        request.mod.filename = source_root .. "/loop.titan"
        assert(lfs.link("./loop.o", source_root .. "/loop.o", true))

        local results = driver.compile_modules({ request }, JOBS, false)
        assert.is_nil(results[1].ok)
        assert.matches("regular nonlink file", results[1].err, 1, true)
        assert.equal("link", lfs.symlinkattributes(source_root .. "/loop.o", "mode"))
        assert.equal("./loop.o", lfs.symlinkattributes(source_root .. "/loop.o", "target"))
    end)

    it("reports completion channel creation failures without launching", function()
        configure_counting_compiler()
        local requests = checked_requests()
        local temporary_path
        local fifo_command
        if platform.windows then
            process.new_batch = function()
                return nil, "injected completion creation failure"
            end
        else
            override_tmpname(function()
                temporary_path = original_compile_tmpname()
                return temporary_path
            end)
            os.execute = function(command)
                if command:find("mkfifo", 1, true) then
                    fifo_command = command
                    return nil, "exit", 91
                end
                return previous_execute(command)
            end
        end

        local results = driver.compile_modules(requests, JOBS, false)
        restore_tmpname()
        os.execute = previous_execute
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(platform.windows and
                "injected completion creation failure" or
                "failed to create parallel compiler completion FIFO",
                1, true), tostring(result.err))
        end
        if not platform.windows then
            assert.truthy(fifo_command:find(
                "'mkfifo' '-m' '600' ", 1, true), fifo_command)
            assert.falsy(file_exists(temporary_path))
        end
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("reports completion channel setup failures without launching", function()
        configure_counting_compiler()
        local temporary_path
        if platform.windows then
            process.new_batch = function()
                error("injected completion open failure", 0)
            end
        else
            override_tmpname(function()
                temporary_path = original_compile_tmpname()
                return temporary_path
            end)
            io.open = function(path, mode)
                if mode == "r+" then
                    return nil, "injected completion open failure"
                end
                return previous_open(path, mode)
            end
        end

        local results = driver.compile_modules(checked_requests(), JOBS, false)
        restore_tmpname()
        io.open = previous_open
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected completion open failure", 1, true),
                tostring(result.err))
        end
        if not platform.windows then
            assert.falsy(file_exists(temporary_path))
        end
        assert.falsy(file_exists(state_directory .. "/commands"))
    end)

    it("reaps every compiler after a completion channel read failure", function()
        configure_counting_compiler()
        local temporary_logs = {}
        override_tmpname(function()
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)
        if platform.windows then
            batch_overrides.wait = function()
                return nil, "injected completion read failure"
            end
        else
            override_completion_file({
                read = function()
                    return nil, "injected completion read failure"
                end,
            })
        end

        local results = driver.compile_modules(
            checked_requests(REFILL_LEAVES), JOBS, false)
        restore_tmpname()
        restore_completion_file()
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected completion read failure", 1, true),
                tostring(result.err))
        end
        assert.equal("0\n", read_file(state_directory .. "/active"))
        local commands = read_file(state_directory .. "/commands")
        local count = 0
        for _ in commands:gmatch("[^\n]+") do count = count + 1 end
        assert.equal(JOBS, count, commands)
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("reports completion channel cleanup failures after reaping", function()
        configure_counting_compiler()
        if platform.windows then
            batch_overrides.close = function(original, batch)
                assert(original(batch))
                return nil, "injected completion close failure"
            end
        else
            override_completion_file({
                close = function(original, file)
                    assert(original(file))
                    return nil, "injected completion close failure"
                end,
            })
        end

        local results = driver.compile_modules(checked_requests(), JOBS, false)
        restore_completion_file()
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected completion close failure", 1, true),
                tostring(result.err))
        end
        assert.equal("0\n", read_file(state_directory .. "/active"))
    end)

    it("reaps an active batch when creating a later log fails", function()
        configure_counting_compiler(nil, nil, math.min(JOBS, 3))
        local requests = requests_with_headers()
        local temporary_logs = {}
        -- Both platforms reserve object siblings before the logs; POSIX also
        -- reserves the completion FIFO before its first log.
        local calls = -#requests
        override_tmpname(function()
            calls = calls + 1
            if calls == (platform.windows and 3 or 4) then
                error("injected tmpname failure", 0)
            end
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)

        local results = driver.compile_modules(requests, JOBS, false)
        restore_tmpname()
        local failed = 0
        for _, result in ipairs(results) do
            if result.ok then
                assert.truthy(result.ok, result.err)
            else
                failed = failed + 1
                assert.truthy(tostring(result.err):find(
                    "injected tmpname failure", 1, true),
                    tostring(result.err))
            end
        end
        assert.equal(1, failed)
        assert.equal(tostring(math.min(JOBS, 3)) .. "\n",
            read_file(state_directory .. "/maximum"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("cleans the first log when creating the second log fails", function()
        configure_counting_compiler(nil, nil, math.min(JOBS, 3))
        local requests = requests_with_headers()
        local temporary_logs = {}
        local calls = -#requests
        override_tmpname(function()
            calls = calls + 1
            if calls == (platform.windows and 2 or 3) then
                return nil, "injected missing temporary path"
            end
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)

        local results = driver.compile_modules(requests, JOBS, false)
        restore_tmpname()
        assert.falsy(results[1].ok)
        assert.truthy(tostring(results[1].err):find(
            "injected missing temporary path", 1, true), tostring(results[1].err))
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
        override_tmpname(function()
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)
        io.stderr = {
            write = function() return nil, "injected command write failure" end,
            flush = function() return true end,
        }
        local results = driver.compile_modules(checked_requests(), JOBS, true)
        io.stderr = previous_stderr
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected command write failure", 1, true),
                tostring(result.err))
        end

        override_launch(function() error("injected popen exception", 0) end)
        results = driver.compile_modules(checked_requests(), JOBS, false)
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected popen exception", 1, true), tostring(result.err))
        end

        override_launch(function() return nil, "injected unavailable popen" end)
        results = driver.compile_modules(checked_requests(), JOBS, false)
        restore_launch()
        restore_tmpname()
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
        local results = driver.compile_modules(checked_requests(), JOBS, false)
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected false write", 1, true), tostring(result.err))
        end

        io.stderr = {
            write = function() return true end,
            flush = function() return nil, "injected false flush" end,
        }
        results = driver.compile_modules(checked_requests(), JOBS, false)
        io.stderr = previous_stderr
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "injected false flush", 1, true), tostring(result.err))
        end
    end)

    it("prints only commands whose parallel launch is attempted", function()
        configure_counting_compiler(nil, nil, math.min(JOBS, 3))
        local requests = requests_with_headers()
        local temporary_logs = {}
        local calls = -#requests
        override_tmpname(function()
            calls = calls + 1
            if calls == (platform.windows and 1 or 2) then
                error("injected tmpname failure", 0)
            end
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)
        local shown = {}
        io.stderr = {
            write = function(_, output)
                shown[#shown + 1] = output
                return true
            end,
            flush = function() return true end,
        }

        local results = driver.compile_modules(requests, JOBS, true)
        restore_tmpname()
        io.stderr = previous_stderr
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
        assert.equal(tostring(math.min(JOBS, 3)) .. "\n",
            read_file(state_directory .. "/maximum"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("reaps the batch when a replay log cannot be opened", function()
        configure_counting_compiler()
        local requests = checked_requests()
        local temporary_logs = {}
        local log_paths = {}
        override_tmpname(function()
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            log_paths[path] = true
            return path
        end)
        io.open = function(path, mode)
            if mode == "rb" and log_paths[path] then
                return nil, "injected log open failure"
            end
            return previous_open(path, mode)
        end

        local results = driver.compile_modules(requests, JOBS, false)
        restore_tmpname()
        io.open = previous_open
        for _, result in ipairs(results) do
            assert.falsy(result.ok)
            assert.truthy(tostring(result.err):find(
                "stdout: injected log open failure", 1, true),
                tostring(result.err))
        end
        assert.equal("0\n", read_file(state_directory .. "/active"))
        for _, path in ipairs(temporary_logs) do
            assert.falsy(file_exists(path), path)
        end
    end)

    it("reaps the batch and removes logs after a replay exception", function()
        configure_counting_compiler("diagnostics")
        local temporary_logs = {}
        override_tmpname(function()
            local path = original_compile_tmpname()
            temporary_logs[#temporary_logs + 1] = path
            return path
        end)
        io.stderr = {
            write = function() error("injected replay failure", 0) end,
            flush = function() return true end,
        }

        local results = driver.compile_modules(checked_requests(), JOBS, false)
        restore_tmpname()
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

    it("uses four CLI compilation jobs by default", function()
        local ok, output, why, code = titanc(nil)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("4\n", read_file(state_directory .. "/maximum"), output)
        assert.is_true(file_exists(workspace_directory ..
            (platform.windows and "/batch.dll" or "/batch.so")))
        if not platform.windows then
            assert.is_true(file_exists(workspace_directory .. "/batch.a"))
        end
    end)

    it("preserves completion notification for an exec compiler prefix", function()
        if platform.windows then
            pending("POSIX exec compiler prefix and asynchronous completion notification")
            return
        end
        local ok, output, why, code = titanc(
            "4", nil, nil, nil, "exec " .. WRAPPER, true)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_compiler_batch(output)
    end)

    it("uses TITAN_JOBS as the concurrency bound", function()
        local ok, output, why, code = titanc(tostring(JOBS))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_compiler_batch(output)
    end)

    it("lets --jobs override the environment", function()
        local ok, output, why, code = titanc("1", tostring(JOBS))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_compiler_batch(output)
    end)

    it("replays diagnostics in logical-module order", function()
        local ok, output, why, code = titanc(tostring(JOBS), nil, nil, "reverse")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local previous = 0
        for _, leaf in ipairs({ "four", "one", "three", "two" }) do
            local position = assert(output:find(
                "parallel compiler diagnostic: " .. leaf, 1, true), output)
            assert.is_true(previous < position, output)
            previous = position
        end
        assert_compiler_batch(output)
    end)

    it("replays a failed compiler diagnostic and still reaps the batch",
       function()
        local ok, output = titanc(tostring(JOBS), nil, "three")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "parallel compiler sentinel: three", 1, true), output)
        assert.equal(tostring(JOBS) .. "\n",
            read_file(state_directory .. "/maximum"), output)
        assert.falsy(file_exists(workspace_directory ..
            (platform.windows and "/batch.dll" or "/batch.so")))
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

local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

local EXIT = {}
local MODULE_NAMES = {
    "argparse",
    "titan-compiler.build",
    "titan-compiler.checker",
    "titan-compiler.coder",
    "titan-compiler.coverage",
    "titan-compiler.parser",
    "titan-compiler.driver",
    "titan-compiler.incremental",
    "titan-compiler.linkcertificate",
    "titan-compiler.nativeinputs",
    "titan-compiler.test_runner",
    "titan-compiler.util",
}

local function fake_argparse(arguments)
    return function()
        local parser = {}
        local declaration = {}
        function declaration:args() return self end
        function declaration:count() return self end
        function declaration:action() return self end
        function parser:argument() return declaration end
        function parser:flag() return declaration end
        function parser:option() return declaration end
        function parser:parse() return arguments end
        return parser
    end
end

local function run_titanc(arguments, environment_jobs)
    local observed = {}
    local driver = {
        imported = {},
        INSTALLED = false,
        TITAN_SOURCE_PATH = ".",
        LUA_SOURCE_PATH = "lua",
        EMIT_LINE_DIRECTIVES = true,
        EXTRA_CPPFLAGS = {},
        EXTRA_CFLAGS = {},
        EXTRA_LDFLAGS = {},
        AR = "ar",
        RANLIB = "ranlib",
        BUILD_PROFILE = "validation",
    }
    local resolver

    function driver.close_resolver_context(context)
        context.closed = true
        return true
    end

    function driver.deduplicate_module_names(names) return names end
    function driver.apply_native_inputs(normalized)
        observed.native_inputs = normalized
    end
    function driver.configure_foreign_c() return true end
    function driver.default_c_parts() return 4 end
    function driver.prepare_output_root(dir) return dir end
    function driver.module_compiled_objects(mod)
        return { mod.filename:gsub("[.]titan$", ".o") }
    end
    function driver.source_link_inputs() return {} end
    function driver.incremental_configuration()
        return { compiler = "compiler" }
    end
    function driver.toolchain_descriptor() return {} end
    function driver.generated_compile_prefix() return { "cc" } end
    function driver.link_extra_flags() return {} end
    function driver.native_link_backend() return "none" end
    function driver.windows_launcher_manifest() return "" end
    function driver.prepare_foreign_headers() return true end
    function driver.preflight_build_outputs() return true end
    function driver.record_module_symbols(_, _, symbols)
        assert.same({}, symbols)
    end
    function driver.plan_compile_requests(requests)
        observed.preflight_requests = requests
        return { outputs = {}, inputs = {} }
    end
    function driver.new_resolver_context(options)
        observed.resolver_jobs = options.jobs
        resolver = {
            source_names = {},
            selected_static_providers = {},
            dynamic_names = {},
            native_bindings = {},
            native_interface_types = {},
            native_static_names = {},
        }
        return resolver
    end
    function driver.defaultloader() return function() end end
    function driver.finalize_resolver_context() return true end
    function driver.plan_foreign_headers() return {} end
    function driver.common_module_provider()
        return "pkg", { "pkg.one", "pkg.two" }
    end
    function driver.plan_module_shims()
        return {}, "pkg.so"
    end
    function driver.validate_provider_output_paths() return true end
    function driver.mangle_module_name(name)
        return name:gsub("[.]", "_")
    end
    function driver.write_foreign_header_plans() return true end
    function driver.compile_modules(requests, jobs, verbose, plans)
        assert.is_table(plans)
        assert.equal(requests, observed.preflight_requests)
        observed.requests = requests
        observed.jobs = jobs
        observed.verbose = verbose
        local results = {}
        for index, request in ipairs(requests) do
            if request.modname == "pkg.two" then
                results[index] = {
                    ok = true,
                    libname = "pkg/two.o",
                    objects = { "pkg/two.o" },
                }
            else
                results[index] = {
                    ok = false,
                    err = "compile failure for " .. request.modname,
                }
            end
        end
        return results
    end

    local checker = {}
    local function check_root(name)
        local filename = name:gsub("[.]", "/") .. ".titan"
        driver.imported[name] = {
            ast = {},
            filename = filename,
            source_files = { filename },
            native_references = {},
        }
        resolver.source_names[name] = true
    end
    function checker.checkimport(name)
        check_root(name)
        return true, {}
    end
    function checker.has_main() return false end

    -- The coordinator: one lock set, then every root restored.
    local build = {}
    function build.lock_outputs(_, directories)
        observed.locked = directories
        return {
            release = function()
                observed.lock_released = true
                return true
            end,
        }
    end
    function build.run(context, request)
        observed.build_jobs = request.jobs
        assert.is_table(request.locks)
        for _, name in ipairs(request.roots) do check_root(name) end
        context.loader = function() end
        return true
    end

    local modules = {
        ["argparse"] = fake_argparse(arguments),
        ["titan-compiler.build"] = build,
        ["titan-compiler.checker"] = checker,
        ["titan-compiler.coverage"] = {},
        ["titan-compiler.coder"] = {
            external_symbols = function() return {} end,
            interface_external_symbols = function() return {} end,
            prepare_coverage = function() end,
        },
        ["titan-compiler.parser"] = {
            pretty_print_ast = function() return "" end,
        },
        ["titan-compiler.driver"] = driver,
        ["titan-compiler.incremental"] = {
            toolchain_identity = function() return "toolchain" end,
            load_digest_cache = function(context)
                assert.equal(resolver, context)
                assert.is_table(observed.locked)
                assert.falsy(observed.lock_released)
                observed.digest_cache_loaded = true
                return true
            end,
            save_digest_cache = function(context)
                assert.equal(resolver, context)
                assert.falsy(context.closed)
                assert.falsy(observed.lock_released)
                observed.digest_cache_saved = true
                return true
            end,
        },
        ["titan-compiler.linkcertificate"] = {
            prepare = function()
                return { directory = "link", synthetic_directory = "syn" }
            end,
            check = function() return false, "no-record" end,
            invalidate = function() return true end,
            commit = function() return true end,
        },
        ["titan-compiler.nativeinputs"] = {
            normalize = function()
                return {
                    ordered = {}, c_sources = {}, compile_argv = {},
                    link_argv = {}, cppflags = {}, cflags = {}, ldflags = {},
                }
            end,
        },
        ["titan-compiler.test_runner"] = {
            MODULE_NAME = "__test.runner",
        },
        ["titan-compiler.util"] = {
            bytewise_less = function(left, right) return left < right end,
        },
    }

    local saved_modules = {}
    for _, name in ipairs(MODULE_NAMES) do
        saved_modules[name] = package.loaded[name]
        package.loaded[name] = modules[name]
    end
    local saved_getenv = platform.getenv
    local saved_exit = os.exit
    local saved_stderr = io.stderr
    local diagnostics = {}
    platform.getenv = function(name)
        if name == "TITAN_JOBS" then return environment_jobs end
        return saved_getenv(name)
    end
    os.exit = function() error(EXIT, 0) end
    io.stderr = {
        write = function(_, ...)
            for index = 1, select("#", ...) do
                diagnostics[#diagnostics + 1] = tostring(select(index, ...))
            end
        end,
    }

    local chunk = assert(loadfile("titanc"))
    local ok, failure = pcall(chunk)

    io.stderr = saved_stderr
    os.exit = saved_exit
    platform.getenv = saved_getenv
    for _, name in ipairs(MODULE_NAMES) do
        package.loaded[name] = saved_modules[name]
    end

    assert.is_false(ok)
    assert.equal(EXIT, failure)
    return table.concat(diagnostics), observed
end

local function ordinary_arguments(jobs)
    return {
        module = { "pkg.three", "pkg.two", "pkg.one" },
        jobs = jobs,
        extra_object = nil,
        coverage_module = {},
        coverage_format = {},
        link = {},
        library_dir = {},
        include_dir = {},
        define = {},
        cflag = {},
        ldflag = {},
        c_source = {},
        test_dir = {},
        test_exclude = {},
    }
end

describe("titanc generated-C parallelism dispatch", function()
    it("rejects malformed and overflowing bounds before resolution", function()
        local malformed, malformed_observed =
            run_titanc(ordinary_arguments(nil), "0")
        assert.same({}, malformed_observed)
        assert.equal(
            "--jobs and TITAN_JOBS require a positive integer\n",
            malformed)

        local overflowing, overflowing_observed = run_titanc(
            ordinary_arguments(string.rep("9", 100)), nil)
        assert.same({}, overflowing_observed)
        assert.equal(
            "--jobs and TITAN_JOBS require a positive integer\n",
            overflowing)
    end)

    it("lets the command-line jobs bound override the environment", function()
        local _, observed = run_titanc(ordinary_arguments("2"), "invalid")
        assert.equal(2, observed.jobs)
        -- The same local cap bounds the resolver's speculative C probe batches.
        assert.equal(2, observed.resolver_jobs)
        -- And the module coordinator's single slot ledger.
        assert.equal(2, observed.build_jobs)
    end)

    it("defaults to four generated-C compilations", function()
        local _, observed = run_titanc(ordinary_arguments(nil), nil)
        assert.equal(4, observed.jobs)
        assert.equal(4, observed.resolver_jobs)
        assert.equal(4, observed.build_jobs)
    end)

    it("uses TITAN_JOBS and preserves sorted batch diagnostics", function()
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), "4")
        assert.equal(4, observed.jobs)
        assert.same({ "pkg.one", "pkg.three", "pkg.two" }, {
            observed.requests[1].modname,
            observed.requests[2].modname,
            observed.requests[3].modname,
        })
        assert.equal(
            "compile failure for pkg.one\ncompile failure for pkg.three\n",
            diagnostics)
    end)
end)

-- Real titanc processes against the installed SDK, with the checkout
-- compiler: concurrent invocations on one output tree, and a coordinator
-- killed while its worker still runs.
describe("titanc invocations sharing one output tree", function()
    if platform.windows then
        it("are exercised by the POSIX process harness", function()
            pending("Windows output-tree coordination runs in the Windows lanes")
        end)
        return
    end

    local installed_prefix = require "spec.support.installed_prefix"
    local ROOT = lfs.currentdir()
    local TIMEOUT = ROOT .. "/spec/support/run_with_timeout.sh"
    local PREFIX = installed_prefix.active()
    local LUA = PREFIX .. "/bin/lua"
    local CLEAN_ENV = "env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u TITAN_JOBS"
    local workspace

    local function quote(text) return assert(cdriver.shell_quote(text)) end

    local function read_file(path)
        local file = assert(io.open(path, "rb"))
        local contents = assert(file:read("a"))
        assert(file:close())
        return contents
    end

    local function write_file(path, contents)
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        assert(file:close())
    end

    local function exists(path) return lfs.attributes(path, "mode") ~= nil end

    local function lines(path)
        local result = {}
        if not exists(path) then return result end
        for line in read_file(path):gmatch("[^\n]+") do result[#result + 1] = line end
        return result
    end

    local function shell(command)
        local pipe = assert(io.popen(command .. " 2>&1", "r"))
        local output = assert(pipe:read("a"))
        local ok, _, code = pipe:close()
        return ok, output, code
    end

    local function remove_tree(path)
        local mode = lfs.symlinkattributes(path, "mode")
        if mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
            end
            lfs.rmdir(path)
        elseif mode then
            os.remove(path)
        end
    end

    -- A compiler stand-in that delays generated module C by
    -- TITAN_SLOW_CC_DELAY seconds and logs each such compilation's start and
    -- end with its process id.
    local SLOW_CC = [[
#!/bin/sh
log=${TITAN_SLOW_CC_LOG:?}
slow=no
compile_only=no
for argument in "$@"; do
    case "$argument" in
        -c) compile_only=yes ;;
        */build/.titan/*) ;;
        */build/*.c) slow=yes ;;
    esac
done
test "$slow" = yes && test "$compile_only" = yes || exec cc "$@"
printf 'start %s\n' "$$" >> "$log"
sleep "${TITAN_SLOW_CC_DELAY:-0}"
cc "$@"
status=$?
printf 'end %s\n' "$$" >> "$log"
exit $status
]]

    before_each(function()
        workspace = assert(require("titan-compiler.io").new_sync():tmpname())
        os.remove(workspace)
        assert(lfs.mkdir(workspace))
        write_file(workspace .. "/slow_cc.sh", SLOW_CC)
        assert(shell("chmod +x " .. quote(workspace .. "/slow_cc.sh")))
        write_file(workspace .. "/titanc.sh", table.concat({
            "#!/bin/sh",
            "exec " .. CLEAN_ENV .. " CC=" .. quote(workspace .. "/slow_cc.sh") ..
                " TITAN_EXTRA_CPPFLAGS= TITAN_EXTRA_CFLAGS= TITAN_EXTRA_LDFLAGS=" ..
                " TITAN_SLOW_CC_LOG=" .. quote(workspace .. "/cc.log") ..
                " TITAN_ROCKS_ROOT=" .. quote(PREFIX) ..
                " TITAN_RUNTIME_PREBUILT=1 " .. quote(LUA) .. " -e " ..
                quote("package.path = " .. string.format("%q",
                    ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;") ..
                    " .. package.path") ..
                " " .. quote(ROOT .. "/titanc") .. ' "$@"',
            "",
        }, "\n"))
        assert(shell("chmod +x " .. quote(workspace .. "/titanc.sh")))
    end)

    after_each(function() remove_tree(workspace) end)

    it("serialize an application and its tests and both stay correct", function()
        write_file(workspace .. "/lib.titan", [[
function twice(number: integer): integer
  return number * 2
end
]])
        write_file(workspace .. "/app.titan", [[
local lib = import "lib"

function main(args: {string}): integer
  if lib.twice(21) == 42 then return 0 else return 1 end
end
]])
        write_file(workspace .. "/app_tests.titan", [[
local test = import "test"
local lib = import "lib"

function test_twice(context: test.Context)
  test.assert(lib.twice(21) == 42)
end
]])
        local function both()
            local script = table.concat({
                "cd " .. quote(workspace) .. " || exit 1",
                "{ TITAN_SLOW_CC_DELAY=1 ./titanc.sh -v --incremental -o build app " ..
                    "> app.log 2>&1; echo $? > app.status; } &",
                "{ TITAN_SLOW_CC_DELAY=1 ./titanc.sh -v --incremental -o build --test " ..
                    "app_tests > tests.log 2>&1; echo $? > tests.status; } &",
                "wait",
            }, "\n")
            local ok, output = shell(quote(TIMEOUT) .. " 300 sh -c " .. quote(script))
            assert.truthy(ok, output)
            local app_log = read_file(workspace .. "/app.log")
            local tests_log = read_file(workspace .. "/tests.log")
            assert.equal("0", (read_file(workspace .. "/app.status"):gsub("%s+", "")), app_log)
            assert.equal("0", (read_file(workspace .. "/tests.status"):gsub("%s+", "")), tests_log)
            return app_log, tests_log
        end
        for round = 1, 2 do
            local app_log, tests_log = both()
            local _, app_waits = app_log:gsub("waiting for build lock", "")
            local _, tests_waits = tests_log:gsub("waiting for build lock", "")
            -- At most one invocation finds the tree locked. On the cold round
            -- the first one compiles for seconds, so the second must wait for
            -- all of it; a certified second round may not overlap at all.
            local waits = app_waits + tests_waits
            if round == 1 then
                assert.equal(1, waits, app_log .. "\n----\n" .. tests_log)
            else
                assert.truthy(waits <= 1, app_log .. "\n----\n" .. tests_log)
            end
            local app_ok, app_output = shell(quote(workspace .. "/build/app"))
            assert.truthy(app_ok, app_output)
            local tests_ok, tests_output = shell(quote(workspace .. "/build/app_tests"))
            assert.truthy(tests_ok, tests_output)
        end
    end)

    it("wait for the orphaned worker and native batch jobs of a killed coordinator", function()
        local payload = string.rep("x", 1100 * 1024)
        write_file(workspace .. "/slow.titan", string.format([[
function first(): string
  return "%s"
end

function second(): string
  return "%s"
end

function value(): integer
  return #first() + #second()
end
]], payload, payload))
        local pid_file = workspace .. "/titanc.pid"
        local log = workspace .. "/cc.log"
        -- A simple background command, so $! is titanc's own process.
        -- Splitting into two C parts under -j 2 dispatches a remote batch
        -- whose native compiler jobs must also hold the output-tree lock.
        assert(shell("cd " .. quote(workspace) .. " || exit 1; TITAN_SLOW_CC_DELAY=3 " ..
            "./titanc.sh -c -o build --c-parts 2 -j 2 slow > first.log 2>&1 & echo $! > " ..
            quote(pid_file)))
        for _ = 1, 1200 do
            if #lines(log) >= 2 then break end
            os.execute("sleep 0.05")
        end
        assert.equal(2, #lines(log), exists(workspace .. "/first.log") and
            read_file(workspace .. "/first.log") or "")
        -- The coordinator dies; its worker exits on control EOF, while both
        -- coordinator-spawned native compilers keep running with the lock.
        assert(os.execute("kill -KILL " .. assert(tonumber(read_file(pid_file)))))
        local ok, output = shell(quote(TIMEOUT) .. " 120 sh -c " ..
            quote("cd " .. quote(workspace) .. " && TITAN_SLOW_CC_DELAY=0 " ..
                "./titanc.sh -v -c -o build --c-parts 2 -j 2 slow"))
        assert.truthy(ok, output)
        assert.truthy(output:find("waiting for build lock", 1, true), output)
        local events = lines(log)
        assert.equal(8, #events, table.concat(events, "\n"))
        local orphan_starts = {
            assert(events[1]:match("^start (%d+)$")),
            assert(events[2]:match("^start (%d+)$")),
        }
        local orphan_ends = {
            assert(events[3]:match("^end (%d+)$")),
            assert(events[4]:match("^end (%d+)$")),
        }
        table.sort(orphan_starts)
        table.sort(orphan_ends)
        -- The successor compiled only after both orphaned native jobs ended.
        assert.same(orphan_starts, orphan_ends)
        assert.truthy(events[5]:match("^start %d+$"), events[5])
        assert.truthy(exists(workspace .. "/build/slow.o"))
        assert.truthy(exists(workspace .. "/build/slow.part1.o"))
    end)
end)

describe("native process launch policy", function()
    local function with_transport(guard, check)
        local names = { "titan-compiler.process", "titan-compiler.platform", "titan", "luv" }
        local saved, registry = {}, debug.getregistry()
        local anchor = "titan-compiler.process: luv"
        local previous_loop = registry[anchor]
        for _, name in ipairs(names) do saved[name] = package.loaded[name] end
        local events, pending, stdio = {}, nil, nil
        local uv = {
            os_environ = function() return {} end,
            fs_open = function() return 100 end,
            fs_close = function() end,
            spawn = function(_, options, completed)
                events[#events + 1] = "spawn"
                stdio = options.stdio
                pending = function() completed(0, 0) end
                return { close = function(_, callback) callback() end }, 42
            end,
            run = function()
                if pending then local callback = pending; pending = nil; callback() end
            end,
        }
        registry[anchor] = uv
        package.loaded["titan-compiler.process"] = nil
        package.loaded["titan-compiler.platform"] = { windows = true }
        package.loaded.titan = guard and {
            _native_process_tree_guard = function()
                events[#events + 1] = "contain"
                return guard()
            end,
        } or {}
        package.loaded.luv = uv
        local ok, err = pcall(function()
            check(require("titan-compiler.process"), events, function() return stdio end)
        end)
        registry[anchor] = previous_loop
        for _, name in ipairs(names) do package.loaded[name] = saved[name] end
        assert.truthy(ok, err)
    end

    it("establishes containment before spawning and preserves inherited leases", function()
        with_transport(function() return true end, function(process, events, stdio)
            assert(process.run({ "cc", "input.c" }, { inherit = { 71, 72 } }))
            assert.same({ "contain", "spawn" }, events)
            assert.same({ 0, 1, 2, 71, 72 }, stdio())
            assert(process.run({ "cc", "other.c" }))
            assert.same({ "contain", "spawn", "spawn" }, events)
        end)
    end)

    it("starts lease-bearing commands asynchronously and reaps them on close", function()
        with_transport(function() return true end, function(process, events, stdio)
            local child = assert(process.start({ "sh", "-c", "compile" },
                { inherit = { 81, 82 } }))
            assert.same({ "contain", "spawn" }, events)
            assert.same({ 0, 1, 2, 81, 82 }, stdio())
            assert.is_nil(child.closed)
            assert.same({ true, "exit", 0 }, { child:close() })
            assert.is_true(child.closed)
        end)
    end)

    it("does not launch when strict containment cannot be established", function()
        with_transport(function() return nil, "job assignment refused" end,
            function(process, events)
                local child, err = process.new_batch():spawn({ "cc" }, "out", "err", 1)
                assert.is_nil(child)
                assert.equal("job assignment refused", err)
                assert.same({ "contain" }, events)
            end)
    end)

    it("does not fall back when the installed runtime lacks containment", function()
        with_transport(nil, function(process, events)
            local child, err = process.new_batch():spawn({ "cc" }, "out", "err", 1)
            assert.is_nil(child)
            assert.matches("runtime lacks _native_process_tree_guard", err, 1, true)
            assert.same({}, events)
        end)
    end)
end)

describe("Windows native descendant containment", function()
    if not platform.windows then return end
    local process = require "titan-compiler.process"
    local uv = process.library()
    local repository = assert(platform.path.normalize(lfs.currentdir()))
    local prefix = assert(platform.path.normalize(
        require("spec.support.installed_prefix").active()))
    local lua = prefix .. "/bin/lua.exe"
    local workspace, wrapper, children, writer_pid, real_command

    local function write_file(path, contents)
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents)); assert(file:close())
    end

    local function read_file(path)
        local file = io.open(path, "rb")
        if not file then return nil end
        local contents = assert(file:read("a")); assert(file:close())
        return contents
    end

    local function remove_tree(path)
        local mode = lfs.symlinkattributes(path, "mode")
        if mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
            end
            assert(lfs.rmdir(path))
        elseif mode then assert(os.remove(path)) end
    end

    local function wait_until(condition, milliseconds)
        local deadline = uv.hrtime() + milliseconds * 1000000
        repeat
            uv.run("nowait")
            if condition() then return true end
            uv.sleep(10)
        until uv.hrtime() >= deadline
        return false
    end

    local function compiler_environment(match)
        local values = {}
        for name, value in pairs(uv.os_environ()) do
            local key = name:upper()
            if key ~= "MAKEFLAGS" and key ~= "MFLAGS" and key ~= "MAKELEVEL" and
               key ~= "TITAN_JOBS" then values[key] = name .. "=" .. value end
        end
        for name, value in pairs({
            CC = assert(platform.windows_process_command({ wrapper })),
            PATH = prefix .. "/bin;" .. (platform.getenv("PATH") or ""),
            TITAN_ROCKS_ROOT = prefix, TITAN_RUNTIME_PREBUILT = "1",
            TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "-O0 -fno-lto",
            TITAN_EXTRA_LDFLAGS = "-fno-lto", CCACHE_DISABLE = "1",
            TITAN_TREE_REAL_CC = real_command, TITAN_TREE_MATCH = match or "",
            TITAN_TREE_READY = workspace .. "/writer.ready",
            TITAN_TREE_RELEASE = workspace .. "/writer.release",
            TITAN_TREE_FINISHED = workspace .. "/writer.finished",
        }) do values[name] = name .. "=" .. value end
        local result = {}
        for _, value in pairs(values) do result[#result + 1] = value end
        return result
    end

    local function start_compiler(role, match, jobs, c_source_only)
        local log = assert(uv.fs_open(workspace .. "/" .. role .. ".log", "w", 420))
        local child = {}
        local initialize = string.format(
            "package.path=%q..package.path;package.cpath=%q..package.cpath;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;",
            repository .. "/titan-runtime/bootstrap/?.dll;")
        if c_source_only then
            -- D2's native-only startup deliberately skips the Titan foreign
            -- profile. Exercise the late guard, after all output locks exist.
            initialize = initialize .. string.format([[
local build = require "titan-compiler.build"
local acquire = build.lock_outputs
local locked = false
build.lock_outputs = function(...)
  local locks, err = acquire(...)
  if locks then locked = true end
  return locks, err
end
local native = require "titan"
local guard = assert(native._native_process_tree_guard)
native._native_process_tree_guard = function()
  assert(locked, "C-only native launch unexpectedly preceded output lock admission")
  local ready, err = guard()
  if ready then
    local receipt = assert(io.open(%q, "wb"))
    assert(receipt:write("after-lock\n")); assert(receipt:close())
  end
  return ready, err
end
]], workspace .. "/" .. role .. ".guard")
        end
        if role == "successor" then
            initialize = initialize .. string.format([[
local factory = assert(package.loadlib(%q, "luaopen_native_writer_admission"))
local observer = factory().watch(%d)
local build = require "titan-compiler.build"
local acquire = build.lock_outputs
build.lock_outputs = function(...)
  assert(not observer:dead(), "old writer exited before the contested lock wait")
  local ready_path = %q
  local ready = assert(io.open(ready_path .. ".tmp", "wb"))
  assert(ready:write("waiting\n")); assert(ready:close())
  assert(os.rename(ready_path .. ".tmp", ready_path))
  local locks, err = acquire(...)
  if locks then
    assert(observer:dead(), "old native writer is alive at successor lock admission")
    local checked = assert(io.open(%q, "wb"))
    assert(checked:write("terminated\n")); assert(checked:close())
  end
  return locks, err
end
]], workspace .. "/native writer admission.dll", writer_pid,
                workspace .. "/admission.waiting", workspace .. "/admission.checked")
        end
        local arguments = {
            "-E", "-e", initialize,
            repository .. "/titanc", "-v", "--incremental", "--tree", workspace,
            "-o", workspace .. "/build", "--jobs", tostring(jobs),
        }
        if c_source_only then
            for _, word in ipairs({ "-c", "--c-source", workspace .. "/native_startup.c",
                    "--print-c-objects" }) do arguments[#arguments + 1] = word end
        else
            for _, word in ipairs({ "--exe", workspace .. "/application",
                    "--c-parts", tostring(jobs), "app" }) do
                arguments[#arguments + 1] = word
            end
        end
        local handle, err = uv.spawn(lua, { args = arguments, cwd = workspace,
            env = compiler_environment(match), stdio = { nil, log, log } },
            function(code, signal)
                child.code, child.signal, child.exited = code, signal, true
                child.handle:close()
            end)
        uv.fs_close(log)
        assert.truthy(handle, err)
        child.handle = handle
        children[#children + 1] = child
        return child
    end

    before_each(function()
        children, writer_pid = {}, nil
        workspace = assert(platform.path.normalize(
            require("titan-compiler.io").new_sync():tmpname()))
        assert(os.remove(workspace)); assert(lfs.mkdir(workspace))
        wrapper = workspace .. "/native wrapper.exe"
        local compiler = assert(cdriver.split_shell_words(platform.getenv("CC") or "clang"))
        real_command = assert(platform.windows_process_command(compiler))
        local argv = {}
        for _, word in ipairs(compiler) do argv[#argv + 1] = word end
        for _, word in ipairs({ "-std=c99", "-Wall", "-Wextra", "-Werror", "-municode",
                repository .. "/spec/fixtures/windows/native_writer_tree.c", "-o", wrapper }) do
            argv[#argv + 1] = word
        end
        local built = process.capture(argv)
        assert.truthy(built.ok, built.diagnostic)
        argv = {}
        for _, word in ipairs(compiler) do argv[#argv + 1] = word end
        for _, word in ipairs({ "-std=c99", "-Wall", "-Wextra", "-Werror", "-shared",
                "-Wl,--exclude-all-symbols", "-I", prefix .. "/include",
                repository .. "/spec/fixtures/windows/native_writer_admission.c",
                prefix .. "/lib/liblua55.a", "-o",
                workspace .. "/native writer admission.dll" }) do
            argv[#argv + 1] = word
        end
        local observer = process.capture(argv)
        assert.truthy(observer.ok, observer.diagnostic)
    end)

    after_each(function()
        for _, child in ipairs(children or {}) do
            if not child.exited then child.handle:kill("sigkill") end
        end
        if workspace and not writer_pid then
            writer_pid = tonumber((read_file(workspace .. "/writer.ready") or ""):match("^(%d+)"))
        end
        if writer_pid then process.capture({ wrapper, "--stop", tostring(writer_pid) }) end
        wait_until(function()
            for _, child in ipairs(children or {}) do if not child.exited then return false end end
            return true
        end, 10000)
        uv.run("nowait")
        if workspace then remove_tree(workspace) end
        workspace = nil
    end)

    local function killed_coordinator(match, jobs, c_source_only)
        if c_source_only then
            write_file(workspace .. "/native_startup.c",
                "int native_value(void) { return 73; }\n")
        else
            local payload = string.rep("x", 1100 * 1024)
            write_file(workspace .. "/app.titan", string.format([[
function first(): string return %q end
function second(): string return %q end
function main(args: {string}): integer
  if #first() + #second() == %d then return 0 else return 1 end
end
]], payload, payload, #payload * 2))
        end
        local holder = start_compiler("holder", match, jobs, c_source_only)
        assert.truthy(wait_until(function()
            return read_file(workspace .. "/writer.ready") ~= nil or holder.exited
        end, 90000), read_file(workspace .. "/holder.log"))
        local ready = read_file(workspace .. "/writer.ready")
        assert.truthy(ready, read_file(workspace .. "/holder.log"))
        local pid, output = ready:match("^(%d+)\n([^\n]+)\n$")
        writer_pid = assert(tonumber(pid), ready)
        assert.truthy(output, ready)
        if c_source_only then
            assert.equal("after-lock\n", read_file(workspace .. "/holder.guard"),
                read_file(workspace .. "/holder.log"))
        end
        local alive = process.capture({ wrapper, "--wait-dead", pid, "0" })
        assert.equal(1, alive.status, alive.diagnostic)
        -- Pin the live writer in the successor before killing the holder. Its
        -- direct zero-time query runs at the full lock-set admission boundary,
        -- not after another process launch or a wait for writer termination.
        local successor = start_compiler("successor", nil, jobs, c_source_only)
        assert.truthy(wait_until(function()
            return read_file(workspace .. "/admission.waiting") ~= nil or successor.exited
        end, 90000), read_file(workspace .. "/successor.log"))
        assert.equal("waiting\n", read_file(workspace .. "/admission.waiting"),
            read_file(workspace .. "/successor.log"))
        assert.is_nil(read_file(workspace .. "/admission.checked"))
        assert(holder.handle:kill("sigkill"))
        assert.truthy(wait_until(function() return holder.exited end, 10000))
        assert.truthy(wait_until(function() return successor.exited end, 90000),
            read_file(workspace .. "/successor.log"))
        assert.equal(0, successor.code, read_file(workspace .. "/successor.log"))
        assert.equal("terminated\n", read_file(workspace .. "/admission.checked"),
            read_file(workspace .. "/successor.log"))
        local native_object
        if c_source_only then
            assert.equal("after-lock\n", read_file(workspace .. "/successor.guard"),
                read_file(workspace .. "/successor.log"))
            local log = read_file(workspace .. "/successor.log"):gsub("\r\n", "\n")
            native_object = assert(log:match("([^\n]+)\n*$"), log)
            assert.truthy(native_object:match("[.]o$"), log)
            assert.equal("file", lfs.attributes(native_object, "mode"), log)
        else
            assert.equal("file", lfs.attributes(workspace .. "/build/app.o", "mode"))
        end
        local before = read_file(output)
        write_file(workspace .. "/writer.release", "continue\n")
        local dead = process.capture({ wrapper, "--wait-dead", pid, "10000" })
        assert.truthy(dead.ok, dead.diagnostic)
        assert.is_nil(lfs.attributes(workspace .. "/writer.finished"))
        assert.equal(before, read_file(output), "old native writer changed the output")
        if c_source_only then
            write_file(workspace .. "/native_consumer.c",
                "int native_value(void);\n" ..
                "int main(void) { return native_value() == 73 ? 0 : 1; }\n")
            local argv = assert(cdriver.split_shell_words(platform.getenv("CC") or "clang"))
            for _, word in ipairs({ workspace .. "/native_consumer.c", native_object,
                    "-o", workspace .. "/native_consumer.exe" }) do
                argv[#argv + 1] = word
            end
            local linked = process.capture(argv)
            assert.truthy(linked.ok, linked.diagnostic)
            local consumer = process.capture({ workspace .. "/native_consumer.exe" })
            assert.truthy(consumer.ok, consumer.diagnostic)
        else
            local application = process.capture({ workspace .. "/application.exe" })
            assert.truthy(application.ok, application.diagnostic)
        end
    end

    it("kills a synchronous entrypoint wrapper and its native grandchild", function()
        killed_coordinator("app__entrypoint.c", 1)
    end)

    it("kills coordinator-dispatched split compilers and their native grandchildren", function()
        -- Two large functions force the existing remote native-batch path.
        killed_coordinator("app.c", 2)
    end)

    it("contains C-only native writers when the first guard starts after lock admission", function()
        killed_coordinator("native_startup.c", 1, true)
    end)
end)

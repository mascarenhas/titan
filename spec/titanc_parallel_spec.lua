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
    "titan-compiler.test_runner",
    "titan-compiler.util",
}

local function fake_argparse(arguments)
    return function()
        local parser = {}
        local declaration = {}
        function declaration:args() return self end
        function declaration:count() return self end
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
    }
    local resolver

    function driver.close_resolver_context(context)
        context.closed = true
        return true
    end

    function driver.deduplicate_module_names(names) return names end
    function driver.configure_foreign_c() end
    function driver.default_c_parts() return 4 end
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
        return { release = function() return true end }
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
        extra_object = {},
        coverage_module = {},
        coverage_format = {},
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
for argument in "$@"; do
    case "$argument" in */build/*.c) slow=yes ;; esac
done
test "$slow" = yes || exec cc "$@"
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

    it("wait for the orphaned worker of a killed coordinator", function()
        write_file(workspace .. "/slow.titan", [[
function value(): integer
  return 7
end
]])
        local pid_file = workspace .. "/titanc.pid"
        local log = workspace .. "/cc.log"
        -- A simple background command, so $! is titanc's own process.
        assert(shell("cd " .. quote(workspace) .. " || exit 1; TITAN_SLOW_CC_DELAY=3 " ..
            "./titanc.sh -c -o build slow > first.log 2>&1 & echo $! > " ..
            quote(pid_file)))
        for _ = 1, 1200 do
            if #lines(log) > 0 then break end
            os.execute("sleep 0.05")
        end
        assert.equal(1, #lines(log), exists(workspace .. "/first.log") and
            read_file(workspace .. "/first.log") or "")
        -- The coordinator dies; its worker and compiler keep running.
        assert(os.execute("kill -KILL " .. assert(tonumber(read_file(pid_file)))))
        local ok, output = shell(quote(TIMEOUT) .. " 120 sh -c " ..
            quote("cd " .. quote(workspace) .. " && TITAN_SLOW_CC_DELAY=0 " ..
                "./titanc.sh -v -c -o build slow"))
        assert.truthy(ok, output)
        assert.truthy(output:find("waiting for build lock", 1, true), output)
        local events = lines(log)
        assert.equal(4, #events, table.concat(events, "\n"))
        local orphan = assert(events[1]:match("^start (%d+)$"))
        -- The successor compiled only after the orphan's compilation ended.
        assert.same({ "start " .. orphan, "end " .. orphan }, { events[1], events[2] })
        assert.truthy(events[3]:match("^start %d+$"), events[3])
        assert.truthy(exists(workspace .. "/build/slow.o"))
    end)
end)

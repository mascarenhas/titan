local assert = require "luassert"
local platform = require "titan-compiler.platform"

local EXIT = {}
local MODULE_NAMES = {
    "argparse",
    "titan-compiler.checker",
    "titan-compiler.coder",
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
    function driver.new_resolver_context()
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
    function driver.compile_modules(requests, jobs, verbose)
        observed.requests = requests
        observed.jobs = jobs
        observed.verbose = verbose
        local results = {}
        for index, request in ipairs(requests) do
            if request.modname == "pkg.two" then
                results[index] = {
                    ok = true,
                    libname = "pkg/two.o",
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
    function checker.checkimport(name)
        local filename = name:gsub("[.]", "/") .. ".titan"
        driver.imported[name] = {
            ast = {},
            filename = filename,
            source_files = { filename },
            native_references = {},
        }
        resolver.source_names[name] = true
        return true, {}
    end
    function checker.has_main() return false end

    local modules = {
        ["argparse"] = fake_argparse(arguments),
        ["titan-compiler.checker"] = checker,
        ["titan-compiler.coder"] = {
            external_symbols = function() return {} end,
            interface_external_symbols = function() return {} end,
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
    end)

    it("defaults to one generated-C compilation", function()
        local _, observed = run_titanc(ordinary_arguments(nil), nil)
        assert.equal(1, observed.jobs)
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

local assert = require "luassert"
local argparse = require "argparse"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

local EXIT = {}

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

-- The real titanc option grammar over an explicit command line.
local function command_line(argv)
    return function(...)
        local parser = argparse(...)
        local parse = parser.parse
        function parser.parse(self) return parse(self, argv) end
        return parser
    end
end

-- `arguments` is a parsed argument table or a `command_line` parser.
-- `customize` adjusts the fakes before the chunk runs; `expect` is nil for an
-- ordinary diagnostic exit, "success" or "raise".
local function run_titanc(arguments, environment_jobs, customize, expect)
    local inherited_descriptors = { 71, 72 }
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
    local output_request, selected_tools

    function driver.close_resolver_context(context)
        context.closed = true
        return true
    end

    function driver.deduplicate_module_names(names) return names end
    function driver.apply_native_inputs(normalized)
        observed.native_inputs = normalized
    end
    function driver.configure_foreign_c() return true end
    function driver.validate_target() return "native" end
    function driver.default_c_parts() return 4 end
    function driver.prepare_output_root(dir) return dir end
    function driver.cleanup_stale_staging(context, outputs, locks, protection)
        assert.equal(resolver, context)
        assert.equal(observed.output_locks, locks)
        assert.falsy(observed.lock_released)
        local expected = { { path = "pkg.so" } }
        if not platform.windows then expected[2] = { path = "pkg.a" } end
        assert.same(expected, outputs)
        -- Stale staging is retired after preparation resolves the link inputs.
        assert.equal(observed.prepared_outputs, outputs)
        assert.same({ "pkg/one.o", "pkg/three.o", "pkg/two.o" }, protection.link_inputs)
        observed.staging_outputs = outputs
        return true
    end
    function driver.module_compiled_objects(mod)
        return { (mod.filename:gsub("[.]titan$", ".o")) }
    end
    function driver.source_link_inputs() return {} end
    function driver.incremental_configuration()
        return { compiler = "compiler" }
    end
    function driver.toolchain_descriptor() return {} end
    function driver.generated_compile_prefix() return { "cc" } end
    function driver.authored_c_compile_prefix() return { "cc" } end
    function driver.link_extra_flags() return {} end
    function driver.native_link_backend() return "none" end
    function driver.output_tool_descriptors(context, kind)
        assert.equal(resolver, context)
        assert.equal("library", kind)
        local tools = {}
        if not platform.windows then
            tools.ar, tools.ranlib = { driver.AR }, { driver.RANLIB }
        end
        output_request = {
            compiler_argv = { "cc" }, link_flags = {}, toolchain = "toolchain",
            directory = ".", darwin = driver.IS_DARWIN == true,
            windows = platform.windows, tools = tools,
        }
        return output_request
    end
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
            io = {},
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
    function driver.provider_output_path()
        return "pkg.so"
    end
    function driver.validate_provider_output_paths() return true end
    function driver.mangle_module_name(name)
        return name:gsub("[%-.]", "_")
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
            descriptors = function() return inherited_descriptors end,
            release = function()
                assert.is_nil(resolver.io._process_inherit)
                observed.lock_released = true
                return true
            end,
        }
    end
    function build.run(context, request)
        observed.build_jobs = request.jobs
        assert.is_table(request.locks)
        observed.output_locks = request.locks
        if not platform.windows then
            assert.equal(inherited_descriptors, context.io._process_inherit)
        end
        for _, name in ipairs(request.roots) do check_root(name) end
        context.loader = function() end
        return true
    end

    local modules = {
        ["argparse"] = type(arguments) == "function" and arguments or
            fake_argparse(arguments),
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
            output_tools = function(context, request)
                assert.equal(resolver, context)
                assert.equal(output_request, request)
                assert.same({ "cc" }, request.compiler_argv)
                assert.same({ "cc" }, request.compile_argv)
                assert.same({
                    "pkg/one.o", "pkg/three.o", "pkg/two.o",
                }, request.inputs)
                selected_tools = {
                    linker = { argv = { "ld" }, driver_argv = { "cc" },
                        identity = { path = "ld", size = 1, time_precision = "coarse" } },
                }
                for role, argv in pairs(request.tools) do
                    selected_tools[role] = { argv = argv,
                        identity = { path = argv[1], size = 1, time_precision = "coarse" } }
                end
                return selected_tools
            end,
            prepare = function(context, spec)
                assert.equal(resolver, context)
                assert.is_table(selected_tools)
                assert.equal(selected_tools, spec.toolchain.output_tools)
                assert.is_nil(observed.staging_outputs)
                assert.falsy(observed.lock_released)
                observed.prepared_outputs = spec.outputs
                return { directory = "link", synthetic_directory = "syn", native_policy = {} }
            end,
            check = function(context)
                assert.equal(resolver, context)
                assert.is_table(observed.staging_outputs)
                assert.falsy(observed.lock_released)
                return false, "no-record"
            end,
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
        -- This harness models no terminal: progress stays exactly the
        -- historical output, so the orchestration assertions stay exact. The
        -- renderers have their own specs.
        ["titan-compiler.progress"] = {
            NULL = "null", PLAIN = "plain", LIVE = "live",
            select = function() return "null" end,
            locale = function() return nil end,
        },
    }

    local printed = {}
    if customize then
        customize({
            driver = driver, modules = modules, observed = observed,
            checker = checker, build = build,
            resolver = function() return resolver end,
        })
    end
    local saved_modules = {}
    for name in pairs(modules) do
        saved_modules[name] = package.loaded[name]
        package.loaded[name] = modules[name]
    end
    local saved_getenv = platform.getenv
    local saved_exit = os.exit
    local saved_stderr = io.stderr
    local environment = setmetatable({
        print = function(...)
            local values = {}
            for index = 1, select("#", ...) do values[index] = tostring(select(index, ...)) end
            printed[#printed + 1] = table.concat(values, "\t")
        end,
    }, { __index = _G })
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

    local chunk = assert(loadfile("titanc", "t", environment))
    local ok, failure = pcall(chunk)

    io.stderr = saved_stderr
    os.exit = saved_exit
    platform.getenv = saved_getenv
    for name in pairs(modules) do
        package.loaded[name] = saved_modules[name]
    end

    local printed_text = table.concat(printed, "\n")
    if expect == "success" then
        assert.is_true(ok, tostring(failure))
    elseif expect == "raise" then
        assert.is_false(ok)
        assert.not_equal(EXIT, failure)
    else
        assert.is_false(ok)
        assert.equal(EXIT, failure)
    end
    return table.concat(diagnostics), observed, failure, printed_text
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

local function arguments_with(overrides)
    local arguments = ordinary_arguments(nil)
    for key, value in pairs(overrides) do arguments[key] = value end
    return arguments
end

local function stop_at_link_inputs(fakes)
    fakes.modules["titan-compiler.linkcertificate"].output_tools = function(_, request)
        fakes.observed.link_inputs = request.inputs
        fakes.observed.uncacheable = request.uncacheable
        return nil, "stopped at the final-link tool request"
    end
end

local function record_propagation(fakes)
    fakes.modules["titan-compiler.jobs"] = {
        propagate = function(signal)
            fakes.observed.propagated = signal
            fakes.observed.closed_before_propagation = fakes.resolver().closed == true
        end,
    }
end

-- Every module compiles and the provider links and publishes: a DSO/archive
-- pair on POSIX, a staged DLL on Windows.
local function link_through(fakes)
    local driver = fakes.driver
    function driver.compile_modules(requests)
        local results = {}
        for index, request in ipairs(requests) do
            local object = request.modname:gsub("[.]", "/") .. ".o"
            results[index] = { ok = true, libname = object, objects = { object } }
        end
        return results
    end
    function driver.derive_target_fingerprint() return "target" end
    function driver.validate_generated_objects() return true end
    function driver.prepare_static_providers_for_target() return true end
    function driver.classify_native_payloads() return { inputs = {} } end
    function driver.link_provider_pair(request)
        fakes.observed.linked_modules = request.module_names
        return { dso = "stage/pkg.so", archive = "stage/pkg.a", entries = {},
            directory = "stage" }
    end
    function driver.publish_provider_bundle(_, _, provider_output)
        fakes.observed.published = provider_output
        return true
    end
    function driver.remove_path(directory)
        fakes.observed.removed = directory
        return true
    end
    function driver.staged_library_output() return "stage/pkg.dll", "stage" end
    function driver.compile_library_output(_, _, _, _, _, _, _, _, module_names)
        fakes.observed.linked_modules = module_names
        return true
    end
    function driver.validate_library_image_fresh() return true end
    function driver.publish_windows_provider(_, provider_output)
        fakes.observed.published = provider_output
        return true
    end
    function driver.cleanup_staging_directories(directories)
        fakes.observed.removed = directories[1]
        return true
    end
end

-- The Windows program layout: a launcher EXE beside its DLL provider.
local function windows_program_layout(fakes)
    function fakes.driver.windows_program_paths(modname, exe, output_module, output_root)
        fakes.observed.windows_program = { modname = modname, exe = exe,
            output_module = output_module, output_root = output_root }
        local executable = exe or ("bin/" .. modname:gsub(".*[.]", ""))
        if not executable:match("%.exe$") then executable = executable .. ".exe" end
        return { executable = executable, provider = "lib/" .. modname .. ".dll",
            relative_provider = "../lib/" .. modname .. ".dll" }
    end
    function fakes.driver.windows_program_auxiliary_paths(entrypoint, provider)
        fakes.observed.auxiliary = { entrypoint = entrypoint, provider = provider }
        return { (entrypoint:gsub("%.c$", ".res.o")) }
    end
end

describe("titanc command-line orchestration", function()
    it("keeps native switches in exact command-line order across kinds", function()
        local _, observed = run_titanc(command_line({
            "-I", "first include", "-D", "NAME=1", "-l", "m,z", "-L", "lib",
            "--cflag=-O1", "--ldflag=-Wl,--as-needed", "-I", "second",
            "pkg.three", "pkg.two", "pkg.one",
        }), nil, function(fakes)
            local native = fakes.modules["titan-compiler.nativeinputs"]
            local normalize = native.normalize
            function native.normalize(request)
                fakes.observed.native_cli = request.cli.ordered
                return normalize(request)
            end
        end)
        assert.same({
            { kind = "include", value = "first include" },
            { kind = "define", value = "NAME=1" },
            { kind = "library", value = "m,z" },
            { kind = "libdir", value = "lib" },
            { kind = "cflag", value = "-O1" },
            { kind = "ldflag", value = "-Wl,--as-needed" },
            { kind = "include", value = "second" },
        }, observed.native_cli)
    end)

    it("rejects contradictory command-line modes before creating a resolver", function()
        local compile_only_conflict = "--compile-only cannot be combined with -l, -L, " ..
            "--ldflag, -X, or --no-uv-bootstrap"
        for _, case in ipairs({
            { { "--print-c-objects", "app" },
              "--print-c-objects requires --compile-only and at least one --c-source" },
            { { "-c", "--c-source", "native.c", "--print-c-objects", "--print-ast", "app" },
              "--print-c-objects cannot be combined with --print-root or --print-ast" },
            { { "-c", "--exe", "bin/app", "app" }, "--exe cannot be combined with --compile-only" },
            { { "-c", "-L", "lib", "app" }, compile_only_conflict },
            { { "-c", "--ldflag=-pthread", "app" }, compile_only_conflict },
            { { "--test-dir", "tests" }, "--test-dir and --test-exclude require --test" },
            { { "--test-exclude", "app_test", "app" },
              "--test-dir and --test-exclude require --test" },
            { { "--test", "--test-exclude", "app_test", "app" },
              "--test-exclude requires --test-dir" },
        }) do
            local diagnostics, observed = run_titanc(command_line(case[1]))
            assert.equal(case[2] .. "\n", diagnostics)
            assert.same({}, observed)
        end
    end)

    it("rejects a stale native support library before creating a resolver", function()
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            fakes.modules.titan = { _sha256_binary = function() return "" end }
        end)
        assert.equal("the installed Titan native support library is missing or stale " ..
            "(it lacks _sha256_binary or _sha256_stream); reinstall Titan\n", diagnostics)
        assert.same({}, observed)
    end)

    it("roots discovered test modules with the sources discovery selected", function()
        local descriptor = { kind = "flat", main = "tests/alpha_test.titan",
            files = { "tests/alpha_test.titan" } }
        local diagnostics, observed = run_titanc(arguments_with({
            module = { "pkg.one" }, test = true, test_dir = { "tests" },
            test_exclude = { "tests.skipped_test" },
        }), nil, function(fakes)
            fakes.modules["titan-compiler.testroots"] = {
                discover = function(context, dirs, excludes, explicit)
                    fakes.observed.discovery = {
                        own_resolver = context == fakes.resolver(),
                        dirs = dirs, excludes = excludes, explicit = explicit,
                    }
                    return { "pkg.one", "tests.alpha_test" },
                        { ["tests.alpha_test"] = descriptor }
                end,
            }
            function fakes.build.run(_, request)
                fakes.observed.run = request
                return false, { "stopped after root selection" }
            end
        end)
        assert.equal("stopped after root selection\n", diagnostics)
        assert.is_true(observed.discovery.own_resolver)
        assert.same({ "tests" }, observed.discovery.dirs)
        assert.same({ "tests.skipped_test" }, observed.discovery.excludes)
        assert.same({ "pkg.one" }, observed.discovery.explicit)
        assert.same({ "pkg.one", "tests.alpha_test" }, observed.run.roots)
        assert.same({ ["pkg.one"] = true, ["tests.alpha_test"] = true },
            observed.run.loader_options.source_roots)
        assert.equal(descriptor,
            observed.run.loader_options.source_overrides["tests.alpha_test"])
        assert.is_true(observed.run.test)
    end)

    it("stops on failed or reserved test-root discovery", function()
        local function discover(roots, sources)
            return run_titanc(arguments_with({
                module = {}, test = true, test_dir = { "tests" },
            }), nil, function(fakes)
                fakes.modules["titan-compiler.testroots"] = {
                    discover = function() return roots, sources end,
                }
            end)
        end
        local diagnostics, observed = discover(nil, "no test modules found")
        assert.equal("no test modules found\n", diagnostics)
        assert.is_nil(observed.build_jobs)
        diagnostics, observed = discover({ "tests.alpha_test", "__test.runner" }, {})
        assert.equal("logical module '__test.runner' is reserved by --test\n", diagnostics)
        assert.is_nil(observed.build_jobs)
    end)

    it("locks an explicit executable directory and rejects --exe for a library", function()
        local diagnostics, observed = run_titanc(arguments_with({ exe = "bin/app" }))
        assert.equal("--exe is only valid when compiling a standalone or test executable\n",
            diagnostics)
        assert.equal("bin", observed.locked[#observed.locked])
        assert.is_true(observed.lock_released)
        diagnostics, observed = run_titanc(arguments_with({ exe = "bin/app" }), nil,
            function(fakes)
                function fakes.driver.prepare_output_root(directory)
                    return nil, "cannot create output directory '" .. directory .. "'"
                end
            end)
        assert.equal("cannot create output directory 'bin'\n", diagnostics)
        assert.is_nil(observed.locked)
    end)

    it("rejects program-only options for a library build", function()
        local diagnostics = run_titanc(arguments_with({ no_uv_bootstrap = true }))
        assert.equal(
            "--no-uv-bootstrap is only valid when compiling a standalone executable\n",
            diagnostics)
        diagnostics = run_titanc(arguments_with({ coverage = true }), nil, function(fakes)
            fakes.driver.NATIVE_LINK_FLAGS = {}
            fakes.modules["titan-compiler.coverage"] = {
                prepare = function() return { selected = {} } end,
                select = function() return true end,
            }
        end)
        assert.equal("--coverage requires a test or standalone executable; " ..
            "use -c for coverage objects\n", diagnostics)
    end)

    it("rejects two requested roots that both define main", function()
        local diagnostics = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            local run = fakes.build.run
            function fakes.build.run(context, request)
                local built = run(context, request)
                fakes.driver.imported["pkg.three"].has_main = true
                fakes.driver.imported["pkg.one"].has_main = true
                return built
            end
        end)
        assert.equal("pkg.one: multiple main functions found " ..
            "(already declared in pkg.three)\n", diagnostics)
    end)

    it("closes the coordinator before propagating a build cancellation signal", function()
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            record_propagation(fakes)
            function fakes.build.run() return false, { "build cancelled" }, 2 end
        end)
        assert.equal(2, observed.propagated)
        assert.is_true(observed.closed_before_propagation)
        assert.equal("build cancelled\n", diagnostics)
        assert.is_true(observed.lock_released)
    end)

    it("reports native node reuse and links C-source objects before -X payloads", function()
        local diagnostics, observed = run_titanc(arguments_with({
            verbose = true, c_source = { "fresh.c", "cached.c" },
            extra_object = { "payload.a" },
        }), nil, function(fakes)
            local native = fakes.modules["titan-compiler.nativeinputs"]
            local normalize = native.normalize
            function native.normalize(request)
                local normalized = normalize(request)
                normalized.c_sources = request.cli.c_sources
                return normalized
            end
            function native.compile(_, request)
                fakes.observed.native_sources = request.sources
                return {
                    { source = "fresh.c", path = "out/fresh.o", hit = false },
                    { source = "cached.c", path = "out/cached.o", hit = true },
                }
            end
            stop_at_link_inputs(fakes)
        end)
        assert.equal("Titan native miss fresh.c\nTitan native hit cached.c\n" ..
            "stopped at the final-link tool request\n", diagnostics)
        assert.same({ "fresh.c", "cached.c" }, observed.native_sources)
        assert.same({ "pkg/one.o", "pkg/three.o", "pkg/two.o",
            "out/fresh.o", "out/cached.o", "payload.a" }, observed.link_inputs)
    end)

    it("rejects library roots without a common provider prefix", function()
        local diagnostics = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            function fakes.driver.common_module_provider() return nil, nil, "pkg.one", "other" end
        end)
        assert.equal("cannot link modules into one shared library: 'pkg.one' and " ..
            "'other' have no common module prefix\n", diagnostics)
    end)

    it("links carried static-provider archives into the library", function()
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            local new_context = fakes.driver.new_resolver_context
            function fakes.driver.new_resolver_context(options)
                local context = new_context(options)
                context.selected_static_providers = { {
                    archive = "deps/libpkg_dep.a",
                    entries = { ["pkg.dep"] = {}, ["pkg.carried"] = {} },
                } }
                return context
            end
            stop_at_link_inputs(fakes)
        end)
        assert.equal("stopped at the final-link tool request\n", diagnostics)
        assert.same({ "pkg/one.o", "pkg/three.o", "pkg/two.o", "deps/libpkg_dep.a" },
            observed.link_inputs)
    end)

    it("keeps uncertified native policy explicit in the final-link tool request", function()
        local diagnostics = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            function fakes.driver.incremental_configuration()
                return nil, "compiler configuration is unreadable"
            end
        end)
        assert.equal("compiler configuration is unreadable\n", diagnostics)

        local function uncertain(configure)
            local _, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
                configure(fakes.driver)
                fakes.modules["titan-compiler.incremental"].compiler_component = function()
                    fakes.observed.compiler_component = true
                    return "compiler inventory"
                end
                stop_at_link_inputs(fakes)
            end)
            return observed
        end
        local observed = uncertain(function(driver)
            function driver.incremental_configuration()
                return nil, "native delegate selection is unknown", "uncertified"
            end
        end)
        assert.equal("native delegate selection is unknown", observed.uncacheable)
        assert.is_true(observed.compiler_component)
        observed = uncertain(function(driver)
            function driver.native_link_backend()
                return "none", "linker selection is unknown", "uncertified"
            end
        end)
        assert.equal("linker selection is unknown", observed.uncacheable)
        assert.is_nil(observed.compiler_component)
    end)

    it("links a standalone program at its logical path unless --exe names one", function()
        local function program(overrides)
            local _, observed = run_titanc(arguments_with(overrides), nil, function(fakes)
                local run = fakes.build.run
                function fakes.build.run(context, request)
                    local built = run(context, request)
                    fakes.driver.imported["app.main"].has_main = true
                    return built
                end
                windows_program_layout(fakes)
                function fakes.driver.output_tool_descriptors(_, kind)
                    fakes.observed.kind = kind
                    return { compiler_argv = { "cc" }, link_flags = {},
                        toolchain = "toolchain", tools = {} }
                end
                local certificate = fakes.modules["titan-compiler.linkcertificate"]
                certificate.output_tools = function() return {} end
                certificate.prepare = function(_, spec)
                    fakes.observed.outputs = spec.outputs
                    fakes.observed.entry = spec.entry
                    fakes.observed.companions = spec.companions
                    error("stopped at final-link preparation", 0)
                end
            end)
            return observed
        end
        local observed = program({ module = { "app.main" } })
        assert.equal("program", observed.kind)
        if platform.windows then
            assert.same({ modname = "app.main" }, observed.windows_program)
            assert.same({ { path = "bin/main.exe" }, { path = "lib/app.main.dll" } },
                observed.outputs)
            assert.equal("../lib/app.main.dll", observed.companions.relative_provider)
        else
            assert.same({ { path = "app/main", executable = true } }, observed.outputs)
        end
        assert.same({ module = "app.main", no_uv_bootstrap = false }, observed.entry)
        observed = program({ module = { "app.main" }, exe = "bin/app" })
        if platform.windows then
            assert.same({ modname = "app.main", exe = "bin/app" }, observed.windows_program)
            assert.same({ { path = "bin/app.exe" }, { path = "lib/app.main.dll" } },
                observed.outputs)
        else
            assert.same({ { path = "bin/app", executable = true } }, observed.outputs)
        end
    end)

    it("reports a failed final-link preparation and preserves its cancellation", function()
        local diagnostics = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            fakes.modules["titan-compiler.linkcertificate"].prepare = function()
                error("cannot certify link input pkg/one.o", 0)
            end
        end)
        assert.equal("cannot certify link input pkg/one.o\n", diagnostics)
        local cancellation = {}
        local _, observed, failure = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            fakes.modules["titan-compiler.linkcertificate"].prepare = function()
                error(cancellation, 0)
            end
        end, "raise")
        assert.equal(cancellation, failure)
        assert.is_true(observed.lock_released)
    end)

    it("reports final-link hits and misses and stops before an unrecorded relink", function()
        local diagnostics, observed = run_titanc(arguments_with({ verbose = true }), nil,
            function(fakes)
                fakes.modules["titan-compiler.linkcertificate"].check = function() return true end
                function fakes.driver.compile_modules()
                    error("a final-link hit must not compile", 0)
                end
            end, "success")
        assert.equal("Titan link hit pkg.so\n", diagnostics)
        assert.is_true(observed.digest_cache_saved)
        assert.is_true(observed.lock_released)

        diagnostics = run_titanc(arguments_with({ verbose = true }), nil, function(fakes)
            fakes.modules["titan-compiler.linkcertificate"].invalidate = function()
                return nil, "record is read-only"
            end
        end)
        assert.equal("Titan link miss pkg.so: no-record\n" ..
            "cannot invalidate final link record: record is read-only\n", diagnostics)
    end)

    it("prints checked ASTs, including roots that only warn, and stops on errors", function()
        local diagnostics, _, _, printed = run_titanc(arguments_with({
            module = { "app", "lib" }, print_ast = true,
        }), nil, function(fakes)
            function fakes.build.plan() return { order = {}, modules = {} } end
            fakes.modules["titan-compiler.parser"].pretty_print_ast = function(ast)
                return "AST " .. ast.name
            end
            function fakes.checker.checkimport(name)
                if name == "app" then return false, "app.titan:1:1: syntax error" end
                fakes.driver.imported[name] = { ast = { name = name } }
                return true, { "lib.titan:2:1: unused import" }
            end
        end)
        assert.equal("app.titan:1:1: syntax error\nlib.titan:2:1: unused import\n", diagnostics)
        assert.equal("AST lib", printed)
    end)

    it("plans a printed program's entrypoint beside its generated output", function()
        local diagnostics, observed, _, printed = run_titanc(arguments_with({
            module = { "app" }, print_ast = true,
        }), nil, function(fakes)
            function fakes.build.plan(_, request)
                fakes.observed.planned_roots = request.roots
                return { order = { "app" }, modules = {} }
            end
            function fakes.driver.preflight_build_outputs(_, plan, options)
                fakes.observed.preflight = { plan = plan, roots = options.roots }
                return true
            end
            fakes.modules["titan-compiler.parser"].pretty_print_ast = function(ast)
                return "AST " .. ast.name
            end
            local check = fakes.checker.checkimport
            function fakes.checker.checkimport(name, loader)
                local ok, errors = check(name, loader)
                fakes.driver.imported[name].ast = { name = name }
                return ok, errors
            end
            function fakes.checker.has_main(ast) return ast.name == "app" end
            windows_program_layout(fakes)
            function fakes.driver.generated_output_path(stem, output)
                assert.is_nil(output)
                return "generated/" .. stem
            end
            function fakes.driver.validate_program_output_paths(_, program, entrypoint, _,
                    extra_outputs)
                fakes.observed.program = program
                fakes.observed.entrypoint = entrypoint
                fakes.observed.extra_outputs = extra_outputs
                return nil, "stopped at program output validation"
            end
        end)
        assert.equal("stopped at program output validation\n", diagnostics)
        assert.equal("AST app", printed)
        assert.same({ "app" }, observed.planned_roots)
        assert.same({ "app" }, observed.preflight.roots)
        assert.same({ "app" }, observed.preflight.plan.order)
        if platform.windows then
            assert.same({ modname = "app" }, observed.windows_program)
            assert.equal("bin/app.exe", observed.program)
            assert.same({ entrypoint = "generated/app__entrypoint.c", provider = "lib/app.dll" },
                observed.auxiliary)
            assert.same({ "generated/app__entrypoint.res.o" }, observed.extra_outputs)
        else
            assert.equal("app", observed.program)
        end
        assert.equal("generated/app__entrypoint.c", observed.entrypoint)
    end)

    it("records a completed provider link and reports a failed final record", function()
        local committed
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            link_through(fakes)
            fakes.modules["titan-compiler.linkcertificate"].commit = function(_, ticket)
                committed = ticket
                return true
            end
        end, "success")
        assert.equal("", diagnostics)
        assert.equal("pkg.so", observed.published)
        assert.equal("stage", observed.removed)
        assert.same({ "pkg.one", "pkg.three", "pkg.two" }, observed.linked_modules)
        assert.equal("link", committed.directory)
        assert.is_true(observed.lock_released)

        for _, case in ipairs({
            { function() error("link record write failed", 0) end, "link record write failed\n" },
            { function() return nil, "disk full" end, "cannot record final link: disk full\n" },
        }) do
            diagnostics = run_titanc(ordinary_arguments(nil), nil, function(fakes)
                link_through(fakes)
                fakes.modules["titan-compiler.linkcertificate"].commit = case[1]
            end)
            assert.equal(case[2], diagnostics)
        end
        local cancellation = {}
        local _, _, failure = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            link_through(fakes)
            fakes.modules["titan-compiler.linkcertificate"].commit = function()
                error(cancellation, 0)
            end
        end, "raise")
        assert.equal(cancellation, failure)
    end)

    it("stops an interrupted provider link before publishing it", function()
        local diagnostics, observed = run_titanc(ordinary_arguments(nil), nil, function(fakes)
            link_through(fakes)
            function fakes.driver.link_provider_pair() return nil, "provider link interrupted", 15 end
            function fakes.driver.compile_library_output() return nil, "interrupted", 15 end
            function fakes.driver.link_failure_message(kind, name, term, code)
                return kind .. " '" .. name .. "' link failed: " .. tostring(term) ..
                    " " .. tostring(code)
            end
            record_propagation(fakes)
        end)
        if platform.windows then
            -- A DLL link reports its failure without a cancellation signal and
            -- retires its staging directory.
            assert.equal("library 'pkg' link failed: interrupted 15\n", diagnostics)
            assert.is_nil(observed.propagated)
            assert.equal("stage", observed.removed)
        else
            -- The coordinator is closed before the POSIX pair link's signal
            -- is propagated.
            assert.equal(15, observed.propagated)
            assert.is_true(observed.closed_before_propagation)
            assert.equal("provider link interrupted\n", diagnostics)
        end
        assert.is_nil(observed.published)
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
            TITAN_ROOT = prefix, TITAN_RUNTIME_PREBUILT = "1",
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

describe("titanc target vocabulary", function()
    local fixtures = require "spec.fixtures.target_selection.support"
    local fixture
    before_each(function()
        fixture = fixtures.new()
        fixtures.write(fixture.source .. "/target_cli.titan",
            "function answer(): integer return 42 end\n")
    end)
    after_each(function() fixture:close() end)

    it("accepts the host, empty values and both flag spellings with flag precedence", function()
        for _, case in ipairs({
            { {}, "" }, { {}, fixture.host ~= "native" and fixture.host or "" },
            { { "--target", "" }, "bogus" },
            { { "-T", "" }, "bogus" },
        }) do
            local args = { "-q", "--print-ast", "target_cli" }
            for _, value in ipairs(case[1]) do args[#args + 1] = value end
            local result = fixture:compile(args, { TITAN_TARGET = case[2] })
            assert.is_true(result.ok, result.output)
        end
        if fixture.host ~= "native" then
            for _, flags in ipairs({ { "-T", fixture.host },
                    { "--target=" .. fixture.host } }) do
                local args = { "-q", "--print-ast", "target_cli" }
                for _, value in ipairs(flags) do args[#args + 1] = value end
                local result = fixture:compile(args, { TITAN_TARGET = "browser" })
                assert.is_true(result.ok, result.output)
            end
        end
    end)

    it("validates every explicit value before Titan or C-source lookup", function()
        for _, value in ipairs({ "linux", "darwin", "windows", "native", "browser", "wasm32" }) do
            if value ~= fixture.host or value == "native" then
                for _, environment in ipairs({ false, true }) do
                    for _, c_only in ipairs({ false, true }) do
                        local args = { "-q", "-c" }
                        if c_only then
                            args[#args + 1] = "--c-source"
                            args[#args + 1] = fixture.source .. "/missing.c"
                        else args[#args + 1] = "missing_module" end
                        if not environment then
                            args[#args + 1] = "--target"; args[#args + 1] = value
                        end
                        local result = fixture:compile(args,
                            { TITAN_TARGET = environment and value or "" })
                        assert.is_false(result.ok)
                        assert.matches(environment and "TITAN_TARGET=" .. value or
                            "--target " .. value, result.output, 1, true)
                        local reason = value == "native" and "not a compilation target" or
                            value == "browser" and "not available yet" or
                            value == "wasm32" and "unknown target" or
                            "native cross-compilation is not supported"
                        assert.matches(reason, result.output, 1, true)
                        assert.is_nil(result.output:find("not found", 1, true))
                    end
                end
            end
        end
        local result = fixture:compile({ "-q", "--target", "bogus" })
        assert.is_false(result.ok)
        assert.matches("unknown target", result.output, 1, true)
        result = fixture:compile({ "-q", "--target", "" })
        assert.is_false(result.ok)
        assert.matches("at least one module name is required", result.output, 1, true)
    end)

    it("ignores target configuration for the runtime SDK-root query", function()
        local result = fixture:compile({ "--print-root" }, { TITAN_TARGET = "bogus" })
        assert.is_true(result.ok, result.output)
        assert.matches(fixture.prefix, result.output, 1, true)
        result = fixture:compile({ "--print-root", "--target", "bogus" },
            { TITAN_TARGET = "browser" })
        assert.is_true(result.ok, result.output)
        assert.matches(fixture.prefix, result.output, 1, true)
    end)
end)

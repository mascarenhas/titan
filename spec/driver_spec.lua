local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local coder = require "titan-compiler.coder"
local sourceinterface = require "titan-compiler.sourceinterface"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local titan = require "titan"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("compiler installation discovery", function()
    it("exports the language-server compiler API independently of the ABI",
       function()
        assert.equal("2", driver.TITAN_ABI_VERSION)
        assert.equal("0.6.0", driver.TITAN_VERSION)
        assert.equal("0.6", driver.TITAN_LIBRARY_VERSION)
        assert.equal("_0_6", driver.TITAN_LIBRARY_VERSION_SUFFIX)
        assert.equal(3, driver.LANGUAGE_SERVER_API_VERSION)
        assert.is_function(driver.serialize_source_interface)
        assert.is_function(driver.restat_c_header_dependencies)
    end)

    it("validates and stores one resolver-owned I/O strategy", function()
        local strategy = compiler_io.new_sync()
        local context = driver.new_resolver_context({ io = strategy })
        assert.equal(strategy, context.io)
        assert.same({}, context.checked_source_modules)

        local ordinary = driver.new_resolver_context()
        assert.is_table(ordinary.io)
        assert.not_equal(strategy, ordinary.io)
        assert.equal(ordinary.io, compiler_io.validate(ordinary.io))

        assert.has_error(function()
            driver.new_resolver_context({ io = {} })
        end, "compiler I/O strategy method 'cwd' must be callable")
    end)

    it("releases sibling tmpname reservations with cancellation ownership",
    function()
        local calls = {}
        local strategy = {
            tmpname = function()
                calls[#calls + 1] = { operation = "tmpname" }
                return "/tmp/titan-owned-reservation"
            end,
            unlink = function(_, path, remove_if_cancelled)
                calls[#calls + 1] = {
                    operation = "unlink",
                    path = path,
                    remove_if_cancelled = remove_if_cancelled,
                }
                return true
            end,
        }

        assert.equal("/project/module.c.tmp.titan-owned-reservation",
            driver.sibling_temporary_path("/project/module.c", strategy))
        assert.same({
            { operation = "tmpname" },
            {
                operation = "unlink",
                path = "/tmp/titan-owned-reservation",
                remove_if_cancelled = true,
            },
        }, calls)
    end)

    it("propagates cancellation while releasing a sibling reservation",
    function()
        local cancellation = { kind = "simulated cancellation" }
        local strategy = {
            tmpname = function()
                return "/tmp/titan-cancelled-reservation"
            end,
            unlink = function(_, path, remove_if_cancelled)
                assert.equal("/tmp/titan-cancelled-reservation", path)
                assert.is_true(remove_if_cancelled)
                error(cancellation)
            end,
        }

        local completed, reason = pcall(
            driver.sibling_temporary_path, "/project/module.c", strategy)
        assert.is_false(completed)
        assert.equal(cancellation, reason)
    end)

    it("initializes uname lazily through the resolver strategy", function()
        local strategy = compiler_io.new_sync()
        local commands = {}
        function strategy:run(argv, options)
            commands[#commands + 1] = {
                argv = argv,
                options = options,
            }
            return {
                started = true,
                ok = true,
                output = "TestOS\n",
            }
        end
        local context = driver.new_resolver_context({ io = strategy })
        assert.same({}, commands)

        local previous_uname = driver.UNAME
        local previous_is_darwin = driver.IS_DARWIN
        local ran, failure = pcall(function()
            local initialized, uname, is_darwin =
                driver.initialize_platform(context)
            assert.is_true(initialized)
            assert.equal("TestOS", uname)
            assert.is_false(is_darwin)
            assert.equal("TestOS", driver.UNAME)
            assert.is_false(driver.IS_DARWIN)
            assert.same({ "uname" }, commands[1].argv)
            assert.is_true(commands[1].options.stderr_to_stdout)

            assert.is_true(driver.initialize_platform(context))
            assert.equal(1, #commands)
        end)
        driver.UNAME = previous_uname
        driver.IS_DARWIN = previous_is_darwin
        assert.truthy(ran, failure)
    end)

    it("initializes native publication flags through a resolver strategy",
    function()
        local strategy = compiler_io.new_sync()
        local commands = {}
        function strategy:run(argv, options)
            commands[#commands + 1] = {
                argv = argv,
                options = options,
            }
            return {
                started = true,
                ok = true,
                output = "Darwin\n",
            }
        end
        local context = driver.new_resolver_context({ io = strategy })
        local previous_uname = driver.UNAME
        local previous_is_darwin = driver.IS_DARWIN
        driver.UNAME = nil
        driver.IS_DARWIN = nil

        local ran, failure = pcall(function()
            assert.same({ "-shared", "-undefined", "dynamic_lookup" },
                driver.shared_library_flags(context))
            assert.same({ "uname" }, commands[1].argv)
            assert.is_true(commands[1].options.stderr_to_stdout)
            assert.equal("Darwin", driver.UNAME)
            assert.is_true(driver.IS_DARWIN)
        end)

        driver.UNAME = previous_uname
        driver.IS_DARWIN = previous_is_darwin
        assert.truthy(ran, failure)
    end)

    it("surfaces resolver strategy failures at public driver boundaries",
    function()
        local failed, reason = driver.source_checkout_from_driver_source(
            "@titan-compiler/driver.lua", nil, {
                cwd = function() return nil, "injected cwd failure" end,
            })
        assert.is_false(failed)
        assert.equal("injected cwd failure", reason)

        assert.has_error(function() driver.initialize_layout({}) end,
            "compiler layout initialization requires a resolver context")
        assert.has_error(function() driver.initialize_platform({}) end,
            "platform initialization requires a resolver context")
        assert.has_error(function() driver.configure_foreign_c({}) end,
            "foreign C configuration requires a resolver context")
        assert.has_error(function() driver.new_resolver_context("invalid") end,
            "resolver context options must be a table")
        assert.has_error(function()
            driver.new_resolver_context({
                extra_ffi_include_dirs = "invalid",
            })
        end, "invalid extra_ffi_include_dirs: compiler include dirs must be " ..
            "an ordered array")

        local previous_support = driver.TEST_SUPPORT_SOURCE_PATH
        driver.TEST_SUPPORT_SOURCE_PATH = "/virtual/titan/test.titan"
        local descriptor
        local completed, failure = pcall(function()
            descriptor = assert(driver.test_support_source_descriptor({
                io = {
                    stat = function(_, filename)
                        assert.equal("/virtual/titan/test.titan", filename)
                        return { kind = "file" }
                    end,
                },
            }))
        end)
        driver.TEST_SUPPORT_SOURCE_PATH = previous_support
        assert.truthy(completed, failure)
        assert.equal("/virtual/titan/test.titan", descriptor.main)

        local failed_platform = driver.new_resolver_context()
        function failed_platform.io:run(argv, options)
            assert.same({ "uname" }, argv)
            assert.is_true(options.stderr_to_stdout)
            return {
                started = false,
                ok = false,
                diagnostic = "injected uname failure",
            }
        end
        local ok, err = driver.initialize_platform(failed_platform)
        assert.is_nil(ok)
        assert.equal("cannot determine the native platform with uname: " ..
            "injected uname failure", err)

        local empty_platform = driver.new_resolver_context()
        function empty_platform.io:run()
            return { started = true, ok = true, output = "  \n" }
        end
        ok, err = driver.initialize_platform(empty_platform)
        assert.is_nil(ok)
        assert.equal("cannot determine the native platform with uname: " ..
            "command produced no output", err)

        local original_configure = driver.configure_foreign_c
        local probe_context = driver.new_resolver_context()
        probe_context.foreign_c_configuration_id =
            driver.FOREIGN_C_CONFIGURATION_ID - 1
        driver.configure_foreign_c = function(context)
            assert.equal(probe_context, context)
            return nil, "injected configuration failure"
        end
        local called
        called, ok, err = pcall(driver.get_probe_service, probe_context)
        driver.configure_foreign_c = original_configure
        assert.truthy(called, ok)
        assert.is_nil(ok)
        assert.equal("injected configuration failure", err)
        assert.equal(err, probe_context.probe_service_error)

        assert.is_true(driver.close_resolver_context(failed_platform))
        assert.is_true(driver.close_resolver_context(empty_platform))
        assert.is_true(driver.close_resolver_context(probe_context))
    end)

    it("distinguishes realpath, stat, and provider inspection failures",
    function()
        local context = driver.new_resolver_context()
        local strategy = context.io
        function strategy:realpath(path)
            assert.equal("/virtual/link/../root", path)
            return nil, "injected realpath failure"
        end
        function strategy:stat(path)
            assert.equal("/virtual/link/../root", path)
            return nil, "injected stat failure"
        end

        local found, err = driver.find_dynamic_interface(
            "/virtual/link/../root", "probe", context)
        assert.is_nil(found)
        assert.equal("injected stat failure", err)

        function strategy:stat()
            return { kind = "directory" }
        end
        found, err = driver.find_dynamic_interface(
            "/virtual/link/../root", "probe", context)
        assert.is_nil(found)
        assert.equal("injected realpath failure", err)

        function strategy:stat() return nil end
        function strategy:lstat(path)
            assert.equal("/virtual/root/probe.so", path)
            return nil
        end
        found, err = driver.find_dynamic_interface(
            "/virtual/link/../root", "probe", context)
        assert.is_nil(found)
        assert.is_nil(err)

        function strategy:lstat()
            return nil, "injected lstat failure"
        end
        found, err = driver.find_dynamic_interface(
            "/virtual/root", "probe", context)
        assert.is_nil(found)
        assert.matches("cannot inspect compiled provider candidate", err,
            1, true)
        assert.matches("injected lstat failure", err, 1, true)

        found, err = driver.find_static_interface(
            "/virtual/root", "probe", context)
        assert.is_nil(found)
        assert.matches("cannot inspect static provider candidate", err,
            1, true)
        assert.matches("injected lstat failure", err, 1, true)

        function strategy:lstat() return { kind = "file" } end
        function strategy:stat()
            return nil, "injected followed-stat failure"
        end
        found, err = driver.find_static_interface(
            "/virtual/root", "probe", context)
        assert.is_nil(found)
        assert.matches("injected followed-stat failure", err, 1, true)

        assert.is_nil(driver.find_compiled_interface(
            "/definitely/missing/titan-provider-root", "probe"))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("loads the driver without touching the filesystem or spawning uname",
       function()
        local module_name = "titan-compiler.driver"
        local loaded_driver = package.loaded[module_name]
        local originals = {
            currentdir = lfs.currentdir,
            attributes = lfs.attributes,
            symlinkattributes = lfs.symlinkattributes,
            chdir = lfs.chdir,
            popen = io.popen,
        }
        local function forbidden(name)
            return function()
                error("module-load " .. name .. " escape")
            end
        end
        package.loaded[module_name] = nil
        lfs.currentdir = forbidden("cwd")
        lfs.attributes = forbidden("stat")
        lfs.symlinkattributes = forbidden("lstat")
        lfs.chdir = forbidden("realpath")
        io.popen = forbidden("subprocess")

        local loaded, value = pcall(require, module_name)

        lfs.currentdir = originals.currentdir
        lfs.attributes = originals.attributes
        lfs.symlinkattributes = originals.symlinkattributes
        lfs.chdir = originals.chdir
        io.popen = originals.popen
        package.loaded[module_name] = loaded_driver

        assert.truthy(loaded, value)
        assert.is_table(value)
        assert.is_nil(value.UNAME)
        assert.is_nil(value.IS_DARWIN)
    end)

    it("uses the first literal Lua 5.5 C-module prefix", function()
        local cpath = table.concat({
            "/first prefix/lib/titan/0.6/?.so",
            "/wrong/lib/lua/5.4/?.so",
            "/also-wrong/lib/lua/5.5/?.dylib",
            "/first prefix/lib/lua/5.5/?.so",
            "/second/lib/lua/5.5/?.so",
        }, ";")
        assert.equal("/first prefix",
            driver.root_from_package_cpath(cpath))
    end)

    it("rejects suffix lookalikes and handles the filesystem root", function()
        assert.is_nil(driver.root_from_package_cpath(table.concat({
            "/prefix/lib/lua/5.5/?x.so",
            "/prefix/lib/lua/5.5/?.so.debug",
            "/prefix/lib/lua/5.5/sub/?.so",
        }, ";")))
        assert.equal("/", driver.root_from_package_cpath(
            "/lib/lua/5.5/?.so;/later/lib/lua/5.5/?.so"))
        assert.is_nil(driver.root_from_package_cpath(nil))
    end)

    it("gives the internal installation override precedence", function()
        assert.equal("/post-install/tree", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", "/post-install/tree/"))
        assert.equal("/lua/prefix", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", ""))
        assert.equal(lfs.currentdir() .. "/normalized",
            driver.resolve_installation_root(
                nil, "./discarded/../normalized//"))
    end)

    it("derives the ABI-owned probe cache from an explicit prefix first",
       function()
        local cpath = "/installed/lib/lua/5.5/?.so"
        assert.equal("/explicit/var/cache/titan-probes/2",
            driver.probe_cache_directory(cpath, "/explicit", "2"))
        assert.equal("/installed/var/cache/titan-probes/2",
            driver.probe_cache_directory(cpath, "", "2"))
        assert.equal("/var/cache/titan-probes/2",
            driver.probe_cache_directory(
                "/lib/lua/5.5/?.so", nil, "2"))
        assert.is_nil(driver.probe_cache_directory(nil, nil, "2"))
    end)

    it("honors the test-only persistent-probe-cache disable switch",
       function()
        local lua = os.getenv("PREFIX") and os.getenv("PREFIX") .. "/bin/lua"
            or "lua"
        local script = [[
local driver = require "titan-compiler.driver"
assert(driver.PROBE_CACHE_DIRECTORY == nil)
]]
        local command = "TITAN_PROBE_CACHE_DISABLE=1 " ..
            assert(driver.shell_quote(lua)) .. " -e " ..
            assert(driver.shell_quote(script))
        assert.is_true(os.execute(command))
    end)

    it("preserves ordinary root spelling but resolves symlink parent traversal",
       function()
        local workspace = os.tmpname()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local physical = workspace .. "/physical"
        local nested = physical .. "/nested"
        assert(lfs.mkdir(physical))
        assert(lfs.mkdir(nested))
        local alias = workspace .. "/alias"
        local command = table.concat({
            "ln", "-s",
            assert(driver.shell_quote(nested)),
            assert(driver.shell_quote(alias)),
        }, " ")
        assert(os.execute(command))

        assert.equal(alias, driver.resolve_installation_root(nil, alias))

        local previous = lfs.currentdir()
        assert(lfs.chdir(physical))
        local expected_parent = lfs.currentdir()
        assert(lfs.chdir(previous))
        assert.equal(expected_parent,
            driver.resolve_installation_root(nil, alias .. "/.."))

        assert(os.remove(alias))
        remove_tree(workspace)
    end)

    it("derives all installed compiler paths from one root", function()
        local paths = assert(driver.installed_paths("/opt/titan/"))
        assert.same({
            root = "/opt/titan",
            lua_source = "/opt/titan/src/lua-5.5.1",
            include = "/opt/titan/include",
            lib = "/opt/titan/lib",
            libtitan = "/opt/titan/lib/titan/0.6/libtitan.a",
            libbacktrace = "/opt/titan/lib/libbacktrace.a",
            liblua = "/opt/titan/lib/liblua.a",
            titan_bin = "/opt/titan/lib/titan/0.6",
            lua_cpath = "/opt/titan/lib/titan/0.6/?.so",
            test_source =
                "/opt/titan/share/titan/0.6/src/titan/test.titan",
        }, paths)

        assert.same({
            "/opt/titan/lib/titan/0.6/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-ldl", "-lm",
        }, driver.installed_link_inputs(paths, false))
        assert.same({
            "/opt/titan/lib/titan/0.6/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-lm",
        }, driver.installed_link_inputs(paths, true))
    end)

    it("keeps canonical test-support outputs under the logical source path",
       function()
        local source = assert(driver.test_support_source_descriptor())
        assert.equal("titan/test", source.program_output)
    end)

    it("reports a missing canonical test support source", function()
        local previous = driver.TEST_SUPPORT_SOURCE_PATH
        driver.TEST_SUPPORT_SOURCE_PATH = "/nonexistent/titan/test.titan"
        local source, message = driver.test_support_source_descriptor()
        driver.TEST_SUPPORT_SOURCE_PATH = previous
        assert.is_nil(source)
        assert.match("Titan test support source is missing", message,
            1, true)
        assert.match("/nonexistent/titan/test.titan", message, 1, true)
    end)

    it("identifies a checkout from driver provenance, not the working directory",
       function()
        local checkout = lfs.currentdir()
        assert.is_true(driver.source_checkout_from_driver_source(
            "@" .. checkout .. "/titan-compiler/driver.lua", "/tmp"))
        assert.is_true(driver.source_checkout_from_driver_source(
            "@./titan-compiler/driver.lua", checkout))
        assert.is_false(driver.source_checkout_from_driver_source(
            "@/opt/titan/share/lua/5.5/titan-compiler/driver.lua",
            checkout))
    end)

    it("requires exactly the two runtime archive members", function()
        assert.is_true(driver.runtime_archive_members_are_exact(
            "titan.o\nminicoro.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF SORTED\ntitan.o\nminicoro.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF_64\ntitan.o\nminicoro.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan.o\nminicoro.o\ntitan_uv.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "__.SYMDEF\ntitan.o\nminicoro.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "minicoro.o\ntitan.o\n"))
    end)

    it("links source builds through the complete runtime archive", function()
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.1/src/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("lua-5.5.1/src"))
    end)

    it("shares the exact generated-object prefix with profiles and probes",
    function()
        local descriptor = assert(driver.toolchain_descriptor())
        local reconstructed = {}
        for _, argument in ipairs(descriptor.compiler_argv) do
            reconstructed[#reconstructed + 1] = argument
        end
        for _, argument in ipairs(descriptor.compile_flags) do
            reconstructed[#reconstructed + 1] = argument
        end
        for _, directory in ipairs(descriptor.include_dirs) do
            reconstructed[#reconstructed + 1] = "-I"
            reconstructed[#reconstructed + 1] = directory
        end

        assert.same(assert(driver.generated_compile_prefix()),
            reconstructed)
        assert.same(driver.foreign_include_dirs(),
            descriptor.include_dirs)
        if not driver.INSTALLED then
            assert.same({
                driver.TITAN_RUNTIME_PATH,
                driver.LUA_SOURCE_PATH,
                driver.LIBBACKTRACE_PATH,
            }, descriptor.include_dirs)
        end
    end)

    it("rescans selected ELF payload after the Titan runtime", function()
        assert.same({
            "-Wl,--start-group",
            "/providers/one.a", "/providers/two.a",
            "-Wl,--end-group",
            "/payload/first.o", "/payload/second.a",
            "-Wl,--start-group",
            "/sdk/libtitan.a",
            "/providers/one.a", "/providers/two.a",
            "-Wl,--end-group",
            "/sdk/libbacktrace.a", "/sdk/liblua.a", "-ldl", "-lm",
        }, driver.standalone_native_link_inputs(
            { "/providers/one.a", "/providers/two.a" },
            { "/payload/first.o", "/payload/second.a" },
            {
                "/sdk/libtitan.a",
                "/sdk/libbacktrace.a",
                "/sdk/liblua.a",
                "-ldl", "-lm",
            },
            false))
    end)

    it("retains continual Darwin standalone archive order", function()
        assert.same({
            "/providers/one.a",
            "/payload/first.o", "/payload/second.a",
            "/sdk/libtitan.a", "/sdk/libbacktrace.a",
            "/sdk/liblua.a", "-lm",
        }, driver.standalone_native_link_inputs(
            { "/providers/one.a" },
            { "/payload/first.o", "/payload/second.a" },
            {
                "/sdk/libtitan.a",
                "/sdk/libbacktrace.a",
                "/sdk/liblua.a",
                "-lm",
            },
            true))
    end)
end)

describe("compiled-container path contracts", function()
    it("deduplicates roots and derives a component-wise provider", function()
        local provider, roots = driver.common_module_provider({
            "foo.bar.left", "foo.bar.left", "foo.bar.right",
        })
        assert.equal("foo.bar", provider)
        assert.same({ "foo.bar.left", "foo.bar.right" }, roots)

        assert.equal("foo", driver.common_module_provider({
            "foo", "foo.bar",
        }))

        local reserved_provider, reserved_roots =
            driver.common_module_provider({
                "pkg.titan.left", "pkg.titan.right",
            })
        assert.equal("pkg.titan", reserved_provider)
        local plans, provider_path = driver.plan_module_shims(
            reserved_provider, reserved_roots)
        assert.truthy(plans)
        assert.equal("pkg/titan.so", provider_path)
        assert.same({ "pkg/titan/left.lua", "pkg/titan/right.lua" }, {
            plans[1].filename, plans[2].filename,
        })

        local none, _, left, right = driver.common_module_provider({
            "foo.bar", "foobar.baz",
        })
        assert.is_nil(none)
        assert.equal("foo.bar", left)
        assert.equal("foobar.baz", right)
    end)

    it("derives one shallow-to-exact candidate per component", function()
        local cases = {
            { "a", { "a.so" } },
            { "a.b", { "a.so", "a/b.so" } },
            { "a.b.c", { "a.so", "a/b.so", "a/b/c.so" } },
            {
                "a.b.c.d",
                { "a.so", "a/b.so", "a/b/c.so", "a/b/c/d.so" },
            },
        }
        for _, case in ipairs(cases) do
            assert.same(case[2], driver.module_binary_candidates(case[1]))
        end
        assert.same({ "a.a", "a/b.a", "a/b/c.a" },
            driver.module_compiled_candidates("a.b.c", ".a"))
        assert.same({}, driver.module_binary_candidates("a..b"))
        assert.same({},
            driver.module_compiled_candidates("a..b", ".a"))
    end)

    it("expands explicit double separators with the runtime default", function()
        assert.equal("R1;D1;D2;R2",
            driver.expand_titan_bin_path("R1;;R2", "D1;D2"))
        assert.same({ "R1", "D1", "D2", "R2" },
            driver.titan_bin_path_entries("R1;;R2", "D1;D2"))
        assert.same({ "D1", "D2" },
            driver.titan_bin_path_entries(nil, "D1;D2"))
    end)

    it("preserves literal percent signs while inserting defaults", function()
        local explicit = "/tmp/100%/first;;/tmp/50%/last"
        local defaults = "/tmp/default%root;/tmp/other%root"
        assert.equal(table.concat({
            "/tmp/100%/first",
            "/tmp/default%root",
            "/tmp/other%root",
            "/tmp/50%/last",
        }, ";"), driver.expand_titan_bin_path(explicit, defaults))
        assert.same({
            "/tmp/100%/first",
            "/tmp/default%root",
            "/tmp/other%root",
            "/tmp/50%/last",
        }, driver.titan_bin_path_entries(explicit, defaults))
    end)

    it("stages an atomic library under its final basename", function()
        local workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        local public = workspace .. "/nested/provider.so"
        local staged, directory = driver.staged_library_output(public)
        assert.truthy(staged, directory)
        assert.equal("provider.so", staged:match("([^/]+)$"))
        assert.equal(workspace .. "/nested",
            assert(directory:match("^(.*)/[^/]+$")))
        assert.equal(directory .. "/provider.so", staged)
        remove_tree(workspace)
    end)
end)

describe("loader resolver ownership", function()
    it("closes the titanc resolver when an unexpected error unwinds the chunk",
    function()
        local close_calls = 0
        local fake_driver = {
            deduplicate_module_names = function(modules) return modules end,
            new_resolver_context = function() return {} end,
            configure_foreign_c = function() end,
            defaultloader = function()
                error("injected titanc loader failure")
            end,
            close_resolver_context = function(context)
                assert.is_table(context)
                close_calls = close_calls + 1
                return true
            end,
        }
        local argument_parser = {}
        local chain = { args = function(self) return self end }
        function argument_parser:argument() return chain end
        function argument_parser:flag() return chain end
        function argument_parser:option() return chain end
        function argument_parser:parse()
            return {
                module = { "exceptional" },
                extra_object = {},
            }
        end
        local fake_argparse = setmetatable({}, {
            __call = function() return argument_parser end,
        })
        local modules = {
            argparse = fake_argparse,
            ["titan-compiler.checker"] = {},
            ["titan-compiler.coder"] = {},
            ["titan-compiler.parser"] = {},
            ["titan-compiler.driver"] = fake_driver,
            ["titan-compiler.test_runner"] = {},
            ["titan-compiler.util"] = {},
        }
        local environment = setmetatable({
            arg = {},
            require = function(name)
                return assert(modules[name], "unexpected module " .. name)
            end,
        }, { __index = _G })
        local chunk = assert(loadfile("titanc", "t", environment))
        local ok, err = pcall(chunk)
        assert.is_false(ok)
        assert.matches("injected titanc loader failure", tostring(err),
            1, true)
        assert.equal(1, close_calls)
    end)

    it("closes internally owned default and table resolvers exactly once",
    function()
        local original_close = driver.close_resolver_context
        local close_calls = 0
        driver.close_resolver_context = function(context)
            assert.is_table(context)
            close_calls = close_calls + 1
            return true
        end

        local ran, failure = pcall(function()
            local default = driver.defaultloader({})
            local first, second, third =
                driver.with_loader(default, function(loader)
                    assert.is_function(loader)
                    return "done", nil, 3
                end)
            assert.equal("done", first)
            assert.is_nil(second)
            assert.equal(3, third)
            assert.equal(1, close_calls)
            assert.is_true(driver.close_loader(default))
            assert.equal(1, close_calls)

            local in_memory = driver.tableloader({}, {}, {})
            local body_ok, body_error = pcall(
                driver.with_loader, in_memory, function()
                    error("injected loader body failure")
                end)
            assert.is_false(body_ok)
            assert.matches("injected loader body failure",
                tostring(body_error), 1, true)
            assert.equal(2, close_calls)
            assert.is_true(driver.close_tableloader(in_memory))
            assert.equal(2, close_calls)

            local borrowed_context = driver.new_resolver_context()
            local borrowed = driver.defaultloader({}, {
                context = borrowed_context,
            })
            assert.is_true(driver.close_loader(borrowed))
            assert.equal(2, close_calls)
            assert.is_true(original_close(borrowed_context))
        end)
        driver.close_resolver_context = original_close
        assert.truthy(ran, failure)
    end)

    it("removes source-header temporaries with or without a probe service",
    function()
        local first = os.tmpname()
        local second = os.tmpname()
        write_file(first, "first")
        write_file(second, "second")
        local context = {
            io = compiler_io.new_sync(),
            source_foreign_header_temporaries = { first, second },
            probe_service = {
                close = function()
                    return nil, "injected probe close failure"
                end,
            },
        }
        local ok, err = driver.close_resolver_context(context)
        assert.is_nil(ok)
        assert.equal("injected probe close failure", err)
        assert.is_nil(context.source_foreign_header_temporaries)
        assert.is_nil(context.probe_service)
        assert.is_nil(lfs.symlinkattributes(first))
        assert.is_nil(lfs.symlinkattributes(second))

        local third = os.tmpname()
        write_file(third, "third")
        assert.is_true(driver.close_resolver_context({
            io = compiler_io.new_sync(),
            source_foreign_header_temporaries = { third },
        }))
        assert.is_nil(lfs.symlinkattributes(third))
    end)

    it("retains source-header temporaries after unlink and lstat failures",
    function()
        assert.has_error(function()
            driver.close_resolver_context({})
        end, "closing a resolver requires its compiler I/O strategy")

        local unlink_strategy = compiler_io.new_sync()
        function unlink_strategy:lstat(path)
            assert.equal("/virtual/remove-failure.h", path)
            return { kind = "file" }
        end
        function unlink_strategy:unlink(path)
            assert.equal("/virtual/remove-failure.h", path)
            return nil, "injected unlink failure"
        end
        local unlink_context = {
            io = unlink_strategy,
            source_foreign_header_temporaries = {
                "/virtual/remove-failure.h",
            },
        }

        local ok, err = driver.close_resolver_context(unlink_context)
        assert.is_nil(ok)
        assert.equal("injected unlink failure", err)
        assert.same({
            "/virtual/remove-failure.h",
        }, unlink_context.source_foreign_header_temporaries)

        local lstat_strategy = compiler_io.new_sync()
        function lstat_strategy:lstat(path)
            assert.equal("/virtual/lstat-failure.h", path)
            return nil, "injected lstat failure"
        end
        local lstat_context = {
            io = lstat_strategy,
            source_foreign_header_temporaries = {
                "/virtual/lstat-failure.h",
            },
        }
        ok, err = driver.close_resolver_context(lstat_context)
        assert.is_nil(ok)
        assert.equal("injected lstat failure", err)
        assert.same({
            "/virtual/lstat-failure.h",
        }, lstat_context.source_foreign_header_temporaries)
    end)

    it("reports an owned resolver close failure after a successful body",
    function()
        local original_close = driver.close_resolver_context
        driver.close_resolver_context = function()
            return nil, "injected resolver close failure"
        end
        local loader = driver.defaultloader({})
        local ok, err = pcall(
            driver.with_loader, loader, function() return true end)
        driver.close_resolver_context = original_close

        assert.is_false(ok)
        assert.matches("failed to close loader resolver context", err)
        assert.matches("injected resolver close failure", err)
        assert.is_true(driver.close_loader(loader))
    end)

    it("retries an owned resolver close after thrown cancellation", function()
        local original_close = driver.close_resolver_context
        local cancellation = { kind = "simulated cancellation" }
        local close_calls = 0
        driver.close_resolver_context = function(context)
            assert.is_table(context)
            close_calls = close_calls + 1
            if close_calls == 1 then error(cancellation) end
            return true
        end

        local ran, failure = pcall(function()
            local loader = driver.defaultloader({})
            local first_closed, reason = pcall(driver.close_loader, loader)
            assert.is_false(first_closed)
            assert.equal(cancellation, reason)
            assert.equal(1, close_calls)

            assert.is_true(driver.close_loader(loader))
            assert.equal(2, close_calls)
            assert.is_true(driver.close_loader(loader))
            assert.equal(2, close_calls)
        end)
        driver.close_resolver_context = original_close
        assert.truthy(ran, failure)
    end)
end)


describe("generated C formatting", function()
    local original_execute
    local original_rename
    local original_print
    local original_formatter
    local original_format_generated_file
    local original_get_file_contents
    local original_set_file_contents

    before_each(function()
        original_execute = os.execute
        original_rename = os.rename
        original_print = _G.print
        original_formatter = driver.CLANG_FORMAT
        original_format_generated_file = driver.format_generated_file
        original_get_file_contents = util.get_file_contents
        original_set_file_contents = util.set_file_contents
    end)

    after_each(function()
        os.execute = original_execute
        os.rename = original_rename
        _G.print = original_print
        driver.CLANG_FORMAT = original_formatter
        driver.format_generated_file = original_format_generated_file
        util.get_file_contents = original_get_file_contents
        util.set_file_contents = original_set_file_contents
    end)

    it("does not invoke the formatter by default", function()
        os.execute = function() error("unexpected formatter execution") end
        driver.CLANG_FORMAT = "'unterminated"
        local path = os.tmpname() .. " generated module.c"
        write_file(path, "int   value;\n")

        assert.is_true(driver.format_generated_file(path, true))
        assert.equal("int   value;\n", assert(util.get_file_contents(path)))
        assert(os.remove(path))
    end)

    it("quotes configured argv and generated paths when opted in", function()
        local commands = {}
        local printed = {}
        os.execute = function(command)
            commands[#commands + 1] = command
            return true, "exit", 0
        end
        _G.print = function(command) printed[#printed + 1] = command end
        driver.CLANG_FORMAT = "'/tools with spaces/clang-format' --Werror"
        local path = os.tmpname() .. " generated module.c"
        write_file(path, "int value;\n")

        assert.is_true(driver.format_generated_file(path, true, true))
        assert.equal(1, #commands)
        assert.same(commands, printed)
        assert.matches("'/tools with spaces/clang%-format'", commands[1])
        assert.matches(path, commands[1], 1, true)
        assert.matches("'%-%-Werror'", commands[1])
        assert(os.remove(path))
    end)

    it("formats and normalizes through the resolver strategy", function()
        local calls = {}
        local normalized
        local strategy = compiler_io.new_sync()
        function strategy:run(argv, options)
            calls[#calls + 1] = { argv = argv, options = options }
            return {
                started = true,
                ok = true,
                why = "exit",
                status = 0,
            }
        end
        function strategy:read_file(path)
            assert.equal("/virtual/generated.c", path)
            return '#line 1 "module.titan"\n\nint value;\n'
        end
        function strategy:write_file(path, contents)
            assert.equal("/virtual/generated.c", path)
            normalized = contents
            return true
        end
        driver.CLANG_FORMAT = "clang-format --Werror"

        assert.is_true(driver.format_generated_file(
            "/virtual/generated.c", false, true, strategy))
        assert.equal(1, #calls)
        assert.same({
            "clang-format",
            "--Werror",
            "-i",
            "--style={BasedOnStyle: LLVM, IndentWidth: 4, SortIncludes: false}",
            "--",
            "/virtual/generated.c",
        }, calls[1].argv)
        assert.is_true(calls[1].options.stderr_to_stdout)
        assert.equal('#line 1 "module.titan"\nint value;\n', normalized)
    end)

    it("normalizes line directives without invoking the formatter", function()
        local path = os.tmpname() .. " generated.c"
        write_file(path, table.concat({
            '#line 7 "first.titan"',
            '',
            '    ',
            'int first;',
            '#line 11 "second.titan"',
            '	',
            'int second;',
            '',
        }, "\n"))
        os.execute = function() error("unexpected formatter execution") end

        assert.is_true(driver.format_generated_file(path, false))
        local contents = assert(util.get_file_contents(path))
        assert.equal(table.concat({
            '#line 7 "first.titan"',
            'int first;',
            '#line 11 "second.titan"',
            'int second;',
            '',
        }, "\n"), contents)
        assert(os.remove(path))
    end)

    it("reports normalization read and write failures", function()
        local path = os.tmpname() .. " generated.c"
        local ok, err = driver.format_generated_file(path, false)
        assert.is_nil(ok)
        assert.matches("failed to normalize", err, 1, true)
        assert.matches(path, err, 1, true)

        write_file(path, '#line 1 "test.titan"\n\nint value;\n')
        util.set_file_contents = function(filename, contents)
            assert.equal(path, filename)
            assert.equal('#line 1 "test.titan"\nint value;\n', contents)
            return false, "injected normalization write failure"
        end
        ok, err = driver.format_generated_file(path, false)
        assert.is_nil(ok)
        assert.matches("failed to normalize", err, 1, true)
        assert.matches("injected normalization write failure", err, 1, true)
        assert(os.remove(path))
    end)

    it("reports opted-in formatter failures before normalization", function()
        local status = 23
        os.execute = function() return nil, "exit", status end
        driver.CLANG_FORMAT = "clang-format"
        local path = "/tmp/generated failure.c"
        local ok, err = driver.format_generated_file(path, false, true)
        assert.is_nil(ok)
        assert.matches("clang%-format", err)
        assert.matches(path, err, 1, true)
        assert.matches("exit 23", err, 1, true)

        status = 127 -- the ordinary shell status for a missing executable
        ok, err = driver.format_generated_file(path, false, true)
        assert.is_nil(ok)
        assert.matches(path, err, 1, true)
        assert.matches("exit 127", err, 1, true)
    end)

    it("reports malformed and empty opted-in formatter commands", function()
        os.execute = function() error("unexpected formatter execution") end
        local path = "/tmp/generated malformed.c"
        driver.CLANG_FORMAT = "'unterminated"
        local ok, err = driver.format_generated_file(path, false, true)
        assert.is_nil(ok)
        assert.matches(path, err, 1, true)
        assert.matches("invalid CLANG_FORMAT", err, 1, true)

        driver.CLANG_FORMAT = ""
        ok, err = driver.format_generated_file(path, false, true)
        assert.is_nil(ok)
        assert.matches(path, err, 1, true)
        assert.matches("CLANG_FORMAT command is empty", err, 1, true)
    end)

    it("preserves a generated header when staging or rename fails", function()
        local root = os.tmpname() .. " formatter transaction"
        assert(lfs.mkdir(root))
        local header = root .. "/module.titan.h"
        local old = driver.FOREIGN_HEADER_MARKER .. "\n/* old */\n"
        local plan = {
            filename = header,
            contents = driver.FOREIGN_HEADER_MARKER .. "\nint value;\n",
            ast = {},
        }
        write_file(header, old)

        util.set_file_contents = function()
            return nil, "injected stage write failure"
        end
        local ok, err = driver.write_foreign_header_plan(plan)
        assert.is_nil(ok)
        assert.matches("injected stage write failure", err, 1, true)
        assert.equal(old, assert(original_get_file_contents(header)))

        util.set_file_contents = original_set_file_contents
        driver.format_generated_file = function() return true end
        os.rename = function()
            return nil, "injected stage rename failure"
        end
        ok, err = driver.write_foreign_header_plan(plan)
        assert.is_nil(ok)
        assert.matches("injected stage rename failure", err, 1, true)
        assert.equal(old, assert(original_get_file_contents(header)))
        assert.is_nil(plan.ast._foreign_header_prepared)
        remove_tree(root)
    end)

    it("publishes a generated header only after its staged copy formats",
    function()
        local root = os.tmpname() .. " formatter space"
        assert(lfs.mkdir(root))
        local header = root .. "/module.titan.h"
        local old = driver.FOREIGN_HEADER_MARKER .. "\n/* old */\n"
        local new = driver.FOREIGN_HEADER_MARKER .. "\nint value;\n"
        write_file(header, old)
        local plan = {
            filename = header,
            contents = new,
            ast = {},
        }
        local calls = {}
        driver.format_generated_file = function(path, verbose, pretty_print)
            assert.is_nil(verbose)
            assert.is_true(pretty_print)
            calls[#calls + 1] = path
            return nil, "injected formatter failure"
        end
        local ok, err = driver.write_foreign_header_plan(plan, nil, true)
        assert.is_nil(ok)
        assert.matches("injected formatter failure", err, 1, true)
        assert.equal(old, assert(util.get_file_contents(header)))
        assert.is_nil(plan.ast._foreign_header_prepared)
        assert.equal(1, #calls)
        assert.is_nil(lfs.symlinkattributes(calls[1]))

        driver.format_generated_file = function(path, verbose, pretty_print)
            assert.is_nil(verbose)
            assert.is_true(pretty_print)
            local contents = assert(util.get_file_contents(path))
            assert(util.set_file_contents(path,
                contents .. "/* formatted */\n"))
            return true
        end
        assert.is_true(driver.write_foreign_header_plan(plan, nil, true))
        assert.equal(new .. "/* formatted */\n",
            assert(util.get_file_contents(header)))
        assert.is_true(plan.ast._foreign_header_prepared)
        remove_tree(root)
    end)
end)

describe("source foreign-header planning", function()
    it("plans dependency headers, writes owned outputs, and removes stale ones",
    function()
        local root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local producer_source = root .. "/producer.titan"
        local consumer_source = root .. "/consumer.titan"
        local producer_import = {
            _tag = "Ast.TopLevelForeignFunc",
            name = "callback",
        }
        local import = {
            _tag = "Ast.TopLevelImport",
            modname = "producer",
            _source_import = true,
        }
        local producer_ast = { producer_import }
        local consumer_ast = { import, {
            _tag = "Ast.TopLevelForeignFunc",
            name = "wrapper",
        } }
        local imported = {
            producer = {
                ast = producer_ast,
                filename = producer_source,
                native_output = producer_source,
            },
            consumer = {
                ast = consumer_ast,
                filename = consumer_source,
                native_output = consumer_source,
            },
        }

        local original = coder.generate_foreign_header
        local generated = {}
        coder.generate_foreign_header = function(name, ast)
            generated[name] = (generated[name] or 0) + 1
            local dependency = ast[1] and ast[1]._foreign_header
            return driver.FOREIGN_HEADER_MARKER .. "\n/* " .. name .. " "
                .. tostring(dependency) .. " */\n"
        end
        local ok, plans_or_err = pcall(
            driver.plan_foreign_headers,
            { "producer", "consumer" }, imported)
        coder.generate_foreign_header = original
        assert.truthy(ok, plans_or_err)
        local plans = plans_or_err
        assert.equal(2, #plans)
        assert.same({ producer = 1, consumer = 1 }, generated)
        assert.equal(root .. "/producer.titan.h", import._foreign_header)
        assert.truthy(plans[2].contents:find(import._foreign_header, 1, true))
        assert.is_true(driver.write_foreign_header_plans(plans))
        assert.equal(plans[1].contents,
            producer_ast._foreign_header_contents)
        assert.equal(plans[2].contents,
            consumer_ast._foreign_header_contents)
        assert.equal("file", lfs.attributes(root .. "/producer.titan.h", "mode"))
        assert.equal("file", lfs.attributes(root .. "/consumer.titan.h", "mode"))

        producer_ast[1]._ignore = true
        consumer_ast[2]._ignore = true
        local stale = assert(driver.plan_foreign_headers(
            { "producer", "consumer" }, imported))
        assert.is_true(driver.write_foreign_header_plans(stale))
        assert.is_nil(lfs.symlinkattributes(root .. "/producer.titan.h"))
        assert.is_nil(lfs.symlinkattributes(root .. "/consumer.titan.h"))
        remove_tree(root)
    end)

    it("rejects shared and user-owned planned header paths", function()
        local root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local shared = root .. "/shared.titan"
        local ast = { { _tag = "Ast.TopLevelForeignFunc", name = "f" } }
        local original = coder.generate_foreign_header
        coder.generate_foreign_header = function()
            return driver.FOREIGN_HEADER_MARKER .. "\n"
        end
        local plans, err = driver.plan_foreign_headers({ "left", "right" }, {
            left = { ast = ast, filename = shared, native_output = shared },
            right = { ast = ast, filename = shared, native_output = shared },
        })
        coder.generate_foreign_header = original
        assert.is_nil(plans)
        assert.matches("is shared by source modules", err, 1, true)

        local reserved = root .. "/reserved.titan"
        write_file(root .. "/reserved.titan.h", "/* user-owned */\n")
        coder.generate_foreign_header = function()
            return driver.FOREIGN_HEADER_MARKER .. "\n"
        end
        local plan = driver.plan_foreign_header("reserved", ast, reserved)
        coder.generate_foreign_header = original
        local ok
        ok, err = driver.validate_foreign_header_plan(plan)
        assert.is_nil(ok)
        assert.matches("refusing to overwrite user-owned", err, 1, true)
        remove_tree(root)
    end)
end)

describe("standalone output ownership", function()
    it("rejects source and synthetic output collisions before compilation",
       function()
        local stems = {
            "suite__test_support",
            "suite__test_runner",
        }
        for _, stem in ipairs(stems) do
            local ok, message = driver.validate_program_output_paths({
                { modname = "generated", output = stem .. ".titan" },
                { modname = "user", output = stem .. ".titan" },
            }, "suite", "suite__test_entrypoint.c", {})
            assert.is_nil(ok)
            assert.matches("aliases output", message, 1, true)
        end

        local ok, message = driver.validate_program_output_paths({
            {
                modname = "suite__test_entrypoint",
                output = "suite__test_entrypoint.titan",
            },
        }, "suite", "suite__test_entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("standalone entrypoint", message, 1, true)

        ok, message = driver.validate_program_output_paths({},
            "suite", "suite__test_entrypoint.c",
            { "suite__test_entrypoint.o" })
        assert.is_nil(ok)
        assert.matches("aliases input", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "generated",
                output = "generated.titan",
                foreign_header = "suite",
            },
        }, "suite", "suite__test_entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("aliases output", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "generated",
                output = "generated.titan",
                foreign_header = "generated.titan.h",
            },
        }, "suite", "suite__test_entrypoint.c",
            { "generated.titan.h" })
        assert.is_nil(ok)
        assert.matches("aliases input", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "portable.first",
                output = "portable_first.titan",
                foreign_header = "PortableCase.titan.h",
            },
            {
                modname = "portable.second",
                output = "portable_second.titan",
                foreign_header = "portablecase.titan.h",
            },
        }, "portable_program", "portable_entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("aliases output", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "portable.input",
                output = "portable_input.titan",
                foreign_header = "PortableInput.titan.h",
            },
        }, "portable_input_program", "portable_input_entrypoint.c",
            { "portableinput.titan.h" })
        assert.is_nil(ok)
        assert.matches("aliases input", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "portable.child",
                output = "portabletree/child.titan",
            },
        }, "PortableTree", "portable_tree_entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("path hierarchy conflict", message, 1, true)

        ok, message = driver.validate_program_output_paths({
            {
                modname = "portable.native",
                output = "portable_native.titan",
                foreign_header = "PortableNativeTree",
            },
        }, "portable_native_program", "portable_native_entrypoint.c",
            { "portablenativetree/child.o" })
        assert.is_nil(ok)
        assert.matches("path hierarchy conflict", message, 1, true)
    end)


    it("accepts a symlinked directory parent and canonicalizes its outputs",
       function()
        local root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local physical = root .. "/physical"
        local linked = root .. "/linked"
        assert(lfs.mkdir(physical))
        assert(lfs.link(physical, linked, true))

        local ok, message = driver.validate_program_output_paths({
            { modname = "linked", output = linked .. "/module.titan" },
        }, root .. "/program", root .. "/entrypoint.c", {})
        assert.truthy(ok, message)

        assert(os.remove(linked))
        assert(lfs.rmdir(physical))
        assert(lfs.rmdir(root))
    end)

    it("rejects hierarchy conflicts and nonregular output leaves", function()
        local root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))

        local ok, message = driver.validate_program_output_paths({
            {
                modname = "suite.child",
                output = root .. "/suite/child.titan",
            },
        }, root .. "/suite", root .. "/entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("path hierarchy conflict", message, 1, true)

        local directory_output = root .. "/support.c"
        assert(lfs.mkdir(directory_output))
        ok, message = driver.validate_program_output_paths({
            { modname = "support", output = root .. "/support.titan" },
        }, root .. "/suite", root .. "/entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("not a regular nonlink file", message, 1, true)

        remove_tree(root)
    end)
end)

describe("compiler module loader", function()
    local root
    local source
    local binary
    local previous

    local function cache_static_provider(context, filename, module_types)
        write_file(filename, "mock static provider\n")
        local provider = {
            archive = filename,
            entries = {},
            key_order = {},
        }
        for name, modtype in pairs(module_types) do
            provider.entries[name] = {
                type = modtype,
                types = types.serialize(modtype),
                origin = filename .. ":" .. name,
            }
            provider.key_order[#provider.key_order + 1] = name
        end
        table.sort(provider.key_order, util.bytewise_less)
        context.provider_cache[filename] = provider
        return provider
    end

    local function cache_dynamic_provider(filename, module_types)
        write_file(filename, "mock dynamic provider\n")
        titan._loadlib = function(found_filename, symbol)
            assert.equal(filename, found_filename)
            for name, modtype in pairs(module_types) do
                local prefix = driver.mangle_module_name(name)
                if symbol == prefix .. "_abi" then
                    return function() return driver.TITAN_ABI_VERSION end
                elseif symbol == prefix .. "_types" then
                    local serialized = types.serialize(modtype)
                    return function() return serialized end
                end
            end
            error("unexpected symbol " .. symbol)
        end
    end

    local function source_module(name, members, type_members,
            source_members, source_type_members)
        source_members = source_members or {}
        for _, member in ipairs(source_members) do
            member.islocal = true
            source_members[member.name] = member
        end
        local modtype = types.Module(name, members or {}, type_members or {})
        modtype._source = true
        modtype.source_members = source_members
        modtype.source_type_members = source_type_members or {}
        return modtype
    end

    local function source_entry(name, modtype, headers)
        local filename = root .. "/" .. name .. ".titan"
        return {
            kind = "source",
            ast = {},
            type = modtype or source_module(name),
            filename = filename,
            source_files = { filename },
            deps = {},
            c_header_dependencies = headers or {},
        }
    end

    local function source_manifest(entry)
        local manifest, err = driver.serialize_source_interface(entry)
        assert.is_nil(err)
        assert.is_string(manifest)
        assert.not_equal("", manifest)
        return manifest
    end

    local function generated_source_manifest(contents)
        driver.imported = {}
        types.registry = {}
        local name = "source_manifest_generated"
        local filename = root .. "/" .. name .. ".titan"
        local loader = driver.defaultloader({}, {
            source_roots = { [name] = true },
            source_overrides = {
                [name] = {
                    kind = "generated",
                    main = filename,
                    files = { filename },
                    contents = { [filename] = contents },
                },
            },
        })
        local ok, result, errors = loader(name)
        assert.truthy(ok, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local entry = assert(driver.imported[name])
        local manifest = entry.source_manifest
        assert.is_string(manifest)
        assert.not_equal("", manifest)
        assert.is_true(driver.close_loader(loader))
        return manifest
    end

    it("reports source-interface publication failures as analysis errors",
    function()
        local name = "source_manifest_publication_failure"
        local filename = root .. "/" .. name .. ".titan"
        local loader = driver.defaultloader({}, {
            source_roots = { [name] = true },
            source_overrides = {
                [name] = {
                    kind = "generated",
                    main = filename,
                    files = { filename },
                    contents = {
                        [filename] = [[
                            function answer(): integer
                                return 42
                            end
                        ]],
                    },
                },
            },
        })
        local serialize = driver.serialize_source_interface
        driver.serialize_source_interface = function()
            return nil, "forced source-interface failure"
        end
        local called, ok, _, errors = pcall(loader, name)
        driver.serialize_source_interface = serialize

        assert.truthy(called, tostring(ok))
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.equal(
            "could not serialize source interface for module '" .. name ..
                "': forced source-interface failure",
            errors[1])
        assert.is_nil(driver.imported[name].source_manifest)
        assert.is_true(driver.close_loader(loader))
    end)

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        source = root .. "/source"
        binary = root .. "/binary"
        assert(lfs.mkdir(source))
        assert(lfs.mkdir(binary))
        assert(lfs.mkdir(source .. "/titan"))
        assert(lfs.mkdir(binary .. "/titan"))

        previous = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            imported = driver.imported,
            registry = types.registry,
            loadlib = titan._loadlib,
        }
        driver.TITAN_SOURCE_PATH = source
        driver.TITAN_BIN_PATH = binary
        driver.imported = {}
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.imported = previous.imported
        types.registry = previous.registry
        titan._loadlib = previous.loadlib
        remove_tree(root)
    end)

    it("validates source-interface entries and their exact header inputs",
    function()
        local function reject(entry, expected)
            local manifest, err = driver.serialize_source_interface(entry)
            assert.is_nil(manifest)
            assert.matches(expected, tostring(err), 1, true)
        end
        local function malformed(mutator)
            local entry = source_entry("source_manifest_invalid")
            mutator(entry)
            return entry
        end

        reject(nil, "is not a complete checked source module")
        reject(malformed(function(entry) entry.kind = "dynamic" end),
            "is not a complete checked source module")
        reject(malformed(function(entry) entry.ast = false end),
            "is not a complete checked source module")
        reject(malformed(function(entry)
            entry.type = types.Module("source_manifest_invalid", {})
        end), "is not a complete checked source module")
        reject(malformed(function(entry) entry.filename = "" end),
            "is not a complete checked source module")
        reject(malformed(function(entry)
            entry.source_files.extra = true
        end), "has invalid source_files")
        reject(malformed(function(entry)
            entry.source_files = {
                [1] = entry.filename,
                [3] = root .. "/source-manifest-part.titan",
            }
        end), "has invalid source_files")
        reject(malformed(function(entry)
            entry.source_files = { root .. "/not-main.titan" }
        end), "has invalid source_files")
        reject(malformed(function(entry) entry.deps = nil end),
            "has no dependency map")
        reject(malformed(function(entry)
            entry.deps = { ["invalid dependency"] = true }
        end), "has an invalid dependency map")

        local valid = {
            kind = "search",
            path = "/virtual/source-interface.h",
            identity = "missing",
        }
        local header_cases = {
            {
                headers = "invalid",
                expected = "must be an ordered array",
            },
            {
                headers = { "invalid" },
                expected = "entry 1 must be a table",
            },
            {
                headers = {{
                    kind = "invalid",
                    path = valid.path,
                    identity = valid.identity,
                }},
                expected = "kind must be 'file' or 'search'",
            },
            {
                headers = {{
                    kind = valid.kind,
                    path = "relative.h",
                    identity = valid.identity,
                }},
                expected = "path must be an absolute NUL-free pathname",
            },
            {
                headers = {{
                    kind = valid.kind,
                    path = valid.path,
                    identity = "",
                }},
                expected = "must have a nonempty identity",
            },
            {
                headers = { valid, valid },
                expected = "repeats search input '/virtual/source-interface.h'",
            },
            {
                headers = { valid, extra = true },
                expected = "must be a dense ordered array",
            },
        }
        for _, case in ipairs(header_cases) do
            reject(malformed(function(entry)
                entry.c_header_dependencies = case.headers
            end), case.expected)
        end
    end)

    it("rejects malformed internal source-interface graphs deterministically",
    function()
        local function direct(modtype, headers)
            return {
                kind = "source",
                type = modtype,
                c_header_dependencies = headers or {},
            }
        end
        local function reject(entry, expected)
            local manifest, err = sourceinterface.serialize(entry)
            assert.is_nil(manifest)
            assert.matches(expected, tostring(err), 1, true)
        end
        local function with_type(name, typ)
            return source_module(name, {}, {}, {}, { Bad = typ })
        end
        local function module_variable(name)
            return {
                _tag = "Type.ModuleVariable",
                modname = name,
                name = "bad",
                type = types.Integer(),
                isconst = false,
                islocal = true,
            }
        end

        reject(nil, "source interface entry must be a source module")
        reject({ kind = "source", type = types.Module("public_only", {}) },
            "source interface entry has no source Type.Module")

        local scalar_name = "source_manifest_bad_scalar"
        local bad_scalar = module_variable(scalar_name)
        bad_scalar.isconst = 0.5
        reject(direct(source_module(
            scalar_name, {}, {}, { bad_scalar })),
            "is not a scalar source-interface value")

        local index_name = "source_manifest_bad_index"
        local bad_index = source_module(index_name)
        bad_index.source_members = {
            [1.5] = module_variable(index_name),
        }
        reject(direct(bad_index), "has an invalid array index")

        local key_name = "source_manifest_bad_key"
        local bad_key = source_module(key_name)
        bad_key.source_members = {
            [false] = module_variable(key_name),
        }
        reject(direct(bad_key), "has a non-array key")

        local function aggregate(origin)
            return {
                _tag = "Type.CStruct",
                cname = { "outer", "inner" },
                tagname = false,
                typedef = false,
                _c_tag_scope = "source_manifest_internal",
                _ffi_scope = "source_manifest_internal",
                _c_origin_header = origin,
            }
        end
        reject(direct(with_type("source_manifest_bad_origin_input",
            aggregate({
                rendered = "<bad-origin-input.h>",
                c_header_dependencies = { "invalid" },
                c_header_search_inputs = {},
            }))), "C header dependencies entry 1 must be a table")
        reject(direct(with_type("source_manifest_uncovered_origin",
            aggregate({
                rendered = "<uncovered.h>",
                c_header_dependencies = {},
                c_header_search_inputs = {},
            }))), "C header origin is not covered by the source interface")
        reject(direct(with_type("source_manifest_bad_wrapper",
            aggregate({
                rendered = "\"bad-wrapper.h\"",
                probe_wrapper = { name = "", contents = "" },
            }))), "has an invalid source-foreign header wrapper")

        local wrapped = direct(with_type("source_manifest_wrapped_origin",
            aggregate({
                rendered = "\"titan-source-foreign-test.h\"",
                probe_wrapper = {
                    name = "titan-source-foreign-test.h",
                    contents = "generated interface",
                },
            })))
        assert.is_string(sourceinterface.serialize(wrapped))

        reject(direct(with_type("source_manifest_bad_header", {
            _tag = "Type.Pointer",
            type = types.Integer(),
            _ffi_scope = "source_manifest_bad_header",
            _c_origin_header = { rendered = "" },
        })), "has no stable rendered spelling")
        reject(direct(with_type("source_manifest_bad_descriptor", {})),
            "is not a type descriptor")
        reject(direct(with_type("source_manifest_unspellable_enum", {
            _tag = "Type.CInteger",
            spelling = "int",
            signed = true,
            rank = 3,
            bits = 32,
            _c_enum_unspellable = true,
            _c_declaration_spelling = false,
            _c_enum_enumerator = false,
            _ffi_scope = "source_manifest_unspellable_enum",
        })), "unspellable anonymous C enum reached a source interface")

        local header_module = source_module("source_manifest_bad_headers")
        local valid_header = {
            kind = "file",
            path = "/virtual/direct-source-interface.h",
            identity = "bytes:direct",
        }
        reject(direct(header_module, "invalid"),
            "C header dependencies must be an ordered array")
        reject(direct(header_module, { "invalid" }),
            "C header dependency 1 must be a table")
        reject(direct(header_module, {{
            kind = "invalid",
            path = valid_header.path,
            identity = valid_header.identity,
        }}), "C header dependency 1 has invalid kind")
        reject(direct(header_module, {{
            kind = valid_header.kind,
            path = "relative.h",
            identity = valid_header.identity,
        }}), "C header dependency 1 has invalid path")
        reject(direct(header_module, {{
            kind = valid_header.kind,
            path = valid_header.path,
            identity = "",
        }}), "C header dependency 1 has no identity")
        reject(direct(header_module, { valid_header, valid_header }),
            "C header dependencies repeat file input " .. valid_header.path)
    end)

    it("keeps generated source manifests stable across non-interface edits",
    function()
        local baseline = [[
local seed: integer = 1
local function hidden(input: integer): integer
    return input + seed
end
function visible(input: integer): integer
    return hidden(input)
end
]]
        local expected = generated_source_manifest(baseline)
        assert.equal(expected, generated_source_manifest([[
-- Leading comments and blank lines must not become semantic metadata.


local seed: integer = 1
local function hidden(input: integer): integer
    return input + seed
end
function visible(input: integer): integer
    return hidden(input)
end
]]))
        assert.equal(expected, generated_source_manifest([[
local seed: integer = 1
local function hidden(input: integer): integer
    if input > seed then return input * 2 end
    return seed
end
function visible(input: integer): integer
    return hidden(input) + hidden(seed)
end
]]))
        assert.equal(expected, generated_source_manifest([[
local seed: integer = 99
local function hidden(input: integer): integer
    return input + seed
end
function visible(input: integer): integer
    return hidden(input)
end
]]))
    end)

    it("changes generated source manifests for private interface edits",
    function()
        local cases = {
            {
                name = "private parameter name",
                before = [[
local function hidden(input: integer): integer return input end
]],
                after = [[
local function hidden(item: integer): integer return item end
]],
            },
            {
                name = "private signature",
                before = [[
local function hidden(input: integer): integer return input end
]],
                after = [[
local function hidden(input: string): string return input end
]],
            },
            {
                name = "private constness",
                before = [[local seed: integer = 1]],
                after = [[local const seed: integer = 1]],
            },
            {
                name = "private value type",
                before = [[local seed: integer = 1]],
                after = [[local seed: string = "one"]],
            },
            {
                name = "local nominal field",
                before = [[
local record Hidden
    payload: integer
end
]],
                after = [[
local record Hidden
    payload: string
end
]],
            },
        }
        for _, case in ipairs(cases) do
            assert.not_equal(
                generated_source_manifest(case.before),
                generated_source_manifest(case.after), case.name)
        end
    end)

    it("includes header kind, path, identity, and order in source manifests",
    function()
        local function manifest(headers)
            return source_manifest(source_entry(
                "source_manifest_headers", nil, headers))
        end
        local first = {
            kind = "search",
            path = "/virtual/first.h",
            identity = "missing",
        }
        local second = {
            kind = "file",
            path = "/virtual/second.h",
            identity = "bytes:one",
        }
        local baseline = manifest({ first, second })
        assert.equal(baseline, manifest({
            {
                kind = first.kind,
                path = first.path,
                identity = first.identity,
            },
            {
                kind = second.kind,
                path = second.path,
                identity = second.identity,
            },
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = "file",
                path = first.path,
                identity = first.identity,
            }, second,
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = first.kind,
                path = "/virtual/renamed.h",
                identity = first.identity,
            }, second,
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = first.kind,
                path = first.path,
                identity = "now-present",
            }, second,
        }))
        assert.not_equal(baseline, manifest({ second, first }))
    end)

    it("ignores benign descriptor sharing topology", function()
        local function manifest(shared)
            local name = "source_manifest_sharing"
            local first = { _tag = "Type.Integer" }
            local second = shared and first or { _tag = "Type.Integer" }
            local member = types.ModuleMember(name, "hidden",
                types.Function({ first, second }, { first },
                    false, false, false), { "left", "right" })
            member.islocal = true
            return source_manifest(source_entry(name,
                source_module(name, {}, {}, { member })))
        end
        assert.equal(manifest(true), manifest(false))
    end)

    it("requires omitted C aggregate layouts to have covered origins",
    function()
        local name = "source_manifest_aggregate_origin"
        local aggregate = types.CStruct(
            "struct hidden", "hidden", false, {}, true, false)
        local entry = source_entry(name,
            source_module(name, {}, {}, {}, { Hidden = aggregate }))
        local manifest, err = driver.serialize_source_interface(entry)
        assert.is_nil(manifest)
        assert.matches("has no stable C header origin", err, 1, true)

        local dependency = {
            kind = "file",
            path = "/virtual/aggregate-origin.h",
            identity = "bytes:aggregate",
        }
        aggregate._c_origin_header = {
            rendered = "<aggregate-origin.h>",
            c_header_dependencies = { dependency },
            c_header_search_inputs = {},
        }
        manifest, err = driver.serialize_source_interface(entry)
        assert.is_nil(manifest)
        assert.matches("is not covered by the source interface", err, 1, true)

        entry.c_header_dependencies = { dependency }
        assert.is_string(source_manifest(entry))
    end)

    it("serializes generic, nominal, alias, and recursive C source graphs " ..
       "without table-address or map-order instability", function()
        local function complex_entry(reverse, integer_bits)
            local name = "source_manifest_complex"
            local dependency = {
                kind = "file",
                path = "/virtual/source-manifest-complex.h",
                identity = "bytes:complex",
            }
            local header = {
                rendered = "source_manifest_complex.h",
                c_header_dependencies = { dependency },
                c_header_search_inputs = {},
            }
            local function cmetadata(typ)
                typ._ffi_scope = name
                typ._c_origin_header = header
                return typ
            end

            local cint = cmetadata(types.CInteger(
                "int", true, 3, integer_bits))
            cint._c_declaration_spelling = "signed int"
            cint._c_enum_enumerator = false
            local cfloat = cmetadata(types.CFloat("double"))
            local cvoid = cmetadata(types.CVoid())
            local aggregate_fields = {}
            local aggregate = cmetadata(types.CStruct(
                "struct source_node", "source_node", false,
                aggregate_fields, true, false))
            aggregate._c_tag_scope = name
            local aggregate_pointer = cmetadata(types.CPointer(
                aggregate, { "const" }))
            local recursive_field = cmetadata(types.CField(
                aggregate, "next", aggregate_pointer, false, false))
            aggregate_fields[1] = recursive_field
            aggregate_fields.next = recursive_field

            local aggregate_union = cmetadata(types.CUnion(
                "union source_choice", "source_choice", false,
                {}, true))
            aggregate_union._c_tag_scope = name
            local carray = cmetadata(types.CArray(cint, {
                "SOURCE_MANIFEST_BOUND",
                1,
                op = "+",
            }, { "volatile" }))
            local ctypedef = cmetadata(types.CTypedef(
                "source_count", cint, { "const" }))
            local cowned = cmetadata(types.COwned(aggregate, false))
            local cfunction = cmetadata(types.CFunction(
                { aggregate_pointer, carray, ctypedef }, cint, false, false))
            cfunction._paramstyle = "prototype"
            cfunction._return_declaration_qualifiers = { "const" }
            local legacy_pointer = cmetadata({
                _tag = "Type.Pointer",
                type = cint,
            })
            local legacy_typedef = cmetadata({
                _tag = "Type.Typedef",
                name = "legacy_count",
                _type = legacy_pointer,
            })

            local callable_scope = types.GenericScope(
                name, false, "identity", "callable", "function")
            local callable_parameter = types.Parameter(
                callable_scope, 1, "T", false)
            local callable_type_parameter = types.TypeParameter("T", false)
            local generic_callable = types.ModuleMember(
                name, "identity",
                types.FunctionScheme(callable_scope,
                    { callable_type_parameter },
                    types.Function(
                        { callable_parameter }, { callable_parameter },
                        false, false, false)),
                { "item" })

            local nominal_name = name .. ".Hidden"
            local nominal_scope = types.GenericScope(
                name, nominal_name, false, "owner", "record")
            local nominal_parameter = types.Parameter(
                nominal_scope, 1, "T", false)
            local nominal_type_parameter = types.TypeParameter("T", false)
            local field = types.Field(
                nominal_name, "payload", nominal_parameter, 0, false)
            field.islocal = true
            local fields = { field }
            fields.payload = field
            local build = types.StaticMethod(
                nominal_name, "build", { nominal_parameter },
                { types.Nominal(nominal_name, { nominal_parameter }) },
                false, false, { "payload" })
            build.islocal = true
            local create = types.StaticMethod(
                nominal_name, "create", {},
                { types.Nominal(nominal_name, { nominal_parameter }) },
                false, false, {})
            create.islocal = true
            local read = types.Method(
                nominal_name, "read", {}, { nominal_parameter },
                false, false, {})
            read.islocal = true
            local replace = types.Method(
                nominal_name, "replace", { nominal_parameter },
                { nominal_parameter }, false, false, { "payload" })
            replace.islocal = true
            local functions, methods = {}, {}
            if reverse then
                functions.create = create
                functions.build = build
                methods.replace = replace
                methods.read = read
            else
                functions.build = build
                functions.create = create
                methods.read = read
                methods.replace = replace
            end
            local nominal = types.Record(
                nominal_name, fields, functions, methods, 1,
                nominal_scope, { nominal_type_parameter })
            nominal.islocal = true
            local nominal_member = types.ModuleMember(
                name, "Hidden", nominal, false)

            local visible_name = name .. ".Visible"
            local visible_field = types.Field(
                visible_name, "shown", types.Integer(), 0, false)
            local hidden_field = types.Field(
                visible_name, "hidden", types.String(), 1, true)
            hidden_field.islocal = true
            local visible_fields = { visible_field, hidden_field }
            visible_fields.shown = visible_field
            visible_fields.hidden = hidden_field
            local visible = types.Record(
                visible_name, visible_fields, {}, {}, 2)
            local public_members = {
                types.ModuleMember(name, "Visible", visible, false),
            }

            local foreign = types.ModuleMember(
                name, "native", cfunction,
                { "node", "values", "count" })
            foreign._foreign_source = true

            local alias = types.GenericAlias(
                name, "Alias", true, nominal_name, false,
                nominal_scope, { nominal_type_parameter })
            local aliases = {}
            local alias_entries = {
                { "Alias", alias },
                { "CArray", carray },
                { "CField", recursive_field },
                { "CFloat", cfloat },
                { "CFunction", cfunction },
                { "CInteger", cint },
                { "COwned", cowned },
                { "CPointer", aggregate_pointer },
                { "CStruct", aggregate },
                { "CTypedef", ctypedef },
                { "CUnion", aggregate_union },
                { "CVoid", cvoid },
                { "LegacyPointer", legacy_pointer },
                { "LegacyTypedef", legacy_typedef },
            }
            if reverse then
                for index = #alias_entries, 1, -1 do
                    aliases[alias_entries[index][1]] =
                        alias_entries[index][2]
                end
            else
                for index = 1, #alias_entries do
                    aliases[alias_entries[index][1]] =
                        alias_entries[index][2]
                end
            end
            local modtype = source_module(
                name, public_members, {},
                { generic_callable, nominal_member, foreign }, aliases)
            return source_entry(name, modtype, { dependency }), aggregate
        end

        local first, first_aggregate = complex_entry(false, 32)
        local second, second_aggregate = complex_entry(true, 32)
        assert.not_equal(first_aggregate, second_aggregate)
        assert.equal(first_aggregate, first_aggregate.fields[1].owner)
        assert.equal(first_aggregate,
            first_aggregate.fields[1].type.pointee)
        local expected = source_manifest(first)
        collectgarbage("collect")
        assert.equal(expected, source_manifest(second))

        local changed = complex_entry(false, 64)
        assert.not_equal(expected, source_manifest(changed))
    end)

    it("rejects malformed resolver caches at their public loader boundary",
    function()
        local context = driver.new_resolver_context()
        local function construction_error(options, expected)
            options.context = context
            local called, err = pcall(driver.defaultloader, {}, options)
            assert.is_false(called)
            assert.matches(expected, tostring(err), 1, true)
        end
        construction_error({ known_source_modules = "invalid" },
            "known_source_modules must be a module-keyed table")
        construction_error({ cached_source_entries = "invalid" },
            "cached_source_entries must be a module-keyed table")
        construction_error({ cached_interfaces = "invalid" },
            "cached_interfaces must be a module-keyed table")
        construction_error({ after_source_check = function() end },
            "after_source_check is no longer supported")
        construction_error({
            known_source_modules = { ["invalid module"] = true },
        }, "known_source_modules must contain valid module names mapped to true")

        local known_loader = driver.defaultloader({}, {
            context = context,
            known_source_modules = { cache_known_source = true },
        })
        assert.is_true(context.source_modules.cache_known_source)
        assert.is_true(driver.close_loader(known_loader))

        local function interface_error(index, candidate, source_required,
                expected)
            local name = "cache_interface_" .. index
            local options = {
                context = context,
                cached_interfaces = { [name] = candidate },
            }
            if source_required then options.source_roots = { [name] = true } end
            local loader = driver.defaultloader({}, options)
            local ok, err = loader(name)
            assert.is_false(ok)
            assert.matches(expected, tostring(err), 1, true)
            assert.is_true(driver.close_loader(loader))
        end
        local function manifest(name)
            return types.serialize(types.Module(name, {}))
        end

        interface_error(1, "invalid", false, "must be a table")
        interface_error(2, {
            filename = root .. "/cache-interface-2.titan",
        }, false, "has no serialized manifest")
        interface_error(3, {
            serialized = manifest("cache_interface_3"),
            filename = "",
        }, false, "has no source filename")
        interface_error(4, {
            serialized = manifest("cache_interface_4"),
            filename = root .. "/cache-interface-4.titan",
            source_files = "invalid",
        }, false, "source_files must be a dense ordered string array")
        interface_error(5, {
            serialized = manifest("cache_interface_5"),
            filename = root .. "/cache-interface-5.titan",
            source_files = { "" },
        }, false, "source_files entry 1 must be a nonempty string")
        interface_error(6, {
            serialized = manifest("cache_interface_6"),
            filename = root .. "/cache-interface-6.titan",
            source_files = {
                root .. "/cache-interface-6.titan",
                extra = true,
            },
        }, false, "source_files must be a dense ordered string array")
        interface_error(7, {
            serialized = manifest("cache_interface_7"),
            filename = root .. "/cache-interface-7.titan",
            dependencies = { "invalid dependency" },
        }, false, "has invalid dependency name")
        interface_error(8, {
            serialized = "not valid Titan type metadata",
            filename = root .. "/cache-interface-8.titan",
        }, false, "invalid cached interface")

        interface_error(9, "invalid", true, "must be a table")
        interface_error(10, {
            filename = root .. "/cache-interface-10.titan",
        }, true, "has no serialized manifest")
        interface_error(11, {
            serialized = manifest("cache_interface_11"),
            filename = "",
        }, true, "has no source filename")
        interface_error(12, {
            serialized = manifest("cache_interface_12"),
            filename = root .. "/cache-interface-12.titan",
            source_files = {
                root .. "/not-the-main-source.titan",
                root .. "/cache-interface-12.titan",
            },
        }, true, "must list its main source filename first")

        local function cached_source(name, ast, deps)
            local filename = root .. "/" .. name .. ".titan"
            local entry = {
                kind = "source",
                ast = ast or {},
                type = source_module(name),
                filename = filename,
                source_files = { filename },
                deps = deps or {},
                c_header_dependencies = {},
            }
            entry.source_manifest = source_manifest(entry)
            return entry
        end
        local function source_entry_error(name, candidate, expected)
            local loader = driver.defaultloader({}, {
                context = context,
                cached_source_entries = { [name] = candidate },
            })
            local ok, err = loader(name)
            assert.is_false(ok)
            assert.matches(expected, tostring(err), 1, true)
            assert.is_true(driver.close_loader(loader))
        end
        source_entry_error("cache_source_invalid", {},
            "is not a complete checked source module")
        local missing_manifest = cached_source("cache_source_no_manifest")
        missing_manifest.source_manifest = nil
        source_entry_error("cache_source_no_manifest", missing_manifest,
            "is not a complete checked source module")

        local public_only = cached_source("cache_source_public_only")
        public_only.type = types.Module("cache_source_public_only", {})
        source_entry_error("cache_source_public_only", public_only,
            "is not a complete checked source module")

        local holey_sources = cached_source("cache_source_holey_files")
        holey_sources.source_files = {
            [1] = holey_sources.filename,
            [3] = root .. "/cache-source-part.titan",
        }
        source_entry_error("cache_source_holey_files", holey_sources,
            "is not a complete checked source module")

        local invalid_deps = cached_source("cache_source_bad_deps")
        invalid_deps.deps = { ["invalid dependency"] = true }
        source_entry_error("cache_source_bad_deps", invalid_deps,
            "has an invalid dependency map")

        local child_name = "cache_nested_child"
        local parent_name = "cache_nested_parent"
        local import_child = {
            _tag = "Ast.TopLevelImport",
            _source_import = true,
            modname = child_name,
        }
        local child = cached_source(child_name)
        local parent = cached_source(parent_name, { import_child }, {
            [child_name] = true,
        })
        local nested_loader = driver.defaultloader({}, {
            context = context,
            cached_source_entries = {
                [parent_name] = parent,
                [child_name] = child,
            },
        })
        local nested_ok, nested_type, nested_errors = nested_loader(parent_name)
        assert.truthy(nested_ok)
        assert.equal(parent.type, nested_type)
        assert.same({}, nested_errors)
        assert.equal(child, driver.imported[child_name])
        assert.equal(parent, driver.imported[parent_name])
        assert.is_true(driver.close_loader(nested_loader))

        local cycle_a_name = "cache_cycle_a"
        local cycle_b_name = "cache_cycle_b"
        local cycle_a = cached_source(cycle_a_name, {{
            _tag = "Ast.TopLevelImport",
            _source_import = true,
            modname = cycle_b_name,
        }}, { [cycle_b_name] = true })
        local cycle_b = cached_source(cycle_b_name, {{
            _tag = "Ast.TopLevelImport",
            _source_import = true,
            modname = cycle_a_name,
        }}, { [cycle_a_name] = true })
        local cycle_loader = driver.defaultloader({}, {
            context = context,
            cached_source_entries = {
                [cycle_a_name] = cycle_a,
                [cycle_b_name] = cycle_b,
            },
        })
        local cycle_ok, cycle_error = cycle_loader(cycle_a_name)
        assert.is_false(cycle_ok)
        assert.matches("cached source entry cycle at module 'cache_cycle_a'",
            cycle_error, 1, true)
        assert.is_true(driver.close_loader(cycle_loader))

        local missing_parent_name = "cache_missing_parent"
        local missing_child_name = "cache_missing_child"
        local missing_parent = cached_source(missing_parent_name, {{
            _tag = "Ast.TopLevelImport",
            _source_import = true,
            modname = missing_child_name,
        }}, { [missing_child_name] = true })
        local missing_loader = driver.defaultloader({}, {
            context = context,
            cached_source_entries = {
                [missing_parent_name] = missing_parent,
            },
        })
        local missing_ok, missing_error = missing_loader(missing_parent_name)
        assert.is_false(missing_ok)
        assert.matches("requires clean source dependency 'cache_missing_child'",
            missing_error, 1, true)
        assert.is_true(driver.close_loader(missing_loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("validates cached C-header inputs and resolver option ownership",
    function()
        local result, err = driver.restat_c_header_dependencies("invalid")
        assert.is_nil(result)
        assert.equal("C header dependencies must be an ordered array", err)

        assert.has_error(function()
            driver.restat_c_header_dependencies({}, "invalid")
        end, "resolver options must be a table")
        assert.has_error(function()
            driver.restat_c_header_dependencies({}, { context = {} })
        end, "options.context must be a resolver context")

        local context = driver.new_resolver_context()
        local valid = {
            kind = "search",
            path = "/virtual/header.h",
            identity = "identity",
        }
        local cases = {
            { value = { "invalid" }, expected = "entry 1 must be a table" },
            {
                value = {{
                    kind = "invalid",
                    path = valid.path,
                    identity = valid.identity,
                }},
                expected = "kind must be 'file' or 'search'",
            },
            {
                value = {{
                    kind = valid.kind,
                    path = "relative.h",
                    identity = valid.identity,
                }},
                expected = "path must be an absolute NUL-free pathname",
            },
            {
                value = {{
                    kind = valid.kind,
                    path = valid.path,
                    identity = "",
                }},
                expected = "must have a nonempty identity",
            },
            {
                value = { valid, valid },
                expected = "repeats search input '/virtual/header.h'",
            },
            {
                value = { valid, extra = true },
                expected = "must be a dense ordered array",
            },
        }
        for _, case in ipairs(cases) do
            result, err = driver.restat_c_header_dependencies(
                case.value, context)
            assert.is_nil(result)
            assert.matches(case.expected, err, 1, true)
        end
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("reports every external topology outcome without retaining ASTs",
    function()
        assert.has_error(function()
            driver.resolve_external_modules("invalid")
        end, "external resolution requests must be a module-keyed table")
        assert.has_error(function()
            driver.resolve_external_modules({}, "invalid")
        end, "known_source_modules must be a module-keyed table")
        assert.has_error(function()
            driver.resolve_external_modules({}, {
                ["invalid module"] = true,
            })
        end, "known_source_modules must contain valid module names mapped to true")
        assert.has_error(function()
            driver.resolve_external_modules({ external_invalid = "yes" })
        end, "external resolution requests must contain valid module names " ..
            "mapped to booleans")

        local missing = driver.resolve_external_modules({
            external_missing = false,
        })
        assert.same({ kind = "missing" }, missing.external_missing)
        local source_missing = driver.resolve_external_modules({
            external_source_missing = true,
        })
        assert.equal("error", source_missing.external_source_missing.kind)
        assert.matches("source module 'external_source_missing' not found",
            source_missing.external_source_missing.message, 1, true)

        assert(lfs.mkdir(source .. "/external_folder"))
        write_file(source .. "/external_folder/external_folder.titan",
            "local value: integer = 1\n")
        write_file(source .. "/external_folder/child.titan",
            "local child: integer = 2\n")
        local blocked = driver.resolve_external_modules({
            ["external_folder.child"] = true,
        })
        assert.equal("error", blocked["external_folder.child"].kind)
        assert.matches("belongs to folder module 'external_folder'",
            blocked["external_folder.child"].message, 1, true)

        assert(lfs.mkdir(source .. "/external_bad_list"))
        write_file(source .. "/external_bad_list/external_bad_list.titan",
            "local value: integer = 1\n")
        local list_context = driver.new_resolver_context()
        function list_context.io:list(path)
            assert.equal(source .. "/external_bad_list", path)
            return "not an ordered list"
        end
        local listed = driver.resolve_external_modules({
            external_bad_list = true,
        }, {}, list_context)
        assert.equal("error", listed.external_bad_list.kind)
        assert.matches("invalid directory entries",
            listed.external_bad_list.message, 1, true)
        assert.is_true(driver.close_resolver_context(list_context))

        local provider_context = driver.new_resolver_context()
        function provider_context.io:lstat(path)
            assert.equal(binary .. "/external_broken.so", path)
            return nil, "injected provider inspection failure"
        end
        local broken = driver.resolve_external_modules({
            external_broken = false,
        }, {}, provider_context)
        assert.equal("error", broken.external_broken.kind)
        assert.matches("injected provider inspection failure",
            broken.external_broken.message, 1, true)
        assert.is_true(driver.close_resolver_context(provider_context))

        local original_close = driver.close_resolver_context
        driver.close_resolver_context = function()
            return nil, "injected external close failure"
        end
        local called, close_failure = pcall(
            driver.resolve_external_modules, {}, {}, {})
        driver.close_resolver_context = original_close
        assert.is_false(called)
        assert.matches("failed to close external resolver context",
            close_failure, 1, true)
        assert.matches("injected external close failure",
            close_failure, 1, true)
        assert.same({}, driver.imported)
    end)

    it("retains only physical contextual-provider provenance at finalization",
    function()
        local facade_name = "contextual_facade"
        local owner_name = "contextual_owner"
        local facade_type = types.Module(facade_name, {})
        local owner_type = types.Module(owner_name, {})
        local archive = root .. "/contextual-provider.a"
        local provider = {
            archive = archive,
            key_order = { facade_name, owner_name },
            entries = {
                [facade_name] = { type = facade_type },
                [owner_name] = { type = owner_type },
            },
        }
        driver.imported[facade_name] = {
            kind = "static",
            type = facade_type,
            static_archive = archive,
            static_provider = provider,
        }
        local context = driver.new_resolver_context()
        local loader = driver.defaultloader({}, { context = context })
        local ok, recovered, errors = loader(owner_name, {
            kind = "nominal-owner",
            exposer = facade_name,
        })
        assert.truthy(ok)
        assert.equal(owner_type, recovered)
        assert.same({}, errors)
        assert.is_nil(driver.imported[owner_name])

        local resolution_key, resolution = next(context.contextual_resolutions)
        assert.is_string(resolution_key)
        assert.equal(owner_name, resolution.owner)
        assert.equal(facade_name, resolution.exposer)
        assert.equal("static", resolution.kind)
        assert.equal(archive, resolution.provider_file)
        assert.equal(archive, resolution.exposer_file)
        assert.is_false(resolution.ordinary_lookup)

        assert.is_true(driver.close_loader(loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(resolution,
            context.contextual_resolutions[resolution_key])
        assert.is_true(driver.close_resolver_context(context))

        driver.imported = {}
        types.registry = {}
        local source_owner = types.Module("contextual_source_owner", {})
        local source_facade = types.Module("contextual_source_facade", {})
        local source_provider = {
            archive = root .. "/contextual-source-provider.a",
            key_order = { "contextual_source_facade" },
            entries = {
                contextual_source_facade = { type = source_facade },
            },
        }
        driver.imported.contextual_source_facade = {
            kind = "static",
            type = source_facade,
            static_archive = source_provider.archive,
            static_provider = source_provider,
        }
        driver.imported.contextual_source_owner = {
            kind = "source",
            type = source_owner,
            filename = root .. "/contextual-source-owner.titan",
            source_files = { root .. "/contextual-source-owner.titan" },
            deps = {},
        }
        local source_context = driver.new_resolver_context()
        local source_loader = driver.defaultloader({}, {
            context = source_context,
        })
        ok, recovered, errors = source_loader("contextual_source_owner", {
            kind = "nominal-owner",
            exposer = "contextual_source_facade",
        })
        assert.truthy(ok)
        assert.equal(source_owner, recovered)
        assert.same({}, errors)
        assert.same({}, source_context.contextual_resolutions)
        assert.is_true(driver.close_loader(source_loader))
        assert.is_true(driver.close_resolver_context(source_context))
    end)

    it("keeps unique source checking headers behind one public probe identity",
    function()
        write_file(source .. "/provider.h", "typedef int provider_int;\n")
        write_file(source .. "/provider.titan", [[
            local c = foreign import "provider.h"
            foreign function identity(input: c.provider_int): c.provider_int
                return input
            end
        ]])

        local function load_once()
            local loader = driver.defaultloader({}, {
                source_roots = { provider = true },
            })
            local ok, modtype, errors, info = loader("provider")
            assert.truthy(ok)
            assert.equal("Type.Module", modtype._tag)
            assert.equal(0, #errors)
            assert.equal(source .. "/provider.titan.h",
                info.foreign_header_probe_identity)
            assert.not_equal(info.foreign_header_probe_identity,
                info.foreign_header)
            assert.matches("provider[.]titan[.]h[.]check[.]tmp[.]",
                info.foreign_header)
            assert.equal("file", lfs.attributes(info.foreign_header, "mode"))
            local cached_ok, _, cached_errors, cached_info = loader("provider")
            assert.truthy(cached_ok)
            assert.equal(0, #cached_errors)
            assert.equal(info.foreign_header, cached_info.foreign_header)
            assert.equal(info.foreign_header_probe_identity,
                cached_info.foreign_header_probe_identity)
            assert.is_true(driver.close_loader(loader))
            assert.is_nil(lfs.symlinkattributes(info.foreign_header))
            return info.foreign_header
        end

        local first = load_once()
        driver.imported = {}
        types.registry = {}
        local second = load_once()
        assert.not_equal(first, second)
    end)

    it("cleans a source checking header when normalization is cancelled",
    function()
        write_file(source .. "/provider.h", "typedef int provider_int;\n")
        write_file(source .. "/provider.titan", [[
            local c = foreign import "provider.h"
            foreign function identity(input: c.provider_int): c.provider_int
                return input
            end
        ]])

        local strategy = compiler_io.new_sync()
        local ordinary_read_file = strategy.read_file
        local checking_header
        function strategy:read_file(path)
            if path:find(".titan.h.check.tmp.", 1, true) then
                checking_header = path
                error("simulated checking-header cancellation")
            end
            return ordinary_read_file(self, path)
        end
        local context = driver.new_resolver_context({ io = strategy })
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { provider = true },
        })

        local loaded, failure = pcall(loader, "provider")
        assert.is_false(loaded)
        assert.matches("simulated checking%-header cancellation", failure)
        assert.is_string(checking_header)
        assert.equal("file", lfs.attributes(checking_header, "mode"))

        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
        assert.is_nil(lfs.symlinkattributes(checking_header))
    end)

    it("absolutizes source checking headers from a relative cross-directory root",
    function()
        local cwd = assert(lfs.currentdir())
        local temporary_name = assert(os.tmpname())
        local suffix = assert(temporary_name:match("([^/]+)$"))
        assert(os.remove(temporary_name))
        local relative_root = ".driver-relative-" .. suffix
        assert(lfs.mkdir(relative_root))
        assert(lfs.mkdir(relative_root .. "/a"))
        assert(lfs.mkdir(relative_root .. "/b"))
        write_file(relative_root .. "/a/provider.h",
            "typedef int provider_int;\n")
        write_file(relative_root .. "/a/provider.titan", [[
            local c = foreign import "provider.h"
            foreign function identity(input: c.provider_int): c.provider_int
                return input
            end
        ]])
        write_file(relative_root .. "/b/consumer.titan", [[
            local provider = import "a.provider.titan"
            function read(): integer return 1 end
        ]])

        local loader
        local ran, failure = pcall(function()
            driver.TITAN_SOURCE_PATH = relative_root
            loader = driver.defaultloader({}, {
                source_roots = { ["b.consumer"] = true },
            })
            local ok, _, errors = loader("b.consumer")
            assert.truthy(ok)
            assert.equal(0, #errors, table.concat(errors, "\n"))
            local provider = assert(driver.imported["a.provider"])
            local physical = assert(provider.checking_foreign_header)
            assert.equal("/", physical:sub(1, 1))
            assert.equal("file", lfs.attributes(physical, "mode"))
            local import = driver.imported["b.consumer"].ast[1]
            assert.equal(physical, import._foreign_header)
            assert.equal(cwd .. "/" .. relative_root ..
                "/a/provider.titan.h",
                import._foreign_header_probe_identity)
            assert.is_true(driver.close_loader(loader))
            loader = nil
            assert.is_nil(lfs.symlinkattributes(physical))
        end)
        if loader then driver.close_loader(loader) end
        remove_tree(relative_root)
        assert.truthy(ran, failure)
    end)

    it("uses binaries for dependencies and source for explicit roots", function()
        assert(lfs.mkdir(source .. "/titan/timer"))
        write_file(source .. "/titan/timer/timer.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(binary .. "/titan/timer.so", "mock interface\n")

        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan/timer.so", filename)
            symbols[#symbols + 1] = symbol
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "titan_timer_abi", "titan_timer_types" }, symbols)
        assert.is_nil(driver.imported["titan.timer"].ast)

        -- A later explicit build request replaces a cached binary interface
        -- with the source root instead of silently treating compilation as a
        -- no-op.
        local deps = {}
        ok, modtype, errors = driver.defaultloader(deps, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.timer"].ast)
        assert.equal(true, deps["titan.timer"])
        assert.equal(source .. "/titan/timer/timer.titan",
            driver.imported["titan.timer"].filename)
        assert.equal("titan/timer__main",
            driver.imported["titan.timer"].program_output)
    end)

    it("canonically resolves explicit-source imports to flat and folder source",
    function()
        assert(lfs.mkdir(source .. "/pkg"))
        assert(lfs.mkdir(source .. "/pkg/folder"))
        assert(lfs.mkdir(binary .. "/pkg"))
        write_file(source .. "/pkg/flat.titan", [[
            local function answer(): integer return 20 end
        ]])
        write_file(source .. "/pkg/folder/folder.titan", [[
            local function answer(): integer return 22 end
        ]])
        write_file(source .. "/consumer.titan", [[
            local flat = import "pkg.flat.titan"
            local folder = import "pkg.folder.titan"
            function answer(): integer
                return flat.answer() + folder.answer()
            end
        ]])

        local compiled_flat = types.Module("pkg.flat", {}, {})
        cache_dynamic_provider(binary .. "/pkg/flat.so", {
            ["pkg.flat"] = compiled_flat,
        })
        write_file(binary .. "/pkg/folder.so",
            "explicit source lookup must not inspect this provider\n")

        local loader = driver.defaultloader({}, {
            source_roots = { consumer = true },
        })
        local ok, modtype, errors, info = loader("pkg.flat")
        assert.truthy(ok)
        assert.equal("pkg.flat", modtype.name)
        assert.equal(0, #errors)
        assert.equal("dynamic", info.kind)

        ok, _, errors = loader("consumer")
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("source", driver.imported["pkg.flat"].kind)
        assert.equal(source .. "/pkg/flat.titan",
            driver.imported["pkg.flat"].filename)
        assert.equal("source", driver.imported["pkg.folder"].kind)
        assert.equal(source .. "/pkg/folder/folder.titan",
            driver.imported["pkg.folder"].filename)
        assert.is_nil(driver.imported["pkg.flat.titan"])
        assert.is_nil(driver.imported["pkg.folder.titan"])

        local imports = driver.imported.consumer.ast
        assert.equal("pkg.flat", imports[1].modname)
        assert.is_true(imports[1].source_required)
        assert.is_true(imports[1]._source_import)
        assert.equal("pkg.folder", imports[2].modname)
        assert.is_true(imports[2].source_required)
        assert.is_true(imports[2]._source_import)
    end)

    it("fingerprints external providers and complete folder topology without ASTs",
    function()
        assert(lfs.mkdir(source .. "/vendor"))
        assert(lfs.mkdir(source .. "/vendor/pkg"))
        local main = source .. "/vendor/pkg/pkg.titan"
        local part = source .. "/vendor/pkg/part.titan"
        write_file(main, "local main_value: integer = 1\n")
        write_file(part, "local part_value: integer = 2\n")

        local compiled = types.Module("vendor.pkg", {}, {})
        local provider = binary .. "/vendor.so"
        cache_dynamic_provider(provider, {
            ["vendor.pkg"] = compiled,
        })

        local strategy = compiler_io.new_sync()
        local observed = { stat = {}, lstat = {}, list = {} }
        for _, method in ipairs({ "stat", "lstat", "list" }) do
            local original = strategy[method]
            strategy[method] = function(self, path, ...)
                observed[method][path] =
                    (observed[method][path] or 0) + 1
                return original(self, path, ...)
            end
        end
        local context = driver.new_resolver_context({ io = strategy })

        local ordinary = driver.resolve_external_modules({
            ["vendor.pkg"] = false,
        }, {
            app = true,
        }, { context = context })
        assert.same({
            kind = "dynamic",
            provider_file = provider,
        }, ordinary["vendor.pkg"])

        local explicit_source = driver.resolve_external_modules({
            ["vendor.pkg"] = true,
        }, {
            app = true,
        }, context)
        assert.same({
            kind = "source",
            main_file = main,
            source_files = { main, part },
        }, explicit_source["vendor.pkg"])
        assert.is_true((observed.lstat[provider] or 0) > 0)
        assert.is_true((observed.stat[main] or 0) > 0)
        assert.is_true((observed.stat[part] or 0) > 0)
        assert.is_true((observed.list[source .. "/vendor/pkg"] or 0) > 0)
        assert.same({}, driver.imported)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects source replacement after using a different compiled interface",
    function()
        local compiled_provider = types.Module("provider", {
            types.ModuleMember("provider", "answer",
                types.Function({}, { types.Integer() }, false, false, false),
                {}),
        })
        cache_dynamic_provider(binary .. "/provider.so", {
            provider = compiled_provider,
        })
        write_file(source .. "/provider.titan", [[
            function answer(): string return "source" end
        ]])
        write_file(source .. "/ordinary_root.titan", [[
            local provider = import "provider"
            function answer(): integer return provider.answer() end
        ]])
        write_file(source .. "/source_root.titan", [[
            local provider = import "provider.titan"
            function answer(): string return provider.answer() end
        ]])

        local loader = driver.defaultloader({}, {
            source_roots = {
                ordinary_root = true,
                source_root = true,
            },
        })
        local ok, result, errors = loader("ordinary_root")
        assert.truthy(ok, result)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("dynamic", driver.imported.provider.kind)

        ok, result, errors = loader("source_root")
        assert.truthy(ok, result)
        assert.equal(1, #errors)
        assert.equal("source module 'provider' does not match a compiled " ..
            "interface already used in this compilation", errors[1])
        assert.equal("source", driver.imported.provider.kind)
    end)

    it("does not fall back to a cached compiled provider for an " ..
       "explicit-source import", function()
        local compiled = types.Module("compiled_only", {}, {})
        cache_dynamic_provider(binary .. "/compiled_only.so", {
            compiled_only = compiled,
        })
        write_file(source .. "/consumer.titan", [[
            local ordinary = import "compiled_only"
            local required = import "compiled_only.titan"
            function answer(): integer return 42 end
        ]])

        local loader = driver.defaultloader({}, {
            source_roots = { consumer = true },
        })
        local ok, _, errors = loader("consumer")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match("source module 'compiled_only' not found",
            errors[1], 1, true)
        assert.equal("dynamic", driver.imported.compiled_only.kind)
    end)

    it("prefers source throughout a source-first invocation", function()
        write_file(source .. "/preferred.titan", [[
            function marker(): integer
                return 7
            end
        ]])
        write_file(binary .. "/preferred.so", "broken binary that must not open\n")
        titan._loadlib = function()
            error("source-first lookup must not probe an occupied binary")
        end

        local context = driver.new_resolver_context({ source_first = true })
        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("preferred")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("source", driver.imported.preferred.kind)
        assert.equal(source .. "/preferred.titan",
            driver.imported.preferred.filename)
    end)

    it("falls back to the preferred compiled format after a source miss",
       function()
        write_file(binary .. "/fallback.so", "mock interface\n")
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/fallback.so", filename)
            if symbol == "fallback_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "fallback_types" then
                return function() return "Module('fallback',{})" end
            end
            error("unexpected symbol " .. symbol)
        end

        local context = driver.new_resolver_context({ source_first = true })
        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("fallback")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported.fallback.kind)
    end)

    it("honors static preference after a source-first miss", function()
        local context = driver.new_resolver_context({
            source_first = true,
            prefer_static = true,
        })
        local archive = binary .. "/fallback_static.a"
        cache_static_provider(context, archive, {
            fallback_static = types.Module("fallback_static", {}, {}),
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("fallback_static")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported.fallback_static.kind)
        assert.equal(archive, driver.imported.fallback_static.filename)
    end)

    it("skips a static provider that overlaps a forced source", function()
        local context = driver.new_resolver_context({
            source_first = true,
            prefer_static = true,
        })
        local archive = binary .. "/fallback_static.a"
        cache_static_provider(context, archive, {
            fallback_static = types.Module("fallback_static", {}, {}),
            ["titan.test"] = types.Module("titan.test", {}, {}),
        })
        write_file(binary .. "/fallback_static.so", "mock interface\n")
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/fallback_static.so", filename)
            if symbol == "fallback_static_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "fallback_static_types" then
                return function()
                    return "Module('fallback_static',{})"
                end
            end
            error("unexpected symbol " .. symbol)
        end

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
            source_overrides = { ["titan.test"] = {} },
        })("fallback_static")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported.fallback_static.kind)
    end)

    it("rejects a static provider while recursively checking a carried source",
       function()
        assert(lfs.mkdir(source .. "/bundle"))
        write_file(source .. "/root.titan", [[
            local later = import "bundle.later"
        ]])
        write_file(source .. "/bundle/later.titan", [[
            local fallback = import "bundle.fallback"
        ]])

        local context = driver.new_resolver_context({
            source_first = true,
            prefer_static = true,
        })
        local fallback_type = types.Module("bundle.fallback", {}, {})
        local later_type = types.Module("bundle.later", {}, {})
        cache_static_provider(context, binary .. "/bundle.a", {
            ["bundle.fallback"] = fallback_type,
            ["bundle.later"] = later_type,
        })
        cache_dynamic_provider(binary .. "/bundle.so", {
            ["bundle.fallback"] = fallback_type,
        })

        local ok, _, errors = driver.defaultloader({}, {
            context = context,
            source_roots = { root = true },
        })("root")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("source", driver.imported["bundle.later"].kind)
        assert.equal("dynamic", driver.imported["bundle.fallback"].kind)
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized, table.concat(finalize_errors or {}, "\n"))
        assert.equal(0, #context.selected_static_providers)
    end)

    it("rebinds an earlier static selection when a later source overlaps it",
       function()
        assert(lfs.mkdir(source .. "/bundle"))
        write_file(source .. "/root.titan", [[
            local fallback = import "bundle.fallback"
            local later = import "bundle.later"
        ]])
        write_file(source .. "/bundle/later.titan", [[
            local marker: integer = 1
        ]])

        local context = driver.new_resolver_context({
            source_first = true,
            prefer_static = true,
        })
        local fallback_type = types.Module("bundle.fallback", {}, {})
        local later_type = types.Module("bundle.later", {}, {})
        cache_static_provider(context, binary .. "/bundle.a", {
            ["bundle.fallback"] = fallback_type,
            ["bundle.later"] = later_type,
        })
        cache_dynamic_provider(binary .. "/bundle.so", {
            ["bundle.fallback"] = fallback_type,
        })

        local static_deps = {}
        local ok, _, errors = driver.defaultloader(static_deps, {
            context = context,
            source_roots = { root = true },
        })("root")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported["bundle.fallback"].kind)
        assert.equal("bundle.so", driver.imported["bundle.fallback"].type.file)
        assert.equal("source", driver.imported["bundle.later"].kind)
        assert.is_nil(static_deps["bundle.fallback"])
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized, table.concat(finalize_errors or {}, "\n"))
        assert.equal(0, #context.selected_static_providers)
    end)

    it("treats a blocked source as terminal before compiled lookup", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan", "local owner: integer = 1\n")
        write_file(folder .. "/child.titan", "local constituent: integer = 1\n")
        write_file(binary .. "/titan/sample.so", "occupied binary\n")
        titan._loadlib = function()
            error("blocked source must be terminal before compiled lookup")
        end

        local context = driver.new_resolver_context({ source_first = true })
        local ok, message = driver.defaultloader({}, {
            context = context,
        })("titan.sample.child")
        assert.falsy(ok)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.match("cannot be loaded directly", message, 1, true)
    end)

    it("checks generated source overrides with ordinary source provenance",
       function()
        local filename = root .. "/generated-suite.titan"
        local descriptor = {
            kind = "generated",
            main = filename,
            files = { filename },
            contents = {
                [filename] = [[
                    function answer(): integer
                        return 42
                    end
                ]],
            },
            program_output = root .. "/generated-suite",
        }
        local deps = {}
        local ok, modtype, errors = driver.defaultloader(deps, {
            source_overrides = { generated = descriptor },
        })("generated")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("source", driver.imported.generated.kind)
        assert.equal(filename, driver.imported.generated.filename)
        assert.equal(descriptor.program_output,
            driver.imported.generated.program_output)
        assert.equal(true, deps.generated)
        assert.is_nil(lfs.attributes(filename, "mode"))
    end)

    it("checks a dirty root against a cached clean source interface",
       function()
        local provider_type = types.Module("provider", {
            types.ModuleMember("provider", "answer",
                types.Function({}, { types.Integer() },
                    false, false, false), {}),
        })
        local filename = root .. "/dirty.titan"
        local descriptor = {
            kind = "generated",
            main = filename,
            files = { filename },
            contents = {
                [filename] = [[
                    local provider = import "provider"
                    function answer(): integer
                        return provider.answer()
                    end
                ]],
            },
        }
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            source_roots = { dirty = true },
            source_overrides = { dirty = descriptor },
            cached_interfaces = {
                provider = {
                    serialized = types.serialize(provider_type),
                    filename = root .. "/provider.titan",
                    source_files = {
                        root .. "/provider.titan",
                        root .. "/provider-part.titan",
                    },
                    dependencies = { "foundation" },
                    c_header_dependencies = {{
                        kind = "search",
                        path = root .. "/provider.h",
                        identity = "c-header-search-v1;lstat=missing;stat=missing",
                    }},
                },
            },
        })

        local ok, modtype, errors = loader("dirty")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_table(driver.imported.dirty.ast)
        assert.is_true(driver.imported.provider._cached_interface)
        assert.is_nil(driver.imported.provider.ast)
        assert.equal(root .. "/provider.titan",
            driver.imported.provider.filename)
        assert.same({
            root .. "/provider.titan",
            root .. "/provider-part.titan",
        }, driver.imported.provider.source_files)
        assert.same({ foundation = true }, driver.imported.provider.deps)
        assert.same({{
            kind = "search",
            path = root .. "/provider.h",
            identity = "c-header-search-v1;lstat=missing;stat=missing",
        }}, driver.imported.provider.c_header_dependencies)
        assert.same({
            dirty = true,
            provider = true,
            foundation = true,
        }, static_deps)
        assert.is_true(driver.close_loader(loader))
    end)

    it("prefers an available source override to a cached interface",
       function()
        local cached = types.Module("provider", {
            types.ModuleMember("provider", "cached_answer",
                types.Function({}, { types.Integer() },
                    false, false, false), {}),
        })
        local filename = root .. "/provider-generated.titan"
        local loader = driver.defaultloader({}, {
            source_roots = { provider = true },
            source_overrides = {
                provider = {
                    kind = "generated",
                    main = filename,
                    files = { filename },
                    contents = {
                        [filename] = [[
                            function source_answer(): integer return 42 end
                        ]],
                    },
                },
            },
            cached_interfaces = {
                provider = {
                    serialized = types.serialize(cached),
                    filename = root .. "/cached-provider.titan",
                },
            },
        })

        local ok, modtype, errors = loader("provider")
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_table(driver.imported.provider.ast)
        assert.is_nil(driver.imported.provider._cached_interface)
        assert.is_nil(modtype.members.cached_answer)
        assert.is_table(modtype.members.source_answer)
        assert.is_true(driver.close_loader(loader))
    end)

    it("reuses a seeded clean project AST for a source import", function()
        local provider_filename = root .. "/provider-generated.titan"
        local provider_descriptor = {
            kind = "generated",
            main = provider_filename,
            files = { provider_filename },
            contents = {
                [provider_filename] = [[
                    local function secret(): integer return 42 end
                ]],
            },
        }
        local provider_loader = driver.defaultloader({}, {
            source_roots = { provider = true },
            source_overrides = { provider = provider_descriptor },
        })
        local provider_ok, _, provider_errors = provider_loader("provider")
        assert.truthy(provider_ok)
        assert.equal(0, #provider_errors,
            table.concat(provider_errors, "\n"))
        local retained = driver.imported.provider
        local retained_ast = retained.ast
        assert.is_true(driver.close_loader(provider_loader))

        -- The language server starts each dirty-root analysis with a fresh
        -- type registry, then supplies only unchanged project entries. A
        -- source import must reuse that full entry rather than falling back to
        -- the narrower serialized-interface seam or reparsing the file.
        driver.imported = {}
        types.registry = {}
        local consumer_filename = root .. "/consumer-generated.titan"
        local context = driver.new_resolver_context()
        local consumer_loader = driver.defaultloader({}, {
            context = context,
            source_roots = { consumer = true },
            source_overrides = {
                consumer = {
                    kind = "generated",
                    main = consumer_filename,
                    files = { consumer_filename },
                    contents = {
                        [consumer_filename] = [[
                            local provider = import "provider.titan"
                            function answer(): integer
                                return provider.secret()
                            end
                        ]],
                    },
                },
            },
            cached_source_entries = { provider = retained },
        })

        local consumer_ok, _, consumer_errors = consumer_loader("consumer")
        assert.truthy(consumer_ok)
        assert.equal(0, #consumer_errors,
            table.concat(consumer_errors, "\n"))
        assert.equal(retained_ast, driver.imported.provider.ast)
        assert.same({ "consumer" }, context.checked_source_modules)
        assert.is_true(driver.imported.consumer.ast[1]._source_import)
        assert.is_true(driver.close_loader(consumer_loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("transiently rechecks a source-required external dependency of a " ..
       "cached project AST", function()
        local external_filename = source .. "/external.titan"
        write_file(external_filename, [[
            local function secret(): integer return 41 end
            function public_answer(): integer return secret() end
        ]])
        local provider_filename = root .. "/provider-external.titan"
        local provider_loader = driver.defaultloader({}, {
            source_roots = { provider = true },
            source_overrides = {
                provider = {
                    kind = "generated",
                    main = provider_filename,
                    files = { provider_filename },
                    contents = {
                        [provider_filename] = [[
                            local external = import "external.titan"
                            local function answer(): integer
                                return external.secret()
                            end
                        ]],
                    },
                },
            },
        })
        local provider_ok, _, provider_errors = provider_loader("provider")
        assert.truthy(provider_ok)
        assert.equal(0, #provider_errors,
            table.concat(provider_errors, "\n"))
        local retained = driver.imported.provider
        local retained_ast = retained.ast
        local external_type = driver.imported.external.type
        local first_external_ast = driver.imported.external.ast
        assert.is_true(driver.close_loader(provider_loader))

        driver.imported = {}
        types.registry = {}
        local consumer_filename = root .. "/consumer-external.titan"
        local context = driver.new_resolver_context()
        local consumer_loader = driver.defaultloader({}, {
            context = context,
            source_roots = { consumer = true },
            source_overrides = {
                consumer = {
                    kind = "generated",
                    main = consumer_filename,
                    files = { consumer_filename },
                    contents = {
                        [consumer_filename] = [[
                            local external = import "external"
                            local provider = import "provider.titan"
                            function result(): integer
                                return external.public_answer() +
                                    provider.answer() - 40
                            end
                        ]],
                    },
                },
            },
            cached_source_entries = { provider = retained },
            cached_interfaces = {
                external = {
                    serialized = types.serialize(external_type),
                    filename = external_filename,
                    source_files = { external_filename },
                    dependencies = {},
                },
            },
        })

        local consumer_ok, _, consumer_errors = consumer_loader("consumer")
        assert.truthy(consumer_ok)
        assert.equal(0, #consumer_errors,
            table.concat(consumer_errors, "\n"))
        assert.equal(retained_ast, driver.imported.provider.ast)
        assert.not_equal(first_external_ast, driver.imported.external.ast)
        assert.same({ "external", "consumer" },
            context.checked_source_modules)
        assert.is_nil(driver.imported.external._cached_interface)
        assert.is_true(driver.imported.external.ast[1].islocal)
        assert.is_true(driver.close_loader(consumer_loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rehydrates cached project foreign headers per resolver", function()
        local provider_filename = root .. "/ffi-provider-generated.titan"
        local provider_loader = driver.defaultloader({}, {
            source_roots = { ffi_provider = true },
            source_overrides = {
                ffi_provider = {
                    kind = "generated",
                    main = provider_filename,
                    files = { provider_filename },
                    contents = {
                        [provider_filename] = [[
                            local c = foreign import "stdint.h"
                            foreign function identity(
                                    input: c.int32_t): c.int32_t
                                return input
                            end
                        ]],
                    },
                },
            },
        })
        local provider_ok, _, provider_errors =
            provider_loader("ffi_provider")
        assert.truthy(provider_ok)
        assert.equal(0, #provider_errors,
            table.concat(provider_errors, "\n"))
        local retained = driver.imported.ffi_provider
        local retained_ast = retained.ast
        local old_header = assert(retained.checking_foreign_header)
        assert.equal("file", lfs.attributes(old_header, "mode"))
        assert.is_true(driver.close_loader(provider_loader))
        assert.is_nil(lfs.symlinkattributes(old_header))

        driver.imported = {}
        types.registry = {}
        local consumer_filename = root .. "/ffi-consumer-generated.titan"
        local context = driver.new_resolver_context()
        local consumer_loader = driver.defaultloader({}, {
            context = context,
            source_roots = { ffi_consumer = true },
            source_overrides = {
                ffi_consumer = {
                    kind = "generated",
                    main = consumer_filename,
                    files = { consumer_filename },
                    contents = {
                        [consumer_filename] = [[
                            local provider =
                                import "ffi_provider.titan"
                            function answer(): integer return 42 end
                        ]],
                    },
                },
            },
            cached_source_entries = { ffi_provider = retained },
        })

        local consumer_ok, _, consumer_errors =
            consumer_loader("ffi_consumer")
        assert.truthy(consumer_ok)
        assert.equal(0, #consumer_errors,
            table.concat(consumer_errors, "\n"))
        local fresh_header =
            driver.imported.ffi_provider.checking_foreign_header
        assert.not_equal(old_header, fresh_header)
        assert.equal("file", lfs.attributes(fresh_header, "mode"))
        assert.equal(retained_ast, driver.imported.ffi_provider.ast)
        assert.same({ "ffi_consumer" }, context.checked_source_modules)
        assert.equal(fresh_header,
            driver.imported.ffi_consumer.ast[1]._foreign_header)
        assert.is_true(driver.close_loader(consumer_loader))
        assert.is_true(driver.close_resolver_context(context))
        assert.is_nil(lfs.symlinkattributes(fresh_header))
    end)

    it("publishes each source module before the cooperative I/O checkpoint",
       function()
        local dep_filename = root .. "/dep-generated.titan"
        local main_filename = root .. "/main-generated.titan"
        local strategy = compiler_io.new_sync()
        local yielded_modules = {}
        function strategy:yield(module_name)
            yielded_modules[#yielded_modules + 1] = module_name
            coroutine.yield()
        end
        local context = driver.new_resolver_context({ io = strategy })
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { main = true },
            source_overrides = {
                dep = {
                    kind = "generated",
                    main = dep_filename,
                    files = { dep_filename },
                    contents = {
                        [dep_filename] = [[
                            function answer(): integer return 42 end
                        ]],
                    },
                },
                main = {
                    kind = "generated",
                    main = main_filename,
                    files = { main_filename },
                    contents = {
                        [main_filename] = [[
                            local dep = import "dep"
                            function answer(): integer return dep.answer() end
                        ]],
                    },
                },
            },
        })
        local thread = coroutine.create(function()
            return loader("main")
        end)

        local resumed, yielded = coroutine.resume(thread)
        assert.truthy(resumed, yielded)
        assert.is_nil(yielded)
        assert.equal("suspended", coroutine.status(thread))
        assert.same({ "dep" }, context.checked_source_modules)
        assert.same({ "dep" }, yielded_modules)
        assert.is_table(driver.imported.dep.ast)
        assert.equal("Ast.TopLevelFunc", driver.imported.dep.ast[1]._tag)
        assert.equal(dep_filename,
            driver.imported.dep.ast[1].loc.filename)
        assert.same({ dep_filename }, driver.imported.dep.source_files)

        resumed, yielded = coroutine.resume(thread)
        assert.truthy(resumed, yielded)
        assert.is_nil(yielded)
        assert.same({ "dep", "main" }, context.checked_source_modules)
        assert.same({ "dep", "main" }, yielded_modules)
        assert.is_table(driver.imported.main.ast)

        local ok, modtype, errors
        resumed, ok, modtype, errors = coroutine.resume(thread)
        assert.truthy(resumed, ok)
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("dead", coroutine.status(thread))
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("uses project FFI include roots without changing global configuration",
       function()
        local include_root = root .. "/project-include"
        assert(lfs.mkdir(include_root))
        write_file(include_root .. "/vscode_titan_project_only.h", [[
            typedef int vscode_titan_project_only_int;
        ]])
        local filename = root .. "/foreign-generated.titan"
        local descriptor = {
            kind = "generated",
            main = filename,
            files = { filename },
            contents = {
                [filename] = [[
                    local c = foreign import "vscode_titan_project_only.h"
                    function answer(): integer return 42 end
                ]],
            },
        }
        local global_includes = driver.foreign_include_dirs()

        local missing_loader = driver.defaultloader({}, {
            source_roots = { foreign_generated = true },
            source_overrides = { foreign_generated = descriptor },
        })
        local missing_ok, _, missing_errors =
            missing_loader("foreign_generated")
        assert.truthy(missing_ok)
        assert.equal(1, #missing_errors)
        assert.match("failed preprocessing 'vscode_titan_project_only.h'",
            missing_errors[1], 1, true)
        assert.is_true(driver.close_loader(missing_loader))

        driver.imported = {}
        types.registry = {}
        local configured_loader = driver.defaultloader({}, {
            source_roots = { foreign_generated = true },
            source_overrides = { foreign_generated = descriptor },
            extra_ffi_include_dirs = { include_root },
        })
        local configured_ok, _, configured_errors =
            configured_loader("foreign_generated")
        assert.truthy(configured_ok)
        assert.equal(0, #configured_errors,
            table.concat(configured_errors, "\n"))
        assert.same(global_includes, driver.foreign_include_dirs())
        assert.is_true(driver.close_loader(configured_loader))
    end)

    it("publishes and restats resolved transitive C header inputs", function()
        local early = root .. "/ffi-early"
        local late = root .. "/ffi-late"
        assert(lfs.mkdir(early))
        assert(lfs.mkdir(late))
        local outer = root .. "/ffi-outer.h"
        local early_selected = early .. "/ffi-selected.h"
        local late_selected = late .. "/ffi-selected.h"
        local late_contents =
            "typedef int titan_driver_selected_header;\n"
        write_file(outer, "#include <ffi-selected.h>\n")
        write_file(late_selected, late_contents)
        local filename = root .. "/ffi-metadata.titan"
        local loader = driver.defaultloader({}, {
            source_roots = { ffi_metadata = true },
            source_overrides = {
                ffi_metadata = {
                    kind = "generated",
                    main = filename,
                    files = { filename },
                    contents = {
                        [filename] = [[
                            local c = foreign import "ffi-outer.h"
                            function answer(): integer return 42 end
                        ]],
                    },
                },
            },
            extra_ffi_include_dirs = { early, late },
        })
        local ok, _, errors = loader("ffi_metadata")
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local observed = driver.imported.ffi_metadata.c_header_dependencies
        local function identity(inputs, kind, path)
            for _, input in ipairs(inputs) do
                if input.kind == kind and input.path == path then
                    return input.identity
                end
            end
        end
        assert.is_string(identity(observed, "file", outer))
        assert.is_string(identity(observed, "file", late_selected))
        assert.is_string(identity(observed, "search", outer))
        assert.matches("stat=missing",
            identity(observed, "search", early_selected), 1, true)
        assert.matches("stat=file",
            identity(observed, "search", late_selected), 1, true)
        local restat_io = compiler_io.new_sync()
        local read_paths = {}
        local original_read = restat_io.read_file
        function restat_io:read_file(path)
            read_paths[path] = (read_paths[path] or 0) + 1
            return original_read(self, path)
        end
        assert.same(observed,
            assert(driver.restat_c_header_dependencies(
                observed, { io = restat_io })))
        assert.is_true((read_paths[outer] or 0) > 0)
        assert.is_true((read_paths[late_selected] or 0) > 0)

        write_file(late_selected,
            "typedef long titan_driver_selected_header;\n")
        local restat_context =
            driver.new_resolver_context({ io = restat_io })
        local nested_changed =
            assert(driver.restat_c_header_dependencies(
                observed, restat_context))
        assert.not_equal(
            identity(observed, "file", late_selected),
            identity(nested_changed, "file", late_selected))

        write_file(late_selected, late_contents)
        write_file(early_selected,
            "typedef short titan_driver_selected_header;\n")
        local shadowed = assert(
            driver.restat_c_header_dependencies(
                observed, { context = restat_context }))
        assert.not_equal(
            identity(observed, "search", early_selected),
            identity(shadowed, "search", early_selected))
        assert.is_true(driver.close_resolver_context(restat_context))
        assert.is_true(driver.close_loader(loader))
    end)

    it("restats exact symlinked include spellings after retargeting",
    function()
        local first = root .. "/ffi-link-first"
        local second = root .. "/ffi-link-second"
        local lexical = root .. "/include"
        local link = root .. "/ffi-sdk-link"
        local outer = root .. "/ffi-link-outer.h"
        local selected_lookup = link .. "/../include/ffi-selected.h"
        local selected_contents = [[
#define TITAN_LINK_VALUE 42
typedef int titan_driver_symlink_value;
]]

        local loader
        local completed, failure = pcall(function()
            assert(lfs.mkdir(first))
            assert(lfs.mkdir(first .. "/nested"))
            assert(lfs.mkdir(first .. "/include"))
            assert(lfs.mkdir(second))
            assert(lfs.mkdir(second .. "/nested"))
            assert(lfs.mkdir(second .. "/include"))
            assert(lfs.mkdir(lexical))
            assert(lfs.link("ffi-link-first/nested", link, true))
            write_file(outer, "#include <ffi-selected.h>\n")
            write_file(first .. "/include/ffi-selected.h", selected_contents)
            write_file(second .. "/include/ffi-selected.h", selected_contents)
            write_file(lexical .. "/ffi-selected.h", [[
#define TITAN_LINK_VALUE 17
typedef double titan_driver_symlink_value;
]])

            local filename = root .. "/ffi-link-metadata.titan"
            loader = driver.defaultloader({}, {
                source_roots = { ffi_link_metadata = true },
                source_overrides = {
                    ffi_link_metadata = {
                        kind = "generated",
                        main = filename,
                        files = { filename },
                        contents = {
                            [filename] = [[
                                local c = foreign import "ffi-link-outer.h"
                                function answer(): integer
                                    return c.TITAN_LINK_VALUE
                                end
                            ]],
                        },
                    },
                },
                extra_ffi_include_dirs = {
                    link .. "/../include",
                },
            })
            local ok, _, errors = loader("ffi_link_metadata")
            assert.truthy(ok)
            assert.equal(0, #errors, table.concat(errors, "\n"))

            local observed =
                driver.imported.ffi_link_metadata.c_header_dependencies
            local function identity(inputs, kind, path)
                for _, input in ipairs(inputs) do
                    if input.kind == kind and input.path == path then
                        return input.identity
                    end
                end
            end
            local first_file =
                identity(observed, "file", selected_lookup)
            local first_search =
                identity(observed, "search", selected_lookup)
            assert.is_string(first_file)
            assert.is_string(first_search)

            assert(os.remove(link))
            assert(lfs.link("ffi-link-second/nested", link, true))
            local restatted = assert(
                driver.restat_c_header_dependencies(observed))
            assert.not_equal(first_file,
                identity(restatted, "file", selected_lookup))
            assert.not_equal(first_search,
                identity(restatted, "search", selected_lookup))
        end)
        if loader then pcall(driver.close_loader, loader) end
        local removed, remove_error = true
        if lfs.symlinkattributes(link) then
            removed, remove_error = os.remove(link)
        end
        assert.truthy(completed, failure)
        assert.truthy(removed, remove_error)
    end)

    it("keeps root precedence ahead of candidate shallowness", function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(first .. "/a"))
        assert(lfs.mkdir(first .. "/a/b"))
        write_file(first .. "/a/b/c.so", "earlier exact\n")
        write_file(second .. "/a.so", "later shallow\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        titan._loadlib = function(filename, symbol)
            assert.equal(first .. "/a/b/c.so", filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b/c.so", modtype.file)
        assert.equal(first .. "/a/b/c.so",
            driver.imported["a.b.c"].filename)
    end)

    it("applies the selected format preference globally across path roots",
       function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        local archive = first .. "/choice.a"
        local dynamic = second .. "/choice.so"
        write_file(dynamic, "later dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local static_context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(static_context, archive, {
            choice = types.Module("choice", {}),
        })
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic, filename)
            if symbol == "choice_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "choice_types" then
                return function() return "Module('choice',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local dynamic_context = driver.new_resolver_context()
        -- Seed the otherwise independent context too: the existing archive
        -- must be inspectable if the dynamic format pass fails.
        dynamic_context.provider_cache[archive] =
            static_context.provider_cache[archive]
        local ok, modtype, errors = driver.defaultloader({}, {
            context = dynamic_context,
        })("choice")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported.choice.kind)
        assert.equal("choice.so", modtype.file)
        assert.equal(dynamic, driver.imported.choice.filename)

        driver.imported = {}
        ok, modtype, errors = driver.defaultloader({}, {
            context = static_context,
        })("choice")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported.choice.kind)
        assert.equal("choice.so", modtype.file)
        assert.equal(archive, driver.imported.choice.static_archive)
    end)

    it("keeps root precedence ahead of archive candidate shallowness",
       function()
        local first = root .. "/first-static"
        local second = root .. "/second-static"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(first .. "/a"))
        assert(lfs.mkdir(first .. "/a/b"))
        local earlier_exact = first .. "/a/b/c.a"
        local later_shallow = second .. "/a.a"
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, earlier_exact, {
            ["a.b.c"] = types.Module("a.b.c", {}),
        })
        cache_static_provider(context, later_shallow, {
            ["a.b.c"] = types.Module("a.b.c", {}),
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b/c.so", modtype.file)
        assert.equal(earlier_exact,
            driver.imported["a.b.c"].static_archive)
        assert.equal("a/b/c.a", driver.imported["a.b.c"].relative)
    end)

    it("tracks occupied archive candidates independently and continues deeper",
       function()
        local first = root .. "/occupied-static"
        local second = root .. "/later-static"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(second .. "/a"))
        local earlier_nonclaim = first .. "/a.a"
        local shadowed_claim = second .. "/a.a"
        local unshadowed_claim = second .. "/a/b.a"
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, earlier_nonclaim, {})
        cache_static_provider(context, shadowed_claim, {
            ["a.b"] = types.Module("a.b", {}),
        })
        cache_static_provider(context, unshadowed_claim, {
            ["a.b"] = types.Module("a.b", {}),
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("a.b")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b.so", modtype.file)
        assert.equal(unshadowed_claim,
            driver.imported["a.b"].static_archive)
        assert.equal("a/b.a", driver.imported["a.b"].relative)
    end)

    it("does not let an occupied DSO pathname shadow an archive pathname",
       function()
        local first = root .. "/dynamic-occupancy"
        local second = root .. "/static-occupancy"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        local dynamic_nonclaim = first .. "/mixed.so"
        local archive = second .. "/mixed.a"
        write_file(dynamic_nonclaim, "unrelated dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context = driver.new_resolver_context()
        cache_static_provider(context, archive, {
            ["mixed.child"] = types.Module("mixed.child", {}),
        })
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic_nonclaim, filename)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("mixed.child")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported["mixed.child"].kind)
        assert.equal(archive,
            driver.imported["mixed.child"].static_archive)
        assert.equal("mixed/child.so", modtype.file)
    end)

    it("treats an exact archive nonclaim as terminal", function()
        local archive = binary .. "/empty.a"
        local dynamic = binary .. "/empty.so"
        write_file(dynamic, "must not be inspected\n")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, archive, {})
        titan._loadlib = function()
            error("an exact static nonclaim must not fall through")
        end

        local ok, message = driver.defaultloader({}, {
            context = context,
        })("empty")
        assert.falsy(ok)
        assert.match("exact static provider '" .. archive ..
            "' contains no metadata for module 'empty'", message, 1, true)
        assert.is_nil(driver.imported.empty)
    end)

    it("rejects a claimed malformed Interface in an archive before fallback",
       function()
        local archive = binary .. "/archive_bad.a"
        local dynamic = binary .. "/archive_bad.so"
        write_file(archive, "selected static provider\n")
        write_file(dynamic, "must not be inspected\n")
        local original_scan = staticmetadata.scan_archive
        local dynamic_probed = false

        local ran, failure = pcall(function()
            staticmetadata.scan_archive = function(filename, options)
                assert.equal(archive, filename)
                local serialized = [[
                    Module("archive_bad", {}, {
                        I = {
                            _tag = "Type.Interface",
                            name = "archive_bad.I",
                            fields = {},
                            methods = {},
                        },
                    })
                ]]
                local decoded, message = options.validate_types(
                    "archive_bad", serialized,
                    archive .. ":archive_bad")
                assert.is_nil(decoded)
                return nil, message
            end
            titan._loadlib = function()
                dynamic_probed = true
                error("a dynamic provider must not hide malformed archive metadata")
            end

            local ok, message = driver.defaultloader({}, {
                context =
                    driver.new_resolver_context({ prefer_static = true }),
            })("archive_bad")
            assert.falsy(ok)
            assert.match(archive, message, 1, true)
            assert.match("archive_bad", message, 1, true)
            assert.match("interface has no members", message, 1, true)
            assert.is_false(dynamic_probed)
            assert.is_nil(driver.imported.archive_bad)
        end)
        staticmetadata.scan_archive = original_scan
        assert.truthy(ran, failure)
    end)

    it("rejects an occupied nonregular static candidate without opening it",
       function()
        local candidate = binary .. "/blocked.a"
        assert(lfs.mkdir(candidate))
        driver.TITAN_BIN_PATH = binary

        local ok, message = driver.defaultloader({}, {
            context =
                driver.new_resolver_context({ prefer_static = true }),
        })("blocked")
        assert.falsy(ok)
        assert.match("static provider candidate '" .. candidate ..
            "' for module 'blocked' is not a readable regular file",
            message, 1, true)
    end)

    it("selects one archive key without importing carried siblings", function()
        local archive = binary .. "/bundle.a"
        local left = types.Module("bundle.left", {})
        local right = types.Module("bundle.right", {})
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, archive, {
            ["bundle.left"] = left,
            ["bundle.right"] = right,
        })

        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("bundle.left")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("static", driver.imported["bundle.left"].kind)
        assert.is_nil(driver.imported["bundle.right"])
        assert.equal("bundle/left.so", modtype.file)
        assert.is_nil(types.serialize(modtype):find(archive, 1, true))

        local finalized, final_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            final_errors and table.concat(final_errors, "\n"))
        assert.is_nil(driver.imported["bundle.right"])
        assert.equal("direct",
            context.native_bindings["bundle.right"])
    end)

    it("shadows an occupied relative candidate in later roots", function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        assert(lfs.mkdir(second .. "/a"))
        write_file(first .. "/a.so", "earlier nonclaim\n")
        write_file(second .. "/a.so", "later claim must be shadowed\n")
        write_file(second .. "/a/b.so", "later unshadowed claim\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local inspected = {}
        titan._loadlib = function(filename, symbol)
            inspected[filename] = true
            if filename == first .. "/a.so" then
                return nil, "undefined symbol: " .. symbol, "init"
            end
            assert.equal(second .. "/a/b.so", filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("a/b.so", modtype.file)
        assert.equal(second .. "/a/b.so",
            driver.imported["a.b.c"].filename)
        assert.is_nil(inspected[second .. "/a.so"])
    end)

    it("treats half metadata as a terminal container claim", function()
        write_file(binary .. "/titan.so", "partial shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_types", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats types-only metadata as a terminal container claim", function()
        write_file(binary .. "/titan.so", "partial shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_abi", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("rejects a wrong ABI before executing types metadata", function()
        write_file(binary .. "/titan.so", "stale shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local types_executed = false
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide a stale claim")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return "stale" end
            elseif symbol == "titan_timer_types" then
                return function()
                    types_executed = true
                    return "Module('titan.timer',{})"
                end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("ABI mismatch", message, 1, true)
        assert.match("but found stale", message, 1, true)
        assert.is_false(types_executed)
        assert.is_false(exact_probed)
    end)

    it("rejects invalid metadata results without falling through", function()
        write_file(binary .. "/meta.so", "invalid metadata claims\n")

        local cases = {
            {
                name = "meta.malformed",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function() return "@" end,
                expected = "unexpected symbol near '@'",
            },
            {
                name = "meta.call_error",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function() error("types metadata exploded") end,
                expected = "types metadata exploded",
            },
            {
                name = "meta.arity",
                abi = function() return driver.TITAN_ABI_VERSION, "extra" end,
                metadata = function()
                    error("types metadata must not execute")
                end,
                expected = "compiled module ABI marker 'meta_arity_abi' " ..
                    "must return exactly one string",
            },
            {
                name = "meta.non_string",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function() return 42 end,
                expected = "compiled module type metadata " ..
                    "'meta_non_string_types' must return exactly one string",
            },
            {
                name = "meta.noncanonical",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function()
                    return [[{ _tag = "Type.Module",
                        name = "meta.noncanonical", members = {} }]]
                end,
                expected = "did not construct a canonical Type.Module",
            },
            {
                name = "meta.member_schema",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function()
                    return [[Module("meta.member_schema", {
                        ModuleMember("meta.member_schema", "bad",
                            { _tag = "Type.Unknown" }, false)
                    })]]
                end,
                expected = "Type.Unknown is not valid in a " ..
                    "value-facing type graph",
            },
            {
                name = "meta.interface_schema",
                abi = function() return driver.TITAN_ABI_VERSION end,
                metadata = function()
                    return [[Module("meta.interface_schema", {}, {
                        I = {
                            _tag = "Type.Interface",
                            name = "meta.interface_schema.I",
                            fields = {},
                            methods = {},
                        },
                    })]]
                end,
                expected = "interface has no members",
                retains_claim = true,
            },
        }

        for _, case in ipairs(cases) do
            titan._loadlib = function(filename, symbol)
                assert.equal(binary .. "/meta.so", filename)
                if symbol == driver.mangle_module_name(case.name) .. "_abi" then
                    return case.abi
                elseif symbol == driver.mangle_module_name(case.name) ..
                                  "_types" then
                    return case.metadata
                end
                error("unexpected metadata symbol " .. symbol)
            end

            local ok, message = driver.defaultloader({})(case.name)
            assert.falsy(ok)
            assert.match(case.expected, message, 1, true)
            if case.retains_claim then
                assert.match(binary .. "/meta.so", message, 1, true)
                assert.match(case.name, message, 1, true)
            end
            assert.is_nil(driver.imported[case.name])
        end
    end)

    it("rejects metadata for a different logical module", function()
        write_file(binary .. "/titan.so", "mismatched shallow claim\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local exact_probed = false
        titan._loadlib = function(filename, symbol)
            if filename == binary .. "/titan/timer.so" then
                exact_probed = true
                error("a deeper candidate must not hide mismatched metadata")
            end
            assert.equal(binary .. "/titan.so", filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.other',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("returned type metadata for 'titan.other'", message,
            1, true)
        assert.match("while loading module 'titan.timer'", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats a candidate open failure as a terminal error", function()
        write_file(binary .. "/titan.so", "broken shallow image\n")
        write_file(binary .. "/titan/timer.so", "valid exact claim\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan.so", filename)
            table.insert(symbols, symbol)
            return nil, "broken image", "open"
        end

        local ok, message = driver.defaultloader({})("titan.timer")
        assert.falsy(ok)
        assert.match("cannot inspect compiled module 'titan.timer'", message,
            1, true)
        assert.match("broken image", message, 1, true)
        assert.same({ "titan_timer_abi" }, symbols)
    end)

    it("uses the first valid claim without probing a duplicate", function()
        assert(lfs.mkdir(binary .. "/dup"))
        write_file(binary .. "/dup.so", "shallow claim\n")
        write_file(binary .. "/dup/item.so", "duplicate exact claim\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/dup.so", filename)
            table.insert(symbols, symbol)
            if symbol == "dup_item_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "dup_item_types" then
                return function() return "Module('dup.item',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, modtype, errors = driver.defaultloader({})("dup.item")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal("dup.so", modtype.file)
        assert.equal(binary .. "/dup.so",
            driver.imported["dup.item"].filename)
        assert.same({ "dup_item_abi", "dup_item_types" }, symbols)
    end)

    it("caches two logical interfaces from one physical container separately",
       function()
        write_file(binary .. "/bundle.so", "two logical interfaces\n")
        local functions = {
            bundle_left_abi = function() return driver.TITAN_ABI_VERSION end,
            bundle_left_types = function()
                return "Module('bundle.left',{})"
            end,
            bundle_right_abi = function() return driver.TITAN_ABI_VERSION end,
            bundle_right_types = function()
                return "Module('bundle.right',{})"
            end,
        }
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/bundle.so", filename)
            table.insert(symbols, symbol)
            return assert(functions[symbol], "unexpected metadata symbol")
        end

        local loader = driver.defaultloader({})
        local left_ok, left, left_errors = loader("bundle.left")
        local right_ok, right, right_errors = loader("bundle.right")
        assert.truthy(left_ok)
        assert.truthy(right_ok)
        assert.equal(0, #left_errors)
        assert.equal(0, #right_errors)
        assert.not_equal(left, right)
        assert.not_equal(driver.imported["bundle.left"],
            driver.imported["bundle.right"])
        assert.equal("bundle.so", left.file)
        assert.equal("bundle.so", right.file)
        assert.equal(binary .. "/bundle.so",
            driver.imported["bundle.left"].filename)
        assert.equal(binary .. "/bundle.so",
            driver.imported["bundle.right"].filename)
        assert.same({
            "bundle_left_abi", "bundle_left_types",
            "bundle_right_abi", "bundle_right_types",
        }, symbols)
        local call_count = #symbols
        local cached_ok, cached_left, cached_errors = loader("bundle.left")
        assert.truthy(cached_ok)
        assert.equal(left, cached_left)
        assert.equal(0, #cached_errors)
        assert.equal(call_count, #symbols)
    end)

    it("falls back to source after clean ancestor nonclaims", function()
        write_file(binary .. "/titan.so", "unrelated extension\n")
        write_file(source .. "/titan/fallback.titan", [[
            function marker(): integer return 17 end
        ]])
        titan._loadlib = function(_, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({})("titan.fallback")
        assert.truthy(ok)
        assert.equal("titan.fallback", modtype.name)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.fallback"].ast)
    end)

    it("assembles a folder module in deterministic source order", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan", [[
            local decoy: integer = 99
        ]])
        write_file(folder .. "/sample.titan", [[
            local from_main: integer = 1
            do
                from_main = from_main + from_zero()
            end
        ]])
        -- Deliberately create contributors in an order unrelated to the
        -- required raw-byte basename order.
        write_file(folder .. "/z.titan",
            "local from_z: integer = 1\n")
        write_file(folder .. "/a.titan",
            "local from_a: integer = 1\n")
        -- Use a digit rather than a case-only filename distinction: the
        -- default macOS filesystem aliases A.titan and a.titan. The pure
        -- comparator spec separately covers uppercase/lowercase byte order.
        write_file(folder .. "/0.titan", [[
            function from_zero(): integer
                do
                    return 1
                end
            end
        ]])
        write_file(folder .. "/aa.titan",
            "local from_aa: integer = 1\n")
        write_file(folder .. "/\195\169.titan",
            "local from_utf8: integer = 1\n")
        write_file(folder .. "/ignored.lua", "return {}\n")
        assert(lfs.mkdir(folder .. "/nested.titan"))

        local ok, modtype, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")

        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        assert.equal(folder .. "/sample.titan", imported.filename)
        assert.equal("titan/sample__main", imported.program_output)
        assert.equal(7, #imported.ast)
        assert.same({
            folder .. "/sample.titan",
            folder .. "/0.titan",
            folder .. "/a.titan",
            folder .. "/aa.titan",
            folder .. "/z.titan",
            folder .. "/\195\169.titan",
            folder .. "/sample.titan",
        }, {
            imported.ast[1].loc.filename,
            imported.ast[2].loc.filename,
            imported.ast[3].loc.filename,
            imported.ast[4].loc.filename,
            imported.ast[5].loc.filename,
            imported.ast[6].loc.filename,
            imported.ast[7].loc.filename,
        })
        assert.equal("Ast.StatBlock", imported.ast[7]._tag)
    end)

    it("shares an Interface declaration and implementation across constituents",
       function()
        local folder = source .. "/titan/interfaces"
        assert(lfs.mkdir(folder))
        local main = folder .. "/interfaces.titan"
        local part = folder .. "/provider.titan"
        write_file(main, [[
            interface Counter
                function step(delta: integer): integer
            end
        ]])
        write_file(part, [[
            record Box
                n: integer
            end

            function Box:step(delta: integer): integer
                return self.n + delta
            end

            function use(box: Box): integer
                local counter: Counter = box
                return counter:step(2)
            end
        ]])

        local ok, modtype, errors = driver.defaultloader({}, {
            source_roots = { ["titan.interfaces"] = true },
        })("titan.interfaces")
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("Type.Interface",
            modtype.type_members.Counter._tag)
        assert.is_nil(modtype.members.Counter)
        assert.equal("Type.Record",
            modtype.members.Box.type._tag)
        assert.equal("Type.Function",
            modtype.members.use.type._tag)

        local imported = driver.imported["titan.interfaces"]
        assert.equal(main, imported.ast[1].loc.filename)
        assert.equal(part, imported.ast[2].loc.filename)
        assert.equal(part, imported.ast[3].loc.filename)
        assert.equal(part, imported.ast[4].loc.filename)
    end)

    it("attributes a cross-constituent Interface mismatch to the real cast file",
       function()
        local folder = source .. "/titan/interface_mismatch"
        assert(lfs.mkdir(folder))
        local main = folder .. "/interface_mismatch.titan"
        local provider = folder .. "/provider.titan"
        local bridge = folder .. "/bridge.titan"
        write_file(main, [[
            interface Counter
                function step(delta: integer): integer
            end
        ]])
        write_file(provider, [[
            record Box end

            function Box:step(delta: string): integer
                return 0
            end
        ]])
        write_file(bridge, [[
            function use(box: Box): Counter
                return box
            end
        ]])

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = {
                ["titan.interface_mismatch"] = true,
            },
        })("titan.interface_mismatch")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(bridge .. ":2:24: type error:", errors[1], 1, true)
        assert.match(
            "record 'titan%.interface_mismatch%.Box' does not implement " ..
            "interface 'titan%.interface_mismatch%.Counter'",
            errors[1])
        assert.match("method 'step' has incompatible type", errors[1], 1, true)
        assert.match("expected", errors[1], 1, true)
    end)

    it("honors source-root order across flat and folder representations",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        write_file(source .. "/titan/sample.titan",
            "local from_flat: integer = 1\n")
        write_file(later .. "/titan/sample/sample.titan",
            "local from_folder: integer = 1\n")

        driver.TITAN_SOURCE_PATH = source .. ";" .. later
        local loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(source .. "/titan/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample",
            driver.imported["titan.sample"].program_output)

        driver.imported = {}
        types.registry = {}
        driver.TITAN_SOURCE_PATH = later .. ";" .. source
        loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })
        ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/sample.titan",
            driver.imported["titan.sample"].filename)
        assert.equal("titan/sample__main",
            driver.imported["titan.sample"].program_output)
    end)

    it("blocks constituent flat sources but permits a deeper folder module",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")

        local child_loader = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })
        local ok, message = child_loader("titan.sample.child")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.child' cannot be loaded directly",
            message, 1, true)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.match("folder module 'titan.sample'", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)

        ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.sample"] = true },
        })("titan.sample.sample")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.sample' cannot be loaded directly",
            message, 1, true)

        assert(lfs.mkdir(folder .. "/child"))
        write_file(folder .. "/child/child.titan", [[
            function distinct(): integer
                return 2
            end
        ]])
        ok, _, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #message)
        assert.equal(folder .. "/child/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("does not fall through a blocked constituent in an earlier root",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.falsy(ok)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.not_match(later, message, 1, true)
    end)

    it("allows a later nested flat module when the earlier constituent is absent",
       function()
        local later = root .. "/later"
        assert(lfs.mkdir(later))
        assert(lfs.mkdir(later .. "/titan"))
        assert(lfs.mkdir(later .. "/titan/sample"))
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(later .. "/titan/sample/child.titan", [[
            function later_module(): integer
                return 3
            end
        ]])
        driver.TITAN_SOURCE_PATH = source .. ";" .. later

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample.child"] = true },
        })("titan.sample.child")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/child.titan",
            driver.imported["titan.sample.child"].filename)
    end)

    it("uses an exact child binary before applying folder-source privacy",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/child.titan",
            "local constituent: integer = 1\n")
        assert(lfs.mkdir(binary .. "/titan/sample"))
        local child_binary = binary .. "/titan/sample/child.so"
        write_file(child_binary, "mock interface\n")

        titan._loadlib = function(filename, symbol)
            assert.equal(child_binary, filename)
            if symbol == "titan_sample_child_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_sample_child_types" then
                return function()
                    return "Module('titan.sample.child',{})"
                end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.sample.child")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal(child_binary,
            driver.imported["titan.sample.child"].filename)
        assert.is_nil(driver.imported["titan.sample.child"].ast)
    end)

    it("reports folder enumeration failure without falling back", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")

        local real_dir = lfs.dir
        lfs.dir = function(path)
            if path == folder then error("permission denied") end
            return real_dir(path)
        end
        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        lfs.dir = real_dir

        assert.truthy(called)
        assert.falsy(ok)
        assert.match("cannot enumerate folder module 'titan.sample'",
            message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.match("permission denied", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("treats a selected contributor read failure as a hard error",
       function()
        local folder = source .. "/titan/sample"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(part, "local contributor: integer = 2\n")

        local strategy = compiler_io.new_sync()
        local real_read_file = strategy.read_file
        function strategy:read_file(path)
            if path == part then
                return false, part .. ": forced read failure"
            end
            return real_read_file(self, path)
        end
        local context = driver.new_resolver_context({ io = strategy })
        local called, ok, message = pcall(driver.defaultloader({}, {
            context = context,
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")

        assert.truthy(called)
        assert.falsy(ok)
        assert.equal(part .. ": forced read failure", message)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a contributor initializer at its exact source location",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "\ndo\n    local invalid: integer = 1\nend\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("rejects a protected contributor initializer by its parser role",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan", [[

do
    defer local cleaned: boolean = true
    raise "expected"
catch
    local caught: value = error
end
]])

        local called, ok, message = pcall(driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        }), "titan.sample")
        assert.truthy(called)
        assert.falsy(ok)
        assert.match(folder .. "/part.titan:2:1", message, 1, true)
        assert.match("module initializer is only allowed", message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("moves a protected main initializer after contributor declarations",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan", [[
answer: integer = 0

do
    defer answer = answer + 1
    raise "expected"
catch
    answer = contributor_answer()
end
]])
        write_file(folder .. "/part.titan", [[
local function contributor_answer(): integer
    return 41
end
]])

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local combined = driver.imported["titan.sample"].ast
        assert.equal("Ast.TopLevelFunc", combined[#combined - 1]._tag)
        assert.equal("contributor_answer", combined[#combined - 1].name)
        assert.equal("Ast.StatTry", combined[#combined]._tag)
        assert.is_true(combined[#combined]._module_initializer)
    end)

    it("reports a syntax error from the failing contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/sample.titan",
            "local decoy: integer = 1\n")
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/broken.titan", "function broken(\n")

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.falsy(ok)
        assert.match(folder .. "/broken.titan:2:1: syntax error:",
            message, 1, true)
        assert.is_nil(driver.imported["titan.sample"])
    end)

    it("reports an exact type-error location from a contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local invalid: integer = \"not an integer\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1: type error:",
            errors[1], 1, true)
        assert.match("declaration of module variable invalid", errors[1],
            1, true)
    end)

    it("tracks contributor imports in one logical dependency closure",
       function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(source .. "/titan/alpha.titan", [[
            function alpha(): integer return 1 end
        ]])
        write_file(source .. "/titan/beta.titan", [[
            function beta(): integer return 2 end
        ]])
        write_file(folder .. "/sample.titan", [[
            local alpha = import "titan.alpha"
            function from_main(): integer return alpha.alpha() end
        ]])
        write_file(folder .. "/part.titan", [[
            local beta = import "titan.beta"
            function from_part(): integer return beta.beta() end
        ]])

        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            source_roots = { ["titan.sample"] = true },
        })
        local ok, modtype, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        local imported = driver.imported["titan.sample"]
        local original_ast = imported.ast
        assert.same({
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, imported.deps)
        assert.same({
            ["titan.sample"] = true,
            ["titan.alpha"] = true,
            ["titan.beta"] = true,
        }, driver.dependency_closure("titan.sample"))
        assert.same(driver.dependency_closure("titan.sample"), static_deps)

        local cached_ok, cached_type, cached_errors = loader("titan.sample")
        assert.truthy(cached_ok)
        assert.equal(modtype, cached_type)
        assert.equal(0, #cached_errors)
        assert.equal(original_ast, driver.imported["titan.sample"].ast)
    end)

    it("keeps folder identity marked across repeated self-imports", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local self_main = import \"titan.sample\"\n")
        write_file(folder .. "/part.titan",
            "\nlocal self_part = import \"titan.sample\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(2, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(folder .. "/sample.titan:1:1", all_errors, 1, true)
        assert.match(folder .. "/part.titan:2:1", all_errors, 1, true)
        assert.match("circular reference to module", all_errors, 1, true)
        assert.is_table(driver.imported["titan.sample"].ast)
        local cache_entries = 0
        for _ in pairs(driver.imported) do
            cache_entries = cache_entries + 1
        end
        assert.equal(1, cache_entries)
    end)

    it("attributes a blocked sibling import to its contributor", function()
        local folder = source .. "/titan/sample"
        assert(lfs.mkdir(folder))
        write_file(folder .. "/sample.titan",
            "local owner: integer = 1\n")
        write_file(folder .. "/part.titan",
            "local sibling = import \"titan.sample.part\"\n")

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(1, #errors)
        assert.match(folder .. "/part.titan:1:1", errors[1], 1, true)
        assert.match("source module 'titan.sample.part' cannot be loaded " ..
            "directly", errors[1], 1, true)
        assert.match(folder .. "/part.titan", errors[1], 1, true)
        assert.is_nil(driver.imported["titan.sample.part"])
    end)

    it("reports both files for cross-file duplicate declarations", function()
        local folder = source .. "/titan/sample"
        local main = folder .. "/sample.titan"
        local part = folder .. "/part.titan"
        assert(lfs.mkdir(folder))
        write_file(main, table.concat({
            "record Box end",
            "type Count = integer",
            "interface Stream function read(): string end",
            "local item = 1",
            "",
        }, "\n"))
        write_file(part, table.concat({
            "type Count = string",
            "type Box = integer",
            "interface Stream function read(): string end",
            "local item = 2",
            "",
        }, "\n"))

        local ok, _, errors = driver.defaultloader({}, {
            source_roots = { ["titan.sample"] = true },
        })("titan.sample")
        assert.truthy(ok)
        assert.equal(4, #errors)
        local all_errors = table.concat(errors, "\n")
        assert.match(part .. ":1:1: type error: duplicate type alias for " ..
            "Count, previous one at " .. main .. ":2:1",
            all_errors, 1, true)
        assert.match(part .. ":2:1: type error: type alias 'Box' conflicts " ..
            "with record declared at " .. main .. ":1:1",
            all_errors, 1, true)
        assert.match(part .. ":3:1: type error: duplicate interface 'Stream', " ..
            "previous one at " .. main .. ":3:1",
            all_errors, 1, true)
        assert.match(part .. ":4:1: type error: duplicate declaration for " ..
            "item, previous one at " .. main .. ":4:1",
            all_errors, 1, true)
    end)

    it("rejects malformed module names without crashing", function()
        local malformed = {
            "", ".", "titan.", ".titan", "titan..timer",
            "1titan", "-titan", "titan.$line", "titan timer",
            "titan/timer", "pkg.titan",
        }
        local source_roots = {}
        for _, name in ipairs(malformed) do source_roots[name] = true end
        local loader = driver.defaultloader({}, {
            source_roots = source_roots,
        })

        for _, name in ipairs(malformed) do
            local called, ok, message = pcall(loader, name)
            assert.truthy(called)
            assert.falsy(ok)
            assert.match(
                "invalid logical Titan module name", message, 1, true)
        end

        local called, plans, message = pcall(
            driver.plan_module_shims,
            "provider$line", { "module$line" })
        assert.truthy(called)
        assert.falsy(plans)
        assert.match("invalid library provider name", message, 1, true)
    end)

    it("requires source for an explicit build root", function()
        write_file(binary .. "/titan/timer.so", "existing binary\n")
        titan._loadlib = function()
            error("an explicit source build must not load its existing binary")
        end

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")

        assert.falsy(ok)
        assert.equal("source module 'titan.timer' not found", message)
        assert.is_nil(driver.imported["titan.timer"])
    end)

    it("reports a missing ABI entry from the internal loader", function()
        write_file(binary .. "/extension.so", "mock image\n")
        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/extension.so", filename)
            table.insert(symbols, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({})("extension")
        assert.falsy(ok)
        assert.match("has no compatible Titan ABI marker", message)
        assert.same({ "extension_abi", "extension_types" }, symbols)
    end)

    it("records a cached table-loader import as a dependency", function()
        local modtype = types.Module("cached", {})
        local imported = { cached = { type = modtype } }
        local deps = {}

        local ok, loaded, errors =
            driver.tableloader({}, imported, deps)("cached")

        assert.truthy(ok)
        assert.equal(modtype, loaded)
        assert.equal(0, #errors)
        assert.equal(true, deps.cached)
    end)

    it("rejects a table source view after using a different cached interface",
    function()
        local compiled = types.Module("cached", {
            types.ModuleMember("cached", "answer",
                types.Function({}, { types.Integer() }, false, false, false),
                {}),
        })
        local imported = {
            cached = { kind = "dynamic", type = compiled },
        }
        local loader = driver.tableloader({
            cached = [[
                function answer(): string return "source" end
            ]],
        }, imported)

        local ok, result, errors = loader("cached")
        assert.truthy(ok, result)
        assert.equal(0, #errors)

        ok, result, errors = loader("cached", { kind = "source-import" })
        assert.truthy(ok, result)
        assert.equal(1, #errors)
        assert.equal("source module 'cached' does not match a compiled " ..
            "interface already used in this compilation", errors[1])
        assert.equal("source", imported.cached.kind)
        assert.is_true(driver.close_tableloader(loader))
    end)
end)

local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local cdriver = require "c-parser.cdriver"
local cprobe = require "titan-compiler.cprobe"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local csemantics = require "titan-compiler.csemantics"
local coder = require "titan-compiler.coder"
local sourceinterface = require "titan-compiler.sourceinterface"
local ffiheaders = require "titan-compiler.ffiheaders"
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local types = require "titan-compiler.types"
local util = require "titan-compiler.util"
local titan = require "titan"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local version = require "titan-compiler.version"
local incremental = require "titan-compiler.incremental"
local browser_fixtures = require "spec.support.browser_fixtures"
local new_context, close_contexts, resolver_options =
    require("spec.support.resolver_contexts")(driver)
after_each(close_contexts)

describe("compiler-specific production debug defaults", function()
    local function fresh_driver(profile)
        local original_getenv = platform.getenv
        local original_driver = package.loaded["titan-compiler.driver"]
        platform.getenv = function(name)
            if name == "TITAN_BUILD_PROFILE" then return profile end
            -- These cases select defaults, independent of CI or caller extras.
            if name == "TITAN_EXTRA_CPPFLAGS" or
                    name == "TITAN_EXTRA_CFLAGS" or
                    name == "TITAN_EXTRA_LDFLAGS" then return nil end
            return original_getenv(name)
        end
        package.loaded["titan-compiler.driver"] = nil
        local loaded, subject = pcall(require, "titan-compiler.driver")
        platform.getenv = original_getenv
        package.loaded["titan-compiler.driver"] = original_driver
        assert.truthy(loaded, subject)
        return subject
    end

    local function probe_context(subject, response)
        local strategy = compiler_io.new_sync()
        local commands = {}
        function strategy:run(argv, options)
            commands[#commands + 1] = { argv = argv, options = options }
            if type(response) == "function" then return response(argv) end
            return { started = true, ok = true, output = response }
        end
        local context = subject.new_resolver_context({ io = strategy, target = "linux" })
        context._platform_initialized = true
        context.uname = "Linux"
        context.is_darwin = false
        return context, commands
    end

    local function has_flag(descriptor, flag)
        for _, argument in ipairs(descriptor.compile_flags) do
            if argument == flag then return true end
        end
        return false
    end

    for _, case in ipairs({
        { "GCC", "#define __GNUC__ 16\n", "gcc" },
        { "Clang despite its GCC compatibility macros",
          "#define __GNUC__ 4\r\n#define __clang__ 1\r\n", "clang" },
        { "unknown compilers", "#define __OTHER_CC__ 1\n", "unknown" },
    }) do
        it("selects production debug defaults for " .. case[1], function()
            local subject = fresh_driver("production")
            subject.CC = "env SENTINEL=present '/tools with spaces/cc' -DCC_OPTION=1"
            local context, commands = probe_context(subject, case[2])
            local descriptor = assert(subject.toolchain_descriptor(context))
            assert.same({ "env", "SENTINEL=present", "/tools with spaces/cc",
                "-DCC_OPTION=1", "-dM", "-E", "-x", "c",
                platform.windows and "NUL" or "/dev/null" }, commands[1].argv)
            assert.is_true(commands[1].options.stderr_to_stdout)
            assert.equal(case[3] == "gcc",
                has_flag(descriptor, "-g1"))
            assert.equal(case[3] == "clang",
                has_flag(descriptor, "-gline-tables-only"))
            assert.equal(case[3] == "clang",
                has_flag(descriptor, "-fdebug-info-for-profiling"))
            assert.equal(case[3] == "unknown", has_flag(descriptor, "-g"))
        end)
    end

    it("caches by parsed compiler argv and I/O strategy and preserves custom flags", function()
        local subject = fresh_driver("production")
        local macros = "#define __GNUC__ 16\n"
        local context, commands = probe_context(subject, function()
            return { started = true, ok = true, output = macros }
        end)
        subject.CC = "'/compiler path' --target=one"
        assert.truthy(has_flag(assert(subject.toolchain_descriptor(context)),
            "-g1"))
        subject.CC = "  '/compiler path'   --target=one  "
        assert(subject.toolchain_descriptor(context))
        assert.equal(1, #commands)

        subject.CC = "'/compiler path' --target=two"
        macros = "#define __GNUC__ 4\n#define __clang__ 1\n"
        local changed = assert(subject.toolchain_descriptor(context))
        assert.is_true(has_flag(changed, "-gline-tables-only"))
        assert.is_false(has_flag(changed, "-g1"))
        assert.equal(2, #commands)

        local other, other_commands = probe_context(subject, "#define __OTHER_CC__ 1\n")
        local neutral = assert(subject.toolchain_descriptor(other))
        assert.is_true(has_flag(neutral, "-g"))
        assert.is_false(has_flag(neutral, "-gline-tables-only"))
        assert.equal(1, #other_commands)

        subject.CFLAGS = "-O1 -g3 -DCUSTOM_DEFAULTS=1"
        subject.CC = "different-compiler"
        local custom = assert(subject.toolchain_descriptor(other))
        assert.same({ "-O1", "-g3", "-DCUSTOM_DEFAULTS=1" }, custom.compile_flags)
        assert.equal(1, #other_commands)
    end)

    it("reuses one lazy strategy for contextless object and link defaults", function()
        local subject = fresh_driver("production")
        subject.CC, subject.UNAME, subject.IS_DARWIN = "compiler-one", "Linux", false
        local context, commands = probe_context(subject, "#define __GNUC__ 16\n")
        local original_new_sync = compiler_io.new_sync
        local created = 0
        compiler_io.new_sync = function()
            created = created + 1
            return context.io
        end
        local completed, failure = xpcall(function()
            assert(subject.generated_compile_prefix())
            assert(subject.generated_compile_prefix())
            assert.equal(1, created)
            assert.equal(1, #commands)
            subject.CC = "compiler-two"
            assert(subject.generated_compile_prefix())
            assert.equal(1, created)
            assert.equal(2, #commands)
        end, debug.traceback)
        compiler_io.new_sync = original_new_sync
        assert.truthy(completed, failure)
    end)

    it("keeps validation defaults independent of compiler-family probes", function()
        local subject = fresh_driver("validation")
        local context, commands = probe_context(subject, function()
            error("validation attempted a compiler-family probe")
        end)
        local descriptor = assert(subject.toolchain_descriptor(context))
        assert.is_true(has_flag(descriptor, "-g"))
        assert.is_true(has_flag(descriptor, "-O0"))
        assert.is_false(has_flag(descriptor, "-g1"))
        assert.same({}, commands)
    end)

    it("reports family-probe failures and retries instead of caching them", function()
        local subject = fresh_driver("production")
        local failing = true
        local context, commands = probe_context(subject, function()
            if failing then
                return { started = false, ok = false,
                    diagnostic = "injected compiler failure" }
            end
            return { started = true, ok = true, output = "#define __GNUC__ 16\n" }
        end)
        local descriptor, err = subject.toolchain_descriptor(context)
        assert.is_nil(descriptor)
        assert.equal("cannot identify C compiler family: injected compiler failure", err)
        failing = false
        assert(subject.toolchain_descriptor(context))
        assert.equal(2, #commands)
    end)

    it("accepts the selected production debug defaults with the configured C compiler", function()
        local subject = fresh_driver("production")
        local context = subject.new_resolver_context()
        local descriptor = assert(subject.toolchain_descriptor(context))
        local argv = { table.unpack(descriptor.compiler_argv) }
        for _, argument in ipairs(descriptor.compile_flags) do
            argv[#argv + 1] = argument
        end
        for _, argument in ipairs({ "-fsyntax-only", "-x", "c",
                platform.windows and "NUL" or "/dev/null" }) do
            argv[#argv + 1] = argument
        end
        local result = context.io:run(argv, { stderr_to_stdout = true })
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.is_true(subject.close_resolver_context(context))
    end)

    it("reports unusable compiler defaults through the authored C prefix",
       function()
        local subject = fresh_driver("validation")
        subject.CFLAGS = "'unterminated"
        local args, err = subject.authored_c_compile_prefix()
        assert.is_nil(args)
        assert.equal("invalid compiler defaults: " ..
            "unterminated single quote in shell words", err)
    end)
end)

local function fixture_path(path)
    return platform.windows and "C:" .. path or path
end

local function posix_model_it(name, callback)
    it(name, function()
        local previous = platform.windows
        local previous_driver = {}
        for key, value in pairs(driver) do previous_driver[key] = value end
        if previous then
            -- Host module-load paths on Windows carry drive letters (`C:/...`).
            -- Delegate to the real production `driver.initialize_layout` so its
            -- context/strategy validation runs unchanged while skipping only
            -- the host-root reinterpretation step.
            driver.initialize_layout = function(context)
                if type(context) == "table" and context.io ~= nil then
                    context._layout_initialized = true
                end
                return previous_driver.initialize_layout(context)
            end
        end
        local completed, failure = xpcall(function() browser_fixtures.with_posix_host(callback) end, debug.traceback)
        for key in pairs(driver) do driver[key] = nil end
        for key, value in pairs(previous_driver) do driver[key] = value end
        assert.truthy(completed, failure)
    end)
end

describe("target source selection API", function()
    it("classifies reserved filename suffixes without changing dotted names", function()
        assert.same({ "windows", "darwin", "linux", "browser", "native" },
            driver.SOURCE_LABELS)
        for _, label in ipairs(driver.SOURCE_LABELS) do
            local logical, selected, err =
                driver.classify_source_filename("foo." .. label .. ".titan")
            assert.equal("foo.titan", logical)
            assert.equal(label, selected)
            assert.is_nil(err)
            assert.equal(label .. ".titan",
                driver.classify_source_filename(label .. ".titan"))
        end
        assert.equal("x.y.titan", driver.classify_source_filename("x.y.titan"))
        assert.equal("linux.titan",
            driver.classify_source_filename("linux.titan"))
        assert.same({ "linux.titan", "native" },
            { driver.classify_source_filename("linux.native.titan") })
        assert.is_nil(driver.classify_source_filename("foo.c"))
        for _, case in ipairs({
            { "x.linux.native.titan", "stacked target labels" },
            { "x.Linux.titan", "mis-cased target label" },
            { "x.Linux.native.titan", "stacked target labels" },
        }) do
            local logical, label, err = driver.classify_source_filename(case[1])
            assert.is_nil(logical)
            assert.is_nil(label)
            assert.matches(case[2], err, 1, true)
            assert.matches(case[1], err, 1, true)
        end
    end)

    it("exposes the complete applicability rows", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local expected = (target == "browser" or target == "native") and
                { target } or { target, "native" }
            assert.same(expected, driver.target_selection_labels(target))
            for _, label in ipairs(driver.SOURCE_LABELS) do
                local applies = false
                for _, selected in ipairs(expected) do
                    applies = applies or selected == label
                end
                assert.equal(applies, driver.target_label_applies(target, label))
            end
        end
        assert.has_error(function() driver.target_selection_labels("bogus") end,
            "invalid source selection target 'bogus'")
        assert.has_error(function() driver.new_resolver_context({ target = "bogus" }) end,
            "invalid source selection target 'bogus'")
    end)

    for _, host in ipairs({ "Linux", "Darwin", "FreeBSD" }) do
        posix_model_it("resolves and validates the target on " .. host, function()
            local strategy = compiler_io.new_sync()
            local calls = 0
            function strategy:run(argv)
                assert.same({ "uname" }, argv)
                calls = calls + 1
                return { started = true, ok = true, output = host .. "\n" }
            end
            local context = driver.new_resolver_context({ io = strategy })
            local expected = host == "Linux" and "linux" or
                host == "Darwin" and "darwin" or "native"
            assert.equal(expected, context.target)
            assert.equal(expected, driver.context_target(context))
            assert.equal(expected, driver.validate_target(context, nil))
            assert.equal(expected, driver.validate_target(context, ""))
            for _, value in ipairs({ "linux", "darwin", "windows",
                    "native", "browser", "wasm32" }) do
                for _, origin in ipairs({ "--target", "TITAN_TARGET" }) do
                    local target, err = driver.validate_target(context, value, origin)
                    if value == expected and value ~= "native" or
                        value == "browser" and expected ~= "native" then
                        assert.equal(value, target)
                        assert.is_nil(err)
                    else
                        assert.is_nil(target)
                        if value == "browser" then
                            assert.equal("browser builds are supported from Linux, macOS and Windows hosts (host is native)", err)
                        else
                            assert.matches(origin == "TITAN_TARGET" and
                                "TITAN_TARGET=" .. value or "--target " .. value, err, 1, true)
                        end
                        local reason = value == "native" and "not a compilation target" or
                            value == "browser" and "supported from Linux, macOS and Windows hosts" or
                            value == "wasm32" and "unknown target" or
                            "native cross-compilation is not supported"
                        assert.matches(reason, err, 1, true)
                    end
                end
            end
            assert.equal(1, calls)
            assert.is_true(driver.close_resolver_context(context))

            local implementation = driver._browser_target
            driver._browser_target = setmetatable({ build = function()
                return assert(implementation.import(browser_fixtures.descriptor()))
            end }, { __index = implementation })
            if expected == "native" then
                assert.has_error(function()
                    driver.new_resolver_context({ io = strategy, target = "browser" })
                end, "browser builds are supported from Linux, macOS and Windows hosts (host is native)")
            else
                local explicit = driver.new_resolver_context({ io = strategy, target = "browser" })
                assert.equal("browser", driver.context_target(explicit))
                assert.is_true(driver.close_resolver_context(explicit))
            end
            driver._browser_target = implementation
        end)
    end

    it("resolves the Windows host without uname", function()
        local windows = platform.windows
        local uname, darwin, cflags = driver.UNAME, driver.IS_DARWIN, driver.CFLAGS
        local context = driver.new_resolver_context({ target = "windows" })
        function context.io:run() error("Windows must not run uname") end
        platform.windows = true
        local ok, err = xpcall(function()
            assert.equal("windows", driver.context_target(context))
            assert.equal("windows", driver.validate_target(context, "windows"))
        end, debug.traceback)
        platform.windows = windows
        driver.UNAME, driver.IS_DARWIN, driver.CFLAGS = uname, darwin, cflags
        assert.is_true(driver.close_resolver_context(context))
        assert.truthy(ok, err)
    end)
end)

-- These assertions model the POSIX standalone writer. Its lexical
-- hierarchy uses POSIX spellings, so a Windows host supplies the small
-- directory-type model instead of passing fictional POSIX paths to LFS.
-- POSIX hosts retain the real filesystem fixture below.
local function posix_output_it(name, callback)
    posix_model_it(name, function()
        if package.config:sub(1, 1) ~= "\\" then return callback() end
        local originals = {
            currentdir = lfs.currentdir, chdir = lfs.chdir,
            attributes = lfs.attributes, symlinkattributes = lfs.symlinkattributes,
        }
        local entries = {}
        lfs.currentdir = function() return "/fixture" end
        lfs.chdir = function() return nil, "no physical directory in the POSIX model" end
        local function attributes(path, field)
            local entry = entries[path]
            if field then return entry and entry[field] end
            return entry
        end
        lfs.attributes, lfs.symlinkattributes = attributes, attributes
        local completed, failure = xpcall(function() callback(entries) end, debug.traceback)
        for key, value in pairs(originals) do lfs[key] = value end
        assert.truthy(completed, failure)
    end)
end

describe("Windows compiler path integration", function()
    local platform = require "titan-compiler.platform"
    local originals, resolver, resolver_io
    before_each(function()
        originals = {
            windows = platform.windows,
            native = platform.native,
            new_sync = compiler_io.new_sync,
            lfs_attributes = lfs.attributes,
            lfs_symlinkattributes = lfs.symlinkattributes,
        }
        resolver = driver.new_resolver_context()
        resolver_io = resolver.io
        platform.windows = true
        platform.native = function(name)
            error("unexpected native call in injected path test: " .. name)
        end
    end)
    after_each(function()
        platform.windows = originals.windows
        platform.native = originals.native
        compiler_io.new_sync = originals.new_sync
        lfs.attributes = originals.lfs_attributes
        lfs.symlinkattributes = originals.lfs_symlinkattributes
        resolver.io = resolver_io
        assert.is_true(driver.close_resolver_context(resolver))
    end)

    local function staging_context(strategy)
        resolver.io = strategy
        return resolver
    end

    local function header_manifest(paths, kind)
        kind = kind or "file"
        local modtype = types.Module("header_paths", {}, {})
        modtype._source = true
        modtype.source_members = {}
        modtype.source_type_members = {}
        local headers = {}
        for index, path in ipairs(paths) do
            headers[index] = {
                kind = type(path) == "table" and path.kind or kind,
                path = type(path) == "table" and path.path or path,
                identity = type(path) == "table" and path.identity or "bytes:header",
            }
        end
        return sourceinterface.serialize({
            kind = "source", type = modtype, c_header_dependencies = headers,
        })
    end

    it("preserves lexical Windows path rules through the shared standalone oracle", function()
        dofile("spec/fixtures/windows_serial/verify_paths.lua")
    end)

    it("serializes fully qualified Windows header paths without rewriting identities", function()
        local paths = {
            "C:/SDK 日本/include/lua.h",
            [[C:\SDK 日本\include\lua.h]],
            [[\\server\share\include\lua.h]],
            [[\\?\C:\SDK\include\lua.h]],
            "C:/SDK/link/../include/lua.h",
        }
        local manifest = assert(header_manifest(paths))
        assert.equal(version.SOURCE_INTERFACE_FORMAT, sourceinterface.FORMAT)
        assert.matches(version.SOURCE_INTERFACE_FORMAT, manifest, 1, true)
        for _, path in ipairs(paths) do
            assert.matches(path, manifest, 1, true)
        end
        assert.not_equal(assert(header_manifest({ paths[1] })),
            assert(header_manifest({ paths[2] })))
        assert.not_equal(assert(header_manifest({ paths[1] }, "file")),
            assert(header_manifest({ paths[1] }, "origin")))
        assert.is_string(assert(header_manifest({
            { kind = "file", path = paths[1], identity = "bytes:header" },
            { kind = "origin", path = paths[1], identity = "origin:header" },
        })))
        local duplicate, duplicate_error = header_manifest({ paths[1], paths[1] })
        assert.is_nil(duplicate)
        assert.matches("repeat file input", duplicate_error, 1, true)
        local duplicate_origin, origin_error = header_manifest({ paths[1], paths[1] }, "origin")
        assert.is_nil(duplicate_origin)
        assert.matches("repeat origin input", origin_error, 1, true)
        for _, path in ipairs({ "relative.h", "C:relative.h", "/rooted.h",
                [[\rooted.h]], [[\\server]], [[\\.\C:\device.h]], "C:/bad\0.h" }) do
            local value, err = header_manifest({ path })
            assert.is_nil(value)
            assert.matches("invalid path", err, 1, true)
        end
    end)

    it("retains Unix header path spellings and rejects Windows drive paths", function()
        platform.windows = false
        local paths = { "/sdk//include/./lua.h", "/sdk/link/../lua.h", "/sdk/lua.h " }
        local manifest = assert(header_manifest(paths))
        for _, path in ipairs(paths) do
            assert.matches(path, manifest, 1, true)
        end
        for _, path in ipairs({ "relative.h", "C:/SDK/lua.h", "/bad\0.h" }) do
            local value, err = header_manifest({ path })
            assert.is_nil(value)
            assert.matches("invalid path", err, 1, true)
        end
    end)

    local function logical_header_owner()
        return { io = {
            cwd = function() return "C:/src/project" end,
            tmpname = function() return "C:/tmp/ffi-reservation" end,
            unlink = function() return true end,
            mkdir = function() return true end,
            write_file = function() return true end,
        } }
    end

    it("constructs Windows generated-header logical origins in their own namespace", function()
        local cases = {
            { "C:/src/pkg/../main.titan", "C:/src/main.ffi.h" },
            { [[C:\src\.\main.titan]], "C:/src/main.ffi.h" },
            { "../main.titan", "C:/src/main.ffi.h" },
            { [[\\server\share\dir\..\main.titan]], "//server/share/main.ffi.h" },
            { [[\\?\C:\src\main.titan]], [[\\?\C:\src\main.ffi.h]] },
        }
        local descriptors = {}
        for index, case in ipairs(cases) do
            local descriptor = assert(ffiheaders.prepare(logical_header_owner(),
                "main", {}, case[1]))
            assert.equal(case[2], descriptor.identity)
            assert.is_true(ffiheaders.validate_plan(descriptor))
            descriptors[index] = descriptor
        end
        assert.equal(descriptors[1].digest, descriptors[2].digest)
        assert.equal(descriptors[1].digest, descriptors[3].digest)
        assert.not_equal(descriptors[1].digest, descriptors[4].digest)
        for _, identity in ipairs({ "C:main.ffi.h", "/main.ffi.h", [[\main.ffi.h]],
                "C:/main\0.ffi.h", "C:/main\n.ffi.h" }) do
            descriptors[1].identity = identity
            assert.has_error(function() ffiheaders.validate_plan(descriptors[1]) end,
                "invalid generated FFI identity")
        end
    end)

    it("requires the injected owner to resolve drive-relative generated origins", function()
        local owner = logical_header_owner()
        local descriptor, err = ffiheaders.prepare(owner, "main", {}, "D:main.titan")
        assert.is_nil(descriptor)
        assert.matches("per-drive", err, 1, true)
        owner.io.absolute = function(_, path)
            assert.equal("D:main.ffi.h", path)
            return [[D:\per-drive\main.ffi.h]]
        end
        descriptor = assert(ffiheaders.prepare(owner, "main", {}, "D:main.titan"))
        assert.equal("D:/per-drive/main.ffi.h", descriptor.identity)
        assert.is_true(ffiheaders.validate_plan(descriptor))
    end)

    it("keeps extended SDK joins and the controlled Lua import library", function()
        local layout = driver.installed_paths([[\\?\C:\SDK é]])
        assert.equal([[\\?\C:\SDK é\lib\titan\0.6]], layout.titan_bin)
        assert.equal([[\\?\C:\SDK é\src\lua-5.5.1]], layout.lua_source)
        assert.equal([[\\?\C:\SDK é\lib\liblua55.a]], layout.liblua)
        assert.equal([[\\?\C:\SDK é\include]], layout.include)
    end)

    it("keeps ordinary executable-relative SDK roots in their ordinary namespace", function()
        local layout = driver.installed_paths([[C:\SDK 日本\bin\..]])
        assert.equal("C:/SDK 日本", layout.root)
        assert.equal("C:/SDK 日本/lib/liblua55.a", layout.liblua)
        assert.equal("C:/SDK 日本/lib/titan/0.6", layout.titan_bin)
    end)

    it("discovers source checkouts through the injected strategy", function()
        local observed = {}
        local strategy = {
            cwd = function() return [[C:\Source Tree\é]] end,
            stat = function(_, filename)
                observed[#observed + 1] = filename
                return { kind = "file" }
            end,
        }
        assert.is_true(driver.source_checkout_from_driver_source(
            [[@titan-compiler\driver.lua]], nil, strategy))
        assert.same({
            "C:/Source Tree/é/titan-runtime/titan.c",
            "C:/Source Tree/é/Makefile",
        }, observed)
    end)

    it("requires injected per-drive resolution without guessing another cwd", function()
        local strategy = {
            cwd = function() return "D:/workspace" end,
            stat = function() return { kind = "file" } end,
        }
        local found, err = driver.source_checkout_from_driver_source(
            [[@C:repo\titan-compiler\driver.lua]], nil, strategy)
        assert.is_false(found)
        assert.matches("per-drive", err, 1, true)
        strategy.absolute = function(_, filename)
            assert.equal([[C:repo\titan-compiler\driver.lua]], filename)
            return [[C:\per-drive\repo\titan-compiler\driver.lua]]
        end
        assert.is_true(driver.source_checkout_from_driver_source(
            [[@C:repo\titan-compiler\driver.lua]], nil, strategy))
    end)

    it("searches DLL containers root-major with extended-safe joins", function()
        assert.same({ "a.dll", "a/b.dll" }, driver.module_binary_candidates("a.b"))
        local observed = {}
        local mocked_native = platform.native
        platform.windows, platform.native = originals.windows, originals.native
        local context = driver.new_resolver_context()
        platform.windows, platform.native = true, mocked_native
        context.io.lstat = function(_, filename)
            observed[#observed + 1] = filename
        end
        assert.is_nil(driver.find_dynamic_interface(
            [[C:\First;\\?\D:\Second]], "a.b", context))
        assert.same({
            "C:/First/a.dll", "C:/First/a/b.dll",
            [[\\?\D:\Second\a.dll]], [[\\?\D:\Second\a\b.dll]],
        }, observed)
        context.io.lstat = function() return nil, "native access denied" end
        local value, err = driver.find_dynamic_interface("C:/First", "a.b", context)
        assert.is_nil(value)
        assert.matches("native access denied", err, 1, true)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("stops ancestor creation at the drive root and keeps stage separators", function()
        local existing = { ["C:/"] = true }
        local created = {}
        compiler_io.new_sync = function()
            return {
                stat = function(_, filename)
                    if existing[filename] then return { kind = "directory" } end
                end,
                mkdir = function(_, filename)
                    created[#created + 1] = filename
                    existing[filename] = true
                    return true
                end,
                tmpname = function() return "C:/temporary/stage" end,
                unlink = function() return true end,
            }
        end
        platform.native = function() error("unexpected native filesystem helper") end
        local staged = assert(driver.staged_library_output("C:/new/child/provider.dll"))
        assert.equal("C:/new/child/provider.dll.stage.tmp.stage/provider.dll", staged)
        assert.same({ "C:/new", "C:/new/child",
            "C:/new/child/provider.dll.stage.tmp.stage" }, created)
    end)

    it("retires only matching stale directories under their held output domain", function()
        local directory = "C:/build/lib"
        local stage = directory .. "/APP.dll.stage.tmp.old"
        local entries = {
            [directory] = { "APP.dll.stage.tmp.old", "app.dll.stage.tmp.",
                "other.dll.stage.tmp.old", "app.dll.tmp.old",
                "app.dll.stage.tmp.link", "app.dll.stage.tmp.file" },
            [stage] = { "APP.dll", "nested" },
            [stage .. "/nested"] = { "outside-link" },
        }
        local kinds = {
            [stage] = "directory", [stage .. "/APP.dll"] = "file",
            [stage .. "/nested"] = "directory",
            [stage .. "/nested/outside-link"] = "symlink",
            [directory .. "/app.dll.stage.tmp."] = "directory",
            [directory .. "/other.dll.stage.tmp.old"] = "directory",
            [directory .. "/app.dll.tmp.old"] = "directory",
            [directory .. "/app.dll.stage.tmp.link"] = "symlink",
            [directory .. "/app.dll.stage.tmp.file"] = "file",
        }
        local removed, locks = {}, { entries = { { directory = "C:/BUILD" } } }
        local strategy = {
            stat = function(_, filename)
                assert.equal(directory, filename)
                return { kind = "directory" }
            end,
            lstat = function(_, filename)
                return kinds[filename] and { kind = kinds[filename] }
            end,
            list = function(_, filename) return assert(entries[filename], filename) end,
            unlink = function(_, filename)
                assert.equal(1, #locks.entries)
                removed[#removed + 1], kinds[filename] = filename, nil
                return true
            end,
            rmdir = function(_, filename)
                assert.equal(1, #locks.entries)
                removed[#removed + 1], kinds[filename] = filename, nil
                return true
            end,
        }
        compiler_io.new_sync = function() error("unexpected host filesystem strategy") end
        -- Neither a reserved sibling nor an input below a matching link, which
        -- is never a candidate, blocks retirement of the genuine stage.
        local plan = {
            reservations = { { path = directory .. "/app.dll" } },
            inputs = { directory .. "/app.dll.stage.tmp.link/source.titan" },
            order = {},
        }
        assert(driver.cleanup_stale_staging(staging_context(strategy),
            { { path = directory .. "/app.dll" } }, locks,
            { plan = plan, native_objects = {}, link_inputs = {},
                native_policy = { cacheable = true, backend = "compiler", files = {} },
                compiler_tools = {}, output_tools = {} }))
        assert.same({ stage .. "/APP.dll", stage .. "/nested/outside-link",
            stage .. "/nested", stage }, removed)
        assert.equal("directory", kinds[directory .. "/app.dll.stage.tmp."])
        assert.equal("directory", kinds[directory .. "/other.dll.stage.tmp.old"])
        assert.equal("directory", kinds[directory .. "/app.dll.tmp.old"])
        assert.equal("symlink", kinds[directory .. "/app.dll.stage.tmp.link"])
        assert.equal("file", kinds[directory .. "/app.dll.stage.tmp.file"])
    end)

    it("rejects stale cleanup without the matching output lock before touching disk", function()
        local context = staging_context(setmetatable({}, {
            __index = function() error("cleanup touched an unlocked filesystem") end,
        }))
        local outputs = { { path = "C:/build/app.dll" } }
        local ok, err = driver.cleanup_stale_staging(context, outputs)
        assert.is_nil(ok)
        assert.matches("requires held output locks", err, 1, true)
        ok, err = driver.cleanup_stale_staging(context, outputs,
            { entries = { { directory = "C:/build-other" } } })
        assert.is_nil(ok)
        assert.matches("no output lock for 'C:/build/app.dll'", err, 1, true)
        ok, err = driver.cleanup_stale_staging(context, outputs,
            { entries = { { directory = "C:/build" } } })
        assert.is_nil(ok)
        assert.matches("requires the invocation's preflighted inputs and reservations",
            err, 1, true)
        local held = { entries = { { directory = "C:/build" } } }
        local plan = { inputs = {}, reservations = {}, order = {} }
        ok, err = driver.cleanup_stale_staging(context, outputs, held, { plan = plan })
        assert.is_nil(ok)
        assert.matches("requires the invocation's native C nodes", err, 1, true)
        -- A node from a nativeinputs result without its recorded dependency
        -- list cannot be protected, so the cleanup fails closed.
        ok, err = driver.cleanup_stale_staging(context, outputs, held, { plan = plan,
            native_objects = { { source = "C:/src/helper.c", path = "C:/build/.native/helper.o" } } })
        assert.is_nil(ok)
        assert.matches("each native C node's source and recorded dependencies", err, 1, true)
        ok, err = driver.cleanup_stale_staging(context, outputs, held,
            { plan = plan, native_objects = {} })
        assert.is_nil(ok)
        assert.matches("requires the invocation's final-link inputs", err, 1, true)
        ok, err = driver.cleanup_stale_staging(context, outputs, held,
            { plan = plan, native_objects = {}, link_inputs = {} })
        assert.is_nil(ok)
        assert.matches("requires the invocation's prepared native link policy", err, 1, true)
        ok, err = driver.cleanup_stale_staging(context, outputs, held,
            { plan = plan, native_objects = {}, link_inputs = {}, native_policy = { files = {} } })
        assert.is_nil(ok)
        assert.matches("requires the invocation's native tool identities", err, 1, true)
    end)

    -- A closed Windows strategy for stale-staging retirement. Nodes are keyed
    -- by normalized absolute spelling; every call is recorded, so a test can
    -- prove that a refusal precedes every removal.
    local function staging_model(nodes)
        local model = { calls = {}, removed = {} }
        local function record(operation, filename)
            model.calls[#model.calls + 1] = operation .. " " .. filename
        end
        local function remove(operation, filename)
            record(operation, filename)
            model.removed[#model.removed + 1], nodes[filename] = filename, nil
            return true
        end
        model.io = {
            cwd = function() return "C:/work" end,
            stat = function(_, filename)
                record("stat", filename)
                return nodes[filename]
            end,
            lstat = function(_, filename)
                record("lstat", filename)
                return nodes[filename]
            end,
            list = function(_, filename)
                record("list", filename)
                local names = {}
                for candidate in pairs(nodes) do
                    local parent, leaf = candidate:match("^(.*)/([^/]+)$")
                    if parent == filename then names[#names + 1] = leaf end
                end
                table.sort(names)
                return names
            end,
            unlink = function(_, filename) return remove("unlink", filename) end,
            rmdir = function(_, filename) return remove("rmdir", filename) end,
        }
        return model
    end

    -- The protection inventory titanc supplies: its preflighted plan, the
    -- native C nodes, the prepared final link's inputs and native library
    -- policy, and its native tools. `compiler_tools = false` models an
    -- uncertified toolchain, which titanc passes as nil.
    local function staging_protection(fields)
        local compiler_tools = fields.compiler_tools
        if compiler_tools == nil then compiler_tools = {}
        elseif compiler_tools == false then compiler_tools = nil end
        return {
            plan = { inputs = fields.inputs or {}, reservations = fields.reservations or {},
                order = fields.order or {} },
            native_objects = fields.native or {},
            link_inputs = fields.links or {},
            native_policy = fields.native_policy or
                { cacheable = true, backend = "compiler", files = fields.native_files or {} },
            compiler_tools = compiler_tools,
            output_tools = fields.output_tools or {},
        }
    end

    describe("stale stages over protected invocation paths", function()
        local bin = "C:/out/bin"
        local abandoned = bin .. "/app.exe.stage.tmp.abandoned"
        local authored = bin .. "/app.exe.stage.tmp.authored"
        local outputs = { { path = bin .. "/app.exe" }, { path = "C:/out/lib/titan/0.6/app.dll" } }
        local locks = { entries = { { directory = "C:/out", path = "C:/out/.titan-build.lock" } } }
        local previous_imported
        before_each(function()
            previous_imported = driver.imported
            compiler_io.new_sync = function() error("unexpected host filesystem strategy") end
        end)
        after_each(function() driver.imported = previous_imported end)

        -- The earlier candidate is genuinely abandoned; the later one holds the
        -- protected file, so validation must precede every removal.
        local function layout(leaf)
            return {
                ["C:/out"] = { kind = "directory" }, [bin] = { kind = "directory" },
                [abandoned] = { kind = "directory" },
                [abandoned .. "/app.exe"] = { kind = "file", device = "7", inode = "abandoned" },
                [authored] = { kind = "directory" },
                [authored .. "/" .. leaf] = { kind = "file", device = "7", inode = "authored" },
            }
        end

        for _, case in ipairs({
            { name = "a declared native object", leaf = "helper.o",
                protection = staging_protection({ inputs = { authored .. "/helper.o" } }) },
            { name = "an authored C source", leaf = "authored.c",
                protection = staging_protection({ inputs = { authored .. "/authored.c" } }) },
            { name = "a case-folded native spelling of an input", leaf = "helper.o",
                protection = staging_protection({
                    inputs = { [[c:\OUT\BIN\APP.EXE.STAGE.TMP.AUTHORED\HELPER.O]] },
                }) },
            { name = "a Titan source restored by the build", leaf = "app.titan",
                protection = staging_protection({ order = { "app" } }),
                imported = { app = { source_files = { authored .. "/app.titan" } } } },
            { name = "a C header a worker recorded after preflight", leaf = "local.h",
                protection = staging_protection({ order = { "app" } }),
                imported = { app = {
                    source_files = { "C:/src/app.titan" },
                    c_header_dependencies = { { kind = "file", path = authored .. "/local.h" } },
                } } },
            { name = "a reserved output", leaf = "app.c",
                protection = staging_protection({
                    reservations = { { path = authored .. "/app.c" } },
                }) },
            { name = "a header recorded only by --c-source preprocessing", leaf = "native.h",
                protection = staging_protection({ inputs = { "C:/src/helper.c" },
                    native = { { source = "C:/src/helper.c", path = "C:/out/.native/helper.o",
                        dependencies = { "C:/src/helper.c", authored .. "/native.h" } } } }) },
            { name = "a --c-source node's own source", leaf = "node.c",
                protection = staging_protection({
                    native = { { source = authored .. "/node.c", path = "C:/out/.native/node.o",
                        dependencies = { "C:/src/node.h" } } } }) },
            { name = "a raw final-link input outside -X", leaf = "helper.a",
                protection = staging_protection({ links = { authored .. "/helper.a" } }) },
            { name = "a native library the link policy resolved", leaf = "libhelper.a",
                protection = staging_protection({
                    links = { "C:/out/bin/app.o" },
                    native_files = { "C:/llvm/lib/libm.a", authored .. "/libhelper.a" },
                }) },
            { name = "the certified compiler executable", leaf = "clang.exe",
                protection = staging_protection({ compiler_tools = {
                    { path = "C:/llvm/bin/ccache.exe" }, { path = authored .. "/clang.exe" },
                } }) },
            { name = "a selected output tool", leaf = "llvm-rc.exe",
                protection = staging_protection({ output_tools = {
                    linker = { argv = { "ld.lld" }, identity = { path = "C:/llvm/bin/ld.lld.exe" } },
                    rc = { argv = { "llvm-rc" }, identity = { path = authored .. "/llvm-rc.exe" } },
                } }) },
            { name = "a selected LTO plugin", leaf = "LLVMgold.dll",
                protection = staging_protection({ output_tools = {
                    lto_plugins = { { argv = { authored .. "/LLVMgold.dll" },
                        identity = { path = authored .. "/LLVMgold.dll" } } },
                } }) },
            { name = "a physical alias of a staged file", leaf = "helper.o",
                protection = staging_protection({ inputs = { "C:/elsewhere/helper.o" } }),
                aliases = {
                    ["C:/elsewhere/helper.o"] = { kind = "file", device = "7", inode = "authored" },
                } },
        }) do
            it("retains every candidate when one contains " .. case.name, function()
                local nodes = layout(case.leaf)
                for filename, node in pairs(case.aliases or {}) do nodes[filename] = node end
                local model = staging_model(nodes)
                driver.imported = case.imported or {}
                local ok, err = driver.cleanup_stale_staging(
                    staging_context(model.io), outputs, locks, case.protection)
                assert.is_nil(ok)
                assert.matches("refusing to retire stale Windows staging: staging path '" ..
                    authored, err, 1, true)
                assert.matches("for final output '" .. bin .. "/app.exe'", err, 1, true)
                assert.same({}, model.removed)
                assert.equal("directory", nodes[abandoned].kind)
                assert.equal("file", nodes[abandoned .. "/app.exe"].kind)
                assert.equal("directory", nodes[authored].kind)
                assert.equal("file", nodes[authored .. "/" .. case.leaf].kind)
            end)
        end

        it("retains every candidate when a later footprint or protected path cannot be observed", function()
            local nodes = layout("helper.o")
            local model = staging_model(nodes)
            local list = model.io.list
            model.io.list = function(strategy, filename)
                if filename == authored then return nil, "list: access denied" end
                return list(strategy, filename)
            end
            local ok, err = driver.cleanup_stale_staging(staging_context(model.io), outputs, locks,
                staging_protection({}))
            assert.is_nil(ok)
            assert.matches("cannot list '" .. authored .. "': list: access denied", err, 1, true)
            assert.same({}, model.removed)

            model.io.list = list
            local lstat = model.io.lstat
            model.io.lstat = function(strategy, filename)
                if filename == "C:/src/denied.h" then return nil, "lstat: access denied" end
                return lstat(strategy, filename)
            end
            ok, err = driver.cleanup_stale_staging(staging_context(model.io), outputs, locks,
                staging_protection({ inputs = { "C:/src/denied.h" } }))
            assert.is_nil(ok)
            assert.matches("refusing to retire stale Windows staging: lstat: access denied",
                err, 1, true)
            assert.same({}, model.removed)
            assert.equal("file", nodes[abandoned .. "/app.exe"].kind)
        end)

        it("retires every candidate when protected paths only meet links or siblings", function()
            local nodes = layout("helper.o")
            -- A link inside an abandoned stage is removed, never followed; a
            -- matching link beside the stages is never a candidate.
            nodes[authored .. "/target-link"] = { kind = "symlink", device = "7", inode = "link" }
            nodes["C:/src/target.h"] = { kind = "file", device = "7", inode = "target" }
            nodes[bin .. "/app.exe.stage.tmp.user-link"] = {
                kind = "symlink", device = "7", inode = "user-link",
            }
            local model = staging_model(nodes)
            driver.imported = {
                app = { source_files = { "C:/src/app.titan" },
                    c_header_dependencies = { { kind = "file", path = "C:/src/target.h" } } },
            }
            assert(driver.cleanup_stale_staging(staging_context(model.io), outputs, locks,
                staging_protection({
                    order = { "app" },
                    reservations = { { path = bin .. "/app.exe" } },
                    inputs = { bin .. "/app.exe.stage.tmp.user-link/source.titan" },
                    native = { { source = "C:/src/helper.c", path = "C:/out/.native/helper.o",
                        dependencies = { "C:/src/helper.c", "C:/src/target.h" } } },
                    links = { "C:/out/bin/app.o" },
                    native_files = { "C:/src/libtarget.a" },
                    compiler_tools = { { path = "C:/llvm/bin/clang.exe" } },
                    output_tools = { linker = { argv = { "ld.lld" },
                        identity = { path = "C:/llvm/bin/ld.lld.exe" } } },
                })))
            assert.same({
                abandoned .. "/app.exe", abandoned,
                authored .. "/helper.o", authored .. "/target-link", authored,
            }, model.removed)
            assert.equal("symlink", nodes[bin .. "/app.exe.stage.tmp.user-link"].kind)
            assert.equal("file", nodes["C:/src/target.h"].kind)
        end)

        -- An unresolved native library policy or an uncertified tool selection
        -- leaves no evidence for a raw operand or tool inside a stage.
        for _, case in ipairs({
            { name = "an opaque native library policy",
                reason = "opaque linker input mechanism: @empty.rsp",
                fields = { links = { "C:/out/bin/app.o" }, native_policy = {
                    cacheable = false, backend = "none", argv = {},
                    reason = "opaque linker input mechanism: @empty.rsp",
                } } },
            { name = "an uncertified compiler toolchain",
                reason = "the compiler toolchain is uncertified",
                fields = { compiler_tools = false } },
            { name = "an uncertified output tool selection",
                reason = "native linker selection is unknown",
                fields = { output_tools = { uncertified = "native linker selection is unknown" } } },
        }) do
            it("retains every candidate while " .. case.name .. " leaves the inventory incomplete", function()
                local nodes = layout("helper.o")
                local model = staging_model(nodes)
                local ok, err = driver.cleanup_stale_staging(
                    staging_context(model.io), outputs, locks, staging_protection(case.fields))
                assert.is_nil(ok)
                assert.matches("refusing to retire stale Windows staging '" .. abandoned ..
                    "': the native link and tool inventory is incomplete (" .. case.reason .. ")",
                    err, 1, true)
                assert.same({}, model.removed)
                assert.equal("file", nodes[abandoned .. "/app.exe"].kind)
                assert.equal("file", nodes[authored .. "/helper.o"].kind)
            end)

            it("continues without stale candidates while " .. case.name .. " is incomplete", function()
                local nodes = {
                    ["C:/out"] = { kind = "directory" }, [bin] = { kind = "directory" },
                    [bin .. "/app.exe"] = { kind = "file", device = "7", inode = "public" },
                    [bin .. "/other.exe.stage.tmp.kept"] = { kind = "directory" },
                }
                local model = staging_model(nodes)
                assert(driver.cleanup_stale_staging(
                    staging_context(model.io), outputs, locks, staging_protection(case.fields)))
                assert.same({}, model.removed)
                assert.equal("directory", nodes[bin .. "/other.exe.stage.tmp.kept"].kind)
            end)
        end
    end)

    describe("stale stages under a deduplicated output-lock alias", function()
        local held = { kind = "file", device = "2864434397",
            inode = "000000000000000000010000000004d2" }
        local locks = { entries = { { directory = "C:/real", path = "C:/real/.titan-build.lock" } } }
        local outputs = {
            { path = "C:/alias/bin/app.exe" }, { path = "C:/real/lib/titan/0.6/app.dll" },
        }
        local stage = "C:/alias/bin/app.exe.stage.tmp.old"
        local function layout(alias_lock)
            return {
                ["C:/real"] = { kind = "directory" }, ["C:/real/.titan-build.lock"] = held,
                ["C:/alias"] = { kind = "directory" }, ["C:/alias/.titan-build.lock"] = alias_lock,
                ["C:/alias/bin"] = { kind = "directory" },
                [stage] = { kind = "directory" },
                [stage .. "/app.exe"] = { kind = "file", device = "2864434397", inode = "stage" },
            }
        end
        before_each(function()
            compiler_io.new_sync = function() error("unexpected host filesystem strategy") end
        end)

        it("retires a stage reached through another spelling of the held lock file", function()
            local model = staging_model(layout(held))
            assert(driver.cleanup_stale_staging(
                staging_context(model.io), outputs, locks, staging_protection({})))
            assert.same({ stage .. "/app.exe", stage }, model.removed)
        end)

        for _, case in ipairs({
            { name = "another domain's lock", lock = { kind = "file", device = "2864434397",
                inode = "000000000000000000010000000004d3" } },
            { name = "a lock file linked to the held one",
                lock = { kind = "symlink", device = held.device, inode = held.inode } },
            { name = "no lock file" },
            { name = "lock files without a native file ID", unavailable = true },
        }) do
            it("rejects an alias proven only by " .. case.name .. " before any listing", function()
                local nodes = layout(case.lock)
                if case.unavailable then
                    -- Native stat omits dev/ino when no file ID is available.
                    nodes["C:/real/.titan-build.lock"] = { kind = "file" }
                    nodes["C:/alias/.titan-build.lock"] = { kind = "file" }
                end
                local model = staging_model(nodes)
                local ok, err = driver.cleanup_stale_staging(
                    staging_context(model.io), outputs, locks, staging_protection({}))
                assert.is_nil(ok)
                assert.matches("no output lock for 'C:/alias/bin/app.exe'", err, 1, true)
                assert.same({}, model.removed)
                for _, call in ipairs(model.calls) do
                    assert.matches("^lstat .*/%.titan%-build%.lock$", call)
                end
                assert.equal("file", nodes[stage .. "/app.exe"].kind)
            end)
        end

        it("reports an ancestor lock inspection failure without retiring anything", function()
            local model = staging_model(layout(held))
            local lstat = model.io.lstat
            model.io.lstat = function(strategy, filename)
                if filename == "C:/alias/.titan-build.lock" then
                    return nil, "lstat: access denied"
                end
                return lstat(strategy, filename)
            end
            local ok, err = driver.cleanup_stale_staging(
                staging_context(model.io), outputs, locks, staging_protection({}))
            assert.is_nil(ok)
            assert.matches("lstat: access denied", err, 1, true)
            assert.same({}, model.removed)
        end)
    end)

    it("reports the failed staged file and still retires the other image directory", function()
        local removed = {}
        local strategy = {
            lstat = function(_, filename)
                return { kind = filename:match("%.dll$") and "file" or "directory" }
            end,
            list = function() return { "image.dll" } end,
            unlink = function(_, filename)
                removed[#removed + 1] = filename
                if filename == "C:/scratch/provider/image.dll" then
                    return nil, "image is still open"
                end
                return true
            end,
            rmdir = function(_, filename)
                removed[#removed + 1] = filename
                return true
            end,
        }
        local ok, err = driver.cleanup_staging_directories(
            { "C:/scratch/provider", "C:/scratch/launcher" }, strategy)
        assert.is_nil(ok)
        assert.matches("C:/scratch/provider/image.dll", err, 1, true)
        assert.matches("image is still open", err, 1, true)
        assert.same({ "C:/scratch/provider/image.dll",
            "C:/scratch/launcher/image.dll", "C:/scratch/launcher" }, removed)
    end)

    it("checks Windows output reservation ancestors through compiler_io without full-table LFS calls", function()
        lfs.symlinkattributes = function(path, request)
            if request == nil then
                error("full-table lfs.symlinkattributes is forbidden on Windows: " .. tostring(path))
            end
            return originals.lfs_symlinkattributes(path, request)
        end
        lfs.attributes = function(path, request)
            if request == nil then
                error("full-table lfs.attributes is forbidden on Windows: " .. tostring(path))
            end
            return originals.lfs_attributes(path, request)
        end

        local lstat_entries = {
            ["C:/"] = {
                kind = "directory", mode = 0x41ff, size = 0,
                device = "100", inode = "1",
            },
            ["C:/project"] = {
                kind = "directory", mode = 0x41ff, size = 0,
                device = "100", inode = "2",
            },
            ["C:/project/file_parent"] = {
                kind = "file", mode = 0x81b6, size = 12,
                device = "100", inode = "3",
            },
            ["C:/project/link_parent"] = {
                kind = "symlink", mode = 0xa1ff, size = 0,
                device = "100", inode = "4",
            },
        }
        local stat_entries = {
            ["C:/project/link_parent"] = {
                kind = "directory", mode = 0x41ff, size = 0,
                device = "100", inode = "5",
            },
        }
        local lstat_counts, stat_counts = {}, {}
        local io_error_path, io_error_method
        compiler_io.new_sync = function()
            return {
                cwd = function() return "C:/project" end,
                lstat = function(_, filename)
                    lstat_counts[filename] = (lstat_counts[filename] or 0) + 1
                    if io_error_method == "lstat" and filename == io_error_path then
                        return nil, "lstat: access denied: " .. filename
                    end
                    return lstat_entries[filename]
                end,
                stat = function(_, filename)
                    stat_counts[filename] = (stat_counts[filename] or 0) + 1
                    if io_error_method == "stat" and filename == io_error_path then
                        return nil, "stat: broken target: " .. filename
                    end
                    return stat_entries[filename] or lstat_entries[filename]
                end,
            }
        end

        local sources = {
            { modname = "app", output = "C:/project/build/app.titan", c_parts = 2 },
        }
        local ok, err = driver.validate_program_output_paths(
            sources, "C:/project/build/bin/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_true(ok, err)
        assert.equal(1, lstat_counts["C:/"])
        assert.equal(1, lstat_counts["C:/project"])
        assert.equal(1, lstat_counts["C:/project/build"])

        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/file_parent/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("output parent 'C:/project/file_parent' is not a directory", err, 1, true)

        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/link_parent/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_true(ok, err)
        assert.equal(1, stat_counts["C:/project/link_parent"])

        stat_entries["C:/project/link_parent"] = {
            kind = "file", mode = 0x81b6, size = 12,
            device = "100", inode = "6",
        }
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/link_parent/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("output parent 'C:/project/link_parent' is not a directory", err, 1, true)

        stat_entries["C:/project/link_parent"] = {
            kind = "directory", mode = 0x41ff, size = 0,
            device = "100", inode = "5",
        }
        lstat_entries["C:/project/build/app.o"] = {
            kind = "file", mode = 0x81b6, size = 64,
            device = "100", inode = "99",
        }
        lstat_entries["C:/project/hardlinked_input.o"] = {
            kind = "file", mode = 0x81b6, size = 64,
            device = "100", inode = "99",
        }
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/build/bin/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c",
            { "C:/project/hardlinked_input.o" })
        assert.is_nil(ok)
        assert.matches("aliases input 'C:/project/hardlinked_input.o'", err, 1, true)

        lstat_entries["C:/project/build/app.o"] = {
            kind = "file", mode = 0x81b6, size = 64,
        }
        lstat_entries["C:/project/hardlinked_input.o"] = {
            kind = "file", mode = 0x81b6, size = 64,
        }
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/build/bin/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c",
            { "C:/project/hardlinked_input.o" })
        assert.is_true(ok, err)
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/build/bin/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c",
            { [[c:\PROJECT\build\APP.O]] })
        assert.is_nil(ok)
        assert.matches("aliases input", err, 1, true)

        io_error_method = "lstat"
        io_error_path = "C:/project"
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/build/bin/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("lstat: access denied: C:/project", err, 1, true)

        io_error_method = "stat"
        io_error_path = "C:/project/link_parent"
        ok, err = driver.validate_program_output_paths(
            sources, "C:/project/link_parent/app.exe",
            "C:/project/build/synthetic/app__entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("stat: broken target: C:/project/link_parent", err, 1, true)
    end)
end)

local function empty_layouts(name)
    return (assert(require("titan-compiler.nominallayout").encode(name, {})))
end

describe("generated output folders", function()
    it("maps flat and folder modules relative to their selected source tree", function()
        local output = paths.join(lfs.currentdir(), "build output")
        for _, source_name in ipairs({ "src/pkg/mod.titan", "/external/src/pkg/mod.titan" }) do
            local source = { kind = "flat", main = source_name,
                files = { source_name }, program_output = "pkg/mod" }
            assert(driver.relocate_source_output("pkg.mod", source, output))
            assert.equal(paths.join(output, "pkg/mod.titan"), source.native_output)
            assert.equal(paths.join(output, "pkg/mod"), source.program_output)
            assert.equal(source_name, source.main)
            assert(driver.relocate_source_output("pkg.mod", source, output))
            assert.equal(paths.join(output, "pkg/mod"), source.program_output)
        end
        local folder = { kind = "folder", main = "/external/src/pkg/mod/mod.titan",
            program_output = "pkg/mod__main" }
        assert(driver.relocate_source_output("pkg.mod", folder, output))
        assert.equal(paths.join(output, "pkg/mod/mod.titan"), folder.native_output)
        assert.equal(paths.join(output, "pkg/mod__main"), folder.program_output)
    end)

    it("creates a relative output folder recursively and rejects regular files", function()
        local root = temporary.name("-output-folder")
        local relative = paths.join(".", paths.basename(root), "nested", "output")
        local absolute = assert(driver.prepare_output_root(relative))
        assert.equal("directory", lfs.attributes(absolute, "mode"))
        assert(paths.is_absolute(absolute))
        assert(driver.remove_path(paths.join(lfs.currentdir(), paths.basename(root))))
        local file = temporary.name()
        local output, err = driver.prepare_output_root(file)
        assert.is_nil(output)
        assert.matches("not a directory", err, 1, true)
        assert(os.remove(file))
    end)

    it("places providers in the output tree", function()
        local root = temporary.name("-output-provider")
        local provider = driver.provider_output_path("package", root)
        assert.equal(paths.join(root, "package" .. (platform.windows and ".dll" or ".so")), provider)
        local missing, err = driver.provider_output_path("bad..name", root)
        assert.is_nil(missing)
        assert.equal("invalid library provider name 'bad..name'", err)
    end)

    it("creates output-local temporaries without renaming across filesystems", function()
        local root = temporary.name("-output-temporaries")
        assert(lfs.mkdir(root))
        local strategy = compiler_io.new_sync()
        local rename = strategy.rename
        local cross_filesystem_attempts = 0
        function strategy:rename(from, to)
            if paths.dirname(from) ~= paths.dirname(to) then
                cross_filesystem_attempts = cross_filesystem_attempts + 1
                return nil, "cross-device link"
            end
            return rename(self, from, to)
        end
        local context = driver.new_resolver_context({ io = strategy, output_root = root })
        local filename = assert(context.io:tmpname())
        assert.equal(paths.normalize(root), paths.dirname(filename))
        assert.equal("file", lfs.attributes(filename, "mode"))
        assert.equal(0, cross_filesystem_attempts)
        assert(context.io:unlink(filename))
        assert(driver.close_resolver_context(context))
        assert(lfs.rmdir(root))
    end)

    it("preserves mkdir semantics for a symlink followed by a parent component", function()
        if platform.windows then
            pending("POSIX symbolic-link and parent-component filesystem semantics")
            return
        end
        local root = temporary.name("-output-parent")
        assert(lfs.mkdir(root))
        assert(lfs.mkdir(root .. "/nested"))
        assert(lfs.mkdir(root .. "/nested/target"))
        assert(lfs.link(root .. "/nested/target", root .. "/alias", true))
        local output = assert(driver.prepare_output_root(root .. "/alias/../actual"))
        assert.equal(assert(compiler_io.new_sync():realpath(root .. "/nested/actual")), output)
        assert.equal("directory", lfs.attributes(root .. "/nested/actual", "mode"))
        assert.is_nil(lfs.attributes(root .. "/actual"))
        assert(driver.remove_path(root))
    end)
end)

describe("Windows launcher filenames", function()
    it("uses the logical module and keeps overrides independent of the provider", function()
        assert.equal("app.exe", driver.windows_launcher_name("app"))
        assert.equal("app.main.exe", driver.windows_launcher_name("app.main"))
        assert.equal("custom.exe", driver.windows_launcher_name("app.main", "custom"))
        assert.equal("custom.EXE", driver.windows_launcher_name("app.main", "custom.EXE"))
        local original = assert(driver.windows_program_paths("app.main"))
        local renamed = assert(driver.windows_program_paths("app.main", "renamed"))
        local in_bin = assert(driver.windows_program_paths("app.main", "bin/renamed"))
        assert.equal("bin/app.main.exe", original.executable)
        assert.equal("renamed.exe", renamed.executable)
        assert.equal(paths.normalize("bin/renamed.exe"), in_bin.executable)
        assert.equal(original.provider, renamed.provider)
        assert.equal(original.provider, in_bin.provider)
        assert.equal("lib/titan/0.6/app/main.dll", original.provider)
        assert.equal("app/main.dll", original.relative_provider)
        assert.equal("app/main.dll", in_bin.relative_provider)
        local suite = assert(driver.windows_program_paths("titan.test_runner", nil, "app.tests"))
        assert.equal("bin/app.tests.exe", suite.executable)
        assert.equal("app/tests.dll", suite.relative_provider)
    end)

    it("relocates Windows program artifacts under an optional output root and explicit --exe", function()
        local root = temporary.name("-coverage-output")
        local original = assert(driver.windows_program_paths("app.main", "bin/display"))
        local covered = assert(driver.windows_program_paths(
            "app.main", paths.join(root, "bin/display"), nil, root))
        assert.equal(paths.join(root, original.executable), covered.executable)
        assert.equal(paths.join(root, original.provider), covered.provider)
        assert.equal(original.relative_provider, covered.relative_provider)
        local direct = assert(driver.windows_program_paths("app.main", "display", nil, root))
        assert.equal("display.exe", direct.executable)
        assert.equal(paths.join(root, original.provider), direct.provider)
        local suite = assert(driver.windows_program_paths("titan.test_runner", nil, "app.tests", root))
        assert.equal(paths.join(root, "bin/app.tests.exe"), suite.executable)
        assert.equal(paths.join(root, "lib/titan/0.6/app/tests.dll"), suite.provider)
        assert.equal("app/tests.dll", suite.relative_provider)
    end)

    it("rejects path syntax, reserved names, controls and ambiguous endings", function()
        for _, name in ipairs({ "", ".", "..", "a/b", "a\\b", "C:app", "app:stream",
            'quote"name', "a*b", "a?b", "a|b", "<app>", "app.", "app ",
            "con", "NUL.txt", "COM1.exe", "LPT9", "COM¹.exe", "LPT³", "CONIN$",
            "CONOUT$", "CON .exe", "app" .. string.char(0), "app" .. string.char(31),
            "app" .. string.char(127), string.char(255) }) do
            local value, err = driver.windows_launcher_name("app", name)
            assert.is_nil(value, name)
            assert.matches("--exe", err, 1, true)
        end
    end)

    it("accepts Unicode names and bounds UTF-16 component length", function()
        assert.equal("aplicação ü.exe", driver.windows_launcher_name("app", "aplicação ü"))
        assert.equal("COM10.exe", driver.windows_launcher_name("app", "COM10"))
        assert.truthy(driver.windows_launcher_name("app", string.rep("x", 251)))
        assert.is_nil(driver.windows_launcher_name("app", string.rep("x", 252)))
        assert.truthy(driver.windows_launcher_name("app", string.rep("😀", 125)))
        assert.is_nil(driver.windows_launcher_name("app", string.rep("😀", 126)))
    end)

    it("rejects a missing DLL inventory before replacing an existing provider", function()
        local platform = require "titan-compiler.platform"
        local filename = temporary.name()
        assert(util.set_file_contents(filename, "existing provider"))
        local previous = platform.windows
        platform.windows = true
        local called, ok, err = pcall(driver.compile_library_output, filename, {})
        platform.windows = previous
        local contents = util.get_file_contents(filename)
        os.remove(filename)
        assert.truthy(called)
        assert.is_nil(ok)
        assert.matches("logical module inventory", err, 1, true)
        assert.equal("existing provider", contents)
    end)

    it("validates selected archive metadata before emitting a launcher", function()
        -- Isolate this pure Windows model's runtime acceptance cache from the
        -- shared driver used by real compiler and filesystem fixtures.
        local driver = assert(loadfile("titan-compiler/driver.lua"))()
        driver.INSTALLED = true
        local platform = require "titan-compiler.platform"
        local previous_native = platform.native
        local previous_sync = compiler_io.new_sync
        local previous_windows, previous_cwd = platform.windows, lfs.currentdir()
        local directory = temporary.name()
        os.remove(directory)
        assert(lfs.mkdir(directory))
        local saved, calls = {}, {}
        for _, name in ipairs({ "compile_library_output", "validate_library_image",
            "validate_library_image_fresh" }) do
            saved[name] = driver[name]
        end
        local entries = { archive = { abi = "2", types = "embedded", layouts = "layout" } }
        local names = { "archive" }
        driver.compile_library_output = function() return true end
        driver.validate_library_image = function() error("coordinator mapped a staged DLL") end
        driver.validate_library_image_fresh = function(_, expected, required)
            if expected == nil then
                assert.same({ "app", "archive" }, required)
                calls[#calls + 1] = "image"
                return true
            end
            assert.equal(entries, expected)
            assert.equal(names, required)
            calls[#calls + 1] = "metadata"
            return nil, "archive metadata mismatch"
        end
        local ran, failure = pcall(function()
            assert(lfs.chdir(directory))
            local real_sync = previous_sync()
            compiler_io.new_sync = function()
                return setmetatable({
                    stat = function() return { kind = "directory" } end,
                    mkdir = function() return true end,
                }, { __index = real_sync })
            end
            platform.windows = true
            local options = { module_names = { "app", "archive" },
                archive_entries = entries, archive_names = names }
            local ok, err = driver.compile_program("app", {}, nil, false,
                nil, nil, nil, "entrypoint.c", nil, options)
            assert.is_nil(ok)
            assert.equal("archive metadata mismatch", err)
            assert.same({ "image", "metadata" }, calls)
            assert.is_nil(lfs.attributes("entrypoint.c"))
            assert.is_nil(lfs.attributes("bin/app.exe"))
        end)
        platform.windows = previous_windows
        platform.native = previous_native
        compiler_io.new_sync = previous_sync
        assert(lfs.chdir(previous_cwd))
        for name, fn in pairs(saved) do driver[name] = fn end
        driver.remove_path(directory)
        assert.truthy(ran, failure)
    end)

    it("reports staging cleanup failure after committing a Windows program", function()
        local subject = assert(loadfile("titan-compiler/driver.lua"))()
        local process = require "titan-compiler.process"
        local publication = require "titan-compiler.windows_publication"
        local previous = { windows = platform.windows, getenv = platform.getenv,
            native = platform.native, sync = compiler_io.new_sync,
            run = process.run, write = util.set_file_contents,
            publish = publication.publish_program }
        local committed, retired, fresh = false, nil, false
        local completed, failure = xpcall(function()
            platform.windows = true
            platform.getenv = function() return nil end
            platform.native = function() error("unexpected native call in Windows publication model") end
            compiler_io.new_sync = function()
                return { stat = function() return { kind = "directory" } end }
            end
            subject.INSTALLED, subject.UNAME, subject.IS_DARWIN = true, "Windows", false
            subject.INSTALL_PATHS = subject.installed_paths("C:/SDK")
            subject.BUILD_PROFILE, subject.CFLAGS, subject.CC = "development", "-O0", "clang"
            subject.TOOLCHAIN_ERROR = nil
            subject.compile_library_output = function() return true end
            subject.staged_library_output = function(filename)
                local basename = filename:match("([^/\\]+)$")
                local directory = filename .. ".stage.tmp.model"
                return directory .. "/" .. basename, directory
            end
            subject.validate_library_image = function() error("coordinator mapped a staged DLL") end
            subject.validate_library_image_fresh = function(_, expected, names)
                assert.is_nil(expected)
                assert.same({ "app" }, names)
                fresh = true
                return true
            end
            subject.generated_compile_prefix = function() return { "clang" } end
            subject.entrypoint_contents = function() return "generated entrypoint" end
            subject.format_generated_file = function() return true end
            subject.run_link_command = function() return true end
            process.run = function() return true, "exit", 0 end
            util.set_file_contents = function() return true end
            publication.publish_program = function(images)
                assert.is_true(fresh)
                assert.equal(paths.normalize("C:/build/lib/titan/0.6/app.dll"), images.provider.destination)
                assert.equal(paths.normalize("C:/build/bin/app.exe"), images.executable.destination)
                committed = true
                return true
            end
            subject.cleanup_staging_directories = function(directories)
                assert.is_true(committed)
                retired = directories
                return nil, "cannot remove '" .. directories[1] .. "/app.dll': access denied"
            end
            local ok, err = subject.compile_program("app", {}, nil, false,
                nil, nil, nil, "C:/build/entrypoint.c", nil,
                { output_root = "C:/build", module_names = { "app" } })
            assert.is_nil(ok)
            assert.matches("Windows program publication committed but staging cleanup failed", err, 1, true)
            assert.matches(retired[1] .. "/app.dll", err, 1, true)
            assert.matches("access denied", err, 1, true)
            assert.same({ paths.normalize("C:/build/lib/titan/0.6/app.dll.stage.tmp.model"),
                paths.normalize("C:/build/bin/app.exe.stage.tmp.model") }, retired)
        end, debug.traceback)
        platform.windows, platform.getenv, platform.native =
            previous.windows, previous.getenv, previous.native
        compiler_io.new_sync, process.run, util.set_file_contents =
            previous.sync, previous.run, previous.write
        publication.publish_program = previous.publish
        assert.is_true(completed, failure)
    end)
end)

describe("Windows provider export inventory", function()
    it("exports raw public foreign entries under the final DLL name", function()
        local signature = types.CFunction({}, types.CVoid(), false, nil)
        local interface = types.Module("pkg.alpha", {
            types.ModuleMember("pkg.alpha", "raw", signature, {}),
        })
        interface.source_members = {
            types.ModuleMember("pkg.alpha", "private_raw", signature, {}),
        }
        local definition, names = driver.windows_provider_exports(
            { "pkg.alpha" }, { ["pkg.alpha"] = interface }, "public/provider.dll")
        assert.matches('LIBRARY "provider.dll"\nEXPORTS\n', definition, 1, true)
        local symbol = coder.foreign_external_symbols("pkg.alpha", interface)[1]
        assert.matches(symbol, definition, 1, true)
        assert.not_matches("private_raw", definition, 1, true)
        assert.equal(8, #names)
    end)

    it("exports only the module protocol in stable linker order", function()
        local expected = {
            "luaopen_pkg_alpha", "luaopen_pkg_zeta",
            "pkg_alpha_abi", "pkg_alpha_abi_value", "pkg_alpha_compatibility",
            "pkg_alpha_init", "pkg_alpha_layouts", "pkg_alpha_types",
            "pkg_zeta_abi", "pkg_zeta_abi_value", "pkg_zeta_compatibility",
            "pkg_zeta_init", "pkg_zeta_layouts", "pkg_zeta_types",
        }
        local definition, names = driver.windows_provider_exports({
            "pkg.zeta", "pkg.alpha",
        })
        assert.same(expected, names)
        assert.equal("EXPORTS\n    " .. table.concat(expected, "\n    ") .. "\n",
            definition)
        local reordered, reordered_names = driver.windows_provider_exports({
            "pkg.alpha", "pkg.zeta",
        })
        assert.equal(definition, reordered)
        assert.same(expected, reordered_names)
    end)

    it("rejects repeated modules and colliding mangled identities", function()
        for _, modules in ipairs({
            { "pkg.alpha", "pkg.alpha" },
            { "pkg.alpha", "pkg_alpha" },
            { "pkg-alpha", "pkg_alpha" },
        }) do
            assert.has_error(function()
                driver.windows_provider_exports(modules)
            end, "duplicate Windows module export pkg_alpha_abi_value")
        end
    end)
end)

describe("Windows launcher generation", function()
    local platform = require "titan-compiler.platform"
    local previous_windows
    before_each(function()
        previous_windows = platform.windows
        platform.windows = true
    end)
    after_each(function()
        platform.windows = previous_windows
    end)

    it("keeps the provider, ABI and opener identities when the launcher is renamed", function()
        local original_loader
        for _, display in ipairs({ "original.exe", "renamed.exe" }) do
            local source = driver.entrypoint_contents("pkg.main-module", display,
                { provider = "pkg/bundle.dll" })
            local compact = source:gsub("%s+", " ")
            local selected = assert(compact:find(
                'titan_module_provider(L, "pkg.main-module", "pkg/bundle.dll")',
                1, true))
            local checked = assert(compact:find(
                'titan_check_module_abi(L, provider, "pkg_main_module_abi", "pkg/bundle.dll")',
                1, true))
            local opened = assert(compact:find(
                'titan_module_symbol(L, provider, "luaopen_pkg_main_module")',
                1, true))
            assert.is_true(selected < checked and checked < opened)
            assert.matches('lua_pushcfunction(L, titan_open_main);', source, 1, true)
            assert.matches('lua_setfield(L, -2, "pkg.main-module");', source, 1, true)
            assert.matches('"' .. display .. '", message)', source, 1, true)
            assert.not_matches('int luaopen_pkg_main_module(', source, 1, true)
            local loader = assert(source:match(
                "static int titan_open_main%(lua_State %*L%) %b{}"))
            if original_loader then assert.equal(original_loader, loader) end
            original_loader = loader
        end
    end)

    it("preserves literal display and provider bytes through template rendering", function()
        local display = assert(driver.windows_launcher_name("pkg.main",
            "ação $MODNAME ${UNKNOWN} 9"))
        local source = driver.entrypoint_contents("pkg.main", display, {
            provider = [[bundle\ação\$MODNAME.dll]],
        })
        local display_literal = [["a\303\247\303\243o \044MODNAME \044{UNKNOWN} 9.exe"]]
        local provider_literal = [["bundle\134a\303\247\303\243o\134\044MODNAME.dll"]]
        assert.matches(display_literal .. ", message)", source, 1, true)
        assert.matches('"pkg.main", ' .. provider_literal, source, 1, true)
        assert.matches('"pkg_main_abi", ' .. provider_literal, source, 1, true)
        assert.not_matches("$MODNAME", source, 1, true)
        assert.not_matches("${UNKNOWN}", source, 1, true)
    end)

    it("keeps module loading and argument setup while selecting the bootstrap policy", function()
        for _, direct in ipairs({ false, true }) do
            local source = driver.entrypoint_contents("pkg.main", nil, {
                provider = "pkg/main.dll", no_uv_bootstrap = direct,
            })
            assert.matches('"main", message)', source, 1, true)
            local arguments = assert(source:find("TITAN_MAIN_ARGV_KEY", 1, true))
            local require_main = assert(source:find('lua_pushliteral(L, "pkg.main");', 1, true))
            local bootstrap = assert(source:find(
                "lua_getfield(L, LUA_REGISTRYINDEX, TITAN_MAIN_BOOTSTRAP_KEY);", 1, true))
            assert.is_true(arguments < require_main and require_main < bootstrap)
            assert.matches("if (" .. (direct and "1" or "0") ..
                " || lua_isnil(L, -1))", source, 1, true)
            assert.matches("lua_call(L, 1, 1);", source, 1, true)
            assert.matches("lua_call(L, 2, 1);", source, 1, true)
        end
    end)

    it("requires the selected provider instead of deriving it from the display name", function()
        assert.has_error(function()
            driver.entrypoint_contents("pkg.main", "renamed.exe")
        end, "Windows entrypoint requires an explicit provider")
    end)
end)

describe("Windows native ABI bootstrap", function()
    local platform = require "titan-compiler.platform"
    local previous_windows, previous_loadlib, previous_abivalue
    local events, native_value, native_stage, claimed
    local serialized = types.serialize(types.Module("winabi", {}, {}))

    before_each(function()
        previous_windows = platform.windows
        previous_loadlib, previous_abivalue = titan._loadlib, titan._abivalue
        platform.windows = true
        events, native_value, native_stage, claimed = {}, driver.TITAN_ABI_VERSION, nil, true
        titan._abivalue = function(path, symbol)
            assert.equal("provider.dll", path)
            assert.equal("winabi_abi_value", symbol)
            events[#events + 1] = "native query"
            return native_value, "native query diagnostic", native_stage
        end
        titan._loadlib = function(_, symbol)
            events[#events + 1] = "resolve " .. symbol
            if claimed and symbol == "winabi_abi" then
                return function()
                    events[#events + 1] = "Lua ABI"
                    return driver.TITAN_ABI_VERSION
                end
            elseif claimed and symbol == "winabi_types" then
                return function()
                    events[#events + 1] = "Lua types"
                    return serialized
                end
            end
            return nil, "missing export", "init"
        end
    end)

    after_each(function()
        platform.windows = previous_windows
        titan._loadlib, titan._abivalue = previous_loadlib, previous_abivalue
    end)

    local function probe()
        return driver.probe_compiled_interface("winabi", "provider.dll",
            { analysis_only = true })
    end

    it("checks the plain-C value before entering any provider Lua function", function()
        local status, module = probe()
        assert.equal("valid", status)
        assert.equal(serialized, types.serialize(module))
        assert.same({ "native query", "resolve winabi_abi", "resolve winabi_types",
            "Lua ABI", "Lua types" }, events)
    end)

    it("rejects a native ABI mismatch without resolving Lua entries", function()
        native_value = "999"
        local status, err = probe()
        assert.equal("error", status)
        assert.matches("ABI mismatch", err, 1, true)
        assert.same({ "native query" }, events)
    end)

    it("rejects a legacy-only claimed module without invoking its Lua entries", function()
        native_value, native_stage = nil, "init"
        local status, err = probe()
        assert.equal("error", status)
        assert.matches("missing native ABI query 'winabi_abi_value'", err, 1, true)
        assert.same({ "native query", "resolve winabi_abi", "resolve winabi_types" }, events)
    end)

    it("preserves a clean nonclaim when all logical metadata exports are absent", function()
        native_value, native_stage, claimed = nil, "init", false
        assert.equal("nonclaim", probe())
        assert.same({ "native query", "resolve winabi_abi", "resolve winabi_types" }, events)
    end)

    it("treats a native query alone as a claimed incomplete module", function()
        claimed = false
        local status, err = probe()
        assert.equal("error", status)
        assert.matches("missing metadata symbol 'winabi_abi'", err, 1, true)
    end)

    for _, stage in ipairs({ "open", "abi" }) do
        it("keeps a native " .. stage .. " failure terminal", function()
            native_value, native_stage, claimed = nil, stage, false
            local status, err = probe()
            assert.equal("error", status)
            assert.matches("native query diagnostic", err, 1, true)
            assert.same({ "native query" }, events)
        end)
    end

    it("rejects a malformed native value before entering Lua metadata", function()
        native_value = false
        local status, err = probe()
        assert.equal("error", status)
        assert.matches("must return a string", err, 1, true)
        assert.same({ "native query" }, events)
    end)

    it("retains Unix support for ABI-2 providers without a native query", function()
        platform.windows = false
        titan._abivalue = function() error("Unix must retain the Lua ABI protocol") end
        assert.equal("valid", probe())
        assert.same({ "resolve winabi_abi", "resolve winabi_types",
            "Lua ABI", "Lua types" }, events)
    end)
end)

local function write_file(path, contents)
    local previous = lfs.attributes(path, "modification")
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
    if previous then assert(lfs.touch(path, previous + 1, previous + 1)) end
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

describe("independent nominal layout metadata", function()
    local previous_loadlib
    local serialized = types.serialize(types.Module("physical", {}, {}))
    local layouts
    local requested

    before_each(function()
        previous_loadlib = titan._loadlib
        layouts = assert(require("titan-compiler.nominallayout").encode("physical", {}))
        requested = {}
        titan._loadlib = function(_, symbol)
            requested[#requested + 1] = symbol
            if symbol == "physical_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "physical_types" then
                return function() return serialized end
            elseif symbol == "physical_layouts" and layouts then
                return function() return layouts end
            end
            return nil, "undefined symbol", "init"
        end
    end)

    after_each(function() titan._loadlib = previous_loadlib end)

    posix_model_it("loads separate physical plans only for native consumers", function()
        local status, modtype, metadata = driver.probe_compiled_interface("physical", "physical.so")
        assert.equal("valid", status)
        assert.equal(serialized, types.serialize(modtype))
        assert.equal(layouts, metadata.layouts)
        assert.same({}, metadata.layout_inventory.layouts)
        assert.same({ "physical_abi", "physical_types", "physical_layouts" }, requested)
        requested = {}
        layouts = nil
        status, modtype, metadata = driver.probe_compiled_interface(
            "physical", "physical.so", { analysis_only = true })
        assert.equal("valid", status)
        assert.equal(serialized, types.serialize(modtype))
        assert.is_nil(metadata.layouts)
        assert.is_nil(metadata.layout_inventory)
        assert.same({ "physical_abi", "physical_types" }, requested)
    end)

    posix_model_it("rejects absent and invalid physical plans before native access", function()
        layouts = nil
        local status, err = driver.probe_compiled_interface("physical", "physical.so")
        assert.equal("error", status)
        assert.matches("missing metadata symbol 'physical_layouts'", err, 1, true)
        layouts = "malformed"
        status, err = driver.probe_compiled_interface("physical", "physical.so")
        assert.equal("error", status)
        assert.matches("invalid nominal layout metadata", err, 1, true)
    end)

    it("includes physical plans in archive and callable protocol equality", function()
        local expected = { physical = { abi = driver.TITAN_ABI_VERSION,
            types = serialized, layouts = layouts } }
        assert(driver.compare_archive_entries(expected, expected, "provider"))
        local actual = { physical = { abi = driver.TITAN_ABI_VERSION,
            types = serialized, layouts = "other" } }
        local valid, err = driver.compare_archive_entries(actual, expected, "provider")
        assert.is_nil(valid)
        assert.matches("nominal layout metadata", err, 1, true)
    end)
end)

describe("compiler installation discovery", function()
    it("exports the language-server compiler API independently of the ABI",
       function()
        assert.equal("2", driver.TITAN_ABI_VERSION)
        assert.equal("0.6.0", driver.TITAN_VERSION)
        assert.equal("0.6", driver.TITAN_LIBRARY_VERSION)
        assert.equal("_0_6", driver.TITAN_LIBRARY_VERSION_SUFFIX)
        assert.equal(1, driver.LANGUAGE_SERVER_API_VERSION)
        assert.is_function(driver.serialize_source_interface)
        assert.is_function(driver.restat_c_header_dependencies)
        assert.is_function(driver.language_server_cache_identity)
        assert.is_function(driver.encode_project_entry)
        assert.is_function(driver.compact_project_entry)
        assert.is_function(driver.decode_project_entry)
    end)

    it("surfaces the runtime's own reason when it cannot resolve the compiler root",
       function()
        local original_getenv = platform.getenv
        local original_driver = package.loaded["titan-compiler.driver"]
        local original_titan = package.loaded.titan
        local reason = "cannot determine the compiler root from argv[0]"
        local subject
        local completed, failure = xpcall(function()
            platform.getenv = function(name)
                if name == "TITAN_ROOT" then return nil end
                return original_getenv(name)
            end
            -- The runtime owns root discovery; an unusable answer carries its
            -- own reason and must reach the caller unchanged.
            package.loaded.titan = {
                _compiler_root = function() return nil, reason end,
            }
            package.loaded["titan-compiler.driver"] = nil
            subject = require "titan-compiler.driver"
        end, debug.traceback)
        package.loaded.titan = original_titan
        package.loaded["titan-compiler.driver"] = original_driver
        platform.getenv = original_getenv
        assert.truthy(completed, failure)
        local root, err = subject.compiler_root(compiler_io.new_sync())
        assert.is_nil(root)
        assert.equal(reason, err)
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

    it("keeps analysis-scoped C state out of checker fallback configuration",
    function()
        local cdriver = require "c-parser.cdriver"
        local csemantics = require "titan-compiler.csemantics"
        local checker = require "titan-compiler.checker"
        local originals = {
            initialize_platform = driver.initialize_platform,
            toolchain_descriptor = driver.toolchain_descriptor,
            target_profile_inputs = cdriver.target_profile_inputs,
            build_profile = csemantics.build_profile,
            configure_foreign_c = checker.configure_foreign_c,
            target_profile = driver.TARGET_PROFILE,
            configuration_id = driver.FOREIGN_C_CONFIGURATION_ID,
        }
        local captured
        local target_analysis
        local target_trace
        local target_adapter

        local completed, failure = xpcall(function()
            driver.initialize_platform = function()
                return true, "TestOS", false
            end
            driver.toolchain_descriptor = function(context)
                return {
                    io = context.io,
                    compiler_argv = { "cc" },
                    compile_flags = {},
                    language_mode = "c99",
                    language_flag = false,
                    cppflags = {},
                    cflags = {},
                    include_dirs = {},
                }
            end
            cdriver.target_profile_inputs = function(options)
                target_analysis = options.process_analysis
                target_trace = options.process_trace
                target_adapter = options.cache_adapter
                return {}
            end
            csemantics.build_profile = function()
                return { identity = "fixture-profile" }
            end
            checker.configure_foreign_c = function(options, config_error)
                assert.is_nil(config_error)
                captured = options
            end

            local analysis = driver.new_c_header_analysis()
            local function trace() end
            local adapter = { get = function() end }
            local context = driver.new_resolver_context({
                target = "native",
                io = compiler_io.new_sync(),
                c_header_analysis = analysis,
                c_header_process_trace = trace,
                cache_adapter = adapter,
            })
            assert.is_true(driver.configure_foreign_c(context))
            assert.equal(analysis, target_analysis)
            assert.equal(trace, target_trace)
            assert.equal(adapter, target_adapter)
            assert.is_nil(captured.process_analysis)
            assert.is_nil(captured.process_trace)
            assert.is_nil(captured.cache_adapter)
            assert.equal(context.io, captured.io)
            assert.is_nil(captured.probe_runner)
        end, debug.traceback)

        driver.initialize_platform = originals.initialize_platform
        driver.toolchain_descriptor = originals.toolchain_descriptor
        cdriver.target_profile_inputs = originals.target_profile_inputs
        csemantics.build_profile = originals.build_profile
        checker.configure_foreign_c = originals.configure_foreign_c
        driver.TARGET_PROFILE = originals.target_profile
        driver.FOREIGN_C_CONFIGURATION_ID = originals.configuration_id
        assert.truthy(completed, failure)
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

    posix_model_it("initializes uname at resolver construction and reuses it", function()
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
        local previous_uname = driver.UNAME
        local previous_is_darwin = driver.IS_DARWIN
        local context = driver.new_resolver_context({ io = strategy })
        assert.equal(1, #commands)

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

    posix_model_it("initializes native publication flags through a resolver strategy",
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
        local previous_uname = driver.UNAME
        local previous_is_darwin = driver.IS_DARWIN
        local context = driver.new_resolver_context({ io = strategy })
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

    posix_model_it("surfaces resolver strategy failures at public driver boundaries",
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
                source_process_trace = true,
            })
        end, "source_process_trace must be a function")
        assert.has_error(function()
            driver.new_resolver_context({
                source_process_trace = function() end,
                c_header_process_trace = true,
            })
        end, "c_header_process_trace must be a function")
        assert.has_error(function()
            driver.new_resolver_context({
                c_probe_cache_trace = true,
            })
        end, "c_probe_cache_trace must be a function")
        assert.has_error(function()
            driver.new_resolver_context({
                c_probe_semantic_trace = true,
            })
        end, "c_probe_semantic_trace must be a function")
        assert.has_error(function()
            driver.new_resolver_context({
                c_probe_execution_trace = true,
            })
        end, "c_probe_execution_trace must be a function")
        assert.has_error(function()
            driver.new_resolver_context({
                extra_ffi_include_dirs = "invalid",
            })
        end, "invalid extra_ffi_include_dirs: compiler include dirs must be " ..
            "an ordered array")

        local failed_platform = driver.new_resolver_context({ target = "native" })
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

        local empty_platform = driver.new_resolver_context({ target = "native" })
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

    posix_model_it("distinguishes realpath, stat, and provider inspection failures",
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

    -- Load a fresh driver with `values` overlaid on the host environment;
    -- `false` unsets a variable.
    local function driver_with_environment(values)
        local module_name = "titan-compiler.driver"
        local loaded_driver = package.loaded[module_name]
        local original_getenv = platform.getenv
        package.loaded[module_name] = nil
        platform.getenv = function(name)
            local value = values[name]
            if value == false then return nil end
            if value ~= nil then return value end
            return original_getenv(name)
        end
        local loaded, value = pcall(require, module_name)
        platform.getenv = original_getenv
        package.loaded[module_name] = loaded_driver
        assert.truthy(loaded, value)
        return value
    end

    -- Run `body` while `require "titan"` yields `support`: a table, or a
    -- string that loading the module raises.
    local function with_support(support, body)
        local loaded, preload = package.loaded.titan, package.preload.titan
        package.loaded.titan = nil
        package.preload.titan = function()
            if type(support) == "string" then error(support, 0) end
            return support
        end
        local results = table.pack(pcall(body))
        package.loaded.titan, package.preload.titan = loaded, preload
        assert.truthy(results[1], results[2])
        return table.unpack(results, 2, results.n)
    end

    it("reports unloadable native support as the missing installation root",
       function()
        local reason = "cannot load the Titan support module: simulated missing support"
        local missing = "simulated missing support\n\tno file 'titan.so'"
        local sync = compiler_io.new_sync()
        -- Driver provenance is a checkout only when the tree has the runtime
        -- source and Makefile; the strategy decides that for this case.
        local function layout(checkout)
            return with_support(missing, function()
                local unloaded = driver_with_environment({
                    TITAN_ROOT = false, TITAN_BUILD_PROFILE = false,
                    TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "",
                    TITAN_EXTRA_LDFLAGS = "",
                })
                local root, root_error = unloaded.compiler_root()
                assert.is_nil(root)
                assert.equal(reason, root_error)
                local strategy = setmetatable({}, { __index = sync })
                function strategy:stat(filename)
                    if filename:find("titan%-runtime[/\\]titan%.c$") or
                       filename:find("[/\\]Makefile$") then
                        return checkout and { kind = "file" } or nil
                    end
                    return sync:stat(filename)
                end
                local context = unloaded.new_resolver_context({ io = strategy })
                assert.is_true(unloaded.close_resolver_context(context))
                return unloaded
            end)
        end

        local installed = layout(false)
        assert.is_false(installed.SOURCE_CHECKOUT)
        assert.equal("cannot locate the Titan installation root: " .. reason ..
            "; set TITAN_ROOT to the installation prefix",
            installed.INSTALLATION_ERROR)
        assert.equal(installed.INSTALLATION_ERROR, installed.TOOLCHAIN_ERROR)

        local checkout = layout(true)
        assert.is_true(checkout.SOURCE_CHECKOUT)
        assert.is_nil(checkout.INSTALLATION_ERROR)
        assert.is_nil(checkout.TOOLCHAIN_ERROR)
    end)

    it("returns Titan path expansion failures as compiled-module lookup diagnostics",
       function()
        local configured = driver_with_environment({
            TITAN_ROOT = fixture_path("/sdk"),
            TITAN_PATH_0_6 = "first;;",
        })
        local context = configured.new_resolver_context()
        local completed, failure = pcall(function()
            for _, case in ipairs({
                { {}, "installed Titan native support lacks " ..
                    "_expand_titan_path; reinstall Titan" },
                { { _expand_titan_path = function()
                      error("cannot determine the executable directory", 0)
                  end },
                  "cannot expand Titan path 'first;;': " ..
                    "cannot determine the executable directory" },
            }) do
                with_support(case[1], function()
                    local entries, entries_error = configured.titan_bin_path_entries(
                        configured.TITAN_BIN_PATH)
                    assert.is_nil(entries)
                    assert.equal(case[2], entries_error)
                    local resolved, resolve_error =
                        configured.find_dependency_interface(
                            configured.TITAN_BIN_PATH, "pkg.mod", context)
                    assert.is_nil(resolved)
                    assert.equal(case[2], resolve_error)
                end)
            end
        end)
        assert.is_true(configured.close_resolver_context(context))
        assert.truthy(completed, failure)
    end)

    it("selects a non-empty TITAN_ROOT as the compiler root and probe-cache owner",
       function()
        local explicit = driver_with_environment({
            TITAN_ROOT = fixture_path("/post-install/tree/"),
            TITAN_PREFIX = false,
            TITAN_PROBE_CACHE_DISABLE = false,
        })
        assert.equal(fixture_path("/post-install/tree"), explicit.TITAN_ROOT)
        assert.equal(fixture_path("/post-install/tree"),
            assert(explicit.compiler_root()))
        assert.equal(fixture_path("/post-install/tree/var/cache/titan-probes/") ..
            cprobe_cache.VERSION, explicit.PROBE_CACHE_DIRECTORY)
    end)

    it("resolves a relative TITAN_ROOT against the current directory", function()
        local explicit = driver_with_environment({
            TITAN_ROOT = "./discarded/../normalized//",
        })
        local previous_windows = platform.windows
        local previous_currentdir, previous_chdir = lfs.currentdir, lfs.chdir
        platform.windows = false
        lfs.currentdir = function() return "/model/work" end
        lfs.chdir = function() return nil, "unavailable model directory" end
        local completed, root = pcall(explicit.compiler_root)
        platform.windows = previous_windows
        lfs.currentdir, lfs.chdir = previous_currentdir, previous_chdir
        assert.truthy(completed, root)
        assert.equal("/model/work/normalized", root)
    end)

    it("searches the current directory and then the SDK providers by default",
       function()
        local root = fixture_path("/sdk")
        local providers = fixture_path("/sdk/lib/titan/0.6")
        local function entries(titan_path_0_6, titan_path)
            local configured = driver_with_environment({
                TITAN_ROOT = root,
                TITAN_PATH_0_6 = titan_path_0_6,
                TITAN_PATH = titan_path,
            })
            return assert(configured.titan_bin_path_entries(
                configured.TITAN_BIN_PATH))
        end
        assert.same({ ".", providers }, entries(false, false))
        assert.same({ "first", ".", providers, "last" },
            entries("first;;last", "ignored"))
        assert.same({ "only", ".", providers }, entries(false, "only;;"))
        assert.same({}, entries("", "ignored"))
    end)

    it("honors the test-only persistent-probe-cache disable switch",
       function()
        local lua = os.getenv("PREFIX") and os.getenv("PREFIX") ..
            (platform.windows and "/bin/lua.exe" or "/bin/lua") or "lua"
        local script = 'local driver = require "titan-compiler.driver"; ' ..
            'assert(driver.PROBE_CACHE_DIRECTORY == nil)'
        local result = compiler_io.new_sync():run({
            "env", "TITAN_PROBE_CACHE_DISABLE=1", lua, "-e", script,
        })
        assert.truthy(result.ok, result.output or result.diagnostic)
    end)

    it("uses format 1 for initialized persistent probe caches",
       function()
        local module_name = "titan-compiler.driver"
        local loaded_driver = package.loaded[module_name]
        local original_getenv = platform.getenv
        package.loaded[module_name] = nil
        platform.getenv = function(name)
            if name == "TITAN_PREFIX" then return fixture_path("/explicit") end
            if name == "TITAN_PROBE_CACHE_DISABLE" then return nil end
            return original_getenv(name)
        end

        local loaded, value = pcall(require, module_name)

        platform.getenv = original_getenv
        package.loaded[module_name] = loaded_driver
        assert.truthy(loaded, value)

        local expected = fixture_path("/explicit/var/cache/titan-probes/") .. cprobe_cache.VERSION
        assert.equal(expected, value.PROBE_CACHE_DIRECTORY)
        local context = value.new_resolver_context()
        assert.equal(expected, value.PROBE_CACHE_DIRECTORY)
        assert.is_true(value.close_resolver_context(context))
    end)

    it("preserves ordinary root spelling and native symlink parent traversal",
       function()
        local available, message = require("spec.support.filesystem").symlink_capability()
        if not available then pending(message); return end
        local workspace = temporary.name()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local physical = workspace .. "/physical"
        local nested = physical .. "/nested"
        assert(lfs.mkdir(physical))
        assert(lfs.mkdir(nested))
        local alias = workspace .. "/alias"
        assert(lfs.link(nested, alias, true))
        local function compiler_root(value)
            return assert(driver_with_environment({
                TITAN_ROOT = value,
            }).compiler_root())
        end

        assert.equal(alias, compiler_root(alias))

        local expected_parent
        if platform.windows then
            -- Ordinary Win32 roots normalize dots before filesystem traversal.
            expected_parent = compiler_root(workspace)
        else
            local previous = lfs.currentdir()
            assert(lfs.chdir(physical))
            expected_parent = lfs.currentdir()
            assert(lfs.chdir(previous))
        end
        assert.equal(expected_parent, compiler_root(alias .. "/.."))

        if platform.windows then
            assert(lfs.rmdir(alias))
        else
            assert(os.remove(alias))
        end
        remove_tree(workspace)
    end)

    posix_model_it("derives all installed compiler paths from one root", function()
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
            sdk_digests = "/opt/titan/lib/titan/0.6/sdk-digests",
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

    it("requires exactly the four runtime archive members", function()
        local members = "titan.o\nminicoro.o\ntitan_path.o\nltitanlib.o\n"
        assert.is_true(driver.runtime_archive_members_are_exact(members))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF SORTED\n" .. members))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF_64\n" .. members))
        assert.is_false(driver.runtime_archive_members_are_exact(
            members .. "titan_uv.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "__.SYMDEF\n" .. members .. "stale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan.o\nminicoro.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "minicoro.o\ntitan.o\ntitan_path.o\nltitanlib.o\n"))
    end)

    posix_model_it("links source builds through the complete runtime archive", function()
        driver.INSTALL_PATHS = nil
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.1/src/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("lua-5.5.1/src"))
    end)

    posix_output_it("links source builds with the matching installed Lua SDK archive", function()
        driver.INSTALL_PATHS = assert(driver.installed_paths("/opt/titan"))
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("/opt/titan/src/lua-5.5.1"))
        -- Another explicitly selected source tree owns its local archive,
        -- even when its pathname resembles an installed SDK's header tree.
        assert.equal("/opt/other/src/lua-5.5.1/liblua.a",
            driver.source_link_inputs("/opt/other/src/lua-5.5.1")[3])
    end)

    it("recognizes matching installed Lua SDK headers through a prefix alias", function()
        if platform.windows then
            pending("POSIX prefix aliases use native directory symlinks")
            return
        end
        local available, message = require("spec.support.filesystem").symlink_capability()
        if not available then pending(message); return end
        local workspace = temporary.name()
        assert(os.remove(workspace))
        assert(lfs.mkdir(workspace))
        local previous_paths = driver.INSTALL_PATHS
        local completed, failure = xpcall(function()
            local physical = workspace .. "/physical"
            assert(lfs.mkdir(physical))
            assert(lfs.mkdir(physical .. "/src"))
            assert(lfs.mkdir(physical .. "/src/lua-5.5.1"))
            local alias = workspace .. "/alias"
            assert(lfs.link(physical, alias, true))
            driver.INSTALL_PATHS = assert(driver.installed_paths(physical))
            assert.equal(physical .. "/lib/liblua.a",
                driver.source_link_inputs(alias .. "/src/lua-5.5.1")[3])
        end, debug.traceback)
        driver.INSTALL_PATHS = previous_paths
        remove_tree(workspace)
        assert.truthy(completed, failure)
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

describe("record constructor compiled-interface validation", function()
    local modname, owner = "constructor_metadata", "constructor_metadata.Box"

    local function module(constructor, custom, nfields)
        local record = types.Record(owner, {
            types.Field(owner, "item", types.Integer(), 0, false),
        }, constructor and {new = constructor} or {}, {}, nfields or 1,
            nil, nil, custom)
        return types.Module(modname, {
            types.ModuleMember(modname, "Box", record, nil),
        }), record
    end

    it("accepts arbitrary public custom new signatures and private omissions", function()
        local scope = types.GenericScope(modname, owner, "new", "static", "static")
        local parameter = types.Parameter(scope, 1, "T", nil)
        local signatures = {
            types.StaticMethod(owner, "new", {}, {}, nil, nil, {}),
            types.StaticMethod(owner, "new", {types.String()},
                {types.Integer(), types.String()}, types.Value(), types.String(),
                {"text"}),
            types.StaticMethod(owner, "new", {parameter}, {parameter},
                nil, nil, {"value"}, scope, {types.TypeParameter("T", nil)}),
        }
        for _, constructor in ipairs(signatures) do
            for _, count in ipairs({1, 2}) do
                local original = module(constructor, true, count)
                local decoded, err = driver.decode_module_interface(
                    types.serialize(original), modname, "custom new metadata")
                assert.truthy(decoded, err)
                assert.is_true(decoded.members.Box.type.custom_constructor)
                assert.is_true(types.equals(original, decoded))
            end
        end
        local original = module(nil, true)
        local decoded, err = driver.decode_module_interface(
            types.serialize(original), modname, "private new metadata")
        assert.truthy(decoded, err)
        assert.is_true(decoded.members.Box.type.custom_constructor)
        assert.is_nil(decoded.members.Box.type.functions.new)
    end)

    it("retains synthesized constructor shape checks and validates the override flag", function()
        local original, record = module(nil, false)
        local ok, err = driver.validate_module_interface(original, modname)
        assert.is_nil(ok)
        assert.matches("all-public record is missing its constructor", err, 1, true)
        record.functions.new = types.StaticMethod(owner, "new", {}, {}, nil, nil, {})
        ok, err = driver.validate_module_interface(original, modname)
        assert.is_nil(ok)
        assert.matches("record constructor does not match its owner", err, 1, true)
        for _, invalid in ipairs({"true", 1}) do
            record.custom_constructor = invalid
            ok, err = driver.validate_module_interface(original, modname)
            assert.is_nil(ok)
            assert.matches("noncanonical custom constructor flag", err, 1, true)
        end
        record.custom_constructor = nil
        ok, err = driver.validate_module_interface(original, modname)
        assert.is_nil(ok)
        assert.matches("noncanonical custom constructor flag", err, 1, true)
    end)

    it("includes override authority in the source interface identity", function()
        local modtype, record = module(nil, false)
        modtype._source = true
        modtype.source_members = modtype.members
        modtype.source_type_members = {}
        local entry = {kind = "source", type = modtype, c_header_dependencies = {}}
        local before = assert(sourceinterface.serialize(entry))
        assert.matches(version.SOURCE_INTERFACE_FORMAT, before, 1, true)
        record.custom_constructor = true
        assert.not_equal(before, assert(sourceinterface.serialize(entry)))
    end)
end)

describe("Array compiled-interface validation", function()
    local modname = "array_metadata"

    local function variable_module(typ)
        return types.Module(modname, {
            types.ModuleVariable(modname, "items", typ, false),
        })
    end

    it("round-trips all three canonical Array qualifiers", function()
        for _, qualifier in ipairs({ "no", "yes", "maybe" }) do
            local array = types.Array(types.Boolean(), { tag = qualifier })
            for _, typ in ipairs({
                array,
                types.Option(array),
                types.Map(types.String(), array),
                types.Array(array, {tag="no"}),
            }) do
                local original = variable_module(typ)
                assert.is_true(driver.validate_module_interface(
                    original, modname))
                local decoded, err = driver.decode_module_interface(
                    types.serialize(original), modname, "Array round trip")
                assert.truthy(decoded, err)
                assert.is_true(types.equals(original, decoded))
            end
        end
    end)

    it("round-trips maybe-const Arrays in checked public signatures and fields",
    function()
        local h = require "spec.support.helpers"
        local ok, err, _, original = h.run_checker([[
            record Box
                items: const? { boolean }
            end

            interface View
                items: const? { boolean }
            end

            function identity(items: const? { boolean }): const? { boolean }
                return items
            end

            function optional(items: const? {boolean}?):
                    const? {boolean}?
                return items
            end
        ]])
        assert.truthy(ok, err)
        local decoded, decode_error = driver.decode_module_interface(
            types.serialize(original), "test", "checked maybe-const metadata")
        assert.truthy(decoded, decode_error)
        assert.is_true(types.equals(original, decoded))
        assert.equal("maybe", decoded.members.Box.type.fields[1].type.isconst.tag)
        assert.equal("maybe", decoded.type_members.View.fields[1].type.isconst.tag)
        assert.equal("maybe", decoded.members.identity.type.params[1].isconst.tag)
        assert.equal("maybe", decoded.members.optional.type.rettypes[1].base.isconst.tag)
    end)

    it("rejects absent and malformed Array qualifiers in raw metadata", function()
        for _, qualifier in ipairs({
            "nil", "false", "true", '"maybe"', "0", "1", '"false"', '"true"', '"Maybe"',
            '"mutable"', "{}", '{tag="unknown"}', '{tag="no", extra=true}',
        }) do
            -- Raw descriptor tables bypass Array's constructor check and must
            -- still be rejected by the compiled-interface validator.
            local serialized = string.format([[
                Module("array_metadata", {
                    ModuleVariable("array_metadata", "items", {
                        _tag = "Type.Array",
                        elem = Boolean(),
                        isconst = %s,
                    }, false),
                })
            ]], qualifier)
            local decoded, err = driver.decode_module_interface(
                serialized, modname, "hostile Array qualifier")
            assert.is_nil(decoded)
            assert.match("array type has a noncanonical const qualifier",
                err, 1, true)
        end
    end)

    it("keeps module-variable const qualifiers boolean", function()
        local modtype = variable_module(types.Array(types.Boolean(), {tag="maybe"}))
        modtype.members.items.isconst = "maybe"
        local ok, err = driver.validate_module_interface(modtype, modname)
        assert.is_nil(ok)
        assert.match("module variable 'items' has a noncanonical const qualifier",
            err, 1, true)
    end)
end)

describe("portable C99 compiled-interface validation", function()
    local modname = "portable_metadata"

    local function variable_module(typ)
        return types.Module(modname, {
            types.ModuleVariable(modname, "item", typ, false),
        })
    end

    local function function_module(param, rettype)
        return types.Module(modname, {
            types.ModuleMember(modname, "item",
                types.Function(
                    param and { param } or {},
                    rettype and { rettype } or {},
                    false, nil, nil),
                param and { "item" } or {}),
        })
    end

    local function reject(modtype, expected)
        local ok, err = driver.validate_module_interface(modtype, modname)
        assert.is_nil(ok)
        assert.match(expected, err, 1, true)
    end

    it("accepts canonical primitives, pointers, callbacks, and owners",
    function()
        local cint = types.CInteger("int", true, 3, 32)
        local callback = types.CPointer(types.CFunction({
            types.CPointer(types.CVoid(), { "const" }),
            cint,
        }, types.CVoid(), false, nil), {})
        assert.is_true(driver.validate_module_interface(
            function_module(callback, callback), modname))
        assert.is_true(driver.validate_module_interface(
            variable_module(types.CPointer(types.CVoid(), {})), modname))
        assert.is_true(driver.validate_module_interface(
            variable_module(types.COwned(cint, true)), modname))

        -- A void alias is a type namespace, not a value-facing use. Consumers
        -- may use it as a pointer pointee or callback return.
        assert.is_true(driver.validate_module_interface(
            types.Module(modname, {}, { Void = types.CVoid() }), modname))
    end)

    it("round-trips C function pointers in TValue-backed slots", function()
        local cint = types.CInteger("int", true, 3, 32)
        local callback = types.CPointer(types.CFunction(
            { cint }, cint, false, nil), {})

        local modules = { variable_module(callback) }

        local record_name = modname .. ".Box"
        local record_field = types.Field(
            record_name, "item", callback, 0, false)
        local record = types.Record(
            record_name, { record_field }, {}, {}, 2)
        modules[#modules + 1] = types.Module(modname, {
            types.ModuleMember(modname, "Box", record, nil),
        })

        local union_name = modname .. ".Choice"
        local variant = types.Variant(
            union_name, "present", {
                types.Field(union_name, "value", callback, 1, false),
            }, 0)
        local union = types.Union(union_name, { variant }, {
            present = types.StaticMethod(
                union_name, "present", { callback },
                { types.Nominal(union_name) }, nil, nil, {"value"}),
        }, {}, 1)
        modules[#modules + 1] = types.Module(modname, {
            types.ModuleMember(modname, "Choice", union, nil),
        })

        local interface_name = modname .. ".View"
        local interface = types.Interface(interface_name, {
            types.Field(interface_name, "item", callback, 0, true),
        }, {})
        modules[#modules + 1] = types.Module(modname, {}, { View = interface })

        for _, modtype in ipairs(modules) do
            assert.is_true(driver.validate_module_interface(modtype, modname))
            local rebuilt = assert(load("return " .. types.serialize(modtype),
                "portable callback metadata", "t", types))()
            assert.is_true(driver.validate_module_interface(rebuilt, modname))
            assert.is_true(types.equals(modtype, rebuilt))
        end
    end)

    it("round-trips public C declarations without admitting source authority", function()
        local cint = types.CInteger("int", true, 3, 32)
        local raw = types.CFunction({ cint }, cint, false, nil)
        local member = types.ModuleMember(modname, "increment", raw, { "input" })
        local module = types.Module(modname, { member })
        assert.is_true(driver.validate_module_interface(module, modname))
        local rebuilt = assert(load("return " .. types.serialize(module),
            "public C declaration metadata", "t", types))()
        assert.is_true(driver.validate_module_interface(rebuilt, modname))
        assert.is_true(types.equals(module, rebuilt))
        assert.same({}, types.public_module_prefix_layout(rebuilt))

        member._foreign_source = true
        reject(module, "module member 1 has an invalid schema")
        member._foreign_source = nil
        member.paramnames = {}
        reject(module, "has invalid parameter-name metadata")
        reject(variable_module(raw), "portable C function has a noncanonical shape")
    end)

    it("rejects direct value-facing void descriptors", function()
        reject(variable_module(types.CVoid()),
            "C void is not valid as a value-facing type")
        reject(function_module(types.CVoid(), nil),
            "C void is not valid as a value-facing type")
    end)

    it("rejects impossible callback parameter graphs", function()
        local cint = types.CInteger("int", true, 3, 32)
        local function callback(param)
            return variable_module(types.CPointer(types.CFunction(
                { param }, cint, false, nil), {}))
        end
        reject(callback(types.CVoid()),
            "portable C function parameter has an invalid shape")
        reject(callback(types.COwned(cint, false)),
            "portable C function parameter has an invalid shape")
        reject(callback(types.Integer()),
            "portable C function parameter has an invalid shape")
        reject(variable_module(types.CPointer(types.CFunction(
            { cint }, types.Integer(), false, nil), {})),
            "portable C function return has an invalid shape")
        reject(variable_module(types.CPointer(types.Integer(), {})),
            "portable C pointer has a noncanonical shape")
        reject(variable_module(types.CPointer(
            types.COwned(cint, false), {})),
            "portable C pointer has a noncanonical shape")
        reject(variable_module(types.COwned(types.Integer(), false)),
            "portable owned C type has a noncanonical shape")

        local cyclic = types.CPointer(types.CVoid(), {})
        cyclic.pointee = cyclic
        reject(variable_module(cyclic),
            "portable C pointer graph is cyclic or noncanonical")
    end)

    it("rejects noncanonical qualifiers and header identities", function()
        local cint = types.CInteger("int", true, 3, 32)
        reject(variable_module(types.CPointer(cint, { "volatile" })),
            "portable C pointer has a noncanonical shape")
        reject(variable_module(types.CTypedef("local_int", cint, {})),
            "C typedef has an invalid declaration identity or target")

        local private = types.CInteger("int", true, 3, 32)
        private._c_numeric = {}
        reject(variable_module(private),
            "type graph contains compiler-only source state")

        local oldstyle = types.CFunction({}, types.CVoid(), false, nil)
        oldstyle._paramstyle = "oldstyle"
        reject(variable_module(types.CPointer(oldstyle, {})),
            'Type.CFunction contains unexpected field "_paramstyle"')
        local decoded, decode_error = driver.decode_module_interface([[
            Module("portable_metadata", {
                ModuleVariable("portable_metadata", "item", {
                    _tag = "Type.CPointer",
                    quals = {},
                    pointee = {
                        _tag = "Type.CFunction",
                        params = {},
                        ret = CVoid(),
                        vararg = false,
                        abi = false,
                        _paramstyle = "oldstyle",
                    },
                }, false),
            })
        ]], modname, "hostile-portable-metadata")
        assert.is_nil(decoded)
        assert.match(
            'Type.CFunction contains unexpected field "_paramstyle"',
            decode_error, 1, true)

        local enum_owner = types.CInteger("int", true, 3, 32)
        enum_owner._c_enum_owner = enum_owner
        reject(variable_module(enum_owner),
            'Type.CInteger contains unexpected field "_c_enum_owner"')

        local arbitrary = types.CFloat("double")
        arbitrary.unexpected = true
        reject(variable_module(arbitrary),
            'Type.CFloat contains unexpected field "unexpected"')
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

        local reserved_provider =
            driver.common_module_provider({
                "pkg.titan.left", "pkg.titan.right",
            })
        assert.equal("pkg.titan", reserved_provider)
        assert.equal("pkg/titan" .. (platform.windows and ".dll" or ".so"),
            driver.provider_output_path(reserved_provider))

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
            local expected = {}
            for index, path in ipairs(case[2]) do
                expected[index] = path:gsub("%.so$", platform.windows and ".dll" or ".so")
            end
            assert.same(expected, driver.module_binary_candidates(case[1]))
        end
        assert.same({ "a.a", "a/b.a", "a/b/c.a" },
            driver.module_compiled_candidates("a.b.c", ".a"))
        assert.same({}, driver.module_binary_candidates("a..b"))
        assert.same({},
            driver.module_compiled_candidates("a..b", ".a"))
    end)

    it("expands explicit double separators with the runtime default", function()
        assert.same({ "R1", "D1", "D2", "R2" },
            driver.titan_bin_path_entries("R1;;R2", "D1;D2"))
        assert.same({ "D1", "D2" },
            driver.titan_bin_path_entries(nil, "D1;D2"))
        -- Inserted default bytes are literal directories, even a `!`.
        assert.same({ "R1", "/sdk!/lib" },
            driver.titan_bin_path_entries("R1;;", "/sdk!/lib"))
    end)

    it("preserves literal percent signs while inserting defaults", function()
        local explicit = "/tmp/100%/first;;/tmp/50%/last"
        local defaults = "/tmp/default%root;/tmp/other%root"
        assert.same({
            "/tmp/100%/first",
            "/tmp/default%root",
            "/tmp/other%root",
            "/tmp/50%/last",
        }, driver.titan_bin_path_entries(explicit, defaults))
    end)

    it("expands ! in a configured Titan path to the compiler interpreter's directory",
       function()
        local prefix = require("spec.support.installed_prefix").active()
        local previous = lfs.currentdir()
        assert(lfs.chdir(prefix .. "/bin"))
        local executable_dir = lfs.currentdir()
        assert(lfs.chdir(previous))
        local script = 'local driver = require "titan-compiler.driver"; ' ..
            'io.write(table.concat(assert(driver.titan_bin_path_entries(' ..
            'driver.TITAN_BIN_PATH)), "\\n"))'
        local result
        if platform.windows then
            -- The native titanc.exe runs from this same bin directory, so its
            -- `!` is the directory this lua.exe expands. MSYS tools rewrite
            -- path-list values, so the spawn environment carries them.
            local root = prefix .. "/selected sdk"
            result = compiler_io.new_sync():run({ prefix .. "/bin/lua.exe", "-e", script }, {
                stderr_to_stdout = false,
                env = { TITAN_PATH = false, TITAN_ROOT = root,
                    TITAN_PATH_0_6 = "!/providers;;",
                    LUA_PATH_5_5 = package.path, LUA_CPATH_5_5 = package.cpath },
            })
            assert.truthy(result.ok, result.output or result.diagnostic)
            local function spelling(entry) return entry:gsub("\\", "/"):lower() end
            local entries = {}
            for entry in result.output:gsub("\r\n", "\n"):gmatch("[^\n]+") do
                entries[#entries + 1] = spelling(entry)
            end
            assert.same({
                spelling(executable_dir .. "/providers"), ".",
                spelling(assert(driver.installed_paths(root)).titan_bin),
            }, entries)
            return
        end
        result = compiler_io.new_sync():run({
            "env", "-u", "TITAN_PATH", "TITAN_ROOT=/sdk",
            "TITAN_PATH_0_6=!/providers;;",
            "LUA_PATH_5_5=" .. package.path, "LUA_CPATH_5_5=" .. package.cpath,
            prefix .. "/bin/lua", "-e", script,
        }, { stderr_to_stdout = false })
        assert.truthy(result.ok, result.output or result.diagnostic)
        assert.equal(table.concat({
            executable_dir .. "/providers", ".", "/sdk/lib/titan/0.6",
        }, "\n"), result.output)
    end)

    it("stages an atomic library under its final basename", function()
        local workspace = temporary.name()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        local basename = "provider" .. (platform.windows and ".dll" or ".so")
        local public = workspace .. "/nested/" .. basename
        local staged, directory = driver.staged_library_output(public)
        assert.truthy(staged, directory)
        assert.equal(basename, staged:match("([^/\\]+)$"))
        local strategy = compiler_io.new_sync()
        assert.equal(assert(strategy:realpath(workspace .. "/nested")),
            assert(strategy:realpath(assert(platform.parent(directory)))))
        assert.equal(assert(platform.join(directory, basename)), staged)
        remove_tree(workspace)
    end)
end)

describe("loader resolver ownership", function()
    it("closes the titanc resolver when an unexpected error unwinds the chunk",
    function()
        local close_calls = 0
        local fake_context = { io = {} }
        local fake_driver = {
            TITAN_SOURCE_PATH = ".",
            deduplicate_module_names = function(modules) return modules end,
            new_resolver_context = function() return fake_context end,
            validate_target = function() return "native" end,
            validate_output_target = function(context)
                assert.equal(fake_context, context)
                assert.same({ 17 }, context.io._process_inherit)
                return true
            end,
            apply_native_inputs = function() end,
            configure_foreign_c = function() end,
            default_c_parts = function() return 1 end,
            defaultloader = function()
                error("injected titanc loader failure")
            end,
            close_resolver_context = function(context)
                assert.equal(fake_context, context)
                close_calls = close_calls + 1
                return true
            end,
        }
        local argument_parser = {}
        local chain = {
            args = function(self) return self end,
            count = function(self) return self end,
            action = function(self) return self end,
        }
        function argument_parser:argument() return chain end
        function argument_parser:flag() return chain end
        function argument_parser:option() return chain end
        function argument_parser:parse()
            return {
                module = { "exceptional" },
                extra_object = {},
                coverage_module = {},
                coverage_format = {},
                test_dir = {},
                test_exclude = {},
                c_source = {},
                link = {},
                library_dir = {},
                ldflag = {},
            }
        end
        local fake_argparse = setmetatable({}, {
            __call = function() return argument_parser end,
        })
        local modules = {
            argparse = fake_argparse,
            ["titan-compiler.build"] = {
                lock_outputs = function()
                    return {
                        descriptors = function() return { 17 } end,
                        release = function() end,
                    }
                end,
                run = function()
                    assert.same({ 17 }, fake_context.io._process_inherit)
                    error("injected titanc loader failure")
                end,
            },
            ["titan-compiler.checker"] = {},
            ["titan-compiler.coder"] = {},
            ["titan-compiler.coverage"] = {},
            ["titan-compiler.parser"] = {},
            ["titan-compiler.path"] = paths,
            ["titan-compiler.driver"] = fake_driver,
            ["titan-compiler.incremental"] = {
                load_digest_cache = function() return true end,
                save_digest_cache = function() return true end,
            },
            ["titan-compiler.nativeinputs"] = {
                normalize = function() return {} end,
            },
            ["titan-compiler.linkcertificate"] = {},
            ["titan-compiler.platform"] = {
                windows = false,
                getenv = function() return nil end,
            },
            ["titan-compiler.test_runner"] = {},
            ["titan-compiler.util"] = {},
            -- No progress renderer in these driver harnesses: the historical
            -- quiet output is what each assertion below describes.
            ["titan-compiler.progress"] = {
                NULL = "null", PLAIN = "plain", LIVE = "live",
                select = function() return "null" end,
                locale = function() return nil end,
            },
            -- titanc requires the native digests before creating its resolver.
            titan = { _sha256_binary = function() return string.rep("\0", 32) end,
                _sha256_stream = function() error("fixture never streams", 0) end },
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
        assert.is_nil(fake_context.io._process_inherit)
    end)

    it("skips Titan FFI and module graph setup for C-only compile-only invocations",
    function()
        local function run_cli(parsed_args)
            local events = {
                initialize_platform = 0,
                configure_foreign_c = 0,
                build_run = 0,
                defaultloader = 0,
                preflight = 0,
                native_compile = 0,
                load_digest_cache = 0,
                save_digest_cache = 0,
                close_context = 0,
                release_locks = 0,
                stdout = {},
            }
            local fake_context = {
                io = {
                    cwd = function() return "/project" end,
                },
                selected_static_providers = {},
                source_names = { app = true },
                dynamic_names = {},
                native_bindings = {},
                native_static_names = { app = true },
                native_interface_types = {},
            }
            local fake_driver = {
                TITAN_SOURCE_PATH = ".",
                EXTRA_CPPFLAGS = {},
                EXTRA_CFLAGS = {},
                EXTRA_LDFLAGS = {},
                imported = {
                    app = {
                        kind = "source",
                        filename = "/project/app.titan",
                        source_files = { "/project/app.titan" },
                        compiled = "/out/app.o",
                        compiled_objects = { "/out/app.o" },
                        external_symbols = {},
                        private_symbols = {},
                        native_references = {},
                    },
                },
                deduplicate_module_names = function(modules) return modules end,
                new_resolver_context = function() return fake_context end,
                validate_target = function() return "native" end,
                prepare_output_root = function(dir) return dir end,
                validate_output_target = function(context)
                    assert.equal(fake_context, context)
                    assert.same({ 19 }, context.io._process_inherit)
                    return true
                end,
                apply_native_inputs = function() end,
                initialize_platform = function(context)
                    assert.equal(fake_context, context)
                    events.initialize_platform = events.initialize_platform + 1
                    return true
                end,
                configure_foreign_c = function(context)
                    assert.equal(fake_context, context)
                    events.configure_foreign_c = events.configure_foreign_c + 1
                    return true
                end,
                default_c_parts = function() return 1 end,
                defaultloader = function()
                    events.defaultloader = events.defaultloader + 1
                    return function() return true end
                end,
                preflight_build_outputs = function(context, plan, opts)
                    assert.equal(fake_context, context)
                    assert.same({ 19 }, context.io._process_inherit)
                    events.preflight = events.preflight + 1
                    events.preflight_plan = plan
                    events.preflight_options = opts
                    return true
                end,
                generated_compile_prefix = function() return { "cc" } end,
                authored_c_compile_prefix = function() return { "cc" } end,
                toolchain_descriptor = function() return { compiler_argv = { "cc" } } end,
                output_tool_descriptors = function() return {} end,
                finalize_resolver_context = function(context)
                    assert.equal(fake_context, context)
                    return true
                end,
                plan_foreign_headers = function() return {} end,
                mangle_module_name = function(name) return name end,
                record_module_symbols = function() end,
                plan_compile_requests = function(_, _, inputs)
                    return { inputs = inputs or {}, outputs = {} }
                end,
                write_foreign_header_plans = function() return true end,
                compile_modules = function(requests)
                    local results = {}
                    for index in ipairs(requests) do
                        results[index] = { ok = true, libname = "/out/app.o" }
                    end
                    return results
                end,
                close_resolver_context = function(context)
                    assert.equal(fake_context, context)
                    events.close_context = events.close_context + 1
                    return true
                end,
            }
            local argument_parser = {}
            local chain = {
                args = function(self) return self end,
                count = function(self) return self end,
                action = function(self) return self end,
            }
            function argument_parser:argument() return chain end
            function argument_parser:flag() return chain end
            function argument_parser:option() return chain end
            function argument_parser:parse() return parsed_args end
            local fake_argparse = setmetatable({}, {
                __call = function() return argument_parser end,
            })
            local modules = {
                argparse = fake_argparse,
                ["titan-compiler.build"] = {
                    lock_outputs = function()
                        return {
                            descriptors = function() return { 19 } end,
                            release = function()
                                events.release_locks = events.release_locks + 1
                            end,
                        }
                    end,
                    run = function(context, request)
                        assert.equal(fake_context, context)
                        events.build_run = events.build_run + 1
                        if request.preflight then
                            assert(request.preflight({ order = {}, modules = {} }))
                        end
                        return true
                    end,
                },
                ["titan-compiler.checker"] = {},
                ["titan-compiler.coder"] = {},
                ["titan-compiler.coverage"] = {},
                ["titan-compiler.parser"] = {},
                ["titan-compiler.path"] = paths,
                ["titan-compiler.driver"] = fake_driver,
                ["titan-compiler.incremental"] = {
                    load_digest_cache = function()
                        events.load_digest_cache = events.load_digest_cache + 1
                        return true
                    end,
                    save_digest_cache = function()
                        events.save_digest_cache = events.save_digest_cache + 1
                        return true
                    end,
                },
                ["titan-compiler.nativeinputs"] = {
                    normalize = function(request)
                        return {
                            c_sources = request.cli.c_sources or {},
                        }
                    end,
                    compile = function(context, request)
                        assert.equal(fake_context, context)
                        assert.same({ 19 }, context.io._process_inherit)
                        events.native_compile = events.native_compile + 1
                        local out = {}
                        for index, src in ipairs(request.sources) do
                            out[index] = {
                                source = src,
                                path = "/out/.native/obj" .. index .. ".o",
                                hit = true,
                            }
                        end
                        return out
                    end,
                },
                ["titan-compiler.linkcertificate"] = {
                    canonical_path = function(_, path)
                        return "/project/" .. tostring(path)
                    end,
                },
                ["titan-compiler.platform"] = {
                    windows = false,
                    getenv = function() return nil end,
                    absolute = function(path) return path end,
                },
                ["titan-compiler.test_runner"] = {},
                ["titan-compiler.util"] = util,
                -- No progress renderer in these driver harnesses: the historical
                -- quiet output is what each assertion below describes.
                ["titan-compiler.progress"] = {
                    NULL = "null", PLAIN = "plain", LIVE = "live",
                    select = function() return "null" end,
                    locale = function() return nil end,
                },
                titan = { _sha256_binary = function() return string.rep("\0", 32) end,
                    _sha256_stream = function() error("fixture never streams", 0) end },
            }
            local fake_io = setmetatable({
                stdout = {
                    write = function(_, ...)
                        for i = 1, select("#", ...) do
                            events.stdout[#events.stdout + 1] = tostring(select(i, ...))
                        end
                        return true
                    end,
                },
            }, { __index = io })
            local environment = setmetatable({
                arg = {},
                io = fake_io,
                require = function(name)
                    return assert(modules[name], "unexpected module " .. name)
                end,
            }, { __index = _G })
            local chunk = assert(loadfile("titanc", "t", environment))
            local ok, err = pcall(chunk)
            assert.is_true(ok, tostring(err))
            assert.is_nil(fake_context.io._process_inherit)
            return events
        end

        local c_only = run_cli({
            module = {},
            compile_only = true,
            print_c_objects = true,
            output = "/out",
            extra_object = nil,
            coverage_module = {},
            coverage_format = {},
            test_dir = {},
            test_exclude = {},
            c_source = { "first.c", "second.c" },
            link = {},
            library_dir = {},
            ldflag = {},
        })
        assert.equal(1, c_only.initialize_platform)
        assert.equal(0, c_only.configure_foreign_c)
        assert.equal(0, c_only.build_run)
        assert.equal(0, c_only.defaultloader)
        assert.equal(1, c_only.preflight)
        assert.same({ order = {}, modules = {} }, c_only.preflight_plan)
        assert.same({}, c_only.preflight_options.roots)
        assert.is_true(c_only.preflight_options.compile_only)
        assert.same({ "first.c", "second.c" }, c_only.preflight_options.native_inputs)
        assert.equal(1, c_only.native_compile)
        assert.equal(1, c_only.load_digest_cache)
        assert.equal(1, c_only.save_digest_cache)
        assert.equal(1, c_only.close_context)
        assert.equal(1, c_only.release_locks)
        assert.equal("/out/.native/obj1.o\n/out/.native/obj2.o\n",
            table.concat(c_only.stdout))

        local mixed = run_cli({
            module = { "app" },
            compile_only = true,
            print_c_objects = true,
            output = "/out",
            extra_object = nil,
            coverage_module = {},
            coverage_format = {},
            test_dir = {},
            test_exclude = {},
            c_source = { "first.c" },
            link = {},
            library_dir = {},
            ldflag = {},
        })
        assert.equal(1, mixed.configure_foreign_c)
        assert.equal(1, mixed.build_run)
        assert.equal(1, mixed.preflight)
        assert.equal(1, mixed.native_compile)
    end)

    it("leaves default and table contexts open until their caller closes them", function()
        local options = resolver_options()
        local context, close_calls = options.context, 0
        context.probe_service = { close = function()
            close_calls = close_calls + 1
            return true
        end }
        local default = driver.defaultloader({}, options)
        local first, second, third = driver.with_loader(default, function(loader)
            assert.is_function(loader)
            return "done", nil, 3
        end)
        assert.equal("done", first)
        assert.is_nil(second)
        assert.equal(3, third)
        assert.equal(0, close_calls)
        assert.is_true(driver.close_loader(default))
        assert.is_true(driver.close_loader(nil))
        assert.equal(0, close_calls)

        local in_memory = driver.tableloader({}, {}, {}, options)
        local cancellation = { kind = "simulated cancellation" }
        local body_ok, body_error = pcall(driver.with_loader, in_memory, function()
            error(cancellation)
        end)
        assert.is_false(body_ok)
        assert.equal(cancellation, body_error)
        assert.is_true(driver.close_tableloader(in_memory))
        assert.equal(0, close_calls)
        assert.is_true(driver.close_resolver_context(context))
        assert.equal(1, close_calls)
        assert.is_true(driver.close_resolver_context(context))
        assert.equal(1, close_calls)
    end)

    it("removes source-header temporaries with or without a probe service",
    function()
        local first = temporary.name()
        local second = temporary.name()
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

        local third = temporary.name()
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
        ffiheaders.remember_file(unlink_context, "/virtual/remove-failure.h")
        assert.equal(1, #unlink_context.source_foreign_header_temporaries)
        function unlink_strategy:unlink() return true end
        assert.is_true(driver.close_resolver_context(unlink_context))
        assert.is_nil(unlink_context.source_foreign_header_temporaries)
        assert.is_nil(unlink_context.source_foreign_header_paths)

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
        ffiheaders.remember_file(lstat_context, "/virtual/lstat-failure.h")
        assert.equal(1, #lstat_context.source_foreign_header_temporaries)
        function lstat_strategy:lstat() return nil end
        assert.is_true(driver.close_resolver_context(lstat_context))
        assert.is_nil(lstat_context.source_foreign_header_temporaries)
        assert.is_nil(lstat_context.source_foreign_header_paths)
    end)

    it("reports a service close failure only to the explicit context owner", function()
        local options = resolver_options()
        local context, close_calls = options.context, 0
        context.probe_service = { close = function()
            close_calls = close_calls + 1
            return nil, "injected resolver close failure"
        end }
        local loader = driver.defaultloader({}, options)
        assert.is_true(driver.with_loader(loader, function() return true end))
        assert.equal(0, close_calls)
        local closed, close_error = driver.close_resolver_context(context)
        assert.is_nil(closed)
        assert.equal("injected resolver close failure", close_error)
        assert.equal(1, close_calls)
        assert.is_true(driver.close_loader(loader))
    end)

    it("retries a cancelled service close only when the explicit owner closes it", function()
        local options = resolver_options()
        local context, close_calls = options.context, 0
        local cancellation = { kind = "simulated cancellation" }
        local service = { close = function()
            close_calls = close_calls + 1
            if close_calls == 1 then error(cancellation) end
            return true
        end }
        context.probe_service = service
        local loader = driver.defaultloader({}, options)
        assert.is_true(driver.close_loader(loader))
        assert.equal(0, close_calls)
        local first_closed, reason = pcall(driver.close_resolver_context, context)
        assert.is_false(first_closed)
        assert.equal(cancellation, reason)
        assert.equal(service, context.probe_service)
        assert.equal(1, close_calls)
        assert.is_true(driver.close_loader(loader))
        assert.equal(1, close_calls)
        assert.is_true(driver.close_resolver_context(context))
        assert.is_nil(context.probe_service)
        assert.equal(2, close_calls)
        assert.is_true(driver.close_resolver_context(context))
        assert.equal(2, close_calls)
    end)

    it("closes test-helper contexts on cancellation without taking borrowed ownership", function()
        local helpers = require "spec.support.helpers"
        local options, close_calls = { analysis_only = true }, 0
        local cancellation = { kind = "simulated cancellation" }
        local called, reason = pcall(helpers.with_resolver_context, options, function(context, supplied)
            assert.equal(context, supplied.context)
            context.probe_service = { close = function()
                close_calls = close_calls + 1
                return true
            end }
            error(cancellation)
        end)
        assert.is_false(called)
        assert.equal(cancellation, reason)
        assert.is_nil(options.context)
        assert.equal(1, close_calls)

        local borrowed = new_context()
        borrowed.probe_service = { close = function()
            close_calls = close_calls + 1
            return true
        end }
        options.context = borrowed
        assert.equal("kept", helpers.with_resolver_context(options, function(context)
            assert.equal(borrowed, context)
            return "kept"
        end))
        assert.equal(borrowed, options.context)
        assert.equal(1, close_calls)
        assert.is_true(driver.close_resolver_context(borrowed))
        assert.equal(2, close_calls)
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
    local original_native

    local original_stderr

    before_each(function()
        original_execute = os.execute
        original_rename = os.rename
        original_print = _G.print
        original_stderr = io.stderr
        original_formatter = driver.CLANG_FORMAT
        original_format_generated_file = driver.format_generated_file
        original_get_file_contents = util.get_file_contents
        original_set_file_contents = util.set_file_contents
        platform.native = original_native
    end)

    after_each(function()
        os.execute = original_execute
        os.rename = original_rename
        _G.print = original_print
        io.stderr = original_stderr
        driver.CLANG_FORMAT = original_formatter
        driver.format_generated_file = original_format_generated_file
        util.get_file_contents = original_get_file_contents
        util.set_file_contents = original_set_file_contents
        platform.native = original_native
    end)

    it("does not invoke the formatter by default", function()
        os.execute = function() error("unexpected formatter execution") end
        driver.CLANG_FORMAT = "'unterminated"
        local path = temporary.name(" generated module.c")
        write_file(path, "int   value;\n")

        assert.is_true(driver.format_generated_file(path, true))
        assert.equal("int   value;\n", assert(util.get_file_contents(path)))
        assert(os.remove(path))
    end)

    posix_model_it("quotes configured argv and generated paths when opted in", function()
        local commands = {}
        local printed = {}
        os.execute = function(command)
            commands[#commands + 1] = command
            return true, "exit", 0
        end
        io.stderr = {
            write = function(_, command)
                printed[#printed + 1] = tostring(command)
                return true
            end,
        }
        driver.CLANG_FORMAT = "'/tools with spaces/clang-format' --Werror"
        local path = temporary.name(" generated module.c")
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
        local path = temporary.name(" generated.c")
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
        local path = temporary.name(" generated.c")
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

    posix_model_it("reports opted-in formatter failures before normalization", function()
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
        local root = temporary.name(" formatter transaction")
        assert(lfs.mkdir(root))
        local header = root .. "/module.titan.h"
        local old = ffiheaders.FOREIGN_MARKER .. "\n/* old */\n"
        local plan = {
            filename = header,
            contents = ffiheaders.FOREIGN_MARKER .. "\nint value;\n",
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
        local previous_sync = compiler_io.new_sync
        compiler_io.new_sync = function()
            local strategy = previous_sync()
            strategy.rename = function() return nil, "injected stage rename failure" end
            return strategy
        end
        ok, err = driver.write_foreign_header_plan(plan)
        compiler_io.new_sync = previous_sync
        assert.is_nil(ok)
        assert.matches("injected stage rename failure", err, 1, true)
        assert.equal(old, assert(original_get_file_contents(header)))
        remove_tree(root)
    end)

    it("keeps both module headers unchanged when either formatter fails", function()
        local root = temporary.name()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local header, ffi_header = root .. "/module.titan.h", root .. "/module.ffi.h"
        local old_header = ffiheaders.FOREIGN_MARKER .. "\n/* old declarations */\n"
        local old_ffi = ffiheaders.MARKER .. "\n/* old environment */\n"
        write_file(header, old_header)
        write_file(ffi_header, old_ffi)
        local plan = { filename = header, ast = {},
            contents = ffiheaders.FOREIGN_MARKER .. "\n/* new declarations */\n",
            ffi_header = { filename = ffi_header, marker = ffiheaders.MARKER,
                contents = ffiheaders.MARKER .. "\n/* new environment */\n" } }
        local calls = {}
        driver.format_generated_file = function(path)
            calls[#calls + 1] = path
            if #calls == 2 then return nil, "second header formatting failed" end
            return true
        end
        local ok, err = driver.write_foreign_header_plan(plan)
        assert.is_nil(ok)
        assert.equal("second header formatting failed", err)
        assert.equal(old_header, assert(util.get_file_contents(header)))
        assert.equal(old_ffi, assert(util.get_file_contents(ffi_header)))
        for _, path in ipairs(calls) do assert.is_nil(lfs.symlinkattributes(path)) end
        remove_tree(root)
    end)

    it("publishes a generated header only after its staged copy formats",
    function()
        local root = temporary.name(" formatter space")
        assert(lfs.mkdir(root))
        local header = root .. "/module.titan.h"
        local old = ffiheaders.FOREIGN_MARKER .. "\n/* old */\n"
        local new = ffiheaders.FOREIGN_MARKER .. "\nint value;\n"
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
            assert.truthy(path:match("%.h$"),
                "clang-format must recognize staged output as a C header")
            calls[#calls + 1] = path
            return nil, "injected formatter failure"
        end
        local ok, err = driver.write_foreign_header_plan(plan, nil, true)
        assert.is_nil(ok)
        assert.matches("injected formatter failure", err, 1, true)
        assert.equal(old, assert(util.get_file_contents(header)))
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
        remove_tree(root)
    end)
end)

describe("source foreign-header planning", function()
    it("orders explicit source environments before every authored directive", function()
        local function foreign(header)
            return { _tag = "Ast.TopLevelForeignImport",
                _include = { rendered = header } }
        end
        local ast = {
            foreign('"/project/main.h"'),
            { _tag = "Ast.TopLevelImport", _source_import = true,
                _ffi_header = "/native/z.ffi.h" },
            { _tag = "Ast.TopLevelImport", _ffi_header = "/native/ordinary.ffi.h" },
            foreign("<limits.h>"),
            { _tag = "Ast.TopLevelImport", _source_import = true,
                _ffi_header = "/native/a.ffi.h" },
            foreign('"/project/main.h"'),
            { _tag = "Ast.TopLevelForeignImport", _ignore = true },
        }
        local contents = coder.generate_ffi_header("test", ast)
        local includes = {}
        for line in contents:gmatch("[^\n]+") do
            if line:sub(1, 9) == "#include " then includes[#includes + 1] = line end
        end
        assert.same({ '#include "/native/z.ffi.h"', '#include "/native/a.ffi.h"',
            '#include "/project/main.h"', '#include <limits.h>',
            '#include "/project/main.h"' }, includes)
        assert.not_equal(coder.generate_ffi_header("a.b", {}),
            coder.generate_ffi_header("a_b", {}))
        assert.not_equal(coder.generate_ffi_header("Case", {}),
            coder.generate_ffi_header("case", {}))
    end)

    for _, ending in ipairs({ { "LF", "\n" }, { "CRLF", "\r\n" } }) do
        it("replays " .. ending[1] .. " foreign recipes with fresh-header directive spacing", function()
            local newline = ending[2]
            local prefix = ffiheaders.FOREIGN_MARKER .. newline .. "#ifndef SAVED_HEADER" .. newline
            local literal = 'const char *path = "C:\\\\root\\\\unchanged";'
            local body = table.concat({
                "static inline int saved(void) {",
                '#line 7 "source.titan"',
                "",
                " \t",
                "int item = 1;",
                "",
                literal,
                "return item;",
                "}",
                "",
            }, newline)
            local recipe = { prefix = prefix, body = body, source_headers = { "dep" },
                policy = { line_directives = true, coverage = false } }
            local digest = ffiheaders.foreign_recipe_digest(recipe)
            local includes = '#include "saved.ffi.h"\n#include "dep.titan.h"\n'
            local replayed = ffiheaders.foreign_contents(recipe, "saved.ffi.h", function(name)
                assert.equal("dep", name)
                return "dep.titan.h"
            end)
            local expected_body = table.concat({
                "static inline int saved(void) {",
                '#line 7 "source.titan"',
                "int item = 1;",
                "",
                literal,
                "return item;",
                "}",
                "",
            }, newline)
            assert.equal(prefix .. "\n" .. includes .. expected_body, replayed)
            assert.equal(body, recipe.body)
            assert.equal(digest, ffiheaders.foreign_recipe_digest(recipe))

            -- Model the fresh writer's text-mode read on either host without
            -- changing the replayed header's independently asserted LF/CRLF bytes.
            local fresh = (prefix .. "\n" .. includes .. body):gsub("\r\n", "\n")
            local strategy = {
                read_file = function() return fresh end,
                write_file = function(_, _, contents) fresh = contents; return true end,
                run = function() error("unexpected formatter execution") end,
            }
            assert.is_true(driver.format_generated_file("saved.titan.h", false, false, strategy))
            assert.equal(fresh, (replayed:gsub("\r\n", "\n")))
        end)
    end

    it("plans dependency headers, writes owned outputs, and removes stale ones",
    function()
        local root = temporary.name()
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
            return ffiheaders.FOREIGN_MARKER .. "\n/* " .. name .. " "
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
        assert.equal(root .. "/producer.ffi.h", import._ffi_header)
        assert.truthy(plans[2].contents:find(import._foreign_header, 1, true))
        assert.truthy(plans[2].ffi_header.contents:find(import._ffi_header, 1, true))
        assert.is_true(driver.write_foreign_header_plans(plans))
        assert.is_not_nil(plans[1].policy)
        assert.is_not_nil(plans[2].policy)
        assert.equal("file", lfs.attributes(root .. "/producer.titan.h", "mode"))
        assert.equal("file", lfs.attributes(root .. "/consumer.titan.h", "mode"))
        assert.equal("file", lfs.attributes(root .. "/producer.ffi.h", "mode"))
        assert.equal("file", lfs.attributes(root .. "/consumer.ffi.h", "mode"))
        assert.equal(plans[1].ffi_header.contents,
            assert(util.get_file_contents(root .. "/producer.ffi.h")))

        producer_ast[1]._ignore = true
        consumer_ast[2]._ignore = true
        local stale = assert(driver.plan_foreign_headers(
            { "producer", "consumer" }, imported))
        assert.is_true(driver.write_foreign_header_plans(stale))
        assert.is_nil(lfs.symlinkattributes(root .. "/producer.titan.h"))
        assert.is_nil(lfs.symlinkattributes(root .. "/consumer.titan.h"))
        assert.equal("file", lfs.attributes(root .. "/producer.ffi.h", "mode"))
        assert.equal("file", lfs.attributes(root .. "/consumer.ffi.h", "mode"))
        assert.equal(root .. "/producer.ffi.h", import._ffi_header)
        assert.is_nil(import._foreign_header)
        remove_tree(root)
    end)

    it("rejects shared and user-owned planned header paths", function()
        local root = temporary.name()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local shared = root .. "/shared.titan"
        local ast = { { _tag = "Ast.TopLevelForeignFunc", name = "f" } }
        local original = coder.generate_foreign_header
        coder.generate_foreign_header = function()
            return ffiheaders.FOREIGN_MARKER .. "\n"
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
            return ffiheaders.FOREIGN_MARKER .. "\n"
        end
        local plan = driver.plan_foreign_header("reserved", ast, reserved)
        coder.generate_foreign_header = original
        local ok
        ok, err = driver.validate_foreign_header_plan(plan)
        assert.is_nil(ok)
        assert.matches("refusing to overwrite user-owned", err, 1, true)

        write_file(root .. "/plain.ffi.h", "/* user-owned C environment */\n")
        local ffi_plan = driver.plan_foreign_header("plain", {}, root .. "/plain.titan")
        ok, err = driver.validate_foreign_header_plan(ffi_plan)
        assert.is_nil(ok)
        assert.matches("refusing to overwrite user-owned", err, 1, true)
        assert.matches("plain.ffi.h", err, 1, true)
        remove_tree(root)
    end)

    for _, header in ipairs({
        { suffix = ".ffi.h", marker = ffiheaders.MARKER },
        { suffix = ".titan.h", marker = ffiheaders.FOREIGN_MARKER },
        { suffix = ".priv.h", marker = coder.PRIVATE_HEADER_MARKER },
    }) do
        it("requires the exact intended ownership marker for fresh " .. header.suffix, function()
            local root = temporary.name()
            assert(os.remove(root))
            assert(lfs.mkdir(root))
            local filename = root .. "/reserved" .. header.suffix
            local plan = { filename = filename, marker = header.marker,
                contents = header.marker .. "\n/* replacement */\n" }
            for _, contents in ipairs({
                "/* user-owned */\n",
                " " .. header.marker .. "\n",
                "/* user prefix */\n" .. header.marker .. "\n",
                header.marker:sub(1, -2),
                (header.marker == ffiheaders.MARKER and
                    ffiheaders.FOREIGN_MARKER or ffiheaders.MARKER) .. "\n",
            }) do
                write_file(filename, contents)
                local ok, err = driver.write_foreign_header_plan(plan)
                assert.is_nil(ok)
                assert.matches("refusing to overwrite user-owned", err, 1, true)
                assert.matches(filename, err, 1, true)
                assert.equal(contents, assert(util.get_file_contents(filename)))
            end
            assert(os.remove(filename))
            assert(lfs.mkdir(filename))
            local original_symlinkattributes = lfs.symlinkattributes
            lfs.symlinkattributes = function(path, field)
                assert.equal("mode", field)
                return original_symlinkattributes(path, field)
            end
            local called, ok, err = pcall(driver.validate_foreign_header_plan, plan)
            lfs.symlinkattributes = original_symlinkattributes
            assert.is_true(called, ok)
            assert.is_nil(ok)
            assert.matches("refusing to overwrite user-owned", err, 1, true)
            assert.equal("directory", lfs.symlinkattributes(filename, "mode"))
            remove_tree(root)
        end)
    end

    it("uses finalized header paths for an already compiled source dependency", function()
        local root = temporary.name()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        local import = { _tag = "Ast.TopLevelImport", modname = "dependency",
            _source_import = true, _ffi_header = "/old/checking/dependency.ffi.h" }
        local plans = assert(driver.plan_foreign_headers({ "dependency", "consumer" }, {
            dependency = { ast = {}, compiled = root .. "/dependency.o",
                filename = "/external/dependency.titan", native_output = root .. "/dependency.titan" },
            consumer = { ast = { import }, filename = root .. "/consumer.titan" },
        }))
        assert.equal(1, #plans)
        assert.equal(root .. "/dependency.ffi.h", import._ffi_header)
        assert.falsy(plans[1].ffi_header.contents:find("/old/checking/", 1, true))
        remove_tree(root)
    end)
end)

describe("module checking header bundles", function()
    local owners
    before_each(function() owners = {} end)
    after_each(function()
        for _, owner in ipairs(owners) do assert.is_true(ffiheaders.close(owner)) end
    end)
    local function owner()
        local value = { io = compiler_io.new_sync() }
        owners[#owners + 1] = value
        return value
    end
    local function foreign(header, search_inputs)
        return { _tag = "Ast.TopLevelForeignImport", _include = {
            rendered = header, c_header_search_inputs = search_inputs,
        } }
    end
    local function source(descriptor)
        return { _tag = "Ast.TopLevelImport", _source_import = true,
            _ffi_header_descriptor = descriptor, _ffi_header = descriptor.filename }
    end

    it("keeps stable content identity across fresh owners and body changes", function()
        local first_owner, second_owner = owner(), owner()
        local observation = { path = fixture_path("/project/include.h"), kind = "file" }
        local first_ast = { foreign('"' .. fixture_path("/project/include.h") .. '"', { observation }) }
        local first = assert(ffiheaders.prepare(first_owner, "pkg.main", first_ast,
            fixture_path("/project/pkg/main.titan")))
        local second = assert(ffiheaders.prepare(second_owner, "pkg.main", {
            foreign('"' .. fixture_path("/project/include.h") .. '"', { { path = fixture_path("/changed/observation") } }),
            { _tag = "Ast.TopLevelFunc", name = "changed_body" },
        }, fixture_path("/project/pkg/main.titan")))
        assert.not_equal(first.filename, second.filename)
        assert.equal(first.digest, second.digest)
        assert.equal(first.contents, second.contents)
        assert.same({ observation }, first.search_inputs)
        assert.equal(first, first_ast._ffi_header)
        assert.equal(first.contents, assert(util.get_file_contents(first.filename)))
        assert.falsy(first.contents:find(first.bundle_root, 1, true))
        local other_origin = assert(ffiheaders.prepare(owner(), "pkg.main", first_ast,
            fixture_path("/other-project/pkg/main.titan")))
        assert.not_equal(first.digest, other_origin.digest)
        local changed = assert(ffiheaders.prepare(owner(), "pkg.main", {
            foreign("<limits.h>"), foreign('"' .. fixture_path("/project/include.h") .. '"'),
        }, fixture_path("/project/pkg/main.titan")))
        assert.not_equal(first.digest, changed.digest)
    end)

    it("recreates real dependency trees after the original owner closes", function()
        local original = owner()
        local dependency = assert(ffiheaders.prepare(original, "shared.base", {
            foreign("<stddef.h>"),
        }, fixture_path("/project/shared/base.titan")))
        local first_consumer = assert(ffiheaders.prepare(original, "app.main", {
            source(dependency), source(dependency), foreign("<limits.h>"),
        }, fixture_path("/project/app/main.titan")))
        assert.equal(2, #first_consumer.dependencies)
        assert.truthy(first_consumer.contents:find(
            '#include "../shared/base.ffi.h"', 1, true))
        assert.is_true(ffiheaders.close(original))
        assert.is_nil(lfs.symlinkattributes(dependency.filename))

        local replay_owner = owner()
        local replay = assert(ffiheaders.materialize(replay_owner, first_consumer))
        assert.equal(first_consumer.digest, replay.digest)
        assert.equal(replay.dependencies[1], replay.dependencies[2])
        assert.not_equal(dependency.filename, replay.dependencies[1].filename)
        assert.equal(dependency.contents,
            assert(util.get_file_contents(replay.dependencies[1].filename)))
        assert.equal(replay.bundle_root, replay.dependencies[1].bundle_root)
        local second_consumer = assert(ffiheaders.prepare(owner(), "app.main", {
            source(dependency), source(dependency), foreign("<limits.h>"),
        }, fixture_path("/project/app/main.titan")))
        assert.equal(first_consumer.digest, second_consumer.digest)
    end)

    it("retains every created file and directory through write cancellation", function()
        local state = owner()
        local strategy = state.io
        local original_write = strategy.write_file
        local cancelled = {}
        function strategy:write_file(path, contents)
            assert(original_write(self, path, contents))
            error(cancelled)
        end
        local ok, err = pcall(ffiheaders.prepare, state, "nested.deep.module", {},
            fixture_path("/project/nested/deep/module.titan"))
        assert.is_false(ok)
        assert.equal(cancelled, err)
        local root = state.source_ffi_header_bundle
        assert.equal("file", lfs.attributes(root .. "/nested/deep/module.ffi.h", "mode"))
        assert.is_true(ffiheaders.close(state))
        assert.is_nil(lfs.symlinkattributes(root))
        assert.is_nil(state.source_foreign_header_temporaries)
        assert.is_nil(state.source_ffi_header_directories)
    end)

    it("computes each environment digest once and retains it during reuse", function()
        local sha256 = require "titan-compiler.sha256"
        local original_hex, environment_hashes = sha256.hex, 0
        sha256.hex = function(contents)
            if contents:find("titan-module-ffi-v2", 1, true) == 1 then
                environment_hashes = environment_hashes + 1
            end
            return original_hex(contents)
        end
        local ok, err = pcall(function()
            local state = owner()
            local base = assert(ffiheaders.prepare(state, "base", {}, fixture_path("/project/base.titan")))
            local middle = assert(ffiheaders.prepare(state, "middle", { source(base) },
                fixture_path("/project/middle.titan")))
            local main = assert(ffiheaders.prepare(state, "main", { source(middle), source(base) },
                fixture_path("/project/main.titan")))
            assert.equal(3, environment_hashes)
            assert.equal(main, assert(ffiheaders.materialize(state, main)))
            local replay = assert(ffiheaders.materialize(owner(), main))
            assert.equal(main.digest, replay.digest)
            assert.equal(replay.dependencies[2], replay.dependencies[1].dependencies[1])
            for _ = 1, 3 do
                local include = assert(cprobe.normalize_include_descriptor({
                    original = main.logical_name, include_name = main.logical_name,
                    include_kind = "quote", resolved = main.identity, generated_header = main,
                }, { io = state.io }))
                assert.equal(main, include.generated_header)
            end
            assert.equal(3, environment_hashes)
        end)
        sha256.hex = original_hex
        assert.is_true(ok, err)
    end)

    it("preserves real C include nesting, diamonds, and dependency-first macro state", function()
        local state = owner()
        local function authored(contents)
            local path = temporary.name()
            ffiheaders.remember_file(state, path)
            write_file(path, contents)
            return foreign('"' .. path .. '"')
        end
        local leaf = assert(ffiheaders.prepare(state, "shared.leaf", { authored([[
            enum { bundle_include_depth = __INCLUDE_LEVEL__ };
            #define BUNDLE_SEED 17
        ]]) }, fixture_path("/project/shared/leaf.titan")))
        local left = assert(ffiheaders.prepare(state, "branch.left", { source(leaf) },
            fixture_path("/project/branch/left.titan")))
        local right = assert(ffiheaders.prepare(state, "branch.right", { source(leaf) },
            fixture_path("/project/branch/right.titan")))
        local main = assert(ffiheaders.prepare(state, "app.main", {
            authored([[
                #if BUNDLE_SEED != 17
                #error source environments must precede own headers
                #endif
                #define BUNDLE_SELECTED 31
            ]]),
            source(left), source(right),
            authored([[
                #if BUNDLE_SELECTED != 31
                #error authored headers must preserve source order
                #endif
                enum { combined_result = BUNDLE_SEED + BUNDLE_SELECTED };
            ]]),
        }, fixture_path("/project/app/main.titan")))
        local probe = temporary.name()
        ffiheaders.remember_file(state, probe)
        write_file(probe, '#include "app/main.ffi.h"\n' .. [[
            _Static_assert(bundle_include_depth == 4, "real include nesting");
            _Static_assert(combined_result == 48, "final combined environment");
        ]])
        local args = assert(cdriver.split_shell_words(driver.CC))
        for _, arg in ipairs({ "-fsyntax-only", "-x", "c", "-I", main.bundle_root, probe }) do
            args[#args + 1] = arg
        end
        local result = state.io:run(args, { stderr_to_stdout = true })
        assert.truthy(result.started and result.ok, result.diagnostic or result.stdout)
    end)
end)

describe("standalone output ownership", function()
    it("checks FFI headers against all native inputs and outputs", function()
        local ok, err = driver.validate_program_output_paths({
            { modname = "module", output = "module.titan", ffi_header = "program" },
        }, "program", "entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("aliases output", err, 1, true)
        ok, err = driver.validate_program_output_paths({
            { modname = "module", output = "module.titan", ffi_header = "Module.ffi.h" },
        }, "program", "entrypoint.c", { "module.ffi.h" })
        assert.is_nil(ok)
        assert.matches("aliases input", err, 1, true)
        ok, err = driver.validate_program_output_paths({
            { modname = "a", output = "a.titan", ffi_header = "same.h" },
            { modname = "b", output = "b.titan", foreign_header = "same.h" },
        }, "program", "entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("aliases output", err, 1, true)
    end)

    it("requires a named executable and a C entrypoint", function()
        local ok, err = driver.validate_program_output_paths({}, "", "entrypoint.c", {})
        assert.is_nil(ok)
        assert.equal("standalone executable path must be a nonempty string", err)
        ok, err = driver.validate_program_output_paths({}, "program", "entrypoint.cc", {})
        assert.is_nil(ok)
        assert.equal("standalone entrypoint path must end in .c", err)
    end)

    posix_output_it("rejects source and synthetic output collisions before compilation",
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
        local available, message = require("spec.support.filesystem").symlink_capability()
        if not available then pending(message); return end
        local root = temporary.name()
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

        if platform.windows then
            assert(lfs.rmdir(linked))
        else
            assert(os.remove(linked))
        end
        assert(lfs.rmdir(physical))
        assert(lfs.rmdir(root))
    end)

    posix_output_it("rejects hierarchy conflicts and nonregular output leaves", function(entries)
        local root = entries and "/fixture/owner" or temporary.name()
        if entries then
            entries[root] = { mode = "directory" }
        else
            assert(os.remove(root))
            assert(lfs.mkdir(root))
        end

        local ok, message = driver.validate_program_output_paths({
            {
                modname = "suite.child",
                output = root .. "/suite/child.titan",
            },
        }, root .. "/suite", root .. "/entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("path hierarchy conflict", message, 1, true)

        local directory_output = root .. "/support.c"
        if entries then entries[directory_output] = { mode = "directory" }
        else assert(lfs.mkdir(directory_output)) end
        ok, message = driver.validate_program_output_paths({
            { modname = "support", output = root .. "/support.titan" },
        }, root .. "/suite", root .. "/entrypoint.c", {})
        assert.is_nil(ok)
        assert.matches("not a regular nonlink file", message, 1, true)

        if not entries then remove_tree(root) end
    end)

    describe("exported API split artifact destinations", function()
        local root
        before_each(function()
            root = temporary.name()
            assert(os.remove(root))
            assert(lfs.mkdir(root))
        end)
        after_each(function() remove_tree(root) end)

        it("preserves authored private headers but accepts compiler-owned ones", function()
            local stem = root .. "/module"
            local sources = { { modname = "module", output = stem .. ".titan",
                                c_parts = 3 } }
            for _, suffix in ipairs({ ".priv.h" }) do
                local filename = stem .. suffix
                local contents = "authored " .. suffix .. "\n"
                write_file(filename, contents)
                local ok, err = driver.validate_program_output_paths(
                    sources, root .. "/program", root .. "/entrypoint.c", {})
                assert.is_nil(ok, suffix)
                assert.matches("refusing to overwrite user-owned", err, 1, true)
                assert.matches(paths.to_slash(paths.normalize(filename)), err, 1, true)
                assert.equal(contents, assert(util.get_file_contents(filename, "rb")))
                assert.is_nil(lfs.attributes(stem .. ".c"))
                assert.is_nil(lfs.attributes(stem .. ".o"))
                assert(os.remove(filename))
            end

            local header = "/* Generated by Titan: module private declarations. */\n" ..
                "/* declarations */\n"
            write_file(stem .. ".priv.h", header)
            local ok, err = driver.validate_program_output_paths(
                sources, root .. "/program", root .. "/entrypoint.c", {})
            assert.truthy(ok, err)
            assert.equal(header, assert(util.get_file_contents(stem .. ".priv.h", "rb")))
        end)

        it("rejects every sidecar collision with a native input or another module's output", function()
            local stem = root .. "/module"
            local split = { modname = "module", output = stem .. ".titan", c_parts = 3 }
            for part = 1, 2 do
                for _, suffix in ipairs({ ".c", ".o" }) do
                    local filename = stem .. ".part" .. part .. suffix
                    local contents = "native input " .. filename .. "\n"
                    write_file(filename, contents)
                    local normalized = paths.to_slash(paths.normalize(filename))
                    local ok, err = driver.validate_program_output_paths(
                        { split }, root .. "/program", root .. "/entrypoint.c",
                        { filename })
                    assert.is_nil(ok, filename)
                    assert.matches(normalized, err, 1, true)
                    assert.matches("logical module 'module'", err, 1, true)
                    assert.matches("aliases input", err, 1, true)

                    ok, err = driver.validate_program_output_paths({
                        { modname = "other", output = root .. "/other.titan",
                          foreign_header = filename },
                        split,
                    }, root .. "/program", root .. "/entrypoint.c", {})
                    assert.is_nil(ok, filename)
                    assert.matches(normalized, err, 1, true)
                    assert.matches("logical module 'module'", err, 1, true)
                    assert.matches("generated foreign header for logical module 'other'", err, 1, true)
                    assert.matches("aliases output", err, 1, true)
                    assert.equal(contents, assert(util.get_file_contents(filename, "rb")))
                    assert(os.remove(filename))
                end
            end
        end)
    end)
end)

describe("build output preflight", function()
    local root, contexts, previous_imported, previous_registry
    before_each(function()
        root = temporary.name()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        contexts = {}
        previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        driver.imported, types.registry = previous_imported, previous_registry
        for _, context in ipairs(contexts) do driver.close_resolver_context(context) end
        remove_tree(root)
    end)

    local function resolver()
        local context = driver.new_resolver_context()
        contexts[#contexts + 1] = context
        return context
    end

    local function descriptor(name, contents)
        local relative = name:gsub("[.]", "/")
        local directory = root
        for component in relative:gmatch("([^/]+)/") do
            directory = directory .. "/" .. component
            if not lfs.attributes(directory) then assert(lfs.mkdir(directory)) end
        end
        local filename = root .. "/" .. relative .. ".titan"
        write_file(filename, contents)
        return { kind = "flat", main = filename, files = { filename },
            program_output = root .. "/" .. relative }
    end

    -- Fresh source modules in dependency order.
    local function source_plan(sources)
        local plan = { order = {}, modules = {} }
        for _, entry in ipairs(sources) do
            plan.order[#plan.order + 1] = entry[1]
            plan.modules[entry[1]] = { kind = "source", source = descriptor(entry[1], entry[2]) }
        end
        return plan
    end

    local function preflight(plan, options)
        options.c_parts = options.c_parts or 1
        return driver.preflight_build_outputs(resolver(), plan, options)
    end

    local function reserved(plan, owner, suffix)
        for _, reservation in ipairs(plan.reservations) do
            if reservation.owner == owner and (suffix == nil or
               paths.to_slash(reservation.path):sub(-#suffix) == suffix) then
                return reservation
            end
        end
    end

    local function contains(values, expected)
        for _, value in ipairs(values) do
            if paths.to_slash(value) == paths.to_slash(expected) then return true end
        end
        return false
    end

    it("selects main through local, self-qualified and imported source aliases", function()
        local plan = source_plan({
            { "types", "type Args = {string}\n" },
            { "app", [[
local types = import "types"
type Arguments = types.Args
type Result = integer
type Code = M.Result
function main(args: Arguments): Code
    return 0
end
]] },
        })
        assert(preflight(plan, { roots = { "app" } }))
        assert.is_table(reserved(plan, "standalone executable"))
        assert.is_nil(reserved(plan, "provider DSO"))

        -- Without the alias target the signature is not a program entry.
        plan = source_plan({ { "lib", "type Code = integer\nfunction main(args: Unknown): Code return 0 end\n" } })
        assert(preflight(plan, { roots = { "lib" } }))
        assert.is_nil(reserved(plan, "standalone executable"))
        assert.is_table(reserved(plan, "provider DSO"))
    end)

    it("selects main through an alias of an already checked dependency interface", function()
        local parser = require "titan-compiler.parser"
        local checker = require "titan-compiler.checker"
        local contents = "type Args = {string}\n"
        local filename = root .. "/checked_types.titan"
        write_file(filename, contents)
        local ast = assert(parser.parse(filename, contents))
        local modtype, errors = checker.check("checked_types", ast, contents, filename)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        driver.imported.checked_types = { kind = "dynamic", type = modtype }
        local plan = source_plan({ { "app", [[
local checked_types = import "checked_types"
function main(args: checked_types.Args): integer
    return 0
end
]] } })
        assert(preflight(plan, { roots = { "app" } }))
        assert.is_table(reserved(plan, "standalone executable"))
    end)

    it("rejects a second main and program-only options for a library", function()
        local main = "function main(args: {string}): integer return 0 end\n"
        local ok, err = preflight(source_plan({ { "app", main }, { "tool", main } }),
            { roots = { "app", "tool" } })
        assert.is_nil(ok)
        assert.equal("tool: multiple main functions found (already declared in app)", err)
        -- Test and compile-only builds never select a standalone main.
        assert(preflight(source_plan({ { "app", main }, { "tool", main } }),
            { roots = { "app", "tool" }, compile_only = true }))

        local library = "function answer(): integer return 42 end\n"
        ok, err = preflight(source_plan({ { "lib", library } }),
            { roots = { "lib" }, exe = root .. "/bin/lib" })
        assert.is_nil(ok)
        assert.equal("--exe is only valid when compiling a standalone or test executable", err)
        ok, err = preflight(source_plan({ { "lib", library } }),
            { roots = { "lib" }, no_uv_bootstrap = true })
        assert.is_nil(ok)
        assert.equal("--no-uv-bootstrap is only valid when compiling a standalone executable", err)
    end)

    it("rejects unrelated library roots and colliding C symbol prefixes", function()
        local library = "function answer(): integer return 42 end\n"
        local ok, err = preflight(source_plan({ { "alpha", library }, { "beta", library } }),
            { roots = { "alpha", "beta" } })
        assert.is_nil(ok)
        assert.equal("cannot link modules into one shared library: 'alpha' and 'beta' " ..
            "have no common module prefix", err)
        ok, err = preflight(source_plan({ { "clash.a-b", library }, { "clash.a.b", library } }),
            { roots = { "clash.a-b", "clash.a.b" } })
        assert.is_nil(ok)
        assert.equal("cannot link logical modules 'clash.a-b' and 'clash.a.b': " ..
            "both use C symbol prefix 'clash_a_b'", err)
    end)

    it("reserves only the provider pair for a library without generated Lua files", function()
        local archive = root .. "/libpkg_dep.a"
        write_file(archive, "!<arch>\n")
        local plan = source_plan({ { "pkg.app", "function answer(): integer return 42 end\n" } })
        plan.modules["pkg.dep"] = { kind = "static", archive = archive }
        driver.imported["pkg.dep"] = {
            kind = "static", static_archive = archive,
            external_symbols = coder.interface_external_symbols("pkg.dep",
                types.Module("pkg.dep", {})),
            static_provider = { archive = archive, entries = {
                ["pkg.dep"] = { type = types.Module("pkg.dep", {}) },
                ["pkg.carried"] = { type = types.Module("pkg.carried", {}) },
            } },
        }
        assert(preflight(plan, { roots = { "pkg.app" }, output_root = root .. "/out" }))
        -- The single requested root is the provider: pkg.app, not its parent.
        local suffix = platform.windows and ".dll" or ".so"
        assert.is_table(reserved(plan, "provider DSO", "/out/pkg/app" .. suffix))
        if not platform.windows then
            assert.is_table(reserved(plan, "provider archive", "/out/pkg/app.a"))
        end
        assert.is_nil(reserved(plan, "provider DSO", "/out/pkg" .. suffix))
        for _, reservation in ipairs(plan.reservations) do
            assert.is_nil(reservation.path:match("%.lua$"), reservation.path)
        end
        assert.is_true(contains(plan.inputs, archive))
    end)

    it("certifies a saved module from its record's inventory and header inputs", function()
        local plan = source_plan({ { "saved", "function answer(): integer return 42 end\n" } })
        plan.modules.saved.certified = { status = "hit", record = {
            type = types.Module("saved", {}),
            object_metadata = { has_main = false },
            c_header_dependencies = {
                { kind = "quoted", path = root .. "/saved.h" },
                { kind = "search", path = root .. "/candidate.h" },
            },
        } }
        assert(preflight(plan, { roots = { "saved" } }))
        assert.is_true(contains(plan.inputs, root .. "/saved.h"))
        assert.is_false(contains(plan.inputs, root .. "/candidate.h"))
        assert.is_table(reserved(plan, "provider DSO"))
    end)

    it("recognizes older compiler-generated C and refuses authored C at an output", function()
        local cpreamble = require "titan-compiler.cpreamble"
        local stem = root .. "/gen"
        local split_push = "#if defined(__ELF__)\n#pragma GCC visibility push(protected)\n" ..
            "#endif\nint split_unit;\n"
        local cases = {
            { "/* An older generated unit. */\n" .. cpreamble.fixed_prefix, true },
            { "#include \"" .. root .. "/elsewhere/gen.priv.h\"\n" .. split_push, false },
            { "int authored(void) { return 1; }\n", false },
        }
        if not platform.windows then
            cases[#cases + 1] = { "#include " ..
                assert(ffiheaders.quote_header(paths.normalize(stem .. ".priv.h"))) .. "\n" ..
                split_push, true }
            cases[#cases + 1] = { "#include \"/moved/output/gen.priv.h\"\n" .. split_push,
                true, driver.PRIVATE_HEADER_MARKER .. "\n" }
        end
        for index, case in ipairs(cases) do
            local plan = source_plan({ { "gen", "function answer(): integer return 42 end\n" } })
            write_file(stem .. ".c", case[1])
            if case[3] then write_file(stem .. ".priv.h", case[3]) end
            local ok, err = preflight(plan, { roots = { "gen" }, compile_only = true })
            if case[2] then
                assert.truthy(ok, err)
            else
                assert.is_nil(ok, index)
                assert.matches("for logical module 'gen' aliases input", err, 1, true)
                assert.matches("(not compiler-generated C; move it or use another output directory)",
                    err, 1, true)
            end
            if case[3] then assert(os.remove(stem .. ".priv.h")) end
        end
    end)
end)

describe("compiler module loader", function()
    local root
    local source
    local binary
    local previous
    local native_abi_exports
    local static_provider_exports

    local function provider_path(path)
        return (path:gsub("%.so$", platform.windows and ".dll" or ".so"))
    end

    -- Fake providers declare the plain-C query independently of their Lua
    -- metadata callbacks, just as real Windows providers do.
    local function mock_native_abi(filename, modules)
        local exports = {}
        for name, query in pairs(modules) do
            exports[driver.mangle_module_name(name) .. "_abi_value"] = query
        end
        native_abi_exports[filename] = exports
        titan._abivalue = function(found_filename, symbol)
            local provider = assert(native_abi_exports[found_filename],
                "unexpected native ABI provider " .. found_filename)
            local query = provider[symbol]
            if query == nil then
                return nil, "undefined symbol: " .. symbol, "init"
            end
            if type(query) == "function" then return query() end
            return query
        end
    end

    local function cache_static_provider(context, filename, module_types)
        write_file(filename, "mock static provider\n")
        local provider = {
            archive = filename,
            entries = {},
            key_order = {},
        }
        -- Static metadata reconstructs canonical logical .so paths on every host.
        for name, modtype in pairs(module_types) do
            provider.entries[name] = {
                abi = driver.TITAN_ABI_VERSION,
                type = modtype,
                types = types.serialize(modtype),
                layouts = empty_layouts(name),
                layout_inventory = assert(require("titan-compiler.nominallayout").decode(
                    empty_layouts(name), name)),
                origin = filename .. ":" .. name,
            }
            provider.key_order[#provider.key_order + 1] = name
        end
        table.sort(provider.key_order, util.bytewise_less)
        static_provider_exports[filename] = provider
        staticmetadata.scan_archive = function(found_filename, options)
            local template = static_provider_exports[found_filename]
            if not template then
                return previous.scan_archive(found_filename, options)
            end
            local result = {
                archive = found_filename,
                entries = {},
                key_order = { table.unpack(template.key_order) },
            }
            for name, entry in pairs(template.entries) do
                local copy = {}
                for k, v in pairs(entry) do copy[k] = v end
                if options and options.validate_types and copy.types then
                    local decoded_types, err = options.validate_types(
                        name, copy.types, copy.origin or found_filename)
                    if not decoded_types then return nil, err end
                    copy.decoded_types = decoded_types
                end
                if options and options.validate_layouts and copy.layouts then
                    local decoded_layouts, err = options.validate_layouts(
                        name, copy.layouts)
                    if not decoded_layouts then return nil, err end
                    copy.decoded_layouts = decoded_layouts
                end
                result.entries[name] = copy
            end
            return result
        end
        context.provider_cache[filename] = provider
        return provider
    end

    local function cache_dynamic_provider(filename, module_types)
        write_file(filename, "mock dynamic provider\n")
        local abi_values = {}
        for name in pairs(module_types) do abi_values[name] = driver.TITAN_ABI_VERSION end
        mock_native_abi(filename, abi_values)
        titan._loadlib = function(found_filename, symbol)
            assert.equal(filename, found_filename)
            for name, modtype in pairs(module_types) do
                local prefix = driver.mangle_module_name(name)
                if symbol == prefix .. "_abi" then
                    return function() return driver.TITAN_ABI_VERSION end
                elseif symbol == prefix .. "_types" then
                    local serialized = types.serialize(modtype)
                    return function() return serialized end
                elseif symbol == prefix .. "_layouts" then
                    return function() return empty_layouts(name) end
                end
            end
            error("unexpected symbol " .. symbol)
        end
    end

    local function embedded_provider(filename, module_types, profile)
        local provider = {
            provider_file = filename,
            entries = {},
        }
        if profile then
            provider.target_profile =
                assert(csemantics.export_profile(profile))
        end
        for name, modtype in pairs(module_types) do
            provider.entries[name] = {
                abi = driver.TITAN_ABI_VERSION,
                types = types.serialize(modtype),
            }
        end
        return provider
    end

    local function native_target_profile()
        local context = driver.new_resolver_context()
        local profile, err = driver.get_target_profile(context)
        assert.is_true(driver.close_resolver_context(context))
        return assert(profile, err)
    end

    local function numeric_embedded_module(name, profile)
        local lua_state = types.CPointer(types.CStruct(
            "lua_State", "lua_State", nil, {}, false, false), {})
        local callback = types.CPointer(types.CFunction(
            { lua_state }, profile.integers.int.type, false, nil), {})
        local function member(member_name, result)
            return types.ModuleMember(name, member_name,
                types.Function({}, { result }, false, nil, nil), {})
        end
        return types.Module(name, {
            member("callback", callback),
            member("answer", profile.integers.int.type),
            member("measure", profile.floats.double.type),
        })
    end

    local function result_module(name, result_type)
        return types.Module(name, {
            types.ModuleMember(name, "answer",
                types.Function({}, { result_type }, false, nil, nil),
                {}),
        })
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

    local function process_header_inputs(filename, options)
        local ffi_types, process_error, include =
            cdriver.process_file(filename, options)
        assert.truthy(ffi_types, process_error)
        local inputs = {}
        for _, input in ipairs(include.c_header_dependencies or {}) do
            inputs[#inputs + 1] = input
        end
        for _, input in ipairs(include.c_header_search_inputs or {}) do
            inputs[#inputs + 1] = input
        end
        return inputs
    end

    local function header_input_identity(inputs, kind, path)
        for _, input in ipairs(inputs) do
            if input.kind == kind and input.path == path then
                return input.identity
            end
        end
    end

    local function generated_source_manifest(contents)
        driver.imported = {}
        types.registry = {}
        local name = "source_manifest_generated"
        local filename = root .. "/" .. name .. ".titan"
        local loader = driver.defaultloader({}, resolver_options({ source_roots = { [name] = true }, source_overrides = {
            [name] = {
                kind = "generated",
                main = filename,
                files = { filename },
                contents = { [filename] = contents },
            },
        }, }))
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

    it("reports source-interface serialization failures with checker diagnostics",
    function()
        local name = "source_manifest_publication_failure"
        local filename = source .. "/" .. name .. ".titan"
        write_file(filename, [[
            function answer(): integer
                return "wrong type"
            end
        ]])
        local context = driver.new_resolver_context({ analysis_only = true })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, { context = context })
        local serialize = types.serialize
        types.serialize = function(modtype)
            if modtype.name == name then
                error("forced source-interface failure", 0)
            end
            return serialize(modtype)
        end
        local called, ok, modtype, errors, info = pcall(loader, name)
        types.serialize = serialize

        assert.truthy(called, tostring(ok))
        assert.is_true(ok, tostring(modtype))
        assert.equal(2, #errors, table.concat(errors, "\n"))
        assert.matches(filename .. ":2:", errors[1], 1, true)
        assert.matches("type error:", errors[1], 1, true)
        assert.matches("string", errors[1], 1, true)
        assert.matches("integer", errors[1], 1, true)
        assert.equal(filename .. ":1:1: could not serialize source interface " ..
            "for module '" .. name .. "': forced source-interface failure",
            errors[2])
        local entry = assert(driver.imported[name])
        assert.equal("source", entry.kind)
        assert.equal(modtype, entry.type)
        assert.is_table(entry.ast)
        assert.is_nil(entry.source_manifest)
        assert.is_true(static_deps[name])
        assert.same({ name }, context.checked_source_modules)
        assert.equal("source", info.kind)
        assert.equal(filename, info.filename)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))

        -- A fresh analysis can recover without a stale circularity marker or
        -- failed interface escaping into its reusable source state.
        driver.imported = {}
        types.registry = {}
        write_file(filename, "function answer(): integer return 42 end\n")
        loader = driver.defaultloader({}, resolver_options())
        ok, modtype, errors = loader(name)
        assert.is_true(ok, tostring(modtype))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_string(driver.imported[name].source_manifest)
        assert.is_true(driver.close_loader(loader))
    end)

    it("propagates source-interface diagnostics from ordinary source imports",
    function()
        local dependency = "source_manifest_failed_dependency"
        local consumer = "source_manifest_import_consumer"
        local dependency_filename = source .. "/" .. dependency .. ".titan"
        write_file(dependency_filename,
            "function answer(): integer return 42 end\n")
        write_file(source .. "/" .. consumer .. ".titan", [[
            local provider = import "source_manifest_failed_dependency"
            function answer(): integer return provider.answer() end
        ]])
        local context = driver.new_resolver_context({ analysis_only = true })
        local loader = driver.defaultloader({}, { context = context })
        local serialize = driver.serialize_source_interface
        driver.serialize_source_interface = function(entry)
            if entry.type.name == dependency then
                return nil, "forced source-interface validation failure"
            end
            return serialize(entry)
        end
        local called, ok, modtype, errors = pcall(loader, consumer)
        driver.serialize_source_interface = serialize

        assert.truthy(called, tostring(ok))
        assert.is_true(ok, tostring(modtype))
        assert.equal(1, #errors, table.concat(errors, "\n"))
        assert.equal(dependency_filename ..
                ":1:1: could not serialize source interface " ..
                "for module '" .. dependency ..
                "': forced source-interface validation failure",
            errors[1])
        assert.is_nil(driver.imported[dependency].source_manifest)
        assert.is_table(driver.imported[dependency].ast)
        assert.is_string(driver.imported[consumer].source_manifest)
        assert.same({ dependency, consumer }, context.checked_source_modules)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("retains a source manifest when checking reports body errors",
    function()
        local name = "source_manifest_body_error"
        write_file(source .. "/" .. name .. ".titan", [[
            function answer(): integer
                return "wrong type"
            end
        ]])
        local loader = driver.defaultloader({}, resolver_options())
        local ok, modtype, errors = loader(name)
        assert.is_true(ok, tostring(modtype))
        assert.equal(1, #errors, table.concat(errors, "\n"))
        assert.matches("type error:", errors[1], 1, true)
        local entry = driver.imported[name]
        assert.is_string(entry.source_manifest)
        assert.equal(source_manifest(entry), entry.source_manifest)
        assert.is_true(driver.close_loader(loader))
    end)

    before_each(function()
        root = temporary.name()
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
            abivalue = titan._abivalue,
            scan_archive = staticmetadata.scan_archive,
        }
        native_abi_exports = {}
        static_provider_exports = {}
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
        titan._abivalue = previous.abivalue
        staticmetadata.scan_archive = previous.scan_archive
        remove_tree(root)
    end)

    describe("incremental source objects", function()
        local loaders, contexts, original_incremental
        local original_linker_backend, original_cppflags
        before_each(function()
            original_linker_backend =
                require("titan-compiler.linkcertificate").linker_backend
            original_cppflags = driver.EXTRA_CPPFLAGS
            loaders, contexts, original_incremental = {}, {}, {}
            for _, name in ipairs({
                    "configuration", "toolchain_identity", "make_certificate" }) do
                original_incremental[name] = incremental[name]
            end
        end)
        after_each(function()
            require("titan-compiler.linkcertificate").linker_backend =
                original_linker_backend
            driver.EXTRA_CPPFLAGS = original_cppflags
            for name, implementation in pairs(original_incremental) do
                incremental[name] = implementation
            end
            for _, loader in ipairs(loaders) do driver.close_loader(loader) end
            for _, context in ipairs(contexts) do
                driver.close_resolver_context(context)
            end
        end)

        local function tracked_context(options)
            local context = driver.new_resolver_context(options)
            contexts[#contexts + 1] = context
            return context
        end

        local function uncertain_toolchain()
            return nil, "native delegate selection is unknown", "uncertified"
        end

        local function fresh_loader(options)
            driver.imported, types.registry = {}, {}
            options = options or {}
            if options.source_first == nil then
                options.source_first = true
            end
            options.context = options.context or tracked_context(options)
            local dependencies = {}
            local loader = driver.defaultloader(dependencies, options)
            loaders[#loaders + 1] = loader
            return loader, dependencies
        end

        local function load_ok(loader, name)
            local ok, result, errors = loader(name)
            assert.is_true(ok, tostring(result))
            assert.equal(0, #errors, table.concat(errors, "\n"))
            return driver.imported[name]
        end

        local function capture_stderr(action)
            local chunks = {}
            local original_stderr = io.stderr
            io.stderr = {
                write = function(_, ...)
                    for index = 1, select("#", ...) do
                        chunks[#chunks + 1] = tostring(select(index, ...))
                    end
                    return true
                end,
            }
            local ok, result = xpcall(action, debug.traceback)
            io.stderr = original_stderr
            assert.is_true(ok, result)
            return result, table.concat(chunks)
        end

        -- These driver tests only load metadata. A small real native object
        -- isolates the source fast path from code generation and final linking.
        local function write_source_object(entry, payload, mutator, options)
            options = options or {}
            local stem = (entry.native_output or entry.filename):gsub("[.]titan$", "")
            local object = stem .. ".o"
            local context = options.context or driver.new_resolver_context()
            local owns_context = options.context == nil
            assert(driver.incremental_configuration(context))
            local static_deps = options.static_deps or { [entry.type.name] = true }
            local imports, bindings, providers = {}, {}, {}
            for _, node in ipairs(entry.ast or {}) do
                if not node._ignore and node._tag == "Ast.TopLevelImport" then
                    local dep = driver.imported[node.modname]
                    imports[#imports + 1] = {
                        name = node.modname,
                        source_required = node._source_import == true,
                    }
                    if static_deps[node.modname] or (dep and dep.kind ~= "dynamic") then
                        bindings[node.modname] = "direct"
                    elseif dep and dep.kind == "dynamic" then
                        bindings[node.modname] = "handle"
                        providers[node.modname] = dep.type.file
                    end
                end
            end
            for owner_name in pairs(entry.ast and entry.ast._binary_usage or {}) do
                if owner_name ~= entry.type.name and not bindings[owner_name] then
                    local recovered = context.contextual_owner_entries and
                        context.contextual_owner_entries[owner_name]
                    if static_deps[owner_name] or (recovered and recovered.linked) then
                        bindings[owner_name] = "direct"
                    else
                        bindings[owner_name] = "global"
                    end
                end
            end
            local source_desc = {
                kind = #entry.source_files > 1 and "folder" or "flat",
                main = entry.filename,
                files = entry.source_files,
                native_output = entry.native_output,
            }
            local source_cert = entry.source_certificate or
                incremental.source_certificate(context, source_desc)
            local layouts = empty_layouts(entry.type.name)
            local foreign_header
            if entry.ast then
                foreign_header = driver.plan_foreign_header(entry.type.name,
                    entry.ast, entry.native_output or entry.filename, false).recipe
            end
            local generated = "int ordinary_object;\n"
            local native = {
                has_main = false,
                imports = imports,
                bindings = bindings,
                providers = providers,
                native_references = {},
                external_symbols = {},
                layouts = layouts,
                foreign_header = foreign_header,
                parts_version = 1,
                parts = {
                    { index = 0, c_suffix = ".c", object_suffix = ".o" },
                },
            }
            native.generated_inputs = { {
                spelling = stem .. ".c", bytes = #generated,
                sha256 = incremental.digest(context, "generated-c", generated),
                semantic = assert(incremental.preprocessed_identities(context,
                    { { filename = stem .. ".c", contents = generated } }))[1],
            } }
            entry.interface_digests = assert(incremental.producer_digests(
                context, entry, layouts, native.foreign_header))
            native.certificate = assert(incremental.make_certificate(
                context, entry, native, {
                    source = source_cert,
                    stem = context.incremental_options.stem(
                        entry.type.name, source_desc),
                    codegen = context.incremental_options.codegen_options(
                        entry.type.name, native),
                    plan = {
                        linked = function(dep_name)
                            if static_deps[dep_name] then return true end
                            local recovered = context.contextual_owner_entries and
                                context.contextual_owner_entries[dep_name]
                            if recovered then return recovered.linked == true end
                            local dep = driver.imported[dep_name]
                            return dep ~= nil and dep.kind ~= "dynamic"
                        end,
                        provider_file = function(dep_name)
                            local dep = driver.imported[dep_name]
                            return dep and dep.kind == "dynamic" and
                                dep.type and dep.type.file or nil
                        end,
                        digest = function(dep_name, view)
                            local dep = driver.imported[dep_name] or
                                (context.contextual_owner_entries and
                                    context.contextual_owner_entries[dep_name])
                            return dep and incremental.interface_digest(
                                context, dep, view) or nil
                        end,
                    },
                    binary_usage = entry.ast and entry.ast._binary_usage or {},
                    generated_parts = {
                        { index = 0, code = generated },
                    },
                }))
            if mutator then mutator(native) end
            if payload == nil then payload = assert(objectmetadata.encode(entry, native)) end
            local code = generated .. (payload == false and ""
                or assert(objectmetadata.render(payload, "source_metadata")))
            write_file(stem .. ".c", code)
            if type(native.certificate) == "table" and type(native.certificate.object_identity) == "string" then
                incremental.record_materialization(context, stem, native.certificate)
            end
            if owns_context then
                assert.is_true(driver.close_resolver_context(context))
            end
            local argv = assert(driver.generated_compile_prefix())
            for _, argument in ipairs({ "-c", stem .. ".c", "-o", object }) do
                argv[#argv + 1] = argument
            end
            local result = compiler_io.new_sync():run(argv)
            assert.is_true(result.ok, result.output or result.diagnostic)
            return object, native
        end

        it("digests through the native support library unless the caller supplies an adapter", function()
            local sha256 = require "titan-compiler.sha256"
            local context = tracked_context()
            local adapter = context.cache_adapter
            assert.equal(titan._sha256_binary, adapter.sha256_binary)
            assert.equal(titan._sha256_stream, adapter.sha256_stream)
            assert.is_nil(adapter.get)
            assert.is_nil(adapter.put)
            assert.are_not.equal(adapter, tracked_context().cache_adapter)
            local value = { module = "identity", sizes = { 1, 2 } }
            assert.equal(incremental.digest({}, "fixture", value),
                incremental.digest(context, "fixture", value))
            local filename = source .. "/digested.titan"
            local contents = "function answer(): integer return 42 end\n"
            write_file(filename, contents)
            assert.equal(sha256.hex(contents), (incremental.file_digest(context, filename)))

            local caller = { get = function() end }
            local supplied = driver.new_resolver_context({ cache_adapter = caller })
            contexts[#contexts + 1] = supplied
            assert.equal(caller, supplied.cache_adapter)

            local loaded = package.loaded.titan
            package.loaded.titan = {}
            local created, without = pcall(driver.new_resolver_context)
            package.loaded.titan = loaded
            assert.is_true(created, without)
            contexts[#contexts + 1] = without
            assert.is_nil(without.cache_adapter)
        end)

        it("certifies streamed compiler and frontend inputs under coarse observations without a caller adapter", function()
            local threshold = incremental.STREAM_THRESHOLD_BYTES
            local compiler_root = root .. "/compiler"
            for _, directory in ipairs({ "", "/titan-compiler", "/titan-compiler/checker",
                    "/titan-compiler/coder", "/c-parser" }) do
                assert(lfs.mkdir(compiler_root .. directory))
            end
            local large_lua = compiler_root .. "/titan-compiler/large.lua"
            local frontend = root .. "/titanc-frontend"
            write_file(compiler_root .. "/titan-compiler/small.lua", "return {}\n")
            write_file(large_lua, "return " .. string.rep("0", threshold) .. "\n")
            write_file(frontend, "-- " .. string.rep("f", threshold) .. "\n")
            local absorbed = {}
            -- Absorbed inputs are keyed by the driver's own spelling of each
            -- path, which differs from the fixture's on Windows.
            local function canonical_key(path)
                return paths.to_slash(paths.normalize(path))
            end
            local function canonical_absorption(entries)
                local normalized = {}
                for path, count in pairs(entries) do
                    normalized[canonical_key(path)] = count
                end
                return normalized
            end
            local function coarse_io()
                local strategy = compiler_io.new_sync()
                for _, method in ipairs({ "stat", "lstat" }) do
                    local observe = strategy[method]
                    strategy[method] = function(self, path)
                        local stat, err = observe(self, path)
                        if not stat then return stat, err end
                        local coarse = {}
                        for field, value in pairs(stat) do coarse[field] = value end
                        coarse.precision, coarse.time_precision = "coarse", "coarse"
                        return coarse
                    end
                end
                local absorb = strategy.absorb_file
                function strategy:absorb_file(path, stream)
                    absorbed[path] = (absorbed[path] or 0) + 1
                    return absorb(self, path, stream)
                end
                return strategy
            end
            local options = { compiler_root = compiler_root, frontend = frontend }
            local function component(cache_adapter)
                local context = driver.new_resolver_context({
                    io = coarse_io(), cache_adapter = cache_adapter,
                })
                contexts[#contexts + 1] = context
                return assert(incremental.compiler_component(context, options))
            end
            -- A caller's digest without a stream reads each whole file.
            local whole_read = { sha256_binary = titan._sha256_binary }

            local streamed = component()
            assert.same({ [canonical_key(large_lua)] = 1, [canonical_key(frontend)] = 1 },
                canonical_absorption(absorbed))
            absorbed = {}
            assert.equal(component(whole_read), streamed)
            assert.same({}, absorbed)

            write_file(large_lua, "return " .. string.rep("1", threshold) .. "\n")
            local changed = component()
            assert.are_not.equal(streamed, changed)
            assert.equal(component(whole_read), changed)
        end)

        it("propagates only explicit native policy uncertainty without a partial configuration", function()
            incremental.toolchain_identity = uncertain_toolchain
            local context = tracked_context()
            local configuration, reason, status =
                driver.incremental_configuration(context)
            assert.is_nil(configuration)
            assert.equal("native delegate selection is unknown", reason)
            assert.equal("uncertified", status)
            assert.is_nil(context.incremental_configuration)
            assert.is_table(context.incremental_options)
            assert.is_string(assert(incremental.compiler_component(context)))
            local again, same_reason, same_status =
                driver.incremental_configuration(context)
            assert.is_nil(again)
            assert.equal(reason, same_reason)
            assert.equal(status, same_status)

            incremental.configuration = function()
                return nil, "native delegate selection is unknown"
            end
            local failed_context = tracked_context()
            local failed, failure, failure_status =
                driver.incremental_configuration(failed_context)
            assert.is_nil(failed)
            assert.matches("cannot certify compiler configuration:", failure, 1, true)
            assert.is_nil(failure_status)
            assert.is_nil(failed_context.incremental_uncertified)
            local cancellation = {}
            incremental.configuration = function() error(cancellation, 0) end
            local completed, raised = pcall(driver.incremental_configuration,
                failed_context)
            assert.is_false(completed)
            assert.equal(cancellation, raised)
        end)

        it("forwards proven compiler stage policy and explicit output uncertainty without another query", function()
            local context = tracked_context()
            local calls = 0
            local tools = { { path = "C:/llvm/bin/clang.exe" } }
            incremental.toolchain_identity = function()
                calls = calls + 1
                return "observed-toolchain", { stage_policy = "llvm", tools = tools }
            end
            local request = assert(driver.output_tool_descriptors(context))
            assert.equal("observed-toolchain", request.toolchain)
            assert.equal("llvm", request.compiler_stage_policy)
            -- Stale-stage retirement protects these already observed binaries.
            assert.equal(tools, request.compiler_tools)
            assert.is_nil(request.uncacheable)
            assert.equal(1, calls)

            incremental.toolchain_identity = uncertain_toolchain
            request = assert(driver.output_tool_descriptors(context))
            assert.is_nil(request.toolchain)
            assert.is_nil(request.compiler_stage_policy)
            assert.is_nil(request.compiler_tools)
            assert.equal("native delegate selection is unknown", request.uncacheable)
            incremental.toolchain_identity = function()
                return nil, "cannot read native executable"
            end
            local failed, failure = driver.output_tool_descriptors(context)
            assert.is_nil(failed)
            assert.equal("cannot read native executable", failure)
            local cancellation = {}
            incremental.toolchain_identity = function() error(cancellation, 0) end
            local completed, raised = pcall(driver.output_tool_descriptors, context)
            assert.is_false(completed)
            assert.equal(cancellation, raised)
        end)

        it("preserves uncertain linker status without caching a guessed backend", function()
            incremental.toolchain_identity = uncertain_toolchain
            local context = tracked_context()
            local calls = 0
            local linkcertificate = require "titan-compiler.linkcertificate"
            linkcertificate.linker_backend = function(_, request)
                calls = calls + 1
                assert.equal("native delegate selection is unknown", request.uncacheable)
                return "none", request.uncacheable, "uncertified"
            end
            for _ = 1, 2 do
                local backend, reason, status = driver.native_link_backend(context)
                assert.equal("none", backend)
                assert.equal("native delegate selection is unknown", reason)
                assert.equal("uncertified", status)
                assert.is_nil(context.native_link_backend)
            end
            assert.equal(2, calls)
            linkcertificate.linker_backend = function()
                return nil, "cannot inspect selected linker"
            end
            local failed, failure = driver.native_link_backend(context)
            assert.is_nil(failed)
            assert.equal("cannot inspect selected linker", failure)
            local cancellation = {}
            linkcertificate.linker_backend = function() error(cancellation, 0) end
            local completed, raised = pcall(driver.native_link_backend, context)
            assert.is_false(completed)
            assert.equal(cancellation, raised)
        end)

        it("rebuilds a prior certified object without publishing a certificate under policy uncertainty", function()
            local name = "incremental_driver_uncertain_native"
            write_file(source .. "/" .. name .. ".titan",
                "function answer(): integer return 42 end\n")
            local initial = load_ok(fresh_loader(), name)
            local object = write_source_object(initial)
            incremental.toolchain_identity = uncertain_toolchain
            incremental.make_certificate = function()
                error("uncertified producer must not publish a certificate", 0)
            end
            local context = tracked_context()
            local loader, dependencies = fresh_loader({
                context = context, incremental = true,
            })
            local entry = load_ok(loader, name)
            assert.is_table(entry.ast)
            assert.is_nil(entry.compiled)
            assert.is_table(entry.source_certificate)
            assert(driver.prepare_foreign_headers(
                { name }, driver.imported, false, false))
            local compiled, compile_error, actual_object = driver.compile_module(
                name, entry, dependencies, false, { context = context })
            assert.is_true(compiled, compile_error)
            assert.equal(object, actual_object)
            assert.is_nil(context.incremental_configuration)
            assert.is_nil(entry.interface_digests)
            local bytes = assert(util.get_file_contents(object, "rb"))
            local restored = assert(objectmetadata.read(bytes, object))
            assert.equal(name, restored.type.name)
            assert.is_nil(restored.object_metadata.certificate)
            local next_loader = fresh_loader({
                context = tracked_context(), incremental = true,
            })
            local next_entry = load_ok(next_loader, name)
            assert.is_table(next_entry.ast)
            assert.is_nil(next_entry.compiled)
        end)

        it("plans fresh source imports rather than restoring records under policy uncertainty", function()
            local name = "incremental_driver_uncertain_plan"
            write_file(source .. "/" .. name .. ".titan",
                "function answer(): integer return 42 end\n")
            write_source_object(load_ok(fresh_loader(), name))
            incremental.toolchain_identity = uncertain_toolchain
            local calls = 0
            local loader = fresh_loader({
                context = tracked_context(), incremental = true, plan_mode = true,
                imports_for = function(modname, source_description, certified)
                    calls = calls + 1
                    assert.equal(name, modname)
                    assert.equal(source .. "/" .. name .. ".titan",
                        paths.to_slash(source_description.main))
                    assert.is_nil(certified)
                    return {}
                end,
            })
            local ok, _, errors = loader(name)
            assert.is_true(ok)
            assert.equal(0, #errors)
            assert.equal(1, calls)
            assert.is_true(driver.imported[name]._planned)
            assert.is_nil(driver.imported[name].compiled)
        end)

        it("keeps real worker compiler inventory validation when native policy is uncertified", function()
            incremental.toolchain_identity = uncertain_toolchain
            local context = tracked_context()
            local configuration = assert(driver.worker_configuration(context))
            assert.is_nil(configuration.configuration)
            assert.equal("native delegate selection is unknown", configuration.uncertified)
            assert.equal(assert(incremental.compiler_component(context)),
                configuration.compiler)
            local worker = assert(driver.new_worker_context(
                configuration, compiler_io.new_sync()))
            contexts[#contexts + 1] = worker
            assert.is_nil(worker.incremental_configuration)
            local certificate, reason, status =
                driver.incremental_configuration(worker)
            assert.is_nil(certificate)
            assert.equal(configuration.uncertified, reason)
            assert.equal("uncertified", status)
            assert.is_true(incremental.counters(worker).file_hashes > 0)

            configuration.compiler = configuration.compiler .. "-changed"
            local mismatched, mismatch_error = driver.new_worker_context(
                configuration, compiler_io.new_sync())
            assert.is_nil(mismatched)
            assert.equal("compiler installation changed during build", mismatch_error)
            configuration.compiler = assert(incremental.compiler_component(context))
            local strategy = compiler_io.new_sync()
            local list = strategy.list
            function strategy:list(directory)
                if paths.basename(directory) == "titan-compiler" then
                    return nil, "compiler inventory is unreadable"
                end
                return list(self, directory)
            end
            local unreadable, inventory_error =
                driver.new_worker_context(configuration, strategy)
            assert.is_nil(unreadable)
            assert.matches("compiler inventory is unreadable", inventory_error, 1, true)
            local cancellation = {}
            function strategy:list() error(cancellation, 0) end
            local completed, raised = pcall(driver.new_worker_context,
                configuration, strategy)
            assert.is_false(completed)
            assert.equal(cancellation, raised)
        end)

        it("publishes raw worker dependencies while rejecting changed sources, headers and include candidates", function()
            local producer = "incremental_driver_raw_producer"
            local consumer = "incremental_driver_raw_consumer"
            local producer_file = source .. "/" .. producer .. ".titan"
            local consumer_file = source .. "/" .. consumer .. ".titan"
            local consumer_source = 'local producer = import "' .. producer ..
                '.titan"\nfunction answer(): integer return producer.answer() end\n'
            local include = source .. "/late"
            assert(lfs.mkdir(include))
            local header = source .. "/raw_worker.h"
            local header_contents = '#include "raw_worker_config.h"\n' ..
                "#define TITAN_RAW_WORKER_VALUE RAW_WORKER_CONFIG\n"
            local config_contents = "#define RAW_WORKER_CONFIG 42\n"
            write_file(header, header_contents)
            write_file(include .. "/raw_worker_config.h", config_contents)
            driver.EXTRA_CPPFLAGS = { table.unpack(driver.EXTRA_CPPFLAGS) }
            driver.EXTRA_CPPFLAGS[#driver.EXTRA_CPPFLAGS + 1] = "-I" .. include
            write_file(producer_file,
                'foreign import "raw_worker.h"\n' ..
                "function answer(): integer return ffi.TITAN_RAW_WORKER_VALUE end\n")
            write_file(consumer_file, consumer_source)
            incremental.toolchain_identity = uncertain_toolchain
            incremental.make_certificate = function()
                error("raw worker must not publish a certificate", 0)
            end
            local context = tracked_context()
            local loader = fresh_loader({
                context = context, incremental = true, plan_mode = true,
                imports_for = function(name)
                    return name == consumer and {
                        { name = producer, source_required = true },
                    } or {}
                end,
            })
            local loaded, _, diagnostics = loader(consumer)
            assert.is_true(loaded)
            assert.equal(0, #diagnostics)
            local plan = driver.resolution_plan(context)
            assert.same({ producer, consumer }, plan.order)
            local configuration = assert(driver.worker_configuration(context))
            local function stage(name)
                local descriptor = driver.plan_descriptor(plan, name)
                local imported, registry = driver.imported, types.registry
                driver.imported, types.registry = {}, {}
                local worker = assert(driver.new_worker_context(
                    configuration, compiler_io.new_sync()))
                contexts[#contexts + 1] = worker
                local result, compile_error = driver.compile_planned_module(
                    worker, name, {
                        plan = descriptor, jobs = 2,
                    })
                driver.imported, types.registry = imported, registry
                assert.truthy(result, compile_error)
                assert.is_table(result.source_snapshot)
                return result
            end
            local function reject_changed_inputs(result, expected)
                local rejected, input_error =
                    driver.publish_staged_module(context, result)
                assert.is_nil(rejected)
                assert.matches(expected, input_error, 1, true)
                assert.is_nil(lfs.attributes(result.object))
                for _, item in ipairs(result.staged) do
                    assert.is_nil(lfs.attributes(item.from))
                end
                return input_error
            end
            for _, name in ipairs(plan.order) do
                assert(driver.invalidate_source_object(
                    context, name, plan.modules[name].source))
                local result = stage(name)
                if name == producer then
                    write_file(header, header_contents .. "#define RAW_WORKER_EXTRA 1\n")
                    local header_error = reject_changed_inputs(result, "c-input ")
                    assert.matches("raw_worker.h", header_error, 1, true)
                    write_file(header, header_contents)
                    result = stage(name)
                    local earlier = source .. "/raw_worker_config.h"
                    write_file(earlier, config_contents)
                    local candidate_error = reject_changed_inputs(result, "c-input ")
                    assert.matches("raw_worker_config.h", candidate_error, 1, true)
                    assert.matches("candidate", candidate_error, 1, true)
                    assert(os.remove(earlier))
                    result = stage(name)
                elseif name == consumer then
                    write_file(consumer_file, consumer_source .. "\n")
                    reject_changed_inputs(result, "changed during the build: source-content")
                    write_file(consumer_file, consumer_source)
                    result = stage(name)
                end
                local published = assert(driver.publish_staged_module(context, result))
                assert.equal("built", published.status)
                assert.is_nil(published.record.object_metadata.certificate)
                plan.update(name, published)
                local entry = assert(driver.restore_source_object(
                    context, name, plan.modules[name].source, published,
                    { published = true }))
                assert.is_nil(entry.ast)
                assert.is_string(entry.compiled)
                assert.is_nil(entry.interface_digests)
            end
            assert.is_true(driver.imported[consumer].deps[producer])
            assert.is_nil(context.incremental_configuration)
            local next_context = tracked_context()
            load_ok(fresh_loader({
                context = next_context, incremental = true,
            }), consumer)
            for _, name in ipairs({ producer, consumer }) do
                assert.is_table(driver.imported[name].ast)
                assert.is_nil(driver.imported[name].compiled)
            end
            assert.is_nil(next_context.incremental_configuration)
        end)

        -- A coordinator's planning loader over the given source modules, with
        -- each module's ordinary or `.titan` imports supplied by name.
        local function planning_loader(sources, imports, certified)
            for name, contents in pairs(sources) do
                write_file(source .. "/" .. name .. ".titan", contents)
            end
            if not certified then incremental.toolchain_identity = uncertain_toolchain end
            local context = tracked_context()
            local loader = fresh_loader({
                context = context, incremental = true, plan_mode = true,
                imports_for = function(name) return imports[name] or {} end,
            })
            return context, loader
        end

        -- One worker over closed configuration and descriptor data.
        local function worker_compile(context, descriptor, name, options)
            options = options or {}
            local configuration = assert(driver.worker_configuration(context))
            if options.configure then options.configure(configuration) end
            local imported, registry = driver.imported, types.registry
            local extra_cflags = driver.EXTRA_CFLAGS
            driver.imported, types.registry = {}, {}
            local worker = assert(driver.new_worker_context(
                configuration, compiler_io.new_sync()))
            contexts[#contexts + 1] = worker
            local result, compile_error = driver.compile_planned_module(
                worker, name, { plan = descriptor, jobs = options.jobs })
            driver.imported, types.registry = imported, registry
            driver.EXTRA_CFLAGS = extra_cflags
            return result, compile_error
        end

        local function publish_planned(context, plan, name, options)
            assert(driver.invalidate_source_object(
                context, name, plan.modules[name].source))
            local result = assert(worker_compile(context,
                driver.plan_descriptor(plan, name), name, options))
            local published = assert(driver.publish_staged_module(context, result))
            plan.update(name, published)
            return published, result
        end

        local function raised(action)
            local ok, err = pcall(action)
            assert.is_false(ok)
            return tostring(err)
        end

        it("plans an unavailable import and reports it again from the worker", function()
            local consumer = "planned_unavailable_consumer"
            local missing = "planned_unavailable_dependency"
            local context, loader = planning_loader({
                [consumer] = 'local dependency = import "' .. missing .. '"\n' ..
                    "function answer(): integer return dependency.answer() end\n",
            }, { [consumer] = { { name = missing } } })
            local loaded, _, diagnostics = loader(consumer)
            assert.is_true(loaded)
            assert.equal(0, #diagnostics)
            local plan = driver.resolution_plan(context)
            assert.same({ consumer }, plan.order)
            local unavailable = plan.modules[missing]
            assert.equal("unavailable", unavailable.kind)
            assert.is_string(unavailable.error)
            assert.equal(unavailable.error, plan.modules[consumer].failed[missing])
            assert.is_nil(plan.linked(missing))
            local digest, digest_error = plan.digest(missing)
            assert.is_nil(digest)
            assert.equal("unavailable", digest_error)
            local descriptor = driver.plan_descriptor(plan, consumer)
            assert.same({ kind = "unavailable", linked = false, error = unavailable.error },
                descriptor.modules[missing])
            local result, compile_error = worker_compile(context, descriptor, consumer)
            assert.is_nil(result)
            assert.matches(unavailable.error, compile_error, 1, true)

            -- The plan and its resolver keep their documented preconditions.
            assert.matches("the build plan has no source module '" .. missing .. "'",
                raised(function() driver.plan_descriptor(plan, missing) end), 1, true)
            assert.matches("only planned source modules accept a certified record",
                raised(function() plan.update(missing, {}) end), 1, true)
            assert.matches("a planned module update requires its certified record",
                raised(function() plan.update(consumer, {}) end), 1, true)
            assert.matches("a resolution plan requires an open planning loader bound to its " ..
                "resolver context", raised(function() driver.resolution_plan(context) end), 1, true)
            assert.matches("a resolution plan requires a resolver context",
                raised(function() driver.resolution_plan({}) end), 1, true)
            assert.matches("restoring an object requires a resolver context",
                raised(function() driver.restore_source_object({}, consumer) end), 1, true)
            assert.matches("restoring an object requires a loader bound to its resolver context",
                raised(function()
                    driver.restore_source_object(tracked_context(), consumer)
                end), 1, true)
            assert.matches("source lookup requires a resolver context",
                raised(function() driver.resolve_source({}, consumer) end), 1, true)
        end)

        it("orders import cycles and their importers after acyclic planned modules", function()
            local context, loader = planning_loader({
                planned_cycle_a = "function a(): integer return 1 end\n",
                planned_cycle_b = "function b(): integer return 2 end\n",
                planned_cycle_leaf = "function leaf(): integer return 3 end\n",
                planned_cycle_root = "function root(): integer return 4 end\n",
                planned_cycle_self = "function itself(): integer return 5 end\n",
            }, {
                planned_cycle_root = {
                    { name = "planned_cycle_a" }, { name = "planned_cycle_leaf" },
                    { name = "planned_cycle_self" },
                },
                planned_cycle_a = { { name = "planned_cycle_b" } },
                planned_cycle_b = { { name = "planned_cycle_a" } },
                planned_cycle_self = { { name = "planned_cycle_self" } },
            })
            assert.is_true((loader("planned_cycle_root")))
            local plan = driver.resolution_plan(context)
            assert.same({
                "planned_cycle_leaf", "planned_cycle_a", "planned_cycle_b",
                "planned_cycle_root", "planned_cycle_self",
            }, plan.order)
            assert.is_nil(plan.modules.planned_cycle_leaf.cyclic)
            for _, name in ipairs({ "planned_cycle_a", "planned_cycle_b",
                    "planned_cycle_root", "planned_cycle_self" }) do
                assert.is_true(plan.modules[name].cyclic, name)
            end
            assert.is_string(plan.modules.planned_cycle_b.failed.planned_cycle_a)
            assert.is_string(plan.modules.planned_cycle_self.failed.planned_cycle_self)
        end)

        it("rejects worker descriptors that diverge from the coordinator's plan", function()
            local base, middle = "planned_chain_base", "planned_chain_middle"
            local top, direct = "planned_chain_top", "planned_chain_direct"
            local context, loader = planning_loader({
                [base] = "function answer(): integer return 40 end\n",
                [middle] = 'local base = import "' .. base .. '"\n' ..
                    "function answer(): integer return base.answer() + 1 end\n",
                [top] = 'local middle = import "' .. middle .. '"\n' ..
                    "function answer(): integer return middle.answer() + 1 end\n",
                [direct] = 'local middle = import "' .. middle .. '.titan"\n' ..
                    "function answer(): integer return middle.answer() + 2 end\n",
            }, {
                [middle] = { { name = base } },
                [top] = { { name = middle } },
                [direct] = { { name = middle, source_required = true } },
            })
            for _, root_name in ipairs({ top, direct }) do
                local loaded, _, diagnostics = loader(root_name)
                assert.is_true(loaded)
                assert.equal(0, #diagnostics)
            end
            local plan = driver.resolution_plan(context)
            assert.same({ base, middle, direct, top }, plan.order)
            publish_planned(context, plan, base)
            publish_planned(context, plan, middle)

            local function diverged(name, change)
                local descriptor = driver.plan_descriptor(plan, name)
                change(descriptor.modules)
                local result, compile_error = worker_compile(context, descriptor, name)
                assert.is_nil(result)
                return compile_error
            end
            assert.matches("build plan divergence: module '" .. middle ..
                "' is not in the coordinator's plan",
                diverged(top, function(modules) modules[middle] = nil end), 1, true)
            assert.matches("build plan divergence: module '" .. middle .. "' has no accepted object",
                diverged(top, function(modules) modules[middle].object = nil end), 1, true)
            assert.matches("cannot read planned object for module '" .. middle .. "'",
                diverged(top, function(modules)
                    modules[middle].object = source .. "/missing.o"
                end), 1, true)
            write_file(source .. "/not-an-object.o", "not an object")
            assert.matches("cannot decode planned object for module '" .. middle .. "'",
                diverged(top, function(modules)
                    modules[middle].object = source .. "/not-an-object.o"
                end), 1, true)
            assert.matches("build plan divergence: module '" .. middle ..
                "' has unsupported planned kind 'archive'",
                diverged(top, function(modules)
                    modules[middle] = { kind = "archive", linked = true }
                end), 1, true)
            assert.matches("build plan divergence: source-imported module '" .. middle ..
                "' is planned as a dynamic provider",
                diverged(direct, function(modules)
                    modules[middle] = { kind = "dynamic", linked = false }
                end), 1, true)
            -- A restored dependency's own recorded imports also come from the plan.
            assert.matches("build plan divergence: module '" .. base ..
                "' is not in the coordinator's plan",
                diverged(top, function(modules) modules[base] = nil end), 1, true)
            assert.matches("build plan divergence: module '" .. middle ..
                "' is not linked in the plan but not in the worker's selection",
                diverged(top, function(modules) modules[middle].linked = false end), 1, true)

            local valid = driver.plan_descriptor(plan, top)
            local result, compile_error = worker_compile(context, {
                protocol = valid.protocol, modname = middle, modules = valid.modules,
            }, top)
            assert.is_nil(result)
            assert.equal("invalid build plan for module '" .. top .. "'", compile_error)
            result = assert(worker_compile(context, valid, top))
            assert.equal(top, result.modname)

            -- The coordinator restores only complete records whose imports it selected.
            local accepted = plan.accepted(middle)
            local metadata = {}
            for key, value in pairs(accepted.record.object_metadata) do metadata[key] = value end
            metadata.imports = { { name = "planned_chain_unselected" } }
            local missing, code, detail = driver.restore_source_object(context, middle,
                plan.modules[middle].source, setmetatable({ object_metadata = metadata },
                    { __index = accepted.record }))
            assert.is_nil(missing)
            assert.equal("dependency-unavailable", code)
            assert.equal("planned_chain_unselected", detail)
            missing, code, detail = driver.restore_source_object(context, middle,
                plan.modules[middle].source, { object_metadata = {} })
            assert.is_nil(missing)
            assert.equal("record-unreadable", code)
            assert.equal("record has no object metadata", detail)
            context.probe_verbose = true
            local entry, hit = capture_stderr(function()
                return assert(driver.restore_source_object(context, base,
                    plan.modules[base].source, plan.accepted(base)))
            end)
            context.probe_verbose = nil
            assert.equal("Titan object hit " .. base .. ": " .. entry.compiled .. "\n", hit)
        end)

        it("compiles planned split parts and retires their published inventory", function()
            local name = "planned_split_parts"
            local functions = {}
            for index = 1, 8 do
                functions[index] = ("function value%d(): integer return %d end\n"):format(index, index)
            end
            local context, loader = planning_loader({ [name] = table.concat(functions) }, {})
            assert.is_true((loader(name)))
            local plan = driver.resolution_plan(context)
            local stem = source .. "/" .. name
            local _, result = publish_planned(context, plan, name, {
                jobs = 2,
                configure = function(configuration)
                    configuration.policy.c_parts = 4
                    configuration.policy.split_threshold = 1
                end,
            })
            assert.is_true(#result.objects > 1)
            local wrote_private_header = false
            for _, filename in ipairs(result.written) do
                if paths.to_slash(filename) == paths.to_slash(paths.normalize(stem .. ".priv.h")) then
                    wrote_private_header = true
                end
            end
            assert.is_true(wrote_private_header)
            for _, object in ipairs(result.objects) do
                assert.equal("file", lfs.attributes(object, "mode"), object)
            end
            write_file(stem .. ".part1.gcda", "stale part counters")
            assert(driver.invalidate_source_object(context, name, plan.modules[name].source))
            for _, object in ipairs(result.objects) do
                assert.is_nil(lfs.attributes(object), object)
            end
            for index = 1, #result.objects - 1 do
                assert.is_nil(lfs.attributes(stem .. ".part" .. index .. ".c"))
            end
            assert.is_nil(lfs.attributes(stem .. ".part1.gcda"))
            assert.equal("file", lfs.attributes(stem .. ".c", "mode"))
        end)

        it("refuses to invalidate a directory or an object it cannot remove", function()
            local name = "planned_invalidation"
            local context, loader = planning_loader({
                [name] = "function answer(): integer return 42 end\n",
            }, {})
            assert.is_true((loader(name)))
            local plan = driver.resolution_plan(context)
            local planned = plan.modules[name].source
            local primary = source .. "/" .. name .. ".o"
            assert(lfs.mkdir(primary))
            local ok, err = driver.invalidate_source_object(context, name, planned)
            assert.is_nil(ok)
            assert.equal("object output '" .. primary .. "' for module '" .. name ..
                "' is a directory", err)
            assert(lfs.rmdir(primary))
            publish_planned(context, plan, name)
            local unlink = context.io.unlink
            function context.io:unlink() return nil, "object is busy" end
            ok, err = driver.invalidate_source_object(context, name, planned)
            context.io.unlink = unlink
            assert.is_nil(ok)
            assert.equal("cannot invalidate object for module '" .. name ..
                "': object is busy", err)
            assert.equal("file", lfs.attributes(primary, "mode"))
        end)

        it("removes a planned module's staged objects when its native compile fails", function()
            local name = "planned_native_failure"
            local context, loader = planning_loader({
                [name] = "function answer(): integer return 42 end\n",
            }, {})
            assert.is_true((loader(name)))
            local plan = driver.resolution_plan(context)
            local result, compile_error = worker_compile(context,
                driver.plan_descriptor(plan, name), name, {
                    configure = function(configuration)
                        local flags = configuration.driver.extra_cflags
                        flags[#flags + 1] = "-include"
                        flags[#flags + 1] = source .. "/missing-forced-header.h"
                    end,
                })
            assert.is_nil(result)
            assert.is_string(compile_error)
            for entry in lfs.dir(source) do
                if entry:find(name, 1, true) then
                    assert.is_nil(entry:match("%.o$") or entry:match("%.o%."), entry)
                end
            end
        end)

        it("discards malformed or unpublishable worker results without an object", function()
            local name = "planned_publication_failures"
            local context, loader = planning_loader({
                [name] = "function answer(): integer return 42 end\n",
            }, {})
            assert.is_true((loader(name)))
            local plan = driver.resolution_plan(context)
            local descriptor = driver.plan_descriptor(plan, name)
            local stem = source .. "/" .. name
            local function staged()
                return assert(worker_compile(context, descriptor, name))
            end
            local function rejected(result, expected)
                local published, err = driver.publish_staged_module(context, result)
                assert.is_nil(published)
                assert.matches(expected, err, 1, true)
                for _, item in ipairs(result.staged or {}) do
                    assert.is_nil(lfs.attributes(item.from), item.from)
                end
            end

            write_file(stem .. ".orphan.tmp", "part bytes")
            rejected({ modname = name, staged = {
                { role = "part", from = stem .. ".orphan.tmp", to = stem .. ".part1.o" },
            } }, "worker result for module '" .. name .. "' has no primary object")
            rejected({ modname = name, staged = {
                { role = "primary", from = stem .. ".missing.tmp", to = stem .. ".o" },
            } }, "cannot read staged object for module '" .. name .. "'")
            write_file(stem .. ".garbage.tmp", "not an object")
            rejected({ modname = name, staged = {
                { role = "primary", from = stem .. ".garbage.tmp", to = stem .. ".o" },
            } }, "cannot decode staged object for module '" .. name .. "'")

            local result = staged()
            result.staged[#result.staged + 1] = {
                role = "part", from = stem .. ".vanished.tmp", to = stem .. ".part9.o",
            }
            rejected(result, "cannot publish object part '" .. stem .. ".part9.o'")
            assert.is_nil(lfs.attributes(stem .. ".o"))

            result = staged()
            local rename = context.io.rename
            function context.io:rename(from, to)
                if from == result.staged[1].from then return nil, "rename denied" end
                return rename(self, from, to)
            end
            rejected(result, "cannot publish object '" .. stem .. ".o': rename denied")
            context.io.rename = rename
            assert.is_nil(lfs.attributes(stem .. ".o"))

            -- A committed object is replaced, unless its removal is refused.
            local published = assert(driver.publish_staged_module(context, staged()))
            result = staged()
            local unlink = context.io.unlink
            function context.io:unlink(filename)
                if filename == published.object then return nil, "unlink denied" end
                return unlink(self, filename)
            end
            rejected(result, "cannot replace object for module '" .. name .. "': unlink denied")
            context.io.unlink = unlink
            assert.equal("file", lfs.attributes(published.object, "mode"))
            assert(driver.publish_staged_module(context, staged()))

            result = staged()
            result.source_snapshot = nil
            rejected(result, "inputs of module '" .. name .. "' changed during the build: " ..
                "invalid uncertified worker input snapshot")

            result = staged()
            assert(os.remove(stem .. ".titan"))
            rejected(result, "cannot resolve module '" .. name .. "' for publication: ")
        end)

        it("rejects a certified worker object whose source changed during the build", function()
            local name = "planned_certified_edit"
            local contents = "function answer(): integer return 42 end\n"
            local context, loader = planning_loader({ [name] = contents }, {}, true)
            assert.is_true((loader(name)))
            local plan = driver.resolution_plan(context)
            assert(driver.invalidate_source_object(context, name, plan.modules[name].source))
            local result = assert(worker_compile(context,
                driver.plan_descriptor(plan, name), name))
            assert.is_nil(result.source_snapshot)
            write_file(source .. "/" .. name .. ".titan", contents .. "\n")
            local published, err = driver.publish_staged_module(context, result)
            assert.is_nil(published)
            assert.matches("inputs of module '" .. name .. "' changed during the build: ",
                err, 1, true)
            assert.is_nil(lfs.attributes(result.object))
        end)

        it("discards staged objects when a target variant appears during publication", function()
            for _, certified in ipairs({ false, true }) do
                local name = "planned_target_override_" .. tostring(certified)
                local contents = "function answer(): integer return 42 end\n"
                local context, loader = planning_loader({ [name] = contents }, {}, certified)
                assert.is_true((loader(name)))
                local configuration = assert(driver.worker_configuration(context))
                assert.equal(driver.context_target(context), configuration.resolver.target)
                local plan = driver.resolution_plan(context)
                assert(driver.invalidate_source_object(context, name, plan.modules[name].source))
                local result = assert(worker_compile(context,
                    driver.plan_descriptor(plan, name), name))
                write_file(source .. "/" .. name .. "." ..
                    assert(driver.context_target(context)) .. ".titan", contents)
                local published, err = driver.publish_staged_module(context, result)
                assert.is_nil(published)
                assert.matches("inputs of module '" .. name .. "' changed during the build",
                    err, 1, true)
                assert.is_nil(lfs.attributes(result.object))
                for _, item in ipairs(result.staged) do
                    assert.is_nil(lfs.attributes(item.from), item.from)
                end
            end
        end)

        it("loads exactly the binary providers the coordinator planned in a worker", function()
            local provider = "planned_binary_provider"
            local consumer = "planned_binary_consumer"
            local provider_file = provider_path(binary .. "/" .. provider .. ".so")
            cache_dynamic_provider(provider_file,
                { [provider] = result_module(provider, types.Integer()) })
            local context, loader = planning_loader({
                [consumer] = 'local provider = import "' .. provider .. '"\n' ..
                    "function answer(): integer return provider.answer() + 1 end\n",
            }, { [consumer] = { { name = provider } } })
            local loaded, _, diagnostics = loader(consumer)
            assert.is_true(loaded)
            assert.equal(0, #diagnostics)
            local plan = driver.resolution_plan(context)
            assert.equal("dynamic", plan.modules[provider].kind)
            local function compiled(change)
                local descriptor = driver.plan_descriptor(plan, consumer)
                if change then change(descriptor.modules[provider]) end
                return worker_compile(context, descriptor, consumer)
            end
            local result = assert(compiled())
            assert.equal(consumer, result.modname)
            local _, divergence = compiled(function(item)
                item.provider_file = "elsewhere/" .. provider .. ".so"
            end)
            assert.matches("build plan divergence: module '" .. provider ..
                "' provider file is '", divergence, 1, true)
            assert.matches("', planned 'elsewhere/" .. provider .. ".so'", divergence, 1, true)

            local other = provider_path(binary .. "/planned_binary_other.so")
            cache_dynamic_provider(other,
                { planned_binary_other = result_module("planned_binary_other", types.Integer()) })
            -- Like dlsym, the other provider has no symbols of the planned module.
            local load = titan._loadlib
            titan._loadlib = function(found, symbol)
                local ok, value = pcall(load, found, symbol)
                if ok then return value end
                return nil, "undefined symbol: " .. symbol, "init"
            end
            local _, unclaimed = compiled(function(item) item.file = other end)
            assert.matches("planned provider '" .. other .. "' no longer claims module '" ..
                provider .. "'", unclaimed, 1, true)

            if platform.windows then return end
            local archive = binary .. "/libplanned_binary_other.a"
            cache_static_provider(context, archive,
                { planned_binary_other = result_module("planned_binary_other", types.Integer()) })
            local _, absent = compiled(function(item)
                item.kind, item.archive, item.relative = "static", archive, "libplanned_binary_other.a"
                item.file, item.provider_file = nil, nil
            end)
            assert.matches("planned static provider '" .. archive .. "' contains no module '" ..
                provider .. "'", absent, 1, true)
        end)

        it("rejects resolver, loader and worker entry points without their required inputs", function()
            assert.matches("frontend must be a nonempty path",
                raised(function() driver.new_resolver_context({ frontend = "" }) end), 1, true)
            assert.matches("configuration certification requires a resolver context",
                raised(function() driver.incremental_configuration({}) end), 1, true)
            assert.matches("plan_mode requires an imports_for function",
                raised(function()
                    driver.defaultloader({}, { context = tracked_context(), plan_mode = true })
                end), 1, true)
            assert.matches("worker_plan must be a build plan descriptor",
                raised(function()
                    driver.defaultloader({}, { context = tracked_context(), worker_plan = {} })
                end), 1, true)
            local worker, worker_error = driver.new_worker_context(
                { protocol = version.BUILD_WORKER_PROTOCOL }, compiler_io.new_sync())
            assert.is_nil(worker)
            assert.equal("incompatible build worker configuration", worker_error)

            incremental.toolchain_identity = uncertain_toolchain
            local configuration = assert(driver.worker_configuration(tracked_context()))
            local support = package.loaded.titan
            package.loaded.titan = { _sha256_binary = support._sha256_binary }
            worker, worker_error = driver.new_worker_context(configuration, compiler_io.new_sync())
            package.loaded.titan = support
            assert.is_nil(worker)
            assert.equal("the installed Titan native support library is missing or stale " ..
                "(it lacks _sha256_binary or _sha256_stream)", worker_error)

            incremental.configuration = function()
                return nil, "compiler inventory is unreadable"
            end
            local failed, failure = driver.worker_configuration(tracked_context())
            assert.is_nil(failed)
            assert.equal("cannot certify compiler configuration: compiler inventory is unreadable",
                failure)
            local cancellation = {}
            incremental.configuration = function() return nil, cancellation end
            local ok, raised_value = pcall(driver.worker_configuration, tracked_context())
            assert.is_false(ok)
            assert.equal(cancellation, raised_value)
        end)

        it("reuses the coordinator's archive scan in a worker only under the same archive observation", function()
            if platform.windows then
                pending("Windows Titan archive-provider consumers are not implemented")
                return
            end
            local process = require "titan-compiler.process"
            local parser = require "titan-compiler.parser"
            local checker = require "titan-compiler.checker"
            local producer = "incremental_driver_archive_producer"
            local consumer = "incremental_driver_archive_consumer"
            local producer_file = source .. "/" .. producer .. ".titan"
            local suffix = "/" .. producer .. ".a"
            -- Publish a real producer archive, then hide its source so the
            -- consumer selects the archive.
            local function publish_producer(contents)
                write_file(producer_file, contents)
                local imported, registry = driver.imported, types.registry
                driver.imported, types.registry = {}, {}
                local ast, parse_error = parser.parse(producer_file, contents)
                assert.truthy(ast, parse_error)
                local _, check_errors = checker.check(
                    producer, ast, contents, producer_file)
                assert.equal(0, #check_errors, table.concat(check_errors, "\n"))
                local compiled, compile_error, object = driver.compile(
                    producer, ast, producer_file, {}, false)
                driver.imported, types.registry = imported, registry
                assert.is_true(compiled, compile_error)
                local target = assert(driver.derive_target_fingerprint(object, producer))
                assert(driver.build_static_archive(
                    binary .. suffix, { object }, {}, target, false))
                assert(os.remove(producer_file))
            end
            publish_producer("function answer(): integer return 41 end\n")
            write_file(source .. "/" .. consumer .. ".titan",
                'local producer = import "' .. producer .. '"\n' ..
                "function answer(): integer return producer.answer() + 1 end\n")
            incremental.toolchain_identity = uncertain_toolchain
            incremental.make_certificate = function()
                error("uncertified worker must not publish a certificate", 0)
            end
            local context = driver.new_resolver_context({ prefer_static = true })
            contexts[#contexts + 1] = context
            local loader = fresh_loader({
                context = context, incremental = true, plan_mode = true,
                imports_for = function(name)
                    return name == consumer and { { name = producer } } or {}
                end,
            })
            local loaded, _, diagnostics = loader(consumer)
            assert.is_true(loaded)
            assert.equal(0, #diagnostics)
            local plan = driver.resolution_plan(context)
            assert.equal("static", plan.modules[producer].kind)
            local archive = plan.modules[producer].archive
            local planned = assert(plan.archives[archive])
            -- Closed data: canonical metadata strings plus the scan's precise
            -- observation, never archive members or decoded objects.
            assert.equal("ns", planned.observation.precision)
            local planned_names = {}
            for name, item in pairs(planned.modules) do
                planned_names[#planned_names + 1] = name
                local fields = {}
                for field, value in pairs(item) do
                    assert.is_string(value)
                    fields[#fields + 1] = field
                end
                table.sort(fields)
                assert.same({ "origin", "payload" }, fields)
            end
            assert.same({ producer }, planned_names)
            local encoded = assert(process.encode_record(
                driver.plan_descriptor(plan, consumer)))
            local configuration = assert(driver.worker_configuration(context))
            local generated_file = source .. "/" .. consumer .. ".c"

            -- One worker over the transported descriptor, counting archive reads.
            local function stage(mutate)
                local descriptor = assert(process.decode_record(encoded))
                if mutate then mutate(descriptor) end
                local reads = 0
                local strategy = compiler_io.new_sync()
                local read_file = strategy.read_file
                function strategy:read_file(path, ...)
                    if path:sub(-#suffix) == suffix then reads = reads + 1 end
                    return read_file(self, path, ...)
                end
                local imported, registry = driver.imported, types.registry
                driver.imported, types.registry = {}, {}
                local worker = assert(driver.new_worker_context(configuration, strategy))
                contexts[#contexts + 1] = worker
                local result, compile_error = driver.compile_planned_module(
                    worker, consumer, { plan = descriptor })
                local selected = driver.imported[producer]
                driver.imported, types.registry = imported, registry
                for _, item in ipairs(result and result.staged or {}) do
                    os.remove(item.from)
                end
                return result, compile_error, reads, selected
            end
            local function staged_ok(mutate)
                local result, compile_error, reads, selected = stage(mutate)
                assert.truthy(result, compile_error)
                return reads, assert(util.get_file_contents(generated_file, "rb")),
                    selected
            end

            local reads, generated, selected = staged_ok()
            assert.equal(0, reads)
            assert.equal("metadata", selected.static_provider.kind)
            assert.is_nil(selected.type.members.extra)
            local fallbacks = {
                { "absent", function(descriptor) descriptor.archives = nil end },
                { "other path", function(descriptor)
                    descriptor.archives = {
                        [archive .. ".other"] = descriptor.archives[archive],
                    }
                end },
                { "coarse", function(descriptor)
                    descriptor.archives[archive].observation.precision = "coarse"
                end },
                { "rejected", function(descriptor)
                    local item = descriptor.archives[archive].modules[producer]
                    item.payload = item.payload .. "\n"
                end },
            }
            for _, case in ipairs(fallbacks) do
                local fallback_reads, fallback_generated, fallback_selected =
                    staged_ok(case[2])
                assert.equal(1, fallback_reads, case[1])
                assert.equal(generated, fallback_generated, case[1])
                assert.equal("archive", fallback_selected.static_provider.kind, case[1])
            end

            -- An archive changed after planning is rescanned, so the worker
            -- never selects the stale planned interface.
            publish_producer("function answer(): integer return 41 end\n" ..
                "function extra(): integer return 7 end\n")
            local changed_reads, _, changed = staged_ok()
            assert.equal(1, changed_reads)
            assert.equal("archive", changed.static_provider.kind)
            assert.truthy(changed.type.members.extra)

            -- Without an observable archive the worker fails closed.
            assert(os.remove(binary .. suffix))
            local missing, missing_error = stage()
            assert.is_nil(missing)
            assert.matches("cannot inspect static provider", missing_error, 1, true)
        end)

        it("skips parsing, checking, generation and native compilation on an object hit", function()
            local name = "incremental_driver_warm"
            write_file(source .. "/" .. name .. ".titan",
                "local function hidden(): integer return 42 end\n"
                .. "function answer(): integer return hidden() end\n")
            local entry = load_ok(fresh_loader(), name)
            local object = write_source_object(entry)
            local before = lfs.attributes(object, "modification")
            local parser = require "titan-compiler.parser"
            local checker = require "titan-compiler.checker"
            local originals = { parse = parser.parse, check = checker.check,
                generate = coder.generate, compile = driver.compile_module }
            local counts = { parse = 0, check = 0, generate = 0, compile = 0 }
            parser.parse = function(...)
                counts.parse = counts.parse + 1
                return originals.parse(...)
            end
            checker.check = function(...)
                counts.check = counts.check + 1
                return originals.check(...)
            end
            coder.generate = function(...)
                counts.generate = counts.generate + 1
                return originals.generate(...)
            end
            driver.compile_module = function(...)
                counts.compile = counts.compile + 1
                return originals.compile(...)
            end
            local ok, failure = xpcall(function()
                local loader, dependencies = fresh_loader({ incremental = true })
                local restored = load_ok(loader, name)
                assert.equal(object, restored.compiled)
                assert.is_nil(restored.ast)
                assert.is_true(dependencies[name])
                assert.is_nil(restored._analysis_manifest)
                assert.is_table(restored.type.source_members.hidden)
                local results = driver.compile_modules({ {
                    modname = name, mod = restored, static_deps = dependencies,
                } }, 1, false)
                assert.is_true(results[1].ok)
                assert.equal(object, results[1].libname)
            end, debug.traceback)
            parser.parse, checker.check = originals.parse, originals.check
            coder.generate, driver.compile_module = originals.generate, originals.compile
            assert.is_true(ok, failure)
            assert.same({ parse = 0, check = 0, generate = 0, compile = 0 }, counts)
            assert.equal(before, lfs.attributes(object, "modification"))
        end)

        it("ignores object metadata by default and classifies missing or unusable records", function()
            local name = "incremental_driver_fallback"
            local filename = source .. "/" .. name .. ".titan"
            local initial_source = "function answer(): integer return 42 end\n"
            write_file(filename, initial_source)
            local entry = load_ok(fresh_loader(), name)
            local uncertified_payload = assert(objectmetadata.encode(entry, {
                has_main = false, imports = {}, native_references = {}, external_symbols = {},
                layouts = empty_layouts(entry.type.name),
                parts_version = 1,
                parts = {
                    { index = 0, c_suffix = ".c", object_suffix = ".o" },
                },
            }))
            for _, scenario in ipairs({
                { label = "absent object", miss = "no-object" },
                { label = "absent source section", payload = false, miss = "record-unreadable" },
                { label = "Lua syntax error", payload = "return {", miss = "record-unreadable" },
                { label = "Lua execution error", payload = "return missing.field", miss = "record-unreadable" },
                { label = "ABI mismatch", payload = "return {abi='unsupported',schema='1',digest='sha256'}", miss = "record-schema" },
                { label = "old envelope without schema", payload = "return {abi='2',module='" .. name .. "',entry={}}", miss = "record-schema" },
                { label = "wrong schema version", payload = "return {abi='2',schema='0',digest='sha256',module='" .. name .. "',entry={}}", miss = "record-schema" },
                { label = "wrong digest algorithm", payload = "return {abi='2',schema='1',digest='blake3',module='" .. name .. "',entry={}}", miss = "record-schema" },
                { label = "missing certificate", payload = uncertified_payload, miss = "record-schema" },
                { label = "incomplete certificate", mutator = function(native) native.certificate.configuration = nil end, miss = "record-schema" },
                { label = "changed source with preserved timestamp", mutator = function() end, edit_source = "function answer(): integer return 43 end\n", miss = "source-content" },
                { label = "default ignores current object", mutator = function() end, default = true },
            }) do
                write_file(filename, initial_source)
                entry = load_ok(fresh_loader(), name)
                local object = filename:gsub("[.]titan$", ".o")
                if scenario.payload ~= nil or scenario.mutator ~= nil then
                    write_source_object(entry, scenario.payload, scenario.mutator)
                else
                    os.remove(object)
                end
                if scenario.edit_source then
                    local modified = assert(lfs.attributes(filename, "modification"))
                    write_file(filename, scenario.edit_source)
                    assert(lfs.touch(filename, modified, modified))
                end
                local restored, stderr = capture_stderr(function()
                    local context = driver.new_resolver_context({ verbose = true })
                    local loader = fresh_loader({
                        context = context,
                        incremental = not scenario.default,
                    })
                    local loaded = load_ok(loader, name)
                    assert.is_true(driver.close_resolver_context(context))
                    return loaded
                end)
                assert.is_table(restored.ast, scenario.label)
                assert.is_nil(restored.compiled, scenario.label)
                if scenario.miss then
                    assert.matches(
                        "Titan object miss " .. name .. ": " .. scenario.miss,
                        stderr, 1, true)
                else
                    assert.equal("", stderr, scenario.label)
                end
            end
        end)

        it("invalidates a stale object after a failed replacement and permits a successful retry", function()
            local name = "incremental_driver_failed_replacement"
            local filename = source .. "/" .. name .. ".titan"
            write_file(filename, "function answer(): integer return 42 end\n")
            local initial_context = driver.new_resolver_context()
            local loader, dependencies = fresh_loader({ context = initial_context })
            local entry = load_ok(loader, name)
            assert(driver.prepare_foreign_headers({ name }, driver.imported, false, false))
            local ok, err, object = driver.compile_module(
                name, entry, dependencies, false, { context = initial_context })
            assert.is_true(driver.close_resolver_context(initial_context))
            assert.truthy(ok, err)
            local function read_object()
                local file = assert(io.open(object, "rb"))
                local bytes = assert(file:read("a"))
                assert(file:close())
                return bytes
            end
            local previous_bytes = read_object()
            local timestamp = os.time() - 20
            assert(lfs.touch(object, timestamp, timestamp))

            write_file(filename, "function answer(): integer return 43 end\n")
            assert(lfs.touch(filename, timestamp + 1, timestamp + 1))
            loader, dependencies = fresh_loader({ incremental = true })
            entry = load_ok(loader, name)
            assert.is_table(entry.ast)
            assert.is_nil(entry.compiled)
            assert(driver.prepare_foreign_headers({ name }, driver.imported, false, false))
            local generate = coder.generate
            coder.generate = function(...)
                local generated = generate(...)
                generated.parts[1].code = generated.parts[1].code ..
                    "\n#error TITAN_INTENTIONAL_REPLACEMENT_FAILURE\n"
                return generated
            end
            local called, failure = xpcall(function()
                ok, err = driver.compile_module(name, entry, dependencies, false)
                assert.is_nil(ok)
                assert.is_string(err)
                assert.is_nil(entry.compiled)
                assert.is_nil(lfs.attributes(object))
            end, debug.traceback)
            coder.generate = generate
            assert.truthy(called, failure)

            ok, err = driver.compile_module(name, entry, dependencies, false)
            assert.truthy(ok, err)
            assert.equal(object, entry.compiled)
            assert.not_equal(previous_bytes, read_object())
            assert.is_true(lfs.attributes(object, "modification") > timestamp)
        end)

        it("certifies folder contributor membership and content independently of timestamps", function()
            local name = "incremental_driver_folder"
            local directory = source .. "/" .. name
            assert(lfs.mkdir(directory))
            local filename = directory .. "/" .. name .. ".titan"
            local contributor = directory .. "/part.titan"
            write_file(filename, "function answer(): integer return hidden() end\n")
            write_file(contributor, "local function hidden(): integer return 42 end\n")
            local entry = load_ok(fresh_loader(), name)
            local object = write_source_object(entry)
            local timestamp = os.time() - 10
            for _, path in ipairs({ filename, contributor, object }) do
                assert(lfs.touch(path, timestamp, timestamp))
            end
            assert.equal(object, load_ok(fresh_loader({ incremental = true }), name).compiled)
            assert(lfs.touch(contributor, timestamp + 1, timestamp + 1))
            assert.equal(object, load_ok(fresh_loader({ incremental = true }), name).compiled)
            write_file(contributor, "local function hidden(): integer return 43 end\n")
            assert(lfs.touch(contributor, timestamp, timestamp))
            assert.is_table(load_ok(fresh_loader({ incremental = true }), name).ast)
        end)

        it("restores missing native headers from cached inline bodies and preserves complete companions", function()
            local name = "incremental_driver_headers"
            local filename = source .. "/" .. name .. ".titan"
            write_file(filename, [[
                local foreign function increment(value: int): int
                    return value + 1
                end
            ]])
            local entry = load_ok(fresh_loader(), name)
            assert(driver.prepare_foreign_headers({ name }, driver.imported, false, false))
            local ffi_path = driver.ffi_header_filename(filename)
            local foreign_path = driver.foreign_header_filename(filename)
            local ffi_contents = assert(util.get_file_contents(ffi_path))
            local foreign_contents = assert(util.get_file_contents(foreign_path))
            assert.matches("static inline", foreign_contents, 1, true)
            local object = write_source_object(entry)
            local object_mtime = lfs.attributes(object, "modification")
            assert(os.remove(ffi_path))
            assert(os.remove(foreign_path))

            local restored = load_ok(fresh_loader({ incremental = true }), name)
            assert.is_nil(restored.ast)
            assert(driver.prepare_foreign_headers({ name }, driver.imported, false, false))
            assert.equal(ffi_contents, assert(util.get_file_contents(ffi_path)))
            assert.equal(foreign_contents, assert(util.get_file_contents(foreign_path)))
            local preserved_mtime = os.time() - 20
            assert(lfs.touch(ffi_path, preserved_mtime, preserved_mtime))
            assert(lfs.touch(foreign_path, preserved_mtime, preserved_mtime))
            assert(driver.prepare_foreign_headers({ name }, driver.imported, false, false))
            assert.equal(preserved_mtime, lfs.attributes(ffi_path, "modification"))
            assert.equal(preserved_mtime, lfs.attributes(foreign_path, "modification"))
            assert.equal(object_mtime, lfs.attributes(object, "modification"))
        end)

        it("includes cached source dependencies outside the requested native header plan", function()
            local producer = "incremental_driver_partial"
            local directory = source .. "/" .. producer
            assert(lfs.mkdir(directory))
            local filename = directory .. "/" .. producer .. ".titan"
            write_file(filename, [[
                foreign function increment(value: int): int
                    return value + 1
                end
            ]])
            local entry = load_ok(fresh_loader(), producer)
            assert(driver.prepare_foreign_headers({ producer }, driver.imported, false, false))
            local ffi_path = driver.ffi_header_filename(filename)
            local foreign_path = driver.foreign_header_filename(filename)
            local ffi_contents = assert(util.get_file_contents(ffi_path))
            local foreign_contents = assert(util.get_file_contents(foreign_path))
            write_source_object(entry)
            assert(os.remove(ffi_path))
            assert(os.remove(foreign_path))

            local consumer = "incremental_driver_partial_consumer"
            local consumer_filename = source .. "/" .. consumer .. ".titan"
            write_file(consumer_filename,
                "local provider = import '" .. producer .. ".titan'\n"
                .. "foreign function answer(value: int): int\n"
                .. "    return provider.increment(value)\nend\n")
            load_ok(fresh_loader({ incremental = true }), consumer)
            assert.is_nil(driver.imported[producer].ast)
            local plans = assert(driver.plan_foreign_headers({ consumer }, driver.imported))
            local planned = {}
            for _, plan in ipairs(plans) do planned[plan.modname] = true end
            assert.same({ [producer] = true, [consumer] = true }, planned)
            assert(driver.write_foreign_header_plans(plans, false, false))
            assert.equal(ffi_contents, assert(util.get_file_contents(ffi_path)))
            assert.equal(foreign_contents, assert(util.get_file_contents(foreign_path)))
            local consumer_header = assert(util.get_file_contents(
                driver.foreign_header_filename(consumer_filename)))
            assert.matches(foreign_path, consumer_header, 1, true)
        end)

        it("requires source presence and direct source capability despite a surviving object", function()
            local name = "incremental_driver_private"
            local filename = source .. "/" .. name .. ".titan"
            write_file(filename, "local function hidden(): integer return 42 end\n")
            local entry = load_ok(fresh_loader(), name)
            write_source_object(entry)
            local consumer = "incremental_driver_consumer"
            write_file(source .. "/" .. consumer .. ".titan",
                "local provider = import '" .. name .. "'\n"
                .. "function answer(): integer return provider.hidden() end\n")
            local loader = fresh_loader({ incremental = true })
            local ok, result, errors = loader(consumer)
            assert.is_true(ok, tostring(result))
            assert.is_true(#errors > 0)
            assert.is_string(driver.imported[name].compiled)

            write_file(source .. "/" .. consumer .. ".titan",
                "local provider = import '" .. name .. ".titan'\n"
                .. "function answer(): integer return provider.hidden() end\n")
            load_ok(fresh_loader({ incremental = true }), consumer)
            assert(os.remove(filename))
            loader = fresh_loader({ incremental = true, source_roots = { [name] = true } })
            ok = loader(name)
            assert.is_false(ok)
            loader = fresh_loader({ incremental = true })
            ok, result, errors = loader(consumer)
            assert.is_true(not ok or #errors > 0, tostring(result))
        end)

        it("preserves contextual native constraints on object hits and hashes each warm input once", function()
            local owner = "incremental_driver_t12_owner"
            local facade = "incremental_driver_t12_facade"
            local first = "incremental_driver_t12_first"
            local second = "incremental_driver_t12_second"
            local app = "incremental_driver_t12_app"
            local shared_header = source .. "/t12_shared.h"
            write_file(shared_header, "#define T12_SHARED_VALUE 21\n")
            local first_file = source .. "/" .. first .. ".titan"
            local second_file = source .. "/" .. second .. ".titan"
            local app_file = source .. "/" .. app .. ".titan"
            write_file(first_file, [[
                foreign import "t12_shared.h"
                function value(): integer return ffi.T12_SHARED_VALUE end
            ]])
            write_file(second_file, [[
                foreign import "t12_shared.h"
                function value(): integer return ffi.T12_SHARED_VALUE end
            ]])
            write_file(app_file,
                "local first = import '" .. first .. ".titan'\n"
                .. "local second = import '" .. second .. ".titan'\n"
                .. "local facade = import '" .. facade .. "'\n"
                .. "function answer(): integer\n"
                .. "    local _item = facade.make()\n"
                .. "    return first.value() + second.value()\n"
                .. "end\n")

            local item_record = types.Record(owner .. ".Item", {}, {}, {}, 1)
            local owner_type = types.Module(owner, {
                types.ModuleMember(owner, "Item", item_record, nil),
            })
            assert.is_true(driver.validate_module_interface(owner_type, owner))
            owner_type.file = owner .. ".so"
            local facade_type = types.Module(facade, {
                types.ModuleMember(facade, "make",
                    types.Function({}, { types.Nominal(owner .. ".Item") },
                        false, nil, nil), {}),
            })
            assert.is_true(driver.validate_module_interface(facade_type, facade))
            facade_type.file = facade .. ".so"
            local archive_path = binary .. "/" .. facade .. ".a"
            local roots = { [first] = true, [second] = true, [app] = true }

            local fresh_ctx = driver.new_resolver_context({ prefer_static = true })
            cache_static_provider(fresh_ctx, archive_path, {
                [facade] = facade_type,
                [owner] = owner_type,
            })
            local fresh_load, fresh_deps = fresh_loader({
                context = fresh_ctx,
                prefer_static = true,
                source_first = false,
                source_roots = roots,
            })
            load_ok(fresh_load, app)
            local finalized, finalize_errors =
                driver.finalize_resolver_context(fresh_ctx)
            assert.truthy(finalized,
                finalize_errors and table.concat(finalize_errors, "\n"))
            assert.is_table(fresh_ctx.native_constraints[owner])
            for _, modname in ipairs({ first, second, app }) do
                write_source_object(driver.imported[modname], nil, nil, {
                    context = fresh_ctx,
                    static_deps = fresh_deps,
                })
            end
            local expected_constraints = fresh_ctx.native_constraints
            local expected_bindings = fresh_ctx.native_bindings
            assert.is_true(driver.close_resolver_context(fresh_ctx))

            local hit_ctx = driver.new_resolver_context({ prefer_static = true })
            cache_static_provider(hit_ctx, archive_path, {
                [facade] = facade_type,
                [owner] = owner_type,
            })
            local hit_load = fresh_loader({
                context = hit_ctx,
                incremental = true,
                prefer_static = true,
                source_first = false,
                source_roots = roots,
            })
            load_ok(hit_load, app)
            for _, modname in ipairs({ first, second, app }) do
                assert.is_nil(driver.imported[modname].ast, modname)
                assert.is_string(driver.imported[modname].compiled, modname)
            end
            finalized, finalize_errors =
                driver.finalize_resolver_context(hit_ctx)
            assert.truthy(finalized,
                finalize_errors and table.concat(finalize_errors, "\n"))
            assert.same(expected_constraints, hit_ctx.native_constraints)
            assert.same(expected_bindings, hit_ctx.native_bindings)

            local counters = incremental.counters(hit_ctx)
            assert.is_nil(counters.revalidation)
            for path_key, counts in pairs(counters.files) do
                assert.equal(1, counts.hashes, path_key)
                assert.is_true(counts.reads <= 1, path_key)
            end
            local shared_real = assert(hit_ctx.io:realpath(shared_header))
            local header_stats = require("c-parser.cpp").header_input_stats(hit_ctx.io)
            assert.is_true((counters.files[shared_real] and counters.files[shared_real].hashes or 0) <= 1)
            assert.equal(1, header_stats.metadata_reuses + header_stats.file_hashes)
            assert.is_true(header_stats.memo_reuses >= 1)
            assert.is_true(header_stats.file_reads <= 1)
            for _, source_path in ipairs({ first_file, second_file, app_file }) do
                local real = assert(hit_ctx.io:realpath(source_path))
                assert.equal(1, counters.files[real].hashes, source_path)
                assert.equal(1, counters.files[real].reads, source_path)
            end

            local first_real = assert(hit_ctx.io:realpath(first_file))
            local warm_hashes = counters.file_hashes
            local warm_reads = counters.file_reads
            local revalidated = incremental.revalidate_record(
                hit_ctx, first, {
                    kind = "flat",
                    main = first_file,
                    files = { first_file },
                }, driver.imported[first])
            assert.equal("hit", revalidated.status)
            assert.equal(warm_hashes, counters.file_hashes)
            assert.equal(warm_reads, counters.file_reads)
            assert.equal(1, counters.files[first_real].hashes)
            assert.is_table(counters.revalidation)
            assert.equal(1, counters.revalidation.passes)
            -- Revalidation re-observes the unchanged source instead of rereading it.
            assert.equal(0, counters.revalidation.files[first_real].hashes)
            assert.equal(0, counters.revalidation.files[first_real].reads)
            assert.equal(1, counters.revalidation.files[first_real].observation_reuses)
            local worker_cfg = assert(driver.worker_configuration(hit_ctx))
            local worker_ctx = assert(driver.new_worker_context(
                worker_cfg, compiler_io.new_sync()))
            assert.equal(warm_hashes, counters.file_hashes)
            assert.is_true(incremental.counters(worker_ctx).file_hashes > 0)
            assert.is_true(driver.close_resolver_context(worker_ctx))
            assert.is_true(driver.close_resolver_context(hit_ctx))
        end)
    end)

    it("validates a closed embedded-interface provider at context creation",
    function()
        local provider_file = root .. "/language-server"
        local function valid_provider()
            return embedded_provider(provider_file, {
                embedded_valid = types.Module("embedded_valid", {}),
            })
        end
        local function reject(candidate, expected)
            local ok, message = pcall(driver.new_resolver_context, {
                embedded_interface_provider = candidate,
            })
            assert.is_false(ok)
            assert.matches("invalid embedded_interface_provider", message,
                1, true)
            assert.matches(expected, message, 1, true)
        end

        reject("invalid", "must be a plain table")
        local candidate = valid_provider()
        candidate.unexpected = true
        reject(candidate, "contains unexpected field \"unexpected\"")
        candidate = valid_provider()
        candidate.provider_file = "relative/server"
        reject(candidate,
            "provider_file must be an absolute NUL-free pathname")
        candidate = valid_provider()
        candidate.provider_file = "/server\0hidden"
        reject(candidate,
            "provider_file must be an absolute NUL-free pathname")
        candidate = valid_provider()
        candidate.entries = setmetatable({}, {})
        reject(candidate, "entries must be a plain module-keyed table")

        candidate = valid_provider()
        candidate.entries["invalid module"] = {
            abi = driver.TITAN_ABI_VERSION,
            types = "Module('invalid module',{})",
        }
        reject(candidate, "invalid logical module name \"invalid module\"")
        candidate = valid_provider()
        candidate.entries.embedded_valid.unexpected = true
        reject(candidate,
            "entry for module 'embedded_valid' contains unexpected field")
        candidate = valid_provider()
        candidate.entries.embedded_valid.abi = 2
        reject(candidate, "ABI must be a string")
        candidate = valid_provider()
        candidate.entries.embedded_valid.abi = "different"
        reject(candidate, "ABI mismatch: expected " ..
            driver.TITAN_ABI_VERSION .. " but found different")
        candidate = valid_provider()
        candidate.entries.embedded_valid.types = true
        reject(candidate, "types must be a serialized module string")
        candidate = valid_provider()
        candidate.entries.embedded_valid.types = "Module('other',{})"
        reject(candidate, "has invalid types")

        candidate = embedded_provider(provider_file, {
            ["collision.name"] = types.Module("collision.name", {}),
            collision_name = types.Module("collision_name", {}),
        })
        reject(candidate, "duplicate native symbol prefix 'collision_name'")

        candidate = valid_provider()
        setmetatable(candidate.entries.embedded_valid, {})
        reject(candidate,
            "entry for module 'embedded_valid' must be a plain table")

        local original = valid_provider()
        local context = driver.new_resolver_context({
            embedded_interface_provider = original,
        })
        local copied = context.embedded_interface_provider
        assert.not_equal(original, copied)
        assert.not_equal(original.entries, copied.entries)
        assert.equal(provider_file, copied.provider_file)
        assert.same({ "embedded_valid" }, copied.key_order)
        assert.equal("embedded_valid", copied.entries.embedded_valid.type.name)
        assert.is_true(copied.analysis_only)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects embedded numeric metadata before publishing its profile",
    function()
        local name = "embedded.numeric_mismatch"
        local profile = native_target_profile()
        local wrong = types.clone_graph(profile.integers.int.type)
        wrong.bits = wrong.bits * 2
        local candidate = embedded_provider(root .. "/language-server", {
            [name] = result_module(name, wrong),
        }, profile)
        local ok, err = pcall(driver.new_resolver_context, {
            embedded_interface_provider = candidate,
        })
        assert.is_false(ok)
        assert.matches("disagrees with the selected target profile", err,
            1, true)
        assert.is_nil(driver.imported[name])
        assert.same({}, types.registry)

        -- A failed validation must not install a memoized success snapshot.
        candidate.entries[name].types = types.serialize(
            result_module(name, profile.integers.int.type))
        local context = driver.new_resolver_context({
            embedded_interface_provider = candidate,
        })
        assert.equal(profile.identity,
            assert(driver.get_target_profile(context)).identity)
        assert.is_true(driver.close_resolver_context(context))

        local malformed = embedded_provider(root .. "/language-server", {
            [name] = result_module(name, profile.integers.int.type),
        }, profile)
        malformed.target_profile.identity = "unrelated profile"
        ok, err = pcall(driver.new_resolver_context, {
            embedded_interface_provider = malformed,
        })
        assert.is_false(ok)
        assert.matches("target_profile", err, 1, true)
        assert.is_nil(driver.imported[name])
        assert.same({}, types.registry)
    end)

    it("isolates embedded numeric profiles across cached provider snapshots",
    function()
        local name = "embedded.numeric_snapshot"
        local profile = native_target_profile()
        local candidate = embedded_provider(root .. "/language-server", {
            [name] = numeric_embedded_module(name, profile),
        }, profile)
        local first = driver.new_resolver_context({
            embedded_interface_provider = candidate,
        })
        local first_profile = assert(driver.get_target_profile(first))
        local first_type = first.embedded_interface_provider.entries[name].type
        local first_numeric = first_type.members[2].type.rettypes[1]
        assert.equal(profile.identity,
            first_numeric._c_numeric_carriers.identity)

        candidate.target_profile.identity = "caller mutation"
        candidate.target_profile.integers.int.bits = 8
        first_profile.integers.int.type.bits = 16
        first_numeric._c_numeric.bits = 16
        first_numeric._c_numeric_carriers.lua_integer.bits = 16

        local second = driver.new_resolver_context({
            embedded_interface_provider = candidate,
        })
        local second_profile = assert(driver.get_target_profile(second))
        local second_type = second.embedded_interface_provider.entries[name].type
        local second_numeric = second_type.members[2].type.rettypes[1]
        assert.equal(profile.identity, second_profile.identity)
        assert.equal(profile.integers.int.type.bits,
            second_profile.integers.int.type.bits)
        assert.equal(profile.integers.int.type.bits, second_numeric.bits)
        assert.equal(profile.integers.int.type._c_numeric.bits,
            second_numeric._c_numeric.bits)
        assert.equal(profile.integers[profile.lua_integer].type.bits,
            second_numeric._c_numeric_carriers.lua_integer.bits)
        assert.not_equal(first_profile, second_profile)
        assert.not_equal(first_numeric, second_numeric)
        assert.not_equal(first_numeric._c_numeric_carriers,
            second_numeric._c_numeric_carriers)
        assert.is_true(driver.close_resolver_context(first))
        assert.is_true(driver.close_resolver_context(second))
    end)

    it("checks embedded numeric calls without SDK headers or native commands",
    function()
        local name = "embedded.numeric"
        local consumer = "embedded_numeric_consumer"
        local profile = native_target_profile()
        local strategy = compiler_io.new_sync()
        local read_file = strategy.read_file
        local native_commands = 0
        local header_reads = 0
        function strategy:run()
            native_commands = native_commands + 1
            return {
                started = false,
                ok = false,
                diagnostic = "native toolchain is unavailable in this embedding",
            }
        end
        function strategy:read_file(path)
            if path:match("%.h$") then
                header_reads = header_reads + 1
                return nil, "SDK headers are unavailable in this embedding"
            end
            return read_file(self, path)
        end
        write_file(source .. "/" .. consumer .. ".titan", [[
            local provider = import "embedded.numeric"
            function answer(): integer
                local callback = provider.callback()
                local integral: integer = callback(L)
                local floating: float = provider.measure()
                local boxed: value = provider.answer()
                return integral + foreign int.sizeof + foreign int.alignof
            end
        ]])
        local context = driver.new_resolver_context({
            io = strategy,
            target = require("spec.fixtures.target_selection.support").host(),
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [name] = numeric_embedded_module(name, profile),
                }, profile),
        })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, { context = context })
        local ok, loaded, errors = loader(consumer)
        assert.truthy(ok, tostring(loaded))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal(0, native_commands)
        assert.equal(0, header_reads)
        assert.is_nil(context.probe_service)
        assert.is_nil(static_deps[name])

        local statements = driver.imported[consumer].ast[2].block.stats
        local callback = statements[1].decls[1]._type.pointee
        assert.equal("Type.CFunction", callback._tag)
        assert.equal(profile.identity, callback.ret._c_numeric_carriers.identity)
        assert.equal(profile.integers.int.type._c_numeric.bits,
            callback.ret._c_numeric.bits)
        assert.equal("c_integer_to_integer",
            statements[2].exps[1]._adjustment.coercion.op)
        assert.equal("c_float_to_float",
            statements[3].exps[1]._adjustment.coercion.op)
        local boxed = statements[4].exps[1]._adjustment
        assert.equal("gradual_view", boxed.kind)
        assert.equal("inject", boxed.op)
        assert.equal(profile.identity, boxed.source._c_numeric_carriers.identity)

        -- C operators still require the selected native probe to prove their
        -- semantics; scalar metadata and pure primitive layout do not.
        local arithmetic_consumer = "embedded_c_arithmetic"
        write_file(source .. "/" .. arithmetic_consumer .. ".titan", [[
            function add(left: foreign int, right: foreign int): foreign int
                return left + right
            end
        ]])
        ok, loaded, errors = loader(arithmetic_consumer)
        assert.truthy(ok, tostring(loaded))
        assert.is_true(#errors > 0)
        assert.matches("native toolchain is unavailable", table.concat(errors, "\n"),
            1, true)
        assert.is_true(native_commands > 0)

        -- An embedded semantic profile cannot stand in for native C tooling.
        local native_consumer = "embedded_native_consumer"
        write_file(source .. "/" .. native_consumer .. ".titan", [[
            foreign import "unavailable_native.h"
            function answer(): integer return 42 end
        ]])
        ok, loaded, errors = loader(native_consumer)
        assert.truthy(ok, tostring(loaded))
        assert.is_true(#errors > 0)
        assert.matches("native toolchain is unavailable", table.concat(errors, "\n"),
            1, true)
        assert.is_true(native_commands > 0)
        -- Native checking failed, but the ordinary answer declaration remains
        -- serializable. Diagnostics, not manifest presence, determine success.
        assert.is_string(driver.imported[native_consumer].source_manifest)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects native probes which disagree with the embedded target profile",
    function()
        local profile = native_target_profile()
        local incompatible = types.clone_graph(profile)
        incompatible.floats.double.mantissa_digits =
            incompatible.floats.double.mantissa_digits - 1
        incompatible.identity =
            assert(csemantics.profile_identity(incompatible))
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    ["embedded.target"] = types.Module("embedded.target", {}),
                }, incompatible),
        })
        assert.equal(incompatible.identity,
            assert(driver.get_target_profile(context)).identity)
        local service, err = driver.get_probe_service(context)
        assert.is_nil(service)
        assert.matches("target profile", err, 1, true)
        assert.is_nil(context.probe_service)
        assert.is_true(driver.close_resolver_context(context))

        local ordinary = driver.new_resolver_context()
        local ordinary_service = assert(driver.get_probe_service(ordinary))
        assert.equal(profile.identity, ordinary_service.profile.identity)
        assert.equal(profile.identity,
            assert(driver.get_target_profile(ordinary)).identity)
        assert.is_true(driver.close_resolver_context(ordinary))
    end)

    it("requires a live C profile when embedded numeric metadata omits target_profile",
    function()
        local name = "embedded.numeric_without_profile"
        local consumer = "embedded_without_profile_consumer"
        local profile = native_target_profile()
        local strategy = compiler_io.new_sync()
        local native_commands = 0
        function strategy:run()
            native_commands = native_commands + 1
            return {
                started = false,
                ok = false,
                diagnostic = "native profile acquisition is unavailable",
            }
        end
        write_file(source .. "/" .. consumer .. ".titan", [[
            local provider = import "embedded.numeric_without_profile"
            function answer(): integer return provider.answer() end
        ]])
        local context = driver.new_resolver_context({
            io = strategy,
            target = require("spec.fixtures.target_selection.support").host(),
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [name] = result_module(name, profile.integers.int.type),
                }),
        })
        local loader = driver.defaultloader({}, { context = context })
        local ok, loaded, errors = loader(consumer)
        assert.truthy(ok, tostring(loaded))
        assert.is_true(#errors > 0)
        assert.matches(platform.windows and
            "the C probe service has no authoritative target profile" or
            "native profile acquisition is unavailable",
            table.concat(errors, "\n"), 1, true)
        assert.is_true(native_commands > 0)
        assert.is_string(driver.imported[consumer].source_manifest)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("discards an embedded target profile when project source overlaps its inventory",
    function()
        local name = "embedded_profile_overlap"
        local profile = native_target_profile()
        local incompatible = types.clone_graph(profile)
        incompatible.floats.double.mantissa_digits =
            incompatible.floats.double.mantissa_digits - 1
        incompatible.identity =
            assert(csemantics.profile_identity(incompatible))
        write_file(source .. "/" .. name .. ".titan", [[
            function answer(): integer return 42 end
        ]])
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [name] = types.Module(name, {}),
                }, incompatible),
        })
        local loader = driver.defaultloader({}, {
            context = context,
            known_source_modules = { [name] = true },
        })
        local ok, loaded, errors = loader(name, { kind = "source-import" })
        assert.truthy(ok, tostring(loaded))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_true(context.embedded_interface_provider_rejected)
        assert.equal("source", driver.imported[name].kind)
        assert.equal(profile.identity,
            assert(driver.get_target_profile(context)).identity)
        assert.equal(profile.identity,
            assert(driver.get_probe_service(context)).profile.identity)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects a late source overlap which would change an already used target profile",
    function()
        local name = "embedded_profile_late_overlap"
        local profile = native_target_profile()
        local incompatible = types.clone_graph(profile)
        incompatible.floats.double.mantissa_digits =
            incompatible.floats.double.mantissa_digits - 1
        incompatible.identity =
            assert(csemantics.profile_identity(incompatible))
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [name] = types.Module(name, {}),
                }, incompatible),
        })
        local loader = driver.defaultloader({}, { context = context })
        local ok, loaded, errors = loader(name)
        assert.truthy(ok, tostring(loaded))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal(incompatible.identity,
            assert(driver.get_target_profile(context)).identity)
        write_file(source .. "/" .. name .. ".titan", [[
            function answer(): integer return 42 end
        ]])

        ok, loaded = loader(name, { kind = "source-import" })
        assert.is_false(ok)
        assert.matches("cannot continue analysis after embedded provider source overlap",
            loaded, 1, true)
        assert.matches("target profile", loaded, 1, true)
        assert.is_true(context.embedded_interface_provider_rejected)
        assert.is_nil(driver.imported[name])
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("reuses immutable validated provider snapshots with isolated contexts",
    function()
        local name = "embedded.snapshot"
        local provider_file = root .. "/language-server"
        local raw = embedded_provider(provider_file, {
            [name] = result_module(name, types.Integer()),
        })
        local original_types = raw.entries[name].types
        local original_decode = driver.decode_module_interface
        local decode_calls = 0
        local contexts = {}
        local loaders = {}
        driver.decode_module_interface = function(...)
            decode_calls = decode_calls + 1
            return original_decode(...)
        end

        local ran, failure = pcall(function()
            local first = driver.new_resolver_context({
                embedded_interface_provider = raw,
            })
            contexts[#contexts + 1] = first
            assert.equal(1, decode_calls)
            local first_provider = first.embedded_interface_provider
            local original_file = first_provider.entries[name].type.file
            local first_loader = driver.defaultloader({}, {
                context = first,
            })
            loaders[#loaders + 1] = first_loader
            local ok, loaded, errors = first_loader(name)
            assert.truthy(ok, tostring(loaded))
            assert.equal(0, #errors)
            assert.equal(first_provider,
                driver.imported[name].embedded_provider)
            first_provider.entries[name].type.file = provider_path("context-one.so")
            first_provider.entries[name].types = "context-one"

            -- Reusing a successfully validated raw table means reusing that
            -- immutable snapshot. Later caller mutation is deliberately not
            -- observed, while each resolver still receives private graphs.
            raw.provider_file = "/mutated/provider"
            raw.entries[name].abi = "mutated"
            raw.entries[name].types = "not serialized metadata"
            raw.unexpected = true
            local second = driver.new_resolver_context({
                embedded_interface_provider = raw,
            })
            contexts[#contexts + 1] = second
            local second_provider = second.embedded_interface_provider
            assert.equal(1, decode_calls)
            assert.not_equal(first_provider, second_provider)
            assert.not_equal(first_provider.entries,
                second_provider.entries)
            assert.not_equal(first_provider.entries[name].type,
                second_provider.entries[name].type)
            assert.equal(provider_file, second_provider.provider_file)
            assert.equal(driver.TITAN_ABI_VERSION,
                second_provider.entries[name].abi)
            assert.equal(original_types,
                second_provider.entries[name].types)
            assert.equal(original_file,
                second_provider.entries[name].type.file)
            local second_loader = driver.defaultloader({}, {
                context = second,
            })
            loaders[#loaders + 1] = second_loader
            assert.is_nil(driver.imported[name])
            ok, loaded, errors = second_loader(name)
            assert.truthy(ok, tostring(loaded))
            assert.equal(0, #errors)
            assert.equal(original_file, loaded.file)
            assert.equal(second_provider,
                driver.imported[name].embedded_provider)

            local distinct_raw = embedded_provider(provider_file, {
                [name] = result_module(name, types.Integer()),
            })
            local third = driver.new_resolver_context({
                embedded_interface_provider = distinct_raw,
            })
            contexts[#contexts + 1] = third
            assert.equal(2, decode_calls)
        end)
        driver.decode_module_interface = original_decode
        for _, loader in ipairs(loaders) do
            assert.is_true(driver.close_loader(loader))
        end
        for _, context in ipairs(contexts) do
            assert.is_true(driver.close_resolver_context(context))
        end
        assert.truthy(ran, failure)
    end)

    it("selects embedded interfaces before disk without native link inputs",
    function()
        local name = "embedded.primary"
        local provider_file = root .. "/language-server"
        local dynamic = binary .. provider_path("/embedded.so")
        write_file(dynamic, "must not be inspected\n")
        titan._loadlib = function()
            error("disk provider was inspected before embedded metadata")
        end
        titan._abivalue = titan._loadlib
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_file, {
                [name] = types.Module(name, {}),
            }),
        })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, { context = context })
        local ok, modtype, errors = loader(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(name, modtype.name)
        assert.equal("embedded", driver.imported[name].kind)
        assert.equal(provider_file, driver.imported[name].filename)
        assert.same({}, static_deps)

        context.used_compiled_interfaces = {}
        ok, modtype, errors = loader(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.is_table(context.used_compiled_interfaces[name])

        local external = driver.resolve_external_modules({
            [name] = false,
        }, {}, context)
        assert.same({
            kind = "embedded",
            provider_file = provider_file,
        }, external[name])

        assert.is_true(driver.close_loader(loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context.selected_static_providers)
        assert.equal(1, #context.selected_embedded_providers)
        assert.equal(provider_file,
            context.selected_embedded_providers[1].provider_file)
        assert.is_nil(context.native_static_names[name])
        assert.is_nil(context.native_bindings[name])
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("does not reuse an embedded selection without its provider context",
    function()
        local name = "sequence.none"
        local embedded_type = result_module(name, types.Integer())
        local disk_type = result_module(name, types.String())
        cache_dynamic_provider(binary .. provider_path("/sequence.so"), {
            [name] = disk_type,
        })

        local context_a = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server-a", {
                    [name] = embedded_type,
                }),
        })
        local static_a = {}
        local loader_a = driver.defaultloader(static_a, {
            context = context_a,
        })
        local ok, modtype, errors = loader_a(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(embedded_type), types.serialize(modtype))
        assert.equal("embedded", driver.imported[name].kind)
        assert.same({}, static_a)
        assert.is_true(driver.close_loader(loader_a))
        assert.is_true(driver.close_resolver_context(context_a))

        local context_none = driver.new_resolver_context()
        local static_none = {}
        local loader_none = driver.defaultloader(static_none, {
            context = context_none,
        })
        assert.is_nil(driver.imported[name])
        ok, modtype, errors = loader_none(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(disk_type), types.serialize(modtype))
        assert.equal("dynamic", driver.imported[name].kind)
        assert.same({}, static_none)
        assert.is_true(driver.close_loader(loader_none))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context_none)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context_none.selected_embedded_providers)
        assert.is_nil(context_none.native_static_names[name])
        assert.equal("handle", context_none.native_bindings[name])
        assert.is_true(driver.close_resolver_context(context_none))
    end)

    it("reconciles cached disk siblings as one embedded inventory",
    function()
        local name = "sequence.disk"
        local unrequested = "sequence.unrequested"
        local disk_type = result_module(name, types.Integer())
        local embedded_type = result_module(name, types.String())
        local unrequested_disk = result_module(unrequested, types.Integer())
        local unrequested_embedded = result_module(
            unrequested, types.String())
        cache_dynamic_provider(binary .. provider_path("/sequence.so"), {
            [name] = disk_type,
            [unrequested] = unrequested_disk,
        })

        local context_disk = driver.new_resolver_context()
        local loader_disk = driver.defaultloader({}, {
            context = context_disk,
        })
        local ok, modtype, errors = loader_disk(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(disk_type), types.serialize(modtype))
        assert.equal("dynamic", driver.imported[name].kind)
        ok, modtype, errors = loader_disk(unrequested)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(unrequested_disk),
            types.serialize(modtype))
        assert.equal("dynamic", driver.imported[unrequested].kind)
        assert.is_true(driver.close_loader(loader_disk))
        assert.is_true(driver.close_resolver_context(context_disk))

        local provider_file = root .. "/language-server-b"
        local context_b = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_file, {
                [name] = embedded_type,
                [unrequested] = unrequested_embedded,
            }),
        })
        local static_b = {}
        local loader_b = driver.defaultloader(static_b, {
            context = context_b,
        })
        assert.is_nil(driver.imported[name])
        assert.is_nil(driver.imported[unrequested])
        ok, modtype, errors = loader_b(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(embedded_type), types.serialize(modtype))
        assert.equal("embedded", driver.imported[name].kind)
        assert.equal(provider_file, driver.imported[name].filename)
        assert.is_nil(driver.imported[unrequested])
        assert.same({}, static_b)
        assert.is_true(driver.close_loader(loader_b))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context_b)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(1, #context_b.selected_embedded_providers)
        assert.equal(provider_file,
            context_b.selected_embedded_providers[1].provider_file)
        assert.is_nil(context_b.native_static_names[name])
        assert.is_nil(context_b.native_bindings[name])
        assert.is_nil(context_b.native_static_names[unrequested])
        assert.is_nil(context_b.native_bindings[unrequested])
        assert.is_true(driver.close_resolver_context(context_b))
    end)

    it("clears a reused static dependency when embedded metadata replaces it",
    function()
        local name = "sequence.static"
        local pruned = "sequence.pruned"
        local static_type = result_module(name, types.Integer())
        local embedded_type = result_module(name, types.String())
        local shared_static_deps = {
            ["closure.keep"] = true,
            [pruned] = true,
        }

        local context_static = driver.new_resolver_context({
            prefer_static = true,
        })
        cache_static_provider(context_static, binary .. "/sequence.a", {
            [name] = static_type,
        })
        local loader_static = driver.defaultloader(shared_static_deps, {
            context = context_static,
        })
        local ok, modtype, errors = loader_static(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(static_type), types.serialize(modtype))
        assert.equal("static", driver.imported[name].kind)
        assert.is_true(shared_static_deps[name])
        assert.is_true(shared_static_deps["closure.keep"])
        assert.is_true(driver.close_loader(loader_static))
        assert.is_true(driver.close_resolver_context(context_static))

        local provider_file = root .. "/language-server-static"
        local context_embedded = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_file, {
                [name] = embedded_type,
                [pruned] = types.Module(pruned, {}),
            }),
        })
        local loader_embedded = driver.defaultloader(shared_static_deps, {
            context = context_embedded,
        })
        assert.is_nil(driver.imported[name])
        assert.is_nil(shared_static_deps[name])
        assert.is_nil(shared_static_deps[pruned])
        assert.is_true(shared_static_deps["closure.keep"])
        ok, modtype, errors = loader_embedded(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(embedded_type), types.serialize(modtype))
        assert.equal("embedded", driver.imported[name].kind)
        assert.is_nil(shared_static_deps[name])
        assert.is_true(shared_static_deps["closure.keep"])
        assert.is_true(driver.close_loader(loader_embedded))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context_embedded)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context_embedded.selected_static_providers)
        assert.equal(1, #context_embedded.selected_embedded_providers)
        assert.is_nil(context_embedded.native_static_names[name])
        assert.is_nil(context_embedded.native_bindings[name])
        assert.is_true(driver.close_resolver_context(context_embedded))
    end)

    it("does not revive embedded names from a cached source dependency closure",
    function()
        local root_name = "sequence.root"
        local dependency = "sequence.transitive"
        local dependency_type = result_module(dependency, types.Integer())
        assert(lfs.mkdir(source .. "/sequence"))
        write_file(source .. "/sequence/root.titan", [[
            local dependency = import "sequence.transitive"
            function answer(): integer
                return dependency.answer()
            end
        ]])

        local shared_static_deps = {}
        local static_context = driver.new_resolver_context({
            prefer_static = true,
        })
        cache_static_provider(static_context, binary .. "/sequence.a", {
            [dependency] = dependency_type,
        })
        local static_loader = driver.defaultloader(shared_static_deps, {
            context = static_context,
            source_roots = { [root_name] = true },
        })
        local ok, modtype, errors = static_loader(root_name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("source", driver.imported[root_name].kind)
        assert.equal("static", driver.imported[dependency].kind)
        assert.is_true(driver.imported[root_name].deps[dependency])
        assert.is_true(shared_static_deps[root_name])
        assert.is_true(shared_static_deps[dependency])
        assert.is_true(driver.close_loader(static_loader))
        assert.is_true(driver.close_resolver_context(static_context))

        local embedded_context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [dependency] = dependency_type,
                }),
        })
        local embedded_loader = driver.defaultloader(shared_static_deps, {
            context = embedded_context,
        })
        assert.is_nil(driver.imported[dependency])
        assert.is_nil(shared_static_deps[dependency])
        assert.is_true(shared_static_deps[root_name])

        ok, modtype, errors = embedded_loader(dependency)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("embedded", driver.imported[dependency].kind)
        ok, modtype, errors = embedded_loader(root_name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("source", driver.imported[root_name].kind)
        assert.is_true(driver.imported[root_name].deps[dependency])
        assert.is_nil(shared_static_deps[dependency])
        assert.is_true(shared_static_deps[root_name])

        assert.is_true(driver.close_loader(embedded_loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(embedded_context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #embedded_context.selected_static_providers)
        assert.equal(1, #embedded_context.selected_embedded_providers)
        assert.is_nil(embedded_context.native_static_names[dependency])
        assert.is_nil(embedded_context.native_bindings[dependency])
        assert.is_true(driver.close_resolver_context(embedded_context))
    end)

    it("replaces an embedded selection from a different provider context",
    function()
        local name = "sequence.embedded"
        local type_a = result_module(name, types.Integer())
        local type_b = result_module(name, types.String())
        local provider_a = root .. "/language-server-a"
        local provider_b = root .. "/language-server-b"

        local context_a = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_a, {
                [name] = type_a,
            }),
        })
        local loader_a = driver.defaultloader({}, { context = context_a })
        local ok, modtype, errors = loader_a(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(type_a), types.serialize(modtype))
        assert.equal(provider_a, driver.imported[name].filename)
        assert.is_true(driver.close_loader(loader_a))
        assert.is_true(driver.close_resolver_context(context_a))

        local context_b = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_b, {
                [name] = type_b,
            }),
        })
        local static_b = {}
        local loader_b = driver.defaultloader(static_b, {
            context = context_b,
        })
        assert.is_nil(driver.imported[name])
        ok, modtype, errors = loader_b(name)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal(types.serialize(type_b), types.serialize(modtype))
        assert.equal("embedded", driver.imported[name].kind)
        assert.equal(provider_b, driver.imported[name].filename)
        assert.same({}, static_b)
        assert.is_true(driver.close_loader(loader_b))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context_b)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(1, #context_b.selected_embedded_providers)
        assert.equal(provider_b,
            context_b.selected_embedded_providers[1].provider_file)
        assert.is_true(driver.close_resolver_context(context_b))
    end)

    it("rejects a new overlapping provider across stale embedded cache state",
    function()
        local other = "sequence.other"
        local overlap = "sequence.overlap"
        local other_type = result_module(other, types.Integer())
        assert(lfs.mkdir(source .. "/sequence"))
        write_file(source .. "/sequence/overlap.titan",
            "local marker: integer = 1\n")
        cache_dynamic_provider(binary .. provider_path("/sequence.so"), {
            [other] = other_type,
        })

        local context_a = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server-a", {
                    [other] = other_type,
                }),
        })
        local loader_a = driver.defaultloader({}, { context = context_a })
        local ok, modtype, errors = loader_a(other)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("embedded", driver.imported[other].kind)
        assert.is_true(driver.close_loader(loader_a))
        assert.is_true(driver.close_resolver_context(context_a))

        local context_b = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server-b", {
                    [other] = other_type,
                    [overlap] = types.Module(overlap, {}),
                }),
        })
        local static_b = {}
        local loader_b = driver.defaultloader(static_b, {
            context = context_b,
            known_source_modules = { [overlap] = true },
        })
        assert.is_nil(driver.imported[other])
        ok, modtype, errors = loader_b(other)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported[other].kind)
        assert.is_true(context_b.embedded_interface_provider_rejected)
        assert.same({}, static_b)

        ok, modtype, errors = loader_b(overlap, {
            kind = "source-import",
        })
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("source", driver.imported[overlap].kind)
        assert.is_true(driver.close_loader(loader_b))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context_b)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context_b.selected_embedded_providers)
        assert.is_nil(context_b.native_static_names[other])
        assert.equal("handle", context_b.native_bindings[other])
        assert.is_true(driver.close_resolver_context(context_b))
    end)

    it("rejects an embedded inventory which overlaps a cached source sibling",
    function()
        local cached_source = "sequence.cached_source"
        local sibling = "sequence.source_sibling"
        local sibling_type = result_module(sibling, types.Integer())
        assert(lfs.mkdir(source .. "/sequence"))
        write_file(source .. "/sequence/cached_source.titan",
            "local marker: integer = 1\n")
        cache_dynamic_provider(binary .. provider_path("/sequence.so"), {
            [sibling] = sibling_type,
        })

        local source_context = driver.new_resolver_context()
        local source_loader = driver.defaultloader({}, {
            context = source_context,
            source_roots = { [cached_source] = true },
        })
        local ok, modtype, errors = source_loader(cached_source)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("source", driver.imported[cached_source].kind)
        assert.is_true(driver.close_loader(source_loader))
        assert.is_true(driver.close_resolver_context(source_context))

        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [cached_source] = types.Module(cached_source, {}),
                    [sibling] = sibling_type,
                }),
        })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            context = context,
        })
        assert.equal("source", driver.imported[cached_source].kind)
        assert.is_true(context.embedded_interface_provider_rejected)
        assert.equal(cached_source,
            context.embedded_interface_provider_overlap)
        ok, modtype, errors = loader(sibling)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported[sibling].kind)
        assert.same({}, static_deps)

        assert.is_true(driver.close_loader(loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context.selected_embedded_providers)
        assert.is_true(context.source_names[cached_source])
        assert.equal("handle", context.native_bindings[sibling])
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects the whole embedded provider for known or required source",
    function()
        local overlap = "embedded.overlap"
        local other = "embedded.other"
        assert(lfs.mkdir(source .. "/embedded"))
        write_file(source .. "/embedded/overlap.titan",
            "local marker: integer = 1\n")
        cache_dynamic_provider(binary .. provider_path("/embedded.so"), {
            [other] = types.Module(other, {}),
        })
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    [overlap] = types.Module(overlap, {}),
                    [other] = types.Module(other, {}),
                }),
        })
        local loader = driver.defaultloader({}, {
            context = context,
            known_source_modules = { [overlap] = true },
        })
        local ok, modtype, errors = loader(other)
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("dynamic", driver.imported[other].kind)
        assert.is_true(context.embedded_interface_provider_rejected)

        ok, modtype, errors = loader(overlap, { kind = "source-import" })
        assert.truthy(ok, tostring(modtype))
        assert.equal(0, #errors)
        assert.equal("source", driver.imported[overlap].kind)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rebinds an earlier embedded selection after a later source overlap",
    function()
        assert(lfs.mkdir(source .. "/bundle"))
        write_file(source .. "/root.titan", [[
            local fallback = import "bundle.fallback"
            local later = import "bundle.later"
        ]])
        write_file(source .. "/bundle/later.titan",
            "local marker: integer = 1\n")
        local fallback_type = types.Module("bundle.fallback", {})
        cache_dynamic_provider(binary .. provider_path("/bundle.so"), {
            ["bundle.fallback"] = fallback_type,
        })
        local context = driver.new_resolver_context({
            source_first = true,
            embedded_interface_provider = embedded_provider(
                root .. "/language-server", {
                    ["bundle.fallback"] = fallback_type,
                    ["bundle.later"] = types.Module("bundle.later", {}),
                }),
        })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, {
            context = context,
            source_roots = { root = true },
        })
        local ok, result, errors = loader("root")
        assert.truthy(ok, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("dynamic", driver.imported["bundle.fallback"].kind)
        assert.equal("source", driver.imported["bundle.later"].kind)
        assert.is_true(context.embedded_interface_provider_rejected)
        assert.is_nil(static_deps["bundle.fallback"])
        assert.is_true(driver.close_loader(loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        assert.equal(0, #context.selected_embedded_providers)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("recovers contextual owners from the same embedded inventory",
    function()
        local facade = "embedded.facade"
        local owner = "embedded.owner"
        local provider_file = root .. "/language-server"
        local context = driver.new_resolver_context({
            embedded_interface_provider = embedded_provider(provider_file, {
                [facade] = types.Module(facade, {}),
                [owner] = types.Module(owner, {}),
            }),
        })
        local static_deps = {}
        local loader = driver.defaultloader(static_deps, { context = context })
        local ok, facade_type, errors = loader(facade)
        assert.truthy(ok, tostring(facade_type))
        assert.equal(0, #errors)
        ok, facade_type, errors = loader(owner, {
            kind = "nominal-owner",
            exposer = facade,
        })
        assert.truthy(ok, tostring(facade_type))
        assert.equal(owner, facade_type.name)
        assert.same({}, errors)
        assert.is_nil(driver.imported[owner])
        assert.same({}, static_deps)
        assert.same({}, context.native_constraints)

        local _, resolution = next(context.contextual_resolutions)
        assert.equal(owner, resolution.owner)
        assert.equal(facade, resolution.exposer)
        assert.equal("embedded", resolution.kind)
        assert.equal(provider_file, resolution.provider_file)
        assert.equal(provider_file, resolution.exposer_file)
        assert.is_false(resolution.ordinary_lookup)

        assert.is_true(driver.close_loader(loader))
        local finalized, finalize_errors =
            driver.finalize_resolver_context(context)
        assert.truthy(finalized,
            finalize_errors and table.concat(finalize_errors, "\n"))
        local retained = false
        for _, candidate in pairs(context.contextual_resolutions) do
            if candidate == resolution then retained = true end
        end
        assert.is_true(retained)
        assert.same({}, context.native_constraints)
        assert.is_nil(context.native_bindings[owner])
        assert.is_true(driver.close_resolver_context(context))
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
            path = fixture_path("/virtual/source-interface.h"),
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
                expected = "kind must be 'file', 'search', or 'origin'",
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
                expected = "repeats search input '" .. fixture_path("/virtual/source-interface.h") .. "'",
            },
            {
                headers = {
                    {
                        kind = "origin",
                        path = valid.path,
                        identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. valid.path,
                    },
                    {
                        kind = "origin",
                        path = valid.path,
                        identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. valid.path,
                    },
                },
                expected = "repeats origin input '" .. fixture_path("/virtual/source-interface.h") .. "'",
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
                tagname = nil,
                typedef = nil,
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
        local function generated_origin(headers)
            local owner = { io = compiler_io.new_sync() }
            local ast = {}
            for _, name in ipairs(headers or {}) do
                ast[#ast + 1] = { _tag = "Ast.TopLevelForeignImport",
                    _include = { rendered = "<" .. name .. ">" } }
            end
            local descriptor = assert(ffiheaders.prepare(owner,
                "source_manifest_generated_origin", ast,
                fixture_path("/project/source_manifest_generated_origin.titan")))
            assert.is_true(ffiheaders.close(owner))
            return assert(cprobe.normalize_include_descriptor({
                include_kind = "quote", include_name = descriptor.logical_name,
                resolved = descriptor.identity, generated_header = descriptor,
            }))
        end
        local function generated_manifest(origin)
            return direct(with_type("source_manifest_generated_origin", aggregate(origin)))
        end
        local first_origin = generated_origin({ "first.h", "second.h" })
        local first_manifest = assert(sourceinterface.serialize(generated_manifest(first_origin)))
        -- A fresh temporary tree with identical logical contents keeps identity.
        assert.equal(first_manifest, assert(sourceinterface.serialize(generated_manifest(
            generated_origin({ "first.h", "second.h" })))))
        -- The logical spelling stays fixed, so the bundle digest must distinguish
        -- a changed environment when aggregate layout is omitted from the graph.
        assert.not_equal(first_manifest, assert(sourceinterface.serialize(generated_manifest(
            generated_origin({ "second.h", "first.h" })))))
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
            path = fixture_path("/virtual/direct-source-interface.h"),
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
            path = fixture_path("/virtual/first.h"),
            identity = "missing",
        }
        local second = {
            kind = "file",
            path = fixture_path("/virtual/second.h"),
            identity = "bytes:one",
        }
        local third = {
            kind = "origin",
            path = second.path,
            identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. second.path,
        }
        local baseline = manifest({ first, second, third })
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
            {
                kind = third.kind,
                path = third.path,
                identity = third.identity,
            },
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = "file",
                path = first.path,
                identity = first.identity,
            }, second, third,
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = first.kind,
                path = fixture_path("/virtual/renamed.h"),
                identity = first.identity,
            }, second, third,
        }))
        assert.not_equal(baseline, manifest({
            {
                kind = first.kind,
                path = first.path,
                identity = "now-present",
            }, second, third,
        }))
        assert.not_equal(baseline, manifest({
            first, second, {
                kind = "origin",
                path = third.path,
                identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. fixture_path("/virtual/other.h"),
            },
        }))
        assert.not_equal(baseline, manifest({ second, first, third }))
    end)

    it("ignores benign descriptor sharing topology", function()
        local function manifest(shared)
            local name = "source_manifest_sharing"
            local first = { _tag = "Type.Integer" }
            local second = shared and first or { _tag = "Type.Integer" }
            local member = types.ModuleMember(name, "hidden",
                types.Function({ first, second }, { first },
                    false, nil, nil), { "left", "right" })
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
            "struct hidden", "hidden", nil, {}, true, false)
        local entry = source_entry(name,
            source_module(name, {}, {}, {}, { Hidden = aggregate }))
        local manifest, err = driver.serialize_source_interface(entry)
        assert.is_nil(manifest)
        assert.matches("has no stable C header origin", err, 1, true)

        local dependency = {
            kind = "file",
            path = fixture_path("/virtual/aggregate-origin.h"),
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
                path = fixture_path("/virtual/source-manifest-complex.h"),
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
                "struct source_node", "source_node", nil,
                aggregate_fields, true, false))
            aggregate._c_tag_scope = name
            local aggregate_pointer = cmetadata(types.CPointer(
                aggregate, { "const" }))
            local recursive_field = cmetadata(types.CField(
                aggregate, "next", aggregate_pointer, nil, false))
            aggregate_fields[1] = recursive_field
            aggregate_fields.next = recursive_field

            local aggregate_union = cmetadata(types.CUnion(
                "union source_choice", "source_choice", nil,
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
                { aggregate_pointer, carray, ctypedef }, cint, false, nil))
            cfunction._paramstyle = "prototype"
            cfunction._return_declaration_qualifiers = { "const" }

            local callable_scope = types.GenericScope(
                name, nil, "identity", "callable", "function")
            local callable_parameter = types.Parameter(
                callable_scope, 1, "T", nil)
            local callable_type_parameter = types.TypeParameter("T", nil)
            local generic_callable = types.ModuleMember(
                name, "identity",
                types.FunctionScheme(callable_scope,
                    { callable_type_parameter },
                    types.Function(
                        { callable_parameter }, { callable_parameter },
                        false, nil, nil)),
                { "item" })

            local nominal_name = name .. ".Hidden"
            local nominal_scope = types.GenericScope(
                name, nominal_name, nil, "owner", "record")
            local nominal_parameter = types.Parameter(
                nominal_scope, 1, "T", nil)
            local nominal_type_parameter = types.TypeParameter("T", nil)
            local field = types.Field(
                nominal_name, "payload", nominal_parameter, 0, false)
            field.islocal = true
            local fields = { field }
            fields.payload = field
            local build = types.StaticMethod(
                nominal_name, "build", { nominal_parameter },
                { types.Nominal(nominal_name, { nominal_parameter }) },
                nil, nil, { "payload" })
            build.islocal = true
            local create = types.StaticMethod(
                nominal_name, "create", {},
                { types.Nominal(nominal_name, { nominal_parameter }) },
                nil, nil, {})
            create.islocal = true
            local read = types.Method(
                nominal_name, "read", {}, { nominal_parameter },
                nil, nil, {})
            read.islocal = true
            local replace = types.Method(
                nominal_name, "replace", { nominal_parameter },
                { nominal_parameter }, nil, nil, { "payload" })
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
                name, "Hidden", nominal, nil)

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
                types.ModuleMember(name, "Visible", visible, nil),
            }

            local foreign = types.ModuleMember(
                name, "native", cfunction,
                { "node", "values", "count" })
            foreign._foreign_source = true

            local alias = types.GenericAlias(
                name, "Alias", true, nominal_name, nil,
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
            path = fixture_path("/virtual/header.h"),
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
                expected = "kind must be 'file', 'search', or 'origin'",
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
                expected = "repeats search input '" .. fixture_path("/virtual/header.h") .. "'",
            },
            {
                value = {
                    {
                        kind = "origin",
                        path = valid.path,
                        identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. valid.path,
                    },
                    {
                        kind = "origin",
                        path = valid.path,
                        identity = version.C_HEADER_ORIGIN_PROTOCOL .. ";real=" .. valid.path,
                    },
                },
                expected = "repeats origin input '" .. fixture_path("/virtual/header.h") .. "'",
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
            }, new_context())
        end, "known_source_modules must contain valid module names mapped to true")
        assert.has_error(function()
            driver.resolve_external_modules({ external_invalid = "yes" }, {}, new_context())
        end, "external resolution requests must contain valid module names " ..
            "mapped to booleans")

        local missing = driver.resolve_external_modules({
            external_missing = false,
        }, {}, new_context())
        assert.same({ kind = "missing" }, missing.external_missing)
        local source_missing = driver.resolve_external_modules({
            external_source_missing = true,
        }, {}, new_context())
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
        }, {}, new_context())
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
            assert.equal(binary .. provider_path("/external_broken.so"), path)
            return nil, "injected provider inspection failure"
        end
        local broken = driver.resolve_external_modules({
            external_broken = false,
        }, {}, provider_context)
        assert.equal("error", broken.external_broken.kind)
        assert.matches("injected provider inspection failure",
            broken.external_broken.message, 1, true)
        assert.is_true(driver.close_resolver_context(provider_context))

        local owned = new_context()
        local close_calls = 0
        owned.probe_service = { close = function()
            close_calls = close_calls + 1
            return nil, "injected external close failure"
        end }
        assert.same({}, driver.resolve_external_modules({}, {}, owned))
        assert.equal(0, close_calls)
        local closed, close_failure = driver.close_resolver_context(owned)
        assert.is_nil(closed)
        assert.equal("injected external close failure", close_failure)
        assert.equal(1, close_calls)
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

    it("attributes persistent probe cache lookups to the checking source module",
    function()
        local events = {}
        local semantic_events = {}
        local execution_events = {}
        local context = driver.new_resolver_context({
            c_probe_cache_trace = function(
                    module_name, stage, hit, key, path)
                events[#events + 1] = {
                    module_name = module_name,
                    stage = stage,
                    hit = hit,
                    key = key,
                    path = path,
                }
            end,
            c_probe_semantic_trace = function(event)
                semantic_events[#semantic_events + 1] = event
            end,
            c_probe_execution_trace = function(event)
                execution_events[#execution_events + 1] = event
            end,
        })
        context.foreign_c_configuration_id =
            driver.FOREIGN_C_CONFIGURATION_ID

        local original_descriptor = driver.toolchain_descriptor
        local original_new_service = cprobe.new_service
        local captured
        local completed, failure = xpcall(function()
            driver.toolchain_descriptor = function(resolver)
                return {
                    io = resolver.io,
                    compiler_argv = { "cc" },
                    compile_flags = {},
                    language_mode = "c99",
                    language_flag = false,
                    cppflags = {},
                    cflags = {},
                    include_dirs = {},
                }
            end
            cprobe.new_service = function(options)
                captured = options
                return { close = function() return true end }
            end

            assert.is_table(driver.get_probe_service(context))
            captured.persistent_cache_trace(
                "lookup", true, "0123abcd", "/cache/result", "provider")
            local semantic = {
                module = "provider",
                event = "semantic_result",
                key = "0123abcd",
            }
            local execution = {
                module = "provider",
                event = "compiler_execution",
                key = "0123abcd",
            }
            captured.semantic_trace(semantic)
            captured.execution_trace(execution)

            assert.same({{
                module_name = "provider",
                stage = "lookup",
                hit = true,
                key = "0123abcd",
                path = "/cache/result",
            }}, events)
            assert.same({ semantic }, semantic_events)
            assert.same({ execution }, execution_events)
        end, debug.traceback)
        driver.toolchain_descriptor = original_descriptor
        cprobe.new_service = original_new_service
        local closed, close_error = driver.close_resolver_context(context)
        assert.truthy(completed, failure)
        assert.truthy(closed, close_error)
    end)

    it("cleans a source checking header when its write is cancelled",
    function()
        local candidate = source_entry("provider")
        candidate.ast = {{
            _tag = "Ast.TopLevelForeignFunc",
            name = "identity",
        }}
        candidate.source_manifest = source_manifest(candidate)

        local strategy = compiler_io.new_sync()
        local ordinary_write_file = strategy.write_file
        local checking_header
        function strategy:write_file(path, contents)
            local wrote, err = ordinary_write_file(self, path, contents)
            if wrote and path:match("/provider[.]titan[.]h$") then
                checking_header = path
                error("simulated checking-header cancellation")
            end
            return wrote, err
        end
        local context = driver.new_resolver_context({ io = strategy })
        local original_generate_foreign_header =
            coder.generate_foreign_header
        coder.generate_foreign_header = function()
            return "/* cached source foreign header */\n"
        end
        local loader
        local loaded, failure = pcall(function()
            loader = driver.defaultloader({}, {
                context = context,
                cached_source_entries = { provider = candidate },
            })
            return loader("provider")
        end)
        coder.generate_foreign_header = original_generate_foreign_header
        assert.is_false(loaded)
        assert.matches("simulated checking%-header cancellation", failure)
        assert.is_string(checking_header)
        assert.equal("file", lfs.attributes(checking_header, "mode"))

        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
        assert.is_nil(lfs.symlinkattributes(checking_header))
    end)

    it("uses binaries for dependencies and source for explicit roots", function()
        assert(lfs.mkdir(source .. "/titan/timer"))
        write_file(source .. "/titan/timer/timer.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(binary .. provider_path("/titan/timer.so"), "mock interface\n")

        local symbols = {}
        mock_native_abi(binary .. provider_path("/titan/timer.so"), { ["titan.timer"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/titan/timer.so"), filename)
            symbols[#symbols + 1] = symbol
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            elseif symbol == "titan_timer_layouts" then
                return function() return empty_layouts("titan.timer") end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({}, resolver_options())("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "titan_timer_abi", "titan_timer_types", "titan_timer_layouts" }, symbols)
        assert.is_nil(driver.imported["titan.timer"].ast)

        -- A later explicit build request replaces a cached binary interface
        -- with the source root instead of silently treating compilation as a
        -- no-op.
        local deps = {}
        ok, modtype, errors = driver.defaultloader(deps, resolver_options({ source_roots = { ["titan.timer"] = true },  }))("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.timer"].ast)
        assert.equal(true, deps["titan.timer"])
        assert.equal(source .. "/titan/timer/timer.titan",
            paths.to_slash(driver.imported["titan.timer"].filename))
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
        cache_dynamic_provider(binary .. provider_path("/pkg/flat.so"), {
            ["pkg.flat"] = compiled_flat,
        })
        write_file(binary .. provider_path("/pkg/folder.so"),
            "explicit source lookup must not inspect this provider\n")

        local loader = driver.defaultloader({}, resolver_options({ source_roots = { consumer = true },  }))
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
            paths.to_slash(driver.imported["pkg.flat"].filename))
        assert.equal("source", driver.imported["pkg.folder"].kind)
        assert.equal(source .. "/pkg/folder/folder.titan",
            paths.to_slash(driver.imported["pkg.folder"].filename))
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
        local provider = binary .. provider_path("/vendor.so")
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
                types.Function({}, { types.Integer() }, false, nil, nil),
                {}),
        })
        cache_dynamic_provider(binary .. provider_path("/provider.so"), {
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

        local loader = driver.defaultloader({}, resolver_options({ source_roots = {
            ordinary_root = true,
            source_root = true,
        },  }))
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

    it("retains immutable snapshots of every consumed compiled view across source replacement and mutable tableloader descriptors",
    function()
        local first_dir = root .. "/first-bin"
        local second_dir = root .. "/second-bin"
        assert(lfs.mkdir(first_dir))
        assert(lfs.mkdir(second_dir))
        local first_so = first_dir .. provider_path("/provider.so")
        local second_so = second_dir .. provider_path("/provider.so")
        local integer_provider = types.Module("provider", {
            types.ModuleMember("provider", "answer",
                types.Function({}, { types.Integer() }, false, nil, nil), {}),
        })
        local string_provider = types.Module("provider", {
            types.ModuleMember("provider", "answer",
                types.Function({}, { types.String() }, false, nil, nil), {}),
        })
        write_file(first_so, "first dynamic provider\n")
        write_file(second_so, "second dynamic provider\n")
        mock_native_abi(first_so, { provider = driver.TITAN_ABI_VERSION })
        mock_native_abi(second_so, { provider = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            local selected = filename == first_so and integer_provider
                or filename == second_so and string_provider
                or error("unexpected provider " .. tostring(filename))
            if symbol == "provider_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "provider_types" then
                local serialized = types.serialize(selected)
                return function() return serialized end
            elseif symbol == "provider_layouts" then
                return function() return empty_layouts("provider") end
            end
            error("unexpected symbol " .. symbol)
        end

        write_file(source .. "/first_consumer.titan", [[
            local provider = import "provider"
            function answer(): integer return provider.answer() end
        ]])
        write_file(source .. "/second_consumer.titan", [[
            local provider = import "provider"
            function answer(): integer return provider.answer() end
        ]])
        write_file(source .. "/provider.titan", [[
            local function secret(): integer return 40 end
            function answer(): integer return secret() + 2 end
        ]])
        write_file(source .. "/matching_source_root.titan", [[
            local provider = import "provider.titan"
            function answer(): integer return provider.secret() + provider.answer() end
        ]])

        driver.TITAN_BIN_PATH = first_dir
        local context = driver.new_resolver_context()
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = {
                first_consumer = true,
                second_consumer = true,
                matching_source_root = true,
            },
        })
        local loaded, result, errors = loader("first_consumer")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        loaded, result, errors = loader("second_consumer")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("dynamic", driver.imported.provider.kind)
        assert.equal(first_so, driver.imported.provider.filename)

        loaded, result, errors = loader("matching_source_root")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.equal("source", driver.imported.provider.kind)
        assert.is_table(driver.imported.provider.type.source_members.secret)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))

        -- Consuming two distinct compiled views of `provider` in one resolver
        -- context and then replacing `provider` with source matching only the
        -- second view must still reject against the first recorded view.
        write_file(source .. "/string_consumer.titan", [[
            local provider = import "provider"
            function answer(): string return provider.answer() end
        ]])
        write_file(source .. "/provider.titan", [[
            function answer(): string return "matches second only" end
        ]])
        write_file(source .. "/mismatch_source_root.titan", [[
            local provider = import "provider.titan"
            function answer(): string return provider.answer() end
        ]])
        driver.imported, types.registry = {}, {}
        local multi_ctx = driver.new_resolver_context()
        local multi_loader = driver.defaultloader({}, {
            context = multi_ctx,
            source_roots = {
                first_consumer = true,
                string_consumer = true,
                mismatch_source_root = true,
            },
        })
        driver.TITAN_BIN_PATH = first_dir
        loaded, result, errors = multi_loader("first_consumer")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))

        driver.imported.provider = nil
        driver.TITAN_BIN_PATH = second_dir
        loaded, result, errors = multi_loader("string_consumer")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors, table.concat(errors, "\n"))

        loaded, result, errors = multi_loader("mismatch_source_root")
        assert.truthy(loaded, tostring(result))
        assert.equal(1, #errors)
        assert.equal("source module 'provider' does not match a compiled " ..
            "interface already used in this compilation", errors[1])
        assert.is_true(driver.close_loader(multi_loader))
        assert.is_true(driver.close_resolver_context(multi_ctx))

        -- Mutating a caller-held tableloader Type.Module descriptor in-place
        -- across A -> B -> A returns must snapshot each returned projection
        -- so a later source replacement matching A still rejects B.
        local mutable_fn = types.Function({}, { types.Integer() }, false, nil, nil)
        local mutable_compiled = types.Module("cached", {
            types.ModuleMember("cached", "answer", mutable_fn, {}),
        })
        local imported = {
            cached = { kind = "dynamic", type = mutable_compiled },
        }
        local table_loader = driver.tableloader({
            cached = [[
                function answer(): integer return 7 end
            ]],
        }, imported, nil, resolver_options())
        loaded, result, errors = table_loader("cached")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors)

        mutable_fn.rettypes[1] = types.String()
        loaded, result, errors = table_loader("cached")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors)

        mutable_fn.rettypes[1] = types.Integer()
        loaded, result, errors = table_loader("cached")
        assert.truthy(loaded, tostring(result))
        assert.equal(0, #errors)

        loaded, result, errors = table_loader("cached", { kind = "source-import" })
        assert.truthy(loaded, tostring(result))
        assert.equal(1, #errors)
        assert.equal("source module 'cached' does not match a compiled " ..
            "interface already used in this compilation", errors[1])
        assert.is_true(driver.close_tableloader(table_loader))
    end)

    it("does not fall back to a cached compiled provider for an " ..
       "explicit-source import", function()
        local compiled = types.Module("compiled_only", {}, {})
        cache_dynamic_provider(binary .. provider_path("/compiled_only.so"), {
            compiled_only = compiled,
        })
        write_file(source .. "/consumer.titan", [[
            local ordinary = import "compiled_only"
            local required = import "compiled_only.titan"
            function answer(): integer return 42 end
        ]])

        local loader = driver.defaultloader({}, resolver_options({ source_roots = { consumer = true },  }))
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
        write_file(binary .. provider_path("/preferred.so"), "broken binary that must not open\n")
        titan._loadlib = function()
            error("source-first lookup must not probe an occupied binary")
        end
        titan._abivalue = titan._loadlib

        local context = driver.new_resolver_context({ source_first = true })
        local ok, modtype, errors = driver.defaultloader({}, {
            context = context,
        })("preferred")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal("source", driver.imported.preferred.kind)
        assert.equal(source .. "/preferred.titan",
            paths.to_slash(driver.imported.preferred.filename))
    end)

    it("falls back to the preferred compiled format after a source miss",
       function()
        write_file(binary .. provider_path("/fallback.so"), "mock interface\n")
        mock_native_abi(binary .. provider_path("/fallback.so"), { fallback = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/fallback.so"), filename)
            if symbol == "fallback_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "fallback_types" then
                return function() return "Module('fallback',{})" end
            elseif symbol == "fallback_layouts" then
                return function() return empty_layouts("fallback") end
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
        write_file(binary .. provider_path("/fallback_static.so"), "mock interface\n")
        mock_native_abi(binary .. provider_path("/fallback_static.so"), { fallback_static = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/fallback_static.so"), filename)
            if symbol == "fallback_static_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "fallback_static_types" then
                return function()
                    return "Module('fallback_static',{})"
                end
            elseif symbol == "fallback_static_layouts" then
                return function() return empty_layouts("fallback_static") end
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
        cache_dynamic_provider(binary .. provider_path("/bundle.so"), {
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
        cache_dynamic_provider(binary .. provider_path("/bundle.so"), {
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
        assert.equal(provider_path("bundle.so"), driver.imported["bundle.fallback"].type.file)
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
        write_file(binary .. provider_path("/titan/sample.so"), "occupied binary\n")
        titan._loadlib = function()
            error("blocked source must be terminal before compiled lookup")
        end
        titan._abivalue = titan._loadlib

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
        local ok, modtype, errors = driver.defaultloader(deps, resolver_options({ source_overrides = { generated = descriptor },  }))("generated")
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
                    false, nil, nil), {}),
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
        local loader = driver.defaultloader(static_deps, resolver_options({ source_roots = { dirty = true }, source_overrides = { dirty = descriptor },
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
                    identity = version.C_HEADER_SEARCH_PROTOCOL ..
                        ";exists=no;kind=missing;open=unreadable",
                }},
            },
        }, }))

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
            identity = version.C_HEADER_SEARCH_PROTOCOL ..
                ";exists=no;kind=missing;open=unreadable",
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
                    false, nil, nil), {}),
        })
        local filename = root .. "/provider-generated.titan"
        local loader = driver.defaultloader({}, resolver_options({ source_roots = { provider = true }, source_overrides = {
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
        }, }))

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
        local provider_loader = driver.defaultloader({}, resolver_options({ source_roots = { provider = true }, source_overrides = { provider = provider_descriptor }, }))
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
        local provider_loader = driver.defaultloader({}, resolver_options({ source_roots = { provider = true }, source_overrides = {
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
        }, }))
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

    it("reports exclusive parse, check, and other source process CPU",
    function()
        local parser = require "titan-compiler.parser"
        local checker = require "titan-compiler.checker"
        local main_filename = root .. "/exclusive-source-profile.titan"
        local part_filename = root .. "/exclusive-source-profile-part.titan"
        write_file(main_filename, [[
            function answer(): integer return 42 end
        ]])
        write_file(part_filename, [[
            function extra(): integer return 1 end
        ]])

        local now = 0
        local strategy = compiler_io.new_sync()
        local read_file = strategy.read_file
        function strategy:read_file(path)
            local contents, read_error = read_file(self, path)
            if path == main_filename or path == part_filename then
                now = now + 0.002
            end
            return contents, read_error
        end

        local phases = {}
        local profiles = {}
        local context = driver.new_resolver_context({
            io = strategy,
            c_header_process_trace = function(
                    _, _, phase, _, cpu_ms)
                phases[#phases + 1] = {
                    phase = phase,
                    cpu_ms = cpu_ms,
                }
            end,
            source_process_trace = function(
                    module_name, traced_filename, outcome,
                    self_cpu_ms, total_cpu_ms,
                    parse_cpu_ms, check_cpu_ms)
                profiles[#profiles + 1] = {
                    module_name = module_name,
                    filename = traced_filename,
                    outcome = outcome,
                    self_cpu_ms = self_cpu_ms,
                    total_cpu_ms = total_cpu_ms,
                    parse_cpu_ms = parse_cpu_ms,
                    check_cpu_ms = check_cpu_ms,
                }
            end,
        })
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { profiled = true },
            source_overrides = {
                profiled = {
                    kind = "folder",
                    main = main_filename,
                    files = { main_filename, part_filename },
                    native_output = main_filename,
                },
            },
        })

        local real_clock = os.clock
        local original_parse = parser.parse
        local original_check = checker.check
        local parsed_files = {}
        os.clock = function() return now end
        parser.parse = function(filename, input)
            local results = table.pack(original_parse(filename, input))
            if filename == main_filename then
                now = now + 0.004
                parsed_files[#parsed_files + 1] = filename
            elseif filename == part_filename then
                now = now + 0.006
                parsed_files[#parsed_files + 1] = filename
            end
            return table.unpack(results, 1, results.n)
        end
        checker.check = function(module_name, ...)
            if module_name == "profiled" then
                -- Fifty milliseconds are checker CPU. The remaining fifty
                -- are complete header processing and downstream conversion;
                -- their component phases are informational and must not be
                -- subtracted from the check or source frame again.
                now = now + 0.040
                context.c_header_process_trace(
                    "profile.h", "/profile.h", "preprocessing",
                    "complete", 7, "/profile.h")
                context.c_header_process_trace(
                    "profile.h", "/profile.h", "c_parse",
                    "complete", 8, "/profile.h")
                now = now + 0.020
                context.c_header_process_trace(
                    "profile.h", "/profile.h", "process_total",
                    "complete", 20, "/profile.h")
                now = now + 0.030
                context.c_header_process_trace(
                    "profile.h", "/profile.h",
                    "downstream_ffi_conversion",
                    "complete", 30, "/profile.h")
            end
            local results = table.pack(original_check(module_name, ...))
            if module_name == "profiled" then now = now + 0.010 end
            return table.unpack(results, 1, results.n)
        end
        local exercised, ok, _, errors = pcall(loader, "profiled")
        checker.check = original_check
        parser.parse = original_parse
        os.clock = real_clock

        local loader_closed, loader_close_error =
            driver.close_loader(loader)
        local context_closed, context_close_error =
            driver.close_resolver_context(context)
        assert.truthy(loader_closed, loader_close_error)
        assert.truthy(context_closed, context_close_error)
        assert.truthy(exercised, ok)
        assert.truthy(ok)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.same({ main_filename, part_filename }, parsed_files)
        assert.same({
            { phase = "preprocessing", cpu_ms = 7 },
            { phase = "c_parse", cpu_ms = 8 },
            { phase = "process_total", cpu_ms = 20 },
            { phase = "downstream_ffi_conversion", cpu_ms = 30 },
        }, phases)
        assert.equal(1, #profiles)
        assert.equal("profiled", profiles[1].module_name)
        assert.equal(main_filename, profiles[1].filename)
        assert.equal("complete", profiles[1].outcome)
        assert.is_true(math.abs(profiles[1].total_cpu_ms - 114) < 0.0001)
        assert.is_true(math.abs(profiles[1].self_cpu_ms - 64) < 0.0001)
        -- Folder parse time is the sum of both constituents (4 + 6), check
        -- time excludes both terminal header phases (100 - 20 - 30), and the
        -- remainder is the two source reads (2 + 2).
        assert.is_true(math.abs(profiles[1].parse_cpu_ms - 10) < 0.0001)
        assert.is_true(math.abs(profiles[1].check_cpu_ms - 50) < 0.0001)
        local other_cpu_ms = profiles[1].self_cpu_ms -
            profiles[1].parse_cpu_ms - profiles[1].check_cpu_ms
        assert.is_true(math.abs(other_cpu_ms - 4) < 0.0001)
    end)

    it("reports zero parse and check CPU for pre-parse source failures",
    function()
        local filename = root .. "/missing-generated-contents.titan"
        local profiles = {}
        local context = driver.new_resolver_context({
            source_process_trace = function(
                    module_name, traced_filename, outcome,
                    self_cpu_ms, total_cpu_ms,
                    parse_cpu_ms, check_cpu_ms)
                profiles[#profiles + 1] = {
                    module_name = module_name,
                    filename = traced_filename,
                    outcome = outcome,
                    self_cpu_ms = self_cpu_ms,
                    total_cpu_ms = total_cpu_ms,
                    parse_cpu_ms = parse_cpu_ms,
                    check_cpu_ms = check_cpu_ms,
                }
            end,
        })
        local loader = driver.defaultloader({}, {
            context = context,
            source_roots = { missing_contents = true },
            source_overrides = {
                missing_contents = {
                    kind = "generated",
                    main = filename,
                    files = { filename },
                    contents = {},
                },
            },
        })

        local ok, message = loader("missing_contents")
        assert.falsy(ok)
        assert.match("generated source has no contents", message, 1, true)
        assert.equal(1, #profiles)
        assert.equal("missing_contents", profiles[1].module_name)
        assert.equal(filename, profiles[1].filename)
        assert.equal("failed", profiles[1].outcome)
        assert.equal(0, profiles[1].parse_cpu_ms)
        assert.equal(0, profiles[1].check_cpu_ms)
        assert.is_true(profiles[1].self_cpu_ms >= 0)
        assert.is_true(
            profiles[1].self_cpu_ms <= profiles[1].total_cpu_ms)
        assert.is_true(driver.close_loader(loader))
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rehydrates relative cross-directory foreign headers per resolver",
    function()
        local cwd = paths.to_slash(assert(lfs.currentdir()))
        local temporary_name = assert(temporary.name())
        local suffix = assert(temporary_name:match("([^/]+)$"))
        assert(os.remove(temporary_name))
        local relative_root = ".driver-relative-" .. suffix
        local provider_source_filename =
            relative_root .. "/a/provider.titan"
        local consumer_source_filename =
            relative_root .. "/b/consumer.titan"
        local provider_filename =
            cwd .. "/" .. provider_source_filename
        local relative_public_header = provider_source_filename .. ".h"
        local public_header = provider_filename .. ".h"
        local previous_source_path = driver.TITAN_SOURCE_PATH
        local provider_loader, provider_context
        local consumer_loader
        local context
        local parsed_generated_headers = {}
        local function trace_generated_header(
                requested, resolved, phase, outcome, cpu_ms, identity)
            if phase == "process_total" and
               requested:match("[.]titan[.]h$") then
                parsed_generated_headers[#parsed_generated_headers + 1] = {
                    requested = requested,
                    resolved = resolved,
                    outcome = outcome,
                    cpu_ms = cpu_ms,
                    identity = identity,
                }
            end
        end

        local completed, failure = xpcall(function()
            assert(lfs.mkdir(relative_root))
            assert(lfs.mkdir(relative_root .. "/a"))
            assert(lfs.mkdir(relative_root .. "/b"))
            write_file(relative_root .. "/a/provider.h",
                "typedef int provider_int;\n")
            write_file(relative_root .. "/a/provider.titan", [[
                foreign import "provider.h"
                foreign function identity(
                        input: provider_int): provider_int
                    return input
                end
            ]])
            write_file(relative_root .. "/b/consumer.titan", [[
                local provider = import "a.provider.titan"
                function answer(): integer return 42 end
            ]])
            driver.TITAN_SOURCE_PATH = relative_root

            local provider_options = resolver_options({
                source_roots = { ["a.provider"] = true },
                c_header_process_trace = trace_generated_header,
            })
            provider_context = provider_options.context
            provider_loader = driver.defaultloader({}, provider_options)
            local provider_ok, _, provider_errors, provider_info =
                provider_loader("a.provider")
            assert.truthy(provider_ok)
            assert.equal(0, #provider_errors,
                table.concat(provider_errors, "\n"))
            local retained = driver.imported["a.provider"]
            local retained_ast = retained.ast
            local old_header = assert(retained.checking_foreign_header)

            -- A normal source check remains the publication seam: the exact
            -- ordered dependency array recorded on the annotated AST is the
            -- one exposed on the imported project-module entry.
            assert.is_true(#retained.ast._c_header_dependencies > 0)
            assert.equal(retained.ast._c_header_dependencies,
                retained.c_header_dependencies)
            assert.equal(provider_source_filename, retained.filename)
            assert.equal(public_header,
                provider_info.foreign_header_probe_identity)
            assert.is_true(paths.is_absolute(old_header))
            assert.not_equal(public_header, old_header)
            assert.matches(
                "/a/provider[.]titan[.]h$", old_header)
            assert.equal("file", lfs.attributes(old_header, "mode"))

            local cached_ok, _, cached_errors, cached_info =
                provider_loader("a.provider")
            assert.truthy(cached_ok)
            assert.equal(0, #cached_errors,
                table.concat(cached_errors, "\n"))
            assert.equal(old_header, cached_info.foreign_header)
            assert.equal(public_header,
                cached_info.foreign_header_probe_identity)
            assert.is_true(driver.close_loader(provider_loader))
            assert.is_true(driver.close_resolver_context(provider_context))
            provider_context = nil
            provider_loader = nil
            assert.is_nil(lfs.symlinkattributes(old_header))

            driver.imported = {}
            types.registry = {}
            local profiles = {}
            context = driver.new_resolver_context({
                c_header_process_trace = trace_generated_header,
                source_process_trace = function(
                        module_name, filename, outcome,
                        self_cpu_ms, total_cpu_ms,
                        parse_cpu_ms, check_cpu_ms)
                    profiles[#profiles + 1] = {
                        module_name = module_name,
                        filename = filename,
                        outcome = outcome,
                        self_cpu_ms = self_cpu_ms,
                        total_cpu_ms = total_cpu_ms,
                        parse_cpu_ms = parse_cpu_ms,
                        check_cpu_ms = check_cpu_ms,
                    }
                end,
            })
            consumer_loader = driver.defaultloader({}, {
                context = context,
                source_roots = { ["b.consumer"] = true },
                cached_source_entries = { ["a.provider"] = retained },
            })

            local consumer_ok, _, consumer_errors =
                consumer_loader("b.consumer")
            assert.truthy(consumer_ok)
            assert.equal(0, #consumer_errors,
                table.concat(consumer_errors, "\n"))
            local fresh_header =
                driver.imported["a.provider"].checking_foreign_header
            assert.is_true(paths.is_absolute(fresh_header))
            assert.not_equal(old_header, fresh_header)
            assert.equal(relative_public_header,
                driver.imported["a.provider"].foreign_header)
            assert.equal("file", lfs.attributes(fresh_header, "mode"))
            assert.equal(retained_ast, driver.imported["a.provider"].ast)
            assert.same({ "b.consumer" }, context.checked_source_modules)
            local import = driver.imported["b.consumer"].ast[1]
            assert.equal(fresh_header, import._foreign_header)
            assert.equal(public_header,
                import._foreign_header_probe_identity)
            assert.equal(0, #parsed_generated_headers)

            assert.equal(2, #profiles)
            assert.equal("a.provider", profiles[1].module_name)
            assert.equal(provider_source_filename, profiles[1].filename)
            assert.equal("complete", profiles[1].outcome)
            assert.is_true(
                profiles[1].self_cpu_ms <= profiles[1].total_cpu_ms)
            assert.equal(0, profiles[1].parse_cpu_ms)
            assert.equal(0, profiles[1].check_cpu_ms)
            assert.equal("b.consumer", profiles[2].module_name)
            assert.equal(consumer_source_filename, profiles[2].filename)
            assert.equal("complete", profiles[2].outcome)
            assert.is_true(
                profiles[2].self_cpu_ms <= profiles[2].total_cpu_ms)
            assert.is_true(profiles[2].parse_cpu_ms >= 0)
            assert.is_true(profiles[2].check_cpu_ms >= 0)

            assert.is_true(driver.close_loader(consumer_loader))
            consumer_loader = nil
            assert.is_true(driver.close_resolver_context(context))
            context = nil
            assert.is_nil(lfs.symlinkattributes(fresh_header))
        end, debug.traceback)

        if consumer_loader then pcall(driver.close_loader, consumer_loader) end
        if provider_loader then pcall(driver.close_loader, provider_loader) end
        if provider_context then pcall(driver.close_resolver_context, provider_context) end
        if context then pcall(driver.close_resolver_context, context) end
        driver.TITAN_SOURCE_PATH = previous_source_path
        remove_tree(relative_root)
        assert.truthy(completed, failure)
    end)

    it("publishes each source module before the cooperative I/O checkpoint",
       function()
        local dep_filename = root .. "/dep-generated.titan"
        local main_filename = root .. "/main-generated.titan"
        local strategy = compiler_io.new_sync()
        local yielded_modules = {}
        local profiles = {}
        function strategy:yield(module_name)
            yielded_modules[#yielded_modules + 1] = module_name
            coroutine.yield()
        end
        local context = driver.new_resolver_context({
            io = strategy,
            source_process_trace = function(
                    module_name, filename, outcome,
                    self_cpu_ms, total_cpu_ms,
                    parse_cpu_ms, check_cpu_ms)
                profiles[#profiles + 1] = {
                    module_name = module_name,
                    filename = filename,
                    outcome = outcome,
                    self_cpu_ms = self_cpu_ms,
                    total_cpu_ms = total_cpu_ms,
                    parse_cpu_ms = parse_cpu_ms,
                    check_cpu_ms = check_cpu_ms,
                }
            end,
        })
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
        assert.equal(1, #profiles)
        assert.equal("dep", profiles[1].module_name)
        assert.equal(dep_filename, profiles[1].filename)
        assert.equal("complete", profiles[1].outcome)
        assert.is_true(profiles[1].self_cpu_ms >= 0)
        assert.is_true(
            profiles[1].self_cpu_ms <= profiles[1].total_cpu_ms)
        assert.is_table(driver.imported.dep.ast)
        assert.equal("Ast.TopLevelFunc", driver.imported.dep.ast[1]._tag)
        assert.equal(dep_filename,
            driver.imported.dep.ast[1].loc.filename)
        assert.same({ dep_filename }, driver.imported.dep.source_files)

        -- The importer frame remains live while the dependency checkpoint is
        -- suspended. Advance the process clock by a deterministic two seconds
        -- to model unrelated Task CPU; it must be excluded from main's self
        -- attribution when the source-check Task resumes.
        local real_clock = os.clock
        local resumed_clock = real_clock() + 2
        os.clock = function() return resumed_clock end
        resumed, yielded = coroutine.resume(thread)
        os.clock = real_clock
        assert.truthy(resumed, yielded)
        assert.is_nil(yielded)
        assert.same({ "dep", "main" }, context.checked_source_modules)
        assert.same({ "dep", "main" }, yielded_modules)
        assert.equal(2, #profiles)
        assert.equal("main", profiles[2].module_name)
        assert.equal(main_filename, profiles[2].filename)
        assert.equal("complete", profiles[2].outcome)
        assert.is_true(profiles[2].self_cpu_ms >= 0)
        assert.is_true(
            profiles[2].self_cpu_ms <= profiles[2].total_cpu_ms)
        assert.is_true(profiles[2].parse_cpu_ms >= 0)
        assert.is_true(profiles[2].check_cpu_ms >= 0)
        -- The parent checker was suspended for two seconds after its source
        -- child completed. That checkpoint delta is excluded from check CPU
        -- as well as from the enclosing source self attribution.
        assert.is_true(profiles[2].check_cpu_ms < 1900)
        assert.is_true(
            profiles[2].total_cpu_ms - profiles[1].total_cpu_ms -
                profiles[2].self_cpu_ms > 1900)
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
        local global_includes = driver.foreign_include_dirs()
        local original_descriptor = driver.toolchain_descriptor
        local original_new_service = cprobe.new_service
        local captured = {}
        local contexts = {}
        local completed, failure = xpcall(function()
            driver.toolchain_descriptor = function(resolver)
                return {
                    io = resolver.io,
                    compiler_argv = { "cc" },
                    compile_flags = {},
                    language_mode = "c99",
                    language_flag = false,
                    cppflags = {},
                    cflags = {},
                    include_dirs = { "/compiler/include" },
                }
            end
            cprobe.new_service = function(options)
                captured[#captured + 1] = options.toolchain.include_dirs
                return { close = function() return true end }
            end

            contexts[1] = driver.new_resolver_context()
            contexts[2] = driver.new_resolver_context({
                extra_ffi_include_dirs = { include_root },
            })
            for _, context in ipairs(contexts) do
                context.foreign_c_configuration_id =
                    driver.FOREIGN_C_CONFIGURATION_ID
                assert.is_table(driver.get_probe_service(context))
            end

            assert.same({ "/compiler/include" }, captured[1])
            assert.same({ "/compiler/include", include_root }, captured[2])
            assert.same(global_includes, driver.foreign_include_dirs())
        end, debug.traceback)
        driver.toolchain_descriptor = original_descriptor
        cprobe.new_service = original_new_service
        for _, context in ipairs(contexts) do
            local closed, close_error =
                driver.close_resolver_context(context)
            assert.truthy(closed, close_error)
        end
        assert.truthy(completed, failure)
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
        local observed = process_header_inputs("ffi-outer.h", {
            source_dir = root,
            compiler_include_dirs = {},
            cppflags = { "-I", early, "-I", late },
        })
        assert.is_string(header_input_identity(observed, "file", outer))
        assert.is_string(
            header_input_identity(observed, "file", late_selected))
        assert.is_string(
            header_input_identity(observed, "origin", late_selected))
        assert.is_string(header_input_identity(observed, "search", outer))
        assert.matches("kind=missing",
            header_input_identity(observed, "search", early_selected),
            1, true)
        assert.matches("kind=file",
            header_input_identity(observed, "search", late_selected),
            1, true)
        local restat_io = compiler_io.new_sync()
        local read_paths = {}
        local original_read = restat_io.read_file
        function restat_io:read_file(path)
            read_paths[path] = (read_paths[path] or 0) + 1
            return original_read(self, path)
        end
        local refreshed, restat_error, changed, classified =
            driver.restat_c_header_dependencies(observed, { io = restat_io })
        assert.is_nil(restat_error)
        assert.is_false(changed)
        assert.is_nil(classified)
        assert.same(observed, refreshed)
        -- Precise native Sync observations reuse unchanged headers without reading.
        assert.equal(0, read_paths[outer] or 0)
        assert.equal(0, read_paths[late_selected] or 0)

        write_file(late_selected,
            "typedef long titan_driver_selected_header;\n")
        local restat_context =
            driver.new_resolver_context({ io = restat_io })
        local nested_changed, nested_error, nested_dirty, nested_reason =
            driver.restat_c_header_dependencies(observed, restat_context)
        assert.is_nil(nested_error)
        assert.is_true(nested_dirty)
        assert.equal("c-input " .. late_selected .. ": content", nested_reason)
        assert.not_equal(
            header_input_identity(observed, "file", late_selected),
            header_input_identity(nested_changed, "file", late_selected))

        write_file(late_selected, late_contents)
        write_file(early_selected,
            "typedef short titan_driver_selected_header;\n")
        assert.is_true(driver.close_resolver_context(restat_context))
        restat_context = driver.new_resolver_context({ io = restat_io })
        local shadowed, shadow_error, shadow_dirty, shadow_reason =
            driver.restat_c_header_dependencies(observed, { context = restat_context })
        assert.is_nil(shadow_error)
        assert.is_true(shadow_dirty)
        assert.equal("c-input " .. early_selected .. ": candidate", shadow_reason)
        assert.not_equal(
            header_input_identity(observed, "search", early_selected),
            header_input_identity(shadowed, "search", early_selected))
        assert.is_true(driver.close_resolver_context(restat_context))
    end)

    it("restats exact symlinked include spellings after retargeting",
    function()
        local available, message = require("spec.support.filesystem").symlink_capability()
        if not available then pending(message); return end
        local first = root .. "/ffi-link-first"
        local second = root .. "/ffi-link-second"
        local lexical = root .. "/include"
        local link = root .. "/ffi-sdk-link"
        local outer = root .. "/ffi-link-outer.h"
        -- Win32 normalizes dots lexically; POSIX traverses the link before '..'.
        local selected_lookup = platform.windows
            and lexical .. "/ffi-selected.h"
            or link .. "/../include/ffi-selected.h"
        local selected_contents = [[
#define TITAN_LINK_VALUE 42
typedef int titan_driver_symlink_value;
]]

        local completed, failure = pcall(function()
            assert(lfs.mkdir(first))
            assert(lfs.mkdir(first .. "/nested"))
            assert(lfs.mkdir(first .. "/include"))
            assert(lfs.mkdir(second))
            assert(lfs.mkdir(second .. "/nested"))
            assert(lfs.mkdir(second .. "/include"))
            assert(lfs.mkdir(lexical))
            assert(lfs.link(platform.windows and first .. "/nested"
                or "ffi-link-first/nested", link, true))
            write_file(outer, "#include <ffi-selected.h>\n")
            write_file(first .. "/include/ffi-selected.h", selected_contents)
            write_file(second .. "/include/ffi-selected.h", selected_contents)
            write_file(lexical .. "/ffi-selected.h", [[
#define TITAN_LINK_VALUE 17
typedef double titan_driver_symlink_value;
]])

            local observed = process_header_inputs("ffi-link-outer.h", {
                source_dir = root,
                compiler_include_dirs = {},
                cppflags = { "-I", link .. "/../include" },
            })
            local first_file =
                header_input_identity(observed, "file", selected_lookup)
            local first_search =
                header_input_identity(observed, "search", selected_lookup)
            local first_origin =
                header_input_identity(observed, "origin", selected_lookup)
            assert.is_string(first_file)
            assert.is_string(first_search)
            assert.is_string(first_origin)

            if platform.windows then
                assert(lfs.rmdir(link))
            else
                assert(os.remove(link))
            end
            assert(lfs.link(platform.windows and second .. "/nested"
                or "ffi-link-second/nested", link, true))
            local restatted, restat_error, changed, reason =
                driver.restat_c_header_dependencies(observed)
            assert.is_nil(restat_error)
            assert.equal(first_file,
                header_input_identity(restatted, "file", selected_lookup))
            assert.equal(first_search,
                header_input_identity(restatted, "search", selected_lookup))
            if platform.windows then
                assert.is_false(changed)
                assert.is_nil(reason)
                assert.equal(first_origin,
                    header_input_identity(restatted, "origin", selected_lookup))
            else
                assert.is_true(changed)
                assert.equal("c-input " .. selected_lookup .. ": provenance", reason)
                assert.not_equal(first_origin,
                    header_input_identity(restatted, "origin", selected_lookup))
            end

            write_file(platform.windows and selected_lookup
                or second .. "/include/ffi-selected.h",
                "typedef long titan_driver_symlink_value;\n")
            local content_restatted, content_error, content_changed, content_reason =
                driver.restat_c_header_dependencies(restatted)
            assert.is_nil(content_error)
            assert.is_true(content_changed)
            assert.equal("c-input " .. selected_lookup .. ": content", content_reason)
            assert.not_equal(first_file,
                header_input_identity(content_restatted, "file", selected_lookup))
        end)
        local removed, remove_error = true
        if lfs.symlinkattributes(link, "mode") then
            if platform.windows then
                removed, remove_error = lfs.rmdir(link)
            else
                removed, remove_error = os.remove(link)
            end
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
        write_file(first .. provider_path("/a/b/c.so"), "earlier exact\n")
        write_file(second .. provider_path("/a.so"), "later shallow\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        mock_native_abi(first .. provider_path("/a/b/c.so"), { ["a.b.c"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(first .. provider_path("/a/b/c.so"), filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            elseif symbol == "a_b_c_layouts" then
                return function() return empty_layouts("a.b.c") end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({}, resolver_options())("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(provider_path("a/b/c.so"), modtype.file)
        assert.equal(first .. provider_path("/a/b/c.so"),
            driver.imported["a.b.c"].filename)
    end)

    it("applies the selected format preference globally across path roots",
       function()
        local first = root .. "/first"
        local second = root .. "/second"
        assert(lfs.mkdir(first))
        assert(lfs.mkdir(second))
        local archive = first .. "/choice.a"
        local dynamic = second .. provider_path("/choice.so")
        write_file(dynamic, "later dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local static_context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(static_context, archive, {
            choice = types.Module("choice", {}),
        })
        mock_native_abi(dynamic, { choice = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(dynamic, filename)
            if symbol == "choice_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "choice_types" then
                return function() return "Module('choice',{})" end
            elseif symbol == "choice_layouts" then
                return function() return empty_layouts("choice") end
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
        assert.equal(provider_path("choice.so"), modtype.file)
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
        local dynamic_nonclaim = first .. provider_path("/mixed.so")
        local archive = second .. "/mixed.a"
        write_file(dynamic_nonclaim, "unrelated dynamic provider\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local context = driver.new_resolver_context()
        cache_static_provider(context, archive, {
            ["mixed.child"] = types.Module("mixed.child", {}),
        })
        mock_native_abi(dynamic_nonclaim, {  })
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
        local dynamic = binary .. provider_path("/empty.so")
        write_file(dynamic, "must not be inspected\n")
        local context =
            driver.new_resolver_context({ prefer_static = true })
        cache_static_provider(context, archive, {})
        titan._loadlib = function()
            error("an exact static nonclaim must not fall through")
        end
        titan._abivalue = titan._loadlib

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
        local dynamic = binary .. provider_path("/archive_bad.so")
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
            titan._abivalue = titan._loadlib

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

    it("validates cached dynamic owner bindings per importing object", function()
        local owner = types.Module("binding_owner", {})
        owner.file = provider_path("binding_owner.so")
        driver.imported.binding_owner = {
            kind = "dynamic", type = owner, filename = binary .. provider_path("/binding_owner.so"),
        }
        driver.imported.direct_user = {
            kind = "source", type = types.Module("direct_user", {}),
            object_metadata = {
                imports = {{ name = "binding_owner", source_required = false }},
                bindings = { binding_owner = "handle" },
                providers = { binding_owner = provider_path("binding_owner.so") },
            },
        }
        driver.imported.indirect_user = {
            kind = "source", type = types.Module("indirect_user", {}),
            object_metadata = {
                imports = {}, bindings = { binding_owner = "global" }, providers = {},
            },
        }
        local context = driver.new_resolver_context()
        local finalized, errors = driver.finalize_resolver_context(context)
        assert.truthy(finalized, errors and table.concat(errors, "\n"))
        assert.equal("handle", context.native_bindings.binding_owner)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects unresolved cached global owners", function()
        driver.imported.indirect_user = {
            kind = "source", type = types.Module("indirect_user", {}),
            object_metadata = {
                imports = {}, bindings = { missing_owner = "global" }, providers = {},
            },
        }
        local context = driver.new_resolver_context()
        local finalized, errors = driver.finalize_resolver_context(context)
        assert.falsy(finalized)
        assert.matches("requires global binding for 'missing_owner'",
            table.concat(errors, "\n"), 1, true)
        assert.is_true(driver.close_resolver_context(context))
    end)

    it("rejects changed providers for cached imported handles", function()
        local owner = types.Module("binding_owner", {})
        owner.file = provider_path("replacement/binding_owner.so")
        driver.imported.binding_owner = {
            kind = "dynamic", type = owner, filename = binary .. provider_path("/replacement.so"),
        }
        driver.imported.direct_user = {
            kind = "source", type = types.Module("direct_user", {}),
            object_metadata = {
                imports = {{ name = "binding_owner", source_required = false }},
                bindings = { binding_owner = "handle" },
                providers = { binding_owner = provider_path("original/binding_owner.so") },
            },
        }
        local context = driver.new_resolver_context()
        local finalized, errors = driver.finalize_resolver_context(context)
        assert.falsy(finalized)
        assert.matches("loads a different provider for 'binding_owner'",
            table.concat(errors, "\n"), 1, true)
        assert.is_true(driver.close_resolver_context(context))
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
        write_file(first .. provider_path("/a.so"), "earlier nonclaim\n")
        write_file(second .. provider_path("/a.so"), "later claim must be shadowed\n")
        write_file(second .. provider_path("/a/b.so"), "later unshadowed claim\n")
        driver.TITAN_BIN_PATH = first .. ";" .. second

        local inspected = {}
        mock_native_abi(first .. provider_path("/a.so"), {})
        mock_native_abi(second .. provider_path("/a/b.so"), { ["a.b.c"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            inspected[filename] = true
            if filename == first .. provider_path("/a.so") then
                return nil, "undefined symbol: " .. symbol, "init"
            end
            assert.equal(second .. provider_path("/a/b.so"), filename)
            if symbol == "a_b_c_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "a_b_c_types" then
                return function() return "Module('a.b.c',{})" end
            elseif symbol == "a_b_c_layouts" then
                return function() return empty_layouts("a.b.c") end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({}, resolver_options())("a.b.c")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(provider_path("a/b.so"), modtype.file)
        assert.equal(second .. provider_path("/a/b.so"),
            driver.imported["a.b.c"].filename)
        assert.is_nil(inspected[second .. provider_path("/a.so")])
    end)

    it("treats half metadata as a terminal container claim", function()
        write_file(binary .. provider_path("/titan.so"), "partial shallow claim\n")
        write_file(binary .. provider_path("/titan/timer.so"), "valid exact claim\n")
        local exact_probed = false
        mock_native_abi(binary .. provider_path("/titan.so"), { ["titan.timer"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            if filename == binary .. provider_path("/titan/timer.so") then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. provider_path("/titan.so"), filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({}, resolver_options())("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_types", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats types-only metadata as a terminal container claim", function()
        write_file(binary .. provider_path("/titan.so"), "partial shallow claim\n")
        write_file(binary .. provider_path("/titan/timer.so"), "valid exact claim\n")
        local exact_probed = false
        mock_native_abi(binary .. provider_path("/titan.so"), {  })
        titan._loadlib = function(filename, symbol)
            if filename == binary .. provider_path("/titan/timer.so") then
                exact_probed = true
                error("a deeper candidate must not hide a partial claim")
            end
            assert.equal(binary .. provider_path("/titan.so"), filename)
            if symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({}, resolver_options())("titan.timer")
        assert.falsy(ok)
        assert.match("claims module 'titan.timer'", message, 1, true)
        assert.match("titan_timer_abi", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("rejects a wrong ABI before executing types metadata", function()
        write_file(binary .. provider_path("/titan.so"), "stale shallow claim\n")
        write_file(binary .. provider_path("/titan/timer.so"), "valid exact claim\n")
        local types_executed = false
        local exact_probed = false
        mock_native_abi(binary .. provider_path("/titan.so"), { ["titan.timer"] = "stale" })
        titan._loadlib = function(filename, symbol)
            if filename == binary .. provider_path("/titan/timer.so") then
                exact_probed = true
                error("a deeper candidate must not hide a stale claim")
            end
            assert.equal(binary .. provider_path("/titan.so"), filename)
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

        local ok, message = driver.defaultloader({}, resolver_options())("titan.timer")
        assert.falsy(ok)
        assert.match("ABI mismatch", message, 1, true)
        assert.match("but found stale", message, 1, true)
        assert.is_false(types_executed)
        assert.is_false(exact_probed)
    end)

    it("rejects invalid metadata results without falling through", function()
        write_file(binary .. provider_path("/meta.so"), "invalid metadata claims\n")

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
            mock_native_abi(binary .. provider_path("/meta.so"), { [case.name] = driver.TITAN_ABI_VERSION })
            titan._loadlib = function(filename, symbol)
                assert.equal(binary .. provider_path("/meta.so"), filename)
                if symbol == driver.mangle_module_name(case.name) .. "_abi" then
                    return case.abi
                elseif symbol == driver.mangle_module_name(case.name) ..
                                  "_types" then
                    return case.metadata
                end
                error("unexpected metadata symbol " .. symbol)
            end

            local ok, message = driver.defaultloader({}, resolver_options())(case.name)
            assert.falsy(ok)
            assert.match(case.expected, message, 1, true)
            if case.retains_claim then
                assert.match(binary .. provider_path("/meta.so"), message, 1, true)
                assert.match(case.name, message, 1, true)
            end
            assert.is_nil(driver.imported[case.name])
        end
    end)

    it("rejects metadata for a different logical module", function()
        write_file(binary .. provider_path("/titan.so"), "mismatched shallow claim\n")
        write_file(binary .. provider_path("/titan/timer.so"), "valid exact claim\n")
        local exact_probed = false
        mock_native_abi(binary .. provider_path("/titan.so"), { ["titan.timer"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            if filename == binary .. provider_path("/titan/timer.so") then
                exact_probed = true
                error("a deeper candidate must not hide mismatched metadata")
            end
            assert.equal(binary .. provider_path("/titan.so"), filename)
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.other',{})" end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, message = driver.defaultloader({}, resolver_options())("titan.timer")
        assert.falsy(ok)
        assert.match("returned type metadata for 'titan.other'", message,
            1, true)
        assert.match("while loading module 'titan.timer'", message, 1, true)
        assert.is_false(exact_probed)
    end)

    it("treats a candidate open failure as a terminal error", function()
        write_file(binary .. provider_path("/titan.so"), "broken shallow image\n")
        write_file(binary .. provider_path("/titan/timer.so"), "valid exact claim\n")
        local symbols = {}
        mock_native_abi(binary .. provider_path("/titan.so"), {
            ["titan.timer"] = function() return nil, "broken image", "open" end,
        })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/titan.so"), filename)
            table.insert(symbols, symbol)
            return nil, "broken image", "open"
        end

        local ok, message = driver.defaultloader({}, resolver_options())("titan.timer")
        assert.falsy(ok)
        assert.match("cannot inspect compiled module 'titan.timer'", message,
            1, true)
        assert.match("broken image", message, 1, true)
        assert.same(platform.windows and {} or { "titan_timer_abi" }, symbols)
    end)

    it("uses the first valid claim without probing a duplicate", function()
        assert(lfs.mkdir(binary .. "/dup"))
        write_file(binary .. provider_path("/dup.so"), "shallow claim\n")
        write_file(binary .. provider_path("/dup/item.so"), "duplicate exact claim\n")
        local symbols = {}
        mock_native_abi(binary .. provider_path("/dup.so"), { ["dup.item"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/dup.so"), filename)
            table.insert(symbols, symbol)
            if symbol == "dup_item_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "dup_item_types" then
                return function() return "Module('dup.item',{})" end
            elseif symbol == "dup_item_layouts" then
                return function() return empty_layouts("dup.item") end
            end
            error("unexpected metadata symbol " .. symbol)
        end

        local ok, modtype, errors = driver.defaultloader({}, resolver_options())("dup.item")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(provider_path("dup.so"), modtype.file)
        assert.equal(binary .. provider_path("/dup.so"),
            driver.imported["dup.item"].filename)
        assert.same({ "dup_item_abi", "dup_item_types", "dup_item_layouts" }, symbols)
    end)

    it("caches two logical interfaces from one physical container separately",
       function()
        write_file(binary .. provider_path("/bundle.so"), "two logical interfaces\n")
        local functions = {
            bundle_left_abi = function() return driver.TITAN_ABI_VERSION end,
            bundle_left_types = function()
                return "Module('bundle.left',{})"
            end,
            bundle_left_layouts = function() return empty_layouts("bundle.left") end,
            bundle_right_abi = function() return driver.TITAN_ABI_VERSION end,
            bundle_right_types = function()
                return "Module('bundle.right',{})"
            end,
            bundle_right_layouts = function() return empty_layouts("bundle.right") end,
        }
        local symbols = {}
        mock_native_abi(binary .. provider_path("/bundle.so"), { ["bundle.left"] = driver.TITAN_ABI_VERSION, ["bundle.right"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/bundle.so"), filename)
            table.insert(symbols, symbol)
            return assert(functions[symbol], "unexpected metadata symbol")
        end

        local loader = driver.defaultloader({}, resolver_options())
        local left_ok, left, left_errors = loader("bundle.left")
        local right_ok, right, right_errors = loader("bundle.right")
        assert.truthy(left_ok)
        assert.truthy(right_ok)
        assert.equal(0, #left_errors)
        assert.equal(0, #right_errors)
        assert.not_equal(left, right)
        assert.not_equal(driver.imported["bundle.left"],
            driver.imported["bundle.right"])
        assert.equal(provider_path("bundle.so"), left.file)
        assert.equal(provider_path("bundle.so"), right.file)
        assert.equal(binary .. provider_path("/bundle.so"),
            driver.imported["bundle.left"].filename)
        assert.equal(binary .. provider_path("/bundle.so"),
            driver.imported["bundle.right"].filename)
        assert.same({
            "bundle_left_abi", "bundle_left_types", "bundle_left_layouts",
            "bundle_right_abi", "bundle_right_types", "bundle_right_layouts",
        }, symbols)
        local call_count = #symbols
        local cached_ok, cached_left, cached_errors = loader("bundle.left")
        assert.truthy(cached_ok)
        assert.equal(left, cached_left)
        assert.equal(0, #cached_errors)
        assert.equal(call_count, #symbols)
    end)

    it("falls back to source after clean ancestor nonclaims", function()
        write_file(binary .. provider_path("/titan.so"), "unrelated extension\n")
        write_file(source .. "/titan/fallback.titan", [[
            function marker(): integer return 17 end
        ]])
        mock_native_abi(binary .. provider_path("/titan.so"), {  })
        titan._loadlib = function(_, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, modtype, errors = driver.defaultloader({}, resolver_options())("titan.fallback")
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

        local ok, modtype, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")

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

        local ok, modtype, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.interfaces"] = true },  }))("titan.interfaces")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = {
            ["titan.interface_mismatch"] = true,
        },  }))("titan.interface_mismatch")
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
        local loader = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))
        local ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(source .. "/titan/sample.titan",
            paths.to_slash(driver.imported["titan.sample"].filename))
        assert.equal("titan/sample",
            driver.imported["titan.sample"].program_output)

        driver.imported = {}
        types.registry = {}
        driver.TITAN_SOURCE_PATH = later .. ";" .. source
        loader = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))
        ok, _, errors = loader("titan.sample")
        assert.truthy(ok)
        assert.equal(0, #errors)
        assert.equal(later .. "/titan/sample/sample.titan",
            paths.to_slash(driver.imported["titan.sample"].filename))
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

        local child_loader = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample.child"] = true },  }))
        local ok, message = child_loader("titan.sample.child")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.child' cannot be loaded directly",
            message, 1, true)
        assert.match(folder .. "/child.titan", message, 1, true)
        assert.match("folder module 'titan.sample'", message, 1, true)
        assert.match(folder .. "/sample.titan", message, 1, true)

        ok, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample.sample"] = true },  }))("titan.sample.sample")
        assert.falsy(ok)
        assert.match("source module 'titan.sample.sample' cannot be loaded directly",
            message, 1, true)

        assert(lfs.mkdir(folder .. "/child"))
        write_file(folder .. "/child/child.titan", [[
            function distinct(): integer
                return 2
            end
        ]])
        ok, _, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample.child"] = true },  }))("titan.sample.child")
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

        local ok, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample.child"] = true },  }))("titan.sample.child")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample.child"] = true },  }))("titan.sample.child")
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
        local child_binary = binary .. provider_path("/titan/sample/child.so")
        write_file(child_binary, "mock interface\n")

        mock_native_abi(child_binary, { ["titan.sample.child"] = driver.TITAN_ABI_VERSION })
        titan._loadlib = function(filename, symbol)
            assert.equal(child_binary, filename)
            if symbol == "titan_sample_child_abi" then
                return function() return driver.TITAN_ABI_VERSION end
            elseif symbol == "titan_sample_child_types" then
                return function()
                    return "Module('titan.sample.child',{})"
                end
            elseif symbol == "titan_sample_child_layouts" then
                return function() return empty_layouts("titan.sample.child") end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({}, resolver_options())("titan.sample.child")
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
        local called, ok, message = pcall(driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  })), "titan.sample")
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

        local ok, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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

        local called, ok, message = pcall(driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  })), "titan.sample")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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

        local ok, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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
        local loader = driver.defaultloader(static_deps, resolver_options({ source_roots = { ["titan.sample"] = true },  }))
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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

        local ok, _, errors = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.sample"] = true },  }))("titan.sample")
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
        local loader = driver.defaultloader({}, resolver_options({ source_roots = source_roots,  }))

        for _, name in ipairs(malformed) do
            local called, ok, message = pcall(loader, name)
            assert.truthy(called)
            assert.falsy(ok)
            assert.match(
                "invalid logical Titan module name", message, 1, true)
        end

        local provider, message = driver.provider_output_path("provider$line")
        assert.falsy(provider)
        assert.match("invalid library provider name", message, 1, true)
    end)

    it("requires source for an explicit build root", function()
        write_file(binary .. provider_path("/titan/timer.so"), "existing binary\n")
        titan._loadlib = function()
            error("an explicit source build must not load its existing binary")
        end
        titan._abivalue = titan._loadlib

        local ok, message = driver.defaultloader({}, resolver_options({ source_roots = { ["titan.timer"] = true },  }))("titan.timer")

        assert.falsy(ok)
        assert.equal("source module 'titan.timer' not found", message)
        assert.is_nil(driver.imported["titan.timer"])
    end)

    it("reports a missing ABI entry from the internal loader", function()
        write_file(binary .. provider_path("/extension.so"), "mock image\n")
        local symbols = {}
        mock_native_abi(binary .. provider_path("/extension.so"), {  })
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. provider_path("/extension.so"), filename)
            table.insert(symbols, symbol)
            return nil, "undefined symbol: " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({}, resolver_options())("extension")
        assert.falsy(ok)
        assert.match("has no compatible Titan ABI marker", message)
        assert.same({ "extension_abi", "extension_types" }, symbols)
    end)

    it("records a cached table-loader import as a dependency", function()
        local modtype = types.Module("cached", {})
        local imported = { cached = { type = modtype } }
        local deps = {}

        local ok, loaded, errors =
            driver.tableloader({}, imported, deps, resolver_options())("cached")

        assert.truthy(ok)
        assert.equal(modtype, loaded)
        assert.equal(0, #errors)
        assert.equal(true, deps.cached)
    end)

    it("rejects a table source view after using a different cached interface",
    function()
        local compiled = types.Module("cached", {
            types.ModuleMember("cached", "answer",
                types.Function({}, { types.Integer() }, false, nil, nil),
                {}),
        })
        local imported = {
            cached = { kind = "dynamic", type = compiled },
        }
        local loader = driver.tableloader({
            cached = [[
                function answer(): string return "source" end
            ]],
        }, imported, nil, resolver_options())

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

describe("Darwin dSYM execution selection", function()
    local subject, context, root, previous, commands, selections, dsym_result
    local cpp = require "c-parser.cpp"

    before_each(function()
        previous = nil
        if platform.windows then return end
        previous = {
            execute = os.execute, getenv = platform.getenv,
            physical = incremental.physical_executable,
            toolchain = incremental.toolchain_identity,
            cwd = assert(lfs.currentdir()),
        }
        root = temporary.name("-darwin-selection")
        assert(lfs.mkdir(root))
        root = assert(compiler_io.new_sync():realpath(root))
        local loaded_driver = package.loaded["titan-compiler.driver"]
        package.loaded["titan-compiler.driver"] = nil
        local loaded, value = pcall(require, "titan-compiler.driver")
        package.loaded["titan-compiler.driver"] = loaded_driver
        assert.is_true(loaded, value)
        subject = value
        context = subject.new_resolver_context()
        context._platform_initialized, context.uname, context.is_darwin =
            true, "Darwin", true
        subject.UNAME, subject.IS_DARWIN = "Darwin", true
        subject.CC, subject.CFLAGS = "native-compiler", ""
        -- This isolated driver models commands, not runtime preparation.
        subject.INSTALLED, subject.OUTPUT_LOCKS = true, nil
        commands, selections, dsym_result = {}, {}, nil
        incremental.toolchain_identity = function()
            return "independent-compiler-proof", { stage_policy = "llvm" }
        end
        incremental.physical_executable = function(_, command)
            assert.equal("dsymutil", command)
            selections[#selections + 1] = assert(lfs.currentdir())
            return nil, "Darwin executable search policy is unknown", "uncertified"
        end
        os.execute = function(command)
            local argv = assert(cpp.split_shell_words(command))
            local invocation = { argv = argv, cwd = assert(lfs.currentdir()) }
            commands[#commands + 1] = invocation
            if argv[1] == "native-compiler" then
                for index, argument in ipairs(argv) do
                    if argument == "-o" then
                        invocation.output = argv[index + 1]
                        write_file(invocation.output, "native image fixture\n")
                        return true, "exit", 0
                    end
                end
                error("native command has no output")
            end
            assert.is_true(argv[1] == "dsymutil" or
                argv[1] == root .. "/tools with spaces/dsymutil")
            if dsym_result then return table.unpack(dsym_result, 1, 3) end
            local output = argv[2]
            if not platform.is_absolute(output) then
                output = paths.join(invocation.cwd, output)
            end
            local bundle = output .. ".dSYM"
            assert(lfs.mkdir(bundle))
            assert(lfs.mkdir(bundle .. "/Contents"))
            assert(lfs.mkdir(bundle .. "/Contents/Resources"))
            assert(lfs.mkdir(bundle .. "/Contents/Resources/DWARF"))
            write_file(bundle .. "/Contents/Resources/DWARF/" ..
                paths.basename(output), "debug fixture\n")
            return true, "exit", 0
        end
    end)

    after_each(function()
        if not previous then return end
        if subject and context then subject.close_resolver_context(context) end
        os.execute, platform.getenv = previous.execute, previous.getenv
        incremental.physical_executable = previous.physical
        incremental.toolchain_identity = previous.toolchain
        assert(lfs.chdir(previous.cwd))
        remove_tree(root)
        subject, context = nil, nil
    end)

    local function compile_program(executable)
        return subject.compile_program("darwin_selection", {}, nil, false, {},
            root .. "/program", {}, root .. "/entry.c", nil, {
                no_uv_bootstrap = true, dsymutil = executable,
            })
    end

    local function assert_raw_execution()
        local invocation = commands[#commands]
        assert.equal("dsymutil", invocation.argv[1])
        assert.equal(previous.cwd, invocation.cwd)
        assert.is_true(platform.is_absolute(invocation.argv[2]))
        assert.equal(previous.cwd, lfs.currentdir())
    end

    it("keeps an unset PATH uncertified through output planning and standalone publication", function()
        if platform.windows then pending("Darwin POSIX launch behavior"); return end
        incremental.physical_executable = previous.physical
        platform.getenv = function(name)
            if name == "PATH" then return nil end
            return previous.getenv(name)
        end
        local request = assert(subject.output_tool_descriptors(context, "program"))
        assert.same({ "dsymutil" }, request.tools.dsymutil)
        assert.is_string(request.uncacheable)
        assert.equal("independent-compiler-proof", request.toolchain)
        assert.is_nil(context.incremental_uncertified)
        local tools = assert(require("titan-compiler.linkcertificate").output_tools(
            context, request))
        assert.equal(request.uncacheable, tools.uncertified)
        local ok, term, code = compile_program(request.tools.dsymutil[1])
        assert.is_true(ok, tostring(term) .. ": " .. tostring(code))
        assert_raw_execution()
        assert.equal("file", lfs.attributes(root .. "/program", "mode"))
        assert.equal("file", lfs.attributes(root ..
            "/program.dSYM/Contents/Resources/DWARF/program", "mode"))
    end)

    it("runs a directly requested uncertified standalone dSYM without changing lookup cwd", function()
        if platform.windows then pending("Darwin POSIX launch behavior"); return end
        local ok, term, code = compile_program()
        assert.is_true(ok, tostring(term) .. ": " .. tostring(code))
        assert.same({ previous.cwd }, selections)
        assert_raw_execution()
    end)

    for _, case in ipairs({
        { name = "ordinary library", stable = false },
        { name = "staged provider", stable = true },
    }) do
        it("keeps raw " .. case.name .. " dSYM lookup in the original cwd", function()
            if platform.windows then pending("Darwin POSIX launch behavior"); return end
            local output = root .. "/private/provider.so"
            local ok, term, code = subject.compile_library_output(
                output, {}, nil, false, {}, {}, nil,
                case.stable and root .. "/public.so" or nil, { "provider" })
            assert.is_true(ok, tostring(term) .. ": " .. tostring(code))
            assert.same({ previous.cwd }, selections)
            assert_raw_execution()
            assert.equal(output, commands[#commands].argv[2])
        end)
    end

    it("retains the admitted absolute spelling and stable leaf for certified execution", function()
        if platform.windows then pending("Darwin POSIX launch behavior"); return end
        local admitted = root .. "/tools with spaces/dsymutil"
        incremental.physical_executable = function(_, command)
            assert.equal("dsymutil", command)
            selections[#selections + 1] = assert(lfs.currentdir())
            return "canonical-physical-tool-identity", admitted
        end
        local request = assert(subject.output_tool_descriptors(context, "program"))
        assert.same({ admitted }, request.tools.dsymutil)
        assert.is_nil(request.uncacheable)
        local ok, term, code = compile_program(request.tools.dsymutil[1])
        assert.is_true(ok, tostring(term) .. ": " .. tostring(code))
        assert.same({ previous.cwd }, selections)
        local invocation = commands[#commands]
        local linked = commands[#commands - 1]
        assert.equal(admitted, invocation.argv[1])
        assert.equal(paths.dirname(linked.output), invocation.cwd)
        assert.equal(paths.basename(linked.output), invocation.argv[2])
        assert.equal(previous.cwd, lfs.currentdir())
    end)

    for _, case in ipairs({
        { name = "ordinary returned failure", select = function()
            return nil, "cannot read the dSYM executable"
        end },
        { name = "raised I/O failure", select = function()
            error("cannot read the dSYM executable", 0)
        end },
    }) do
        it("does not turn a dSYM " .. case.name .. " into raw execution", function()
            if platform.windows then pending("Darwin POSIX launch behavior"); return end
            incremental.physical_executable = case.select
            local request, descriptor_error =
                subject.output_tool_descriptors(context, "program")
            assert.is_nil(request)
            assert.equal("cannot read the dSYM executable", descriptor_error)
            local ok, execution_error = compile_program()
            assert.is_nil(ok)
            assert.equal("cannot read the dSYM executable", execution_error)
            for _, invocation in ipairs(commands) do
                assert.equal("native-compiler", invocation.argv[1])
            end
            assert.equal(previous.cwd, lfs.currentdir())
            assert.is_nil(lfs.attributes(root .. "/program"))
        end)
    end

    it("preserves selector cancellation identity at descriptor and standalone boundaries", function()
        if platform.windows then pending("Darwin POSIX launch behavior"); return end
        local cancellation = {}
        incremental.physical_executable = function() error(cancellation, 0) end
        local completed, raised = pcall(subject.output_tool_descriptors,
            context, "program")
        assert.is_false(completed)
        assert.equal(cancellation, raised)
        completed, raised = pcall(compile_program)
        assert.is_false(completed)
        assert.equal(cancellation, raised)
        assert.equal(previous.cwd, lfs.currentdir())
        assert.is_nil(lfs.attributes(root .. "/program"))
    end)

    it("preserves operational failure of a legitimately raw dSYM command", function()
        if platform.windows then pending("Darwin POSIX launch behavior"); return end
        dsym_result = { false, "exit", 23 }
        local ok, term, code = compile_program()
        assert.is_nil(ok)
        assert.equal("exit", term)
        assert.equal(23, code)
        assert_raw_execution()
        assert.is_nil(lfs.attributes(root .. "/program"))
        assert.is_nil(lfs.attributes(root .. "/program.dSYM"))
    end)
end)

describe("Windows link response files", function()
    local process = require "titan-compiler.process"
    local previous, response

    before_each(function()
        response = temporary.name("-native-link.rsp")
        os.remove(response)
        previous = {
            windows = platform.windows, cc = driver.CC, getenv = platform.getenv,
            reserve = driver.sibling_temporary_path,
            execute = os.execute, process_run = process.run,
            print = _G.print, stderr = io.stderr,
            remove = os.remove,
        }
        platform.windows = true
        driver.CC = 'ccache "C:/compiler tools/clang.exe"'
        driver.sibling_temporary_path = function() return response end
    end)

    after_each(function()
        platform.windows = previous.windows
        driver.CC = previous.cc
        driver.sibling_temporary_path = previous.reserve
        os.execute = previous.execute
        process.run = previous.process_run
        _G.print = previous.print
        io.stderr = previous.stderr
        os.remove = previous.remove
        platform.getenv = previous.getenv
        os.remove(response)
    end)

    it("renders GNU response quotes rather than cmd escapes with exact LF bytes", function()
        local contents = assert(platform.windows_response_contents({
            "", "plain.o", [=[C:\long path\file.o]=], [=[quote"inside.o]=],
            [=[trailing\]=], [=[a\"b]=], "%!^&|; ℙ.o",
            "single'quote.o", "tab\tchar.o", "@flag",
        }))
        assert.equal([=[""
"plain.o"
"C:\\long path\\file.o"
"quote\"inside.o"
"trailing\\"
"a\\\"b"
"%!^&|; ℙ.o"
"single'quote.o"
"tab	char.o"
"@flag"
]=], contents)
    end)

    it("rejects malformed arrays and command bytes before publication", function()
        for _, arguments in ipairs({
            {}, { "nul\0.o" }, { "line\nbreak.o" }, { "carriage\rreturn.o" },
            { "\255.o" }, { "valid.o", extra = "not an argument" },
        }) do
            local contents, err = platform.windows_response_contents(arguments)
            assert.is_nil(contents)
            assert.is_string(err)
        end
    end)

    it("rejects invalid argv and a different CC prefix before publication", function()
        driver.sibling_temporary_path = function() error("response must not be reserved") end
        os.execute = function() error("link must not launch") end
        process.run = function() error("link must not launch") end
        for _, case in ipairs({
            { "nonempty argument array", nil },
            { "nonempty argument array", false },
            { "nonempty argument array", "not argv" },
            { "nonempty argument array", {} },
            { "dense argument array", {
                "ccache", "C:/compiler tools/clang.exe", [4] = "input.o",
            } },
            { "dense argument array", {
                "ccache", "C:/compiler tools/clang.exe", "input.o", extra = true,
            } },
            { "dense argument array", {
                "ccache", "C:/compiler tools/clang.exe", "input.o", [1.5] = true,
            } },
            { "configured CC command prefix", { "other", "cc", "input.o" } },
            { "configured CC command prefix", { "ccache", "other.exe", "input.o" } },
            { "configured CC command prefix", { "ccache" } },
        }) do
            local ok, err = driver.run_link_command(case[2], false, "result.dll")
            assert.is_nil(ok)
            assert.matches(case[1], err, 1, true)
        end
    end)

    for _, case in ipairs({ { "successful", true, 0 }, { "failed", false, 23 } }) do
        it("bounds the shell command and cleans a " .. case[1] .. " link", function()
            local argv = { "ccache", "C:/compiler tools/clang.exe", "-shared", "-o", "result.dll" }
            for index = 1, 300 do
                argv[#argv + 1] = "C:/a long generated output directory/module" .. index .. ".o"
            end
            local contents = assert(platform.windows_response_contents({ table.unpack(argv, 3) }))
            assert.is_true(#contents > 8191)
            local printed = {}
            io.stderr = {
                write = function(_, line)
                    printed[#printed + 1] = tostring(line)
                    return true
                end,
            }
            os.execute = function() error("Windows link must use process.run") end
            process.run = function(launched_argv)
                local command = assert(platform.windows_command(launched_argv, false))
                assert.is_true(#command < 1024)
                assert.truthy(command:find("@", 1, true))
                assert.truthy(command:find("compiler", 1, true))
                assert.falsy(command:find("module300.o", 1, true))
                local file = assert(io.open(response, "rb"))
                local bytes = file:read("a")
                assert(file:close())
                assert.equal(contents, bytes)
                return case[2] or nil, "exit", case[3]
            end
            local ok, term, code = driver.run_link_command(argv, true, "result.dll")
            assert.equal(case[2] or nil, ok)
            assert.equal("exit", term)
            assert.equal(case[3], code)
            assert.equal(2, #printed)
            assert.truthy(printed[1]:find("module300.o", 1, true))
            assert.truthy(printed[2]:find("@", 1, true))
            assert.is_nil(lfs.attributes(response))
        end)
    end

    for _, case in ipairs({ { "successful", true, 0 }, { "failed", false, 23 } }) do
        it("reports response removal failure after a " .. case[1] .. " link", function()
            os.execute = function() error("Windows link must use process.run") end
            process.run = function() return case[2] or nil, "exit", case[3] end
            os.remove = function(filename)
                if filename == response then return nil, "injected removal failure" end
                return previous.remove(filename)
            end
            local ok, err, code = driver.run_link_command({
                "ccache", "C:/compiler tools/clang.exe", "input.o",
            }, false, "result.dll")
            assert.is_nil(ok)
            assert.equal(case[3], code)
            assert.equal((case[2] and "" or "exit; ") ..
                "failed to remove link response file '" .. response ..
                "': injected removal failure", err)
            assert.equal("file", lfs.attributes(response, "mode"))
        end)
    end

    it("reserves the real response beside the output and removes it", function()
        driver.sibling_temporary_path = previous.reserve
        if not previous.windows then platform.getenv = os.getenv end
        local output = paths.basename(response) .. ".dll"
        local prefix = output .. ".link.rsp.tmp."
        os.execute = function() error("Windows link must use process.run") end
        process.run = function(launched_argv)
            local found
            for filename in lfs.dir(".") do
                if filename:sub(1, #prefix) == prefix then
                    assert.is_nil(found)
                    found = filename
                end
            end
            assert.is_string(found)
            response = found
            assert.equal("file", lfs.attributes(response, "mode"))
            assert.same({
                "ccache", "C:/compiler tools/clang.exe", "@" .. response,
            }, launched_argv)
            return true, "exit", 0
        end
        assert.is_true(driver.run_link_command({
            "ccache", "C:/compiler tools/clang.exe", "-shared", "-o", output, "input.o",
        }, false, output))
        assert.is_nil(lfs.attributes(response))
    end)

    it("removes the response file when execution throws", function()
        os.execute = function() error("Windows link must use process.run") end
        process.run = function() error("injected link launch error") end
        local ok, err = driver.run_link_command({
            "ccache", "C:/compiler tools/clang.exe", "input.o",
        }, false, "result.dll")
        assert.is_nil(ok)
        assert.matches("injected link launch error", err, 1, true)
        assert.is_nil(lfs.attributes(response))
    end)

    it("reports response publication failure before launching", function()
        driver.sibling_temporary_path = function() return response .. "/missing.rsp" end
        os.execute = function() error("link must not launch") end
        process.run = function() error("link must not launch") end
        local ok, err = driver.run_link_command({
            "ccache", "C:/compiler tools/clang.exe", "input.o",
        }, false, "result.dll")
        assert.is_nil(ok)
        assert.matches("failed to open link response file", err, 1, true)
    end)

    it("links native Windows object paths beyond the CreateProcess limit", function()
        if not previous.windows then
            pending("native Windows Clang response-file transport")
            return
        end
        driver.CC = previous.cc
        local root = temporary.name("-long link paths"):gsub("\\", "/")
        os.remove(root)
        assert(lfs.mkdir(root))
        local files = {}
        local function write(path, contents)
            files[#files + 1] = path
            assert(util.set_file_contents(path, contents, "wb"))
        end
        local tested, test_error = xpcall(function()
            local source, object = root .. "/empty.c", root .. "/empty.o"
            write(source, "/* A valid object with no duplicate external definitions. */\n")
            local command = assert(cdriver.split_shell_words(driver.CC))
            for _, argument in ipairs({ "-x", "c", "-c", source, "-o", object }) do
                command[#command + 1] = argument
            end
            files[#files + 1] = object
            local result = compiler_io.new_sync():run(command, { stderr_to_stdout = true })
            assert.is_true(result.ok, result.output or result.diagnostic)
            local bytes = assert(util.get_file_contents(object, "rb"))
            local output = root .. "/linked.dll"
            files[#files + 1] = output
            command = assert(cdriver.split_shell_words(driver.CC))
            for _, argument in ipairs({ "-shared", "-o", output }) do
                command[#command + 1] = argument:gsub("/", "\\")
            end
            for index = 1, 300 do
                local name = root .. "/" .. string.rep("long_object_", 7) .. index .. ".o"
                write(name, bytes)
                command[#command + 1] = name:gsub("/", "\\")
            end
            assert.is_true(#table.concat(command, " ") > 32767)
            local ok, term, code = driver.run_link_command(command, false, output)
            assert.is_true(ok, tostring(term) .. ", exit " .. tostring(code))
            assert.equal("file", lfs.attributes(output, "mode"))
            assert.is_nil(lfs.attributes(response))
        end, debug.traceback)
        for _, file in ipairs(files) do os.remove(file) end
        assert(lfs.rmdir(root))
        if not tested then error(test_error, 0) end
    end)

    it("leaves POSIX link execution unchanged", function()
        platform.windows = false
        driver.sibling_temporary_path = function() error("POSIX response file") end
        local argv = { "cc", "an object.o", "-o", "result" }
        local expected = {}
        for _, word in ipairs(argv) do expected[#expected + 1] = assert(cdriver.shell_quote(word)) end
        os.execute = function(command)
            assert.equal(table.concat(expected, " "), command)
            return true, "exit", 0
        end
        assert.is_true(driver.run_link_command(argv, false, "result"))
    end)
end)

describe("Windows driver dispatch", function()
    local platform = require "titan-compiler.platform"
    local process = require "titan-compiler.process"
    local previous

    before_each(function()
        previous = {
            windows = platform.windows,
            native = platform.native,
            uname = driver.UNAME,
            darwin = driver.IS_DARWIN,
            cflags = driver.CFLAGS,
            compile_module = driver.compile_module,
            new_sync = compiler_io.new_sync,
            execute = os.execute,
            process_run = process.run,
        }
        platform.windows = true
    end)

    after_each(function()
        platform.windows = previous.windows
        platform.native = previous.native
        driver.UNAME = previous.uname
        driver.IS_DARWIN = previous.darwin
        driver.CFLAGS = previous.cflags
        driver.compile_module = previous.compile_module
        compiler_io.new_sync = previous.new_sync
        os.execute = previous.execute
        process.run = previous.process_run
    end)

    it("initializes without requiring uname or native support", function()
        local strategy = compiler_io.new_sync()
        function strategy:run() error("Windows attempted uname") end
        platform.native = function() error("eager native support") end
        -- Platform dispatch owns no layout discovery. A real Linux prefix is
        -- not a valid synthetic Windows installation for this unit boundary.
        local context = { io = strategy }
        driver.activate_target_caches(context, "windows")
        local ok, uname, darwin = driver.initialize_platform(context)
        assert.is_true(ok)
        assert.equal("Windows", uname)
        assert.is_false(darwin)
        assert.is_true(context._platform_initialized)
        assert.equal(strategy, context.io)
    end)

    it("executes preflighted one-job batches serially without native process support", function()
        local calls, requests, plans = {}, {}, {}
        compiler_io.new_sync = function()
            return { rename = function() return true end }
        end
        for _, leaf in ipairs({ "first", "failed", "last" }) do
            local name = "windows_serial." .. leaf
            local object = "C:/project/windows_serial/" .. leaf .. ".o"
            requests[#requests + 1] = { modname = name, mod = {} }
            plans[#plans + 1] = {
                materialize = function()
                    return {
                        modname = name, primary_object = object,
                        objects = { object },
                        jobs = { { argv = { name }, object_path = object,
                            temporary_object = object .. ".temporary", part_index = 0 } },
                    }
                end,
            }
        end
        os.execute = function() error("Windows compile must use process.run") end
        process.run = function(argv)
            local name = assert(argv[1]:match("windows_serial%.[a-z]+"))
            calls[#calls + 1] = name
            if name == "windows_serial.failed" then return nil, "compile rejected" end
            return true
        end
        local results = driver.compile_modules(requests, 1, false, plans)
        assert.same({ "windows_serial.first", "windows_serial.failed",
            "windows_serial.last" }, calls)
        assert.is_true(results[1].ok)
        assert.equal("compile rejected", results[2].err)
        assert.is_true(results[3].ok)
    end)

    it("retains injected sibling reservation ownership", function()
        local calls = {}
        local strategy = {
            tmpname = function()
                calls[#calls + 1] = "reserve"
                return "C:/temporary/owned-reservation"
            end,
            unlink = function(_, path, finish_cleanup)
                assert.equal("C:/temporary/owned-reservation", path)
                assert.is_true(finish_cleanup)
                calls[#calls + 1] = "release"
                return true
            end,
        }
        platform.native = function() error("injected I/O bypassed") end
        assert.equal("C:/project/module.c.tmp.owned-reservation",
            driver.sibling_temporary_path("C:/project/module.c", strategy))
        assert.same({ "reserve", "release" }, calls)
    end)
end)

describe("target-aware source resolver", function()
    local fixtures = require "spec.fixtures.target_selection.support"
    local function slashed_files(files)
        local result = {}
        for index, filename in ipairs(files) do result[index] = paths.to_slash(filename) end
        return result
    end
    local root, contexts, saved_imported, saved_registry, saved_path
    local saved_browser_target, saved_initialize_platform, saved_binary_path
    local function context(target, strategy)
        local value = driver.new_resolver_context({ target = target, io = strategy,
            analysis_only = true })
        contexts[#contexts + 1] = value
        return value
    end
    local function put(relative, bytes)
        fixtures.write(root .. "/" .. relative, bytes or "function answer(): integer return 42 end\n")
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); fixtures.mkdir(root)
        contexts = {}
        saved_imported, saved_registry, saved_path =
            driver.imported, types.registry, driver.TITAN_SOURCE_PATH
        driver.imported, types.registry, driver.TITAN_SOURCE_PATH = {}, {}, root
        saved_binary_path = driver.TITAN_BIN_PATH
        saved_browser_target, saved_initialize_platform =
            driver._browser_target, driver.initialize_platform
        driver._browser_target = setmetatable({ build = function(_, inputs)
            return assert(saved_browser_target.import(browser_fixtures.descriptor(inputs.paths.root)))
        end }, { __index = saved_browser_target })
        driver.initialize_platform = function(ctx)
            if type(ctx) == "table" and ctx.io ~= nil and ctx._target_initializing and
               ctx.target == "browser" and platform.windows then
                ctx._platform_initialized, ctx.uname, ctx.is_darwin = true, "Linux", false
            end
            return saved_initialize_platform(ctx)
        end
    end)
    after_each(function()
        for _, value in ipairs(contexts) do assert(driver.close_resolver_context(value)) end
        driver.imported, types.registry, driver.TITAN_SOURCE_PATH =
            saved_imported, saved_registry, saved_path
        driver.TITAN_BIN_PATH = saved_binary_path
        driver._browser_target, driver.initialize_platform =
            saved_browser_target, saved_initialize_platform
        fixtures.remove(root)
    end)

    it("reserves the browser source map and trace table during pre-worker output planning", function()
        put("app.titan", "function main(args: {string}): integer return #args end\n")
        local ctx = context("browser")
        local source = assert(driver.resolve_source(ctx, "app"))
        local plan = { order = { "app" },
            modules = { app = { kind = "source", source = source } } }
        assert(driver.preflight_build_outputs(ctx, plan, { roots = { "app" }, c_parts = 1 }))
        local reserved = {}
        for _, output in ipairs(plan.reservations) do reserved[output.owner] = paths.to_slash(output.path) end
        assert.matches("%.wasm%.map$", reserved["browser source map"])
        assert.matches("%.wasm%.trace$", reserved["browser trace table"])
    end)

    it("keeps context validation ahead of the Windows browser host model", function()
        local uninitialized = { io = compiler_io.new_sync(), target = "browser", _resolver_context = true }
        local windows = platform.windows
        local ok, failure = pcall(function()
            platform.windows = true
            assert.has_error(function() driver.initialize_platform() end,
                "platform initialization requires a resolver context")
            assert.has_error(function() driver.initialize_platform({}) end,
                "platform initialization requires a resolver context")
            assert.has_error(function() driver.initialize_platform(uninitialized) end,
                "compiler target context is not initialized")
        end)
        platform.windows = windows
        if not ok then error(failure, 0) end
        assert.is_nil(uninitialized._platform_initialized)
        assert.is_nil(uninitialized.uname)
        assert.is_nil(uninitialized.is_darwin)
    end)

    it("selects every target row, including target-only modules and canonical paths", function()
        put("choice.titan")
        for _, label in ipairs(driver.SOURCE_LABELS) do put("choice." .. label .. ".titan") end
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local ctx = context(target)
            local source = assert(driver.resolve_source(ctx, "choice"))
            assert.equal(root .. "/choice." .. target .. ".titan", paths.to_slash(source.main))
            assert.equal(root .. "/choice.titan", paths.to_slash(source.native_output))
            assert.equal("choice", source.program_output)
            assert(os.remove(source.main))
            local fallback = assert(driver.resolve_source(ctx, "choice"))
            local label = target ~= "browser" and target ~= "native" and "native" or nil
            assert.equal(root .. "/choice" .. (label and "." .. label or "") .. ".titan",
                paths.to_slash(fallback.main))
            put("choice." .. target .. ".titan")
        end
        put("only.browser.titan")
        assert.is_nil(driver.resolve_source(context("linux"), "only"))
        assert.equal(root .. "/only.browser.titan",
            paths.to_slash(assert(driver.resolve_source(context("browser"), "only")).main))
    end)

    local stdlib_root = paths.to_slash(lfs.currentdir())
    local excluded_stdlib = {
        { "fs", "fs" }, { "net", "net" }, { "ssl", "ssl" },
        { "uv", "uv/uv", "tcp" },
        { "sqlite3", "sqlite3/sqlite3", "bindings" },
        { "thread", "thread/thread", "channel" },
    }
    for _, entry in ipairs(excluded_stdlib) do
        local name = "titan." .. entry[1]
        local physical = stdlib_root .. "/titan/" .. entry[2]
        it("keeps the native-only stdlib selection for " .. name, function()
            for _, target in ipairs({ "linux", "darwin", "windows", "native" }) do
                local source = assert(driver.resolve_source(context(target), name, stdlib_root))
                assert.equal(physical .. ".native.titan", paths.to_slash(source.main), target)
                assert.equal(physical .. ".titan", paths.to_slash(source.native_output), target)
                assert.equal(entry[3] and "folder" or "flat", source.kind, target)
                assert.equal(source.main, source.files[1], target)
            end
        end)

        -- Without the browser SDK's absent-module list both import forms keep
        -- the ordinary not-found message; with it, a listed module names the
        -- target and the SDK's reason, and unlisted names stay unchanged.
        it("rejects browser imports of the native-only stdlib module " .. name, function()
            driver.TITAN_SOURCE_PATH = root .. ";" .. stdlib_root
            driver.TITAN_BIN_PATH = root
            -- The descriptor's installation root holds the fixture SDK.
            local fixture_target = driver._browser_target
            driver._browser_target = setmetatable({ build = function()
                return assert(saved_browser_target.import(browser_fixtures.descriptor(root .. "/sdk")))
            end }, { __index = saved_browser_target })
            local tested, failure = pcall(function()
                local function import_error(ctx, consumer, imported)
                    put(consumer .. ".titan", 'local excluded = import "' .. imported .. '"\n')
                    local ok, _, errors = driver.defaultloader({}, {
                        context = ctx, source_roots = { [consumer] = true },
                    })(consumer)
                    assert.is_true(ok)
                    assert.equal(1, #errors, table.concat(errors, "\n"))
                    return errors[1]
                end
                local ctx = context("browser")
                assert.is_nil(driver.resolve_source(ctx, name, stdlib_root))
                assert.matches("module '" .. name .. "' not found", import_error(ctx, "plain", entry[1]), 1, true)
                assert.matches("source module '" .. name .. "' not found",
                    import_error(ctx, "marked", entry[1] .. ".titan"), 1, true)
                local unavailable = "module '" .. name .. "' is not available for target 'browser': requires a native host"
                for _, newline in ipairs({ "\n", "\r\n" }) do
                    fixtures.write(root .. "/sdk/lib/titan-browser/" .. driver.TITAN_LIBRARY_VERSION .. "/absent-modules",
                        "titan.example\trequires an example" .. newline .. name .. "\trequires a native host" .. newline)
                    ctx = context("browser")
                    -- Consumers loaded once stay imported, so each pass uses its own.
                    local pass = newline == "\n" and "" or "_crlf"
                    assert.matches(unavailable, import_error(ctx, "listed" .. pass, entry[1]), 1, true)
                    assert.matches(unavailable, import_error(ctx, "listed_source" .. pass, entry[1] .. ".titan"), 1, true)
                    assert.matches("module 'missing' not found", import_error(ctx, "unlisted" .. pass, "missing"), 1, true)
                    assert.matches("source module 'missing' not found",
                        import_error(ctx, "unlisted_source" .. pass, "missing.titan"), 1, true)
                    -- External resolution reports a required source like an
                    -- import and keeps the probe's `missing` kind.
                    local external = driver.resolve_external_modules({ [name] = true, missing = true }, {}, ctx)
                    assert.same({ kind = "error", message = unavailable }, external[name])
                    assert.same({ kind = "error", message = "source module 'missing' not found" }, external.missing)
                    external = driver.resolve_external_modules({ [name] = false, missing = false }, {}, ctx)
                    assert.same({ kind = "missing" }, external[name])
                    assert.same({ kind = "missing" }, external.missing)
                    -- The table loader: an absent table entry, and a cached
                    -- compiled interface under a source request.
                    local source_import = { kind = "source-import" }
                    local loader = driver.tableloader({}, {}, {}, { context = ctx })
                    assert.same({ false, unavailable }, { loader(name) })
                    assert.same({ false, unavailable }, { loader(name, source_import) })
                    assert.same({ false, "module 'missing' not found" }, { loader("missing") })
                    assert.same({ false, "source module 'missing' not found" }, { loader("missing", source_import) })
                    local cached = driver.tableloader({},
                        { [name] = { kind = "compiled", type = types.Module(name, {}) } }, {}, { context = ctx })
                    assert.same({ false, unavailable }, { cached(name, source_import) })
                end
                assert.is_nil(driver.imported[name])
            end)
            driver._browser_target = fixture_target
            if not tested then error(failure, 0) end
        end)
    end
    it("selects the browser-only bridge without a native placeholder", function()
        local selected = assert(driver.resolve_source(context("browser"), "titan.browser", stdlib_root))
        assert.equal(stdlib_root .. "/titan/browser.browser.titan", paths.to_slash(selected.main))
        for _, target in ipairs({ "linux", "darwin", "windows", "native" }) do
            assert.is_nil(driver.resolve_source(context(target), "titan.browser", stdlib_root))
        end
        assert.equal("titan.browser", require("titan-compiler.parser").normalize_import("browser"))
    end)

    it("composes titan.async from its shared main and the target's contributor members", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local member = target == "browser" and "browser" or "native"
            local selected = assert(driver.resolve_source(context(target), "titan.async", stdlib_root))
            assert.equal("folder", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/async/async.titan", paths.to_slash(selected.main), target)
            local files = {}
            for index, filename in ipairs(selected.files) do files[index] = paths.basename(filename) end
            assert.same(target == "browser" and
                { "async.titan", "external.browser.titan", "runtime.browser.titan" } or
                { "async.titan", "external.native.titan", "foreign.native.titan",
                  "receiver.native.titan", "runtime.native.titan" }, files, target)
            for _, part in ipairs({ "runtime", "external", "receiver", "foreign" }) do
                local blocked = driver.resolve_source(context(target), "titan.async." .. part, stdlib_root)
                if member == "browser" and (part == "receiver" or part == "foreign") then
                    -- These families have no browser member: an ordinary miss.
                    assert.is_nil(blocked, part)
                else
                    assert.equal("blocked", assert(blocked, part).kind, part)
                    assert.equal(stdlib_root .. "/titan/async/" .. part .. "." .. member .. ".titan",
                        paths.to_slash(blocked.contributor), target .. " " .. part)
                end
            end
        end
    end)

    it("composes titan.http from its shared main and the target's contributor members", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local selected = assert(driver.resolve_source(context(target), "titan.http", stdlib_root))
            assert.equal("folder", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/http/http.titan", paths.to_slash(selected.main), target)
            assert.equal(selected.main, selected.native_output, target)
            local files = {}
            for index, filename in ipairs(selected.files) do files[index] = paths.basename(filename) end
            assert.same(target == "browser" and {
                "http.titan", "client.browser.titan", "headers.titan", "options.titan",
            } or {
                "http.titan", "client.native.titan", "headers.titan", "native_imports.native.titan",
                "options.titan", "parser.native.titan", "pool.native.titan",
                "server.native.titan", "transfer.native.titan", "upgrade.native.titan",
            }, files, target)
            for _, part in ipairs({ "client", "headers", "options", "native_imports", "parser",
                "pool", "server", "transfer", "upgrade" }) do
                local blocked = driver.resolve_source(context(target), "titan.http." .. part, stdlib_root)
                local shared = part == "headers" or part == "options"
                if target == "browser" and not shared and part ~= "client" then
                    assert.is_nil(blocked, part)
                else
                    assert.equal("blocked", assert(blocked, part).kind, part)
                    assert.equal(selected.main, blocked.main, target .. " " .. part)
                    local member = shared and "" or (target == "browser" and ".browser" or ".native")
                    assert.equal(stdlib_root .. "/titan/http/" .. part .. member .. ".titan",
                        paths.to_slash(blocked.contributor), target .. " " .. part)
                end
            end
        end
    end)

    it("composes titan.websocket from the target main and contributor members", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local member = target == "browser" and "browser" or "native"
            local selected = assert(driver.resolve_source(context(target), "titan.websocket", stdlib_root))
            assert.equal("folder", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/websocket/websocket." .. member .. ".titan",
                paths.to_slash(selected.main), target)
            assert.equal(stdlib_root .. "/titan/websocket/websocket.titan",
                paths.to_slash(selected.native_output), target)
            local files = {}
            for index, filename in ipairs(selected.files) do files[index] = paths.basename(filename) end
            assert.same(target == "browser" and {
                "websocket.browser.titan", "client.browser.titan", "types.titan", "utf8.titan",
            } or {
                "websocket.native.titan", "connection.native.titan", "crypto.native.titan",
                "frames.native.titan", "handshake.native.titan", "types.titan", "utf8.titan",
            }, files, target)
            for _, part in ipairs({ "client", "connection", "crypto", "frames", "handshake",
                "types", "utf8" }) do
                local blocked = driver.resolve_source(context(target), "titan.websocket." .. part, stdlib_root)
                local shared = part == "types" or part == "utf8"
                if (target == "browser" and not shared and part ~= "client") or
                    (target ~= "browser" and part == "client") then
                    assert.is_nil(blocked, part)
                else
                    assert.equal("blocked", assert(blocked, part).kind, part)
                    -- Privacy diagnostics name the first main variant, independent of target.
                    assert.equal(stdlib_root .. "/titan/websocket/websocket.browser.titan",
                        paths.to_slash(blocked.main), target .. " " .. part)
                    local suffix = shared and "" or "." .. member
                    assert.equal(stdlib_root .. "/titan/websocket/" .. part .. suffix .. ".titan",
                        paths.to_slash(blocked.contributor), target .. " " .. part)
                end
            end
        end
    end)

    it("selects titan.timer's native variant on native targets and its browser variant on the browser", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local member = target == "browser" and "browser" or "native"
            local selected = assert(driver.resolve_source(context(target), "titan.timer", stdlib_root))
            assert.equal("flat", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/timer." .. member .. ".titan", paths.to_slash(selected.main), target)
            assert.equal(stdlib_root .. "/titan/timer.titan", paths.to_slash(selected.native_output), target)
            assert.same({ selected.main }, selected.files, target)
        end
    end)

    it("selects titan.io's shared main on every target", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local selected = assert(driver.resolve_source(context(target), "titan.io", stdlib_root))
            assert.equal("flat", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/io.titan", paths.to_slash(selected.main), target)
            assert.equal(selected.main, selected.native_output, target)
            assert.same({ selected.main }, selected.files, target)
        end
    end)

    it("composes titan.lua with synchronous browser and native worker contributors", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local selected = assert(driver.resolve_source(context(target), "titan.lua", stdlib_root))
            assert.equal("folder", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/lua/lua.titan", paths.to_slash(selected.main), target)
            assert.equal(selected.main, selected.native_output, target)
            local files = {}
            for index, filename in ipairs(selected.files) do files[index] = paths.basename(filename) end
            assert.same(target == "browser" and {
                "lua.titan", "loading.browser.titan", "worker.titan",
            } or {
                "lua.titan", "background.native.titan", "loading.native.titan", "worker.titan",
            }, files, target)
            for _, part in ipairs({ "background", "loading", "worker" }) do
                local blocked = driver.resolve_source(context(target), "titan.lua." .. part, stdlib_root)
                if part == "background" and target == "browser" then
                    assert.is_nil(blocked, part)
                else
                    assert.equal("blocked", assert(blocked, part).kind, part)
                    local member = part == "worker" and "" or
                        (target == "browser" and ".browser" or ".native")
                    assert.equal(stdlib_root .. "/titan/lua/" .. part .. member .. ".titan",
                        paths.to_slash(blocked.contributor), target .. " " .. part)
                end
            end
        end
    end)

    it("composes titan.os from its shared main and the target's contributor members", function()
        for _, target in ipairs(driver.SOURCE_LABELS) do
            local member = target == "browser" and "browser" or "native"
            local selected = assert(driver.resolve_source(context(target), "titan.os", stdlib_root))
            assert.equal("folder", selected.kind, target)
            assert.equal(stdlib_root .. "/titan/os/os.titan", paths.to_slash(selected.main), target)
            assert.equal(selected.main, selected.native_output, target)
            local files = {}
            for index, filename in ipairs(selected.files) do files[index] = paths.basename(filename) end
            assert.same({
                "os.titan", "clock." .. member .. ".titan",
                "environment." .. member .. ".titan", "process." .. member .. ".titan",
                "stdio." .. member .. ".titan",
            }, files, target)
            for _, part in ipairs({ "clock", "environment", "process", "stdio" }) do
                local blocked = driver.resolve_source(context(target), "titan.os." .. part, stdlib_root)
                assert.equal("blocked", assert(blocked, part).kind, part)
                assert.equal(stdlib_root .. "/titan/os/" .. part .. "." .. member .. ".titan",
                    paths.to_slash(blocked.contributor), target .. " " .. part)
            end
        end
    end)

    for _, target in ipairs(driver.SOURCE_LABELS) do
        it("blocks native-only stdlib folder contributors on " .. target, function()
            for _, entry in ipairs(excluded_stdlib) do
                if entry[3] then
                    local name = "titan." .. entry[1] .. "." .. entry[3]
                    local source = driver.resolve_source(context(target), name, stdlib_root)
                    assert.truthy(source, name)
                    assert.equal("blocked", source.kind, name)
                    assert.equal(stdlib_root .. "/titan/" .. entry[2] .. ".native.titan",
                        paths.to_slash(source.main), name)
                    assert.equal(stdlib_root .. "/titan/" .. entry[1] .. "/" .. entry[3] .. ".titan",
                        paths.to_slash(source.contributor), name)
                end
            end
        end)
    end

    posix_model_it("selects native then default on an unlisted native host", function()
        local strategy = compiler_io.new_sync()
        function strategy:run(argv)
            assert.same({ "uname" }, argv)
            return { started = true, ok = true, output = "FreeBSD\n" }
        end
        put("choice.titan"); put("choice.native.titan"); put("choice.linux.titan")
        local ctx = context(nil, strategy)
        assert.equal("native", driver.context_target(ctx))
        assert.equal(root .. "/choice.native.titan",
            paths.to_slash(assert(driver.resolve_source(ctx, "choice")).main))
        assert(os.remove(root .. "/choice.native.titan"))
        assert.equal(root .. "/choice.titan",
            paths.to_slash(assert(driver.resolve_source(ctx, "choice")).main))
    end)

    it("preserves root and folder precedence and target-independent privacy", function()
        put("early/pick.titan"); put("late/pick.linux.titan")
        local ctx = context("linux")
        local roots = root .. "/early;" .. root .. "/late"
        assert.equal(root .. "/early/pick.titan",
            paths.to_slash(assert(driver.resolve_source(ctx, "pick", roots)).main))
        put("early/pick/pick.titan")
        assert.equal("folder", assert(driver.resolve_source(ctx, "pick", roots)).kind)
        assert(os.remove(root .. "/early/pick/pick.titan"))
        put("early/pick/pick.browser.titan")
        assert.equal("flat", assert(driver.resolve_source(ctx, "pick", roots)).kind)
        assert.equal("folder", assert(driver.resolve_source(context("browser"), "pick", roots)).kind)
        ctx = context("linux")
        put("early/pick/child.titan")
        local blocked = assert(driver.resolve_source(ctx, "pick.child", roots))
        assert.equal("blocked", blocked.kind)
        assert.equal(root .. "/early/pick/pick.browser.titan", paths.to_slash(blocked.main))
        put("early/pick/child/child.native.titan")
        assert.equal("folder", assert(driver.resolve_source(ctx, "pick.child", roots)).kind)
        put("early/pick/absent.browser.titan")
        assert.is_nil(driver.resolve_source(ctx, "pick.absent", roots))
    end)

    it("selects contributor groups and sorts their logical filenames bytewise", function()
        put("ensemble/ensemble.titan")
        put("ensemble/ensemble.linux.titan")
        put("ensemble/a.titan"); put("ensemble/a-common.native.titan")
        put("ensemble/a_extra.linux.titan"); put("ensemble/x.y.titan")
        put("ensemble/ignored.browser.titan"); put("ensemble/native_only.native.titan")
        local source = assert(driver.resolve_source(context("linux"), "ensemble"))
        local expected = { "ensemble.linux.titan", "a-common.native.titan", "a.titan",
            "a_extra.linux.titan", "native_only.native.titan", "x.y.titan" }
        for index, name in ipairs(expected) do expected[index] = root .. "/ensemble/" .. name end
        assert.same(expected, slashed_files(source.files))
        local browser = assert(driver.resolve_source(context("browser"), "ensemble"))
        assert.same({ root .. "/ensemble/ensemble.titan", root .. "/ensemble/a.titan",
            root .. "/ensemble/ignored.browser.titan", root .. "/ensemble/x.y.titan" },
            slashed_files(browser.files))
        assert.equal(root .. "/ensemble/ensemble.titan", paths.to_slash(source.native_output))
    end)

    it("preserves no-variant contributor order when any one member becomes a variant", function()
        put("ensemble/ensemble.titan")
        local names = { "a-common", "a", "a_extra" }
        for _, name in ipairs(names) do put("ensemble/" .. name .. ".titan") end
        local ctx = context("native")
        local function selected()
            return slashed_files(assert(driver.resolve_source(ctx, "ensemble")).files)
        end
        local expected = { root .. "/ensemble/ensemble.titan" }
        for _, name in ipairs(names) do expected[#expected + 1] = root .. "/ensemble/" .. name .. ".titan" end
        assert.same(expected, selected())
        for index, name in ipairs(names) do
            local plain = root .. "/ensemble/" .. name .. ".titan"
            local variant = root .. "/ensemble/" .. name .. ".native.titan"
            assert(os.rename(plain, variant))
            expected[index + 1] = variant
            assert.same(expected, selected())
            assert(os.rename(variant, plain))
            expected[index + 1] = plain
        end
    end)

    it("diagnoses reserved suffix errors even in inactive main-family files", function()
        put("ensemble/ensemble.titan")
        for _, case in ipairs({ { "x.linux.native.titan", "stacked target labels" },
                { "ensemble.Linux.titan", "mis-cased target label" } }) do
            put("ensemble/" .. case[1])
            local source, err = driver.resolve_source(context("browser"), "ensemble")
            assert.is_nil(source); assert.matches(case[2], err, 1, true)
            assert(os.remove(root .. "/ensemble/" .. case[1]))
        end
    end)

    it("does not fall back after a selected file read or folder enumeration fails", function()
        put("selected.titan"); put("selected.native.titan")
        put("folder.titan"); put("folder/folder.native.titan")
        local strategy = compiler_io.new_sync()
        local original_read = strategy.read_file
        function strategy:read_file(filename)
            local slashed = paths.to_slash(filename)
            if slashed == root .. "/selected.native.titan" then
                return nil, "selected read denied"
            end
            assert.not_equal(root .. "/selected.titan", slashed)
            return original_read(self, filename)
        end
        function strategy:list() return nil, "selected enumeration denied" end
        local ctx = context("native", strategy)
        local source, err = driver.resolve_source(ctx, "folder")
        assert.is_nil(source)
        assert.matches("selected enumeration denied", err, 1, true)
        assert.matches("folder.native.titan", err, 1, true)
        local ok, message = driver.defaultloader({}, { context = ctx,
            source_roots = { selected = true } })("selected")
        assert.is_false(ok)
        assert.matches("selected read denied", message, 1, true)
    end)

    it("never reads inactive syntax or foreign headers and never falls back from selected errors", function()
        put("ensemble/ensemble.titan")
        put("ensemble/bad.browser.titan", "this is not Titan syntax @@@")
        put("ensemble/header.browser.titan", 'foreign import "missing-inactive.h"\n')
        local strategy = compiler_io.new_sync()
        local reads, original_read = {}, strategy.read_file
        function strategy:read_file(filename)
            reads[paths.to_slash(filename)] = true
            return original_read(self, filename)
        end
        local ctx = context("linux", strategy)
        local ok, _, errors = driver.defaultloader({}, { context = ctx,
            source_roots = { ensemble = true } })("ensemble")
        assert.is_true(ok); assert.equal(0, #errors)
        assert.is_true(reads[root .. "/ensemble/ensemble.titan"])
        assert.is_nil(reads[root .. "/ensemble/bad.browser.titan"])
        assert.is_nil(reads[root .. "/ensemble/header.browser.titan"])
        put("terminal.titan")
        put("terminal.native.titan", "function broken(: end")
        local selected, message = driver.defaultloader({}, { context = ctx,
            source_roots = { terminal = true } })("terminal")
        assert.is_false(selected)
        assert.matches("terminal.native.titan", message, 1, true)
        assert.is_true(reads[root .. "/terminal.native.titan"])
        assert.is_nil(reads[root .. "/terminal.titan"])
    end)

    it("re-resolves cached interface descriptors before admitting their selection", function()
        put("cached.titan", "local old: integer = 1\n")
        local ctx = context("linux")
        local loader = driver.defaultloader({}, { context = ctx,
            source_roots = { cached = true } })
        local ok, _, errors = loader("cached")
        assert.is_true(ok); assert.equal(0, #errors)
        local old = driver.imported.cached
        local cached = { serialized = old.source_manifest, filename = old.filename,
            source_files = old.source_files }
        driver.imported, types.registry = {}, {}
        put("cached.linux.titan", "function selected(): integer return 7 end\n")
        local current = driver.defaultloader({}, { context = context("linux"),
            source_roots = { cached = true }, cached_interfaces = { cached = cached } })
        ok, _, errors = current("cached", { kind = "source-import" })
        assert.is_true(ok); assert.equal(0, #errors)
        assert.equal(root .. "/cached.linux.titan", paths.to_slash(driver.imported.cached.filename))
        assert.equal(root .. "/cached.titan", paths.to_slash(driver.imported.cached.native_output))
    end)

    it("keeps every generated stem logical when given a physical variant main", function()
        local source = root .. "/foo.linux.titan"
        assert.equal(root .. "/foo", driver.module_output_stem(source))
        assert.equal(root .. "/foo.titan.h", driver.foreign_header_filename(source))
        assert.equal(root .. "/foo.ffi.h", driver.ffi_header_filename(source))
        assert.equal(root .. "/foo.priv.h", driver.private_header_filename(source))
        assert.equal(root .. "/foo.part1.c", driver.part_c_filename(source, 1))
        assert.equal(root .. "/foo.part1.o", driver.part_object_filename(source, 1))
    end)

    it("raises source-name diagnostics through public compiler filename APIs", function()
        local ctx = context("native")
        local apis = {
            driver.module_output_stem,
            driver.foreign_header_filename,
            driver.ffi_header_filename,
            driver.private_header_filename,
            function(filename) return driver.part_c_filename(filename, 1) end,
            function(filename) return driver.part_object_filename(filename, 1) end,
            function(filename) return driver.plan_foreign_header("filename_error", {}, filename) end,
            function(filename) return driver.prepare_source_ffi_header(ctx, "filename_error", {}, filename) end,
            function(filename) return ffiheaders.prepare(ctx, "filename_error", {}, filename) end,
            function(filename) return driver.compile("filename_error", {}, filename, {}, false) end,
        }
        for _, case in ipairs({
            { "x.linux.native.titan", "stacked target labels" },
            { "x.Linux.titan", "mis-cased target label" },
        }) do
            for _, api in ipairs(apis) do
                local ok, diagnostic = pcall(api, root .. "/" .. case[1])
                assert.is_false(ok)
                assert.equal(case[2] .. " in source '" .. case[1] .. "'", diagnostic)
            end
        end
    end)

    it("compiles variant mains into logical split objects and private headers", function()
        put("parts.native.titan", [[
foreign function target_parts_increment(n: int): int return n + 1 end
function first(): integer return 1 end
function second(): integer return first() + 2 end
function third(): integer return second() + 3 end
function fourth(): integer return third() + 4 end
]])
        local deps = {}
        local ctx = context("native")
        local loader = driver.defaultloader(deps, { context = ctx,
            source_roots = { parts = true } })
        local ok, result, errors = loader("parts")
        assert.is_true(ok, tostring(result)); assert.equal(0, #errors)
        local compiled, compile_error = driver.compile_module("parts", driver.imported.parts,
            deps, false, { c_parts = 3, split_threshold = 0 })
        assert.truthy(compiled, compile_error)
        for _, suffix in ipairs({ ".c", ".o", ".part1.c", ".part1.o",
                ".priv.h", ".titan.h", ".ffi.h" }) do
            assert.equal("file", lfs.attributes(root .. "/parts" .. suffix, "mode"), suffix)
            assert.is_nil(lfs.attributes(root .. "/parts.native" .. suffix))
        end
    end)
end)

local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local incremental = require "titan-compiler.incremental"
local certificate = require "titan-compiler.linkcertificate"
local types = require "titan-compiler.types"
local browser_target = require "titan-compiler.browsertarget"
local fixtures = require "spec.support.browser_fixtures"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local platform = require "titan-compiler.platform"
local build = require "titan-compiler.build"
local lfs = require "lfs"
local path = require "titan-compiler.path"

local function fresh_driver()
    local saved = package.loaded["titan-compiler.driver"]
    package.loaded["titan-compiler.driver"] = nil
    local ok, subject = pcall(require, "titan-compiler.driver")
    package.loaded["titan-compiler.driver"] = saved
    assert.is_true(ok, subject)
    return subject
end

local function descriptor(root, changed)
    local data = fixtures.descriptor(root)
    if changed then
        data.compile_flags[2] = "-O0"
        fixtures.identify(data)
    end
    return assert(browser_target.import(data))
end

local function loaded(loader, name)
    local ok, modtype, errors = loader(name)
    assert.is_true(ok, modtype)
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return modtype
end

-- Isolate descriptor verification (covered by its own specs) with a validated,
-- frozen fixture. Constructors, accessors and cache activation remain real.
describe("browser semantic cache isolation", function()
    local subject, root, contexts, saved_registry, saved_browser, saved_initialize_platform
    local provider_fixture, provider_images
    local function context(target, data, analysis_only)
        subject._browser_target = setmetatable({
            build = function() return data or descriptor(root) end,
        }, { __index = browser_target })
        local ctx = subject.new_resolver_context({ analysis_only = analysis_only ~= false, target = target,
            embedded_interface_provider = { provider_file = root .. "/semantic-host",
                entries = {}, target_profile = fixtures.profile_data() } })
        contexts[#contexts + 1] = ctx
        return ctx
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
        saved_registry, contexts = types.registry, {}
        subject = fresh_driver()
        subject.TITAN_SOURCE_PATH = root
        saved_browser = subject._browser_target
        saved_initialize_platform = subject.initialize_platform
        subject.initialize_platform = function(ctx)
            if platform.windows and ctx.target == "browser" and not ctx._platform_initialized then
                -- Model the supported host observation, not Windows browser
                -- support. Keep native Windows provider lookup genuine.
                ctx.uname, ctx.is_darwin, ctx._platform_initialized = "Linux", false, true
            end
            return saved_initialize_platform(ctx)
        end
    end)
    after_each(function()
        for _, ctx in ipairs(contexts) do assert(subject.close_resolver_context(ctx)) end
        subject._browser_target = saved_browser
        subject.initialize_platform = saved_initialize_platform
        types.registry = saved_registry
        local owned_fixture, images = provider_fixture, provider_images
        provider_fixture, provider_images = nil, nil
        if owned_fixture then owned_fixture:close(images) end
        files.remove(root)
    end)

    local function stale_compilation(prepare)
        local native = context(nil, nil, false)
        files.write(root .. "/frozen.titan",
            "record Item\n value: integer\nend\nfunction answer(): integer return 1 end\n")
        loaded(subject.defaultloader({}, { context = native,
            source_roots = { frozen = true } }), "frozen")
        local entry = subject.imported.frozen
        assert.is_table(entry.ast._erased_registry)
        local request = { modname = "frozen", mod = entry,
            options = { context = native, c_parts = 1 } }
        local plans = prepare and assert(subject.plan_compile_requests({ request })) or nil
        files.write(root .. "/frozen.c", subject.GENERATED_C_MARKER .. "\n/* retained source */\n")
        files.write(root .. "/frozen.o", "retained object bytes")
        local retained, past = {}, os.time() - 120
        for _, suffix in ipairs({ ".c", ".o" }) do
            local filename = root .. "/frozen" .. suffix
            assert(lfs.touch(filename, past, past))
            retained[filename] = files.read(filename)
        end
        local browser = context("browser")
        files.write(root .. "/active.browser.titan", "record Active\n value: string\nend\n")
        loaded(subject.defaultloader({}, { context = browser,
            source_roots = { active = true } }), "active")
        local registry, imported = types.registry, subject.imported
        local owner, active = registry["active.Active"], imported.active
        local inventory = assert(browser.io:list(root))
        table.sort(inventory)
        local function unchanged()
            assert.equal(registry, types.registry)
            assert.equal(imported, subject.imported)
            assert.equal(owner, types.registry["active.Active"])
            assert.equal(active, subject.imported.active)
            assert.is_nil(native.source_modules.unrelated)
            for filename, bytes in pairs(retained) do
                assert.equal(bytes, files.read(filename))
                assert.equal(past, lfs.attributes(filename, "modification"))
            end
            local current = assert(browser.io:list(root))
            table.sort(current)
            assert.same(inventory, current)
            assert(subject.assert_target_context(browser))
        end
        local message = "compiler caches now belong to target " ..
            browser.target_descriptor.identity .. "; create a new context"
        return native, browser, entry, request, plans, unchanged, message
    end

    it("rejects stale native direct compilation before code generation can replace the browser registry", function()
        local native, _, entry, _, _, unchanged, message = stale_compilation(false)
        assert.has_error(function()
            subject.compile("frozen", entry.ast, entry.filename, {}, false, { context = native })
        end, message)
        unchanged()
        assert(subject.close_resolver_context(native))
    end)

    it("rejects stale batch requests and captured materializers before fast paths or output mutation", function()
        local native, browser, entry, request, plans, unchanged, message = stale_compilation(true)
        local compiled = {}
        for key, value in pairs(entry) do compiled[key] = value end
        compiled.compiled, compiled.compiled_objects = root .. "/frozen.o", { root .. "/frozen.o" }
        local warm = { modname = "frozen", mod = compiled, options = { context = native } }
        local current = { modname = "frozen", mod = entry, options = { context = browser } }
        for _, action in ipairs({
            function() subject.plan_compile_requests({ request }) end,
            function() subject.plan_compile_requests({ warm }) end,
            function() subject.compile_modules({ request }, 1) end,
            function() subject.compile_modules({ warm }, 1, false, {}) end,
            function() plans[1].materialize() end,
            function() subject.compile_modules({ current }, 1, false, plans) end,
        }) do
            assert.has_error(action, message)
            unchanged()
        end
    end)

    it("rejects stale invalidation, staging and borrowed semantic contexts before any work", function()
        local native, _, entry, _, _, unchanged, message = stale_compilation(false)
        for _, action in ipairs({
            function() subject.invalidate_source_object(native, "frozen", { main = entry.filename }) end,
            function() subject.cleanup_stale_staging(native, {}) end,
            function() subject.restat_c_header_dependencies({}, native) end,
            function() subject.restat_c_header_dependencies({}, { context = native }) end,
            function() subject.resolve_external_modules({}, { unrelated = true }, native) end,
            function() subject.resolve_external_modules({}, { unrelated = true }, { context = native }) end,
            function() subject.language_server_cache_identity({ context = native }) end,
        }) do
            assert.has_error(action, message)
            unchanged()
        end
    end)

    it("rejects never-activated contexts at compile and borrowed boundaries but accepts raw I/O constructor options", function()
        local _, _, entry, _, _, unchanged = stale_compilation(false)
        local uninitialized = { io = compiler_io.new_sync(), _resolver_context = true }
        local request = { modname = "frozen", mod = entry, options = { context = uninitialized } }
        local compiled = { compiled = root .. "/frozen.o", compiled_objects = { root .. "/frozen.o" } }
        local warm = { modname = "frozen", mod = compiled, options = { context = uninitialized } }
        for _, action in ipairs({
            function() subject.compile("frozen", entry.ast, entry.filename, {}, false, request.options) end,
            function() subject.plan_compile_requests({ request }) end,
            function() subject.plan_compile_requests({ warm }) end,
            function() subject.compile_modules({ warm }, 1, false, {}) end,
            function() subject.invalidate_source_object(uninitialized, "frozen", { main = entry.filename }) end,
            function() subject.cleanup_stale_staging(uninitialized, {}) end,
            function() subject.restat_c_header_dependencies({}, uninitialized) end,
            function() subject.restat_c_header_dependencies({}, { context = uninitialized }) end,
            function() subject.resolve_external_modules({}, {}, uninitialized) end,
            function() subject.resolve_external_modules({}, {}, { context = uninitialized }) end,
        }) do
            assert.has_error(action, "compiler target context is not initialized")
            unchanged()
        end
        assert.same({}, subject.resolve_external_modules({}, {}, { io = compiler_io.new_sync() }))
    end)

    it("rejects a context that has never activated semantic caches", function()
        assert.has_error(function() subject.assert_target_context({ io = compiler_io.new_sync() }) end,
            "compiler target context is not initialized")
    end)

    it("rebinds the whole nominal closure, preserves same-target sharing, and never reactivates a stale context", function()
        local first = context()
        subject.imported.owner = { kind = "source" }
        types.registry["owner.Record"] = { native = true }
        local owner = subject.imported.owner
        local same = context()
        assert.equal(owner, subject.imported.owner)
        assert.is_true(types.registry["owner.Record"].native)
        assert(subject.assert_target_context(first))
        local browser = context("browser")
        assert.is_nil(subject.imported.owner)
        assert.is_nil(types.registry["owner.Record"])
        local message = "compiler caches now belong to target " .. browser.target_descriptor.identity .. "; create a new context"
        assert.has_error(function() subject.assert_target_context(first) end, message)
        assert.has_error(function() subject.activate_target_caches(same, subject.context_target(same)) end, message)
        assert(subject.assert_target_context(browser))
        local native = context()
        assert(subject.assert_target_context(native))
        assert.has_error(function() subject.assert_target_context(first) end,
            "compiler caches now belong to target " .. subject.context_target(native) .. "; create a new context")
    end)

    it("selects native, browser, then native source interfaces and a warm compiled native provider without manual clearing", function()
        provider_fixture = files.new()
        files.write(provider_fixture.source .. "/warm/provider.titan",
            "function answer(): integer return 42 end\n")
        provider_fixture:compiled({ "--jobs", "1", "--c-parts", "1", "warm.provider" })
        files.write(root .. "/choice.native.titan", "record Item\n native_value: integer\nend\n")
        files.write(root .. "/choice.browser.titan", "record Item\n browser_value: string\nend\n")
        files.write(root .. "/warm/provider.browser.titan", "function browser_only(): string return 'browser' end\n")
        local native_path = provider_fixture.output
        subject.TITAN_BIN_PATH = native_path
        local first = context()
        local native_loader = subject.defaultloader({}, { context = first, source_roots = { choice = true } })
        local native_type = loaded(native_loader, "choice")
        assert.equal(root .. "/choice.native.titan", subject.imported.choice.filename)
        local native_owner = types.registry["choice.Item"]
        assert.is_table(native_owner)
        local provider = loaded(native_loader, "warm.provider")
        local native_provider = subject.imported["warm.provider"]
        provider_images = { native_provider.filename }
        assert.is_true(native_provider.kind == "dynamic" or native_provider.kind == "static")
        assert.equal(provider, loaded(native_loader, "warm.provider"))
        local browser = context("browser")
        subject.TITAN_BIN_PATH = root
        local browser_loader = subject.defaultloader({}, { context = browser, source_roots = { choice = true } })
        local browser_type = loaded(browser_loader, "choice")
        assert.not_equal(native_type, browser_type)
        assert.not_equal(native_owner, types.registry["choice.Item"])
        assert.equal(root .. "/choice.browser.titan", subject.imported.choice.filename)
        loaded(browser_loader, "warm.provider")
        assert.equal("source", subject.imported["warm.provider"].kind)
        assert.equal(root .. "/warm/provider.browser.titan", subject.imported["warm.provider"].filename)
        assert.has_error(function() native_loader("warm.provider") end,
            "compiler caches now belong to target " .. browser.target_descriptor.identity .. "; create a new context")
        subject.TITAN_BIN_PATH = native_path
        local third = context()
        local third_loader = subject.defaultloader({}, { context = third, source_roots = { choice = true } })
        loaded(third_loader, "choice")
        assert.equal(root .. "/choice.native.titan", subject.imported.choice.filename)
        assert.not_equal(native_owner, types.registry["choice.Item"])
        loaded(third_loader, "warm.provider")
        assert.equal(native_provider.kind, subject.imported["warm.provider"].kind)
        assert.equal(native_provider.filename, subject.imported["warm.provider"].filename)
        assert.not_equal(native_provider, subject.imported["warm.provider"])
    end)

    it("guards table-loader warm entries and semantic entry points before touching stale state", function()
        local first = context()
        local imported = {}
        local loader = subject.tableloader({ cached = "record Item\n value: integer\nend\n" }, imported, {}, { context = first })
        loaded(loader, "cached")
        files.write(root .. "/planned.titan", "function answer(): integer return 42 end\n")
        local planning = subject.defaultloader({}, { context = first,
            source_roots = { planned = true }, plan_mode = true,
            imports_for = function() return {} end })
        loaded(planning, "planned")
        local plan = subject.resolution_plan(first)
        local browser = context("browser")
        local message = "compiler caches now belong to target " .. browser.target_descriptor.identity .. "; create a new context"
        for _, action in ipairs({
            function() loader("cached") end,
            function() subject.defaultloader({}, { context = first }) end,
            function() subject.tableloader({}, {}, {}, { context = first }) end,
            function() subject.resolve_source(first, "cached") end,
            function() subject.restore_source_object(first, "cached", {}, {}) end,
            function() subject.resolution_plan(first) end,
            function() subject.finalize_resolver_context(first) end,
            function() subject.completion_binary_catalog(first) end,
            function() plan.linked("planned") end,
            function() plan.provider_file("planned") end,
            function() plan.digest("planned", "public") end,
            function() plan.update("planned", {}) end,
            function() plan.accepted("planned") end,
        }) do assert.has_error(action, message) end
        assert(subject.assert_target_context(browser))
    end)

    it("invalidates browser semantic caches when descriptor identity changes", function()
        local first = context("browser")
        subject.imported.owner = { kind = "source" }
        types.registry["owner.Record"] = {}
        -- A changed descriptor is a different target identity, even though the
        -- selected source label stays browser.
        local changed = descriptor(root, true)
        assert.not_equal(first.target_descriptor.identity, changed.identity)
        local next_context = context("browser", changed)
        assert(subject.assert_target_context(next_context))
        assert.is_nil(subject.imported.owner)
        assert.is_nil(types.registry["owner.Record"])
        assert.has_error(function() subject.activate_target_caches(first, first.target_descriptor.identity) end,
            "compiler caches now belong to target " .. changed.identity .. "; create a new context")
    end)

    it("keeps a native module named browser.member in the native module namespace", function()
        files.write(root .. "/browser/member.native.titan", "function answer(): integer return 42 end\n")
        files.write(root .. "/browser/member.browser.titan", "function answer(): string return 'browser' end\n")
        local ctx = context()
        loaded(subject.defaultloader({}, { context = ctx, source_roots = { ["browser.member"] = true } }), "browser.member")
        assert.equal(root .. "/browser/member.native.titan", subject.imported["browser.member"].filename)
    end)
end)

describe("native provider fixture cleanup", function()
    local fixture, saved_windows, saved_remove
    before_each(function()
        saved_windows, saved_remove = platform.windows, os.remove
        fixture = files.new()
    end)
    after_each(function()
        platform.windows, os.remove = saved_windows, saved_remove
        files.remove(fixture.root)
    end)
    local function deny_removal(filename, code)
        local selected = path.normalize(filename)
        os.remove = function(candidate)
            if path.normalize(candidate) == selected then
                return nil, "injected unlink failure", code
            end
            return saved_remove(candidate)
        end
    end
    it("retains only a recorded mapped Windows DLL and its ancestors while removing every other artifact", function()
        local image = fixture.output .. "/warm/provider.dll"
        local unloaded = fixture.output .. "/unloaded.dll"
        local sidecar = fixture.output .. "/sidecar.txt"
        files.write(image, "mapped provider")
        files.write(unloaded, "unloaded provider")
        files.write(sidecar, "other artifact")
        platform.windows = true
        deny_removal(image, 13)
        fixture:close({ path.from_slash(image) })
        assert.equal("mapped provider", files.read(image))
        assert.is_nil(lfs.attributes(unloaded))
        assert.is_nil(lfs.attributes(sidecar))
        assert.is_nil(lfs.attributes(fixture.source))
        assert.is_nil(lfs.attributes(fixture.frontend))
        local entries = {}
        for name in lfs.dir(fixture.root) do
            if name ~= "." and name ~= ".." then entries[#entries + 1] = name end
        end
        assert.same({ "out" }, entries)
    end)
    for _, case in ipairs({
        { name = "an unrecorded Windows DLL", windows = true, filename = "provider.dll", recorded = "other.dll", code = 13 },
        { name = "strict cleanup without loaded images", windows = true, filename = "provider.dll", code = 13 },
        { name = "a recorded non-DLL artifact", windows = true, filename = "provider.o", recorded = "provider.o", code = 13 },
        { name = "an unexpected error on a recorded Windows DLL", windows = true, filename = "provider.dll", recorded = "provider.dll", code = 5 },
        { name = "a recorded DLL on POSIX", windows = false, filename = "provider.dll", recorded = "provider.dll", code = 13 },
    }) do
        it("reports removal failure for " .. case.name, function()
            local image = fixture.output .. "/" .. case.filename
            files.write(image, "unremoved artifact")
            local images = case.recorded and { fixture.output .. "/" .. case.recorded } or nil
            platform.windows = case.windows
            deny_removal(image, case.code)
            local ok, failure = pcall(function() fixture:close(images) end)
            assert.is_false(ok)
            assert.is_table(failure)
            assert.matches("injected unlink failure$", failure.message)
            assert.equal("unremoved artifact", files.read(image))
        end)
    end
end)

describe("browser output-root ownership", function()
    local subject, root, marker, strategy, locks, saved_registry
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
        marker = path.join(root, ".titan-target")
        saved_registry = types.registry
        subject, strategy = fresh_driver(), compiler_io.new_sync()
    end)
    after_each(function()
        if locks then assert(locks:release()); locks = nil end
        types.registry = saved_registry
        files.remove(root)
    end)
    local function ctx(target)
        local value = { io = strategy, target = target }
        assert(subject.activate_target_caches(value, target))
        return value
    end
    local function claim(target, directory, create)
        return subject.validate_output_target(ctx(target), directory or root, create ~= false)
    end
    local function conflict(marked, selected)
        return string.format("output root %q belongs to target %q, not %q; use a separate --output directory", root, marked, selected)
    end
    it("marks a fresh browser root after taking its lock, and accepts warm roots without rewriting the marker", function()
        locks = assert(build.lock_outputs(strategy, { root }))
        assert(claim("browser"))
        assert.equal("browser\n", files.read(marker))
        files.write(root .. "/module.o", "object")
        local past = os.time() - 120
        assert(lfs.touch(marker, past, past))
        assert(claim("browser"))
        assert.equal(past, lfs.attributes(marker, "modification"))
        local ok, message = claim("linux")
        assert.is_nil(ok); assert.equal(conflict("browser", "linux"), message)
        ok, message = claim("native", nil, false)
        assert.is_nil(ok); assert.equal(conflict("browser", "native"), message)
    end)
    it("refuses unmarked nonempty browser roots and does not create a marker for hosts", function()
        files.write(root .. "/module.o", "native object")
        assert(claim("linux"))
        assert.is_nil(lfs.attributes(marker))
        local ok, message = claim("browser")
        assert.is_nil(ok)
        assert.equal(string.format("browser output root %q is not empty and has no .titan-target marker; use a separate --output directory", root), message)
        assert.equal("native object", files.read(root .. "/module.o"))
    end)
    it("recognizes host markers, rejects mismatches in both directions, and allows separate roots", function()
        files.write(marker, "linux\n")
        assert(claim("linux"))
        local ok, message = claim("browser")
        assert.is_nil(ok); assert.equal(conflict("linux", "browser"), message)
        local browser_root = root .. "/browser-out"
        files.mkdir(browser_root)
        assert(claim("browser", browser_root))
        assert(claim("linux"))
        assert.equal("linux\n", files.read(marker))
    end)
    it("rejects malformed, unreadable, and non-file markers without relabeling", function()
        for _, content in ipairs({ "", "browser", "Browser\n", "browser\nlinux\n", "unknown\n", "browser\r\n", string.rep("x", 17) }) do
            files.write(marker, content)
            local ok, message = claim("browser")
            assert.is_nil(ok)
            assert.equal(string.format("cannot read target marker %q: invalid target marker", marker), message)
            assert.equal(content, files.read(marker))
        end
        files.write(marker, "browser\n")
        local original = strategy.read_file
        function strategy:read_file(filename)
            if filename == marker then return nil, "read denied" end
            return original(self, filename)
        end
        local ok, message = claim("browser")
        assert.is_nil(ok); assert.equal(string.format("cannot read target marker %q: read denied", marker), message)
        strategy.read_file = original
        assert(os.remove(marker)); files.mkdir(marker)
        ok, message = claim("browser")
        assert.is_nil(ok); assert.matches("invalid target marker", message, 1, true)
    end)
    it("reports marker write and inspection failures", function()
        function strategy:write_file() return nil, "write denied" end
        local ok, message = claim("browser")
        assert.is_nil(ok); assert.equal(string.format("cannot write target marker %q: write denied", marker), message)
        function strategy:lstat() return nil, "stat denied" end
        ok, message = claim("browser")
        assert.is_nil(ok); assert.equal(string.format("cannot read target marker %q: stat denied", marker), message)
    end)
end)

describe("browser object and link certificate identity", function()
    local root
    local function tool_path(name)
        return path.join(root, name .. (platform.windows and ".exe" or ""))
    end
    before_each(function()
        root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
    end)
    after_each(function() files.remove(root) end)
    local function tool_context()
        local strategy = compiler_io.new_sync()
        function strategy:executable() return true end
        function strategy:run() error("certificate unexpectedly ran a native tool") end
        return { io = strategy }
    end
    it("hashes browser target identity in toolchain details while keeping the native table unchanged", function()
        local tool = tool_path("compiler")
        files.write(tool, "controlled compiler bytes")
        local ctx = tool_context()
        local request = { compiler_argv = { tool }, preprocessor_identity = "macros",
            banner = "clang version 22.1.8 (fixture)", stage_tools = {} }
        local native, native_details = incremental.toolchain_identity(ctx, request)
        assert.is_string(native)
        assert.same({ preprocessor = "macros", banner = request.banner,
            tools = native_details.tools, stage_policy = "llvm" }, native_details)
        assert.equal(native, incremental.digest(ctx, "toolchain", native_details))
        request.target_identity = descriptor(root).identity
        local browser, browser_details = incremental.toolchain_identity(ctx, request)
        assert.not_equal(native, browser)
        assert.equal(request.target_identity, browser_details.target_identity)
        assert.equal(browser, incremental.digest(ctx, "toolchain", browser_details))
        request.target_identity = request.target_identity .. "-changed"
        assert.not_equal(browser, incremental.toolchain_identity(ctx, request))
        request.target_identity = nil
        assert.equal(native, incremental.toolchain_identity(ctx, request))
    end)
    it("uses archive tools only and refuses cross-target link records without changing the output-only key", function()
        files.write(root .. "/provider.a", "published archive")
        local ar, ranlib = tool_path("emar"), tool_path("emranlib")
        files.write(ar, "archive tool")
        files.write(ranlib, "archive index tool")
        local ctx = tool_context()
        ctx.target_descriptor = descriptor(root)
        local tools = assert(certificate.output_tools(ctx, { tools = {
            ar = { ar }, ranlib = { ranlib } } }))
        assert.is_table(tools.ar); assert.is_table(tools.ranlib); assert.is_nil(tools.linker)
        assert.equal("archive", certificate.linker_backend(ctx))
        local opaque = certificate.native_library_policy(ctx, { argv = { "@opaque-link-input" } })
        assert.is_false(opaque.cacheable)
        assert.equal("opaque linker input mechanism: @opaque-link-input", opaque.reason)
        local spec = { output_root = root, outputs = { root .. "/provider.a" },
            kind = "library", policy = { target = "native-profile" }, native_libraries = { backend = "gnu" } }
        local browser = certificate.prepare(ctx, spec)
        assert.equal(ctx.target_descriptor.identity, browser.recipe.policy.target)
        assert.equal("native-profile", spec.policy.target)
        assert.is_true(browser.cacheable)
        assert(certificate.commit(ctx, browser))
        assert.is_true(certificate.check(ctx, certificate.prepare(ctx, spec)))
        ctx.target_descriptor = descriptor(root, true)
        local changed = certificate.prepare(ctx, spec)
        assert.equal(browser.key, changed.key)
        assert.not_equal(browser.input, changed.input)
        assert.is_false(certificate.check(ctx, changed))
        ctx.target_descriptor = nil
        spec.native_libraries = { backend = "lld", dependency_file = root .. "/native.d" }
        files.write(root .. "/native.d", root .. "/provider.a:\n")
        local native = certificate.prepare(ctx, spec)
        assert.equal(browser.key, native.key)
        assert.not_equal(browser.input, native.input)
        assert.equal("native-profile", native.recipe.policy.target)
        assert.is_false(certificate.check(ctx, native))
        assert(certificate.commit(ctx, native))
        local before = files.read(native.record)
        assert.is_true(certificate.check(ctx, certificate.prepare(ctx, spec)))
        assert.equal(before, files.read(native.record))
    end)
end)

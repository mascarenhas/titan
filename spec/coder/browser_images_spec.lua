local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local driver = require "titan-compiler.driver"
local linkcertificate = require "titan-compiler.linkcertificate"
local fixtures = require "spec.support.browser_fixtures"
local toolchain = require "spec.support.browser_toolchain"
local staticmetadata = require "titan-compiler.staticmetadata"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local process = require "titan-compiler.process"
local repository = toolchain.repository
local sdk_remedy = platform.windows and "mingw32-make -f Makefile.win browser-sdk" or "make browser-sdk"
local workspace

local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = assert(file:read("a")); assert(file:close())
    return bytes
end
local function run(argv)
    return compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
end
local function maximum_declared_locals(bytes)
    local image = assert(staticmetadata.browser_trace_image(bytes))
    local maximum = 0
    for _, range in ipairs(image.function_ranges) do
        local position = range[1]
        local function u32()
            local value, factor = 0, 1
            for _ = 1, 5 do
                assert.is_true(position < range[2], "truncated function local declaration")
                local digit = bytes:byte(position + 1)
                position = position + 1
                value = value + (digit & 127) * factor
                if digit < 128 then return value end
                factor = factor * 128
            end
            error("overlong function local declaration")
        end
        local count = 0
        for _ = 1, u32() do
            count = count + u32()
            assert.is_true(position < range[2], "missing function local type")
            position = position + 1
        end
        maximum = math.max(maximum, count)
    end
    return maximum
end

local function cli(info, ...)
    local setup = string.format("package.path=%q..package.path;",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. (info.compiler_setup or "")
    local argv = { "env", "TITAN_ROOT=" .. (info.sdk_prefix or info.prefix), "TITAN_TARGET=", "TITAN_PATH_0_6=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=" .. (info.extra_cflags or ""),
        "TITAN_EXTRA_LDFLAGS=", "TITAN_BUILD_PROFILE=" .. (info.profile or driver.BUILD_PROFILE),
        info.lua, "-E", "-e", setup, repository .. "/titanc",
        "-q", "--target", "browser", "--tree", workspace .. "/src", "-o", info.output or workspace .. "/out" }
    for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
    return run(argv)
end

local function c_image(info, name, worker, flags)
    local output = workspace .. "/out"
    files.mkdir(output)
    local quoted_flags = {}
    for _, flag in ipairs(flags or {}) do quoted_flags[#quoted_flags + 1] = string.format("%q", flag) end
    local script = string.format([[
local driver = require "titan-compiler.driver"
driver.TITAN_SOURCE_PATH = %q
local output, name, worker = %q, %q, %q
local context = driver.new_resolver_context({ target = "browser", output_root = output })
local ok, why, code = driver.compile_browser_image(driver.browser_c_image_contents(worker),
    output .. "/" .. name .. ".c", output .. "/" .. name .. ".mjs", {}, {}, {}, false,
    { context = context, profile = { purpose = "protocol" }, final_link_flags = { %s } })
assert(ok, tostring(why) .. (code and (", exit " .. code) or ""))
assert(driver.close_resolver_context(context))
]], workspace .. "/src", output, name, worker, table.concat(quoted_flags, ","))
    -- Keep literal C line continuations out of the host command line.
    local filename = workspace .. "/" .. name .. "-build.lua"
    files.write(filename, string.format("package.path=%q..package.path;",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script)
    local result = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        info.lua, "-E", filename })
    assert.is_true(result.ok, result.output or result.diagnostic)
    return output .. "/" .. name .. ".mjs"
end

local function image_identity(info, image, source)
    local result = run({ info.node.path, "--input-type=module", "-e", [[
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const image = process.argv[1];
const map = JSON.parse(await readFile(image.replace(/\.mjs$/, '.wasm.map'), 'utf8'));
const expectedSource = process.argv[2];
if (expectedSource) {
    assert.ok(map.sources.some(source => source.replaceAll('\\', '/').split('/').at(-1) === expectedSource),
        'final source map omitted ' + expectedSource);
}
const create = (await import(pathToFileURL(image).href)).default;
const instance = create({locateFile: name => resolve(dirname(image), name)});
try {
    assert.deepEqual(Object.keys(instance).sort(),
        ['initialize', 'run', 'call', 'callTask', 'notify', 'drain', 'dispose', 'trace'].sort());
    await instance.initialize();
    assert.ok(Object.isFrozen(instance.trace));
    // Ready means the eager adapter checked the private C export's identity
    // against this map. No raw Module/heap/factory escapes the public creator.
    assert.equal(instance.trace.state, 'ready', instance.trace.reason);
    const identity = map.x_titan_image;
    assert.match(identity, /^[0-9a-f]{64}$/);
    assert.ok(Number.isInteger(map.x_titan_function_imports));
    assert.ok(map.x_titan_function_ranges.length > 0);
    assert.equal(map.x_titan_function_names.length,
        map.x_titan_function_imports + map.x_titan_function_ranges.length);
    process.stdout.write(identity);
} finally { await instance.dispose(); }
]], image, source or "" })
    assert.is_true(result.ok, result.output or result.diagnostic)
    return result.output
end

local function native_trace()
    local prefix = require("spec.support.installed_prefix").active()
    local suffix = platform.windows and ".exe" or ""
    local script = string.format([[
local driver = require "titan-compiler.driver"
local context = driver.new_resolver_context({ target = %q })
assert(driver.configure_foreign_c(context))
local runtime, fixture, output, prefix = %q, %q, %q, %q
local function append(argv, extra)
    for _, argument in ipairs(extra) do argv[#argv + 1] = argument end
    return argv
end
local function command(argv)
    local result = context.io:run(argv, { stderr_to_stdout = true })
    assert(result.ok, result.output or result.diagnostic)
    return result
end
local compile = assert(driver.generated_compile_prefix(context))
append(compile, { "-DTITAN_NO_LIBBACKTRACE", "-c", runtime, "-o", output .. ".runtime.o" })
command(compile)
compile = assert(driver.authored_c_compile_prefix(context))
append(compile, { "-c", fixture, "-o", output .. ".fixture.o" })
command(compile)
local link = assert(driver.authored_c_compile_prefix(context))
append(link, { "-o", output, output .. ".fixture.o", output .. ".runtime.o" })
append(link, driver.installed_link_inputs(driver.installed_paths(prefix), driver.IS_DARWIN))
if driver.UNAME == "Linux" then link[#link + 1] = "-rdynamic" end
command(link)
io.write(command({ output }).output)
assert(driver.close_resolver_context(context))
]], files.host(), repository .. "/titan-runtime/titan.c",
        repository .. "/spec/fixtures/browser_images/native-trace.c",
        workspace .. "/trace" .. suffix, prefix)
    local result = process.capture({ prefix .. "/bin/lua" .. suffix, "-E", "-e",
        string.format("package.path=%q..package.path;", repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script },
        { env = { TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_BUILD_PROFILE = "validation",
            PATH = prefix .. "/bin" .. (platform.windows and ";" or ":") .. (os.getenv("PATH") or ""),
            TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" } })
    assert.is_true(result.ok, result.output or result.diagnostic)
    return result.output
end

describe("browser stock Lua initialization", function()
    it("applies the profile inside initialization but never in a native entrypoint", function()
        local browser = driver.browser_entrypoint_contents("profile_app", "profile-app")
        local opened = assert(browser:find("luaL_openlibs(L);", 1, true))
        local searcher = assert(browser:find("titan_install_searcher(L);", opened, true))
        local profile = assert(browser:find(
            "if (luaL_loadstring(L, TITAN_LUA_BROWSER_PROFILE) != LUA_OK) return lua_error(L);",
            searcher, true))
        local called = assert(browser:find("lua_call(L, 0, 0);", profile, true))
        local root = assert(browser:find('lua_pushliteral(L, "profile_app");', called, true))
        assert.is_true(opened < searcher and searcher < profile and profile < called and called < root)
        -- Windows entrypoints name their provider; other targets ignore it.
        local native = driver.entrypoint_contents("profile_app", "profile-app",
            { provider = "profile_app.dll" })
        assert.is_nil(native:find("TITAN_LUA_BROWSER_PROFILE", 1, true))
    end)
end)

describe("browser image profile and SDK readiness", function()
    local IDENTITY = string.rep("0123456789abcdef", 4)
    -- The SDK factory's module surface: named test seams, then one trailing
    -- default export naming the instantiate function the loader receives.
    local FACTORY = "export function createTrace(views) { return views; }\n" ..
        "export function createWasiImports(bridge) { return bridge; }\n" ..
        "const here = import.meta.url;\n" ..
        "async function instantiate(owner) { return owner; }\n" ..
        "export default instantiate;\n"
    local LOADER = "export function create(factory, options, image) { return {factory, options, image}; }\n"
    local PURPOSES = { "program", "test", "protocol", "gate", "minicoro", "budget", "baseline" }
    -- The pinned link and post-link contract, hand-written so the spec pins it
    -- instead of borrowing the implementation.
    local function link_flags(budgets, gate)
        budgets = budgets or {}
        local flags = { "-mexec-model=reactor", "-Wl,--stack-first",
            "-Wl,-z,stack-size=" .. (budgets.stack_size or 1048576),
            "-Wl,--initial-heap=" .. (budgets.initial_heap or 15728640),
            "-Wl,--max-memory=" .. (budgets.maximum_memory or 2147483648),
            "-Wl,--gc-sections", "-Wl,--export-table",
            "-Wl,--export=__stack_pointer", "-Wl,--export=__stack_low", "-Wl,--export=__stack_high" }
        if gate then
            flags[#flags + 1] = "-Wl,--export=titan_browser_gate_guarded"
            flags[#flags + 1] = "-Wl,--export=titan_browser_gate_observe"
        end
        for _, library in ipairs({ "-lc-printscan-long-double", "-lsetjmp", "-lwasi-emulated-process-clocks" }) do
            flags[#flags + 1] = library
        end
        return flags
    end
    local function optimizer_flags(level, skip)
        local flags = { level, "--debuginfo", "--stack-check" }
        if skip then
            flags[#flags + 1] = "--skip-pass=inlining-optimizing"
            flags[#flags + 1] = "--skip-pass=duplicate-function-elimination"
        end
        for _, feature in ipairs({ "--enable-exception-handling", "--enable-multivalue", "--enable-bulk-memory",
                "--enable-mutable-globals", "--enable-sign-ext", "--enable-nontrapping-float-to-int",
                "--enable-reference-types" }) do
            flags[#flags + 1] = feature
        end
        return flags
    end
    local function count(list, value)
        local found = 0
        for _, item in ipairs(list) do
            if item == value then found = found + 1 end
        end
        return found
    end

    it("embeds the SDK factory and loader and exposes only the persistent image creator", function()
        local embedded = assert(browserlink.embed(FACTORY, LOADER, "app.wasm", IDENTITY))
        -- The named seams stay private declarations; only `create` is exported.
        assert.truthy(embedded:find("^function createTrace%(views%)"), embedded)
        assert.truthy(embedded:find("\nfunction createWasiImports(bridge)", 1, true), embedded)
        assert.truthy(embedded:find("\nconst here = import.meta.url;\n", 1, true), embedded)
        assert.truthy(embedded:find("\nasync function instantiate(owner)", 1, true), embedded)
        assert.is_nil(embedded:find("export function", 1, true))
        assert.is_nil(embedded:find("export default instantiate", 1, true))
        assert.truthy(embedded:find("\nconst titanCreate = (() => {\nfunction create(factory, options, image)",
            1, true), embedded)
        assert.truthy(embedded:find("\nreturn create;\n})();\n", 1, true), embedded)
        assert.truthy(embedded:find("\nexport default function create(options = {}) {\n", 1, true), embedded)
        assert.truthy(embedded:find("options.locateFile ?? (name => name.endsWith('.wasm.trace') ?", 1, true),
            embedded)
        -- Both resources stay visible to bundlers as `new URL` literals.
        assert.truthy(embedded:find('new URL("app.wasm.trace", import.meta.url).href', 1, true), embedded)
        assert.truthy(embedded:find('new URL("app.wasm", import.meta.url).href', 1, true), embedded)
        assert.truthy(embedded:find('return titanCreate(instantiate, {...options, locateFile}, {identity: "' ..
            IDENTITY .. '", wasm: "app.wasm", directory: new URL(\'.\', import.meta.url).href});', 1, true),
            embedded)
        local _, exports = embedded:gsub("export ", "")
        assert.equal(1, exports)
    end)

    it("rejects unsupported factory and loader surfaces before image publication", function()
        for _, factory in ipairs({
            "async function instantiate(owner) { return owner; }\n",
            "export default instantiate;\nconst late = 1;\n",
            "export default first;\nexport default instantiate;\n",
            "export default function instantiate() {}\n",
            "export const seam = 1;\nexport default instantiate;\n",
            "export { instantiate as other };\nexport default instantiate;\n",
            "import runtime from './runtime.mjs';\nexport default instantiate;\n",
            "const a = 1;\n  import './side.mjs';\nexport default instantiate;\n",
        }) do
            local embedded, err = browserlink.embed(factory, LOADER, "app.wasm", IDENTITY)
            assert.is_nil(embedded, factory)
            assert.equal("browser factory has an unsupported module surface", err)
        end
        for _, loader in ipairs({
            "function create() {}\n",
            "export function create() {}\nexport const module = {};\n",
            "export const first = 1;\nexport function create() {}\n",
            "import runtime from './runtime.mjs';\nexport function create() {}\n",
            "export function create() {}\nimport './late.mjs';\n",
        }) do
            local embedded, err = browserlink.embed(FACTORY, loader, "app.wasm", IDENTITY)
            assert.is_nil(embedded, loader)
            assert.equal("browser loader has an unsupported module surface", err)
        end
        for _, identity in ipairs({ IDENTITY:upper(), IDENTITY:sub(2), IDENTITY .. "0", "", 42 }) do
            local embedded, err = browserlink.embed(FACTORY, LOADER, "app.wasm", identity)
            assert.is_nil(embedded)
            assert.equal("browser image identity must be 64 lowercase hexadecimal digits", err)
        end
        local embedded = assert(browserlink.embed(FACTORY, LOADER, 'a"b\n.wasm', IDENTITY))
        assert.truthy(embedded:find('new URL("a\\u0022b\\u000a.wasm", import.meta.url)', 1, true), embedded)
        assert.truthy(embedded:find('new URL("a\\u0022b\\u000a.wasm.trace", import.meta.url)', 1, true), embedded)
        assert.truthy(embedded:find('wasm: "a\\u0022b\\u000a.wasm", directory', 1, true), embedded)
    end)

    it("derives the closed SDK asset set without extending BrowserPaths", function()
        local paths = fixtures.paths()
        local assets = browserlink.sdk_assets(paths)
        local join = require("titan-compiler.path").join
        assert.equal(paths.libtitan, assets.runtime)
        assert.equal(paths.sdk_digests, assets.sdk_digests)
        assert.equal(join(paths.titan_bin, "titan-wasm-factory.mjs"), assets.factory)
        assert.equal(join(paths.titan_bin, "titan-browser.mjs"), assets.loader)
        local keys = {}
        for key in pairs(assets) do keys[#keys + 1] = key end
        table.sort(keys)
        assert.same({ "build_profile", "factory", "loader", "lpeglabel", "node_worker", "page", "provider",
            "runner", "runner_module", "runtime", "sdk_digests" }, keys)
    end)

    it("requires only readable runtime and JS assets, in bootstrap order", function()
        local descriptor = fixtures.descriptor()
        local assets = browserlink.sdk_assets(descriptor.paths)
        local present = {}
        local make = sdk_remedy
        local context = { io = {
            stat = function(_, filename) return present[filename] and { kind = "file" } end,
            read_file = function(_, filename)
                return present[filename] and (filename == assets.build_profile and descriptor.build_profile .. "\n" or "bytes")
            end,
        } }
        for _, key in ipairs({ "runtime", "factory", "loader", "runner", "runner_module", "node_worker",
                "page", "build_profile" }) do
            local found, err = browserlink.require_sdk(context, descriptor, { prefix = "/prefix", rocks_tree = "/rocks" })
            assert.is_nil(found)
            assert.equal("browser SDK is incomplete: missing " .. string.format("%q", assets[key]) ..
                "; run '" .. make .. " PREFIX=/prefix ROCKS_TREE=/rocks'", err)
            present[assets[key]] = true
        end
        if platform.windows then
            local paths = require "titan-compiler.path"
            for _, relative in ipairs(browserlink.windows_runner_files(driver.TITAN_LIBRARY_VERSION)) do
                present[paths.join(descriptor.paths.root, relative)] = true
            end
        end
        assert.same(assets, assert(browserlink.require_sdk(context, descriptor, { prefix = "/prefix" })))
        present[assets.runtime] = nil
        local _, err = browserlink.require_sdk(context, descriptor, { prefix = "/prefix" })
        assert.truthy(err:find("run '" .. make .. " PREFIX=/prefix'", 1, true))
    end)

    it("renders the host calendar and the named entry exports in every launcher", function()
        local source = driver.browser_c_image_contents(
            "static int titan_browser_worker(lua_State *L) { return 0; }")
        for _, header in ipairs({ "errno.h", "time.h" }) do
            assert.truthy(source:find("#include <" .. header .. ">", 1, true), header)
        end
        -- wasi-libc's calendar is UTC-only: local time comes from the host.
        for _, text in ipairs({
            "struct tm *localtime_r(const time_t *restrict t, struct tm *restrict tm) {",
            "if (!titan_browser_localtime((int64_t)*t, tm)) {",
            "struct tm *localtime(const time_t *t) {",
            "time_t mktime(struct tm *tm) {",
            "t = titan_browser_mktime(tm);",
            "errno = EOVERFLOW;",
            "tm->__tm_zone = zone;",
        }) do
            assert.truthy(source:find(text, 1, true), text)
        end
        -- Each entry names its own export; the link exports nothing else by name.
        for _, name in ipairs({ "titan_browser_initialize", "titan_browser_entry", "titan_browser_invoke",
                "titan_browser_release_callable", "titan_browser_close" }) do
            assert.truthy(source:find('TITAN_WASM_EXPORT("' .. name .. '")\nint ' .. name .. "(", 1, true), name)
        end
        -- The factory's allocator exports call the program's malloc and free,
        -- so -Wl,--wrap=malloc,--wrap=free wrappers see the host's blocks too.
        for _, text in ipairs({
            'TITAN_WASM_EXPORT("malloc")\nvoid *titan_browser_export_malloc(size_t size) {\n    return malloc(size);\n}',
            'TITAN_WASM_EXPORT("free")\nvoid titan_browser_export_free(void *block) {\n    free(block);\n}',
        }) do
            assert.truthy(source:find(text, 1, true), text)
        end
        -- Output reaches the host through WASI fd_write, not a launcher shim.
        for _, name in ipairs({ "emscripten", "__wasi_fd_write", "__syscall_", "titan_browser_host_output" }) do
            assert.is_nil(source:find(name, 1, true), name)
        end
    end)

    it("links a validation program as a stack-checked reactor exporting the factory's interface", function()
        local descriptor = fixtures.descriptor()
        local profile = assert(browserlink.profile(descriptor, { purpose = "program" }))
        assert.same({}, profile.compile_flags)
        assert.same(link_flags(), profile.link_flags)
        assert.same(optimizer_flags("-O1"), profile.optimizer_flags)
        assert.same({ target_identity = descriptor.identity, profile = "validation", purpose = "program",
            optimization = "-O1", backend = "jspi",
            budgets = { stack_size = 1048576, initial_heap = 15728640, maximum_memory = 2147483648 },
            link_flags = profile.link_flags, optimizer_flags = profile.optimizer_flags,
            compile_flags = profile.compile_flags }, profile.identity_inputs)
    end)

    it("gives production programs the descriptor level and the same link", function()
        local descriptor = fixtures.descriptor(nil, { build_profile = "production" })
        local profile = assert(browserlink.profile(descriptor, { purpose = "program" }))
        assert.same({}, profile.compile_flags)
        assert.same(link_flags(), profile.link_flags)
        assert.same(optimizer_flags("-O3"), profile.optimizer_flags)
        assert.equal(descriptor.identity, profile.identity_inputs.target_identity)
        assert.equal("-O3", profile.identity_inputs.optimization)
        assert.equal("production", profile.identity_inputs.profile)
    end)

    it("skips Binaryen inlining and function folding only in a production test image", function()
        local production = fixtures.descriptor(nil, { build_profile = "production" })
        local profile = assert(browserlink.profile(production, { purpose = "test" }))
        assert.same(link_flags(), profile.link_flags)
        assert.same(optimizer_flags("-O3", true), profile.optimizer_flags)
        -- The validation profile's test images keep #330's frozen program profile.
        local frozen = assert(browserlink.profile(fixtures.descriptor(), { purpose = "test" }))
        local program = assert(browserlink.profile(fixtures.descriptor(), { purpose = "program" }))
        assert.same(program.link_flags, frozen.link_flags)
        assert.same(program.optimizer_flags, frozen.optimizer_flags)
        -- Harness purposes are not test images, even when the installation optimizes.
        for _, purpose in ipairs({ "protocol", "gate", "minicoro", "budget", "baseline" }) do
            local harness = assert(browserlink.profile(production, { purpose = purpose }))
            assert.same(optimizer_flags("-O3"), harness.optimizer_flags, purpose)
            assert.same(link_flags(nil, purpose == "gate"), harness.link_flags, purpose)
        end
    end)

    it("keeps internal gate, budget and baseline variants constrained", function()
        local descriptor = fixtures.descriptor()
        local gate = assert(browserlink.profile(descriptor, { purpose = "gate" }))
        assert.same(link_flags(nil, true), gate.link_flags)
        for _, case in ipairs({
            { nil, "browser link profile options are required" },
            { "program", "browser link profile options are required" },
            { {}, "invalid browser link profile purpose" },
            { { purpose = "image" }, "invalid browser link profile purpose" },
            -- Emscripten's assertion level and interpreter entry are gone, not ignored.
            { { purpose = "program", assertions = 2 }, "unknown browser link profile option assertions" },
            { { purpose = "baseline", entry = "lua-main" }, "unknown browser link profile option entry" },
            { { purpose = "program", unknown = true }, "unknown browser link profile option unknown" },
            { { purpose = "protocol", optimization = "O2" }, "invalid browser link optimization override" },
            { { purpose = "baseline", optimization = "O3" }, "invalid browser link optimization override" },
            { { purpose = "budget", optimization = "Os" }, "invalid browser link optimization override" },
            { { purpose = "program", budgets = {} }, "browser budget overrides require the budget profile" },
            { { purpose = "budget", budgets = 65536 }, "browser budget overrides require the budget profile" },
            { { purpose = "budget", budgets = { stack_size = 17 } }, "invalid browser budget override stack_size" },
            { { purpose = "budget", budgets = { stack_size = 0 } }, "invalid browser budget override stack_size" },
            { { purpose = "budget", budgets = { stack_size = 65536.0 } },
                "invalid browser budget override stack_size" },
            { { purpose = "budget", budgets = { initial_memory = 16777216 } },
                "invalid browser budget override initial_memory" },
            { { purpose = "budget", budgets = { initial_heap = 32768 } },
                "invalid browser budget override initial_heap" },
            { { purpose = "budget", budgets = { maximum_memory = 65552 } },
                "invalid browser budget override maximum_memory" },
            { { purpose = "budget", budgets = { initial_heap = 2146500608 } }, "invalid browser memory budgets" },
            -- Aligned values whose sum with the other budget would wrap.
            { { purpose = "budget", budgets = { initial_heap = 0x7fffffffffff0000 } },
                "invalid browser memory budgets" },
            { { purpose = "budget", budgets = { stack_size = 0x7ffffffffffffff0 } },
                "invalid browser memory budgets" },
            { { purpose = "budget", budgets = { stack_size = 2147483648 } }, "invalid browser memory budgets" },
            { { purpose = "budget", budgets = { maximum_memory = 2147549184 } }, "invalid browser memory budgets" },
        }) do
            local plan, err = browserlink.profile(descriptor, case[1])
            assert.is_nil(plan)
            assert.equal(case[2], err)
        end
        local budgets = { stack_size = 65536, initial_heap = 65536, maximum_memory = 1048576 }
        local budget = assert(browserlink.profile(descriptor, { purpose = "budget",
            optimization = "O1", budgets = budgets }))
        assert.same(link_flags(budgets), budget.link_flags)
        assert.same({ "-O1" }, budget.compile_flags)
        assert.same(optimizer_flags("-O1"), budget.optimizer_flags)
        assert.same(budgets, budget.identity_inputs.budgets)
        local baseline = assert(browserlink.profile(descriptor, { purpose = "baseline", optimization = "O2" }))
        assert.same(link_flags(), baseline.link_flags)
        assert.same({ "-O2" }, baseline.compile_flags)
        assert.same(optimizer_flags("-O2"), baseline.optimizer_flags)
        assert.equal("-O2", baseline.identity_inputs.optimization)
        local minicoro = assert(browserlink.profile(fixtures.descriptor(nil, { build_profile = "production" }),
            { purpose = "minicoro", optimization = "O1" }))
        assert.same(optimizer_flags("-O1"), minicoro.optimizer_flags)
        local plan, err = browserlink.profile(fixtures.descriptor(nil, { build_profile = "debug" }),
            { purpose = "program" })
        assert.is_nil(plan)
        assert.equal("invalid browser build profile", err)
    end)

    it("links every purpose as a reactor whose JSPI belongs to the factory, and records its identity", function()
        for _, build_profile in ipairs({ "production", "validation" }) do
            for _, purpose in ipairs(PURPOSES) do
                local plan = assert(browserlink.profile(fixtures.descriptor(nil, { build_profile = build_profile }),
                    { purpose = purpose }))
                assert.equal("-mexec-model=reactor", plan.link_flags[1])
                assert.equal("jspi", plan.identity_inputs.backend)
                assert.equal(purpose, plan.identity_inputs.purpose)
                assert.same(plan.link_flags, plan.identity_inputs.link_flags)
                assert.same(plan.optimizer_flags, plan.identity_inputs.optimizer_flags)
                assert.same(plan.compile_flags, plan.identity_inputs.compile_flags)
                for _, flag in ipairs(plan.link_flags) do
                    -- No Emscripten setting, link-time JSPI list or relaxed symbol policy.
                    assert.is_nil(flag:match("^%-s"), flag)
                    assert.is_nil(flag:find("JSPI", 1, true), flag)
                    assert.is_nil(flag:find("undefined", 1, true), flag)
                    assert.is_nil(flag:find("entry", 1, true), flag)
                end
                for _, flag in ipairs(plan.optimizer_flags) do
                    assert.is_nil(flag:find("asyncify", 1, true), flag)
                    assert.is_nil(flag:find("jspi", 1, true), flag)
                    -- wasm-opt 133's --all-features writes imports that V8 refuses.
                    assert.not_equal("--all-features", flag)
                end
            end
        end
    end)

    -- The launcher exports the allocator itself (see the launcher case), so a
    -- wrapped malloc or free never loses the factory's export name.
    it("exports only the factory's memory, table and stack bounds by name, plus the gate entries", function()
        for _, purpose in ipairs(PURPOSES) do
            local plan = assert(browserlink.profile(fixtures.descriptor(), { purpose = purpose }))
            local exports = {}
            for _, flag in ipairs(plan.link_flags) do
                local name = flag:match("^%-Wl,%-%-export=(.+)$")
                if name then exports[#exports + 1] = name end
            end
            local expected = { "__stack_pointer", "__stack_low", "__stack_high" }
            if purpose == "gate" then
                expected[#expected + 1] = "titan_browser_gate_guarded"
                expected[#expected + 1] = "titan_browser_gate_observe"
            end
            assert.same(expected, exports, purpose)
            assert.equal(1, count(plan.link_flags, "-Wl,--export-table"), purpose)
            assert.equal(1, count(plan.link_flags, "-Wl,--stack-first"), purpose)
            assert.equal(1, count(plan.optimizer_flags, "--stack-check"), purpose)
            assert.equal(1, count(plan.optimizer_flags, "--debuginfo"), purpose)
        end
    end)

    it("preserves long-double printf precision in every profile and purpose", function()
        for _, build_profile in ipairs({ "production", "validation" }) do
            for _, purpose in ipairs(PURPOSES) do
                local plan = assert(browserlink.profile(fixtures.descriptor(nil, { build_profile = build_profile }),
                    { purpose = purpose }))
                assert.equal(1, count(plan.link_flags, "-lc-printscan-long-double"))
                assert.same(plan.link_flags, plan.identity_inputs.link_flags)
            end
        end
    end)

    it("pins exnref setjmp/longjmp in every profile and purpose", function()
        for _, build_profile in ipairs({ "production", "validation" }) do
            for _, purpose in ipairs(PURPOSES) do
                local plan = assert(browserlink.profile(fixtures.descriptor(nil, { build_profile = build_profile }),
                    { purpose = purpose }))
                assert.equal(1, count(plan.link_flags, "-lsetjmp"))
                assert.equal(1, count(plan.optimizer_flags, "--enable-exception-handling"))
                for _, flags in ipairs({ plan.link_flags, plan.optimizer_flags }) do
                    for _, flag in ipairs(flags) do assert.is_nil(flag:find("legacy", 1, true), flag) end
                end
                assert.same(plan.optimizer_flags, plan.identity_inputs.optimizer_flags)
            end
        end
    end)

    it("derives the image link purpose and refuses a contrary certified purpose", function()
        local saved_descriptor, saved_options = driver.context_target_descriptor, driver.browser_link_options
        local production = fixtures.descriptor(nil, { build_profile = "production" })
        driver.context_target_descriptor = function() return production end
        local cleanup <close> = setmetatable({}, { __close = function()
            driver.context_target_descriptor, driver.browser_link_options = saved_descriptor, saved_options
        end })
        driver.browser_link_options = nil
        local test_context = { target = "browser", link_kind = "test" }
        local test_plan = assert(driver.browser_link_plan(test_context))
        -- identity_inputs is what titanc records as policy.browser_profile.
        assert.equal("test", test_plan.identity_inputs.purpose)
        assert.equal("production", test_plan.identity_inputs.profile)
        assert.same(optimizer_flags("-O3", true), test_plan.optimizer_flags)
        local program_plan = assert(driver.browser_link_plan({ target = "browser", link_kind = "program" }))
        assert.equal("program", program_plan.identity_inputs.purpose)
        assert.same(optimizer_flags("-O3"), program_plan.optimizer_flags)
        -- A harness purpose is not an image kind and stays usable on either kind.
        driver.browser_link_options = { purpose = "budget" }
        assert.equal("budget", assert(driver.browser_link_plan(test_context)).identity_inputs.purpose)
        assert.equal("budget", assert(driver.browser_link_plan(
            { target = "browser", link_kind = "program" })).identity_inputs.purpose)
        -- A program purpose may never certify or link a test image, or the reverse,
        -- whether the caller passes the kind explicitly (titanc's certificate call
        -- and compile_browser_image's shape) or lets it be derived.
        local program_context = { target = "browser", link_kind = "program" }
        for _, call in ipairs({ { test_context }, { test_context, "test" } }) do
            driver.browser_link_options = { purpose = "program" }
            local refused, err = driver.browser_link_plan(call[1], call[2])
            assert.is_nil(refused)
            assert.equal('browser link purpose "program" does not match this test image', err)
        end
        for _, call in ipairs({ { program_context }, { program_context, "program" } }) do
            driver.browser_link_options = { purpose = "test" }
            local refused, err = driver.browser_link_plan(call[1], call[2])
            assert.is_nil(refused)
            assert.equal('browser link purpose "test" does not match this program image', err)
        end
        -- An agreeing preset still certifies and links, through both shapes.
        for _, call in ipairs({ { test_context }, { test_context, "test" } }) do
            driver.browser_link_options = { purpose = "test" }
            assert.equal("test", assert(driver.browser_link_plan(call[1], call[2])).identity_inputs.purpose)
        end
        -- A preset harness table must name its profile; inheriting the kind
        -- would silently give a measurement build an image's flags.
        driver.browser_link_options = { optimization = "O2" }
        local unnamed, unnamed_error = driver.browser_link_plan(test_context)
        assert.is_nil(unnamed)
        assert.equal("browser link profile options require a purpose", unnamed_error)
    end)

    it("uses Wasm's supported input trace instead of an ELF-only dependency flag", function()
        local context = { target_descriptor = fixtures.descriptor(), link_kind = "test" }
        local backend = linkcertificate.linker_backend(context)
        assert.equal("wasm", backend)
        local policy = linkcertificate.native_library_policy(context,
            { backend = backend, dependency_file = "/out/link.d" })
        assert.is_true(policy.cacheable)
        assert.is_true(policy.capture_trace)
        assert.equal("/out/link.d", policy.dependency_file)
        assert.same({ "-Wl,--trace" }, policy.argv)
    end)

    it("owns the browser artifact set at final validation even on a Darwin host", function()
        local root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
        local previous = driver.IS_DARWIN
        local cleanup <close> = setmetatable({}, { __close = function()
            driver.IS_DARWIN = previous
            files.remove(root)
        end })
        driver.IS_DARWIN = true
        local context = { target = "browser", uname = "Darwin", is_darwin = true }
        local executable, wasm = root .. "/app.mjs", root .. "/app.wasm"
        local dsym, entrypoint = executable .. ".dSYM", root .. "/entrypoint.c"
        files.write(dsym, "unrelated user file")
        local ok, why = driver.validate_program_output_paths({}, executable, entrypoint,
            { dsym }, { wasm, wasm .. ".map", wasm .. ".trace" }, {}, context)
        assert.is_true(ok, why)
        assert.equal("unrelated user file", read(dsym))
        for _, input in ipairs({ wasm, wasm .. ".map", wasm .. ".trace" }) do
            ok, why = driver.validate_program_output_paths({}, executable, entrypoint,
                { input }, { wasm, wasm .. ".map", wasm .. ".trace" }, {}, context)
            assert.is_nil(ok)
            assert.truthy(why:find("aliases input", 1, true), why)
        end
        ok, why = driver.validate_program_output_paths({}, executable, entrypoint,
            {}, { wasm }, {}, { target = "macos" })
        assert.is_nil(ok)
        assert.truthy(why:find(dsym, 1, true), why)
        files.remove(dsym)
        local header = dsym .. "/authored.h"
        files.write(header, "/* user header */")
        ok, why = driver.validate_program_output_paths({}, executable, entrypoint,
            { header }, { wasm }, {}, context)
        assert.is_true(ok, why)
        assert.equal("/* user header */", read(header))
    end)

    it("refuses to link under a build profile other than the SDK's", function()
        local info, why = toolchain.require({ sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/plain.titan", "function main(args: {string}): integer\n    return 0\nend\n")
        local sdk = read(info.sdk_root .. "/build-profile"):match("^(%l+)\n$")
        local other = sdk == "production" and "validation" or "production"
        local result = cli({ prefix = info.prefix, lua = info.lua, profile = other }, "plain")
        assert.is_false(result.ok, "a link under another profile was accepted")
        local log = result.output or result.diagnostic or ""
        -- The diagnosis quotes the descriptor's path spelling, including
        -- escaped backslashes from Windows.
        local make = sdk_remedy
        assert.truthy(log:gsub("\\+", "/"):find(string.format(
            "/lib/titan-browser/0.6\" was built with the %s profile, but this build " ..
            "uses %s; set TITAN_BUILD_PROFILE=%s, or build a %s browser SDK in another prefix with " ..
            "'%s PREFIX=<prefix> TITAN_BUILD_PROFILE=%s'", sdk, other, sdk, other, make, other), 1, true), log)
        assert.is_nil(lfs.attributes(workspace .. "/out/plain.mjs"))
    end)

    it("refuses a preset link profile that names no purpose", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/plain.titan",
            "function answer(): integer\n    return 1\nend\n")
        local result = cli({ prefix = info.prefix, lua = info.lua,
            compiler_setup = "require('titan-compiler.driver').browser_link_options=" ..
                "{budgets={stack_size=65536}};" },
            "-c", "plain")
        assert.is_false(result.ok, "a purposeless preset was accepted")
        local log = result.output or result.diagnostic or ""
        assert.truthy(log:find("browser link profile options require a purpose", 1, true), log)
    end)

    it("reports a CLI compile extra with the compile diagnostic and a link extra with the link one", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/plain.titan",
            "function answer(): integer\n    return 1\nend\n")
        local profile = driver.BUILD_PROFILE
        local compile = "browser " .. profile .. " profile owns compile option "
        local link = "browser " .. profile .. " link profile owns option "
        for _, case in ipairs({
            { arguments = { "-c", "plain", "--cflag=-O2" }, expected = compile .. '"-O2"' },
            { arguments = { "-c", "plain", "--cflag=-fno-inline" }, expected = compile .. '"-fno-inline"' },
            { arguments = { "-c", "plain" }, extra_cflags = "-g2", expected = compile .. '"-g2"' },
            { arguments = { "-c", "plain" }, extra_cflags = "-D_WASI_EMULATED_PROCESS_CLOCKS",
                expected = compile .. '"-D_WASI_EMULATED_PROCESS_CLOCKS"' },
            -- --ldflag is a link-phase option, which -c rejects, so the link
            -- cases run the ordinary build and stop at the ownership check.
            { arguments = { "plain", "--ldflag=-O3" }, expected = link .. "-O3" },
            { arguments = { "plain", "--ldflag=-fno-optimize-sibling-calls" }, expected = link .. "-fno-optimize-sibling-calls" },
            { arguments = { "plain", "--ldflag=-Wl,--export=main" }, expected = link .. "-Wl,--export=main" },
            { arguments = { "plain", "--ldflag=--pre-js=pre.js" }, expected = "browser " .. profile ..
                " link profile does not accept --pre-js; add JavaScript through titan.browser bindings or " ..
                "create({ imports })" },
        }) do
            local result = cli({ prefix = info.prefix, lua = info.lua, extra_cflags = case.extra_cflags },
                table.unpack(case.arguments))
            assert.is_false(result.ok, "the CLI accepted an owned option: " .. case.expected)
            local log = result.output or result.diagnostic or ""
            assert.truthy(log:find(case.expected, 1, true), log)
            local other = case.expected:find("link profile", 1, true) and compile or link
            assert.is_nil(log:find(other, 1, true), log)
        end
    end)

    it("refuses link options that put JavaScript or files into the image", function()
        local javascript = "add JavaScript through titan.browser bindings or create({ imports })"
        for _, case in ipairs({
            { { "--pre-js", "pre.js" }, "--pre-js; " .. javascript },
            { { "--post-js=post.js" }, "--post-js; " .. javascript },
            { { "-lm", "--extern-pre-js", "pre.js" }, "--extern-pre-js; " .. javascript },
            { { "--extern-post-js=post.js" }, "--extern-post-js; " .. javascript },
            { { "--js-library", "library.js" }, "--js-library; " .. javascript },
            { { "--js-library=library.js" }, "--js-library; " .. javascript },
            { { "--embed-file", "data" }, "--embed-file; browser images have no filesystem" },
            { { "--preload-file=data" }, "--preload-file; browser images have no filesystem" },
        }) do
            local ok, err = browserlink.validate_extras(case[1], nil, "production")
            assert.is_nil(ok)
            assert.equal("browser production link profile does not accept " .. case[2], err)
            ok, err = browserlink.validate_extras(case[1], { purpose = "baseline" }, "validation", "compile")
            assert.is_nil(ok)
            assert.equal("browser validation profile does not accept " .. case[2], err)
            ok, err = browserlink.validate_extras(case[1])
            assert.is_nil(ok)
            assert.equal("browser link profile does not accept " .. case[2], err)
        end
    end)

    it("rejects trailing attempts to override profile-owned settings", function()
        local function owned(flags, options, expected)
            local ok, why = browserlink.validate_extras(flags, options)
            assert.is_nil(ok, table.concat(flags, " "))
            assert.equal("browser link profile owns option " .. expected, why)
        end
        -- Optimization, inlining, sibling-call, frame-pointer and debug choices
        -- belong to the build profile, except in the measurement purposes.
        for _, flag in ipairs({ "-O3", "-Os", "-g0", "-gdwarf-5", "-finline-functions", "-fno-inline",
                "-foptimize-sibling-calls", "-fno-optimize-sibling-calls", "-fomit-frame-pointer",
                "-fno-omit-frame-pointer" }) do
            owned({ flag }, nil, flag)
            for _, purpose in ipairs({ "program", "test", "protocol", "gate" }) do
                owned({ flag }, { purpose = purpose }, flag)
            end
            for _, purpose in ipairs({ "baseline", "minicoro", "budget" }) do
                assert.is_true(browserlink.validate_extras({ flag }, { purpose = purpose }))
            end
        end
        -- The target's defines, joined and split, in every purpose.
        for _, name in ipairs({ "TITAN_TARGET_BROWSER", "TITAN_COROUTINE_STACK_SIZE", "TITAN_CODEC_DEPTH_LIMIT",
                "_WASI_EMULATED_PROCESS_CLOCKS" }) do
            for _, purpose in ipairs(PURPOSES) do
                local options = { purpose = purpose }
                owned({ "-D" .. name .. "=1" }, options, "-D" .. name .. "=1")
                owned({ "-D" .. name }, options, "-D" .. name)
                owned({ "-U" .. name }, options, "-U" .. name)
                owned({ "-D", name .. "=1" }, options, "-D")
                owned({ "-U", name }, options, "-U")
            end
        end
        -- Driver options that drop the libraries, start files or symbols the
        -- image needs, set its stack or entry, or select another linker than
        -- the SDK's certified wasm-ld.
        for _, flags in ipairs({ { "-s" }, { "-nostartfiles" }, { "-nostdlib" }, { "-nodefaultlibs" },
                { "-z", "stack-size=65536" }, { "-e", "main" }, { "-fuse-ld=lld" }, { "--ld-path=/usr/bin/ld" },
                { "-B/opt/bin" }, { "--prefix=/opt/bin" }, { "--prefix", "/opt/bin" } }) do
            owned(flags, nil, flags[1])
            owned(flags, { purpose = "baseline" }, flags[1])
        end
        -- Linker options, through -Wl lists and -Xlinker, that place the stack,
        -- size and grow memory, choose the exports, imports and entry, or drop
        -- the names and line tables traces need.
        for _, argument in ipairs({ "--stack-first", "-z", "--stack-size=65536", "--initial-heap=65536",
                "--initial-memory=65536", "--max-memory=65536", "--no-growable-memory", "--export=main",
                "--export-all", "--export-dynamic", "--export-if-defined=main", "--export-memory",
                "--export-table", "--import-memory", "--import-table", "--import-undefined",
                "--allow-undefined", "--allow-undefined-file=imports.txt", "--unresolved-symbols=ignore-all",
                "-e", "--entry=main", "--no-entry", "--shared-memory", "--gc-sections", "--no-gc-sections",
                "-s", "-S", "--strip-all", "--strip-debug", "--global-base=1024", "--table-base=1",
                "--growable-table", "--experimental-pic" }) do
            owned({ "-Wl," .. argument }, nil, "-Wl," .. argument)
            owned({ "-Xlinker", argument }, nil, argument)
            owned({ "-Wl,--wrap=malloc," .. argument }, { purpose = "baseline" }, "-Wl,--wrap=malloc," .. argument)
            -- An option's `--no-` spelling is the same option.
            local name = argument:match("^%-%-([%w-]+)")
            if name and not name:match("^no%-") then
                owned({ "-Wl,--no-" .. name }, nil, "-Wl,--no-" .. name)
                owned({ "-Xlinker", "--no-" .. name }, { purpose = "minicoro" }, "--no-" .. name)
            end
        end
        owned({ "-Wl,-z,stack-size=65536" }, nil, "-Wl,-z,stack-size=65536")
        owned({ "-Wl,-e,main" }, nil, "-Wl,-e,main")
        -- A linker response file could carry any owned option.
        for _, case in ipairs({ { { "-Wl,@link.rsp" }, "-Wl,@link.rsp" }, { { "-Xlinker", "@link.rsp" }, "@link.rsp" },
                { { "-Wl,--wrap=malloc,@link.rsp" }, "-Wl,--wrap=malloc,@link.rsp" } }) do
            local ok, why = browserlink.validate_extras(case[1], { purpose = "budget" })
            assert.is_nil(ok)
            assert.equal("browser link profile does not accept linker response file " .. case[2], why)
            ok, why = browserlink.validate_extras(case[1], { purpose = "program" }, "production", "compile")
            assert.is_nil(ok)
            assert.equal("browser production profile does not accept linker response file " .. case[2], why)
        end
        -- A longer define name is not the owned one; unrelated linker and
        -- library options pass through.
        assert.is_true(browserlink.validate_extras({ "-DTITAN_TARGET_BROWSER_EXTRA=1", "-D", "TITAN_CODEC_DEPTH",
            "-DUSER_DEFINE=1", "-U", "USER_DEFINE", "-lm", "-L/opt/lib", "-Wl,--wrap=malloc",
            "-Xlinker", "--wrap=free", "-Wl,--no-demangle", "-Wl,--trace" }, { purpose = "program" }))
        -- Compile extras are reported by the compile diagnostic, link extras by
        -- the link one (OG-L4): the same option, one owner, one message.
        for _, flag in ipairs({ "-O2", "-g2", "-fno-inline", "-DTITAN_TARGET_BROWSER=1",
                "-D_WASI_EMULATED_PROCESS_CLOCKS", "-UTITAN_CODEC_DEPTH_LIMIT", "-nostdlib", "-Wl,--export=main" }) do
            local ok, why = browserlink.validate_extras({ flag }, { purpose = "gate" }, "production", "compile")
            assert.is_nil(ok)
            assert.equal('browser production profile owns compile option "' .. flag .. '"', why)
            ok, why = browserlink.validate_extras({ flag }, { purpose = "gate" }, "production")
            assert.is_nil(ok)
            assert.equal("browser production link profile owns option " .. flag, why)
        end
        local ok, why = browserlink.validate_extras({ "-O2" }, nil, nil, "compile")
        assert.is_nil(ok)
        assert.equal('browser profile owns compile option "-O2"', why)
        -- The real call path names the installation profile it protects.
        for _, purpose in ipairs({ "program", "test", "gate" }) do
            for _, profile in ipairs({ "production", "validation" }) do
                for _, flag in ipairs({ "-O2", "-g2", "-fno-inline", "-fno-optimize-sibling-calls" }) do
                    ok, why = browserlink.validate_extras({ flag }, { purpose = purpose }, profile)
                    assert.is_nil(ok)
                    assert.equal("browser " .. profile .. " link profile owns option " .. flag, why)
                end
            end
            assert.is_true(browserlink.validate_extras({ "-Wl,--wrap=malloc", "-lm" },
                { purpose = purpose }, "production"))
        end
        assert.same({ "out/app.mjs", "out/app.wasm" }, { driver.browser_program_path("out/app") })
        local filename, err = driver.browser_program_path("unused", "out/app.js")
        assert.is_nil(filename)
        assert.equal('browser executable output "out/app.js" must end in .mjs', err)
    end)
end)

describe("real browser test image", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)
    it("formats browser long doubles exactly and compares native text when its reported precision exceeds double", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        local source = read(repository .. "/spec/fixtures/browser_images/long_double.titan")
        files.write(workspace .. "/src/long_double.titan", source)
        if platform.windows then
            -- The UCRT printf expects double for %Lg; MinGW's formatter
            -- accepts CLANG64's extended long double.
            files.write(workspace .. "/src/long_double.windows.titan",
                (source:gsub("ffi%.printf%(", "ffi.__mingw_printf(")))
        end
        local setup = string.format("package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;")
        local native_image = workspace .. "/native/long_double" .. (platform.windows and ".exe" or "")
        local native_build = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=", "TITAN_PATH_0_6=",
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            info.lua, "-E", "-e", setup, repository .. "/titanc", "-q", "--incremental",
            "--tree", workspace .. "/src", "--output", workspace .. "/native", "--exe", native_image, "long_double" })
        assert.is_true(native_build.ok, native_build.output)
        local native = run({native_image})
        assert.is_true(native.ok, native.output)
        local native_precision, double_precision = native.output:match("precision=(%d+)/(%d+)")
        native_precision, double_precision = tonumber(native_precision), tonumber(double_precision)
        assert.is_number(native_precision)
        assert.is_number(double_precision)
        local native_text = assert(native.output:match("text=([^\r\n]+)"))
        local extended_text = "1.00000000000000000087"
        if native_precision > double_precision then
            assert.equal(extended_text, native_text)
        else
            assert.equal(double_precision, native_precision)
            assert.equal("1", native_text)
        end
        local browser_build = cli(info, "--incremental", "--exe", workspace .. "/out/long_double.mjs", "long_double")
        assert.is_true(browser_build.ok, browser_build.output)
        for _, engine in ipairs({"node", "chromium"}) do
            local result = run(toolchain.runner(info, "--engine", engine, "--grace", "0",
                workspace .. "/out/long_double.mjs"))
            assert.is_true(result.ok, result.output)
            local browser_precision, browser_double = result.output:match("precision=(%d+)/(%d+)")
            assert.is_true(tonumber(browser_precision) > tonumber(browser_double), result.output)
            local browser_text = assert(result.output:match("text=([^\r\n]+)"))
            assert.equal(extended_text, browser_text)
            if native_precision > double_precision then assert.equal(native_text, browser_text) end
            io.stdout:write(string.format("\nLONG-DOUBLE engine=%s browser=%s native=%s precision=%d/%d native-reference=%s\n",
                engine, browser_text, native_text, native_precision, double_precision,
                native_precision > double_precision and "extended" or "double-width"))
        end
    end)
    it("instantiates coroutine cleanup images well below the engine local limit", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        local runtime = require "spec.fixtures.browser_runtime.support"
        workspace = runtime.workspace()
        local root = workspace .. "/coroutine"
        local ok, log = runtime.cli(info, root, { purpose = "test" }, {
            "--test", "--exe", root .. "/public.mjs",
            "--c-source", runtime.fixture .. "/close.c", "coroutine.tests", "gc.tests" })
        assert.is_true(ok, log)
        local maximum = maximum_declared_locals(read(root .. "/public.wasm"))
        assert.is_true(maximum > 0 and maximum < 10000,
            "coroutine image declares too many function locals: " .. maximum)
        image_identity(info, root .. "/public.mjs", "unwind_common.titan")
        io.stdout:write(string.format("\nCOROUTINE-LOCALS profile=%s max-declared=%d\n", driver.BUILD_PROFILE, maximum))
        io.stdout:flush()
    end)

    -- Production-only by construction: it asserts the production object and
    -- post-link profile from a real production installation. CI runs it in the
    -- production `browser-playwright` cell, never in a validation install.
    it("keeps frame flags on test owners only and links a production test image as a test image", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        if driver.BUILD_PROFILE ~= "production" then
            -- The observed compile and link lines are the production profile's.
            pending("needs a production installation to observe the production object profile")
            return
        end
        local fixture = repository .. "/spec/fixtures/browser_trace"
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local setup = string.format("package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;")
        local function build(name, purpose, test)
            local options = purpose and ("require('titan-compiler.driver').browser_link_options=" ..
                string.format("{purpose=%q};", purpose)) or ""
            local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=", "TITAN_PATH_0_6=",
                "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
                "TITAN_PROBE_CACHE_DISABLE=1", "CCACHE_DISABLE=1",
                info.lua, "-E", "-e", setup .. options, repository .. "/titanc",
                "-v", "--target", "browser", "--no-uv-bootstrap", "--tree", fixture,
                "-o", workspace .. "/out", "--exe", workspace .. "/out/" .. name .. ".mjs",
                "--c-source", fixture .. "/trace_support.c" }
            if test then argv[#argv + 1] = "--test" end
            argv[#argv + 1] = "trace_cases"
            argv[#argv + 1] = "trace_uncaught"
            local result = run(argv)
            assert.is_true(result.ok, result.output or result.diagnostic)
            return result.output or ""
        end
        local function command(log, needle, anchor)
            local found
            for line in log:gmatch("[^\n]+") do
                if line:find(needle, 1, true) and line:find(anchor, 1, true) then
                    assert.is_nil(found, "repeated command line for " .. needle .. "\n" .. log)
                    found = line
                end
            end
            return assert(found, "no command line for " .. needle .. "\n" .. log)
        end
        local test_log = build("test_image", "test", true)
        local owner = command(test_log, "/trace_cases/trace_cases.c'", "'-c'")
        assert.truthy(owner:find("'-fno-inline'", 1, true), owner)
        assert.truthy(owner:find("'-fno-optimize-sibling-calls'", 1, true), owner)
        local helper = command(test_log, "/trace_uncaught.c'", "'-c'")
        assert.is_nil(helper:find("'-fno-inline'", 1, true), helper)
        -- The frames are object flags; the link is the same reactor link, and
        -- only wasm-opt's passes tell a test image from a program image.
        local test_link = command(test_log, "test_image.wasm.linked'", "'-mexec-model=reactor'")
        assert.is_nil(test_link:find("'--stack-check'", 1, true), test_link)
        local test_optimize = command(test_log, "test_image.wasm.linked'", "'--stack-check'")
        assert.truthy(test_optimize:find("'-O3'", 1, true), test_optimize)
        assert.truthy(test_optimize:find("'--skip-pass=inlining-optimizing'", 1, true), test_optimize)
        assert.truthy(test_optimize:find("'--skip-pass=duplicate-function-elimination'", 1, true), test_optimize)
        local program_log = build("program_image", nil, false)
        local plain = command(program_log, "/trace_uncaught.c'", "'-c'")
        assert.is_nil(plain:find("'-fno-inline'", 1, true), plain)
        local program_link = command(program_log, "program_image.wasm.linked'", "'-mexec-model=reactor'")
        assert.is_nil(program_link:find("'-fno-inline'", 1, true), program_link)
        local program_optimize = command(program_log, "program_image.wasm.linked'", "'--stack-check'")
        assert.truthy(program_optimize:find("'-O3'", 1, true), program_optimize)
        assert.is_nil(program_optimize:find("--skip-pass", 1, true), program_optimize)
    end)

    -- Runs in both installations (CI's production cell selects it by name), so
    -- each profile links a real image through the strict reactor link.
    it("checks the linked image: publishes a declared host import and refuses an undeclared one", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/checked.titan", "function main(args: {string}): integer\n    return #args\nend\n")
        local helper = workspace .. "/helper.c"
        -- A C constructor that calls a declared host import still links: the
        -- compiler's protocol probe runs it against inert stubs (D15).
        local function link(declaration)
            files.write(helper, declaration .. "int page_value(void);\n" ..
                "__attribute__((constructor)) static void load(void) { page_value(); }\n")
            return cli(info, "--c-source", helper, "checked")
        end
        -- The link allows no undefined symbol: a host function needs an import name.
        local result = link("")
        assert.is_false(result.ok, "an undeclared host function was published")
        local log = result.output or result.diagnostic or ""
        assert.truthy(log:find("undefined symbol: page_value", 1, true), log)
        for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.trace", ".wasm.map" }) do
            assert.is_nil(lfs.attributes(workspace .. "/out/checked" .. suffix), suffix)
        end
        result = link('__attribute__((import_module("env"), import_name("page_value")))\n')
        assert.is_true(result.ok, result.output or result.diagnostic)
        for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.trace", ".wasm.map" }) do
            assert.equal("file", lfs.attributes(workspace .. "/out/checked" .. suffix, "mode"), suffix)
        end
        local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/checked.wasm")))
        local imported = false
        for _, item in ipairs(inventory.imports) do
            if item.module == "env" and item.name == "page_value" then imported = true end
        end
        assert.is_true(imported, "the declared host import is missing from the image")
        -- The module is the SDK's static factory, the loader and `create`: it
        -- loads no other module and exports only the creator.
        local module = read(workspace .. "/out/checked.mjs")
        assert.is_nil(module:find("import(", 1, true))
        assert.is_nil(module:find("require(", 1, true))
        assert.is_nil(module:find("\n%s*import%s"))
        assert.is_nil(module:find("^%s*import%s"))
        local _, exports = module:gsub("\n%s*export%s", "")
        assert.equal(1, exports)
        assert.truthy(module:find("\nexport default function create(options = {}) {\n", 1, true))
    end)

    it("raises the five dynamic-provider guard diagnostics without native loader imports", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        local image = c_image(info, "dynamic-guards", read(repository .. "/spec/fixtures/browser_images/dynamic-guards.c"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = run(toolchain.runner(info, "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", image))
            assert.is_true(result.ok, result.output or result.diagnostic)
            assert.truthy(result.output:find("dynamic-guards=5", 1, true), result.output)
        end
    end)

    it("links default and explicit programs through main, support preloads and the bootstrap hook", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.write(workspace .. "/src/image_main.titan",
            read(repository .. "/spec/fixtures/browser_images/program-main.titan"))
        local source = repository .. "/spec/fixtures/browser_images/program-bootstrap.c"
        local result = cli(info, "--incremental", "--c-source", source,
            "--ldflag=-Wl,--wrap=luaL_openselectedlibs", "image_main")
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.is_nil(result.output:find("support-bootstrap", 1, true), "compiler unexpectedly ran main")
        local explicit = workspace .. "/out/explicit-program.mjs"
        result = cli(info, "--incremental", "--exe", explicit, "--c-source", source,
            "--ldflag=-Wl,--wrap=luaL_openselectedlibs", "image_main")
        assert.is_true(result.ok, result.output or result.diagnostic)
        local runtime = assert(require("titan-compiler.staticmetadata").scan_archive(
            info.sdk_root .. "/libtitan.a", { target = fixtures.fingerprint() }))
        local members = {}
        for index, member in ipairs(runtime.members) do members[index] = member.display_name end
        assert.same({ "titan.o", "minicoro.o", "titan_path.o", "ltitanlib.o" }, members)
        assert.is_true(driver.validate_browser_provider(runtime))
        -- Only objects and archives carry the compiler's metadata payloads.
        local objdump = require("titan-compiler.path").join(
            require("titan-compiler.path").dirname(info.tools.cc[1]), "llvm-objdump" .. (platform.windows and ".exe" or ""))
        for _, image in ipairs({ "image_main", "explicit-program" }) do
            assert.equal("file", lfs.attributes(workspace .. "/out/" .. image .. ".mjs", "mode"))
            local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/" .. image .. ".wasm")))
            local exports = {}
            for _, item in ipairs(inventory.exports) do exports[item.name] = true end
            -- The entries name themselves; the link exports what the factory needs.
            for _, name in ipairs({ "titan_browser_initialize", "titan_browser_entry", "titan_browser_invoke",
                    "titan_browser_release_callable", "titan_browser_close", "titan_browser_trace_identity",
                    "malloc", "free", "memory", "__indirect_function_table", "_initialize", "__stack_pointer",
                    "__stack_low", "__stack_high", "__set_stack_limits" }) do
                assert.is_true(exports[name], "missing browser gateway " .. name)
            end
            assert.is_nil(exports.titan_browser_gate_guarded)
            assert.is_nil(exports.main)
            assert.is_nil(exports._start)
            local segments = run({ objdump, "-t", workspace .. "/out/" .. image .. ".wasm" })
            assert.is_true(segments.ok, segments.output)
            assert.truthy(segments.output:find(" DATA", 1, true), segments.output)
            assert.is_nil(segments.output:find(".titan.", 1, true), segments.output)
        end
        local symbols = run({ objdump, "-t", workspace .. "/out/image_main.o" })
        assert.is_true(symbols.ok, symbols.output)
        local names = require("titan-compiler.coder.core").coder
        for _, family in ipairs({ "titan_metadata", "titan_source" }) do
            local symbol = names._linkage_symbol_name(names._private_symbol("image_main", family))
            assert.truthy(symbols.output:find(symbol, 1, true), symbols.output)
        end
        local fixture = workspace .. "/out/program-results.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/program-results.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            result = run(toolchain.runner(info, "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--",
                "image_main.mjs", "explicit-program.mjs"))
            assert.is_true(result.ok, result.output or result.diagnostic)
        end
    end)

    -- The payloads are external on Wasm. Their private names meet neither the
    -- protocol functions of a module named titan_object_source (such as
    -- titan_object_source_init) nor names that an authored C helper defines.
    it("links modules and C helpers that spell ASCII metadata payload names", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/titan_object_source.titan", "function value(): integer\n    return 2\nend\n")
        files.write(workspace .. "/src/init.titan", "function value(): integer\n    return 3\nend\n")
        files.write(workspace .. "/src/app.titan", [[
local source = import "titan_object_source"
local init = import "init"
function main(args: {string}): integer
    return source.value() * init.value()
end
]])
        files.write(workspace .. "/src/plain.titan", "function main(args: {string}): integer\n    return 7\nend\n")
        local helper = workspace .. "/helper.c"
        files.write(helper, "const unsigned char plain_titan_metadata[] = { 1 };\n" ..
            "const unsigned char titan_object_source_plain[] = { 2 };\n")
        for _, case in ipairs({ { "app", 6, {} }, { "plain", 7, { "--c-source", helper } } }) do
            local name, status, options = case[1], case[2], case[3]
            options[#options + 1] = name
            local result = cli(info, table.unpack(options))
            assert.is_true(result.ok, result.output or result.diagnostic)
            result = run(toolchain.runner(info, "--grace", "0", workspace .. "/out/" .. name .. ".mjs"))
            assert.equal(status, result.status, result.output or result.diagnostic)
        end
    end)

    it("contains initialization, conversion and allocation failures through the protected entry", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        local names = {}
        for _, case in ipairs({
            { "entry-close" }, { "entry-binary" }, { "entry-tostring" },
            { "entry-state-oom", { "-Wl,--wrap=luaL_newstate" } },
            { "entry-long-error" },
            { "entry-bootstrap-oom", { "-Wl,--wrap=luaL_openselectedlibs", "-Wl,--wrap=lua_pcallk" } },
        }) do
            names[#names + 1] = case[1]
            local image = c_image(info, case[1],
                read(repository .. "/spec/fixtures/browser_images/" .. case[1] .. ".c"), case[2])
            toolchain.check_imports(image, case[1] == "entry-close" and { "entry", "fixture:images" } or { "entry" })
        end
        local fixture = workspace .. "/out/entry-results.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/entry-results.mjs"))
        local imports = workspace .. "/out/fixture-imports.mjs"
        files.write(imports, read(repository .. "/spec/fixtures/browser_runtime/fixture-imports.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local argv = toolchain.runner(info, "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--imports", imports, "--js-test", fixture, "--")
            for _, name in ipairs(names) do argv[#argv + 1] = name end
            local result = run(argv)
            assert.is_true(result.ok, result.output or result.diagnostic)
        end
    end)

    it("delivers native C stdio batches and rejects file calls under Node and Chromium", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        local image = c_image(info, "stdio-image", read(repository .. "/spec/fixtures/browser_images/stdio-only.c"))
        -- No host shell or file system: the image imports only the entry's
        -- reviewed WASI and Titan functions.
        toolchain.check_imports(image, { "entry" })
        local fixture = workspace .. "/out/stdio-only.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/stdio-only.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = run(toolchain.runner(info, "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--", "stdio-image.mjs"))
            assert.is_true(result.ok, result.output or result.diagnostic)
        end
    end)

    it("permits objects without the SDK and diagnoses image readiness and suffixes precisely", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/image_main.titan", read(repository .. "/spec/fixtures/browser_images/program.titan"))
        local prefix = workspace .. "/prefix"
        files.mkdir(prefix); files.mkdir(prefix .. "/lib")
        toolchain.stage_lua(info, prefix)
        local isolated = { prefix = info.prefix, lua = info.lua, sdk_prefix = prefix }
        local result = cli(isolated, "-c", "--incremental", "image_main")
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.equal("file", lfs.attributes(workspace .. "/out/image_main.o", "mode"))
        result = cli(isolated, "--exe", workspace .. "/out/app.js", "image_main")
        assert.is_false(result.ok)
        assert.truthy(result.output:find("must end in .mjs", 1, true), result.output)
        result = cli(isolated, "image_main")
        assert.is_false(result.ok)
        local runtime = browserlink.sdk_assets(fixtures.paths(prefix)).runtime
        assert.truthy(result.output:find("browser SDK is incomplete: missing " .. string.format("%q", runtime) ..
            "; run '" .. sdk_remedy .. " PREFIX=" .. prefix .. "'", 1, true), result.output)
        assert.is_nil(lfs.attributes(workspace .. "/out/image_main.mjs"))
        assert.is_nil(lfs.attributes(workspace .. "/out/image_main.wasm"))
    end)

    it("preflights direct C-image maps against code inputs before writing the entrypoint", function()
        local info, why = toolchain.require({ sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local map, entrypoint, executable = workspace .. "/app.wasm.map",
            workspace .. "/app.c", workspace .. "/app.mjs"
        files.write(map, "authored input bytes")
        local script = string.format([[
local driver = require "titan-compiler.driver"
local context = driver.new_resolver_context({ target = "browser", output_root = %q })
local ok, why = driver.compile_browser_image("unused entrypoint", %q, %q, { %q }, {}, {}, false,
    { context = context, profile = { purpose = "protocol" } })
assert(not ok and why:find("aliases input", 1, true), tostring(why))
assert(driver.close_resolver_context(context))
]], workspace, entrypoint, executable, map)
        local result = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            info.lua, "-E", "-e",
            string.format("package.path=%q..package.path;", repository .. "/?.lua;" ..
                repository .. "/?/init.lua;") .. script })
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.equal("authored input bytes", read(map))
        assert.is_nil(lfs.attributes(entrypoint))
        assert.is_nil(lfs.attributes(executable))
    end)

    it("resolves a UTF-8 function name from the extended map through the instantiated names table", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        for _, extension in ipairs({ "titan", "c", "h" }) do
            local destination = extension == "titan" and "trace_names.titan" or "trace-names." .. extension
            files.write(workspace .. "/src/" .. destination,
                read(repository .. "/spec/fixtures/browser_images/trace-names." .. extension))
        end
        local result = cli(info, "--c-source", workspace .. "/src/trace-names.c", "trace_names")
        assert.is_true(result.ok, result.output or result.diagnostic)
        result = run({ info.node.path, "-e", [[
const map = JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8'));
const names = map.x_titan_function_names.filter(name => typeof name === 'string' && name.endsWith('_labelled_titan'));
if (names.length !== 1) throw new Error('expected one final labelled function name');
process.stdout.write(names[0]);
]], workspace .. "/out/trace_names.wasm.map" })
        assert.is_true(result.ok, result.output or result.diagnostic)
        local symbol = result.output
        assert.truthy(symbol:find("ℳ", 1, true), symbol)
        assert.is_nil(symbol:find("\\u2133", 1, true))
        for _, row in ipairs({ { symbol, 0 }, { symbol .. "_absent", 17 } }) do
            result = run(toolchain.runner(info, "--engine", "node", "--grace", "0",
                workspace .. "/out/trace_names.mjs", "--", row[1]))
            assert.equal(row[2], result.status, result.output or result.diagnostic)
        end
    end)

    it("keeps final-link flags local and image identity stable across repeated in-process links", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src"); files.mkdir(workspace .. "/out")
        local script = string.format([[
local driver = require "titan-compiler.driver"
local strategy = require("titan-compiler.io").new_sync()
local read_response = require("spec.support.browser_process_audit").read_link_response
local real_run, links = strategy.run, 0
function strategy:run(argv, options)
    local count = 0
    for _, flag in ipairs(read_response(argv[#argv]) or argv) do
        if flag == "-Wl,--trace" then count = count + 1 end
    end
    if count > 0 then
        assert(count == 1, "final-link flag was duplicated")
        links = links + 1
    end
    return real_run(self, argv, options)
end
driver.TITAN_SOURCE_PATH = %q
local output = %q
local context = driver.new_resolver_context({ target = "browser", output_root = output, io = strategy })
driver.NATIVE_LINK_FLAGS = { "-Wl,--no-demangle" }
local extras = driver.NATIVE_LINK_FLAGS
local flags = { "-Wl,--trace" }
local contents = driver.browser_c_image_contents("static int titan_browser_worker(lua_State *L) { (void)L; return 0; }")
local previous
for iteration = 1, 2 do
    local ok, why, code = driver.compile_browser_image(contents,
        output .. "/repeated.c", output .. "/repeated.mjs", {}, {}, {}, false,
        { context = context, profile = { purpose = "protocol" },
          final_link_flags = flags, dependency_output = output .. "/dependencies" })
    assert(ok, tostring(why) .. (code and (", exit " .. code) or ""))
    assert(driver.NATIVE_LINK_FLAGS == extras and #extras == 1 and extras[1] == "-Wl,--no-demangle",
        "image link changed global link extras")
    assert(#flags == 1 and flags[1] == "-Wl,--trace", "image link changed final-link options")
    local map = assert(strategy:read_file(output .. "/repeated.wasm.map"))
    local identity = assert(map:match('"x_titan_image":"([0-9a-f]+)"'))
    assert(not previous or identity == previous, "identical inputs changed image identity")
    previous = identity
end
assert(links == 2, "both real links must receive the final-link flag")
assert(driver.close_resolver_context(context))
]], workspace .. "/src", workspace .. "/out")
        local result = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            info.lua, "-E", "-e", string.format("package.path=%q..package.path;",
                repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script })
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.match("^[0-9a-f]+$", image_identity(info, workspace .. "/out/repeated.mjs"))
    end)

    it("publishes a matching extended map and callable identity for an optimized measurement control", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/image_control.titan", [[
local test = import "test"
function main(args: {string}): integer
    test.assert(#args >= 0)
    return #args
end
]])
        files.write(workspace .. "/src/control-helper.c", "int control_helper(void) { return 37; }\n")
        local library_flag = "-L" .. workspace .. "/src"
        local variant = { prefix = info.prefix, lua = info.lua, compiler_setup = string.format([[
local driver = require "titan-compiler.driver"
driver.browser_link_options = {purpose='baseline',optimization='O2'}
-- Observe the static-provider protocol image's link, not the measurement image's.
local image, protocol = driver.compile_browser_image, false
driver.compile_browser_image = function(...)
    local options = select(8, ...)
    protocol = options and options.profile and options.profile.purpose == "protocol"
    local results = table.pack(image(...))
    protocol = false
    return table.unpack(results, 1, results.n)
end
local run_link = driver.run_link_command
driver.run_link_command = function(argv, ...)
    if protocol then
        local library, demangle
        for index, flag in ipairs(argv) do
            assert(flag ~= "-Os", "measurement override reached protocol link")
            if flag == %q then library = index end
            if flag == "-Wl,--no-demangle" then demangle = index end
        end
        assert(library and demangle and library < demangle, "protocol lost ordered nontrace link flags")
        io.stdout:write("control protocol link\n")
    end
    return run_link(argv, ...)
end
local run_probe = driver.run_standalone_archive_probe
driver.run_standalone_archive_probe = function(...)
    local before = { table.unpack(driver.link_extra_flags()) }
    local ok, why, code = run_probe(...)
    local after = driver.link_extra_flags()
    assert(#before == #after, "protocol changed outer link flags")
    for index, flag in ipairs(before) do assert(flag == after[index], "protocol changed outer link flag order") end
    return ok, why, code
end
]], library_flag) }
        local result = cli(variant, "--incremental", "--c-source", workspace .. "/src/control-helper.c",
            "--ldflag=-Os", "--ldflag=" .. library_flag, "--ldflag=-Wl,--no-demangle", "image_control")
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.truthy(result.output:match("control protocol link\r?\n"),
            "measurement control did not execute the real static-provider protocol link")
        local image = workspace .. "/out/image_control.mjs"
        local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/image_control.wasm")))
        -- The identity export keeps its declared name through wasm-ld and
        -- wasm-opt; no export is minified.
        local stable_identity = false
        for _, item in ipairs(inventory.exports) do
            if item.name == "titan_browser_trace_identity" then stable_identity = true end
        end
        assert.is_true(stable_identity, "the identity export did not keep its declared name")
        assert.match("^[0-9a-f]+$", image_identity(info, image, "image_control.titan"))
    end)

    it("certifies optimization for FFI, generated workers and authored C together", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/optimized.h", [[
#ifndef TITAN_IMAGE_OPTIMIZED_H
#define TITAN_IMAGE_OPTIMIZED_H
#if !defined(__OPTIMIZE__) || !__OPTIMIZE__
#error optimization did not reach this compilation
#endif
#define TITAN_IMAGE_OPTIMIZED 42
#endif
]])
        for _, module in ipairs({ "opt_left", "opt_right" }) do
            files.write(workspace .. "/src/" .. module .. ".titan", [[
foreign import "optimized.h"
function answer(): integer
    return ffi.TITAN_IMAGE_OPTIMIZED
end
]])
        end
        files.write(workspace .. "/src/helper.c",
            '#include "optimized.h"\nint titan_image_optimized(void) { return TITAN_IMAGE_OPTIMIZED; }\n')
        local identities = {}
        for _, optimization in ipairs({ "O1", "O2" }) do
            local variant = { prefix = info.prefix, lua = info.lua, output = workspace .. "/" .. optimization,
                compiler_setup = "require('titan-compiler.driver').browser_link_options=" ..
                    "{purpose='baseline',optimization='" .. optimization .. "'};" }
            local result = cli(variant, "-c", "--incremental", "--jobs", "2", "--c-source",
                workspace .. "/src/helper.c", "opt_left", "opt_right")
            assert.is_true(result.ok, result.output or result.diagnostic)
            local metadata = require "titan-compiler.objectmetadata"
            local original = read(variant.output .. "/opt_left.o")
            local record = assert(metadata.read(original, variant.output .. "/opt_left.o"))
            identities[optimization] = record.object_metadata.certificate.configuration.toolchain
            result = cli(variant, "-c", "--incremental", "--jobs", "2", "--c-source",
                workspace .. "/src/helper.c", "opt_left", "opt_right")
            assert.is_true(result.ok, result.output or result.diagnostic)
            assert.equal(original, read(variant.output .. "/opt_left.o"))
        end
        assert.not_equal(identities.O1, identities.O2)
    end)

    it("maps a selected contributor prologue to its own physical source", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.mkdir(workspace .. "/src/source_location")
        files.write(workspace .. "/src/source_location/source_location.titan", [[
local definitions = import "definitions.titan"
function main(args: {string}): integer
    return definitions.copied(0) + selected_leaf(#args)
end
]])
        files.write(workspace .. "/src/source_location/member.browser.titan", [[
local function selected_leaf(n: integer): integer
    local rooted = {n}
    return rooted[1]
end
]])
        files.write(workspace .. "/src/definitions.titan",
            read(repository .. "/spec/fixtures/browser_images/definitions.titan"))
        local result = cli(info, "--exe", workspace .. "/out/contributor.mjs",
            "--c-parts", "4", "source_location")
        assert.is_true(result.ok, result.output or result.diagnostic)
        local header = read(workspace .. "/out/definitions.titan.h")
        for _, name in ipairs({ "copied", "outlined", "empty" }) do
            local at = assert(header:find("foreign_inline_" .. name .. "(", 1, true))
            local definition = assert(header:find("foreign_inline_" .. name .. "(", at + 1, true))
            local before = header:sub(1, definition - 1)
            assert.truthy(before:match('#line %d+ "[^\r\n]-definitions[.]titan"\r?\n[^\r\n]*$'), name)
        end
        result = run({ info.node.path, "--input-type=module", "-e", [[
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const map = JSON.parse(await readFile(process.argv[1], 'utf8'));
const indices = map.x_titan_function_names.flatMap((name, index) =>
    typeof name === 'string' && name.endsWith('selected_leaf_titan') ? [index] : []);
assert.equal(indices.length, 1, 'selected contributor function missing or ambiguous');
const [start, end] = map.x_titan_function_ranges[indices[0] - map.x_titan_function_imports];
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function vlq(segment) {
    const values = [];
    let value = 0, shift = 0;
    for (const character of segment) {
        const digit = alphabet.indexOf(character);
        assert.ok(digit >= 0);
        value += (digit & 31) * 2 ** shift;
        if (digit & 32) { shift += 5; continue; }
        values.push(value & 1 ? -Math.floor(value / 2) : value / 2);
        value = 0; shift = 0;
    }
    assert.equal(shift, 0);
    return values;
}
assert.ok(!map.mappings.includes(';'), 'Wasm mappings must use one generated line');
let pc = 0, source = 0, line = 0, found = false;
for (const segment of map.mappings.split(',')) {
    const fields = vlq(segment);
    pc += fields[0];
    if (fields.length === 1) continue;
    source += fields[1]; line += fields[2];
    if (pc < start) continue;
    if (pc >= end) break;
    assert.equal(map.sources[source].replaceAll('\\', '/').split('/').at(-1),
        'member.browser.titan', 'the first prologue mapping borrowed the preceding contributor');
    assert.ok(line >= 0);
    found = true;
    break;
}
assert.ok(found, 'selected function prologue has no mapped instruction');
]], workspace .. "/out/contributor.wasm.map" })
        assert.is_true(result.ok, result.output or result.diagnostic)
    end)

    it("links the normal CLI test runner and executes one selected case through the installed loader", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/image_case.titan", [[
local test = import "test"
function test_trivial(context: test.Context)
    test.assert(context:name() == "image_case.test_trivial")
end
]])
        local result = cli(info, "--test", "--incremental", "image_case")
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.equal("file", lfs.attributes(workspace .. "/out/image_case.mjs", "mode"))
        local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/image_case.wasm")))
        local exports = {}
        for _, item in ipairs(inventory.exports) do exports[item.name] = true end
        assert.is_true(exports.titan_browser_entry)
        assert.is_true(exports.titan_browser_trace_identity)
        local map = read(workspace .. "/out/image_case.wasm.map")
        assert.truthy(map:find('"x_titan_image":"', 1, true))
        assert.truthy(map:find('"x_titan_function_ranges":[[', 1, true))
        assert.truthy(map:find('"x_titan_function_names":[', 1, true))
        image_identity(info, workspace .. "/out/image_case.mjs", "image_case.titan")
        for _, name in ipairs({ "titan_browser_initialize", "titan_browser_invoke", "titan_browser_release_callable",
                "titan_browser_close", "malloc", "free" }) do
            assert.is_true(exports[name], "missing browser gateway " .. name)
        end
        assert.is_nil(exports.titan_browser_gate_guarded)
        result = run(toolchain.runner(info, "--engine", "node", "--grace", "0",
            workspace .. "/out/image_case.mjs", "--", "--filter=^image_case[.]test_trivial$"))
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.truthy(result.output:find("[==========] 1 test ran.", 1, true), result.output)
        assert.truthy(result.output:find("[  PASSED  ] 1 test.", 1, true), result.output)
    end)
end)

describe("native trace backend invariance", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)

    it("keeps direct fallback capture depth, frame order and the 255-frame truncation boundary", function()
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local output = native_trace()
        assert.match("fallback shallow=%d+ deep=255 long%-trace=%d+", output)
    end)

end)

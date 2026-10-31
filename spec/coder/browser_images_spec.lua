local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local driver = require "titan-compiler.driver"
local linkcertificate = require "titan-compiler.linkcertificate"
local fixtures = require "spec.support.browser_fixtures"
local toolchain = require "spec.support.browser_toolchain"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local process = require "titan-compiler.process"
local repository = assert(lfs.currentdir())
local workspace

local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = assert(file:read("a")); assert(file:close())
    return bytes
end
local function run(argv)
    return compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
end

local function cli(info, ...)
    local setup = string.format("package.path=%q..package.path;",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. (info.compiler_setup or "")
    local argv = { "env", "TITAN_ROOT=" .. (info.sdk_prefix or info.prefix), "TITAN_TARGET=", "TITAN_PATH_0_6=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        info.prefix .. "/bin/lua", "-E", "-e", setup, repository .. "/titanc",
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
    { context = context, profile = { purpose = "protocol", assertions = 2 }, final_link_flags = { %s } })
assert(ok, tostring(why) .. (code and (", exit " .. code) or ""))
assert(driver.close_resolver_context(context))
]], workspace .. "/src", output, name, worker, table.concat(quoted_flags, ","))
    local result = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        info.prefix .. "/bin/lua", "-E", "-e", string.format("package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script })
    assert.is_true(result.ok, result.output or result.diagnostic)
    return output .. "/" .. name .. ".mjs"
end

local function native_trace(null_backend)
    local prefix = require("spec.support.installed_prefix").active()
    local suffix = platform.windows and ".exe" or ""
    local script = string.format([[
local driver = require "titan-compiler.driver"
local context = driver.new_resolver_context({ target = %q })
assert(driver.configure_foreign_c(context))
local runtime, fixture, output, prefix, null_backend = %q, %q, %q, %q, %s
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
if null_backend then compile[#compile + 1] = "-DTITAN_TARGET_BROWSER" end
command(compile)
compile = assert(driver.authored_c_compile_prefix(context))
append(compile, { "-c", fixture, "-o", output .. ".fixture.o" })
if null_backend then compile[#compile + 1] = "-DFIXTURE_NULL" end
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
        workspace .. "/trace" .. suffix, prefix, tostring(null_backend))
    local result = process.capture({ prefix .. "/bin/lua" .. suffix, "-E", "-e",
        string.format("package.path=%q..package.path;", repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script },
        { env = { TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_BUILD_PROFILE = "validation",
            TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" } })
    assert.is_true(result.ok, result.output or result.diagnostic)
    return result.output
end

describe("browser image profile and SDK readiness", function()
    it("derives the closed SDK asset set without extending BrowserPaths", function()
        local paths = fixtures.paths()
        local assets = browserlink.sdk_assets(paths)
        assert.equal(paths.libtitan, assets.runtime)
        assert.equal(paths.sdk_digests, assets.sdk_digests)
        local keys = {}
        for key in pairs(assets) do keys[#keys + 1] = key end
        table.sort(keys)
        assert.same({ "js_library", "loader", "lpeglabel", "node_worker", "page", "provider",
            "runner", "runner_module", "runtime", "sdk_digests" }, keys)
    end)

    it("requires only readable runtime and JS assets, in bootstrap order", function()
        local descriptor = fixtures.descriptor()
        local assets = browserlink.sdk_assets(descriptor.paths)
        local present = {}
        local context = { io = {
            stat = function(_, filename) return present[filename] and { kind = "file" } end,
            read_file = function(_, filename) return present[filename] and "bytes" end,
        } }
        for _, key in ipairs({ "runtime", "js_library", "loader", "runner", "runner_module", "node_worker", "page" }) do
            local found, err = browserlink.require_sdk(context, descriptor, { prefix = "/prefix", rocks_tree = "/rocks" })
            assert.is_nil(found)
            assert.equal("browser SDK is incomplete: missing " .. string.format("%q", assets[key]) ..
                "; run 'make browser-sdk PREFIX=/prefix ROCKS_TREE=/rocks'", err)
            present[assets[key]] = true
        end
        assert.same(assets, assert(browserlink.require_sdk(context, descriptor, { prefix = "/prefix" })))
        present[assets.runtime] = nil
        local _, err = browserlink.require_sdk(context, descriptor, { prefix = "/prefix" })
        assert.truthy(err:find("run 'make browser-sdk PREFIX=/prefix'", 1, true))
    end)

    it("exports private current HEAPU8 and exact production marshalling exports", function()
        local descriptor = fixtures.descriptor()
        local profile = assert(browserlink.profile(descriptor, { purpose = "program", assertions = 2 }))
        assert.same({}, profile.compile_flags)
        assert.same({
            "-sASYNCIFY=1", "-sSUPPORT_LONGJMP=emscripten", "-sSTACK_SIZE=1048576",
            "-sASYNCIFY_STACK_SIZE=65536", "-sINITIAL_MEMORY=16777216", "-sALLOW_MEMORY_GROWTH=1",
            "-sMAXIMUM_MEMORY=2147483648", "-sABORTING_MALLOC=0", "-sEXIT_RUNTIME=0", "-sINVOKE_RUN=0",
            "--no-entry", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sENVIRONMENT=web,node",
            "-sFORCE_FILESYSTEM=1",
            '-sEXPORTED_FUNCTIONS=["_titan_browser_entry","_malloc","_free"]',
            '-sEXPORTED_RUNTIME_METHODS=["ccall","HEAPU8"]',
            '-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]',
            "--js-library", browserlink.sdk_assets(descriptor.paths).js_library,
            "-sASSERTIONS=2", "-sSTACK_OVERFLOW_CHECK=2",
        }, profile.link_flags)
        assert.equal(descriptor.identity, profile.identity_inputs.target_identity)
        assert.equal("-O2", profile.identity_inputs.optimization)
    end)

    it("keeps internal gate, budget and baseline variants constrained", function()
        local descriptor = fixtures.descriptor()
        local gate = assert(browserlink.profile(descriptor, { purpose = "gate", assertions = 0 }))
        assert.truthy(table.concat(gate.link_flags, " "):find('"_titan_browser_gate_guarded","_titan_browser_gate_observe"', 1, true))
        for _, options in ipairs({ { purpose = "program", assertions = 2, asyncify = false },
            { purpose = "protocol", assertions = 2, optimization = "O2" },
            { purpose = "program", assertions = 2, budgets = {} },
            { purpose = "gate", assertions = 1 }, { purpose = "program", assertions = 2, unknown = true },
            { purpose = "gate", assertions = 2, entry = "lua-main" },
            { purpose = "budget", assertions = 2, budgets = { stack_size = 17 } },
            { purpose = "budget", assertions = 2, budgets = { initial_memory = 2147549184 } } }) do
            assert.is_nil(browserlink.profile(descriptor, options))
        end
        local budget = assert(browserlink.profile(descriptor, { purpose = "budget", assertions = 2,
            optimization = "O1", budgets = { stack_size = 65536 } }))
        assert.same({ "-O1" }, budget.compile_flags)
        local baseline = assert(browserlink.profile(descriptor, { purpose = "baseline", assertions = 2,
            entry = "lua-main", asyncify = false, optimization = "O2" }))
        local flags = table.concat(baseline.link_flags, " ")
        assert.is_nil(flags:find("--no-entry", 1, true))
        assert.is_nil(flags:find("--js-library", 1, true))
        assert.truthy(flags:find('-sEXPORTED_FUNCTIONS=["_main","_malloc","_free"]', 1, true))
    end)

    it("preserves byte-oriented FS and TTY for every purpose including the interpreter baseline", function()
        for _, purpose in ipairs({ "program", "protocol", "gate", "minicoro", "budget", "baseline" }) do
            for _, entry in ipairs(purpose == "baseline" and { "titan", "lua-main" } or { "titan" }) do
                local plan = assert(browserlink.profile(fixtures.descriptor(),
                    { purpose = purpose, assertions = 2, entry = entry }))
                assert.truthy(table.concat(plan.link_flags, " "):find("-sFORCE_FILESYSTEM=1", 1, true))
                assert.same(plan.link_flags, plan.identity_inputs.link_flags)
            end
        end
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

    it("rejects trailing attempts to override profile-owned settings", function()
        for _, flags in ipairs({ { "-sASYNCIFY=0" }, { "-s", "ASYNCIFY_IGNORE_INDIRECT=1" },
            { "-DTITAN_COROUTINE_STACK_SIZE=1" }, { "-UTITAN_TARGET_BROWSER" }, { "-sNO_ASYNCIFY=1" },
            { "-sFORCE_FILESYSTEM=0" }, { "-sFILESYSTEM=0" }, { "-sMINIMAL_RUNTIME=1" },
            { "--js-library=x.js" }, { "--no-entry" } }) do
            assert.is_nil(browserlink.validate_extras(flags))
        end
        assert.is_true(browserlink.validate_extras({ "-lm", "-sWASM_BIGINT=1" }))
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
    it("attempts both final libc drains and preserves stdout-first or original-error precedence", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        c_image(info, "entry-flush", read(repository .. "/spec/fixtures/browser_images/entry-flush.c"))
        local fixture = workspace .. "/out/flush-results.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/flush-results.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = run({ info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--", "entry-flush.mjs" })
            assert.is_true(result.ok, result.output or result.diagnostic)
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
            { "entry-copy-oom", { "-Wl,--wrap=malloc" } },
            { "entry-bootstrap-oom", { "-Wl,--wrap=luaL_openselectedlibs", "-Wl,--wrap=lua_pcallk" } },
        }) do
            names[#names + 1] = case[1]
            c_image(info, case[1], read(repository .. "/spec/fixtures/browser_images/" .. case[1] .. ".c"), case[2])
        end
        local fixture = workspace .. "/out/entry-results.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/entry-results.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local argv = { info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--" }
            for _, name in ipairs(names) do argv[#argv + 1] = name end
            local result = run(argv)
            assert.is_true(result.ok, result.output or result.diagnostic)
        end
    end)

    it("delivers pure-C stdio-only binary tails to Chromium byte sinks", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        c_image(info, "stdio-image", [[
static int titan_browser_worker(lua_State *L) {
    static const unsigned char out[] = {65, 0, 255, 195, 40};
    static const unsigned char err[] = {66, 0, 254, 226, 40};
    static char out_buffer[BUFSIZ], err_buffer[BUFSIZ];
    if (setvbuf(stdout, out_buffer, _IOFBF, sizeof out_buffer) != 0 ||
        setvbuf(stderr, err_buffer, _IOFBF, sizeof err_buffer) != 0)
        return luaL_error(L, "cannot buffer stdio fixture");
    if (fwrite(out, 1, sizeof out, stdout) != sizeof out ||
        fwrite(err, 1, sizeof err, stderr) != sizeof err)
        return luaL_error(L, "cannot write stdio fixture");
    lua_pushinteger(L, 0);
    return 1;
}
]])
        local fixture = workspace .. "/out/stdio-only.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/stdio-only.mjs"))
        local result = run({ info.sdk_root .. "/titan-browser-run", "--engine", "chromium",
            "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--", "stdio-image.mjs" })
        assert.is_true(result.ok, result.output or result.diagnostic)
    end)

    it("permits objects without the SDK and diagnoses image readiness and suffixes precisely", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/image_main.titan", read(repository .. "/spec/fixtures/browser_images/program.titan"))
        local prefix = workspace .. "/prefix"
        files.mkdir(prefix); files.mkdir(prefix .. "/lib")
        assert(lfs.link(info.prefix .. "/lib/browser", prefix .. "/lib/browser", true))
        assert(lfs.link(info.prefix .. "/include", prefix .. "/include", true))
        local isolated = { prefix = info.prefix, sdk_prefix = prefix }
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
            "; run 'make browser-sdk PREFIX=" .. prefix .. "'", 1, true), result.output)
        assert.is_nil(lfs.attributes(workspace .. "/out/image_main.mjs"))
        assert.is_nil(lfs.attributes(workspace .. "/out/image_main.wasm"))
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
            local variant = { prefix = info.prefix, output = workspace .. "/" .. optimization,
                compiler_setup = "require('titan-compiler.driver').browser_link_options=" ..
                    "{purpose='baseline',assertions=2,optimization='" .. optimization .. "'};" }
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
        assert.is_true(exports.malloc)
        assert.is_true(exports.free)
        assert.is_nil(exports.titan_browser_gate_guarded)
        result = run({ info.sdk_root .. "/titan-browser-run", "--engine", "node", "--grace", "0",
            workspace .. "/out/image_case.mjs", "--", "--filter=^image_case[.]test_trivial$" })
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
        local output = native_trace(false)
        assert.match("fallback shallow=%d+ deep=255 long%-trace=%d+", output)
    end)

    it("runs the focused native null backend with Lua frames and one-shot trace pinning", function()
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local output = native_trace(true)
        assert.match("null shallow=0 deep=0 long%-trace=%d+", output)
    end)
end)

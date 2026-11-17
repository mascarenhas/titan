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
    it("embeds one private factory and exposes only the persistent image creator", function()
        local image = "async function Module(options) { return options; }\n" ..
            "const wasm = new URL('app.wasm', import.meta.url);\nexport default Module;\n"
        local loader = "export function create(factory, options) { return {factory, options}; }\n"
        local embedded = assert(browserlink.embed(image, loader, "app.wasm", IDENTITY))
        assert.truthy(embedded:find("async function Module(options)", 1, true))
        assert.truthy(embedded:find("new URL('app.wasm', import.meta.url)", 1, true))
        assert.truthy(embedded:find('new URL("app.wasm.trace", import.meta.url)', 1, true))
        assert.truthy(embedded:find("options.locateFile ??", 1, true))
        assert.truthy(embedded:find("export default function create(options = {})", 1, true))
        assert.is_nil(embedded:find("export default Module", 1, true))
        assert.is_nil(embedded:find("export function create", 1, true))
        local _, exports = embedded:gsub("export default", "")
        assert.equal(1, exports)
    end)

    it("rejects unsupported factory and loader surfaces before image publication", function()
        local loader = "export function create(factory, options) { return options; }\n"
        for _, image in ipairs({
            "const Module = {};\n",
            "export default Module;\n",
            "\nexport default First;\nexport default Module;\n",
            "\nexport default function Module() {}\n",
        }) do
            local embedded, err = browserlink.embed(image, loader, "app.wasm", IDENTITY)
            assert.is_nil(embedded)
            assert.equal("browser image has no unique default factory export", err)
        end
        for _, source in ipairs({
            "function create() {}\n",
            "export function create() {}\nexport const module = {};\n",
            "import runtime from './runtime.mjs';\nexport function create() {}\n",
        }) do
            local embedded, err = browserlink.embed("\nexport default Module;\n", source, "app.wasm", IDENTITY)
            assert.is_nil(embedded)
            assert.equal("browser loader has an unsupported module surface", err)
        end
        for _, identity in ipairs({ IDENTITY:upper(), IDENTITY:sub(2), IDENTITY .. "0", "" }) do
            local embedded, err = browserlink.embed("\nexport default Module;\n", loader, "app.wasm", identity)
            assert.is_nil(embedded)
            assert.equal("browser image identity must be 64 lowercase hexadecimal digits", err)
        end
        local embedded = assert(browserlink.embed("\nexport default Module;\n", loader, 'a"b\n.wasm', IDENTITY))
        assert.truthy(embedded:find('a\\u0022b\\u000a.wasm', 1, true))
    end)

    it("rewrites the pinned Node shell to process.getBuiltinModule in every printed form", function()
        local loader = "export function create(factory, options) { return options; }\n"
        for _, shell in ipairs({
            -- As Emscripten 6.0.13 prints it unoptimized, at -O2, at -Os or -O3,
            -- and without -g2.
            "if (ENVIRONMENT_IS_NODE) {\n" ..
            "  // We need to use `createRequire()` to construct the require()` function.\n" ..
            "  const { createRequire } = await import('node:module');\n" ..
            "  /** @suppress{duplicate} */\n" ..
            "  var require = createRequire(import.meta.url);\n}\n" ..
            "if (ENVIRONMENT_IS_NODE) {\n  var fs = require('node:fs');\n" ..
            "  scriptDirectory = require('node:path').dirname(require('node:url').fileURLToPath(_scriptName)) + '/';\n}\n",
            "if (ENVIRONMENT_IS_NODE) {\n" ..
            "  const {createRequire} = await (import(\"node:module\"));\n" ..
            "  /** @suppress{duplicate} */ var require = createRequire(import.meta.url);\n}\n" ..
            "if (ENVIRONMENT_IS_NODE) {\n  var fs = require(\"node:fs\");\n" ..
            "  scriptDirectory = require(\"node:path\").dirname(require(\"node:url\").fileURLToPath(_scriptName)) + \"/\";\n}\n",
            "if (ENVIRONMENT_IS_NODE) {\n" ..
            "  const {createRequire} = await ((import(\"node:module\")));\n" ..
            "  /** @suppress{duplicate} */ var require = createRequire(import.meta.url);\n}\n" ..
            "if (ENVIRONMENT_IS_NODE) {\n  var fs = require(\"node:fs\");\n" ..
            "  scriptDirectory = require(\"node:path\").dirname(require(\"node:url\").fileURLToPath(_scriptName)) + \"/\";\n}\n",
            "if(ENVIRONMENT_IS_NODE){const{createRequire}=await(import(\"node:module\"));" ..
            "var require=createRequire(import.meta.url)}if(ENVIRONMENT_IS_NODE){var fs=require(\"node:fs\");" ..
            "if(_scriptName.startsWith(\"file:\"))scriptDirectory=require(\"node:path\")" ..
            ".dirname(require(\"node:url\").fileURLToPath(_scriptName))+\"/\"}\n",
        }) do
            local embedded = assert(browserlink.embed(shell .. "\nexport default Module;\n", loader,
                "app.wasm", IDENTITY))
            assert.is_nil(embedded:find("= createRequire(", 1, true))
            assert.is_nil(embedded:find("import(", 1, true))
            assert.is_nil(embedded:find("node:", 1, true))
            local quote = shell:find('"node:fs"', 1, true) and '"' or "'"
            assert.truthy(embedded:find("var fs = process.getBuiltinModule(" .. quote .. "fs" .. quote .. ");",
                1, true))
            assert.truthy(embedded:find("process.getBuiltinModule(" .. quote .. "path" .. quote ..
                ").dirname(process.getBuiltinModule(" .. quote .. "url" .. quote ..
                ").fileURLToPath(_scriptName))", 1, true))
        end
    end)

    it("refuses a Node shell that it recognizes only in part", function()
        local loader = "export function create(factory, options) { return options; }\n"
        -- An unrecognized printing of one statement would leave its `require`.
        local shell = "if (ENVIRONMENT_IS_NODE) {\n" ..
            "  const { createRequire } = await import('node:module');\n" ..
            "  var require = createRequire((import.meta.url));\n}\n" ..
            "if (ENVIRONMENT_IS_NODE) {\n  var fs = require('node:fs');\n" ..
            "  scriptDirectory = require('node:path').dirname(require('node:url').fileURLToPath(_scriptName)) + '/';\n}\n"
        local embedded, err = browserlink.embed(shell .. "\nexport default Module;\n", loader, "app.wasm", IDENTITY)
        assert.is_nil(embedded)
        assert.equal("browser image has an unrecognized Emscripten Node shell", err)
    end)

    it("refuses every way a module loads another and accepts look-alike prose", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        local context = { io = compiler_io.new_sync() }
        local tools = { location = require("titan-compiler.path").dirname(info.tools.cc[1]) }
        local checker = repository .. "/titan-runtime/browser/titan-browser-module-check.mjs"
        local module = workspace .. "/module.mjs"
        local function check(body)
            files.write(module, "async function Module(options) { return options; }\n" .. body ..
                "\nexport default function create() {}\n")
            return browserlink.check_module(context, tools, checker, module)
        end
        local bridge = "pass page JavaScript to Titan as create({bindings}) values through titan.browser"
        local self_contained = "the image module is self-contained; " .. bridge
        local no_node = "browser images load no Node module; " .. bridge
        local builtin = 'uses getBuiltinModule beyond the shell\'s "fs", "path" and "url" calls'
        for _, case in ipairs({
            -- A postfix operator, a statement header and a block before `/`
            -- decide between division and a regular expression.
            { "let a = 1, b = 2, x = a++ / b; require('fs'); let q = a / b;", "uses require at line 2 (require)", no_node },
            { "if (a) /'/.test(b); import('node:fs'); if (b) /'/.test(a);",
                "uses dynamic import() at line 2 (import('node:fs'))", self_contained },
            { "if (a) { b() }\n/'/.test(a); require('fs');", "uses require at line 3 (require)", no_node },
            { "const s = 'a\\\r\nb'; require('fs');", "uses require at line 3 (require)", no_node },
            -- Escaped specifiers name the same module.
            { 'import("\\x6eode:fs");', 'uses dynamic import() at line 2 (import("\\x6eode:fs"))', self_contained },
            { 'import("\\u{6e}ode:fs");', 'uses dynamic import() at line 2 (import("\\u{6e}ode:fs"))', self_contained },
            { 'import("node\\:fs");', 'uses dynamic import() at line 2 (import("node\\:fs"))', self_contained },
            { "import(`\\x6eode:${name}`);", "uses dynamic import() at line 2 (import(`\\x6eode:${name}`))", self_contained },
            { "import('./page.mjs');", "uses dynamic import() at line 2 (import('./page.mjs'))", self_contained },
            -- Every spelling of a call through `require`, and an alias.
            { "(require)('fs');", "uses require at line 2 (require)", no_node },
            { "(0, require)('fs');", "uses require at line 2 (require)", no_node },
            { "require?.('fs');", "uses require at line 2 (require)", no_node },
            { "require`fs`;", "uses require at line 2 (require)", no_node },
            { "const load = require; load('fs');", "uses require at line 2 (require)", no_node },
            { "(module.require)('node:fs');", "reads require at line 2 (module.require)", no_node },
            { "module['require']('fs');", "reads require at line 2 (module['require'])", no_node },
            { "const { require: load } = module;", "reads require at line 2 (require: load)", no_node },
            { "process.getBuiltinModule('os');", builtin .. " at line 2 (process.getBuiltinModule('os'))", no_node },
            { "process.getBuiltinModule('node:fs');",
                builtin .. " at line 2 (process.getBuiltinModule('node:fs'))", no_node },
            { "process.getBuiltinModule(name);", builtin .. " at line 2 (process.getBuiltinModule(name))", no_node },
            { "const get = process.getBuiltinModule; get('fs');",
                builtin .. " at line 2 (process.getBuiltinModule)", no_node },
            { "const { getBuiltinModule } = process;", builtin .. " at line 2 (getBuiltinModule)", no_node },
            { "import fs from 'node:fs';", "imports \"node:fs\" at line 2 (import fs from 'node:fs';)", self_contained },
            { "import './page.mjs';", "imports \"./page.mjs\" at line 2 (import './page.mjs';)", self_contained },
            { "export * from './page.mjs';", "re-exports from \"./page.mjs\" at line 2 (export * from './page.mjs';)",
                self_contained },
            { "export { value } from './page.mjs';",
                "re-exports from \"./page.mjs\" at line 2 (export { value } from './page.mjs';)", self_contained },
        }) do
            local ok, err = check(case[1])
            assert.is_nil(ok, case[1])
            assert.equal("browser image module " .. case[2] .. "; " .. case[3], err)
        end
        local ok, err = check("const broken = 'node")
        assert.is_nil(ok)
        assert.equal("browser image module does not parse as an ES module: Unterminated string constant (2:15)", err)
        assert.is_true(check(table.concat({
            "// We need `createRequire()` to construct the require() function; import('node:fs').",
            "/* const fs = await import('node:fs'); require('fs'); */",
            "const help = 'pass require(\"node:fs\") nothing', ratio = total / 2 / count;",
            "const options = { require: false, requireTrace: true }, more = options.requires;",
            "const quote = /['\"`]/g, text = `a ${ {b: '}'}.b } c`;",
            "here: for (;;) break here;",
            "const url = new URL('app.wasm', import.meta.url);",
            "var fs = process.getBuiltinModule('fs');",
            "var directory = process.getBuiltinModule(\"path\").dirname(process.getBuiltinModule(\"url\").fileURLToPath(url));",
        }, "\n")))
    end)

    it("derives the closed SDK asset set without extending BrowserPaths", function()
        local paths = fixtures.paths()
        local assets = browserlink.sdk_assets(paths)
        assert.equal(paths.libtitan, assets.runtime)
        assert.equal(paths.sdk_digests, assets.sdk_digests)
        local keys = {}
        for key in pairs(assets) do keys[#keys + 1] = key end
        table.sort(keys)
        assert.same({ "bridge_library", "build_profile", "js_library", "loader", "lpeglabel", "module_check",
            "node_worker", "page", "provider", "runner", "runner_module", "runtime", "sdk_digests", "trace_library" },
            keys)
    end)

    it("requires only readable runtime and JS assets, in bootstrap order", function()
        local descriptor = fixtures.descriptor()
        local assets = browserlink.sdk_assets(descriptor.paths)
        local present = {}
        local context = { io = {
            stat = function(_, filename) return present[filename] and { kind = "file" } end,
            read_file = function(_, filename)
                return present[filename] and (filename == assets.build_profile and descriptor.build_profile .. "\n" or "bytes")
            end,
        } }
        for _, key in ipairs({ "runtime", "js_library", "bridge_library", "trace_library",
                "loader", "runner", "runner_module", "node_worker", "page", "module_check", "build_profile" }) do
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

    it("renders native stdio and unavailable file syscalls in every launcher", function()
        local source = driver.browser_c_image_contents(
            "static int titan_browser_worker(lua_State *L) { return 0; }")
        for _, header in ipairs({ "errno.h", "wasi/api.h", "emscripten/syscalls.h" }) do
            assert.truthy(source:find("#include <" .. header .. ">", 1, true), header)
        end
        for _, name in ipairs({ "__wasi_fd_write", "__wasi_fd_read", "__wasi_fd_close", "__wasi_fd_seek",
            "__syscall_openat", "__syscall_unlinkat", "__syscall_renameat", "__syscall_rmdir",
            "__syscall_stat64", "__syscall_lstat64", "__syscall_fstat64", "__syscall_newfstatat",
            "__syscall_getcwd", "__syscall_readlinkat", "__syscall_ioctl", "__syscall_fcntl64",
            "__syscall_dup3", "_emscripten_system" }) do
            assert.truthy(source:find(name .. "(", 1, true), name)
        end
        assert.truthy(source:find("titan_browser_host_output(fd, iovs[i].buf, iovs[i].buf_len)", 1, true))
        assert.truthy(source:find("*nwritten = total;", 1, true))
    end)

    it("exports private current HEAPU8 and exact production marshalling exports", function()
        local descriptor = fixtures.descriptor()
        local profile = assert(browserlink.profile(descriptor, { purpose = "program", assertions = 2 }))
        assert.same({}, profile.compile_flags)
        assert.same({
            "-O1", "-fno-inline", "-fno-optimize-sibling-calls", "-gsource-map", "-g2",
            "-sJSPI=1",
            '-sJSPI_IMPORTS=["titan_mco_transfer","titan_mco_destroy","titan_browser_relinquish"]',
            '-sJSPI_EXPORTS=["titan_browser_initialize","titan_browser_entry","titan_browser_invoke",' ..
                '"titan_browser_close","titan_mco_entry"]',
            "-sSUPPORT_LONGJMP=wasm", "-sWASM_LEGACY_EXCEPTIONS=1", "-sSTACK_SIZE=1048576",
            "-sINITIAL_HEAP=15728640", "-sALLOW_MEMORY_GROWTH=1",
            "-sMAXIMUM_MEMORY=2147483648", "-sABORTING_MALLOC=0", "-sEXIT_RUNTIME=0", "-sINVOKE_RUN=0",
            "--no-entry", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sENVIRONMENT=web,node",
            "-sMIN_NODE_VERSION=260000", "-sFILESYSTEM=0", "-sPRINTF_LONG_DOUBLE=1",
            '-sEXPORTED_FUNCTIONS=["_titan_browser_initialize","_titan_browser_entry","_titan_browser_invoke",' ..
                '"_titan_browser_release_callable","_titan_browser_close",' ..
                '"_malloc","_free","_titan_browser_trace_identity"]',
            '-sEXPORTED_RUNTIME_METHODS=["HEAPU8"]',
            '-sINCOMING_MODULE_JS_API=["locateFile","onAbort"]',
            "--js-library", browserlink.sdk_assets(descriptor.paths).js_library,
            "--js-library", browserlink.sdk_assets(descriptor.paths).bridge_library,
            "--js-library", browserlink.sdk_assets(descriptor.paths).trace_library,
            "-sASSERTIONS=2", "-sSTACK_OVERFLOW_CHECK=2",
        }, profile.link_flags)
        assert.equal(descriptor.identity, profile.identity_inputs.target_identity)
        assert.equal("-O1", profile.identity_inputs.optimization)
        assert.equal("validation", profile.identity_inputs.profile)
    end)

    it("gives production programs the descriptor level and no frame flags", function()
        local descriptor = fixtures.descriptor(nil, { build_profile = "production" })
        local profile = assert(browserlink.profile(descriptor, { purpose = "program", assertions = 2 }))
        assert.same({}, profile.compile_flags)
        assert.same({
            "-O3", "-gsource-map", "-g2",
            "-sJSPI=1",
            '-sJSPI_IMPORTS=["titan_mco_transfer","titan_mco_destroy","titan_browser_relinquish"]',
            '-sJSPI_EXPORTS=["titan_browser_initialize","titan_browser_entry","titan_browser_invoke",' ..
                '"titan_browser_close","titan_mco_entry"]',
            "-sSUPPORT_LONGJMP=wasm", "-sWASM_LEGACY_EXCEPTIONS=1", "-sSTACK_SIZE=1048576",
            "-sINITIAL_HEAP=15728640", "-sALLOW_MEMORY_GROWTH=1",
            "-sMAXIMUM_MEMORY=2147483648", "-sABORTING_MALLOC=0", "-sEXIT_RUNTIME=0", "-sINVOKE_RUN=0",
            "--no-entry", "-sMODULARIZE=1", "-sEXPORT_ES6=1", "-sENVIRONMENT=web,node",
            "-sMIN_NODE_VERSION=260000", "-sFILESYSTEM=0", "-sPRINTF_LONG_DOUBLE=1",
            '-sEXPORTED_FUNCTIONS=["_titan_browser_initialize","_titan_browser_entry","_titan_browser_invoke",' ..
                '"_titan_browser_release_callable","_titan_browser_close",' ..
                '"_malloc","_free","_titan_browser_trace_identity"]',
            '-sEXPORTED_RUNTIME_METHODS=["HEAPU8"]',
            '-sINCOMING_MODULE_JS_API=["locateFile","onAbort"]',
            "--js-library", browserlink.sdk_assets(descriptor.paths).js_library,
            "--js-library", browserlink.sdk_assets(descriptor.paths).bridge_library,
            "--js-library", browserlink.sdk_assets(descriptor.paths).trace_library,
            "-sASSERTIONS=2", "-sSTACK_OVERFLOW_CHECK=2",
        }, profile.link_flags)
        assert.equal("-O3", profile.identity_inputs.optimization)
        assert.equal("production", profile.identity_inputs.profile)
    end)

    it("keeps frames and skips Binaryen inlining in a production test image", function()
        local descriptor = fixtures.descriptor(nil, { build_profile = "production" })
        local profile = assert(browserlink.profile(descriptor, { purpose = "test", assertions = 2 }))
        local flags = table.concat(profile.link_flags, " ")
        assert.truthy(flags:find("-O3 -fno-inline -fno-optimize-sibling-calls -gsource-map -g2 ", 1, true), flags)
        assert.truthy(flags:find(
            "-sBINARYEN_EXTRA_PASSES=--skip-pass=inlining-optimizing," ..
            "--skip-pass=duplicate-function-elimination", 1, true), flags)
        -- The validation profile never runs the level optimizer, so its test
        -- images keep #330's frozen link flags exactly.
        local frozen = assert(browserlink.profile(fixtures.descriptor(), { purpose = "test", assertions = 2 }))
        local program = assert(browserlink.profile(fixtures.descriptor(), { purpose = "program", assertions = 2 }))
        assert.same(program.link_flags, frozen.link_flags)
        -- Harness purposes keep their frame-preserving link settings even when
        -- the installation optimizes.
        for _, purpose in ipairs({ "protocol", "gate", "minicoro", "budget", "baseline" }) do
            local harness = assert(browserlink.profile(descriptor, { purpose = purpose, assertions = 2 }))
            local text = table.concat(harness.link_flags, " ")
            assert.truthy(text:find("-fno-inline -fno-optimize-sibling-calls", 1, true), purpose)
            assert.is_nil(text:find("--skip-pass", 1, true), purpose)
        end
    end)

    it("keeps internal gate, budget and baseline variants constrained", function()
        local descriptor = fixtures.descriptor()
        local gate = assert(browserlink.profile(descriptor, { purpose = "gate", assertions = 0 }))
        assert.truthy(table.concat(gate.link_flags, " "):find('"_titan_browser_gate_guarded","_titan_browser_gate_observe"', 1, true))
        for _, options in ipairs({
            { purpose = "protocol", assertions = 2, optimization = "O2" },
            { purpose = "program", assertions = 2, budgets = {} },
            { purpose = "gate", assertions = 1 }, { purpose = "program", assertions = 2, unknown = true },
            { purpose = "gate", assertions = 2, entry = "lua-main" },
            { purpose = "budget", assertions = 2, budgets = { stack_size = 17 } },
            { purpose = "budget", assertions = 2, budgets = { initial_memory = 16777216 } },
            { purpose = "budget", assertions = 2, budgets = { initial_heap = 32768 } },
            { purpose = "budget", assertions = 2, budgets = { initial_heap = 2146500608 } },
            -- Aligned values whose sum with the other budget would wrap.
            { purpose = "budget", assertions = 2, budgets = { initial_heap = 0x7fffffffffff0000 } },
            { purpose = "budget", assertions = 2, budgets = { stack_size = 0x7ffffffffffffff0 } },
            { purpose = "budget", assertions = 2, budgets = { stack_size = 2147483648 } } }) do
            assert.is_nil(browserlink.profile(descriptor, options))
        end
        local budget = assert(browserlink.profile(descriptor, { purpose = "budget", assertions = 2,
            optimization = "O1", budgets = { stack_size = 65536, initial_heap = 65536 } }))
        assert.truthy(table.concat(budget.link_flags, " "):find("-sSTACK_SIZE=65536 -sINITIAL_HEAP=65536 ", 1, true))
        assert.same({ "-O1" }, budget.compile_flags)
        local baseline = assert(browserlink.profile(descriptor, { purpose = "baseline", assertions = 2,
            entry = "lua-main", optimization = "O2" }))
        local flags = table.concat(baseline.link_flags, " ")
        assert.is_nil(flags:find("--no-entry", 1, true))
        assert.is_nil(flags:find("--js-library", 1, true))
        assert.truthy(flags:find('-sEXPORTED_FUNCTIONS=["_main","_malloc","_free"]', 1, true))
    end)

    it("owns one JSPI backend and records explicit import/export identity for every purpose", function()
        for _, purpose in ipairs({ "program", "test", "protocol", "gate", "minicoro", "budget", "baseline" }) do
            for _, assertions in ipairs({ 0, 2 }) do
                local plan = assert(browserlink.profile(fixtures.descriptor(),
                    { purpose = purpose, assertions = assertions }))
                local flags = table.concat(plan.link_flags, " ")
                assert.truthy(flags:find("-sJSPI=1", 1, true))
                assert.truthy(flags:find("-sJSPI_IMPORTS=", 1, true))
                assert.truthy(flags:find("-sJSPI_EXPORTS=", 1, true))
                assert.is_nil(flags:find("ASYNCIFY", 1, true))
                assert.is_nil(flags:find("simplify-locals", 1, true))
                assert.equal("jspi", plan.identity_inputs.backend)
                assert.same(plan.link_flags, plan.identity_inputs.link_flags)
            end
        end
    end)

    it("disables the launcher filesystem while preserving the interpreter baseline", function()
        for _, purpose in ipairs({ "program", "test", "protocol", "gate", "minicoro", "budget", "baseline" }) do
            for _, entry in ipairs(purpose == "baseline" and { "titan", "lua-main" } or { "titan" }) do
                local plan = assert(browserlink.profile(fixtures.descriptor(),
                    { purpose = purpose, assertions = 2, entry = entry }))
                local flags = table.concat(plan.link_flags, " ")
                assert.truthy(flags:find(entry == "titan" and "-sFILESYSTEM=0" or "-sFORCE_FILESYSTEM=1", 1, true))
                assert.is_nil(flags:find(entry == "titan" and "-sFORCE_FILESYSTEM=" or "-sFILESYSTEM=", 1, true))
                assert.truthy(flags:find(entry == "titan" and
                    '-sINCOMING_MODULE_JS_API=["locateFile","onAbort"]' or
                    '-sINCOMING_MODULE_JS_API=["stdin","stdout","stderr","locateFile","onAbort"]', 1, true))
                assert.same(plan.link_flags, plan.identity_inputs.link_flags)
            end
        end
    end)

    it("preserves long-double printf precision in every profile, purpose and entry", function()
        for _, build_profile in ipairs({ "production", "validation" }) do
            for _, purpose in ipairs({ "program", "test", "protocol", "gate", "minicoro", "budget", "baseline" }) do
                for _, entry in ipairs(purpose == "baseline" and { "titan", "lua-main" } or { "titan" }) do
                    local plan = assert(browserlink.profile(fixtures.descriptor(nil, {build_profile = build_profile}),
                        {purpose = purpose, assertions = 2, entry = entry}))
                    local count = 0
                    for _, flag in ipairs(plan.link_flags) do
                        if flag == "-sPRINTF_LONG_DOUBLE=1" then count = count + 1 end
                    end
                    assert.equal(1, count)
                    assert.same(plan.link_flags, plan.identity_inputs.link_flags)
                end
            end
        end
    end)

    it("pins legacy Wasm EH in every profile, purpose and entry", function()
        for _, build_profile in ipairs({ "production", "validation" }) do
            for _, purpose in ipairs({ "program", "test", "protocol", "gate", "minicoro", "budget", "baseline" }) do
                for _, entry in ipairs(purpose == "baseline" and { "titan", "lua-main" } or { "titan" }) do
                    local plan = assert(browserlink.profile(fixtures.descriptor(nil, { build_profile = build_profile }),
                        { purpose = purpose, assertions = 2, entry = entry }))
                    local sjlj, legacy = 0, 0
                    for _, flag in ipairs(plan.link_flags) do
                        if flag == "-sSUPPORT_LONGJMP=wasm" then sjlj = sjlj + 1 end
                        if flag == "-sWASM_LEGACY_EXCEPTIONS=1" then legacy = legacy + 1 end
                    end
                    assert.equal(1, sjlj)
                    assert.equal(1, legacy)
                    assert.same(plan.link_flags, plan.identity_inputs.link_flags)
                end
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
        local test_flags = table.concat(test_plan.link_flags, " ")
        assert.truthy(test_flags:find("-O3 -fno-inline -fno-optimize-sibling-calls", 1, true), test_flags)
        assert.truthy(test_flags:find("--skip-pass=inlining-optimizing", 1, true), test_flags)
        assert.truthy(test_flags:find("--skip-pass=duplicate-function-elimination", 1, true), test_flags)
        local program_plan = assert(driver.browser_link_plan({ target = "browser", link_kind = "program" }))
        assert.equal("program", program_plan.identity_inputs.purpose)
        local program_flags = table.concat(program_plan.link_flags, " ")
        assert.is_nil(program_flags:find("-fno-inline", 1, true), program_flags)
        assert.is_nil(program_flags:find("--skip-pass", 1, true), program_flags)
        -- A harness purpose is not an image kind and stays usable on either kind.
        driver.browser_link_options = { purpose = "budget", assertions = 2 }
        assert.equal("budget", assert(driver.browser_link_plan(test_context)).identity_inputs.purpose)
        assert.equal("budget", assert(driver.browser_link_plan(
            { target = "browser", link_kind = "program" })).identity_inputs.purpose)
        -- A program purpose may never certify or link a test image, or the reverse,
        -- whether the caller passes the kind explicitly (titanc's certificate call
        -- and compile_browser_image's shape) or lets it be derived.
        local program_context = { target = "browser", link_kind = "program" }
        for _, call in ipairs({ { test_context }, { test_context, "test" } }) do
            driver.browser_link_options = { purpose = "program", assertions = 2 }
            local refused, err = driver.browser_link_plan(call[1], call[2])
            assert.is_nil(refused)
            assert.equal('browser link purpose "program" does not match this test image', err)
        end
        for _, call in ipairs({ { program_context }, { program_context, "program" } }) do
            driver.browser_link_options = { purpose = "test", assertions = 2 }
            local refused, err = driver.browser_link_plan(call[1], call[2])
            assert.is_nil(refused)
            assert.equal('browser link purpose "test" does not match this program image', err)
        end
        -- An agreeing preset still certifies and links, through both shapes.
        for _, call in ipairs({ { test_context }, { test_context, "test" } }) do
            driver.browser_link_options = { purpose = "test", assertions = 2 }
            assert.equal("test", assert(driver.browser_link_plan(call[1], call[2])).identity_inputs.purpose)
        end
        -- A preset harness table must name its profile; inheriting the kind
        -- would silently give a measurement build an image's flags.
        driver.browser_link_options = { assertions = 2 }
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
        local result = cli({ prefix = info.prefix, profile = other }, "plain")
        assert.is_false(result.ok, "a link under another profile was accepted")
        local log = result.output or result.diagnostic or ""
        -- The SDK path is the descriptor's spelling of the installation root.
        assert.truthy(log:find(string.format("/lib/titan-browser/0.6\" was built with the %s profile, but this build " ..
            "uses %s; set TITAN_BUILD_PROFILE=%s, or build a %s browser SDK in another prefix with " ..
            "'make browser-sdk PREFIX=<prefix> TITAN_BUILD_PROFILE=%s'", sdk, other, sdk, other, other), 1, true), log)
        assert.is_nil(lfs.attributes(workspace .. "/out/plain.mjs"))
    end)

    it("refuses a preset link profile that names no purpose", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/plain.titan",
            "function answer(): integer\n    return 1\nend\n")
        local result = cli({ prefix = info.prefix,
            compiler_setup = "require('titan-compiler.driver').browser_link_options={assertions=2};" },
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
            { arguments = { "-c", "plain" }, extra_cflags = "-sBINARYEN_EXTRA_PASSES=--coalesce-locals",
                expected = compile .. '"-sBINARYEN_EXTRA_PASSES=--coalesce-locals"' },
            -- --ldflag is a link-phase option, which -c rejects, so the link
            -- cases run the ordinary build and stop at the ownership check.
            { arguments = { "plain", "--ldflag=-O3" }, expected = link .. "-O3" },
            { arguments = { "plain", "--ldflag=-fno-optimize-sibling-calls" }, expected = link .. "-fno-optimize-sibling-calls" },
            { arguments = { "plain", "--ldflag=--pre-js=pre.js" }, expected = "browser " .. profile ..
                " link profile does not accept --pre-js; add JavaScript with EM_JS or EM_ASM in a --c-source helper" },
        }) do
            local result = cli({ prefix = info.prefix, extra_cflags = case.extra_cflags },
                table.unpack(case.arguments))
            assert.is_false(result.ok, "the CLI accepted an owned option: " .. case.expected)
            local log = result.output or result.diagnostic or ""
            assert.truthy(log:find(case.expected, 1, true), log)
            local other = case.expected:find("link profile", 1, true) and compile or link
            assert.is_nil(log:find(other, 1, true), log)
        end
    end)

    it("refuses link options whose files the image identity does not record", function()
        local javascript = "add JavaScript with EM_JS or EM_ASM in a --c-source helper"
        for _, case in ipairs({
            { { "--pre-js", "pre.js" }, "--pre-js; " .. javascript },
            { { "--post-js=post.js" }, "--post-js; " .. javascript },
            { { "-lm", "--extern-pre-js", "pre.js" }, "--extern-pre-js; " .. javascript },
            { { "--extern-post-js=post.js" }, "--extern-post-js; " .. javascript },
            { { "--js-transform", "cat" }, "--js-transform; the generated module is Titan's" },
            { { "--embed-file", "data" }, "--embed-file; browser images have no filesystem" },
            { { "--preload-file=data" }, "--preload-file; browser images have no filesystem" },
            { { "--exclude-file", "*.tmp" }, "--exclude-file; browser images have no filesystem" },
        }) do
            local ok, err = browserlink.validate_extras(case[1], nil, "production")
            assert.is_nil(ok)
            assert.equal("browser production link profile does not accept " .. case[2], err)
        end
    end)

    it("rejects trailing attempts to override profile-owned settings", function()
        for _, flags in ipairs({ { "-sASYNCIFY=0" }, { "-s", "ASYNCIFY_IGNORE_INDIRECT=1" },
            { "-DTITAN_COROUTINE_STACK_SIZE=1" }, { "-UTITAN_TARGET_BROWSER" }, { "-sNO_ASYNCIFY=1" },
            { "-sJSPI=0" }, { "-s", "JSPI_EXPORTS=[]" }, { "-sNO_JSPI=1" },
            { "-sJSPI_IMPORTS=[]" }, { "-DJSPI=0" }, { "-U", "JSPI_EXPORTS" },
            { "-sFORCE_FILESYSTEM=0" }, { "-sFILESYSTEM=0" }, { "-sMINIMAL_RUNTIME=1" },
            { "-sINITIAL_MEMORY=33554432" }, { "-sINITIAL_HEAP=33554432" },
            { "-sMIN_NODE_VERSION=180300" }, { "-s", "MIN_NODE_VERSION=220000" },
            { "--js-library=x.js" }, { "--no-entry" } }) do
            assert.is_nil(browserlink.validate_extras(flags))
        end
        assert.is_true(browserlink.validate_extras({ "-lm", "-sWASM_BIGINT=1" }))
        for _, flag in ipairs({ "-O3", "-g0", "-finline-functions", "-foptimize-sibling-calls" }) do
            assert.is_nil(browserlink.validate_extras({ flag }))
        end
        for _, purpose in ipairs({ "baseline", "minicoro", "budget" }) do
            assert.is_true(browserlink.validate_extras({ "-g2", "-Os" }, { purpose = purpose }))
        end
        for _, purpose in ipairs({ "program", "test", "protocol", "gate", "baseline", "minicoro", "budget" }) do
            for _, flags in ipairs({
                { "-sBINARYEN_EXTRA_PASSES=" },
                { "-s", "BINARYEN_EXTRA_PASSES=coalesce-locals" },
                { "-sNO_BINARYEN_EXTRA_PASSES=1" },
                { "-DBINARYEN_EXTRA_PASSES=0" },
                { "-U", "BINARYEN_EXTRA_PASSES" },
                { "-sPRINTF_LONG_DOUBLE=0" },
                { "-s", "PRINTF_LONG_DOUBLE=0" },
                { "-sNO_PRINTF_LONG_DOUBLE=1" },
                { "-sWASM_LEGACY_EXCEPTIONS=0" },
                { "-s", "WASM_LEGACY_EXCEPTIONS=0" },
                { "-sNO_WASM_LEGACY_EXCEPTIONS=1" },
                { "-s", "NO_WASM_LEGACY_EXCEPTIONS" },
                { "-DPRINTF_LONG_DOUBLE=0" },
                { "-U", "PRINTF_LONG_DOUBLE" },
                { "-DTITAN_CODEC_DEPTH_LIMIT=1000" },
                { "-D", "TITAN_CODEC_DEPTH_LIMIT=1000" },
                { "-UTITAN_CODEC_DEPTH_LIMIT" },
                { "-U", "TITAN_CODEC_DEPTH_LIMIT" },
            }) do
                local ok, why = browserlink.validate_extras(flags, { purpose = purpose })
                assert.is_nil(ok)
                assert.equal("browser link profile owns option " .. flags[1], why)
            end
        end
        -- Compile extras are reported by the compile diagnostic, link extras by
        -- the link one (OG-L4): the same option, one owner, one message.
        for _, flag in ipairs({ "-O2", "-g2", "-fno-inline", "-DTITAN_TARGET_BROWSER=1",
            "-DTITAN_CODEC_DEPTH_LIMIT=1000", "-UTITAN_CODEC_DEPTH_LIMIT" }) do
            local ok, why = browserlink.validate_extras({ flag }, { purpose = "gate" }, "production", "compile")
            assert.is_nil(ok)
            assert.equal('browser production profile owns compile option "' .. flag .. '"', why)
        end
        assert.is_nil(browserlink.validate_extras({ "-O2" }, { purpose = "gate" }, "production"))
        -- The real call path names the installation profile it protects.
        for _, purpose in ipairs({ "program", "test", "gate" }) do
            for _, profile in ipairs({ "production", "validation" }) do
                for _, flag in ipairs({ "-O2", "-g2", "-fno-inline",
                    "-fno-optimize-sibling-calls" }) do
                    local ok, why = browserlink.validate_extras({ flag }, { purpose = purpose }, profile)
                    assert.is_nil(ok)
                    assert.equal("browser " .. profile .. " link profile owns option " .. flag, why)
                end
                local ok = browserlink.validate_extras({ "-sBINARYEN_EXTRA_PASSES=--coalesce-locals" },
                    { purpose = purpose }, profile)
                assert.is_nil(ok)
            end
            -- Unrelated Emscripten settings still pass through.
            assert.is_true(browserlink.validate_extras({ "-sWASM_BIGINT=1", "-lm" },
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
        files.write(workspace .. "/src/long_double.titan", read(repository .. "/spec/fixtures/browser_images/long_double.titan"))
        local setup = string.format("package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;")
        local native_image = workspace .. "/native/long_double"
        local native_build = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=", "TITAN_PATH_0_6=",
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            info.prefix .. "/bin/lua", "-E", "-e", setup, repository .. "/titanc", "-q", "--incremental",
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
            local result = run({info.sdk_root .. "/titan-browser-run", "--engine", engine, "--grace", "0",
                workspace .. "/out/long_double.mjs"})
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
        for _, assertions in ipairs({ 0, 2 }) do
            local root = workspace .. "/assertions-" .. assertions
            local ok, log = runtime.cli(info, root, { purpose = "test", assertions = assertions }, {
                "--test", "--exe", root .. "/public.mjs",
                "--c-source", runtime.fixture .. "/close.c", "coroutine.tests", "gc.tests" })
            assert.is_true(ok, log)
            local maximum = maximum_declared_locals(read(root .. "/public.wasm"))
            assert.is_true(maximum > 0 and maximum < 10000,
                "coroutine image declares too many function locals: " .. maximum)
            image_identity(info, root .. "/public.mjs", "unwind_common.titan")
            io.stdout:write(string.format("\nCOROUTINE-LOCALS assertions=%d max-declared=%d\n", assertions, maximum))
            io.stdout:flush()
        end
    end)

    -- Production-only by construction: it asserts the production object and
    -- link profile from a real production installation. CI runs it in the
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
                string.format("{purpose=%q,assertions=2};", purpose)) or ""
            local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=", "TITAN_PATH_0_6=",
                "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
                "TITAN_PROBE_CACHE_DISABLE=1", "CCACHE_DISABLE=1",
                info.prefix .. "/bin/lua", "-E", "-e", setup .. options, repository .. "/titanc",
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
        local test_link = command(test_log, "test_image.mjs'", "'--no-entry'")
        assert.truthy(test_link:find("'-fno-inline'", 1, true), test_link)
        assert.truthy(test_link:find("--skip-pass=inlining-optimizing", 1, true), test_link)
        assert.truthy(test_link:find("--skip-pass=duplicate-function-elimination", 1, true), test_link)
        local program_log = build("program_image", nil, false)
        local plain = command(program_log, "/trace_uncaught.c'", "'-c'")
        assert.is_nil(plain:find("'-fno-inline'", 1, true), plain)
        local program_link = command(program_log, "program_image.mjs'", "'--no-entry'")
        assert.is_nil(program_link:find("'-fno-inline'", 1, true), program_link)
        assert.is_nil(program_link:find("--skip-pass", 1, true), program_link)
    end)

    -- Runs in both installations (CI's production cell selects it by name), so
    -- each profile links a real image through the module check.
    it("checks the linked module: accepts a real image and refuses an EM_JS import", function()
        local info, why = toolchain.require({ node = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        files.write(workspace .. "/src/checked.titan", "function main(args: {string}): integer\n    return #args\nend\n")
        local helper = workspace .. "/helper.c"
        local function link(body)
            files.write(helper, "#include <emscripten.h>\nEM_JS(int, page_value, (void), {\n" .. body ..
                "\n});\n__attribute__((constructor)) static void load(void) { page_value(); }\n")
            return cli(info, "--c-source", helper, "checked")
        end
        local result = link("  import('./page.mjs');\n  return 1;")
        assert.is_false(result.ok, "an EM_JS dynamic import was published")
        local log = result.output or result.diagnostic or ""
        assert.truthy(log:find("browser image module uses dynamic import() at line ", 1, true), log)
        -- The diagnostic quotes the final module, whose string quotes the
        -- profile's minifier may rewrite.
        assert.truthy(log:find("%(import%((['\"])%./page%.mjs%1%)%); the image module is self%-contained; " ..
            "pass page JavaScript to Titan as create%({bindings}%) values through titan%.browser"), log)
        for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.trace", ".wasm.map" }) do
            assert.is_nil(lfs.attributes(workspace .. "/out/checked" .. suffix), suffix)
        end
        result = link("  return globalThis.pageValue ?? 1;")
        assert.is_true(result.ok, result.output or result.diagnostic)
        for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.trace", ".wasm.map" }) do
            assert.equal("file", lfs.attributes(workspace .. "/out/checked" .. suffix, "mode"), suffix)
        end
    end)

    it("raises the five dynamic-provider guard diagnostics without native loader imports", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        local image = c_image(info, "dynamic-guards", read(repository .. "/spec/fixtures/browser_images/dynamic-guards.c"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = run({ info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", image })
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
            require("titan-compiler.path").dirname(info.tools.clang[1]), "llvm-objdump")
        for _, image in ipairs({ "image_main", "explicit-program" }) do
            assert.equal("file", lfs.attributes(workspace .. "/out/" .. image .. ".mjs", "mode"))
            local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/" .. image .. ".wasm")))
            local exports = {}
            for _, item in ipairs(inventory.exports) do exports[item.name] = true end
            for _, name in ipairs({ "titan_browser_initialize", "titan_browser_entry", "titan_browser_invoke",
                    "titan_browser_release_callable", "titan_browser_close", "malloc", "free" }) do
                assert.is_true(exports[name], "missing browser gateway " .. name)
            end
            assert.is_nil(exports.titan_browser_gate_guarded)
            assert.is_nil(exports.main)
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
            result = run({ info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--",
                "image_main.mjs", "explicit-program.mjs" })
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
            result = run({ info.sdk_root .. "/titan-browser-run", "--grace", "0", workspace .. "/out/" .. name .. ".mjs" })
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

    it("delivers native C stdio batches and rejects file calls under Node and Chromium", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.mkdir(workspace .. "/src")
        c_image(info, "stdio-image", read(repository .. "/spec/fixtures/browser_images/stdio-only.c"))
        local fixture = workspace .. "/out/stdio-only.mjs"
        files.write(fixture, read(repository .. "/spec/fixtures/browser_images/stdio-only.mjs"))
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = run({ info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--chrome", info.chrome.path, "--grace", "0", "--js-test", fixture, "--", "stdio-image.mjs" })
            assert.is_true(result.ok, result.output or result.diagnostic)
            assert.is_nil(result.output:find("TITAN_UNEXPECTED_HOST_SHELL", 1, true), result.output)
        end
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
    { context = context, profile = { purpose = "protocol", assertions = 2 } })
assert(not ok and why:find("aliases input", 1, true), tostring(why))
assert(driver.close_resolver_context(context))
]], workspace, entrypoint, executable, map)
        local result = run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
            info.prefix .. "/bin/lua", "-E", "-e",
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
            result = run({ info.sdk_root .. "/titan-browser-run", "--engine", "node", "--grace", "0",
                workspace .. "/out/trace_names.mjs", "--", row[1] })
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
local real_run, links = strategy.run, 0
function strategy:run(argv, options)
    local count = 0
    for _, flag in ipairs(argv) do
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
        { context = context, profile = { purpose = "protocol", assertions = 2 },
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
            info.prefix .. "/bin/lua", "-E", "-e", string.format("package.path=%q..package.path;",
                repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. script })
        assert.is_true(result.ok, result.output or result.diagnostic)
        assert.match("^[0-9a-f]+$", image_identity(info, workspace .. "/out/repeated.mjs"))
    end)

    it("publishes a matching extended map and callable identity for an optimized JSPI measurement control", function()
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
        local variant = { prefix = info.prefix, compiler_setup = string.format([[
local driver = require "titan-compiler.driver"
driver.browser_link_options = {purpose='baseline',assertions=0,optimization='O2'}
local run_link = driver.run_link_command
driver.run_link_command = function(argv, ...)
    local protocol, library, demangle = false, nil, nil
    for index, flag in ipairs(argv) do
        if flag == "-sASSERTIONS=2" then protocol = true end
        if flag == %q then library = index end
        if flag == "-Wl,--no-demangle" then demangle = index end
    end
    if protocol then
        for _, flag in ipairs(argv) do assert(flag ~= "-Os", "measurement override reached protocol link") end
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
        assert.truthy(result.output:find("control protocol link\n", 1, true),
            "measurement control did not execute the real static-provider protocol link")
        local image = workspace .. "/out/image_control.mjs"
        local inventory = assert(browserlink.image_inventory(read(workspace .. "/out/image_control.wasm")))
        -- The pinned JSPI path explicitly disables import/export minification
        -- (Emscripten tools/link.py); do not claim an unsupported minified cell.
        local stable_identity = false
        for _, item in ipairs(inventory.exports) do
            if item.name == "titan_browser_trace_identity" then stable_identity = true end
        end
        assert.is_true(stable_identity, "JSPI identity export did not follow the pinned naming contract")
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
            assert.truthy(before:match('#line %d+ "[^\n]-definitions[.]titan"\n[^\n]*$'), name)
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
        local output = native_trace()
        assert.match("fallback shallow=%d+ deep=255 long%-trace=%d+", output)
    end)

end)

local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local compiler_io = require "titan-compiler.io"
local staticmetadata = require "titan-compiler.staticmetadata"
local objectmetadata = require "titan-compiler.objectmetadata"
local depfile = require "titan-compiler.depfile"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local repository = assert(lfs.currentdir())
local paths = require "titan-compiler.path"
local workspace

local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = assert(file:read("a")); assert(file:close())
    return bytes
end

local function run(info, code, ...)
    local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=" .. (info.target or ""), "CCACHE_DISABLE=1",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_RUNTIME_PREBUILT=1", info.prefix .. "/bin/lua", "-E", "-e",
        string.format("package.path=%q..package.path;", repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. code }
    if info.emcc_cflags then table.insert(argv, 2, "EMCC_CFLAGS=" .. info.emcc_cflags) end
    for _, argument in ipairs({ ... }) do argv[#argv + 1] = argument end
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.started and result.ok, result.output or result.diagnostic or ""
end

local function prepare()
    workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
    files.mkdir(workspace .. "/source"); files.mkdir(workspace .. "/out")
    files.write(workspace .. "/source/browser_facts.h", [[
#ifndef TITAN_BROWSER_FACTS_H
#define TITAN_BROWSER_FACTS_H
#if TITAN_TARGET_BROWSER != 1
#error browser target define did not reach FFI and generated C
#endif
#if __SIZEOF_POINTER__ != 4 || __SIZEOF_LONG__ != 4
#error browser compilation used host C widths
#endif
#define BROWSER_HEADER_VALUE 42
#endif
]])
    files.write(workspace .. "/source/object_fixture.titan", [[
foreign import "browser_facts.h"
function answer(): integer
    return ffi.BROWSER_HEADER_VALUE
end
]])
end

local function cli(info, ...)
    return run(info, "", repository .. "/titanc",
        "--target", "browser", "-q", "--tree", workspace .. "/source",
        "--output", info.output or workspace .. "/out", ...)
end

local function wasm_object(filename)
    local bytes = read(filename)
    assert.equal("\0asm", bytes:sub(1, 4))
    local object = assert(staticmetadata.classify_object(bytes, filename))
    assert.equal("wasm", object.fingerprint.format)
    assert.equal(32, object.fingerprint.word_size)
    return object, bytes
end

describe("browser real object toolchain", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)

    it("verifies the real fork record and compiles a module directly with target C facts", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        local script = string.format([[
local driver = require "titan-compiler.driver"
local browser = require "titan-compiler.browsertarget"
driver.TITAN_SOURCE_PATH = %q
driver.apply_native_inputs({ compile_argv = {}, link_argv = {} })
local context = driver.new_resolver_context({ target = "browser", output_root = %q })
assert(driver.configure_foreign_c(context))
local descriptor = assert(driver.context_target_descriptor(context))
assert(descriptor.tools.version == "6.0.13")
assert(descriptor.lua.record.target == "wasm32-unknown-emscripten")
assert(descriptor.profile_data.integers.long.bits == 32)
assert(descriptor.include_dirs[1] == descriptor.paths.lua_source)
local deps = {}
local loader = driver.defaultloader(deps, { context = context, output_root = context.output_root,
    source_roots = { object_fixture = true } })
local ok, modtype, errors = loader("object_fixture")
assert(ok, modtype); assert(#errors == 0, table.concat(errors, "\n"))
assert(driver.finalize_resolver_context(context))
local entry = driver.imported.object_fixture
local compiled, err = driver.compile_module("object_fixture", entry, deps, false, { context = context })
assert(compiled, err)
assert(driver.close_resolver_context(context))
]], workspace .. "/source", workspace .. "/out")
        local ok, output = run(info, script)
        assert.is_true(ok, output)
        local object, bytes = wasm_object(workspace .. "/out/object_fixture.o")
        assert.equal("object_fixture", object.metadata.module)
        local entry = assert(objectmetadata.read(bytes, "direct browser object"))
        assert.equal("object_fixture", entry.type.name)
    end)

    it("clears ambient EMCC_CFLAGS across browser compiler routes without changing native identity", function()
        local info, why = toolchain.require({ node = true, sdk = true })
        if not info then pending(why) return end
        prepare()
        files.write(workspace .. "/source/ambient.h", "int ambient_helper(void);\n")
        files.write(workspace .. "/source/ambient.c", [[
#include <setjmp.h>
int ambient_helper(void) {
    jmp_buf saved;
    if (setjmp(saved) == 0) longjmp(saved, 7);
    return 7;
}
]])
        files.write(workspace .. "/source/ambient.titan", [[
foreign import "ambient.h"
function main(args: {string}): integer
    local result: integer = ffi.ambient_helper()
    if result ~= 7 then return 1 end
    raise "ambient caught"
catch
    return 0
end
]])
        for index, ambient in ipairs({ "-sWASM_LEGACY_EXCEPTIONS=0", "-sSUPPORT_LONGJMP=emscripten" }) do
            local output = workspace .. "/ambient-out-" .. index
            files.mkdir(output)
            local image = output .. "/ambient.mjs"
            local poisoned = { prefix = info.prefix, output = output, emcc_cflags = ambient }
            local checked = string.format([[
local driver = require "titan-compiler.driver"
local incremental = require "titan-compiler.incremental"
assert(os.getenv("EMCC_CFLAGS") == %q)
local native = driver.new_resolver_context()
local before = assert(driver.toolchain_descriptor(native))
local native_identity = assert(incremental.toolchain_identity(native, before))
assert(driver.close_resolver_context(native))
local browser = driver.new_resolver_context({target="browser", output_root=%q})
local descriptor = assert(driver.context_target_descriptor(browser))
local toolchain = assert(driver.toolchain_descriptor(browser))
assert(#descriptor.tools.cc == 1)
assert(toolchain.compiler_argv[1] == "env" and toolchain.compiler_argv[2] == "EMCC_CFLAGS=")
assert(toolchain.stage_tools[1] == descriptor.tools.cc[1])
local identity, details = incremental.toolchain_identity(browser, toolchain)
assert(identity, details)
local compiler = assert(browser.io:realpath(descriptor.tools.cc[1]))
local found = false
for _, tool in ipairs(details.tools) do if tool.path == compiler then found = true end end
assert(found, "emcc physical identity was lost behind env")
assert(driver.close_resolver_context(browser))
local restored = driver.new_resolver_context()
local after = assert(driver.toolchain_descriptor(restored))
assert(table.concat(before.compiler_argv, "\0") == table.concat(after.compiler_argv, "\0"))
assert(incremental.toolchain_identity(restored, after) == native_identity)
assert(after.stage_tools == nil)
assert(os.getenv("EMCC_CFLAGS") == %q)
local inherited = restored.io:run({"sh", "-c", 'printf "%%s" "$EMCC_CFLAGS"'})
assert(inherited.ok and inherited.output == os.getenv("EMCC_CFLAGS"))
assert(driver.close_resolver_context(restored))
]], ambient, output, ambient)
            local ok, log = run(poisoned, checked)
            assert.is_true(ok, log)
            ok, log = cli(poisoned, "--incremental", "--jobs", "2",
                "--c-source", workspace .. "/source/ambient.c", "--exe", image, "ambient")
            assert.is_true(ok, log)
            local wat = output .. "/ambient.wat"
            local disassembled = compiler_io.new_sync():run({
                paths.join(paths.dirname(info.tools.clang[1]), "wasm-dis"),
                output .. "/ambient.wasm", "-o", wat,
            }, { stderr_to_stdout = true })
            assert.is_true(disassembled.ok, disassembled.output)
            local instructions = read(wat)
            assert.truthy(instructions:match("%(try%s"), "legacy Wasm EH try was not emitted")
            assert.is_nil(instructions:find("(try_table", 1, true), "ambient flags changed the EH encoding")
            assert.is_nil(instructions:match('%(import [^\n]-"invoke_'), "ambient flags restored JS SJLJ")
            local executed = compiler_io.new_sync():run({
                info.sdk_root .. "/titan-browser-run", "--engine", "node", "--root", output, image,
            }, { stderr_to_stdout = true })
            assert.is_true(executed.ok, executed.output)
        end
    end)

    it("compiles real standard stream macro values through emcc", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        files.write(workspace .. "/source/stdio_fixture.titan", [[
foreign import "stdio.h"
function write_stdout(): integer
    return ffi.fwrite("out", 1, 3, ffi.stdout)
end
function write_stderr(): integer
    return ffi.fwrite("err", 1, 3, ffi.stderr)
end
]])
        local ok, output = cli(info, "-c", "stdio_fixture")
        assert.is_true(ok, output)
        local object = wasm_object(workspace .. "/out/stdio_fixture.o")
        assert.equal("stdio_fixture", object.metadata.module)
        local generated = read(workspace .. "/out/stdio_fixture.c")
        for _, name in ipairs({ "fwrite", "stdout", "stderr" }) do
            assert.truthy(generated:find(name, 1, true), name)
        end
    end)

    it("names a real feature-changing cflag instead of blaming the Lua record", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        local ok, output = cli(info, "-c", "--cflag=-msimd128", "object_fixture")
        assert.is_false(ok)
        assert.truthy(output:find("browser target compiler probe", 1, true), output)
        assert.truthy(output:find('"-msimd128"', 1, true), output)
        assert.truthy(output:find("remove feature-changing flags", 1, true), output)
        assert.is_nil(output:find("browser Lua record", 1, true))
        assert.is_nil(output:find("make install-browser", 1, true))
        assert.is_nil(lfs.attributes(workspace .. "/out/object_fixture.c"))
        assert.is_nil(lfs.attributes(workspace .. "/out/object_fixture.o"))
    end)

    it("transports a verified descriptor to build workers and preserves every Lua header origin", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        local ok, output = cli(info, "-c", "--incremental", "--jobs", "2", "object_fixture")
        assert.is_true(ok, output)
        local object, bytes = wasm_object(workspace .. "/out/object_fixture.o")
        assert.equal("object_fixture", object.metadata.module)
        assert(objectmetadata.read(bytes, "worker browser object"))

        -- Recompile untouched generated C with a dependency report: runtime
        -- headers in PREFIX/include must not quote-capture native Lua headers.
        local dependency = workspace .. "/headers.d"
        local command = { table.unpack(info.tools.cc) }
        for _, argument in ipairs(toolchain.with_lua_defines(info,
                { "--std=c99", "-O0", "-sSUPPORT_LONGJMP=wasm", "-sWASM_LEGACY_EXCEPTIONS=1" },
                { "-DTITAN_TARGET_BROWSER=1",
                  "-I", info.prefix .. "/lib/browser/include", "-I", info.prefix .. "/include",
                  "-MD", "-MF", dependency, "-c", workspace .. "/out/object_fixture.c",
                  "-o", workspace .. "/header-check.o" })) do
            command[#command + 1] = argument
        end
        local result = compiler_io.new_sync():run(command, { stderr_to_stdout = true })
        assert.is_true(result.started and result.ok, result.output or result.diagnostic)
        local header_names = {}
        for name in lfs.dir(info.prefix .. "/lib/browser/include") do
            if name:match("[.]h$") then header_names[name] = true end
        end
        local dependencies = assert(depfile.parse(read(dependency)))
        local lua_headers = {}
        for _, filename in ipairs(dependencies) do
            local name = filename:match("([^/]+)$")
            if header_names[name] then
                lua_headers[name] = true
                assert.equal(info.prefix .. "/lib/browser/include/" .. name, filename,
                    "unverified Lua header origin in generated module: " .. filename)
            end
        end
        for _, name in ipairs({ "lua.h", "luaconf.h", "lstate.h", "lobject.h", "ldo.h" }) do
            assert.is_true(lua_headers[name], "generated module did not expose required Lua header " .. name)
        end
        wasm_object(workspace .. "/header-check.o")
    end)

    it("supports authored C-only work with browser Lua and no browser runtime archive", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        files.write(workspace .. "/source/helper.c", [[
#if TITAN_TARGET_BROWSER != 1 || __SIZEOF_POINTER__ != 4
#error incorrect browser compile policy
#endif
int browser_helper(void) { return 42; }
]])
        local ok, output = cli(info, "-c", "--incremental", "--c-source",
            workspace .. "/source/helper.c", "--print-c-objects")
        assert.is_true(ok, output)
        local filename = assert(output:match("([^\r\n]+)[\r\n]*$"), output)
        wasm_object(filename)
        assert.is_nil(lfs.attributes(workspace .. "/out/helper.so"))
    end)

    it("requires owned output even when browser selection came from the environment", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        prepare()
        local selected = { prefix = info.prefix, target = "browser" }
        local ok, output = run(selected, "", repository .. "/titanc",
            "-q", "-c", "--tree", workspace .. "/source", "object_fixture")
        assert.is_false(ok)
        assert.truthy(output:find("--target browser requires --output", 1, true), output)
        assert.is_nil(lfs.attributes(workspace .. "/source/object_fixture.c"))
    end)
end)

-- Capability discovery is exercised in fresh processes: the helper caches a
-- successful compile-only discovery, so one spec process cannot switch the
-- prefix under it. Each child below owns a fake installed tree whose record,
-- launcher and SDK assets stay entirely inside the temporary directory, and a
-- fake Emscripten install whose `emcc` only reports the pinned version. That
-- keeps these cases runnable in the ordinary SDK-only shards instead of
-- pending on a real cross toolchain.
local version = require "titan-compiler.version"
local installed = require "spec.support.installed_prefix"
local baseline_json = require "spec.support.browser_baseline_json"

local validation_prefix = installed.active()
local platform = require "titan-compiler.platform"

local SDK_ASSETS = { "libtitan.a", "titan-browser-library.js", "titan-browser-bridge.js", "titan-browser-trace.js",
    "titan-browser.mjs", "titan-browser-run", "titan-browser-run.mjs",
    "titan-browser-node-worker.mjs", "titan-browser-page.mjs", "titan-browser-module-check.mjs" }
local NODE_OK = { path = "/opt/node26/bin/node", version = "v26.13.0", ok = true }
local CHROME_OK = { path = "/opt/chrome/chrome-headless-shell",
    version = "Google Chrome for Testing 156.0.8078.80", ok = true }

describe("browser toolchain capabilities", function()
    local prefixes

    -- These cases drive POSIX fixture executables; the helper itself rejects a
    -- Windows host before any capability work, so the same host fact is the
    -- honest pending reason there.
    local function posix_only()
        if platform.windows then
            pending("browser builds are supported from Linux and macOS hosts")
            return true
        end
        return false
    end

    after_each(function()
        for _, root in ipairs(prefixes or {}) do files.remove(root) end
        prefixes = nil
    end)

    -- lfs in this toolchain has no chmod; these fixtures are POSIX shell
    -- scripts and the cases pend on Windows before reaching them.
    local function make_executable(filename)
        local quoted = "'" .. filename:gsub("'", "'\\''") .. "'"
        local ok, how, status = os.execute("chmod 755 " .. quoted)
        assert(ok == true, "chmod failed: " .. tostring(how or status))
    end

    local function fixture_prefix()
        local root = temporary.name()
        assert(os.remove(root))
        files.mkdir(root)
        for _, relative in ipairs({ "lib/browser/liblua.a",
                "lib/browser/liblua-config.txt", "lib/browser/include/lua.h",
                "lib/browser/include/luaconf.h", "lib/browser/include/lstate.h" }) do
            files.write(root .. "/" .. relative, "")
        end
        local em = root .. "/emsdk/upstream/emscripten"
        files.write(em .. "/emcc", "#!/bin/sh\n" ..
            "echo 'emcc (Emscripten gcc/clang-like replacement) 6.0.13'\n")
        make_executable(em .. "/emcc")
        for _, name in ipairs({ "emar", "emranlib" }) do
            files.write(em .. "/" .. name, "#!/bin/sh\nexit 0\n")
            make_executable(em .. "/" .. name)
        end
        files.write(root .. "/emsdk/upstream/bin/clang", "#!/bin/sh\nexit 0\n")
        make_executable(root .. "/emsdk/upstream/bin/clang")
        prefixes = prefixes or {}
        prefixes[#prefixes + 1] = root
        return root
    end

    local function sdk_directory(root)
        return root .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION
    end

    local function probe_json(node, chrome)
        -- JSON escapes, not Lua %q: a diagnostic may contain newlines, and a
        -- raw newline inside a JSON string would be corruption.
        local function text(value)
            return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
                if char == '"' then return '\\"' end
                if char == "\\" then return "\\\\" end
                if char == "\n" then return "\\n" end
                if char == "\r" then return "\\r" end
                if char == "\t" then return "\\t" end
                return string.format("\\u%04x", char:byte())
            end) .. '"'
        end
        local function record(values)
            local function value(item)
                return type(item) == "string" and text(item) or "null"
            end
            return string.format('{"path":%s,"version":%s,"ok":%s,"reason":%s}',
                value(values.path), value(values.version),
                values.ok and "true" or "false", value(values.reason))
        end
        return '{"node":' .. record(node) .. ',"chrome":' .. record(chrome) .. "}\n"
    end

    local function install_probe(root, node, chrome, counter)
        local directory = sdk_directory(root)
        files.write(directory .. "/probe.json", probe_json(node, chrome))
        local script = "#!/bin/sh\n"
        if counter then
            script = script .. "echo probe >> '" .. counter .. "'\n"
        end
        script = script .. 'cat "$(dirname "$0")/probe.json"\n'
        files.write(directory .. "/titan-browser-run", script)
        make_executable(directory .. "/titan-browser-run")
        return directory
    end

    local function install_sdk(root)
        local directory = sdk_directory(root)
        for _, name in ipairs(SDK_ASSETS) do
            files.write(directory .. "/" .. name, "")
        end
        return directory
    end

    -- The child keeps the validation prefix for its Lua interpreter and
    -- TITAN_ROOT, and points EMSDK/PREFIX at the fixture tree.
    local function helper_child(environment, code)
        local argv = { "env", "TITAN_ROOT=" .. validation_prefix,
            "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_REQUIRE_BROWSER_TOOLCHAIN=" ..
                (environment.strict and "1" or "") }
        for key, value in pairs(environment) do
            if key ~= "strict" then argv[#argv + 1] = key .. "=" .. value end
        end
        argv[#argv + 1] = validation_prefix .. "/bin/lua"
        argv[#argv + 1] = "-E"
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = string.format(
            "package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. code
        local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
        return result.started and result.ok, result.output or result.diagnostic or ""
    end

    local function fixture_environment(root, strict)
        return { strict = strict, PREFIX = root, ROCKS_TREE = "",
            EMSDK = root .. "/emsdk" }
    end

    it("reports Node and Chrome from the installed runner probe without changing the compile-only result", function()
        if posix_only() then return end
        local root = fixture_prefix()
        install_probe(root, NODE_OK, CHROME_OK)
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local base = assert(toolchain.detect())
assert(base.prefix == os.getenv("PREFIX"), "compile-only detection used the wrong prefix")
assert(base.node == nil and base.chrome == nil and base.sdk_root == nil,
    "compile-only detection must not expose capabilities")
assert(type(base.tools.cc[1]) == "string" and type(base.record_path) == "string")
local info = assert(toolchain.detect({ node = true, chrome = true }))
assert(info.prefix == base.prefix and info.record_path == base.record_path,
    "extended detection changed the compile-only fields")
assert(info.node.path == "/opt/node26/bin/node", tostring(info.node.path))
assert(info.node.version == "v26.13.0", tostring(info.node.version))
assert(info.chrome.path == "/opt/chrome/chrome-headless-shell", tostring(info.chrome.path))
assert(info.chrome.version == "Google Chrome for Testing 156.0.8078.80",
    tostring(info.chrome.version))
assert(info.sdk_root == nil, "the SDK was not requested")
print("capabilities-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("capabilities%-ok"), output)
    end)

    it("pends on an unavailable capability, raises it under the strict variable, and retries after it appears", function()
        if posix_only() then return end
        local root = fixture_prefix()
        install_probe(root, { path = "/usr/bin/node", version = "v22.23.4",
            ok = false, reason = "\"/usr/bin/node\" reports v22.23.4; expected Node 26 or newer" },
            CHROME_OK)
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason, malformed = toolchain.detect({ node = true })
assert(found == nil, "an unusable Node must not be a capability")
assert(malformed == nil, "an explained refusal is an absence, not corruption")
assert(reason:find("expected Node 26 or newer", 1, true), tostring(reason))
local pending_info, pending_reason = toolchain.require({ node = true })
assert(pending_info == nil, "non-strict require must pend")
assert(pending_reason:match("^browser toolchain unavailable: "), tostring(pending_reason))
print("pend-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("pend%-ok"), output)

        local strict_ok, strict_output = helper_child(fixture_environment(root, true), [[
local toolchain = require "spec.support.browser_toolchain"
toolchain.require({ node = true })
print("unreachable-strict")
]])
        assert.is_false(strict_ok)
        assert.is_nil(strict_output:find("unreachable%-strict"))
        assert.truthy(strict_output:find("browser toolchain unavailable", 1, true),
            strict_output)

        -- The absence is not cached: the same process sees the fixed probe.
        local retry_ok, retry_output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local missing = toolchain.detect({ node = true })
assert(missing == nil, "the refusal must be reported first")
local path = os.getenv("PREFIX") .. "/lib/titan-browser/]] ..
            version.TITAN_LIBRARY_VERSION .. [[/titan-browser-run"
local file = assert(io.open(path, "wb"))
assert(file:write('#!/bin/sh\ncat "$(dirname "$0")/probe.json"\n')); assert(file:close())
assert(os.execute("chmod 755 '" .. path .. "'"))
local probe = assert(io.open(os.getenv("PREFIX") .. "/lib/titan-browser/]] ..
            version.TITAN_LIBRARY_VERSION .. [[/probe.json", "wb"))
assert(probe:write('{"node":{"path":"/opt/node26/bin/node","version":"v26.13.0",' ..
    '"ok":true,"reason":null},"chrome":{"path":null,"version":null,' ..
    '"ok":false,"reason":"chromium missing"}}\n'))
assert(probe:close())
local found = assert(toolchain.detect({ node = true }))
assert(found.node.version == "v26.13.0", tostring(found.node.version))
print("retry-ok")
]])
        assert.is_true(retry_ok, retry_output)
        assert.truthy(retry_output:find("retry%-ok"), retry_output)
    end)

    it("accepts a multi-line escaped failure reason as a normal absence", function()
        if posix_only() then return end
        local root = fixture_prefix()
        install_probe(root, { path = "/usr/bin/node", version = nil, ok = false,
            reason = "first line of the diagnostic\nsecond line: expected Node 26 or newer" },
            CHROME_OK)
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason, malformed = toolchain.detect({ node = true })
assert(found == nil, "a refusal is not a capability")
assert(malformed == nil, "escaped text is not corruption")
assert(reason == "first line of the diagnostic\nsecond line: expected Node 26 or newer",
    string.format("%q", tostring(reason)))
print("escaped-reason-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("escaped%-reason%-ok"), output)
    end)

    it("treats a malformed probe record as corruption instead of an absence or a success", function()
        if posix_only() then return end
        local root = fixture_prefix()
        install_probe(root, NODE_OK, CHROME_OK)
        local directory = sdk_directory(root)
        local cases = {
            { name = "success without a path",
                node = '{"path":null,"version":"v26.13.0","ok":true,"reason":null}',
                requested = "node" },
            { name = "success with an empty version",
                node = '{"path":"/opt/node","version":"","ok":true,"reason":null}',
                requested = "node" },
            { name = "success with a reason",
                node = '{"path":"/opt/node","version":"v26.13.0","ok":true,"reason":"why"}',
                requested = "node" },
            { name = "failure without a reason",
                node = '{"path":null,"version":null,"ok":false,"reason":null}',
                requested = "node" },
            { name = "failure with an empty reason",
                node = '{"path":null,"version":null,"ok":false,"reason":""}',
                requested = "node" },
            { name = "unrequested peer is corrupt",
                node = '{"path":"/opt/node","version":"v26.13.0","ok":true,"reason":null}',
                chrome = '{"path":"/opt/chrome","version":null,"ok":true,"reason":null}',
                requested = "node" },
            { name = "raw control byte in a string",
                node = '{"path":"/opt/\1node","version":"v26.13.0","ok":true,"reason":null}',
                requested = "node" },
        }
        for _, case in ipairs(cases) do
            local chrome = case.chrome or
                '{"path":null,"version":null,"ok":false,"reason":"chromium missing"}'
            files.write(directory .. "/probe.json",
                '{"node":' .. case.node .. ',"chrome":' .. chrome .. "}\n")
            local ok, output = helper_child(fixture_environment(root),
                string.format([[
local toolchain = require "spec.support.browser_toolchain"
local found, reason, malformed = toolchain.detect({ %s = true })
assert(found == nil, "a malformed record must not be a capability")
assert(malformed == true, "a malformed record must be reported as corruption")
assert(reason:find("malformed browser runner probe result", 1, true), tostring(reason))
local called, failure = pcall(function() toolchain.require({ %s = true }) end)
assert(not called, "a malformed probe result must raise without the strict variable")
assert(tostring(failure):find("malformed browser runner probe result", 1, true),
    tostring(failure))
print("malformed-ok")
]], case.requested, case.requested))
            assert.is_true(ok, case.name .. ": " .. output)
            assert.truthy(output:find("malformed%-ok"), case.name .. ": " .. output)
        end

        -- Nothing corrupt is cached: the same process repairs the probe and
        -- reads it normally on the very next call.
        files.write(directory .. "/probe.json",
            '{"node":' .. cases[#cases].node .. ',"chrome":' ..
            '{"path":null,"version":null,"ok":false,"reason":"chromium missing"}}\n')
        local repaired_ok, repaired_output = helper_child(
            { strict = false, PREFIX = root, ROCKS_TREE = "", EMSDK = root .. "/emsdk",
                PROBE_JSON = probe_json(NODE_OK, CHROME_OK) }, [[
local toolchain = require "spec.support.browser_toolchain"
local corrupt, _, malformed = toolchain.detect({ node = true })
assert(corrupt == nil and malformed == true, "the corrupt probe must fail first")
local file = assert(io.open(os.getenv("PREFIX") .. "/lib/titan-browser/]] ..
            version.TITAN_LIBRARY_VERSION .. [[/probe.json", "wb"))
assert(file:write(os.getenv("PROBE_JSON"))); assert(file:close())
local info = assert(toolchain.detect({ node = true }))
assert(info.node.version == "v26.13.0", tostring(info.node.version))
print("repaired-ok")
]])
        assert.is_true(repaired_ok, repaired_output)
        assert.truthy(repaired_output:find("repaired%-ok"), repaired_output)
    end)

    it("reports a probe that cannot start Node as an unavailable capability", function()
        if posix_only() then return end
        local root = fixture_prefix()
        files.write(sdk_directory(root) .. "/titan-browser-run",
            "#!/bin/sh\n" ..
            "echo 'titan-browser-run: Node 26 or newer is required (node not found)' >&2\n" ..
            "exit 75\n")
        make_executable(sdk_directory(root) .. "/titan-browser-run")
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason = toolchain.require({ node = true })
assert(found == nil, "a failed probe must not be a capability")
assert(reason:find("Node 26 or newer is required", 1, true), tostring(reason))
print("probe-failure-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("probe%-failure%-ok"), output)
    end)

    it("distinguishes an absent browser SDK from a present but incomplete one", function()
        if posix_only() then return end
        local root = fixture_prefix()
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason, malformed = toolchain.detect({ sdk = true })
assert(found == nil, "an absent SDK must not be a capability")
assert(malformed == false, "an absent SDK is a pendable capability, not a failure")
assert(reason:find("browser SDK is incomplete: missing", 1, true), tostring(reason))
assert(reason:find("make browser-sdk PREFIX=" .. os.getenv("PREFIX"), 1, true),
    "the diagnostic must name the command: " .. tostring(reason))
print("sdk-absent-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("sdk%-absent%-ok"), output)

        files.write(sdk_directory(root) .. "/libtitan.a", "")
        local broken_ok, broken_output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local called, failure = pcall(toolchain.require, { sdk = true })
assert(not called, "an incomplete installed SDK must fail, not pend")
assert(tostring(failure):find("browser SDK is incomplete: missing", 1, true),
    tostring(failure))
print("sdk-incomplete-ok")
]])
        assert.is_true(broken_ok, broken_output)
        assert.truthy(broken_output:find("sdk%-incomplete%-ok"), broken_output)

        local directory = install_sdk(root)
        local complete_ok, complete_output = helper_child(
            { strict = false, PREFIX = root, ROCKS_TREE = "", EMSDK = root .. "/emsdk",
                SDK_ROOT = directory }, [[
local toolchain = require "spec.support.browser_toolchain"
local found = assert(toolchain.detect({ sdk = true }))
assert(found.sdk_root == os.getenv("SDK_ROOT"), tostring(found.sdk_root))
assert(found.node == nil and found.chrome == nil, "unrequested capabilities must stay absent")
print("sdk-complete-ok")
]])
        assert.is_true(complete_ok, complete_output)
        assert.truthy(complete_output:find("sdk%-complete%-ok"), complete_output)
    end)

    it("resolves the browser SDK under an explicit ROCKS_TREE", function()
        if posix_only() then return end
        local root = fixture_prefix()
        local rocks = temporary.name()
        assert(os.remove(rocks))
        files.mkdir(rocks)
        prefixes[#prefixes + 1] = rocks
        local directory = install_sdk(rocks)
        local ok, output = helper_child(
            { strict = false, PREFIX = root, ROCKS_TREE = rocks,
                EMSDK = root .. "/emsdk", SDK_ROOT = directory }, [[
local toolchain = require "spec.support.browser_toolchain"
local found = assert(toolchain.detect({ sdk = true }))
assert(found.sdk_root == os.getenv("SDK_ROOT"), tostring(found.sdk_root))
assert(found.sdk_root:find(os.getenv("ROCKS_TREE"), 1, true),
    "the SDK must live in the install tree: " .. tostring(found.sdk_root))
print("rocks-tree-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("rocks%-tree%-ok"), output)
    end)

    it("rechecks an absent SDK instead of caching the absence", function()
        if posix_only() then return end
        local root = fixture_prefix()
        files.mkdir(root .. "/lib/titan-browser")
        local ok, output = helper_child(
            { strict = false, PREFIX = root, ROCKS_TREE = "", EMSDK = root .. "/emsdk",
                SDK_DIRECTORY = sdk_directory(root) }, [[
local toolchain = require "spec.support.browser_toolchain"
local missing, reason = toolchain.detect({ sdk = true })
assert(missing == nil and reason:find("browser SDK is incomplete", 1, true),
    tostring(reason))
local directory = os.getenv("SDK_DIRECTORY")
local lfs = require "lfs"
assert(lfs.mkdir(directory))
for _, name in ipairs({ "libtitan.a", "titan-browser-library.js", "titan-browser-bridge.js", "titan-browser-trace.js",
        "titan-browser.mjs", "titan-browser-run", "titan-browser-run.mjs",
        "titan-browser-node-worker.mjs", "titan-browser-page.mjs", "titan-browser-module-check.mjs" }) do
    local file = assert(io.open(directory .. "/" .. name, "wb"))
    assert(file:write("")); assert(file:close())
end
local found = assert(toolchain.detect({ sdk = true }))
assert(found.sdk_root == directory, tostring(found.sdk_root))
print("sdk-retry-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("sdk%-retry%-ok"), output)
    end)

    it("caches successful capabilities separately and re-probes a missing peer", function()
        if posix_only() then return end
        local root = fixture_prefix()
        local counter = root .. "/probe-count"
        install_probe(root, NODE_OK,
            { path = nil, version = nil, ok = false, reason = "chromium missing" }, counter)
        local ok, output = helper_child(
            { strict = false, PREFIX = root, ROCKS_TREE = "", EMSDK = root .. "/emsdk",
                COUNTER = counter }, [[
local toolchain = require "spec.support.browser_toolchain"
local function probes()
    local file = io.open(os.getenv("COUNTER"), "rb")
    if not file then return 0 end
    local text = assert(file:read("a")); assert(file:close())
    local count = 0
    for _ in text:gmatch("probe") do count = count + 1 end
    return count
end
local node = assert(toolchain.detect({ node = true }))
assert(node.node.version == "v26.13.0", tostring(node.node.version))
assert(probes() == 1, "the first query probes once: " .. probes())
local missing, reason = toolchain.detect({ chrome = true })
assert(missing == nil and reason == "chromium missing", tostring(reason))
assert(probes() == 2, "an unavailable peer is probed again: " .. probes())
-- The node success stays cached while chrome is repaired and re-read.
local directory = os.getenv("PREFIX") .. "/lib/titan-browser/]] ..
            version.TITAN_LIBRARY_VERSION .. [["
local probe = assert(io.open(directory .. "/probe.json", "wb"))
assert(probe:write('{"node":{"path":"/opt/node26/bin/node","version":"v26.13.0",' ..
    '"ok":true,"reason":null},"chrome":{"path":"/opt/chrome/chrome-headless-shell",' ..
    '"version":"Google Chrome for Testing 156.0.8078.80","ok":true,"reason":null}}\n'))
assert(probe:close())
local chrome = assert(toolchain.detect({ chrome = true }))
assert(chrome.chrome.version == "Google Chrome for Testing 156.0.8078.80")
assert(probes() == 3, "a repaired peer is probed once: " .. probes())
toolchain.detect({ node = true })
assert(probes() == 3, "cached capabilities never probe again: " .. probes())
print("cache-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("cache%-ok"), output)
    end)

    it("accepts empty requirements and rejects malformed requirement tables", function()
        if posix_only() then return end
        local root = fixture_prefix()
        install_probe(root, NODE_OK, CHROME_OK)
        local ok, output = helper_child(fixture_environment(root), [[
local toolchain = require "spec.support.browser_toolchain"
local base = assert(toolchain.detect())
local empty = assert(toolchain.detect({}))
assert(empty.prefix == base.prefix and empty.tools.cc[1] == base.tools.cc[1])
assert(empty.node == nil and empty.chrome == nil and empty.sdk_root == nil)
print("empty-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("empty%-ok"), output)

        for _, literal in ipairs({ "true", '{ node = "yes" }', '{ nope = true }' }) do
            local code = [[
local toolchain = require "spec.support.browser_toolchain"
local called = pcall(toolchain.detect, REQUIREMENT)
assert(not called, "invalid requirements must raise before detection")
local called_require = pcall(toolchain.require, REQUIREMENT)
assert(not called_require, "invalid requirements must raise through require too")
print("invalid-ok")
]]
            local invalid_ok, invalid_output = helper_child(fixture_environment(root),
                (code:gsub("REQUIREMENT", literal)))
            assert.is_true(invalid_ok, literal .. ": " .. invalid_output)
            assert.truthy(invalid_output:find("invalid%-ok"), literal .. ": " .. invalid_output)
        end
    end)

    it("falls back to the source runner before the SDK exists", function()
        if posix_only() then return end
        local info, why = toolchain.require({ node = true })
        if not info then pending(why) return end
        local root = fixture_prefix()
        local ok, output = helper_child({ strict = false, PREFIX = root,
            ROCKS_TREE = "", EMSDK = root .. "/emsdk",
            TITAN_NODE = os.getenv("TITAN_NODE") or "" }, [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason = toolchain.detect({ node = true })
assert(found, tostring(reason))
assert(tonumber(found.node.version:match("^v(%d+)[.]")) >= 26, tostring(found.node.version))
print("source-fallback-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("source%-fallback%-ok"), output)
    end)

    it("preserves ordered arrays and computes medians for asymmetric samples", function()
        local encoded = baseline_json.encode({
            "n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8", "n9", "n10", "n11", "n12" })
        local previous = 0
        for index = 1, 12 do
            local position = assert(encoded:find('"n' .. index .. '"', 1, true),
                "missing array element " .. index .. " in " .. encoded)
            assert.is_true(position > previous,
                "array element " .. index .. " was reordered")
            previous = position
        end
        -- Paired CLI arguments keep adjacency and order.
        local flags = baseline_json.encode({ "-sEXIT_RUNTIME=0", "--js-library", "path" })
        local first = assert(flags:find('"-sEXIT_RUNTIME=0"', 1, true), flags)
        local second = assert(flags:find('"--js-library"', 1, true), flags)
        local third = assert(flags:find('"path"', 1, true), flags)
        assert.is_true(first < second and second < third,
            "paired arguments were reordered: " .. flags)
        assert.truthy(baseline_json.encode({ b = 1, a = 2 }):find('"a": 2', 1, true))
        assert.is_equal(2, baseline_json.median({ 3, 1, 2 }))
        assert.is_equal(2.5, baseline_json.median({ 4, 1, 3, 2 }))
        assert.is_nil(baseline_json.median({}))
        assert.is_equal(2, baseline_json.median({ 3, 1, 2, "ignored" }))
    end)

    it("restores executable modes from a pinned ZIP", function()
        if posix_only() then return end
        local python = compiler_io.new_sync():run({ "python3", "--version" })
        if not python or not python.started or not python.ok then
            pending("python3 is required for the archive fixture")
            return
        end
        local root = temporary.name()
        assert(os.remove(root))
        files.mkdir(root)
        prefixes = prefixes or {}
        prefixes[#prefixes + 1] = root
        local archive = root .. "/artifact.zip"
        local builder = root .. "/build.py"
        files.write(builder, [[
import zipfile
archive = zipfile.ZipFile(sys.argv[1], "w")
info = zipfile.ZipInfo("chrome-headless-shell-linux64/chrome-headless-shell")
info.external_attr = (0o755 << 16)
archive.writestr(info, "#!/bin/sh\nexit 0\n")
readme = zipfile.ZipInfo("chrome-headless-shell-linux64/README")
readme.external_attr = (0o644 << 16)
archive.writestr(readme, "readme\n")
archive.close()
]])
        assert.is_true(compiler_io.new_sync():run({ "python3", "-c",
            "import sys; sys.argv = ['build', " .. string.format("%q", archive) .. "]; " ..
            "exec(open(" .. string.format("%q", builder) .. ").read())" }).ok)
        local destination = root .. "/extracted"
        local result = compiler_io.new_sync():run({ "python3",
            repository .. "/scripts/browser_extract_zip.py", archive, destination })
        assert.is_true(result.started and result.ok, result.output or result.diagnostic)
        local binary = destination .. "/chrome-headless-shell-linux64/chrome-headless-shell"
        local executable = compiler_io.new_sync():run({ "test", "-x", binary })
        assert.is_true(executable.ok, "the extracted shell must be executable")
    end)
end)

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
        "--target", "browser", "-q", "--tree", workspace .. "/source", "--output", workspace .. "/out", ...)
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
        local ok, output = cli(info, "-c", "--cflag=-O1", "--cflag=-msimd128", "object_fixture")
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
        for _, argument in ipairs({ "--std=c99", "-O0", "-sSUPPORT_LONGJMP=emscripten",
                "-DLUA_USE_BROWSER", "-DLUA_USE_POSIX", "-DTITAN_TARGET_BROWSER=1",
                "-I", info.prefix .. "/lib/browser/include", "-I", info.prefix .. "/include",
                "-MD", "-MF", dependency, "-c", workspace .. "/out/object_fixture.c",
                "-o", workspace .. "/header-check.o" }) do command[#command + 1] = argument end
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
-- launcher and SDK assets stay entirely inside the temporary directory.
local version = require "titan-compiler.version"

local SDK_ASSETS = { "libtitan.a", "titan-browser-library.js", "titan-browser.mjs",
    "titan-browser-run", "titan-browser-run.mjs", "titan-browser-node-worker.mjs",
    "titan-browser-page.mjs" }
local NODE_OK = { path = "/opt/node24/bin/node", version = "v24.19.0", ok = true }
local CHROME_OK = { path = "/opt/chrome/chrome-headless-shell",
    version = "Google Chrome for Testing 156.0.8078.80", ok = true }
local CHROME_ABSENT = { ok = false,
    reason = "titan-browser-run: headless Chromium not found; " ..
        "set TITAN_CHROME to a Chrome executable" }

describe("browser toolchain capabilities", function()
    local prefixes

    after_each(function()
        for _, root in ipairs(prefixes or {}) do files.remove(root) end
        prefixes = nil
    end)

    local function fixture_prefix()
        local root = temporary.name()
        assert(os.remove(root))
        for _, relative in ipairs({ "lib/browser/liblua.a",
                "lib/browser/liblua-config.txt", "lib/browser/include/lua.h",
                "lib/browser/include/luaconf.h", "lib/browser/include/lstate.h" }) do
            files.write(root .. "/" .. relative, "")
        end
        prefixes = prefixes or {}
        prefixes[#prefixes + 1] = root
        return root
    end

    local function sdk_directory(prefix)
        return prefix .. "/lib/titan-browser/" .. version.TITAN_LIBRARY_VERSION
    end

    local function probe_json(node, chrome)
        local function record(values)
            local function value(text)
                return type(text) == "string" and string.format("%q", text) or "null"
            end
            return string.format('{"path":%s,"version":%s,"ok":%s,"reason":%s}',
                value(values.path), value(values.version),
                values.ok and "true" or "false", value(values.reason))
        end
        return '{"node":' .. record(node) .. ',"chrome":' .. record(chrome) .. "}\n"
    end

    -- lfs in this toolchain has no chmod; the fixture probes are POSIX shell
    -- scripts and these cases pend on Windows before reaching them.
    local function make_executable(filename)
        local quoted = "'" .. filename:gsub("'", "'\\''") .. "'"
        local ok, how, status = os.execute("chmod 755 " .. quoted)
        assert(ok == true, "chmod failed: " .. tostring(how or status))
    end

    local function install_probe(prefix, node, chrome)
        local directory = sdk_directory(prefix)
        files.write(directory .. "/probe.json", probe_json(node, chrome))
        files.write(directory .. "/titan-browser-run",
            '#!/bin/sh\ncat "$(dirname "$0")/probe.json"\n')
        make_executable(directory .. "/titan-browser-run")
        return directory
    end

    local function install_sdk(prefix)
        local directory = sdk_directory(prefix)
        for _, name in ipairs(SDK_ASSETS) do
            files.write(directory .. "/" .. name, "")
        end
        return directory
    end

    local function helper_child(info, prefix, strict, environment, code)
        local argv = { "env", "TITAN_ROOT=" .. info.prefix, "PREFIX=" .. prefix,
            "ROCKS_TREE=", "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
            "TITAN_REQUIRE_BROWSER_TOOLCHAIN=" .. (strict and "1" or "") }
        for key, value in pairs(environment or {}) do
            argv[#argv + 1] = key .. "=" .. value
        end
        argv[#argv + 1] = info.prefix .. "/bin/lua"
        argv[#argv + 1] = "-E"
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = string.format(
            "package.path=%q..package.path;",
            repository .. "/?.lua;" .. repository .. "/?/init.lua;") .. code
        local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
        return result.started and result.ok, result.output or result.diagnostic or ""
    end

    it("reports Node and Chrome from the installed runner probe without changing the compile-only result", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        install_probe(prefix, NODE_OK, CHROME_OK)
        local ok, output = helper_child(info, prefix, false, nil, [[
local toolchain = require "spec.support.browser_toolchain"
local base = assert(toolchain.detect())
assert(base.prefix == os.getenv("PREFIX"), "compile-only detection used the wrong prefix")
assert(base.node == nil and base.chrome == nil and base.sdk_root == nil,
    "compile-only detection must not expose capabilities")
assert(type(base.tools.cc[1]) == "string" and type(base.record_path) == "string")
local info = assert(toolchain.detect({ node = true, chrome = true }))
assert(info.prefix == base.prefix and info.record_path == base.record_path,
    "extended detection changed the compile-only fields")
assert(info.node.path == "/opt/node24/bin/node", tostring(info.node.path))
assert(info.node.version == "v24.19.0", tostring(info.node.version))
assert(info.chrome.path == "/opt/chrome/chrome-headless-shell", tostring(info.chrome.path))
assert(info.chrome.version == "Google Chrome for Testing 156.0.8078.80",
    tostring(info.chrome.version))
assert(info.sdk_root == nil, "the SDK was not requested")
print("capabilities-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("capabilities%-ok"), output)
    end)

    it("pends on an unavailable capability and raises it under the strict variable", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        install_probe(prefix, { path = "/usr/bin/node", version = "v22.23.4",
            ok = false, reason = "\"/usr/bin/node\" reports v22.23.4; expected Node 24" },
            CHROME_OK)
        local ok, output = helper_child(info, prefix, false, nil, [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason = toolchain.require({ node = true })
assert(found == nil, "an unusable Node must not be a capability")
assert(reason:match("^browser toolchain unavailable: "), tostring(reason))
assert(reason:find("expected Node 24", 1, true), tostring(reason))
print("pend-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("pend%-ok"), output)

        local strict_ok, strict_output = helper_child(info, prefix, true, nil, [[
local toolchain = require "spec.support.browser_toolchain"
toolchain.require({ node = true })
print("unreachable-strict")
]])
        assert.is_false(strict_ok)
        assert.is_nil(strict_output:find("unreachable%-strict"))
        assert.truthy(strict_output:find("browser toolchain unavailable", 1, true),
            strict_output)
    end)

    it("fails a present but malformed probe result instead of skipping it", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        local directory = install_probe(prefix, NODE_OK, CHROME_OK)
        local shapes = {
            '{"node":{"path":"/n","version":"v24.19.0","ok":true,"reason":null},"chrome":{}}\n',
            '{"node":{"path":"/n","version":"v24.19.0","ok":true,"reason":null},' ..
                '"chrome":{"path":null,"version":null,"ok":false,"reason":null},"extra":1}\n',
            '{"node":{"path":"/n","version":"v24.19.0","ok":"yes","reason":null},' ..
                '"chrome":{"path":null,"version":null,"ok":false,"reason":null}}\n',
            '{"node":{"path":"/n","version":"v24.19.0","ok":true,"reason":null},' ..
                '"chrome":{"path":null,"version":null,"ok":false,"reason":null}}',
            '{"node":{"path":"/n","version":"v24.19.0","ok":true,"reason":null},' ..
                '"chrome":{"path":null,"version":null,"ok":false,"reason":null}}\n\n',
        }
        for index, bytes in ipairs(shapes) do
            files.write(directory .. "/probe.json", bytes)
            local ok, output = helper_child(info, prefix, false, nil, [[
local toolchain = require "spec.support.browser_toolchain"
local called, failure = pcall(toolchain.require, { node = true })
assert(not called, "a malformed probe result must not pend")
assert(tostring(failure):find("malformed browser runner probe result", 1, true),
    tostring(failure))
print("malformed-ok")
]])
            assert.is_true(ok, "shape " .. index .. ": " .. output)
            assert.truthy(output:find("malformed%-ok"), "shape " .. index .. ": " .. output)
        end
    end)

    it("reports a probe that cannot start Node as an unavailable capability", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        files.write(sdk_directory(prefix) .. "/titan-browser-run",
            '#!/bin/sh\n' ..
            'echo "titan-browser-run: Node 24 is required (node not found)" >&2\n' ..
            'exit 75\n')
        make_executable(sdk_directory(prefix) .. "/titan-browser-run")
        local ok, output = helper_child(info, prefix, false, nil, [[
local toolchain = require "spec.support.browser_toolchain"
local found, reason = toolchain.require({ node = true })
assert(found == nil, "a failed probe must not be a capability")
assert(reason:find("Node 24 is required", 1, true), tostring(reason))
print("probe-failure-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("probe%-failure%-ok"), output)
    end)

    it("distinguishes an absent browser SDK from a present but incomplete one", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        local ok, output = helper_child(info, prefix, false, nil, [[
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

        files.write(sdk_directory(prefix) .. "/libtitan.a", "")
        local broken_ok, broken_output = helper_child(info, prefix, false, nil, [[
local toolchain = require "spec.support.browser_toolchain"
local called, failure = pcall(toolchain.require, { sdk = true })
assert(not called, "an incomplete installed SDK must fail, not pend")
assert(tostring(failure):find("browser SDK is incomplete: missing", 1, true),
    tostring(failure))
print("sdk-incomplete-ok")
]])
        assert.is_true(broken_ok, broken_output)
        assert.truthy(broken_output:find("sdk%-incomplete%-ok"), broken_output)

        local directory = install_sdk(prefix)
        local complete_ok, complete_output = helper_child(info, prefix, false,
            { SDK_ROOT = directory }, [[
local toolchain = require "spec.support.browser_toolchain"
local found = assert(toolchain.detect({ sdk = true }))
assert(found.sdk_root == os.getenv("SDK_ROOT"), tostring(found.sdk_root))
assert(found.node == nil and found.chrome == nil, "unrequested capabilities must stay absent")
print("sdk-complete-ok")
]])
        assert.is_true(complete_ok, complete_output)
        assert.truthy(complete_output:find("sdk%-complete%-ok"), complete_output)
    end)

    it("caches a successful capability after the probe environment changes", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        local directory = install_probe(prefix, NODE_OK, CHROME_OK)
        local ok, output = helper_child(info, prefix, false,
            { PROBE = directory .. "/probe.json" }, [[
local toolchain = require "spec.support.browser_toolchain"
local first = assert(toolchain.detect({ node = true }))
assert(first.node.version == "v24.19.0", tostring(first.node.version))
local file = assert(io.open(os.getenv("PROBE"), "wb"))
assert(file:write('{"node":{"path":"/opt/node24/bin/node","version":"v24.99.0",' ..
    '"ok":true,"reason":null},"chrome":{"path":null,"version":null,' ..
    '"ok":false,"reason":null}}\n'))
assert(file:close())
local second = assert(toolchain.detect({ node = true }))
assert(second.node.version == "v24.19.0", "a successful capability must be cached")
print("cache-ok")
]])
        assert.is_true(ok, output)
        assert.truthy(output:find("cache%-ok"), output)
    end)

    it("rechecks an absent SDK instead of caching the absence", function()
        local info, why = toolchain.require(); if not info then pending(why) return end
        local prefix = fixture_prefix()
        files.mkdir(prefix .. "/lib/titan-browser")
        local ok, output = helper_child(info, prefix, false,
            { SDK_DIRECTORY = sdk_directory(prefix) }, [[
local toolchain = require "spec.support.browser_toolchain"
local missing, reason = toolchain.detect({ sdk = true })
assert(missing == nil and reason:find("browser SDK is incomplete", 1, true),
    tostring(reason))
local directory = os.getenv("SDK_DIRECTORY")
local lfs = require "lfs"
assert(lfs.mkdir(directory))
for _, name in ipairs({ "libtitan.a", "titan-browser-library.js", "titan-browser.mjs",
        "titan-browser-run", "titan-browser-run.mjs",
        "titan-browser-node-worker.mjs", "titan-browser-page.mjs" }) do
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

    it("rejects unknown and non-boolean requirements before detecting anything", function()
        local ok, message = pcall(toolchain.require, { nope = true })
        assert.is_false(ok)
        assert.truthy(tostring(message):find(
            'unknown browser toolchain requirement "nope"', 1, true), tostring(message))
        ok, message = pcall(toolchain.detect, { node = "yes" })
        assert.is_false(ok)
        assert.truthy(tostring(message):find("must be true", 1, true), tostring(message))
    end)
end)

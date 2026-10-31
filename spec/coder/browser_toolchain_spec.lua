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

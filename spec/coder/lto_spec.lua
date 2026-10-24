local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local coder_names = require "titan-compiler.coder.names"
local lfs = require "lfs"
local objectmetadata = require "titan-compiler.objectmetadata"
local platform = require "titan-compiler.platform"
local staticmetadata = require "titan-compiler.staticmetadata"

local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
local REPOSITORY = assert(lfs.currentdir())
if platform.windows then REPOSITORY = assert(platform.path.normalize(REPOSITORY)) end
local CC = os.getenv("CC") or "cc"
local SENTINEL = "titan_lto_unresolved_without_optimization"

local function run(arguments)
    local result = compiler_io.new_sync():run(arguments)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.ok, output, result.why, result.status
end

local LINUX = false
if not platform.windows then
    local platform_ok, platform_name = run({ "uname", "-s" })
    assert.truthy(platform_ok, platform_name)
    LINUX = platform_name:match("Linux") ~= nil
end

local function mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir(parent) end
    assert(lfs.mkdir(path))
end

local function write(path, contents)
    mkdir(path:match("^(.*)/[^/]+$") or ".")
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function remove(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("Titan link-time optimization", function()
    local workspace
    local source_root

    before_each(function()
        if not LINUX then return end
        workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        source_root = workspace .. "/sources"
        mkdir(source_root)
        assert(lfs.chdir(workspace))
    end)

    after_each(function()
        assert(lfs.chdir(REPOSITORY))
        if workspace then remove(workspace) end
    end)

    local function titanc_arguments(extra_compile, extra_link, ...)
        -- GCC also uses MAKE for parallel LTO; skip only Titan's runtime build.
        local arguments = {
            "env", "-u", "TITAN_BUILD_PROFILE", "CC=" .. CC, "CCACHE_DISABLE=1", "TITAN_RUNTIME_PREBUILT=1",
            "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. PREFIX,
            "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=" .. (extra_compile or ""),
            "TITAN_EXTRA_LDFLAGS=" .. (extra_link or ""),
            LUA, "-E", "-e", string.format("package.path = %q .. package.path",
                REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;"),
            REPOSITORY .. "/titanc", "--tree", source_root,
        }
        for _, argument in ipairs({ ... }) do arguments[#arguments + 1] = argument end
        return arguments
    end

    local function titanc(extra_compile, extra_link, ...)
        return run(titanc_arguments(extra_compile, extra_link, ...))
    end

    local function compiled(...)
        local ok, output = titanc(nil, nil, ...)
        assert.is_true(ok, output)
        return output
    end

    it("optimizes separate modules into providers and a source-free archive consumer", function()
        if not LINUX then pending("default LTO is Linux-only"); return end
        local base = source_root .. "/lto_fixture/base"
        local facade = source_root .. "/lto_fixture/facade"
        write(source_root .. "/oracle.h", "void " .. SENTINEL .. "(void);\n")
        write(base .. ".titan", [[
            local foreign function answer(): int
                local total = 0
                while total < 42 do total = total + 1 end
                return total
            end
        ]])
        write(facade .. ".titan", [[
            local base = import "lto_fixture.base.titan"
            foreign import "]] .. source_root .. [[/oracle.h"
            function answer(): integer
                local result = base.answer()
                if result ~= 42 then ffi.]] .. SENTINEL .. [[() end
                return result as integer
            end
        ]])
        write(source_root .. "/direct_app.titan", [[
            local facade = import "lto_fixture.facade.titan"
            function main(args: {string}): integer return facade.answer() - 42 end
        ]])

        compiled("-c", "--incremental", "lto_fixture.base")
        compiled("-c", "--incremental", "lto_fixture.facade")
        compiled("-c", "--incremental", "direct_app")
        -- Only the forwarding entry is header-inline, not the foreign body:
        -- the constant result must still propagate across objects through LTO.
        local header = read(base .. ".titan.h")
        local canonical = coder_names._foreign_func_name("lto_fixture.base", "answer")
        local helper = coder_names._foreign_inline_name("lto_fixture.base", "answer")
        local name, callee = header:match(
            "static inline int (%S+)%(void%) {%s*return (%S+)%(%)%;%s*}")
        assert.equal(helper, name, header)
        assert.equal(canonical, callee, header)
        assert.falsy(header:find("while", 1, true), header)
        local nm_ok, unresolved = run({ "nm", "-u", facade .. ".o" })
        assert.is_true(nm_ok, unresolved)
        assert.matches(SENTINEL, unresolved, 1, true)
        for _, item in ipairs({ { base, "lto_fixture.base" }, { facade, "lto_fixture.facade" } }) do
            local bytes = read(item[1] .. ".o")
            local public = assert(staticmetadata.classify_object(bytes, item[1] .. ".o"))
            assert.equal(item[2], public.metadata.module)
            local source = assert(objectmetadata.read(bytes, item[1] .. ".o"))
            assert.equal(item[2], source.type.name)
        end

        local direct_output = compiled("--incremental", "--verbose", "direct_app")
        assert.matches("Titan object hit lto_fixture.facade:", direct_output, 1, true)
        local ok, output = run({ "./direct_app" })
        assert.is_true(ok, output)

        compiled("--incremental", "lto_fixture.base", "lto_fixture.facade")
        nm_ok, unresolved = run({ "nm", "-u", "lto_fixture.so" })
        assert.is_true(nm_ok, unresolved)
        assert.falsy(unresolved:find(SENTINEL, 1, true), unresolved)
        ok, output = run({ LUA, "-E", "-e",
            [[package.path = "./?.lua;" .. package.path; assert(require("lto_fixture.facade").answer() == 42)]] })
        assert.is_true(ok, output)

        -- Repeat the pair under a real shared jobserver. The archive-backed
        -- LTO link may then borrow its own slot alongside the DSO link, and
        -- GCC's LTRANS jobs join the same pool; both images must still be
        -- optimized and validated before publication.
        local quoted = {}
        for index, argument in ipairs(titanc_arguments(nil, nil,
                "--incremental", "--jobs", "3", "lto_fixture.base", "lto_fixture.facade")) do
            quoted[index] = assert(cdriver.shell_quote(argument))
        end
        write(workspace .. "/provider.sh",
            "exec " .. table.concat(quoted, " ") .. "\n")
        write(workspace .. "/parent.mk", "all:\n\t+@sh provider.sh\n")
        assert(os.remove("lto_fixture.so"))
        assert(os.remove("lto_fixture.a"))
        ok, output = run({ "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
            "-u", "MAKELEVEL", "make", "--no-print-directory", "-j3",
            "-f", "parent.mk" })
        assert.is_true(ok, output)
        nm_ok, unresolved = run({ "nm", "-u", "lto_fixture.so" })
        assert.is_true(nm_ok, unresolved)
        assert.falsy(unresolved:find(SENTINEL, 1, true), unresolved)
        ok, output = run({ LUA, "-E", "-e",
            [[package.path = "./?.lua;" .. package.path; assert(require("lto_fixture.facade").answer() == 42)]] })
        assert.is_true(ok, output)

        -- Only the compiled provider remains resolvable. The archive must
        -- preserve the original inter-module optimization input after Titan's
        -- own extraction, validation, and repacking path.
        assert(os.rename(source_root .. "/lto_fixture", workspace .. "/unavailable-sources"))
        write(source_root .. "/archive_app.titan", [[
            local facade = import "lto_fixture.facade"
            function main(args: {string}): integer return facade.answer() - 42 end
        ]])
        compiled("-c", "--incremental", "--static", "archive_app")
        compiled("--incremental", "--static", "archive_app")
        ok, output = run({ "./archive_app" })
        assert.is_true(ok, output)

        -- Fat objects also contain ordinary native code. Turning off the
        -- link optimizer must expose the unresolved sentinel in that code;
        -- otherwise successful links above would not prove cross-object LTO.
        ok, output = titanc("-O0 -fno-lto", "-O0 -fno-lto",
            "--incremental", "--static", "archive_app")
        assert.is_false(ok, output)
        assert.matches(SENTINEL, output, 1, true)
    end)
end)

local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local layout = require "titan-compiler.nominallayout"
local objectmetadata = require "titan-compiler.objectmetadata"
local staticmetadata = require "titan-compiler.staticmetadata"

local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua" .. (platform.windows and ".exe" or "")
local REPOSITORY = assert(lfs.currentdir())
if platform.windows then REPOSITORY = assert(platform.path.normalize(REPOSITORY)) end
local workspace, source_root

local function run(arguments)
    arguments = { table.unpack(arguments) }
    if platform.windows and arguments[1] == "env" then arguments[1] = "env.exe" end
    local result = compiler_io.new_sync():run(arguments)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.started and result.ok, output
end

local function run_program(name)
    local executable = platform.windows and
        assert(driver.windows_program_paths(name)).executable or "./" .. name
    return run({ "env", "TITAN_PATH_0_6=" ..
        (platform.windows and "./lib/titan/0.6;" or "") ..
        ".;" .. PREFIX .. "/lib/titan/0.6",
        "PATH=" .. PREFIX .. "/bin" .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or ""), executable })
end

local function write(path, contents)
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

local function compiled(...)
    local arguments = {
        "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1",
        "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. PREFIX,
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
        "TITAN_EXTRA_LDFLAGS=-fno-lto",
        LUA, "-E", "-e", string.format(
            "package.path = %q .. package.path; package.cpath = %q .. package.cpath",
            REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
            REPOSITORY .. "/titan-runtime/bootstrap/?" ..
                (platform.windows and ".dll" or ".so") .. ";"),
        REPOSITORY .. "/titanc", "--tree", source_root,
    }
    for _, argument in ipairs({ ... }) do arguments[#arguments + 1] = argument end
    local ok, output = run(arguments)
    assert.is_true(ok, output)
    return output
end

local function provider(name)
    write(source_root .. "/private.h", [[
        typedef struct nominal_private_native {
            long double precise;
            int secret;
            struct nominal_private_native *self;
        } nominal_private_native;
    ]])
    write(source_root .. "/" .. name .. ".titan", [[
        foreign import "private.h"
        record State
            local native: foreign nominal_private_native
            local hidden: string
            count: integer
            label: string
            local tail: foreign long double
        end
        record Box<|T|>
            item: T
            count: integer
        end
        union Choice
            local hidden(integer)
            ready(count: integer, label: string)
        end
        local foreign function native_secret(pointer: *nominal_private_native): int
            return pointer.secret
        end
        function make(): State
            local state = State.new(foreign nominal_private_native.new(),
                "hidden", 40, "old", 1.5)
            state.native.secret = 7
            state.native.self = state.native
            return state
        end
        function check(state: State): integer
            if state.native.self ~= state.native then return -100 end
            return state.count + native_secret(state.native) + #state.hidden + #state.label
        end
        function choice(): Choice return Choice.ready(5, "union") end
    ]])
    return source_root .. "/" .. name
end

describe("nominal layout provider boundaries", function()
    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
        assert(lfs.mkdir(workspace))
        source_root = workspace .. "/sources"
        assert(lfs.mkdir(source_root))
        assert(lfs.chdir(workspace))
    end)

    after_each(function()
        assert(lfs.chdir(REPOSITORY))
        if workspace then remove(workspace) end
    end)

    it("reconstructs a public prefix and erased generic slots from an archive alone", function()
        if platform.windows then
            pending("Titan static provider archives are unsupported on Windows")
            return
        end
        local name = "nominal_archive_fixture"
        local stem = provider(name)
        compiled(name)
        local archive = assert(staticmetadata.scan_archive(name .. ".a"))
        local metadata = assert(archive.entries[name])
        local inventory = assert(layout.decode(metadata.layouts, name))
        assert.equal("payload", inventory.records[name .. ".State"].by_index[2].storage)
        assert.equal(0, inventory.records[name .. ".State"].by_index[3].uv_index)
        assert.equal("uv", inventory.records[name .. ".Box"].by_index[0].storage)
        assert.falsy(metadata.layouts:find("nominal_private_native", 1, true))
        assert.falsy(metadata.types:find("nominal_private_native", 1, true))

        for _, suffix in ipairs({ ".titan", ".c", ".o", ".ffi.h", ".titan.h" }) do
            remove(stem .. suffix)
        end
        remove(source_root .. "/private.h")
        remove(name .. ".so")
        remove(name .. ".lua")
        write(source_root .. "/archive_app.titan", [[
            local provider = import "nominal_archive_fixture"
            foreign import "lua.h"
            function main(args: {string}): integer
                local state = provider.make()
                state.count = state.count + 2
                state.label = "public"
                local integer_box = provider.Box<|integer|>.new(19, 2)
                local string_box = provider.Box<|string|>.new("alive", 3)
                ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                if provider.check(state) ~= 61 then return 1 end
                if integer_box.item + integer_box.count ~= 21 then return 2 end
                if string_box.item ~= "alive" or string_box.count ~= 3 then return 3 end
                case provider.choice()
                when ready(count, label) then
                    if count + #label ~= 10 then return 4 end
                else return 5
                end
                return 0
            end
        ]])
        compiled("--static", "archive_app")
        local consumer = read(source_root .. "/archive_app.c")
        assert.falsy(consumer:find("nominal_private_native", 1, true))
        assert.falsy(consumer:find("private.h", 1, true))
        local ok, output = run_program("archive_app")
        assert.is_true(ok, output)
    end)

    it("reconstructs a public prefix from a DSO after deleting all producer sources and headers", function()
        local name = "nominal_dso_fixture"
        local stem = provider(name)
        compiled(name)
        for _, suffix in ipairs({ ".titan", ".c", ".o", ".ffi.h", ".titan.h" }) do
            remove(stem .. suffix)
        end
        remove(source_root .. "/private.h")
        remove(name .. ".a")
        remove(name .. ".lua")
        write(source_root .. "/dso_app.titan", [[
            local provider = import "nominal_dso_fixture"
            foreign import "lua.h"
            function main(args: {string}): integer
                local state = provider.make()
                state.count = 42
                state.label = "public"
                ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                if provider.check(state) ~= 61 then return 1 end
                local box = provider.Box<|integer|>.new(19, 2)
                if box.item + box.count ~= 21 then return 2 end
                case provider.choice()
                when ready(count, label) then
                    if count + #label ~= 10 then return 3 end
                else return 4
                end
                return 0
            end
        ]])
        compiled("dso_app")
        local consumer = read(source_root .. "/dso_app.c")
        assert.falsy(consumer:find("nominal_private_native", 1, true))
        assert.falsy(consumer:find("private.h", 1, true))
        local ok, output = run_program("dso_app")
        assert.is_true(ok, output)
    end)

    it("restores source-object layouts and private native projections without recompiling the producer", function()
        local name = "nominal_incremental_fixture"
        local stem = provider(name)
        compiled("-c", "--incremental", name)
        local bytes = read(stem .. ".o")
        local cached = assert(objectmetadata.read(bytes, stem .. ".o"))
        assert.truthy(cached.layout_inventory.records[name .. ".State"])
        assert.truthy(cached.object_metadata.layouts)
        remove(stem .. ".ffi.h")
        remove(stem .. ".titan.h")
        assert(lfs.touch(stem .. ".o", os.time() + 60))

        write(source_root .. "/incremental_app.titan", [[
            local provider = import "nominal_incremental_fixture.titan"
            function main(args: {string}): integer
                local state = provider.make()
                state.native.secret = 10
                state.hidden = "changed"
                state.count = 20
                state.label = "public"
                return provider.check(state) - 43
            end
        ]])
        local output = compiled("-c", "--incremental", "--verbose", "incremental_app")
        assert.matches("Titan object hit " .. name .. ":", output, 1, true)
        assert.equal(bytes, read(stem .. ".o"))
        assert.equal("file", lfs.attributes(stem .. ".ffi.h", "mode"))
        assert.equal("file", lfs.attributes(stem .. ".titan.h", "mode"))
        compiled("--incremental", "incremental_app")
        assert.equal(bytes, read(stem .. ".o"))
        local ok, result = run_program("incremental_app")
        assert.is_true(ok, result)
    end)
end)

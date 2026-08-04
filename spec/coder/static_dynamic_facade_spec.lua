local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local staticmetadata = require "titan-compiler.staticmetadata"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, cwd)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(cwd))
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    assert.truthy(lfs.chdir(previous))
    return ok == true, output, why, code
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents)
    local parent = assert(path:match("^(.+)/[^/]+$"))
    make_directory(parent)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function compiler_argv(workspace, source_root, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_20=" .. workspace,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin")
    end

    local installed = not USE_CHECKOUT_COMPILER and
        PREFIX and exists(PREFIX .. "/bin/titanc")
    if installed then
        table.insert(argv, PREFIX .. "/bin/titanc")
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
        table.insert(argv, "LUA_CPATH=" .. REPO .. "/?.so;;")
        table.insert(argv, LUA)
        table.insert(argv, "-e")
        table.insert(argv, string.format(
            "package.path=%q..package.path", REPO .. "/?.lua;" ..
                REPO .. "/?/init.lua;"))
        table.insert(argv, REPO .. "/titanc")
    end

    table.insert(argv, "--tree")
    table.insert(argv, source_root)
    for _, argument in ipairs({ ... }) do table.insert(argv, argument) end
    return argv
end

local function compile(workspace, source_root, ...)
    return run(compiler_argv(workspace, source_root, ...), workspace)
end

local function metadata_options()
    return {
        expected_abi = driver.TITAN_VER,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end,
    }
end

describe("static facade with a producer-dynamic nominal owner", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root)
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("uses a visible owner archive only for type recovery", function()
        write_file(source_root .. "/dynamic/owner.titan", [[
record Box
    n: integer
end

function Box.make(n: integer): Box
    return Box.new(n)
end

function Box:add(delta: integer): integer
    return self.n + delta
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "dynamic.owner")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local owner_dso = workspace .. "/dynamic/owner.so"
        local owner_archive = workspace .. "/dynamic/owner.a"
        assert.equal("file", lfs.attributes(owner_dso, "mode"))
        local owner_archive_bytes = read_file(owner_archive)
        assert.truthy(os.remove(owner_archive))

        write_file(source_root .. "/dynamic/facade.titan", [[
local owner = import "dynamic.owner"
type Box = owner.Box

function make(n: integer): Box
    return Box.make(n)
end
]])
        ok, output, why, code =
            compile(workspace, source_root, "dynamic.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local facade_c = read_file(source_root .. "/dynamic/facade.c")
        assert.truthy(facade_c:find(
            'loadlib(L, "dynamic/owner.so")', 1, true), facade_c)
        assert.truthy(facade_c:find(
            'loadsym(L, dynamic_owner_handle, "dynamic_owner_Box_make_titanstatic")',
            1, true), facade_c)
        local facade_archive = workspace .. "/dynamic/facade.a"
        local facade, facade_err =
            staticmetadata.scan_archive(facade_archive, metadata_options())
        assert.truthy(facade, facade_err)
        assert.same({ "dynamic.facade" }, facade.key_order)
        assert.is_nil(facade.entries["dynamic.owner"])
        assert.truthy(facade.entries["dynamic.facade"].types:find(
            "dynamic.owner.Box", 1, true))

        -- The facade has already committed to its producer's DSO identity.
        -- Leave only the same-interface owner archive visible while compiling
        -- the consumer: neither the producer DSO nor source may accidentally
        -- satisfy contextual type recovery. The archive must still remain a
        -- type-only input rather than becoming an ordinary link input.
        local hidden_owner_dso = workspace .. "/dynamic/owner.runtime-image"
        assert.truthy(os.rename(owner_dso, hidden_owner_dso))
        assert.truthy(os.remove(
            source_root .. "/dynamic/owner.titan"))
        write_file(source_root .. "/app.titan", [[
local facade = import "dynamic.facade"

function main(args: {string}): integer
    local make: (integer) -> facade.Box = facade.Box.make
    local box = make(40)
    if box:add(2) == 42 and facade.make(39).n == 39 then
        return 0
    else
        return 1
    end
end
]])
        ok, output = compile(
            workspace, source_root, "--static", "app")
        assert.falsy(ok)
        assert.truthy(output:find(
            "invalid type 'dynamic.owner.Box'", 1, true),
            output)
        assert.is_nil(lfs.attributes(workspace .. "/app", "mode"))

        write_file(owner_archive, owner_archive_bytes)
        ok, output, why, code =
            compile(workspace, source_root, "-v", "--static", "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated = read_file(source_root .. "/app.c")
        assert.truthy(generated:find(
            'loadglobalsym(L, "dynamic_owner_Box_add_titanmethod")',
            1, true), generated)
        assert.truthy(generated:find(
            'lua_getfield(L, LUA_REGISTRYINDEX, "Titan module dynamic.owner")',
            1, true), generated)

        local final_link
        for line in output:gmatch("[^\r\n]+") do
            if line:find("'app__entrypoint.o'", 1, true) and
               not line:find("'app__entrypoint.c'", 1, true) then
                assert.is_nil(final_link, output)
                final_link = line
            end
        end
        assert.truthy(final_link, output)
        assert.truthy(final_link:find(facade_archive, 1, true), final_link)
        assert.falsy(final_link:find(owner_archive, 1, true), final_link)
        assert.falsy(final_link:find(owner_dso, 1, true), final_link)
        assert.falsy(output:find(owner_archive, 1, true), output)

        -- The executable must need the producer-chosen owner DSO at runtime.
        -- Neither the type-only archive, sibling facade DSO, nor any shim may
        -- have smuggled in a fallback implementation.
        assert.truthy(os.remove(owner_archive))
        assert.truthy(os.remove(workspace .. "/dynamic/facade.so"))
        assert.truthy(os.remove(workspace .. "/dynamic/facade.lua"))
        assert.truthy(os.remove(workspace .. "/dynamic/owner.lua"))
        ok, output, why, code =
            run({ workspace .. "/app" }, workspace)
        assert.falsy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:find("dynamic/owner.so", 1, true), output)

        assert.truthy(os.rename(hidden_owner_dso, owner_dso))
        ok, output, why, code =
            run({ workspace .. "/app" }, workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)
end)

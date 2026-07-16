local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO = lfs.currentdir()
local PREFIX = os.getenv("PREFIX") or os.getenv("TITAN_TEST_PREFIX")
local LUA = PREFIX and (PREFIX .. "/bin/lua") or "lua"

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
    make_directory(assert(path:match("^(.+)/[^/]+$")))
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

local function compiler_argv(output_root, source_root, titan_path, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_16=" .. titan_path,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin")
    end

    local installed = PREFIX and exists(PREFIX .. "/bin/titanc")
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

local function compile(output_root, source_root, titan_path, ...)
    return run(compiler_argv(
        output_root, source_root, titan_path, ...), output_root)
end

local function assert_compiles(output_root, source_root, titan_path, ...)
    local ok, output, why, code = compile(
        output_root, source_root, titan_path, ...)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

local function run_lua(cwd, titan_path, package_path, cpath_roots, code)
    assert.truthy(PREFIX,
        "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
    local cpath = {}
    for _, root in ipairs(cpath_roots) do
        table.insert(cpath, root .. "/?.so")
    end
    table.insert(cpath, PREFIX .. "/lib/titan/0.16/?.so")
    table.insert(cpath, PREFIX .. "/lib/lua/5.5/?.so")

    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "TITAN_PATH_0_16=" .. titan_path,
        "TITAN_PATH=",
        LUA, "-e", string.format([[
package.path = %q
package.cpath = %q
%s
]], package_path .. "/?.lua", table.concat(cpath, ";"), code),
    }, cwd)
end

describe("compiled-provider selection across Titan path roots", function()
    local workspace
    local root_one
    local root_two
    local consumer_root
    local source_one
    local source_two
    local consumer_source
    local titan_path

    setup(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))

        root_one = workspace .. "/R1"
        root_two = workspace .. "/R2"
        consumer_root = workspace .. "/consumer"
        source_one = workspace .. "/source-one"
        source_two = workspace .. "/source-two"
        consumer_source = workspace .. "/consumer-source"
        for _, directory in ipairs({
            root_one, root_two, consumer_root,
            source_one, source_two, consumer_source,
        }) do
            make_directory(directory)
        end
        titan_path = root_one .. ";;" .. root_two

        write_file(source_one .. "/route/item.titan", [[
function origin(): integer
    return 101
end

function root_one_only(): integer
    return 11
end
]])
        write_file(source_two .. "/route/item.titan", [[
function origin(): integer
    return 202
end

function root_two_only(): integer
    return 22
end
]])

        assert_compiles(root_one, source_one, root_one, "route.item")
        assert_compiles(root_two, source_two, root_two, "route.item")

        write_file(consumer_source .. "/path_consumer.titan", [[
local item = import "route.item"

function answer(): integer
    return item.origin() + item.root_one_only()
end
]])
        assert_compiles(consumer_root, consumer_source, titan_path,
            "path_consumer")
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("uses the earlier exact provider for checking and Titan imports",
       function()
        assert.equal("file", lfs.attributes(
            root_one .. "/route/item.so", "mode"))
        assert.equal("file", lfs.attributes(
            root_two .. "/route/item.so", "mode"))

        local generated = read_file(
            consumer_source .. "/path_consumer.c")
        assert.truthy(generated:find(
            'loadlib(L, "route/item.so")', 1, true), generated)
        assert.falsy(generated:find(root_one, 1, true), generated)
        assert.falsy(generated:find(root_two, 1, true), generated)
        -- root_one_only exists only in R1, so successful checking proves that
        -- the compiler selected R1 before emitting this native call.
        assert.truthy(generated:find(
            "route_item_root_one_only_titan", 1, true), generated)

        local ok, output = run_lua(
            consumer_root, titan_path, consumer_root, { consumer_root }, [[
local consumer = require "path_consumer"
assert(consumer.answer() == 112)
]])
        assert.truthy(ok, output)
    end)

    it("lets generated shims follow package.cpath precedence independently",
       function()
        local aligned_path = root_one .. ";;" .. root_two
        local ok, output = run_lua(
            workspace, aligned_path, root_one, { root_one, root_two },
            string.format([[
assert(package.searchpath("route.item", package.cpath) == %q)
local item = require "route.item"
assert(item.origin() == 101)
assert(item.root_one_only() == 11)
]], root_one .. "/route/item.so"))
        assert.truthy(ok, output)

        -- The Lua shim comes from R1 in both processes. Reversing only C-path
        -- order therefore demonstrates physical Lua-provider precedence, not
        -- fallback through the Titan import path.
        ok, output = run_lua(
            workspace, aligned_path, root_one, { root_two, root_one },
            string.format([[
assert(package.searchpath("route.item", package.cpath) == %q)
local item = require "route.item"
assert(item.origin() == 202)
assert(item.root_two_only() == 22)
]], root_two .. "/route/item.so"))
        assert.truthy(ok, output)
    end)

    it("selects one shallower provider from a later Titan path root",
       function()
        write_file(source_two .. "/later/branch/item.titan", [[
function answer(): integer
    return 303
end
]])
        write_file(source_two .. "/later/peer.titan", [[
function marker(): integer
    return 404
end
]])
        assert_compiles(root_two, source_two, root_two,
            "later.branch.item", "later.peer")
        assert.equal("file", lfs.attributes(root_two .. "/later.so", "mode"))
        assert.is_nil(lfs.attributes(
            root_two .. "/later/branch/item.so", "mode"))

        write_file(consumer_source .. "/later_consumer.titan", [[
local item = import "later.branch.item"

function answer(): integer
    return item.answer()
end
]])
        assert_compiles(consumer_root, consumer_source, titan_path,
            "later_consumer")

        local generated = read_file(
            consumer_source .. "/later_consumer.c")
        assert.truthy(generated:find(
            'loadlib(L, "later.so")', 1, true), generated)
        assert.falsy(generated:find(
            'loadlib(L, "later/branch/item.so")', 1, true), generated)

        local ok, output = run_lua(
            consumer_root, titan_path, consumer_root, { consumer_root }, [[
local consumer = require "later_consumer"
assert(consumer.answer() == 303)
]])
        assert.truthy(ok, output)
    end)
end)

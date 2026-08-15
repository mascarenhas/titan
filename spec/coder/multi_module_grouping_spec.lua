local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"

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

local function collect_files(path, suffix, files)
    files = files or {}
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                collect_files(path .. "/" .. name, suffix, files)
            end
        end
    elseif mode == "file" and path:sub(-#suffix) == suffix then
        table.insert(files, path)
    end
    table.sort(files)
    return files
end

local function compiler_argv(workspace, source_root, ...)
    local installed = PREFIX and exists(PREFIX .. "/bin/titanc")
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH_5_5",
    }
    if installed then
        table.insert(argv, "-u")
        table.insert(argv, "LUA_CPATH")
    end
    table.insert(argv, "CCACHE_DISABLE=1")
    -- Opt-in formatting coverage must not make the ordinary test/CI lane
    -- depend on clang-format being installed.
    table.insert(argv, "CLANG_FORMAT=true")
    table.insert(argv, "TITAN_PATH_0_25=" .. workspace)
    table.insert(argv, "TITAN_PATH=")
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:" ..
            (os.getenv("PATH") or "/usr/bin:/bin"))
    end

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

local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?.so;" .. %q .. "/?.so;" .. package.cpath
%s
]], workspace, workspace, REPO, code),
    }, workspace)
end

describe("public compiler module grouping", function()
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

    it("keeps an exact provider for one root and deduplicates CLI roots",
       function()
        write_file(source_root .. "/single/item.titan", [[
function answer(): integer
    return 17
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v", "single.item", "single.item")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert.equal("file", lfs.attributes(
            workspace .. "/single/item.so", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/single/item.a", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/single/item.lua", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/single.so", "mode"))

        local shim = read_file(workspace .. "/single/item.lua")
        assert.truthy(shim:find(
            'package.searchpath("single.item", package.cpath)', 1, true),
            shim)
        assert.truthy(shim:find('"luaopen_single_item"', 1, true), shim)

        local compile_lines = 0
        local link_lines = 0
        for line in output:gmatch("[^\n]+") do
            if line:find("'-c'", 1, true) and
               line:find("/single/item.c'", 1, true) then
                compile_lines = compile_lines + 1
            end
            if line:find("'-shared'", 1, true) then
                link_lines = link_lines + 1
            end
        end
        assert.equal(1, compile_lines, output)
        -- The public DSO and the private archive-validation image each link
        -- once; duplicate CLI roots must not add another compile or link.
        assert.equal(2, link_lines, output)

        ok, output = run_lua(workspace, [[
local item = require "single.item"
assert(item.answer() == 17)
assert(require("single.item") == item)
]])
        assert.truthy(ok, output)
    end)

    it("derives a root provider for a requested root and descendant",
       function()
        write_file(source_root .. "/group.titan", [[
function base_value(): integer
    return 40
end
]])
        write_file(source_root .. "/group/child.titan", [[
local parent = import "group"

function child_value(): integer
    return parent.base_value() + 2
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "group", "group.child")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert.equal("file", lfs.attributes(workspace .. "/group.so", "mode"))
        assert.equal("file", lfs.attributes(workspace .. "/group.lua", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/group/child.lua", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/group/child.so", "mode"))

        for _, shim_path in ipairs({
            workspace .. "/group.lua",
            workspace .. "/group/child.lua",
        }) do
            local shim = read_file(shim_path)
            assert.truthy(shim:find(
                'package.searchpath("group", package.cpath)', 1, true), shim)
        end

        ok, output = run_lua(workspace, [[
local child = require "group.child"
local root = require "group"
assert(child.child_value() == 42)
assert(root.base_value() == 40)
]])
        assert.truthy(ok, output)
    end)

    it("emits one logical shim and no contributor artifacts for a folder module",
       function()
        local folder = source_root .. "/folder/unit"
        write_file(folder .. "/unit.titan", [[
function answer(): integer
    return contributor_answer()
end
]])
        write_file(folder .. "/part.titan", [[
local function contributor_answer(): integer
    return 42
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "folder.unit")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert.equal("file", lfs.attributes(
            workspace .. "/folder/unit.so", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/folder/unit.lua", "mode"))
        assert.same({ workspace .. "/folder/unit.lua" },
            collect_files(workspace, ".lua"))

        assert.equal("file", lfs.attributes(folder .. "/unit.c", "mode"))
        assert.equal("file", lfs.attributes(folder .. "/unit.o", "mode"))
        for _, path in ipairs({
            folder .. "/part.c",
            folder .. "/part.o",
            workspace .. "/folder/unit/part.lua",
            workspace .. "/folder/unit/part.so",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end

        ok, output = run_lua(workspace, [[
local unit = require "folder.unit"
assert(unit.answer() == 42)
]])
        assert.truthy(ok, output)
    end)

    it("bundles unrelated roots when exactly one root defines main",
       function()
        write_file(source_root .. "/library.titan", [[
function exit_code(): integer
    return 27
end
]])
        write_file(source_root .. "/application.titan", [[
local library = import "library"

function main(args: {string}): integer
    return library.exit_code()
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "--pretty-print", "library", "application")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert.equal("file", lfs.attributes(workspace .. "/application",
            "mode"))
        local entrypoint = workspace .. "/application__entrypoint.c"
        assert.equal("file", lfs.attributes(entrypoint, "mode"))
        assert.same({}, collect_files(workspace, ".so"))
        assert.same({}, collect_files(workspace, ".lua"))

        ok, output, why, code = run({ workspace .. "/application" },
            workspace)
        assert.falsy(ok)
        assert.equal("", output)
        assert.equal("exit", why)
        assert.equal(27, code)
    end)
end)

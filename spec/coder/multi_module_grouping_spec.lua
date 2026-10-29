local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"

local REPO = assert(lfs.currentdir())
if platform.windows then REPO = assert(platform.path.normalize(REPO)) end
local PREFIX = require("spec.support.installed_prefix").active()
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local LUA = PREFIX .. "/bin/lua" .. (platform.windows and ".exe" or "")
local INSTALLED_TITANC = PREFIX .. (platform.windows and
    "/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" or "/bin/titanc")
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function run(argv, cwd)
    local command = { table.unpack(argv) }
    local scripts = {}
    if platform.windows then
        if command[1] == "env" then command[1] = "env.exe" end
        for index = 1, #command - 1 do
            if command[index] == "-e" and command[index + 1]:find("[\r\n]") then
                local script = assert(compiler_io.new_sync():tmpname())
                local file = assert(io.open(script, "wb"))
                assert(file:write(command[index + 1]))
                assert(file:close())
                scripts[#scripts + 1] = script
                command[index] = script
                table.remove(command, index + 1)
                break
            end
        end
    end
    local previous = assert(lfs.currentdir())
    assert.truthy(lfs.chdir(cwd))
    local called, result = pcall(function()
        return compiler_io.new_sync():run(command)
    end)
    assert.truthy(lfs.chdir(previous))
    for _, script in ipairs(scripts) do os.remove(script) end
    assert.truthy(called, result)
    local output = result.output or result.diagnostic or ""
    if platform.windows then
        output = output:gsub("\r\n", "\n")
        output = output:gsub('%^"(.-)%^"', function(word)
            return assert(cdriver.shell_quote((word:gsub("%^(.)", "%1"))))
        end)
    end
    return result.started and result.ok, output, result.why, result.status
end

local function temporary_workspace()
    local path = assert(compiler_io.new_sync():tmpname())
    assert.truthy(os.remove(path))
    assert.truthy(lfs.mkdir(path))
    if platform.windows then path = assert(platform.path.normalize(path)) end
    return path
end

local function shared_path(workspace, stem)
    return workspace .. "/" .. stem .. SHARED_SUFFIX
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
    local installed = not USE_CHECKOUT_COMPILER and
        PREFIX and exists(INSTALLED_TITANC)
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
    table.insert(argv, "CLANG_FORMAT=" .. (platform.windows and "true.exe" or "true"))
    table.insert(argv, "TITAN_PATH_0_6=" .. workspace)
    table.insert(argv, "TITAN_PATH=")
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin" .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or "/usr/bin:/bin"))
    end

    if installed then
        if platform.windows then table.insert(argv, LUA) end
        table.insert(argv, INSTALLED_TITANC)
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROOT=" .. PREFIX)
        table.insert(argv, "LUA_CPATH=" .. REPO .. "/?" .. SHARED_SUFFIX .. ";;")
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

local function compile_with_environment(
        workspace, source_root, environment, ...)
    local argv = compiler_argv(workspace, source_root, ...)
    local command_index
    for index, argument in ipairs(argv) do
        if argument == INSTALLED_TITANC or argument == LUA then
            command_index = index
            break
        end
    end
    assert.truthy(command_index, "cannot locate compiler command")

    local names = {}
    for name in pairs(environment) do names[#names + 1] = name end
    table.sort(names)
    for offset, name in ipairs(names) do
        table.insert(argv, command_index + offset - 1,
            name .. "=" .. environment[name])
    end
    return run(argv, workspace)
end

-- Lua hosts install the Titan searcher through the `titan` support module and
-- find the workspace's providers through the Titan path, never cpath.
local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        "TITAN_PATH_0_6=" .. workspace .. ";;", "TITAN_PATH=",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
require "titan"
%s
]], workspace, REPO, SHARED_SUFFIX, code),
    }, workspace)
end

describe("public compiler module grouping", function()
    local workspace
    local source_root

    before_each(function()
        workspace = temporary_workspace()
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
            shared_path(workspace, "single/item"), "mode"))
        if platform.windows then
            assert.is_nil(lfs.attributes(workspace .. "/single/item.a", "mode"))
        else
            assert.equal("file", lfs.attributes(workspace .. "/single/item.a", "mode"))
        end
        assert.is_nil(lfs.attributes(shared_path(workspace, "single"), "mode"))
        assert.same({}, collect_files(workspace, ".lua"))

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
        -- Unix also links a private archive-validation image. Duplicate CLI
        -- roots must not add another compile or provider link on either host.
        assert.equal(platform.windows and 1 or 2, link_lines, output)

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

        assert.equal("file", lfs.attributes(shared_path(workspace, "group"), "mode"))
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "group/child"), "mode"))
        assert.same({}, collect_files(workspace, ".lua"))

        ok, output = run_lua(workspace, [[
local child = require "group.child"
local root = require "group"
assert(child.child_value() == 42)
assert(root.base_value() == 40)
]])
        assert.truthy(ok, output)
    end)

    it("emits no Lua loader and no contributor artifacts for a folder module",
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
            shared_path(workspace, "folder/unit"), "mode"))
        assert.same({}, collect_files(workspace, ".lua"))

        assert.equal("file", lfs.attributes(folder .. "/unit.c", "mode"))
        assert.equal("file", lfs.attributes(folder .. "/unit.o", "mode"))
        for _, path in ipairs({
            folder .. "/part.c",
            folder .. "/part.o",
            workspace .. "/folder/unit/part.lua",
            shared_path(workspace, "folder/unit/part"),
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end

        ok, output = run_lua(workspace, [[
local unit = require "folder.unit"
assert(unit.answer() == 42)
]])
        assert.truthy(ok, output)
    end)

    it("preloads initialized source imports in a standalone",
       function()
        write_file(source_root .. "/library/leaf.titan", [[
local initialized = 0

function answer(): integer
    return 15
end

function initializations(): integer
    return initialized
end

do
    initialized = initialized + 1
end
]])
        write_file(source_root .. "/library.titan", [[
local leaf = import "library.leaf"

local initialized = 0

function answer(): integer
    return leaf.answer() + 12
end

function initializations(): integer
    return initialized
end

function leaf_initializations(): integer
    return leaf.initializations()
end

do
    initialized = initialized + 1
end
]])
        write_file(source_root .. "/application.titan", [=[
local library = import "library"
local tlua = import "lua"

function main(args: {string}): integer
    if library.initializations() ~= 1 or
       library.leaf_initializations() ~= 1 then
        return 1
    end

    local preload_state = tlua.load([[
return type(package.preload["application"]),
       type(package.preload["library"]),
       type(package.preload["library.leaf"]),
       package.loaded["library"],
       package.loaded["library.leaf"]
]], "=standalone-preload-state", nil)
    local application_preload: value, library_preload: value,
          leaf_preload: value, library_cached: value, leaf_cached: value =
        preload_state()
    if application_preload as string ~= "function" or
       library_preload as string ~= "function" or
       leaf_preload as string ~= "function" or
       library_cached ~= nil or leaf_cached ~= nil then
        return 2
    end

    local inspect = tlua.load([[
local module = ...
return module.answer(), module.initializations()
]], "=standalone-preload-inspect", nil)
    local loaded_library = tlua.require("library")
    local library_value: value, library_inits: value = inspect(loaded_library)
    if library_value as integer ~= 27 or library_inits as integer ~= 1 or
       tlua.require("library") ~= loaded_library then
        return 3
    end

    local loaded_leaf = tlua.require("library.leaf")
    local leaf_value: value, leaf_inits: value = inspect(loaded_leaf)
    if leaf_value as integer ~= 15 or leaf_inits as integer ~= 1 or
       tlua.require("library.leaf") ~= loaded_leaf then
        return 4
    end

    if library.initializations() ~= 1 or
       library.leaf_initializations() ~= 1 then
        return 5
    end
    return library.answer()
end
]=])

        local ok, output, why, code = compile_with_environment(
            workspace, source_root, {
                TITAN_PATH_0_6 = workspace .. ";;",
            }, "--pretty-print",
            "library", "application")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local paths = platform.windows and
            assert(driver.windows_program_paths("application")) or nil
        local executable = workspace .. "/" ..
            (paths and paths.executable or "application")
        assert.equal("file", lfs.attributes(executable, "mode"))
        local entrypoints = collect_files(source_root .. "/.titan-links",
            "/synthetic/application__entrypoint.c")
        assert.equal(1, #entrypoints)
        assert.equal("file", lfs.attributes(entrypoints[1], "mode"))
        assert.same(paths and { workspace .. "/" .. paths.provider } or {},
            collect_files(workspace, SHARED_SUFFIX))
        assert.same({}, collect_files(workspace, ".lua"))

        local program_argv = {
            "env", "TITAN_PATH_0_6=" ..
                (platform.windows and "./lib/titan/0.6;" or "") ..
                ".;" .. PREFIX .. "/lib/titan/0.6",
            "PATH=" .. PREFIX .. "/bin" .. (platform.windows and ";" or ":") ..
                (os.getenv("PATH") or "/usr/bin:/bin"),
            executable,
        }
        if platform.windows then
            -- Preserve the native provider list when env.exe launches the EXE.
            table.insert(program_argv, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6")
        end
        ok, output, why, code = run(program_argv, workspace)
        assert.falsy(ok)
        assert.equal("", output)
        assert.equal("exit", why)
        assert.equal(27, code, output)
    end)
end)

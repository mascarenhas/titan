-- Shared scaffolding for the Titan path and searcher specs. The compiler-only
-- cases live in spec/coder/multi_module_path_runtime_spec.lua; the cases whose
-- fixtures import installed standard modules live in
-- spec/coder/multi_module_path_stdlib_spec.lua, which CI runs only after the
-- full provider is installed. Both require this harness instead of keeping a
-- second copy of the workspace, provider and host scaffolding.
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"

local M = {}

M.REPO = path.normalize(assert(lfs.currentdir()))
M.PREFIX = require("spec.support.installed_prefix").active()
M.SHARED_SUFFIX = platform.windows and ".dll" or ".so"
M.EXE_SUFFIX = platform.windows and ".exe" or ""
M.LUA = path.join(M.PREFIX, "bin", "lua" .. M.EXE_SUFFIX)
-- The installed compiler program: the native titanc.exe on Windows.
local INSTALLED_TITANC = path.join(M.PREFIX, "bin", "titanc" .. M.EXE_SUFFIX)
-- The installed support module; the only C path entry of every runtime chunk.
M.SUPPORT_CPATH = path.to_slash(path.join(M.PREFIX, "lib/lua/5.5",
    "?" .. M.SHARED_SUFFIX))
-- titan.h TITAN_PATH_KEY: the per-state effective Titan path.
M.TITAN_PATH_KEY = "ec10e486-d8fd-11e7-87f4-e7e9581a929c"

local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function exists(name)
    return lfs.attributes(name, "mode") ~= nil
end
M.exists = exists

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
M.run = run

local function temporary_workspace()
    local workspace = assert(compiler_io.new_sync():tmpname())
    assert.truthy(os.remove(workspace))
    assert.truthy(lfs.mkdir(workspace))
    return path.normalize(workspace)
end
M.temporary_workspace = temporary_workspace

local function shared_path(workspace, stem)
    return path.join(workspace, stem .. M.SHARED_SUFFIX)
end
M.shared_path = shared_path

local function make_directory(directory)
    if lfs.attributes(directory, "mode") == "directory" then return end
    local parent = path.dirname(directory)
    if parent ~= directory then make_directory(parent) end
    assert.truthy(lfs.mkdir(directory), "could not create " .. directory)
end
M.make_directory = make_directory

local function write_file(filename, contents)
    make_directory(path.dirname(filename))
    local file = assert(io.open(filename, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end
M.write_file = write_file

local function read_file(filename)
    local file = assert(io.open(filename, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end
M.read_file = read_file

local function copy_file(source, destination)
    write_file(destination, read_file(source))
end
M.copy_file = copy_file

local function remove_tree(directory)
    local mode = lfs.symlinkattributes(directory, "mode")
    if mode == "directory" then
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then
                remove_tree(path.join(directory, name))
            end
        end
        assert.truthy(lfs.rmdir(directory))
    elseif mode then
        assert.truthy(os.remove(directory))
    end
end
M.remove_tree = remove_tree

local function compiler_argv(output_root, source_root, titan_path, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_6=" .. titan_path,
        "TITAN_PATH=",
    }
    if M.PREFIX then
        table.insert(argv, "PATH=" .. path.join(M.PREFIX, "bin") .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or "/usr/bin:/bin"))
    end

    local installed = not USE_CHECKOUT_COMPILER and
        M.PREFIX and exists(INSTALLED_TITANC)
    if installed then
        table.insert(argv, INSTALLED_TITANC)
    else
        assert.truthy(M.PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROOT=" .. M.PREFIX)
        table.insert(argv, "LUA_CPATH=" .. path.to_slash(path.join(M.REPO, "?" .. M.SHARED_SUFFIX)) .. ";;")
        table.insert(argv, M.LUA)
        table.insert(argv, "-e")
        table.insert(argv, string.format(
            "package.path=%q..package.path", path.to_slash(path.join(M.REPO, "?.lua")) .. ";" ..
                path.to_slash(path.join(M.REPO, "?/init.lua")) .. ";"))
        table.insert(argv, path.join(M.REPO, "titanc"))
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
M.assert_compiles = assert_compiles

-- Run a Lua chunk in a fresh host whose only C path entry is the support
-- module. `require "titan"` installs the Titan searcher; Lua source search is
-- disabled so nothing but that searcher can resolve a Titan module.
-- options.titan_path sets TITAN_PATH_0_6 (nil leaves every Titan path variable
-- unset); options.env adds "NAME=value" entries; options.lua selects the host.
local function run_lua(cwd, options, code)
    assert.truthy(M.PREFIX,
        "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "-u", "TITAN_PATH", "-u", "TITAN_PATH_0_6",
        "-u", "TITAN_ROOT", "-u", "TITANC",
    }
    if options.titan_path ~= nil then
        table.insert(argv, "TITAN_PATH_0_6=" .. options.titan_path)
    end
    for _, entry in ipairs(options.env or {}) do table.insert(argv, entry) end
    table.insert(argv, options.lua or M.LUA)
    table.insert(argv, "-e")
    table.insert(argv, string.format([[
package.path = ""
package.cpath = %q
local titan = require "titan"
local TITAN_PATH_KEY = %q
%s
]], M.SUPPORT_CPATH, M.TITAN_PATH_KEY, code))
    return run(argv, cwd)
end

local function assert_runs(cwd, options, code)
    local ok, output = run_lua(cwd, options, code)
    assert.truthy(ok, output)
    return output
end
M.assert_runs = assert_runs

-- The provider fixture: one module whose origin identifies its root.
local function item_source(origin)
    return string.format([[
count: integer = 0

function origin(): integer
    return %d
end

function bump(): integer
    count = count + 1
    return count
end
]], origin)
end
M.item_source = item_source

local function root(workspace, name)
    return path.join(workspace, name)
end
M.root = root

-- A Unix stand-in for titanc that records each launch and prints a root.
local function write_titanc_shim(directory, log, printed_root)
    local shim = path.join(directory, "titanc")
    write_file(shim, string.format([[
#!/bin/sh
printf 'probe\n' >> '%s'
printf '%%s\n' '%s'
]], log, printed_root))
    local ok, output = run({ "chmod", "+x", shim }, directory)
    assert.truthy(ok, output)
    return shim
end
M.write_titanc_shim = write_titanc_shim

local function probe_count(log)
    if not exists(log) then return 0 end
    local _, count = read_file(log):gsub("probe\n", "")
    return count
end
M.probe_count = probe_count

return M

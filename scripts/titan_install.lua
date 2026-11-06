local command, private, tree, lua_dir, luarocks = ...
local windows = package.config:sub(1, 1) == "\\"

-- Dependencies can live in a selected rock tree separate from the Lua prefix.
if command == "publish" and tree then
    package.path = tree .. "/share/lua/5.5/?.lua;" ..
        tree .. "/share/lua/5.5/?/init.lua;" .. package.path
    package.cpath = tree .. "/lib/lua/5.5/?." ..
        (windows and "dll" or "so") .. ";" .. package.cpath
end
local lfs = require "lfs"
local installer = {}

local function slash(path)
    return windows and path:gsub("\\", "/") or path
end

local function parent(path)
    return path:match("^(.*)/[^/]+$")
end

local function mkdir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local outer = parent(path)
    if outer and outer ~= "" then mkdir(outer) end
    assert(lfs.mkdir(path))
end

local function physical(path)
    local previous = assert(lfs.currentdir())
    assert(lfs.chdir(path))
    local result = slash(assert(lfs.currentdir()))
    assert(lfs.chdir(previous))
    return result
end

local function same(left, right)
    left, right = physical(left), physical(right)
    if windows then left, right = left:lower(), right:lower() end
    return left == right
end

-- Windows also accepts backslash separators, so split on both there before
-- rejecting dot components.
local function contained(root, relative)
    local path = root
    local components = {}
    for component in relative:gmatch(windows and "[^/\\]+" or "[^/]+") do
        assert(component ~= "." and component ~= "..", "invalid SDK path: " .. relative)
        components[#components + 1] = component
    end
    for index = 1, #components - 1 do
        path = path .. "/" .. components[index]
        local mode = lfs.symlinkattributes(path, "mode")
        assert(mode == nil or mode == "directory",
            "SDK destination parent is not an ordinary directory: " .. path)
    end
end

local function quote(value)
    assert(not value:find("%z"), "command argument contains NUL")
    if windows then
        -- cmd.exe expands percent variables even inside quotes. These paths
        -- cannot be passed faithfully through its command-string interface.
        assert(not value:find('["%%\r\n]'),
            "Windows command path contains an unsupported quote or percent")
        return '"' .. value .. '"'
    end
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function execute(argv)
    local words = {}
    for _, word in ipairs(argv) do words[#words + 1] = quote(word) end
    local line = table.concat(words, " ")
    if windows then line = "type NUL && " .. line end
    return os.execute(line)
end

local function files(root, relative, result)
    relative, result = relative or "", result or {}
    local directory = relative == "" and root or root .. "/" .. relative
    for name in lfs.dir(directory) do
        if name ~= "." and name ~= ".." then
            local child = relative == "" and name or relative .. "/" .. name
            local mode = assert(lfs.symlinkattributes(root .. "/" .. child, "mode"))
            if mode == "directory" then
                files(root, child, result)
            else
                assert(mode == "file", "payload is not an ordinary file: " .. child)
                result[#result + 1] = child
            end
        end
    end
    table.sort(result)
    return result
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove_tree(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function copy(source, destination, executable)
    local attributes = assert(lfs.attributes(source))
    mkdir(assert(parent(destination)))
    local existing = lfs.symlinkattributes(destination, "mode")
    assert(existing == nil or existing == "file",
        "installation destination is not an ordinary file: " .. destination)
    -- Never truncate an installed image: another process may have it mapped.
    -- A fresh sibling also keeps the old file intact if copying fails.
    local name = os.tmpname()
    if lfs.symlinkattributes(name) then assert(os.remove(name)) end
    local staging = assert(parent(destination)) .. "/.titan-install-" ..
        assert(name:match("([^/\\]+)$"))
    assert(lfs.mkdir(staging))
    local staged = staging .. "/payload"
    local guard <close> = setmetatable({}, { __close = function()
        os.remove(staged)
        lfs.rmdir(staging)
    end })
    do
        local input <close> = assert(io.open(source, "rb"))
        local output <close> = assert(io.open(staged, "wb"))
        while true do
            local bytes, read_error = input:read(65536)
            assert(not read_error, read_error)
            if not bytes then break end
            assert(output:write(bytes))
        end
        assert(output:flush())
    end
    if not windows then
        assert(execute({ "chmod", executable and "0755" or "0644", staged }))
    end
    assert(lfs.touch(staged, attributes.access, attributes.modification))
    -- The Windows C rename API cannot replace an existing file. A loaded DLL
    -- refuses removal here; report that failure without rewriting its bytes.
    if windows and existing then assert(os.remove(destination)) end
    assert(os.rename(staged, destination))
end

local lua_headers = {
    ["include/lua.h"] = true, ["include/luaconf.h"] = true,
    ["include/lauxlib.h"] = true, ["include/lualib.h"] = true,
    ["include/lua.hpp"] = true,
}

local function lua_owned(relative, common_prefix)
    local name = windows and relative:lower() or relative
    if name == "bin/lua55.dll" then return true end
    return common_prefix and (name:match("^src/lua%-5[.]5[.]1/") or
        name == "lib/liblua.a" or name == "lib/liblua55.a" or lua_headers[name])
end

local function prepare_windows_cleanup_launcher(destination)
    if not windows then return end
    local relative = "bin/titan-uninstall.bat"
    contained(destination, relative)
    local path = destination .. "/" .. relative
    local mode = lfs.symlinkattributes(path, "mode")
    if not mode then return end
    assert(mode == "file", "cleanup launcher is not an ordinary file: " .. path)
    local contents
    do
        local input <close> = assert(io.open(path, "rb"))
        contents = assert(input:read("*a")):gsub("\r\n", "\n")
    end
    if contents:match("\n%(goto%) 2>nul & [^\n]+ %%%*\n?$") then return end
    local header, invocation = contents:match(
        "^(.*\n)([^\n]+)\nexit /b %%ERRORLEVEL%%\n?$")
    assert(header and invocation, "unsupported LuaRocks cleanup launcher: " .. path)
    -- Retire CMD's batch context before LuaRocks deletes this launcher. Keeping
    -- just the exit on the invocation line still makes CMD reopen the deleted
    -- batch file. Return naturally with Lua's status so a parent batch CALL
    -- continues after this launcher. Retain LuaRocks' Lua paths and context.
    local output <close> = assert(io.open(path, "wb"))
    assert(output:write((header .. "(goto) 2>nul & " .. invocation ..
        "\n"):gsub("\n", "\r\n")))
end

-- LuaRocks' Windows deployment of a bin `.exe` also writes an unrecorded
-- `<name>.lua` package-path helper beside it, so bin/titanc.exe gains a
-- bin/titanc.lua that `luarocks remove` would leave behind. titanc.exe never
-- reads it (its script is the rock's titan-compiler/titanc.lua). Remove
-- exactly that generated two-line helper, and nothing else of that name.
local function retire_windows_exe_helper(destination)
    if not windows then return end
    local relative = "bin/titanc.lua"
    contained(destination, relative)
    local path = destination .. "/" .. relative
    if lfs.symlinkattributes(path, "mode") ~= "file" then return end
    local contents
    do
        local input <close> = assert(io.open(path, "rb"))
        contents = assert(input:read("*a")):gsub("\r\n", "\n")
    end
    if contents:match('^package%.path="[^\n]*"%.%.package%.path\n' ..
            'package%.cpath="[^\n]*"%.%.package%.cpath\n$') then
        assert(os.remove(path))
    end
end

local function titan_owned(relative)
    local library = relative:match("^lib/titan/%d+[.]%d+/(.+)$")
    return library == "libtitan.a" or library == "titan.a" or
        library == "titan.so" or library == "titan.dll" or
        (library and library:match("^titan[.]so[.]dSYM/")) or
        relative == "include/titan.h" or relative == "include/minicoro.h" or
        relative == "include/transfer.h" or
        relative == "include/titan/ffi.h" or relative == "include/titan/browser.h" or
        relative:match("^share/titan/") or relative == "etc/titan/build-profile"
end

-- The Lua archive driver.installed_paths links for this platform.
local sdk_lua_archive = windows and "lib/liblua55.a" or "lib/liblua.a"

-- The approved SDK native link inputs, and nothing else: the Titan-owned
-- provider and runtime archive directly in the library version directory,
-- the copied libbacktrace archive and the selected Lua archive. A shared Lua
-- prefix keeps its own archive; it is recorded without being copied,
-- replaced or taken into cleanup ownership. Preserved or foreign files, even
-- inside the version directory, are never recorded.
local function sdk_link_inputs(destination, inventory, common_prefix)
    local release, inputs = nil, {}
    for _, relative in ipairs(inventory) do
        local directory = relative:match("^lib/titan/(%d+[.]%d+)/[^/]+$")
        if directory and titan_owned(relative) then
            assert(release == nil or release == directory,
                "SDK payload has several Titan library versions")
            release = directory
            inputs[#inputs + 1] = relative
        elseif (relative == "lib/libbacktrace.a" or relative == sdk_lua_archive) and
           not lua_owned(relative, common_prefix) then
            inputs[#inputs + 1] = relative
        end
    end
    if common_prefix and lfs.attributes(destination .. "/" .. sdk_lua_archive, "mode") == "file" then
        inputs[#inputs + 1] = sdk_lua_archive
    end
    return release, inputs
end

-- Record content digests with precise observations for titanc, which reuses
-- them only while every observation is unchanged. The `titan` support module
-- that LuaRocks just deployed to lib/lua/5.5 supplies the digest and precise
-- stat; the compiler owns the format. A payload without a loadable compiler
-- and support module (installer fixtures) records nothing, and titanc then
-- reads and hashes these inputs as usual.
local function publish_sdk_digests(destination, inventory, common_prefix)
    local release, inputs = sdk_link_inputs(destination, inventory, common_prefix)
    if not release then return nil end
    local compiler, incremental = pcall(require, "titan-compiler.incremental")
    if not compiler then return nil end
    local relative = "lib/titan/" .. release .. "/" .. incremental.SDK_DIGESTS
    local manifest = destination .. "/" .. relative
    if lfs.symlinkattributes(manifest, "mode") then assert(os.remove(manifest)) end
    local search = package.cpath
    package.cpath = destination .. "/lib/lua/5.5/?." .. (windows and "dll" or "so")
    local loaded, support = pcall(require, "titan")
    package.cpath = search
    if not loaded or type(support) ~= "table" or type(support._sha256_binary) ~= "function" or
       type(support._stat_precise) ~= "function" then
        return nil
    end
    local compiler_io = require "titan-compiler.io"
    local context = { io = compiler_io.new_sync(),
        cache_adapter = { sha256_binary = support._sha256_binary,
            sha256_stream = support._sha256_stream } }
    local paths = {}
    for _, path in ipairs(inputs) do paths[#paths + 1] = destination .. "/" .. path end
    assert(incremental.write_sdk_digests(context, manifest, paths))
    return relative
end

function installer.publish(package_dir, destination, lua_prefix, program)
    assert(package_dir and destination and lua_prefix and program,
        "publish requires package directory, tree, Lua prefix and LuaRocks program")
    package_dir = physical(package_dir)
    mkdir(destination)
    destination, lua_prefix = physical(destination), physical(lua_prefix)
    local common_prefix = same(destination, lua_prefix)
    assert(not windows or common_prefix,
        "the Windows Titan rock requires the Lua SDK prefix as its installation tree")
    local payload = package_dir .. "/titan-sdk"
    local inventory = files(payload)
    for _, relative in ipairs(inventory) do
        assert(relative:match("^[^/]+/") and
            ({ include = true, lib = true, share = true, etc = true,
                src = true, bin = true })[relative:match("^([^/]+)/")],
            "unexpected SDK payload path: " .. relative)
        if not lua_owned(relative, common_prefix) then contained(destination, relative) end
    end
    if not windows then
        for _, relative in ipairs({ "include/openssl", "include/titan_longjmp.h",
            "lib/libtitan.a", "lib/libuv.a" }) do contained(destination, relative) end
        local mode_file = io.open(package_dir .. "/installer/openssl-mode", "rb")
        if mode_file then
            local mode = mode_file:read("*a"):match("^%s*(.-)%s*$")
            assert(mode_file:close())
            if mode == "system" then remove_tree(destination .. "/include/openssl") end
        end
        for _, obsolete in ipairs({
            "include/titan_longjmp.h", "lib/libtitan.a", "lib/libuv.a",
        }) do
            if lfs.symlinkattributes(destination .. "/" .. obsolete) then
                assert(os.remove(destination .. "/" .. obsolete))
            end
        end
    end
    for _, relative in ipairs(inventory) do
        if not lua_owned(relative, common_prefix) then
            copy(payload .. "/" .. relative, destination .. "/" .. relative,
                relative:match("^bin/") or relative:match("^lib/titan/[^/]+/titan[.]so$") or
                relative:match("[.]dll$"))
        end
    end
    local digests = publish_sdk_digests(destination, inventory, common_prefix)
    mkdir(package_dir .. "/installer")
    local location <close> = assert(io.open(package_dir .. "/installer/location.lua", "wb"))
    assert(location:write(string.format(
        "return { tree = %q, lua_dir = %q, luarocks = %q, digests = %s }\n",
        destination, lua_prefix, program, digests and string.format("%q", digests) or "nil")))
    prepare_windows_cleanup_launcher(destination)
    retire_windows_exe_helper(destination)
    return true
end

-- The one recorded cleanup path uninstall accepts beyond the payload's
-- Titan-owned files: the manifest publish_sdk_digests wrote for a Titan
-- library version (incremental.SDK_DIGESTS). Any other name, including an
-- unrelated in-prefix file or a dot or backslash traversal, is ignored.
local function sdk_digests_path(relative)
    return type(relative) == "string" and
        relative:match("^lib/titan/%d+[.]%d+/sdk%-digests$") ~= nil
end

local browser_sdk_owned = {
    "libtitan.a",
    "libtitan-lpeglabel.a",
    "titan.a",
    "titan-browser.mjs",
    "titan-browser-library.js",
    "titan-browser-bridge.js",
    "titan-browser-trace.js",
    "titan-browser-run",
    "titan-browser-run.mjs",
    "titan-browser-node-worker.mjs",
    "titan-browser-page.mjs",
    "sdk-digests",
}

function installer.uninstall(package_dir, program)
    package_dir = physical(package_dir)
    local location = assert(loadfile(package_dir .. "/installer/location.lua", "t", {}))()
    local destination = physical(assert(location.tree))
    local inventory, releases = {}, {}
    -- Capture every matching version's inventory while LuaRocks still owns it.
    -- The running helper and lfs are already loaded before those files disappear.
    local versions = assert(parent(package_dir))
    for version in lfs.dir(versions) do
        if version ~= "." and version ~= ".." then
            local candidate = versions .. "/" .. version
            local configuration = candidate .. "/installer/location.lua"
            if lfs.attributes(configuration, "mode") == "file" then
                local installed = assert(loadfile(configuration, "t", {}))()
                if lfs.attributes(assert(installed.tree), "mode") == "directory" and
                   same(installed.tree, destination) then
                    local release = version:match("^(%d+[.]%d+)[.]")
                    if release then releases[release] = true end
                    for _, relative in ipairs(files(candidate .. "/titan-sdk")) do
                        if titan_owned(relative) then
                            inventory[relative] = true
                            local sdk_release = relative:match("^lib/titan/(%d+[.]%d+)/")
                            if sdk_release then releases[sdk_release] = true end
                        end
                    end
                    if sdk_digests_path(installed.digests) then inventory[installed.digests] = true end
                end
            end
        end
    end
    for release in pairs(releases) do
        for _, name in ipairs(browser_sdk_owned) do
            inventory["lib/titan-browser/" .. release .. "/" .. name] = true
        end
    end
    for relative in pairs(inventory) do
        contained(destination, relative)
        local mode = lfs.symlinkattributes(destination .. "/" .. relative, "mode")
        assert(mode == nil or mode == "file" or mode == "link",
            "cleanup destination is not a file: " .. destination .. "/" .. relative)
    end
    if not program then
        program = assert(location.luarocks)
        if lfs.attributes(program, "mode") ~= "file" then
            program = windows and "luarocks.exe" or "luarocks"
        end
    end
    local removed, why, status = execute({ program,
        "--lua-version", "5.5", "--lua-dir", assert(location.lua_dir),
        "--tree", destination, "remove", "titan" })
    if removed ~= true and removed ~= 0 then
        return nil, "LuaRocks removal failed (" .. tostring(why) .. " " ..
            tostring(status) .. "); Titan SDK files were preserved"
    end
    local directories = {}
    for relative in pairs(inventory) do
        local path = destination .. "/" .. relative
        local mode = lfs.symlinkattributes(path, "mode")
        if mode then
            assert(mode == "file" or mode == "link",
                "cleanup destination is not a file: " .. path)
            local deleted, message = os.remove(path)
            if not deleted then
                return nil, "LuaRocks removed Titan, but cleanup could not remove " .. path ..
                    ": " .. tostring(message) .. ". Close programs using Titan, reinstall " ..
                    "the rock to restore its cleanup command, then run titan-uninstall again."
            end
        end
        local directory = parent(path)
        while directory and directory ~= destination do
            directories[directory] = true
            directory = parent(directory)
        end
    end
    local ordered = {}
    for directory in pairs(directories) do ordered[#ordered + 1] = directory end
    table.sort(ordered, function(left, right) return #left > #right end)
    for _, directory in ipairs(ordered) do
        if lfs.symlinkattributes(directory, "mode") == "directory" then
            lfs.rmdir(directory) -- Shared directories are pruned only if empty.
        end
    end
    return true
end

if command then
    assert(command == "publish", "usage: titan_install.lua publish PACKAGE TREE LUA_PREFIX LUAROCKS")
    installer.publish(private, tree, lua_dir, luarocks)
end
return installer

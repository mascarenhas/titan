local command, private, tree, lua_dir, luarocks = ...
local windows = package.config:sub(1, 1) == "\\"

-- Dependencies can live in a selected rock tree separate from the Lua prefix.
local dependencies = command == "publish" and tree or command == "uninstall-browser-sdk" and private
if dependencies then
    package.path = dependencies .. "/share/lua/5.5/?.lua;" ..
        dependencies .. "/share/lua/5.5/?/init.lua;" .. package.path
    package.cpath = dependencies .. "/lib/lua/5.5/?." ..
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

local function installation(package_dir)
    package_dir = physical(package_dir)
    local location = assert(loadfile(package_dir .. "/installer/location.lua", "t", {}))()
    return package_dir, physical(assert(location.tree)), location
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

local function execute(argv, stdout)
    local words = {}
    for _, word in ipairs(argv) do words[#words + 1] = quote(word) end
    local line = table.concat(words, " ")
    if stdout then line = line .. " > " .. quote(stdout) end
    if windows then line = "type NUL && " .. line end
    return os.execute(line)
end

local function luarocks_command(location, destination, program, ...)
    if not program then
        program = assert(location.luarocks)
        if lfs.attributes(program, "mode") ~= "file" then
            program = windows and "luarocks.exe" or "luarocks"
        end
    end
    return { program, "--lua-version", "5.5", "--lua-dir", assert(location.lua_dir),
        "--tree", destination, ... }
end

local function prune(destination, paths)
    local directories, ordered = {}, {}
    for _, relative in ipairs(paths) do
        local directory = parent(relative)
        while directory and not directories[directory] do
            directories[directory] = true
            ordered[#ordered + 1] = directory
            directory = parent(directory)
        end
    end
    table.sort(ordered, function(left, right) return #left > #right end)
    for _, directory in ipairs(ordered) do
        local path = destination .. "/" .. directory
        if lfs.symlinkattributes(path, "mode") == "directory" then
            lfs.rmdir(path) -- Shared directories are pruned only if empty.
        end
    end
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

-- Every file `make browser-sdk` writes in lib/titan-browser/<release>;
-- spec/browser_sdk_spec.lua checks a fresh SDK build against this list.
-- Uninstall removes them and keeps any other file there, such as an
-- application archive.
installer.browser_sdk_owned = {
    "libtitan.a",
    "libtitan-lpeglabel.a",
    "titan.a",
    "titan-browser.mjs",
    "titan-protobuf.mjs",
    "titan-wasm-factory.mjs",
    "titan-browser-run",
    "titan-browser-run.mjs",
    "titan-browser-node-worker.mjs",
    "titan-browser-page.mjs",
    "titan-browser-vfs.mjs",
    "titan-browser-sql.mjs",
    "titan-storage-worker.mjs",
    "titan-sqlite3-service.wasm",
    "build-profile",
    "absent-modules",
    "analysis-target",
    "sdk-digests",
}

function installer.uninstall(package_dir, program)
    local destination, location
    package_dir, destination, location = installation(package_dir)
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
        for _, name in ipairs(installer.browser_sdk_owned) do
            inventory["lib/titan-browser/" .. release .. "/" .. name] = true
        end
    end
    for relative in pairs(inventory) do
        contained(destination, relative)
        local mode = lfs.symlinkattributes(destination .. "/" .. relative, "mode")
        assert(mode == nil or mode == "file" or mode == "link",
            "cleanup destination is not a file: " .. destination .. "/" .. relative)
    end
    local removed, why, status = execute(luarocks_command(location, destination, program, "remove", "titan"))
    if removed ~= true and removed ~= 0 then
        return nil, "LuaRocks removal failed (" .. tostring(why) .. " " ..
            tostring(status) .. "); Titan SDK files were preserved"
    end
    local paths = {}
    for relative in pairs(inventory) do
        paths[#paths + 1] = relative
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
    end
    prune(destination, paths)
    return true
end

local rocks_directory = "lib/luarocks/rocks-5.5"
local module_inventory = "lib/titan/.module-rocks"
local module_marker = "titan-module-published"

local function fold(name)
    return (name:gsub("[A-Z]", string.lower))
end

local function portable_component(name)
    -- Win32 also aliases device basenames before the first extension.
    local stem = fold(name:match("^[^.]*")):gsub(" +$", "")
    return name ~= "" and not name:find('[^ -~]') and
        not name:find('[<>:"/\\|?*]') and not name:find("[ .]$") and
        not stem:find("~%d+$") and stem ~= "con" and stem ~= "prn" and
        stem ~= "aux" and stem ~= "nul" and stem ~= "conin$" and stem ~= "conout$" and
        not stem:match("^com%d$") and not stem:match("^lpt%d$")
end

local function rock_name(name)
    assert(type(name) == "string" and name:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") and
        portable_component(name), "invalid rock name: " .. tostring(name))
    name = fold(name)
    assert(name ~= "titan", "the Titan rock is reserved; expected a Titan module rock name")
    assert(not name:match("%.rock$") and not name:match("%.rockspec$"),
        "expected a rock name, not a rock filename: " .. name)
    return name
end

local function rock_version(version)
    assert(type(version) == "string" and version:match("^[A-Za-z0-9][A-Za-z0-9_.-]*%-%d+$") and
        portable_component(version), "expected an exact LuaRocks version (including revision): " ..
        tostring(version))
    return version
end

-- Includes targets the SDK may create or retire even when absent from this
-- installation (e.g. bundled OpenSSL headers and Windows import libraries).
local reserved = {
    ["include/titan"] = true, ["include/openssl"] = true, ["include/uv"] = true,
    ["include/uv.h"] = true,
    ["include/llhttp.h"] = true, ["include/sqlite3.h"] = true,
    ["include/backtrace.h"] = true, ["include/backtrace-supported.h"] = true,
    ["include/titan_longjmp.h"] = true,
    ["lib/libbacktrace.a"] = true, ["lib/libtitan.a"] = true, ["lib/libuv.a"] = true,
    ["lib/libuv.dll.a"] = true, ["lib/libllhttp.dll.a"] = true, ["lib/libsqlite3.dll.a"] = true,
    ["lib/libcrypto.dll.a"] = true, ["lib/libssl.dll.a"] = true,
    ["lib/browser"] = true, ["lib/lua"] = true, ["lib/luarocks"] = true,
    ["lib/titan"] = true, ["lib/titan-browser"] = true,
}

local function module_path(relative)
    for part in (relative .. "/"):gmatch("([^/]*)/") do
        assert(portable_component(part), "invalid module payload path: " .. relative)
    end
    local key = fold(relative)
    local modules = key:match("^lib/titan/%d+[.]%d+/(.+)$")
    local base = modules and modules:match("^[^/]+") or key:match("^[^/]+/[^/]+")
    assert(base and (modules or key:match("^include/") or key:match("^lib/")),
        "invalid module destination: " .. relative)
    if modules then
        local root = key:sub(1, #key - #modules) .. base
        assert(not titan_owned(root) and not sdk_digests_path(root) and
            base ~= "titan.so.dsym" and base ~= "_titan_browser" and base ~= "titan" and
            base ~= "titan.titan", "reserved SDK path: " .. relative)
    else
        local path = key
        while path and path:find("/", 1, true) do
            assert(not reserved[path] and not titan_owned(path) and not lua_owned(path, true),
                "reserved SDK path: " .. relative)
            path = parent(path)
        end
    end
end

local function lstat(uv, path)
    local stat, err, code = uv.fs_lstat(path)
    assert(stat or code == "ENOENT", err)
    return stat
end

local function regular(stat)
    return stat and stat.type == "file" and stat.nlink == 1
end

local function scan(uv, path)
    local request = assert(uv.fs_scandir(path))
    return function() return uv.fs_scandir_next(request) end
end

-- Check each spelling against directory entries as well as lstat. Lookup
-- alone cannot distinguish a case alias on case-insensitive filesystems, or
-- see a differently cased sibling on case-sensitive ones.
local function inspect_paths(uv, root)
    local entries = {}
    return function(relative, kind)
        local path = root
        local rest = relative
        for part in relative:gmatch("[^/]+") do
            local children = entries[path]
            if not children then
                children = {}
                for name in scan(uv, path) do
                    local key = fold(name)
                    children[key] = children[key] == nil and name or false
                end
                entries[path] = children
            end
            path = path .. "/" .. part
            local name = children[fold(part)]
            local stat = lstat(uv, path)
            assert(name == part or (name == nil and not stat), "path alias at " .. path)
            if not stat then return false end
            local last = rest == part
            local expected = last and kind or "directory"
            assert((expected == "file" and regular(stat)) or
                (expected == "directory" and stat.type == "directory"),
                "not an ordinary " .. expected .. ": " .. path)
            if last then return true end
            rest = rest:sub(#part + 2)
        end
    end
end

-- A plain text ownership record is retained independently of the rock. While
-- replacing a projection, it reserves the old and new paths so that a failed
-- copy/deletion or LuaRocks hook rollback cannot strand unowned files.
local function read_record(path)
    local input <close> = assert(io.open(path, "rb"))
    local active, pending = input:read("l", "l")
    assert(active and pending and (active ~= "" or pending ~= ""),
        "invalid module inventory: " .. path)
    local record = {
        active = active ~= "" and rock_version(active) or nil,
        pending = pending ~= "" and rock_version(pending) or nil,
        paths = {},
    }
    for relative in input:lines() do record.paths[#record.paths + 1] = relative end
    return record
end

local function write_atomic(uv, path, data)
    local fd, temporary = uv.fs_mkstemp(path .. ".tmp-XXXXXX")
    assert(fd, temporary)
    local guard <close> = setmetatable({}, { __close = function()
        if fd then uv.fs_close(fd) end
        uv.fs_unlink(temporary)
    end })
    assert(uv.fs_write(fd, data, 0) == #data, "cannot write " .. path)
    assert(uv.fs_close(fd))
    fd = nil
    assert(uv.fs_rename(temporary, path))
end

local function write_record(uv, path, active, pending, paths)
    write_atomic(uv, path, active .. "\n" .. pending .. "\n" ..
        table.concat(paths, "\n") .. "\n")
end

local function index_files(index, rock, paths)
    for _, relative in ipairs(paths) do
        module_path(relative)
        local path, owner = relative, rock
        while path do
            local key = fold(path)
            local entry = index[key]
            assert(not entry or (entry.path == path and entry.owner == owner),
                "module path conflicts with " .. (entry and entry.path or "") ..
                (entry and entry.owner and " owned by " .. entry.owner or "") .. ": " .. relative)
            if entry and not owner then break end
            if not entry then index[key] = { path = path, owner = owner } end
            path, owner = parent(path), nil
        end
    end
end

local function module_context(package_dir)
    local destination, location
    package_dir, destination, location = installation(package_dir)
    local release = assert(package_dir:match("/titan/(%d+[.]%d+)[.][^/]+$"),
        "cannot locate the installed Titan library release")
    local uv = require "luv"
    local inspect = inspect_paths(uv, destination)
    local rocks = destination .. "/" .. rocks_directory
    assert(inspect(rocks_directory, "directory"), "cannot locate the LuaRocks installation tree")
    assert(same(assert(parent(parent(package_dir))), rocks),
        "Titan's launcher does not belong to the recorded LuaRocks tree")
    return {
        destination = destination, location = location, release = release, uv = uv,
        inspect = inspect, inventory = destination .. "/" .. module_inventory,
    }
end

local function inventory(ctx)
    local records, index = {}, {}
    if ctx.inspect(module_inventory, "directory") then
        for name in scan(ctx.uv, ctx.inventory) do
            local rock = fold(name):match("^(.*)%.paths$")
            if rock then
                assert(rock_name(rock) .. ".paths" == name, "invalid module inventory name: " .. name)
                assert(ctx.inspect(module_inventory .. "/" .. name, "file"))
                local record = read_record(ctx.inventory .. "/" .. name)
                index_files(index, rock, record.paths)
                records[rock] = record
            end
        end
    end
    return records, index
end

local function staged_files(uv, root, release)
    local paths, sources = {}, {}
    local function walk(source, destination)
        for name in scan(uv, source) do
            assert(portable_component(name), "invalid module payload path: " .. source .. "/" .. name)
            local from, to = source .. "/" .. name, destination .. "/" .. name
            assert(destination ~= "lib" or not reserved["lib/" .. fold(name)],
                "reserved SDK path: " .. to)
            local stat = lstat(uv, from)
            if stat and stat.type == "directory" then
                walk(from, to)
            else
                assert(regular(stat), "module payload is not an ordinary file: " .. from)
                paths[#paths + 1], sources[to] = to, from
            end
        end
    end
    local roots = { include = "include", lib = "lib", modules = "lib/titan/" .. release }
    for name in scan(uv, root) do
        local source, destination = root .. "/" .. name, roots[name]
        assert(destination, "unexpected module staging directory: " .. source)
        assert(lstat(uv, source).type == "directory", "not an ordinary directory: " .. source)
        walk(source, destination)
    end
    assert(#paths > 0, "no files to publish under " .. root)
    table.sort(paths)
    return paths, sources
end

local function preflight(ctx, rock, index, paths)
    for _, relative in ipairs(paths) do
        if ctx.inspect(relative, "file") then
            local owner = index[fold(relative)]
            assert(owner and owner.path == relative and owner.owner == rock,
                "module destination already exists: " .. ctx.destination .. "/" .. relative)
        end
    end
end

local function cleanup_files(ctx, paths)
    for _, relative in ipairs(paths) do
        local path = ctx.destination .. "/" .. relative
        local ok, err, code = ctx.uv.fs_unlink(path)
        assert(ok or code == "ENOENT", "cannot remove " .. path .. ": " .. tostring(err))
    end
    prune(ctx.destination, paths)
end

function installer.publish_module(package_dir, private_rock)
    local ctx = module_context(package_dir)
    private_rock = slash(private_rock)
    local absolute = windows and (private_rock:match("^[A-Za-z]:/") or
        private_rock:match("^//[^/]")) or not windows and private_rock:sub(1, 1) == "/"
    local tree, name, version = private_rock:match("^(.*)/lib/luarocks/rocks%-5%.5/([^/]+)/([^/]+)$")
    if tree == "" or (windows and tree and tree:match("^[A-Za-z]:$")) then
        tree = tree .. "/"
    end
    assert(absolute and tree and same(tree, ctx.destination),
        "--path must name a LuaRocks 5.5 rock version directory in this Titan installation tree")
    local rock = rock_name(name)
    assert(rock == name, "--path must use the installed rock name")
    rock_version(version)
    local relative = rocks_directory .. "/" .. rock .. "/" .. version
    assert(ctx.inspect(relative .. "/rock_manifest", "file"), "--path does not name an installed rock")
    assert(ctx.inspect(relative .. "/dist", "directory"), "missing module staging directory: " .. private_rock .. "/dist")
    local private = ctx.destination .. "/" .. relative
    local paths, sources = staged_files(ctx.uv, private .. "/dist", ctx.release)
    local records, index = inventory(ctx)
    local previous = records[rock]
    preflight(ctx, rock, index, paths)
    index_files(index, rock, paths)
    local combined, stale = {}, {}
    for _, path in ipairs(paths) do combined[#combined + 1] = path end
    if previous then
        preflight(ctx, rock, index, previous.paths)
        for _, path in ipairs(previous.paths) do
            if not sources[path] then
                combined[#combined + 1] = path
                stale[#stale + 1] = path
            end
        end
    end
    ctx.inspect(relative .. "/" .. module_marker, "file")
    local record = ctx.inventory .. "/" .. rock .. ".paths"
    -- Existing records were checked while loading the inventory. For a new
    -- name, also reject platform aliases not listed under the exact spelling.
    if not previous then ctx.inspect(module_inventory .. "/" .. rock .. ".paths", "file") end
    mkdir(ctx.inventory)
    write_record(ctx.uv, record, previous and previous.active or "", version, combined)
    for _, path in ipairs(paths) do
        copy(sources[path], ctx.destination .. "/" .. path, path:match("[.]so$"))
    end
    cleanup_files(ctx, stale)
    write_atomic(ctx.uv, private .. "/" .. module_marker, rock .. " " .. version .. "\n")
    write_record(ctx.uv, record, version, "", paths)
    return true
end

local function expect_exact_version(ctx, rock, version)
    -- LuaRocks compares parsed versions, not their spelling (e.g. 1.01
    -- and 1.1). Ask the same executable which versions its remove would
    -- match. This also works with standalone LuaRocks on Windows.
    local uv = ctx.uv
    local fd, temporary = uv.fs_mkstemp(assert(uv.os_tmpdir()) .. "/titan-rock-list-XXXXXX")
    assert(fd, temporary)
    local guard <close> = setmetatable({}, { __close = function() uv.fs_unlink(temporary) end })
    assert(uv.fs_close(fd))
    local listed = execute(luarocks_command(ctx.location, ctx.destination, nil,
        "list", "--porcelain", rock, version), temporary)
    assert(listed, "could not list installed LuaRocks versions")
    local exact = false
    for line in io.lines(temporary) do
        local name, listed_version = line:match("^([^\t]+)\t([^\t]+)\t")
        if name == rock then
            assert(listed_version == version,
                "LuaRocks cannot remove " .. version .. " without also matching " .. listed_version)
            exact = true
        end
    end
    assert(exact, "LuaRocks could not find the installed version of " .. rock .. ": " .. version)
end

function installer.uninstall_module(package_dir, name, version)
    local rock = rock_name(name)
    if version then rock_version(version) end
    local ctx = module_context(package_dir)
    local records, index = inventory(ctx)
    local record = records[rock]
    local active = record and (record.active or record.pending)
    version = version or active
    if not version then
        assert(not ctx.inspect(rocks_directory .. "/" .. rock, "directory"),
            "no active Titan module publication for " .. rock)
        return true, "No published files to remove for " .. rock .. "."
    end
    local relative = rocks_directory .. "/" .. rock .. "/" .. version
    local installed = ctx.inspect(relative, "directory")
    if installed then
        local marker = relative .. "/" .. module_marker
        assert(ctx.inspect(marker, "file"),
            "not a published Titan module rock: " .. rock .. " " .. version)
        local input <close> = assert(io.open(ctx.destination .. "/" .. marker, "rb"))
        assert(input:read("a") == rock .. " " .. version .. "\n",
            "not a published Titan module rock: " .. rock .. " " .. version)
    end
    if version == active then preflight(ctx, rock, index, record.paths) end
    if installed then
        expect_exact_version(ctx, rock, version)
        local removed, why, status = execute(luarocks_command(ctx.location, ctx.destination,
            nil, "remove", rock, version))
        if removed ~= true and removed ~= 0 then
            return nil, "LuaRocks removal failed (" .. tostring(why) .. " " ..
                tostring(status) .. "); Titan module files were preserved"
        end
    end
    if version == active then
        cleanup_files(ctx, record.paths)
        assert(ctx.uv.fs_unlink(ctx.inventory .. "/" .. rock .. ".paths"))
        lfs.rmdir(ctx.inventory)
        return true, "Cleaned published files for " .. rock .. " " .. version .. "."
    end
    if installed then return true, "Removed " .. rock .. " " .. version .. "." end
    return true, "Nothing to remove for " .. rock .. " " .. version .. "."
end

-- `make uninstall-browser-sdk`: removes one release's browser SDK files from
-- `tree` and keeps every other file there, such as an application archive.
-- The directory goes only when nothing else is left in it.
function installer.uninstall_browser_sdk(sdk_tree, release)
    assert(type(release) == "string" and release:match("^%d+[.]%d+$"),
        "usage: titan_install.lua uninstall-browser-sdk TREE RELEASE")
    local destination = physical(sdk_tree)
    local relative = "lib/titan-browser/" .. release
    local paths = {}
    local function append(asset)
        contained(destination, asset)
        paths[#paths + 1] = destination .. "/" .. asset
    end
    for _, name in ipairs(installer.browser_sdk_owned) do append(relative .. "/" .. name) end
    local windows_provider = windows and "lib/titan/" .. release .. "/_titan_browser"
    if windows_provider then
        append("bin/titan-browser-job.exe")
        append(windows_provider .. "/windows_job.dll")
    end
    for _, path in ipairs(paths) do
        local mode = lfs.symlinkattributes(path, "mode")
        if mode ~= nil and mode ~= "file" and mode ~= "link" then
            return nil, "browser SDK file is not a file: " .. path
        end
    end
    for _, path in ipairs(paths) do
        if lfs.symlinkattributes(path, "mode") then
            local deleted, message = os.remove(path)
            if not deleted then return nil, "cannot remove " .. path .. ": " .. tostring(message) end
        end
    end
    if windows_provider then lfs.rmdir(destination .. "/" .. windows_provider) end
    lfs.rmdir(destination .. "/" .. relative)
    lfs.rmdir(destination .. "/lib/titan-browser")
    return true
end

if command == "uninstall-browser-sdk" then
    local removed, err = installer.uninstall_browser_sdk(private, tree)
    if not removed then
        io.stderr:write(err, "\n")
        os.exit(1)
    end
elseif command then
    assert(command == "publish", "usage: titan_install.lua publish PACKAGE TREE LUA_PREFIX LUAROCKS")
    installer.publish(private, tree, lua_dir, luarocks)
end
return installer

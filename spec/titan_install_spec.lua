local assert = require "luassert"
local lfs = require "lfs"
local temporary = require "spec.support.temporary"

local function directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then directory(parent) end
    assert(lfs.mkdir(path))
end

local function write(path, value)
    directory(assert(path:match("^(.*)/[^/]+$")))
    local file <close> = assert(io.open(path, "wb"))
    assert(file:write(value))
end

local function read(path)
    local file <close> = assert(io.open(path, "rb"))
    return file:read("*a")
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

describe("retained Titan SDK installation", function()
    local workspace, installer, execute, remove

    before_each(function()
        workspace = temporary.name()
        assert(os.remove(workspace))
        directory(workspace)
        local previous = assert(lfs.currentdir())
        assert(lfs.chdir(workspace))
        workspace = assert(lfs.currentdir()):gsub("\\", "/")
        assert(lfs.chdir(previous))
        installer = assert(loadfile("scripts/titan_install.lua"))()
        execute = os.execute
        remove = os.remove
    end)

    after_each(function()
        os.execute = execute
        os.remove = remove
        remove_tree(workspace)
    end)

    it("publishes exact payload files and timestamps while preserving the matching Lua SDK", function()
        local private = workspace .. "/rocks/titan/0.6.0-1"
        local prefix = workspace .. "/SDK 'quoted'"
        local payload = private .. "/titan-sdk"
        write(payload .. "/lib/titan/0.6/titan.so", "built provider")
        write(payload .. "/lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so", "debug symbols")
        write(payload .. "/include/titan.h", "Titan header")
        write(payload .. "/src/lua-5.5.1/lua.h", "packaged Lua")
        write(payload .. "/lib/liblua.a", "packaged Lua archive")
        write(payload .. "/include/lua.h", "packaged public Lua header")
        write(payload .. "/bin/lua55.dll", "packaged Lua DLL")
        for _, name in ipairs({ "src/lua-5.5.1/lua.h", "lib/liblua.a",
            "include/lua.h", "bin/lua55.dll" }) do
            write(prefix .. "/" .. name, "existing Lua owner")
        end
        local built_time = 1000000000 -- Representable by both POSIX and Windows CRT.
        assert(lfs.touch(payload .. "/lib/titan/0.6/titan.so", built_time, built_time))

        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))

        assert.equal("built provider", read(prefix .. "/lib/titan/0.6/titan.so"))
        assert.equal(built_time, lfs.attributes(prefix .. "/lib/titan/0.6/titan.so", "modification"))
        assert.equal("Titan header", read(prefix .. "/include/titan.h"))
        for _, name in ipairs({ "src/lua-5.5.1/lua.h", "lib/liblua.a",
            "include/lua.h", "bin/lua55.dll" }) do
            assert.equal("existing Lua owner", read(prefix .. "/" .. name))
        end
        if package.config:sub(1, 1) ~= "\\" then
            assert.equal("rwxr-xr-x", lfs.attributes(prefix .. "/lib/titan/0.6/titan.so", "permissions"))
            assert.equal("rw-r--r--", lfs.attributes(prefix .. "/include/titan.h", "permissions"))
            assert.equal("rw-r--r--", lfs.attributes(prefix ..
                "/lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so", "permissions"))
        end
        local location = assert(loadfile(private .. "/installer/location.lua"))()
        assert.equal(prefix .. "/bin/luarocks", location.luarocks)
    end)

    -- Loading the provider module first lets publish's require reuse it for
    -- these fixtures' placeholder provider bytes.
    local function digest_context()
        return { io = require("titan-compiler.io").new_sync(),
            cache_adapter = { sha256_binary = require("titan")._sha256_binary } }
    end

    it("records only the approved SDK link inputs, including the shared Lua archive", function()
        local incremental = require "titan-compiler.incremental"
        local sha256 = require "titan-compiler.sha256"
        local private = workspace .. "/rocks/titan/0.6.0-1"
        local prefix = workspace .. "/SDK"
        local payload = private .. "/titan-sdk"
        local lua_archive = package.config:sub(1, 1) == "\\" and "lib/liblua55.a" or "lib/liblua.a"
        local copied = { "lib/titan/0.6/titan.so", "lib/titan/0.6/titan.a",
            "lib/titan/0.6/libtitan.a", "lib/libbacktrace.a" }
        for _, name in ipairs(copied) do write(payload .. "/" .. name, "payload " .. name) end
        -- Copied or preserved payload files outside the approved inventory.
        local excluded = { "lib/titan/0.6/application.a", "lib/libuv.dll.a", "include/titan.h",
            "lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so" }
        for _, name in ipairs(excluded) do write(payload .. "/" .. name, name) end
        write(payload .. "/" .. lua_archive, "packaged Lua archive")
        write(prefix .. "/" .. lua_archive, "existing Lua owner")
        local ctx = digest_context()

        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))

        local location = assert(loadfile(private .. "/installer/location.lua", "t", {}))()
        assert.equal("lib/titan/0.6/sdk-digests", location.digests)
        assert(incremental.load_sdk_digests(ctx, prefix .. "/" .. location.digests))
        local entries = 0
        for _ in pairs(ctx.incremental.sdk.files) do entries = entries + 1 end
        assert.equal(#copied + 1, entries)
        for _, name in ipairs(copied) do
            local digest, bytes = incremental.file_digest(ctx, prefix .. "/" .. name)
            assert.equal(sha256.hex("payload " .. name), digest, name)
            assert.is_nil(bytes)
        end
        -- The shared Lua prefix keeps its own archive, recorded as it is.
        local digest, bytes = incremental.file_digest(ctx, prefix .. "/" .. lua_archive)
        assert.equal(sha256.hex("existing Lua owner"), digest)
        assert.is_nil(bytes)
        local counters = incremental.counters(ctx)
        assert.equal(#copied + 1, counters.sdk_reuses)
        assert.equal(0, counters.file_reads)

        os.execute = function() return true, "exit", 0 end
        assert(installer.uninstall(private))
        assert.is_nil(lfs.symlinkattributes(prefix .. "/" .. location.digests))
        assert.equal("existing Lua owner", read(prefix .. "/" .. lua_archive))
        assert.equal("lib/titan/0.6/application.a", read(prefix .. "/lib/titan/0.6/application.a"))
    end)

    it("records the copied Lua archive of a separate Unix tree", function()
        if package.config:sub(1, 1) == "\\" then
            pending("Windows installations keep the Lua SDK and rock tree together")
            return
        end
        local incremental = require "titan-compiler.incremental"
        local sha256 = require "titan-compiler.sha256"
        local private, lua = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/Lua"
        local separate = workspace .. "/separate tree"
        write(private .. "/titan-sdk/lib/titan/0.6/titan.so", "provider")
        write(private .. "/titan-sdk/lib/liblua.a", "packaged SDK")
        write(lua .. "/lib/liblua.a", "Lua owner")
        local ctx = digest_context()

        assert(installer.publish(private, separate, lua, lua .. "/bin/luarocks"))

        assert(incremental.load_sdk_digests(ctx, separate .. "/lib/titan/0.6/sdk-digests"))
        assert.equal(sha256.hex("packaged SDK"),
            (incremental.file_digest(ctx, separate .. "/lib/liblua.a")))
        assert.equal(1, incremental.counters(ctx).sdk_reuses)
        incremental.file_digest(ctx, lua .. "/lib/liblua.a")
        assert.equal(1, incremental.counters(ctx).sdk_reuses)
        assert.equal("Lua owner", read(lua .. "/lib/liblua.a"))
    end)

    it("removes only a recorded SDK digest manifest and ignores other recorded cleanup paths", function()
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        local outside = workspace .. "/outside/victim"
        write(private .. "/titan-sdk/include/titan.h", "header")
        directory(prefix)
        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))
        local function uninstall_recording(digests)
            write(private .. "/installer/location.lua", string.format(
                "return { tree = %q, lua_dir = %q, luarocks = %q, digests = %q }",
                prefix, prefix, prefix .. "/bin/luarocks", digests))
            assert(installer.uninstall(private))
        end
        os.execute = function() return true, "exit", 0 end
        local backslashed = "lib\\titan\\0.6\\..\\..\\..\\..\\outside\\victim"
        local victims = {
            ["include/unrelated.h"] = prefix .. "/include/unrelated.h",
            ["lib/titan/0.6/application.a"] = prefix .. "/lib/titan/0.6/application.a",
            ["lib/titan/0.6/sdk-digests/../../../../outside/victim"] = outside,
            ["../outside/victim"] = outside,
            -- A traversal on Windows, an unrelated in-prefix name elsewhere.
            [backslashed] = package.config:sub(1, 1) == "\\" and outside or prefix .. "/" .. backslashed,
        }
        for recorded, victim in pairs(victims) do
            write(victim, "foreign")
            uninstall_recording(recorded)
            assert.equal("foreign", read(victim), recorded)
        end
        local manifest = prefix .. "/lib/titan/0.6/sdk-digests"
        write(manifest, "manifest")
        uninstall_recording("lib/titan/0.6/sdk-digests")
        assert.is_nil(lfs.symlinkattributes(manifest))
    end)

    it("rejects Windows backslash traversal before copying SDK files", function()
        if package.config:sub(1, 1) == "\\" then
            pending("native Windows file names cannot contain backslashes")
            return
        end
        local configuration = package.config
        package.config = "\\" .. configuration:sub(2)
        local loaded, windows_installer = pcall(function()
            return assert(loadfile("scripts/titan_install.lua"))()
        end)
        package.config = configuration
        assert.truthy(loaded, windows_installer)
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        write(private .. "/titan-sdk/include/..\\..\\escape.h", "escape")
        directory(prefix)

        local published, message = pcall(windows_installer.publish,
            private, prefix, prefix, prefix .. "/bin/luarocks")

        assert.is_false(published)
        assert.matches("invalid SDK path", message, 1, true)
        assert.is_nil(lfs.symlinkattributes(prefix .. "/include"))
    end)

    it("preserves external files when LuaRocks refuses dependency-breaking removal", function()
        local private = workspace .. "/rocks/titan/0.6.0-1"
        local prefix = workspace .. "/SDK"
        write(private .. "/titan-sdk/lib/titan/0.6/titan.so", "provider")
        directory(prefix)
        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))
        local program = workspace .. "/external tools/luarocks"
        os.execute = function(command)
            assert.truthy(command:find("remove", 1, true))
            assert.falsy(command:find("--force", 1, true))
            assert.truthy(command:find(program, 1, true))
            assert.truthy(command:find("--lua-version", 1, true))
            assert.truthy(command:find("--lua-dir", 1, true))
            return nil, "exit", 1
        end

        local removed, message = installer.uninstall(private, program)

        assert.is_nil(removed)
        assert.matches("SDK files were preserved", message, 1, true)
        assert.equal("provider", read(prefix .. "/lib/titan/0.6/titan.so"))
        assert.equal("directory", lfs.attributes(private, "mode"))
    end)

    it("rejects linked destination parents before publishing or removing the rock", function()
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        local outside = workspace .. "/outside"
        write(private .. "/titan-sdk/include/titan.h", "packaged header")
        write(outside .. "/titan.h", "external owner")
        directory(prefix)
        local linked = lfs.link(outside, prefix .. "/include", true)
        if not linked then
            pending("directory symlink creation is unavailable")
            return
        end
        local published, message = pcall(installer.publish,
            private, prefix, prefix, prefix .. "/bin/luarocks")
        assert.is_false(published)
        assert.matches("parent is not an ordinary directory", message, 1, true)
        assert.equal("external owner", read(outside .. "/titan.h"))

        write(private .. "/installer/location.lua", string.format(
            "return { tree = %q, luarocks = %q }", prefix, prefix .. "/bin/luarocks"))
        os.execute = function() error("LuaRocks must not remove the rock", 0) end
        local removed
        removed, message = pcall(installer.uninstall, private)
        assert.is_false(removed)
        assert.matches("parent is not an ordinary directory", message, 1, true)
        assert.equal("external owner", read(outside .. "/titan.h"))
        assert.equal("directory", lfs.attributes(private, "mode"))
    end)

    it("replaces installed files without changing an already open image", function()
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        write(private .. "/titan-sdk/lib/titan/0.6/titan.so", "replacement")
        write(prefix .. "/lib/titan/0.6/titan.so", "original")
        local image <close> = assert(io.open(prefix .. "/lib/titan/0.6/titan.so", "rb"))
        local published, message = pcall(installer.publish,
            private, prefix, prefix, prefix .. "/bin/luarocks")
        if package.config:sub(1, 1) == "\\" and not published then
            assert.equal("original", read(prefix .. "/lib/titan/0.6/titan.so"))
        else
            assert.truthy(published, message)
            assert.equal("replacement", read(prefix .. "/lib/titan/0.6/titan.so"))
        end
        assert.equal("original", image:read("*a"))
    end)

    it("reports recovery when a native image stays locked after LuaRocks removal", function()
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        local image = prefix .. "/lib/titan/0.6/titan.dll"
        write(private .. "/titan-sdk/lib/titan/0.6/titan.dll", "provider")
        directory(prefix)
        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))
        os.execute = function()
            remove_tree(private)
            return true, "exit", 0
        end
        os.remove = function(path)
            if path == image then return nil, "permission denied" end
            return remove(path)
        end

        local removed, message = installer.uninstall(private)

        assert.is_nil(removed)
        assert.matches("LuaRocks removed Titan", message, 1, true)
        assert.matches(image, message, 1, true)
        assert.matches("reinstall the rock", message, 1, true)
        assert.equal("provider", read(image))
        assert.is_nil(lfs.attributes(private))
    end)

    it("returns the cleanup status from a self-removing Windows batch launcher", function()
        if package.config:sub(1, 1) ~= "\\" then
            pending("native CMD batch retirement")
            return
        end
        local private = workspace .. "/rocks/titan/0.6.0-1"
        local prefix = workspace .. "/SDK with spaces"
        local launcher = prefix .. "/bin/titan-uninstall.bat"
        local entry = prefix .. "/cleanup.lua"
        local lua = require("spec.support.installed_prefix").active() .. "/bin/lua.exe"
        write(private .. "/titan-sdk/include/titan.h", "header")
        write(entry, string.format([[
if arg[1] == "--refuse" then os.exit(1) end
assert(os.remove(%q))
assert(os.remove(arg[0]))
]], launcher))
        write(launcher, '@echo off\r\nsetlocal\r\n"' .. lua:gsub("/", "\\") ..
            '" "' .. entry:gsub("/", "\\") .. '" %*\r\nexit /b %ERRORLEVEL%\r\n')
        assert(installer.publish(private, prefix, prefix, "unused-luarocks.exe"))

        local command = 'type NUL && "' .. launcher:gsub("/", "\\") .. '"'
        local refused, _, status = execute(command .. " --refuse")
        assert.falsy(refused)
        assert.equal(1, status)
        assert.equal("file", lfs.attributes(launcher, "mode"))
        local caller, sentinel = workspace .. "/caller.bat", workspace .. "/caller-status"
        write(caller, '@echo off\r\ncall "' .. launcher:gsub("/", "\\") ..
            '" %*\r\nset "result=%ERRORLEVEL%"\r\n> "' .. sentinel:gsub("/", "\\") ..
            '" echo %result%\r\nexit /b %result%\r\n')
        local call = 'type NUL && "' .. caller:gsub("/", "\\") .. '"'
        refused, _, status = execute(call .. " --refuse")
        assert.falsy(refused)
        assert.equal(1, status)
        assert.equal("1", read(sentinel):match("%S+"))
        local removed, why, code = execute(call)
        assert.truthy(removed, tostring(why) .. " " .. tostring(code))
        assert.equal("0", read(sentinel):match("%S+"))
        assert.equal("file", lfs.attributes(caller, "mode"))
        assert.is_nil(lfs.attributes(launcher))
        assert.is_nil(lfs.attributes(entry))
    end)

    it("removes stale bundled OpenSSL and obsolete Unix SDK paths when publishing system mode", function()
        if package.config:sub(1, 1) == "\\" then
            pending("Windows system OpenSSL retains its copied native SDK")
            return
        end
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        write(private .. "/titan-sdk/include/titan.h", "current header")
        write(private .. "/installer/openssl-mode", "system\n")
        local obsolete = { "include/openssl/ssl.h", "include/titan_longjmp.h",
            "lib/libtitan.a", "lib/libuv.a" }
        for _, name in ipairs(obsolete) do write(prefix .. "/" .. name, "obsolete") end
        write(prefix .. "/include/unrelated.h", "other SDK")

        assert(installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks"))

        for _, name in ipairs(obsolete) do assert.is_nil(lfs.symlinkattributes(prefix .. "/" .. name), name) end
        assert.is_nil(lfs.symlinkattributes(prefix .. "/include/openssl"))
        assert.equal("current header", read(prefix .. "/include/titan.h"))
        assert.equal("other SDK", read(prefix .. "/include/unrelated.h"))
    end)

    it("recognizes a physical Lua prefix alias and copies the SDK only into a separate Unix tree", function()
        if package.config:sub(1, 1) == "\\" then
            pending("Windows installations keep the Lua SDK and rock tree together")
            return
        end
        local private, lua = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/Lua"
        local alias, separate = workspace .. "/Lua alias", workspace .. "/separate tree"
        write(private .. "/titan-sdk/lib/liblua.a", "packaged SDK")
        write(private .. "/titan-sdk/src/lua-5.5.1/lua.h", "packaged internal header")
        write(lua .. "/lib/liblua.a", "Lua owner")
        write(lua .. "/src/lua-5.5.1/lua.h", "Lua owner header")
        assert(lfs.link(lua, alias, true))

        assert(installer.publish(private, alias, lua, lua .. "/bin/luarocks"))
        assert.equal("Lua owner", read(lua .. "/lib/liblua.a"))
        assert.equal("Lua owner header", read(lua .. "/src/lua-5.5.1/lua.h"))

        assert(installer.publish(private, separate, lua, lua .. "/bin/luarocks"))
        assert.equal("packaged SDK", read(separate .. "/lib/liblua.a"))
        assert.equal("packaged internal header", read(separate .. "/src/lua-5.5.1/lua.h"))
        assert.equal("Lua owner", read(lua .. "/lib/liblua.a"))
    end)

    it("rejects a separate Windows tree before copying SDK files", function()
        local configuration = package.config
        package.config = "\\" .. configuration:sub(2)
        local loaded, windows_installer = pcall(function()
            return assert(loadfile("scripts/titan_install.lua"))()
        end)
        package.config = configuration
        assert.truthy(loaded, windows_installer)
        local private, lua = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/Lua"
        local separate = workspace .. "/separate tree"
        write(private .. "/titan-sdk/include/titan.h", "Titan header")
        directory(lua)

        local published, message = pcall(windows_installer.publish,
            private, separate, lua, lua .. "/bin/luarocks")

        assert.is_false(published)
        assert.matches("requires the Lua SDK prefix", message, 1, true)
        assert.is_nil(lfs.symlinkattributes(separate .. "/include/titan.h"))
    end)

    it("retires only LuaRocks' generated package-path helper beside titanc.exe", function()
        local configuration = package.config
        package.config = "\\" .. configuration:sub(2)
        local loaded, windows_installer = pcall(function()
            return assert(loadfile("scripts/titan_install.lua"))()
        end)
        package.config = configuration
        assert.truthy(loaded, windows_installer)
        local private, prefix = workspace .. "/rocks/titan/0.6.0-1", workspace .. "/SDK"
        write(private .. "/titan-sdk/include/titan.h", "Titan header")
        write(prefix .. "/bin/titanc.exe", "native titanc")
        -- LuaRocks' Windows copy_binary writes these two text-mode lines
        -- beside each deployed .exe, and `luarocks remove` never deletes them.
        local helper = prefix .. "/bin/titanc.lua"
        write(helper, 'package.path="C:\\\\SDK\\\\share\\\\lua\\\\5.5\\\\?.lua;"..package.path\r\n' ..
            'package.cpath="C:\\\\SDK\\\\share\\\\lua\\\\5.5\\\\?.lua;"..package.cpath\r\n')

        assert(windows_installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks.exe"))

        assert.is_nil(lfs.symlinkattributes(helper))
        assert.equal("native titanc", read(prefix .. "/bin/titanc.exe"))
        -- Any other file of that name is not LuaRocks' helper and stays.
        write(helper, "return 'user script'\n")
        assert(windows_installer.publish(private, prefix, prefix, prefix .. "/bin/luarocks.exe"))
        assert.equal("return 'user script'\n", read(helper))
    end)

    it("captures every version before removal and cleans only Titan-owned external files", function()
        local versions = workspace .. "/rocks/titan"
        local prefix = workspace .. "/SDK"
        local lua = package.config:sub(1, 1) == "\\" and prefix or workspace .. "/Lua"
        directory(prefix)
        directory(lua)
        local current = versions .. "/0.6.0-1"
        local old = versions .. "/0.5.0-1"
        local preserved = {
            "lib/liblua.a", "src/lua-5.5.1/lua.h", "lib/libbacktrace.a",
            "lib/libuv.dll.a", "include/uv.h", "bin/libuv-1.dll",
            "lib/titan/0.6/application.a",
        }
        for _, name in ipairs(preserved) do
            write(current .. "/titan-sdk/" .. name, name)
            if lua == prefix and (name == "lib/liblua.a" or name:match("^src/")) then
                write(prefix .. "/" .. name, name)
            end
        end
        local browser_lua_preserved = {
            "lib/browser/liblua.a",
            "lib/browser/liblua-config.txt",
            "lib/browser/include/lua.h",
            "lib/titan-browser/0.6/application.a",
        }
        for _, name in ipairs(browser_lua_preserved) do
            write(prefix .. "/" .. name, name)
        end
        local browser_sdk_owned = {
            "lib/titan-browser/0.6/libtitan.a",
            "lib/titan-browser/0.6/libtitan-lpeglabel.a",
            "lib/titan-browser/0.6/titan.a",
            "lib/titan-browser/0.6/titan-browser.mjs",
            "lib/titan-browser/0.6/titan-protobuf.mjs",
            "lib/titan-browser/0.6/titan-browser-library.js",
            "lib/titan-browser/0.6/titan-browser-bridge.js",
            "lib/titan-browser/0.6/titan-browser-trace.js",
            "lib/titan-browser/0.6/titan-browser-run",
            "lib/titan-browser/0.6/titan-browser-run.mjs",
            "lib/titan-browser/0.6/titan-browser-node-worker.mjs",
            "lib/titan-browser/0.6/titan-browser-page.mjs",
            "lib/titan-browser/0.6/titan-browser-module-check.mjs",
            "lib/titan-browser/0.6/build-profile",
            "lib/titan-browser/0.6/absent-modules",
            "lib/titan-browser/0.6/sdk-digests",
            "lib/titan-browser/0.5/libtitan.a",
        }
        for _, name in ipairs(browser_sdk_owned) do
            write(prefix .. "/" .. name, name)
        end
        local owned = { "lib/titan/0.6/titan.so", "lib/titan/0.6/titan.a",
            "lib/titan/0.6/libtitan.a", "include/titan.h", "include/minicoro.h", "include/transfer.h",
            "include/titan/ffi.h", "share/titan/LICENSE", "etc/titan/build-profile",
            "lib/titan/0.6/titan.so.dSYM/Contents/Resources/DWARF/titan.so" }
        for _, name in ipairs(owned) do write(current .. "/titan-sdk/" .. name, name) end
        write(old .. "/titan-sdk/lib/titan/0.5/titan.so", "older provider")
        assert(installer.publish(current, prefix, lua, prefix .. "/bin/luarocks"))
        assert(installer.publish(old, prefix, lua, prefix .. "/bin/luarocks"))
        write(prefix .. "/include/openssl/ssl.h", "third-party SSL")
        os.execute = function(command)
            assert.truthy(command:find("--tree", 1, true))
            assert.truthy(command:find("remove", 1, true))
            assert.falsy(command:find("0.6.0-1", 1, true))
            remove_tree(versions)
            return true, "exit", 0
        end

        assert(installer.uninstall(current))

        for _, name in ipairs(owned) do assert.is_nil(lfs.symlinkattributes(prefix .. "/" .. name), name) end
        for _, name in ipairs(browser_sdk_owned) do
            assert.is_nil(lfs.symlinkattributes(prefix .. "/" .. name), name)
        end
        assert.is_nil(lfs.symlinkattributes(prefix .. "/lib/titan/0.5/titan.so"))
        assert.is_nil(lfs.symlinkattributes(prefix .. "/lib/titan-browser/0.5"))
        for _, name in ipairs(preserved) do assert.equal(name, read(prefix .. "/" .. name)) end
        for _, name in ipairs(browser_lua_preserved) do
            assert.equal(name, read(prefix .. "/" .. name), name)
        end
        assert.equal("third-party SSL", read(prefix .. "/include/openssl/ssl.h"))
    end)
end)

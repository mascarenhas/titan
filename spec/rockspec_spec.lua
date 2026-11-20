local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local paths = require "titan-compiler.path"
local installed_prefix = require "spec.support.installed_prefix"
local source_inventory = require "spec.support.source_inventory"
local LUA, TITANC
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local PROGRAM_SUFFIX = platform.windows and ".exe" or ""

local STDLIB_MODULES = {
    "coroutine", "uv", "async", "timer", "io", "fs", "net", "ssl",
    "url", "http", "websocket", "os", "path", "peg", "string", "math", "lua", "iteration", "gc",
    "test", "reflect", "sqlite3", "json", "protobuf", "transfer", "thread",
}
local COMPILER_SLICE_PATHS = {}
for _, owner in ipairs({ "checker", "coder" }) do
    for _, path in ipairs(source_inventory.lua_files(
            "titan-compiler/" .. owner)) do
        COMPILER_SLICE_PATHS[#COMPILER_SLICE_PATHS + 1] = assert(
            path:match("^titan%-compiler/(.+)$"))
    end
end

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function run(argv, cwd)
    local command = { table.unpack(argv) }
    local script
    if platform.windows then
        local first = 1
        if command[1] == "env" or command[1] == "env.exe" then
            command[1] = "env.exe"
            first = 2
            while command[first] do
                if command[first] == "-u" then first = first + 2
                elseif command[first]:match("^[%w_]+=") then first = first + 1
                else break end
            end
        end
        if command[first] and command[first]:lower():match("[/\\]lua[.]exe$") then
            for index = first + 1, #command - 1 do
                if command[index] == "-e" then
                    -- Native Windows argv cannot carry multiline chunks. The
                    -- same Lua probe runs from a private file instead.
                    script = assert(compiler_io.new_sync():tmpname())
                    local file = assert(io.open(script, "wb"))
                    assert(file:write(command[index + 1]))
                    assert(file:close())
                    command[index] = script
                    table.remove(command, index + 1)
                    break
                end
            end
        end
    end
    local previous = assert(lfs.currentdir())
    if cwd then assert.truthy(lfs.chdir(cwd)) end
    local called, result = pcall(function()
        return compiler_io.new_sync():run(command)
    end)
    if cwd then assert.truthy(lfs.chdir(previous)) end
    if script then os.remove(script) end
    assert.truthy(called, result)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.started and result.ok, output, result.why, result.status
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    assert.truthy(file:close())
    return contents
end

local function load_rock_manifest(path)
    local environment = {}
    local chunk = assert(loadfile(path, "t", environment))
    local ok, err = pcall(chunk)
    assert.truthy(ok, err)
    return assert(environment.rock_manifest)
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function make_directory(path)
    if lfs.attributes(path, "mode") then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), path)
end

local function copy_tree(source, destination)
    local mode = assert(lfs.symlinkattributes(source, "mode"), source)
    if mode == "file" then
        local parent = assert(destination:match("^(.+)/[^/]+$"))
        make_directory(parent)
        write_file(destination, read_file(source))
    elseif mode == "directory" then
        make_directory(destination)
        for entry in lfs.dir(source) do
            if entry ~= "." and entry ~= ".." then
                copy_tree(source .. "/" .. entry,
                    destination .. "/" .. entry)
            end
        end
    else
        error("cannot copy " .. source .. " of type " .. mode)
    end
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        lfs.rmdir(path)
    elseif mode then
        os.remove(path)
    end
end

local function temporary_directory(label)
    local reservation = assert(compiler_io.new_sync():tmpname())
    assert.truthy(os.remove(reservation))
    local path = label and reservation .. "-titan-" .. label or reservation
    assert.truthy(lfs.mkdir(path))
    local previous = assert(lfs.currentdir())
    assert.truthy(lfs.chdir(path))
    local physical = assert(lfs.currentdir())
    assert.truthy(lfs.chdir(previous))
    return platform.windows and physical:gsub("\\", "/") or physical
end

local PREFIX = installed_prefix.active()

LUA = PREFIX .. "/bin/lua" .. PROGRAM_SUFFIX
local LUAROCKS = PREFIX .. "/bin/luarocks" .. PROGRAM_SUFFIX
-- The installed compiler program: the native titanc.exe on Windows.
TITANC = PREFIX .. "/bin/titanc" .. PROGRAM_SUFFIX
local TITAN_LIBDIR = PREFIX .. "/lib/titan/0.6"
local TITAN_RUNTIME_ARCHIVE = TITAN_LIBDIR .. "/libtitan.a"
local STDLIB_PROVIDER = TITAN_LIBDIR .. "/titan" .. SHARED_SUFFIX
local STDLIB_STATIC_ARCHIVE = TITAN_LIBDIR .. "/titan.a"
local LUA_LIBDIR = PREFIX .. "/lib/lua/5.5"
local LUA_SHAREDIR = PREFIX .. "/share/lua/5.5"
-- The `titan` support module is an ordinary rock-owned native Lua module.
local SUPPORT_MODULE = LUA_LIBDIR .. "/titan" .. SHARED_SUFFIX

local function clean_environment(argv)
    local command = {
        "env",
        "-u", "LUA_PATH",
        "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH_5_5",
        "-u", "TITAN_PATH_0_6",
        "-u", "TITAN_PATH",
        "-u", "TITAN_ROOT",
    }
    -- Standalone Windows LuaRocks selects its Lua SDK through this config.
    -- Keep that caller choice while removing module search-path overrides.
    if not platform.windows then
        for _, name in ipairs({ "LUAROCKS_CONFIG", "LUAROCKS_CONFIG_5_5",
                "LUAROCKS_SYSCONFDIR" }) do
            command[#command + 1] = "-u"
            command[#command + 1] = name
        end
    end
    command[#command + 1] = "CCACHE_DISABLE=1"
    command[#command + 1] = "PATH=" .. PREFIX .. "/bin" ..
        (platform.windows and ";" or ":") .. (os.getenv("PATH") or "/usr/bin:/bin")
    for _, word in ipairs(argv) do command[#command + 1] = word end
    return command
end

local function compiler_argv(...)
    local argv = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(assert(cdriver.split_shell_words(
        os.getenv("CC") or (platform.windows and "clang.exe" or "cc")))) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function archive_object_members(output)
    local members = {}
    for member in output:gmatch("[^\r\n]+") do
        local basename = assert(member:match("([^/]+)$"))
        if basename ~= "__.SYMDEF" and
           basename ~= "__.SYMDEF SORTED" and
           basename ~= "__.SYMDEF_64" and
           basename ~= "__.SYMDEF_64 SORTED" then
            members[#members + 1] = basename
        end
    end
    table.sort(members)
    return members
end

local function assert_file(path)
    assert.equal("file", lfs.attributes(path, "mode"), path)
end

local function assert_unique_regular_file(path)
    assert.equal("file", lfs.symlinkattributes(path, "mode"), path)
    assert.equal(1, lfs.attributes(path, "nlink"), path)
end

local function assert_absent(path)
    assert.falsy(lfs.symlinkattributes(path), path)
end

local function normalized_path(path)
    if platform.windows then return platform.path.normalize(path):lower() end
    return path
end

local function assert_no_obsolete_module_layout(root, module)
    local library_dir = root .. "/lib/titan/0.6"
    local lua_libdir = root .. "/lib/lua/5.5"
    for _, obsolete in ipairs({
        library_dir .. "/titan/" .. module .. SHARED_SUFFIX,
        library_dir .. "/" .. module .. SHARED_SUFFIX,
        lua_libdir .. "/titan/" .. module .. SHARED_SUFFIX,
        lua_libdir .. "/titan/stdlib_0_6/" .. module .. SHARED_SUFFIX,
    }) do
        assert_absent(obsolete)
        assert_absent(obsolete .. ".dSYM")
    end
end

describe("standalone-prefix source installation", function()
    local workspace

    teardown(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    it("copies every compiler Lua module through the Make installer",
    function()
        workspace = temporary_directory("compiler-installer")
        local destination = workspace .. "/rock staging"
        local ok, output = run({
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
            "make", "--no-print-directory", "-s", "-f",
            platform.windows and "Makefile.win" or "Makefile",
            "PREFIX=" .. PREFIX, "install-compiler",
            "INST_LUADIR=" .. destination .. "/lua",
            "INST_BINDIR=" .. destination .. "/bin",
            "INST_CONFDIR=" .. destination .. "/conf",
            "INST_LIBDIR=" .. destination .. "/lib",
        })
        assert.truthy(ok, output)
        local expected = {}
        for _, owner in ipairs({ "titan-compiler", "c-parser" }) do
            for _, path in ipairs(source_inventory.lua_files(owner)) do
                local installed = destination .. "/lua/" .. path
                expected[path] = true
                assert_unique_regular_file(installed)
                assert.equal(read_file(path), read_file(installed), path)
                if not platform.windows then
                    assert.equal("rw-r--r--", lfs.attributes(installed, "permissions"), path)
                    assert.equal(lfs.attributes(path, "modification"),
                        lfs.attributes(installed, "modification"), path)
                end
            end
        end
        if platform.windows then
            -- The native titanc.exe replaces the script launcher in bin; the
            -- unchanged script is the rock's Lua file that titanc.exe runs.
            expected["titan-compiler/titanc.lua"] = true
            assert.equal(read_file("titanc"),
                read_file(destination .. "/lua/titan-compiler/titanc.lua"))
        end
        for _, path in ipairs(source_inventory.lua_files(destination .. "/lua")) do
            local relative = path:sub(#destination + #"/lua/" + 1)
            assert.truthy(expected[relative], "unexpected installed module " .. relative)
            expected[relative] = nil
        end
        assert.same({}, expected)
        if platform.windows then
            assert_unique_regular_file(destination .. "/bin/titanc.exe")
            assert_absent(destination .. "/bin/titanc")
        else
            assert.equal(read_file("titanc"), read_file(destination .. "/bin/titanc"))
            assert.equal("rwxr-xr-x", lfs.attributes(
                destination .. "/bin/titanc", "permissions"))
            assert.equal(lfs.attributes("titanc", "modification"),
                lfs.attributes(destination .. "/bin/titanc", "modification"))
        end
        assert.equal(read_file("THIRD_PARTY_NOTICES.md"), read_file(
            destination .. "/conf/THIRD_PARTY_NOTICES.md"))
        -- The compiler installer also stages the built support module.
        local staged_support = destination .. "/lib/titan" .. SHARED_SUFFIX
        assert_unique_regular_file(staged_support)
        if not platform.windows then
            assert.equal(read_file("titan-runtime/bootstrap/titan.so"),
                read_file(staged_support))
            assert.equal("rwxr-xr-x", lfs.attributes(staged_support, "permissions"))
        end
    end)

    it("installs one matching Lua and Titan SDK before the standard images",
    function()
        for _, source in ipairs({
            "lua.h", "luaconf.h", "lobject.h", "lapi.c", "loadlib.c",
        }) do
            assert_file(PREFIX .. "/src/lua-5.5.1/" .. source)
        end
        for _, header in ipairs({
            "lua.h", "luaconf.h", "titan.h", "minicoro.h", "titan/ffi.h",
            "llhttp.h", "sqlite3.h",
        }) do
            assert_file(PREFIX .. "/include/" .. header)
        end
        assert_absent(PREFIX .. "/include/titan_longjmp.h")
        for _, archive in ipairs(platform.windows and { "liblua55.a", "libbacktrace.a" } or
                { "liblua.a", "libbacktrace.a" }) do
            assert_file(PREFIX .. "/lib/" .. archive)
        end
        if platform.windows then
            -- LuaRocks deploys the native compiler program with no batch,
            -- script or package-path helper beside it.
            for _, launcher in ipairs({ "titanc", "titanc.bat", "titanc.lua" }) do
                assert_absent(PREFIX .. "/bin/" .. launcher)
            end
            assert.equal(read_file("titanc"),
                read_file(LUA_SHAREDIR .. "/titan-compiler/titanc.lua"))
            for _, dll in ipairs({ "lua55.dll", "libuv-1.dll", "libllhttp-9.4.dll",
                    "libsqlite3-0.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll" }) do
                assert_file(PREFIX .. "/bin/" .. dll)
            end
            for _, import_library in ipairs({ "libuv.dll.a", "libllhttp.dll.a",
                    "libsqlite3.dll.a", "libssl.dll.a", "libcrypto.dll.a" }) do
                assert_file(PREFIX .. "/lib/" .. import_library)
            end
            assert_file(PREFIX .. "/include/backtrace.h")
        end
        assert_unique_regular_file(TITAN_RUNTIME_ARCHIVE)
        assert_absent(PREFIX .. "/lib/libtitan.a")
        assert_file(LUA)
        assert_file(LUAROCKS)
        assert_file(TITANC)
        local version_ok, version_output = run({ LUA, "-v" })
        assert.truthy(version_ok, version_output)
        assert.truthy(version_output:find("Lua 5.5.1", 1, true),
            version_output)
        assert_unique_regular_file(STDLIB_PROVIDER)
        if platform.windows then assert_absent(STDLIB_STATIC_ARCHIVE)
        else assert_unique_regular_file(STDLIB_STATIC_ARCHIVE) end
        assert_absent(PREFIX .. "/share/titan/0.6/src/titan/test.titan")
        assert_file(PREFIX ..
            "/share/lua/5.5/titan-compiler/staticmetadata.lua")
        for _, path in ipairs(COMPILER_SLICE_PATHS) do
            assert_file(PREFIX .. "/share/lua/5.5/titan-compiler/" .. path)
        end
        assert_absent(PREFIX ..
            "/share/lua/5.5/titan-compiler/pretty.lua")
        for _, module in ipairs({
            "cdeclarator.lua", "cpreamble.lua", "cprobe.lua",
            "cprobe_cache.lua", "ffiheaders.lua", "objectmetadata.lua",
            "csemantics.lua", "io.lua", "sha256.lua", "test_runner.lua",
            "version.lua", "build.lua", "build_worker.lua", "incremental.lua",
            "depfile.lua", "linkcertificate.lua", "nativeinputs.lua", "progress.lua",
            "testroots.lua",
        }) do
            assert_file(PREFIX ..
                "/share/lua/5.5/titan-compiler/" .. module)
        end
        -- Plain Lua finds the support module on its default C path. The
        -- standard provider is one image; its modules have no staged Lua shims.
        assert_unique_regular_file(SUPPORT_MODULE)
        assert_absent(LUA_SHAREDIR .. "/titan")
        assert_absent(LUA_SHAREDIR .. "/titan.lua")
        assert_absent(LUA_SHAREDIR .. "/peg.lua")
        assert_absent(LUA_SHAREDIR .. "/string.lua")
        assert_absent(PREFIX .. "/lib/libtitan-lpeglabel.a")
        assert_absent(TITAN_LIBDIR .. "/libtitan-lpeglabel.a")
        assert_absent(PREFIX .. "/include/titan_lpeglabel.h")
        assert_absent(PREFIX .. "/include/titan_lpeglabel_namespace.h")
        assert_absent(PREFIX .. "/share/lua/5.5/lpeglabel-build")
        assert_absent(PREFIX .. "/lib/libtitan-llhttp.a")
        assert_absent(PREFIX .. "/lib/libtitan-sqlite3.a")
        assert_absent(TITAN_LIBDIR .. "/libtitan-sqlite3.a")
        assert_absent(PREFIX .. "/lib/libssl.a")
        assert_absent(PREFIX .. "/lib/libcrypto.a")
        assert.equal(read_file("LICENSE"),
            read_file(PREFIX .. "/share/titan/LICENSE"))
        assert_file(PREFIX .. "/share/titan/THIRD_PARTY_NOTICES.md")
        for _, license in ipairs({
            "libuv-LICENSE", "libuv-LICENSE-extra", "libuv-tree-LICENSE",
            "libuv-inet-LICENSE", "lpeglabel-LICENSE", "lpeg-LICENSE",
            "lpeg-patterns-LICENSE", "ta-regex-LICENSE", "lua-LICENSE",
            "llhttp-LICENSE", "sqlite3-LICENSE", "openssl-LICENSE", "go-LICENSE",
            "libbacktrace-LICENSE",
        }) do
            assert_file(PREFIX .. "/share/titan/LICENSES/" .. license)
        end
        if platform.windows then
            assert_file(PREFIX .. "/share/titan/LICENSES/llvm-LICENSE")
        end
        local notices =
            read_file(PREFIX .. "/share/titan/THIRD_PARTY_NOTICES.md")
        for _, notice in ipairs({
            "912b0b9e8641074408ffc2259e069b188e0c717b",
            "0da7cadb867858f8fdf2bfbfbc92a51a7c28c3d7",
            "Copyright (c) 2012-2016 Daurnimator",
            "857e48682791ba55c98a7dd99c5fc7d71c02597d",
            "Converting regexes to Parsing Expression Grammars",
            "Marcelo Oikawa", "Ana Lucia de Moura",
            "lstrlib.c", "Lua 5.5.1",
            "OpenSSL 3.5.7", "OPENSSL_MODE=system",
            "llhttp 9.4.3", "Copyright Fedor Indutny, 2018",
            "SQLite 3.53.4", "public domain",
            "LICENSES/libuv-LICENSE-extra", "LICENSES/libuv-tree-LICENSE",
            "LICENSES/libuv-inet-LICENSE", "Niels Provos", "Internet Systems Consortium",
            "The Luvit Authors", "luv `1.52.1-0`",
        }) do
            assert.truthy(notices:find(notice, 1, true), notice)
        end
        local host_output = "Windows"
        if not platform.windows then
            local host_ok
            host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
        end
        if host_output:match("^%s*Darwin%s*$") then
            assert.equal("directory", lfs.symlinkattributes(
                STDLIB_PROVIDER .. ".dSYM", "mode"))
        else
            assert_absent(STDLIB_PROVIDER .. ".dSYM")
        end
        for _, module in ipairs(STDLIB_MODULES) do
            assert_no_obsolete_module_layout(PREFIX, module)
        end

        local configured_tools = {}
        for _, variable in ipairs({ "CC", "LD", "AR", "RANLIB" }) do
            local configured, tool, config_why, config_code = run(
                clean_environment({
                    LUAROCKS, "config", "variables." .. variable,
                }))
            assert.truthy(configured, tool .. "\n(" ..
                tostring(config_why) .. ", " .. tostring(config_code) .. ")")
            configured_tools[variable] = assert(tool:match("^%s*(.-)%s*$"))
            assert.not_equal("", configured_tools[variable])
        end
        assert.equal(configured_tools.CC, configured_tools.LD)

        local source_config = read_file(
            PREFIX .. "/src/lua-5.5.1/luaconf.h")
        local source_loadlib = read_file(
            PREFIX .. "/src/lua-5.5.1/loadlib.c")
        local public_config = read_file(PREFIX .. "/include/luaconf.h")
        assert.equal(source_config, public_config)
        assert.falsy(source_config:find(PREFIX, 1, true), source_config)
        assert.falsy(source_loadlib:find(PREFIX, 1, true), source_loadlib)
        assert.falsy(source_loadlib:find("luaopen_titan_uv", 1, true),
            source_loadlib)
        assert.truthy(source_loadlib:find(
            "reg = lsys_load(L, path, *sym == '*');", 1, true),
            source_loadlib)

        local ar = assert(cdriver.split_shell_words(os.getenv("AR") or
            (platform.windows and "llvm-ar" or "ar")))
        ar[#ar + 1] = "t"
        ar[#ar + 1] = TITAN_RUNTIME_ARCHIVE
        local ok, output, why, code = run(ar)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local members = archive_object_members(output)
        -- Static hosts can link and preload the support module from the
        -- runtime archive; ordinary links pull its members only on demand.
        assert.same({ "ltitanlib.o", "minicoro.o", "titan.o", "titan_path.o" },
            members)

        if not platform.windows then
            assert.is_true(read_file("libbacktrace/.libs/libbacktrace.a") ==
                read_file(PREFIX .. "/lib/libbacktrace.a"),
                "installed libbacktrace must match this prepared source tree")
        end

        assert.falsy(lfs.symlinkattributes(PREFIX .. "/lib/libuv.a"))
        assert_file(PREFIX .. "/include/uv.h")
        assert_file(PREFIX .. "/include/uv/version.h")

        local expected_openssl_mode = os.getenv("TITAN_EXPECT_OPENSSL_MODE")
            or os.getenv("OPENSSL_MODE") or "system"
        if expected_openssl_mode == "system" and not platform.windows then
            assert_absent(PREFIX .. "/include/openssl")
        else
            assert.truthy(expected_openssl_mode == "bundled" or
                (platform.windows and expected_openssl_mode == "system"))
            -- Generated headers alone are incomplete: ssl.h includes ordinary
            -- source headers such as e_ostime.h from the same public tree.
            for _, header in ipairs({
                "ssl.h", "sslerr.h", "e_ostime.h", "configuration.h", "opensslv.h",
            }) do
                assert_file(PREFIX .. "/include/openssl/" .. header)
            end
        end

        local workspace = temporary_directory("sdk-headers")
        local source = workspace .. "/sdk.c"
        write_file(source, [[
#include <lua.h>
#include <titan/ffi.h>
#include <uv.h>
#include <llhttp.h>
#include <sqlite3.h>
#include <openssl/ssl.h>
int titan_sdk_headers(void) { return LUA_VERSION_NUM + SQLITE_VERSION_NUMBER; }
]])
        local headers_ok, headers_output = run(compiler_argv(
            "-std=c99", "-D_GNU_SOURCE", "-DOPENSSL_API_COMPAT=30000",
            "-I", PREFIX .. "/include", "-I", PREFIX .. "/src/lua-5.5.1",
            "-fsyntax-only", source), workspace)
        remove_tree(workspace)
        assert.truthy(headers_ok, headers_output)

        local manifest_path = PREFIX ..
            "/lib/luarocks/rocks-5.5/titan/0.6.0-1/rock_manifest"
        local manifest = read_file(manifest_path)
        local manifest_table = load_rock_manifest(manifest_path)
        local retained_native = manifest_table["titan-sdk"].lib.titan["0.6"]
        assert.truthy(retained_native["titan" .. SHARED_SUFFIX], manifest)
        assert.truthy(retained_native["libtitan.a"], manifest)
        if platform.windows then assert.falsy(retained_native["titan.a"], manifest)
        else assert.truthy(retained_native["titan.a"], manifest) end
        assert.truthy(manifest_table.installer["titan_install.lua"], manifest)
        assert.truthy(manifest_table.bin["titan-install"], manifest)
        assert.truthy(manifest_table.bin["titan-uninstall"], manifest)
        assert_file(PREFIX .. "/bin/titan-install" .. (platform.windows and ".bat" or ""))
        if platform.windows then
            local launch = 'type NUL && "' .. PREFIX .. '/bin/titan-install.bat"'
            assert.truthy(os.execute(launch .. " --help"))
            local accepted, outcome, status = os.execute(launch .. " --module invalid")
            assert.is_nil(accepted)
            assert.equal("exit", outcome)
            assert.equal(1, status)
        end
        -- LuaRocks owns the compiler entry: the native program on Windows,
        -- which runs the rock's Lua copy of the titanc script.
        if platform.windows then
            assert.truthy(manifest_table.bin["titanc.exe"], manifest)
            assert.is_nil(manifest_table.bin.titanc, manifest)
            assert.truthy(manifest_table.lua["titan-compiler"]["titanc.lua"], manifest)
        else
            assert.truthy(manifest_table.bin.titanc, manifest)
        end
        assert.falsy(manifest:find("vendor/lpeglabel", 1, true), manifest)
        assert.falsy(manifest:find("libtitan-lpeglabel", 1, true), manifest)
        assert.falsy(manifest:find('["pretty.lua"]', 1, true), manifest)
        assert.truthy(manifest:find(
            '["staticmetadata.lua"]', 1, true), manifest)
        for _, module in ipairs({
            "cdeclarator.lua", "cpreamble.lua", "cprobe.lua",
            "cprobe_cache.lua", "ffiheaders.lua", "objectmetadata.lua",
            "csemantics.lua", "io.lua", "sha256.lua", "test_runner.lua",
            "version.lua",
        }) do
            assert.truthy(manifest:find(
                '["' .. module .. '"]', 1, true), manifest)
        end
        -- LuaRocks owns the deployed support module and no Lua shims.
        local deployed_native = manifest_table.lib or {}
        assert.truthy(deployed_native["titan" .. SHARED_SUFFIX], manifest)
        assert.is_nil(manifest_table.lua.titan, manifest)
        for _, module in ipairs(STDLIB_MODULES) do
            local image = module .. SHARED_SUFFIX
            assert.falsy(retained_native[image], manifest)
            assert.falsy(deployed_native[image], manifest)
            assert.falsy((deployed_native.titan or {})[image], manifest)
        end
        -- `make binary-rock` (`luarocks pack`) copies the retained rock
        -- directory and the manifest's deployed files. Neither carries
        -- standard-library source or any part of the browser SDK, which `make
        -- browser-sdk` installs outside LuaRocks; documentation examples are
        -- the only Titan source.
        local function assert_binary_payload(path, name)
            assert.falsy(name:match("^titan%-browser") or name == "titan-protobuf.mjs", path)
            assert.falsy(name:match("%.browser%.titan$"), path)
            assert.truthy(not name:match("%.titan$") or path:match("^doc/"), path)
        end
        local function audit_manifest(entries, prefix)
            for name, entry in pairs(entries) do
                assert_binary_payload(prefix .. name, name)
                if type(entry) == "table" then audit_manifest(entry, prefix .. name .. "/") end
            end
        end
        audit_manifest(manifest_table, "")
        local function audit_tree(directory, prefix)
            for name in lfs.dir(directory) do
                if name ~= "." and name ~= ".." then
                    assert_binary_payload(prefix .. name, name)
                    if lfs.symlinkattributes(directory .. "/" .. name, "mode") == "directory" then
                        audit_tree(directory .. "/" .. name, prefix .. name .. "/")
                    end
                end
            end
        end
        audit_tree(PREFIX .. "/lib/luarocks/rocks-5.5/titan/0.6.0-1", "")

        -- The installer recorded every approved SDK native link input,
        -- including the selected Lua archive; titanc admits and reuses each
        -- digest without reading the bytes.
        local incremental = require "titan-compiler.incremental"
        local location = assert(loadfile(PREFIX ..
            "/lib/luarocks/rocks-5.5/titan/0.6.0-1/installer/location.lua", "t", {}))()
        assert.equal("lib/titan/0.6/" .. incremental.SDK_DIGESTS, location.digests)
        local support = require "titan"
        local certified = { io = compiler_io.new_sync(),
            cache_adapter = { sha256_binary = support._sha256_binary } }
        assert(incremental.load_sdk_digests(certified, PREFIX .. "/" .. location.digests))
        local sdk_inputs = { "lib/titan/0.6/titan" .. SHARED_SUFFIX, "lib/titan/0.6/libtitan.a",
            "lib/libbacktrace.a", platform.windows and "lib/liblua55.a" or "lib/liblua.a" }
        if not platform.windows then sdk_inputs[#sdk_inputs + 1] = "lib/titan/0.6/titan.a" end
        local sha256 = require "titan-compiler.sha256"
        for _, relative in ipairs(sdk_inputs) do
            local digest, bytes = incremental.file_digest(certified, PREFIX .. "/" .. relative)
            assert.is_nil(bytes, relative)
            assert.equal(sha256.hex_via(support._sha256_binary,
                read_file(PREFIX .. "/" .. relative)), digest, relative)
        end
        assert.equal(#sdk_inputs, incremental.counters(certified).sdk_reuses)
        assert.equal(0, incremental.counters(certified).file_reads)
    end)

    it("packs and unpacks every vendored and standard-library source",
    function()
        -- Keep the complete source-rock layout below legacy Windows path limits.
        workspace = temporary_directory(not platform.windows and
            "source-rock-inventory" or nil)
        local source_repository = workspace .. "/source"
        local unpack_root = workspace .. "/unpacked"
        make_directory(source_repository)
        make_directory(unpack_root)

        local git_root = (not lfs.symlinkattributes(".git", "mode") and
            os.getenv("TITAN_SOURCE_GIT_ROOT")) or "."
        local ok, output, why, code = run({
            "git", "-C", git_root, "ls-files", "--cached", "--others",
            "--exclude-standard", "-z",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local copied = 0
        for path in (output .. "\0"):gmatch("(.-)%z") do
            -- `--cached` reports index entries intentionally deleted by the
            -- worktree under test. They are not part of the source inventory
            -- being packed and have no pathname to copy.
            if (path == "lua-5.5.1" or path == ".agents/skills") and
                    lfs.symlinkattributes(path, "mode") == "directory" then
                local listed, files = run({ "git", "-C",
                    git_root .. "/" .. path, "ls-files", "-z" })
                assert.truthy(listed, files)
                for source in (files .. "\0"):gmatch("(.-)%z") do
                    if source ~= "" then
                        copy_tree(path .. "/" .. source,
                            source_repository .. "/" .. path .. "/" .. source)
                        copied = copied + 1
                    end
                end
            elseif path ~= "" and lfs.symlinkattributes(path, "mode") then
                copy_tree(path, source_repository .. "/" .. path)
                copied = copied + 1
            end
        end
        assert.truthy(copied > 0)

        for _, argv in ipairs({
            { "git", "init", "-q", source_repository },
            { "git", "-C", source_repository, "add", "-f", "." },
            {
                "git", "-C", source_repository,
                "-c", "user.name=Titan source-rock test",
                "-c", "user.email=titan-source-rock@example.invalid",
                "commit", "-qm", "source inventory",
            },
        }) do
            ok, output, why, code = run(argv)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
        end

        local rockspec = read_file("titan-0.6.0-1.rockspec")
        local replacement_count
        local rockspec_environment = {}
        assert(load(rockspec, "=packed rockspec", "t", rockspec_environment))()
        local source_url = assert(rockspec_environment.source.url)
        local source_url_pattern = source_url:gsub("(%W)", "%%%1")
        rockspec, replacement_count = rockspec:gsub(
            'url%s*=%s*"' .. source_url_pattern .. '"',
            function()
                -- LuaRocks' git_file fetcher removes this protocol before
                -- invoking Git, so keep Windows' native drive path intact.
                return 'url = "git+file://' ..
                    source_repository:gsub("\\", "/") .. '"'
            end)
        assert.equal(1, replacement_count)
        local packed_rockspec = workspace .. "/titan-0.6.0-1.rockspec"
        write_file(packed_rockspec, rockspec)

        ok, output, why, code = run(clean_environment({
            LUAROCKS, "pack", packed_rockspec,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local source_rock = workspace .. "/titan-0.6.0-1.src.rock"
        assert_file(source_rock)

        ok, output, why, code = run(clean_environment({
            LUAROCKS, "unpack", "--force", source_rock,
        }), unpack_root)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local unpacked_files = {}
        local function collect(path, relative)
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local child = path .. "/" .. entry
                    local child_relative =
                        relative == "" and entry or relative .. "/" .. entry
                    local mode = assert(lfs.symlinkattributes(child, "mode"))
                    if mode == "directory" then
                        collect(child, child_relative)
                    elseif mode == "file" then
                        unpacked_files[child_relative] = true
                    end
                end
            end
        end
        collect(unpack_root, "")

        local function contains_suffix(suffix)
            for path in pairs(unpacked_files) do
                if path == suffix or
                   path:sub(-#suffix - 1) == "/" .. suffix then
                    return true
                end
            end
            return false
        end
        for _, expected in ipairs({
            ".gitmodules",
            ".agents/skills/titan-programmer/SKILL.md",
            "Makefile.win",
            "scripts/WindowsLibbacktraceAllocator.pm",
            "vendor/libbacktrace/libbacktrace-0b9b49c-alloc-growth.patch",
            "spec/fixtures/libbacktrace/allocator_vector_probe.c",
            "spec/support/check_libbacktrace_allocator.sh",
            "spec/support/check_windows_libbacktrace_allocator.pl",
            "vendor/libuv/libuv-1.53.0-windows-write-reentry.patch",
            "vendor/lua/UPSTREAM.md",
            -- The Windows build's native titanc.exe entry and manifest.
            "titan-runtime/titanc_windows.c",
            "vendor/windows-compiler/titanc.rc",
            "vendor/windows-compiler/titanc.manifest",
            "lua-5.5.1/src/Makefile",
            "lua-5.5.1/src/lua.h",
            "lua-5.5.1/src/luaconf.h",
            "lua-5.5.1/src/loadlib.c",
            "vendor/lpeglabel/relabel.lua",
            "vendor/lpeglabel/test.lua",
            "vendor/lpeglabel/testlabel.lua",
            "vendor/lpeglabel/testrelabelparser.lua",
            "vendor/lpeglabel/LICENSE",
            "vendor/lpeglabel/UPSTREAM.md",
            -- Loaded by scripts/browser_stdlib.lua beside itself.
            "scripts/browser_stdlib_inventory.lua",
            -- Copied by `make browser-sdk` beside the compiler's SDK assets.
            "titan-runtime/browser/titan-protobuf.mjs",
            "spec/stdlib/titan/async/test_support/test_support.titan",
            "spec/stdlib/titan/async/test_support/sleep.titan",
            "spec/stdlib/titan/async/tests/all_join_test.titan",
            "spec/stdlib/titan/async/tests/coverage_combinator_matrix_test.titan",
            "spec/stdlib/titan/async/tests/coverage_recovery_test.native.titan",
            "spec/stdlib/titan/async/tests/any_race_test.titan",
            "spec/stdlib/titan/async/tests/await_test.titan",
            "spec/stdlib/titan/async/tests/await_native_test.native.titan",
            "spec/stdlib/titan/async/tests/channel_test.titan",
            "spec/stdlib/titan/async/tests/completion_test.native.titan",
            "spec/stdlib/titan/async/tests/fatal_test.titan",
            "spec/stdlib/titan/async/tests/fatal_native_test.native.titan",
            "spec/stdlib/titan/async/tests/foreign_work_test.native.titan",
            "spec/stdlib/titan/async/tests/async_stack_probe.h",
            "spec/stdlib/titan/async/tests/external_wait_test.native.titan",
            "spec/stdlib/titan/async/tests/receiver_probe.h",
            "spec/stdlib/titan/async/tests/coalescing_receiver_test.native.titan",
            "spec/stdlib/titan/async/tests/transfer_payload_test.native.titan",
            "spec/stdlib/titan/transfer/tests/scalar_envelope_test.titan",
            "spec/stdlib/titan/async/tests/transfer_scope_reuse_test.native.titan",
            "spec/fixtures/stdlib/titan/transfer_ownership_smoke_app.titan",
            "spec/fixtures/stdlib/titan/transfer_alloc_fault_app.titan",
            "spec/fixtures/stdlib/native/transfer_alloc_fault_api.h",
            "spec/fixtures/stdlib/native/transfer_alloc_fault.c",
            "spec/fixtures/stdlib/titan/uv_sync_alloc_fault_app.titan",
            "spec/fixtures/stdlib/native/uv_sync_alloc_fault_api.h",
            "spec/fixtures/stdlib/native/uv_sync_alloc_fault.c",
            "spec/fixtures/stdlib/titan/thread_retirement_fault_app.titan",
            "spec/fixtures/stdlib/native/thread_retirement_fault_api.h",
            "spec/fixtures/stdlib/native/thread_retirement_fault.c",
            "spec/stdlib/titan/async/tests/receiver_test.native.titan",
            "spec/stdlib/titan/async/tests/runtime_close_test.titan",
            "spec/stdlib/titan/async/tests/runtime_close_native_test.native.titan",
            "spec/stdlib/titan/async/tests/subscription_test.titan",
            "spec/stdlib/titan/async/tests/task_test.titan",
            "spec/stdlib/titan/async/tests/task_native_test.native.titan",
            "spec/stdlib/titan/async/tests/task_timer_test.titan",
            "spec/stdlib/titan/async/tests/native_imports.native.titan",
            "spec/stdlib/titan/async/tests/version_test.native.titan",
            "spec/stdlib/titan/async/tests/tests.titan",
            "spec/stdlib/titan/coroutine/test_support.titan",
            "spec/stdlib/titan/coroutine/tests/basic_test.titan",
            "spec/stdlib/titan/coroutine/tests/gc_test.titan",
            "spec/stdlib/titan/coroutine/tests/lifecycle_test.titan",
            "spec/stdlib/titan/coroutine/tests/lua_boundary_test.native.titan",
            "spec/stdlib/titan/coroutine/tests/nested_test.titan",
            "spec/stdlib/titan/coroutine/tests/tests.titan",
            "spec/stdlib/titan/coroutine/tests/transfer_test.titan",
            "spec/stdlib/titan/fs/fixture_support.h",
            "spec/stdlib/titan/fs/test_support.titan",
            "spec/stdlib/titan/fs/tests.titan",
            "spec/stdlib/titan/gc/tests.titan",
            "spec/stdlib/titan/http/test_support.titan",
            "spec/stdlib/titan/http/tests/client_behavior.native.titan",
            "spec/stdlib/titan/http/tests/client_reuse_test.native.titan",
            "spec/stdlib/titan/http/tests/request_options_test.native.titan",
            "spec/stdlib/titan/http/tests/redirect_test.native.titan",
            "spec/stdlib/titan/http/tests/eof_behavior.native.titan",
            "spec/stdlib/titan/http/tests/tls_idle_disconnect_test.native.titan",
            "spec/stdlib/titan/http/tests/reuse_port_test.native.titan",
            "spec/stdlib/titan/http/tests/server_behavior.native.titan",
            "spec/stdlib/titan/http/tests/sanitizer_process_test.native.titan",
            "spec/stdlib/titan/http/tests/test_cases.native.titan",
            "spec/stdlib/titan/http/tests/native_imports.native.titan",
            "spec/stdlib/titan/http/tests/portable.titan",
            "spec/stdlib/titan/http/tests/validation.browser.titan",
            "spec/stdlib/titan/http/tests/tests.titan",
            "spec/stdlib/titan/http/tests/timeout_tls_behavior.native.titan",
            "spec/stdlib/titan/http/tests/upgrade_behavior.native.titan",
            "spec/stdlib/titan/io/print_capture.h",
            "spec/stdlib/titan/io/test_support.titan",
            "spec/stdlib/titan/io/tests/core_test.titan",
            "spec/stdlib/titan/io/tests/tests.titan",
            "spec/stdlib/titan/iteration/tests.titan",
            "spec/stdlib/titan/lua/preload_fixture.titan",
            "spec/stdlib/titan/lua/receiver_fixture.native.titan",
            "spec/stdlib/titan/lua/test_support.native.titan",
            "spec/stdlib/titan/lua/handle_transfer_fixture.native.titan",
            "spec/stdlib/titan/lua/transfer_fixture/receivers.native.titan",
            "spec/stdlib/titan/lua/transfer_fixture/transfer_fixture.titan",
            "spec/stdlib/titan/lua/tests/composition_test.titan",
            "spec/stdlib/titan/lua/tests/core_test.titan",
            "spec/stdlib/titan/lua/tests/dofile_test.native.titan",
            "spec/stdlib/titan/lua/tests/handle_transfer_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_async_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_preload_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_reader_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_receiver_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_transfer_test.native.titan",
            "spec/stdlib/titan/lua/tests/independent_state_test.titan",
            "spec/stdlib/titan/lua/tests/preload_test.titan",
            "spec/stdlib/titan/lua/tests/record_payload_cases.titan",
            "spec/stdlib/titan/lua/tests/record_payload_test.native.titan",
            "spec/stdlib/titan/lua/tests/require_test.native.titan",
            "spec/stdlib/titan/lua/tests/source_require_test.native.titan",
            "spec/stdlib/titan/lua/tests/state_close_test.native.titan",
            "spec/stdlib/titan/lua/tests/stock_profile.browser.titan",
            "spec/stdlib/titan/lua/tests/stream_transfer_test.browser.titan",
            "spec/stdlib/titan/lua/tests/tests.titan",
            "spec/stdlib/titan/lua/tests/transfer_cases.titan",
            "spec/stdlib/titan/math/tests.titan",
            "spec/stdlib/titan/net/test_support.titan",
            "spec/stdlib/titan/net/tests.titan",
            "spec/stdlib/titan/os/process_test_support.titan",
            "spec/stdlib/titan/os/process_tests/disposal_test.titan",
            "spec/stdlib/titan/os/process_tests/shell_test.titan",
            "spec/stdlib/titan/os/process_tests/exit_test.titan",
            "spec/stdlib/titan/os/process_tests/host_process_test.titan",
            "spec/stdlib/titan/os/process_tests/parent_stdio_test.titan",
            "spec/stdlib/titan/os/process_tests/process_tests.titan",
            "spec/stdlib/titan/os/process_tests/signal_test.titan",
            "spec/stdlib/titan/os/process_tests/stream_test.titan",
            "spec/stdlib/titan/os/process_tests/coverage_stream_test.titan",
            "spec/stdlib/titan/os/process_tests/coverage_read_failure_test.titan",
            "spec/stdlib/titan/os/process_tests/coverage_shutdown_admission_test.titan",
            "spec/stdlib/titan/os/process_tests/coverage_tty_test.titan",
            "spec/stdlib/titan/os/test_support.titan",
            "spec/stdlib/titan/os/tests/helpers_test.titan",
            "spec/stdlib/titan/os/tests/tests.titan",
            "spec/stdlib/titan/os/tests/time_test.titan",
            "spec/stdlib/titan/os/tests/coverage_calendar_test.titan",
            "spec/stdlib/titan/peg/test_support.titan",
            "spec/stdlib/titan/peg/tests/core_test.titan",
            "spec/stdlib/titan/peg/tests/gc_test.titan",
            "spec/stdlib/titan/peg/tests/relabel_test.titan",
            "spec/stdlib/titan/peg/tests/tests.titan",
            "spec/stdlib/titan/ssl/backpressure_support.titan",
            "spec/stdlib/titan/ssl/test_support.titan",
            "spec/stdlib/titan/ssl/tests/tests.titan",
            "spec/stdlib/titan/ssl/tests/coverage.titan",
            "spec/stdlib/titan/ssl/tests/allocation_test.titan",
            "spec/stdlib/titan/ssl/tests/error_strings_test.titan",
            "spec/stdlib/titan/ssl/tests/late_write_test.titan",
            "spec/stdlib/titan/ssl/tests/drain_failure_test.titan",
            "spec/fixtures/stdlib/native/ssl_allocator_fixture.c",
            "spec/fixtures/stdlib/native/ssl_allocator_fixture.h",
            "spec/fixtures/stdlib/titan/ssl_allocator_app.titan",
            "spec/fixtures/stdlib/native/ssl_error_strings.c",
            "spec/fixtures/stdlib/native/ssl_error_strings.h",
            "spec/fixtures/stdlib/titan/ssl_error_strings_app.titan",
            "spec/fixtures/stdlib/titan/async_recovery_app.titan",
            "spec/stdlib/titan/string/core_test.titan",
            "spec/stdlib/titan/string/format_pack_test.titan",
            "spec/stdlib/titan/string/regex_test.titan",
            "spec/stdlib/titan/string/test_support.titan",
            "spec/stdlib/titan/support/async/async.titan",
            "spec/stdlib/titan/support/async/drive.native.titan",
            "spec/stdlib/titan/support/command.titan",
            "spec/stdlib/titan/support/common.titan",
            "spec/stdlib/titan/support/runtime.titan",
            "spec/stdlib/titan/timer/tests/tests.titan",
            "spec/stdlib/titan/timer/tests/timers.native.titan",
            "spec/stdlib/titan/timer/tests/timers.browser.titan",
            "spec/stdlib/titan/url/tests.titan",
            "spec/stdlib/titan/websocket/tests/tests.titan",
            "spec/stdlib/titan/websocket/tests/imports.native.titan",
            "spec/stdlib/titan/websocket/tests/portable.titan",
            "spec/stdlib/titan/websocket/tests/validation.browser.titan",
            "spec/stdlib/titan/websocket/tests/raw_peer.native.titan",
            "spec/stdlib/titan/websocket/tests/fixtures.native.titan",
            "spec/stdlib/titan/websocket/tests/messages_test.native.titan",
            "spec/stdlib/titan/websocket/tests/protocol_test.native.titan",
            "spec/stdlib/titan/websocket/tests/opening_test.native.titan",
            "spec/stdlib/titan/websocket/tests/lifecycle_test.native.titan",
            "spec/stdlib/titan/websocket/tests/ownership_test.native.titan",
            "spec/stdlib/titan/websocket/tests/backpressure.native.titan",
            "spec/stdlib/titan/websocket/tests/backpressure_test.native.titan",

            "spec/stdlib/titan/uv/runtime_tests.titan",
            "spec/stdlib/titan/uv/public_tests/coverage_misc_callbacks.titan",
            "spec/stdlib/titan/uv/public_tests/coverage_tty.titan",
            "spec/stdlib/titan/uv/public_tests/external_wake.titan",
            "spec/stdlib/titan/uv/task_test_support.titan",
            "spec/stdlib/titan/uv/task_tests/cancellation_test.titan",
            "spec/stdlib/titan/uv/task_tests/continuations_test.titan",
            "spec/stdlib/titan/uv/task_tests/task_tests.titan",
            "spec/test_runner_spec.lua",
            "spec/coder/test_runner_spec.lua",
            "spec/stdlib/titan/test/tests.titan",
            "spec/fixtures/test_runner/nested/tests/tests.titan",
            "spec/fixtures/test_runner/test_runner_dependency.titan",
            "spec/fixtures/test_runner/test_runner_edge.titan",
            "spec/fixtures/test_runner/test_runner_fixture.titan",
            "spec/fixtures/test_runner/test_runner_folder/contributor.titan",
            "spec/fixtures/test_runner/test_runner_folder/test_runner_folder.titan",
            "spec/fixtures/test_runner/test_runner_mutation.titan",
            "spec/fixtures/test_runner/test_runner_static.titan",
            "spec/fixtures/test_runner/titan/test/runner/user.titan",
            "spec/fixtures/test_runner/titan/test/user.titan",
            "spec/support/run_rock_tests.sh",
            "spec/support/run_parallel_compiler_tests.sh",
            "spec/support/run_with_timeout.sh",
            "spec/support/clean_generated_test_artifacts.sh",
            "spec/support/clean_generated_test_artifacts.lua",
            "spec/support/build_windows_stdlib_native.sh",
            "spec/fixtures/stdlib/native/async_foreign_work.c",
            "spec/fixtures/stdlib/native/async_foreign_work.h",
            "spec/fixtures/stdlib/native/os_process_child.c",
            "spec/fixtures/stdlib/native/os_process_host_child.c",
            "spec/fixtures/stdlib/native/os_descriptor_limit.c",
            "spec/fixtures/stdlib/native/os_descriptor_limit.h",
            "spec/fixtures/stdlib/native/uv_stdio_probe.c",
            "spec/fixtures/stdlib/native/uv_stdio_probe.h",
            "spec/fixtures/stdlib/native/uv_coverage_pty.h",
            "spec/fixtures/stdlib/titan/os_exit_app.titan",
            "spec/fixtures/stdlib/titan/os_parent_stdin_app.titan",
            "spec/fixtures/stdlib/titan/os_descriptor_limit_app.titan",
            "spec/fixtures/stdlib/titan/os_read_failure_app.titan",
            "spec/fixtures/stdlib/titan/os_shutdown_admission_app.titan",
            "spec/fixtures/stdlib/titan/os_parent_tty_app.titan",
            "spec/fixtures/stdlib/titan/ssl_http_sanitizer_app.titan",
            "spec/fixtures/stdlib/titan/http_tls_idle_app.titan",
            "spec/fixtures/stdlib/titan/http_tcp_idle_app.titan",
            "spec/fixtures/stdlib/titan/uv_stdio_app.titan",
            "spec/fixtures/stdlib/titan/uv_bootstrap/uv_bootstrap_app.titan",
            "spec/fixtures/stdlib/titan/uv_bootstrap/uv_sync_app.titan",
            "spec/fixtures/test_runner/test_runner_bootstrap.titan",
            "spec/fixtures/ssl/ca.pem",
            "spec/fixtures/ssl/server.pem",
            "spec/fixtures/ssl/server-key.pem",
            "spec/fixtures/ssl/wrong-server.pem",
            "spec/fixtures/ssl/coverage-fixtures.md",
            "spec/fixtures/ssl/coverage-certificate-trailing-der.pem",
            "spec/fixtures/ssl/coverage-encrypted-rsa-key.pem",
            "spec/fixtures/ssl/coverage-key-trailing-der.pem",
            "spec/fixtures/ssl/coverage-mismatched-key.pem",
            "spec/fixtures/ssl/coverage-trusted-ca.pem",
            "spec/fixtures/ssl/coverage-unsupported-certificate.pem",
            "spec/fixtures/ssl/coverage-unsupported-key.pem",
            "spec/stdlib/titan/path/tests.titan",
            "spec/path_spec.lua",
            "spec/support/path_cases.lua",
            "doc/language/standard-library-path.md",
            "doc/implementation/standard-library-path.md",
            "LICENSES/go-LICENSE",
            "spec/stdlib/titan/json/tests/tests.titan",
            "spec/stdlib/titan/json/tests/parser_test.titan",
            "spec/stdlib/titan/json/tests/mapping_test.titan",
            "spec/stdlib/titan/json/tests/core_test.titan",
            "doc/language/standard-library-json.md",
            "doc/implementation/json-library.md",
            "doc/language/standard-library-transfer.md",
            "doc/implementation/transfer-library.md",
            "spec/stdlib/titan/thread/tests/tests.titan",
            "spec/stdlib/titan/thread/tests/ownership_test.titan",
            "spec/stdlib/titan/thread/tests/wake_test.titan",
            "doc/language/standard-library-thread.md",
            "doc/implementation/thread-library.md",
            "spec/stdlib/titan/protobuf/tests.titan",
            "spec/stdlib/titan/protobuf/protobuf_fixture.h",
            "doc/language/standard-library-protobuf.md",
            "doc/implementation/protobuf-library.md",
            "titan-compiler/test_runner.lua",
            "titan-compiler/coder/closure_transfer.lua",
            "titan-compiler/ffiheaders.lua",
            "titan-compiler/objectmetadata.lua",
            "spec/support/stdlib_test_modules.mk",
            ".agents/skills/titan-websocket/SKILL.md",
            "doc/implementation/websocket-library.md",
            "doc/language/standard-library-websocket.md",
            "spec/conformance/websocket/.gitignore",
            "spec/conformance/websocket/README.md",
            "spec/conformance/websocket/check_reports.py",
            "spec/conformance/websocket/config/fuzzingclient.json",
            "spec/conformance/websocket/config/fuzzingserver.json",
            "spec/conformance/websocket/expected.json",
            "spec/conformance/websocket/fixtures/case_driver.titan",
            "spec/conformance/websocket/fixtures/echo_server.titan",
            "spec/conformance/websocket/pins.json",
            "spec/conformance/websocket/run.py",
            "spec/conformance/websocket/runner_inventory.py",
            "spec/conformance/websocket/test_check_reports.py",
            "spec/conformance/websocket/test_orchestration.py",
            "LICENSES/libuv-LICENSE", "LICENSES/libuv-LICENSE-extra",
            "LICENSES/libuv-tree-LICENSE", "LICENSES/libuv-inet-LICENSE",
            "LICENSES/lpeglabel-LICENSE",
            "LICENSES/lpeg-LICENSE",
            "LICENSES/lpeg-patterns-LICENSE",
            "LICENSES/ta-regex-LICENSE",
            "LICENSES/lua-LICENSE",
            "LICENSES/llhttp-LICENSE",
            "LICENSES/sqlite3-LICENSE",
            "LICENSES/openssl-LICENSE",
            "THIRD_PARTY_NOTICES.md",
        }) do
            assert.truthy(contains_suffix(expected), expected)
        end
        -- The Make lists name the standard-library, runtime, and LPegLabel
        -- sources and headers, and the scripts a recipe runs, which name the
        -- scripts they run in turn. The compiler's browser selection adds the
        -- browser-only standard-library sources (`audited_stdlib_sources`),
        -- the sources' quoted includes and foreign imports name their
        -- checkout headers, and `make browser-sdk` copies the compiler's SDK
        -- assets from titan-runtime/browser. The hand list above keeps only
        -- files that none of these name.
        local makefile = read_file("Makefile")
        local stdlib_sources = source_inventory.audited_stdlib_sources()
        local derived = { table.unpack(stdlib_sources) }
        local function add_make_list(name)
            for _, word in ipairs(source_inventory.makefile_words(name)) do
                local nested = word:match("^%$%(([%w_]+)%)$")
                if nested then add_make_list(nested) else derived[#derived + 1] = word end
            end
        end
        local header_lists = 0
        for name in ("\n" .. makefile):gmatch("\n([%w_]+_TITAN_HEADERS)%s*:=") do
            add_make_list(name)
            header_lists = header_lists + 1
        end
        assert.truthy(header_lists > 0)
        for _, name in ipairs({ "TITAN_RUNTIME_SOURCES",
                "TITAN_SDK_ROOT_HEADERS", "TITAN_SDK_NAMESPACED_HEADERS" }) do
            add_make_list(name)
        end
        local lpeglabel = assert(makefile:match("\nLPEGLABEL_VENDOR_DIR %?= (%S+)\n"))
        for _, name in ipairs({ "LPEGLABEL_SOURCE_NAMES", "LPEGLABEL_HEADER_NAMES" }) do
            for _, word in ipairs(source_inventory.makefile_words(name)) do
                derived[#derived + 1] = lpeglabel .. "/" .. word
            end
        end
        local scripts, named = { "Makefile", "Makefile.win", "scripts/install_compiler.mk", "scripts/browser.mk" }, {}
        local index = 1
        while scripts[index] do
            for script in read_file(scripts[index]):gmatch("scripts/[%w_.-]+") do
                if not named[script] then
                    named[script] = true
                    scripts[#scripts + 1] = script
                    derived[#derived + 1] = script
                end
            end
            index = index + 1
        end
        -- A quoted include or foreign import names a checkout header beside
        -- its includer (`..` and `.` allowed) or, for the standard library,
        -- below titan/; anything else is a system, Lua, or dependency header.
        local function checkout_header(directory, name)
            local path = (directory .. "/" .. name):gsub("/%./", "/"):gsub("^%./", "")
            local previous
            repeat previous = path; path = path:gsub("[^/]+/%.%./", "", 1) until path == previous
            return lfs.attributes(path, "mode") == "file" and path or nil
        end
        local headers, unread = {}, {}
        local function include(path)
            if path and not headers[path] then
                headers[path] = true
                unread[#unread + 1] = path
                derived[#derived + 1] = path
            end
        end
        local function includes(filename)
            for name in read_file(filename):gmatch('#%s*include%s*"([^"]+)"') do
                include(checkout_header(filename:match("^(.*)/"), name))
            end
        end
        for _, source in ipairs(source_inventory.makefile_words("TITAN_RUNTIME_SOURCES")) do
            includes(source)
        end
        for _, source in ipairs(stdlib_sources) do
            for name in read_file(source):gmatch('foreign%s+import%s+"([^"]+)"') do
                include(checkout_header(source:match("^(.*)/"), name) or checkout_header("titan", name))
            end
        end
        while #unread > 0 do includes(table.remove(unread)) end
        assert.truthy(headers["titan-runtime/titan_winloader.h"])
        assert.truthy(headers["titan/transfer_native.h"])
        local assets = browserlink.sdk_assets({ titan_bin = "sdk", libtitan = "sdk/libtitan.a",
            sdk_digests = "sdk/sdk-digests" })
        for _, key in ipairs({ "js_library", "bridge_library", "trace_library", "loader",
                "runner", "runner_module", "node_worker", "page", "module_check" }) do
            derived[#derived + 1] = "titan-runtime/browser/" .. assets[key]:match("[^/\\]+$")
        end
        for _, expected in ipairs(derived) do
            assert.truthy(contains_suffix(expected), expected)
        end
        assert.truthy(contains_suffix("titan-runtime/browser/_titan_browser/windows_job.titan"))
        for _, retired in ipairs({
            "titan/lua.titan",
            "titan/uv/file.titan",
            "titan/uv/os.titan",
            "titan/uv/runtime.titan",
            "titan/uv/task.titan",
            "titan/uv/work.titan",
            "titan/http/http.native.titan",
            "titan/http/client.titan",
            "titan/http/native.titan",
            "titan/http/pool.titan",
            "titan/http/server.titan",
            "titan/http/transfer.titan",
            "titan/http/upgrade.titan",
            "titan/websocket/handshake.titan",
            "titan/websocket/connection.titan",
            "titan/websocket/frames.titan",
            "titan/websocket/native.titan",
        }) do
            assert.falsy(contains_suffix(retired), retired)
        end
        for path in pairs(unpacked_files) do
            assert.falsy(path:find("/lpeglabel-build/", 1, true), path)
            assert.falsy(path:match("/libtitan%-lpeglabel[.]a$"), path)
            assert.falsy(path:match("/vendor/lpeglabel/.*[.]o$"), path)
            assert.falsy(path:find("/llhttp-build/", 1, true), path)
            assert.falsy(path:find("/sqlite3-build/", 1, true), path)
            assert.falsy(path:find("/sqlite-autoconf-", 1, true), path)
            assert.falsy(path:find("/llhttp-release-v", 1, true), path)
            assert.falsy(path:find("/openssl-build/", 1, true), path)
            assert.falsy(path:match("/openssl%-%d"), path)
        end
        -- Keep one standard-library tree. The Windows browser job helper is
        -- a separate build tool, not another standard-library source.
        local root
        for path in pairs(unpacked_files) do
            if path == "Makefile.win" or path:sub(-#"/Makefile.win") == "/Makefile.win" then
                assert.is_nil(root, path)
                root = path:sub(1, -#"Makefile.win" - 1)
            end
        end
        assert.is_string(root)
        local function relative(path)
            return path:sub(1, #root) == root and path:sub(#root + 1) or nil
        end
        local stdlib_files = {}
        for path in pairs(unpacked_files) do
            local file = relative(path)
            if file and file:match("^titan/") then stdlib_files[file:match("[^/]+$")] = file end
        end
        for path in pairs(unpacked_files) do
            local file = relative(path)
            local top = file and file:match("^([^/]+)/")
            if top and top ~= "titan" and top ~= "spec" and top ~= "doc" then
                if file ~= "titan-runtime/browser/_titan_browser/windows_job.titan" then
                    assert.falsy(file:match("%.titan$"), file)
                end
                local duplicated = stdlib_files[file:match("[^/]+$")]
                assert.is_nil(duplicated, file .. " duplicates " .. tostring(duplicated))
            end
        end
    end)

    it("copies a prepared provider pair without compiler test source",
    function()
        if platform.windows then
            pending("Unix Make publication of the paired DSO and Titan static archive")
            return
        end
        workspace = temporary_directory("stdlib-layout-publication")

        local stage = workspace .. "/stage"
        local canonical = workspace .. "/lib/titan/0.6/titan.so"
        local canonical_archive = workspace .. "/lib/titan/0.6/titan.a"

        local function seed_layout()
            make_directory(assert(canonical:match("^(.+)/[^/]+$")))
            write_file(canonical, "prior combined image\n")
            make_directory(workspace .. "/share/titan/0.6/src/titan")
            write_file(workspace .. "/share/titan/0.6/src/titan/test.titan",
                "obsolete compiler-owned support source\n")

        end

        local function assert_published()
            assert_unique_regular_file(canonical)
            assert_unique_regular_file(canonical_archive)
            local same, comparison, comparison_why, comparison_code = run({
                "cmp", "-s", stage .. "/titan.so", canonical,
            })
            assert.truthy(same, comparison .. "\n(" ..
                tostring(comparison_why) .. ", " ..
                tostring(comparison_code) .. ")")
            same, comparison, comparison_why, comparison_code = run({
                "cmp", "-s", stage .. "/titan.a", canonical_archive,
            })
            assert.truthy(same, comparison .. "\n(" ..
                tostring(comparison_why) .. ", " ..
                tostring(comparison_code) .. ")")
            assert.equal(
                lfs.symlinkattributes(stage .. "/titan.so.dSYM", "mode"),
                lfs.symlinkattributes(canonical .. ".dSYM", "mode"),
                canonical .. ".dSYM")
            for _, module in ipairs(STDLIB_MODULES) do
                assert_no_obsolete_module_layout(workspace, module)
            end
            assert_absent(workspace .. "/share/lua/5.5/titan")
            assert_absent(workspace .. "/share/titan/0.6/src/titan/test.titan")
            assert_absent(workspace .. "/lib/lua/5.5/titan.so")
            assert_absent(workspace .. "/lib/lua/5.5/titan.so.dSYM")
        end

        seed_layout()
        assert.equal("file", lfs.attributes(canonical, "mode"),
            "canonical before installation")
        assert_absent(canonical_archive)
        copy_tree(STDLIB_PROVIDER, stage .. "/titan.so")
        copy_tree(STDLIB_STATIC_ARCHIVE, stage .. "/titan.a")
        if lfs.symlinkattributes(STDLIB_PROVIDER .. ".dSYM") then
            copy_tree(STDLIB_PROVIDER .. ".dSYM",
                stage .. "/titan.so.dSYM")
        end
        local install = {
            "make", "--no-print-directory", "-s",
            "PREFIX=" .. PREFIX,
            "ROCKS_TREE=",
            "TITAN_INSTALL_TREE=" .. workspace,
            "TITAN_LUA=" .. LUA,
            "STDLIB_INSTALL_STAGE=" .. stage,
            "publish-stdlib",
        }
        local ok, output, why, code = run(install)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("file", lfs.attributes(canonical, "mode"),
            "canonical after installation")
        assert.equal("file", lfs.attributes(canonical_archive, "mode"),
            "canonical archive after installation")
        assert_published()
    end)

    it("uses the prefix LuaRocks tree and one combined standard image",
    function()
        workspace = temporary_directory("rock-tree")
        local ok, output, why, code
        ok, output = run(clean_environment({
            LUAROCKS, "config", "variables.LUA_DIR",
        }), workspace)
        assert.truthy(ok, output)
        assert.equal(normalized_path(PREFIX),
            normalized_path(assert(output:match("^%s*(.-)%s*$"))))
        ok, output = run(clean_environment({
            LUAROCKS, "config", "rocks_trees",
        }), workspace)
        assert.truthy(ok, output)
        local configured_trees = assert(load("return " .. output,
            "=configured LuaRocks trees", "t", {}))()
        -- Stock LuaRocks retains its configured user tree after --tree. Only
        -- those exact user paths may follow the selected prefix's paths.
        local allowed_user_paths = {
            ["--lr-path"] = {}, ["--lr-cpath"] = {}, ["--lr-bin"] = {},
        }
        for _, tree in ipairs(configured_trees) do
            if type(tree) == "table" and tree.name == "user" then
                local lua_dir = normalized_path(tree.lua_dir or
                    tree.root .. "/share/lua/5.5")
                local lib_dir = normalized_path(tree.lib_dir or
                    tree.root .. "/lib/lua/5.5")
                local bin_dir = normalized_path(tree.bin_dir or
                    tree.root .. "/bin")
                allowed_user_paths["--lr-path"][lua_dir .. "/?.lua"] = true
                allowed_user_paths["--lr-path"][lua_dir .. "/?/init.lua"] = true
                allowed_user_paths["--lr-cpath"][lib_dir .. "/?" ..
                    SHARED_SUFFIX] = true
                allowed_user_paths["--lr-bin"][bin_dir] = true
            end
        end
        local prefix_paths = {
            ["--lr-path"] = {
                normalized_path(LUA_SHAREDIR .. "/?.lua"),
                normalized_path(LUA_SHAREDIR .. "/?/init.lua"),
            },
            ["--lr-cpath"] = {
                normalized_path(LUA_LIBDIR .. "/?" .. SHARED_SUFFIX),
            },
            ["--lr-bin"] = { normalized_path(PREFIX .. "/bin") },
        }
        for _, option in ipairs({ "--lr-path", "--lr-cpath", "--lr-bin" }) do
            ok, output, why, code = run(clean_environment({
                LUAROCKS, "--tree", PREFIX, "path", option,
            }), workspace)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(code) .. ")")
            local entries = 0
            local separator = option == "--lr-bin" and
                not platform.windows and ":" or ";"
            for entry in output:gmatch("[^" .. separator .. "\r\n]+") do
                entries = entries + 1
                local normalized_entry = normalized_path(entry)
                local expected = prefix_paths[option][entries]
                if expected then
                    assert.equal(expected, normalized_entry,
                        option .. ": " .. output)
                else
                    assert.truthy(allowed_user_paths[option][normalized_entry],
                        option .. ": " .. output)
                end
                assert.falsy(normalized_entry:find(
                    normalized_path(workspace .. "/lua_modules"), 1, true), output)
            end
            assert.truthy(entries >= #prefix_paths[option], option .. ": " .. output)
        end

        -- Clean Lua derives its search paths from the physical executable
        -- location; LuaRocks above retains the configured prefix spelling.
        local physical_prefix = assert(compiler_io.new_sync():realpath(PREFIX))
        local runtime_program = string.format([[
            local provider_path = %q
            local support_path = %q
            -- Lua's default cpath spells the support directory relative to
            -- its executable (<prefix>/bin/../lib/lua/5.5); compare the
            -- resolved files, not path spellings.
            local filesystem = require("titan-compiler.io").new_sync()
            local windows = package.config:sub(1, 1) == "\\"
            local normalize = function(path)
                if not path then return nil end
                local resolved = assert(filesystem:realpath(path))
                return windows and resolved:lower() or resolved
            end
            local builtin_coroutine = require "coroutine"
            local builtin_io = require "io"
            local builtin_os = require "os"
            local titan = require "titan"
            local coroutine = require "titan.coroutine"
            local async = require "titan.async"
            local timer = require "titan.timer"
            local titan_io = require "titan.io"
            local peg = require "titan.peg"
            local titan_string = require "titan.string"
            local titan_math = require "titan.math"
            local titan_lua = require "titan.lua"
            local iteration = require "titan.iteration"
            local gc = require "titan.gc"
            local testing = require "titan.test"
            local json = require "titan.json"
            local protobuf = require "titan.protobuf"
            local transfer = require "titan.transfer"
            local titan_thread = require "titan.thread"
            local builtin_string = require "string"
            -- Requiring async initializes its public uv dependency globally.
            -- The returned async-owned Task resolves its methods through the
            -- combined provider without a separate uv require by the consumer.
            local transitive_result
            local transitive = async.run(function()
                timer.yield()
                transitive_result = "transitive"
            end)
            async.loop()
            assert(transitive:status():as_string() == "succeeded")
            assert(transitive_result == "transitive")

            local uv = require "titan.uv"
            local fs = require "titan.fs"
            local net = require "titan.net"
            local ssl = require "titan.ssl"
            local url = require "titan.url"
            local http = require "titan.http"
            local system = require "titan.os"
            assert(type(builtin_coroutine) == "table")
            assert(type(builtin_os) == "table")
            assert(type(titan) == "table")
            assert(type(titan.backtrace) == "function")
            assert(type(titan._loadlibglobal) == "function")
            -- Plain Lua loads the support module from its default
            -- lib/lua/5.5 path; the Titan searcher then finds the provider.
            assert(normalize(package.searchpath("titan", package.cpath)) ==
                normalize(support_path))
            assert(package.searchpath("titan.uv", package.path) == nil)
            local missing, missing_error, missing_stage =
                titan._loadlib(provider_path, "luaopen_titan")
            assert(missing == nil and missing_stage == "init", tostring(missing_error))
            assert(titan._loadlib(support_path, "luaopen_titan"))
            missing, missing_error, missing_stage =
                titan._loadlib(support_path, "luaopen_titan_math")
            assert(missing == nil and missing_stage == "init", tostring(missing_error))
            -- The support image exports only luaopen_titan, so a process that
            -- also preloads libtitan.a cannot interpose its path internals.
            for _, hidden in ipairs({ "loadlib", "titan_install_searcher",
                    "titan_module_preload", "titan_check_abi_entry",
                    "titan_path_lua_executable_dir",
                    "titan_path_lua_compiler_root",
                    "titan_path_lua_expand" }) do
                local found, hidden_error, hidden_stage =
                    titan._loadlib(support_path, hidden)
                assert(found == nil and hidden_stage == "init",
                    hidden .. ": " .. tostring(hidden_error))
            end
            assert(type(coroutine) == "userdata")
            assert(type(uv) == "userdata")
            assert(type(async) == "userdata")
            assert(type(timer) == "userdata")
            assert(type(titan_io) == "userdata")
            assert(type(fs) == "userdata")
            assert(type(net) == "userdata")
            assert(type(ssl) == "userdata")
            assert(type(url) == "userdata")
            assert(type(http) == "userdata")
            assert(type(system) == "userdata")
            assert(type(peg) == "userdata")
            assert(type(titan_string) == "userdata")
            assert(type(titan_math) == "userdata")
            assert(type(titan_lua) == "userdata")
            assert(type(iteration) == "userdata")
            assert(type(gc) == "userdata")
            assert(type(testing) == "userdata")
            assert(type(json) == "userdata")
            assert(type(protobuf) == "userdata")
            assert(type(transfer) == "userdata")
            assert(type(titan_thread) == "userdata")
            local json_source = '{"answer":42,"values":[1,null,3]}'
            assert(json.encode(json.decode(json_source)) == json_source)
            assert(not testing.testing())
            assert(not testing.verbose())
            assert(peg.literal("installed"):match("installed") == 10)
            assert(titan_string.len("installed\0string") == 16)
            assert(titan_math.sqrt(81.0) == 9.0)
            local parsed_url, parse_error =
                url.parse("https://example.com/installed?q=1")
            assert(parse_error == nil)
            assert(parsed_url.authority == "example.com")
            assert(parsed_url.target == "/installed?q=1")
            assert(builtin_string == string)
            for name, module in pairs({
                coroutine = coroutine,
                uv = uv,
                async = async,
                timer = timer,
                io = titan_io,
                fs = fs,
                net = net,
                ssl = ssl,
                url = url,
                http = http,
                os = system,
                peg = peg,
                string = titan_string,
                math = titan_math,
                lua = titan_lua,
                iteration = iteration,
                gc = gc,
                test = testing,
                json = json,
                protobuf = protobuf,
                transfer = transfer,
                thread = titan_thread,
            }) do
                local symbol = "luaopen_titan_" .. name
                assert(package.searchpath("titan." .. name, package.path) == nil)
                assert(package.searchpath("titan." .. name, package.cpath) ==
                    nil)
                local canonical_open = assert(titan._loadlibglobal(
                    provider_path, symbol, "titan." .. name))
                assert(rawequal(canonical_open(), module))
            end
            assert(require "coroutine" == builtin_coroutine)
            assert(require "io" == builtin_io)
            assert(require "os" == builtin_os)
            assert(system.pid() > 0)
            local installed_result
            local task = async.run(function()
                local inner = coroutine.create(function()
                    timer.yield()
                    return "installed"
                end, {})
                installed_result = inner:resume(nil, nil)
            end)
            async.loop()
            assert(task:status():as_string() == "succeeded")
            assert(installed_result == "installed")

            local direct_result
            local direct = async.run(function()
                timer.yield()
                direct_result = "direct"
            end)
            async.loop()
            assert(direct:status():as_string() == "succeeded")
            assert(direct_result == "direct")
        ]], assert(platform.join(physical_prefix,
                "lib/titan/0.6/titan" .. SHARED_SUFFIX)),
            assert(platform.join(physical_prefix,
                "lib/lua/5.5/titan" .. SHARED_SUFFIX)))
        ok, output, why, code = run(clean_environment({
            LUA, "-e", runtime_program,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("compiles and runs outside the checkout using configured Lua paths",
    function()
        workspace = temporary_directory("installed-compiler")
        local source = assert(io.open(workspace .. "/installed.titan", "wb"))
        source:write([[
local async = import "async"
local timer = import "timer"
local ssl = import "ssl"
local url = import "url"
local http = import "http"

local function accepts_tls(_connection: ssl.Connection): boolean
  return true
end

function main(args: {string}): integer
  case async.await<|integer, string|>(function (resolve, _reject, _fatal)
    resolve(42)
  end)
  when success(answer) then
    if answer ~= 42 then return 1 end
  when error(_message) then
    return 1
  end
  timer.sleep(0)
  local parsed?, parse_error? =
    url.parse("https://example.com/short-import")
  if parse_error then return 1 end
  local actual = parsed as url.Url
  if actual.scheme == "https" and actual.path == "/short-import" then
    return 0
  end
  return 1
end
]])
        source:close()

        -- Running the installed driver from the checkout root must not turn it
        -- back into source mode merely because that CWD contains a Makefile.
        local ok, output = run(clean_environment({
            TITANC, "--lua", PREFIX .. "/src/lua-5.5.1", "installed",
        }))
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--lua is only available in a source checkout", 1, true), output)

        ok, output = run(clean_environment({
            TITANC, "--lua", PREFIX .. "/src/lua-5.5.1", "installed",
        }), workspace)
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "--lua is only available in a source checkout", 1, true), output)

        local why, code
        ok, output, why, code = run(clean_environment({
            TITANC, "installed",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local executable = workspace .. (platform.windows and
            "/bin/installed.exe" or "/installed")
        assert_file(executable)
        if platform.windows then
            assert_file(workspace .. "/lib/titan/0.6/installed.dll")
        end
        local generated = read_file(workspace .. "/installed.c")
        assert.truthy(generated:find(
            'titan_module_provider(L, "titan.async", "titan' .. SHARED_SUFFIX .. '")',
            1, true), generated)
        assert.truthy(generated:find(
            'titan_module_provider(L, "titan.timer", "titan' .. SHARED_SUFFIX .. '")',
            1, true), generated)
        for _, module in ipairs({ "async", "timer", "ssl", "url", "http" }) do
            assert.falsy(generated:find("/titan/" .. module .. SHARED_SUFFIX,
                1, true), generated)
        end

        -- This executable is outside the installation, so explicitly select
        -- the provider belonging to the compiler that built it.
        local providers = TITAN_LIBDIR
        if platform.windows then
            providers = workspace .. "/lib/titan/0.6;" .. providers
        end
        ok, output, why, code = run(clean_environment({
            "TITAN_PATH_0_6=" .. providers,
            executable,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("", output)
    end)

    it("loads direct libuv calls lazily for Titan and explicitly for Lua",
    function()
        if platform.windows then
            pending("POSIX lazy undefined libuv symbols and RTLD_GLOBAL provider promotion")
            return
        end
        workspace = temporary_directory("direct-libuv")
        write_file(workspace .. "/provider_probe.h", [[
int titan_uv_provider_probe(void);
]])
        write_file(workspace .. "/provider_probe.c", [[
#include <stddef.h>
#include <uv.h>

int titan_uv_provider_probe(void) {
  unsigned char byte = 0;
  return uv_random(NULL, NULL, &byte, sizeof(byte), 0, NULL);
}
]])
        write_file(workspace .. "/direct_uv.titan", [[
foreign import "provider_probe.h"
local uv = import "uv"

function check(): boolean
  local marker = uv.timer_t.new()
  return (ffi.titan_uv_provider_probe() as integer) == 0 and
         not marker:as_handle_t():is_initialized()
end
]])
        write_file(workspace .. "/lua_direct_uv.titan", [[
foreign import "provider_probe.h"

function check(): boolean
  return (ffi.titan_uv_provider_probe() as integer) == 0
end
]])

        local ok, output = run({ "uname", "-s" }, workspace)
        assert.truthy(ok, output)
        local host = assert(output:match("^%s*(%S+)"))
        local compile = compiler_argv(
            "-std=c99", "-fPIC", "-I", PREFIX .. "/include")
        if host == "Linux" then compile[#compile + 1] = "-D_GNU_SOURCE" end
        for _, word in ipairs({
            "-c", "provider_probe.c", "-o", "provider_probe.o",
        }) do
            compile[#compile + 1] = word
        end
        local why, code
        ok, output, why, code = run(compile, workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        ok, output, why, code = run(clean_environment({
            TITANC, "direct_uv", "-X", "provider_probe.o",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_file(workspace .. "/direct_uv.so")
        local direct_c = read_file(workspace .. "/direct_uv.c")
        assert.truthy(direct_c:find(
            'titan_module_provider(L, "titan.uv", "titan.so")', 1, true), direct_c)
        assert.falsy(direct_c:find("/titan/uv.so", 1, true), direct_c)

        ok, output, why, code = run(clean_environment({
            TITANC, "lua_direct_uv", "-X", "provider_probe.o",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_file(workspace .. "/lua_direct_uv.so")

        ok, output, why, code = run({ "nm", "-u", "direct_uv.so" },
            workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(output:match("[_ ]uv_random[%s\r\n]"), output)

        if host == "Darwin" then
            ok, output, why, code = run({ "otool", "-L", "direct_uv.so" },
                workspace)
        else
            ok, output, why, code = run(
                { "readelf", "-d", "direct_uv.so" }, workspace)
        end
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.falsy(output:find("libuv", 1, true), output)
        assert.falsy(output:find("titan/uv.so", 1, true), output)

        assert.truthy(os.rename(workspace .. "/direct_uv.titan",
            workspace .. "/direct_uv.source"))
        write_file(workspace .. "/consumer.titan", [[
local direct_uv = import "direct_uv"

function main(args: {string}): integer
  if direct_uv.check() then return 0 end
  return 1
end
]])
        ok, output, why, code = run(clean_environment({ TITANC, "consumer" }),
            workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local consumer_c = read_file(workspace .. "/consumer.c")
        assert.truthy(consumer_c:find(
            'titan_module_provider(L, "direct_uv", "direct_uv.so")', 1, true), consumer_c)
        ok, output, why, code = run(clean_environment({
            "TITAN_PATH_0_6=.;" .. TITAN_LIBDIR, "./consumer",
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- A plain Lua host requires the support module from lib/lua/5.5;
        -- its searcher finds the provider through the default Titan path.
        local lua_probe = string.format([[
assert(package.searchpath("titan.uv", package.path) == nil)
assert(package.searchpath("titan", package.cpath) == %q)
assert(package.searchpath("titan.uv", package.cpath) == nil)
require "titan"
local uv = require "titan.uv"
local direct_uv = require "lua_direct_uv"
assert(direct_uv.check())
local marker = uv.timer_t.new()
assert(not marker:as_handle_t():is_initialized())
]], SUPPORT_MODULE)
        local lua_cpath = table.concat({
            workspace .. "/?.so",
            LUA_LIBDIR .. "/?.so",
        }, ";")
        ok, output, why, code = run(clean_environment({
            "LUA_CPATH_5_5=" .. lua_cpath,
            LUA, "-e", lua_probe,
        }), workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)
end)

describe("LuaRocks native payload lifecycle", function()
    local workspace

    after_each(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    it("publishes make, source and binary rocks and cleans only Titan after LuaRocks agrees", function()
        if platform.windows then
            pending("Unix separate-tree lifecycle; Windows uses the matching Lua SDK prefix")
            return
        end
        workspace = temporary_directory("rock-payload-lifecycle")
        local repository = assert(lfs.currentdir())
        local source = workspace .. "/source repository"
        local outside = workspace .. "/unrelated working directory"
        local trees = {
            workspace .. "/make tree", workspace .. "/source tree",
            workspace .. "/binary tree",
        }
        local function environment(argv)
            local isolated = {
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
            }
            for _, argument in ipairs(argv) do isolated[#isolated + 1] = argument end
            return clean_environment(isolated)
        end
        make_directory(source)
        make_directory(outside)
        local owned = {
            "include/titan.h", "include/minicoro.h", "include/transfer.h", "include/titan/ffi.h",
            "lib/titan/0.6/libtitan.a", "lib/titan/0.6/titan" .. SHARED_SUFFIX,
            "share/titan/NOTICE", "etc/titan/build-profile",
        }
        if not platform.windows then owned[#owned + 1] = "lib/titan/0.6/titan.a" end
        local dependency_sdk = {
            "lib/libbacktrace.a", "include/uv.h", "include/openssl/ssl.h",
            "src/lua-5.5.1/lua.h", "lib/liblua.a",
        }
        for _, inventory in ipairs({ owned, dependency_sdk }) do
            for _, path in ipairs(inventory) do
                make_directory(assert((source .. "/titan-sdk/" .. path):match("^(.+)/[^/]+$")))
                write_file(source .. "/titan-sdk/" .. path, "fixture payload: " .. path .. "\n")
            end
        end
        copy_tree("scripts/titan_install.lua", source .. "/installer/titan_install.lua")
        copy_tree("scripts/titan-install", source .. "/titan-install")
        copy_tree("scripts/titan-uninstall", source .. "/titan-uninstall")
        -- LuaRocks deploys and owns the `titan` support module as an
        -- ordinary native module in the tree's lib/lua/5.5.
        local support_name = "titan" .. SHARED_SUFFIX
        local support = "fixture support module\n"
        write_file(source .. "/" .. support_name, support)
        write_file(source .. "/Makefile", string.format([[
.PHONY: all install
all:
	@:
install:
	mkdir -p "$(INST_PREFIX)" "$(INST_BINDIR)" "$(INST_LIBDIR)"
	cp -R titan-sdk installer "$(INST_PREFIX)/"
	install -m 0755 titan-install "$(INST_BINDIR)/titan-install"
	install -m 0755 titan-uninstall "$(INST_BINDIR)/titan-uninstall"
	install -m 0755 %s "$(INST_LIBDIR)/%s"
]], support_name, support_name))
        local specification = {}
        assert(load(read_file("titan-0.6.0-1.rockspec"), "=production rockspec", "t", specification))()
        local hook = assert(specification.hooks.post_install)
        if platform.windows then hook = assert(specification.hooks.platforms.windows.post_install) end
        local copy_directories = {}
        for _, directory in ipairs(specification.build.copy_directories) do
            make_directory(source .. "/" .. directory)
            write_file(source .. "/" .. directory .. "/fixture.txt", directory .. "\n")
            copy_directories[#copy_directories + 1] = string.format("%q", directory)
        end
        local rockspec = source .. "/titan-0.6.0-1.rockspec"
        write_file(rockspec, string.format([[
rockspec_format = "3.0"
package = "titan"
version = "0.6.0-1"
source = { url = %q }
description = { summary = "Tiny Titan installation fixture", license = "MIT" }
dependencies = { "lua ~> 5.5" }
hooks = { post_install = %q }
build = {
    type = "make",
    install_variables = {
        INST_PREFIX = "$(PREFIX)", INST_BINDIR = "$(BINDIR)",
        INST_LUADIR = "$(LUADIR)", INST_LIBDIR = "$(LIBDIR)"
    },
    copy_directories = { %s }
}
]], "git+file://" .. source:gsub("\\", "/"), hook, table.concat(copy_directories, ", ")))
        for _, argv in ipairs({
            { "git", "init", "-q", source },
            { "git", "-C", source, "add", "-f", "." },
            { "git", "-C", source, "-c", "user.name=Titan installation test",
                "-c", "user.email=titan-install@example.invalid", "commit", "-qm", "fixture" },
        }) do
            local ok, output = run(argv)
            assert.truthy(ok, output)
        end
        local function luarocks(tree, ...)
            local argv = { LUAROCKS, "--tree", tree, ... }
            local ok, output = run(environment(argv), outside)
            assert.truthy(ok, output)
            return output
        end
        local function private(tree)
            return tree .. "/lib/luarocks/rocks-5.5/titan/0.6.0-1"
        end
        local function assert_installed(tree)
            local retained = private(tree)
            local manifest = load_rock_manifest(retained .. "/rock_manifest")
            assert.truthy(manifest.lib[support_name])
            assert.equal(support, read_file(tree .. "/lib/lua/5.5/" .. support_name))
            assert_file(retained .. "/installer/titan_install.lua")
            assert_file(retained .. "/bin/titan-install")
            assert_file(tree .. "/bin/titan-install")
            assert_file(retained .. "/bin/titan-uninstall")
            assert_file(tree .. "/bin/titan-uninstall" .. (platform.windows and ".bat" or ""))
            local location = assert(loadfile(retained .. "/installer/location.lua", "t", {}))()
            assert.equal(normalized_path(tree), normalized_path(location.tree))
            assert.equal(normalized_path(PREFIX), normalized_path(location.lua_dir))
            for _, inventory in ipairs({ owned, dependency_sdk }) do
                for _, path in ipairs(inventory) do
                    local contents = read_file(source .. "/titan-sdk/" .. path)
                    assert.equal(contents, read_file(retained .. "/titan-sdk/" .. path), path)
                    assert.equal(contents, read_file(tree .. "/" .. path), path)
                end
            end
        end
        local ok, output = run(environment({ LUAROCKS, "--tree", trees[1],
            "make", rockspec, "--deps-mode=none" }), source)
        assert.truthy(ok, output)
        assert_installed(trees[1])
        local packed, pack_output = run(environment({ LUAROCKS, "pack", rockspec }), outside)
        assert.truthy(packed, pack_output)
        local source_rock = outside .. "/titan-0.6.0-1.src.rock"
        assert_file(source_rock)
        luarocks(trees[2], "install", source_rock, "--deps-mode=none")
        assert_installed(trees[2])
        local arch = luarocks(trees[1], "config", "arch"):match("^%s*(.-)%s*$")
        ok, output = run(environment({ "make", "--no-print-directory", "-s", "-f",
            repository .. (platform.windows and "/Makefile.win" or "/Makefile"),
            "PREFIX=" .. PREFIX, "ROCKS_TREE=" .. trees[1], "TITAN_LUAROCKS=" .. LUAROCKS,
            "binary-rock" }), outside)
        assert.truthy(ok, output)
        local binary_rock = outside .. "/titan-0.6.0-1." .. arch .. ".rock"
        assert_file(binary_rock)
        luarocks(trees[3], "install", binary_rock, "--deps-mode=none",
            "MAKE=" .. workspace .. "/unavailable make")
        assert_installed(trees[3])

        local function install_dependency(name, module, dependencies)
            write_file(outside .. "/" .. module .. ".lua", "return true\n")
            local path = outside .. "/" .. name .. "-1.0-1.rockspec"
            write_file(path, string.format([[
rockspec_format = "3.0"
package = %q
version = "1.0-1"
source = { url = "file:///unused" }
description = { license = "MIT" }
dependencies = { %s }
build = { type = "builtin", modules = { [%q] = %q } }
]], name, dependencies, module, module .. ".lua"))
            luarocks(trees[3], "make", path, "--deps-mode=none")
        end
        install_dependency("titan-install-test-keep", "fixture_dependency", '"lua ~> 5.5"')
        install_dependency("titan-install-test-dependent", "fixture_dependent", '"titan == 0.6.0-1"')

        -- Exercise the real deployed wrapper and LuaRocks' own exact-version
        -- removal, including rollback of a refused post_install hook.
        local tree = trees[3]
        local function module_tool(tool, ...)
            return run(environment({ tree .. "/bin/titan-" .. tool, ... }), outside)
        end
        assert.truthy(module_tool("install", "--help"))
        assert.truthy(module_tool("uninstall", "--help"))
        assert.falsy(module_tool("install", "--module", private(tree)))
        assert.falsy(module_tool("install", "--path", private(trees[1])))
        assert.falsy(module_tool("install", "--path", private(tree)))
        assert.falsy(module_tool("uninstall", "titan-install-test-keep", "1.0-1"))
        assert.falsy(module_tool("uninstall", "titan", "0.6.0-1"))
        local function module_rock(name, version, payload, expected_error)
            local base = workspace .. "/" .. name .. "-" .. version
            make_directory(base)
            local rockspec_path = base .. "/" .. name .. "-" .. version .. ".rockspec"
            write_file(rockspec_path, string.format([[
rockspec_format = "3.0"
package = %q
version = %q
source = { url = "file:///unused" }
description = { license = "MIT" }
dependencies = { "titan == 0.6.0-1" }
hooks = { post_install = '"$(SCRIPTS_DIR)/titan-install" --path "$(PREFIX)"' }
build = { type = "builtin", modules = {}, copy_directories = { "dist" } }
]], name, version))
            remove_tree(base .. "/dist")
            for path, contents in pairs(payload) do
                local staged = base .. "/dist/" .. path
                make_directory(assert(staged:match("^(.+)/[^/]+$")))
                write_file(staged, contents)
            end
            local installed, log = run(environment({
                LUAROCKS, "--tree", tree, "make", rockspec_path, "--deps-mode=none", "--keep",
            }), base)
            if expected_error then
                assert.falsy(installed, log)
                assert.truthy(log:find(expected_error, 1, true), log)
            else
                assert.truthy(installed, log)
            end
            return tree .. "/lib/luarocks/rocks-5.5/" .. name .. "/" .. version
        end
        local module_name, other_name = "fixture-titan-first", "fixture-titan-second"
        local module_lib = tree .. "/lib/titan/0.6"
        local old = module_rock(module_name, "1.0-1", {
            ["modules/fixture/nested/old.titan"] = "old source",
            ["include/shared/header.h"] = "first header",
            ["lib/named/archive.a"] = "first archive",
        })
        assert.equal("old source", read_file(module_lib .. "/fixture/nested/old.titan"))
        assert.equal("first header", read_file(tree .. "/include/shared/header.h"))
        assert.equal("first archive", read_file(tree .. "/lib/named/archive.a"))
        local other = module_rock(other_name, "1.0-1", {
            ["modules/fixture/second.titan"] = "second source",
            ["include/shared/other.h"] = "second header",
        })
        module_rock(module_name, "1.0-1", {
            ["modules/fixture/first.titan"] = "same-version replacement",
        })
        assert_absent(module_lib .. "/fixture/nested")
        assert_absent(tree .. "/include/shared/header.h")
        assert_absent(tree .. "/lib/named")
        assert.equal("same-version replacement", read_file(module_lib .. "/fixture/first.titan"))
        local active = module_rock(module_name, "2.0-1", {
            ["modules/fixture/current.titan"] = "new active version",
        })
        assert_absent(module_lib .. "/fixture/first.titan")
        assert_file(old .. "/rock_manifest")
        local refused = module_rock(other_name, "2.0-1", {
            ["modules/fixture/current.titan"] = "foreign owner",
            ["include/must-not-write.h"] = "preflight must check all files first",
        }, "module destination already exists")
        assert_absent(refused)
        assert_absent(tree .. "/include/must-not-write.h")
        assert.truthy(module_tool("uninstall", module_name, "1.0-1"))
        assert_absent(old)
        assert_file(active .. "/rock_manifest")
        assert.equal("new active version", read_file(module_lib .. "/fixture/current.titan"))
        install_dependency("titan-install-test-consumer", "fixture_consumer",
            '"' .. module_name .. ' == 2.0-1"')
        ok, output = module_tool("uninstall", module_name)
        assert.falsy(ok, output)
        assert.truthy(output:find("Titan module files were preserved", 1, true), output)
        assert_file(active .. "/rock_manifest")
        assert.equal("new active version", read_file(module_lib .. "/fixture/current.titan"))
        luarocks(tree, "remove", "titan-install-test-consumer", "1.0-1")
        luarocks(tree, "remove", module_name, "2.0-1")
        assert_absent(active)
        assert_file(module_lib .. "/fixture/current.titan")
        assert.truthy(module_tool("uninstall", module_name, "2.0-1"))
        assert.truthy(module_tool("uninstall", module_name))
        assert_absent(module_lib .. "/fixture/current.titan")
        assert.equal("second source", read_file(module_lib .. "/fixture/second.titan"))
        assert.equal("second header", read_file(tree .. "/include/shared/other.h"))
        assert.truthy(module_tool("uninstall", other_name))
        assert_absent(other)
        assert_absent(module_lib .. "/fixture")
        assert_absent(tree .. "/include/shared")

        local alias_name = "fixture-titan-alias-version"
        local alias_first = module_rock(alias_name, "1.01-1", {
            ["include/alias-version.h"] = "first spelling",
        })
        local alias_second = module_rock(alias_name, "1.1-1", {
            ["include/alias-version.h"] = "second spelling",
        })
        ok, output = module_tool("uninstall", alias_name, "1.1-1")
        assert.falsy(ok, output)
        assert.truthy(output:find("without also matching 1.01-1", 1, true), output)
        assert_file(alias_first .. "/rock_manifest")
        assert_file(alias_second .. "/rock_manifest")
        assert.equal("second spelling", read_file(tree .. "/include/alias-version.h"))
        luarocks(tree, "remove", alias_name)
        assert.truthy(module_tool("uninstall", alias_name))

        local preserved = {
            "bin/lua" .. PROGRAM_SUFFIX, "include/unrelated.h", "include/titan/keep.h",
            "share/titan/user-note.txt",
        }
        for _, path in ipairs(preserved) do
            make_directory(assert((trees[3] .. "/" .. path):match("^(.+)/[^/]+$")))
            write_file(trees[3] .. "/" .. path, "preserved: " .. path .. "\n")
        end
        local function uninstall(tree)
            local argv = platform.windows and { LUA, private(tree) .. "/bin/titan-uninstall" } or
                { tree .. "/bin/titan-uninstall" }
            if tree == trees[3] then
                argv[#argv + 1] = "--luarocks"
                argv[#argv + 1] = LUAROCKS
            end
            return run(environment(argv), outside)
        end
        ok, output = uninstall(trees[3])
        assert.falsy(ok, output)
        assert.truthy(output:find("Titan SDK files were preserved", 1, true), output)
        assert_installed(trees[3])
        luarocks(trees[3], "remove", "titan-install-test-dependent")
        for _, tree in ipairs(trees) do
            ok, output = uninstall(tree)
            assert.truthy(ok, output)
            for _, path in ipairs(owned) do assert_absent(tree .. "/" .. path) end
            assert_absent(private(tree))
            assert_absent(tree .. "/lib/lua/5.5/" .. support_name)
            assert_absent(tree .. "/bin/titan-install")
            assert_absent(tree .. "/bin/titan-uninstall" .. (platform.windows and ".bat" or ""))
            for _, path in ipairs(dependency_sdk) do
                assert.equal(read_file(source .. "/titan-sdk/" .. path), read_file(tree .. "/" .. path))
            end
        end
        for _, path in ipairs(preserved) do
            assert.equal("preserved: " .. path .. "\n", read_file(trees[3] .. "/" .. path))
        end
        assert.equal("return true\n", read_file(trees[3] .. "/share/lua/5.5/fixture_dependency.lua"))
        assert_file(trees[3] .. "/lib/luarocks/rocks-5.5/titan-install-test-keep/1.0-1/rock_manifest")
    end)
end)

describe("automatic Lua prefix selection", function()
    local workspace
    local repository
    local make_command
    local tools_path
    local inspection

    local function checked_run(argv)
        local ok, output = run(argv, workspace)
        assert.truthy(ok, output)
        return output
    end

    local function environment(path, extra)
        local argv = { "env" }
        for _, name in ipairs({
            "TITAN_BUILD_PROFILE", "PREFIX", "MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "MAKELEVEL",
            "GNUMAKEFLAGS", "LUA_INIT", "LUA_INIT_5_5", "LUA_PATH",
            "LUA_PATH_5_5", "LUA_CPATH", "LUA_CPATH_5_5",
        }) do
            argv[#argv + 1] = "-u"
            argv[#argv + 1] = name
        end
        argv[#argv + 1] = "PATH=" .. path
        for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
        return argv
    end

    local function inspect(path, arguments, extra_environment, include_sdk)
        local argv = environment(path, extra_environment)
        for _, word in ipairs({
            make_command, "--no-print-directory", "-s",
            "-f", repository .. "/Makefile", "-f", inspection,
            "HOST_OS=Linux", "HOST_ARCH=prefix-probe",
            "TEST_LUA=false",
            include_sdk and "inspect-prefix-sdk" or "inspect-prefix",
        }) do argv[#argv + 1] = word end
        -- TEST_LUA=false suppresses the unrelated native-test SDK probe; this
        -- inspection exercises only PREFIX discovery and SDK path selection.
        for _, word in ipairs(arguments or {}) do argv[#argv + 1] = word end
        return checked_run(argv)
    end

    local function detect(path)
        local argv = environment(path)
        argv[#argv + 1] = "/bin/sh"
        argv[#argv + 1] = repository .. "/scripts/detect_lua_prefix.sh"
        return checked_run(argv)
    end

    local function copy_lua(prefix)
        make_directory(prefix .. "/bin")
        checked_run({ "cp", "-p", LUA, prefix .. "/bin/lua" })
        return prefix .. "/bin:" .. tools_path
    end

    local function prefix_output(prefix)
        return prefix .. "\n" .. prefix .. "/bin/lua\n"
    end

    before_each(function()
        if platform.windows then return end
        repository = assert(lfs.currentdir())
        workspace = temporary_directory("prefix-discovery")
        workspace = assert(checked_run({ "pwd", "-P" }):match("^(.-)\n$"))
        make_command = assert(checked_run({ "sh", "-c", "command -v make" })
            :match("^(.-)\n$"))
        tools_path = workspace .. "/tools"
        make_directory(tools_path)
        checked_run({ "ln", "-s", "/bin/sh", tools_path .. "/sh" })
        -- The detector follows launcher symlinks with readlink.
        for _, tool in ipairs({ "uname", "readlink" }) do
            local path = assert(checked_run({ "sh", "-c", "command -v " .. tool })
                :match("^(.-)\n$"))
            checked_run({ "ln", "-s", path, tools_path .. "/" .. tool })
        end
        inspection = workspace .. "/inspect.mk"
        -- The semicolons force Make through the shell's printf builtin, so
        -- this intentionally narrow PATH needs no external printf program.
        write_file(inspection, [[
.PHONY: inspect-prefix inspect-prefix-sdk
inspect-prefix:
	@printf '%s\n' '$(PREFIX)' '$(LUA_BIN)';
inspect-prefix-sdk:
	@printf '%s\n' '$(PREFIX)' '$(LUA_BIN)' '$(TITAN_RUNTIME_LUA_SOURCE_PATH)' '$(TITAN_RUNTIME_LUA_LIB)';
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    it("selects PATH Lua before LuaRocks or Titan have been installed",
    function()
        if platform.windows then
            pending("POSIX PATH Lua discovery through detect_lua_prefix.sh and Unix Make")
            return
        end
        local prefix = workspace .. "/prefix"
        local path = copy_lua(prefix)
        assert.equal(prefix_output(prefix), inspect(path))
        assert_absent(prefix .. "/bin/luarocks")
        assert_absent(prefix .. "/lib/titan")
        assert_absent(prefix .. "/src")
    end)

    it("selects an independent validation prefix instead of the active PATH SDK",
    function()
        if platform.windows then
            pending("Unix Make selects the implicit .lua-validation prefix")
            return
        end
        local prefix = workspace .. "/prefix"
        local path = copy_lua(prefix)
        assert.equal(prefix_output(workspace .. "/.lua-validation"),
            inspect(path, nil, { "TITAN_BUILD_PROFILE=validation" }))
    end)

    it("preserves directory aliases and resolves external launcher symlinks",
    function()
        if platform.windows then
            pending("POSIX Lua prefix discovery through directory and executable symlinks")
            return
        end
        local prefix = workspace .. "/prefix"
        copy_lua(prefix)
        local alias = workspace .. "/alias"
        checked_run({ "ln", "-s", prefix, alias })
        assert.equal(prefix_output(alias), inspect(alias .. "/bin:" .. tools_path))
        assert.equal(prefix_output(workspace .. "/alias"),
            inspect("alias/bin:" .. tools_path))

        local launcher = workspace .. "/launcher/bin"
        make_directory(launcher)
        checked_run({ "ln", "-s", prefix .. "/bin/lua", launcher .. "/lua" })
        assert.equal(prefix_output(prefix), inspect(launcher .. ":" .. tools_path))
    end)

    it("detects a Lua prefix containing spaces", function()
        if platform.windows then
            pending("POSIX detect_lua_prefix.sh discovers an executable prefix with spaces")
            return
        end
        local prefix = workspace .. "/prefix with spaces"
        assert.equal(prefix .. "\n", detect(copy_lua(prefix)))
    end)

    it("keeps explicit environment and command-line prefixes without probing Lua",
    function()
        if platform.windows then
            pending("Unix Make PREFIX precedence avoids executing POSIX shell sentinels")
            return
        end
        local marker = workspace .. "/lua-was-probed"
        local lua = tools_path .. "/lua"
        write_file(lua, "#!/bin/sh\n: > " .. quote(marker) .. "\nexit 1\n")
        checked_run({ "chmod", "+x", lua })
        local configured = workspace .. "/configured"
        assert.equal(prefix_output(configured),
            inspect(tools_path, nil, { "PREFIX=" .. configured }))
        local selected = workspace .. "/selected"
        assert.equal(prefix_output(selected), inspect(tools_path,
            { "PREFIX=" .. selected }, { "PREFIX=" .. configured }))
        assert_absent(marker)
    end)

    it("ignores ambient Lua startup code and module paths", function()
        if platform.windows then
            pending("POSIX Lua prefix discovery ignores ambient Lua startup configuration")
            return
        end
        local prefix = workspace .. "/prefix"
        local path = copy_lua(prefix)
        local marker = workspace .. "/lua-init-was-run"
        local init = string.format(
            "assert(io.open(%q, 'w')):close(); error('unexpected startup')", marker)
        assert.equal(prefix_output(prefix), inspect(path, nil, {
            "LUA_INIT=" .. init, "LUA_INIT_5_5=" .. init,
            "LUA_PATH=/unrelated/?.lua", "LUA_PATH_5_5=/unrelated/?.lua",
            "LUA_CPATH=/unrelated/?.so", "LUA_CPATH_5_5=/unrelated/?.so",
        }))
        assert_absent(marker)
    end)

    it("falls back when PATH has no Lua or an interpreter that fails",
    function()
        if platform.windows then
            pending("Unix Make falls back to /usr/local when POSIX PATH has no usable Lua")
            return
        end
        assert.equal(prefix_output("/usr/local"), inspect(tools_path))
        write_file(tools_path .. "/lua", "#!/bin/sh\nexit 1\n")
        checked_run({ "chmod", "+x", tools_path .. "/lua" })
        assert.equal(prefix_output("/usr/local"), inspect(tools_path))
    end)

    it("rejects incompatible interpreter versions", function()
        if platform.windows then
            pending("POSIX Lua prefix detector rejects an incompatible PATH interpreter")
            return
        end
        local lua = tools_path .. "/lua"
        -- Run the real interpreter with another version before the
        -- detector's -e chunk, without requiring another system Lua version.
        write_file(lua, "#!/bin/sh\nexec " .. quote(LUA) ..
            " -E -e " .. quote('_VERSION = "Lua 5.4"') .. " \"$@\"\n")
        checked_run({ "chmod", "+x", lua })
        assert.equal(prefix_output("/usr/local"), inspect(tools_path))
    end)

    it("retains an incomplete detected SDK so its missing archive is an error",
    function()
        if platform.windows then
            pending("Unix Make diagnoses a detected SDK missing its liblua.a")
            return
        end
        local prefix = workspace .. "/prefix"
        local path = copy_lua(prefix)
        make_directory(prefix .. "/src/lua-5.5.1")
        for _, header in ipairs({ "lua.h", "lobject.h" }) do
            write_file(prefix .. "/src/lua-5.5.1/" .. header, "header fixture\n")
        end
        assert.equal(prefix .. "\n" .. prefix .. "/bin/lua\n" ..
            prefix .. "/src/lua-5.5.1\n" .. prefix .. "/lib/liblua.a\n",
            inspect(path, nil, nil, true))
        local argv = environment(path, { "LC_ALL=C" })
        for _, word in ipairs({
            make_command, "--no-print-directory", "-s",
            "-f", repository .. "/Makefile", "HOST_OS=Linux",
            "HOST_ARCH=prefix-probe",
            "TEST_LUA=false", prefix .. "/lib/liblua.a",
        }) do argv[#argv + 1] = word end
        local ok, output = run(argv, workspace)
        assert.falsy(ok, output)
        assert.truthy(output:find("No rule to make target", 1, true), output)
        assert.truthy(output:find(prefix .. "/lib/liblua.a", 1, true), output)
        assert_absent(workspace .. "/lua-5.5.1")
    end)
end)

describe("installed Lua SDK Make inputs", function()
    local workspace

    after_each(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    it("selects matching installed inputs while preserving source overrides",
    function()
        if platform.windows then
            pending("Unix Make selects the installed Lua source tree and matching static archive")
            return
        end
        workspace = temporary_directory("lua-sdk-selection")
        local repository = assert(lfs.currentdir())
        local inspection = workspace .. "/inspect.mk"
        write_file(inspection, [[
.PHONY: inspect-lua-sdk
inspect-lua-sdk:
	@printf '%s\n' '$(TITAN_RUNTIME_LUA_SOURCE_PATH)' '$(TITAN_RUNTIME_LUA_LIB)' '$(LUA_SDK_PREREQ)'
]])
        local function inputs(prefix, extra)
            local argv = {
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "make", "--no-print-directory", "-f", repository .. "/Makefile",
                "-f", inspection, "PREFIX=" .. prefix, "inspect-lua-sdk",
            }
            for _, word in ipairs(extra or {}) do argv[#argv + 1] = word end
            local ok, output = run(argv, workspace)
            assert.truthy(ok, output)
            return output
        end

        assert.equal(PREFIX .. "/src/lua-5.5.1\n" ..
            PREFIX .. "/lib/liblua.a\n\n", inputs(PREFIX))
        local selected = workspace .. "/custom-lua-src"
        assert.equal(selected .. "\n" .. selected .. "/liblua.a\n\n",
            inputs(PREFIX, { "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. selected }))
        local archive = workspace .. "/custom-liblua.a"
        assert.equal(selected .. "\n" .. archive .. "\n\n",
            inputs(PREFIX, {
                "TITAN_RUNTIME_LUA_SOURCE_PATH=" .. selected,
                "TITAN_RUNTIME_LUA_LIB=" .. archive,
            }))

        local unprepared = workspace .. "/unprepared-prefix"
        local fallback = "lua-5.5.1/src\nlua-5.5.1/src/liblua.a\n" ..
            "lua\n"
        assert.equal(fallback, inputs(unprepared))
        make_directory(unprepared .. "/src/lua-5.5.1")
        for _, header in ipairs({ "lua.h", "lobject.h" }) do
            copy_tree(PREFIX .. "/src/lua-5.5.1/" .. header,
                unprepared .. "/src/lua-5.5.1/" .. header)
        end
        assert.equal(unprepared .. "/src/lua-5.5.1\n" ..
            unprepared .. "/lib/liblua.a\n\n", inputs(unprepared))
        assert_absent(workspace .. "/lua-5.5.1")
    end)

    it("rejects installed headers without their matching Lua archive",
    function()
        if platform.windows then
            pending("Unix Make runtime prerequisite rejects an SDK without liblua.a")
            return
        end
        workspace = temporary_directory("incomplete-lua-sdk")
        local repository = assert(lfs.currentdir())
        local incomplete = workspace .. "/prefix"
        copy_tree(PREFIX .. "/src/lua-5.5.1",
            incomplete .. "/src/lua-5.5.1")
        for _, source in ipairs({ "titan.c", "titan.h", "transfer.h", "titan/ffi.h" }) do
            copy_tree("titan-runtime/" .. source,
                workspace .. "/titan-runtime/" .. source)
        end
        local ok, output = run({
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
            "LC_ALL=C", "make", "--no-print-directory",
            "-f", repository .. "/Makefile", "PREFIX=" .. incomplete,
            "LIBBT_DIR=" .. repository .. "/libbacktrace", "runtime",
        }, workspace)
        assert.falsy(ok, output)
        assert.truthy(output:find("No rule to make target", 1, true), output)
        assert.truthy(output:find(incomplete .. "/lib/liblua.a", 1, true), output)
        assert_absent(workspace .. "/lua-5.5.1")
    end)

    it("builds and stages native targets without a checkout Lua tree",
    function()
        if platform.windows then
            pending("Unix Make builds runtime/bootstrap/native archives against the installed Lua SDK")
            return
        end
        workspace = temporary_directory("installed-lua-sdk-build")
        local repository = assert(lfs.currentdir())
        copy_tree("LICENSE", workspace .. "/LICENSE")
        for _, source in ipairs({
            "titan.c", "titan.h", "minicoro.c", "minicoro.h", "transfer.h",
            "titan_path.c", "ltitanlib.c", "titan/ffi.h", "titan/browser.h",
        }) do
            copy_tree("titan-runtime/" .. source,
                workspace .. "/titan-runtime/" .. source)
        end
        -- The support link reads the export map relative to Make's working
        -- directory, like the runtime sources copied above.
        copy_tree("scripts/titan_support_exports.map",
            workspace .. "/scripts/titan_support_exports.map")
        copy_tree("vendor/lpeglabel", workspace .. "/vendor/lpeglabel")
        local stage = workspace .. "/sdk"
        local libbacktrace = PREFIX .. "/lib/libbacktrace.a"
        local llhttp_header = PREFIX .. "/include/llhttp.h"
        local sqlite_header = PREFIX .. "/include/sqlite3.h"
        -- Reuse only the unrelated prepared native dependencies. Lua's own
        -- targets remain fully active, so an accidental source dependency
        -- fails against the deliberately absent checkout Lua tree.
        local ok, output = run({
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
            "CCACHE_DISABLE=1", "make", "--no-print-directory",
            "-f", repository .. "/Makefile", "PREFIX=" .. PREFIX,
            "ROCKS_TREE=" .. stage, "OPENSSL_MODE=system",
            "LIBUV_LIB=" .. repository .. "/libuv-build/libuv.a",
            "LIBUV_SRC_DIR=" .. repository .. "/libuv-v1.53.0",
            "--old-file=" .. repository .. "/libuv-build/libuv.a",
            "LIBBT_DIR=" .. repository .. "/libbacktrace",
            "LIBBT_LIB=" .. libbacktrace,
            "LLHTTP_HEADER=" .. llhttp_header, "SQLITE3_HEADER=" .. sqlite_header,
            "--old-file=" .. libbacktrace,
            "--old-file=" .. llhttp_header, "--old-file=" .. sqlite_header,
            "CFLAGS=-std=c99 -O0 -fPIC", "ROCK_CFLAGS=-O0 -fPIC",
            "runtime", "titan-runtime/bootstrap/titan.so", "lpeglabel",
            "install-titan-sdk",
        }, workspace)
        assert.truthy(ok, output)
        assert_absent(workspace .. "/lua-5.5.1")
        for _, artifact in ipairs({
            "titan-runtime/libtitan.a", "titan-runtime/bootstrap/titan.so",
            "lpeglabel-build/libtitan-lpeglabel.a",
            "sdk/lib/titan/0.6/libtitan.a",
            "sdk/include/titan/ffi.h", "sdk/include/titan/browser.h",
            "sdk/include/uv.h", "sdk/include/uv/version.h",
        }) do
            assert_file(workspace .. "/" .. artifact)
        end
        -- The runtime SDK carries no standard provider and no support module.
        assert_absent(stage .. "/lib/titan/0.6/titan.so")
        assert_absent(stage .. "/lib/lua/5.5/titan.so")
        for _, source in ipairs({ "luaconf.h", "lobject.h", "loadlib.c" }) do
            assert.equal(read_file(PREFIX .. "/src/lua-5.5.1/" .. source),
                read_file(stage .. "/src/lua-5.5.1/" .. source), source)
        end
        assert.equal(read_file(PREFIX .. "/lib/liblua.a"),
            read_file(stage .. "/lib/liblua.a"))
        assert.equal(read_file("LICENSE"),
            read_file(stage .. "/share/titan/LICENSE"))
        ok, output = run({ LUA, "-E", "-e", string.format([[
local open = assert(package.loadlib(%q, "luaopen_titan"))
assert(type(open()._loadlibglobal) == "function")
]], workspace .. "/titan-runtime/bootstrap/titan.so") })
        assert.truthy(ok, output)
    end)
end)

describe("relocatable Lua build configuration", function()
    local workspace

    after_each(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    local function selected_make()
        if not platform.windows then return "make" end
        local ok, output = run({ LUAROCKS, "config", "variables.MAKE" })
        assert.truthy(ok, output)
        local command = assert(output:match("^%s*(.-)%s*$"))
        assert.not_equal("", command)
        return command
    end

    local function prohibit_source_fetch()
        local tools = workspace .. "/tools"
        local marker = workspace .. "/source-fetch-used"
        make_directory(tools)
        for _, name in ipairs({ "git", "curl", "wget" }) do
            local command = tools .. "/" .. name
            write_file(command, "#!/bin/sh\n: > " .. quote(marker) .. "\nexit 91\n")
            local ok, output = run({ "chmod", "+x", command })
            assert.truthy(ok, output)
        end
        local path = os.getenv("PATH") or "/usr/bin:/bin"
        if platform.windows then
            -- These fixtures invoke MSYS env.exe, whose PATH lookup uses
            -- POSIX separators even when its native Lua caller uses Windows.
            local ok, output = run({ "cygpath.exe", "-u", tools })
            assert.truthy(ok, output)
            tools = assert(output:match("^%s*(.-)%s*$"))
            ok, output = run({ "cygpath.exe", "-p", "-u", path })
            assert.truthy(ok, output)
            path = assert(output:match("^%s*(.-)%s*$"))
        end
        return tools .. ":" .. path, marker
    end

    it("preserves Windows Lua linker options in recursive Make arguments", function()
        workspace = temporary_directory("windows-lua-link-argv")
        local repository = assert(lfs.currentdir())
        local root = workspace .. "/windows-build"
        -- Recursive recipes execute under -n, while the preparation targets
        -- marked old and all ordinary recipes remain untouched.
        local ok, output = run({
            "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
            "-u", "MAKEOVERRIDES", "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
            "make", "--no-print-directory", "-n",
            "-f", repository .. "/Makefile.win",
            "WINDOWS_BUILD_ROOT=" .. root,
            "MAKE=printf '<%s>\\n'",
            "LUA_LDFLAGS=-Lsentinel -Wl,--as-needed",
            "--old-file=" .. root .. "/lua-5.5.1/src/lua-windows.res",
            "lua-build",
        }, repository)
        assert.truthy(ok, output)

        -- The caller's linker options reach both Lua links unsplit and first.
        for _, name in ipairs({ "MYLDFLAGS", "MYDLLFLAGS" }) do
            local value = assert(output:match("\n<" .. name .. "=(.-)>\n"), output)
            local words = assert(cdriver.split_shell_words(value))
            assert.same({ "-Lsentinel", "-Wl,--as-needed" }, { words[1], words[2] }, name)
        end
        assert_absent(root)
    end)

    it("rebuilds the Windows stdlib with the installed compiler without reinstalling the rock", function()
        workspace = temporary_directory("windows-stdlib-installed")
        local repository = assert(lfs.currentdir())
        local prefix = workspace .. "/prepared SDK"
        local root = workspace .. "/prepared build"
        for _, target in ipairs({ "stdlib", "install-stdlib" }) do
            local ok, output = run({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS",
                "-u", "MAKEOVERRIDES", "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
                "make", "--no-print-directory", "-n", "-f", repository .. "/Makefile.win",
                "PREFIX=" .. prefix, "ROCKS_TREE=" .. prefix,
                "WINDOWS_BUILD_ROOT=" .. root,
                "ROCK_TITANC=C:/SDK/bin/titanc.exe", "ROCK_LUA=C:/SDK/bin/lua.exe",
                "MAKE=printf '<%s>\\n'", target,
            }, repository)
            assert.truthy(ok, output)
            local _, builds = output:gsub("scripts/build_windows_stdlib[.]sh", "")
            assert.equal(1, builds, output)
            assert.truthy(output:find("ROCK_TITANC='C:/SDK/bin/titanc.exe'", 1, true), output)
            assert.truthy(output:find("ROCK_LUA='C:/SDK/bin/lua.exe'", 1, true), output)
            assert.falsy(output:find("luarocks.exe", 1, true), output)
            assert.falsy(output:find("install_windows_luarocks.sh", 1, true), output)
            assert.falsy(output:find("build_windows_runtime.sh", 1, true), output)
            assert.falsy(output:find("build_windows_native.sh", 1, true), output)
            if target == "stdlib" then
                assert.falsy(output:find("<publish-stdlib>", 1, true), output)
            else
                assert.truthy(output:find("<publish-stdlib>", 1, true), output)
            end
        end
        assert_absent(prefix)
        assert_absent(root)
    end)

    it("keeps both rock install passes limited to copying built files", function()
        workspace = temporary_directory("rock-install-copies")
        local repository = assert(lfs.currentdir())
        local prefix = workspace .. "/prepared SDK"
        local root = workspace .. "/prepared build"
        -- The build pass already produced the support module the shared
        -- compiler install deploys: the checkout's on Unix, the Windows
        -- build root's runtime DLL on Windows.
        local windows_support = root .. "/runtime/titan.dll"
        make_directory(root .. "/runtime")
        write_file(windows_support, "support module\n")
        for _, makefile in ipairs({ "Makefile", "Makefile.win" }) do
            local ok, output = run({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
                "make", "--no-print-directory", "-n", "-f", repository .. "/" .. makefile,
                "PREFIX=" .. prefix, "ROCKS_TREE=" .. prefix,
                "WINDOWS_BUILD_ROOT=" .. root,
                "INST_PREFIX=" .. workspace .. "/rock",
                "INST_LUADIR=" .. workspace .. "/rock/lua",
                "INST_BINDIR=" .. workspace .. "/rock/bin",
                "INST_CONFDIR=" .. workspace .. "/rock/conf",
                "INST_LIBDIR=" .. workspace .. "/rock/lib",
                "install",
            }, repository)
            assert.truthy(ok, output)
            for _, forbidden in ipairs({ "build_windows_stdlib.sh", "build_windows_runtime.sh",
                    "build_windows_native.sh", "install_windows_luarocks.sh", "--source-first",
                    "ltitanlib.c", "titan_path.c" }) do
                assert.falsy(output:find(forbidden, 1, true), output)
            end
            -- Windows deploys the built native titanc.exe and keeps the
            -- unchanged script as the rock's Lua file; Unix deploys the script.
            if makefile == "Makefile.win" then
                assert.truthy(output:find('/runtime/titanc.exe" "' ..
                    workspace .. '/rock/bin/titanc.exe"', 1, true), output)
                assert.truthy(output:find('titanc "' .. workspace ..
                    '/rock/lua/titan-compiler/titanc.lua"', 1, true), output)
                assert.falsy(output:find('/rock/bin/titanc"', 1, true), output)
            else
                assert.truthy(output:find('titanc "' .. workspace .. '/rock/bin/titanc"', 1, true), output)
                assert.falsy(output:find("titanc.exe", 1, true), output)
            end
            local suffix = makefile == "Makefile.win" and ".dll" or ".so"
            assert.truthy(output:find("/lib/titan/0.6/titan" .. suffix, 1, true), output)
            assert.truthy(output:find("/rock/lib/titan" .. suffix .. '"', 1, true), output)
        end
        assert_absent(prefix)
        assert.equal("support module\n", read_file(windows_support))
        assert.truthy(os.remove(windows_support))
        assert.truthy(lfs.rmdir(root .. "/runtime"))
        assert.truthy(lfs.rmdir(root), "the install passes wrote into the build root")
        assert_absent(workspace .. "/rock")
    end)

    it("stages the Windows rock SDK without copying Lua or changing the prepared prefix", function()
        if platform.windows then
            pending("POSIX model of Windows Make staging without native compilation")
            return
        end
        workspace = temporary_directory("windows-rock-stage")
        local source = workspace .. "/source checkout"
        local prefix = workspace .. "/prepared SDK"
        local build = workspace .. "/native build"
        local private = workspace .. "/private rock"
        local old = os.time() - 120
        local function fixture(root, relative, contents)
            local path = root .. "/" .. relative
            make_directory(assert(path:match("^(.+)/[^/]+$")))
            write_file(path, contents or "fixture: " .. relative .. "\n")
            assert(lfs.touch(path, old, old))
            return path
        end
        for _, path in ipairs({ "Makefile.win", "scripts/install_compiler.mk", "scripts/browser.mk",
                "scripts/titan_install.lua", "scripts/titan-install", "scripts/titan-uninstall",
                "spec/support/stdlib_test_modules.mk" }) do
            fixture(source, path, read_file(path))
        end
        for _, path in ipairs({ "titanc", "titan-compiler/driver.lua", "LICENSE",
                "THIRD_PARTY_NOTICES.md", "LICENSES/fixture-license",
                "titan-runtime/titan.h", "titan-runtime/minicoro.h", "titan-runtime/transfer.h",
                "titan-runtime/titan/ffi.h", "titan-runtime/titan/browser.h" }) do fixture(source, path) end
        fixture(build, "out/titan.dll")
        fixture(build, "runtime/libtitan.a")
        fixture(build, "runtime/titan.dll", "support module\n")
        fixture(build, "runtime/titanc.exe", "native titanc\n")
        local expected = {
            ["lib/titan/0.6/libtitan.a"] = build .. "/runtime/libtitan.a",
            ["lib/titan/0.6/titan.dll"] = build .. "/out/titan.dll",
            ["include/titan.h"] = source .. "/titan-runtime/titan.h",
            ["include/minicoro.h"] = source .. "/titan-runtime/minicoro.h",
            ["include/transfer.h"] = source .. "/titan-runtime/transfer.h",
            ["include/titan/ffi.h"] = source .. "/titan-runtime/titan/ffi.h",
            ["include/titan/browser.h"] = source .. "/titan-runtime/titan/browser.h",
            ["share/titan/LICENSE"] = source .. "/LICENSE",
            ["share/titan/THIRD_PARTY_NOTICES.md"] = source .. "/THIRD_PARTY_NOTICES.md",
            ["share/titan/LICENSES/fixture-license"] = source .. "/LICENSES/fixture-license",
        }
        for _, path in ipairs({
            "bin/libuv-1.dll", "bin/libllhttp-9.4.dll", "bin/libsqlite3-0.dll",
            "bin/libcrypto-3-x64.dll", "bin/libssl-3-x64.dll",
            "lib/libuv.dll.a", "lib/libllhttp.dll.a", "lib/libsqlite3.dll.a",
            "lib/libcrypto.dll.a", "lib/libssl.dll.a", "lib/libbacktrace.a",
            "include/uv.h", "include/llhttp.h", "include/sqlite3.h",
            "include/backtrace.h", "include/backtrace-supported.h",
            "include/uv/version.h", "include/openssl/ssl.h",
        }) do expected[path] = fixture(prefix, path) end
        for _, path in ipairs({ "bin/lua.exe", "bin/lua55.dll", "lib/liblua55.a",
                "include/lua.h", "src/lua-5.5.1/lua.h", "bin/unrelated.exe",
                "lib/unrelated.a", "include/unrelated.h", "share/unrelated.txt",
                "include/titan.h", "lib/titan/0.6/titan.dll",
                "lib/lua/5.5/titan.dll", "etc/titan/build-profile" }) do
            fixture(prefix, path, "existing SDK file: " .. path .. "\n")
        end
        local function snapshot(root, relative, result)
            relative, result = relative or "", result or {}
            for name in lfs.dir(root .. (relative == "" and "" or "/" .. relative)) do
                if name ~= "." and name ~= ".." then
                    local child = relative == "" and name or relative .. "/" .. name
                    local path = root .. "/" .. child
                    if lfs.attributes(path, "mode") == "directory" then snapshot(root, child, result)
                    else result[child] = { read_file(path), lfs.attributes(path, "modification") } end
                end
            end
            return result
        end
        local original = snapshot(prefix)
        local ok, output = run({
            "env", "-u", "OS", "-u", "MAKEFLAGS", "-u", "MFLAGS",
            "-u", "MAKEOVERRIDES", "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
            "make", "--no-print-directory", "-s", "-f", "Makefile.win", "install",
            "PREFIX=" .. prefix, "ROCKS_TREE=" .. prefix, "WINDOWS_BUILD_ROOT=" .. build,
            "INST_PREFIX=" .. private, "INST_LUADIR=" .. private .. "/lua",
            "INST_BINDIR=" .. private .. "/bin", "INST_CONFDIR=" .. private .. "/conf",
            "INST_LIBDIR=" .. private .. "/lib",
            "TITAN_LICENSE_FILES=fixture-license", "STDLIB_MODULES=math",
            "OPENSSL_MODE=system", "TITAN_BUILD_PROFILE=validation",
        }, source)
        assert.truthy(ok, output)
        assert.same(original, snapshot(prefix))
        local staged = snapshot(private .. "/titan-sdk")
        assert.equal("validation\n", assert(staged["etc/titan/build-profile"])[1])
        staged["etc/titan/build-profile"] = nil
        for relative, input in pairs(expected) do
            assert.same({ read_file(input), old }, staged[relative], relative)
            staged[relative] = nil
        end
        assert.same({}, staged, "unexpected files in the retained native SDK")
        for _, copy in ipairs({
            { "titanc", "lua/titan-compiler/titanc.lua" },
            { "scripts/titan-install", "bin/titan-install" },
            { "scripts/titan-uninstall", "bin/titan-uninstall" },
            { "scripts/titan_install.lua", "installer/titan_install.lua" },
            { "titan-compiler/driver.lua", "lua/titan-compiler/driver.lua" },
            { "THIRD_PARTY_NOTICES.md", "conf/THIRD_PARTY_NOTICES.md" },
        }) do
            assert.equal(read_file(source .. "/" .. copy[1]), read_file(private .. "/" .. copy[2]))
            assert.equal(old, lfs.attributes(private .. "/" .. copy[2], "modification"))
        end
        -- LuaRocks deploys the support module from its lib staging directory
        -- and the native titanc.exe, not a script launcher, from bin; no Lua
        -- shims are staged.
        for _, built in ipairs({ { "titan.dll", "lib/titan.dll" },
                { "titanc.exe", "bin/titanc.exe" } }) do
            assert.equal(read_file(build .. "/runtime/" .. built[1]),
                read_file(private .. "/" .. built[2]))
            assert.equal(old, lfs.attributes(private .. "/" .. built[2], "modification"))
        end
        assert_absent(private .. "/bin/titanc")
        assert_absent(private .. "/lua/titan")
        assert.equal("system\n", read_file(private .. "/installer/openssl-mode"))
    end)

    it("selects the Windows source compiler without using an installed compiler path", function()
        if platform.windows then
            pending("POSIX shell fixture for Windows compiler selection")
            return
        end
        workspace = temporary_directory("windows-source-compiler")
        local repository = assert(lfs.currentdir())
        local build_root = workspace .. "/build root"
        local prefix = workspace .. "/SDK prefix"
        local source_root = workspace .. "/source root"
        local tools = workspace .. "/tools"
        for _, path in ipairs({ build_root, prefix, source_root, tools }) do
            make_directory(path)
        end
        write_file(tools .. "/cygpath", [[#!/bin/sh
set -eu
test "$1" = -m
printf '%s\n' "$2"
]])
        -- Each stand-in records the program that ran, then its arguments: the
        -- source compiler runs through the selected Lua, while the installed
        -- compiler is the native program itself.
        local probe = [[#!/bin/sh
set -eu
printf '%s\0' "$0" "$@" > "$PROBE_ARGV"
printf '%s\n' "$TITAN_ROOT" "$TITAN_RUNTIME_PREBUILT" \
  "${TITAN_COMPILER_BOOTSTRAP-}" "$MSYS2_ARG_CONV_EXCL" \
  "${TITAN_TARGET-<unset>}" > "$PROBE_ENV"
]]
        local lua = tools .. "/fake lua.exe"
        local selected_compiler = workspace .. "/selected compiler/titanc.exe"
        write_file(lua, probe)
        make_directory(workspace .. "/selected compiler")
        write_file(selected_compiler, probe)
        local ok, output = run({ "chmod", "+x", tools .. "/cygpath", lua, selected_compiler })
        assert.truthy(ok, output)
        local argv_log = workspace .. "/argv"
        local environment_log = workspace .. "/environment"
        for _, installed_runtime in ipairs({ "0", "1" }) do
            ok, output = run({
                "env", "-u", "TITAN_COMPILER_BOOTSTRAP",
                "MSYSTEM=CLANG64", "TITAN_JOBS=3", "TITAN_TARGET=bogus",
                "PATH=" .. tools .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin"),
                "ROCK_LUA=" .. lua, "ROCK_TITANC=" .. selected_compiler,
                "STDLIB_USE_INSTALLED_RUNTIME=" .. installed_runtime,
                "PROBE_ARGV=" .. argv_log, "PROBE_ENV=" .. environment_log,
                "bash", repository .. "/scripts/build_windows_stdlib.sh",
                build_root, prefix, "titan.math", "titan.json",
            }, source_root)
            assert.truthy(ok, output)
            local arguments = {}
            for argument in read_file(argv_log):gmatch("(.-)%z") do
                arguments[#arguments + 1] = argument
            end
            -- The selected compiler builds the requested roots into the
            -- build root; the native payload after them is not pinned here.
            local expected = {
                "--output", build_root .. "/out", "--source-first", "--incremental", "-j", "3", "--tree", source_root,
                "titan.math", "titan.json",
            }
            local bootstrap = ""
            if installed_runtime == "0" then
                assert.equal(lua, table.remove(arguments, 1))
                assert.equal("-E", table.remove(arguments, 1))
                assert.equal("-e", table.remove(arguments, 1))
                local setup = table.remove(arguments, 1)
                assert.truthy(setup:find('package.path="./?.lua;./?/init.lua;"', 1, true), setup)
                assert.truthy(setup:find('os.getenv("TITAN_COMPILER_BOOTSTRAP")', 1, true), setup)
                assert.truthy(setup:find('.. "/?.dll;" .. package.cpath', 1, true), setup)
                assert.equal("./titanc", table.remove(arguments, 1))
                bootstrap = build_root .. "/runtime"
            else
                assert.equal(selected_compiler, table.remove(arguments, 1))
            end
            assert.same(expected, { table.unpack(arguments, 1, #expected) })
            -- The compiler child never inherits an ambient target selection,
            -- whether the script bootstraps the source compiler or runs the
            -- installed one.
            assert.equal(table.concat({ prefix, "1", bootstrap, "*", "<unset>", "" },
                "\n"), read_file(environment_log))
        end
    end)

    it("refreshes Windows harness inputs without discarding owned build outputs", function()
        if platform.windows then
            pending("POSIX shell fixture for Windows harness orchestration")
            return
        end
        workspace = temporary_directory("windows-harness-refresh")
        local repository = assert(lfs.currentdir())
        local source = workspace .. "/source checkout"
        local prefix = workspace .. "/published SDK"
        local work = workspace .. "/native workspace"
        local tools = workspace .. "/tools"
        local function fixture(base, name, contents)
            local path = base .. "/" .. name
            make_directory(assert(path:match("^(.+)/[^/]+$")))
            write_file(path, contents)
            return path
        end
        for _, name in ipairs({
                "Makefile.win", "scripts/windows_build_profile.sh",
                "spec/support/windows_stdlib_tests.sh",
                "spec/support/build_windows_stdlib_native.sh",
                "scripts/windows_native_coverage.sh",
                "spec/support/stdlib_test_modules.mk",
                "spec/support/check_stdlib_test_output.lua" }) do
            fixture(source, name, read_file(repository .. "/" .. name))
        end
        fixture(source, "scripts/install_compiler.mk", "")
        fixture(source, "scripts/browser.mk", read_file(repository .. "/scripts/browser.mk"))
        fixture(source, "scripts/build_windows_runtime.sh", [=[#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$1/runtime"
[[ -f $1/runtime/libtitan-lpeglabel.a ]] ||
  printf '%s\n' "libtitan-lpeglabel.a" > "$1/runtime/libtitan-lpeglabel.a"
]=])
        fixture(source, "titan/transfer_native.h", "/* transfer input */\n")
        fixture(source, "titan/protobuf/native.h", "/* protobuf input */\n")
        fixture(source, "spec/stdlib/titan/test/tests.titan",
            "function value(): integer return 1 end\n")
        fixture(source, "spec/stdlib/titan/retired_tests.titan",
            "function value(): integer return 2 end\n")
        local native = "spec/fixtures/stdlib/native/"
        for _, name in ipairs({ "async_foreign_work", "fs_fixture", "uv_stdio_probe",
                "sqlite3_worker_fixture", "ssl_allocator_fixture",
                "ssl_error_strings", "os_descriptor_limit",
                "os_process_host_child", "windows_test_supervisor" }) do
            fixture(source, native .. name .. ".c", "/* " .. name .. " */\n")
            fixture(source, native .. name .. ".h", "/* " .. name .. " header */\n")
        end
        for _, name in ipairs({ "uv_coverage_threads.h", "uv_coverage_pty.h",
                "os_process_host_child_windows.h" }) do
            fixture(source, native .. name, "/* native header */\n")
        end
        fixture(source, "spec/fixtures/retired.txt", "retired fixture\n")
        fixture(source, "spec/fixtures/shape.txt", "old file shape\n")
        for _, name in ipairs({
                "share/lua/5.5/titan-compiler/titanc.lua",
                "lib/titan/0.6/titan.dll", "lib/lua/5.5/titan.dll",
                "lib/libsqlite3.dll.a", "bin/lua55.dll",
                "share/retired.lua" }) do
            fixture(prefix, name, "published input: " .. name .. "\n")
        end
        -- The SDK's lua.exe only runs the output check (`-E script`); the
        -- harness compiles with the native titanc.exe directly.
        local lua = fixture(prefix, "bin/lua.exe", [=[#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -E ]]
]=])
        local titanc = fixture(prefix, "bin/titanc.exe", [=[#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WINDOWS_TITANC_LOG"
printf 'target=[%s]\n' "${TITAN_TARGET-<unset>}" >> "$WINDOWS_CHILD_ENV_LOG"
output= exe= c_source= compile_only=0 coverage=0 print_objects=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) output=$2; shift ;;
    --exe) exe=$2; shift ;;
    --c-source) c_source=$2; shift ;;
    -c) compile_only=1 ;;
    --print-c-objects) print_objects=1 ;;
    --coverage) coverage=1 ;;
  esac
  shift
done
mkdir -p "$output"
if [[ $compile_only == 1 ]]; then
  mkdir -p "$output/.native"
  object="$output/.native/fixture.o"
  if [[ ! -f $object ]] || ! cmp -s "$c_source" "$object"; then
    cp "$c_source" "$object"
    printf '%s\n' "$c_source" >> "$WINDOWS_C_COMPILE_LOG"
  fi
  if [[ $print_objects == 1 ]]; then printf '%s\r\n' "$object"; fi
else
  if [[ ! -f $exe ]]; then
    printf '%s\n' "aggregate executable" > "$exe"
    printf '%s\n' "$exe" >> "$WINDOWS_LINK_LOG"
  fi
  if [[ $coverage == 1 ]]; then
    mkdir -p "$output/.coverage"
    [[ -f $output/.coverage/retained.gcno ]] ||
      printf '%s\n' "coverage notes" > "$output/.coverage/retained.gcno"
  fi
fi
]=])
        local cc = fixture(tools, "native-cc", [=[#!/usr/bin/env bash
set -euo pipefail
case $1 in
  -dumpmachine) echo x86_64-w64-windows-gnu; exit 0 ;;
  --version) echo "fixture Clang"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$WINDOWS_NATIVE_LOG"
source=
while [[ $# -gt 0 ]]; do
  case $1 in
    */cwd/spec/fixtures/stdlib/native/os_process_host_child.c|\
    */cwd/spec/fixtures/stdlib/native/windows_test_supervisor.c) source=$1 ;;
  esac
  if [[ $1 == -o ]]; then
    [[ -n $source && -f $source ]] || {
      echo 'expected an existing native helper C source before -o' >&2
      exit 2
    }
    printf '%s\n' "pure C executable" > "$2"
    exit 0
  fi
  shift
done
exit 1
]=])
        local cygpath = fixture(tools, "cygpath", [=[#!/bin/sh
set -eu
format= codepage=
while [ "$#" -gt 1 ]; do
  case $1 in
    -m|-w|-aw|-u) format=$1; shift ;;
    -C) codepage=$2; shift 2 ;;
    *) printf 'unexpected cygpath option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ "$#" -eq 1 ] && [ -n "$format" ] || exit 2
require_utf8=0
case $1 in
  */os_process_host_child.c|*/windows_test_supervisor.c) require_utf8=1 ;;
  */"process child ação 東京.exe"|*/windows-test-supervisor.exe)
    [ "$format" != -m ] || require_utf8=1 ;;
esac
if [ "$require_utf8" = 1 ]; then
  [ "$format" = -m ] && [ "$codepage" = UTF8 ] || {
    echo 'native helper conversion requires -m -C UTF8' >&2
    exit 2
  }
fi
printf '%s\n' "$1"
]=])
        local powershell = fixture(tools, "powershell.exe", [=[#!/usr/bin/env bash
set -euo pipefail
if [[ $TITAN_BEHAVIOR_MODE == run && -n ${TITAN_BEHAVIOR_EXE:-} ]]; then
  printf 'target=[%s]\n' "${TITAN_TARGET-<unset>}" >> "$WINDOWS_CHILD_ENV_LOG"
  [[ ! -e $TITAN_TEST_ROOT/stale ]]
  : > "$TITAN_BEHAVIOR_WORK/stdout.log"
  : > "$TITAN_BEHAVIOR_WORK/stderr.log"
fi
]=])
        local ok, output = run({ "chmod", "+x", lua, titanc, cc, cygpath, powershell })
        assert.truthy(ok, output)
        local native_log = workspace .. "/native.log"
        local compiler_log = workspace .. "/titanc.log"
        local c_compile_log = workspace .. "/c-compile.log"
        local link_log = workspace .. "/link.log"
        local child_environment_log = workspace .. "/child-environment.log"
        write_file(child_environment_log, "")
        local function harness(mode, coverage, profile)
            local command = {
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
                "-u", "LUA_PATH", "-u", "LUA_CPATH",
                "MSYSTEM=CLANG64", "TITAN_TARGET=bogus",
                "TITAN_BUILD_PROFILE=" .. (profile or "validation"),
                "TITAN_TEST_COVERAGE=" .. (coverage and "1" or "0"),
                "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
                "TEST_CPPFLAGS=", "TEST_CFLAGS=-O0 -fno-lto", "TEST_LDFLAGS=",
                "TITAN_JOBS=2", "MAKE=make", "CC=" .. quote(cc),
                "PATH=" .. tools .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin"),
                "WINDOWS_NATIVE_LOG=" .. native_log, "WINDOWS_TITANC_LOG=" .. compiler_log,
                "WINDOWS_C_COMPILE_LOG=" .. c_compile_log, "WINDOWS_LINK_LOG=" .. link_log,
                "WINDOWS_CHILD_ENV_LOG=" .. child_environment_log,
                "bash", source .. "/spec/support/windows_stdlib_tests.sh", mode, work,
            }
            if mode == "build" then command[#command + 1] = prefix end
            return run(command, source)
        end
        -- The script's compiler and suite children never inherit an ambient
        -- target selection: build mode records through the installed compiler,
        -- run mode through the executed suite child.
        local function assert_target_cleared(required)
            local recorded = read_file(child_environment_log)
            if required then
                assert.truthy(recorded:find("target=[<unset>]", 1, true),
                    "no child environment recorded: " .. recorded)
            end
            assert.falsy(recorded:find("bogus", 1, true), recorded)
            write_file(child_environment_log, "")
        end
        ok, output = harness("build")
        assert.truthy(ok, output)
        assert_target_cleared(true)
        local raw_commands = read_file(native_log)
        assert.truthy(raw_commands:find(work .. "/sdk/bin/process child ação 東京.exe", 1, true), raw_commands)
        assert_file(work .. "/sdk/bin/process child ação 東京.exe")
        assert.falsy(read_file(repository .. "/Makefile.win"):find("process child ação 東京.exe", 1, true))
        local native_compiles = read_file(c_compile_log)
        local links = read_file(link_log)
        local commands = read_file(compiler_log)
        -- Platform link flags may be interleaved with these switches, so
        -- assert each switch rather than one contiguous argv fragment.
        for _, flag in ipairs({ "--test", "--incremental", "--no-uv-bootstrap" }) do
            assert.truthy(commands:find(flag .. " ", 1, true), commands)
        end
        assert.truthy(commands:find(" -j 2 ", 1, true), commands)
        assert.truthy(commands:find("--test-dir " .. work .. "/source/spec/stdlib/titan", 1, true), commands)
        assert.truthy(commands:find("--exe " .. work .. "/sdk/bin/titan-stdlib-tests.exe", 1, true), commands)
        assert.falsy(commands:find("--launcher-name", 1, true), commands)
        assert.falsy(commands:find("async.tests", 1, true), commands)
        local _, native_sources = commands:gsub("%-%-c%-source", "")
        assert.equal(8, native_sources, commands)
        local _, printed_objects = commands:gsub("%-%-print%-c%-objects", "")
        assert.equal(5, printed_objects, commands)
        local fixed_helpers = { "uv_stdio_probe", "sqlite3_worker_fixture",
            "ssl_allocator_fixture", "ssl_error_strings", "os_descriptor_limit" }
        for _, name in ipairs(fixed_helpers) do
            local object = work .. "/cwd/.titan-tests/" .. name .. ".o"
            assert.equal(read_file(source .. "/" .. native .. name .. ".c"), read_file(object))
            assert.truthy(lfs.touch(object, 1000, 1000))
            fixture(work, "native/" .. name .. "/.native/stale-other-tree.o", "stale native node\n")
        end
        local sdk_input = work .. "/sdk/lib/titan/0.6/titan.dll"
        local source_input = work .. "/source/spec/stdlib/titan/test/tests.titan"
        assert.truthy(lfs.touch(sdk_input, 1000, 1000))
        assert.truthy(lfs.touch(source_input, 1000, 1000))
        fixture(work, "sdk/retained.generated", "unrelated generated output\n")
        fixture(work, "scratch/stale", "execution scratch\n")
        -- Republish identical SDK bytes with new publication timestamps.
        write_file(prefix .. "/lib/titan/0.6/titan.dll", read_file(sdk_input))
        assert.truthy(os.remove(prefix .. "/share/retired.lua"))
        assert.truthy(os.remove(source .. "/spec/stdlib/titan/retired_tests.titan"))
        assert.truthy(os.remove(source .. "/spec/fixtures/retired.txt"))
        assert.truthy(os.remove(source .. "/spec/fixtures/shape.txt"))
        fixture(source, "spec/fixtures/shape.txt/new.txt", "new directory shape\n")
        ok, output = harness("build")
        assert.truthy(ok, output)
        assert_target_cleared(true)
        assert.equal(raw_commands, read_file(native_log))
        assert.equal(native_compiles, read_file(c_compile_log))
        assert.equal(links, read_file(link_log))
        assert.equal(1000, lfs.attributes(sdk_input, "modification"))
        assert.equal(1000, lfs.attributes(source_input, "modification"))
        for _, name in ipairs(fixed_helpers) do
            assert.equal(1000, lfs.attributes(work .. "/cwd/.titan-tests/" .. name .. ".o", "modification"))
            assert.equal("stale native node\n", read_file(work .. "/native/" .. name ..
                "/.native/stale-other-tree.o"))
        end
        assert_absent(work .. "/sdk/share/retired.lua")
        assert_absent(work .. "/source/spec/stdlib/titan/retired_tests.titan")
        assert_absent(work .. "/cwd/spec/fixtures/retired.txt")
        assert.equal("new directory shape\n", read_file(work .. "/cwd/spec/fixtures/shape.txt/new.txt"))
        assert.equal("unrelated generated output\n", read_file(work .. "/sdk/retained.generated"))
        assert_file(work .. "/scratch/stale")
        ok, output = harness("run")
        assert.truthy(ok, output)
        assert_target_cleared(true)
        assert_absent(work .. "/scratch/stale")
        fixture(work, "scratch/stale", "must survive rejected runs\n")
        ok, output = harness("run", false, "production")
        assert.falsy(ok, output)
        assert.truthy(output:find("different profile", 1, true), output)
        assert_file(work .. "/scratch/stale")
        ok, output = harness("run", true)
        assert.falsy(ok, output)
        assert.truthy(output:find("different coverage mode", 1, true), output)
        assert_file(work .. "/scratch/stale")
        local edited_source = source .. "/spec/stdlib/titan/test/tests.titan"
        write_file(edited_source, "function value(): integer return 3 end\n")
        assert.truthy(lfs.touch(edited_source, 1000, 1000))
        local edited_sdk = "/lib/lua/5.5/titan.dll"
        assert.truthy(lfs.touch(work .. "/sdk" .. edited_sdk, 1000, 1000))
        write_file(prefix .. edited_sdk, "changed SDK input\n")
        assert.truthy(lfs.touch(prefix .. edited_sdk, 1000, 1000))
        -- Retained native certificates must also repair missing fixed copies.
        for _, name in ipairs(fixed_helpers) do
            assert.truthy(os.remove(work .. "/cwd/.titan-tests/" .. name .. ".o"))
        end
        ok, output = harness("build", true)
        assert.truthy(ok, output)
        assert_target_cleared(true)
        assert.equal("function value(): integer return 3 end\n", read_file(source_input))
        assert.equal("changed SDK input\n", read_file(work .. "/sdk" .. edited_sdk))
        for _, name in ipairs(fixed_helpers) do
            local object = work .. "/cwd/.titan-tests/" .. name .. ".o"
            assert.equal(read_file(source .. "/" .. native .. name .. ".c"), read_file(object))
            assert.equal("stale native node\n", read_file(work .. "/native/" .. name ..
                "/.native/stale-other-tree.o"))
        end
        local notes = work .. "/coverage/.coverage/retained.gcno"
        assert.truthy(lfs.touch(notes, 1000, 1000))
        ok, output = harness("build", true)
        assert.truthy(ok, output)
        assert_target_cleared(false)
        assert.equal(1000, lfs.attributes(notes, "modification"))
        assert.equal(raw_commands, read_file(native_log))
        assert.equal(native_compiles, read_file(c_compile_log))
        assert.truthy(read_file(compiler_log):find("--output " .. work .. "/coverage", 1, true))
        ok, output = harness("run", true)
        assert.truthy(ok, output)
        assert.equal(1000, lfs.attributes(notes, "modification"))
    end)

    it("builds and reuses the exact Unicode Windows host child through native Make", function()
        if not platform.windows then
            pending("native Windows Make UTF-8 output boundary")
            return
        end
        workspace = temporary_directory("windows-native-child-name")
        local repository = assert(lfs.currentdir())
        local work = workspace .. "/native workspace"
        local inputs = work .. "/cwd/spec/fixtures/stdlib/native"
        local bin = work .. "/sdk/bin"
        make_directory(inputs)
        make_directory(bin)
        write_file(work .. "/.titan-test-owner", "titan-windows-stdlib-tests-v1\n")
        for _, name in ipairs({ "os_process_host_child.c", "os_process_host_child_windows.h",
                "windows_test_supervisor.c" }) do
            write_file(inputs .. "/" .. name,
                read_file(repository .. "/spec/fixtures/stdlib/native/" .. name))
        end
        local compiler = assert(cdriver.split_shell_words(os.getenv("CC") or "clang.exe"))
        assert.truthy(compiler[1])
        write_file(work .. "/CC.argv", table.concat(compiler, "\0") .. "\0")
        write_file(work .. "/cppflags.argv", "")
        write_file(work .. "/cflags.argv", "-O0\0-fno-lto\0")
        write_file(work .. "/ldflags.argv", "-fno-lto\0")
        write_file(work .. "/native-flags.config", "native Unicode output contract\n")
        local function build_native()
            return run({
                "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
                "MSYSTEM=CLANG64", "MSYS2_ARG_CONV_EXCL=*",
                selected_make(), "--no-print-directory", "-f", repository .. "/Makefile.win",
                "TITAN_TEST_BUILD_DIR=" .. work, "windows-stdlib-test-native",
            }, repository)
        end
        local ok, output = build_native()
        assert.truthy(ok, output)
        local child = bin .. "/process child ação 東京.exe"
        local supervisor = bin .. "/windows-test-supervisor.exe"
        assert_file(child)
        assert_file(supervisor)
        local names = {}
        for name in lfs.dir(bin) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        table.sort(names)
        assert.same({ "process child ação 東京.exe", "windows-test-supervisor.exe" }, names)
        ok, output = run({ child, "output", "ação 東京", "" })
        assert.truthy(ok, output)
        assert.equal("ação 東京", output)
        local contents = { read_file(child), read_file(supervisor) }
        local future = os.time() + 86400
        assert.truthy(lfs.touch(child, future, future))
        assert.truthy(lfs.touch(supervisor, future, future))
        ok, output = build_native()
        assert.truthy(ok, output)
        assert.equal(future, lfs.attributes(child, "modification"))
        assert.equal(future, lfs.attributes(supervisor, "modification"))
        assert.equal(contents[1], read_file(child))
        assert.equal(contents[2], read_file(supervisor))
        assert.truthy(os.remove(child))
        ok, output = build_native()
        assert.truthy(ok, output)
        assert_file(child)
        assert.equal(future, lfs.attributes(supervisor, "modification"))
    end)

    it("does not launch Windows compiler or test wrappers under Make observation modes", function()
        if platform.windows then
            pending("POSIX shell fixture for Windows Make observation modes")
            return
        end
        workspace = temporary_directory("windows-make-observation")
        local repository = assert(lfs.currentdir())
        local tools = workspace .. "/tools"
        make_directory(tools)
        for _, mode in ipairs({ "-n", "-q", "-t" }) do
            for _, target in ipairs({ "stdlib", "titan-stdlib-test-build",
                    "titan-native-coverage-build", "rock-test" }) do
                local marker = workspace .. "/unexpected-wrapper"
                local wrapper = tools .. "/bash"
                write_file(wrapper, "#!/bin/sh\n: > " .. quote(marker) .. "\nexit 93\n")
                local ok, output = run({ "chmod", "+x", wrapper })
                assert.truthy(ok, output)
                local commands = {
                    "env", "-u", "MAKEFLAGS", "-u", "MFLAGS", "-u", "MAKEOVERRIDES",
                    "-u", "MAKELEVEL", "-u", "GNUMAKEFLAGS",
                    "PATH=" .. tools .. ":" .. (os.getenv("PATH") or "/usr/bin:/bin"),
                    "make", "--no-print-directory", mode, "-f", repository .. "/Makefile.win",
                    "PREFIX=" .. workspace .. "/absent SDK",
                    "WINDOWS_BUILD_ROOT=" .. workspace .. "/absent outputs",
                    "SHELL=/bin/bash", target,
                }
                ok, output = run(commands, repository)
                assert.equal(mode ~= "-q", ok, output)
                assert_absent(marker)
                assert_absent(workspace .. "/absent SDK")
                assert_absent(workspace .. "/absent outputs")
            end
        end
    end)

    it("requires initialized Lua sources before changing either build tree",
    function()
        workspace = temporary_directory("lua-source-required")
        local tools_path, fetch_marker = prohibit_source_fetch()
        local repository = assert(lfs.currentdir())
        local source = workspace .. "/lua-5.5.1"
        local windows_root = workspace .. "/windows-build"
        local windows_source = windows_root .. "/lua-5.5.1/src"
        make_directory(source .. "/src")
        make_directory(windows_source)
        write_file(source .. "/src/loadlib.c", "existing source sentinel\n")
        write_file(windows_source .. "/loadlib.c", "existing Windows stage\n")
        write_file(windows_source .. "/.titan-windows-source", "existing stage stamp\n")
        local ok, output
        if not platform.windows then
            ok, output = run({ "env", "PATH=" .. tools_path,
                "make", "--no-print-directory", "-f",
                repository .. "/Makefile", "PREFIX=" .. workspace .. "/prefix",
                "LUA_DIR=lua-5.5.1",
                "lua" }, workspace)
            assert.falsy(ok, output)
            assert.truthy(output:find("git submodule update --init", 1, true), output)
        end
        ok, output = run({ "env", "PATH=" .. tools_path,
            selected_make(), "--no-print-directory", "-f",
            repository .. "/Makefile.win", "PREFIX=" .. workspace .. "/prefix",
            "LUA_DIR=" .. source, "WINDOWS_BUILD_ROOT=" .. windows_root,
            "lua-source" }, repository)
        assert.falsy(ok, output)
        assert.truthy(output:find("git submodule update --init", 1, true), output)
        assert.equal("existing source sentinel\n", read_file(source .. "/src/loadlib.c"))
        assert.equal("existing Windows stage\n", read_file(windows_source .. "/loadlib.c"))
        assert.equal("existing stage stamp\n",
            read_file(windows_source .. "/.titan-windows-source"))
        assert_absent(fetch_marker)
    end)


    it("reuses installed Lua and LuaRocks solely by their program paths", function()
        if platform.windows then
            pending("Unix Make warm bootstrap checks extensionless Lua and LuaRocks programs")
            return
        end
        workspace = temporary_directory("lua-bootstrap-reuse")
        local tools_path, fetch_marker = prohibit_source_fetch()
        local repository = assert(lfs.currentdir())
        local prefix = workspace .. "/prepared-prefix"
        make_directory(prefix .. "/bin")
        for _, name in ipairs({ "lua", "luarocks" }) do
            write_file(prefix .. "/bin/" .. name, "prebuilt program sentinel\n")
        end
        local ok, output = run({ "env", "PATH=" .. tools_path,
            "make", "--no-print-directory", "-f", repository .. "/Makefile",
            "PREFIX=" .. prefix, "LUA_CC=false", "LUA_PLATFORM=invalid",
            "LUA_MYCFLAGS=changed flags",
            "lua", "luarocks" }, workspace)
        assert.truthy(ok, output)
        for _, name in ipairs({ "lua", "luarocks" }) do
            assert.equal("prebuilt program sentinel\n", read_file(prefix .. "/bin/" .. name))
        end
        assert_absent(workspace .. "/lua-5.5.1")
        assert_absent(workspace .. "/luarocks-3.13.0")
        assert_absent(prefix .. "/etc")
        assert_absent(fetch_marker)
    end)

    it("reuses prebuilt Windows Lua and LuaRocks without source or build tools", function()
        workspace = temporary_directory("windows-bootstrap-reuse")
        local tools_path, fetch_marker = prohibit_source_fetch()
        local repository = assert(lfs.currentdir())
        local prefix = workspace .. "/prepared prefix"
        local root = workspace .. "/windows build"
        make_directory(prefix .. "/bin")
        for _, name in ipairs({ "lua.exe", "luarocks.exe" }) do
            write_file(prefix .. "/bin/" .. name, "prebuilt Windows program sentinel\n")
        end
        local ok, output = run({ "env", "PATH=" .. tools_path,
            selected_make(), "--no-print-directory", "-f", repository .. "/Makefile.win",
            "PREFIX=" .. prefix, "WINDOWS_BUILD_ROOT=" .. root,
            "LUA_DIR=" .. workspace .. "/missing-lua", "CC=false", "RC=false",
            "lua", "luarocks" }, repository)
        assert.truthy(ok, output)
        for _, name in ipairs({ "lua.exe", "luarocks.exe" }) do
            assert.equal("prebuilt Windows program sentinel\n",
                read_file(prefix .. "/bin/" .. name))
        end
        assert_absent(root)
        assert_absent(prefix .. "/etc")
        assert_absent(fetch_marker)
    end)

end)

describe("relocatable installed Lua", function()
    local workspace
    local original_prefix
    local relocated_prefix

    before_each(function()
        workspace = temporary_directory("lua-relocation")
        -- macOS temporary directories can be reached through /var symlinks.
        -- The loader deliberately reports the canonical executable location.
        if platform.windows then
            -- Keep an ordinary native path for tools and paths assembled with
            -- "/"; Windows realpath returns an extended \\?\ prefix.
            workspace = paths.to_slash(workspace)
        else
            workspace = assert(compiler_io.new_sync():realpath(workspace))
        end
        local ok, output
        original_prefix = workspace .. "/original prefix"
        relocated_prefix = workspace .. "/moved prefix with spaces"
        for _, suffix in ipairs({
            "/bin", "/share/lua/5.5", "/lib/lua/5.5", "/lib/titan/0.6",
            "/custom/lua", "/custom/native",
        }) do
            make_directory(original_prefix .. suffix)
        end
        if platform.windows then
            copy_tree(LUA, original_prefix .. "/bin/lua.exe")
            copy_tree(PREFIX .. "/bin/lua55.dll", original_prefix .. "/bin/lua55.dll")
        else
            ok, output = run({ "cp", "-p", LUA, original_prefix .. "/bin/lua" })
            assert.truthy(ok, output)
        end
        for _, suffix in ipairs({ "/share/lua/5.5", "/custom/lua" }) do
            write_file(original_prefix .. suffix .. "/relocation_lua.lua",
                'return "relocated Lua module"\n')
        end
        local source = workspace .. "/module.c"
        write_file(source, [[
#include <lua.h>
#ifdef _WIN32
__declspec(dllexport)
#endif
int luaopen_relocation_native(lua_State *L) {
  lua_pushliteral(L, "relocated native module");
  return 1;
}
#ifdef _WIN32
__declspec(dllexport)
#endif
int luaopen_relocation_titan(lua_State *L) {
  lua_pushliteral(L, "relocated Titan library path");
  return 1;
}
]])
        local native_module = original_prefix ..
            "/lib/lua/5.5/relocation_native" .. SHARED_SUFFIX
        local argv = compiler_argv("-fPIC", "-I" .. PREFIX .. "/include")
        local host_output = "Windows"
        if not platform.windows then
            local host_ok
            host_ok, host_output = run({ "uname", "-s" })
            assert.truthy(host_ok, host_output)
        end
        local flags = host_output:match("^%s*Darwin%s*$") and
            { "-bundle", "-undefined", "dynamic_lookup" } or { "-shared" }
        for _, flag in ipairs(flags) do argv[#argv + 1] = flag end
        for _, word in ipairs({ source, "-o", native_module }) do
            argv[#argv + 1] = word
        end
        if platform.windows then argv[#argv + 1] = PREFIX .. "/lib/liblua55.a" end
        ok, output = run(argv)
        assert.truthy(ok, output)
        copy_tree(native_module, original_prefix ..
            "/lib/titan/0.6/relocation_titan" .. SHARED_SUFFIX)
        copy_tree(native_module, original_prefix ..
            "/custom/native/relocation_native" .. SHARED_SUFFIX)
    end)

    after_each(function()
        if workspace then remove_tree(workspace); workspace = nil end
    end)

    local function check_default_paths(prefix, executable)
        local bin = prefix .. "/bin"
        local expected_path = platform.windows and {
            bin .. "/lua/?.lua", bin .. "/lua/?/init.lua",
            bin .. "/?.lua", bin .. "/?/init.lua",
            prefix .. "/share/lua/5.5/?.lua", prefix .. "/share/lua/5.5/?/init.lua",
            "./?.lua", "./?/init.lua",
        } or {
            prefix .. "/share/lua/5.5/?.lua", prefix .. "/share/lua/5.5/?/init.lua",
            prefix .. "/lib/lua/5.5/?.lua", prefix .. "/lib/lua/5.5/?/init.lua",
            "./?.lua", "./?/init.lua",
        }
        -- Lua's defaults carry no Titan provider directory: the Titan
        -- searcher, not package.cpath, finds lib/titan/0.6 providers.
        local expected_cpath = platform.windows and {
            bin .. "/?.dll", prefix .. "/lib/lua/5.5/?.dll",
            bin .. "/loadall.dll", "./?.dll",
        } or {
            prefix .. "/lib/lua/5.5/?.so", prefix .. "/lib/lua/5.5/loadall.so",
            "./?.so",
        }
        local probe = string.format([[
local prefix = %q
local extension = %q
local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/bin/%%.%%./", "/"))
end
assert(normalize(package.path) == %q, package.path)
assert(normalize(package.cpath) == %q, package.cpath)
assert(normalize(package.searchpath("relocation_native", package.cpath)) ==
       prefix .. "/lib/lua/5.5/relocation_native" .. extension)
assert(package.searchpath("relocation_titan", package.cpath) == nil)
assert(require "relocation_lua" == "relocated Lua module")
assert(require "relocation_native" == "relocated native module")
]], prefix, SHARED_SUFFIX, table.concat(expected_path, ";"),
            table.concat(expected_cpath, ";"))
        local ok, output = run(clean_environment({
            executable or prefix .. "/bin/lua" .. PROGRAM_SUFFIX, "-E", "-e", probe,
        }), workspace)
        assert.truthy(ok, output)
    end

    it("loads prefix-local Lua and C modules after moving the executable",
    function()
        check_default_paths(original_prefix)
        assert.truthy(os.rename(original_prefix, relocated_prefix))
        assert_absent(original_prefix)
        check_default_paths(relocated_prefix)

        if not platform.windows then
            local alias = workspace .. "/lua alias"
            local ok, output = run({ "ln", "-s",
                relocated_prefix .. "/bin/lua", alias })
            assert.truthy(ok, output)
            check_default_paths(relocated_prefix, alias)
        end
    end)

    for _, suffix in ipairs({ "", "_5_5" }) do
        it("expands ! in LUA_PATH" .. suffix .. " and LUA_CPATH" .. suffix,
        function()
            assert.truthy(os.rename(original_prefix, relocated_prefix))
            local probe = string.format([[
local prefix = %q
local extension = %q
local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/bin/%%.%%./", "/"))
end
local lua_path, cpath = normalize(package.path), normalize(package.cpath)
assert(lua_path:sub(1, #(prefix .. "/custom/lua/?.lua;")) ==
       prefix .. "/custom/lua/?.lua;", package.path)
assert(cpath:sub(1, #(prefix .. "/custom/native/?" .. extension .. ";")) ==
       prefix .. "/custom/native/?" .. extension .. ";", package.cpath)
assert(not package.path:find("!", 1, true), package.path)
assert(not package.cpath:find("!", 1, true), package.cpath)
assert(lua_path:find(prefix .. "/share/lua/5.5/?.lua", 1, true))
assert(cpath:find(prefix .. "/lib/lua/5.5/?" .. extension, 1, true))
assert(not cpath:find("/lib/titan/", 1, true), package.cpath)
assert(lua_path:sub(-#"./unchanged/?.lua") == "./unchanged/?.lua")
assert(cpath:sub(-#("./unchanged/?" .. extension)) == "./unchanged/?" .. extension)
assert(normalize(package.searchpath("relocation_lua", package.path)) ==
       prefix .. "/custom/lua/relocation_lua.lua")
assert(normalize(package.searchpath("relocation_native", package.cpath)) ==
       prefix .. "/custom/native/relocation_native" .. extension)
assert(require "relocation_lua" == "relocated Lua module")
assert(require "relocation_native" == "relocated native module")
]], relocated_prefix, SHARED_SUFFIX)
            -- On every platform ! is the interpreter's real directory.
            local executable_root = "!/../"
            local ok, output = run(clean_environment({
                "LUA_PATH" .. suffix .. "=" .. executable_root ..
                    "custom/lua/?.lua;;./unchanged/?.lua",
                "LUA_CPATH" .. suffix .. "=" .. executable_root ..
                    "custom/native/?" .. SHARED_SUFFIX .. ";;./unchanged/?" .. SHARED_SUFFIX,
                relocated_prefix .. "/bin/lua" .. PROGRAM_SUFFIX, "-e", probe,
            }), workspace)
            assert.truthy(ok, output)
        end)
    end
end)

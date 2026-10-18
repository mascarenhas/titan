local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local coder_core = require "titan-compiler.coder.core"
local coder_names = require "titan-compiler.coder.names"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local path = require "titan-compiler.path"
local staticmetadata = require "titan-compiler.staticmetadata"

local REPO = assert(lfs.currentdir())
if platform.windows then REPO = assert(platform.path.normalize(REPO)) end
local PREFIX = require("spec.support.installed_prefix").active()
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local LUA = PREFIX .. "/bin/lua" .. (platform.windows and ".exe" or "")
local INSTALLED_TITANC = PREFIX .. (platform.windows and
    "/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" or "/bin/titanc")
local LUA_INCLUDE = PREFIX .. "/include"
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

local function single_dsym_relocation_map(dsym)
    local root = dsym .. "/Contents/Resources/Relocations"
    local maps = {}
    for architecture in lfs.dir(root) do
        if architecture ~= "." and architecture ~= ".." then
            local architecture_root = root .. "/" .. architecture
            if lfs.attributes(architecture_root, "mode") == "directory" then
                for filename in lfs.dir(architecture_root) do
                    if filename:match("[.]yml$") then
                        maps[#maps + 1] =
                            architecture_root .. "/" .. filename
                    end
                end
            end
        end
    end
    table.sort(maps)
    assert.equal(1, #maps)
    return read_file(maps[1])
end

local function final_archive_command_uses(output, argument)
    for line in output:gmatch("[^\r\n]+") do
        if line:find("'" .. argument .. "'", 1, true) and
           line:find("/output.a'", 1, true) then
            return true
        end
    end
    return false
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
        "TITAN_PATH_0_6=" .. workspace,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin" ..
            (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or "/usr/bin:/bin"))
    end

    -- The opt-in is only for testing an in-progress checkout before the
    -- prefix's next `luarocks make`; normal `luarocks test` continues to prove
    -- the installed compiler snapshot.
    local installed = not USE_CHECKOUT_COMPILER and
        PREFIX and exists(INSTALLED_TITANC)
    if installed then
        if platform.windows then table.insert(argv, LUA) end
        table.insert(argv, INSTALLED_TITANC)
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
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
    local installed_titanc = INSTALLED_TITANC
    for index, argument in ipairs(argv) do
        if argument == installed_titanc or argument == LUA then
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

local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?" .. %q .. ";" .. %q .. "/?" .. %q .. ";" .. package.cpath
%s
]], workspace, workspace, SHARED_SUFFIX, REPO, SHARED_SUFFIX, code),
    }, workspace)
end

local function count_plain(text, needle)
    local count = 0
    local start = 1
    while true do
        local at = text:find(needle, start, true)
        if not at then return count end
        count = count + 1
        start = at + #needle
    end
end

local function copy_file(source, destination)
    write_file(destination, read_file(source))
end

local function configured_words(command)
    return assert(cdriver.split_shell_words(command))
end

local function compile_c_object(workspace, stem, body)
    local source = workspace .. "/" .. stem .. ".c"
    local object = workspace .. "/" .. stem .. ".o"
    write_file(source, body)
    local argv = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(configured_words(driver.CC)) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs({
        "-std=c99", "-fPIC", "-c", source, "-o", object,
    }) do
        argv[#argv + 1] = word
    end
    local ok, output = run(argv, workspace)
    assert.truthy(ok, output)
    return object
end

local function make_archive(workspace, name, objects)
    local archive = workspace .. "/" .. name
    local argv = configured_words(driver.AR)
    argv[#argv + 1] = "rcs"
    argv[#argv + 1] = archive
    for _, object in ipairs(objects) do argv[#argv + 1] = object end
    local ok, output = run(argv, workspace)
    assert.truthy(ok, output)
    return archive
end

local function archive_field(value, width)
    local text = tostring(value)
    assert.is_true(#text <= width)
    return text .. string.rep(" ", width - #text)
end

local function regular_archive_bytes(members)
    local records = { "!<arch>\n" }
    for _, member in ipairs(members) do
        local data = member.data
        records[#records + 1] =
            archive_field(member.name, 16) ..
            archive_field(0, 12) ..
            archive_field(0, 6) ..
            archive_field(0, 6) ..
            archive_field(100644, 8) ..
            archive_field(#data, 10) ..
            "`\n" ..
            data ..
            (#data % 2 == 1 and "\n" or "")
    end
    return table.concat(records)
end

local function normalize_regular_archive_header_noise(bytes)
    assert.equal("!<arch>\n", bytes:sub(1, 8))
    local records = { "!<arch>\n" }
    local position = 9
    while position <= #bytes do
        local header = bytes:sub(position, position + 59)
        assert.equal(60, #header)
        assert.equal("`\n", header:sub(59, 60))
        local size = assert(tonumber(
            assert(header:sub(49, 58):match("^ *(%d+) *$"))))
        local record_size = 60 + size + (size % 2)
        local record_end = position + record_size - 1
        assert.is_true(record_end <= #bytes)
        records[#records + 1] =
            header:sub(1, 16) .. string.rep(" ", 32) ..
            header:sub(49, 60)
        records[#records + 1] =
            bytes:sub(position + 60, record_end)
        position = record_end + 1
    end
    assert.equal(#bytes + 1, position)
    return table.concat(records)
end

local function native_symbols(workspace, filename)
    local ok, output = run({ platform.windows and "llvm-nm.exe" or "nm", "-g", filename }, workspace)
    assert.truthy(ok, output)
    return output
end

local function native_support_object(workspace)
    if not platform.windows then return REPO .. "/titan-runtime/ltitanlib.o" end
    local object = path.join(workspace, "ltitanlib.o")
    local argv = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(configured_words(driver.CC)) do
        argv[#argv + 1] = word
    end
    for _, flags in ipairs({ driver.EXTRA_CPPFLAGS, driver.EXTRA_CFLAGS }) do
        for _, word in ipairs(flags) do argv[#argv + 1] = word end
    end
    for _, word in ipairs({
        "-std=c99", "-fPIC", "-I", LUA_INCLUDE,
        "-I", path.join(PREFIX, "src", "lua-5.5.1"),
        "-c", path.join(REPO, "titan-runtime", "ltitanlib.c"),
        "-o", object,
    }) do
        argv[#argv + 1] = word
    end
    local compiled, output = run(argv, workspace)
    assert.truthy(compiled, output)
    return object
end

local function run_program(workspace, relative)
    if platform.windows then
        local logical = relative:gsub("/", ".")
        relative = assert(driver.windows_program_paths(logical)).executable
        return run({ "env.exe",
            "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6",
            "PATH=" .. PREFIX .. "/bin;" .. (os.getenv("PATH") or ""),
            "TITAN_PATH_0_6=" .. workspace .. "/lib/titan/0.6;" ..
                workspace .. ";" .. PREFIX .. "/lib/titan/0.6",
            workspace .. "/" .. relative }, workspace)
    end
    return run({ workspace .. "/" .. relative }, workspace)
end

local function metadata_options()
    return {
        expected_abi = driver.TITAN_ABI_VERSION,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end,
    }
end

local function assert_provider_pair(workspace, provider, module_names,
                                    validate_archive_protocols)
    local dso = shared_path(workspace, provider)
    local archive_path = workspace .. "/" .. provider .. ".a"
    assert.equal("file", lfs.attributes(dso, "mode"))
    if platform.windows then
        assert.is_nil(lfs.attributes(archive_path, "mode"))
        local names = {}
        for _, name in ipairs(module_names) do names[#names + 1] = string.format("%q", name) end
        -- A checked provider remains mapped for a process's lifetime on
        -- Windows. This child owns metadata reads, so later cases can rebuild
        -- the same fixture without overwriting a mapped DLL in Busted.
        local valid, output = run_lua(workspace, string.format([[
local driver = require "titan-compiler.driver"
local names = { %s }
local entries = assert(driver.library_interface_entries(%q, names))
assert(driver.validate_library_image(%q, names))
local keys = {}
for name in pairs(entries) do keys[#keys + 1] = name end
table.sort(keys)
for _, name in ipairs(keys) do print(name) end
]], table.concat(names, ", "), dso, dso))
        assert.truthy(valid, output)
        local keys = {}
        for name in output:gmatch("[^\r\n]+") do keys[#keys + 1] = name end
        local expected = { table.unpack(module_names) }
        table.sort(expected)
        assert.same(expected, keys)
        return { key_order = keys }
    end
    assert.equal("file", lfs.attributes(archive_path, "mode"))

    local archive, archive_err =
        staticmetadata.scan_archive(archive_path, metadata_options())
    assert.truthy(archive, archive_err)
    local callable, callable_err =
        driver.library_interface_entries(dso, module_names)
    assert.truthy(callable, callable_err)
    local equal, equality_err = driver.compare_archive_entries(
        archive.entries, callable, "published provider pair")
    assert.truthy(equal, equality_err)
    assert.truthy(driver.validate_library_image(dso, module_names))

    if validate_archive_protocols then
        local image = shared_path(workspace, "archive-protocol-validation")
        local linked, link_term, link_code =
            driver.compile_archive_validation_image(
                image, archive_path, nil, false)
        assert.truthy(linked, table.concat({
            tostring(link_term), tostring(link_code),
        }, ", "))
        local valid, validation_err =
            driver.validate_library_image(image, module_names)
        assert.truthy(valid, validation_err)
        local archive_equal, archive_equality_err =
            driver.validate_archive_library_equality(
                archive, image, module_names)
        assert.truthy(archive_equal, archive_equality_err)
        os.remove(image)
        if lfs.attributes(image .. ".dSYM", "mode") then
            remove_tree(image .. ".dSYM")
        end
    end
    return archive
end

describe("multiple logical modules through one public shared library", function()
    local workspace
    local source_root
    local verbose_output

    setup(function()
        workspace = temporary_workspace()
        source_root = workspace .. "/source"
        make_directory(source_root .. "/pkg")

        write_file(source_root .. "/pkg/shared.titan", [[
local visits: integer = 0

function touch(): integer
    visits = visits + 1
    return visits
end

function identity(value_: value): value
    return value_
end
]])
        write_file(source_root .. "/pkg/left.titan", [[
local common = import "pkg.shared"
local current: integer = 10

record Box
    n: integer;
end

function read(): integer
    return current + common.touch()
end

function callable_relay(): integer
    local broad: function (value): value = common.identity
    local narrowed: function (Box): Box = broad
    local dynamic: value = narrowed
    local wider: function (Box, value): Box = dynamic
    return wider(Box.new(42), "ignored").n
end

do
    current = current + 1
end
]])
        write_file(source_root .. "/pkg/right.titan", [[
local common = import "pkg.shared"
local current: integer = 20

function read(): integer
    return current + common.touch()
end

do
    current = current + 2
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        verbose_output = output
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("publishes one physical provider and emits one shim per logical source module",
       function()
        local archive = assert_provider_pair(workspace, "pkg", {
            "pkg.left", "pkg.right", "pkg.shared",
        }, true)
        assert.same({
            "pkg.left", "pkg.right", "pkg.shared",
        }, archive.key_order)
        for _, name in ipairs({ "left", "right", "shared" }) do
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".c", "mode"))
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".o", "mode"))
            assert.equal("file", lfs.attributes(
                workspace .. "/pkg/" .. name .. ".lua", "mode"))
            assert.is_nil(lfs.attributes(
                workspace .. "/pkg/" .. name .. SHARED_SUFFIX, "mode"))

            local shim = read_file(workspace .. "/pkg/" .. name .. ".lua")
            assert.equal("-- Generated by titanc; do not edit.",
                shim:match("([^\n]+)"))
            assert.truthy(shim:find('package.searchpath("pkg", package.cpath)',
                1, true), shim)
            assert.truthy(shim:find('"luaopen_pkg_' .. name .. '"', 1, true),
                shim)
        end

        local link_lines = {}
        for line in verbose_output:gmatch("[^\n]+") do
            if line:find("'-shared'", 1, true) then
                table.insert(link_lines, line)
            end
        end
        assert.equal(platform.windows and 1 or 2, #link_lines, verbose_output)
        local provider_link
        local archive_validation_link
        for _, line in ipairs(link_lines) do
            if line:find("/pkg/left.o'", 1, true) then
                provider_link = line
            elseif line:find("archive%-validation%.so") then
                archive_validation_link = line
            end
        end
        assert.truthy(provider_link, verbose_output)
        if not platform.windows then assert.truthy(archive_validation_link, verbose_output) end
        if driver.IS_DARWIN then
            assert.truthy(provider_link:find(
                "'-Xlinker' '-reproducible' '-Xlinker' " ..
                "'-install_name' '-Xlinker' 'pkg.so'",
                1, true), provider_link)
            assert.truthy(verbose_output:find(
                "'dsymutil' 'pkg.so'", 1, true), verbose_output)
            local relocation_map =
                single_dsym_relocation_map(workspace .. "/pkg.so.dSYM")
            assert.falsy(relocation_map:find(
                ".stage.tmp.", 1, true), relocation_map)
            assert.truthy(relocation_map:match(
                "binary%-path:%s+['\"]?pkg%.so['\"]?%s*\n"),
                relocation_map)
        end
        local left_at = assert(provider_link:find(
            "/pkg/left.o'", 1, true), provider_link)
        local right_at = assert(provider_link:find(
            "/pkg/right.o'", 1, true), provider_link)
        local shared_at = assert(provider_link:find(
            "/pkg/shared.o'", 1, true), provider_link)
        assert.is_true(left_at < right_at and right_at < shared_at,
            provider_link)
        if driver.IS_DARWIN then
            assert.truthy(archive_validation_link:find(
                "'-force_load'", 1, true), archive_validation_link)
        elseif not platform.windows then
            assert.truthy(archive_validation_link:find(
                "'-Wl,--whole-archive'", 1, true), archive_validation_link)
            assert.truthy(archive_validation_link:find(
                "'-Wl,--no-whole-archive'", 1, true),
                archive_validation_link)
        end

        local left_c = read_file(source_root .. "/pkg/left.c")
        assert.falsy(left_c:find("titan_module_provider(L,", 1, true), left_c)
        assert.truthy(left_c:find("extern Udata *pkg_shared_init", 1, true),
            left_c)
    end)

    it("rebuilds deterministic archive bytes when configured tools support D",
       function()
        if platform.windows then
            pending("Titan static provider archives and deterministic AR/RANLIB flags are unsupported on Windows")
            return
        end
        local before = read_file(workspace .. "/pkg.a")
        local ok, output, why, code = compile(
            workspace, source_root, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "pkg", {
            "pkg.left", "pkg.right", "pkg.shared",
        })
        -- Verbose output includes capability probes even when they fail.
        -- Inspect only the real staged output command, never tool-probe.a.
        if final_archive_command_uses(output, "qDc") and
           final_archive_command_uses(output, "-D") then
            assert.equal(before, read_file(workspace .. "/pkg.a"))
        end
    end)

    it("preserves provider mtimes on an unchanged warm rerun", function()
        local dso = shared_path(workspace, "pkg")
        local archive = workspace .. "/pkg.a"
        local dso_bytes = read_file(dso)
        local archive_bytes = not platform.windows and read_file(archive) or nil
        local dso_mtime = assert(lfs.attributes(dso, "modification"))
        local archive_mtime = not platform.windows and
            assert(lfs.attributes(archive, "modification")) or nil
        local waited, wait_output = run({ "sleep", "2" }, workspace)
        assert.truthy(waited, wait_output)

        local ok, output, why, code = compile(
            workspace, source_root,
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal(dso_bytes, read_file(dso))
        if not platform.windows then assert.equal(archive_bytes, read_file(archive)) end
        assert.same({
            dso = dso_mtime,
            archive = archive_mtime,
        }, {
            dso = lfs.attributes(dso, "modification"),
            archive = lfs.attributes(archive, "modification"),
        })
    end)

    it("preserves a nondeterministic ordinary archive on a warm rerun",
       function()
        if platform.windows then
            pending("Unix paired static-provider archive rebuilding with AR/RANLIB shell wrappers")
            return
        end
        local dso = shared_path(workspace, "pkg")
        local archive = workspace .. "/pkg.a"
        local counter = workspace .. "/ordinary-ranlib-count"
        local ar_log = workspace .. "/ordinary-ar-log"
        local ranlib_log = workspace .. "/ordinary-ranlib-log"
        local snapshots = workspace .. "/ordinary-archive-snapshots"
        local patcher = workspace .. "/vary-archive-headers.lua"
        local ar_wrapper = workspace .. "/ordinary-ar"
        local ranlib_wrapper = workspace .. "/ordinary-ranlib"
        make_directory(snapshots)

        write_file(patcher, [[
local archive, count_text, snapshots = ...
local count = assert(tonumber(count_text))
local input = assert(io.open(archive, "rb"))
local bytes = assert(input:read("*a"))
assert(input:close())
assert(bytes:sub(1, 8) == "!<arch>\n")

local function field(value, width)
    local text = tostring(value)
    assert(#text <= width)
    return text .. string.rep(" ", width - #text)
end

local modes = { "100640", "100641", "100642", "100643",
                "100644", "100645", "100646", "100647" }
local records = { "!<arch>\n" }
local position = 9
while position <= #bytes do
    local header = bytes:sub(position, position + 59)
    assert(#header == 60 and header:sub(59, 60) == "`\n")
    local size = assert(tonumber(
        assert(header:sub(49, 58):match("^ *(%d+) *$"))))
    local record_size = 60 + size + (size % 2)
    local record_end = position + record_size - 1
    assert(record_end <= #bytes)
    records[#records + 1] =
        header:sub(1, 16) ..
        field(1000000000 + count, 12) ..
        field(1000 + count, 6) ..
        field(2000 + count, 6) ..
        field(modes[count % #modes + 1], 8) ..
        header:sub(49, 60)
    records[#records + 1] = bytes:sub(position + 60, record_end)
    position = record_end + 1
end
assert(position == #bytes + 1)
local output = table.concat(records)

local function write(path)
    local file = assert(io.open(path, "wb"))
    assert(file:write(output))
    assert(file:close())
end

write(archive)
if archive:match("/output[.]a$") then
    write(snapshots .. "/staged-" .. tostring(count) .. ".a")
end
]])
        write_file(ar_wrapper, string.format([[#!/bin/sh
case ${1-} in
    *D*)
        printf 'reject-D\n' >> %s
        exit 71
        ;;
esac
%s "$@"
status=$?
if [ "$status" -ne 0 ]; then exit "$status"; fi
printf 'ordinary-success\n' >> %s
exit 0
]], assert(cdriver.shell_quote(ar_log)),
            quote_argv(configured_words(driver.AR)),
            assert(cdriver.shell_quote(ar_log))))
        write_file(ranlib_wrapper, string.format([[#!/bin/sh
if [ "${1-}" = "-D" ]; then
    printf 'reject-D\n' >> %s
    exit 72
fi
%s "$@"
status=$?
if [ "$status" -ne 0 ]; then exit "$status"; fi
printf 'ordinary-success\n' >> %s
count=0
if [ -f %s ]; then
    IFS= read -r count < %s || exit 73
fi
count=$((count + 1))
printf '%%s\n' "$count" > %s
%s %s "$1" "$count" %s
]], assert(cdriver.shell_quote(ranlib_log)),
            quote_argv(configured_words(driver.RANLIB)),
            assert(cdriver.shell_quote(ranlib_log)),
            assert(cdriver.shell_quote(counter)),
            assert(cdriver.shell_quote(counter)),
            assert(cdriver.shell_quote(counter)),
            assert(cdriver.shell_quote(LUA)),
            assert(cdriver.shell_quote(patcher)),
            assert(cdriver.shell_quote(snapshots))))
        local executable, chmod_output = run({
            "chmod", "u+x", ar_wrapper, ranlib_wrapper,
        }, workspace)
        assert.truthy(executable, chmod_output)

        assert.truthy(os.remove(dso))
        assert.truthy(os.remove(archive))
        if exists(dso .. ".dSYM") then remove_tree(dso .. ".dSYM") end
        local environment = {
            AR = ar_wrapper,
            RANLIB = ranlib_wrapper,
        }
        local ok, output, why, code = compile_with_environment(
            workspace, source_root, environment, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("2\n", read_file(counter))
        local first_staged =
            read_file(snapshots .. "/staged-2.a")
        local dso_bytes = read_file(dso)
        local archive_bytes = read_file(archive)
        assert.equal(first_staged, archive_bytes)
        assert.equal(archive_field(1000000002, 12),
            archive_bytes:sub(25, 36))
        local dso_mtime = assert(lfs.attributes(dso, "modification"))
        local archive_mtime = assert(lfs.attributes(archive, "modification"))
        local waited, wait_output = run({ "sleep", "2" }, workspace)
        assert.truthy(waited, wait_output)

        ok, output, why, code = compile_with_environment(
            workspace, source_root, environment, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.equal("4\n", read_file(counter))
        local second_staged =
            read_file(snapshots .. "/staged-4.a")
        assert.not_equal(first_staged, second_staged)
        assert.equal(
            normalize_regular_archive_header_noise(first_staged),
            normalize_regular_archive_header_noise(second_staged))
        assert.equal(dso_bytes, read_file(dso))
        assert.equal(archive_bytes, read_file(archive))
        assert.same({
            dso = dso_mtime,
            archive = archive_mtime,
        }, {
            dso = lfs.attributes(dso, "modification"),
            archive = lfs.attributes(archive, "modification"),
        })
        assert.equal(2, count_plain(read_file(ar_log), "reject-D\n"))
        assert.equal(4,
            count_plain(read_file(ar_log), "ordinary-success\n"))
        assert.equal(2, count_plain(read_file(ranlib_log), "reject-D\n"))
        assert.equal(4,
            count_plain(read_file(ranlib_log), "ordinary-success\n"))
        assert_provider_pair(workspace, "pkg", {
            "pkg.left", "pkg.right", "pkg.shared",
        })
    end)

    it("keeps the published pair when configured RANLIB always fails",
       function()
        if platform.windows then
            pending("Unix paired DSO/archive publication and static-provider RANLIB failure semantics")
            return
        end
        local dso = shared_path(workspace, "pkg")
        local archive = workspace .. "/pkg.a"
        local dso_bytes = read_file(dso)
        local archive_bytes = read_file(archive)
        local dso_mtime = assert(lfs.attributes(dso, "modification"))
        local archive_mtime = assert(lfs.attributes(archive, "modification"))
        local waited, wait_output = run({ "sleep", "2" }, workspace)
        assert.truthy(waited, wait_output)
        local failing_ranlib = workspace .. "/failing-ranlib"
        write_file(failing_ranlib, "#!/bin/sh\nexit 73\n")
        local executable, chmod_output =
            run({ "chmod", "u+x", failing_ranlib }, workspace)
        assert.truthy(executable, chmod_output)

        local ok, output = compile_with_environment(
            workspace, source_root, {
                RANLIB = failing_ranlib,
            }, "pkg.left", "pkg.right", "pkg.shared")
        assert.falsy(ok, output)
        assert.truthy(output:find(
            "configured RANLIB supports neither -D nor ordinary mode",
            1, true), output)
        assert.equal(dso_bytes, read_file(dso))
        assert.equal(archive_bytes, read_file(archive))
        assert.equal(dso_mtime, lfs.attributes(dso, "modification"))
        assert.equal(archive_mtime,
            lfs.attributes(archive, "modification"))
    end)

    it("derives active-target mismatch from TITAN_EXTRA_CFLAGS alone",
       function()
        if platform.windows then
            pending("Static provider target fingerprints with ELF/Mach-O object mutation")
            return
        end
        local patcher = workspace .. "/patch-target.lua"
        write_file(patcher, [[
local path = assert(arg[1])
local input = assert(io.open(path, "rb"))
local bytes = assert(input:read("*a"))
assert(input:close())

local magic = bytes:sub(1, 4)
local offset
local endian
if magic == "\127ELF" then
    local class = bytes:byte(5)
    local encoding = bytes:byte(6)
    offset = assert(class == 1 and 36 or class == 2 and 48 or nil)
    endian = assert(encoding == 1 and "little" or
        encoding == 2 and "big" or nil)
elseif magic == "\206\250\237\254" or
       magic == "\207\250\237\254" then
    offset = 8
    endian = "little"
elseif magic == "\254\237\250\206" or
       magic == "\254\237\250\207" then
    offset = 8
    endian = "big"
else
    error("unsupported generated object magic")
end

local position = offset + (endian == "little" and 1 or 4)
bytes = bytes:sub(1, position - 1) ..
    string.char(bytes:byte(position) ~ 1) ..
    bytes:sub(position + 1)
local output = assert(io.open(path, "wb"))
assert(output:write(bytes))
assert(output:close())
]])
        local marker = workspace .. "/patched-targets"
        local wrapper = workspace .. "/target-selecting-cc"
        write_file(wrapper, string.format([[#!/bin/sh
marked=no
compile=no
next_output=no
output=
for argument in "$@"; do
    if [ "$next_output" = yes ]; then
        output=$argument
        next_output=no
    elif [ "$argument" = "-o" ]; then
        next_output=yes
    elif [ "$argument" = "-c" ]; then
        compile=yes
    elif [ "$argument" = "-DTITAN_TEST_ALTERNATE_TARGET=1" ]; then
        marked=yes
    fi
done
%s "$@"
status=$?
if [ "$status" -ne 0 ]; then exit "$status"; fi
if [ "$marked" = yes ] && [ "$compile" = yes ] && [ -n "$output" ]; then
    %s %s "$output" || exit $?
    printf '%%s\n' "$output" >> %s
fi
exit 0
]], quote_argv(configured_words(driver.CC)),
            assert(cdriver.shell_quote(LUA)),
            assert(cdriver.shell_quote(patcher)),
            assert(cdriver.shell_quote(marker))))
        local executable, chmod_output =
            run({ "chmod", "u+x", wrapper }, workspace)
        assert.truthy(executable, chmod_output)

        write_file(source_root .. "/targetcheck.titan", [[
local left = import "pkg.left"

function read(): integer
    return left.read()
end
]])
        local environment = {
            CC = wrapper,
            TITAN_EXTRA_CFLAGS = "",
        }
        local ok, output, why, code = compile_with_environment(
            workspace, source_root, environment,
            "--static", "targetcheck")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.is_nil(lfs.attributes(marker, "mode"))

        environment.TITAN_EXTRA_CFLAGS =
            "-DTITAN_TEST_ALTERNATE_TARGET=1"
        ok, output = compile_with_environment(
            workspace, source_root, environment,
            "--static", "targetcheck")
        assert.falsy(ok, output)
        assert.truthy(output:find("target mismatch", 1, true), output)
        assert.truthy(read_file(marker):find(
            source_root .. "/targetcheck.o", 1, true))

        local active, active_err = driver.derive_target_fingerprint(
            source_root .. "/targetcheck.o", "targetcheck")
        assert.truthy(active, active_err)
        local provider, provider_err = staticmetadata.scan_archive(
            workspace .. "/pkg.a", metadata_options())
        assert.truthy(provider, provider_err)
        local matches = staticmetadata.fingerprint_matches(
            provider.members[1].fingerprint, active)
        assert.is_false(matches)
    end)

    it("keeps logical module state independent while reusing the provider",
       function()
        local ok, output = run_lua(workspace, [[
local right = require "pkg.right"
local left = require "pkg.left"
assert(right.read() == 23)
assert(left.read() == 13)
assert(left.callable_relay() == 42)
assert(require("pkg.right") == right)
assert(require("pkg.left") == left)
]])
        assert.truthy(ok, output)
    end)

    it("binds every folder contributor alias to one compiled module state",
       function()
        -- This source tree contains only the client. pkg.shared must resolve
        -- through the separately compiled provider in workspace, not source.
        local client_root = workspace .. "/alias-client-source"
        write_file(client_root .. "/alias_client/alias_client.titan", [[
local first = import "pkg.shared"
local second = import "pkg.shared"

function run(): integer
    local a = first.touch()
    local b = second.touch()
    local c = third_touch()
    local d = fourth_touch()
    return a * 1000 + b * 100 + c * 10 + d
end
]])
        write_file(client_root .. "/alias_client/aliases.titan", [[
local third = import "pkg.shared"
local fourth = import "pkg.shared"

local function third_touch(): integer
    return third.touch()
end

local function fourth_touch(): integer
    return fourth.touch()
end
]])
        local ok, output, why, code =
            compile(workspace, client_root, "alias_client")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output = run_lua(workspace, [[
local client = require "alias_client"
assert(client.run() == 1234)
assert(client.run() == 5678)
]])
        assert.truthy(ok, output)
    end)

    it("supports a binary-only external consumer through the selected provider",
       function()
        write_file(source_root .. "/consumer.titan", [[
local left = import "pkg.left"
local right = import "pkg.right"

function run(): integer
    return left.read() * 100 + right.read()
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "consumer", { "consumer" })

        local generated = read_file(source_root .. "/consumer.c")
        -- Each logical import retains the selected physical provider as its
        -- fallback. Existing-state initialization does not repeat native wiring.
        assert.equal(1, count_plain(generated,
            'titan_module_provider(L, "pkg.left", "pkg' .. SHARED_SUFFIX .. '")'))
        assert.equal(1, count_plain(generated,
            'titan_module_provider(L, "pkg.right", "pkg' .. SHARED_SUFFIX .. '")'))
        assert.falsy(generated:find(
            'titan_module_provider(L, "pkg.left", "pkg/left' .. SHARED_SUFFIX .. '")', 1, true))
        assert.falsy(generated:find(
            'titan_module_provider(L, "pkg.right", "pkg/right' .. SHARED_SUFFIX .. '")', 1, true))
        assert.truthy(generated:find('"pkg_left_abi"', 1, true), generated)
        assert.truthy(generated:find('"pkg_right_abi"', 1, true), generated)
        assert.truthy(generated:find('"pkg_left_compatibility"', 1, true), generated)
        assert.truthy(generated:find('"pkg_right_compatibility"', 1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 1224)
]])
        assert.truthy(ok, output)
    end)

    it("aborts when a multi-module DSO changes a used member signature",
       function()
        -- Recompile pkg.so with an incompatible type interface for pkg.left while keeping pkg.right
        write_file(source_root .. "/pkg/left.titan", [[
local common = import "pkg.shared"
function read(): string
    return "incompatible"
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Attempting to run consumer (which was compiled expecting integer from left.read())
        -- must identify the required pkg.left.read contract that changed.
        ok, output = run_lua(workspace, [[
local ok, err = pcall(require, "consumer")
assert(not ok, "expected require to fail")
assert(err:find("binary compatibility mismatch importing 'pkg.left'", 1, true), err)
assert(err:find("functions.read", 1, true), err)
]])
        assert.truthy(ok, output)
    end)
end)

describe("dense arrays through one shared prefix provider", function()
    local workspace
    local source_root

    before_each(function()
        workspace = temporary_workspace()
        source_root = workspace .. "/source"
        make_directory(source_root .. "/arraypkg")

        write_file(source_root .. "/arraypkg/shared.titan", [[
function make(): {value}
    return {10, nil, 30}
end

function set(xs: {value}, i: integer, v: value)
    xs[i] = v
end

function echo(xs: {value}): {value}
    return xs
end
]])
        write_file(source_root .. "/arraypkg/left.titan", [[
local shared = import "arraypkg.shared"

function roundtrip(): {value}
    local xs = shared.make()
    shared.set(xs, 5, 50)
    return shared.echo(xs)
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "arraypkg.left", "arraypkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("shares one Array between its logical modules", function()
        assert_provider_pair(workspace, "arraypkg", {
            "arraypkg.left", "arraypkg.shared",
        }, true)
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "arraypkg/left"), "mode"))
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "arraypkg/shared"), "mode"))

        local ok, output = run_lua(workspace, [[
local left = require "arraypkg.left"
local shared = require "arraypkg.shared"
local xs = left.roundtrip()
assert(type(xs) == "userdata")
assert(#xs == 5)
assert(xs[1] == 10 and xs[2] == nil and xs[3] == 30)
assert(xs[4] == nil and xs[5] == 50)
assert(shared.echo(xs) == xs)
]])
        assert.truthy(ok, output)
    end)
end)

describe("native trace names across one multi-module image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = temporary_workspace()
        source_root = workspace .. "/source"

        write_file(source_root .. "/warmup.titan", [[
function boom(): integer
    raise "warmup"
    return 0
end
]])
        write_file(source_root .. "/trace/right.titan", [[
function boom(): integer
    raise "combined"
    return 0
end
]])
        write_file(source_root .. "/trace/left.titan", [[
local right = import "trace.right"

function relay(): integer
    return right.boom()
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("refreshes libbacktrace and symbolizes frames from separate objects",
       function()
        local ok, output, why, code =
            compile(workspace, source_root, "warmup")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "warmup", { "warmup" })

        ok, output, why, code = compile(
            workspace, source_root, "trace.left", "trace.right")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "trace", {
            "trace.left", "trace.right",
        })
        assert.is_nil(lfs.attributes(shared_path(workspace, "trace/left"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/left.a", "mode"))
        assert.is_nil(lfs.attributes(shared_path(workspace, "trace/right"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/right.a", "mode"))

        ok, output = run_lua(workspace, [[
local titan = require "titan"
local warmup = require "warmup"
local warm_ok, warm_err = pcall(warmup.boom)
assert(not warm_ok and warm_err == "warmup")
local warm_trace = titan.backtrace()
assert(warm_trace:find("in warmup.boom", 1, true), warm_trace)

-- Loading trace.so after the first trace must invalidate libbacktrace's
-- snapshot. The next trace crosses the left.c and right.c objects linked into
-- that one provider, and each object contributes its own logical name table.
local left = require "trace.left"
local combined_ok, combined_err = pcall(left.relay)
assert(not combined_ok and combined_err == "combined")
local combined_trace = titan.backtrace()
assert(combined_trace:find("in trace.right.boom", 1, true), combined_trace)
assert(combined_trace:find("in trace.left.relay", 1, true), combined_trace)
assert(combined_trace:find(
    "right%.titan:%d+: in trace%.right%.boom"), combined_trace)
assert(combined_trace:find(
    "left%.titan:%d+: in trace%.left%.relay"), combined_trace)
assert(not combined_trace:find("in warmup.boom", 1, true), combined_trace)
assert(not combined_trace:find("titanentry", 1, true), combined_trace)
]])
        assert.truthy(ok, output)
    end)
end)

describe("rich logical interfaces inside one shared image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = temporary_workspace()
        source_root = workspace .. "/source"

        write_file(source_root .. "/shape/api.titan", [[
interface Incrementer
    function add(delta: integer): integer
end

interface Dynamic
    function convert(input: value): value
end
]])
        write_file(source_root .. "/shape/consumer.titan", [[
local api = import "shape.api"

function use(value_: api.Incrementer): integer
    local add: function (integer): integer = value_:add
    return add(2)
end

function use_dynamic(value_: api.Dynamic, input: value): value
    local convert: function (value): value = value_:convert
    return convert(input)
end
]])
        write_file(source_root .. "/shape/provider.titan", [[
record Foo
    n: integer
end

function Foo.make(n: integer): Foo
    return Foo.new(n)
end

function Foo:plus(delta: integer): integer
    return self.n + delta
end

function Foo:add(delta: integer): integer
    return self.n + delta
end

function Foo:convert(input: integer): integer
    return self.n + input
end

function inc(x: integer): integer
    return x + 1
end

function twice(f: function (integer): integer, x: integer): integer
    return f(f(x))
end
]])
        write_file(source_root .. "/shape/facade.titan", [[
local api = import "shape.api"
local consumer = import "shape.consumer"
local provider = import "shape.provider"

type Foo = provider.Foo

function make(n: integer): Foo
    return provider.Foo.make(n)
end

function exact(x: integer): integer
    return provider.twice(provider.inc, x)
end

function roundtrip_exact(x: integer): integer
    local dynamic: value = provider.inc
    local f: function (integer): integer = dynamic
    return f(x)
end

function interface_exact(n: integer): integer
    local incrementer: api.Incrementer = provider.Foo.new(n)
    return consumer.use(incrementer)
end

function interface_adjusted(n: integer): integer
    local dynamic: api.Dynamic = provider.Foo.new(n)
    local converted = consumer.use_dynamic(dynamic, n as value)
    return converted as integer
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("preserves rich APIs and four-module Interface topology through consumers",
       function()
        local ok, output, why, code = compile(
            workspace, source_root,
            "shape.api", "shape.consumer", "shape.provider", "shape.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert_provider_pair(workspace, "shape", {
            "shape.api", "shape.consumer", "shape.facade", "shape.provider",
        })
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "shape/provider"), "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/provider.a", "mode"))
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "shape/facade"), "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/facade.a", "mode"))
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "shape/api"), "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/consumer.a", "mode"))

        write_file(source_root .. "/consumer.titan", [[
local facade = import "shape.facade"

function run(): integer
    local foo: facade.Foo = facade.make(40)
    local plus: function (integer): integer = foo:plus
    return foo:plus(1) + plus(2) + facade.exact(1)
        + facade.roundtrip_exact(5)
end
]])
        ok, output, why, code = compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "consumer", { "consumer" })

        local generated = read_file(source_root .. "/consumer.c")
        assert.truthy(generated:find('titan_module_provider(L, "shape.facade", "shape' .. SHARED_SUFFIX .. '")', 1, true),
            generated)
        assert.falsy(generated:find(
            'titan_module_provider(L, "shape.facade", "shape/facade' .. SHARED_SUFFIX .. '")', 1, true), generated)
        assert.truthy(generated:find(
            'titan_module_provider(L, "shape.provider", NULL)', 1, true),
            generated)
        local plus_symbol = coder_core.c_string_literal(
            coder_names._linkage_symbol_name(
                "shape_provider_\\u2133_Foo_\\u2131_plus_titanmethod"))
        assert.match(
            'titan_module_symbol%s*%(%s*L,%s*shape_provider_provider,%s*' ..
                plus_symbol .. '%s*%)',
            generated)
        assert.falsy(generated:find(
            "shape_api_init", 1, true), generated)
        assert.falsy(generated:find(
            "shape_consumer_init", 1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 92)
local facade = require "shape.facade"
local provider = require "shape.provider"
assert(facade.make(7):plus(8) == 15)
assert(provider.Foo.make(9):plus(1) == 10)
assert(facade.interface_exact(40) == 42)
assert(facade.interface_adjusted(20) == 40)
]])
        assert.truthy(ok, output)

        write_file(source_root .. "/shape_app.titan", [[
local facade = import "shape.facade"

function main(args: {string}): integer
    if facade.interface_exact(40) == 42 and
       facade.interface_adjusted(20) == 40 then
        return 0
    else
        return 1
    end
end
]])
        local arguments = platform.windows and { "shape_app" } or { "--static", "shape_app" }
        ok, output, why, code = compile(workspace, source_root, table.unpack(arguments))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local static_generated = read_file(source_root .. "/shape_app.c")
        if platform.windows then
            assert.truthy(static_generated:find(
                'titan_module_provider(L, "shape.facade", "shape.dll")', 1, true), static_generated)
        else
            assert.falsy(static_generated:find(
                'titan_module_provider(L, "shape.facade", "shape.so")', 1, true), static_generated)
            assert.truthy(static_generated:find(
                "extern Udata *shape_facade_init", 1, true), static_generated)
        end
        assert.falsy(static_generated:find(
            "shape_api_init", 1, true), static_generated)
        assert.falsy(static_generated:find(
            "shape_consumer_init", 1, true), static_generated)

        if not platform.windows then
            -- The Unix standalone selected the ancestor archive while its
            -- DSO sibling was present. Removing it proves no dynamic
            -- Interface owner or implementer lookup remains at run time.
            assert.truthy(os.remove(shared_path(workspace, "shape")))
        end
        ok, output, why, code = run_program(workspace, "shape_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)
end)

describe("public static-provider composition", function()
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

    local function write_app(name, dependency, expected)
        write_file(source_root .. "/apps/" .. name .. ".titan",
            string.format([[
local dependency = import %q

function main(args: {string}): integer
    if dependency.get() == %d then
        return 0
    else
        return 1
    end
end
]], dependency, expected))
    end

    it("links exact Interface archives into a standalone four-module bridge",
       function()
        if platform.windows then
            pending("Titan static Interface archive providers are unsupported on Windows")
            return
        end
        write_file(source_root .. "/exact_iface/api.titan", [[
interface Incrementer
    function add(delta: integer): integer
end

interface Dynamic
    function convert(input: value): value
end
]])
        write_file(source_root .. "/exact_iface/provider.titan", [[
record Box
    n: integer
end

function Box:add(delta: integer): integer
    return self.n + delta
end

function Box:convert(input: integer): integer
    return self.n + input
end
]])

        local ok, output, why, code =
            compile(workspace, source_root, "exact_iface.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            compile(workspace, source_root, "exact_iface.provider")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(
            workspace, "exact_iface/api", { "exact_iface.api" })
        assert_provider_pair(
            workspace, "exact_iface/provider", {
                "exact_iface.provider",
            })

        -- Leave only the terminal regular archives visible. The consumer
        -- knows the Interface owner but not the concrete provider; the bridge
        -- is the first source module to introduce both.
        assert.truthy(os.remove(shared_path(workspace, "exact_iface/api")))
        assert.truthy(os.remove(shared_path(workspace, "exact_iface/provider")))
        write_file(source_root .. "/exact_iface/consumer.titan", [[
local api = import "exact_iface.api"

function use(value_: api.Incrementer): integer
    local add: function (integer): integer = value_:add
    return add(2)
end

function use_dynamic(value_: api.Dynamic, input: value): value
    local convert: function (value): value = value_:convert
    return convert(input)
end
]])
        write_file(source_root .. "/exact_iface/bridge.titan", [[
local api = import "exact_iface.api"
local consumer = import "exact_iface.consumer"
local provider = import "exact_iface.provider"

function main(args: {string}): integer
    local incrementer: api.Incrementer = provider.Box.new(40)
    local dynamic: api.Dynamic = provider.Box.new(20)
    local converted = consumer.use_dynamic(dynamic, 20 as value)
    local converted_integer = converted as integer
    if consumer.use(incrementer) == 42 and
       converted_integer == 40 then
        return 0
    else
        return 1
    end
end
]])
        ok, output, why, code =
            compile(workspace, source_root, "exact_iface.bridge")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated =
            read_file(source_root .. "/exact_iface/bridge.c")
        assert.falsy(generated:find(
            'titan_module_provider(L, "exact_iface.api", "exact_iface/api.so")', 1, true), generated)
        assert.falsy(generated:find(
            'titan_module_provider(L, "exact_iface.provider", "exact_iface/provider.so")', 1, true), generated)
        assert.truthy(generated:find(
            "extern Udata *exact_iface_api_init", 1, true), generated)
        assert.truthy(generated:find(
            "extern Udata *exact_iface_provider_init", 1, true), generated)

        ok, output, why, code =
            run_program(workspace, "exact_iface/bridge")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("honors default/static preference, both fallbacks, and hidden-DSO execution",
       function()
        if platform.windows then
            pending("Titan static-provider selection and archive fallback are unsupported on Windows")
            return
        end
        local dynamic_build = workspace .. "/dynamic"
        local static_build = workspace .. "/static"
        local dynamic_source = dynamic_build .. "/source"
        local static_source = static_build .. "/source"
        make_directory(dynamic_source)
        make_directory(static_source)
        write_file(dynamic_source .. "/choice/api.titan", [[
function get(): integer
    return 11
end
]])
        write_file(static_source .. "/choice/api.titan", [[
function get(): integer
    return 22
end
]])

        local ok, output, why, code =
            compile(dynamic_build, dynamic_source, "choice.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            compile(static_build, static_source, "choice.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local dynamic_dso = dynamic_build .. "/choice/api.so"
        local static_archive = static_build .. "/choice/api.a"
        local selected_dso = shared_path(workspace, "choice/api")
        local selected_archive = workspace .. "/choice/api.a"
        copy_file(dynamic_dso, selected_dso)
        copy_file(static_archive, selected_archive)
        local dso_bytes = read_file(selected_dso)
        local archive_bytes = read_file(selected_archive)

        write_app("default_choice", "choice.api", 11)
        ok, output, why, code =
            compile(workspace, source_root, "apps.default_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/default_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_app("static_choice", "choice.api", 22)
        ok, output, why, code = compile(
            workspace, source_root, "--static", "apps.static_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(selected_dso))
        ok, output, why, code =
            run_program(workspace, "apps/static_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- `--static` is a preference: without the archive it uses the DSO.
        write_file(selected_dso, dso_bytes)
        assert.truthy(os.remove(selected_archive))
        write_app("static_dso_fallback", "choice.api", 11)
        ok, output, why, code = compile(
            workspace, source_root, "--static",
            "apps.static_dso_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/static_dso_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Default mode likewise falls through from DSO to archive.
        write_file(selected_archive, archive_bytes)
        assert.truthy(os.remove(selected_dso))
        write_app("default_archive_fallback", "choice.api", 22)
        ok, output, why, code = compile(
            workspace, source_root, "apps.default_archive_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/default_archive_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Source remains the final dependency fallback after both native
        -- format passes.
        assert.truthy(os.remove(selected_archive))
        write_file(source_root .. "/choice/api.titan", [[
function get(): integer
    return 33
end
]])
        write_app("source_fallback", "choice.api", 33)
        ok, output, why, code =
            compile(workspace, source_root, "apps.source_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/source_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("repackages complete provider membership and consumes it statically",
       function()
        if platform.windows then
            pending("Titan static-provider archive repackaging and standalone extraction are unsupported on Windows")
            return
        end
        local provider_a = workspace .. "/provider-a"
        local provider_b = workspace .. "/provider-b"
        local source_a = provider_a .. "/source"
        local source_b = provider_b .. "/source"
        make_directory(source_a)
        make_directory(source_b)
        write_file(source_a .. "/base/owner.titan", [[
record Box
    n: integer
end

function make(n: integer): Box
    return Box.new(n)
end
]])
        write_file(source_a .. "/base/facade.titan", [[
local owner = import "base.owner"
type Box = owner.Box

function get(): integer
    local make: function (integer): Box = Box.new
    return make(40).n
end
]])
        local ok, output, why, code = compile(
            provider_a, source_a, "base.owner", "base.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        copy_file(provider_a .. "/base.so", provider_b .. "/base.so")
        copy_file(provider_a .. "/base.a", provider_b .. "/base.a")

        write_file(source_b .. "/bundle/impl.titan", [[
local facade = import "base.facade"
type Box = facade.Box

local initialized = 0

function get(): integer
    return facade.get() + 2
end

function make(n: integer): Box
    return facade.Box.new(n)
end

function initializations(): integer
    return initialized
end

do
    initialized = initialized + 1
end
]])
        write_file(source_b .. "/bundle/api.titan", [[
local impl = import "bundle.impl"
type Box = impl.Box

local initialized = 0

function get(): integer
    return impl.get()
end

function make(n: integer): Box
    return impl.make(n)
end

function initializations(): integer
    return initialized
end

function impl_initializations(): integer
    return impl.initializations()
end

do
    initialized = initialized + 1
end
]])
        write_file(source_b .. "/bundle/unused.titan", [[
function get(): integer
    return 99
end
]])
        ok, output, why, code = compile(
            provider_b, source_b, "--static",
            "bundle.api", "bundle.impl", "bundle.unused")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local bundle = assert_provider_pair(
            provider_b, "bundle", {
                "base.facade", "base.owner", "bundle.api", "bundle.impl",
                "bundle.unused",
            }, true)
        assert.same({
            "base.facade", "base.owner", "bundle.api", "bundle.impl",
            "bundle.unused",
        }, bundle.key_order)
        assert.equal("file", lfs.attributes(
            provider_b .. "/base/facade.lua", "mode"))
        assert.equal("file", lfs.attributes(
            provider_b .. "/base/owner.lua", "mode"))

        -- The selected provider has been flattened into B. Remove A entirely
        -- before compiling and running the static consumer.
        assert.truthy(os.remove(provider_b .. "/base.so"))
        assert.truthy(os.remove(provider_b .. "/base.a"))
        write_file(source_b .. "/app.titan", [=[
local api = import "bundle.api"
local tlua = import "lua"

function main(args: {string}): integer
    if api.initializations() ~= 1 or api.impl_initializations() ~= 1 then
        return 1
    end

    local preload_state = tlua.load([[
return type(package.preload["bundle.api"]),
       type(package.preload["bundle.impl"]),
       package.preload["bundle.unused"],
       package.loaded["bundle.api"],
       package.loaded["bundle.impl"]
]], "=static-standalone-preload-state", nil)
    local api_preload: value, impl_preload: value, unused_preload: value,
          cached_api: value, cached_impl: value = preload_state()
    if api_preload as string ~= "function" or
       impl_preload as string ~= "function" or unused_preload ~= nil or
       cached_api ~= nil or cached_impl ~= nil then
        return 2
    end

    local loaded_api = tlua.require("bundle.api")
    if tlua.require("bundle.api") ~= loaded_api then return 3 end
    local loaded_impl = tlua.require("bundle.impl")
    if tlua.require("bundle.impl") ~= loaded_impl then return 4 end
    local inspect = tlua.load([[
local module = ...
local box = module.make(42)
return module.get(), module.initializations(), box.n
]], "=static-standalone-preload", nil)
    local api_answer: value, api_initialized: value, api_box: value =
        inspect(loaded_api)
    local impl_answer: value, impl_initialized: value, impl_box: value =
        inspect(loaded_impl)
    local make: function (integer): api.Box = api.Box.new
    if api_answer as integer ~= 42 or api_initialized as integer ~= 1 or
       api_box as integer ~= 42 or impl_answer as integer ~= 42 or
       impl_initialized as integer ~= 1 or impl_box as integer ~= 42 or
       api.initializations() ~= 1 or api.impl_initializations() ~= 1 or
       make(42).n ~= 42 then
        return 5
    end
    return 0
end
]=])
        ok, output, why, code =
            compile_with_environment(provider_b, source_b, {
                TITAN_PATH_0_6 = provider_b .. ";;",
            }, "--static", "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(provider_b .. "/bundle.so"))
        assert.truthy(os.remove(provider_b .. "/bundle/api.lua"))
        assert.truthy(os.remove(provider_b .. "/bundle/impl.lua"))
        assert.truthy(os.remove(provider_b .. "/bundle/unused.lua"))
        ok, output, why, code = run_program(provider_b, "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Carried physical membership remains unavailable through an
        -- unrelated ordinary lookup: bundle.a is not a candidate for
        -- base.owner.
        write_file(source_b .. "/negative.titan", [[
local owner = import "base.owner"

function probe(): integer
    return owner.make(1).n
end
]])
        ok, output = compile(provider_b, source_b, "--static", "negative")
        assert.falsy(ok)
        assert.truthy(output:find(
            "module 'base.owner' not found", 1, true), output)
    end)

    it("rejects raw members and repackages real macOS metadata objects",
       function()
        if platform.windows then
            pending("Mach-O universal Titan archive metadata and libtool repackaging")
            return
        end
        if not driver.IS_DARWIN then return end

        write_file(source_root .. "/fat/api.titan", [[
function get(): integer
    return 42
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "fat.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated = source_root .. "/fat/api.c"
        local function compile_arch(arch)
            local object = workspace .. "/fat-api-" .. arch .. ".o"
            local argv = { "env", "CCACHE_DISABLE=1" }
            for _, word in ipairs(configured_words(driver.CC)) do
                argv[#argv + 1] = word
            end
            argv[#argv + 1] = "-arch"
            argv[#argv + 1] = arch
            for _, word in ipairs(configured_words(driver.CFLAGS)) do
                argv[#argv + 1] = word
            end
            for _, word in ipairs({
                "-c", generated,
                "-I", assert(driver.INCLUDE_PATH),
                "-I", assert(driver.LUA_SOURCE_PATH),
                "-o", object,
            }) do
                argv[#argv + 1] = word
            end
            local compiled, compile_output = run(argv, workspace)
            assert.truthy(compiled, compile_output)
            return object
        end

        local x86_object = compile_arch("x86_64")
        local arm_object = compile_arch("arm64")
        local x86_archive = make_archive(
            workspace, "fat-api-x86_64.a", { x86_object })
        local arm_archive = make_archive(
            workspace, "fat-api-arm64.a", { arm_object })

        local raw = workspace .. "/raw.txt"
        write_file(raw, "titan metadata is not a Mach-O object\n")
        local raw_archive = workspace .. "/raw-member.a"
        -- Current Darwin ar may report success while discarding a non-Mach-O
        -- input. Construct the regular archive directly so both Apple tools
        -- receive the malformed member this test intends to exercise.
        write_file(raw_archive, regular_archive_bytes({
            { name = "raw.txt/", data = read_file(raw) },
        }))
        assert.truthy(read_file(raw_archive):find(
            "titan metadata is not a Mach-O object", 1, true))
        local rejected, raw_err =
            staticmetadata.scan_archive(raw_archive, metadata_options())
        assert.falsy(rejected)
        assert.match("unsupported native object", raw_err, 1, true)

        local raw_libtool = workspace .. "/raw-libtool.a"
        local accepted, rejection_output = run({
            "/usr/bin/libtool", "-static", "-o", raw_libtool,
            raw_archive,
        }, workspace)
        if accepted then
            local filtered, filtered_err =
                staticmetadata.scan_archive(
                    raw_libtool, metadata_options())
            assert.truthy(filtered, filtered_err)
            assert.equal("archive", filtered.kind)
            assert.equal(0, #filtered.members)
            assert.same({}, filtered.key_order)
        else
            assert.truthy(
                rejection_output:find("raw-member.a", 1, true) or
                rejection_output:find("raw.txt", 1, true),
                rejection_output)
        end

        local raw_universal = workspace .. "/raw-universal.a"
        accepted, rejection_output = run({
            "/usr/bin/lipo", "-create",
            x86_archive, raw_archive,
            "-output", raw_universal,
        }, workspace)
        assert.falsy(accepted, rejection_output)
        assert.truthy(
            rejection_output:find("raw-member.a", 1, true) or
            rejection_output:find("raw.txt", 1, true),
            rejection_output)

        local universal = workspace .. "/fat/api.a"
        assert.truthy(os.remove(universal))
        ok, output = run({
            "/usr/bin/lipo", "-create",
            x86_archive, arm_archive,
            "-output", universal,
        }, workspace)
        assert.truthy(ok, output)
        assert.truthy(os.remove(shared_path(workspace, "fat/api")))

        local fat, fat_err = staticmetadata.scan_archive(
            universal, metadata_options())
        assert.truthy(fat, fat_err)
        assert.equal("fat_archive", fat.kind)
        assert.same({ "fat.api" }, fat.key_order)
        assert.equal(2, #fat.slices)

        write_file(source_root .. "/bundle/api.titan", [[
local fat = import "fat.api"

function get(): integer
    return fat.get()
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "bundle.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local bundle = assert_provider_pair(
            workspace, "bundle/api", {
                "bundle.api", "fat.api",
            }, true)
        assert.equal("archive", bundle.kind)
        assert.same({ "bundle.api", "fat.api" }, bundle.key_order)

        local libtool_archive = workspace .. "/bundle-libtool.a"
        ok, output = run({
            "/usr/bin/libtool", "-static", "-o", libtool_archive,
            workspace .. "/bundle/api.a",
        }, workspace)
        assert.truthy(ok, output)
        local libtool_result, libtool_err = staticmetadata.scan_archive(
            libtool_archive, metadata_options())
        assert.truthy(libtool_result, libtool_err)
        assert.equal("archive", libtool_result.kind)
        assert.same(bundle.key_order, libtool_result.key_order)

        assert.truthy(os.remove(universal))
        assert.truthy(os.remove(shared_path(workspace, "bundle/api")))
        write_file(source_root .. "/universal_app.titan", [[
local api = import "bundle.api"

function main(args: {string}): integer
    if api.get() == 42 then return 0 else return 1 end
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "universal_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "universal_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("keeps unused archive members unextracted and resolves later -X runtime references",
       function()
        if platform.windows then
            pending("Titan static-provider member extraction and POSIX runtime/backtrace payload references")
            return
        end
        local missing_header = source_root .. "/never_available.h"
        write_file(missing_header,
            "int titan_test_never_available(void);\n")
        write_file(source_root .. "/bundle/api.titan", [[
function get(): integer
    return 42
end
]])
        write_file(source_root .. "/bundle/unused.titan",
            string.format([[
foreign import %q

function get(): integer
    return ffi.titan_test_never_available() as integer
end
]], missing_header))
        local definition = compile_c_object(
            workspace, "never-available-definition", [[
int titan_test_never_available(void) { return 9; }
]])
        local ok, output, why, code = compile(
            workspace, source_root, "bundle.api", "bundle.unused",
            "-X", definition)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Rebuild the candidate archive from only the two Titan objects. The
        -- unused module now has an intentionally unresolved private native
        -- dependency which must remain inert under ordinary extraction.
        local lean_archive = make_archive(
            workspace, "lean-bundle.a", {
                source_root .. "/bundle/api.o",
                source_root .. "/bundle/unused.o",
            })
        copy_file(lean_archive, workspace .. "/bundle.a")

        local support = compile_c_object(
            workspace, "support-needs-titan-runtime", [[
typedef struct lua_State lua_State;
extern void titan_invalidate_backtrace_state(lua_State *L);
void support_needs_titan_runtime(void) {
    titan_invalidate_backtrace_state((lua_State *)0);
}
]])
        write_file(source_root .. "/app.titan", [[
local api = import "bundle.api"

function main(args: {string}): integer
    if api.get() == 42 then return 0 else return 1 end
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "app", "-X", support)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(shared_path(workspace, "bundle")))
        os.remove(workspace .. "/bundle/api.lua")
        os.remove(workspace .. "/bundle/unused.lua")
        ok, output, why, code = run_program(workspace, "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("carries object/archive -X payload into providers and rejects metadata",
       function()
        local direct = compile_c_object(workspace, "direct-payload",
            "int direct_payload(void) { return 17; }\n")
        local archived_object = compile_c_object(
            workspace, "archived-payload",
            "int archived_payload(void) { return 19; }\n")
        local payload_archive = make_archive(
            workspace, "native-payload.a", { archived_object })
        local leading_dash = compile_c_object(
            workspace, "-leading-payload",
            "int leading_dash_payload(void) { return 23; }\n")
        local leading_dash_relative =
            assert(leading_dash:match("([^/]+)$"))
        write_file(source_root .. "/payload/item.titan", [[
function get(): integer
    return 7
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v", "payload.item",
            "--extra-object=" .. leading_dash_relative,
            direct, payload_archive)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local dso_link = assert(output:match("[^\n]*'%-shared'[^\n]*"),
            output)
        if driver.IS_DARWIN then
            assert.truthy(dso_link:find(
                "'-Xlinker' '-reproducible' '-Xlinker' " ..
                "'-install_name' '-Xlinker' 'payload/item.so'",
                1, true), dso_link)
            assert.truthy(output:find(
                "'dsymutil' 'item.so'", 1, true), output)
            local relocation_map = single_dsym_relocation_map(
                workspace .. "/payload/item.so.dSYM")
            assert.falsy(relocation_map:find(
                ".stage.tmp.", 1, true), relocation_map)
            assert.truthy(relocation_map:match(
                "binary%-path:%s+['\"]?item%.so['\"]?%s*\n"),
                relocation_map)
        end
        local direct_at = assert(dso_link:find(direct, 1, true), dso_link)
        local archive_at =
            assert(dso_link:find(payload_archive, 1, true), dso_link)
        local leading_dash_at =
            assert(dso_link:find(leading_dash, 1, true), dso_link)
        assert.is_true(
            leading_dash_at < direct_at and direct_at < archive_at,
            dso_link)
        local provider = assert_provider_pair(
            workspace, "payload/item", { "payload.item" }, true)
        if not platform.windows then assert.equal(4, #provider.members) end
        local outputs = { shared_path(workspace, "payload/item") }
        if not platform.windows then outputs[#outputs + 1] = workspace .. "/payload/item.a" end
        for _, output_path in ipairs(outputs) do
            local symbols = native_symbols(workspace, output_path)
            assert.truthy(symbols:find("direct_payload", 1, true), symbols)
            assert.truthy(symbols:find("archived_payload", 1, true), symbols)
            assert.truthy(symbols:find(
                "leading_dash_payload", 1, true), symbols)
        end

        write_file(source_root .. "/bad/item.titan", [[
function get(): integer
    return 9
end
]])
        ok, output = compile(
            workspace, source_root, "bad.item",
            "-X", source_root .. "/payload/item.o")
        assert.falsy(ok)
        assert.truthy(output:find(
            "contains Titan module metadata", 1, true), output)
        assert.is_nil(lfs.attributes(
            shared_path(workspace, "bad/item"), "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/bad/item.a", "mode"))
    end)
end)

describe("multi-module library preflight and native support contracts", function()
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

    it("rejects unrelated roots before producing compiler artifacts", function()
        write_file(source_root .. "/alpha.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/beta.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root, "alpha", "beta")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link modules into one shared library: 'alpha' and 'beta' " ..
            "have no common module prefix", 1, true), output)
        for _, path in ipairs({
            source_root .. "/alpha.c", source_root .. "/alpha.o",
            source_root .. "/beta.c", source_root .. "/beta.o",
            shared_path(workspace, "alpha"), workspace .. "/alpha.a",
            workspace .. "/alpha.lua",
            shared_path(workspace, "beta"), workspace .. "/beta.a",
            workspace .. "/beta.lua",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end
    end)

    it("rejects replacing a selected dynamic input provider before code generation",
       function()
        write_file(source_root .. "/foo/dep.titan",
            "function get(): integer return 1 end\n")
        write_file(source_root .. "/foo/seed.titan",
            "function get(): integer return 2 end\n")
        local ok, output, why, code = compile(
            workspace, source_root, "foo.dep", "foo.seed")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local old_provider = read_file(shared_path(workspace, "foo"))

        write_file(source_root .. "/foo/left.titan", [[
local dep = import "foo.dep"
function get(): integer return dep.get() end
]])
        write_file(source_root .. "/foo/right.titan", [[
local dep = import "foo.dep"
function get(): integer return dep.get() + 1 end
]])
        ok, output = compile(
            workspace, source_root, "foo.left", "foo.right")
        assert.falsy(ok)
        assert.truthy(output:find("native provider output", 1, true), output)
        assert.truthy(output:find("aliases input", 1, true), output)
        assert.equal(old_provider, read_file(shared_path(workspace, "foo")))
        assert.is_nil(lfs.attributes(
            source_root .. "/foo/left.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/foo/right.c", "mode"))
    end)

    it("rejects mangled symbol collisions before code generation", function()
        write_file(source_root .. "/clash/a-b.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/clash/a/b.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "clash.a-b", "clash.a.b")
        assert.falsy(ok)
        assert.truthy(output:find("both use C symbol prefix 'clash_a_b'", 1,
            true), output)
        assert.is_nil(lfs.attributes(source_root .. "/clash/a-b.c", "mode"))
        assert.is_nil(lfs.attributes(source_root .. "/clash/a/b.c", "mode"))
        assert.is_nil(lfs.attributes(shared_path(workspace, "clash"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/clash.a", "mode"))
    end)

    it("prepares source foreign headers before explicit source consumers",
       function()
        write_file(source_root .. "/headers/types.h", [[
typedef int ffi_int;
]])
        write_file(source_root .. "/headers/provider.titan", [[
foreign import "types.h"

foreign function increment(input: ffi_int): ffi_int
    return input + 1
end
]])
        write_file(source_root .. "/headers/consumer.titan", [[
foreign import "types.h"
local provider = import "headers.provider.titan"

foreign function twice(input: ffi_int): ffi_int
    return provider.increment(provider.increment(input))
end

function run(): integer
    return twice(4 as foreign ffi_int) as integer
end
]])

        local ok, output = compile(workspace, source_root, "headers.consumer")
        assert.truthy(ok, output)
        local provider_header =
            source_root .. "/headers/provider.titan.h"
        local consumer_header =
            source_root .. "/headers/consumer.titan.h"
        assert.equal("file", lfs.attributes(provider_header, "mode"))
        assert.equal("file", lfs.attributes(consumer_header, "mode"))
        local header = read_file(consumer_header)
        local dependency = assert(header:find(
            '#include "' .. provider_header .. '"', 1, true))
        local declaration = assert(header:find("twice_titan", dependency, true))
        assert.is_true(dependency < declaration)
        assert.truthy(read_file(source_root .. "/headers/consumer.c"):find(
            '#include "' .. consumer_header .. '"', 1, true))

        local ran, result = run_lua(workspace, [[
local consumer = require "headers.consumer"
io.write(consumer.run())
]])
        assert.truthy(ran, result)
        assert.equal("6", result)
    end)

    it("checks consumer macros in the emitted source-header environment",
       function()
        write_file(source_root .. "/macro/provider.h", [[
#define TITAN_SOURCE_COLLISION 2
typedef int ffi_int;
]])
        write_file(source_root .. "/macro/consumer.h", [[
#define TITAN_SOURCE_COLLISION 1
typedef int consumer_int;
]])
        write_file(source_root .. "/macro/provider.titan", [[
foreign import "provider.h"
foreign function identity(input: ffi_int): ffi_int return input end
]])
        write_file(source_root .. "/macro/consumer.titan", [[
foreign import "consumer.h"
local provider = import "macro.provider.titan"
function collision(): integer return ffi.TITAN_SOURCE_COLLISION end
]])

        local ok, output = compile(workspace, source_root, "macro.consumer")
        assert.truthy(ok, output)
        local environment = read_file(source_root .. "/macro/consumer.ffi.h")
        local dependency = assert(environment:find(
            '/macro/provider.ffi.h"', 1, true))
        local direct = assert(environment:find(
            '/macro/consumer.h"', dependency, true))
        assert.is_true(dependency < direct)
        local ran, result = run_lua(workspace, [[
local consumer = require "macro.consumer"
io.write(consumer.collision())
]])
        assert.truthy(ran, result)
        assert.equal("1", result)
    end)

    it("removes stale owned foreign headers and preserves reserved user files",
       function()
        write_file(source_root .. "/stale/types.h", "typedef int ffi_int;\n")
        write_file(source_root .. "/stale/item.titan", [[
foreign import "types.h"
foreign function identity(input: ffi_int): ffi_int
    return input
end
function answer(): integer return identity(7 as foreign ffi_int) as integer end
]])
        local ok, output = compile(workspace, source_root, "stale.item")
        assert.truthy(ok, output)
        local header = source_root .. "/stale/item.titan.h"
        assert.equal("file", lfs.attributes(header, "mode"))

        write_file(source_root .. "/stale/item.titan",
            "function answer(): integer return 8 end\n")
        ok, output = compile(workspace, source_root, "stale.item")
        assert.truthy(ok, output)
        assert.is_nil(lfs.attributes(header, "mode"))

        write_file(source_root .. "/reserved/types.h", "typedef int ffi_int;\n")
        write_file(source_root .. "/reserved/item.titan", [[
foreign import "types.h"
foreign function identity(input: ffi_int): ffi_int return input end
]])
        local reserved = source_root .. "/reserved/item.titan.h"
        write_file(reserved, "/* user-owned */\n")
        ok, output = compile(workspace, source_root, "reserved.item")
        assert.falsy(ok)
        assert.truthy(output:find(
            "refusing to overwrite user-owned generated-header path", 1,
            true), output)
        assert.equal("/* user-owned */\n", read_file(reserved))
        assert.is_nil(lfs.attributes(
            source_root .. "/reserved/item.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/reserved/item.o", "mode"))
    end)

    it("keeps source-private symbols injective across module boundaries",
       function()
        write_file(source_root .. "/private/root.titan", [[
local function child_leaf(): integer return 1 end
function expose(): integer return child_leaf() end
]])
        write_file(source_root .. "/private/root/child.titan", [[
local function leaf(): integer return 2 end
function expose(): integer return leaf() end
]])

        local ok, output = compile(workspace, source_root,
            "private.root", "private.root.child")
        assert.truthy(ok, output)
        local ran, result = run_lua(workspace, [[
local root = require "private.root"
local child = require "private.root.child"
io.write(root.expose(), " ", child.expose())
]])
        assert.truthy(ran, result)
        assert.equal("1 2", result)
    end)

    it("keeps module/member boundary symbols injective", function()
        write_file(source_root .. "/boundary/root.titan", [[
function child_leaf(): integer return 1 end
]])
        write_file(source_root .. "/boundary/root/child.titan",
            "function leaf(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root,
            "boundary.root", "boundary.root.child")
        assert.truthy(ok, output)
        local ran, result = run_lua(workspace, [[
local root = require "boundary.root"
local child = require "boundary.root.child"
io.write(root.child_leaf(), " ", child.leaf())
]])
        assert.truthy(ran, result)
        assert.equal("1 2", result)
    end)

    it("preflights symbols from producer-dynamic contextual owners",
       function()
        write_file(source_root .. "/a.titan", [[
record R
    n: integer
end

function b_c(): integer
    return 1
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "a")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_file(source_root .. "/facade/api.titan", [[
local owner = import "a"
type R = owner.R
]])
        ok, output, why, code =
            compile(workspace, source_root, "facade.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_file(source_root .. "/a_b.titan",
            "function c(): integer return 2 end\n")
        write_file(source_root .. "/app.titan", [[
local facade = import "facade.api"
local peer = import "a_b"

function main(args: {string}): integer
    if peer.c() == 2 then return 0 else return 1 end
end
]])
        local arguments = platform.windows and { "app", "a_b" } or { "--static", "app", "a_b" }
        ok, output, why, code = compile(workspace, source_root, table.unpack(arguments))
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local ran, result = run_program(workspace, "app")
        assert.truthy(ran, result)
    end)

    it("keeps module/nominal boundary symbols injective", function()
        write_file(source_root .. "/record_boundary/root.titan", [[
record child_Thing
    n: integer
end

function child_Thing.make(n: integer): child_Thing
    return child_Thing.new(n)
end

function child_Thing:run(): integer
    return self.n + 1
end

function exercise(): integer
    local item = child_Thing.make(10)
    local bound = item:run
    return item:run() + bound()
end
]])
        write_file(source_root .. "/record_boundary/root/child.titan", [[
record Thing
    n: integer
end

function Thing.make(n: integer): Thing
    return Thing.new(n)
end

function Thing:run(): integer
    return self.n + 2
end

function exercise(): integer
    local item = Thing.make(20)
    local bound = item:run
    return item:run() + bound()
end
]])

        local ok, output = compile(workspace, source_root,
            "record_boundary.root", "record_boundary.root.child")
        assert.truthy(ok, output)
        local root_c = read_file(source_root .. "/record_boundary/root.c")
        local child_c =
            read_file(source_root .. "/record_boundary/root/child.c")
        for source, owner in pairs({
            [root_c] = "child_Thing",
            [child_c] = "Thing",
        }) do
            local stem = "record_boundary_root"
            if owner == "Thing" then stem = stem .. "_child" end
            stem = stem .. "_\\u2133_" .. owner .. "_\\u2131_"
            for _, suffix in ipairs({
                "new_titanstatic", "make_titanstatic", "run_titanmethod",
                "run_boundmethod", "run_titanentry_boundlua",
                "run_titanentry_boundstrict",
            }) do
                assert.truthy(source:find(stem .. suffix, 1, true), suffix)
            end
        end
        local ran, result = run_lua(workspace, [[
local root = require "record_boundary.root"
local child = require "record_boundary.root.child"
io.write(root.exercise(), " ", child.exercise(), " ",
    root.child_Thing.make(30):run(), " ", child.Thing.make(40):run())
]])
        assert.truthy(ran, result)
        assert.equal("22 44 31 42", result)
    end)

    it("keeps Interface nominal boundary symbols injective", function()
        write_file(source_root .. "/interface_boundary/root.titan", [[
interface child_Stream
    function read(): integer
end
]])
        write_file(source_root .. "/interface_boundary/root/child.titan", [[
interface Stream
    function read(): integer
end
]])

        local ok, output = compile(workspace, source_root,
            "interface_boundary.root", "interface_boundary.root.child")
        assert.truthy(ok, output)
        local root_c = read_file(source_root .. "/interface_boundary/root.c")
        local child_c =
            read_file(source_root .. "/interface_boundary/root/child.c")
        for source, stem in pairs({
            [root_c] = "interface_boundary_root_\\u2133_child_Stream_\\u2131_read_",
            [child_c] = "interface_boundary_root_child_\\u2133_Stream_\\u2131_read_",
        }) do
            for _, role in ipairs({
                "interface_boundmethod", "titanentry_interface_boundlua",
                "titanentry_interface_boundstrict",
            }) do
                assert.truthy(source:find(stem .. role, 1, true), role)
            end
        end
    end)

    it("links a legacy ABI-2 archive without inventing an optional query export", function()
        if platform.windows then
            pending("Legacy Titan static archive protocol linking is unsupported on Windows")
            return
        end
        local legacy_workspace = workspace .. "/legacy-abi-value"
        local legacy_source = legacy_workspace .. "/source"
        local provider_stem = legacy_source .. "/luaopen/bundle/foo"
        write_file(provider_stem .. ".titan",
            "function probe(): integer return 2 end\n")
        local ok, output = compile(
            legacy_workspace, legacy_source, "-v", "luaopen.bundle.foo")
        assert.truthy(ok, output)

        -- Retain the generated ABI-2 protocols and metadata, removing only
        -- the optional query and its source-owned resolver entry.
        local source = read_file(provider_stem .. ".c")
        local count
        source, count = source:gsub(
            "const char %*luaopen_bundle_foo_abi_value%(void%) {%s*" ..
            "return TITAN_ABI_VERSION;%s*}", "")
        assert.equal(1, count)
        source, count = source:gsub(
            "[^\n]*if %(strcmp%(symbol, \"luaopen_bundle_foo_abi_value\"%) " ..
            "== 0%) return [^\n]*;\n", "")
        assert.equal(1, count)
        assert.is_nil(source:find("luaopen_bundle_foo_abi_value", 1, true))
        write_file(provider_stem .. ".c", source)

        local object = legacy_workspace .. "/legacy-provider.o"
        local compile_argv
        for line in output:gmatch("[^\r\n]+") do
            local argv = cdriver.split_shell_words(line)
            if argv then
                local has_source, compiles = false, false
                for _, argument in ipairs(argv) do
                    if argument == provider_stem .. ".c" then has_source = true end
                    if argument == "-c" then compiles = true end
                end
                if has_source and compiles then compile_argv = argv end
            end
        end
        assert.truthy(compile_argv, "missing generated object compile command")
        for index, argument in ipairs(compile_argv) do
            if argument == "-o" then compile_argv[index + 1] = object end
        end
        ok, output = run(compile_argv, legacy_workspace)
        assert.truthy(ok, output)
        local symbols = native_symbols(legacy_workspace, object)
        assert.is_nil(symbols:find("luaopen_bundle_foo_abi_value", 1, true))

        local archive = legacy_workspace .. "/luaopen/bundle/foo.a"
        assert.truthy(os.remove(archive))
        make_archive(legacy_workspace, "luaopen/bundle/foo.a", { object })
        local parsed, parse_error = staticmetadata.scan_archive(archive, metadata_options())
        assert.truthy(parsed, parse_error)
        assert.equal("2", parsed.entries["luaopen.bundle.foo"].abi)
        assert.truthy(os.remove(provider_stem .. ".titan"))
        assert.truthy(os.remove(shared_path(legacy_workspace, "luaopen/bundle/foo")))
        assert.truthy(os.remove(legacy_workspace .. "/luaopen/bundle/foo.lua"))

        write_file(legacy_source .. "/bundle/foo_abi_value.titan", [[
local old = import "luaopen.bundle.foo"
function probe(): integer return old.probe() + 40 end
]])
        ok, output = compile(
            legacy_workspace, legacy_source, "--static", "bundle.foo_abi_value")
        assert.truthy(ok, output)
        local ran, result = run_lua(legacy_workspace, [[
local current = require "bundle.foo_abi_value"
local old = require "luaopen.bundle.foo"
io.write(current.probe(), " ", old.probe())
]])
        assert.truthy(ran, result)
        assert.equal("42 2", result)
    end)

    for _, protocol in ipairs({
        { suffix = "abi", owner = "module ABI entry" },
        { suffix = "abi_value", owner = "module ABI value entry" },
    }) do
        it("preflights cross-family protocol symbols from source dependencies (" ..
           protocol.suffix .. ")", function()
            write_file(source_root .. "/bundle/foo_" .. protocol.suffix .. ".titan",
                "function probe(): integer return 1 end\n")
            write_file(source_root .. "/bundle/left.titan", [[
local other = import "luaopen.bundle.foo"
function probe(): integer return other.probe() end
]])
            write_file(source_root .. "/luaopen/bundle/foo.titan",
                "function probe(): integer return 2 end\n")

            local ok, output = compile(workspace, source_root,
                "bundle.left", "bundle.foo_" .. protocol.suffix)
            assert.falsy(ok)
            assert.truthy(output:find(
                "cannot link C symbol 'luaopen_bundle_foo_" .. protocol.suffix .. "'",
                1, true), output)
            assert.truthy(output:find("module Lua entry", 1, true), output)
            assert.truthy(output:find(protocol.owner, 1, true), output)
            assert.is_nil(lfs.attributes(source_root .. "/bundle/left.c", "mode"))
            assert.is_nil(lfs.attributes(
                source_root .. "/luaopen/bundle/foo.c", "mode"))
            assert.is_nil(lfs.attributes(shared_path(workspace, "bundle"), "mode"))
            assert.is_nil(lfs.attributes(workspace .. "/bundle.a", "mode"))
        end)
    end

    it("refuses an unrecognized Lua shim before changing C output", function()
        write_file(source_root .. "/owned/item.titan",
            "function probe(): integer return 1 end\n")
        write_file(workspace .. "/owned/item.lua", "return 'user file'\n")

        local ok, output = compile(workspace, source_root, "owned.item")
        assert.falsy(ok)
        assert.truthy(output:find(
            "refusing to overwrite unrecognized Lua file 'owned/item.lua'",
            1, true), output)
        assert.equal("return 'user file'\n",
            read_file(workspace .. "/owned/item.lua"))
        assert.is_nil(lfs.attributes(source_root .. "/owned/item.c", "mode"))
        assert.is_nil(lfs.attributes(shared_path(workspace, "owned/item"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/owned/item.a", "mode"))
    end)

    it("requires semantic native support in a physical titan provider", function()
        write_file(source_root .. "/titan/one.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "titan.one", "titan.two")
        assert.falsy(ok)
        assert.truthy(output:find(
            "linked provider 'titan' has an invalid native support entry", 1,
            true), output)
        assert.is_nil(lfs.attributes(shared_path(workspace, "titan"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan.a", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/one.lua", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/two.lua", "mode"))
    end)

    it("accepts the reviewed native support object and leaves bare support inert",
       function()
        write_file(source_root .. "/titan/one.titan", [[
local initialized: integer = 0
function probe(): integer return initialized end
do initialized = initialized + 1 end
]])
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")
        write_file(workspace .. "/registry-probe.c", [[
#include "lua.h"
#include "lauxlib.h"
#ifdef _WIN32
__declspec(dllexport)
#endif
int luaopen_probe_registry(lua_State *L) {
    int present;
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module titan.one");
    present = !lua_isnil(L, -1);
    lua_pop(L, 1);
    lua_pushboolean(L, present);
    return 1;
}
]])
        local compiler = {
            "env", "CCACHE_DISABLE=1",
        }
        for _, word in ipairs(configured_words(driver.CC)) do
            compiler[#compiler + 1] = word
        end
        for _, word in ipairs({
            "-std=c99", "-fPIC", "-I", LUA_INCLUDE,
            "-c", "registry-probe.c", "-o", "registry-probe.o",
        }) do
            compiler[#compiler + 1] = word
        end
        local compiled, compile_output = run(compiler, workspace)
        assert.truthy(compiled, compile_output)

        local ok, output, why, code = compile(
            workspace, source_root, "titan.one", "titan.two",
            "-X", native_support_object(workspace),
            workspace .. "/registry-probe.o")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "titan", {
            "titan.one", "titan.two",
        })

        ok, output = run_lua(workspace, string.format([[
local support = require "titan"
assert(type(support._loadlib) == "function")
assert(type(support._loadlibglobal) == "function")
local registry_probe = assert(package.loadlib(
    %q, "luaopen_probe_registry"))
assert(registry_probe() == false)
local one = require "titan.one"
local two = require "titan.two"
assert(registry_probe() == true)
assert(one.probe() == 1)
assert(two.probe() == 2)
]], "./titan" .. SHARED_SUFFIX))
        assert.truthy(ok, output)

        -- The semantic gate owns a fresh controlled Lua process. A parent
        -- compiler may itself have used -E; an inherited LUA_INIT must not be
        -- able to alter package.loadlib or forge the gate's result file.
        write_file(workspace .. "/hostile-init.lua",
            [[error("LUA_INIT reached Titan support validation", 0)]])
        write_file(workspace .. "/validate-support.lua", string.format([[
package.path = %q .. package.path
package.cpath = %q .. package.cpath
local driver = require "titan-compiler.driver"
local valid, validation_error = driver.validate_titan_support(arg[1])
assert(valid, validation_error)
]], REPO .. "/?.lua;" .. REPO .. "/?/init.lua;",
            REPO .. "/?" .. SHARED_SUFFIX .. ";"))
        local validate_argv = {
            "env", "LUA_INIT=@" .. workspace .. "/hostile-init.lua",
        }
        if PREFIX then
            validate_argv[#validate_argv + 1] =
                "TITAN_ROCKS_ROOT=" .. PREFIX
        end
        validate_argv[#validate_argv + 1] = LUA
        validate_argv[#validate_argv + 1] = "-E"
        validate_argv[#validate_argv + 1] =
            workspace .. "/validate-support.lua"
        validate_argv[#validate_argv + 1] = shared_path(workspace, "titan")
        ok, output = run(validate_argv, workspace)
        assert.truthy(ok, output)

        -- Windows has no Titan static-provider archive; the shared support
        -- and fresh-process validation above remain required there.
        if platform.windows then return end

        -- A shallow titan.a selected by a standalone owns the bare native
        -- support entry as well as logical titan.* protocols. Rebuild it from
        -- only the logical module objects to prove the executable gate catches
        -- a missing luaopen_titan before publishing the program.
        local no_support = make_archive(
            workspace, "titan-without-support.a", {
                source_root .. "/titan/one.o",
                source_root .. "/titan/two.o",
            })
        copy_file(no_support, workspace .. "/titan.a")
        write_file(source_root .. "/support_app.titan", [[
local one = import "titan.one"
function main(args: {string}): integer return one.probe() end
]])
        ok, output = compile(
            workspace, source_root, "--static", "support_app")
        assert.falsy(ok)
        assert.truthy(output:find(
            "selected static provider failed executable-context protocol linking",
            1, true), output)
        assert.is_nil(lfs.attributes(workspace .. "/support_app", "mode"))
    end)
end)

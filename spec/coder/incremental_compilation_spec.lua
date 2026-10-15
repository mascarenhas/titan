local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"

local NAMESPACE = "incremental_cli_fixture"
local APP = "incremental_cli_app"
local OTHER = "incremental_cli_other"
local ROOTS = { NAMESPACE, APP, OTHER }
local REPOSITORY = assert(lfs.currentdir())
if platform.windows then REPOSITORY = assert(platform.path.normalize(REPOSITORY)) end
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local workspace

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function read(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert(file:close())
    return contents
end

local function mkdir(path)
    if exists(path) then return end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdir(parent) end
    assert(lfs.mkdir(path))
end

local function write(path, contents)
    mkdir(path:match("^(.*)/[^/]+$") or ".")
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
end

local function remove(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function command(argv)
    local quoted = {}
    for index, value in ipairs(argv) do quoted[index] = assert(cdriver.shell_quote(value)) end
    return table.concat(quoted, " ")
end

local function run(argv)
    argv = { table.unpack(argv) }
    if platform.windows and argv[1] == "env" then argv[1] = "env.exe" end
    local result = compiler_io.new_sync():run(argv)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.started and result.ok, output, result.why, result.status
end

local prefix = require("spec.support.installed_prefix").active()
local LUA = prefix .. "/bin/lua" .. (platform.windows and ".exe" or "")

local function program_path(name)
    if not platform.windows then return "./" .. name end
    return assert(driver.windows_program_paths((name:gsub("/", ".")))).executable
end

local function run_program(name, ...)
    local argv = { "env", "TITAN_PATH_0_6=" ..
        (platform.windows and "./lib/titan/0.6;" or "") ..
        ".;" .. prefix .. "/lib/titan/0.6",
        "PATH=" .. prefix .. "/bin" .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or ""), program_path(name) }
    if platform.windows then
        table.insert(argv, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6")
    end
    for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
    return run(argv)
end

local function compiler_arguments()
    -- Match the existing CLI specs: exercise this checkout's CLI and compiler
    -- while keeping the selected installation's Lua/native SDK.
    return {
        "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
        "TITAN_ROCKS_ROOT=" .. assert(prefix, "incremental CLI specs require an installed SDK"),
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto", "TITAN_EXTRA_LDFLAGS=-fno-lto",
        LUA, "-E", "-e",
        string.format("package.path = %q .. package.path; package.cpath = %q .. package.cpath",
            REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
            REPOSITORY .. "/titan-runtime/bootstrap/?" .. SHARED_SUFFIX .. ";"),
        REPOSITORY .. "/titanc", "--tree", workspace,
    }
end

local function compile(...)
    local argv = compiler_arguments()
    for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
    return run(argv)
end

local function compiled(...)
    local ok, output = compile(...)
    assert.is_true(ok, output)
    return output
end

local function source(name, contents, folder)
    local stem = workspace .. "/" .. name:gsub("[.]", "/")
    if folder then stem = stem .. "/" .. name:match("[^.]+$") end
    write(stem .. ".titan", contents)
    return stem
end

local function exit_code(name, expected)
    local ok, output, why, code = run_program(name)
    assert.equal("exit", why, output)
    assert.equal(expected, code, output)
    assert.equal(expected == 0, ok, output)
end

local function main(value)
    return "function main(args: {string}): integer\nreturn " .. value .. "\nend\n"
end

describe("incremental and separate compilation (CLI)", function()
    before_each(function()
        workspace = assert(compiler_io.new_sync():tmpname())
        assert(os.remove(workspace))
        if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
        mkdir(workspace)
    end)

    after_each(function()
        remove(workspace)
        for _, root in ipairs(ROOTS) do
            for _, suffix in ipairs({ "", ".so", ".so.dSYM", ".a", ".lua", ".dSYM",
                "__entrypoint.c", "__entrypoint.o", "__main", "__main.dSYM" }) do
                remove(root .. suffix)
            end
            if platform.windows then
                remove(root .. ".dll")
                remove(root .. ".dll.def")
                local paths = assert(driver.windows_program_paths(root))
                remove(paths.executable)
                remove(paths.provider)
                remove(paths.provider .. ".def")
                for _, suffix in ipairs({ ".c", ".o", ".manifest", ".rc", ".res" }) do
                    remove(root .. "__entrypoint" .. suffix)
                end
            end
        end
    end)

    it("writes the complete source hierarchy and executable into a new output folder", function()
        local folder = NAMESPACE .. ".folder"
        local folder_source = source(folder, [[
            foreign import "native.h"
            foreign type Count = int
            foreign function bump(item: Count): Count return item + ffi.OFFSET end
        ]], true)
        write(folder_source:match("^(.*)/[^/]+$") .. "/native.h", "#define OFFSET 7\n")
        write(folder_source:match("^(.*)/[^/]+$") .. "/private.titan", [[
            local function answer(): integer return 35 end
        ]])
        local app_source = source(APP, 'local folder = import "' .. folder .. [[.titan"
            function main(args: {string}): integer
                local callback: foreign function(Count): Count = folder.bump
                return callback(folder.answer() as foreign Count) as integer
            end
        ]])
        local output = workspace .. "/build files/nested/output"
        compiled("--output", output, APP)
        local folder_output = output .. "/" .. NAMESPACE .. "/folder/folder"
        for _, stem in ipairs({ output .. "/" .. APP, folder_output }) do
            for _, suffix in ipairs({ ".c", ".o", ".ffi.h" }) do
                assert.is_true(exists(stem .. suffix), stem .. suffix)
            end
        end
        assert.is_true(exists(folder_output .. ".titan.h"))
        for _, stem in ipairs({ app_source, folder_source }) do
            for _, suffix in ipairs({ ".c", ".o", ".ffi.h", ".titan.h" }) do
                assert.is_false(exists(stem .. suffix), stem .. suffix)
            end
        end
        local executable = platform.windows and
            assert(driver.windows_program_paths(APP, nil, nil, output)).executable or output .. "/" .. APP
        local command = { "env", "TITAN_PATH_0_6=" .. prefix .. "/lib/titan/0.6;;", executable }
        if platform.windows then table.insert(command, 2, "MSYS2_ENV_CONV_EXCL=TITAN_PATH_0_6") end
        local ok, text, why, code = run(command)
        assert.equal("exit", why, text)
        assert.equal(42, code, text)
        assert.is_false(ok)
        assert.is_true(exists(output .. "/" .. APP .. "__entrypoint.c"))
        assert.is_false(exists(APP .. "__entrypoint.c"))
    end)

    it("puts library providers and Lua shims beside the redirected module hierarchy", function()
        local flat, folder = NAMESPACE .. ".flat", NAMESPACE .. ".folder"
        local first = source(flat, "function answer(): integer return 21 end\n")
        local second = source(folder, "function answer(): integer return 22 end\n", true)
        local output = workspace .. "/provider output"
        compiled("-o", output, flat, folder)
        assert.is_true(exists(output .. "/" .. NAMESPACE .. SHARED_SUFFIX))
        if not platform.windows then assert.is_true(exists(output .. "/" .. NAMESPACE .. ".a")) end
        for _, name in ipairs({ flat, folder }) do
            assert.is_true(exists(output .. "/" .. name:gsub("[.]", "/") .. ".lua"))
        end
        for _, stem in ipairs({ first, second }) do
            assert.is_false(exists(stem .. ".c"))
            assert.is_false(exists(stem .. ".o"))
            assert.is_false(exists(stem .. ".ffi.h"))
        end
        local ok, text = run({ LUA, "-E", "-e", string.format(
            "package.path = %q .. package.path; package.cpath = %q .. package.cpath; " ..
            "assert(require(%q).answer() == 21); assert(require(%q).answer() == 22)",
            output .. "/?.lua;", output .. "/?" .. SHARED_SUFFIX .. ";", flat, folder) })
        assert.is_true(ok, text)
    end)

    it("reuses only relocated objects and restores their foreign headers", function()
        local base = NAMESPACE .. ".base"
        local original = source(base, [[
            foreign type Count = int
            foreign function bump(item: Count): Count return item + 7 end
        ]])
        source(APP, 'local base = import "' .. base .. [[.titan"
            function main(args: {string}): integer
                local callback: foreign function(Count): Count = base.bump
                return callback(35 as foreign Count) as integer
            end
        ]])
        local output = workspace .. "/incremental output"
        compiled("-o", output, "-c", base)
        local relocated = output .. "/" .. base:gsub("[.]", "/")
        local object = read(relocated .. ".o")
        local future = os.time() + 120
        assert(lfs.touch(relocated .. ".o", future))
        assert(os.remove(relocated .. ".ffi.h"))
        assert(os.remove(relocated .. ".titan.h"))
        write(original .. ".o", "unrelated source-adjacent object")
        assert(lfs.touch(original .. ".o", future + 120))
        compiled("-o", output, "-c", "--incremental", APP)
        assert.equal(object, read(relocated .. ".o"))
        assert.equal(future, lfs.attributes(relocated .. ".o", "modification"))
        assert.is_true(exists(relocated .. ".ffi.h"))
        assert.is_true(exists(relocated .. ".titan.h"))
        assert.equal("unrelated source-adjacent object", read(original .. ".o"))
    end)

    it("rejects an output path that is a file before checking modules", function()
        local output = workspace .. "/reserved"
        write(output, "user-owned\n")
        local ok, text = compile("-o", output, APP)
        assert.is_false(ok)
        assert.matches("not a directory", text, 1, true)
        assert.equal("user-owned\n", read(output))
    end)

    it("compiles unrelated main roots without selecting an executable or provider", function()
        local first = source(APP, main(3))
        local second = source(OTHER, main(4))
        compiled("--compile-only", APP, OTHER)
        for _, stem in ipairs({ first, second }) do
            assert.is_true(exists(stem .. ".o"))
            assert.is_true(exists(stem .. ".ffi.h"))
        end
        for _, name in ipairs({ APP, OTHER }) do
            assert.is_false(exists(name))
            assert.is_false(exists(name .. SHARED_SUFFIX))
            assert.is_false(exists(name .. ".a"))
            assert.is_false(exists(name .. ".lua"))
            assert.is_false(exists(name .. "__entrypoint.c"))
        end
        local ok, output = compile("--incremental", APP, OTHER)
        assert.is_false(ok)
        assert.matches("multiple main functions", output, 1, true)
    end)

    it("rejects incompatible options before looking for source", function()
        local cases = {
            { { "--incremental", "--print-ast", APP }, "--incremental cannot be combined" },
            { { "-c", "-l", "m", APP }, "--compile-only cannot be combined" },
            { { "-c", APP, "-X", "payload.o" }, "--compile-only cannot be combined" },
            { { "-c", "--no-uv-bootstrap", APP }, "--compile-only cannot be combined" },
        }
        for _, case in ipairs(cases) do
            local ok, output = compile(table.unpack(case[1]))
            assert.is_false(ok, command(case[1]))
            assert.matches(case[2], output, 1, true)
        end
    end)

    it("ignores newer objects by default and in compile-only mode", function()
        local stem = source(APP, main(3))
        compiled("-c", APP)
        write(stem .. ".titan", main(7))
        assert(lfs.touch(stem .. ".titan", os.time() - 60))
        compiled(APP)
        exit_code(APP, 7)

        write(stem .. ".titan", main(11))
        assert(lfs.touch(stem .. ".titan", os.time() - 60))
        compiled("-c", APP)
        compiled("--incremental", APP)
        exit_code(APP, 11)
    end)

    it("forces all explicit roots even when reached through an earlier root", function()
        local base = NAMESPACE .. ".base"
        local base_stem = source(base, [[
            local function answer(): integer return 13 end
        ]])
        source(APP, 'local base = import "' .. base .. [[.titan"
            function main(args: {string}): integer return base.answer() end
        ]])
        compiled("-c", "--incremental", base, APP)
        write(base_stem .. ".titan", [[
            local function answer(): integer return 17 end
        ]])
        assert(lfs.touch(base_stem .. ".titan", os.time() - 60))
        compiled("-c", "--incremental", APP, base)
        compiled("--incremental", APP)
        exit_code(APP, 17)
    end)

    it("reuses dependency objects while rebuilding the explicit root", function()
        local base = NAMESPACE .. ".base"
        local base_stem = source(base, [[function answer(): integer return 19 end]])
        local app_stem = source(APP, 'local base = import "' .. base .. [[.titan"
            function main(args: {string}): integer return base.answer() end
        ]])
        compiled("-c", base, APP)
        local future = os.time() + 60
        assert(lfs.touch(base_stem .. ".o", future))
        assert(lfs.touch(app_stem .. ".o", future))
        local contents = read(base_stem .. ".o")
        compiled("-c", "--incremental", APP)
        assert.equal(future, lfs.attributes(base_stem .. ".o", "modification"))
        assert.equal(contents, read(base_stem .. ".o"))
        assert.is_true(lfs.attributes(app_stem .. ".o", "modification") < future)
        compiled("--incremental", APP)
        exit_code(APP, 19)
    end)

    it("restores folder foreign headers and private declarations for a new consumer", function()
        local folder = NAMESPACE .. ".folder"
        local stem = source(folder, [[
            foreign type Count = int
            foreign function bump(item: Count): Count return item + 7 end
        ]], true)
        write(stem:match("^(.*)/[^/]+$") .. "/private.titan", [[
            local record Secret
                count: integer
            end
            local function count(item: Secret): integer return item.count end
        ]])
        compiled("-c", "--incremental", folder)
        local object = read(stem .. ".o")
        assert(os.remove(stem .. ".ffi.h"))
        assert(os.remove(stem .. ".titan.h"))
        source(APP, 'local folder = import "' .. folder .. [[.titan"
            function main(args: {string}): integer
                local item = folder.Secret.new(35)
                local callback: foreign function(Count): Count = folder.bump
                return callback(folder.count(item) as foreign Count) as integer
            end
        ]])
        compiled("-c", "--incremental", APP)
        assert.equal(object, read(stem .. ".o"))
        assert.is_true(exists(stem .. ".ffi.h"))
        assert.is_true(exists(stem .. ".titan.h"))
        compiled("--incremental", APP)
        exit_code(APP, 42)
    end)

    it("rejects changed cached native bindings until Make recompiles the root", function()
        local base = NAMESPACE .. ".base"
        source(base, [[function answer(): integer return 23 end]])
        compiled(base)
        source(base, [[function answer(): integer return 29 end]])
        compiled("-c", "--incremental", "--source-first", base)
        source(APP, 'local base = import "' .. base .. [["
            function main(args: {string}): integer return base.answer() end
        ]])
        compiled("-c", "--incremental", "--source-first", APP)
        compiled("--incremental", "--source-first", APP)
        exit_code(APP, 29)
        local ok, output = compile("--incremental", APP)
        assert.is_false(ok)
        assert.matches("requires direct binding", output, 1, true)
        assert.matches("rebuild it with the selected dependency providers", output, 1, true)
        compiled("-c", "--incremental", APP)
        compiled("--incremental", APP)
        exit_code(APP, 23)
        ok, output = compile("--incremental", "--source-first", APP)
        assert.is_false(ok)
        assert.matches("requires handle binding", output, 1, true)
        compiled("-c", "--incremental", "--source-first", APP)
        compiled("--incremental", "--source-first", APP)
        exit_code(APP, 29)
    end)

    it("discards failed native output before a successful retry and warm link", function()
        local stem = source(APP, main(31))
        compiled("-c", APP)
        local wrapper = workspace .. "/failing-cc.sh"
        local real_cc = assert(cdriver.split_shell_words(os.getenv("CC") or
            (platform.windows and "clang.exe" or "cc")))
        local wrapper_command
        if platform.windows then
            wrapper = workspace .. "/failing-cc.lua"
            local quoted_cc = {}
            for _, value in ipairs(real_cc) do quoted_cc[#quoted_cc + 1] = string.format("%q", value) end
            write(wrapper, string.format([[
package.path = %q .. package.path
local arguments = { %s }
local output, selected
for index, value in ipairs(arg) do
    if arg[index - 1] == "-o" then output = value end
    if value == %q then selected = true end
    arguments[#arguments + 1] = value
end
if selected then
    local file = assert(io.open(assert(output), "wb"))
    assert(file:write("partial native object\n"))
    assert(file:close())
    io.stderr:write("intentional module compiler failure\n")
    os.exit(1)
end
local result = require("titan-compiler.io").new_sync():run(arguments)
io.stdout:write(result.output or result.diagnostic or "")
os.exit(result.ok and 0 or result.status or 1)
]], REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
                table.concat(quoted_cc, ", "), stem .. ".c"))
            wrapper_command = command({ LUA, wrapper })
        else
            write(wrapper, table.concat({
            "#!/bin/sh",
            "fixture_output=",
            "fixture_previous=",
            "fixture_module=no",
            "for fixture_argument do",
            '    if [ "$fixture_previous" = -o ]; then fixture_output=$fixture_argument; fi',
            '    if [ "$fixture_argument" = ' .. assert(cdriver.shell_quote(stem .. ".c")) ..
                ' ]; then fixture_module=yes; fi',
            "    fixture_previous=$fixture_argument",
            "done",
            'if [ "$fixture_module" = yes ]; then',
            '    printf "partial native object\\n" > "$fixture_output"',
            '    printf "intentional module compiler failure\\n" >&2',
            "    exit 1",
            "fi",
            "exec " .. command(real_cc) .. ' "$@"',
            "",
        }, "\n"))
            wrapper_command = command({ "sh", wrapper })
        end
        local argv = compiler_arguments()
        table.insert(argv, 2, "CC=" .. wrapper_command)
        argv[#argv + 1], argv[#argv + 2], argv[#argv + 3] = "-c", "--incremental", APP
        local ok, output = run(argv)
        assert.is_false(ok)
        assert.matches("intentional module compiler failure", output, 1, true)
        assert.is_false(exists(stem .. ".o"))
        compiled("-c", "--incremental", APP)
        local object = read(stem .. ".o")
        local future = os.time() + 60
        assert(lfs.touch(stem .. ".o", future))
        compiled("--incremental", APP)
        assert.equal(future, lfs.attributes(stem .. ".o", "modification"))
        assert.equal(object, read(stem .. ".o"))
        exit_code(APP, 31)
    end)

    it("keeps unchanged dynamic owner and facade imports valid on a warm link", function()
        local owner = NAMESPACE .. ".owner"
        local facade = NAMESPACE .. ".facade"
        source(owner, [[record Item value: integer end]])
        source(facade, 'local owner = import "' .. owner .. [["
            type Item = owner.Item
            function make(): Item return owner.Item.new(5) end
        ]])
        compiled(owner, facade)
        local stem = source(APP, 'local owner = import "' .. owner .. '"\n' ..
            'local facade = import "' .. facade .. [["
            function main(args: {string}): integer
                return facade.make().value + owner.Item.new(6).value
            end
        ]])
        compiled("--incremental", APP)
        local future = os.time() + 60
        assert(lfs.touch(stem .. ".o", future))
        compiled("--incremental", APP)
        assert.equal(future, lfs.attributes(stem .. ".o", "modification"))
        exit_code(APP, 11)
    end)

    it("links separately built app objects with the stdlib and another library", function()
        if platform.windows then
            pending("Titan static-provider linking is unsupported on Windows")
            return
        end
        local library = NAMESPACE .. ".library"
        local helper = APP .. ".helper"
        local application = APP .. ".main"
        source(library, [[function number(): integer return 30 end]])
        compiled(library)
        local helper_stem = source(helper, [[
            local math = import "math"
            function number(): integer return math.sqrt(81.0) as integer end
        ]])
        local header = workspace .. "/payload.h"
        local payload = workspace .. "/payload.o"
        write(header, "int incremental_cli_payload(void);\n")
        write(workspace .. "/payload.c", "int incremental_cli_payload(void) { return 3; }\n")
        local native_argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
        for _, value in ipairs({ "-fPIC", "-c", workspace .. "/payload.c", "-o", payload }) do
            native_argv[#native_argv + 1] = value
        end
        local native_ok, native_output = run(native_argv)
        assert.is_true(native_ok, native_output)
        local app_stem = source(application,
            'local helper = import "' .. helper .. '.titan"\n' ..
            'local library = import "' .. library .. '"\n' ..
            'foreign import "' .. header .. [["
            function main(args: {string}): integer
                return helper.number() + library.number() + (ffi.incremental_cli_payload() as integer)
            end
        ]])
        compiled("-c", "--incremental", "--static", helper)
        compiled("-c", "--incremental", "--static", application)
        assert.is_false(exists(APP .. "/main"))
        assert.is_false(exists(APP .. "/main__entrypoint.c"))
        local future = os.time() + 60
        local saved = {}
        for _, stem in ipairs({ helper_stem, app_stem }) do
            for _, suffix in ipairs({ ".o", ".c", ".ffi.h" }) do
                local path = stem .. suffix
                saved[path] = read(path)
                assert(lfs.touch(path, future))
            end
        end
        local output = compiled("--incremental", "--static", "--verbose", "-l", "m",
            application, "-X", payload)
        assert.matches("Titan object hit " .. helper .. ":", output, 1, true)
        assert.matches("Titan object hit " .. application .. ":", output, 1, true)
        for path, contents in pairs(saved) do
            assert.equal(contents, read(path), path)
            assert.equal(future, lfs.attributes(path, "modification"), path)
        end
        exit_code(APP .. "/main", 42)
    end)

    it("reuses direct and indirect dynamic owners across separate test builds", function()
        -- These test programs live outside the selected installation's bin.
        local provider_path = "TITAN_PATH_0_6=.;" .. prefix .. "/lib/titan/0.6"
        local wrapper = NAMESPACE .. ".wrapper"
        local wrapper_stem = source(wrapper, [[
            local sqlite3 = import "sqlite3"
            record Access
                const connection: sqlite3.Connection
            end
            function open(): Access
                return Access.new(sqlite3.connect(":memory:"))
            end
        ]])
        local indirect_stem = source(APP, 'local wrapper = import "' .. wrapper .. [["
            local test = import "test"
            function test_indirect(context: test.Context)
                local access = wrapper.open()
                defer access.connection:close()
                test.assert(access.connection:get_autocommit())
            end
        ]])
        local direct_stem = source(OTHER, [[
            local sqlite3 = import "sqlite3"
            local test = import "test"
            function test_direct(context: test.Context)
                local connection = sqlite3.connect(":memory:")
                defer connection:close()
                test.assert(connection:get_autocommit())
            end
        ]])
        assert(lfs.chdir(workspace))
        local ok, result = xpcall(function()
            -- A fresh source build already supports the indirect method call.
            compiled("--test", APP)
            local ran, output = run_program(APP)
            assert.is_true(ran, output)
            assert.matches("[  PASSED  ] 1 test.", output, 1, true)

            compiled("-c", "--test", "--incremental", wrapper)
            compiled("-c", "--test", "--incremental", APP)
            output = compiled("--test", "--incremental", "-v", APP)
            assert.matches("Titan object hit " .. APP .. ":", output, 1, true)
            assert.matches("Titan object hit " .. wrapper .. ":", output, 1, true)
            ran, output = run_program(APP)
            assert.is_true(ran, output)
            assert.matches("[  PASSED  ] 1 test.", output, 1, true)

            compiled("-c", "--test", "--incremental", OTHER)
            local saved = {}
            for _, stem in ipairs({ wrapper_stem, indirect_stem, direct_stem }) do
                saved[stem .. ".o"] = read(stem .. ".o")
            end
            for _, roots in ipairs({ {APP, OTHER}, {OTHER, APP} }) do
                output = compiled("--test", "--incremental", "-v", table.unpack(roots))
                for _, name in ipairs({ APP, OTHER, wrapper }) do
                    assert.matches("Titan object hit " .. name .. ":", output, 1, true)
                end
                for filename, bytes in pairs(saved) do assert.equal(bytes, read(filename)) end
                ran, output = run_program(roots[1])
                assert.is_true(ran, output)
                assert.matches("[  PASSED  ] 2 tests.", output, 1, true)
                assert.matches(APP .. ".test_indirect", output, 1, true)
                assert.matches(OTHER .. ".test_direct", output, 1, true)
            end
        end, debug.traceback)
        assert(lfs.chdir(REPOSITORY))
        assert.is_true(ok, result)
    end)

    it("links separately compiled test owners with a compiled provider and cached discovery", function()
        local helper = NAMESPACE .. ".support"
        local helper_stem = source(helper, [[
            local test = import "test"
            function active(): boolean return test.testing() end
        ]])
        local first_stem = source(APP, 'local support = import "' .. helper .. [[.titan"
            local test = import "test"
            function test_first(context: test.Context)
                test.assert(support.active())
                test.assert(context:name() == "incremental_cli_app.test_first")
            end
            function main(args: {string}): integer return 1 end
        ]])
        local second_stem = source(OTHER, [[
            local test = import "test"
            function test_second(context: test.Context) test.assert(true) end
            function main(args: {string}): integer return 2 end
        ]])
        -- The real aggregate also gives all object recipes one build directory.
        assert(lfs.chdir(workspace))
        local ok, result = xpcall(function()
            local future = os.time() + 60
            compiled("-c", "--test", "--incremental", helper)
            local first_output = compiled("-c", "--test", "--incremental", "-v", APP)
            assert.matches("-fno-optimize-sibling-calls", first_output, 1, true)
            compiled("-c", "--test", "--incremental", OTHER)
            assert.is_false(exists(APP))
            assert.is_false(exists(APP .. "__test_runner.c"))
            assert.is_false(exists("titan/test__test_runner.c"))
            assert.is_false(exists(workspace .. "/titan/test__test_support.o"))
            local saved = {}
            for _, stem in ipairs({ first_stem, second_stem, helper_stem }) do
                for _, suffix in ipairs({ ".o", ".c", ".ffi.h" }) do
                    local path = stem .. suffix
                    saved[path] = read(path)
                    assert(lfs.touch(path, future))
                end
            end
            local output = compiled("--test", "--incremental", "--verbose", APP, OTHER)
            for _, name in ipairs({ APP, OTHER }) do
                assert.matches("Titan object hit " .. name .. ":", output, 1, true)
            end
            for path, contents in pairs(saved) do
                assert.equal(contents, read(path), path)
                assert.equal(future, lfs.attributes(path, "modification"), path)
            end
            local run_ok, run_output = run_program(APP)
            assert.is_true(run_ok, run_output)
            assert.matches("[  PASSED  ] 2 tests.", run_output, 1, true)
            write(second_stem .. ".titan", [[
                local test = import "test"
                function test_renamed(context: test.Context) test.assert(true) end
                function test_added(context: test.Context) test.assert(true) end
            ]])
            compiled("-c", "--test", "--incremental", OTHER)
            compiled("--test", "--incremental", APP, OTHER)
            run_ok, run_output = run_program(APP, "--verbose")
            assert.is_true(run_ok, run_output)
            assert.matches("[  PASSED  ] 3 tests.", run_output, 1, true)
            assert.matches(OTHER .. ".test_added", run_output, 1, true)
            assert.matches(OTHER .. ".test_renamed", run_output, 1, true)
            assert.falsy(run_output:find(OTHER .. ".test_second", 1, true))
        end, debug.traceback)
        assert(lfs.chdir(REPOSITORY))
        if not ok then error(result, 0) end
    end)

    for _, provider_kind in ipairs({ "static", "dynamic" }) do
        it("shares unchanged production objects between applications and tests with " ..
            provider_kind .. " standard providers", function()
            if platform.windows and provider_kind == "static" then
                pending("Titan static-provider linking is unsupported on Windows")
                return
            end
            local flags = provider_kind == "static" and { "--static" } or {}
            local function compile_selected(...)
                local arguments = { table.unpack(flags) }
                for _, argument in ipairs({ ... }) do
                    arguments[#arguments + 1] = argument
                end
                return compiled(table.unpack(arguments))
            end
            local production = NAMESPACE .. ".production"
            local production_stem = source(production, [[
                local math = import "math"
                local function hidden(): integer return math.abs(-42) end
                function answer(): integer return hidden() end
            ]])
            local app_stem = source(APP, 'local production = import "' .. production .. [["
                function main(args: {string}): integer return production.answer() end
            ]])
            source(OTHER, 'local production = import "' .. production .. [[.titan"
                local test = import "test"
                function test_shared(context: test.Context)
                    test.assert(production.hidden() == 42)
                    test.assert(production.answer() == 42)
                    context:cleanup(function() test.assert(test.testing()) end)
                end
            ]])
            local provider = prefix .. "/lib/titan/0.6/titan" ..
                (provider_kind == "static" and ".a" or SHARED_SUFFIX)
            local provider_modified = lfs.attributes(provider, "modification")
            assert.truthy(provider_modified, provider)
            assert(lfs.chdir(workspace))
            local ok, failure = xpcall(function()
                compile_selected("--incremental", APP)
                exit_code(APP, 42)
                local future = os.time() + 60
                local saved = {}
                for _, stem in ipairs({ production_stem, app_stem }) do
                    for _, suffix in ipairs({ ".c", ".o", ".ffi.h" }) do
                        local path = stem .. suffix
                        saved[path] = read(path)
                        assert(lfs.touch(path, future))
                    end
                end
                local output = compile_selected("--test", "--incremental", "--verbose", OTHER)
                assert.matches("Titan object hit " .. production .. ":", output, 1, true)
                assert.falsy(output:find("__test_support", 1, true), output)
                assert.is_false(exists(OTHER .. "__test_support.o"))
                assert.is_false(exists("titan/test__test_support.o"))
                local ran, run_output = run_program(OTHER)
                assert.is_true(ran, run_output)
                assert.matches("[  PASSED  ] 1 test.", run_output, 1, true)
                assert.matches(OTHER .. ".test_shared", run_output, 1, true)
                output = compile_selected("--incremental", "--verbose", APP)
                for _, name in ipairs({ APP, production }) do
                    assert.matches("Titan object hit " .. name .. ":", output, 1, true)
                end
                exit_code(APP, 42)
                for path, contents in pairs(saved) do
                    assert.equal(contents, read(path), path)
                    assert.equal(future, lfs.attributes(path, "modification"), path)
                end
                assert.equal(provider_modified, lfs.attributes(provider, "modification"))
            end, debug.traceback)
            assert(lfs.chdir(REPOSITORY))
            assert.is_true(ok, failure)
        end)
    end

    it("builds a parallel Make DAG and propagates changed inline foreign bodies", function()
        if platform.windows then
            pending("This Unix Make fixture publishes the unsupported Titan archive provider")
            return
        end
        local base = NAMESPACE .. ".base"
        local left = NAMESPACE .. ".left"
        local right = NAMESPACE .. ".right"
        local base_stem = source(base, [[
            foreign function bump(item: int): int return item + 1 end
        ]])
        local stems = { base_stem }
        for index, name in ipairs({ left, right }) do
            stems[#stems + 1] = source(name, 'local base = import "' .. base .. [[.titan"
                function number(): integer return base.bump(]] .. index .. [[) as integer end
            ]])
        end
        local function invocation(...)
            local argv = compiler_arguments()
            argv[#argv + 1] = "--source-first"
            argv[#argv + 1] = "--incremental"
            for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
            return command(argv)
        end
        local makefile = workspace .. "/build.mk"
        write(makefile, table.concat({
            ".DELETE_ON_ERROR:",
            ".PHONY: all",
            "all: " .. NAMESPACE .. ".so",
            base_stem .. ".o: " .. base_stem .. ".titan " .. makefile,
            "\t" .. invocation("-c", base),
            stems[2] .. ".o: " .. stems[2] .. ".titan " .. base_stem .. ".o " .. makefile,
            "\t" .. invocation("-c", left),
            stems[3] .. ".o: " .. stems[3] .. ".titan " .. base_stem .. ".o " .. makefile,
            "\t" .. invocation("-c", right),
            NAMESPACE .. ".so: " .. table.concat(stems, ".o ") .. ".o " .. makefile,
            "\t" .. invocation(base, left, right),
            "",
        }, "\n"))
        local function make(...)
            local argv = { "make", "-f", makefile, "-j2" }
            for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
            local ok, output = run(argv)
            assert.is_true(ok, output)
        end
        local function values(expected_left, expected_right)
            local script = string.format(
                'package.path = "./?.lua;" .. package.path; ' ..
                'assert(require(%q).number() == %d); assert(require(%q).number() == %d)',
                left, expected_left, right, expected_right)
            local ok, output = run({ LUA, "-E", "-e", script })
            assert.is_true(ok, output)
        end
        make()
        assert.is_true(exists(NAMESPACE .. ".a"))
        values(2, 3)
        local observations = {}
        for _, stem in ipairs(stems) do
            for _, suffix in ipairs({ ".o", ".ffi.h" }) do
                observations[stem .. suffix] = lfs.attributes(stem .. suffix, "modification")
            end
        end
        observations[base_stem .. ".titan.h"] =
            lfs.attributes(base_stem .. ".titan.h", "modification")
        make("-q")
        make()
        for path, modified in pairs(observations) do
            assert.equal(modified, lfs.attributes(path, "modification"), path)
        end
        write(base_stem .. ".titan", [[
            foreign function bump(item: int): int return item + 5 end
        ]])
        make()
        values(6, 7)
        make("-q")
    end)
end)

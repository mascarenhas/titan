local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local filesystem = require "spec.support.filesystem"
local objectmetadata = require "titan-compiler.objectmetadata"

local NAMESPACE = "incremental_cli_fixture"
local APP = "incremental_cli_app"
local OTHER = "incremental_cli_other"
local ROOTS = { NAMESPACE, APP, OTHER }
local REPOSITORY = assert(lfs.currentdir())
if platform.windows then REPOSITORY = assert(platform.path.normalize(REPOSITORY)) end
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local workspace
local compiler_root, sdk_root, compiler_environment

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
    local options
    if platform.windows and argv[1] == "env" then
        local variables, rest = {}, {}
        local index = 2
        while argv[index] do
            local name, value = argv[index]:match("^([%a_][%w_]*)=(.*)$")
            if not name then break end
            variables[name] = value
            index = index + 1
        end
        for i = index, #argv do rest[#rest + 1] = argv[i] end
        argv, options = rest, { env = variables }
    end
    local result = compiler_io.new_sync():run(argv, options)
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
    for _, value in ipairs({ ... }) do argv[#argv + 1] = value end
    return run(argv)
end

local function compiler_arguments()
    -- Match the existing CLI specs: exercise this checkout's CLI and compiler
    -- while keeping the selected installation's Lua/native SDK.
    local argv = {
        "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
        "TITAN_ROOT=" .. assert(sdk_root or prefix,
            "incremental CLI specs require an installed SDK"),
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto", "TITAN_EXTRA_LDFLAGS=-fno-lto",
        LUA, "-E", "-e",
        string.format("package.path = %q .. package.path; package.cpath = %q .. package.cpath",
            (compiler_root or REPOSITORY) .. "/?.lua;" ..
                (compiler_root or REPOSITORY) .. "/?/init.lua;",
            REPOSITORY .. "/titan-runtime/bootstrap/?" .. SHARED_SUFFIX .. ";"),
        (compiler_root or REPOSITORY) .. "/titanc", "--tree", workspace,
    }
    for name, value in pairs(compiler_environment or {}) do
        local replaced = false
        for index, argument in ipairs(argv) do
            if argument:sub(1, #name + 1) == name .. "=" then
                argv[index], replaced = name .. "=" .. value, true
                break
            end
        end
        if not replaced then table.insert(argv, 2, name .. "=" .. value) end
    end
    return argv
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

-- Private copies keep publication/configuration fixtures away from the selected
-- SDK without changing link counts on shared installed archives or providers.
local function copy_tree(from, to)
    mkdir(to)
    for name in lfs.dir(from) do
        if name ~= "." and name ~= ".." then
            local input, output = from .. "/" .. name, to .. "/" .. name
            if lfs.attributes(input, "mode") == "directory" then
                copy_tree(input, output)
            else
                write(output, read(input))
            end
        end
    end
end

local function private_sdk()
    sdk_root = workspace .. "/sdk"
    if platform.windows then
        copy_tree(prefix .. "/bin", sdk_root .. "/bin")
    end
    copy_tree(prefix .. "/include", sdk_root .. "/include")
    if exists(prefix .. "/src/lua-5.5.1") then
        copy_tree(prefix .. "/src/lua-5.5.1", sdk_root .. "/src/lua-5.5.1")
    end
    copy_tree(prefix .. "/lib", sdk_root .. "/lib")
    return sdk_root
end

local function private_compiler()
    compiler_root = workspace .. "/compiler"
    copy_tree(REPOSITORY .. "/titan-compiler", compiler_root .. "/titan-compiler")
    copy_tree(REPOSITORY .. "/c-parser", compiler_root .. "/c-parser")
    write(compiler_root .. "/titanc", read(REPOSITORY .. "/titanc"))
    write(compiler_root .. "/titan-config.lua", read(REPOSITORY .. "/titan-config.lua"))
    return compiler_root
end

local function certified(...)
    return compiled("-o", workspace .. "/build", "--incremental",
        "--source-first", "-v", ...)
end

local function object_path(stem)
    return workspace .. "/build/" .. stem:sub(#workspace + 2) .. ".o"
end

local function remember_objects(stems)
    local saved, timestamp = {}, os.time() - 120
    for name, stem in pairs(stems) do
        local path = object_path(stem)
        assert(lfs.touch(path, timestamp, timestamp))
        saved[name] = { path = path, bytes = read(path), timestamp = timestamp }
    end
    return saved
end

local function decisions(output, saved, misses)
    local seen = {}
    for line in output:gmatch("[^\n]+") do
        local status, name, detail = line:match("^Titan object (%w+) ([^:]+): (.+)$")
        if name and saved[name] then
            assert.is_nil(seen[name], "duplicate object decision: " .. line)
            seen[name] = status
            local reason = misses[name]
            if reason then
                assert.equal("miss", status, line)
                assert.equal(reason, detail:sub(1, #reason), line)
            else
                assert.equal("hit", status, line)
            end
        end
    end
    for name, previous in pairs(saved) do
        assert.is_string(seen[name], output)
        local modified = assert(lfs.attributes(previous.path, "modification"))
        if misses[name] then
            assert.not_equal(previous.timestamp, modified, name)
        else
            assert.equal(previous.timestamp, modified, name)
            assert.equal(previous.bytes, read(previous.path), name)
        end
    end
end

local function no_native_compile(output)
    for line in output:gmatch("[^\n]+") do
        assert.is_nil(line:match("%s['\"]?%-c['\"]?%s"),
            "unexpected native compilation: " .. line)
    end
end

local function certified_exit(expected)
    local executable = platform.windows and
        assert(driver.windows_program_paths(APP, nil, nil, workspace .. "/build")).executable
        or workspace .. "/build/" .. APP
    local argv = { "env",
        "PATH=" .. (sdk_root or prefix) .. "/bin" .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or ""),
        "TITAN_PATH_0_6=" ..
            (platform.windows and (workspace .. "/build/lib/titan/0.6;") or "") ..
            workspace .. "/build;" ..
            (sdk_root or prefix) .. "/lib/titan/0.6;;", executable }
    local ok, output, why, status = run(argv)
    assert.equal("exit", why, output)
    assert.equal(expected, status, output)
    assert.equal(expected == 0, ok, output)
    return output
end

describe("incremental and separate compilation (CLI)", function()
    before_each(function()
        compiler_root, sdk_root, compiler_environment = nil, nil, {}
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
                -- A launcher's resources are named after its entrypoint C file
                -- (`<root>__entrypoint.c.rc`), never after the module root.
                for _, path in ipairs(driver.windows_program_auxiliary_paths(
                        root .. "__entrypoint.c", paths.provider)) do
                    remove(path)
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
        local ok, text, why, code = run(command)
        assert.equal("exit", why, text)
        assert.equal(42, code, text)
        assert.is_false(ok)
        local synthetic_entrypoint
        for entry in lfs.dir(output .. "/.titan-links") do
            if entry ~= "." and entry ~= ".." then
                local candidate = output .. "/.titan-links/" .. entry ..
                    "/synthetic/" .. APP .. "__entrypoint.c"
                if exists(candidate) then
                    synthetic_entrypoint = candidate
                end
            end
        end
        assert.is_string(synthetic_entrypoint)
        assert.is_false(exists(output .. "/" .. APP .. "__entrypoint.c"))
        assert.is_false(exists(APP .. "__entrypoint.c"))
        if platform.windows then
            -- Launcher resources follow the synthetic entrypoint C file into the output tree.
            for _, suffix in ipairs({ ".manifest", ".rc", ".res" }) do
                assert.is_true(exists(synthetic_entrypoint .. suffix))
                assert.is_false(exists(output .. "/" .. APP .. "__entrypoint.c" .. suffix))
                assert.is_false(exists(APP .. "__entrypoint.c" .. suffix))
            end
        end
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

    it("rebuilds changed roots even when reached through an earlier root", function()
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

    it("certifies dependency objects and explicit incremental roots", function()
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
        local output = compiled("-c", "--incremental", "-v", APP)
        assert.matches("Titan object hit " .. base .. ":", output, 1, true)
        assert.matches("Titan object hit " .. APP .. ":", output, 1, true)
        assert.equal(future, lfs.attributes(base_stem .. ".o", "modification"))
        assert.equal(contents, read(base_stem .. ".o"))
        assert.equal(future, lfs.attributes(app_stem .. ".o", "modification"))
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

    it("recompiles consumers automatically when native provider bindings change", function()
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
        local output = compiled("--incremental", "-v", APP)
        assert.matches("Titan object miss " .. APP .. ": import-binding", output, 1, true)
        exit_code(APP, 23)
        output = compiled("--incremental", "--source-first", "-v", APP)
        assert.matches("Titan object miss " .. APP .. ": import-binding", output, 1, true)
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

    it("builds a module graph and propagates changed inline foreign bodies", function()
        if platform.windows then
            pending("Titan archive providers are unsupported on Windows")
            return
        end
        local base = NAMESPACE .. ".base"
        local left = NAMESPACE .. ".left"
        local right = NAMESPACE .. ".right"
        local base_stem = source(base, [[
            local foreign function bump(item: int): int return item + 1 end
        ]])
        local stems = { base_stem }
        for index, name in ipairs({ left, right }) do
            stems[#stems + 1] = source(name, 'local base = import "' .. base .. [[.titan"
                function number(): integer return base.bump(]] .. index .. [[) as integer end
            ]])
        end
        local function build()
            return compiled("--source-first", "--incremental", "-j", "2",
                "-v", base, left, right)
        end
        local function values(expected_left, expected_right)
            local script = string.format(
                'package.path = "./?.lua;" .. package.path; ' ..
                'assert(require(%q).number() == %d); assert(require(%q).number() == %d)',
                left, expected_left, right, expected_right)
            local ok, output = run({ LUA, "-E", "-e", script })
            assert.is_true(ok, output)
        end
        build()
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
        local warm = build()
        for _, name in ipairs({ base, left, right }) do
            assert.matches("Titan object hit " .. name .. ":", warm, 1, true)
        end
        for path, modified in pairs(observations) do
            assert.equal(modified, lfs.attributes(path, "modification"), path)
        end
        write(base_stem .. ".titan", [[
            local foreign function bump(item: int): int return item + 5 end
        ]])
        local output = build()
        assert.matches("Titan object miss " .. base .. ": source-content", output, 1, true)
        for _, name in ipairs({ left, right }) do
            assert.matches("Titan object miss " .. name .. ": import-interface", output, 1, true)
        end
        values(6, 7)
        build()
    end)

    describe("certified input decisions", function()
        for _, publication in ipairs({ "copy", "hardlink", "symlink" }) do
            it("reuses objects after identical " .. publication .. " SDK publication", function()
                if publication == "symlink" then
                    local available, message = filesystem.symlink_capability()
                    if not available then pending(message); return end
                end
                local sdk = private_sdk()
                local republished = {
                    {
                        path = sdk .. "/include/titan.h",
                        target = sdk .. "/published-titan.h",
                    },
                    {
                        path = sdk .. "/include/titan/ffi.h",
                        target = sdk .. "/published-ffi.h",
                    },
                    {
                        path = sdk .. "/lib/titan/0.6/titan" .. SHARED_SUFFIX,
                        target = sdk .. "/published-titan" .. SHARED_SUFFIX,
                    },
                }
                if not platform.windows and exists(sdk .. "/lib/titan/0.6/titan.a") then
                    republished[#republished + 1] = {
                        path = sdk .. "/lib/titan/0.6/titan.a",
                        target = sdk .. "/published-titan.a",
                    }
                end
                if publication == "symlink" then
                    for _, item in ipairs(republished) do
                        write(item.target, read(item.path))
                        assert(os.remove(item.path))
                        assert(lfs.link(item.target, item.path, true))
                    end
                end
                local base = NAMESPACE .. ".base"
                local base_stem = source(base, [[
                    foreign import "titan/ffi.h"
                    local math = import "math"
                    function answer(): integer return math.abs(-11) end
                ]])
                local app_stem = source(APP, 'local base = import "' .. base .. [[.titan"
                    function main(args: {string}): integer return base.answer() end
                ]])
                local stems = { [base] = base_stem, [APP] = app_stem }
                certified(APP)
                local saved = remember_objects(stems)
                for _, item in ipairs(republished) do
                    local bytes = read(item.path)
                    assert(os.remove(item.path))
                    if publication == "copy" then
                        write(item.path, bytes)
                        assert(lfs.touch(item.path, os.time() + 60))
                    elseif publication == "hardlink" then
                        write(item.target, bytes)
                        assert(lfs.link(item.target, item.path))
                    else
                        assert(lfs.link(item.target, item.path, true))
                    end
                end
                local output = certified(APP)
                decisions(output, saved, {})
                no_native_compile(output)
                assert.is_nil(output:find("C include candidate changed after module header resolution", 1, true))
                certified_exit(11)
            end)
        end

        for _, change in ipairs({ "content", "missing", "candidate", "unreadable" }) do
            it("rechecks a " .. change .. " C header without external prerequisites", function()
                if change == "unreadable" and platform.windows then
                    pending("POSIX permission bits are not an NTFS access contract")
                    return
                end
                local base = NAMESPACE .. ".base"
                local stem = source(base, [[
                    foreign import "value.h"
                    function answer(): integer return ffi.INCREMENTAL_VALUE end
                ]])
                local directory = stem:match("^(.*)/")
                local selected = directory .. "/value.h"
                local early, late = workspace .. "/early", workspace .. "/late"
                mkdir(early)
                write(late .. "/value.h", change == "candidate" and
                    "#define INCREMENTAL_VALUE 31\n" or "#define INCREMENTAL_VALUE 32\n")
                if change ~= "candidate" then
                    write(selected, "#define INCREMENTAL_VALUE 31\n")
                end
                local stems = { [base] = stem, [APP] = source(APP,
                    'local base = import "' .. base .. [["
                    function main(args: {string}): integer return base.answer() end
                ]]) }
                certified("-I", early, "-I", late, APP)
                certified_exit(31)
                local saved = remember_objects(stems)
                local changed_path = selected
                if change == "content" then
                    local modified = lfs.attributes(selected, "modification")
                    write(selected, "#define INCREMENTAL_VALUE 32\n")
                    assert(lfs.touch(selected, modified, modified))
                elseif change == "missing" then
                    assert(os.remove(selected))
                elseif change == "candidate" then
                    changed_path = early .. "/value.h"
                    write(changed_path, "#define INCREMENTAL_VALUE 32\n")
                else
                    local ok, text = run({ "chmod", "000", selected })
                    assert.is_true(ok, text)
                    local readable = io.open(selected, "rb")
                    if readable then
                        readable:close()
                        assert(run({ "chmod", "600", selected }))
                        pending("the current user can read chmod-000 files")
                        return
                    end
                end
                local completed, failure = xpcall(function()
                    local output = certified("-I", early, "-I", late, APP)
                    decisions(output, saved, {
                        [base] = "c-input " .. changed_path .. ": " .. change,
                    })
                    certified_exit(32)
                end, debug.traceback)
                if change == "unreadable" then
                    local ok, text = run({ "chmod", "600", selected })
                    assert.is_true(ok, text)
                end
                assert.is_true(completed, failure)
            end)
        end

        it("refreshes a retained C environment before checking a fresh source importer", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, [[
                foreign import "value.h"
                function answer(): integer return ffi.INCREMENTAL_VALUE end
            ]])
            local early, late = workspace .. "/early", workspace .. "/late"
            mkdir(early)
            write(late .. "/value.h", "#define INCREMENTAL_VALUE 41\n")
            certified("-c", "-I", early, "-I", late, base)
            local saved = remember_objects({ [base] = stem })
            write(early .. "/value.h", "#define INCREMENTAL_VALUE 42\n")
            source(APP, 'local base = import "' .. base .. [[.titan"
                function main(args: {string}): integer
                    return base.answer() + (ffi.INCREMENTAL_VALUE as integer) - 42
                end
            ]])
            local output = certified("-I", early, "-I", late, APP)
            decisions(output, saved, { [base] = "c-input " .. early .. "/value.h: candidate" })
            assert.is_nil(output:find("C include candidate changed after module header resolution", 1, true))
            certified_exit(42)
        end)

        it("cuts off ordinary consumers after producer body edits", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, "function answer(): integer return 21 end\n")
            local stems = { [base] = stem, [APP] = source(APP,
                'local base = import "' .. base .. [["
                function main(args: {string}): integer return base.answer() end
            ]]) }
            certified(APP)
            local saved = remember_objects(stems)
            write(stem .. ".titan", "function answer(): integer return 22 end\n")
            local output = certified(APP)
            decisions(output, saved, { [base] = "source-content" })
            certified_exit(22)
        end)

        it("rechecks exactly the importers after a public signature changes", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, "function answer(): integer return 21 end\n")
            local stems = { [base] = stem, [APP] = source(APP,
                'local base = import "' .. base .. [["
                function main(args: {string}): integer return base.answer() as integer end
            ]]), [OTHER] = source(OTHER, "function unrelated(): integer return 7 end\n") }
            certified("-c", APP, OTHER)
            local saved = remember_objects(stems)
            write(stem .. ".titan", "function answer(): float return 23.0 end\n")
            local output = certified(APP, OTHER)
            decisions(output, saved, {
                [base] = "source-content", [APP] = "import-interface " .. base .. " (public)",
            })
            certified_exit(23)
            write(stem .. ".titan", "function answer(): string return \"changed\" end\n")
            local ok, rejected = compile("-o", workspace .. "/build",
                "--incremental", "--source-first", "-v", APP)
            assert.is_false(ok)
            assert.matches("Titan object miss " .. APP .. ": import-interface " .. base .. " (public)",
                rejected, 1, true)
            assert.matches("string", rejected, 1, true)
        end)

        it("certifies the private layout of a public record", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, [[
                record Item local hidden: integer; value: integer end
                function make(): Item return Item.new(1, 24) end
            ]])
            local stems = { [base] = stem, [APP] = source(APP,
                'local base = import "' .. base .. [["
                function main(args: {string}): integer return base.make().value end
            ]]) }
            certified(APP)
            local saved = remember_objects(stems)
            write(stem .. ".titan", [[
                record Item local hidden: string; local extra: integer; value: integer end
                function make(): Item return Item.new("private", 1, 25) end
            ]])
            local output = certified(APP)
            decisions(output, saved, {
                [base] = "source-content", [APP] = "import-interface " .. base .. " (public)",
            })
            certified_exit(25)
        end)

        it("distinguishes source-private surface changes from private function bodies", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, "local function answer(): integer return 26 end\n")
            local stems = { [base] = stem, [APP] = source(APP,
                'local base = import "' .. base .. [[.titan"
                function main(args: {string}): integer return base.answer() as integer end
            ]]) }
            certified(APP)
            local saved = remember_objects(stems)
            write(stem .. ".titan", "local function answer(): integer return 27 end\n")
            decisions(certified(APP), saved, { [base] = "source-content" })
            certified_exit(27)
            saved = remember_objects(stems)
            write(stem .. ".titan", "local function answer(): float return 28.0 end\n")
            decisions(certified(APP), saved, {
                [base] = "source-content", [APP] = "import-interface " .. base .. " (source)",
            })
            certified_exit(28)
        end)

        it("recompiles importers when a copied local foreign helper body changes", function()
            local base = NAMESPACE .. ".base"
            local stem = source(base, "local foreign function answer(): int return 51 end\n")
            local stems = { [base] = stem, [APP] = source(APP,
                'local base = import "' .. base .. [[.titan"
                function main(args: {string}): integer return base.answer() as integer end
            ]]) }
            certified(APP)
            local saved = remember_objects(stems)
            write(stem .. ".titan", "local foreign function answer(): int return 52 end\n")
            decisions(certified(APP), saved, {
                [base] = "source-content", [APP] = "import-interface " .. base .. " (source)",
            })
            certified_exit(52)
        end)

        it("fingerprints modules independently inside one binary provider", function()
            local base, other = NAMESPACE .. ".base", NAMESPACE .. ".other"
            local stem = source(base, "function answer(): integer return 41 end\n")
            local other_stem = source(other, "function other(): integer return 1 end\n")
            local out = workspace .. "/build"
            compiled("-o", out, base, other)
            compiler_environment.TITAN_PATH_0_6 = out .. ";" .. prefix .. "/lib/titan/0.6"
            local app_stem = source(APP, 'local base = import "' .. base .. [["
                function main(args: {string}): integer return base.answer() as integer end
            ]])
            local function binary_build()
                return compiled("-o", out, "--incremental", "-v", APP)
            end
            binary_build()
            local saved = remember_objects({ [APP] = app_stem })
            write(other_stem .. ".titan", "function other(): string return \"unrelated\" end\n")
            compiled("-o", out, base, other)
            decisions(binary_build(), saved, {})
            certified_exit(41)
            write(stem .. ".titan", "function answer(): integer return 42 end\n")
            compiled("-o", out, base, other)
            decisions(binary_build(), saved, {})
            certified_exit(42)
            write(stem .. ".titan", "function answer(): float return 43.0 end\n")
            compiled("-o", out, base, other)
            decisions(binary_build(), saved, { [APP] = "import-interface " .. base .. " (public)" })
            certified_exit(43)
            write(stem .. ".titan", "function answer(): string return \"changed\" end\n")
            compiled("-o", out, base, other)
            local ok, rejected = compile("-o", out, "--incremental", "-v", APP)
            assert.is_false(ok)
            assert.matches("Titan object miss " .. APP .. ": import-interface " .. base .. " (public)",
                rejected, 1, true)
            assert.matches("string", rejected, 1, true)
        end)

        it("certifies contributor membership and source bytes rather than timestamps", function()
            local folder = NAMESPACE .. ".folder"
            local stem = source(folder, "function answer(): integer return 61 end\n", true)
            local stems = { [folder] = stem, [APP] = source(APP,
                'local folder = import "' .. folder .. [["
                function main(args: {string}): integer return folder.answer() end
            ]]) }
            certified(APP)
            local saved = remember_objects(stems)
            local part = stem:match("^(.*)/") .. "/private.titan"
            write(part, "local function unused(): integer return 1 end\n")
            decisions(certified(APP), saved, { [folder] = "source-set added " .. part })
            saved = remember_objects(stems)
            assert(os.remove(part))
            decisions(certified(APP), saved, { [folder] = "source-set removed " .. part })
            saved = remember_objects(stems)
            local modified = lfs.attributes(stem .. ".titan", "modification")
            write(stem .. ".titan", "function answer(): integer return 62 end\n")
            assert(lfs.touch(stem .. ".titan", modified, modified))
            decisions(certified(APP), saved, { [folder] = "source-content " .. stem .. ".titan" })
            certified_exit(62)
        end)

        it("keeps plain compile-only roots forced while incremental roots certify", function()
            local stem = source(APP, main(63))
            local stems = { [APP] = stem }
            certified("-c", APP)
            local saved = remember_objects(stems)
            local output = certified("-c", APP)
            decisions(output, saved, {})
            no_native_compile(output)
            compiled("-o", workspace .. "/build", "-c", "-v", APP)
            assert.not_equal(saved[APP].timestamp, lfs.attributes(object_path(stem), "modification"))
            saved = remember_objects(stems)
            write(stem .. ".titan", main(64))
            decisions(certified("-c", APP), saved, { [APP] = "source-content" })
            certified(APP)
            certified_exit(64)
        end)

        it("certifies contextual owners that are not direct imports", function()
            local owner, facade = NAMESPACE .. ".owner", OTHER .. ".facade"
            local out = workspace .. "/build"
            compiler_environment.TITAN_PATH_0_6 = out .. ";" .. prefix .. "/lib/titan/0.6"
            local function publish_owner(body)
                local owner_stem = source(owner, body)
                compiled("-o", out, owner)
                remove(owner_stem .. ".titan")
            end
            publish_owner([[
                record Item
                    local hidden: integer
                    value: integer
                end
                function Item:read(): integer return 0 end
                function make(): Item return Item.new(1, 71) end
            ]])
            local facade_stem = source(facade, 'local owner = import "' .. owner .. [["
                function make(): owner.Item return owner.make() end
            ]])
            local app_stem = source(APP, 'local facade = import "' .. facade .. [["
                function main(args: {string}): integer
                    local item = facade.make()
                    return item.value + item:read()
                end
            ]])
            local stems = { [facade] = facade_stem, [APP] = app_stem }
            local function binary_build(...)
                local arguments = { "-o", out, "--incremental", "--source-first", "-v", ... }
                arguments[#arguments + 1] = APP
                return compiled(table.unpack(arguments))
            end
            binary_build()
            certified_exit(71)
            local saved = remember_objects(stems)
            publish_owner([[
                record Item
                    local hidden: string
                    local extra: integer
                    value: integer
                end
                function Item:read(): integer return 0 end
                function make(): Item return Item.new("private", 1, 72) end
            ]])
            decisions(binary_build(), saved, {
                [facade] = "import-interface " .. owner .. " (public)",
                [APP] = "owner-interface " .. owner,
            })
            certified_exit(72)
            if not platform.windows then
                saved = remember_objects(stems)
                decisions(binary_build("--static"), saved, {
                    [facade] = "import-binding " .. owner,
                    [APP] = "owner-binding " .. owner .. ": global -> direct",
                })
                certified_exit(72)
                saved = remember_objects(stems)
                decisions(binary_build(), saved, {
                    [facade] = "import-binding " .. owner,
                    [APP] = "owner-binding " .. owner .. ": direct -> global",
                })
                certified_exit(72)
            end
        end)

        for _, component in ipairs({ "compiler", "preamble", "options", "toolchain" }) do
            it("classifies changed configuration " .. component .. " inputs", function()
                if component == "compiler" then private_compiler() end
                if component == "preamble" then private_sdk() end
                if component == "toolchain" then
                    for _, cc in ipairs({ "gcc", "clang" }) do
                        local available, text = run({ cc, "--version" })
                        if not available then pending(cc .. " is unavailable: " .. text); return end
                    end
                    compiler_environment.CC = "gcc"
                end
                local stem = source(APP, main(73))
                certified(APP)
                local saved = remember_objects({ [APP] = stem })
                if component == "compiler" then
                    local path = compiler_root .. "/titan-compiler/coder.lua"
                    write(path, read(path) .. "\n-- configuration identity fixture\n")
                elseif component == "preamble" then
                    local path = sdk_root .. "/include/titan.h"
                    write(path, read(path) .. "\n/* configuration identity fixture */\n")
                elseif component == "options" then
                    compiler_environment.TITAN_EXTRA_CFLAGS = "-O1 -fno-lto"
                else
                    compiler_environment.CC = "clang"
                end
                decisions(certified(APP), saved, { [APP] = "configuration " .. component })
                certified_exit(73)
            end)
        end

        it("certifies split policy as a code-generation input", function()
            local stem = source(APP, [[
                function first(): integer return 37 end
                function second(): integer return 37 end
                function main(args: {string}): integer return first() + second() end
            ]])
            certified("--c-parts", "1", APP)
            local saved = remember_objects({ [APP] = stem })
            decisions(certified("--c-parts", "2", APP),
                saved, { [APP] = "codegen-options c_parts" })
            certified_exit(74)
        end)

        it("certifies test-owner native flags without invalidating production modules", function()
            local base = NAMESPACE .. ".base"
            local stems = { [base] = source(base,
                "function answer(): integer return 75 end\n"), [APP] = source(APP,
                'local base = import "' .. base .. [["
                local test = import "test"
                function test_answer(context: test.Context)
                    test.assert(base.answer() == 75)
                end
            ]]) }
            certified("-c", APP)
            local saved = remember_objects(stems)
            local output = certified("--test", APP)
            decisions(output, saved, { [APP] = "codegen-options test_flags" })
            local result = certified_exit(0)
            assert.matches("[  PASSED  ] 1 test.", result, 1, true)
            saved = remember_objects(stems)
            output = certified("--test", APP)
            decisions(output, saved, {})
            no_native_compile(output)
        end)

        for _, publication in ipairs({ "retarget", "hardlink" }) do
            it("rechecks declaring provenance in a mixed " .. publication .. " build", function()
                local available, message = filesystem.symlink_capability()
                if not available then pending(message); return end
                local base = NAMESPACE .. ".base"
                local stem = source(base, [[
                    foreign import "inc/wrapper.h"
                    function identity(item: foreign *Item): foreign *Item return item end
                ]])
                local directory = stem:match("^(.*)/")
                local header = directory .. "/inc/foo.h"
                local first, second = directory .. "/first/item.h", directory .. "/second/item.h"
                local bytes = "typedef struct Item { int value; } Item;\n"
                write(first, bytes)
                write(second, bytes)
                write(directory .. "/inc/wrapper.h", '#include "foo.h"\n')
                assert(lfs.link(first, header, true))
                local app_stem = source(APP, 'local base = import "' .. base .. [["
                    foreign import "]] .. directory .. [[/inc/wrapper.h"
                    function main(args: {string}): integer
                        local item = foreign Item.new()
                        item.value = 76
                        return base.identity(item).value as integer
                    end
                ]])
                certified(APP)
                local saved = remember_objects({ [base] = stem, [APP] = app_stem })
                local before = assert(objectmetadata.read(read(object_path(stem)), object_path(stem)))
                assert(os.remove(header))
                assert(lfs.link(second, header, publication == "retarget"))
                write(app_stem .. ".titan", read(app_stem .. ".titan") .. "\n-- fresh importer\n")
                local output = certified(APP)
                local after = assert(objectmetadata.read(read(object_path(stem)), object_path(stem)))
                local function identity(entry, kind)
                    for _, input in ipairs(entry.c_header_dependencies) do
                        if input.kind == kind and input.path == header then return input.identity end
                    end
                    error("missing " .. kind .. " header input")
                end
                if platform.windows then
                    decisions(output, saved, { [APP] = "source-content" })
                    assert.equal(identity(before, "origin"), identity(after, "origin"))
                else
                    decisions(output, saved, {
                        [base] = "c-input " .. header .. ": provenance", [APP] = "source-content",
                    })
                    assert.not_equal(identity(before, "origin"), identity(after, "origin"))
                end
                assert.equal(identity(before, "file"), identity(after, "file"))
                assert.is_nil(output:find("not visible with its original identity", 1, true))
                certified_exit(76)
            end)
        end

        for _, input in ipairs({ "forced", "shadow", "runtime", "presence" }) do
            it("certifies " .. input .. " preamble inputs without a foreign import", function()
                local flags, changed = {}, nil
                if input == "runtime" then
                    private_sdk()
                    changed = sdk_root .. "/include/transfer.h"
                elseif input == "shadow" then
                    local directory = workspace .. "/system"
                    mkdir(directory)
                    flags = { "--cflag=-isystem", "--cflag=" .. directory }
                    changed = directory .. "/float.h"
                else
                    local forced = workspace .. "/forced.h"
                    flags = { "--cflag=-include", "--cflag=" .. forced }
                    if input == "presence" then
                        write(forced, [[
#if __has_include("optional.h")
#define INCREMENTAL_PRESENCE 1
#else
#define INCREMENTAL_PRESENCE 0
#endif
]])
                        changed = workspace .. "/optional.h"
                    else
                        write(forced, "#define INCREMENTAL_FORCED 1\n")
                        changed = forced
                    end
                end
                local stem = source(APP, main(77))
                local arguments = { table.unpack(flags) }
                arguments[#arguments + 1] = APP
                certified(table.unpack(arguments))
                local saved = remember_objects({ [APP] = stem })
                if input == "shadow" then
                    write(changed, "#include_next <float.h>\n#define INCREMENTAL_SHADOW 1\n")
                elseif input == "presence" then
                    write(changed, "/* presence alone changes the preprocessed branch */\n")
                else
                    write(changed, read(changed) .. "\n/* changed preamble input */\n")
                end
                decisions(certified(table.unpack(arguments)), saved, { [APP] = "configuration preamble" })
                certified_exit(77)
            end)
        end
    end)
end)

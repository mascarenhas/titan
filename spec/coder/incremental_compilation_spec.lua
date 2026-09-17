local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local NAMESPACE = "incremental_cli_fixture"
local APP = "incremental_cli_app"
local OTHER = "incremental_cli_other"
local ROOTS = { NAMESPACE, APP, OTHER }
local REPOSITORY = assert(lfs.currentdir())
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
    local pipe = assert(io.popen(command(argv) .. " 2>&1", "r"))
    local output = assert(pipe:read("*a"))
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local prefix = os.getenv("PREFIX") or os.getenv("TITAN_ROCKS_ROOT")
if not prefix then
    for template in package.cpath:gmatch("[^;]+") do
        prefix = template:match("^(.*)/lib/lua/5[.]5/[?][.]so$")
        if prefix then break end
    end
end
local LUA = prefix and exists(prefix .. "/bin/lua") and prefix .. "/bin/lua" or "lua"

local function compiler_arguments()
    -- Match the existing CLI specs: exercise this checkout's CLI and compiler
    -- while keeping the selected installation's Lua/native SDK.
    return {
        "env", "MAKE=true", "CCACHE_DISABLE=1", "TITAN_PROBE_CACHE_DISABLE=1",
        "TITAN_ROCKS_ROOT=" .. assert(prefix, "incremental CLI specs require an installed SDK"),
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0", "TITAN_EXTRA_LDFLAGS=",
        LUA, "-E", "-e",
        string.format("package.path = %q .. package.path; package.cpath = %q .. package.cpath",
            REPOSITORY .. "/?.lua;" .. REPOSITORY .. "/?/init.lua;",
            REPOSITORY .. "/titan-runtime/bootstrap/?.so;"),
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
    local ok, output, why, code = run({ "./" .. name })
    assert.equal("exit", why, output)
    assert.equal(expected, code, output)
    assert.equal(expected == 0, ok, output)
end

local function main(value)
    return "function main(args: {string}): integer\nreturn " .. value .. "\nend\n"
end

describe("incremental and separate compilation (CLI)", function()
    before_each(function()
        workspace = os.tmpname()
        assert(os.remove(workspace))
        mkdir(workspace)
    end)

    after_each(function()
        remove(workspace)
        for _, root in ipairs(ROOTS) do
            for _, suffix in ipairs({ "", ".so", ".so.dSYM", ".a", ".lua", ".dSYM",
                "__entrypoint.c", "__entrypoint.o", "__main", "__main.dSYM" }) do
                remove(root .. suffix)
            end
        end
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
            assert.is_false(exists(name .. ".so"))
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
        local real_cc = command(assert(cdriver.split_shell_words(os.getenv("CC") or "cc")))
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
            "exec " .. real_cc .. ' "$@"',
            "",
        }, "\n"))
        local argv = compiler_arguments()
        table.insert(argv, 2, "CC=sh " .. assert(cdriver.shell_quote(wrapper)))
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

    it("links separately compiled test owners with shared support and cached discovery", function()
        local helper = NAMESPACE .. ".support"
        local helper_stem = source(helper, [[
            local test = import "test.titan"
            function active(): boolean return test.runner_active end
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
        -- The real aggregate also gives all object recipes one private build
        -- directory. Never write the shared support fixture into the checkout.
        assert(lfs.chdir(workspace))
        local ok, result = xpcall(function()
            compiled("-c", "--test", "--incremental", "titan.test")
            local support = workspace .. "/titan/test__test_support"
            local future = os.time() + 60
            assert(lfs.touch(support .. ".o", future))
            compiled("-c", "--test", "--incremental", helper)
            local first_output = compiled("-c", "--test", "--incremental", "-v", APP)
            assert.matches("-fno-optimize-sibling-calls", first_output, 1, true)
            compiled("-c", "--test", "--incremental", OTHER)
            assert.is_false(exists(APP))
            assert.is_false(exists(APP .. "__test_runner.c"))
            assert.is_false(exists("titan/test__test_runner.c"))
            assert.equal(future, lfs.attributes(support .. ".o", "modification"))
            local saved = {}
            for _, stem in ipairs({ first_stem, second_stem, helper_stem, support }) do
                for _, suffix in ipairs({ ".o", ".c", ".ffi.h" }) do
                    local path = stem .. suffix
                    saved[path] = read(path)
                    assert(lfs.touch(path, future))
                end
            end
            local output = compiled("--test", "--incremental", "--verbose", APP, OTHER)
            for _, name in ipairs({ APP, OTHER, "titan.test" }) do
                assert.matches("Titan object hit " .. name .. ":", output, 1, true)
            end
            for path, contents in pairs(saved) do
                assert.equal(contents, read(path), path)
                assert.equal(future, lfs.attributes(path, "modification"), path)
            end
            local run_ok, run_output = run({ "./" .. APP })
            assert.is_true(run_ok, run_output)
            assert.matches("[  PASSED  ] 2 tests.", run_output, 1, true)
            write(second_stem .. ".titan", [[
                local test = import "test"
                function test_renamed(context: test.Context) test.assert(true) end
                function test_added(context: test.Context) test.assert(true) end
            ]])
            compiled("-c", "--test", "--incremental", OTHER)
            compiled("--test", "--incremental", APP, OTHER)
            run_ok, run_output = run({ "./" .. APP, "--verbose" })
            assert.is_true(run_ok, run_output)
            assert.matches("[  PASSED  ] 3 tests.", run_output, 1, true)
            assert.matches(OTHER .. ".test_added", run_output, 1, true)
            assert.matches(OTHER .. ".test_renamed", run_output, 1, true)
            assert.falsy(run_output:find(OTHER .. ".test_second", 1, true))
        end, debug.traceback)
        assert(lfs.chdir(REPOSITORY))
        if not ok then error(result, 0) end
    end)

    it("builds a parallel Make DAG and propagates changed inline foreign bodies", function()
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

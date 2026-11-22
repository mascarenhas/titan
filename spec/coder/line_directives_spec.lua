local assert = require "luassert"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local async_stdlib = require "spec.support.async_stdlib"
local h = require "spec.support.helpers"
local installed_prefix = require "spec.support.installed_prefix"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local cdriver = require "c-parser.cdriver"
local util = require "titan-compiler.util"

local MODULE = "line_directives"
local FILENAME = MODULE .. ".titan"
local SOURCE = [[
function answer(): integer
    return 42
end
]]

local function generate(policy)
    h.reset()
    local ast, parse_err = h.parse(SOURCE, FILENAME)
    assert.truthy(ast, parse_err)
    local _, errors = checker.check(MODULE, ast, SOURCE, FILENAME)
    assert.equal(0, #errors, table.concat(errors, "\n"))
    if policy == nil then
        return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION).parts[1].code
    end
    return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION, policy).parts[1].code
end

local function has_line_directive(code)
    return code:find("#line ", 1, true) ~= nil
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local PREFIX = installed_prefix.active()
local prefix_lua = PREFIX .. (platform.windows and "/bin/lua.exe" or "/bin/lua")
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua or "lua"
local CHECKOUT_FIRST =
    [[package.path = "./?.lua;./?/init.lua;" .. package.path]]

local function run(argv)
    local result = compiler_io.new_sync():run(argv)
    local output = result.output or result.diagnostic or ""
    if platform.windows then output = output:gsub("\r\n", "\n") end
    return result.ok, output, result.why, result.status
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
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

local function clean_cli_artifacts()
    os.remove(MODULE .. ".dll")
    os.remove(MODULE .. ".so")
    os.remove(MODULE .. ".a")
    remove_tree(MODULE .. ".so.dSYM")
end

describe("generated C line directives", function()
    it("emits directives by default and when explicitly enabled", function()
        assert.is_true(has_line_directive(generate()))
        assert.is_true(has_line_directive(generate(true)))
    end)

    it("omits every directive when disabled and resets on the next generation",
       function()
        assert.is_false(has_line_directive(generate(false)))
        assert.is_true(has_line_directive(generate()))
        assert.is_false(has_line_directive(generate(false)))
        assert.is_true(has_line_directive(generate(true)))
    end)

    it("reads the direct-driver default from TITAN_NO_LINE_DIRECTIVES", function()
        local probe = CHECKOUT_FIRST ..
            [[; io.write(tostring(require("titan-compiler.driver").EMIT_LINE_DIRECTIVES))]]
        local ok, output, why, status = run({
            "env", "TITAN_NO_LINE_DIRECTIVES=1", LUA, "-e", probe,
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(status) .. ")")
        assert.equal("false", output)

        ok, output, why, status = run({
            "env", "TITAN_NO_LINE_DIRECTIVES=0", LUA, "-e", probe,
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(status) .. ")")
        assert.equal("true", output)
    end)

    it("publishes and applies the titanc --no-line-directives option",
    function()
        local ok, output, why, status = run({
            LUA, "-e", CHECKOUT_FIRST, "./titanc", "--help",
        })
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(status) .. ")")
        assert.truthy(output:find("--no-line-directives", 1, true), output)

        clean_cli_artifacts()
        local workspace = assert(compiler_io.new_sync():tmpname())
        if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
        os.remove(workspace)
        assert.truthy(lfs.mkdir(workspace))
        local source = assert(io.open(workspace .. "/" .. FILENAME, "wb"))
        assert.truthy(source:write(SOURCE))
        assert.truthy(source:close())

        local lua_workspace
        local tested, test_error = xpcall(function()
            local argv = {
                "env",
                "CCACHE_DISABLE=1",
                "TITAN_RUNTIME_PREBUILT=1",
                "TITAN_EXTRA_CPPFLAGS=",
                "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
                "TITAN_EXTRA_LDFLAGS=-fno-lto",
                "TITAN_NO_LINE_DIRECTIVES=0",
                LUA,
                "-e", CHECKOUT_FIRST,
                "./titanc",
                "--no-line-directives",
                "--tree", workspace,
            }
            if platform.windows then
                table.insert(argv, 2, "TITAN_ROOT=" .. PREFIX)
            else
                lua_workspace = async_stdlib.workspace("line-directives")
                argv[#argv + 1] = "--lua"
                argv[#argv + 1] = lua_workspace .. "/lua-5.5.1"
            end
            argv[#argv + 1] = MODULE
            ok, output, why, status = run(argv)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(status) .. ")")
            local generated = assert(io.open(
                workspace .. "/" .. MODULE .. ".c", "rb"))
            local code = assert(generated:read("*a"))
            assert.truthy(generated:close())
            assert.is_false(has_line_directive(code))
        end, debug.traceback)

        remove_tree(workspace)
        if lua_workspace then remove_tree(lua_workspace) end
        clean_cli_artifacts()
        if not tested then error(test_error, 0) end
    end)

    it("spells line-control filenames that the host C compiler decodes exactly", function()
        -- Names are virtual, so quotes, question marks and control bytes work
        -- on every host. Valid UTF-8 keeps Clang free of encoding warnings.
        local generated = 'C:\\dir\\b"c ??/ ??= $line ${x} 文 😀 Ω.c'
        local source = 'C:\\dir\\b"c ??/ ??= $line ${x} 文 😀 Ω\t\1\127.titan'
        local function bytes(text)
            local values = {}
            for index = 1, #text do values[index] = tostring(text:byte(index)) end
            return table.concat(values, ",")
        end
        local program = table.concat({
            "#include <string.h>",
            "#define TITAN_GENERATED_C_FILE " .. util.c_line_filename(generated),
            "static const unsigned char generated_expected[] = {" .. bytes(generated) .. "};",
            "static const unsigned char source_expected[] = {" .. bytes(source) .. "};",
            "#line 1 TITAN_GENERATED_C_FILE",
            "static const char *generated_file(void) { return __FILE__; }",
            "#line 7 " .. util.c_line_filename(source),
            "static const char *source_file(void) { return __FILE__; }",
            "typedef char source_length_check[sizeof(__FILE__) == sizeof(source_expected) + 1 ? 1 : -1];",
            '#line 13 "probe.c"',
            "static int same(const char *actual, const unsigned char *expected, size_t size) {",
            "    return strlen(actual) == size && memcmp(actual, expected, size) == 0;",
            "}",
            "int main(void) {",
            "    if (!same(generated_file(), generated_expected, sizeof(generated_expected))) return 1;",
            "    if (!same(source_file(), source_expected, sizeof(source_expected))) return 2;",
            "    return 0;",
            "}",
            "",
        }, "\n")
        local workspace = assert(compiler_io.new_sync():tmpname())
        if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
        os.remove(workspace)
        assert.truthy(lfs.mkdir(workspace))
        local tested, test_error = xpcall(function()
            local probe = workspace .. "/probe.c"
            local executable = workspace .. "/probe" .. (platform.windows and ".exe" or "")
            assert.truthy(util.set_file_contents(probe, program, "wb"))
            local argv = assert(cdriver.split_shell_words(driver.CC))
            for _, word in ipairs({ "--std=c99", "-Wall", "-Werror", "-o", executable, probe }) do
                argv[#argv + 1] = word
            end
            local ok, output, why, status = run(argv)
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " .. tostring(status) .. ")")
            ok, output, why, status = run({ executable })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " .. tostring(status) .. ")")
        end, debug.traceback)
        remove_tree(workspace)
        if not tested then error(test_error, 0) end
    end)

    it("spells every generated line control with the shared filename literal", function()
        -- The same chunk name still reaches evaluated literals as `\044line`
        -- through c_string_literal; only line controls change spelling.
        local name = 'weird ??/ $line "q" 文.titan'
        h.reset()
        local ast, parse_err = h.parse(SOURCE, name)
        assert.truthy(ast, parse_err)
        local _, errors = checker.check(MODULE, ast, SOURCE, name)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local code = coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION).parts[1].code
        local spelled, named = util.c_line_filename(name), 0
        for directive in code:gmatch("#line [^\n]*") do
            local tail = directive:match("^#line %d+ (.*)$")
            assert.truthy(tail == "TITAN_GENERATED_C_FILE" or tail == spelled, directive)
            if tail == spelled then named = named + 1 end
        end
        assert.is_true(named > 0)
    end)
end)

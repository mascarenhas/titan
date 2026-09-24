local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"
local lfs = require "lfs"

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
        return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION)
    end
    return coder.generate(MODULE, ast, {}, driver.TITAN_ABI_VERSION, policy)
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

local prefix_lua = os.getenv("PREFIX") and
    (os.getenv("PREFIX") .. "/bin/lua") or nil
local LUA = prefix_lua and file_exists(prefix_lua) and prefix_lua or "lua"
local CHECKOUT_FIRST =
    [[package.path = "./?.lua;./?/init.lua;" .. package.path]]

local function run(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    local pipe = assert(io.popen(table.concat(quoted, " ") .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, status = pipe:close()
    return ok == true, output, why, status
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
    os.remove(MODULE .. ".so")
    os.remove(MODULE .. ".a")
    os.remove(MODULE .. ".lua")
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
        local probe = [[
package.path = "./?.lua;./?/init.lua;" .. package.path
io.write(tostring(require("titan-compiler.driver").EMIT_LINE_DIRECTIVES))
]]
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
        local workspace = os.tmpname()
        os.remove(workspace)
        assert.truthy(lfs.mkdir(workspace))
        local source = assert(io.open(workspace .. "/" .. FILENAME, "wb"))
        assert.truthy(source:write(SOURCE))
        assert.truthy(source:close())

        local tested, test_error = xpcall(function()
            ok, output, why, status = run({
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
                MODULE,
            })
            assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
                tostring(status) .. ")")
            local generated = assert(io.open(
                workspace .. "/" .. MODULE .. ".c", "rb"))
            local code = assert(generated:read("*a"))
            assert.truthy(generated:close())
            assert.is_false(has_line_directive(code))
        end, debug.traceback)

        remove_tree(workspace)
        clean_cli_artifacts()
        if not tested then error(test_error, 0) end
    end)
end)

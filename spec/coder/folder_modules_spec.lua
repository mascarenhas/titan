local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local TITANC = PREFIX .. "/bin/titanc"
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, cwd)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(cwd))
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    assert.truthy(lfs.chdir(previous))
    return ok == true, output, why, code
end

local function make_directory(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then make_directory(parent) end
    assert.truthy(lfs.mkdir(path), "could not create " .. path)
end

local function write_file(path, contents)
    make_directory(assert(path:match("^(.+)/[^/]+$")))
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

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
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

local function line_of(source, needle)
    local position = assert(source:find(needle, 1, true))
    local _, lines = source:sub(1, position - 1):gsub("\n", "\n")
    return lines + 1
end

local function escape_pattern(text)
    return (text:gsub("([^%w])", "%%%1"))
end

describe("folder modules through the public compiler", function()
    local workspace
    local source_root
    local module_folder
    local main_source
    local trace_source

    local function compile(modname)
        local argv = {
            "env",
            "-u", "LUA_PATH", "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
            "CCACHE_DISABLE=1",
            "TITAN_PATH_0_24=" .. workspace,
            "TITAN_PATH=",
        }
        if USE_CHECKOUT_COMPILER then
            table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
            table.insert(argv, "LUA_CPATH=" .. REPO .. "/?.so;;")
            table.insert(argv, LUA)
            table.insert(argv, "-e")
            table.insert(argv, string.format(
                "package.path=%q..package.path", REPO .. "/?.lua;" ..
                    REPO .. "/?/init.lua;"))
            table.insert(argv, REPO .. "/titanc")
        else
            table.insert(argv, TITANC)
        end
        table.insert(argv, "--tree")
        table.insert(argv, source_root)
        table.insert(argv, modname)
        local ok, output, why, code = run(argv, workspace)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        return output
    end

    setup(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/external-source"
        module_folder = source_root .. "/foldercase"
        make_directory(module_folder)

        write_file(source_root .. "/support.titan", [[
function offset(): integer
    return 2
end
]])
        write_file(module_folder .. "/probe.h", [[
enum { FOLDER_MODULE_PROBE = 3 };
]])

        main_source = [[
local total: integer = 0
local initial_box = Box.new(3)

function bump(delta: Delta): integer
    return contributor_bump(delta)
end

function read(): integer
    return total
end

function initial_box_value(): integer
    return initial_box.n
end

function through_extra(n: integer): integer
    return extra(n)
end

function through_interface(n: integer): integer
    local reader: Reader = Box.new(n)
    local read: () -> integer = reader:read
    return read()
end

function explode(): integer
    return contributor_explode()
end

do
    defer total = total + 0
    raise "expected during initialization"
catch
    total = initialize_total()
end
]]
        write_file(module_folder .. "/foldercase.titan", main_source)
        write_file(module_folder .. "/a.titan", [[
local support = import "support"
local probe = foreign import "probe.h"

local type Delta = integer

interface Reader
    function read(): integer
end

function Box.make(n: integer): Box
    return Box.new(n)
end

function Box:bump(delta: Delta): integer
    self.n = self.n + delta
    return contributor_bump(delta)
end

local function initialize_total(): integer
    return support.offset() + (probe.FOLDER_MODULE_PROBE as integer)
end

local function contributor_bump(delta: Delta): integer
    total = total + delta
    return total
end


record Box
    n: integer
end
]])
        -- This subdirectory and its Titan source must not contribute.
        write_file(module_folder .. "/nested/ignored.titan", [[
function must_not_exist(): integer
    return 99
end
]])
        write_file(module_folder .. "/generated.c", "/* ignored */\n")

        trace_source = [[local function extra(n: integer): integer
    return n
end

function Box:read(): integer
    return self.n
end

local function contributor_explode(): integer
    local fail: () -> integer = function(): integer
        raise "folder boom"
        return 0
    end
    return fail()
end
]]
        write_file(module_folder .. "/trace.titan", trace_source)

        compile("foldercase")

        write_file(source_root .. "/consumer.titan", [[
local folder = import "foldercase"

function update(delta: integer): integer
    return folder.bump(delta)
end

function bump_box(initial: integer, delta: integer): integer
    local box = folder.Box.make(initial)
    return box:bump(delta)
end
]])
        compile("consumer")
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("emits one logical library from main-stem C and object files", function()
        assert.equal("file", lfs.attributes(workspace .. "/foldercase.so",
            "mode"))
        assert.equal("file", lfs.attributes(
            module_folder .. "/foldercase.c", "mode"))
        assert.equal("file", lfs.attributes(
            module_folder .. "/foldercase.o", "mode"))
        for _, basename in ipairs({ "a", "trace", "ignored" }) do
            assert.is_nil(lfs.attributes(module_folder .. "/" .. basename ..
                ".c", "mode"))
            assert.is_nil(lfs.attributes(module_folder .. "/" .. basename ..
                ".o", "mode"))
            assert.is_nil(lfs.attributes(workspace .. "/foldercase/" ..
                basename .. ".so", "mode"))
        end

        local generated = read_file(module_folder .. "/foldercase.c")
        for _, filename in ipairs({
            module_folder .. "/foldercase.titan",
            module_folder .. "/a.titan",
            module_folder .. "/trace.titan",
        }) do
            assert.truthy(generated:match(
                '#line %d+ "' .. escape_pattern(filename) .. '"'), filename)
        end
        assert.truthy(generated:find("luaopen_foldercase", 1, true))
        assert.truthy(generated:find("foldercase_types", 1, true))
        assert.truthy(generated:find("foldercase_init", 1, true))
        assert.truthy(generated:find("Titan module foldercase", 1, true))
        assert.truthy(generated:find(
            "foldercase_\\u2133_Reader_\\u2131_read_interface_boundmethod", 1, true))
        assert.falsy(generated:find("foldercase_a_", 1, true))
        assert.falsy(generated:find("foldercase_trace_", 1, true))
        assert.falsy(generated:find("must_not_exist", 1, true))
        assert.truthy(generated:find(
            '#include "' .. module_folder .. '/probe.h"', 1, true))
    end)

    it("shares one API, module state, and cross-constituent Interface",
       function()
        local script = string.format([[
package.cpath = %q .. "/?.so;" .. package.cpath
local folder = require "foldercase"
local consumer = require "consumer"
assert(type(folder) == "userdata")
assert(folder.read() == 5)
assert(folder.initial_box_value() == 3)
assert(folder.bump(2) == 7)
local box = folder.Box.make(10)
assert(box:bump(3) == 10)
assert(box.n == 13)
assert(consumer.update(4) == 14)
assert(folder.read() == 14)
assert(consumer.bump_box(8, 2) == 16)
assert(folder.read() == 16)
assert(folder.through_extra(37) == 37)
assert(folder.through_interface(42) == 42)
print("OK")
]], workspace)
        local ok, output = run({ LUA, "-e", script }, workspace)
        assert.truthy(ok, output)
        assert.equal("OK\n", output)
    end)

    it("attributes cross-file native and anonymous frames exactly", function()
        local trace_file = module_folder .. "/trace.titan"
        local main_call = line_of(main_source, "return contributor_explode()")
        local lambda_definition = line_of(trace_source,
            "local fail: () -> integer = function(): integer")
        local lambda_raise = line_of(trace_source, 'raise "folder boom"')
        local lambda_call = line_of(trace_source, "return fail()")
        local script = string.format([==[
package.cpath = %q .. "/?.so;" .. package.cpath
local titan = require "titan"
local folder = require "foldercase"
assert(not pcall(folder.explode))
local trace = titan.backtrace()
assert(trace:find(%q), trace)
assert(trace:find(%q), trace)
assert(trace:find(%q), trace)
assert(not trace:find("foldercase%%.c:"), trace)
print("OK")
]==], workspace,
            escape_pattern("trace.titan:" .. lambda_raise ..
                ": in anonymous function at " .. trace_file .. ":" ..
                lambda_definition),
            escape_pattern("trace.titan:" .. lambda_call ..
                ": in foldercase.contributor_explode"),
            escape_pattern("foldercase.titan:" .. main_call ..
                ": in foldercase.explode"))
        local ok, output = run({ LUA, "-e", script }, workspace)
        assert.truthy(ok, output)
        assert.equal("OK\n", output)
    end)

    it("creates logical output parents for an external dotted folder library",
       function()
        local folder = source_root .. "/packages/dotted"
        write_file(folder .. "/dotted.titan", [[
function answer(): integer
    return contributor_answer()
end
]])
        write_file(folder .. "/part.titan", [[
local function contributor_answer(): integer
    return 42
end
]])

        compile("packages.dotted")
        assert.equal("directory", lfs.attributes(
            workspace .. "/packages", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/packages/dotted.so", "mode"))
        assert.equal("file", lfs.attributes(folder .. "/dotted.c", "mode"))
        assert.equal("file", lfs.attributes(folder .. "/dotted.o", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/part.c", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/part.o", "mode"))

        local script = string.format([[
package.cpath = %q .. "/?.so;" .. package.cpath
local dotted = require "packages.dotted"
assert(dotted.answer() == 42)
]], workspace)
        local ok, output = run({ LUA, "-e", script }, workspace)
        assert.truthy(ok, output)
    end)

    it("uses a collision-free executable for a folder main", function()
        local folder = source_root .. "/programs/folderapp"
        write_file(folder .. "/folderapp.titan", [[
local function exit_code(): integer
    return contributor_exit_code()
end
]])
        write_file(folder .. "/program.titan", [[
local function contributor_exit_code(): integer
    return 17
end

function main(args: {string}): integer
    return exit_code()
end
]])

        compile("programs.folderapp")
        assert.equal("file", lfs.attributes(
            workspace .. "/programs/folderapp__main", "mode"))
        assert.equal("directory", lfs.attributes(
            workspace .. "/programs", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/programs/folderapp", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/programs/folderapp__entrypoint.c", "mode"))
        assert.equal("file", lfs.attributes(
            folder .. "/folderapp.c", "mode"))
        assert.equal("file", lfs.attributes(
            folder .. "/folderapp.o", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/program.c", "mode"))

        local ok, output, why, code = run({
            workspace .. "/programs/folderapp__main",
        }, workspace)
        assert.falsy(ok)
        assert.equal("exit", why)
        assert.equal(17, code)
        assert.equal("", output)
    end)

    it("leaves flat library and program artifact paths unchanged", function()
        write_file(source_root .. "/flatlib.titan", [[
function answer(): integer
    return 11
end
]])
        compile("flatlib")
        assert.equal("file", lfs.attributes(workspace .. "/flatlib.so",
            "mode"))
        assert.equal("file", lfs.attributes(source_root .. "/flatlib.c",
            "mode"))
        assert.equal("file", lfs.attributes(source_root .. "/flatlib.o",
            "mode"))

        write_file(source_root .. "/flatapp.titan", [[
function main(args: {string}): integer
    return 19
end
]])
        compile("flatapp")
        assert.equal("file", lfs.attributes(workspace .. "/flatapp", "mode"))
        assert.equal("file", lfs.attributes(
            workspace .. "/flatapp__entrypoint.c", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/flatapp__main", "mode"))
        local ok, output, why, code = run({ workspace .. "/flatapp" },
            workspace)
        assert.falsy(ok)
        assert.equal("exit", why)
        assert.equal(19, code)
        assert.equal("", output)
    end)
end)

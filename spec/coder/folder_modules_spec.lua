local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"

local REPO = assert(lfs.currentdir())
if platform.windows then REPO = assert(platform.path.normalize(REPO)) end
local PREFIX = require("spec.support.installed_prefix").active()
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local LUA = PREFIX .. "/bin/lua" .. (platform.windows and ".exe" or "")
local INSTALLED_TITANC = PREFIX .. (platform.windows and
    "/lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" or "/bin/titanc")
local TITANC = INSTALLED_TITANC
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

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

local function program_path(workspace, modname, unix_relative)
    return workspace .. "/" .. (platform.windows and
        assert(driver.windows_program_paths(modname)).executable or unix_relative)
end

local function run_program(workspace, modname, unix_relative)
    local provider_root = platform.windows and
        workspace .. "/lib/titan/0.6" or workspace
    return run({ "env", "PATH=" .. PREFIX .. "/bin" ..
        (platform.windows and ";" or ":") .. (os.getenv("PATH") or "/usr/bin:/bin"),
        "TITAN_PATH_0_6=" .. provider_root .. ";" .. PREFIX .. "/lib/titan/0.6",
        program_path(workspace, modname, unix_relative) }, workspace)
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

local function synthetic_file(output_root, basename)
    local found
    local links = output_root .. "/.titan-links"
    for key in lfs.dir(links) do
        if #key == 64 and key:match("^[0-9a-f]+$") then
            local filename = links .. "/" .. key .. "/synthetic/" .. basename
            if lfs.attributes(filename, "mode") == "file" then
                assert.is_nil(found, basename)
                found = filename
            end
        end
    end
    assert.truthy(found, "missing target-private synthetic file: " .. basename)
    return found
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
            "TITAN_PATH_0_6=" .. workspace,
            "TITAN_PATH=",
            "PATH=" .. PREFIX .. "/bin" .. (platform.windows and ";" or ":") ..
                (os.getenv("PATH") or "/usr/bin:/bin"),
        }
        if USE_CHECKOUT_COMPILER then
            table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
            table.insert(argv, "LUA_CPATH=" .. REPO .. "/?" .. SHARED_SUFFIX .. ";;")
            table.insert(argv, LUA)
            table.insert(argv, "-e")
            table.insert(argv, string.format(
                "package.path=%q..package.path", REPO .. "/?.lua;" ..
                    REPO .. "/?/init.lua;"))
            table.insert(argv, REPO .. "/titanc")
        else
            if platform.windows then table.insert(argv, LUA) end
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
        workspace = temporary_workspace()
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

function settled_total(): integer
    return settled
end

function initial_box_value(): integer
    return initial_box.n
end

function through_extra(n: integer): integer
    return extra(n)
end

function through_interface(n: integer): integer
    local reader: Reader = Box.new(n)
    local read: function (): integer = reader:read
    return read()
end

function explode(): integer
    return contributor_explode()
end

do
    defer total = total + 0
    raise "expected during initialization"
catch
    settled = initialize_total()
    total = settled
end
]]
        write_file(module_folder .. "/foldercase.titan", main_source)
        write_file(module_folder .. "/a.titan", [[
local support = import "support"
foreign import "probe.h"

local type Delta = integer

const settled: integer?

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
    return support.offset() + (ffi.FOLDER_MODULE_PROBE as integer)
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
    local fail: function (): integer = function(): integer
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
        assert.equal("file", lfs.attributes(shared_path(workspace, "foldercase"),
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
                basename .. SHARED_SUFFIX, "mode"))
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
            '#include "' .. module_folder .. '/foldercase.ffi.h"', 1, true))
        assert.truthy(read_file(module_folder .. "/foldercase.ffi.h"):find(
            '#include "' .. module_folder .. '/probe.h"', 1, true))
    end)

    it("shares one API, module state, and cross-constituent Interface",
       function()
        local script = string.format([[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local folder = require "foldercase"
local consumer = require "consumer"
assert(type(folder) == "userdata")
assert(folder.read() == 5)
assert(folder.settled == 5 and folder.settled_total() == 5)
assert(not pcall(function() folder.settled = 6 end))
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
]], workspace, SHARED_SUFFIX)
        -- The consumer provider resolves its foldercase dependency through
        -- the runtime Titan path, so name the publication root explicitly.
        local ok, output = run({ "env", "TITAN_PATH_0_6=" .. workspace .. ";;",
            LUA, "-e", script }, workspace)
        assert.truthy(ok, output)
        assert.equal("OK\n", output)
    end)

    it("attributes cross-file native and anonymous frames exactly", function()
        local trace_file = module_folder .. "/trace.titan"
        local main_call = line_of(main_source, "return contributor_explode()")
        local lambda_definition = line_of(trace_source,
            "local fail: function (): integer = function(): integer")
        local lambda_raise = line_of(trace_source, 'raise "folder boom"')
        local lambda_call = line_of(trace_source, "return fail()")
        local script = string.format([==[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local titan = require "titan"
local folder = require "foldercase"
assert(not pcall(folder.explode))
local trace = titan.backtrace()
assert(trace:find(%q), trace)
assert(trace:find(%q), trace)
assert(trace:find(%q), trace)
assert(not trace:find("foldercase%%.c:"), trace)
print("OK")
]==], workspace, SHARED_SUFFIX,
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
            shared_path(workspace, "packages/dotted"), "mode"))
        assert.equal("file", lfs.attributes(folder .. "/dotted.c", "mode"))
        assert.equal("file", lfs.attributes(folder .. "/dotted.o", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/part.c", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/part.o", "mode"))

        local script = string.format([[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local dotted = require "packages.dotted"
assert(dotted.answer() == 42)
]], workspace, SHARED_SUFFIX)
        local ok, output = run({ LUA, "-e", script }, workspace)
        assert.truthy(ok, output)
    end)

    it("shares one custom record constructor across distinct contributors", function()
        local folder = source_root .. "/customparts"
        write_file(folder .. "/customparts.titan", [[
calls: integer = 0

function from_main(): integer
    return Box(1).value
end

function constructor_from_main(): function(integer): Box
    return Box.new
end
]])
        write_file(folder .. "/a-record.titan", [[
record Box
    local value: integer
end

function Box:read(): integer
    return self.value
end
]])
        write_file(folder .. "/b-constructor.titan", [[
function Box.new(input: integer): Box
    calls = calls + 1
    return {value = input + 10}
end
]])
        write_file(folder .. "/c-caller.titan", [[
function from_contributor(): integer
    return Box{input = 2}.value
end

function constructor_from_contributor(): function(integer): Box
    return Box.new
end
]])

        compile("customparts")
        for _, basename in ipairs({"a-record", "b-constructor", "c-caller"}) do
            assert.is_nil(lfs.attributes(folder .. "/" .. basename .. ".c"))
            assert.is_nil(lfs.attributes(folder .. "/" .. basename .. ".o"))
        end
        local script = string.format([[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local folder = require "customparts"
assert(folder.calls == 0)
assert(folder.from_main() == 11)
assert(folder.from_contributor() == 12)
assert(folder.Box(3):read() == 13)
assert(folder.calls == 3)
local constructor = folder.constructor_from_main()
assert(constructor == folder.constructor_from_contributor())
assert(constructor == folder.Box.new)
assert(constructor(4):read() == 14 and folder.calls == 4)
]], workspace, SHARED_SUFFIX)
        local ok, output = run({LUA, "-e", script}, workspace)
        assert.truthy(ok, output)
    end)

    for _, mode in ipairs({"dynamic", "static"}) do
        it("imports arbitrary custom constructor results from a " .. mode .. " provider", function()
            if platform.windows and mode == "static" then
                pending("Titan static-provider archives are unsupported on Windows")
                return
            end
            local provider = "factory_api_" .. mode
            local consumer = "factory_client_" .. mode
            local provider_source = source_root .. "/" .. provider .. ".titan"
            write_file(provider_source, [[
record Factory
    unused: integer
end

function Factory.new(text: string): (integer, string?, string)
    return #text, nil, text
end

type Alias = Factory
]])
            compile(provider)
            assert.truthy(os.remove(provider_source))
            local unselected = workspace .. "/" .. provider ..
                (mode == "dynamic" and ".a" or SHARED_SUFFIX)
            if not platform.windows then assert.truthy(os.remove(unselected)) end
            assert.is_nil(lfs.attributes(provider_source))
            assert.is_nil(lfs.attributes(unselected))
            write_file(source_root .. "/" .. consumer .. ".titan", string.format([[
local provider = import %q

function positional(): (integer, string?, string)
    return provider.Factory("positional")
end

function named(): (integer, string?, string)
    return provider.Alias{text = "named"}
end

function string_argument(): (integer, string?, string)
    return provider.Factory "string"
end
]], provider))
            compile(consumer)
            local script = string.format([[
package.cpath = %q .. "/?" .. %q .. ";" .. package.cpath
local consumer = require %q
for name, expected in pairs({positional = "positional", named = "named", string_argument = "string"}) do
    local results = table.pack(consumer[name]())
    assert(results.n == 3)
    assert(results[1] == #expected and results[2] == nil and results[3] == expected)
end
]], workspace, SHARED_SUFFIX, consumer)
            -- The consumer provider resolves its imported provider through
            -- the runtime Titan path, so name that root explicitly.
            local ok, output = run({ "env", "TITAN_PATH_0_6=" .. workspace .. ";;",
                LUA, "-e", script }, workspace)
            assert.truthy(ok, output)
        end)
    end

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
            program_path(workspace, "programs.folderapp", "programs/folderapp__main"), "mode"))
        if platform.windows then
            assert.equal("file", lfs.attributes(workspace .. "/" ..
                assert(driver.windows_program_paths("programs.folderapp")).provider, "mode"))
            assert.is_nil(lfs.attributes(workspace .. "/programs/folderapp__main", "mode"))
        else
            assert.equal("directory", lfs.attributes(
                workspace .. "/programs", "mode"))
            assert.is_nil(lfs.attributes(
                workspace .. "/programs/folderapp", "mode"))
        end
        assert.equal("file", lfs.attributes(
            synthetic_file(source_root, "folderapp__entrypoint.c"), "mode"))
        assert.equal("file", lfs.attributes(
            folder .. "/folderapp.c", "mode"))
        assert.equal("file", lfs.attributes(
            folder .. "/folderapp.o", "mode"))
        assert.is_nil(lfs.attributes(folder .. "/program.c", "mode"))

        local ok, output, why, code = run_program(workspace,
            "programs.folderapp", "programs/folderapp__main")
        assert.falsy(ok)
        assert.equal("exit", why)
        assert.equal(17, code, output)
        assert.equal("", output)
    end)

    it("keeps flat module outputs and moves program intermediates into the target namespace", function()
        write_file(source_root .. "/flatlib.titan", [[
function answer(): integer
    return 11
end
]])
        compile("flatlib")
        assert.equal("file", lfs.attributes(shared_path(workspace, "flatlib"),
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
        assert.equal("file", lfs.attributes(
            program_path(workspace, "flatapp", "flatapp"), "mode"))
        if platform.windows then
            assert.equal("file", lfs.attributes(workspace .. "/" ..
                assert(driver.windows_program_paths("flatapp")).provider, "mode"))
            assert.is_nil(lfs.attributes(workspace .. "/flatapp", "mode"))
        end
        assert.equal("file", lfs.attributes(
            synthetic_file(source_root, "flatapp__entrypoint.c"), "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/flatapp__main", "mode"))
        local ok, output, why, code = run_program(workspace, "flatapp", "flatapp")
        assert.falsy(ok)
        assert.equal("exit", why)
        assert.equal(19, code, output)
        assert.equal("", output)
    end)
end)

local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"
local DEPTH_PROBE = require("spec.support.helpers").DEPTH_PROBE

local REPO = path.normalize(assert(lfs.currentdir()))
local PREFIX = require("spec.support.installed_prefix").active()
local SHARED_SUFFIX = platform.windows and ".dll" or ".so"
local LUA = path.join(PREFIX, "bin", "lua" .. (platform.windows and ".exe" or ""))
local INSTALLED_TITANC = path.join(PREFIX, platform.windows and
    "lib/luarocks/rocks-5.5/titan/0.6.0-1/bin/titanc" or "bin/titanc")

local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
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
    local workspace = assert(compiler_io.new_sync():tmpname())
    assert.truthy(os.remove(workspace))
    assert.truthy(lfs.mkdir(workspace))
    return path.normalize(workspace)
end

local function shared_path(workspace, stem)
    return path.join(workspace, stem .. SHARED_SUFFIX)
end

local function make_directory(directory)
    if lfs.attributes(directory, "mode") == "directory" then return end
    local parent = path.dirname(directory)
    if parent ~= directory then make_directory(parent) end
    assert.truthy(lfs.mkdir(directory), "could not create " .. directory)
end

local function write_file(filename, contents)
    make_directory(path.dirname(filename))
    local file = assert(io.open(filename, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function remove_tree(directory)
    local mode = lfs.symlinkattributes(directory, "mode")
    if mode == "directory" then
        for name in lfs.dir(directory) do
            if name ~= "." and name ~= ".." then
                remove_tree(path.join(directory, name))
            end
        end
        assert.truthy(lfs.rmdir(directory))
    elseif mode then
        assert.truthy(os.remove(directory))
    end
end

local function compiler_argv(output_root, source_root, titan_path, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_6=" .. titan_path,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. path.join(PREFIX, "bin") .. (platform.windows and ";" or ":") ..
            (os.getenv("PATH") or "/usr/bin:/bin"))
    end

    local installed = not USE_CHECKOUT_COMPILER and
        PREFIX and exists(INSTALLED_TITANC)
    if installed then
        if platform.windows then table.insert(argv, LUA) end
        table.insert(argv, INSTALLED_TITANC)
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
        table.insert(argv, "LUA_CPATH=" .. path.to_slash(path.join(REPO, "?" .. SHARED_SUFFIX)) .. ";;")
        table.insert(argv, LUA)
        table.insert(argv, "-e")
        table.insert(argv, string.format(
            "package.path=%q..package.path", path.to_slash(path.join(REPO, "?.lua")) .. ";" ..
                path.to_slash(path.join(REPO, "?/init.lua")) .. ";"))
        table.insert(argv, path.join(REPO, "titanc"))
    end

    table.insert(argv, "--tree")
    table.insert(argv, source_root)
    for _, argument in ipairs({ ... }) do table.insert(argv, argument) end
    return argv
end

local function compile(output_root, source_root, titan_path, ...)
    return run(compiler_argv(
        output_root, source_root, titan_path, ...), output_root)
end

local function assert_compiles(output_root, source_root, titan_path, ...)
    local ok, output, why, code = compile(
        output_root, source_root, titan_path, ...)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
end

local function run_lua(cwd, titan_path, package_path, cpath_roots, code)
    assert.truthy(PREFIX,
        "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
    local cpath = {}
    for _, root in ipairs(cpath_roots) do
        table.insert(cpath, path.to_slash(path.join(root, "?" .. SHARED_SUFFIX)))
    end
    table.insert(cpath, path.to_slash(path.join(PREFIX, "lib/titan/0.6", "?" .. SHARED_SUFFIX)))
    table.insert(cpath, path.to_slash(path.join(PREFIX, "lib/lua/5.5", "?" .. SHARED_SUFFIX)))

    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "TITAN_PATH_0_6=" .. titan_path,
        "TITAN_PATH=",
        LUA, "-e", string.format([[
package.path = %q
package.cpath = %q
%s
]], path.to_slash(path.join(package_path, "?.lua")), table.concat(cpath, ";"), code),
    }, cwd)
end

describe("compiled-provider selection across Titan path roots", function()
    local workspace
    local root_one
    local root_two
    local consumer_root
    local source_one
    local source_two
    local consumer_source
    local titan_path

    setup(function()
        workspace = temporary_workspace()

        root_one = path.join(workspace, "R1")
        root_two = path.join(workspace, "R2")
        consumer_root = path.join(workspace, "consumer")
        source_one = path.join(workspace, "source-one")
        source_two = path.join(workspace, "source-two")
        consumer_source = path.join(workspace, "consumer-source")
        for _, directory in ipairs({
            root_one, root_two, consumer_root,
            source_one, source_two, consumer_source,
        }) do
            make_directory(directory)
        end
        titan_path = root_one .. ";;" .. root_two

        write_file(path.join(source_one, "route/item.titan"), [[
function origin(): integer
    return 101
end

function root_one_only(): integer
    return 11
end
]])
        write_file(path.join(source_two, "route/item.titan"), [[
function origin(): integer
    return 202
end

function root_two_only(): integer
    return 22
end
]])

        assert_compiles(root_one, source_one, root_one, "route.item")
        assert_compiles(root_two, source_two, root_two, "route.item")

        write_file(path.join(consumer_source, "path_consumer.titan"), [[
local item = import "route.item"

function answer(): integer
    return item.origin() + item.root_one_only()
end
]])
        assert_compiles(consumer_root, consumer_source, titan_path,
            "path_consumer")
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("uses the earlier exact provider for checking and Titan imports",
       function()
        assert.equal("file", lfs.attributes(
            shared_path(root_one, "route/item"), "mode"))
        assert.equal("file", lfs.attributes(
            shared_path(root_two, "route/item"), "mode"))

        local generated = read_file(
            path.join(consumer_source, "path_consumer.c"))
        assert.truthy(generated:find(
            'titan_module_provider(L, "route.item", "route/item' .. SHARED_SUFFIX .. '")', 1, true), generated)
        assert.falsy(generated:find(root_one, 1, true), generated)
        assert.falsy(generated:find(root_two, 1, true), generated)
        -- root_one_only exists only in R1, so successful checking proves that
        -- the compiler selected R1 before emitting this native call.
        assert.truthy(generated:find(
            "route_item_\\u2133_root_one_only_titan", 1, true), generated)

        local ok, output = run_lua(
            consumer_root, titan_path, consumer_root, { consumer_root }, [[
local consumer = require "path_consumer"
assert(consumer.answer() == 112)
]])
        assert.truthy(ok, output)
    end)

    it("lets generated shims follow package.cpath precedence independently",
       function()
        local aligned_path = root_one .. ";;" .. root_two
        local ok, output = run_lua(
            workspace, aligned_path, root_one, { root_one, root_two },
            string.format([[
local found = assert(package.searchpath("route.item", package.cpath))
local expected = %q
if package.config:sub(1, 1) == "\\" then
    local filesystem = require "titan"
    assert(assert(filesystem._win_realpath(found)):lower() ==
        assert(filesystem._win_realpath(expected)):lower())
else
    assert(found == expected)
end
local item = require "route.item"
assert(item.origin() == 101)
assert(item.root_one_only() == 11)
]], shared_path(root_one, "route/item")))
        assert.truthy(ok, output)

        -- The Lua shim comes from R1 in both processes. Reversing only C-path
        -- order therefore demonstrates physical Lua-provider precedence, not
        -- fallback through the Titan import path.
        ok, output = run_lua(
            workspace, aligned_path, root_one, { root_two, root_one },
            string.format([[
local found = assert(package.searchpath("route.item", package.cpath))
local expected = %q
if package.config:sub(1, 1) == "\\" then
    local filesystem = require "titan"
    assert(assert(filesystem._win_realpath(found)):lower() ==
        assert(filesystem._win_realpath(expected)):lower())
else
    assert(found == expected)
end
local item = require "route.item"
assert(item.origin() == 202)
assert(item.root_two_only() == 22)
]], shared_path(root_two, "route/item")))
        assert.truthy(ok, output)
    end)

    it("selects one shallower provider from a later Titan path root",
       function()
        write_file(path.join(source_two, "later/branch/item.titan"), [[
function answer(): integer
    return 303
end
]])
        write_file(path.join(source_two, "later/peer.titan"), [[
function marker(): integer
    return 404
end
]])
        assert_compiles(root_two, source_two, root_two,
            "later.branch.item", "later.peer")
        assert.equal("file", lfs.attributes(shared_path(root_two, "later"), "mode"))
        assert.is_nil(lfs.attributes(
            shared_path(root_two, "later/branch/item"), "mode"))

        write_file(path.join(consumer_source, "later_consumer.titan"), [[
local item = import "later.branch.item"

function answer(): integer
    return item.answer()
end
]])
        assert_compiles(consumer_root, consumer_source, titan_path,
            "later_consumer")

        local generated = read_file(
            path.join(consumer_source, "later_consumer.c"))
        assert.truthy(generated:find(
            'titan_module_provider(L, "later.branch.item", "later' .. SHARED_SUFFIX .. '")', 1, true), generated)
        assert.falsy(generated:find(
            'titan_module_provider(L, "later.branch.item", "later/branch/item' .. SHARED_SUFFIX .. '")', 1, true), generated)

        local ok, output = run_lua(
            consumer_root, titan_path, consumer_root, { consumer_root }, [[
local consumer = require "later_consumer"
assert(consumer.answer() == 303)
]])
        assert.truthy(ok, output)
    end)

    it("shares dense arrays through a selected provider", function()
        write_file(path.join(source_one, "staticarray/api.titan"), [[
function make(): {integer}
    return {10, 20, 30}
end

function set(xs: {value}, i: integer, v: value)
    xs[i] = v
end

function echo(xs: {value}): {value}
    return xs
end
]])
        assert_compiles(root_one, source_one, root_one, "staticarray.api")
        if platform.windows then
            assert.is_nil(lfs.attributes(path.join(root_one, "staticarray/api.a"), "mode"))
        else
            assert.equal("file", lfs.attributes(path.join(root_one, "staticarray/api.a"), "mode"))
        end

        write_file(path.join(consumer_source, "static_array_consumer.titan"), [[
local api = import "staticarray.api"

function roundtrip(): {value}
    local xs = api.make()
    api.set(xs, 5, 50)
    return api.echo(xs)
end
]])
        local arguments = platform.windows and { "static_array_consumer" } or
            { "--static", "static_array_consumer" }
        assert_compiles(consumer_root, consumer_source, root_one, table.unpack(arguments))

        local generated = read_file(
            path.join(consumer_source, "static_array_consumer.c"))
        if platform.windows then
            assert.truthy(generated:find(
                'titan_module_provider(L, "staticarray.api", "staticarray/api.dll")', 1, true), generated)
        else
            assert.falsy(generated:find(
                'titan_module_provider(L, "staticarray.api", "staticarray/api.so")', 1, true), generated)
            assert.truthy(generated:find(
                "extern Udata *staticarray_api_init", 1, true), generated)
        end

        local ok, output = run_lua(
            consumer_root, root_one, consumer_root, { consumer_root }, [[
local consumer = require "static_array_consumer"
local xs = consumer.roundtrip()
assert(type(xs) == "userdata")
assert(#xs == 5)
assert(xs[1] == 10 and xs[2] == 20 and xs[3] == 30)
assert(xs[4] == nil and xs[5] == 50)

-- The integer writer constructed inside the selected archive survives the
-- provider/consumer boundary and the consumer's {value} return view.
xs[6] = 60.0
assert(math.type(xs[6]) == "integer" and xs[6] == 60,
    ("type=%s value=%s"):format(
        tostring(math.type(xs[6])), tostring(xs[6])))
local write_ok, write_err = pcall(function() xs[7] = "wrong" end)
assert(not write_ok, "invalid string write unexpectedly succeeded")
assert(tostring(write_err):find(
    "expected integer", 1, true), tostring(write_err))
assert(#xs == 6 and xs[7] == nil)
]])
        assert.truthy(ok, output)
    end)

    it("uses native and strict entries from a selected provider",
       function()
        write_file(path.join(source_one, "staticentry/api.titan"), [[
function probe(p: function (): integer): integer
    return p()
end

function boundary(x: integer): value
    if x == 3 then
        return 2.0
    end
    return x
end
]])
        assert_compiles(root_one, source_one, root_one, "staticentry.api")
        if platform.windows then
            assert.is_nil(lfs.attributes(path.join(root_one, "staticentry/api.a"), "mode"))
        else
            assert.equal("file", lfs.attributes(path.join(root_one, "staticentry/api.a"), "mode"))
        end

        write_file(path.join(consumer_source, "static_entry_consumer.titan"), [[
local provider = import "staticentry.api"

function direct_depth(p: function (): integer): integer
    return provider.probe(p)
end

function exact_depth(p: function (): integer): integer
    local f: function (function (): integer): integer = provider.probe
    return f(p)
end

function strict_result(): integer
    local f: function (integer): integer = provider.boundary
    return f(3)
end

function strict_argument(x: value): value
    local f: function (value): value = provider.boundary
    return f(x)
end

function boundary_function(): function (integer): value
    return provider.boundary
end
]])
        local arguments = platform.windows and { "static_entry_consumer" } or
            { "--static", "static_entry_consumer" }
        assert_compiles(consumer_root, consumer_source, root_one, table.unpack(arguments))

        local generated = read_file(
            path.join(consumer_source, "static_entry_consumer.c"))
        if platform.windows then
            assert.truthy(generated:find(
                'titan_module_provider(L, "staticentry.api", "staticentry/api.dll")', 1, true), generated)
        else
            assert.falsy(generated:find(
                'titan_module_provider(L, "staticentry.api", "staticentry/api.so")', 1, true), generated)
            assert.truthy(generated:find(
                "extern Udata *staticentry_api_init", 1, true), generated)
        end

        local ok, output = run_lua(
            consumer_root, root_one, consumer_root, { consumer_root },
            DEPTH_PROBE .. [[
local consumer = require "static_entry_consumer"

-- A direct static call and an exact-tag first-class call both use the
-- provider's native entry, so neither adds a Lua stack-entry frame.
local direct_depth = consumer.direct_depth(depth)
local exact_depth = consumer.exact_depth(depth)
assert(direct_depth == exact_depth,
    ("direct=%s exact=%s"):format(direct_depth, exact_depth))

-- Repeated access returns the same canonical provider closure. From Lua its
-- ordinary CClosure.f entry converts 2.0 for the integer formal, which is
-- visible in the declared value result.
local boundary = consumer.boundary_function()
assert(boundary == consumer.boundary_function())
assert(math.type(boundary(2.0)) == "integer")
assert(boundary(2.0) == 2)

-- Titan's non-exact views of those same branded closures take the strict
-- trailer and reject the float tag instead of coercing it.
local result_ok, result_err = pcall(consumer.strict_result)
assert(not result_ok, tostring(result_err))
assert(tostring(result_err):find(
    "expected integer", 1, true), tostring(result_err))

local argument_ok, argument_err =
    pcall(consumer.strict_argument, 2.0)
assert(not argument_ok, tostring(argument_err))
assert(tostring(argument_err):find(
    "expected integer", 1, true), tostring(argument_err))
]])
        assert.truthy(ok, output)
    end)

    it("keeps union closure slots symmetric through a prefix provider",
       function()
        write_file(path.join(source_one, "prefix/messages.titan"), [[
record Delta
    x: float
    y: float
end

union Message
    quit()
    local hidden(integer)
    move(Delta)
end

function Message:total(): float
    case self
    when move(delta) then
        return delta.x + delta.y
    when quit() then
        return 0.0
    else
        return -1.0
    end
end

function hidden_message(): Message
    return Message.hidden(77)
end
]])
        write_file(path.join(source_one, "prefix/peer.titan"), [[
function marker(): integer
    return 19
end
]])
        assert_compiles(root_one, source_one, root_one,
            "prefix.messages", "prefix.peer")
        if platform.windows then
            assert.is_nil(lfs.attributes(path.join(root_one, "prefix.a"), "mode"))
        else
            assert.equal("file", lfs.attributes(path.join(root_one, "prefix.a"), "mode"))
        end
        assert.equal("file", lfs.attributes(shared_path(root_one, "prefix"), "mode"))
        assert.is_nil(lfs.attributes(
            path.join(root_one, "prefix/messages.a"), "mode"))

        write_file(path.join(consumer_source, "prefix_union_consumer.titan"), [[
local m = import "prefix.messages"
local moved = m.Message.move({ x = 1.0, y = 2.0 })

function total(): float
    local make: function (m.Delta): m.Message = m.Message.move
    local another = make({ x = 20.0, y = 22.0 })
    return moved:total() + another:total()
end

function same(): boolean
    return m.Message.move == m.Message.move
end

function bound(): float
    local read: function (): float = moved:total
    return read()
end

function hidden_else(): integer
    case m.hidden_message()
    when quit() then
        return 0
    when move(delta) then
        return 1
    else
        return 77
    end
end
]])
        local arguments = platform.windows and { "prefix_union_consumer" } or
            { "--static", "prefix_union_consumer" }
        assert_compiles(consumer_root, consumer_source, root_one, table.unpack(arguments))

        local generated = read_file(
            path.join(consumer_source, "prefix_union_consumer.c"))
        if platform.windows then
            assert.truthy(generated:find(
                'titan_module_provider(L, "prefix.messages", "prefix.dll")', 1, true), generated)
        else
            assert.falsy(generated:find(
                'titan_module_provider(L, "prefix.messages", "prefix.so")', 1, true), generated)
            assert.truthy(generated:find(
                "extern Udata *prefix_messages_init", 1, true), generated)
        end
        assert.truthy(generated:find(
            "case%s+1:%s+goto%s+_case_"), generated)

        local ok, output = run_lua(
            consumer_root, root_one, consumer_root, { consumer_root }, [[
local consumer = require "prefix_union_consumer"
assert(consumer.total() == 45.0)
assert(consumer.same())
assert(consumer.bound() == 3.0)
assert(consumer.hidden_else() == 77)
]])
        assert.truthy(ok, output)
    end)
end)

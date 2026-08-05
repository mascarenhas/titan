local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"
local DEPTH_PROBE = require("spec.support.helpers").DEPTH_PROBE

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"

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

local function compiler_argv(output_root, source_root, titan_path, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_18=/obsolete/titan-0.18",
        "TITAN_PATH_0_21=" .. titan_path,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin")
    end

    local installed = PREFIX and exists(PREFIX .. "/bin/titanc")
    if installed then
        table.insert(argv, PREFIX .. "/bin/titanc")
    else
        assert.truthy(PREFIX,
            "set PREFIX or TITAN_TEST_PREFIX for native compiler tests")
        table.insert(argv, "TITAN_ROCKS_ROOT=" .. PREFIX)
        table.insert(argv, "LUA_CPATH=" .. REPO .. "/?.so;;")
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
        table.insert(cpath, root .. "/?.so")
    end
    table.insert(cpath, PREFIX .. "/lib/titan/0.21/?.so")
    table.insert(cpath, PREFIX .. "/lib/lua/5.5/?.so")

    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "TITAN_PATH_0_18=/obsolete/titan-0.18",
        "TITAN_PATH_0_21=" .. titan_path,
        "TITAN_PATH=",
        LUA, "-e", string.format([[
package.path = %q
package.cpath = %q
%s
]], package_path .. "/?.lua", table.concat(cpath, ";"), code),
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
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))

        root_one = workspace .. "/R1"
        root_two = workspace .. "/R2"
        consumer_root = workspace .. "/consumer"
        source_one = workspace .. "/source-one"
        source_two = workspace .. "/source-two"
        consumer_source = workspace .. "/consumer-source"
        for _, directory in ipairs({
            root_one, root_two, consumer_root,
            source_one, source_two, consumer_source,
        }) do
            make_directory(directory)
        end
        titan_path = root_one .. ";;" .. root_two

        write_file(source_one .. "/route/item.titan", [[
function origin(): integer
    return 101
end

function root_one_only(): integer
    return 11
end
]])
        write_file(source_two .. "/route/item.titan", [[
function origin(): integer
    return 202
end

function root_two_only(): integer
    return 22
end
]])

        assert_compiles(root_one, source_one, root_one, "route.item")
        assert_compiles(root_two, source_two, root_two, "route.item")

        write_file(consumer_source .. "/path_consumer.titan", [[
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
            root_one .. "/route/item.so", "mode"))
        assert.equal("file", lfs.attributes(
            root_two .. "/route/item.so", "mode"))

        local generated = read_file(
            consumer_source .. "/path_consumer.c")
        assert.truthy(generated:find(
            'loadlib(L, "route/item.so")', 1, true), generated)
        assert.falsy(generated:find(root_one, 1, true), generated)
        assert.falsy(generated:find(root_two, 1, true), generated)
        -- root_one_only exists only in R1, so successful checking proves that
        -- the compiler selected R1 before emitting this native call.
        assert.truthy(generated:find(
            "route_item_root_one_only_titan", 1, true), generated)

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
assert(package.searchpath("route.item", package.cpath) == %q)
local item = require "route.item"
assert(item.origin() == 101)
assert(item.root_one_only() == 11)
]], root_one .. "/route/item.so"))
        assert.truthy(ok, output)

        -- The Lua shim comes from R1 in both processes. Reversing only C-path
        -- order therefore demonstrates physical Lua-provider precedence, not
        -- fallback through the Titan import path.
        ok, output = run_lua(
            workspace, aligned_path, root_one, { root_two, root_one },
            string.format([[
assert(package.searchpath("route.item", package.cpath) == %q)
local item = require "route.item"
assert(item.origin() == 202)
assert(item.root_two_only() == 22)
]], root_two .. "/route/item.so"))
        assert.truthy(ok, output)
    end)

    it("selects one shallower provider from a later Titan path root",
       function()
        write_file(source_two .. "/later/branch/item.titan", [[
function answer(): integer
    return 303
end
]])
        write_file(source_two .. "/later/peer.titan", [[
function marker(): integer
    return 404
end
]])
        assert_compiles(root_two, source_two, root_two,
            "later.branch.item", "later.peer")
        assert.equal("file", lfs.attributes(root_two .. "/later.so", "mode"))
        assert.is_nil(lfs.attributes(
            root_two .. "/later/branch/item.so", "mode"))

        write_file(consumer_source .. "/later_consumer.titan", [[
local item = import "later.branch.item"

function answer(): integer
    return item.answer()
end
]])
        assert_compiles(consumer_root, consumer_source, titan_path,
            "later_consumer")

        local generated = read_file(
            consumer_source .. "/later_consumer.c")
        assert.truthy(generated:find(
            'loadlib(L, "later.so")', 1, true), generated)
        assert.falsy(generated:find(
            'loadlib(L, "later/branch/item.so")', 1, true), generated)

        local ok, output = run_lua(
            consumer_root, titan_path, consumer_root, { consumer_root }, [[
local consumer = require "later_consumer"
assert(consumer.answer() == 303)
]])
        assert.truthy(ok, output)
    end)

    it("shares dense arrays through a selected static provider", function()
        write_file(source_one .. "/staticarray/api.titan", [[
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
        assert.equal("file", lfs.attributes(
            root_one .. "/staticarray/api.a", "mode"))

        write_file(consumer_source .. "/static_array_consumer.titan", [[
local api = import "staticarray.api"

function roundtrip(): {value}
    local xs = api.make()
    api.set(xs, 5, 50)
    return api.echo(xs)
end
]])
        assert_compiles(consumer_root, consumer_source, root_one,
            "--static", "static_array_consumer")

        local generated = read_file(
            consumer_source .. "/static_array_consumer.c")
        assert.falsy(generated:find(
            'loadlib(L, "staticarray/api.so")', 1, true), generated)
        assert.truthy(generated:find(
            "extern Udata *staticarray_api_init", 1, true), generated)

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

    it("uses native and strict entries from a selected static provider",
       function()
        write_file(source_one .. "/staticentry/api.titan", [[
function probe(p: () -> integer): integer
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
        assert.equal("file", lfs.attributes(
            root_one .. "/staticentry/api.a", "mode"))

        write_file(consumer_source .. "/static_entry_consumer.titan", [[
local provider = import "staticentry.api"

function direct_depth(p: () -> integer): integer
    return provider.probe(p)
end

function exact_depth(p: () -> integer): integer
    local f: (() -> integer) -> integer = provider.probe
    return f(p)
end

function strict_result(): integer
    local f: (integer) -> integer = provider.boundary
    return f(3)
end

function strict_argument(x: value): value
    local f: (value) -> value = provider.boundary
    return f(x)
end

function boundary_function(): (integer) -> value
    return provider.boundary
end
]])
        assert_compiles(consumer_root, consumer_source, root_one,
            "--static", "static_entry_consumer")

        local generated = read_file(
            consumer_source .. "/static_entry_consumer.c")
        assert.falsy(generated:find(
            'loadlib(L, "staticentry/api.so")', 1, true), generated)
        assert.truthy(generated:find(
            "extern Udata *staticentry_api_init", 1, true), generated)

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

    it("keeps union closure slots symmetric through a prefix archive",
       function()
        write_file(source_one .. "/prefix/messages.titan", [[
record Delta
    x: float
    y: float
end

union Message
    quit
    local hidden: integer
    move: Delta
end

function Message:total(): float
    case self
    when move: delta then
        return delta.x + delta.y
    when quit then
        return 0.0
    else
        return -1.0
    end
end

function hidden_message(): Message
    return Message.hidden(77)
end
]])
        write_file(source_one .. "/prefix/peer.titan", [[
function marker(): integer
    return 19
end
]])
        assert_compiles(root_one, source_one, root_one,
            "prefix.messages", "prefix.peer")
        assert.equal("file", lfs.attributes(root_one .. "/prefix.a", "mode"))
        assert.equal("file", lfs.attributes(root_one .. "/prefix.so", "mode"))
        assert.is_nil(lfs.attributes(
            root_one .. "/prefix/messages.a", "mode"))

        write_file(consumer_source .. "/prefix_union_consumer.titan", [[
local m = import "prefix.messages"
local moved = m.Message.move({ x = 1.0, y = 2.0 })

function total(): float
    local make: (m.Delta) -> m.Message = m.Message.move
    local another = make({ x = 20.0, y = 22.0 })
    return moved:total() + another:total()
end

function same(): boolean
    return m.Message.move == m.Message.move
end

function bound(): float
    local read: () -> float = moved:total
    return read()
end

function hidden_else(): integer
    case m.hidden_message()
    when quit then
        return 0
    when move: delta then
        return 1
    else
        return 77
    end
end
]])
        assert_compiles(consumer_root, consumer_source, root_one,
            "--static", "prefix_union_consumer")

        local generated = read_file(
            consumer_source .. "/prefix_union_consumer.c")
        assert.falsy(generated:find(
            'loadlib(L, "prefix.so")', 1, true), generated)
        assert.truthy(generated:find(
            "extern Udata *prefix_messages_init", 1, true), generated)
        assert.truthy(generated:find(
            "case 2: goto _case_", 1, true), generated)

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

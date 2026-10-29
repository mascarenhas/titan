local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local compiler_io = require "titan-compiler.io"
local driver = require "titan-compiler.driver"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local lfs = require "lfs"
local DEPTH_PROBE = require("spec.support.helpers").DEPTH_PROBE
-- The workspace, provider, host and titanc-probe scaffolding is shared with
-- multi_module_path_stdlib_spec.lua, which owns the cases whose fixtures
-- import installed standard modules.
local support = require "spec.support.multi_module_path"

local PREFIX = support.PREFIX
local SHARED_SUFFIX = support.SHARED_SUFFIX
local EXE_SUFFIX = support.EXE_SUFFIX
local LUA = support.LUA
local TITAN_PATH_KEY = support.TITAN_PATH_KEY
local run = support.run
local temporary_workspace = support.temporary_workspace
local shared_path = support.shared_path
local make_directory = support.make_directory
local write_file = support.write_file
local read_file = support.read_file
local copy_file = support.copy_file
local remove_tree = support.remove_tree
local assert_compiles = support.assert_compiles
local assert_runs = support.assert_runs
local item_source = support.item_source
local write_titanc_shim = support.write_titanc_shim
local probe_count = support.probe_count

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

        assert_runs(consumer_root,
            { titan_path = consumer_root .. ";" .. titan_path }, [[
local consumer = require "path_consumer"
assert(consumer.answer() == 112)
]])
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

        assert_runs(consumer_root,
            { titan_path = consumer_root .. ";" .. titan_path },
            string.format([[
-- A direct require selects the shallow bundle of the later root too.
local item, provider = require "later.branch.item"
assert(item.answer() == 303)
assert(provider:sub(-%d) == %q, provider)
local consumer = require "later_consumer"
assert(consumer.answer() == 303)
]], #("later" .. SHARED_SUFFIX), "later" .. SHARED_SUFFIX))
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

        assert_runs(consumer_root,
            { titan_path = consumer_root .. ";" .. root_one }, [[
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

        assert_runs(consumer_root,
            { titan_path = consumer_root .. ";" .. root_one },
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

        assert_runs(consumer_root,
            { titan_path = consumer_root .. ";" .. root_one }, [[
local consumer = require "prefix_union_consumer"
assert(consumer.total() == 45.0)
assert(consumer.same())
assert(consumer.bound() == 3.0)
assert(consumer.hidden_else() == 77)
]])
    end)
end)

describe("Titan runtime searcher and Titan path", function()
    local workspace
    -- Provider roots, each the output of one compilation.
    local exact_one, exact_two, bundle, other, consumer, guard
    local sdk, empty_sdk

    local function root(name) return support.root(workspace, name) end

    local function realpath(name)
        return assert(compiler_io.new_sync():realpath(name))
    end

    -- The kernel's spelling of an existing directory (symlinks resolved).
    local function physical_dir(directory)
        local previous = assert(lfs.currentdir())
        assert.truthy(lfs.chdir(directory))
        local physical = assert(lfs.currentdir())
        assert.truthy(lfs.chdir(previous))
        return physical
    end

    local function same_path(left, right)
        if platform.windows then
            left = left:gsub("\\", "/"):lower()
            right = right:gsub("\\", "/"):lower()
        end
        return left == right
    end

    -- A copied host gives `!` a directory this test controls.
    local function copy_lua(directory)
        make_directory(directory)
        local host = path.join(directory, "lua" .. EXE_SUFFIX)
        local ok, output = run({ "cp", "-p", LUA, host }, workspace)
        assert.truthy(ok, output)
        if platform.windows then
            for name in lfs.dir(path.join(PREFIX, "bin")) do
                if name:match("^lua.*%.dll$") then
                    copy_file(path.join(PREFIX, "bin", name),
                        path.join(directory, name))
                end
            end
        end
        return host
    end

    -- Compile one C file with the configured compiler.
    local function compile_c(source, output, words)
        local argv = { "env", "CCACHE_DISABLE=1" }
        for _, word in ipairs(assert(cdriver.split_shell_words(driver.CC))) do
            argv[#argv + 1] = word
        end
        argv[#argv + 1] = "-std=c99"
        for _, word in ipairs(words or {}) do argv[#argv + 1] = word end
        for _, word in ipairs({ source, "-o", output }) do
            argv[#argv + 1] = word
        end
        local ok, cc_output = run(argv, workspace)
        assert.truthy(ok, cc_output)
    end

    setup(function()
        workspace = temporary_workspace()
        exact_one = root("exact-one")
        exact_two = root("exact-two")
        bundle = root("bundle")
        other = root("other")
        consumer = root("consumer")
        guard = root("guard")
        sdk = root("sdk")
        empty_sdk = root("empty-sdk")
        for _, directory in ipairs({
            exact_one, exact_two, bundle, other, consumer, guard,
            sdk, empty_sdk,
        }) do
            make_directory(directory)
        end

        local source = root("src-one")
        write_file(path.join(source, "search/item.titan"), item_source(1))
        assert_compiles(exact_one, source, exact_one, "search.item")

        source = root("src-two")
        write_file(path.join(source, "search/item.titan"), item_source(2))
        assert_compiles(exact_two, source, exact_two, "search.item")

        -- search.so claiming search.item (and search.peer).
        source = root("src-bundle")
        write_file(path.join(source, "search/item.titan"), item_source(3))
        write_file(path.join(source, "search/peer.titan"), [[
function marker(): integer
    return 33
end
]])
        assert_compiles(bundle, source, bundle, "search.item", "search.peer")
        assert.equal("file", lfs.attributes(shared_path(bundle, "search"), "mode"))

        -- search.so that does not claim search.item.
        source = root("src-other")
        write_file(path.join(source, "search/alpha.titan"), [[
function marker(): integer
    return 44
end
]])
        write_file(path.join(source, "search/beta.titan"), [[
function marker(): integer
    return 45
end
]])
        assert_compiles(other, source, other, "search.alpha", "search.beta")
        assert.equal("file", lfs.attributes(shared_path(other, "search"), "mode"))

        source = root("src-consumer")
        write_file(path.join(source, "search_consumer.titan"), [[
local item = import "search.item"

function bump_item(): integer
    return item.bump()
end

function origin(): integer
    return item.origin()
end
]])
        assert_compiles(consumer, source, exact_one .. ";" .. consumer,
            "search_consumer")

        -- guard.so holds guard.b-c, whose mangled names equal guard.b_c's.
        source = root("src-guard")
        write_file(path.join(source, "guard/b-c.titan"), [[
function value(): integer
    return 7
end
]])
        write_file(path.join(source, "guard/peer.titan"), [[
function marker(): integer
    return 8
end
]])
        assert_compiles(guard, source, guard, "guard.b-c", "guard.peer")
        assert.equal("file", lfs.attributes(shared_path(guard, "guard"), "mode"))

        copy_file(shared_path(exact_two, "search/item"),
            shared_path(path.join(sdk, "lib/titan/0.6"), "search/item"))
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("selects providers root-major and shallow to exact, with occupancy",
       function()
        local function origin_with(titan_path)
            local output = assert_runs(workspace, { titan_path = titan_path }, [[
local item, provider = require "search.item"
io.write(item.origin(), " ", provider, "\n")
]])
            local value, provider = output:match("(%d+) ([^\n]+)")
            return tonumber(value), provider
        end

        -- The first root's exact provider wins; the loader data is its path.
        local value, provider = origin_with(exact_two .. ";" .. exact_one)
        assert.equal(2, value)
        assert.truthy(same_path(realpath(shared_path(exact_two, "search/item")),
            realpath(provider)), provider)
        assert.equal(1, (origin_with(exact_one .. ";" .. exact_two)))

        -- Root-major: an exact provider in an earlier root beats a shallow
        -- bundle in a later root, and vice versa.
        assert.equal(1, (origin_with(exact_one .. ";" .. bundle)))
        assert.equal(3, (origin_with(bundle .. ";" .. exact_one)))

        -- Within one root the shallow bundle is tried first.
        local both = root("both")
        copy_file(shared_path(bundle, "search"), shared_path(both, "search"))
        copy_file(shared_path(exact_two, "search/item"),
            shared_path(both, "search/item"))
        assert.equal(3, (origin_with(both)))

        -- An occupied nonclaiming search.so shadows the claiming search.so of
        -- a later root, so the exact provider after them is selected.
        assert.equal(1, (origin_with(other .. ";" .. bundle .. ";" .. exact_one)))
        -- Empty entries are separators, not directories.
        assert.equal(1, (origin_with(";" .. exact_one .. ";")))
    end)

    it("returns a clean miss and raises for a selected broken provider",
       function()
        local output = assert_runs(workspace, { titan_path = exact_one }, [[
local ok, message = pcall(require, "search.missing")
assert(not ok)
io.write(message)
]])
        assert.truthy(output:find("module 'search.missing' not found", 1, true), output)
        assert.truthy(output:find("no file '[^']*search/missing" ..
            SHARED_SUFFIX:gsub("%.", "%%.") .. "'"), output)

        local function terminal(titan_path, expected)
            local message = assert_runs(workspace, { titan_path = titan_path }, [[
local ok, message = pcall(require, "search.item")
assert(not ok)
io.write(message)
]])
            assert.falsy(message:find("not found", 1, true), message)
            assert.truthy(message:find(expected, 1, true), message)
        end

        -- An occupied candidate that cannot be opened is selected: the valid
        -- provider of the later root is never used to conceal it.
        local junk = root("junk")
        write_file(shared_path(junk, "search/item"), "not a native image\n")
        terminal(junk .. ";" .. exact_one,
            platform.windows and "cannot load library" or "cannot load Titan provider")
        if not platform.windows then
            local dangling = root("dangling")
            make_directory(path.join(dangling, "search"))
            local ok, link_output = run({ "ln", "-s", root("absent.so"),
                shared_path(dangling, "search/item") }, workspace)
            assert.truthy(ok, link_output)
            terminal(dangling .. ";" .. exact_one, "cannot load Titan provider")
        end

        -- An exact candidate with neither marker is terminal; an ancestor
        -- with neither is a clean nonclaim (covered by the occupancy case).
        local markerless = root("markerless")
        copy_file(shared_path(other, "search"),
            shared_path(markerless, "search/item"))
        terminal(markerless .. ";" .. exact_one,
            "does not define module 'search.item'")

        if not platform.windows then
            -- Native images claiming search.item with a partial claim, then
            -- with an incompatible ABI marker. Neither has an opener.
            local function fabricated(directory, defines)
                local source = path.join(directory, "fabricated.c")
                write_file(source, [[
typedef struct lua_State lua_State;
extern const char *lua_pushstring(lua_State *L, const char *s);
int search_item_abi(lua_State *L) { lua_pushstring(L, "0"); return 1; }
#if defined(WITH_TYPES)
int search_item_types(lua_State *L) { lua_pushstring(L, ""); return 1; }
#endif
]])
                make_directory(path.join(directory, "search"))
                local words = { "-fPIC" }
                for _, word in ipairs(assert(driver.shared_library_flags())) do
                    words[#words + 1] = word
                end
                for _, word in ipairs(defines) do words[#words + 1] = word end
                compile_c(source, shared_path(directory, "search/item"), words)
            end
            local partial = root("partial")
            fabricated(partial, {})
            terminal(partial .. ";" .. exact_one,
                "claims module 'search.item' but is missing metadata symbol " ..
                "'search_item_types'")
            local incompatible = root("incompatible")
            fabricated(incompatible, { "-DWITH_TYPES" })
            terminal(incompatible .. ";" .. exact_one,
                "ABI mismatch: expected " .. driver.TITAN_ABI_VERSION ..
                " but found 0")
        end
    end)

    it("reuses the canonical module for require-first and import-first loads",
       function()
        assert_runs(workspace, { titan_path = consumer .. ";" .. exact_one }, [[
local item = require "search.item"
assert(item.bump() == 1)
local consumer = require "search_consumer"
assert(consumer.bump_item() == 2)
assert(item.bump() == 3)
]])

        -- The import initializes search.item; a later require returns that
        -- canonical module without opening any image, even after its
        -- provider file is gone. Initialization also publishes the module's
        -- native preload, so Lua's own preload searcher may answer the
        -- require first; either way the canonical module comes back.
        local moved = root("moved")
        copy_file(shared_path(exact_one, "search/item"),
            shared_path(moved, "search/item"))
        assert_runs(workspace, { titan_path = consumer .. ";" .. moved },
            string.format([[
local consumer = require "search_consumer"
assert(consumer.bump_item() == 1)
if package.config:sub(1, 1) ~= "\\" then
    assert(os.rename(%q, %q))
end
local item = require "search.item"
assert(item.bump() == 2)
assert(consumer.origin() == 1)
-- The Titan searcher's own canonical branch returns the same module and
-- names no provider file.
local loader, data = package.searchers[#package.searchers]("search.item")
assert(data == nil, tostring(data))
assert(rawequal(loader("search.item"), item))
assert(item.bump() == 3)
]], shared_path(moved, "search/item"), shared_path(moved, "search/item.moved")))
    end)

    it("rejects a claim whose mangled names belong to another logical module",
       function()
        local output = assert_runs(workspace, { titan_path = guard }, [[
local ok, message = pcall(require, "guard.b_c")
assert(not ok)
io.write(message, "\n")
assert(debug.getregistry()["Titan module guard.b-c"] == nil)
local module = require "guard.b-c"
assert(module.value() == 7)
]])
        assert.truthy(output:find(
            "module name mismatch: requested 'guard.b_c', provider defines " ..
            "'guard.b-c'", 1, true), output)
    end)

    it("expands `;;` and `!`, honors precedence, and keeps an empty path empty",
       function()
        local app = root("app")
        local host = copy_lua(path.join(app, "bin"))
        local exe_dir = physical_dir(path.join(app, "bin"))
        local installed = path.join(app, "lib/titan/0.6")
        local log = root("empty-path.log")
        local shim = not platform.windows and
            write_titanc_shim(root("shim-empty"), log, sdk) or nil
        local probe_env = shim and { "TITANC=" .. shim } or { "TITANC=" .. root("absent-titanc") }

        -- Default `!;!/../lib/titan/0.6`: the bin-sibling provider tree...
        copy_file(shared_path(exact_one, "search/item"),
            shared_path(installed, "search/item"))
        local output = assert_runs(workspace, { lua = host, env = probe_env }, [[
local item, provider = require "search.item"
assert(item.origin() == 1, item.origin())
io.write(titan._executable_dir(), "\n", debug.getregistry()[TITAN_PATH_KEY], "\n")
]])
        local reported, effective = output:match("([^\n]*)\n([^\n]*)\n")
        assert.truthy(same_path(exe_dir, reported), output)
        -- No `.` and no SDK fallback in the effective default path.
        assert.equal(reported .. ";" .. reported .. "/../lib/titan/0.6", effective)
        -- ...after a flat provider beside the executable.
        copy_file(shared_path(exact_two, "search/item"),
            shared_path(path.join(app, "bin"), "search/item"))
        assert_runs(workspace, { lua = host, env = probe_env }, [[
assert(require("search.item").origin() == 2)
]])
        assert(os.remove(shared_path(path.join(app, "bin"), "search/item")))

        -- `!` in a configured entry; TITAN_PATH_0_6 wins over TITAN_PATH.
        copy_file(shared_path(exact_two, "search/item"),
            shared_path(path.join(app, "bin/providers"), "search/item"))
        assert_runs(workspace, {
            lua = host, titan_path = "!/providers",
            env = { "TITAN_PATH=" .. exact_one },
        }, [[
assert(require("search.item").origin() == 2)
]])
        assert_runs(workspace, { lua = host, env = { "TITAN_PATH=" .. exact_one } }, [[
assert(require("search.item").origin() == 1)
]])

        -- `;;` inserts the default in place: the consumer is found in the
        -- default tree, its import in the earlier configured root.
        copy_file(shared_path(consumer, "search_consumer"),
            shared_path(installed, "search_consumer"))
        assert_runs(workspace, {
            lua = host, titan_path = exact_two .. ";;", env = probe_env,
        }, [[
assert(require("search_consumer").origin() == 2)
]])

        -- An explicitly empty value is an empty search: no default, no SDK
        -- fallback, no probe.
        assert_runs(workspace, { lua = host, titan_path = "", env = probe_env }, [[
local ok, message = pcall(require, "search.item")
assert(not ok)
assert(message:find("Titan path is empty", 1, true), message)
]])
        assert.equal(0, probe_count(log))

        if not platform.windows then
            -- `!` is the executable's real directory, also through a symlink
            -- run from another working directory.
            local link_dir = root("links")
            make_directory(link_dir)
            local link = path.join(link_dir, "lua")
            local ok, output = run({ "ln", "-s", host, link }, workspace)
            assert.truthy(ok, output)
            output = assert_runs(root("src-one"), { lua = link, env = probe_env }, [[
assert(require("search.item").origin() == 1)
io.write(titan._executable_dir(), "\n")
]])
            assert.equal(exe_dir, output:match("([^\n]*)\n"))
        end
    end)

    it("does not search the current directory at runtime", function()
        local cwd = root("cwd")
        copy_file(shared_path(exact_one, "search/item"),
            shared_path(cwd, "search/item"))
        local output = assert_runs(cwd, { env = { "TITAN_ROOT=" .. empty_sdk } }, [[
local ok, message = pcall(require, "search.item")
assert(not ok)
io.write(message)
]])
        assert.truthy(output:find("module 'search.item' not found", 1, true), output)
        assert.falsy(output:find("no file './", 1, true), output)
    end)

    it("uses TITAN_ROOT as the SDK fallback without launching titanc",
       function()
        local log = root("titan-root.log")
        local env = { "TITAN_ROOT=" .. sdk }
        if not platform.windows then
            table.insert(env, "TITANC=" ..
                write_titanc_shim(root("shim-root"), log, empty_sdk))
        end
        assert_runs(workspace, { env = env }, string.format([[
local item, provider = require "search.item"
assert(item.origin() == 2)
assert(provider:gsub("\\", "/"):find(%q, 1, true), provider)
]], "lib/titan/0.6"))
        assert.equal(0, probe_count(log))
    end)

    it("uses a stored Titan path verbatim, without expansion or fallback",
       function()
        local app = root("verbatim-app")
        local host = copy_lua(path.join(app, "bin"))
        -- Providers at both places an expansion of `!/providers;;` would
        -- search, and in the fallback SDK the TITANC stand-in reports.
        copy_file(shared_path(exact_one, "search/item"),
            shared_path(path.join(app, "bin/providers"), "search/item"))
        copy_file(shared_path(exact_one, "search/item"),
            shared_path(path.join(app, "lib/titan/0.6"), "search/item"))
        local log = root("verbatim.log")
        local titanc = platform.windows and root("absent-titanc.exe") or
            write_titanc_shim(root("shim-verbatim"), log, sdk)
        local output = assert_runs(workspace, {
            lua = host, env = { "TITANC=" .. titanc },
        }, [[
debug.getregistry()[TITAN_PATH_KEY] = "!/providers;;"
local ok, message = pcall(require, "search.item")
assert(not ok)
io.write(message)
]])
        assert.truthy(output:find(
            "no file '!/providers/search" .. SHARED_SUFFIX .. "'", 1, true), output)
        -- Any fallback attempt, failed or not, would show here or resolve.
        assert.falsy(output:find("no Titan SDK fallback", 1, true), output)
        assert.equal(0, probe_count(log))
    end)

    if not platform.windows then
        it("normalizes a TITAN_ROOT with `..` through realpath, else lexically",
           function()
            local base = root("dotdot")
            make_directory(path.join(base, "real/sub"))
            make_directory(path.join(base, "real/sdk"))
            for _, link in ipairs({
                { path.join(base, "real/sub"), path.join(base, "link") },
                { path.join(base, "loop"), path.join(base, "loop") },
            }) do
                local ok, output = run({ "ln", "-s", link[1], link[2] }, workspace)
                assert.truthy(ok, output)
            end
            local function compiler_root(value)
                local output = assert_runs(workspace, {
                    env = { "TITAN_ROOT=" .. value },
                }, [[
local root, message = titan._compiler_root()
io.write(tostring(root), "\n", tostring(message), "\n")
]])
                return output:match("^([^\n]*)\n")
            end

            -- The kernel resolves link/.. to real/, so an existing target is
            -- named through realpath, not lexically.
            assert.equal(physical_dir(path.join(base, "real/sdk")),
                compiler_root(base .. "/link/../sdk"))
            -- A missing target, and any other realpath failure (a symlink
            -- loop), normalize lexically.
            assert.equal(base .. "/missing",
                compiler_root(base .. "/link/../missing"))
            assert.equal(base .. "/sdk", compiler_root(base .. "/loop/../sdk"))

            -- The runtime SDK fallback uses the same resolved root.
            copy_file(shared_path(exact_two, "search/item"),
                shared_path(path.join(base, "real/sdk/lib/titan/0.6"),
                    "search/item"))
            assert_runs(workspace, {
                titan_path = other .. ";;",
                env = { "TITAN_ROOT=" .. base .. "/link/../sdk" },
            }, [[
assert(require("search.item").origin() == 2)
]])
        end)
    end

    if not platform.windows then
        it("probes titanc lazily, once per state, and never after a hit",
           function()
            local log = root("probe.log")
            local shim_dir = root("shim-path")
            write_titanc_shim(shim_dir, log, sdk)
            local env = { "PATH=" .. shim_dir .. ":" ..
                (os.getenv("PATH") or "/usr/bin:/bin") }

            -- A provider found in an earlier root never probes; the first
            -- miss probes once and every later lookup reuses the outcome.
            assert_runs(workspace, { titan_path = exact_one .. ";;", env = env }, [[
assert(require("search.item").origin() == 1)
]])
            assert.equal(0, probe_count(log))
            assert_runs(workspace, { titan_path = bundle .. ";;", env = env }, [[
assert(require("search.peer").marker() == 33)
assert(not pcall(require, "search.missing"))
assert(not pcall(require, "search.other_missing"))
local ok, message = pcall(require, "search.missing")
assert(not ok)
]])
            assert.equal(1, probe_count(log))

            -- The probe result is the SDK fallback, after every other root.
            assert_runs(workspace, { titan_path = other .. ";;", env = env }, [[
local item, provider = require "search.item"
assert(item.origin() == 2)
assert(not pcall(require, "search.missing"))
]])
            assert.equal(2, probe_count(log))

            -- A non-empty $TITANC names the program instead of PATH.
            local named = write_titanc_shim(root("shim-titanc"), log, sdk)
            assert_runs(workspace, {
                titan_path = other .. ";;", env = { "TITANC=" .. named },
            }, [[
assert(require("search.item").origin() == 2)
]])
            assert.equal(3, probe_count(log))

            -- An explicit path without `;;`, or a path an application stored
            -- in the registry, never gains the fallback.
            assert_runs(workspace, { titan_path = exact_one, env = env }, [[
assert(not pcall(require, "search.missing"))
]])
            assert_runs(workspace, { env = env }, string.format([[
debug.getregistry()[TITAN_PATH_KEY] = %q
assert(require("search.item").origin() == 1)
assert(not pcall(require, "search.missing"))
]], exact_one))
            assert.equal(3, probe_count(log))
        end)
    end

    -- A native stand-in for titanc exercises each platform's spawn
    -- (posix_spawnp, or CreateProcessW with a restricted handle list).
    it("probes a compiled TITANC program once per state, and reports one that cannot start",
       function()
        local directory = root("probe-program")
        local source = path.join(directory, "probe.c")
        write_file(source, [[
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *log = getenv("TITAN_PROBE_LOG");
    const char *root = getenv("TITAN_PROBE_ROOT");
    FILE *file;
    if (argc != 2 || strcmp(argv[1], "--print-root") != 0) return 2;
    if (log == NULL || root == NULL) return 3;
    file = fopen(log, "ab");
    if (file == NULL) return 4;
    fputs("probe\n", file);
    fclose(file);
    printf("%s\n", root);
    return 0;
}
]])
        local function native(name)
            return platform.windows and (name:gsub("/", "\\")) or name
        end
        local program = path.join(directory, "titanc-probe" .. EXE_SUFFIX)
        compile_c(source, program)
        local log = root("program-probe.log")
        assert_runs(workspace, {
            titan_path = other .. ";;",
            env = {
                "TITANC=" .. native(program),
                "TITAN_PROBE_LOG=" .. native(log),
                "TITAN_PROBE_ROOT=" .. sdk,
            },
        }, [[
local item, provider = require "search.item"
assert(item.origin() == 2)
assert(provider:gsub("\\", "/"):find("lib/titan/0.6", 1, true), provider)
-- Later misses search the cached fallback without launching it again.
assert(not pcall(require, "search.missing"))
local ok, message = pcall(require, "search.other_missing")
assert(not ok)
assert(not message:find("no Titan SDK fallback", 1, true), message)
]])
        assert.equal(1, probe_count(log))

        local not_program_path = path.join(directory, "not-a-program" .. EXE_SUFFIX)
        write_file(not_program_path, "not a program\n")
        local not_program = native(not_program_path)
        local output = assert_runs(workspace, {
            titan_path = other .. ";;", env = { "TITANC=" .. not_program },
        }, [[
local ok, message = pcall(require, "search.item")
assert(not ok)
io.write(message)
]])
        assert.truthy(output:find(
            "no Titan SDK fallback: cannot start '" .. not_program, 1, true), output)
    end)

    -- Bare program names resolve through the PATH entries alone: the default
    -- `titanc` and a TITANC without a directory part. Windows looks for
    -- titanc.exe and appends `.exe` to a TITANC name without an extension;
    -- posix_spawnp searches PATH on Unix. A program present only in the
    -- current directory is never started. The shared runner hands the
    -- variables to each platform's own channel: `env -u ... NAME=value ...`
    -- ahead of the command on POSIX, the native spawn environment on Windows.
    it("resolves titanc and a bare TITANC name through PATH entries only",
       function()
        local directory = root("path-probe")
        local source = path.join(directory, "probe.c")
        write_file(source, [[
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *log = getenv("TITAN_PROBE_LOG");
    const char *root = getenv("TITAN_PROBE_ROOT");
    FILE *file;
    if (argc != 2 || strcmp(argv[1], "--print-root") != 0) return 2;
    if (log == NULL || root == NULL) return 3;
    file = fopen(log, "ab");
    if (file == NULL) return 4;
    fputs("probe\n", file);
    fclose(file);
    printf("%s\n", root);
    return 0;
}
]])
        for _, name in ipairs({ "titanc", "titanc-path-probe" }) do
            compile_c(source, path.join(directory, name .. EXE_SUFFIX))
        end
        local empty = root("path-probe-empty")
        make_directory(empty)
        local function native(name)
            return platform.windows and (name:gsub("/", "\\")) or name
        end
        local log = root("path-probe.log")
        local chunk = root("path-probe.lua")
        write_file(chunk, string.format([[
package.path = ""
package.cpath = %q
require "titan"
if ... == "found" then
  assert(require("search.item").origin() == 2)
else
  local ok, message = pcall(require, "search.item")
  assert(not ok)
  io.write(message)
end
]], support.SUPPORT_CPATH))
        local function query(cwd, search, selected, expectation)
            -- PATH carries only the fixture list; the parent's Titan
            -- selection and Lua startup hooks are removed.
            local environment = {
                { "PATH", native(search) },
                { "TITANC", selected or false },
                { "TITAN_ROOT", false },
                { "TITAN_PATH", false },
                { "TITAN_PATH_0_6", other .. ";;" },
                { "TITAN_PROBE_LOG", native(log) },
                { "TITAN_PROBE_ROOT", sdk },
                { "LUA_INIT", false },
                { "LUA_INIT_5_5", false },
            }
            local ok, output = run({ LUA, "-E", chunk, expectation }, cwd,
                environment)
            assert.truthy(ok, output)
            return output
        end
        local found = { false, "titanc-path-probe" }
        if platform.windows then found[#found + 1] = "titanc-path-probe.exe" end
        for index, selected in ipairs(found) do
            query(workspace, directory, selected or nil, "found")
            assert.equal(index, probe_count(log))
        end
        -- Both programs sit in the current directory, but no PATH entry.
        for _, name in ipairs({ "titanc", "titanc-path-probe" }) do
            local message = query(directory, empty,
                name ~= "titanc" and name or nil, "missing")
            assert.truthy(message:find("no Titan SDK fallback: ", 1, true), message)
            assert.truthy(message:find(platform.windows and
                ("'" .. name .. "' was not found on PATH") or ("'" .. name), 1, true), message)
            assert.equal(#found, probe_count(log))
        end
    end)

    -- The root query child must not run the parent's Lua startup hooks: a
    -- LUA_INIT that installs the searcher and requires a missing module would
    -- otherwise start the same fallback query again, recursively and without
    -- a bound. Everything else in the environment must still be inherited.
    it("keeps Lua startup hooks out of the root query child", function()
        local directory = root("init-probe")
        local source = path.join(directory, "init_probe.c")
        write_file(source, [[
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *log = getenv("TITAN_PROBE_LOG");
    const char *root = getenv("TITAN_PROBE_ROOT");
    FILE *file;
    if (argc != 2 || strcmp(argv[1], "--print-root") != 0) return 2;
    if (log == NULL || root == NULL) return 3;
    file = fopen(log, "ab");
    if (file == NULL) return 4;
    fputs("probe\n", file);
    fputs(getenv("LUA_INIT") == NULL ? "lua_init=absent\n" : "lua_init=present\n",
        file);
    fputs(getenv("LUA_INIT_5_5") == NULL ? "lua_init_5_5=absent\n" :
        "lua_init_5_5=present\n", file);
    fclose(file);
    printf("%s\n", root);
    return 0;
}
]])
        local function native(name)
            return platform.windows and (name:gsub("/", "\\")) or name
        end
        local program = path.join(directory, "titanc-init" .. EXE_SUFFIX)
        compile_c(source, program)
        local log = root("init-probe.log")
        -- Windows compares environment names case-insensitively, so the mixed
        -- spelling must be withheld too; Lua's own startup lookup is
        -- case-insensitive there, which the asserting chunk below proves.
        local names = platform.windows and
            { "Lua_Init_5_5", "Lua_Init" } or { "LUA_INIT_5_5", "LUA_INIT" }
        local initializer = 'probe_lua_init = "seen"'
        assert_runs(workspace, {
            titan_path = other .. ";;",
            env = {
                "TITANC=" .. native(program),
                "TITAN_PROBE_LOG=" .. native(log),
                "TITAN_PROBE_ROOT=" .. sdk,
                names[1] .. "=" .. initializer,
                names[2] .. "=" .. initializer,
            },
        }, [[
assert(probe_lua_init == "seen", "the parent host runs its Lua startup hook")
local item, provider = require "search.item"
assert(item.origin() == 2)
assert(provider:gsub("\\", "/"):find("lib/titan/0.6", 1, true), provider)
assert(not pcall(require, "search.missing"))
]])
        assert.equal(1, probe_count(log))
        assert.equal("probe\nlua_init=absent\nlua_init_5_5=absent\n",
            read_file(log))
    end)

    -- A native host can drop its whole environment: glibc's clearenv() leaves
    -- no `environ` at all. The lazy SDK fallback must then finish normally
    -- instead of dereferencing it, and a host that keeps only an absolute
    -- TITANC and the probe variables across the clear must resolve the SDK
    -- exactly as usual.
    if not platform.windows then
        it("survives a host that cleared its environment before the fallback",
           function()
            local directory = root("cleared-host")
            local source = path.join(directory, "clearenv.c")
            write_file(source, [[
#if !defined(__APPLE__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#define host_environ() (*_NSGetEnviron())
#else
extern char **environ;
#define host_environ() environ
#endif

static char *kept_entry(const char *name) {
    const char *value = getenv(name);
    char *entry;
    if (value == NULL) return NULL;
    entry = (char *)malloc(strlen(name) + strlen(value) + 2);
    if (entry == NULL) return NULL;
    strcpy(entry, name);
    strcat(entry, "=");
    strcat(entry, value);
    return entry;
}

/* Replace the whole environment with the fixture's variables, if any: no
** kept variable means the runtime sees `environ == NULL` on glibc. */
int luaopen_clearenv(void *state) {
    static const char *const names[] = {
        "TITANC", "TITAN_PROBE_LOG", "TITAN_PROBE_ROOT",
    };
    char **table;
    int index, used = 0;
    (void)state;
    table = (char **)malloc(4 * sizeof(char *));
    if (table == NULL) return 0;
    for (index = 0; index < 3; index++) {
        char *entry = kept_entry(names[index]);
        if (entry != NULL) table[used++] = entry;
    }
    table[used] = NULL;
#if defined(__APPLE__)
    /* Darwin has no clearenv(); an empty table is the same runtime effect. */
    host_environ() = table;
#else
    host_environ() = used == 0 ? NULL : table;
    if (used == 0) free(table);
#endif
    return 0;
}
]])
            local words = { "-fPIC" }
            for _, word in ipairs(assert(driver.shared_library_flags())) do
                words[#words + 1] = word
            end
            compile_c(source, shared_path(directory, "clearenv"), words)
            local cpath = path.to_slash(path.join(directory,
                "?" .. SHARED_SUFFIX))
            local function host(env, code)
                return assert_runs(workspace, { env = env }, string.format(
                    "package.cpath = package.cpath .. %q\n%s", ";" .. cpath,
                    code))
            end

            -- Nothing survives the clear, so the query child gets an empty
            -- environment and the miss is ordinary.
            local output = host({}, [[
require "clearenv"
local ok, message = pcall(require, "search.missing")
assert(not ok)
io.write(message)
]])
            assert.truthy(output:find(
                "module 'search.missing' not found", 1, true), output)

            -- The variables the fixture keeps survive the clear.
            local probe = path.join(directory, "probe.c")
            write_file(probe, [[
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *log = getenv("TITAN_PROBE_LOG");
    const char *root = getenv("TITAN_PROBE_ROOT");
    FILE *file;
    if (argc != 2 || strcmp(argv[1], "--print-root") != 0) return 2;
    if (log == NULL || root == NULL) return 3;
    file = fopen(log, "ab");
    if (file == NULL) return 4;
    fputs("probe\n", file);
    fclose(file);
    printf("%s\n", root);
    return 0;
}
]])
            local program = path.join(directory, "titanc-absolute")
            compile_c(probe, program)
            local log = root("cleared-host.log")
            host({
                "TITANC=" .. program,
                "TITAN_PROBE_LOG=" .. log,
                "TITAN_PROBE_ROOT=" .. sdk,
            }, [[
require "clearenv"
assert(require("search.item").origin() == 2)
]])
            assert.equal(1, probe_count(log))
        end)
    end

end)

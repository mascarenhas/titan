local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local staticmetadata = require "titan-compiler.staticmetadata"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local LUA_INCLUDE = PREFIX .. "/include"
local USE_CHECKOUT_COMPILER =
    os.getenv("TITAN_TEST_USE_CHECKOUT_COMPILER") == "1"

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
    local parent = assert(path:match("^(.+)/[^/]+$"))
    make_directory(parent)
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

local function final_archive_command_uses(output, argument)
    for line in output:gmatch("[^\r\n]+") do
        if line:find("'" .. argument .. "'", 1, true) and
           line:find("/output.a'", 1, true) then
            return true
        end
    end
    return false
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

local function compiler_argv(workspace, source_root, ...)
    local argv = {
        "env",
        "-u", "LUA_PATH", "-u", "LUA_PATH_5_5",
        "-u", "LUA_CPATH", "-u", "LUA_CPATH_5_5",
        "CCACHE_DISABLE=1",
        "TITAN_PATH_0_16=" .. workspace,
        "TITAN_PATH=",
    }
    if PREFIX then
        table.insert(argv, "PATH=" .. PREFIX .. "/bin:/usr/bin:/bin")
    end

    -- The opt-in is only for testing an in-progress checkout before the
    -- prefix's next `luarocks make`; normal `luarocks test` continues to prove
    -- the installed compiler snapshot.
    local installed = not USE_CHECKOUT_COMPILER and
        PREFIX and exists(PREFIX .. "/bin/titanc")
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

local function compile(workspace, source_root, ...)
    return run(compiler_argv(workspace, source_root, ...), workspace)
end

local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?.so;" .. %q .. "/?.so;" .. package.cpath
%s
]], workspace, workspace, REPO, code),
    }, workspace)
end

local function count_plain(text, needle)
    local count = 0
    local start = 1
    while true do
        local at = text:find(needle, start, true)
        if not at then return count end
        count = count + 1
        start = at + #needle
    end
end

local function copy_file(source, destination)
    write_file(destination, read_file(source))
end

local function configured_words(command)
    return assert(cdriver.split_shell_words(command))
end

local function compile_c_object(workspace, stem, body)
    local source = workspace .. "/" .. stem .. ".c"
    local object = workspace .. "/" .. stem .. ".o"
    write_file(source, body)
    local argv = { "env", "CCACHE_DISABLE=1" }
    for _, word in ipairs(configured_words(driver.CC)) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs({
        "-std=c99", "-fPIC", "-c", source, "-o", object,
    }) do
        argv[#argv + 1] = word
    end
    local ok, output = run(argv, workspace)
    assert.truthy(ok, output)
    return object
end

local function make_archive(workspace, name, objects)
    local archive = workspace .. "/" .. name
    local argv = configured_words(driver.AR)
    argv[#argv + 1] = "rcs"
    argv[#argv + 1] = archive
    for _, object in ipairs(objects) do argv[#argv + 1] = object end
    local ok, output = run(argv, workspace)
    assert.truthy(ok, output)
    return archive
end

local function native_symbols(workspace, filename)
    local ok, output = run({ "nm", "-g", filename }, workspace)
    assert.truthy(ok, output)
    return output
end

local function run_program(workspace, relative)
    return run({ workspace .. "/" .. relative }, workspace)
end

local function metadata_options()
    return {
        expected_abi = driver.TITAN_VER,
        validate_types = function(name, serialized, origin)
            return driver.decode_module_interface(serialized, name, origin)
        end,
    }
end

local function assert_provider_pair(workspace, provider, module_names,
                                    validate_archive_protocols)
    local dso = workspace .. "/" .. provider .. ".so"
    local archive_path = workspace .. "/" .. provider .. ".a"
    assert.equal("file", lfs.attributes(dso, "mode"))
    assert.equal("file", lfs.attributes(archive_path, "mode"))

    local archive, archive_err =
        staticmetadata.scan_archive(archive_path, metadata_options())
    assert.truthy(archive, archive_err)
    local callable, callable_err =
        driver.library_interface_entries(dso, module_names)
    assert.truthy(callable, callable_err)
    local equal, equality_err = driver.compare_archive_entries(
        archive.entries, callable, "published provider pair")
    assert.truthy(equal, equality_err)
    assert.truthy(driver.validate_library_image(dso, module_names))

    if validate_archive_protocols then
        local image = workspace .. "/archive-protocol-validation.so"
        local linked, link_term, link_code =
            driver.compile_archive_validation_image(
                image, archive_path, nil, false)
        assert.truthy(linked, table.concat({
            tostring(link_term), tostring(link_code),
        }, ", "))
        local valid, validation_err =
            driver.validate_library_image(image, module_names)
        assert.truthy(valid, validation_err)
        local archive_equal, archive_equality_err =
            driver.validate_archive_library_equality(
                archive, image, module_names)
        assert.truthy(archive_equal, archive_equality_err)
        os.remove(image)
        if lfs.attributes(image .. ".dSYM", "mode") then
            remove_tree(image .. ".dSYM")
        end
    end
    return archive
end

describe("multiple logical modules through one public shared library", function()
    local workspace
    local source_root
    local verbose_output

    setup(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root .. "/pkg")

        write_file(source_root .. "/pkg/shared.titan", [[
local visits: integer = 0

function touch(): integer
    visits = visits + 1
    return visits
end
]])
        write_file(source_root .. "/pkg/left.titan", [[
local common = import "pkg.shared"
local current: integer = 10

function read(): integer
    return current + common.touch()
end

do
    current = current + 1
end
]])
        write_file(source_root .. "/pkg/right.titan", [[
local common = import "pkg.shared"
local current: integer = 20

function read(): integer
    return current + common.touch()
end

do
    current = current + 2
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        verbose_output = output
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("publishes one paired provider and emits one shim per logical source module",
       function()
        local archive = assert_provider_pair(workspace, "pkg", {
            "pkg.left", "pkg.right", "pkg.shared",
        }, true)
        assert.same({
            "pkg.left", "pkg.right", "pkg.shared",
        }, archive.key_order)
        for _, name in ipairs({ "left", "right", "shared" }) do
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".c", "mode"))
            assert.equal("file", lfs.attributes(
                source_root .. "/pkg/" .. name .. ".o", "mode"))
            assert.equal("file", lfs.attributes(
                workspace .. "/pkg/" .. name .. ".lua", "mode"))
            assert.is_nil(lfs.attributes(
                workspace .. "/pkg/" .. name .. ".so", "mode"))

            local shim = read_file(workspace .. "/pkg/" .. name .. ".lua")
            assert.equal("-- Generated by titanc; do not edit.",
                shim:match("([^\n]+)"))
            assert.truthy(shim:find('package.searchpath("pkg", package.cpath)',
                1, true), shim)
            assert.truthy(shim:find('"luaopen_pkg_' .. name .. '"', 1, true),
                shim)
        end

        local link_lines = {}
        for line in verbose_output:gmatch("[^\n]+") do
            if line:find("'-shared'", 1, true) then
                table.insert(link_lines, line)
            end
        end
        assert.equal(2, #link_lines, verbose_output)
        local provider_link
        local archive_validation_link
        for _, line in ipairs(link_lines) do
            if line:find("/pkg/left.o'", 1, true) then
                provider_link = line
            elseif line:find("archive%-validation%.so") then
                archive_validation_link = line
            end
        end
        assert.truthy(provider_link, verbose_output)
        assert.truthy(archive_validation_link, verbose_output)
        local left_at = assert(provider_link:find(
            "/pkg/left.o'", 1, true), provider_link)
        local right_at = assert(provider_link:find(
            "/pkg/right.o'", 1, true), provider_link)
        local shared_at = assert(provider_link:find(
            "/pkg/shared.o'", 1, true), provider_link)
        assert.is_true(left_at < right_at and right_at < shared_at,
            provider_link)
        if driver.IS_DARWIN then
            assert.truthy(archive_validation_link:find(
                "'-force_load'", 1, true), archive_validation_link)
        else
            assert.truthy(archive_validation_link:find(
                "'-Wl,--whole-archive'", 1, true), archive_validation_link)
            assert.truthy(archive_validation_link:find(
                "'-Wl,--no-whole-archive'", 1, true),
                archive_validation_link)
        end

        local left_c = read_file(source_root .. "/pkg/left.c")
        assert.falsy(left_c:find("loadlib(L,", 1, true), left_c)
        assert.truthy(left_c:find("extern Udata *pkg_shared_init", 1, true),
            left_c)
    end)

    it("rebuilds deterministic archive bytes when configured tools support D",
       function()
        local before = read_file(workspace .. "/pkg.a")
        local ok, output, why, code = compile(
            workspace, source_root, "-v",
            "pkg.left", "pkg.right", "pkg.shared")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "pkg", {
            "pkg.left", "pkg.right", "pkg.shared",
        })
        -- Verbose output includes capability probes even when they fail.
        -- Inspect only the real staged output command, never tool-probe.a.
        if final_archive_command_uses(output, "qD") and
           final_archive_command_uses(output, "-D") then
            assert.equal(before, read_file(workspace .. "/pkg.a"))
        end
    end)

    it("keeps logical module state independent while reusing the provider",
       function()
        local ok, output = run_lua(workspace, [[
local right = require "pkg.right"
local left = require "pkg.left"
assert(right.read() == 23)
assert(left.read() == 13)
assert(require("pkg.right") == right)
assert(require("pkg.left") == left)
]])
        assert.truthy(ok, output)
    end)

    it("supports a binary-only external consumer through the selected provider",
       function()
        write_file(source_root .. "/consumer.titan", [[
local left = import "pkg.left"
local right = import "pkg.right"

function run(): integer
    return left.read() * 100 + right.read()
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "consumer", { "consumer" })

        local generated = read_file(source_root .. "/consumer.c")
        -- The module protocol renders the import setup in its two initialization
        -- paths, so each of the two logical imports appears twice.
        assert.equal(4, count_plain(generated, 'loadlib(L, "pkg.so")'))
        assert.falsy(generated:find('loadlib(L, "pkg/left.so")', 1, true))
        assert.falsy(generated:find('loadlib(L, "pkg/right.so")', 1, true))
        assert.truthy(generated:find('"pkg_left_abi"', 1, true), generated)
        assert.truthy(generated:find('"pkg_right_abi"', 1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 1224)
]])
        assert.truthy(ok, output)
    end)
end)

describe("native trace names across one multi-module image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"

        write_file(source_root .. "/warmup.titan", [[
function boom(): integer
    raise "warmup"
    return 0
end
]])
        write_file(source_root .. "/trace/right.titan", [[
function boom(): integer
    raise "combined"
    return 0
end
]])
        write_file(source_root .. "/trace/left.titan", [[
local right = import "trace.right"

function relay(): integer
    return right.boom()
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("refreshes libbacktrace and symbolizes frames from separate objects",
       function()
        local ok, output, why, code =
            compile(workspace, source_root, "warmup")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "warmup", { "warmup" })

        ok, output, why, code = compile(
            workspace, source_root, "trace.left", "trace.right")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "trace", {
            "trace.left", "trace.right",
        })
        assert.is_nil(lfs.attributes(workspace .. "/trace/left.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/left.a", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/right.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/trace/right.a", "mode"))

        ok, output = run_lua(workspace, [[
local titan = require "titan"
local warmup = require "warmup"
local warm_ok, warm_err = pcall(warmup.boom)
assert(not warm_ok and warm_err == "warmup")
local warm_trace = titan.backtrace()
assert(warm_trace:find("in warmup.boom", 1, true), warm_trace)

-- Loading trace.so after the first trace must invalidate libbacktrace's
-- snapshot. The next trace crosses the left.c and right.c objects linked into
-- that one provider, and each object contributes its own logical name table.
local left = require "trace.left"
local combined_ok, combined_err = pcall(left.relay)
assert(not combined_ok and combined_err == "combined")
local combined_trace = titan.backtrace()
assert(combined_trace:find("in trace.right.boom", 1, true), combined_trace)
assert(combined_trace:find("in trace.left.relay", 1, true), combined_trace)
assert(combined_trace:find(
    "right%.titan:%d+: in trace%.right%.boom"), combined_trace)
assert(combined_trace:find(
    "left%.titan:%d+: in trace%.left%.relay"), combined_trace)
assert(not combined_trace:find("in warmup.boom", 1, true), combined_trace)
assert(not combined_trace:find("titanentry", 1, true), combined_trace)
]])
        assert.truthy(ok, output)
    end)
end)

describe("rich logical interfaces inside one shared image", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"

        write_file(source_root .. "/shape/provider.titan", [[
record Foo
    n: integer
end

function Foo.make(n: integer): Foo
    return Foo.new(n)
end

function Foo:plus(delta: integer): integer
    return self.n + delta
end

function inc(x: integer): integer
    return x + 1
end

function twice(f: (integer) -> integer, x: integer): integer
    return f(f(x))
end
]])
        write_file(source_root .. "/shape/facade.titan", [[
local provider = import "shape.provider"

type Foo = provider.Foo

function make(n: integer): Foo
    return provider.Foo.make(n)
end

function exact(x: integer): integer
    return provider.twice(provider.inc, x)
end

function generic(x: integer): integer
    local dynamic: value = provider.inc
    local f: (integer) -> integer = dynamic
    return f(x)
end
]])
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("preserves records, aliases, methods, record functions, and function values",
       function()
        local ok, output, why, code = compile(
            workspace, source_root, "shape.provider", "shape.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        assert_provider_pair(workspace, "shape", {
            "shape.facade", "shape.provider",
        })
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/provider.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/provider.a", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/facade.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/shape/facade.a", "mode"))

        write_file(source_root .. "/consumer.titan", [[
local facade = import "shape.facade"

function run(): integer
    local foo: facade.Foo = facade.make(40)
    local plus: (integer) -> integer = foo:plus
    return foo:plus(1) + plus(2) + facade.exact(1) + facade.generic(5)
end
]])
        ok, output, why, code = compile(workspace, source_root, "consumer")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "consumer", { "consumer" })

        local generated = read_file(source_root .. "/consumer.c")
        assert.truthy(generated:find('loadlib(L, "shape.so")', 1, true),
            generated)
        assert.falsy(generated:find(
            'loadlib(L, "shape/facade.so")', 1, true), generated)
        assert.truthy(generated:find(
            'loadglobalsym(L, "shape_provider_Foo_plus_titanmethod")',
            1, true), generated)

        ok, output = run_lua(workspace, [[
local consumer = require "consumer"
assert(consumer.run() == 92)
local facade = require "shape.facade"
local provider = require "shape.provider"
assert(facade.make(7):plus(8) == 15)
assert(provider.Foo.make(9):plus(1) == 10)
]])
        assert.truthy(ok, output)
    end)
end)

describe("public static-provider composition", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root)
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    local function write_app(name, dependency, expected)
        write_file(source_root .. "/apps/" .. name .. ".titan",
            string.format([[
local dependency = import %q

function main(args: {string}): integer
    if dependency.get() == %d then
        return 0
    else
        return 1
    end
end
]], dependency, expected))
    end

    it("honors default/static preference, both fallbacks, and hidden-DSO execution",
       function()
        local dynamic_build = workspace .. "/dynamic"
        local static_build = workspace .. "/static"
        local dynamic_source = dynamic_build .. "/source"
        local static_source = static_build .. "/source"
        make_directory(dynamic_source)
        make_directory(static_source)
        write_file(dynamic_source .. "/choice/api.titan", [[
function get(): integer
    return 11
end
]])
        write_file(static_source .. "/choice/api.titan", [[
function get(): integer
    return 22
end
]])

        local ok, output, why, code =
            compile(dynamic_build, dynamic_source, "choice.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            compile(static_build, static_source, "choice.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local dynamic_dso = dynamic_build .. "/choice/api.so"
        local static_archive = static_build .. "/choice/api.a"
        local selected_dso = workspace .. "/choice/api.so"
        local selected_archive = workspace .. "/choice/api.a"
        copy_file(dynamic_dso, selected_dso)
        copy_file(static_archive, selected_archive)
        local dso_bytes = read_file(selected_dso)
        local archive_bytes = read_file(selected_archive)

        write_app("default_choice", "choice.api", 11)
        ok, output, why, code =
            compile(workspace, source_root, "apps.default_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/default_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_app("static_choice", "choice.api", 22)
        ok, output, why, code = compile(
            workspace, source_root, "--static", "apps.static_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(selected_dso))
        ok, output, why, code =
            run_program(workspace, "apps/static_choice")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- `--static` is a preference: without the archive it uses the DSO.
        write_file(selected_dso, dso_bytes)
        assert.truthy(os.remove(selected_archive))
        write_app("static_dso_fallback", "choice.api", 11)
        ok, output, why, code = compile(
            workspace, source_root, "--static",
            "apps.static_dso_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/static_dso_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Default mode likewise falls through from DSO to archive.
        write_file(selected_archive, archive_bytes)
        assert.truthy(os.remove(selected_dso))
        write_app("default_archive_fallback", "choice.api", 22)
        ok, output, why, code = compile(
            workspace, source_root, "apps.default_archive_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/default_archive_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Source remains the final dependency fallback after both native
        -- format passes.
        assert.truthy(os.remove(selected_archive))
        write_file(source_root .. "/choice/api.titan", [[
function get(): integer
    return 33
end
]])
        write_app("source_fallback", "choice.api", 33)
        ok, output, why, code =
            compile(workspace, source_root, "apps.source_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "apps/source_fallback")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("repackages complete provider membership and consumes it statically",
       function()
        local provider_a = workspace .. "/provider-a"
        local provider_b = workspace .. "/provider-b"
        local source_a = provider_a .. "/source"
        local source_b = provider_b .. "/source"
        make_directory(source_a)
        make_directory(source_b)
        write_file(source_a .. "/base/owner.titan", [[
record Box
    n: integer
end

function make(n: integer): Box
    return Box.new(n)
end
]])
        write_file(source_a .. "/base/facade.titan", [[
local owner = import "base.owner"
type Box = owner.Box

function get(): integer
    return owner.make(40).n
end
]])
        local ok, output, why, code = compile(
            provider_a, source_a, "base.owner", "base.facade")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        copy_file(provider_a .. "/base.so", provider_b .. "/base.so")
        copy_file(provider_a .. "/base.a", provider_b .. "/base.a")

        write_file(source_b .. "/bundle/api.titan", [[
local facade = import "base.facade"

function get(): integer
    return facade.get() + 2
end
]])
        ok, output, why, code = compile(
            provider_b, source_b, "--static", "bundle.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local bundle = assert_provider_pair(
            provider_b, "bundle/api", {
                "base.facade", "base.owner", "bundle.api",
            }, true)
        assert.same({
            "base.facade", "base.owner", "bundle.api",
        }, bundle.key_order)
        assert.equal("file", lfs.attributes(
            provider_b .. "/base/facade.lua", "mode"))
        assert.equal("file", lfs.attributes(
            provider_b .. "/base/owner.lua", "mode"))

        -- The selected provider has been flattened into B. Remove A entirely
        -- before compiling and running the static consumer.
        assert.truthy(os.remove(provider_b .. "/base.so"))
        assert.truthy(os.remove(provider_b .. "/base.a"))
        write_file(source_b .. "/app.titan", [[
local api = import "bundle.api"

function main(args: {string}): integer
    if api.get() == 42 then
        return 0
    else
        return 1
    end
end
]])
        ok, output, why, code =
            compile(provider_b, source_b, "--static", "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(provider_b .. "/bundle/api.so"))
        os.remove(provider_b .. "/bundle/api.lua")
        ok, output, why, code = run_program(provider_b, "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Carried physical membership remains unavailable through an
        -- unrelated ordinary lookup: bundle/api.a is not a candidate for
        -- base.owner.
        write_file(source_b .. "/negative.titan", [[
local owner = import "base.owner"

function probe(): integer
    return owner.make(1).n
end
]])
        ok, output = compile(provider_b, source_b, "--static", "negative")
        assert.falsy(ok)
        assert.truthy(output:find(
            "module 'base.owner' not found", 1, true), output)
    end)

    it("selects and repackages a real macOS universal provider",
       function()
        if not driver.IS_DARWIN then return end

        write_file(source_root .. "/fat/api.titan", [[
function get(): integer
    return 42
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "fat.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        local generated = source_root .. "/fat/api.c"
        local function compile_arch(arch)
            local object = workspace .. "/fat-api-" .. arch .. ".o"
            local argv = { "env", "CCACHE_DISABLE=1" }
            for _, word in ipairs(configured_words(driver.CC)) do
                argv[#argv + 1] = word
            end
            argv[#argv + 1] = "-arch"
            argv[#argv + 1] = arch
            for _, word in ipairs(configured_words(driver.CFLAGS)) do
                argv[#argv + 1] = word
            end
            for _, word in ipairs({
                "-c", generated,
                "-I", assert(driver.INCLUDE_PATH),
                "-I", assert(driver.LUA_SOURCE_PATH),
                "-o", object,
            }) do
                argv[#argv + 1] = word
            end
            local compiled, compile_output = run(argv, workspace)
            assert.truthy(compiled, compile_output)
            return object
        end

        local x86_archive = make_archive(
            workspace, "fat-api-x86_64.a", {
                compile_arch("x86_64"),
            })
        local arm_archive = make_archive(
            workspace, "fat-api-arm64.a", {
                compile_arch("arm64"),
            })
        local universal = workspace .. "/fat/api.a"
        assert.truthy(os.remove(universal))
        ok, output = run({
            "/usr/bin/lipo", "-create",
            x86_archive, arm_archive,
            "-output", universal,
        }, workspace)
        assert.truthy(ok, output)
        assert.truthy(os.remove(workspace .. "/fat/api.so"))

        local fat, fat_err = staticmetadata.scan_archive(
            universal, metadata_options())
        assert.truthy(fat, fat_err)
        assert.equal("fat_archive", fat.kind)
        assert.same({ "fat.api" }, fat.key_order)
        assert.equal(2, #fat.slices)

        write_file(source_root .. "/bundle/api.titan", [[
local fat = import "fat.api"

function get(): integer
    return fat.get()
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "bundle.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local bundle = assert_provider_pair(
            workspace, "bundle/api", {
                "bundle.api", "fat.api",
            }, true)
        assert.equal("archive", bundle.kind)
        assert.same({ "bundle.api", "fat.api" }, bundle.key_order)

        local libtool_archive = workspace .. "/bundle-libtool.a"
        ok, output = run({
            "/usr/bin/libtool", "-static", "-o", libtool_archive,
            workspace .. "/bundle/api.a",
        }, workspace)
        assert.truthy(ok, output)
        local libtool_result, libtool_err = staticmetadata.scan_archive(
            libtool_archive, metadata_options())
        assert.truthy(libtool_result, libtool_err)
        assert.equal("archive", libtool_result.kind)
        assert.same(bundle.key_order, libtool_result.key_order)

        assert.truthy(os.remove(universal))
        assert.truthy(os.remove(workspace .. "/bundle/api.so"))
        write_file(source_root .. "/universal_app.titan", [[
local api = import "bundle.api"

function main(args: {string}): integer
    if api.get() == 42 then return 0 else return 1 end
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "universal_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        ok, output, why, code =
            run_program(workspace, "universal_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("keeps unused archive members unextracted and resolves later -X runtime references",
       function()
        local missing_header = source_root .. "/never_available.h"
        write_file(missing_header,
            "int titan_test_never_available(void);\n")
        write_file(source_root .. "/bundle/api.titan", [[
function get(): integer
    return 42
end
]])
        write_file(source_root .. "/bundle/unused.titan",
            string.format([[
local private = foreign import %q

function get(): integer
    return private.titan_test_never_available() as integer
end
]], missing_header))
        local definition = compile_c_object(
            workspace, "never-available-definition", [[
int titan_test_never_available(void) { return 9; }
]])
        local ok, output, why, code = compile(
            workspace, source_root, "bundle.api", "bundle.unused",
            "-X", definition)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        -- Rebuild the candidate archive from only the two Titan objects. The
        -- unused module now has an intentionally unresolved private native
        -- dependency which must remain inert under ordinary extraction.
        local lean_archive = make_archive(
            workspace, "lean-bundle.a", {
                source_root .. "/bundle/api.o",
                source_root .. "/bundle/unused.o",
            })
        copy_file(lean_archive, workspace .. "/bundle.a")

        local support = compile_c_object(
            workspace, "support-needs-titan-runtime", [[
typedef struct lua_State lua_State;
extern void titan_invalidate_backtrace_state(lua_State *L);
void support_needs_titan_runtime(void) {
    titan_invalidate_backtrace_state((lua_State *)0);
}
]])
        write_file(source_root .. "/app.titan", [[
local api = import "bundle.api"

function main(args: {string}): integer
    if api.get() == 42 then return 0 else return 1 end
end
]])
        ok, output, why, code = compile(
            workspace, source_root, "--static", "app", "-X", support)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert.truthy(os.remove(workspace .. "/bundle.so"))
        os.remove(workspace .. "/bundle/api.lua")
        os.remove(workspace .. "/bundle/unused.lua")
        ok, output, why, code = run_program(workspace, "app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("carries object/archive -X payload into both forms and rejects metadata",
       function()
        local direct = compile_c_object(workspace, "direct-payload",
            "int direct_payload(void) { return 17; }\n")
        local archived_object = compile_c_object(
            workspace, "archived-payload",
            "int archived_payload(void) { return 19; }\n")
        local payload_archive = make_archive(
            workspace, "native-payload.a", { archived_object })
        local leading_dash = compile_c_object(
            workspace, "-leading-payload",
            "int leading_dash_payload(void) { return 23; }\n")
        local leading_dash_relative =
            assert(leading_dash:match("([^/]+)$"))
        write_file(source_root .. "/payload/item.titan", [[
function get(): integer
    return 7
end
]])

        local ok, output, why, code = compile(
            workspace, source_root, "-v", "payload.item",
            "--extra-object=" .. leading_dash_relative,
            direct, payload_archive)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local dso_link = assert(output:match("[^\n]*'%-shared'[^\n]*"),
            output)
        local direct_at = assert(dso_link:find(direct, 1, true), dso_link)
        local archive_at =
            assert(dso_link:find(payload_archive, 1, true), dso_link)
        local leading_dash_at =
            assert(dso_link:find(leading_dash, 1, true), dso_link)
        assert.is_true(
            leading_dash_at < direct_at and direct_at < archive_at,
            dso_link)
        local provider = assert_provider_pair(
            workspace, "payload/item", { "payload.item" }, true)
        assert.equal(4, #provider.members)
        for _, output_path in ipairs({
            workspace .. "/payload/item.so",
            workspace .. "/payload/item.a",
        }) do
            local symbols = native_symbols(workspace, output_path)
            assert.truthy(symbols:find("direct_payload", 1, true), symbols)
            assert.truthy(symbols:find("archived_payload", 1, true), symbols)
            assert.truthy(symbols:find(
                "leading_dash_payload", 1, true), symbols)
        end

        write_file(source_root .. "/bad/item.titan", [[
function get(): integer
    return 9
end
]])
        ok, output = compile(
            workspace, source_root, "bad.item",
            "-X", source_root .. "/payload/item.o")
        assert.falsy(ok)
        assert.truthy(output:find(
            "contains Titan module metadata", 1, true), output)
        assert.is_nil(lfs.attributes(
            workspace .. "/bad/item.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/bad/item.a", "mode"))
    end)
end)

describe("multi-module library preflight and native support contracts", function()
    local workspace
    local source_root

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
        source_root = workspace .. "/source"
        make_directory(source_root)
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("rejects unrelated roots before producing compiler artifacts", function()
        write_file(source_root .. "/alpha.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/beta.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root, "alpha", "beta")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link modules into one shared library: 'alpha' and 'beta' " ..
            "have no common module prefix", 1, true), output)
        for _, path in ipairs({
            source_root .. "/alpha.c", source_root .. "/alpha.o",
            source_root .. "/beta.c", source_root .. "/beta.o",
            workspace .. "/alpha.so", workspace .. "/alpha.a",
            workspace .. "/alpha.lua",
            workspace .. "/beta.so", workspace .. "/beta.a",
            workspace .. "/beta.lua",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end
    end)

    it("rejects replacing a selected dynamic input provider before code generation",
       function()
        write_file(source_root .. "/foo/dep.titan",
            "function get(): integer return 1 end\n")
        write_file(source_root .. "/foo/seed.titan",
            "function get(): integer return 2 end\n")
        local ok, output, why, code = compile(
            workspace, source_root, "foo.dep", "foo.seed")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        local old_provider = read_file(workspace .. "/foo.so")

        write_file(source_root .. "/foo/left.titan", [[
local dep = import "foo.dep"
function get(): integer return dep.get() end
]])
        write_file(source_root .. "/foo/right.titan", [[
local dep = import "foo.dep"
function get(): integer return dep.get() + 1 end
]])
        ok, output = compile(
            workspace, source_root, "foo.left", "foo.right")
        assert.falsy(ok)
        assert.truthy(output:find("native provider output", 1, true), output)
        assert.truthy(output:find("aliases input", 1, true), output)
        assert.equal(old_provider, read_file(workspace .. "/foo.so"))
        assert.is_nil(lfs.attributes(
            source_root .. "/foo/left.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/foo/right.c", "mode"))
    end)

    it("rejects mangled symbol collisions before code generation", function()
        write_file(source_root .. "/clash/a-b.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/clash/a/b.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "clash.a-b", "clash.a.b")
        assert.falsy(ok)
        assert.truthy(output:find("both use C symbol prefix 'clash_a_b'", 1,
            true), output)
        assert.is_nil(lfs.attributes(source_root .. "/clash/a-b.c", "mode"))
        assert.is_nil(lfs.attributes(source_root .. "/clash/a/b.c", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/clash.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/clash.a", "mode"))
    end)

    it("rejects module/member boundary symbol collisions before code generation",
       function()
        write_file(source_root .. "/boundary/root.titan", [[
function child_leaf(): integer return 1 end
function main(args: {string}): integer return 0 end
]])
        write_file(source_root .. "/boundary/root/child.titan",
            "function leaf(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root,
            "boundary.root", "boundary.root.child")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link C symbol 'boundary_root_child_leaf_titan'", 1,
            true), output)
        assert.truthy(output:find("function 'boundary.root.child_leaf'", 1,
            true), output)
        assert.truthy(output:find("function 'boundary.root.child.leaf'", 1,
            true), output)
        for _, path in ipairs({
            source_root .. "/boundary/root.c",
            source_root .. "/boundary/root.o",
            source_root .. "/boundary/root/child.c",
            source_root .. "/boundary/root/child.o",
            workspace .. "/boundary/root.so",
            workspace .. "/boundary/root.a",
            workspace .. "/boundary/root.lua",
            workspace .. "/boundary/root/child.lua",
            workspace .. "/boundary/root",
        }) do
            assert.is_nil(lfs.attributes(path, "mode"), path)
        end
    end)

    it("preflights symbols from producer-dynamic contextual owners",
       function()
        write_file(source_root .. "/a.titan", [[
record R
    n: integer
end

function b_c(): integer
    return 1
end
]])
        local ok, output, why, code =
            compile(workspace, source_root, "a")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_file(source_root .. "/facade/api.titan", [[
local owner = import "a"
type R = owner.R
]])
        ok, output, why, code =
            compile(workspace, source_root, "facade.api")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")

        write_file(source_root .. "/a_b.titan",
            "function c(): integer return 2 end\n")
        write_file(source_root .. "/app.titan", [[
local facade = import "facade.api"

function main(args: {string}): integer
    return 0
end
]])
        ok, output = compile(
            workspace, source_root, "--static", "app", "a_b")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link C symbol 'a_b_c_titan'", 1, true), output)
        assert.truthy(output:find(
            "function 'a.b_c'", 1, true), output)
        assert.truthy(output:find(
            "function 'a_b.c'", 1, true), output)
        assert.is_nil(lfs.attributes(source_root .. "/app.c", "mode"))
        assert.is_nil(lfs.attributes(source_root .. "/a_b.c", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/app", "mode"))
    end)

    it("preflights record-function and bound-method symbols", function()
        write_file(source_root .. "/record_boundary/root.titan", [[
record child_Thing
    n: integer
end

function child_Thing:run(): integer
    return self.n
end
]])
        write_file(source_root .. "/record_boundary/root/child.titan", [[
record Thing
    n: integer
end

function Thing:run(): integer
    return self.n
end
]])

        local ok, output = compile(workspace, source_root,
            "record_boundary.root", "record_boundary.root.child")
        assert.falsy(ok)
        for _, symbol in ipairs({
            "record_boundary_root_child_Thing_new_titanstatic",
            "record_boundary_root_child_Thing_run_titanmethod",
            "record_boundary_root_child_Thing_run_boundmethod",
            "record_boundary_root_child_Thing_run_titanentry_boundlua",
        }) do
            assert.truthy(output:find(
                "cannot link C symbol '" .. symbol .. "'", 1, true), output)
        end
        assert.is_nil(lfs.attributes(
            source_root .. "/record_boundary/root.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/record_boundary/root/child.c", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/record_boundary/root.so", "mode"))
        assert.is_nil(lfs.attributes(
            workspace .. "/record_boundary/root.a", "mode"))
    end)

    it("preflights cross-family protocol symbols from source dependencies",
       function()
        write_file(source_root .. "/bundle/foo_abi.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/bundle/left.titan", [[
local other = import "luaopen.bundle.foo"
function probe(): integer return other.probe() end
]])
        write_file(source_root .. "/luaopen/bundle/foo.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(workspace, source_root,
            "bundle.left", "bundle.foo_abi")
        assert.falsy(ok)
        assert.truthy(output:find(
            "cannot link C symbol 'luaopen_bundle_foo_abi'", 1, true),
            output)
        assert.truthy(output:find("module Lua entry", 1, true), output)
        assert.truthy(output:find("module ABI entry", 1, true), output)
        assert.is_nil(lfs.attributes(source_root .. "/bundle/left.c", "mode"))
        assert.is_nil(lfs.attributes(
            source_root .. "/luaopen/bundle/foo.c", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/bundle.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/bundle.a", "mode"))
    end)

    it("refuses an unrecognized Lua shim before changing C output", function()
        write_file(source_root .. "/owned/item.titan",
            "function probe(): integer return 1 end\n")
        write_file(workspace .. "/owned/item.lua", "return 'user file'\n")

        local ok, output = compile(workspace, source_root, "owned.item")
        assert.falsy(ok)
        assert.truthy(output:find(
            "refusing to overwrite unrecognized Lua file 'owned/item.lua'",
            1, true), output)
        assert.equal("return 'user file'\n",
            read_file(workspace .. "/owned/item.lua"))
        assert.is_nil(lfs.attributes(source_root .. "/owned/item.c", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/owned/item.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/owned/item.a", "mode"))
    end)

    it("requires semantic native support in a physical titan provider", function()
        write_file(source_root .. "/titan/one.titan",
            "function probe(): integer return 1 end\n")
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")

        local ok, output = compile(
            workspace, source_root, "titan.one", "titan.two")
        assert.falsy(ok)
        assert.truthy(output:find(
            "linked provider 'titan' has an invalid native support entry", 1,
            true), output)
        assert.is_nil(lfs.attributes(workspace .. "/titan.so", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan.a", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/one.lua", "mode"))
        assert.is_nil(lfs.attributes(workspace .. "/titan/two.lua", "mode"))
    end)

    it("accepts the reviewed native support object and leaves bare support inert",
       function()
        write_file(source_root .. "/titan/one.titan", [[
local initialized: integer = 0
function probe(): integer return initialized end
do initialized = initialized + 1 end
]])
        write_file(source_root .. "/titan/two.titan",
            "function probe(): integer return 2 end\n")
        write_file(workspace .. "/registry-probe.c", [[
#include "lua.h"
#include "lauxlib.h"
int luaopen_probe_registry(lua_State *L) {
    int present;
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module titan.one");
    present = !lua_isnil(L, -1);
    lua_pop(L, 1);
    lua_pushboolean(L, present);
    return 1;
}
]])
        local compiler = {
            "env", "CCACHE_DISABLE=1",
        }
        for _, word in ipairs(configured_words(driver.CC)) do
            compiler[#compiler + 1] = word
        end
        for _, word in ipairs({
            "-std=c99", "-fPIC", "-I", LUA_INCLUDE,
            "-c", "registry-probe.c", "-o", "registry-probe.o",
        }) do
            compiler[#compiler + 1] = word
        end
        local compiled, compile_output = run(compiler, workspace)
        assert.truthy(compiled, compile_output)

        local ok, output, why, code = compile(
            workspace, source_root, "titan.one", "titan.two",
            "-X", REPO .. "/titan-runtime/titanlib.o",
            workspace .. "/registry-probe.o")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
        assert_provider_pair(workspace, "titan", {
            "titan.one", "titan.two",
        })

        ok, output = run_lua(workspace, [[
local support = require "titan"
assert(type(support._loadlib) == "function")
assert(type(support._loadlibglobal) == "function")
local registry_probe = assert(package.loadlib(
    "./titan.so", "luaopen_probe_registry"))
assert(registry_probe() == false)
local one = require "titan.one"
local two = require "titan.two"
assert(registry_probe() == true)
assert(one.probe() == 1)
assert(two.probe() == 2)
]])
        assert.truthy(ok, output)

        -- The semantic gate owns a fresh controlled Lua process. A parent
        -- compiler may itself have used -E; an inherited LUA_INIT must not be
        -- able to alter package.loadlib or forge the gate's result file.
        write_file(workspace .. "/hostile-init.lua",
            [[error("LUA_INIT reached Titan support validation", 0)]])
        write_file(workspace .. "/validate-support.lua", string.format([[
package.path = %q .. package.path
package.cpath = %q .. package.cpath
local driver = require "titan-compiler.driver"
local valid, validation_error = driver.validate_titan_support(arg[1])
assert(valid, validation_error)
]], REPO .. "/?.lua;" .. REPO .. "/?/init.lua;",
            REPO .. "/?.so;"))
        local validate_argv = {
            "env", "LUA_INIT=@" .. workspace .. "/hostile-init.lua",
        }
        if PREFIX then
            validate_argv[#validate_argv + 1] =
                "TITAN_ROCKS_ROOT=" .. PREFIX
        end
        validate_argv[#validate_argv + 1] = LUA
        validate_argv[#validate_argv + 1] = "-E"
        validate_argv[#validate_argv + 1] =
            workspace .. "/validate-support.lua"
        validate_argv[#validate_argv + 1] = workspace .. "/titan.so"
        ok, output = run(validate_argv, workspace)
        assert.truthy(ok, output)

        -- A shallow titan.a selected by a standalone owns the bare native
        -- support entry as well as logical titan.* protocols. Rebuild it from
        -- only the logical module objects to prove the executable gate catches
        -- a missing luaopen_titan before publishing the program.
        local no_support = make_archive(
            workspace, "titan-without-support.a", {
                source_root .. "/titan/one.o",
                source_root .. "/titan/two.o",
            })
        copy_file(no_support, workspace .. "/titan.a")
        write_file(source_root .. "/support_app.titan", [[
local one = import "titan.one"
function main(args: {string}): integer return one.probe() end
]])
        ok, output = compile(
            workspace, source_root, "--static", "support_app")
        assert.falsy(ok)
        assert.truthy(output:find(
            "selected static provider failed executable-context protocol linking",
            1, true), output)
        assert.is_nil(lfs.attributes(workspace .. "/support_app", "mode"))
    end)
end)

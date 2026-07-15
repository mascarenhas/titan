local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"
local titan = require "titan"

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
end

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

describe("compiler installation discovery", function()
    it("uses the first literal Lua 5.5 C-module prefix", function()
        local cpath = table.concat({
            "/first prefix/lib/titan/0.11/?.so",
            "/wrong/lib/lua/5.4/?.so",
            "/also-wrong/lib/lua/5.5/?.dylib",
            "/first prefix/lib/lua/5.5/?.so",
            "/second/lib/lua/5.5/?.so",
        }, ";")
        assert.equal("/first prefix",
            driver.root_from_package_cpath(cpath))
    end)

    it("rejects suffix lookalikes and handles the filesystem root", function()
        assert.is_nil(driver.root_from_package_cpath(table.concat({
            "/prefix/lib/lua/5.5/?x.so",
            "/prefix/lib/lua/5.5/?.so.debug",
            "/prefix/lib/lua/5.5/sub/?.so",
        }, ";")))
        assert.equal("/", driver.root_from_package_cpath(
            "/lib/lua/5.5/?.so;/later/lib/lua/5.5/?.so"))
        assert.is_nil(driver.root_from_package_cpath(nil))
    end)

    it("gives the internal installation override precedence", function()
        assert.equal("/post-install/tree", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", "/post-install/tree/"))
        assert.equal("/lua/prefix", driver.resolve_installation_root(
            "/lua/prefix/lib/lua/5.5/?.so", ""))
    end)

    it("derives all installed compiler paths from one root", function()
        local paths = assert(driver.installed_paths("/opt/titan/"))
        assert.same({
            root = "/opt/titan",
            lua_source = "/opt/titan/src/lua-5.5.0",
            include = "/opt/titan/include",
            lib = "/opt/titan/lib",
            libtitan = "/opt/titan/lib/libtitan.a",
            libbacktrace = "/opt/titan/lib/libbacktrace.a",
            liblua = "/opt/titan/lib/liblua.a",
            titan_bin = "/opt/titan/lib/titan/0.11",
            lua_cpath = "/opt/titan/lib/titan/0.11/?.so",
        }, paths)

        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-ldl", "-lm",
        }, driver.installed_link_inputs(paths, false))
        assert.same({
            "/opt/titan/lib/libtitan.a",
            "/opt/titan/lib/libbacktrace.a",
            "/opt/titan/lib/liblua.a",
            "-lm",
        }, driver.installed_link_inputs(paths, true))
    end)

    it("identifies a checkout from driver provenance, not the working directory",
       function()
        local checkout = lfs.currentdir()
        assert.is_true(driver.source_checkout_from_driver_source(
            "@" .. checkout .. "/titan-compiler/driver.lua", "/tmp"))
        assert.is_true(driver.source_checkout_from_driver_source(
            "@./titan-compiler/driver.lua", checkout))
        assert.is_false(driver.source_checkout_from_driver_source(
            "@/opt/titan/share/lua/5.5/titan-compiler/driver.lua",
            checkout))
    end)

    it("requires exactly the three runtime archive members", function()
        assert.is_true(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF SORTED\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_true(driver.runtime_archive_members_are_exact(
            "__.SYMDEF_64\ntitan.o\ntitan_coro.o\ntitan_uv.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "__.SYMDEF\ntitan.o\ntitan_coro.o\ntitan_uv.o\nstale.o\n"))
        assert.is_false(driver.runtime_archive_members_are_exact(
            "titan_coro.o\ntitan.o\ntitan_uv.o\n"))
    end)

    it("links source builds through the complete runtime archive", function()
        assert.same({
            "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.0/src/liblua.a",
            "-ldl", "-lm",
        }, driver.source_link_inputs("lua-5.5.0/src"))
    end)
end)

describe("compiler module loader", function()
    local root
    local source
    local binary
    local previous

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))
        source = root .. "/source"
        binary = root .. "/binary"
        assert(lfs.mkdir(source))
        assert(lfs.mkdir(binary))
        assert(lfs.mkdir(source .. "/titan"))
        assert(lfs.mkdir(binary .. "/titan"))

        previous = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            imported = driver.imported,
            registry = types.registry,
            loadlib = titan._loadlib,
        }
        driver.TITAN_SOURCE_PATH = source
        driver.TITAN_BIN_PATH = binary
        driver.imported = {}
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.imported = previous.imported
        types.registry = previous.registry
        titan._loadlib = previous.loadlib
        remove_tree(root)
    end)

    it("uses binaries for dependencies and source for explicit roots", function()
        write_file(source .. "/titan/timer.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(binary .. "/titan/timer.so", "mock interface\n")

        local symbols = {}
        titan._loadlib = function(filename, symbol)
            assert.equal(binary .. "/titan/timer.so", filename)
            symbols[#symbols + 1] = symbol
            if symbol == "titan_timer_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "titan_timer_types" then
                return function() return "Module('titan.timer',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors =
            driver.defaultloader({})("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "titan_timer_abi", "titan_timer_types" }, symbols)
        assert.is_nil(driver.imported["titan.timer"].ast)

        -- A later explicit build request replaces a cached binary interface
        -- with the source root instead of silently treating compilation as a
        -- no-op.
        local deps = {}
        ok, modtype, errors = driver.defaultloader(deps, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.is_table(driver.imported["titan.timer"].ast)
        assert.equal(true, deps["titan.timer"])
    end)

    it("requires source for an explicit build root", function()
        write_file(binary .. "/titan/timer.so", "existing binary\n")
        titan._loadlib = function()
            error("an explicit source build must not load its existing binary")
        end

        local ok, message = driver.defaultloader({}, {
            source_roots = { ["titan.timer"] = true },
        })("titan.timer")

        assert.falsy(ok)
        assert.equal("source module 'titan.timer' not found", message)
        assert.is_nil(driver.imported["titan.timer"])
    end)

    it("reports a missing ABI entry from the internal loader", function()
        write_file(binary .. "/extension.so", "mock image\n")
        local calls = 0
        titan._loadlib = function(filename, symbol)
            calls = calls + 1
            assert.equal(binary .. "/extension.so", filename)
            assert.equal("extension_abi", symbol)
            return nil, "undefined symbol: extension_abi", "init"
        end

        local ok, message = driver.defaultloader({})("extension")
        assert.falsy(ok)
        assert.match("has no compatible Titan ABI marker", message)
        assert.equal(1, calls)
    end)

    it("records a cached table-loader import as a dependency", function()
        local modtype = types.Module("cached", {})
        local imported = { cached = { type = modtype } }
        local deps = {}

        local ok, loaded, errors =
            driver.tableloader({}, imported, deps)("cached")

        assert.truthy(ok)
        assert.equal(modtype, loaded)
        assert.equal(0, #errors)
        assert.equal(true, deps.cached)
    end)
end)

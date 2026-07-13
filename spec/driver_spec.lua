local lfs = require "lfs"
local assert = require "luassert"

local driver = require "titan-compiler.driver"
local types = require "titan-compiler.types"

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
            titan_stdlib = "/opt/titan/lib/titan/0.11/titan",
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
    local standard_bin
    local application_source
    local application_bin
    local previous

    before_each(function()
        root = os.tmpname()
        assert(os.remove(root))
        assert(lfs.mkdir(root))

        source = root .. "/stdlib"
        standard_bin = root .. "/stdlib-bin"
        application_source = root .. "/application"
        application_bin = root .. "/application-bin"
        for _, path in ipairs({
            source, standard_bin, application_source, application_bin,
        }) do
            assert(lfs.mkdir(path))
        end

        previous = {
            source_path = driver.TITAN_SOURCE_PATH,
            bin_path = driver.TITAN_BIN_PATH,
            stdlib_path = driver.TITAN_STDLIB_PATH,
            stdlib_implicit_prefix = driver.TITAN_STDLIB_IMPLICIT_PREFIX,
            install_paths = driver.INSTALL_PATHS,
            imported = driver.imported,
            uv_provider_path = driver._uv_provider_path,
            registry = types.registry,
            loadlib = package.loadlib,
        }
        driver.imported = {}
        driver._uv_provider_path = nil
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.TITAN_STDLIB_PATH = previous.stdlib_path
        driver.TITAN_STDLIB_IMPLICIT_PREFIX =
            previous.stdlib_implicit_prefix
        driver.INSTALL_PATHS = previous.install_paths
        driver.imported = previous.imported
        driver._uv_provider_path = previous.uv_provider_path
        types.registry = previous.registry
        package.loadlib = previous.loadlib
        remove_tree(root)
    end)

    it("tracks a binary standard dependency of a standard source", function()
        write_file(source .. "/coroutine.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(source .. "/os.titan", [[
            local coroutine = import "coroutine"

            function marker(): integer
                return 1
            end
        ]])
        write_file(standard_bin .. "/coroutine.so", "mock interface\n")

        -- Make the canonical files visible through the application paths too.
        -- They must not be mistaken for shadows of themselves.
        driver.TITAN_SOURCE_PATH = source .. ";" .. application_source
        driver.TITAN_BIN_PATH = standard_bin .. ";" .. application_bin

        local loaded_symbols = {}
        package.loadlib = function(filename, symbol)
            assert.equal(standard_bin .. "/coroutine.so", filename)
            loaded_symbols[symbol] = true
            if symbol == "coroutine_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "coroutine_types" then
                return function() return "Module('coroutine',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local static_deps = {}
        local options = {
            stdlib_build_root = "os",
            stdlib_source_path = source,
            stdlib_path = standard_bin,
        }
        local ok, modtype, errors =
            driver.defaultloader(static_deps, options)("os")

        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.truthy(loaded_symbols.coroutine_abi)
        assert.truthy(loaded_symbols.coroutine_types)
        assert.equal(true, static_deps.os)
        assert.equal(driver.STANDARD_DEPENDENCY, static_deps.coroutine)
        assert.equal(driver.STANDARD_DEPENDENCY,
            driver.imported.os.deps.coroutine)

        local closure = driver.dependency_closure("os")
        assert.equal(true, closure.os)
        assert.equal(driver.STANDARD_DEPENDENCY, closure.coroutine)

        -- A later root gets the complete dependency closure even though both
        -- modules now come from the import cache.
        local cached_deps = {}
        local cached_ok =
            driver.defaultloader(cached_deps, options)("os")
        assert.truthy(cached_ok)
        assert.equal(true, cached_deps.os)
        assert.equal(driver.STANDARD_DEPENDENCY, cached_deps.coroutine)
    end)

    it("prefixes standard binaries under the default parent path", function()
        local canonical = standard_bin .. "/titan"
        assert(lfs.mkdir(canonical))
        write_file(canonical .. "/coroutine.so", "mock interface\n")

        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin
        driver.TITAN_STDLIB_PATH = standard_bin
        driver.TITAN_STDLIB_IMPLICIT_PREFIX = true
        package.loadlib = function(filename, symbol)
            assert.equal(canonical .. "/coroutine.so", filename)
            if symbol == "coroutine_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "coroutine_types" then
                return function() return "Module('coroutine',{})" end
            end
            return nil, "unexpected symbol " .. symbol
        end

        local ok, modtype, errors = driver.defaultloader({})("coroutine")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
    end)

    it("rejects an installed parent shadow of the qualified standard image",
       function()
        local canonical = standard_bin .. "/titan"
        assert(lfs.mkdir(canonical))
        write_file(canonical .. "/coroutine.so", "canonical image\n")
        write_file(application_bin .. "/coroutine.so", "copied image\n")

        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin
        driver.TITAN_STDLIB_PATH = standard_bin
        driver.TITAN_STDLIB_IMPLICIT_PREFIX = true
        driver.INSTALL_PATHS = { titan_bin = application_bin }
        local ok, message = driver.defaultloader({})("coroutine")
        assert.falsy(ok)
        assert.match("reserved standard module 'coroutine' is shadowed " ..
            "by local binary", message)
    end)

    it("rejects application source and binary shadows of standard modules",
       function()
        write_file(source .. "/coroutine.titan", [[
            function marker(): integer
                return 1
            end
        ]])
        write_file(standard_bin .. "/coroutine.so", "mock interface\n")
        write_file(application_source .. "/coroutine.titan", [[
            function impostor(): integer
                return 2
            end
        ]])

        package.loadlib = function()
            error("a shadowed standard module must not be loaded")
        end

        local options = {
            stdlib_source_path = source,
            stdlib_path = standard_bin,
        }
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin
        local ok, err = driver.defaultloader({}, options)("coroutine")
        assert.falsy(ok)
        assert.match("reserved standard module 'coroutine'.*shadowed by " ..
            "application source", err)

        assert(os.remove(application_source .. "/coroutine.titan"))
        write_file(application_bin .. "/coroutine.so", "impostor\n")
        driver.imported = {}
        ok, err = driver.defaultloader({}, options)("coroutine")
        assert.falsy(ok)
        assert.match("reserved standard module 'coroutine'.*shadowed by " ..
            "local binary", err)
    end)

    it("loads one canonical uv provider globally before its interface",
       function()
        write_file(standard_bin .. "/uv.so", "mock provider\n")
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin

        local symbols = {}
        package.loadlib = function(filename, symbol)
            assert.equal(standard_bin .. "/uv.so", filename)
            symbols[#symbols + 1] = symbol
            if symbol == "*" then
                return true
            elseif symbol == "uv_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "uv_types" then
                return function() return "Module('uv',{})" end
            end
            return nil, "unexpected symbol " .. symbol, "init"
        end

        local options = { stdlib_path = standard_bin }
        local ok, modtype, errors = driver.defaultloader({}, options)("uv")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.same({ "*", "uv_abi", "uv_types" }, symbols)

        local second = root .. "/other-stdlib"
        assert(lfs.mkdir(second))
        write_file(second .. "/uv.so", "second provider\n")
        driver.imported = {}
        ok, modtype = driver.defaultloader({}, { stdlib_path = second })("uv")
        assert.falsy(ok)
        assert.match("refusing a second provider", modtype)
    end)

    it("marks an ordinary binary that needs the canonical uv provider",
       function()
        write_file(standard_bin .. "/uv.so", "mock provider\n")
        write_file(application_bin .. "/direct.so", "mock extension\n")
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin

        local provider_loaded = false
        package.loadlib = function(filename, symbol)
            if filename == standard_bin .. "/uv.so" then
                assert.equal("*", symbol)
                provider_loaded = true
                return true
            end
            assert.equal(application_bin .. "/direct.so", filename)
            if symbol == "direct_abi" and not provider_loaded then
                return nil, "undefined symbol: uv_random", "open"
            elseif symbol == "direct_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "direct_types" then
                return function()
                    return "Module('direct',{})", "uv-provider"
                end
            end
            return nil, "unexpected symbol " .. symbol, "init"
        end

        local deps = {}
        local ok, modtype, errors = driver.defaultloader(deps, {
            stdlib_path = standard_bin,
        })("direct")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.truthy(provider_loaded)
        assert.equal(driver.UV_DYNAMIC_DEPENDENCY, deps.direct)
    end)

    it("rejects an unresolved libuv binary without provider metadata",
       function()
        write_file(standard_bin .. "/uv.so", "mock provider\n")
        write_file(application_bin .. "/direct.so", "mock extension\n")
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin

        local provider_loaded = false
        package.loadlib = function(filename, symbol)
            if filename == standard_bin .. "/uv.so" then
                assert.equal("*", symbol)
                provider_loaded = true
                return true
            end
            assert.equal(application_bin .. "/direct.so", filename)
            if symbol == "direct_abi" and not provider_loaded then
                return nil, "undefined symbol: uv_random", "open"
            elseif symbol == "direct_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "direct_types" then
                return function() return "Module('direct',{})" end
            end
            return nil, "unexpected symbol " .. symbol, "init"
        end

        local ok, message = driver.defaultloader({}, {
            stdlib_path = standard_bin,
        })("direct")
        assert.falsy(ok)
        assert.match("does not declare 'uv%-provider' dependency metadata",
            message)
        assert.truthy(provider_loaded)
    end)

    it("keeps the uv marker when the provider made the first open succeed",
       function()
        write_file(standard_bin .. "/uv.so", "mock provider\n")
        write_file(application_bin .. "/direct.so", "mock extension\n")
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin

        package.loadlib = function(filename, symbol)
            if filename == standard_bin .. "/uv.so" then
                assert.equal("*", symbol)
                return true
            end
            assert.equal(application_bin .. "/direct.so", filename)
            if symbol == "direct_abi" then
                return function() return driver.TITAN_VER end
            elseif symbol == "direct_types" then
                return function()
                    return "Module('direct',{})", "uv-provider"
                end
            end
            return nil, "unexpected symbol " .. symbol, "init"
        end

        local deps = {}
        local ok, modtype, errors = driver.defaultloader(deps, {
            stdlib_path = standard_bin,
        })("direct")
        assert.truthy(ok)
        assert.equal("Type.Module", modtype._tag)
        assert.equal(0, #errors)
        assert.equal(driver.UV_DYNAMIC_DEPENDENCY, deps.direct)
    end)

    it("does not mistake a missing uv-named ABI entry for libuv",
       function()
        write_file(application_bin .. "/my_uv_extension.so", "mock image\n")
        driver.TITAN_SOURCE_PATH = application_source
        driver.TITAN_BIN_PATH = application_bin

        local calls = 0
        package.loadlib = function(filename, symbol)
            calls = calls + 1
            assert.equal(application_bin .. "/my_uv_extension.so", filename)
            assert.equal("my_uv_extension_abi", symbol)
            return nil, "undefined symbol: my_uv_extension_abi", "init"
        end

        local ok, message = driver.defaultloader({})("my_uv_extension")
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

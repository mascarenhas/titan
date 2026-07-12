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
            imported = driver.imported,
            registry = types.registry,
            loadlib = package.loadlib,
        }
        driver.imported = {}
        types.registry = {}
    end)

    after_each(function()
        driver.TITAN_SOURCE_PATH = previous.source_path
        driver.TITAN_BIN_PATH = previous.bin_path
        driver.imported = previous.imported
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

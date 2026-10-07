local installed_prefix = require "spec.support.installed_prefix"
local platform = require "titan-compiler.platform"
local root = platform.windows and "C:/" or "/"
local suffix = platform.windows and ".dll" or ".so"

local function absolute(path)
    return root .. path
end

describe("installed-prefix test support", function()
    local original_getenv
    local original_cpath

    before_each(function()
        original_getenv = os.getenv
        original_cpath = package.cpath
    end)

    after_each(function()
        os.getenv = original_getenv
        package.cpath = original_cpath
    end)

    local function set_environment(values)
        os.getenv = function(name)
            return values[name]
        end
    end

    it("derives the prefix from the ordinary Lua C-module template",
       function()
        assert.equal(absolute("opt/titan"), installed_prefix.from_cpath(
            absolute("other/?") .. suffix .. ";" ..
            absolute("opt/titan/lib/lua/5.5/?") .. suffix .. ";./?" .. suffix))
        assert.equal(root, installed_prefix.from_cpath(
            absolute("lib/lua/5.5/?") .. suffix))
        assert.is_nil(installed_prefix.from_cpath(absolute("other/?") .. suffix))
    end)

    it("prefers explicit configuration and normalizes trailing slashes",
       function()
        set_environment({
            PREFIX = absolute("tmp/explicit///"),
            TITAN_TEST_PREFIX = absolute("tmp/fallback"),
        })
        package.cpath = absolute("tmp/cpath/lib/lua/5.5/?") .. suffix
        assert.equal(absolute("tmp/explicit"), installed_prefix.active())
    end)

    it("uses the test override and then the active Lua path as fallbacks",
       function()
        set_environment({
            PREFIX = "",
            TITAN_TEST_PREFIX = absolute("tmp/test-prefix"),
        })
        assert.equal(absolute("tmp/test-prefix"), installed_prefix.active())

        set_environment({})
        package.cpath = absolute("tmp/cpath/lib/lua/5.5/?") .. suffix
        assert.equal(absolute("tmp/cpath"), installed_prefix.active())
    end)

    it("rejects an undiscoverable or relative prefix", function()
        set_environment({})
        package.cpath = "./?" .. suffix
        assert.has_error(function()
            installed_prefix.active()
        end, "native Titan specs require an absolute PREFIX/" ..
            "TITAN_TEST_PREFIX or an active Lua package.cpath containing " ..
            "/lib/lua/5.5/?" .. suffix)

        set_environment({ PREFIX = "relative" })
        assert.has_error(function()
            installed_prefix.active()
        end)
    end)
end)

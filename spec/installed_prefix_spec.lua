local installed_prefix = require "spec.support.installed_prefix"

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
        assert.equal("/opt/titan", installed_prefix.from_cpath(
            "/other/?.so;/opt/titan/lib/lua/5.5/?.so;./?.so"))
        assert.equal("/", installed_prefix.from_cpath(
            "/lib/lua/5.5/?.so"))
        assert.is_nil(installed_prefix.from_cpath("/other/?.so"))
    end)

    it("prefers explicit configuration and normalizes trailing slashes",
       function()
        set_environment({
            PREFIX = "/tmp/explicit///",
            TITAN_TEST_PREFIX = "/tmp/fallback",
        })
        package.cpath = "/tmp/cpath/lib/lua/5.5/?.so"
        assert.equal("/tmp/explicit", installed_prefix.active())
    end)

    it("uses the test override and then the active Lua path as fallbacks",
       function()
        set_environment({
            PREFIX = "",
            TITAN_TEST_PREFIX = "/tmp/test-prefix",
        })
        assert.equal("/tmp/test-prefix", installed_prefix.active())

        set_environment({})
        package.cpath = "/tmp/cpath/lib/lua/5.5/?.so"
        assert.equal("/tmp/cpath", installed_prefix.active())
    end)

    it("rejects an undiscoverable or relative prefix", function()
        set_environment({})
        package.cpath = "./?.so"
        assert.has_error(function()
            installed_prefix.active()
        end, "native Titan specs require an absolute PREFIX/" ..
            "TITAN_TEST_PREFIX or an active Lua package.cpath containing " ..
            "/lib/lua/5.5/?.so")

        set_environment({ PREFIX = "relative" })
        assert.has_error(function()
            installed_prefix.active()
        end)
    end)
end)

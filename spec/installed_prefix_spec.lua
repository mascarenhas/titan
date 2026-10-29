local installed_prefix = require "spec.support.installed_prefix"
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local root = platform.windows and "C:/" or "/"

local function absolute(path)
    return root .. path
end

describe("installed-prefix test support", function()
    local original_getenv
    local original_compiler_root

    before_each(function()
        original_getenv = os.getenv
        original_compiler_root = driver.compiler_root
    end)

    after_each(function()
        os.getenv = original_getenv
        driver.compiler_root = original_compiler_root
    end)

    local function set_environment(values)
        os.getenv = function(name)
            return values[name]
        end
    end

    local function set_compiler_root(value, err)
        driver.compiler_root = function()
            return value, err
        end
    end

    it("prefers explicit configuration and normalizes trailing slashes",
       function()
        set_environment({
            PREFIX = absolute("tmp/explicit///"),
            TITAN_TEST_PREFIX = absolute("tmp/fallback"),
        })
        set_compiler_root(absolute("tmp/compiler"))
        assert.equal(absolute("tmp/explicit"), installed_prefix.active())
    end)

    it("uses the test override and then the compiler root as fallbacks",
       function()
        set_compiler_root(absolute("tmp/compiler/"))
        set_environment({
            PREFIX = "",
            TITAN_TEST_PREFIX = absolute("tmp/test-prefix"),
        })
        assert.equal(absolute("tmp/test-prefix"), installed_prefix.active())

        set_environment({})
        assert.equal(absolute("tmp/compiler"), installed_prefix.active())
    end)

    it("rejects an undiscoverable or relative prefix", function()
        set_environment({})
        set_compiler_root(nil, "no compiler root")
        assert.has_error(function()
            installed_prefix.active()
        end, "native Titan specs require an absolute PREFIX/" ..
            "TITAN_TEST_PREFIX or a Titan compiler root")

        set_environment({ PREFIX = "relative" })
        assert.has_error(function()
            installed_prefix.active()
        end)
    end)
end)

local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

local function shell_command(argv)
    local words = {}
    for i, word in ipairs(argv) do
        words[i] = assert(cdriver.shell_quote(word))
    end
    return table.concat(words, " ")
end

describe("compiled-module ABI version", function()
    after_each(function()
        os.remove("legacy.c")
        os.remove("legacy.so")
        os.remove("legacy15.c")
        os.remove("legacy15.so")
    end)

    it("keeps the compiler lookup and runtime loader versions in sync", function()
        local f = assert(io.open("titan-runtime/titan.h", "r"))
        local header = f:read("*a")
        f:close()
        f = assert(io.open("Makefile", "r"))
        local makefile = f:read("*a")
        f:close()
        f = assert(io.open(".github/workflows/ci.yml", "r"))
        local workflow = f:read("*a")
        f:close()

        local runtime_version =
            assert(header:match('#define%s+TITAN_VER%s+"([^"]+)"'))
        local runtime_suffix =
            assert(header:match('#define%s+TITAN_VER_SUFFIX%s+"([^"]+)"'))

        assert.equal(driver.TITAN_VER, runtime_version)
        assert.equal(driver.TITAN_VER_SUFFIX, runtime_suffix)
        assert.equal("_" .. driver.TITAN_VER:gsub("%.", "_"),
                     driver.TITAN_VER_SUFFIX)
        assert.equal("0.16", driver.TITAN_VER)
        assert.equal("_0_16", driver.TITAN_VER_SUFFIX)
        assert.match("TITAN_ABI_VERSION%s*:?=%s*0%.16", makefile)
        assert.match("TITAN_PATH_0_16", makefile)
        assert.match("TITAN_PATH_0_16", workflow)
        assert.not_match("TITAN_PATH_0_15", makefile)
        assert.not_match("TITAN_PATH_0_15", workflow)
    end)

    it("rejects a compiled container with types but no ABI marker", function()
        os.remove("legacy.titan")
        local f = assert(io.open("legacy.c", "w"))
        f:write([[
            int legacy_types(void *L) {
                (void)L;
                return 0;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy.so", "legacy.c"
        }, " "))
        assert.truthy(ok, "could not build fake legacy module")

        local loader = driver.defaultloader({})
        local loaded, err = loader("legacy")
        assert.falsy(loaded)
        assert.match("claims module 'legacy'", err, 1, true)
        assert.match("missing metadata symbol 'legacy_abi'", err, 1, true)
    end)

    it("rejects a 0.15 module before executing its old type metadata", function()
        os.remove("legacy15.titan")
        local f = assert(io.open("legacy15.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int legacy15_abi(lua_State *L) {
                lua_pushstring(L, "0.15");
                return 1;
            }

            int legacy15_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid 0.15 metadata");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy15.so", "legacy15.c"
        }, " "))
        assert.truthy(ok, "could not build fake 0.15 module")

        local loader = driver.defaultloader({})
        local loaded, err = loader("legacy15")
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 0.16 but found 0.15", err, 1, true)
    end)

    it("ignores the previous versioned Titan path variable", function()
        local prefix = assert(prefix_from_cpath(package.cpath),
            "cannot find the active Lua prefix in package.cpath")
        local script = [[
            package.path = "./?.lua;./?/init.lua;" .. package.path
            local current = require "titan-compiler.driver"
            assert(current.TITAN_BIN_PATH ~= "/obsolete/titan-0.15")
            assert(current.TITAN_BIN_PATH:match("0%.16"))
        ]]
        local ok = os.execute(shell_command({
            "env",
            "-u", "LUA_PATH",
            "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH_5_5",
            "-u", "TITAN_PATH_0_16",
            "-u", "TITAN_PATH",
            "TITAN_PATH_0_15=/obsolete/titan-0.15",
            prefix .. "/bin/lua", "-e", script,
        }))
        assert.truthy(ok)
    end)
end)

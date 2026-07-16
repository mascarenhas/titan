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
        os.remove("legacy14.c")
        os.remove("legacy14.so")
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
        assert.equal("0.15", driver.TITAN_VER)
        assert.equal("_0_15", driver.TITAN_VER_SUFFIX)
        assert.match("TITAN_ABI_VERSION%s*:?=%s*0%.15", makefile)
        assert.match("TITAN_PATH_0_15", makefile)
        assert.match("TITAN_PATH_0_15", workflow)
        assert.not_match("TITAN_PATH_0_14", makefile)
        assert.not_match("TITAN_PATH_0_14", workflow)
    end)

    it("rejects a compiled module that lacks the current ABI marker", function()
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
        assert.match("compatible Titan ABI marker", err)
        assert.match(driver.TITAN_VER, err)
    end)

    it("rejects a 0.14 module before loading its old type metadata", function()
        os.remove("legacy14.titan")
        local f = assert(io.open("legacy14.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int legacy14_abi(lua_State *L) {
                lua_pushstring(L, "0.14");
                return 1;
            }

            int legacy14_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid 0.14 metadata");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy14.so", "legacy14.c"
        }, " "))
        assert.truthy(ok, "could not build fake 0.14 module")

        local loader = driver.defaultloader({})
        local loaded, err = loader("legacy14")
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 0.15 but found 0.14", err, 1, true)
    end)

    it("ignores the previous versioned Titan path variable", function()
        local prefix = assert(prefix_from_cpath(package.cpath),
            "cannot find the active Lua prefix in package.cpath")
        local script = [[
            package.path = "./?.lua;./?/init.lua;" .. package.path
            local current = require "titan-compiler.driver"
            assert(current.TITAN_BIN_PATH ~= "/obsolete/titan-0.14")
            assert(current.TITAN_BIN_PATH:match("0%.15"))
        ]]
        local ok = os.execute(shell_command({
            "env",
            "-u", "LUA_PATH",
            "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH_5_5",
            "-u", "TITAN_PATH_0_15",
            "-u", "TITAN_PATH",
            "TITAN_PATH_0_14=/obsolete/titan-0.14",
            prefix .. "/bin/lua", "-e", script,
        }))
        assert.truthy(ok)
    end)
end)

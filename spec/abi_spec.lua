local driver = require "titan-compiler.driver"

describe("compiled-module ABI version", function()
    after_each(function()
        os.remove("legacy.c")
        os.remove("legacy.so")
        os.remove("legacy12.c")
        os.remove("legacy12.so")
    end)

    it("keeps the compiler lookup and runtime loader versions in sync", function()
        local f = assert(io.open("titan-runtime/titan.h", "r"))
        local header = f:read("*a")
        f:close()

        local runtime_version =
            assert(header:match('#define%s+TITAN_VER%s+"([^"]+)"'))
        local runtime_suffix =
            assert(header:match('#define%s+TITAN_VER_SUFFIX%s+"([^"]+)"'))

        assert.equal(driver.TITAN_VER, runtime_version)
        assert.equal(driver.TITAN_VER_SUFFIX, runtime_suffix)
        assert.equal("_" .. driver.TITAN_VER:gsub("%.", "_"),
                     driver.TITAN_VER_SUFFIX)
        assert.equal("0.13", driver.TITAN_VER)
        assert.equal("_0_13", driver.TITAN_VER_SUFFIX)
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

    it("rejects a 0.12 module before loading its old type metadata", function()
        os.remove("legacy12.titan")
        local f = assert(io.open("legacy12.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int legacy12_abi(lua_State *L) {
                lua_pushstring(L, "0.12");
                return 1;
            }

            int legacy12_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid 0.12 metadata");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy12.so", "legacy12.c"
        }, " "))
        assert.truthy(ok, "could not build fake 0.12 module")

        local loader = driver.defaultloader({})
        local loaded, err = loader("legacy12")
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 0.13 but found 0.12", err, 1, true)
    end)
end)

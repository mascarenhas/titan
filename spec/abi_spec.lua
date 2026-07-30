local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"
local staticmetadata = require "titan-compiler.staticmetadata"

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

local function configured_command(command, ...)
    local argv = assert(cdriver.split_shell_words(command))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return shell_command(argv)
end

describe("compiled-module ABI version", function()
    after_each(function()
        os.remove("legacy.c")
        os.remove("legacy.so")
        os.remove("legacy19.c")
        os.remove("legacy19.so")
        os.remove("legacy19archive.c")
        os.remove("legacy19archive.o")
        os.remove("legacy19archive.a")
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
        f = assert(io.open("scripts/stdlib_installer.lua", "r"))
        local installer = f:read("*a")
        f:close()
        f = assert(io.open("spec/support/async_stdlib.lua", "r"))
        local async_support = f:read("*a")
        f:close()

        local runtime_version =
            assert(header:match('#define%s+TITAN_VER%s+"([^"]+)"'))
        local runtime_suffix =
            assert(header:match('#define%s+TITAN_VER_SUFFIX%s+"([^"]+)"'))

        assert.equal(driver.TITAN_VER, runtime_version)
        assert.equal(driver.TITAN_VER_SUFFIX, runtime_suffix)
        assert.equal("_" .. driver.TITAN_VER:gsub("%.", "_"),
                     driver.TITAN_VER_SUFFIX)
        assert.equal("0.20", driver.TITAN_VER)
        assert.equal("_0_20", driver.TITAN_VER_SUFFIX)
        assert.match("TITAN_ABI_VERSION%s*:?=%s*0%.20", makefile)
        assert.match("TITAN_PATH_0_20", makefile)
        assert.match("TITAN_PATH_0_20", workflow)
        assert.not_match("TITAN_PATH_0_19", makefile)
        assert.match('TITAN_ABI_VERSION:%s*"0%.20"', workflow)
        local cache_abi = "abi-${{ env.TITAN_ABI_VERSION }}"
        local first_cache_abi =
            assert(workflow:find(cache_abi, 1, true))
        assert.truthy(workflow:find(
            cache_abi, first_cache_abi + #cache_abi, true))
        assert.truthy(workflow:find(
            "Prepare the ABI-0.20 standalone prefix", 1, true))
        assert.truthy(workflow:find(
            "make lua\n          make luarocks", 1, true))
        assert.truthy(workflow:find(
            '"$PREFIX/bin/luarocks" remove titan --force', 1, true))
        assert.truthy(workflow:find(
            '"/lib/titan/0.20/?.so"', 1, true))
        assert.truthy(workflow:find(
            '"/lib/titan/0.19/?.so"', 1, true))
        assert.truthy(workflow:find(
            "assert(not cpath:find(previous, 1, true), cpath)", 1, true))
        assert.not_match("ci_abi_migration_smoke", workflow)
        assert.is_nil(io.open("spec/support/ci_abi_migration_smoke.sh", "r"))
        assert.match("lib/titan/0%.20", installer)
        assert.match("stdlib_0_20", installer)
        assert.not_match("lib/titan/0%.19", installer)
        assert.not_match("stdlib_0_19", installer)
        assert.truthy(async_support:find(
            "/lib/titan/0%.20/titan%.so$", 1, true))
        assert.falsy(async_support:find(
            "/lib/titan/0%.19/titan%.so$", 1, true))
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
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("legacy")
        end)
        assert.falsy(loaded)
        assert.match("claims module 'legacy'", err, 1, true)
        assert.match("missing metadata symbol 'legacy_abi'", err, 1, true)
    end)

    it("rejects a 0.19 DSO before executing its old type metadata", function()
        os.remove("legacy19.titan")
        local f = assert(io.open("legacy19.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int legacy19_abi(lua_State *L) {
                lua_pushstring(L, "0.19");
                return 1;
            }

            int legacy19_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid 0.19 metadata");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy19.so", "legacy19.c"
        }, " "))
        assert.truthy(ok, "could not build fake 0.19 module")

        local loader = driver.defaultloader({})
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("legacy19")
        end)
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 0.20 but found 0.19", err, 1, true)
    end)

    it("rejects a 0.19 archive before decoding or linking old metadata",
       function()
        local payload = assert(staticmetadata.render(
            "legacy19archive", "0.19",
            "this is deliberately invalid 0.19 metadata"))
        local initializer = assert(staticmetadata.c_initializer(payload))
        local f = assert(io.open("legacy19archive.c", "w"))
        f:write(string.format([[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#else
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#endif
TITAN_META_SECTION
static const unsigned char legacy19archive_metadata[] = %s;
int legacy19archive_payload(void) { return 0; }
]], initializer))
        f:close()

        local ok = os.execute(configured_command(
            driver.CC, "-c", "-fPIC", "legacy19archive.c",
            "-o", "legacy19archive.o"))
        assert.truthy(ok, "could not build fake 0.19 archive object")
        ok = os.execute(configured_command(
            driver.AR, "rcs", "legacy19archive.a", "legacy19archive.o"))
        assert.truthy(ok, "could not build fake 0.19 archive")
        ok = os.execute(configured_command(
            driver.RANLIB, "legacy19archive.a"))
        assert.truthy(ok, "could not index fake 0.19 archive")

        driver.imported = {}
        local decoded = false
        local original_decode = driver.decode_module_interface
        driver.decode_module_interface = function(...)
            decoded = true
            return original_decode(...)
        end
        local loader = driver.defaultloader({}, {
                prefer_static = true,
            })
        local result = table.pack(pcall(function()
            return driver.with_loader(loader, function(loader)
                return loader("legacy19archive")
            end)
        end))
        driver.decode_module_interface = original_decode
        assert.truthy(result[1], result[2])
        local loaded, err = result[2], result[3]
        assert.falsy(loaded)
        assert.falsy(decoded)
        assert.match("ABI mismatch", err, 1, true)
        assert.match("expected 0.20 but found 0.19", err, 1, true)
    end)

    it("ignores the previous versioned Titan path variable", function()
        local prefix = assert(prefix_from_cpath(package.cpath),
            "cannot find the active Lua prefix in package.cpath")
        local script = [[
            package.path = "./?.lua;./?/init.lua;" .. package.path
            local current = require "titan-compiler.driver"
            assert(current.TITAN_BIN_PATH ~= "/obsolete/titan-0.19")
            assert(current.TITAN_BIN_PATH:match("0%.20"))
        ]]
        local ok = os.execute(shell_command({
            "env",
            "-u", "LUA_PATH",
            "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH_5_5",
            "-u", "TITAN_PATH_0_20",
            "-u", "TITAN_PATH",
            "TITAN_PATH_0_19=/obsolete/titan-0.19",
            prefix .. "/bin/lua", "-e", script,
        }))
        assert.truthy(ok)
    end)
end)

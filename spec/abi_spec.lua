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

local function count_plain(haystack, needle)
    local count = 0
    local offset = 1
    while true do
        local found = haystack:find(needle, offset, true)
        if not found then return count end
        count = count + 1
        offset = found + #needle
    end
end

describe("compiled-module ABI version", function()
    after_each(function()
        os.remove("legacy.c")
        os.remove("legacy.so")
        os.remove("legacy21.c")
        os.remove("legacy21.so")
        os.remove("legacy21archive.c")
        os.remove("legacy21archive.o")
        os.remove("legacy21archive.a")
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
        assert.equal("0.23", driver.TITAN_VER)
        assert.equal("_0_23", driver.TITAN_VER_SUFFIX)
        assert.truthy(makefile:find(
            "LUA_VERSION      ?= 5.5.1", 1, true))
        assert.truthy(makefile:find(
            "LUA_URL          := https://drive.google.com/uc?export=download&id=15oUbOJpvI7JGPK9CEYD38p06ahPywPpQ",
            1, true))
        assert.truthy(makefile:find(
            "else ifeq ($(HOST_OS),Linux)\n    LUA_PLATFORM := linux-readline",
            1, true))
        assert.match("READLINE_MODE%s*%?=%s*auto", makefile)
        assert.match("READLINE_VERSION%s*:?=%s*8%.3", makefile)
        assert.match("READLINE_PATCHLEVEL%s*:?=%s*3", makefile)
        assert.truthy(makefile:find(
            "READLINE_SHA256      := " ..
            "fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc",
            1, true))
        assert.truthy(makefile:find(
            "72dee13601ce38f6746eb15239999a7c56f8e1ff5eb1ec8153a1f213e4acdb29",
            1, true))
        assert.truthy(makefile:find(
            "READLINE_COMBINED_PATCH_SHA256 := " ..
            "70cbc596c0a7b3a35fabb8a05711a60e2695bd2d06a4e2f46f6f168f84403f96",
            1, true))
        assert.truthy(makefile:find(
            "$(LUA_BUILD_CONFIG): $(LUA_EXTRACTED) " ..
            "$(READLINE_SELECTION_CONFIG)", 1, true))
        assert.truthy(makefile:find(
            "System Readline development files unavailable; provisioning",
            1, true))
        assert.truthy(makefile:find(
            '--prefix="$(PREFIX)"', 1, true))
        assert.truthy(makefile:find(
            "--disable-shared --enable-static", 1, true))
        assert.truthy(makefile:find(
            ".readline-$(READLINE_RELEASE).stage.XXXXXX", 1, true))
        assert.truthy(makefile:find(
            "READLINE_LICENSE_SOURCE := LICENSES/readline-LICENSE",
            1, true))
        assert.truthy(makefile:find(
            "-Wl,-l:libtinfo.so.6", 1, true))
        assert.match("TITAN_ABI_VERSION%s*:?=%s*0%.23", makefile)
        assert.match("TITAN_PATH_0_23", makefile)
        assert.match("TITAN_PATH_0_23", workflow)
        assert.not_match("TITAN_PATH_0_22", makefile)
        assert.equal(2, count_plain(
            workflow, 'TITAN_ABI_VERSION: "0.23"'))
        local cache_abi = "abi-${{ env.TITAN_ABI_VERSION }}"
        assert.equal(4, count_plain(workflow, cache_abi))
        assert.truthy(workflow:find(
            "Prepare the ABI-0.23 standalone prefix", 1, true))
        assert.truthy(workflow:find(
            'READLINE_MODE: bundled', 1, true))
        assert.truthy(workflow:find(
            'READLINE_MODE: system', 1, true))
        assert.truthy(workflow:find(
            "libssl-dev libtinfo-dev libuv1-dev", 1, true))
        assert.truthy(workflow:find(
            "readline-8.3-p3.config", 1, true))
        assert.truthy(workflow:find(
            "readline-build/.titan-readline-8.3-p3/lib/libreadline.a", 1, true))
        assert.truthy(workflow:find(
            "cmp LICENSES/readline-LICENSE", 1, true))
        assert.truthy(workflow:find(
            "Install bundled Readline", 1, true))
        assert.truthy(workflow:find(
            "make lua", 1, true))
        assert.truthy(workflow:find(
            "make luarocks", 1, true))
        assert.truthy(workflow:find(
            '"$PREFIX/bin/luarocks" remove titan --force', 1, true))
        assert.truthy(workflow:find(
            '"/lib/titan/0.23/?.so"', 1, true))
        assert.truthy(workflow:find(
            '"/lib/titan/0.22/?.so"', 1, true))
        assert.truthy(workflow:find(
            "assert(not cpath:find(previous, 1, true), cpath)", 1, true))
        assert.not_match("ci_abi_migration_smoke", workflow)
        assert.is_nil(io.open("spec/support/ci_abi_migration_smoke.sh", "r"))
        assert.not_match("lib/titan/0%.22", installer)
        assert.match("stdlib_0_23", installer)
        assert.not_match("lib/titan/0%.21", installer)
        assert.not_match("stdlib_0_21", installer)
        assert.truthy(async_support:find(
            "/lib/titan/0%.22/titan%.so$", 1, true))
        assert.falsy(async_support:find(
            "/lib/titan/0%.21/titan%.so$", 1, true))
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

    it("rejects a 0.21 DSO before executing its old type metadata", function()
        os.remove("legacy21.titan")
        local f = assert(io.open("legacy21.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int legacy21_abi(lua_State *L) {
                lua_pushstring(L, "0.21");
                return 1;
            }

            int legacy21_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid 0.21 metadata");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local ok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "legacy21.so", "legacy21.c"
        }, " "))
        assert.truthy(ok, "could not build fake 0.21 module")

        local loader = driver.defaultloader({})
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("legacy21")
        end)
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 0.23 but found 0.21", err, 1, true)
    end)

    it("rejects a 0.21 archive before decoding or linking old metadata",
        function()
            local payload = assert(staticmetadata.render(
                "legacy21archive", "0.21",
                "this is deliberately invalid 0.21 metadata"))
            local initializer = assert(staticmetadata.c_initializer(payload))
            local f = assert(io.open("legacy21archive.c", "w"))
            f:write(string.format([[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#else
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#endif
TITAN_META_SECTION
static const unsigned char legacy21archive_metadata[] = %s;
int legacy21archive_payload(void) { return 0; }
]], initializer))
            f:close()

            local ok = os.execute(configured_command(
                driver.CC, "-c", "-fPIC", "legacy21archive.c",
                "-o", "legacy21archive.o"))
            assert.truthy(ok, "could not build fake 0.21 archive object")
            ok = os.execute(configured_command(
                driver.AR, "rcs", "legacy21archive.a", "legacy21archive.o"))
            assert.truthy(ok, "could not build fake 0.21 archive")
            ok = os.execute(configured_command(
                driver.RANLIB, "legacy21archive.a"))
            assert.truthy(ok, "could not index fake 0.21 archive")

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
                    return loader("legacy21archive")
                end)
            end))
            driver.decode_module_interface = original_decode
            assert.truthy(result[1], result[2])
            local loaded, err = result[2], result[3]
            assert.falsy(loaded)
            assert.falsy(decoded)
            assert.match("ABI mismatch", err, 1, true)
            assert.match("expected 0.23 but found 0.21", err, 1, true)
        end)

    it("ignores the previous versioned Titan path variable", function()
        local prefix = assert(prefix_from_cpath(package.cpath),
            "cannot find the active Lua prefix in package.cpath")
        local script = [[
            package.path = "./?.lua;./?/init.lua;" .. package.path
            local current = require "titan-compiler.driver"
            assert(current.TITAN_BIN_PATH ~= "/obsolete/titan-0.22")
            assert(current.TITAN_BIN_PATH:match("0%.23"))
        ]]
        local ok = os.execute(shell_command({
            "env",
            "-u", "LUA_PATH",
            "-u", "LUA_CPATH",
            "-u", "LUA_PATH_5_5",
            "-u", "LUA_CPATH_5_5",
            "-u", "TITAN_PATH_0_23",
            "-u", "TITAN_PATH",
            "TITAN_PATH_0_22=/obsolete/titan-0.22",
            prefix .. "/bin/lua", "-e", script,
        }))
        assert.truthy(ok)
    end)
end)

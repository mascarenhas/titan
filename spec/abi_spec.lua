local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"
local staticmetadata = require "titan-compiler.staticmetadata"

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

local function shared_fixture_command(output, source)
    local argv = assert(cdriver.split_shell_words(driver.CC))
    argv[#argv + 1] = "-fPIC"
    for _, flag in ipairs(assert(driver.shared_library_flags())) do
        argv[#argv + 1] = flag
    end
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = output
    argv[#argv + 1] = source
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
        os.remove("incompatible.c")
        os.remove("incompatible.so")
        os.remove("incompatible_archive.c")
        os.remove("incompatible_archive.o")
        os.remove("incompatible_archive.a")
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

        local runtime_abi = assert(header:match(
            '#define%s+TITAN_ABI_VERSION%s+"([^"]+)"'))
        local runtime_version = assert(header:match(
            '#define%s+TITAN_VERSION%s+"([^"]+)"'))
        local runtime_library_version = assert(header:match(
            '#define%s+TITAN_LIBRARY_VERSION%s+"([^"]+)"'))
        local runtime_suffix =
            assert(header:match(
                '#define%s+TITAN_LIBRARY_VERSION_SUFFIX%s+"([^"]+)"'))

        assert.equal(driver.TITAN_ABI_VERSION, runtime_abi)
        assert.equal(driver.TITAN_VERSION, runtime_version)
        assert.equal(driver.TITAN_LIBRARY_VERSION, runtime_library_version)
        assert.equal(driver.TITAN_LIBRARY_VERSION_SUFFIX, runtime_suffix)
        assert.match("^%d+$", driver.TITAN_ABI_VERSION)
        assert.match("^%d+%.%d+%.%d+$", driver.TITAN_VERSION)
        assert.equal(driver.TITAN_VERSION:match("^(%d+%.%d+)%.[0-9]+$"),
            driver.TITAN_LIBRARY_VERSION)
        assert.not_equal(driver.TITAN_ABI_VERSION,
            driver.TITAN_LIBRARY_VERSION)
        assert.equal("_" .. driver.TITAN_LIBRARY_VERSION:gsub("%.", "_"),
            driver.TITAN_LIBRARY_VERSION_SUFFIX)
        assert.equal("2", driver.TITAN_ABI_VERSION)
        assert.equal("0.6.0", driver.TITAN_VERSION)
        assert.equal("0.6", driver.TITAN_LIBRARY_VERSION)
        assert.equal("_0_6", driver.TITAN_LIBRARY_VERSION_SUFFIX)
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
            "$(READLINE_SELECTION_CONFIG): $(LUA_EXTRACTED) FORCE",
            1, true))
        assert.truthy(makefile:find(
            '$(MAKE) -j1 -C "$(READLINE_BUILD_DIR)" install;',
            1, true))
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
        assert.match("TITAN_ABI_VERSION%s*:?=%s*2", makefile)
        assert.match("TITAN_VERSION%s*:?=%s*0%.6%.0", makefile)
        assert.match("TITAN_LIBRARY_VERSION%s*:?=", makefile)
        assert.truthy(makefile:find(
            "TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)", 1, true))
        assert.match("TITAN_PATH_0_6", workflow)
        assert.equal(1, count_plain(
            workflow, 'TITAN_ABI_VERSION: "2"'))
        local cache_abi = "abi-${{ env.TITAN_ABI_VERSION }}"
        assert.equal(13, count_plain(workflow, cache_abi))
        assert.equal(4, count_plain(workflow,
            ".lua/var/cache/titan-probes/${{ env.TITAN_ABI_VERSION }}"))
        assert.truthy(workflow:find(
            "Prepare the standalone prefix", 1, true))
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
            '"/lib/titan/0.6/?.so"', 1, true))
        assert.equal(3, count_plain(workflow,
            'runtime_archive="$PREFIX/lib/titan/0.6/libtitan.a"'))
        assert.equal(3, count_plain(workflow,
            'test ! -e "$PREFIX/lib/libtitan.a"'))
        assert.not_match("ci_abi_migration_smoke", workflow)
        assert.is_nil(io.open("spec/support/ci_abi_migration_smoke.sh", "r"))
        assert.match("driver%.TITAN_ABI_VERSION", installer)
        assert.match("driver%.TITAN_LIBRARY_VERSION", installer)
        assert.match("driver%.TITAN_LIBRARY_VERSION_SUFFIX", installer)
        assert.truthy(async_support:find(
            'prefix .. "/lib/titan/0.6"', 1, true))
        assert.truthy(async_support:find(
            '"TITAN_PATH_0_6="', 1, true))
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
        local ok = os.execute(shared_fixture_command("legacy.so", "legacy.c"))
        assert.truthy(ok, "could not build fake legacy module")

        local loader = driver.defaultloader({})
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("legacy")
        end)
        assert.falsy(loaded)
        assert.match("claims module 'legacy'", err, 1, true)
        assert.match("missing metadata symbol 'legacy_abi'", err, 1, true)
    end)

    it("rejects an incompatible DSO before executing its type metadata",
       function()
        os.remove("incompatible.titan")
        local f = assert(io.open("incompatible.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);

            int incompatible_abi(lua_State *L) {
                lua_pushstring(L, "1");
                return 1;
            }

            int incompatible_types(lua_State *L) {
                lua_pushstring(L, "this is deliberately invalid metadata");
                return 1;
            }
        ]])
        f:close()
        local ok = os.execute(shared_fixture_command(
            "incompatible.so", "incompatible.c"))
        assert.truthy(ok, "could not build incompatible module")

        local loader = driver.defaultloader({})
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("incompatible")
        end)
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 2 but found 1", err, 1, true)
    end)

    it("rejects an incompatible archive before decoding or linking metadata",
        function()
            local payload = assert(staticmetadata.render(
                "incompatible_archive", "1",
                "this is deliberately invalid metadata"))
            local initializer = assert(staticmetadata.c_initializer(payload))
            local f = assert(io.open("incompatible_archive.c", "w"))
            f:write(string.format([[
#if defined(__APPLE__)
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section("__TEXT,__titanmeta")))
#else
#define TITAN_META_SECTION \
    __attribute__((used, aligned(1), section(".titan.meta")))
#endif
TITAN_META_SECTION
static const unsigned char incompatible_archive_metadata[] = %s;
int incompatible_archive_payload(void) { return 0; }
]], initializer))
            f:close()

            local ok = os.execute(configured_command(
                driver.CC, "-c", "-fPIC", "incompatible_archive.c",
                "-o", "incompatible_archive.o"))
            assert.truthy(ok, "could not build incompatible archive object")
            ok = os.execute(configured_command(
                driver.AR, "rcs", "incompatible_archive.a",
                "incompatible_archive.o"))
            assert.truthy(ok, "could not build incompatible archive")
            ok = os.execute(configured_command(
                driver.RANLIB, "incompatible_archive.a"))
            assert.truthy(ok, "could not index incompatible archive")

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
                    return loader("incompatible_archive")
                end)
            end))
            driver.decode_module_interface = original_decode
            assert.truthy(result[1], result[2])
            local loaded, err = result[2], result[3]
            assert.falsy(loaded)
            assert.falsy(decoded)
            assert.match("ABI mismatch", err, 1, true)
            assert.match("expected 2 but found 1", err, 1, true)
        end)
end)

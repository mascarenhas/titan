local driver = require "titan-compiler.driver"
local cdriver = require "c-parser.cdriver"
local cprobe_cache = require "titan-compiler.cprobe_cache"
local staticmetadata = require "titan-compiler.staticmetadata"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local shared_suffix = platform.windows and ".dll" or ".so"

local function run(argv, message)
    local result = compiler_io.new_sync():run(argv)
    assert.truthy(result.started and result.ok,
        message .. ": " .. tostring(result.diagnostic or result.output))
end

local function configured_command(command, ...)
    local argv = assert(cdriver.split_shell_words(command))
    for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
    return argv
end

local function shared_fixture_command(output, source)
    local argv = assert(cdriver.split_shell_words(driver.CC))
    if not platform.windows then argv[#argv + 1] = "-fPIC" end
    for _, flag in ipairs(assert(driver.shared_library_flags())) do
        argv[#argv + 1] = flag
    end
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = output
    argv[#argv + 1] = source
    return argv
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
        os.remove("legacy" .. shared_suffix)
        os.remove("incompatible.c")
        os.remove("incompatible" .. shared_suffix)
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
        f = assert(io.open(".gitmodules", "r"))
        local submodules = f:read("*a")
        f:close()
        f = assert(io.open(".github/workflows/ci.yml", "r"))
        local linux_workflow = f:read("*a")
        f:close()
        f = assert(io.open(".github/workflows/macos.yml", "r"))
        local macos_workflow = f:read("*a")
        f:close()
        local workflow = linux_workflow .. "\n" .. macos_workflow
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
        assert.match("LUA_VERSION%s*:?=%s*5%.5%.1", makefile)
        assert.match("LUA_SOURCE_READY%s*:?=%s*%$%(LUA_DIR%)/src/lua[.]h", makefile)
        assert.match("path%s*=%s*lua%-5%.5%.1", submodules)
        assert.match("url%s*=%s*https://github%.com/mascarenhas/lua%-5%.5%.1[.]git", submodules)
        assert.truthy(makefile:find(
            "else ifeq ($(HOST_OS),Linux)\n    LUA_PLATFORM := linux-readline",
            1, true))
        assert.truthy(makefile:find('if test ! -f "$(LUA_BIN)"', 1, true))
        assert.truthy(makefile:find('if test ! -f "$(LUAROCKS_BIN)"', 1, true))
        assert.falsy(makefile:find("READLINE_MODE", 1, true))
        assert.falsy(makefile:find("LUA_BUILD_CONFIG", 1, true))
        assert.falsy(makefile:find("LUAROCKS_INSTALL_STAMP", 1, true))
        assert.match("TITAN_ABI_VERSION%s*:?=%s*2", makefile)
        assert.match("TITAN_VERSION%s*:?=%s*0%.6%.0", makefile)
        assert.match("TITAN_LIBRARY_VERSION%s*:?=", makefile)
        assert.truthy(makefile:find(
            "TITAN_PATH$(TITAN_LIBRARY_VERSION_SUFFIX)", 1, true))
        assert.match("TITAN_PATH_0_6", workflow)
        for _, lane in ipairs({ linux_workflow, macos_workflow }) do
            assert.equal(1, count_plain(
                lane, 'TITAN_ABI_VERSION: "2"'))
        end
        local cache_abi = "abi-${{ env.TITAN_ABI_VERSION }}"
        assert.equal(4, count_plain(workflow, cache_abi))
        assert.equal(4, count_plain(workflow,
            ".lua/var/cache/titan-probes/" .. cprobe_cache.VERSION))
        assert.equal(6, count_plain(workflow,
            "titan-probes-" .. cprobe_cache.VERSION .. "-"))
        assert.truthy(workflow:find(
            "Prepare the standalone prefix", 1, true))
        assert.truthy(workflow:find(
            "libreadline-dev libssl-dev perl", 1, true))
        assert.falsy(workflow:find("READLINE_MODE", 1, true))
        assert.truthy(workflow:find(
            "make lua", 1, true))
        assert.truthy(workflow:find(
            "make luarocks", 1, true))
        assert.truthy(workflow:find(
            '"$PREFIX/bin/luarocks" remove titan --force', 1, true))
        assert.equal(3, count_plain(workflow,
            'runtime_archive="$PREFIX/lib/titan/0.6/libtitan.a"'))
        assert.equal(3, count_plain(workflow,
            'test ! -e "$PREFIX/lib/libtitan.a"'))
        assert.not_match("ci_abi_migration_smoke", workflow)
        assert.is_nil(io.open("spec/support/ci_abi_migration_smoke.sh", "r"))
        assert.truthy(async_support:find(
            'prefix .. "/lib/titan/0.6"', 1, true))
        assert.truthy(async_support:find(
            '"TITAN_PATH_0_6="', 1, true))
    end)

    it("rejects a compiled container with types but no ABI marker", function()
        os.remove("legacy.titan")
        local f = assert(io.open("legacy.c", "w"))
        f:write([[
#if defined(_WIN32)
            __declspec(dllexport)
#endif
            int legacy_types(void *L) {
                (void)L;
                return 0;
            }
        ]])
        f:close()
        run(shared_fixture_command("legacy" .. shared_suffix, "legacy.c"),
            "could not build fake legacy module")

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
#if defined(_WIN32)
            static int types_called;

            __declspec(dllexport) const char *incompatible_abi_value(void) {
                return "1";
            }

            __declspec(dllexport) int incompatible_abi(void *L) {
                (void)L;
                return 0;
            }

            __declspec(dllexport) int incompatible_types(void *L) {
                (void)L;
                types_called = 1;
                return 0;
            }

            __declspec(dllexport) const char *incompatible_types_called(void) {
                return types_called ? "1" : "0";
            }
#else
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
#endif
        ]])
        f:close()
        run(shared_fixture_command("incompatible" .. shared_suffix,
            "incompatible.c"), "could not build incompatible module")

        local loader = driver.defaultloader({})
        local loaded, err = driver.with_loader(loader, function(loader)
            return loader("incompatible")
        end)
        assert.falsy(loaded)
        assert.match("ABI mismatch: expected 2 but found 1", err, 1, true)
        if platform.windows then
            assert.equal("0", require("titan")._abivalue(
                "incompatible.dll", "incompatible_types_called"))
        end
    end)

    it("rejects an incompatible archive before decoding or linking metadata",
        function()
            if platform.windows then
                pending("Titan archive providers require ELF or Mach-O; " ..
                    "Windows supports DLL providers only")
                return
            end
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

            run(configured_command(
                driver.CC, "-c", "-fPIC", "incompatible_archive.c",
                "-o", "incompatible_archive.o"),
                "could not build incompatible archive object")
            run(configured_command(
                driver.AR, "rcs", "incompatible_archive.a",
                "incompatible_archive.o"),
                "could not build incompatible archive")
            run(configured_command(driver.RANLIB, "incompatible_archive.a"),
                "could not index incompatible archive")

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

-- Phase-0 contract tests for canonical Titan standard modules. These fixtures
-- deliberately use tiny `coroutine` and `os` implementations: the behavior
-- under test is resolution, code generation, aliasing, and entrypoint
-- bootstrap selection, independently of the production modules' internals.
local lfs = require "lfs"
local assert = require "luassert"

local FIXTURE = "spec/fixtures/stdlib"
local MODULES = FIXTURE .. "/modules"
local APPLICATION = FIXTURE .. "/application"
local ORDINARY = FIXTURE .. "/ordinary"
local SHADOW_SOURCE = FIXTURE .. "/shadow-source"
local BOOTSTRAP = FIXTURE .. "/bootstrap"
local BUILD = FIXTURE .. "/build"
local ORDINARY_BIN = BUILD .. "/ordinary"

local function file_exists(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local LUA = file_exists("./lua") and "./lua" or ".lua/bin/lua"
local RAW_LUA = file_exists(".lua/bin/lua") and ".lua/bin/lua" or LUA
local TITANC = LUA ..
    [[ -e 'package.path="./?.lua;./?/init.lua;" .. package.path' ./titanc]]
local BASE_ENV = "env CCACHE_DISABLE=1 TITAN_STDLIB_PATH=" .. BUILD ..
    " TITAN_PATH_0_11=" .. ORDINARY_BIN ..
    " TITAN_PATH=" .. ORDINARY_BIN ..
    " LUA_CPATH='" .. BUILD .. "/?.so;" .. ORDINARY_BIN .. "/?.so;;' "

local function run_command(command)
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function assert_command_ok(command)
    local ok, output, why, code = run_command(command)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
    return output
end

local function compile(arguments, environment)
    return run_command((environment or BASE_ENV) .. TITANC .. " " .. arguments)
end

local function assert_compile_ok(arguments, environment)
    local ok, output, why, code = compile(arguments, environment)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
    return output
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local contents = f:read("*a")
    f:close()
    return contents
end

local function write_file(path, contents)
    local f = assert(io.open(path, "wb"))
    f:write(contents)
    f:close()
end

local function remove_files(paths)
    for _, path in ipairs(paths) do os.remove(path) end
end

local GENERATED_FILES = {
    "ordinary_dep.so", "consumer.so",
    "mixed_consumer.so", "source_visible_consumer.so",
    "source_chain.so",
    "cached_one.so", "cached_two.so",
    "bin_consumer.so", "shadow_consumer.so",
    "direct_main", "direct_main__entrypoint.c",
    "hooked_main", "hooked_main__entrypoint.c",
    "standard_app", "standard_app__entrypoint.c",
    MODULES .. "/coroutine.c", MODULES .. "/coroutine.o",
    MODULES .. "/os.c", MODULES .. "/os.o",
    MODULES .. "/source_visible_consumer.c",
    MODULES .. "/source_visible_consumer.o",
    ORDINARY .. "/ordinary_dep.c", ORDINARY .. "/ordinary_dep.o",
    APPLICATION .. "/consumer.c", APPLICATION .. "/consumer.o",
    APPLICATION .. "/mixed_consumer.c", APPLICATION .. "/mixed_consumer.o",
    APPLICATION .. "/source_helper.c", APPLICATION .. "/source_helper.o",
    APPLICATION .. "/source_chain.c", APPLICATION .. "/source_chain.o",
    APPLICATION .. "/cached_helper.c", APPLICATION .. "/cached_helper.o",
    APPLICATION .. "/cached_one.c", APPLICATION .. "/cached_one.o",
    APPLICATION .. "/cached_two.c", APPLICATION .. "/cached_two.o",
    APPLICATION .. "/bin_consumer.c", APPLICATION .. "/bin_consumer.o",
    APPLICATION .. "/standard_app.c", APPLICATION .. "/standard_app.o",
    SHADOW_SOURCE .. "/shadow_consumer.c",
    SHADOW_SOURCE .. "/shadow_consumer.o",
    BOOTSTRAP .. "/direct_main.c", BOOTSTRAP .. "/direct_main.o",
    BOOTSTRAP .. "/provider.c", BOOTSTRAP .. "/provider.o",
    BOOTSTRAP .. "/hooked_main.c", BOOTSTRAP .. "/hooked_main.o",
    FIXTURE .. "/shadow-bin/os.so",
}

local function clean_generated()
    remove_files(GENERATED_FILES)
    os.execute("rm -rf " .. BUILD)
    os.execute("rmdir " .. FIXTURE .. "/shadow-bin 2>/dev/null")
    os.execute("rm -rf direct_main.dSYM hooked_main.dSYM " ..
        "standard_app.dSYM coroutine.so.dSYM os.so.dSYM " ..
        "ordinary_dep.so.dSYM consumer.so.dSYM mixed_consumer.so.dSYM")
end

local function install_aliases()
    assert_command_ok("mkdir -p " .. BUILD .. "/titan")
    assert_command_ok("ln -s ../coroutine.so " ..
        BUILD .. "/titan/coroutine.so")
    assert_command_ok("ln -s ../os.so " .. BUILD .. "/titan/os.so")
end

local function compile_into(arguments, output, destination)
    local backup = BUILD .. "/saved-" .. output
    if file_exists(output) then
        assert(os.rename(output, backup))
    end
    local ok, result = pcall(assert_compile_ok, arguments)
    if ok then
        local moved, move_err = os.rename(output, destination)
        if not moved then
            ok, result = false, move_err
        end
    end
    if file_exists(backup) then
        local restored, restore_err = os.rename(backup, output)
        if not restored then
            ok = false
            result = tostring(result) .. "; failed restoring " .. output ..
                ": " .. tostring(restore_err)
        end
    end
    assert.truthy(ok, result)
end

local function build_phase0_fixture()
    assert_command_ok("mkdir -p " .. ORDINARY_BIN)
    compile_into("--stdlib-build --tree " .. MODULES ..
        " --lua-name titan.coroutine coroutine", "coroutine.so",
        BUILD .. "/coroutine.so")
    compile_into("--stdlib-build --tree " .. MODULES ..
        " --lua-name titan.os os", "os.so", BUILD .. "/os.so")
    install_aliases()
    compile_into("--tree " .. ORDINARY .. " ordinary_dep",
        "ordinary_dep.so", ORDINARY_BIN .. "/ordinary_dep.so")
    assert_compile_ok("--tree " .. APPLICATION .. " consumer")
    assert_compile_ok("--tree " .. APPLICATION .. " mixed_consumer")
    assert_compile_ok("--tree " .. APPLICATION .. " source_chain")
    assert_compile_ok("--tree " .. APPLICATION .. " cached_one cached_two")
end

local function run_lua(source)
    local script = os.tmpname()
    write_file(script, source)
    local ok, output, why, code = run_command(
        BASE_ENV .. RAW_LUA .. " " .. script)
    os.remove(script)
    assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
        tostring(code) .. ")")
    return output
end

local function assert_has_symbol(binary, symbol)
    local output = assert_command_ok("nm -g " .. binary)
    assert.truthy(output:find(symbol, 1, true),
        binary .. " does not export " .. symbol .. "\n" .. output)
    return output
end

describe("standard-library driver and runtime foundation", function()
    setup(function()
        clean_generated()
        os.remove("titan-runtime/titan.o")
        build_phase0_fixture()
    end)

    teardown(clean_generated)

    it("does not unload the manually wired module graph by flat load order",
       function()
        local runtime = read_file("titan-runtime/titan.c")
        assert.falsy(runtime:find("dlclose(", 1, true))
        assert.truthy(runtime:find("process lifetime", 1, true))
    end)

    it("enforces unambiguous --stdlib-build and --lua-name roots", function()
        local ok, output = compile("--stdlib-build --tree " .. MODULES ..
            " os coroutine")
        assert.falsy(ok)
        assert.match("%-%-stdlib%-build requires exactly one module", output)

        ok, output = compile("--stdlib-build --tree " .. APPLICATION ..
            " consumer")
        assert.falsy(ok)
        assert.match("requires a reserved standard module name", output)

        ok, output = compile("--stdlib-build --tree " .. MODULES ..
            " coroutine")
        assert.falsy(ok)
        assert.match("requires %-%-lua%-name titan%.coroutine", output)

        ok, output = compile("--stdlib-build --tree " .. MODULES ..
            " --lua-name coroutine coroutine")
        assert.falsy(ok)
        assert.match("requires %-%-lua%-name titan%.coroutine", output)

        ok, output = compile("--tree " .. APPLICATION ..
            " --lua-name titan.alias consumer bin_consumer")
        assert.falsy(ok)
        assert.match("%-%-lua%-name requires exactly one module", output)

        ok, output = compile("--tree " .. APPLICATION ..
            " --lua-name titan%.%.bad consumer")
        assert.falsy(ok)
        assert.match("invalid qualified Lua name", output)

        ok, output = compile("--tree " .. BOOTSTRAP ..
            " --lua-name titan.direct direct_main")
        assert.falsy(ok)
        assert.match("%-%-lua%-name cannot be used with a module that defines main",
            output)

        ok, output = compile("--tree " .. MODULES .. " os")
        assert.falsy(ok)
        assert.match("reserved standard module 'os' must be built with " ..
            "%-%-stdlib%-build", output)
    end)

    it("keeps canonical ABI symbols while exporting only the Lua alias", function()
        local os_symbols = assert_has_symbol(
            BUILD .. "/os.so", "luaopen_titan_os")
        for _, symbol in ipairs({ "os_init", "os_abi", "os_types" }) do
            assert.truthy(os_symbols:find(symbol, 1, true), symbol)
        end
        assert.falsy(os_symbols:find("luaopen_os", 1, true))
        assert.falsy(os_symbols:find("coroutine_init", 1, true),
            "os.so source-linked its reserved dependency")

        local coroutine_symbols = assert_has_symbol(
            BUILD .. "/coroutine.so", "luaopen_titan_coroutine")
        for _, symbol in ipairs({
            "coroutine_init", "coroutine_abi", "coroutine_types",
        }) do
            assert.truthy(coroutine_symbols:find(symbol, 1, true), symbol)
        end
        assert.falsy(coroutine_symbols:find("luaopen_coroutine", 1, true))
        assert.falsy(coroutine_symbols:find("luaopen_coro", 1, true))
    end)

    it("emits loadstdlib only for standard-origin binary imports", function()
        local standard_c = read_file(MODULES .. "/os.c")
        assert.truthy(standard_c:find(
            [[loadstdlib(L, "coroutine.so")]], 1, true))
        assert.falsy(standard_c:find([[loadlib(L, "coroutine.so")]], 1, true))

        local mixed_c = read_file(APPLICATION .. "/mixed_consumer.c")
        assert.truthy(mixed_c:find([[loadstdlib(L, "os.so")]], 1, true))
        assert.falsy(mixed_c:find([[loadlib(L, "os.so")]], 1, true))
        assert.truthy(mixed_c:find(
            [[loadlib(L, "ordinary_dep.so")]], 1, true))
        assert.falsy(mixed_c:find(
            [[loadstdlib(L, "ordinary_dep.so")]], 1, true))
    end)

    it("preserves the standard origin inside a non-root source dependency",
       function()
        local helper_c = read_file(APPLICATION .. "/source_helper.c")
        assert.truthy(helper_c:find([[loadstdlib(L, "os.so")]], 1, true))
        assert.falsy(helper_c:find([[loadlib(L, "os.so")]], 1, true))
        run_lua([[
            local chain = require "source_chain"
            assert(chain.bump() == 101)
        ]])
    end)

    it("retains cached source closures for a second explicit root", function()
        local helper_c = read_file(APPLICATION .. "/cached_helper.c")
        assert.truthy(helper_c:find([[loadstdlib(L, "os.so")]], 1, true))
        assert.falsy(helper_c:find([[loadlib(L, "os.so")]], 1, true))
        local one_symbols = assert_command_ok("nm -g cached_one.so")
        local two_symbols = assert_command_ok("nm -g cached_two.so")
        assert.truthy(one_symbols:find("cached_helper_init", 1, true))
        assert.truthy(two_symbols:find("cached_helper_init", 1, true))
    end)

    it("pins imports to binaries when canonical standard sources are visible",
       function()
        local env = "env CCACHE_DISABLE=1 TITAN_STDLIB_PATH=" .. BUILD .. " " ..
            "TITAN_STDLIB_SOURCE_PATH=" .. MODULES .. " " ..
            "TITAN_PATH_0_11=" .. ORDINARY_BIN .. " "
        assert_compile_ok("--tree " .. MODULES ..
            " source_visible_consumer", env)

        local generated = read_file(MODULES .. "/source_visible_consumer.c")
        assert.truthy(generated:find([[loadstdlib(L, "os.so")]], 1, true))
        assert.falsy(generated:find([[loadlib(L, "os.so")]], 1, true))

        local symbols = assert_command_ok("nm -g source_visible_consumer.so")
        assert.falsy(symbols:find("os_init", 1, true),
            "the standard source was recursively linked")
    end)

    it("diagnoses an application source claiming a reserved name", function()
        local ok, output = compile("--tree " .. SHADOW_SOURCE ..
            " shadow_consumer")
        assert.falsy(ok)
        assert.match("reserved standard module 'os' is shadowed by " ..
            "application source", output)
        assert.match("shadow%-source/os%.titan", output)
    end)

    it("diagnoses an ordinary Titan-path binary claiming a reserved name",
       function()
        assert_command_ok("mkdir -p " .. FIXTURE .. "/shadow-bin")
        write_file(FIXTURE .. "/shadow-bin/os.so", "not a shared library\n")
        local env = "env CCACHE_DISABLE=1 TITAN_STDLIB_PATH=" .. BUILD .. " " ..
            "TITAN_PATH_0_11=" .. FIXTURE .. "/shadow-bin "
        local ok, output = compile("--tree " .. APPLICATION ..
            " bin_consumer", env)
        os.remove(FIXTURE .. "/shadow-bin/os.so")
        assert.falsy(ok)
        assert.match("reserved standard module 'os' is shadowed by " ..
            "local binary", output)
        assert.match("shadow%-bin/os%.so", output)
    end)

    it("shares os state when a Titan import initializes the image first",
       function()
        run_lua([[
            local builtin = require "os"
            local consumer = require "consumer"
            assert(consumer.bump() == 101)

            local standard_os = require "titan.os"
            assert(standard_os.bump() == 102)
            assert(require "os" == builtin)
            assert(package.loaded.os == builtin)

            local canonical_open = assert(package.loadlib(
                "]] .. BUILD .. [[/os.so", "luaopen_titan_os"))
            local alias_open = assert(package.loadlib(
                "]] .. BUILD .. [[/titan/os.so", "luaopen_titan_os"))
            assert(canonical_open == alias_open)
            assert(rawequal(canonical_open(), standard_os))
        ]])
    end)

    it("shares os state when the Lua alias initializes the image first",
       function()
        run_lua([[
            local builtin = require "os"
            local standard_os = require "titan.os"
            assert(standard_os.bump() == 101)

            local consumer = require "consumer"
            assert(consumer.bump() == 102)
            assert(require "os" == builtin)
            assert(package.loaded.os == builtin)

            local canonical_open = assert(package.loadlib(
                "]] .. BUILD .. [[/os.so", "luaopen_titan_os"))
            local alias_open = assert(package.loadlib(
                "]] .. BUILD .. [[/titan/os.so", "luaopen_titan_os"))
            assert(canonical_open == alias_open)
            assert(rawequal(alias_open(), standard_os))
        ]])
    end)

    it("coexists with Lua's coroutine library through one aliased image",
       function()
        assert.equal("link", lfs.symlinkattributes(
            BUILD .. "/titan/coroutine.so", "mode"))
        run_lua([[
            local builtin = require "coroutine"
            local standard_coroutine = require "titan.coroutine"
            assert(type(builtin) == "table")
            assert(type(standard_coroutine) == "userdata")
            assert(standard_coroutine.marker() == 100)
            assert(require "coroutine" == builtin)
            assert(package.loaded.coroutine == builtin)

            local canonical_open = assert(package.loadlib(
                "]] .. BUILD .. [[/coroutine.so", "luaopen_titan_coroutine"))
            local alias_open = assert(package.loadlib(
                "]] .. BUILD .. [[/titan/coroutine.so", "luaopen_titan_coroutine"))
            assert(canonical_open == alias_open)
            assert(rawequal(canonical_open(), standard_coroutine))
            assert(package.loadlib(
                "]] .. BUILD .. [[/coroutine.so", "luaopen_coroutine") == nil)
            assert(package.loadlib("]] .. BUILD .. [[/coroutine.so",
                "luaopen_coro") == nil)
        ]])
    end)

    it("links a standalone using canonical os beside Lua's builtin os",
       function()
        assert_compile_ok("--tree " .. APPLICATION .. " standard_app")
        local ok, output, why, code = run_command(
            BASE_ENV .. "./standard_app")
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end)

    it("preserves direct main and selects an initialized registry hook",
       function()
        assert_compile_ok("--tree " .. BOOTSTRAP .. " direct_main")
        local ok, output, why, code = run_command(BASE_ENV .. "./direct_main")
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(9, code)

        assert_compile_ok("--tree " .. BOOTSTRAP .. " hooked_main")
        ok, output, why, code = run_command(BASE_ENV .. "./hooked_main")
        assert.falsy(ok, output)
        assert.equal("exit", why)
        assert.equal(17, code)
    end)
end)

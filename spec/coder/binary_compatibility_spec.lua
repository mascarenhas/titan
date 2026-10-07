-- Compile against one DSO, replace only that DSO, then load the unchanged
-- consumer in a fresh Lua process. No source file or paired archive is ever
-- available to turn these checks into source/static linking accidentally.
local h = require "spec.support.helpers"
local lfs = require "lfs"
local driver = require "titan-compiler.driver"
local compiler_io = require "titan-compiler.io"
local platform = require "titan-compiler.platform"
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua" .. (platform.windows and ".exe" or "")
local REPOSITORY = assert(lfs.currentdir())

local generated = {}
local serial = 0

-- Native interface inspection deliberately caches dlopen handles for the
-- process lifetime. Different cases need different logical/provider names;
-- replacement within one case keeps exactly the same names and paths.
local function scoped(text)
    if platform.windows then text = text:gsub("%.so%f[%A]", ".dll") end
    return (text:gsub("bc180_", "bc180_" .. serial .. "_"))
end

local function run(arguments)
    arguments = { table.unpack(arguments) }
    if platform.windows and arguments[1] == "env" then arguments[1] = "env.exe" end
    local result = compiler_io.new_sync():run(arguments)
    assert.is_true(result.started and result.ok, result.output or result.diagnostic)
    return (result.output or ""):gsub("\r\n", "\n")
end

local function call(code)
    return h.call("string", scoped(code))
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function read(path)
    local file = assert(io.open(scoped(path), "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function save_artifact(source, target, suffix)
    local file = assert(io.open(scoped(target .. suffix), "wb"))
    assert(file:write(read(source .. suffix)))
    assert(file:close())
    generated[scoped(target)] = true
end

local function run_native_harness(source, objects)
    local cdriver = require "c-parser.cdriver"
    local core = require "titan-compiler.coder.core"
    local prefix = require("spec.support.installed_prefix").active()
    local paths = driver.installed_paths(prefix)
    local stem = scoped("bc180_harness")
    generated[stem] = true
    local file = assert(io.open(stem .. ".c", "w"))
    assert(file:write([[
#include <assert.h>
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "titan.h"

static int execute(lua_State *L, const char *source) {
    if (luaL_dostring(L, source) != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 0;
    }
    return 1;
}

static lua_State *new_state(void) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    lua_getglobal(L, "package");
    lua_pushstring(L, ]] .. core.c_string_literal(package.path) .. [[);
    lua_setfield(L, -2, "path");
    lua_pushstring(L, ]] .. core.c_string_literal(package.cpath) .. [[);
    lua_setfield(L, -2, "cpath");
    lua_pop(L, 1);
    titan_init_paths(L);
    return L;
}
]], scoped(source)))
    assert(file:close())
    local argv = assert(cdriver.split_shell_words(driver.CC))
    for _, argument in ipairs({ "--std=c99", "-O0", "-g", "-Wall", "-Wextra",
            "-I" .. paths.include, "-I" .. paths.lua_source,
            stem .. ".c" }) do
        argv[#argv + 1] = argument
    end
    for _, object in ipairs(objects or {}) do argv[#argv + 1] = scoped(object) end
    for _, input in ipairs(driver.installed_link_inputs(paths, driver.IS_DARWIN)) do
        argv[#argv + 1] = input
    end
    if not platform.windows then
        argv[#argv + 1] = "-pthread"
        argv[#argv + 1] = driver.IS_DARWIN and "-Wl,-export_dynamic" or "-Wl,--export-dynamic"
    end
    argv[#argv + 1], argv[#argv + 2] = "-o", stem .. ".exe"
    run(argv)
    run({ "./" .. stem .. ".exe" })
    return function() run({ "./" .. stem .. ".exe" }) end
end

local function build(modules)
    for _, module in ipairs(modules) do
        module.name, module.src = scoped(module.name), scoped(module.src)
        generated[module.name] = true
        assert.is_nil(lfs.attributes(module.name .. ".titan"))
        assert.is_nil(lfs.attributes(module.name .. ".a"))
    end
    -- The shared helper gives Windows compilation a fresh process while
    -- retaining this caller's installed SDK paths and configured native tools.
    local ok, err = h.build_so_chain(modules)
    assert.truthy(ok, err)
    for _, module in ipairs(modules) do
        assert.is_nil(lfs.attributes(module.name .. ".a"))
    end
end

local function fixture(provider, consumer)
    build({
        { name = "bc180_provider", src = provider },
        { name = "bc180_consumer", src = consumer },
    })
    return read("bc180_consumer.so")
end

local function replace(provider, consumer_image)
    build({ { name = "bc180_provider", src = provider } })
    assert.truthy(read("bc180_consumer.so") == consumer_image,
        "provider replacement changed the consumer binary")
end

local function runs(body)
    local ok, out = call([[
        local consumer = require "bc180_consumer"
    ]] .. body)
    assert.truthy(ok, out)
end

local function rejects(entity)
    local ok, out = call(string.format([[
        for attempt = 1, 2 do
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "incompatible replacement loaded on attempt " .. attempt)
            assert(type(err) == "string", "load failure was not a diagnostic")
            assert(err:lower():find("compatib", 1, true), err)
            assert(err:find(%q, 1, true), err)
        end
    ]], entity))
    assert.truthy(ok, out)
end

describe("selective binary dependency compatibility", function()
    before_each(function() serial = serial + 1 end)
    after_each(function()
        for name in pairs(generated) do
            for _, suffix in ipairs({ ".c", ".o", ".so", ".dll", ".dll.def", ".a",
                    ".ffi.h", ".titan.h", ".so.dSYM", ".exe", ".exe.dSYM" }) do
                remove_tree(name .. suffix)
            end
        end
        generated = {}
    end)

    it("exposes a Lua-independent ABI value through the canonical provider", function()
        build({ {
            name = "bc180_provider",
            src = [[
                initializations: integer = 0
                do
                    initializations = initializations + 1
                end
            ]],
        } })

        run_native_harness([[
#ifdef _WIN32
#include <windows.h>
#define RTLD_LAZY 0
#define RTLD_LOCAL 0
#define dlopen(path, mode) ((void *)LoadLibraryA(path))
#define dlsym(image, name) ((void *)GetProcAddress((HMODULE)(image), name))
#else
#include <dlfcn.h>
#endif
#include <string.h>

typedef const char *(*abi_value_fn)(void);

int main(void) {
    void *image = dlopen("./bc180_provider.so", RTLD_LAZY | RTLD_LOCAL);
    assert(image != NULL);

    void *raw = dlsym(image, "bc180_provider_abi_value");
    assert(raw != NULL);
    abi_value_fn query = titan_cast_func(abi_value_fn, raw);

    /* Query the ABI before creating any Lua state or initializing the module. */
    const char *abi = query();
    assert(abi != NULL);
    assert(strcmp(abi, TITAN_ABI_VERSION) == 0);

    lua_State *L = new_state();
    int top = lua_gettop(L);
    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module bc180_provider");
    assert(lua_isnil(L, -1));
    lua_pop(L, 1);

    void *legacy_raw = dlsym(image, "bc180_provider_abi");
    assert(legacy_raw != NULL);
    lua_CFunction legacy = titan_cast_func(lua_CFunction, legacy_raw);
    assert(legacy(L) == 1);
    assert(lua_gettop(L) == top + 1);
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), abi) == 0);
    lua_settop(L, top);

    lua_getfield(L, LUA_REGISTRYINDEX, "Titan module bc180_provider");
    assert(lua_isnil(L, -1));
    lua_pop(L, 1);

    void *open_raw = dlsym(image, "luaopen_bc180_provider");
    assert(open_raw != NULL);
    lua_CFunction open = titan_cast_func(lua_CFunction, open_raw);
    assert(open(L) == 1);
    lua_setglobal(L, "provider");
    assert(execute(L, "assert(provider.initializations == 1)"));

    top = lua_gettop(L);
    TitanModuleProvider provider =
        titan_module_provider(L, "bc180_provider", NULL);
    assert(provider.handle == NULL);
    assert(provider.symbols != NULL);

    void *canonical = titan_module_symbol(
        L, provider, "bc180_provider_abi_value");
    assert(canonical == raw);
    abi_value_fn canonical_query = titan_cast_func(abi_value_fn, canonical);
    assert(strcmp(canonical_query(), abi) == 0);
    assert(lua_gettop(L) == top);
    assert(execute(L, "assert(provider.initializations == 1)"));

    lua_close(L);
    return 0;
}
]])
    end)

    it("accepts removal, addition and type changes of unused declarations", function()
        local image = fixture([[
            unused: integer = 7
            function removed(): integer return 5 end
            function changed(input: integer): integer return input end
            function answer(): integer return 41 end
            record Unused item: integer end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        runs("assert(consumer.run() == 41)")
        replace([[
            function added(): string return "new" end
            function answer(): integer return 42 end
            function changed(input: string): string return input end
            unused: string = "changed"
            record Unused item: string; extra: boolean end
        ]], image)
        runs("assert(consumer.run() == 42)")
    end)

    it("resolves moved variable and canonical callable slots without changing direct calls", function()
        local image = fixture([[
            counter: integer = 10
            spare: integer = 2
            function answer(input: integer): integer return input + counter end
            function unused(): integer return -1 end
            record Box n: integer end
            function Box.answer(input: integer): integer return input + 100 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer
                p.counter = p.counter + 1
                local answer = p.answer
                local static = p.Box.answer
                return p.answer(1) + answer(2) + static(3) + p.counter
            end
            function get_function(): function(integer): integer
                return p.answer
            end
            function get_static(): function(integer): integer
                return p.Box.answer
            end
        ]])
        runs([[
            local p = require "bc180_provider"
            assert(rawequal(consumer.get_function(), p.answer))
            assert(rawequal(consumer.get_static(), p.Box.answer))
            assert(consumer.run() == 139)
            assert(p.counter == 11 and p.spare == 2)
        ]])
        replace([[
            extra: string = "shifts every later slot"
            spare: integer = 9
            counter: integer = 20
            function unused(): integer return -2 end
            function added(): integer return -3 end
            function answer(input: integer): integer return input + counter end
            record Earlier n: integer end
            record Box n: integer end
            function Box.aaa(): integer return -4 end
            function Box.answer(input: integer): integer return input + 200 end
        ]], image)
        runs([[
            local p = require "bc180_provider"
            assert(rawequal(consumer.get_function(), p.answer))
            assert(rawequal(consumer.get_static(), p.Box.answer))
            assert(consumer.run() == 269)
            assert(p.counter == 21 and p.spare == 9)
            assert(p.extra == "shifts every later slot")
        ]])
    end)

    it("uses source module state for Lua calls through cross-module callable adapters", function()
        -- Different provider-only callable signatures move its private tag
        -- slots away from the consumer's. A wrong module owner must not happen
        -- to find the expected tag at the same private slot in both modules.
        local unrelated = {}
        for count = 1, 15 do
            local parameters = {}
            for index = 1, count do
                parameters[index] = "p" .. index .. ": integer"
            end
            unrelated[#unrelated + 1] = "function unused" .. count .. "("
                .. table.concat(parameters, ",") .. "): integer return 0 end"
        end
        fixture(table.concat(unrelated, "\n") .. [[
            function factory(x: integer): function(): integer
                return function(): integer return x + 1 end
            end
            record Factory n: integer end
            function Factory:make(x: integer): function(): integer
                local n = self.n
                return function(): integer return n + x end
            end
            function new_factory(): Factory return Factory.new(1) end
        ]], [[
            local p = import "bc180_provider"
            function view(): function(value): value
                local adjusted: function(value): value = p.factory
                return adjusted
            end
            function nested_view(): function(value, value): value
                local first: function(value): value = p.factory
                local second: function(value, value): value = first
                return second
            end
            function bound_view(): function(value): value
                local bound = p.new_factory():make
                local adjusted: function(value): value = bound
                return adjusted
            end
            function invoke(candidate: value): integer
                local f: function(): integer = candidate
                return f()
            end
        ]])
        runs([[
            local p = require "bc180_provider"
            local direct = p.factory(41)
            local direct_bound = p.new_factory():make(41)
            local adapted = consumer.view()(41)
            local nested = consumer.nested_view()(41, "ignored")
            local bound = consumer.bound_view()(41)
            local _, direct_tag = debug.getupvalue(direct, 2)
            assert(direct_tag ~= nil, "source function tag is absent")
            for _, inner in ipairs({direct, direct_bound, adapted, nested, bound}) do
                local _, tag = debug.getupvalue(inner, 2)
                assert(tag == direct_tag, "adapter lost the canonical returned function tag")
                assert(inner() == 42)
                assert(consumer.invoke(inner) == 42)
            end
        ]])
    end)

    local changed_functions = {
        { name = "parameter type", replacement = [[
            function consume(input: string): integer return 42 end
        ]] },
        { name = "parameter name", replacement = [[
            function consume(renamed: integer): integer return renamed end
        ]] },
        { name = "result type", replacement = [[
            function consume(input: integer): string return "changed" end
        ]] },
        { name = "variadic input", replacement = [[
            function consume(input: integer, ...: integer): integer return input end
        ]] },
        { name = "flexible results", replacement = [[
            function consume(input: integer): (...: integer) return input end
        ]] },
        { name = "removal", replacement = [[
            function other(input: integer): integer return input end
        ]] },
    }
    for _, case in ipairs(changed_functions) do
        it("rejects a used function's changed " .. case.name, function()
            local image = fixture([[
                function consume(input: integer): integer return input end
            ]], [[
                local p = import "bc180_provider"
                function run(): integer return p.consume { input = 42 } end
            ]])
            replace(case.replacement, image)
            rejects("consume")
        end)
    end

    it("returns the canonical consumer without checking another image's dependencies", function()
        build({ { name = "bc180_consumer", src = [[
            function seed(): integer return 1 end
        ]] } })
        local seed = assert(io.open(scoped("bc180_seed.so"), "wb"))
        seed:write(read("bc180_consumer.so"))
        seed:close()
        generated[scoped("bc180_seed")] = true
        local image = fixture([[
            record Box n: integer end
        ]], [[
            local p = import "bc180_provider"
            function read(box: p.Box): integer return box.n end
        ]])
        replace("record Box n: string end", image)
        assert(os.remove(scoped("bc180_provider.so")))
        local ok, out = call([[
            local seed = assert(package.loadlib("./bc180_seed.so",
                "luaopen_bc180_consumer"))()
            assert(seed.seed() == 1)
            -- Enter the second image directly: the registered logical module
            -- wins before the unused image's dependencies are inspected.
            for attempt = 1, 2 do
                local second = assert(package.loadlib("./bc180_consumer.so",
                    "luaopen_bc180_consumer"))()
                assert(rawequal(second, seed))
                assert(second.seed() == 1)
                assert(rawequal(require "bc180_consumer", seed))
            end
        ]])
        assert.truthy(ok, out)
    end)

    describe("canonical providers", function()
        local original = [[
            count: integer = 10
            spare: integer = 99
            function answer(input: integer): integer return count + input end
            record Box n: integer end
            function make(n: integer): Box return Box.new(n) end
            function Box.answer(input: integer): integer return count + input + 100 end
            function Box:read(input: integer): integer return self.n + count + input end
        ]]
        local replacement = [[
            added: string = "different slots and implementation"
            spare: integer = 999
            count: integer = 200
            function unused(): integer return -1 end
            record Box n: integer end
            function Box.aaa(): integer return -2 end
            function Box.answer(input: integer): integer return count + input + 1100 end
            function make(n: integer): Box return Box.new(n) end
            function answer(input: integer): integer return count + input + 1000 end
            function Box:read(input: integer): integer return self.n + count + input + 1000 end
        ]]
        local consumer = [[
            local p = import "bc180_provider"
            interface ExactRead
                function read(input: integer): integer
            end
            interface AdjustedRead
                function read(input: value): value
            end
            function count(): integer return p.count end
            function set(n: integer) p.count = n end
            function direct(input: integer): integer return p.answer(input) end
            function first(input: integer): integer
                local f = p.answer
                return f(input)
            end
            function get_function(): function(integer): integer return p.answer end
            function static_call(input: integer): integer return p.Box.answer(input) end
            function static_value(input: integer): integer
                local f = p.Box.answer
                return f(input)
            end
            function get_static(): function(integer): integer return p.Box.answer end
            function method(input: integer): integer return p.make(7):read(input) end
            function get_bound(n: integer): function(integer): integer
                return p.make(n):read
            end
            function exact_read(input: integer): integer
                local wrapped: ExactRead = p.make(7)
                return wrapped:read(input)
            end
            function adjusted_read(input: integer): integer
                local wrapped: AdjustedRead = p.make(7)
                return wrapped:read(input) as integer
            end
        ]]

        local function assertions(count, offset)
            return string.format([[
                consumer.set(%d)
                assert(consumer.count() == %d)
                assert(provider.count == %d and provider.spare == %d)
                assert(consumer.direct(2) == %d)
                assert(consumer.first(3) == %d)
                assert(consumer.static_call(4) == %d)
                assert(consumer.static_value(5) == %d)
                assert(consumer.method(6) == %d)
                assert(held(8) == %d)
                assert(consumer.exact_read(9) == %d)
                assert(consumer.adjusted_read(10) == %d)
                assert(rawequal(consumer.get_function(), provider.answer))
                assert(rawequal(consumer.get_static(), provider.Box.answer))
            ]], count, count, count, offset == 0 and 99 or 999,
                count + offset + 2, count + offset + 3,
                count + offset + 104, count + offset + 105,
                count + offset + 13, count + offset + 15,
                count + offset + 16, count + offset + 17)
        end

        it("uses the elected provider before a reordered or absent candidate DSO", function()
            local image = fixture(original, consumer)
            save_artifact("bc180_provider", "bc180_saved", ".so")
            replace(replacement, image)
            local script = [[
                local provider = assert(package.loadlib("./bc180_saved.so",
                    "luaopen_bc180_provider"))()
                local consumer = require "bc180_consumer"
                local held = consumer.get_bound(7)
            ]] .. assertions(40, 0)
            local ok, out = call(script)
            assert.truthy(ok, out)
            assert(os.remove(scoped("bc180_provider.so")))
            ok, out = call(script)
            assert.truthy(ok, out)
            assert.truthy(read("bc180_consumer.so") == image)
        end)

        it("checks the canonical provider contract even when the candidate matches", function()
            build({ { name = "bc180_provider", src = [[
                function answer(): string return "original" end
            ]] } })
            save_artifact("bc180_provider", "bc180_saved", ".so")
            fixture([[
                function answer(): integer return 42 end
            ]], [[
                local p = import "bc180_provider"
                function run(): integer return p.answer() end
            ]])
            local ok, out = call([[
                local provider = assert(package.loadlib("./bc180_saved.so",
                    "luaopen_bc180_provider"))()
                assert(provider.answer() == "original")
                for attempt = 1, 2 do
                    local ok, err = pcall(require, "bc180_consumer")
                    assert(not ok, "candidate metadata overrode the canonical contract")
                    assert(err:find("compatibility", 1, true), err)
                    assert(err:find("answer", 1, true), err)
                end
            ]])
            assert.truthy(ok, out)
        end)

        it("uses the provider elected while initializing an earlier dependency", function()
            local sources = {
                bc180_provider = original,
                bc180_facade = [[
                    local p = import "bc180_provider"
                    function count(): integer return p.count end
                ]],
            }
            local modules = {}
            for name, source in pairs(sources) do
                modules[scoped(name)] = scoped(source)
                generated[scoped(name)] = true
            end
            local ok, err = h.generate_modules(modules, scoped("bc180_facade"))
            assert.truthy(ok, err)
            build({
                { name = "bc180_provider", src = replacement },
                { name = "bc180_consumer", src = [[
                    local facade = import "bc180_facade"
                ]] .. consumer .. [[
                    function facade_count(): integer return facade.count() end
                ]] },
            })
            local called, out = call([[
                local consumer = require "bc180_consumer"
                local provider = require "bc180_provider"
                local held = consumer.get_bound(7)
                assert(consumer.count() == 10)
            ]] .. assertions(40, 0) .. [[
                assert(consumer.facade_count() == 40)
            ]])
            assert.truthy(called, out)
        end)

        it("keeps an executable's embedded provider when a dynamic consumer is loaded", function()
            local image = fixture(original, consumer)
            save_artifact("bc180_provider", "bc180_embedded", ".o")
            replace(replacement, image)
            local core = require "titan-compiler.coder.core"
            local source = [[
extern int luaopen_bc180_provider(lua_State *L);
int main(void) {
    lua_State *L = new_state();
    assert(luaopen_bc180_provider(L) == 1);
    lua_setglobal(L, "provider");
    int ok = execute(L, ]] .. core.c_string_literal([[
        consumer = require "bc180_consumer"
        held = consumer.get_bound(7)
    ]] .. assertions(40, 0)) .. [[);
    lua_close(L);
    return ok ? 0 : 1;
}
]]
            local rerun = run_native_harness(source, { "bc180_embedded.o" })
            assert(os.remove(scoped("bc180_provider.so")))
            rerun()
            assert.truthy(read("bc180_consumer.so") == image)
        end)

        it("keeps one consumer DSO's bindings independent in two live Lua states", function()
            local image = fixture(original, consumer)
            save_artifact("bc180_provider", "bc180_saved_first", ".so")
            replace(replacement, image)
            save_artifact("bc180_provider", "bc180_saved_second", ".so")
            assert(os.remove(scoped("bc180_provider.so")))
            local core = require "titan-compiler.coder.core"
            local function initialize(path, count)
                return string.format([[
                    local support = require "titan"
                    provider = assert(support._loadlibglobal(%q,
                        "luaopen_bc180_provider", "bc180_provider"))()
                    assert(provider.count == %d)
                    consumer = assert(support._loadlibglobal("./bc180_consumer.so",
                        "luaopen_bc180_consumer", "bc180_consumer"))()
                    held = consumer.get_bound(7)
                ]], path, count)
            end
            run_native_harness([[
int main(void) {
    lua_State *first = new_state();
    lua_State *second = new_state();
    int ok = execute(first, ]] .. core.c_string_literal(initialize("./bc180_saved_first.so", 10)) .. [[)
        && execute(second, ]] .. core.c_string_literal(initialize("./bc180_saved_second.so", 200)) .. [[);
    for (int i = 0; ok && i < 4; i++) {
        ok = execute(first, ]] .. core.c_string_literal(assertions(40, 0)) .. [[)
            && execute(second, ]] .. core.c_string_literal(assertions(400, 1000)) .. [[);
    }
    lua_close(second);
    if (ok) ok = execute(first, ]] .. core.c_string_literal(assertions(50, 0)) .. [[);
    lua_close(first);
    return ok ? 0 : 1;
}
]])
            assert.truthy(read("bc180_consumer.so") == image)
        end)
    end)

    it("keeps verification independent of mutable Lua globals", function()
        local image = fixture([[
            function answer(): integer return 1 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        replace("function answer(): string return 'changed' end", image)
        local ok, out = call([[
            type = function() return "table" end
            next = function() return nil end
            error = function() end
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "mutable globals disabled the verifier")
            assert(err:find("compatibility", 1, true), err)
            assert(err:find("answer", 1, true), err)
        ]])
        assert.truthy(ok, out)
    end)

    it("tracks writes even when an imported variable is never read", function()
        local image = fixture("target: integer = 1", [[
            local p = import "bc180_provider"
            function store() p.target = 42 end
        ]])
        replace("target: string = \"changed\"", image)
        rejects("target")
    end)

    it("rejects a mutable imported variable becoming const", function()
        local image = fixture("target: integer = 1", [[
            local p = import "bc180_provider"
            function run(): integer return p.target end
        ]])
        replace("const target: integer = 1", image)
        rejects("target")
    end)

    it("checks canonical generic signatures rather than individual instantiations", function()
        local image = fixture([[
            record Box<|T|> item: T end
            function identity<|T|>(input: T): T return input end
            function make<|T|>(input: T): Box<|T|> return Box.new(input) end
        ]], [[
            local p = import "bc180_provider"
            function number(): integer return p.identity<|integer|>(42) end
            function text(): string return p.identity<|string|>("forty-two") end
            function boxed(): integer return p.make<|integer|>(42).item end
        ]])
        runs([[
            assert(consumer.number() == 42)
            assert(consumer.text() == "forty-two")
            assert(consumer.boxed() == 42)
        ]])
        replace([[
            function unused(): string return "new" end
            record Box<|Element|> item: Element end
            function make<|Element|>(input: Element): Box<|Element|>
                return Box.new(input)
            end
            function identity<|Element|>(input: Element): Element return input end
        ]], image)
        runs([[
            assert(consumer.number() == 42)
            assert(consumer.text() == "forty-two")
            assert(consumer.boxed() == 42)
        ]])
    end)

    it("accepts changed private record storage and unused concrete members", function()
        local image = fixture([[
            record Box
                local hidden: integer
                n: integer
                text: string
            end
            function make(): Box return Box.new(1, 40, "old") end
            function Box:read(): integer return self.n end
            function Box:unused(): integer return 1 end
            function Box.unused_static(): integer return 2 end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer
                local box = p.make()
                box.n = box.n + 2
                return box:read()
            end
            function text(): string return p.make().text end
        ]])
        local function public_prefix()
            return assert(read("bc180_provider.c"):match(
                "typedef struct {([^{}]*)} _titan_nominal_[%w_]+_public_payload;"))
        end
        local prefix = public_prefix()
        replace([[
            record Box
                local hidden: string
                local extra: integer
                n: integer
                local another: string
                text: string
            end
            function Box:read(): integer return self.n end
            function make(): Box return Box.new("private", 7, 50, "more", "new") end
            function Box:added(): string return "new" end
        ]], image)
        assert.equal(prefix, public_prefix(),
            "private changes altered the compatible public C prefix")
        runs([[
            assert(consumer.run() == 52)
            assert(consumer.text() == "new")
        ]])
    end)

    local record_changes = {
        { name = "type", fields = "n: string; text: string", args = '"1", "x"' },
        { name = "order", fields = "text: string; n: integer", args = '"x", 1' },
        { name = "constness", fields = "const n: integer; text: string", args = '1, "x"' },
        { name = "addition", fields = "n: integer; text: string; more: integer", args = '1, "x", 2' },
    }
    for _, case in ipairs(record_changes) do
        it("rejects a referenced record's changed public field " .. case.name, function()
            local image = fixture([[
                record Box n: integer; text: string end
                function make(): Box return Box.new(1, "x") end
            ]], [[
                local p = import "bc180_provider"
                function run(): integer return p.make().n end
            ]])
            replace("record Box " .. case.fields .. " end\n" ..
                "function make(): Box return Box.new(" .. case.args .. ") end", image)
            rejects("Box")
        end)
    end

    it("accepts the first private record field for accessor-only consumers", function()
        local image = fixture([[
            record Box n: integer end
            function make(): Box return Box.new(41) end
        ]], [[
            local p = import "bc180_provider"
            function run(): integer return p.make().n end
        ]])
        replace([[
            record Box n: integer; local hidden: string end
            function make(): Box return Box.new(42, "private") end
        ]], image)
        runs("assert(consumer.run() == 42)")
    end)

    it("rejects removal of record literal authority by a private field", function()
        local image = fixture("record Box n: integer end", [[
            local p = import "bc180_provider"
            function run(): integer
                local box: p.Box = { n = 42 }
                return box.n
            end
        ]])
        runs("assert(consumer.run() == 42)")
        replace("record Box n: integer; local hidden: string end", image)
        rejects("literal")
    end)

    it("rejects replacing literal authority with a same-signature custom new", function()
        local image = fixture("record Box n: integer end", [[
            local p = import "bc180_provider"
            function run(): integer
                local box: p.Box = {n = 42}
                return box.n
            end
        ]])
        runs("assert(consumer.run() == 42)")
        replace([[
            record Box n: integer end
            function Box.new(n: integer): Box return {n = n + 1} end
        ]], image)
        rejects("Box.literal")
    end)

    it("allows an unchanged direct new consumer to use a same-signature override", function()
        local image = fixture("record Box n: integer end", [[
            local p = import "bc180_provider"
            function run(): integer return p.Box.new(41).n end
        ]])
        runs("assert(consumer.run() == 41)")
        replace([[
            record Box n: integer end
            function Box.new(n: integer): Box return {n = n + 1} end
        ]], image)
        runs("assert(consumer.run() == 42)")
    end)

    it("rejects overriding a constructor used in a constant module initializer", function()
        local image = fixture("record Box n: integer end", [[
            local p = import "bc180_provider"
            box: p.Box = p.Box(41)
            function run(): integer return box.n end
        ]])
        runs("assert(consumer.run() == 41)")
        replace([[
            record Box n: integer end
            function Box.new(n: integer): Box return {n = n + 1} end
        ]], image)
        rejects("Box.literal")
    end)

    it("requires raw construction authority for a DSO constructor with fused native storage", function()
        local image = fixture("record Buffer const data: foreign *int end", [[
            foreign import "spec/fixtures/nominal_allocation_probe.h"
            local p = import "bc180_provider"
            function make(): (p.Buffer, integer)
                ffi.nominal_probe_begin(L)
                local buffer = p.Buffer(foreign int.new_array(3))
                local allocations = ffi.nominal_probe_end(L)
                buffer.data[0] = 42
                return buffer, allocations
            end
            function read(buffer: p.Buffer): integer return buffer.data[0] end
        ]])
        runs([[
            local buffer, allocations = consumer.make()
            assert(allocations == 1)
            collectgarbage('collect')
            assert(consumer.read(buffer) == 42)
        ]])
        replace([[
            record Buffer const data: foreign *int end
            function Buffer.new(data: foreign *int): Buffer return {data = data} end
        ]], image)
        rejects("Buffer.literal")
    end)

    it("tracks a bound method even when no direct method call exists", function()
        local image = fixture([[
            record Box n: integer end
            function Box:add(amount: integer): integer return self.n + amount end
        ]], [[
            local p = import "bc180_provider"
            function run(box: p.Box): function(integer): integer
                return box:add
            end
        ]])
        replace([[
            record Box n: integer end
            function Box:add(renamed: integer): integer return self.n + renamed end
        ]], image)
        rejects("add")
    end)

    it("keeps public union tags stable across private additions and ordinary fallthrough", function()
        local image = fixture([[
            union Choice first(n: integer); second(text: string) end
            function make(which: integer): Choice
                if which == 1 then return Choice.first(41) end
                return Choice.second("public")
            end
        ]], [[
            local p = import "bc180_provider"
            function run(which: integer): integer
                local result = 99
                case p.make(which)
                when first(n) then result = n
                when second(text) then result = #text
                end
                return result
            end
        ]])
        replace([[
            union Choice
                local hidden()
                first(n: integer)
                local another(value: string)
                second(text: string)
            end
            function make(which: integer): Choice
                if which == 1 then return Choice.first(42) end
                if which == 2 then return Choice.second("public") end
                return Choice.hidden()
            end
        ]], image)
        runs([[
            assert(consumer.run(1) == 42)
            assert(consumer.run(2) == 6)
            assert(consumer.run(3) == 99)
        ]])
    end)

    local union_changes = {
        { name = "variant order", declaration = "second(); first(n: integer)" },
        { name = "payload name", declaration = "first(renamed: integer); second()" },
        { name = "payload type", declaration = "first(n: string); second()" },
        { name = "public addition", declaration = "first(n: integer); second(); third()" },
    }
    for _, case in ipairs(union_changes) do
        it("rejects a referenced union's changed " .. case.name, function()
            local image = fixture([[
                union Choice first(n: integer); second() end
            ]], [[
                local p = import "bc180_provider"
                function run(choice: p.Choice): integer
                    local result = 0
                    case choice
                    when first(n) then result = n
                    end
                    return result
                end
            ]])
            replace("union Choice " .. case.declaration .. " end", image)
            rejects("Choice")
        end)
    end

    for _, trailing_else in ipairs({ "", "else local unreachable = 1" }) do
        local label = trailing_else == "" and "without else" or "with a falling-through else"
        it("rejects private union additions invalidating a return proof " .. label, function()
            local image = fixture("union Choice first(); second() end", [[
                local p = import "bc180_provider"
                function run(choice: p.Choice): string
                    case choice
                    when first() then return "first"
                    when second() then return "second"
            ]] .. trailing_else .. [[
                    end
                end
            ]])
            replace("union Choice local hidden(); first(); second() end", image)
            rejects("Choice")
        end)
    end

    it("accepts private union additions when an else independently returns", function()
        local image = fixture([[
            union Choice first(); second() end
            function make(): Choice return Choice.first() end
        ]], [[
            local p = import "bc180_provider"
            function run(): string
                case p.make()
                when first() then return "first"
                when second() then return "second"
                else return "private"
                end
            end
        ]])
        replace([[
            union Choice local hidden(); first(); second() end
            function make(): Choice return Choice.hidden() end
        ]], image)
        runs('assert(consumer.run() == "private")')
    end)

    it("checks every Interface method even when the consumer calls only one", function()
        local image = fixture([[
            interface Reader
                function read(): integer
                function unused(limit: integer): integer
            end
        ]], [[
            local p = import "bc180_provider"
            function run(reader: p.Reader): integer return reader:read() end
        ]])
        replace([[
            interface Reader
                function read(): integer
                function unused(renamed: integer): integer
            end
        ]], image)
        rejects("Reader")
    end)

    it("checks ordered Interface fields even when the consumer reads only one", function()
        local image = fixture([[
            interface Reader first: integer; second: integer end
        ]], [[
            local p = import "bc180_provider"
            function run(reader: p.Reader): integer return reader.first end
        ]])
        replace("interface Reader second: integer; first: integer end", image)
        rejects("Reader")
    end)

    it("tracks concrete methods used only by implicit Interface conversion", function()
        local image = fixture([[
            record Box n: integer end
            function make(): Box return Box.new(40) end
            function Box:add(amount: integer): integer return self.n + amount end
        ]], [[
            local p = import "bc180_provider"
            interface Adder function add(amount: integer): integer end
            function run(): integer
                local wrapped: Adder = p.make()
                return wrapped:add(2)
            end
        ]])
        runs("assert(consumer.run() == 42)")
        replace([[
            record Box n: integer end
            function make(): Box return Box.new(40) end
            function Box:add(renamed: integer): integer return self.n + renamed end
        ]], image)
        rejects("add")
    end)

    it("checks transitive nominal-owner methods without requiring a direct import", function()
        build({
            { name = "bc180_owner", src = [[
                record Box n: integer end
                function make(): Box return Box.new(42) end
                function Box:read(): integer return self.n end
            ]] },
            { name = "bc180_provider", src = [[
                local owner = import "bc180_owner"
                type Item = owner.Box
                function make(): Item return owner.make() end
            ]] },
            { name = "bc180_consumer", src = [[
                local p = import "bc180_provider"
                function run(): integer return p.make():read() end
            ]] },
        })
        local consumer_image = read("bc180_consumer.so")
        local provider_image = read("bc180_provider.so")
        runs("assert(consumer.run() == 42)")
        build({ { name = "bc180_owner", src = [[
            record Box n: integer end
            function make(): Box return Box.new(42) end
            function Box:read(): string return "changed" end
        ]] } })
        assert.truthy(read("bc180_consumer.so") == consumer_image)
        assert.truthy(read("bc180_provider.so") == provider_image)
        rejects("read")
    end)

    it("requires a referenced nominal alias to remain exposed", function()
        build({ { name = "bc180_owner", src = "record Box n: integer end" } })
        local image = fixture([[
            local owner = import "bc180_owner"
            type Item = owner.Box
        ]], [[
            local p = import "bc180_provider"
            function run(item: p.Item): integer return item.n end
        ]])
        replace([[
            local owner = import "bc180_owner"
            type Renamed = owner.Box
        ]], image)
        rejects("Item")
    end)

    it("rejects rebinding a nominal alias to a structurally identical owner", function()
        build({
            { name = "bc180_owner", src = "record Box n: integer end" },
            { name = "bc180_other", src = "record Box n: integer end" },
        })
        local image = fixture([[
            local owner = import "bc180_owner"
            type Item = owner.Box
        ]], [[
            local p = import "bc180_provider"
            function run(item: p.Item): integer return item.n end
        ]])
        replace([[
            local owner = import "bc180_other"
            type Item = owner.Box
        ]], image)
        rejects("Item")
    end)

    local function fake_provider(body, abi_value)
        assert.equal("string", type(abi_value))
        local file = assert(io.open(scoped("bc180_provider.c"), "w"))
        file:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *, const char *);
        ]], scoped(body))
        if platform.windows then
            -- Native Windows checks the plain-C ABI query before entering Lua
            -- or looking for compatibility metadata. Keep wrong ABI fixtures
            -- explicit independently of their authored Lua callbacks.
            local core = require "titan-compiler.coder.core"
            file:write("\nconst char *", scoped("bc180_provider_abi_value"),
                "(void) { return ", core.c_string_literal(abi_value), "; }\n")
        end
        file:close()
        local cdriver = require "c-parser.cdriver"
        local argv = assert(cdriver.split_shell_words(driver.CC))
        argv[#argv + 1] = "-shared"
        if platform.windows then
            argv[#argv + 1] = "-Wl,--export-all-symbols"
        else
            argv[#argv + 1] = "-fPIC"
            if driver.IS_DARWIN then
                argv[#argv + 1], argv[#argv + 2] = "-undefined", "dynamic_lookup"
            end
        end
        argv[#argv + 1], argv[#argv + 2] = "-o", scoped("bc180_provider.so")
        argv[#argv + 1] = scoped("bc180_provider.c")
        if platform.windows then argv[#argv + 1] = PREFIX .. "/lib/liblua55.a" end
        run(argv)
    end

    it("does not consult replacement DSOs for a same-binary source dependency", function()
        local sources = {
            bc180_provider = "function answer(): integer return 42 end",
            bc180_consumer = [[
                local p = import "bc180_provider"
                function run(): integer return p.answer() end
            ]],
        }
        local modules = {}
        for name, source in pairs(sources) do
            modules[scoped(name)] = scoped(source)
            generated[scoped(name)] = true
        end
        local ok, err = h.generate_modules(modules, scoped("bc180_consumer"))
        assert.truthy(ok, err)
        local image = read("bc180_consumer.so")
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "wrong ABI"); return 1;
            }
        ]], "wrong ABI")
        assert.truthy(read("bc180_consumer.so") == image)
        runs("assert(consumer.run() == 42)")
    end)

    it("checks ABI before looking for compatibility metadata", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "wrong ABI"); return 1;
            }
        ]], "wrong ABI")
        local ok, out = call([[
            local ok, err = pcall(require, "bc180_consumer")
            assert(not ok, "wrong ABI loaded")
            assert(err:find("ABI", 1, true), err)
            assert(err:find("wrong ABI", 1, true), err)
            assert(not err:lower():find("compatib", 1, true), err)
        ]])
        assert.truthy(ok, out)
    end)

    it("rejects a missing compatibility entry before resolving native functions", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "2"); return 1;
            }
        ]], "2")
        rejects("missing")
    end)

    it("rejects a malformed compatibility chunk before initialization", function()
        fixture("function answer(): integer return 42 end", [[
            local p = import "bc180_provider"
            function run(): integer return p.answer() end
        ]])
        fake_provider([[
            int bc180_provider_abi(lua_State *L) {
                lua_pushstring(L, "2"); return 1;
            }
            int bc180_provider_compatibility(lua_State *L) {
                lua_pushstring(L, "this is not a valid Lua chunk"); return 1;
            }
        ]], "2")
        rejects("compatib")
    end)

    describe("incremental replacement", function()
        local workspace

        before_each(function()
            workspace = assert(compiler_io.new_sync():tmpname())
            assert(os.remove(workspace))
            if platform.windows then workspace = assert(platform.path.normalize(workspace)) end
            assert(lfs.mkdir(workspace))
        end)

        after_each(function()
            remove_tree(workspace)
            remove_tree(scoped("bc180_consumer.lua"))
        end)

        it("retains dynamic slots and transitive checks through compile-only and warm final links", function()
            local cdriver = require "c-parser.cdriver"
            local repository = assert(lfs.currentdir())
            local prefix = PREFIX
            local function compile(...)
                local primer = string.format(
                    "package.path = %q .. package.path; package.cpath = %q .. package.cpath",
                    repository .. "/?.lua;" .. repository .. "/?/init.lua;",
                    repository .. "/titan-runtime/bootstrap/?" ..
                        (platform.windows and ".dll" or ".so") .. ";")
                local argv = {
                    "env", "TITAN_RUNTIME_PREBUILT=1", "CCACHE_DISABLE=1",
                    "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_ROCKS_ROOT=" .. prefix,
                    "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=-O0 -fno-lto",
                    "TITAN_EXTRA_LDFLAGS=-fno-lto", LUA, "-E",
                }
                if platform.windows then
                    -- A private file preserves escaped Windows paths through
                    -- the native command transport before entering titanc.
                    local bootstrap = assert(platform.join(
                        workspace, "compiler-bootstrap.lua"))
                    local script = assert(io.open(bootstrap, "wb"))
                    assert(script:write(primer, [[

local program = table.remove(arg, 1)
arg[0] = program
dofile(program)
]]))
                    assert(script:close())
                    argv[#argv + 1] = bootstrap
                else
                    argv[#argv + 1], argv[#argv + 2] = "-e", primer
                end
                for _, argument in ipairs({ repository .. "/titanc",
                        "--tree", workspace }) do
                    argv[#argv + 1] = argument
                end
                for _, argument in ipairs({ ... }) do
                    argv[#argv + 1] = scoped(argument)
                end
                run(argv)
            end

            build({
                { name = "bc180_owner", src = [[
                    record Item n: integer end
                    function make(): Item return Item.new(7) end
                    function Item:read(): integer return self.n end
                ]] },
                { name = "bc180_provider", src = [[
                    local owner = import "bc180_owner"
                    counter: integer = 10
                    function answer(delta: integer): integer return counter + delta end
                    function make(): owner.Item return owner.make() end
                    record Box n: integer end
                    function Box.answer(): integer return 100 end
                ]] },
            })
            local stem = workspace .. "/bc180_consumer"
            local file = assert(io.open(scoped(stem .. ".titan"), "w"))
            assert(file:write(scoped([[
                local p = import "bc180_provider"
                function run(): integer
                    p.counter = p.counter + 1
                    local answer = p.answer
                    local static = p.Box.answer
                    local item = p.make()
                    local method = item:read
                    return answer(1) + p.answer(2) + static() + method()
                end
            ]])))
            assert(file:close())
            generated[scoped("bc180_consumer")] = true

            compile("-c", "--incremental", "bc180_consumer")
            local object = read(stem .. ".o")
            local future = os.time() + 60
            assert(lfs.touch(scoped(stem .. ".o"), future))
            for _ = 1, 2 do
                compile("--incremental", "bc180_consumer")
                assert.equal(future, lfs.attributes(scoped(stem .. ".o"), "modification"))
                assert.truthy(read(stem .. ".o") == object,
                    "warm final link rebuilt the compile-only consumer object")
                runs("assert(consumer.run() == 132)")
            end

            local image = read("bc180_consumer.so")
            replace([[
                local owner = import "bc180_owner"
                unrelated: string = "moves variable and closure slots"
                counter: integer = 20
                function unused(): integer return -1 end
                function make(): owner.Item return owner.make() end
                function answer(delta: integer): integer return counter + delta end
                record Box n: integer end
                function Box.aaa(): integer return -2 end
                function Box.answer(): integer return 200 end
            ]], image)
            runs("assert(consumer.run() == 252)")
            build({ { name = "bc180_owner", src = [[
                record Item n: integer end
                function make(): Item return Item.new(7) end
                function Item:read(): string return "incompatible" end
            ]] } })
            assert.truthy(read("bc180_consumer.so") == image)
            assert.truthy(read(stem .. ".o") == object)
            rejects("read")
        end)
    end)
end)

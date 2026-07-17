-- Native support behavior belongs to the non-LuaCov standard-library group.
local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local REPO = lfs.currentdir()
local PREFIX = require("spec.support.installed_prefix").active()
local LUA = PREFIX .. "/bin/lua"
local INCLUDE = PREFIX .. "/include"
local LUA_LIB = PREFIX .. "/lib/liblua.a"

local function quote_argv(argv)
    local quoted = {}
    for index, argument in ipairs(argv) do
        quoted[index] = assert(cdriver.shell_quote(argument))
    end
    return table.concat(quoted, " ")
end

local function run(argv, cwd)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(cwd))
    local pipe = assert(io.popen(quote_argv(argv) .. " 2>&1", "r"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    assert.truthy(lfs.chdir(previous))
    return ok == true, output, why, code
end

local function canonical_directory(path)
    local previous = lfs.currentdir()
    assert.truthy(lfs.chdir(path))
    local canonical = lfs.currentdir()
    assert.truthy(lfs.chdir(previous))
    return canonical
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function compile_shared(workspace, source, output)
    local argv = {
        "env", "CCACHE_DISABLE=1", "cc", "-std=c99", "-fPIC", "-shared",
    }
    local uname = assert(io.popen("uname", "r"))
    local platform = uname:read("*a")
    uname:close()
    if platform:find("Darwin", 1, true) then
        table.insert(argv, "-undefined")
        table.insert(argv, "dynamic_lookup")
    end
    for _, argument in ipairs({
        "-I", INCLUDE, "-o", output, source,
    }) do
        table.insert(argv, argument)
    end
    return run(argv, workspace)
end

local function compile_state_harness(workspace, source, output)
    local argv = {
        "env", "CCACHE_DISABLE=1", "cc", "-std=c99", "-I", INCLUDE,
        source, REPO .. "/titan-runtime/titanlib.c",
        LUA_LIB, "-lm", "-o", output,
    }
    local uname = assert(io.popen("uname", "r"))
    local platform = uname:read("*a")
    uname:close()
    if not platform:find("Darwin", 1, true) then
        table.insert(argv, "-ldl")
    end
    return run(argv, workspace)
end

local function run_lua(workspace, code)
    return run({
        "env",
        "-u", "LUA_PATH", "-u", "LUA_CPATH",
        "-u", "LUA_PATH_5_5", "-u", "LUA_CPATH_5_5",
        LUA, "-e", string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.cpath = %q .. "/?.so;" .. %q .. "/?.so;" .. package.cpath
%s
]], workspace, workspace, REPO, code),
    }, workspace)
end

describe("titan._loadlibglobal", function()
    local workspace

    before_each(function()
        workspace = os.tmpname()
        assert.truthy(os.remove(workspace))
        assert.truthy(lfs.mkdir(workspace))
    end)

    after_each(function()
        if workspace then remove_tree(workspace) end
    end)

    it("promotes a previously local image into the process symbol namespace",
       function()
        write_file(workspace .. "/provider.c", [[
#include "lua.h"
#include "lauxlib.h"

int loader_test_value(void) { return 42; }

int luaopen_loader_provider(lua_State *L) {
    lua_newtable(L);
    return 1;
}
]])
        write_file(workspace .. "/consumer.c", [[
#include "lua.h"
#include "lauxlib.h"

extern int loader_test_value(void);

static int read_value(lua_State *L) {
    lua_pushinteger(L, loader_test_value());
    return 1;
}

int luaopen_loader_consumer(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, read_value);
    lua_setfield(L, -2, "read");
    return 1;
}
]])
        local ok, output = compile_shared(
            workspace, "provider.c", "provider.so")
        assert.truthy(ok, output)
        ok, output = compile_shared(workspace, "consumer.c", "consumer.so")
        assert.truthy(ok, output)

        ok, output = run_lua(workspace, [[
local local_open = assert(package.loadlib(
    "./provider.so", "luaopen_loader_provider"))
assert(type(local_open()) == "table")

local hidden = package.loadlib("./consumer.so", "luaopen_loader_consumer")
assert(hidden == nil)

local titan = require "titan"
local global_open = assert(titan._loadlibglobal(
    "./provider.so", "luaopen_loader_provider"))
assert(type(global_open()) == "table")

local consumer_open = assert(package.loadlib(
    "./consumer.so", "luaopen_loader_consumer"))
assert(consumer_open().read() == 42)
]])
        assert.truthy(ok, output)
    end)

    it("does not let the compiler's local cache satisfy a global request",
       function()
        write_file(workspace .. "/provider.c", [[
#include "lua.h"
int loader_test_value(void) { return 73; }
int luaopen_loader_provider(lua_State *L) { lua_newtable(L); return 1; }
]])
        write_file(workspace .. "/consumer.c", [[
#include "lua.h"
#include "lauxlib.h"
extern int loader_test_value(void);
static int read_value(lua_State *L) {
    lua_pushinteger(L, loader_test_value()); return 1;
}
int luaopen_loader_consumer(lua_State *L) {
    lua_pushcfunction(L, read_value); return 1;
}
]])
        local ok, output = compile_shared(
            workspace, "provider.c", "provider.so")
        assert.truthy(ok, output)
        ok, output = compile_shared(workspace, "consumer.c", "consumer.so")
        assert.truthy(ok, output)

        ok, output = run_lua(workspace, [[
local titan = require "titan"
assert(titan._loadlib("./provider.so", "luaopen_loader_provider"))
assert(package.loadlib("./consumer.so", "luaopen_loader_consumer") == nil)
assert(titan._loadlibglobal("./provider.so", "luaopen_loader_provider"))
local open = assert(package.loadlib(
    "./consumer.so", "luaopen_loader_consumer"))
local read = open()
assert(read() == 73)
]])
        assert.truthy(ok, output)
    end)

    it("maps a provider lazily when eager package loading cannot", function()
        write_file(workspace .. "/lazy.c", [[
#include "lua.h"
#include "lauxlib.h"
extern int deliberately_missing_loader_symbol(void);
static int unresolved(lua_State *L) {
    lua_pushinteger(L, deliberately_missing_loader_symbol());
    return 1;
}
int luaopen_lazy_provider(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, unresolved);
    lua_setfield(L, -2, "unresolved");
    return 1;
}
]])
        local ok, output = compile_shared(workspace, "lazy.c", "lazy.so")
        assert.truthy(ok, output)

        ok, output = run_lua(workspace, [[
assert(package.loadlib("./lazy.so", "luaopen_lazy_provider") == nil)
local titan = require "titan"
local open = assert(titan._loadlibglobal(
    "./lazy.so", "luaopen_lazy_provider"))
local module = open()
assert(type(module.unresolved) == "function")
]])
        assert.truthy(ok, output)
    end)

    it("reports canonical open and symbol failure stages", function()
        write_file(workspace .. "/empty.c", [[
#include "lua.h"
int luaopen_present(lua_State *L) { lua_pushboolean(L, 1); return 1; }
]])
        local ok, output = compile_shared(workspace, "empty.c", "empty.so")
        assert.truthy(ok, output)
        local canonical_empty = canonical_directory(workspace) .. "/empty.so"

        local script = string.format([[
local titan = require "titan"
local fn, message, stage = titan._loadlibglobal(
    "./missing.so", "luaopen_missing")
assert(fn == nil and type(message) == "string" and stage == "open")
assert(message:find("./missing.so", 1, true))

fn, message, stage = titan._loadlibglobal(
    "./empty.so", "luaopen_missing")
assert(fn == nil and type(message) == "string" and stage == "init")

local relative = assert(titan._loadlibglobal(
    "./empty.so", "luaopen_present"))
local absolute = assert(titan._loadlibglobal(
    %q, "luaopen_present"))
local bare = assert(titan._loadlibglobal(
    "empty.so", "luaopen_present"))
assert(relative == absolute and absolute == bare)
local cache = assert(debug.getregistry()[
    "3f6cae7b-8aeb-42eb-9f72-a978cfe96f7c"])
local entries = 0
for path, handle in pairs(cache) do
    entries = entries + 1
    assert(path == %q)
    assert(type(handle) == "userdata")
end
assert(entries == 1)
]], workspace .. "/empty.so", canonical_empty)
        ok, output = run_lua(workspace, script)
        assert.truthy(ok, output)
    end)

    it("creates a distinct canonical cache in each independent Lua state",
       function()
        write_file(workspace .. "/provider.c", [[
#include "lua.h"
int luaopen_state_provider(lua_State *L) { (void)L; return 0; }
]])
        local ok, output = compile_shared(
            workspace, "provider.c", "provider.so")
        assert.truthy(ok, output)

        write_file(workspace .. "/states.c", [[
#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CACHE_KEY "3f6cae7b-8aeb-42eb-9f72-a978cfe96f7c"

int luaopen_titan(lua_State *L);

static int cache_is_absent(lua_State *L) {
  int absent;
  lua_pushliteral(L, CACHE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  absent = lua_isnil(L, -1);
  lua_pop(L, 1);
  return absent;
}

static int load_provider(lua_State *L, const char *path) {
  luaL_requiref(L, "titan", luaopen_titan, 1);
  lua_getfield(L, -1, "_loadlibglobal");
  lua_remove(L, -2);
  lua_pushstring(L, path);
  lua_pushliteral(L, "luaopen_state_provider");
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    fprintf(stderr, "%s\n", lua_tostring(L, -1));
    return 0;
  }
  if (!lua_isfunction(L, -1)) return 0;
  lua_pop(L, 1);
  return 1;
}

static int inspect_cache(lua_State *L, const char *canonical,
                         const void **table, void **handle) {
  int entries = 0;
  lua_pushliteral(L, CACHE_KEY);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (!lua_istable(L, -1)) return 0;
  *table = lua_topointer(L, -1);
  lua_pushnil(L);
  while (lua_next(L, -2) != 0) {
    const char *key = lua_tostring(L, -2);
    if (key == NULL || strcmp(key, canonical) != 0 ||
        !lua_islightuserdata(L, -1)) return 0;
    *handle = lua_touserdata(L, -1);
    entries++;
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return entries == 1;
}

int main(int argc, char **argv) {
  lua_State *first;
  lua_State *second;
  char *canonical;
  const void *first_table = NULL, *second_table = NULL;
  void *first_handle = NULL, *second_handle = NULL;
  if (argc != 2) return 2;
  canonical = realpath(argv[1], NULL);
  if (canonical == NULL) return 3;
  first = luaL_newstate();
  second = luaL_newstate();
  if (first == NULL || second == NULL) return 4;
  luaL_openlibs(first);
  luaL_openlibs(second);
  if (!cache_is_absent(first) || !cache_is_absent(second)) return 5;
  if (!load_provider(first, argv[1])) return 6;
  if (!cache_is_absent(second)) return 7;
  if (!load_provider(second, argv[1])) return 8;
  if (!inspect_cache(first, canonical, &first_table, &first_handle) ||
      !inspect_cache(second, canonical, &second_table, &second_handle)) return 9;
  if (first_table == second_table || first_handle != second_handle) return 10;
  lua_close(second);
  lua_close(first);
  free(canonical);
  return 0;
}
]])
        ok, output = compile_state_harness(
            workspace, "states.c", "states")
        assert.truthy(ok, output)
        ok, output = run({ "./states", workspace .. "/provider.so" },
            workspace)
        assert.truthy(ok, output)
    end)
end)

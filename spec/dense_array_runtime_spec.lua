local assert = require "luassert"
local cdriver = require "c-parser.cdriver"
local lfs = require "lfs"

local function quote(word)
    return assert(cdriver.shell_quote(word))
end

local function write_file(path, contents)
    local file = assert(io.open(path, "wb"))
    assert.truthy(file:write(contents))
    assert.truthy(file:close())
end

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path .. "/" .. entry)
            end
        end
        assert.truthy(lfs.rmdir(path))
    elseif mode then
        assert.truthy(os.remove(path))
    end
end

local function make_temp_dir()
    local path = assert(os.tmpname()) .. "-dense-array-runtime"
    os.remove(path)
    assert.truthy(lfs.mkdir(path))
    return path
end

local function append_words(argv, words, label)
    if not words or words == "" then return end
    local parsed, err = cdriver.split_shell_words(words)
    assert.truthy(parsed, "cannot parse " .. label .. ": " .. tostring(err))
    for _, word in ipairs(parsed) do argv[#argv + 1] = word end
end

local function run_argv(argv, environment)
    local words = {}
    for _, word in ipairs(argv) do words[#words + 1] = quote(word) end
    local command = table.concat(words, " ")
    if environment then command = environment .. " " .. command end
    local pipe = assert(io.popen(command .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function host_os()
    local pipe = assert(io.popen("uname -s"))
    local output = assert(pipe:read("*l"))
    assert.truthy(pipe:close())
    return output
end

local HARNESS = [=[
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "titan.h"

static char backing_root_key;
static char proxy_root_key;
static char weak_root_key;

static void push_backing(lua_State *L, Table *backing) {
    TValue value;
    assert(lua_checkstack(L, 1));
    sethvalue(L, &value, backing);
    lua_pushtvalue(L, value);
}

static void push_proxy(lua_State *L, Udata *proxy) {
    TValue value;
    assert(lua_checkstack(L, 1));
    setuvalue(L, &value, proxy);
    lua_pushtvalue(L, value);
}

static int live_hash_entries(const Table *backing) {
    unsigned i;
    int count = 0;
    if (isdummy(backing))
        return 0;
    for (i = 0; i < sizenode(backing); i++) {
        if (!isempty(gval(gnode(backing, i))))
            count++;
    }
    return count;
}

static void assert_shape(Table *backing, Udata *proxy, Table *metatable,
                         unsigned capacity, lua_Unsigned length) {
    TValue cycle;
    assert(backing->asize == capacity);
    assert(backing->metatable == NULL);
    assert(allocsizenode(backing) == 1);
    assert(live_hash_entries(backing) == 1);
    assert(!tagisempty(luaH_getint(backing, 0, &cycle)));
    assert(ttisfulluserdata(&cycle));
    assert(uvalue(&cycle) == proxy);
    assert(proxy->len == 0);
    assert(proxy->nuvalue == 1);
    assert(proxy->metatable == metatable);
    assert(ttistable(&proxy->uv[0].uv));
    assert(hvalue(&proxy->uv[0].uv) == backing);
    assert(titan_array_length(backing) == length);
    assert(titan_array_try_proxy(backing, metatable) == proxy);
    assert(titan_array_try_backing(&cycle, metatable) == backing);
}

static Table *new_rooted_array(lua_State *L, Table *metatable,
                               unsigned capacity, Udata **proxy) {
    Table *backing = titan_array_new(L, metatable, capacity);
    push_backing(L, backing);
    *proxy = titan_array_require_proxy(L, backing, metatable);
    return backing;
}

static void set_integer(lua_State *L, Table *backing, lua_Integer index,
                        lua_Integer value) {
    lua_pushinteger(L, value);
    titan_array_set_stack(L, backing, index, -1);
    lua_pop(L, 1);
}

static void set_nil(lua_State *L, Table *backing, lua_Integer index) {
    lua_pushnil(L);
    titan_array_set_stack(L, backing, index, -1);
    lua_pop(L, 1);
}

static void assert_integer(Table *backing, lua_Integer index,
                           lua_Integer expected) {
    TValue value;
    assert(!tagisempty(titan_array_get(backing, index, &value)));
    assert(ttisinteger(&value));
    assert(ivalue(&value) == expected);
}

static void assert_nil(Table *backing, lua_Integer index) {
    TValue value;
    assert(tagisempty(titan_array_get(backing, index, &value)));
    assert(ttisnil(&value));
}

static int growth_at_limit(lua_State *L) {
    (void)titan_array_growth(L, (lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY);
    return 0;
}

static int constructor_one_past(lua_State *L) {
    Table *metatable = titan_array_metatable(L);
    (void)titan_array_new(
        L, metatable, (lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY + 1u);
    return 0;
}

static void expect_c_error(lua_State *L, lua_CFunction function,
                           const char *message) {
    int status;
    lua_pushcfunction(L, function);
    status = lua_pcall(L, 0, 0, 0);
    assert(status != LUA_OK);
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strstr(lua_tostring(L, -1), message) != NULL);
    lua_pop(L, 1);
}

static void run_chunk(lua_State *L, const char *chunk) {
    int status = luaL_dostring(L, chunk);
    if (status != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        abort();
    }
}

static void test_capacity_length_and_hash(void) {
    static const unsigned exact_capacities[] = {0, 1, 3, 9};
    lua_State *L = luaL_newstate();
    Table *metatable;
    unsigned i;

    assert(L != NULL);
    metatable = titan_array_metatable(L);
    assert(metatable == titan_array_metatable(L));

    assert(TITAN_ARRAY_MAX_CAPACITY ==
        (((1u << (l_numbits(int) - 1)) <
          (MAX_SIZET / (sizeof(Value) + 1)))
            ? (1u << (l_numbits(int) - 1))
            : cast_uint(MAX_SIZET / (sizeof(Value) + 1))));
    assert(titan_array_growth(L, 1) == 2);
    assert(titan_array_growth(L, 2) == 4);
    assert(titan_array_growth(L, 3) == 4);
    assert(titan_array_growth(L, 4) == 8);
    assert(titan_array_growth(L, 5) == 8);
    assert(titan_array_growth(
        L, (lua_Unsigned)TITAN_ARRAY_MAX_CAPACITY - 1u) ==
        TITAN_ARRAY_MAX_CAPACITY);
    expect_c_error(L, growth_at_limit, "array index too large");
    expect_c_error(L, constructor_one_past, "array index too large");

    for (i = 0; i < sizeof(exact_capacities) /
                          sizeof(exact_capacities[0]); i++) {
        int top = lua_gettop(L);
        Udata *proxy;
        Table *backing = new_rooted_array(
            L, metatable, exact_capacities[i], &proxy);
        assert_shape(backing, proxy, metatable, exact_capacities[i], 0);
        lua_settop(L, top);
        lua_gc(L, LUA_GCCOLLECT);
    }

    {
        Udata *proxy;
        Table *backing = new_rooted_array(L, metatable, 3, &proxy);
        set_integer(L, backing, 1, 11);
        set_integer(L, backing, 3, 33);
        assert_shape(backing, proxy, metatable, 3, 3);

        /* Interior deletion keeps the highest-present-positive length. */
        set_nil(L, backing, 2);
        assert_shape(backing, proxy, metatable, 3, 3);
        assert_nil(backing, 2);

        /* A tail deletion backscans across the hole. */
        set_nil(L, backing, 3);
        assert_shape(backing, proxy, metatable, 3, 1);
        assert_integer(backing, 1, 11);

        /* Nil above capacity is an allocation-free no-op. */
        set_nil(L, backing, 100);
        assert_shape(backing, proxy, metatable, 3, 1);

        /* A non-nil write grows strictly past index 4: 3 -> 8. */
        set_integer(L, backing, 4, 44);
        assert_shape(backing, proxy, metatable, 8, 4);
        assert_integer(backing, 1, 11);
        assert_integer(backing, 4, 44);

        /* Every later resize preserves both key 0 and the saved hint. */
        set_integer(L, backing, 9, 99);
        assert_shape(backing, proxy, metatable, 16, 9);
        titan_array_resize(L, backing, 32);
        assert_shape(backing, proxy, metatable, 32, 9);

        set_integer(L, backing, 8, 88);
        assert_shape(backing, proxy, metatable, 32, 9);
        set_nil(L, backing, 9);
        assert_shape(backing, proxy, metatable, 32, 8);
        set_nil(L, backing, 8);
        assert_shape(backing, proxy, metatable, 32, 4);
        set_nil(L, backing, 4);
        assert_shape(backing, proxy, metatable, 32, 1);
        set_nil(L, backing, 1);
        assert_shape(backing, proxy, metatable, 32, 0);

        assert_nil(backing, 0);
        assert_nil(backing, -1);
        assert_nil(backing, LUA_MININTEGER);
    }

    /*
    ** Exercise a successful positive write well above the 16-bit range without
    ** approaching MAXASIZE. The strictly-greater rule grows index 65537 to
    ** capacity 131072; assert_shape simultaneously proves the value stayed in
    ** the array part and the hash still contains only key 0.
    */
    {
        int top = lua_gettop(L);
        const lua_Integer high_index = 65537;
        Udata *proxy;
        Table *backing = new_rooted_array(L, metatable, 0, &proxy);
        set_integer(L, backing, high_index, 77);
        assert_shape(backing, proxy, metatable, 131072u,
                     (lua_Unsigned)high_index);
        assert_integer(backing, high_index, 77);
        assert_nil(backing, high_index - 1);
        set_nil(L, backing, high_index);
        assert_shape(backing, proxy, metatable, 131072u, 0);
        lua_settop(L, top);
    }

    lua_close(L);
}

static void test_lua_callbacks_and_boxing(void) {
    lua_State *L = luaL_newstate();
    Table *metatable;
    Table *outer;
    Table *inner;
    Table *map;
    Udata *outer_proxy;
    Udata *inner_proxy;
    TValue value;

    assert(L != NULL);
    luaL_openlibs(L);
    metatable = titan_array_metatable(L);

    outer = new_rooted_array(L, metatable, 0, &outer_proxy);
    inner = new_rooted_array(L, metatable, 1, &inner_proxy);
    set_integer(L, inner, 1, 7);

    /* Titan/internal nested Arrays store raw backings. */
    push_backing(L, inner);
    titan_array_set_stack(L, outer, 1, -1);
    lua_pop(L, 1);

    /* An ordinary Map, even with an unrelated key 0, is not misboxed. */
    lua_newtable(L);
    value = lua_totvalue(L, -1);
    map = hvalue(&value);
    lua_pushliteral(L, "unrelated");
    lua_rawseti(L, -2, 0);
    assert(titan_array_try_proxy(map, metatable) == NULL);
    titan_array_set_stack(L, outer, 2, -1);
    lua_pushvalue(L, -1);
    lua_setglobal(L, "map");
    lua_pop(L, 1);

    push_proxy(L, outer_proxy);
    lua_setglobal(L, "outer");
    push_proxy(L, inner_proxy);
    lua_setglobal(L, "inner");
    lua_settop(L, 0);

    /*
    ** A Titan Array is table-like but not a Lua table:
    ** rawget/rawset/rawlen reject the userdata proxy, while stock Lua 5.5's
    ** table library accepts it through raw __index/__newindex/__len fields.
    */
    run_chunk(L,
        "local function fails_with(f, text)\n"
        "  local ok, err = pcall(f)\n"
        "  assert(not ok)\n"
        "  assert(tostring(err):find(text, 1, true), tostring(err))\n"
        "end\n"
        "assert(type(outer) == 'userdata')\n"
        "assert(getmetatable(outer) == 'Titan array metatable')\n"
        "assert(outer[1] == inner)\n"
        "assert(outer[1.0] == inner)\n"
        "assert(outer[2] == map)\n"
        "assert(outer[2][0] == 'unrelated')\n"
        "assert(#outer == 2)\n"
        "outer[3] = inner\n"
        "assert(outer[3] == inner)\n"
        "assert(#outer == 3)\n"
        "outer[2] = nil\n"
        "assert(#outer == 3)\n"
        "local seen = 0\n"
        "for k, v in ipairs(outer) do\n"
        "  seen = seen + 1\n"
        "  assert(k == 1 and v == inner)\n"
        "end\n"
        "assert(seen == 1)\n"
        "outer[3] = nil\n"
        "assert(#outer == 1)\n"
        "assert(outer[0] == nil)\n"
        "assert(outer[-1] == nil)\n"
        "assert(outer[math.mininteger] == nil)\n"
        "for _, key in ipairs({0, -1, math.mininteger}) do\n"
        "  fails_with(function() outer[key] = 1 end,\n"
        "             'Titan array index must be positive')\n"
        "end\n"
        "fails_with(function() return outer[1.5] end,\n"
        "           'Titan array index must be an integer')\n"
        "fails_with(function() outer[1.5] = 1 end,\n"
        "           'Titan array index must be an integer')\n"
        "fails_with(function() return outer['1'] end,\n"
        "           'Titan array index must be an integer')\n"
        "fails_with(function() outer[{}] = 1 end,\n"
        "           'Titan array index must be an integer')\n"
        "fails_with(function() outer[math.maxinteger] = true end,\n"
        "           'array index too large')\n"
        "assert(not pcall(rawget, outer, 1))\n"
        "assert(not pcall(rawset, outer, 1, true))\n"
        "assert(not pcall(rawlen, outer))\n"
        "assert(outer[1] == inner)\n"
        "assert(#outer == 1)\n");

    assert_shape(outer, outer_proxy, metatable, 4, 1);
    assert_shape(inner, inner_proxy, metatable, 1, 1);

    sethvalue(L, &value, map);
    assert(titan_array_try_backing(&value, metatable) == NULL);
    lua_newuserdatauv(L, 0, 1);
    value = lua_totvalue(L, -1);
    assert(titan_array_try_backing(&value, metatable) == NULL);
    lua_pop(L, 1);

    lua_close(L);
}

static void registry_store(lua_State *L, const void *key,
                           const TValue *value) {
    lua_pushtvalue(L, *value);
    lua_rawsetp(L, LUA_REGISTRYINDEX, key);
}

static void registry_clear(lua_State *L, const void *key) {
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, key);
}

static void make_weak_values(lua_State *L) {
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "v");
    lua_setfield(L, -2, "__mode");
    assert(lua_setmetatable(L, -2));
    lua_rawsetp(L, LUA_REGISTRYINDEX, &weak_root_key);
}

static void weak_store(lua_State *L, lua_Integer index,
                       const TValue *value) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &weak_root_key);
    assert(lua_type(L, -1) == LUA_TTABLE);
    lua_pushtvalue(L, *value);
    lua_rawseti(L, -2, index);
    lua_pop(L, 1);
}

static TValue weak_get(lua_State *L, lua_Integer index) {
    TValue value;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &weak_root_key);
    assert(lua_type(L, -1) == LUA_TTABLE);
    lua_rawgeti(L, -1, index);
    value = lua_totvalue(L, -1);
    lua_pop(L, 2);
    return value;
}

static void collect(lua_State *L) {
    lua_gc(L, LUA_GCCOLLECT);
    lua_gc(L, LUA_GCCOLLECT);
}

static size_t memory_bytes(lua_State *L) {
    return ((size_t)lua_gc(L, LUA_GCCOUNT) << 10) +
           (size_t)lua_gc(L, LUA_GCCOUNTB);
}

static void allocate_grow_drop(lua_State *L, Table *metatable) {
    int i;
    for (i = 0; i < 200; i++) {
        Udata *proxy;
        Table *backing = new_rooted_array(L, metatable, 0, &proxy);
        set_integer(L, backing, 33, i);
        assert_shape(backing, proxy, metatable, 64, 33);
        lua_pop(L, 1);
        if ((i % 17) == 0)
            lua_gc(L, LUA_GCSTEP, (size_t)1);
    }
    collect(L);
}

static void test_gc_mode(int mode) {
    lua_State *L = luaL_newstate();
    Table *metatable;
    TValue backing_value;
    TValue proxy_value;
    TValue observed;
    Table *backing;
    Udata *proxy;
    size_t first_envelope;
    size_t second_envelope;

    assert(L != NULL);
    luaL_openlibs(L);
    lua_gc(L, mode);
    metatable = titan_array_metatable(L);

    /* A backing held by a scanned native owner keeps its proxy alive. */
    make_weak_values(L);
    backing = new_rooted_array(L, metatable, 0, &proxy);
    sethvalue(L, &backing_value, backing);
    setuvalue(L, &proxy_value, proxy);
    weak_store(L, 1, &proxy_value);
    registry_store(L, &backing_root_key, &backing_value);
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisfulluserdata(&observed));
    assert(uvalue(&observed) == proxy);
    assert(titan_array_try_backing(&observed, metatable) == backing);
    registry_clear(L, &backing_root_key);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));

    /* A proxy-only root keeps the backing and its elements alive. */
    make_weak_values(L);
    backing = new_rooted_array(L, metatable, 0, &proxy);
    sethvalue(L, &backing_value, backing);
    setuvalue(L, &proxy_value, proxy);
    weak_store(L, 1, &backing_value);
    registry_store(L, &proxy_root_key, &proxy_value);
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttistable(&observed));
    assert(hvalue(&observed) == backing);
    assert(titan_array_try_proxy(hvalue(&observed), metatable) == proxy);
    registry_clear(L, &proxy_root_key);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));

    /* An otherwise-unreachable two-object cycle is collected normally. */
    make_weak_values(L);
    backing = new_rooted_array(L, metatable, 0, &proxy);
    sethvalue(L, &backing_value, backing);
    setuvalue(L, &proxy_value, proxy);
    weak_store(L, 1, &backing_value);
    weak_store(L, 2, &proxy_value);
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));
    observed = weak_get(L, 2);
    assert(ttisnil(&observed));

    /*
    ** Age the backing, then mutate it to point at a young long string. The
    ** backward barrier must retain the string in both collector modes.
    */
    make_weak_values(L);
    backing = new_rooted_array(L, metatable, 0, &proxy);
    setuvalue(L, &proxy_value, proxy);
    registry_store(L, &proxy_root_key, &proxy_value);
    lua_settop(L, 0);
    collect(L);
    {
        char bytes[512];
        TValue fetched;
        TString *young_string;
        Table *young_table;
        memset(bytes, 'x', sizeof(bytes));
        lua_pushlstring(L, bytes, sizeof(bytes));
        fetched = lua_totvalue(L, -1);
        young_string = tsvalue(&fetched);
        titan_array_set_stack(L, backing, 1, -1);
        lua_pop(L, 1);
        collect(L);
        assert(!tagisempty(titan_array_get(backing, 1, &fetched)));
        assert(ttisstring(&fetched));
        assert(tsvalue(&fetched) == young_string);

        lua_newtable(L);
        observed = lua_totvalue(L, -1);
        young_table = hvalue(&observed);
        weak_store(L, 1, &observed);
        titan_array_set_stack(L, backing, 1, -1);
        lua_pop(L, 1);
        collect(L);
        observed = weak_get(L, 1);
        assert(ttistable(&observed));
        assert(hvalue(&observed) == young_table);
        assert(!tagisempty(titan_array_get(backing, 1, &fetched)));
        assert(ttistable(&fetched));
        assert(hvalue(&fetched) == young_table);

        set_nil(L, backing, 1);
        collect(L);
        observed = weak_get(L, 1);
        assert(ttisnil(&observed));
    }
    registry_clear(L, &proxy_root_key);
    registry_clear(L, &weak_root_key);
    collect(L);

    /* Repeated allocation/growth/cycle collection reaches a stable envelope. */
    allocate_grow_drop(L, metatable);
    first_envelope = memory_bytes(L);
    allocate_grow_drop(L, metatable);
    second_envelope = memory_bytes(L);
    assert(second_envelope <= first_envelope + 64u * 1024u);

    lua_close(L);
}

static void test_per_state_metatables(void) {
    lua_State *first = luaL_newstate();
    lua_State *second = luaL_newstate();
    Table *first_metatable;
    Table *second_metatable;
    assert(first != NULL && second != NULL);
    first_metatable = titan_array_metatable(first);
    second_metatable = titan_array_metatable(second);
    assert(first_metatable != second_metatable);
    assert(first_metatable == titan_array_metatable(first));
    assert(second_metatable == titan_array_metatable(second));
    lua_close(first);
    lua_close(second);
}

int main(void) {
    test_capacity_length_and_hash();
    test_lua_callbacks_and_boxing();
#ifndef TITAN_ARRAY_HARDMEM_PROBE
    test_gc_mode(LUA_GCINC);
    test_gc_mode(LUA_GCGEN);
    test_per_state_metatables();
#endif
    puts("dense array runtime ok");
    return 0;
}
]=]

local LUA_SOURCES = {
    "lapi", "lcode", "lctype", "ldebug", "ldo", "ldump", "lfunc", "lgc",
    "llex", "lmem", "lobject", "lopcodes", "lparser", "lstate", "lstring",
    "ltable", "ltm", "lundump", "lvm", "lzio",
    "lauxlib", "lbaselib", "lcorolib", "ldblib", "liolib", "lmathlib",
    "loadlib", "loslib", "lstrlib", "ltablib", "lutf8lib", "linit",
}

local function compile_and_run(hard_memory)
    local root = make_temp_dir()
    local source = root .. "/dense_array_runtime.c"
    local executable = root .. "/dense_array_runtime"
    local platform = host_os()
    write_file(source, HARNESS)

    local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
    for _, word in ipairs({
        "--std=c99", hard_memory and "-O0" or "-O1", "-g",
        "-Wall", "-Wextra", "-fno-optimize-sibling-calls",
        "-I.", "-Ititan-runtime", "-Ilua-5.5.0/src", "-Ilibbacktrace",
    }) do
        argv[#argv + 1] = word
    end
    if hard_memory then
        argv[#argv + 1] = "-DHARDMEMTESTS"
        argv[#argv + 1] = "-DLUA_USE_APICHECK"
        argv[#argv + 1] = "-DTITAN_ARRAY_HARDMEM_PROBE"
        argv[#argv + 1] = platform == "Darwin"
            and "-DLUA_USE_MACOSX" or "-DLUA_USE_LINUX"
    end
    append_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS"),
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = source
    argv[#argv + 1] = "titan-runtime/titan.c"
    if hard_memory then
        for _, stem in ipairs(LUA_SOURCES) do
            argv[#argv + 1] = "lua-5.5.0/src/" .. stem .. ".c"
        end
    else
        argv[#argv + 1] = "lua-5.5.0/src/liblua.a"
    end
    for _, word in ipairs({
        "libbacktrace/.libs/libbacktrace.a", "-o", executable,
    }) do
        argv[#argv + 1] = word
    end
    append_words(argv, os.getenv("TITAN_TEST_EXTRA_LDFLAGS"),
        "TITAN_TEST_EXTRA_LDFLAGS")
    argv[#argv + 1] = "-lm"
    if platform ~= "Darwin" then argv[#argv + 1] = "-ldl" end
    argv[#argv + 1] = "-pthread"

    local ok, output, why, code =
        run_argv(argv, "CCACHE_DISABLE=1")
    if not ok then
        remove_tree(root)
        assert.truthy(ok, output .. "\n(" .. tostring(why) .. ", " ..
            tostring(code) .. ")")
    end

    local run_ok, run_output, run_why, run_code =
        run_argv({ executable })
    remove_tree(root)
    assert.truthy(run_ok, run_output .. "\n(" ..
        tostring(run_why) .. ", " .. tostring(run_code) .. ")")
    assert.matches("dense array runtime ok", run_output, 1, true)
end

describe("dense Array stock-Lua runtime", function()
    it("preserves capacity, length, proxy, callback, and GC invariants",
       function()
        compile_and_run(false)
    end)

    it("keeps both construction objects rooted under HARDMEMTESTS",
       function()
        compile_and_run(true)
    end)
end)

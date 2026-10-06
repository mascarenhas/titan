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

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = assert(file:read("*a"))
    assert.truthy(file:close())
    return contents
end

local function c_function_body(source, name)
    local escaped = name:gsub("(%W)", "%%%1")
    return assert(source:match(
        "%f[%w_]" .. escaped .. "%f[^%w_]%s*%b()%s*(%b{})"), name)
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
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lgc.h"
#include "lfunc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "titan.h"

#ifdef TITAN_RUNTIME_VISIBILITY_PROBE
#include <dlfcn.h>

int titan_runtime_export_probe(void) {
    return 1;
}

static void test_runtime_visibility(void) {
    void *image = dlopen(NULL, RTLD_LAZY);
    assert(image != NULL);
    assert(dlsym(image, "titan_runtime_export_probe") != NULL);
    assert(dlsym(image, "titan_array_growth") == NULL);
    assert(dlsym(image, "titan_module_provider") == NULL);
    assert(dlsym(image, "titan_publish_function_type_tag") == NULL);
    assert(dlclose(image) == 0);
}
#endif

static char backing_root_key;
static char proxy_root_key;
static char weak_root_key;
static const char *first_function_tag_candidate = "Titan function type unit.first tag";
static const char *second_function_tag_candidate = "Titan function type unit.second tag";
static int coercing_writer_calls;

typedef struct MetatableFaultAllocator {
    lua_Alloc delegate;
    void *delegate_userdata;
    int fail_cclosure;
    unsigned failed_cclosures;
} MetatableFaultAllocator;

static void *metatable_fault_allocator(void *userdata, void *block,
                                       size_t old_size, size_t new_size) {
    MetatableFaultAllocator *allocator = userdata;

    /*
    ** Array metatable construction creates two-upvalue C closures only after
    ** both candidate metatables have their non-callback fields. Reject that
    ** exact object allocation, including Lua's emergency-GC retry, without
    ** perturbing the earlier table and string allocations.
    */
    if (allocator->fail_cclosure && block == NULL &&
        old_size == LUA_TFUNCTION && new_size == sizeCclosure(2)) {
        allocator->failed_cclosures++;
        return NULL;
    }
    return allocator->delegate(
        allocator->delegate_userdata, block, old_size, new_size);
}

static int identity_writer(lua_State *L) {
    lua_settop(L, 1);
    return 1;
}

static void push_identity_writer(lua_State *L) {
    TValue value;
    /*
    ** One full-userdata upvalue both forces a real CClosure (rather than an
    ** LCF) and models the generated writer's captured module root.
    */
    lua_newuserdatauv(L, 0, 0);
    lua_pushcclosure(L, identity_writer, 1);
    value = lua_totvalue(L, -1);
    assert(ttisCclosure(&value));
}

static int coercing_integer_writer(lua_State *L) {
    int isinteger;
    lua_Integer value;
    assert(lua_type(L, lua_upvalueindex(1)) == LUA_TUSERDATA);
    coercing_writer_calls++;
    if (lua_type(L, 1) != LUA_TNUMBER)
        return luaL_error(L, "writer rejected value");
    value = lua_tointegerx(L, 1, &isinteger);
    if (!isinteger)
        return luaL_error(L, "writer rejected value");
    lua_pushinteger(L, value);
    return 1;
}

static void push_coercing_integer_writer(lua_State *L) {
    TValue value;
    lua_newuserdatauv(L, 0, 0);
    lua_pushcclosure(L, coercing_integer_writer, 1);
    value = lua_totvalue(L, -1);
    assert(ttisCclosure(&value));
}

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
    assert(isdummy(backing) || allocsizenode(backing) == 0);
    assert(live_hash_entries(backing) == 0);
    arr2obj(backing, 0, &cycle);
    assert(ttisfulluserdata(&cycle));
    assert(uvalue(&cycle) == proxy);
    assert(proxy->len == 0);
    assert(proxy->nuvalue == 2);
    assert(proxy->metatable == metatable);
    assert(ttistable(&proxy->uv[0].uv));
    assert(hvalue(&proxy->uv[0].uv) == backing);
    assert(ttisCclosure(&proxy->uv[1].uv));
    assert(titan_array_length(backing) == length);
    assert(titan_array_try_proxy(backing, metatable) == proxy);
    assert(titan_array_try_backing(&cycle, metatable) == backing);
}

static void assert_const_shape(Table *backing, Udata *proxy,
                               Table *metatable, unsigned capacity,
                               lua_Unsigned length) {
    TValue cycle;
    assert(backing->asize == capacity);
    assert(backing->metatable == NULL);
    assert(isdummy(backing) || allocsizenode(backing) == 0);
    assert(live_hash_entries(backing) == 0);
    arr2obj(backing, 0, &cycle);
    assert(ttisfulluserdata(&cycle));
    assert(uvalue(&cycle) == proxy);
    assert(proxy->len == 0);
    assert(proxy->nuvalue == 2);
    assert(proxy->metatable == metatable);
    assert(ttistable(&proxy->uv[0].uv));
    assert(hvalue(&proxy->uv[0].uv) == backing);
    assert(ttisnil(&proxy->uv[1].uv));
    assert(titan_array_length(backing) == length);
    assert(titan_array_try_proxy(backing, metatable) == proxy);
    assert(titan_array_try_backing(&cycle, metatable) == backing);
}

static Table *new_rooted_array(lua_State *L, Table *metatable,
                               unsigned capacity, Udata **proxy) {
    int base = lua_gettop(L);
    TValue writer;
    Table *backing;

    push_identity_writer(L);
    writer = lua_totvalue(L, -1);
    lua_pushnil(L);
    {
        int top = lua_gettop(L);
        backing = titan_array_new(
            L, metatable, capacity, &writer, L->top.p - 1);
        assert(lua_gettop(L) == top);
    }
    *proxy = titan_array_require_proxy(backing);
    /*
    ** Leave only the backing root requested by this helper. The writer and its
    ** captured owner must now survive exclusively through proxy uv[1].
    */
    lua_remove(L, base + 1);
    assert(lua_gettop(L) == base + 1);
    return backing;
}

static Table *new_rooted_const_array(lua_State *L, Table *metatable,
                                     unsigned capacity, Udata **proxy) {
    int base = lua_gettop(L);
    int top;
    Table *backing;
    lua_pushnil(L);
    top = lua_gettop(L);
    backing = titan_const_array_new(
        L, metatable, capacity, L->top.p - 1);
    assert(lua_gettop(L) == top);
    *proxy = titan_array_require_proxy(backing);
    assert(lua_gettop(L) == base + 1);
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

static int open_array_metatable(lua_State *L) {
    (void)titan_array_metatable(L);
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

static void test_array_metatable_publication(void) {
    lua_State *L = luaL_newstate();
    Table *metatable;
    Table *const_metatable;
    TValue value;

    assert(L != NULL);
    lua_pushliteral(L, "poisoned");
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
    expect_c_error(L, open_array_metatable,
                   "invalid Titan array metatable registry entry");
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), "poisoned") == 0);
    lua_pop(L, 1);

    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
    lua_pushliteral(L, "poisoned const");
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
    expect_c_error(L, open_array_metatable,
                   "invalid Titan array metatable registry entry");
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), "poisoned const") == 0);
    lua_pop(L, 1);

    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
    titan_array_metatables(L, &metatable, &const_metatable);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE);
    value = lua_totvalue(L, -1);
    assert(ttistable(&value));
    assert(hvalue(&value) == metatable);
    lua_rawgetp(L, -1, TITAN_BRAND);
    assert(lua_tointeger(L, -1) == TITAN_ARRAY);
    lua_pop(L, 2);
    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
    value = lua_totvalue(L, -1);
    assert(ttistable(&value));
    assert(hvalue(&value) == const_metatable);
    lua_rawgetp(L, -1, TITAN_BRAND);
    assert(lua_tointeger(L, -1) == TITAN_CONST_ARRAY);
    lua_pop(L, 2);
    lua_close(L);
}

static void test_array_metatable_allocation_retry(void) {
    static const char *callbacks[] = {
        "__index", "__newindex", "__len"
    };
    MetatableFaultAllocator allocator = {0};
    lua_State *L = luaL_newstate();
    Table *metatable;
    Table *const_metatable;
    TValue value;
    int status;
    unsigned i;

    assert(L != NULL);
    allocator.delegate = lua_getallocf(L, &allocator.delegate_userdata);
    assert(allocator.delegate != NULL);
    lua_setallocf(L, metatable_fault_allocator, &allocator);
    lua_pushcfunction(L, open_array_metatable);
    allocator.fail_cclosure = 1;
    status = lua_pcall(L, 0, 0, 0);
    allocator.fail_cclosure = 0;
    lua_setallocf(L, allocator.delegate, allocator.delegate_userdata);

    assert(status == LUA_ERRMEM);
    assert(allocator.failed_cclosures > 0);
    assert(lua_type(L, -1) == LUA_TSTRING);
    lua_pop(L, 1);

    /* The failed candidate must not become the state's nominal identity. */
    assert(lua_getfield(
        L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE) == LUA_TNIL);
    lua_pop(L, 1);
    assert(lua_getfield(
        L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE) == LUA_TNIL);
    lua_pop(L, 1);

    /* With allocation restored, retry publishes one complete canonical pair. */
    titan_array_metatables(L, &metatable, &const_metatable);
    assert(lua_getfield(
        L, LUA_REGISTRYINDEX, TITAN_ARRAY_METATABLE) == LUA_TTABLE);
    value = lua_totvalue(L, -1);
    assert(ttistable(&value));
    assert(hvalue(&value) == metatable);
    lua_getfield(L, -1, "__name");
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), TITAN_ARRAY_METATABLE) == 0);
    lua_pop(L, 1);
    lua_getfield(L, -1, "__metatable");
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), TITAN_ARRAY_METATABLE) == 0);
    lua_pop(L, 1);
    for (i = 0; i < sizeof(callbacks) / sizeof(callbacks[0]); i++) {
        lua_getfield(L, -1, callbacks[i]);
        assert(lua_iscfunction(L, -1));
        lua_pop(L, 1);
    }
    lua_pop(L, 1);

    assert(lua_getfield(
        L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE) == LUA_TTABLE);
    value = lua_totvalue(L, -1);
    assert(ttistable(&value));
    assert(hvalue(&value) == const_metatable);
    lua_getfield(L, -1, "__name");
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), TITAN_CONST_ARRAY_METATABLE) == 0);
    lua_pop(L, 1);
    lua_getfield(L, -1, "__metatable");
    assert(lua_type(L, -1) == LUA_TSTRING);
    assert(strcmp(lua_tostring(L, -1), TITAN_CONST_ARRAY_METATABLE) == 0);
    lua_pop(L, 1);
    lua_getfield(L, -1, "__index");
    assert(lua_iscfunction(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, -1, "__newindex");
    assert(lua_isnil(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, -1, "__len");
    assert(lua_iscfunction(L, -1));
    lua_pop(L, 2);

    assert(titan_array_metatable(L) == metatable);
    assert(titan_const_array_metatable(L) == const_metatable);
    lua_close(L);
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

    for (i = 0; i < sizeof(exact_capacities) /
                          sizeof(exact_capacities[0]); i++) {
        int top = lua_gettop(L);
        Udata *proxy;
        Table *backing = new_rooted_array(
            L, metatable, exact_capacities[i], &proxy);
        assert_shape(backing, proxy, metatable, exact_capacities[i] + 1, 0);
        lua_settop(L, top);
        lua_gc(L, LUA_GCCOLLECT);
    }

    {
        Udata *proxy;
        Table *backing = new_rooted_array(L, metatable, 3, &proxy);
        set_integer(L, backing, 1, 11);
        set_integer(L, backing, 3, 33);
        assert_shape(backing, proxy, metatable, 4, 3);

        /* Interior deletion keeps the highest-present-positive length. */
        set_nil(L, backing, 2);
        assert_shape(backing, proxy, metatable, 4, 3);
        assert_nil(backing, 2);

        /* A tail deletion backscans across the hole. */
        set_nil(L, backing, 3);
        assert_shape(backing, proxy, metatable, 4, 1);
        assert_integer(backing, 1, 11);

        /* Nil above capacity is an allocation-free no-op. */
        set_nil(L, backing, 100);
        assert_shape(backing, proxy, metatable, 4, 1);

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
    assert_shape(inner, inner_proxy, metatable, 2, 1);

    sethvalue(L, &value, map);
    assert(titan_array_try_backing(&value, metatable) == NULL);
    lua_newuserdatauv(L, 0, 1);
    value = lua_totvalue(L, -1);
    assert(titan_array_try_backing(&value, metatable) == NULL);
    lua_pop(L, 1);

    lua_close(L);
}

static void test_const_array_copy_freeze_and_nested_boxing(void) {
    lua_State *L = luaL_newstate();
    Table *mutable_metatable;
    Table *const_metatable;
    Table *source;
    Table *copy;
    Table *frozen;
    Table *inner_mutable;
    Table *inner_const;
    Table *outer_const;
    Table *impostor;
    Udata *source_proxy;
    Udata *copy_proxy;
    Udata *frozen_proxy;
    Udata *inner_mutable_proxy;
    Udata *inner_const_proxy;
    Udata *outer_const_proxy;
    Udata *impostor_proxy;
    TValue observed;

    assert(L != NULL);
    luaL_openlibs(L);
    titan_array_metatables(L, &mutable_metatable, &const_metatable);
    assert(mutable_metatable != const_metatable);
    assert(titan_array_metatable(L) == mutable_metatable);
    assert(titan_const_array_metatable(L) == const_metatable);

    lua_getfield(L, LUA_REGISTRYINDEX, TITAN_CONST_ARRAY_METATABLE);
    observed = lua_totvalue(L, -1);
    assert(ttistable(&observed));
    assert(hvalue(&observed) == const_metatable);
    lua_getfield(L, -1, "__newindex");
    assert(lua_isnil(L, -1));
    lua_pop(L, 2);

    inner_mutable = new_rooted_array(
        L, mutable_metatable, 1, &inner_mutable_proxy);
    set_integer(L, inner_mutable, 1, 71);
    source = new_rooted_array(L, mutable_metatable, 8, &source_proxy);
    set_integer(L, source, 1, 11);
    push_backing(L, inner_mutable);
    titan_array_set_stack(L, source, 2, -1);
    lua_pop(L, 1);
    set_integer(L, source, 4, 44);

    lua_pushnil(L);
    {
        int top = lua_gettop(L);
        copy = titan_array_shallow_copy(
            L, source, mutable_metatable, const_metatable, L->top.p - 1);
        assert(lua_gettop(L) == top);
    }
    copy_proxy = titan_array_require_proxy(copy);
    assert(copy != source);
    assert(source->asize == 9);
    assert_const_shape(copy, copy_proxy, const_metatable, 9, 4);
    assert(copy->asize == source->asize);
    assert_integer(copy, 1, 11);
    assert_nil(copy, 3);
    assert_integer(copy, 4, 44);
    set_integer(L, source, 1, 99);
    assert_integer(source, 1, 99);
    assert_integer(copy, 1, 11);
    assert(titan_array_try_proxy_either(
        source, mutable_metatable, const_metatable) == source_proxy);
    assert(titan_array_try_proxy_either(
        copy, mutable_metatable, const_metatable) == copy_proxy);

    push_proxy(L, source_proxy);
    lua_setglobal(L, "mutable_source");
    push_proxy(L, copy_proxy);
    lua_setglobal(L, "const_copy");
    run_chunk(L,
        "local ok = pcall(function() const_copy[1] = 22 end)\n"
        "assert(not ok)\n"
        "assert(getmetatable(const_copy) == "
            "'Titan const array metatable')\n"
        "assert(#const_copy == 4 and const_copy[3] == nil)\n"
        "assert(const_copy[1] == 11 and mutable_source[1] == 99)\n"
        "assert(const_copy[2] == mutable_source[2])\n");

    frozen = new_rooted_array(
        L, mutable_metatable, 2, &frozen_proxy);
    set_integer(L, frozen, 1, 81);
    push_proxy(L, frozen_proxy);
    lua_setglobal(L, "freeze_before");
    {
        int top = lua_gettop(L);
        assert(titan_array_freeze(
            L, frozen, mutable_metatable, const_metatable) == frozen);
        assert(lua_gettop(L) == top);
    }
    assert(titan_array_try_proxy(frozen, mutable_metatable) == NULL);
    assert_const_shape(frozen, frozen_proxy, const_metatable, 3, 1);
    push_proxy(L, frozen_proxy);
    lua_setglobal(L, "frozen");
    run_chunk(L,
        "assert(rawequal(freeze_before, frozen))\n"
        "local ok = pcall(function() frozen[1] = 82 end)\n"
        "assert(not ok)\n"
        "assert(frozen[1] == 81 and #frozen == 1)\n"
        "assert(getmetatable(frozen) == "
            "'Titan const array metatable')\n");

    inner_const = new_rooted_const_array(
        L, const_metatable, 1, &inner_const_proxy);
    set_integer(L, inner_const, 1, 91);
    outer_const = new_rooted_const_array(
        L, const_metatable, 2, &outer_const_proxy);
    push_backing(L, inner_mutable);
    titan_array_set_stack(L, outer_const, 1, -1);
    lua_pop(L, 1);
    push_backing(L, inner_const);
    titan_array_set_stack(L, outer_const, 2, -1);
    lua_pop(L, 1);
    assert_const_shape(
        inner_const, inner_const_proxy, const_metatable, 2, 1);
    assert_const_shape(
        outer_const, outer_const_proxy, const_metatable, 3, 2);
    push_proxy(L, outer_const_proxy);
    lua_setglobal(L, "outer_const");
    run_chunk(L,
        "assert(getmetatable(outer_const[1]) == "
            "'Titan array metatable')\n"
        "assert(getmetatable(outer_const[2]) == "
            "'Titan const array metatable')\n"
        "assert(outer_const[1][1] == 71)\n"
        "assert(outer_const[2][1] == 91)\n");

    /* Exact identity, not a structurally similar proxy, defines Array tags. */
    impostor = new_rooted_const_array(
        L, const_metatable, 0, &impostor_proxy);
    {
        int fake_index;
        int original_index;
        int set;
        sethvalue(L, &observed, const_metatable);
        lua_pushtvalue(L, observed);
        original_index = lua_gettop(L);
        lua_newtable(L);
        fake_index = lua_gettop(L);
        lua_pushliteral(L, TITAN_CONST_ARRAY_METATABLE);
        lua_setfield(L, fake_index, "__name");
        lua_pushliteral(L, TITAN_CONST_ARRAY_METATABLE);
        lua_setfield(L, fake_index, "__metatable");
        lua_getfield(L, original_index, "__index");
        lua_setfield(L, fake_index, "__index");
        lua_getfield(L, original_index, "__len");
        lua_setfield(L, fake_index, "__len");
        push_proxy(L, impostor_proxy);
        lua_pushvalue(L, fake_index);
        set = lua_setmetatable(L, -2);
        assert(set);
        lua_pop(L, 3);
    }
    assert(titan_array_try_proxy_either(
        impostor, mutable_metatable, const_metatable) == NULL);

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

static void test_lua_writer_dispatch(void) {
    lua_State *L = luaL_newstate();
    Table *metatable;
    Table *backing;
    Udata *proxy;
    TValue writer;
    TValue owner;
    TValue observed;
    TValue proxy_value;

    assert(L != NULL);
    luaL_openlibs(L);
    metatable = titan_array_metatable(L);
    make_weak_values(L);

    /*
    ** Keep the writer rooted only on the stack during construction. After the
    ** stack is cleared, the global proxy's uv[1] must retain both the closure
    ** and its captured module-like userdata.
    */
    push_coercing_integer_writer(L);
    writer = lua_totvalue(L, -1);
    owner = clCvalue(&writer)->upvalue[0];
    assert(ttisfulluserdata(&owner));
    weak_store(L, 1, &writer);
    weak_store(L, 2, &owner);

    lua_pushnil(L);
    {
        int top = lua_gettop(L);
        backing = titan_array_new(
            L, metatable, 0, &writer, L->top.p - 1);
        assert(lua_gettop(L) == top);
    }
    proxy = titan_array_require_proxy(backing);
    assert(ttisCclosure(&proxy->uv[1].uv));
    assert(clCvalue(&proxy->uv[1].uv) == clCvalue(&writer));
    push_proxy(L, proxy);
    lua_setglobal(L, "coercing");
    lua_settop(L, 0);

    collect(L);
    observed = weak_get(L, 1);
    assert(ttisCclosure(&observed));
    assert(clCvalue(&observed) == clCvalue(&proxy->uv[1].uv));
    observed = weak_get(L, 2);
    assert(ttisfulluserdata(&observed));

    coercing_writer_calls = 0;
    run_chunk(L,
        "local function fails_with(f, text)\n"
        "  local ok, err = pcall(f)\n"
        "  assert(not ok)\n"
        "  assert(tostring(err):find(text, 1, true), tostring(err))\n"
        "end\n"
        "assert(#coercing == 0)\n"
        "coercing[1] = 2.0\n"
        "assert(coercing[1] == 2)\n"
        "assert(math.type(coercing[1]) == 'integer')\n"
        "fails_with(function() coercing[100] = 'bad' end,\n"
        "           'writer rejected value')\n"
        "assert(#coercing == 1 and coercing[1] == 2)\n"
        "for _, key in ipairs({0, -1, math.mininteger}) do\n"
        "  fails_with(function() coercing[key] = 3 end,\n"
        "             'Titan array index must be positive')\n"
        "end\n"
        "fails_with(function() coercing[1.5] = 3 end,\n"
        "           'Titan array index must be an integer')\n"
        "fails_with(function() coercing[math.maxinteger] = 3 end,\n"
        "           'array index too large')\n");
    assert(coercing_writer_calls == 2);
    assert_shape(backing, proxy, metatable, 2, 1);
    assert_integer(backing, 1, 2);
    assert_nil(backing, 100);

    push_proxy(L, proxy);
    proxy_value = lua_totvalue(L, -1);
    assert(titan_array_try_backing(&proxy_value, metatable) == backing);
    lua_pop(L, 1);

    /*
    ** Nil deletion bypasses the writer. A nil far beyond capacity remains an
    ** allocation-free no-op.
    */
    run_chunk(L,
        "coercing[1] = nil\n"
        "coercing[math.maxinteger] = nil\n"
        "assert(#coercing == 0 and coercing[1] == nil)\n");
    assert(coercing_writer_calls == 2);
    assert_shape(backing, proxy, metatable, 2, 0);

    /*
    ** Once the proxy root is gone, the backing/proxy/writer/owner graph is an
    ** ordinary unreachable cycle and must collect.
    */
    lua_pushnil(L);
    lua_setglobal(L, "coercing");
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));
    observed = weak_get(L, 2);
    assert(ttisnil(&observed));
    registry_clear(L, &weak_root_key);
    lua_close(L);
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
    TValue writer_value;
    TValue owner_value;
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
    writer_value = proxy->uv[1].uv;
    owner_value = clCvalue(&writer_value)->upvalue[0];
    assert(ttisfulluserdata(&owner_value));
    weak_store(L, 1, &backing_value);
    weak_store(L, 2, &writer_value);
    weak_store(L, 3, &owner_value);
    registry_store(L, &proxy_root_key, &proxy_value);
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttistable(&observed));
    assert(hvalue(&observed) == backing);
    assert(titan_array_try_proxy(hvalue(&observed), metatable) == proxy);
    observed = weak_get(L, 2);
    assert(ttisCclosure(&observed));
    assert(clCvalue(&observed) == clCvalue(&writer_value));
    observed = weak_get(L, 3);
    assert(ttisfulluserdata(&observed));
    assert(uvalue(&observed) == uvalue(&owner_value));
    registry_clear(L, &proxy_root_key);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));
    observed = weak_get(L, 2);
    assert(ttisnil(&observed));
    observed = weak_get(L, 3);
    assert(ttisnil(&observed));

    /* An otherwise-unreachable two-object cycle is collected normally. */
    make_weak_values(L);
    backing = new_rooted_array(L, metatable, 0, &proxy);
    sethvalue(L, &backing_value, backing);
    setuvalue(L, &proxy_value, proxy);
    writer_value = proxy->uv[1].uv;
    owner_value = clCvalue(&writer_value)->upvalue[0];
    weak_store(L, 1, &backing_value);
    weak_store(L, 2, &proxy_value);
    weak_store(L, 3, &writer_value);
    weak_store(L, 4, &owner_value);
    lua_settop(L, 0);
    collect(L);
    observed = weak_get(L, 1);
    assert(ttisnil(&observed));
    observed = weak_get(L, 2);
    assert(ttisnil(&observed));
    observed = weak_get(L, 3);
    assert(ttisnil(&observed));
    observed = weak_get(L, 4);
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
    Table *first_const_metatable;
    Table *second_metatable;
    Table *second_const_metatable;
    assert(first != NULL && second != NULL);
    titan_array_metatables(
        first, &first_metatable, &first_const_metatable);
    titan_array_metatables(
        second, &second_metatable, &second_const_metatable);
    assert(first_metatable != second_metatable);
    assert(first_const_metatable != second_const_metatable);
    assert(first_metatable != first_const_metatable);
    assert(second_metatable != second_const_metatable);
    assert(first_metatable == titan_array_metatable(first));
    assert(first_const_metatable == titan_const_array_metatable(first));
    assert(second_metatable == titan_array_metatable(second));
    assert(second_const_metatable == titan_const_array_metatable(second));
    lua_close(first);
    lua_close(second);
}

static void test_function_type_tag_publication(void) {
    static const char *first_key = "Titan function type unit.first tag";
    static const char *second_key = "Titan function type unit.second tag";
    static const char *first_tag_candidate = "Function({},{},false,nil,nil)";
    static const char *first_tag_candidate_dup = "Function({},{},false,nil,nil)";
    static const char *second_tag_candidate = "Function({Integer()},{Integer()},false,nil,nil)";
    lua_State *first = luaL_newstate();
    lua_State *second = luaL_newstate();
    const void *first_tag;
    const void *recovered_tag;
    const void *other_tag;
    int top;

    assert(first != NULL && second != NULL);

    top = lua_gettop(first);
    first_tag = titan_publish_function_type_tag(
        first, first_key, first_tag_candidate);
    assert(first_tag == first_tag_candidate);
    assert(lua_gettop(first) == top);

    /*
    ** A second provider for the same structural function type recovers the
    ** first provider's canonical pointer.
    */
    recovered_tag = titan_publish_function_type_tag(
        first, first_key, first_tag_candidate_dup);
    assert(recovered_tag == first_tag);
    assert(lua_gettop(first) == top);

    other_tag = titan_publish_function_type_tag(
        first, second_key, second_tag_candidate);
    assert(other_tag == second_tag_candidate);
    assert(lua_gettop(first) == top);

    /*
    ** Registry ownership is per Lua state. The same key elects this state's
    ** first candidate independently.
    */
    top = lua_gettop(second);
    recovered_tag = titan_publish_function_type_tag(
        second, first_key, first_tag_candidate_dup);
    assert(recovered_tag == first_tag_candidate_dup);
    assert(lua_gettop(second) == top);

    lua_close(first);
    lua_close(second);
}

int main(void) {
#ifdef TITAN_RUNTIME_VISIBILITY_PROBE
    test_runtime_visibility();
#endif
    test_array_metatable_publication();
    test_array_metatable_allocation_retry();
    test_capacity_length_and_hash();
    test_lua_callbacks_and_boxing();
    test_const_array_copy_freeze_and_nested_boxing();
#ifndef TITAN_ARRAY_HARDMEM_PROBE
    test_lua_writer_dispatch();
    test_gc_mode(LUA_GCINC);
    test_gc_mode(LUA_GCGEN);
    test_per_state_metatables();
    test_function_type_tag_publication();
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

local function compile_and_run(hard_memory, expose_lua_internals)
    local root = make_temp_dir()
    local source = root .. "/dense_array_runtime.c"
    local executable = root .. "/dense_array_runtime"
    local platform = host_os()
    write_file(source, HARNESS)

    local argv = assert(cdriver.split_shell_words(os.getenv("CC") or "cc"))
    for _, word in ipairs({
        "--std=c99", "-O0", "-fno-lto", "-g",
        "-Wall", "-Wextra", "-fno-optimize-sibling-calls",
        "-I.", "-Ititan-runtime", "-Ilua-5.5.1/src", "-Ilibbacktrace",
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
    if expose_lua_internals then
        local header = root .. "/lua_exports.h"
        write_file(header, [[
#define LUAI_FUNC __attribute__((visibility("default"))) extern
#define LUAI_DDEC(dec) LUAI_FUNC dec
#define LUAI_DDEF
]])
        argv[#argv + 1] = "-include"
        argv[#argv + 1] = header
        argv[#argv + 1] = "-DTITAN_RUNTIME_VISIBILITY_PROBE"
        argv[#argv + 1] = platform == "Darwin"
            and "-Wl,-export_dynamic" or "-Wl,--export-dynamic"
    end
    append_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS"),
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = source
    argv[#argv + 1] = "titan-runtime/titan.c"
    if hard_memory then
        for _, stem in ipairs(LUA_SOURCES) do
            argv[#argv + 1] = "lua-5.5.1/src/" .. stem .. ".c"
        end
    else
        argv[#argv + 1] = "lua-5.5.1/src/liblua.a"
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
    it("keeps compiler-internal construction helpers off the Lua stack",
        function()
            local runtime = read_file("titan-runtime/titan.c")
            local header = read_file("titan-runtime/titan.h")
            local source = runtime .. "\n" .. header
            for _, name in ipairs({
                "titan_array_try_proxy_either",
                "titan_const_array_metatable",
                "titan_const_array_new",
            }) do
                assert.matches("static%s+l_inline%s+[^\n]-" .. name ..
                    "%s*%b()%s*%b{}", header)
                assert.is_nil(runtime:match(
                        "%f[%w_]" .. name .. "%f[^%w_]%s*%b()%s*%b{}"),
                    name .. " must stay in the installed inline header")
            end
            for _, name in ipairs({
                "titan_array_new_impl",
                "titan_array_new",
                "titan_const_array_new",
                "titan_array_shallow_copy",
                "titan_array_freeze",
            }) do
                local body = c_function_body(source, name)
                local without_asserts = body:gsub("lua_assert%s*%b()", "")
                assert.is_nil(without_asserts:match(
                        "%f[%w_]lua_[%w_]*%s*%("),
                    name .. " calls the public Lua stack API")
                assert.is_nil(body:match("%f[%w_]luaL_[%w_]*%s*%("),
                    name .. " raises a public auxiliary-library error")
                assert.is_nil(body:match("L%s*%-%>%s*top"),
                    name .. " changes the Lua stack directly")
            end
        end)

    it("preserves capacity, length, proxy, callback, and GC invariants",
        function()
            compile_and_run(false)
        end)

    it("keeps both construction objects rooted under HARDMEMTESTS",
        function()
            compile_and_run(true)
        end)

    it("keeps embedded runtime helpers private when Lua internals are exposed",
        function()
            compile_and_run(false, true)
        end)
end)

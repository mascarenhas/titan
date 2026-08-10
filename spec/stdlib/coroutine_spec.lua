local assert = require 'luassert'
local lfs = require 'lfs'
local coder = require 'titan-compiler.coder'

local ROOT_ARTIFACTS = {
    "titan-runtime/libtitan.a",
    "titan-runtime/.titan-runtime-archive-build-config",
    "titan.so",
    "titan.so.dSYM",
    "titan/coroutine.a",
    "titan/coroutine.so",
    "titan/coroutine.so.dSYM",
    "titan/coroutine.lua",
    "titan/coroutine.c",
    "titan/coroutine.o",
}
local artifact_backup

local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function prefix_from_cpath(cpath)
    for template in (cpath .. ";"):gmatch("(.-);") do
        local root = template:match("^(.*)/lib/lua/5%.5/%?%.so$")
        if root then return root end
    end
end

local PREFIX = (os.getenv("PREFIX") or prefix_from_cpath(package.cpath) or "")
    :gsub("/+$", "")
assert.equal("/", PREFIX:sub(1, 1),
    "coroutine specs require an absolute standalone Titan PREFIX")

local LUA = PREFIX .. "/bin/lua"
assert(file_exists(LUA), "No Lua found")

local TITANC = LUA ..
    [[ -e 'package.path="./?.lua;./?/init.lua;" .. package.path' ./titanc]]
local COROUTINE_VARIANT_ROOT = os.tmpname() .. "-titan-coroutine-exact"
os.remove(COROUTINE_VARIANT_ROOT)
local COROUTINE_VARIANT_SO =
    COROUTINE_VARIANT_ROOT .. "/titan/coroutine.so"
local COROUTINE_VARIANT_SOURCE_ROOT =
    COROUTINE_VARIANT_ROOT .. "/source"
local COROUTINE_VARIANT_SOURCE =
    COROUTINE_VARIANT_SOURCE_ROOT .. "/titan/coroutine.titan"
local COROUTINE_VARIANT_C =
    COROUTINE_VARIANT_SOURCE_ROOT .. "/titan/coroutine.c"
local CHECKSTACK_VARIANT_ROOT =
    os.tmpname() .. "-titan-coroutine-checkstack"
os.remove(CHECKSTACK_VARIANT_ROOT)
local CHECKSTACK_VARIANT_SO =
    CHECKSTACK_VARIANT_ROOT .. "/titan/coroutine.so"
local CHECKSTACK_VARIANT_SOURCE_ROOT =
    CHECKSTACK_VARIANT_ROOT .. "/source"
local CHECKSTACK_VARIANT_SOURCE =
    CHECKSTACK_VARIANT_SOURCE_ROOT .. "/titan/coroutine.titan"
local WRAPPER_FIXTURE_SO = COROUTINE_VARIANT_ROOT .. "/test.so"
local WRAPPER_FIXTURE_SHIM = COROUTINE_VARIANT_ROOT .. "/test.lua"
local CHECKSTACK_FIXTURE = lfs.currentdir() ..
    "/spec/fixtures/stdlib/native/coroutine_transfer_fault.h"
local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end
local function test_env(root, so)
    return "env -u LUA_PATH -u LUA_CPATH " ..
        "-u LUA_PATH_5_5 -u LUA_CPATH_5_5 CCACHE_DISABLE=1 PREFIX=" .. quote(PREFIX) ..
        " TITAN_PATH=" .. quote(root) .. " " ..
        "LUA_PATH=" .. quote(root .. "/?.lua;./?.lua;;") ..
        " LUA_CPATH=" .. quote(root .. "/?.so;./?.so;;") .. " " ..
        "TITAN_COROUTINE_TEST_SO=" .. quote(so) .. " "
end
local TEST_ENV = test_env(COROUTINE_VARIANT_ROOT, COROUTINE_VARIANT_SO)
local CHECKSTACK_TEST_ENV =
    test_env(CHECKSTACK_VARIANT_ROOT, CHECKSTACK_VARIANT_SO)

local function clean_test_artifacts()
    os.execute("rm -rf test.o test.so test.a test.c test.titan " ..
        "test.lua test.so.dSYM " ..
        "coroutine_standalone app app__entrypoint.c app__entrypoint.o " ..
        "app.dSYM")
end

local function exec_ok(cmd)
    local ok, _, code = os.execute(cmd)
    return ok == true or ok == 0 or code == 0
end

local function preserve_root_artifacts()
    assert.is_nil(artifact_backup)
    local directory = os.tmpname() .. "-titan-coroutine-artifacts"
    os.remove(directory)
    assert.truthy(lfs.mkdir(directory))
    local entries = {}
    for index, path in ipairs(ROOT_ARTIFACTS) do
        local attributes = lfs.symlinkattributes(path)
        local entry = { path = path, mode = attributes and attributes.mode }
        if entry.mode == "link" then
            local pipe = assert(io.popen("readlink " .. path))
            entry.target = assert(pipe:read("*l"))
            assert.truthy(pipe:close())
        elseif entry.mode then
            entry.backup = directory .. "/" .. index
            local cp = entry.mode == "directory" and "cp -Rp " or "cp -p "
            assert.truthy(exec_ok(cp .. path .. " " .. entry.backup))
        end
        entries[#entries + 1] = entry
    end
    artifact_backup = { directory = directory, entries = entries }
end

local function restore_root_artifacts()
    local backup = assert(artifact_backup)
    for _, entry in ipairs(backup.entries) do
        if entry.mode == "directory" or
            lfs.symlinkattributes(entry.path, "mode") == "directory" then
            assert.truthy(exec_ok("rm -rf " .. entry.path))
        else
            os.remove(entry.path)
        end
        if entry.mode == "link" then
            assert.truthy(exec_ok(
                "ln -s " .. entry.target .. " " .. entry.path))
        elseif entry.mode == "directory" then
            assert.truthy(exec_ok(
                "cp -Rp " .. entry.backup .. " " .. entry.path))
        elseif entry.mode then
            assert.truthy(exec_ok(
                "cp -p " .. entry.backup .. " " .. entry.path))
        end
    end
    assert.truthy(exec_ok("rm -rf " .. backup.directory))
    artifact_backup = nil
end

local function write_file(path, contents)
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local contents = f:read("*a")
    f:close()
    return contents
end

local function replace_once(source, old, new)
    local first, last = source:find(old, 1, true)
    assert.truthy(first, "missing coroutine variant anchor: " .. old)
    assert.is_nil(source:find(old, last + 1, true),
        "ambiguous coroutine variant anchor: " .. old)
    return source:sub(1, first - 1) .. new .. source:sub(last + 1)
end

local function matching_c_brace(source, opening)
    assert.equal("{", source:sub(opening, opening))
    local depth = 0
    for position = opening, #source do
        local byte = source:sub(position, position)
        if byte == "{" then
            depth = depth + 1
        elseif byte == "}" then
            depth = depth - 1
            if depth == 0 then return position end
        end
    end
    error("unmatched generated-C brace at byte " .. opening, 0)
end

local function coroutine_native_name(name)
    return coder._source_private_prefix("titan.coroutine", name) .. "_titan"
end

local function generated_function_body(generated, signature)
    -- Checked numeric conversions can close an inner guard at column zero, so
    -- a textual "\n}\n" is not a reliable end-of-function delimiter.
    local prototype = assert(generated:find(signature, 1, true))
    local function_start = assert(generated:find(
        signature, prototype + #signature, true))
    local opening = assert(generated:find("{", function_start, true))
    local closing = matching_c_brace(generated, opening)
    return generated:sub(function_start, closing)
end

local function compile_coroutine_variant(root, source_root, source_path,
                                         so_path, source, env)
    assert.truthy(exec_ok("rm -rf " .. quote(root)))
    assert.truthy(exec_ok(
        "mkdir -p " .. quote(root .. "/titan") .. " " ..
        quote(source_root .. "/titan")))
    write_file(source_path, source)
    os.remove("titan/coroutine.a")
    os.remove("titan/coroutine.so")
    assert.truthy(exec_ok("rm -rf titan/coroutine.so.dSYM"))
    assert.truthy(exec_ok(
        env .. "TITAN_PATH= " .. TITANC .. " --tree " ..
        quote(source_root) .. " titan.coroutine"))
    assert.truthy(exec_ok("cp -p " .. quote("titan/coroutine.so") .. " " ..
        quote(so_path)))
    os.remove("titan/coroutine.a")
    os.remove("titan/coroutine.so")
    assert.truthy(exec_ok("cp -p " .. quote("titan/coroutine.lua") .. " " ..
        quote(root .. "/titan/coroutine.lua")))
    os.remove("titan/coroutine.lua")
    if lfs.attributes("titan/coroutine.so.dSYM", "mode") == "directory" then
        assert.truthy(exec_ok("cp -Rp " .. quote("titan/coroutine.so.dSYM") ..
            " " .. quote(so_path .. ".dSYM")))
        assert.truthy(exec_ok("rm -rf titan/coroutine.so.dSYM"))
    end
end

local function build_coroutine()
    -- This is deliberately the sole stdlib source-rewrite exception. Public
    -- behavior cannot place GC inside the native resume-to-transfer-root
    -- window, so an isolated exact provider inserts that one deterministic
    -- probe. Keep every anchor unique and keep the production provider intact.
    local source = read_file("titan/coroutine.titan")
    source = replace_once(source,
        "local runtime = mco.mco_runtime.new()\n",
        "local runtime = mco.mco_runtime.new()\n" ..
        "local transfer_gc_mode: integer = 0\n")
    local anchor = "  local result = mco.mco_resume(co, ctag)\n"
    source = replace_once(source, anchor,
        anchor ..
        "  if transfer_gc_mode == 1 then\n" ..
        "    lua.lua_gc(L, lua.LUA_GCCOLLECT)\n" ..
        "  elseif transfer_gc_mode == 2 then\n" ..
        "    lua.lua_gc(L, lua.LUA_GCSTEP, 0 as lua.lua_Integer)\n" ..
        "  end\n")
    local exports = [[

function _test_set_transfer_gc_mode(mode: integer)
  transfer_gc_mode = mode
end
]]
    local initializer = '\ndo\n  lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "titan.coroutine")'
    source = replace_once(source, initializer, exports .. initializer)
    compile_coroutine_variant(
        COROUTINE_VARIANT_ROOT,
        COROUTINE_VARIANT_SOURCE_ROOT,
        COROUTINE_VARIANT_SOURCE,
        COROUTINE_VARIANT_SO,
        source,
        TEST_ENV)
end

local function build_checkstack_coroutine()
    -- The same narrow exception applies here: the production boundary offers
    -- no way to force lua_checkstack to fail after saving the exact stack top.
    -- The isolated provider redirects only those Lua operations to a native
    -- fixture; it is not a general source-transform testing pattern.
    local source = read_file("titan/coroutine.titan")
    source = replace_once(source,
        'local coro_native = foreign import "titan/coro.h"\n',
        'local coro_native = foreign import "titan/coro.h"\n' ..
        'local coro_test = foreign import "' ..
        CHECKSTACK_FIXTURE .. '"\n')
    source = replace_once(source,
        "lua.lua_checkstack(L, 2)",
        "coro_test.titan_coro_test_lua_checkstack(L, 2)")
    source = replace_once(source,
        "ffi.lua_pushtvalue(L, owner)",
        "coro_test.titan_coro_test_lua_pushtvalue(L, owner)")
    source = replace_once(source,
        "ffi.lua_pushtvalue(L, payload)",
        "coro_test.titan_coro_test_lua_pushtvalue(L, payload)")

    local helper_start = assert(source:find(
        "local function root_transfer", 1, true))
    local helper_end = assert(source:find(
        "\nend\n\nlocal function clear_transfer", helper_start, true))
    local helper = source:sub(helper_start, helper_end + 4)
    local top_replacements
    helper, top_replacements = helper:gsub(
        "lua%.lua_settop%(L, top%)",
        "coro_test.titan_coro_test_lua_settop(L, top)")
    assert.same(1, top_replacements,
        "transfer-root helper must restore the top on both failures and success")
    source = source:sub(1, helper_start - 1) .. helper ..
        source:sub(helper_end + 5)

    local exports = [[

function _test_arm_checkstack_failure()
  coro_test.titan_coro_test_arm_checkstack_failure()
end

function _test_checkstack_failure_ok(): boolean
  return (coro_test.titan_coro_test_checkstack_failure_ok() as integer) ~= 0
end
]]
    local initializer = '\ndo\n  lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "titan.coroutine")'
    source = replace_once(source, initializer, exports .. initializer)
    compile_coroutine_variant(
        CHECKSTACK_VARIANT_ROOT,
        CHECKSTACK_VARIANT_SOURCE_ROOT,
        CHECKSTACK_VARIANT_SOURCE,
        CHECKSTACK_VARIANT_SO,
        source,
        CHECKSTACK_TEST_ENV)
end

local WRAPPER_FIXTURE = [=[
local coroutine = import "coroutine"

function canonical_body(arg: value): value
    return arg
end

function canonical_make(): coroutine.Coro
    return coroutine.create(canonical_body, "tag")
end
]=]

local wrapper_fixture_built = false

local function build_wrapper_fixture()
    if wrapper_fixture_built then return end

    clean_test_artifacts()
    write_file("test.titan", WRAPPER_FIXTURE)
    assert.truthy(exec_ok(TEST_ENV .. TITANC .. " test"))
    assert.truthy(exec_ok("cp -p test.so " .. quote(WRAPPER_FIXTURE_SO)))
    assert.truthy(exec_ok("cp -p test.lua " .. quote(WRAPPER_FIXTURE_SHIM)))

    if lfs.attributes("test.so.dSYM", "mode") == "directory" then
        local destination = WRAPPER_FIXTURE_SO .. ".dSYM"
        assert.truthy(exec_ok("rm -rf " .. quote(destination)))
        assert.truthy(exec_ok(
            "cp -Rp test.so.dSYM " .. quote(destination)))
    end

    wrapper_fixture_built = true
end

local function clean_coroutine_artifacts()
    os.remove("titan/coroutine.a")
    os.remove("titan/coroutine.so")
    exec_ok("rm -rf titan/coroutine.so.dSYM")
    os.remove("titan/coroutine.lua")
    os.remove("titan/coroutine.c")
    os.remove("titan/coroutine.o")
    exec_ok("rm -rf " .. quote(COROUTINE_VARIANT_ROOT))
    exec_ok("rm -rf " .. quote(CHECKSTACK_VARIANT_ROOT))
    wrapper_fixture_built = false
end

local function run_wrapper(lua_code, preload)
    build_wrapper_fixture()
    local script = os.tmpname()
    write_file(script, lua_code)
    local load = preload == false and "" or "-l test "
    local f = assert(io.popen(
        TEST_ENV .. LUA .. " " .. load .. script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function run_lua_in_env(lua_code, env)
    local script = os.tmpname()
    write_file(script, lua_code)
    local f = assert(io.popen(env .. LUA .. " " .. script .. " 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    os.remove(script)
    assert.truthy(ok, "lua failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

local function run_lua(lua_code)
    return run_lua_in_env(lua_code, TEST_ENV)
end

local function compile_and_run_standalone_import()
    clean_test_artifacts()
    assert.truthy(exec_ok("mkdir -p coroutine_standalone"))
    write_file("coroutine_standalone/app.titan", [[
        local coroutine = import "coroutine"

        function body(arg: value): value
            return arg
        end

        function main(args: {string}): integer
            local co = coroutine.create(body, "tag")
            if co:resume("ok") == "ok" then
                return 0
            end
            return 1
        end
    ]])
    assert.truthy(exec_ok(TEST_ENV .. TITANC ..
        " --tree coroutine_standalone app"))

    local f = assert(io.popen(TEST_ENV .. "./app 2>&1"))
    local out = f:read("*a")
    local ok, why, status = f:close()
    assert.truthy(ok, "program failed (" .. tostring(why) .. ", " ..
        tostring(status) .. ")\n" .. out)
    return out
end

describe("coroutine standard module", function()
    setup(function()
        preserve_root_artifacts()
        -- This suite deliberately exercises an exact child image. Hide the
        -- production shallow container from the suite's Titan path by putting
        -- the temporary exact DSO/shim in a private root. The production
        -- titan.so stays on Lua's C path only to provide bare support APIs.
        build_coroutine()
    end)

    after_each(clean_test_artifacts)
    teardown(function()
        clean_coroutine_artifacts()
        restore_root_artifacts()
    end)

    it("keeps minicoro runtime state in GC-owned module-local storage", function()
        local generated = read_file(COROUTINE_VARIANT_C)
        assert.match("sizeof%(mco_runtime%)", generated)
        assert.match("getudatamem.-current_co", generated)
        assert.not_match("titan_coro_configure", generated, 1, true)
        assert.not_match("titan_coro_running", generated, 1, true)
        assert.not_match("Titan coroutine runtime 0.11", generated, 1, true)
        assert.not_match("lua_getupvalue", generated, 1, true)

        local create = generated_function_body(
            generated, "Udata* titan_coroutine_create_titan(")
        local owner_count = assert(create:find(
            "ivalue%(&_mod%->uv%[%d+%]%.uv%)"))
        local count_check = assert(create:find(
            "numeric value is outside the range of %s", owner_count, true))
        local owner_create = assert(create:find(
            "lua_newuserdatauv(", count_check, true))
        assert.is_true(owner_count < count_check)
        assert.is_true(count_check < owner_create)

        local native = read_file("titan-runtime/titan_coro.c")
        assert.not_match("titan_coro_runtime", native, 1, true)
        assert.not_match("titan_coro_configure", native, 1, true)
        assert.not_match("titan_coro_running", native, 1, true)
        assert.not_match("titan_coro_root_transfer", generated, 1, true)
        assert.not_match("titan_coro_clear_transfer", generated, 1, true)
        assert.not_match("titan_coro_root_transfer", native, 1, true)
        assert.not_match("titan_coro_clear_transfer", native, 1, true)

        local header = read_file("titan-runtime/titan/coro.h")
        local source = read_file("titan/coroutine.titan")
        assert.match("local TITAN_CORO_OWNER_USERVALUES = 5",
            source, 1, true)
        assert.not_match("TITAN_CORO_OWNER_USERVALUES", header, 1, true)
        assert.not_match("TITAN_CORO_ENTRY_FUNCTION", header, 1, true)
        assert.match("struct mco_coro;", header, 1, true)
        assert.match("void titan_coro_entry(struct mco_coro *co);",
            header, 1, true)
        assert.not_match("typedef struct mco_coro", header, 1, true)
        assert.not_match("titan_coro_root_transfer", header, 1, true)
        assert.not_match("titan_coro_clear_transfer", header, 1, true)
    end)

    it("roots transfers through checked public Lua uservalue APIs", function()
        local generated = read_file(COROUTINE_VARIANT_C)
        local signature = "TITAN_SOURCE_LOCAL void " ..
            coroutine_native_name("root_transfer") .. "("
        local body = generated_function_body(generated, signature)

        local recover = assert(body:find("mco_get_user_data", 1, true))
        local owner = assert(body:find("Udata *_local_owner", recover, true))
        local anchor = assert(body:find(
            "setuvalue(L, s2v((restorestack", owner, true))
        local saved_top = assert(body:find("lua_gettop(L)", anchor, true))
        local count_check = assert(body:find(
            "numeric value is outside the range of %s", saved_top, true))
        local checkstack = assert(body:find(
            "lua_checkstack(L, ((int)(", count_check, true))
        local owner_push = assert(body:find(
            "lua_pushtvalue(L", checkstack, true))
        local payload_push = assert(body:find(
            "lua_pushtvalue(L", owner_push + 1, true))
        local setter = assert(body:find(
            "lua_setiuservalue(L", payload_push, true))
        local setter_check = assert(body:find("if(", setter, true))

        assert.is_true(recover < owner)
        assert.is_true(owner < anchor)
        assert.is_true(anchor < saved_top)
        assert.is_true(saved_top < count_check)
        assert.is_true(count_check < checkstack)
        assert.is_true(checkstack < owner_push)
        assert.is_true(owner_push < payload_push)
        assert.is_true(payload_push < setter)
        assert.is_true(setter < setter_check)

        local restores = {}
        local position = 1
        while true do
            local restore = body:find("lua_settop(L, _local_top", position,
                true)
            if not restore then
                break
            end
            restores[#restores + 1] = restore
            position = restore + 1
        end
        assert.same(1, #restores)
        assert.is_true(checkstack < restores[1])
        assert.is_true(owner_push < restores[1])
        assert.is_true(setter_check < restores[1])

        assert.not_match("ud->uv", body, 1, true)
        assert.not_match("luaC_barrierback", body, 1, true)
    end)

    it("restores the exact top and pushes nothing on checkstack failure",
        function()
            -- Build this second transformed provider only for the one fault-
            -- injection case that consumes it. Filtered sanitizer runs exercise
            -- the ordinary transfer-root variant without paying for this DSO.
            build_checkstack_coroutine()
            local out = run_lua_in_env([==[
            local coroutine = require "titan.coroutine"
            local co = coroutine.create(function(arg)
                return arg
            end, "tag")

            coroutine._test_arm_checkstack_failure()
            local ok, err = pcall(function()
                return co:resume("first")
            end)
            assert(not ok, "injected lua_checkstack failure did not raise")
            assert(tostring(err):find(
                "cannot reserve Lua stack for coroutine transfer root",
                1, true), tostring(err))
            assert(coroutine._test_checkstack_failure_ok(),
                   "failure path pushed or did not restore the saved top")
            assert(co:status() == "suspended")
            assert(co:resume("second") == "second")
            assert(co:status() == "dead")
            print("OK")
        ]==], CHECKSTACK_TEST_ENV)
            assert.match("OK", out)
        end)

    it("removes retired transfer helpers from runtime objects", function()
        local nm = os.getenv("NM") or "nm"
        for _, path in ipairs({
            "titan-runtime/titan_coro.o",
            "titan-runtime/libtitan.a",
        }) do
            local pipe = assert(io.popen(
                nm .. " -g " .. quote(path) .. " 2>&1"))
            local output = pipe:read("*a")
            assert.truthy(pipe:close(), output)
            assert.match("titan_coro_entry", output, 1, true)
            assert.match("titan_coro_tag_equal", output, 1, true)
            assert.not_match("titan_coro_root_transfer", output, 1, true)
            assert.not_match("titan_coro_clear_transfer", output, 1, true)
        end
    end)

    it("rejects a poisoned metatable entry without replacing it",
        function()
            local out = run_lua([==[
            local registry = debug.getregistry()
            registry["titan.coroutine"] = "poisoned"
            local ok, err = pcall(require, "titan.coroutine")
            assert(not ok)
            assert(tostring(err):find(
                "invalid Titan coroutine metatable registry entry", 1,
                true), tostring(err))
            assert(registry["titan.coroutine"] == "poisoned")
            print("OK")
        ]==])
            assert.match("OK", out)
        end)

    it("publishes a complete coroutine metatable and preserves its type name",
        function()
            local source = read_file(COROUTINE_VARIANT_SOURCE)
            local lookup = assert(source:find(
                'lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "titan.coroutine")',
                1, true))
            local construct = assert(source:find(
                "lua.lua_createtable(L, 0, 2)", lookup, true))
            local name = assert(source:find(
                'lua.lua_setfield(L, -2, "__name")', construct, true))
            local gc = assert(source:find(
                'lua.lua_setfield(L, -2, "__gc")', name, true))
            local publish = assert(source:find(
                'lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, "titan.coroutine")',
                name, true))
            assert.is_true(lookup < construct and construct < name)
            assert.is_true(name < gc and gc < publish)

            local out = run_lua([==[
            local coroutine = require "titan.coroutine"
            local metatable = debug.getregistry()["titan.coroutine"]
            assert(type(metatable) == "table")
            assert(metatable.__name == "titan.coroutine")
            print("OK")
        ]==])
            assert.match("OK", out)
        end)

    it("anchors a popped payload before clearing its transfer root", function()
        local generated = read_file(COROUTINE_VARIANT_C)
        local signature = "TITAN_SOURCE_LOCAL TValue " ..
            coroutine_native_name("pop_transfer_or_raise") .. "("
        local body = generated_function_body(generated, signature)
        local payload_pop = assert(body:find("mco_pop(_param_co", 1, true))
        payload_pop = assert(body:find("mco_pop(_param_co", payload_pop + 1,
            true))
        local anchor_refresh = assert(body:find("setobj2t", payload_pop,
            true))
        local root_clear = assert(body:find(
            coroutine_native_name("clear_transfer"),
            payload_pop, true))
        assert.is_true(payload_pop < anchor_refresh)
        assert.is_true(anchor_refresh < root_clear)
    end)

    it("shares the canonical module when Titan imports before Lua requires", function()
        local out = run_wrapper([==[
            local lua_coroutine = require "coroutine"
            local from_titan = test.canonical_make()
            local titan_coroutine = require "titan.coroutine"
            local from_lua = titan_coroutine.create(function(arg)
                return arg
            end, "tag")

            assert(type(titan_coroutine) == "userdata")
            assert(require "coroutine" == lua_coroutine)
            assert(package.loaded.coroutine == lua_coroutine)
            assert(debug.getmetatable(from_titan) ==
                   debug.getmetatable(from_lua))
            assert(debug.getregistry()["titan.coroutine"] ~= nil)
            assert(debug.getregistry()["titan.coro"] == nil)
            assert(debug.getregistry()["Titan coroutine runtime 0.11"] == nil)
            local open = assert(package.loadlib(assert(os.getenv(
                "TITAN_COROUTINE_TEST_SO")), "luaopen_titan_coroutine"))
            assert(open() == titan_coroutine)
            assert(package.loadlib(
                assert(os.getenv("TITAN_COROUTINE_TEST_SO")),
                "luaopen_coroutine") == nil)
            assert(package.loadlib(
                assert(os.getenv("TITAN_COROUTINE_TEST_SO")),
                "luaopen_coro") == nil)
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("shares the canonical module when Lua requires before Titan imports", function()
        local out = run_wrapper([==[
            local lua_coroutine = require "coroutine"
            local titan_coroutine = require "titan.coroutine"
            local from_lua = titan_coroutine.create(function(arg)
                return arg
            end, "tag")
            local test = require "test"
            local from_titan = test.canonical_make()

            assert(type(titan_coroutine) == "userdata")
            assert(require "coroutine" == lua_coroutine)
            assert(package.loaded.coroutine == lua_coroutine)
            assert(debug.getmetatable(from_titan) ==
                   debug.getmetatable(from_lua))
            local open = assert(package.loadlib(assert(os.getenv(
                "TITAN_COROUTINE_TEST_SO")), "luaopen_titan_coroutine"))
            assert(open() == titan_coroutine)
            print("OK")
        ]==], false)
        assert.match("OK", out)
    end)

    it("roots fresh terminal result and error transfers through pop-side GC", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local function exercise(mode, transfer_gc_mode)
                collectgarbage(mode)

                local finalized_result = 0
                local weak_result = setmetatable({}, { __mode = "v" })
                local returns_fresh = coroutine.create(function()
                    local value = setmetatable({
                        kind = mode .. "-result",
                    }, {
                        __gc = function()
                            finalized_result = finalized_result + 1
                        end,
                    })
                    weak_result[1] = value
                    return value
                end, "tag")
                if mode == "generational" then
                    -- Promote the owner before the coroutine creates its fresh
                    -- result so the injected minor collection needs the
                    -- uservalue setter's old-to-young back barrier.
                    collectgarbage("collect")
                end
                coroutine._test_set_transfer_gc_mode(transfer_gc_mode)
                local result = returns_fresh:resume(nil)
                assert(result == weak_result[1] and
                       result.kind == mode .. "-result",
                       mode .. " fresh terminal result was not preserved")
                result = nil
                for _ = 1, 4 do collectgarbage("collect") end
                assert(weak_result[1] == nil and finalized_result == 1,
                       mode .. " terminal result root was not cleared")

                local finalized_error = 0
                local weak_error = setmetatable({}, { __mode = "v" })
                local raises_fresh = coroutine.create(function()
                    local value = setmetatable({
                        kind = mode .. "-error",
                    }, {
                        __gc = function()
                            finalized_error = finalized_error + 1
                        end,
                    })
                    weak_error[1] = value
                    error(value)
                end, "tag")
                if mode == "generational" then
                    collectgarbage("collect")
                end
                coroutine._test_set_transfer_gc_mode(transfer_gc_mode)
                local ok, err = pcall(function()
                    return raises_fresh:resume(nil)
                end)
                assert(not ok, mode .. " fresh terminal error was not raised")
                assert(err == weak_error[1] and
                       err.kind == mode .. "-error",
                       mode .. " fresh terminal error was not preserved")
                err = nil
                for _ = 1, 4 do collectgarbage("collect") end
                assert(weak_error[1] == nil and finalized_error == 1,
                       mode .. " terminal error root was not cleared")
            end

            exercise("incremental", 1)
            exercise("generational", 2)
            coroutine._test_set_transfer_gc_mode(0)
            collectgarbage("incremental")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("rejects unmatched raw tags without calling __eq", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local calls = 0
            local mt = {
                __eq = function()
                    calls = calls + 1
                    return true
                end
            }
            local resume_tag = setmetatable({}, mt)
            local yield_tag = setmetatable({}, mt)
            local co = coroutine.create(function()
                return coroutine.yield("unmatched", yield_tag)
            end, resume_tag)

            local ok, err = pcall(function()
                co:resume(nil, resume_tag)
            end)
            assert(not ok, "raw-unequal tags should not match")
            assert(tostring(err):find("Invalid operation", 1, true),
                   tostring(err))
            assert(calls == 0, "__eq comparator was called")
            assert(co:status() == "dead")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("loads from Lua and roots value payloads and identity tags across GC", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"
            collectgarbage("generational")

            local tag = {}
            local payload
            local marker
            local co = coroutine.create(function(arg)
                assert(arg == payload)
                collectgarbage("step")
                local got = coroutine.yield(marker, tag)
                assert(got == payload)
                return marker(got)
            end, tag)

            collectgarbage("collect")
            payload = { answer = 41 }
            marker = function(x) return x.answer + 1 end
            assert(co:status() == "suspended")
            assert(co:resume(payload, tag) == marker)
            payload.extra = {}
            for _ = 1, 50 do collectgarbage("step") end
            assert(co:resume(payload, tag) == 42)
            assert(co:status() == "dead")

            local nco = coroutine.create(function(arg)
                local back = coroutine.yield("numeric", 1.0)
                return back
            end, 1)
            assert(nco:resume(nil, 1) == "numeric")
            assert(nco:resume("done", 1.0) == "done")

            collectgarbage("incremental")
            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("reports Lua call errors for bad coroutine API use", function()
        local out = run_lua([==[
            local coroutine = require "titan.coroutine"

            local function fails(fn, needle)
                local ok, err = pcall(fn)
                assert(not ok, "expected API call to fail")
                if needle then
                    assert(tostring(err):find(needle, 1, true),
                           tostring(err))
                end
            end

            local bad_callback = coroutine.create("not callable", "tag")
            fails(function()
                bad_callback:resume(nil)
            end)

            fails(function()
                coroutine.yield("payload")
            end, "must provide non-nil tag argument to coroutine.yield")

            fails(function()
                coroutine.yield("payload", "tag")
            end, "Invalid coroutine")

            print("OK")
        ]==])
        assert.match("OK", out)
    end)

    it("imports coroutine from a compiled module in a standalone executable", function()
        local out = compile_and_run_standalone_import()
        assert.same("", out)
    end)
end)

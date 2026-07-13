local lfs = require "lfs"
local cdriver = require "c-parser.cdriver"
local phase2 = require "spec.support.phase2"

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local function shell_quote(word)
    return "'" .. word:gsub("'", "'\\''") .. "'"
end

local function append_shell_words(argv, words, label)
    local parsed, err = cdriver.split_shell_words(words or "")
    assert.is_table(parsed, label .. ": " .. tostring(err))
    for _, word in ipairs(parsed) do argv[#argv + 1] = word end
end

local function compile_allocation_counter(workspace)
    local object = workspace .. "/titan_uv_test_allocation.o"
    local argv = {}
    append_shell_words(argv, os.getenv("CC") or "cc", "CC")
    argv[#argv + 1] = "-std=c99"
    argv[#argv + 1] = "-fPIC"
    argv[#argv + 1] = "-I" .. phase2.repo .. "/lua-5.5.0/src"
    argv[#argv + 1] = "-I" .. phase2.repo .. "/spec/fixtures/uv"
    append_shell_words(argv, os.getenv("TITAN_TEST_EXTRA_CFLAGS") or "",
        "TITAN_TEST_EXTRA_CFLAGS")
    argv[#argv + 1] = "-c"
    argv[#argv + 1] = phase2.repo ..
        "/spec/fixtures/uv/titan_uv_test_allocation.c"
    argv[#argv + 1] = "-o"
    argv[#argv + 1] = object
    for index, word in ipairs(argv) do argv[index] = shell_quote(word) end
    local ok, _, output = phase2.run(table.concat(argv, " "), workspace)
    assert.truthy(ok, output)
    return object
end

local function host_config()
    local pipe = assert(io.popen("uname -s"))
    local host = assert(pipe:read("*l"))
    assert.truthy(pipe:close())
    local cppflags = "-I" .. phase2.repo .. "/libuv-v1.52.1/include" ..
        " -I" .. phase2.repo .. "/spec/fixtures/uv"
    local ldflags = "-lpthread"
    if host == "Linux" then
        cppflags = cppflags .. " -D_GNU_SOURCE"
        ldflags = ldflags .. " -ldl -lrt"
    end
    return host, cppflags, ldflags
end

describe("uv native-owner fixture", function()
    local workspace
    local generated
    local consumer_generated
    local module_path
    local consumer_module_path

    setup(function()
        workspace = phase2.workspace("native-owner")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/native_owner_probe.titan",
            "native_owner_probe")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/native_owner_consumer.titan",
            "native_owner_consumer")
        local _, cppflags, ldflags = host_config()
        local runtime = workspace .. "/titan-runtime/libtitan.a"
        assert.truthy(lfs.attributes(runtime),
            "Phase 1 fixture requires make runtime's libtitan.a")
        local allocation_counter = compile_allocation_counter(workspace)
        ldflags = phase2.repo .. "/libuv-build/libuv.a " .. ldflags
        phase2.compile(workspace, "native_owner_probe", {
            cppflags = cppflags,
            cflags = "-fno-strict-aliasing " ..
                "-Dlua_newuserdatauv=titan_uv_test_newuserdatauv " ..
                "-DluaS_newudata=titan_uv_test_newudata",
            ldflags = ldflags,
            extra_objects = {
                allocation_counter,
            },
        })
        phase2.compile(workspace, "native_owner_consumer", {
            cppflags = cppflags,
            cflags = "-fno-strict-aliasing " ..
                "-Dlua_newuserdatauv=titan_uv_test_newuserdatauv " ..
                "-DluaS_newudata=titan_uv_test_newudata",
            ldflags = ldflags,
            extra_objects = {
                allocation_counter,
            },
        })
        generated = read_file(
            workspace .. "/src/native_owner_probe.c")
        consumer_generated = read_file(
            workspace .. "/src/native_owner_consumer.c")
        module_path = workspace .. "/native_owner_probe.so"
        consumer_module_path = workspace .. "/native_owner_consumer.so"
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    local function run_lua(code)
        local script = workspace .. "/native-owner-probe.lua"
        local file = assert(io.open(script, "wb"))
        file:write(code)
        file:close()
        return phase2.run(phase2.lua_command(workspace, script), workspace)
    end

    it("generates exact owner ABI and function-level native catches", function()
        local public_uv = assert(generated:find("#include <uv.h>", 1, true))
        local lua_header = assert(generated:find("#include <lua.h>", 1, true))
        local ffi_header = assert(generated:find(
            "#include <titan/ffi.h>", 1, true))
        local shim_header = assert(generated:find(
            "#include <titan/uv.h>", 1, true))
        assert.is_true(public_uv < lua_header)
        assert.is_true(lua_header < ffi_header)
        assert.is_true(ffi_header < shim_header)

        assert.match("native_owner_probe_timer_dispatch_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, Udata%* _param_owner, lua_Integer _param_event_kind, lua_Integer _param_result, size_t _param_size, titan_ffi_void_ptr _param_pointer%)",
            generated)
        assert.match("native_owner_probe_fs_dispatch_titan%(lua_State %*L, Udata %*_mod, CClosure %*_fn, Udata%* _param_owner, lua_Integer _param_event_kind, lua_Integer _param_result, size_t _param_size, titan_ffi_void_ptr _param_pointer%)",
            generated)

        local timer = phase2.c_function_definition(generated,
            "static void native_owner_probe_timer_dispatch_titan(",
            "static int native_owner_probe_timer_dispatch_titanentry_lua(")
        local fs = phase2.c_function_definition(generated,
            "static void native_owner_probe_fs_dispatch_titan(",
            "static int native_owner_probe_fs_dispatch_titanentry_lua(")
        local timer_setjmp = assert(timer:find("TITAN_SETJMP", 1, true))
        local timer_gc = assert(timer:find("luaC_checkGC", 1, true))
        assert.is_true(timer_setjmp < timer_gc)
        assert.match("uv_stop", timer, 1, true)
        local fs_setjmp = assert(fs:find("TITAN_SETJMP", 1, true))
        local fs_gc = assert(fs:find("luaC_checkGC", 1, true))
        assert.is_true(fs_setjmp < fs_gc)
        assert.match("uv_fs_req_cleanup", fs, 1, true)
        assert.match("uv_stop", fs, 1, true)

        assert.match("sizeof%(uv_loop_t%)", generated)
        assert.match("sizeof%(uv_timer_t%)", generated)
        assert.match("sizeof%(uv_fs_t%)", generated)
        assert.match("sizeof%(uv_buf_t%)", generated)
        assert.match("_Alignof%(uv_loop_t%)", generated)
        assert.match("_Alignof%(uv_timer_t%)", generated)
        assert.match("_Alignof%(uv_fs_t%)", generated)
        assert.match("lua_getupvalue%(L,.-1.-1", generated)

        local access = generated:match(
            "int native_owner_probe__timer_is_closing_titan%b()%s*{(.-)static int native_owner_probe__timer_is_closing_titanentry_lua")
        assert.truthy(access)
        assert.match("titan_uvshim_timer_is_closing", access, 1, true)
        assert.not_match("lua_newuserdatauv", access, 1, true)
        assert.not_match("titan_uv_test_newuserdatauv", access, 1, true)
        assert.not_match("lua_togco", access, 1, true)

        local cross_module_access = phase2.c_function_definition(
            consumer_generated,
            "static int native_owner_consumer_cross_module_timer_access_titan(",
            "static int native_owner_consumer_cross_module_timer_access_titanentry_lua(")
        assert.match("native_owner_probe__timer_is_closing_titan",
            cross_module_access, 1, true)
        assert.not_match("native_owner_probe__timer_is_closing_titanentry_lua",
            cross_module_access, 1, true)

        local shim = read_file("titan-runtime/titan_uv.c")
        assert.not_match("lua_pcall", shim, 1, true)
        assert.not_match("luaD_call", shim, 1, true)
        assert.match("dispatch%(L, M, NULL, owner, event_kind, result, size, pointer%)",
            shim)
    end)

    it("uses an isolated Lua entry and checks wrong owner identities", function()
        local host = host_config()
        local command = host == "Darwin" and
            ("nm -g " .. module_path) or ("nm -D " .. module_path)
        local ok, _, symbols = phase2.run(command, workspace)
        assert.truthy(ok, symbols)
        assert.match("luaopen_native_owner_probe", symbols, 1, true)
        assert.not_match("luaopen_titan_uv", symbols, 1, true)

        ok, _, symbols = run_lua([[
            local probe = require "native_owner_probe"
            assert(probe.uv_timer_t.new == nil)
            local good, err = pcall(probe._timer_is_closed, {})
            assert(not good)
            assert(tostring(err):find("uv_timer_t", 1, true))
            good, err = pcall(probe._timer_is_closed, probe)
            assert(not good)
            assert(tostring(err):find("uv_timer_t", 1, true))
            assert(type(probe.version()) == "string")
        ]])
        assert.truthy(ok, symbols)
    end)

    it("cleans timer, close, and filesystem callbacks after GC",
       function()
        local ok, _, output = run_lua([[
            local probe = require "native_owner_probe"
            local r = probe._phase1_probe(".", false, false, false, false)
            assert(r[1] == 5)
            assert(r[2] == 2 and r[3] == 2 and r[4] == 1)
            assert(r[5] == 0 and r[6] == 0)
            assert(r[7] == 1 and r[8] == 1 and r[19] == 1)
            assert(r[9] == 1)
            assert(r[10] == 0 and r[11] == 32)
            assert(r[12] == 1 and r[13] == 0)
            assert(r[20] == 1)
            for _ = 1, 4 do collectgarbage("collect") end
            assert(probe._phase1_owner_roots_released(),
                   "terminal callback owners or native storage stayed rooted")
        ]])
        assert.truthy(ok, output)
    end)

    it("roots owner graphs across incremental and generational GC without " ..
       "cross-module handle boxing", function()
        local host = host_config()
        local dependencies = host == "Darwin" and
            ("otool -L " .. consumer_module_path) or
            ("readelf -d " .. consumer_module_path)
        local linked, _, linked_output = phase2.run(dependencies, workspace)
        assert.truthy(linked, linked_output)
        assert.not_match("native_owner_probe", linked_output, 1, true)

        local ok, _, output = run_lua([[
            local consumer = require "native_owner_consumer"
            local r = consumer.gc_proof(".")
            assert(r[1],
                   "incremental cycle never observed both owners black")
            assert(r[2], "incremental owner-to-buffer barrier failed")
            assert(r[3], "Runtime maps did not retain the accepted owner graph")
            assert(r[4], "generational owner-to-buffer barrier failed")
            assert(r[5], "owner layout changed during GC proof")
            assert(r[6], "internal Titan userdata allocator was not intercepted")
            assert(r[7],
                   "cross-module typed-handle access allocated a userdata")
            assert(r[8] == 32 and r[9] == 32)
            assert(r[10] == 5)
            assert(r[11] == 2 and r[12] == 2 and r[13] == 1)
            assert(not r[14] and r[15] and r[16] == 0)
            assert(r[17], "terminal owner or buffer graph stayed rooted")
        ]])
        assert.truthy(ok, output)
    end)

    it("contains an observed Task failure and runs a later timer", function()
        local ok, _, output = run_lua([[
            local probe = require "native_owner_probe"
            local r = probe._phase1_probe(".", true, false, false, false)
            assert(r[1] == 5 and r[2] == 2)
            assert(r[5] == 1 and r[6] == 0)
            assert(r[14] == 1)
            assert(r[17] == "phase-1 observed task failure")
            assert(r[18]:find("in native_owner_probe.task_body", 1, true))
            assert(r[4] == 1 and r[7] == 1)
            assert(r[3] == 2 and r[8] == 1 and r[19] == 1)
            assert(r[9] == 1 and r[12] == 1)
        ]])
        assert.truthy(ok, output)
    end)

    it("turns Task-handler and dispatcher failures into Runtime fatal state",
       function()
        local ok, _, output = run_lua([[
            local probe = require "native_owner_probe"

            local handler = probe._phase1_probe(
                ".", true, true, false, false)
            assert(handler[6] == 1 and handler[5] == 0)
            assert(handler[15] == "phase-1 task error handler failure")
            assert(handler[16]:find(
                "in native_owner_probe.task_error_handler", 1, true))
            assert(handler[3] == 2 and handler[4] == 1)
            assert(handler[7] == 1 and handler[8] == 1 and handler[19] == 1)

            local injected = probe._phase1_probe(
                ".", false, false, true, false)
            assert(injected[6] == 1)
            assert(injected[15] == "phase-1 injected dispatcher failure")
            assert(injected[16]:find(
                "in native_owner_probe.timer_dispatch", 1, true))
            assert(injected[2] == 0)
            assert(injected[3] == 2 and injected[4] == 1)
            assert(injected[7] == 1 and injected[8] == 1 and
                   injected[19] == 1)

            local fs_injected = probe._phase1_probe(
                ".", false, false, false, true)
            assert(fs_injected[6] == 1)
            assert(fs_injected[15] ==
                   "phase-1 injected filesystem dispatcher failure")
            assert(fs_injected[16]:find(
                "in native_owner_probe.fs_dispatch", 1, true))
            assert(fs_injected[4] == 0)
            assert(fs_injected[7] == 1)
            assert(fs_injected[3] == 2 and fs_injected[19] == 1)
        ]])
        assert.truthy(ok, output)
    end)

    it("links the fixture without a dynamic libuv dependency", function()
        local host = host_config()
        local command = host == "Darwin" and
            ("otool -L " .. module_path) or ("readelf -d " .. module_path)
        local ok, _, output = phase2.run(command, workspace)
        assert.truthy(ok, output)
        assert.falsy(output:lower():find("libuv", 1, true), output)
    end)
end)

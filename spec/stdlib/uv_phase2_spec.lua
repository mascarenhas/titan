local lfs = require "lfs"
local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local phase2 = require "spec.support.phase2"

describe("uv Phase 2 continuation pump", function()
    local workspace
    local cache_workspaces = {}

    setup(function()
        workspace = phase2.workspace("uv")
        phase2.copy_fixture(workspace, "behavior.titan", "phase2_behavior")
        phase2.copy_fixture(workspace, "cancellation.titan",
            "phase2_cancellation")
        phase2.compile(workspace, "phase2_behavior")
        phase2.compile(workspace, "phase2_cancellation")
    end)

    teardown(function()
        phase2.cleanup(workspace)
        for _, path in ipairs(cache_workspaces) do phase2.cleanup(path) end
        types.registry = {}
        driver.imported = {}
    end)

    local function run_scenario(name)
        local command = phase2.lua_command(workspace,
            phase2.repo .. "/spec/fixtures/uv/phase2/runtime.lua", name)
        return phase2.run(command, workspace)
    end

    it("runs nonblocking/nested roots, shared-tag nesting, A-to-B handoff, " ..
       "out-of-order timers, observation, and child-loop rejection", function()
        local ok, status, output = run_scenario("scheduler")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 scheduler passed", output, 1, true)
    end)

    it("preserves a first, sticky cancellation reason", function()
        local ok, status, output = run_scenario("cancellation")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 cancellation passed", output, 1, true)
    end)

    it("reports a cyclic Task join as an idle-loop deadlock", function()
        local ok, status, output = run_scenario("join-cycle")
        assert.falsy(ok, output)
        assert.not_equals(0, status)
        assert.match("libuv loop became idle while Tasks were waiting", output,
            1, true)
        assert.match("request=join", output, 1, true)
    end)

    it("roots dropped Tasks through generational GC and closes sequential loops",
    function()
        local ok, status, output = run_scenario("sequential-gc")
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.match("RESULT phase2 sequential GC sessions passed", output,
            1, true)
    end)

    it("clones cached test workspaces across insulated helper reloads",
    function()
        local key = "uv-phase2-cache-spec:" .. tostring({})
        local builds = 0
        local function build_template()
            builds = builds + 1
            local template = phase2.workspace("cache-template")
            local marker = assert(io.open(template .. "/cache-marker", "wb"))
            marker:write("template")
            marker:close()
            return template
        end

        local first = phase2.cached_workspace(key, build_template)
        cache_workspaces[#cache_workspaces + 1] = first
        local marker = assert(io.open(first .. "/cache-marker", "wb"))
        marker:write("first-clone")
        marker:close()

        local module_name = "spec.support.phase2"
        local original = package.loaded[module_name]
        package.loaded[module_name] = nil
        local reloaded = require(module_name)
        package.loaded[module_name] = original
        local second = reloaded.cached_workspace(key, function()
            error("workspace cache rebuilt an existing template")
        end)
        cache_workspaces[#cache_workspaces + 1] = second

        assert.equals(1, builds)
        assert.not_equals(first, second)
        assert.equals("first-clone", phase2.read(first .. "/cache-marker"))
        assert.equals("template", phase2.read(second .. "/cache-marker"))
    end)

    it("rehydrates all Phase 2 opaque records from qualified binary modules",
    function()
        types.registry = {}
        driver.imported = {}
        local old_bin = driver.TITAN_BIN_PATH
        local stdlib = phase2.standard_dir()
        driver.TITAN_BIN_PATH = phase2.module_root(stdlib)
        local source = phase2.read(
            "spec/fixtures/uv/phase2/binary_consumer.titan")
        local ast, parse_errors = parser.parse("binary_consumer.titan", source)
        assert.truthy(ast, parse_errors and parser.error_to_string(
            parse_errors, "binary_consumer.titan"))
        local deps = {}
        local modtype, errors = checker.check("binary_consumer", ast, source,
            "binary_consumer.titan", driver.defaultloader(deps))
        driver.TITAN_BIN_PATH = old_bin

        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals("uv-provider", deps["titan.uv"])
        assert.equals("dynamic-uv", deps["titan.timer"])
        assert.truthy(modtype.members.task_identity)
        assert.equals(27, types.registry["titan.uv.Task"].nfields)
        assert.equals(0, #types.registry["titan.uv.Task"].fields)
        assert.equals(8, types.registry["titan.uv.uv_timer_t"].nfields)
        assert.equals(0, #types.registry["titan.uv.uv_timer_t"].fields)
        assert.equals(1, types.registry["titan.timer.Ticker"].nfields)
        assert.equals(0, #types.registry["titan.timer.Ticker"].fields)
        assert.equals(5, #types.registry["titan.uv.Error"].fields)
        assert.equals(1, #types.registry["titan.uv.Cancelled"].fields)
    end)

    it("retains the direct native callback path and statically links libuv",
    function()
        local shim = phase2.read("titan-runtime/titan_uv.c")
        assert.not_match("lua_pcall", shim, 1, true)
        assert.not_match("luaD_call", shim, 1, true)
        assert.match("dispatch%(L, M, NULL, owner, event_kind, result, size, pointer%)",
            shim)

        local uv_c = phase2.read("titan/uv.c")
        local dispatcher = phase2.c_function_definition(uv_c,
            "static void titan_uv_timer_dispatch_titan(",
            "static int titan_uv_timer_dispatch_titanentry_lua(")
        local setjmp = assert(dispatcher:find("TITAN_SETJMP", 1, true))
        local first_gc = assert(dispatcher:find("luaC_checkGC", 1, true))
        assert.is_true(setjmp < first_gc)
        assert.match("uv_stop", dispatcher, 1, true)

        local fs_dispatcher = phase2.c_function_definition(uv_c,
            "static void titan_uv_fs_dispatch_titan(",
            "static int titan_uv_fs_dispatch_titanentry_lua(")
        local fs_setjmp = assert(fs_dispatcher:find(
            "TITAN_SETJMP", 1, true))
        local fs_gc = assert(fs_dispatcher:find("luaC_checkGC", 1, true))
        assert.is_true(fs_setjmp < fs_gc)
        assert.match("uv_fs_req_cleanup", fs_dispatcher, 1, true)
        assert.match("uv_stop", fs_dispatcher, 1, true)

        -- The real allocation counter in uv_spec covers the foundational
        -- timer wrapper. Lock representative File, TCP, and Process
        -- middle-layer paths too: their exact local pointer fields must never
        -- be boxed into a fresh userdata during repeated handle use.
        for _, accessor in ipairs({
            { "int titan_uv__fs_is_closed_titan(",
              "static int titan_uv__fs_is_closed_titanentry_lua(" },
            { "int titan_uv__net_is_closed_titan(",
              "static int titan_uv__net_is_closed_titanentry_lua(" },
            { "lua_Integer titan_uv__os_process_wait_titan(",
              "static int titan_uv__os_process_wait_titanentry_lua(" },
        }) do
            local body = phase2.c_function_definition(
                uv_c, accessor[1], accessor[2])
            assert.not_match("lua_newuserdatauv", body, 1, true)
        end

        -- Homogeneous private ownership links use exact records or record
        -- options, not value. Their generated hot paths therefore need only
        -- the option nil check and must not validate record metatables or
        -- consult the registry while linking, traversing, or unwrapping them.
        for _, path in ipairs({
            { "static TString* titan_uv_waiting_task_diagnostic_titan(",
              "static void titan_uv_check_alignment_titan(" },
            { "static void titan_uv_link_task_titan(",
              "static void titan_uv_unlink_task_titan(" },
            { "static void titan_uv_link_process_control_titan(",
              "static void titan_uv_unlink_process_control_titan(" },
            { "static Udata* titan_uv_process_pipe_titan(",
              "Udata* titan_uv__os_process_spawn_titan(" },
        }) do
            local body = phase2.c_function_definition(
                uv_c, path[1], path[2])
            assert.not_match("->metatable", body, 1, true)
            assert.not_match("lua_rawget(L, LUA_REGISTRYINDEX)",
                body, 1, true)
        end

        local uv_so = phase2.standard_dir() .. "/uv.so"
        local uname = assert(io.popen("uname -s"))
        local host = assert(uname:read("*l"))
        uname:close()
        local command = host == "Darwin" and
            ("otool -L '" .. uv_so .. "'") or
            ("readelf -d '" .. uv_so .. "'")
        local ok, _, output = phase2.run(command)
        assert.truthy(ok, output)
        assert.falsy(output:lower():find("libuv", 1, true), output)
    end)

    it("loads timer through canonical binary uv without another libuv image",
    function()
        local generated = phase2.read("titan/timer.c")
        assert.match('loadlib%(L, "titan/uv%.so"%)', generated)
        assert.match('"titan_uv_abi"', generated, 1, true)
        assert.match('"titan_uv_init"', generated, 1, true)
        assert.not_match("#include <uv.h>", generated, 1, true)
        assert.not_match("titan_uvshim", generated, 1, true)

        local uname = assert(io.popen("uname -s"))
        local host = assert(uname:read("*l"))
        uname:close()
        local timer_so = phase2.standard_dir() .. "/timer.so"
        local symbols_command = host == "Darwin" and
            ("nm -g '" .. timer_so .. "'") or
            ("nm -D '" .. timer_so .. "'")
        local ok, _, symbols = phase2.run(symbols_command)
        assert.truthy(ok, symbols)
        assert.match("luaopen_titan_timer", symbols, 1, true)
        assert.match("titan_timer_init", symbols, 1, true)
        assert.match("titan_timer_abi", symbols, 1, true)
        assert.match("titan_timer_types", symbols, 1, true)
        assert.not_match("luaopen_timer", symbols, 1, true)
        assert.not_match("titan_uvshim", symbols, 1, true)

        local dependencies_command = host == "Darwin" and
            ("otool -L '" .. timer_so .. "'") or
            ("readelf -d '" .. timer_so .. "'")
        ok, _, symbols = phase2.run(dependencies_command)
        assert.truthy(ok, symbols)
        assert.falsy(symbols:lower():find("libuv", 1, true), symbols)
    end)
end)

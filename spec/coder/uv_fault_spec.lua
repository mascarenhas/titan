local phase2 = require "spec.support.phase2"
local lua_header = phase2.read("lua-5.5.0/src/lua.h")
local LUA_MINSTACK = tonumber(assert(lua_header:match(
    "#define%s+LUA_MINSTACK%s+(%d+)")))

local function assert_entry_catch_precedes_gc(generated, signature, following,
                                                expected_slots)
    local definition = phase2.c_function_definition(
        generated, signature, following)
    local slots = tonumber(assert(definition:match(
        "L%->stack_last%.p %- L%->top%.p > (%d+)")))
    assert.equals(expected_slots, slots)
    assert.is_true(slots + 4 <= LUA_MINSTACK)
    local setjmp = assert(definition:find("TITAN_SETJMP", 1, true))
    local first_gc = assert(definition:find("luaC_checkGC", 1, true))
    assert.is_true(setjmp < first_gc)
end

describe("uv Phase 2 isolated scheduler faults", function()
    local workspace

    setup(function()
        workspace = phase2.variant_workspace(
            "spec/support/make_uv_test_variant.lua")
        phase2.copy_fixture(workspace, "fault_core.titan", "fault_core")
        phase2.compile(workspace, "fault_core", { stdlib = workspace })
        phase2.copy_fixture(workspace, "bootstrap_main_cancel.titan",
            "bootstrap_main_cancel")
        phase2.compile(workspace, "bootstrap_main_cancel", {
            stdlib = workspace,
        })
    end)

    teardown(function()
        phase2.cleanup(workspace)
    end)

    local function run_lua(fixture)
        local script = phase2.repo .. "/spec/fixtures/uv/phase2/" .. fixture
        return phase2.run(
            phase2.variant_lua_command(workspace, script), workspace)
    end

    it("keeps fault controls out of production and in the variant", function()
        local production = phase2.read("stdlib/uv.c")
        assert.falsy(production:find("__test_", 1, true))
        local variant = phase2.read(workspace .. "/stdlib/uv.c")
        assert.match("uv___test_run_main_titan", variant, 1, true)
        assert.match("uv___test_cancel_main_titan", variant, 1, true)
        assert.match("uv___test_fail_next_close_bookkeeping_titan",
            variant, 1, true)
        assert_entry_catch_precedes_gc(variant,
            "static void uv_timer_dispatch_titan(",
            "static int uv_timer_dispatch_titanentry_lua(", 10)

        local loop = phase2.c_function_definition(variant,
            "void uv_loop_titan(", "static int uv_loop_titanentry_lua(")
        local minstack = assert(loop:find("LUA_MINSTACK", 1, true))
        local reservation_error = assert(loop:find(
            "cannot reserve stack for libuv native callbacks", minstack, true))
        assert.match("==%s*0", loop:sub(minstack, reservation_error))

        local coroutine = phase2.read(workspace .. "/stdlib/coroutine.c")
        assert_entry_catch_precedes_gc(coroutine,
            "static void coroutine_coro_entry_titan(",
            "static int coroutine_coro_entry_titanentry_lua(", 8)

        local runtime = phase2.read("titan-runtime/titan.c")
        local newthread = phase2.c_function_definition(runtime,
            "lua_State *titan_newthread(", "int errorhandler(")
        assert.match("if%s*%(%s*!lua_checkstack%(%s*T,%s*LUA_MINSTACK%s*%)%s*%)",
            newthread)
        assert.match("cannot reserve stack for Titan coroutine entry",
            newthread, 1, true)
    end)

    it("runs cleanup shielding and bounded immediate-error delivery", function()
        local ok, status, output = phase2.run(
            phase2.variant_app_command(workspace, "fault_core"), workspace)
        assert.truthy(ok, output)
        assert.equals(0, status, output)
    end)

    it("reports cancellation of the real standalone bootstrap main Task",
    function()
        local ok, status, output = phase2.run(
            phase2.variant_app_command(workspace, "bootstrap_main_cancel"),
            workspace)
        assert.falsy(ok, output)
        assert.equals(1, status, output)
        assert.match("phase2-bootstrap-main-cancelled", output, 1, true)
        assert.match("stack traceback:", output, 1, true)
        assert.match("in bootstrap_main_cancel.main", output, 1, true)
    end)

    for _, case in ipairs({
        { "pre_runtime_child_loop.lua", "rejects a child loop before Runtime creation" },
        { "callback_invariants.lua", "keeps callback and C uv_run depth one on main L" },
        { "cancelled_delayed_join.lua", "revokes a delayed join observer before delivery" },
        { "fatal_rejects_work.lua", "rejects ordinary work after callback infrastructure fatal" },
        { "untracked_timer_ebusy.lua", "diagnoses an untracked handle at loop close" },
        { "cancel_fallback.lua", "uses an outer-safe cancellation fallback" },
        { "dispatcher_catch.lua", "contains dispatcher failures in Titan" },
        { "main_cancel.lua", "reports cancellation of the main Task" },
        { "main_precedence.lua", "preserves first-error precedence" },
    }) do
        it(case[2], function()
            local ok, status, output = run_lua(case[1])
            assert.truthy(ok, output)
            assert.equals(0, status, output)
            assert.match("RESULT", output, 1, true)
        end)
    end
end)

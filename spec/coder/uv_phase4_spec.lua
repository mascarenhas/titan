local phase2 = require "spec.support.phase2"
local phase3 = require "spec.support.phase3"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function interface_definition(source)
    local first = assert(source:find("int uv_types(", 1, true))
    local last = assert(source:find("int uv_abi(", first, true))
    return source:sub(first, last - 1)
end

-- The two close-specific cancellation regressions live with the File pump in
-- fs_fault_spec: a cancelled finally closes two Files sequentially, and a
-- secondary close waiter survives an epoch change. This suite owns the
-- remaining scheduler/FS callback/GC races without duplicating those fixtures.
describe("uv Phase 4 deterministic races", function()
    local workspace
    local root

    setup(function()
        workspace, root = phase3.variant_workspace(
            "spec/support/make_phase4_test_variant.lua")
        phase2.copy_source(workspace,
            "spec/fixtures/uv/phase4/race_cases.titan",
            "phase4_race_cases")
        local compile_options = {
            stdlib = workspace,
        }
        phase3.compile(workspace, "phase4_race_cases", compile_options)
        phase2.copy_source(workspace,
            "spec/fixtures/uv/phase4/main_child.titan",
            "phase4_main_child")
        phase3.compile(workspace, "phase4_main_child", compile_options)
    end)

    teardown(function()
        phase3.cleanup(workspace)
    end)

    it("keeps deterministic race controls isolated and fail-closed", function()
        local production_titan = phase3.read("stdlib/uv.titan")
        local production_c = phase3.read("stdlib/uv.c")
        assert.falsy(production_titan:find("__test_phase4_", 1, true))
        assert.falsy(production_c:find("__test_phase4_", 1, true))

        local variant_titan = phase3.read(
            workspace .. "/stdlib/uv.titan")
        local variant_c = phase3.read(workspace .. "/stdlib/uv.c")
        local variant_interface = interface_definition(variant_c)
        for _, hook in ipairs({
            "__test_phase4_owner_starts",
            "__test_phase4_delay_next_cancel",
            "__test_phase4_delay_next_fs_callback",
            "__test_phase4_reset_fs_counters",
            "__test_phase4_override_next_fs_cancel_success",
            "__test_phase4_fs_physical_callbacks",
            "__test_phase4_fs_deliveries",
            "__test_phase4_fs_cancel_calls",
            "__test_phase4_fs_cancel_status",
            "__test_phase4_fs_cleanups",
            "__test_phase4_fs_open_successes",
            "__test_phase4_fs_open_publications",
            "__test_phase4_fs_internal_close_enqueues",
            "__test_phase4_fs_internal_close_callbacks",
            "__test_phase4_fs_pending_roots",
            "__test_phase4_file_roots",
            "__test_phase4_runtime_active",
        }) do
            assert.match(hook, variant_titan, 1, true)
            assert.match(hook, variant_interface, 1, true)
        end

        local physical = assert(variant_titan:find(
            "test_phase4_fs_physical_callbacks", 1, true))
        local delay_owner = assert(variant_titan:find(
            "OWNER_PHASE4_FS_DELAY", physical, true))
        local body = assert(variant_titan:find(
            "fs_dispatch_body(owner, event_kind, result, size)",
            delay_owner, true))
        assert.is_true(physical < delay_owner and delay_owner < body)
    end)

    it("makes completion/cancellation races, sticky awaits, public errors, " ..
       "late FS callbacks/open disposal, and cross-generation roots " ..
       "deterministic", function()
        local command = phase3.variant_lua_command(workspace,
            phase3.repo .. "/spec/fixtures/uv/phase4/runtime.lua", root)
        local ok, status, output = phase3.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase4 race and GC cases passed",
            output, 1, true)
    end)

    it("drives an independent child after standalone main returns", function()
        local marker = root .. "/main-child.marker"
        local command = phase3.variant_app_command(
            workspace, "phase4_main_child") .. " " .. quote(marker)
        local ok, status, output = phase3.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.equals("independent-child-finished", phase3.read(marker))
    end)

    it("destroys suspended and stacked coroutine fibers", function()
        local script = phase3.repo ..
            "/spec/fixtures/uv/phase4/stacked_gc.lua"
        local command = phase3.variant_lua_command(workspace, script)
        local ok, status, output = phase3.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT phase4 stacked coroutine destruction passed",
            output, 1, true)
    end)
end)

local phase3 = require "spec.support.phase3"

local function quote(word)
    return "'" .. tostring(word):gsub("'", "'\\''") .. "'"
end

local function count_plain(source, needle)
    local count = 0
    local cursor = 1
    while true do
        local first = source:find(needle, cursor, true)
        if not first then return count end
        count = count + 1
        cursor = first + #needle
    end
end

local function interface_definition(source, module)
    local first = assert(source:find("int " .. module .. "_types(", 1, true))
    local last = assert(source:find("int " .. module .. "_abi(", first, true))
    return source:sub(first, last - 1)
end

describe("fs Phase 3 isolated lifecycle faults", function()
    local workspace
    local root

    setup(function()
        workspace, root = phase3.variant_workspace(
            "spec/support/make_fs_test_variant.lua")
        phase3.copy_fixture(workspace, "fs_faults.titan",
            "phase3_fs_faults")
        phase3.compile(workspace, "phase3_fs_faults", {
            stdlib = workspace,
        })
    end)

    teardown(function()
        phase3.cleanup(workspace)
    end)

    it("keeps filesystem controls isolated and instruments every cleanup arm",
    function()
        local production_uv_source = phase3.read("stdlib/uv.titan")
        local production_fs_source = phase3.read("stdlib/fs.titan")
        local production_uv_c = phase3.read("stdlib/uv.c")
        local production_fs_c = phase3.read("stdlib/fs.c")
        for _, source in ipairs({
            production_uv_source,
            production_fs_source,
            production_uv_c,
            production_fs_c,
            interface_definition(production_uv_c, "uv"),
            interface_definition(production_fs_c, "fs"),
        }) do
            assert.falsy(source:find("__test_fs_", 1, true))
        end

        local variant_source = phase3.read(workspace .. "/stdlib/uv.titan")
        local variant_c = phase3.read(workspace .. "/stdlib/uv.c")
        local variant_interface = interface_definition(variant_c, "uv")
        for _, hook in ipairs({
            "__test_fs_reset_counters",
            "__test_fs_submission_count",
            "__test_fs_cleanup_count",
            "__test_fs_current_active",
            "__test_fs_max_active_per_file",
            "__test_fs_fail_next_submit",
            "__test_fs_fail_next_prepare",
            "__test_fs_fail_prepare_after",
            "__test_fs_force_close_callback_errors",
            "__test_fs_close_retry_limit",
            "__test_fs_set_max_write_chunk",
            "__test_fs_pause_next_file_submission",
            "__test_fs_resume_file_submissions",
        }) do
            assert.match(hook, variant_source, 1, true)
            assert.match(hook, variant_interface, 1, true)
        end

        assert.equals(2, count_plain(variant_source,
            "libuv.uv_fs_req_cleanup(owner.handle)"))
        assert.equals(2, count_plain(variant_source,
            "test_fs_cleanups = test_fs_cleanups + 1"))

        assert.falsy(production_uv_source:find(
            "local function owner_pointer", 1, true))
        assert.falsy(production_uv_source:find(
            "local function fs_owner_pointer", 1, true))
        local submit = assert(production_uv_source:find(
            "local function submit_fs_operation", 1, true))
        local open_flags = assert(production_uv_source:find(
            "open_flags = fs_open_flags(operation.data)", submit, true))
        local prepared = assert(production_uv_source:find(
            "-- TITAN_UV_FS_TEST_AFTER_PREPARE", open_flags, true))
        local owner_allocation = assert(production_uv_source:find(
            "allocate_fs_owner(runtime, operation)", prepared, true))
        local submitted = assert(production_uv_source:find(
            "owner.metadata.lifecycle = FS_OWNER_SUBMITTED",
            owner_allocation, true))
        assert.is_true(open_flags < prepared and
            prepared < owner_allocation and owner_allocation < submitted)

        local pump = assert(variant_source:find(
            "local function submit_file_head", 1, true))
        local pause = assert(variant_source:find(
            "-- TITAN_UV_FS_TEST_PAUSE_BEFORE_ALLOCATION", pump, true))
        local early_return = assert(variant_source:find("return nil", pause, true))
        local allocation = assert(variant_source:find(
            "submit_fs_operation(operation)", pause, true))
        assert.is_true(pause < early_return and early_return < allocation)

        local variant_fs_c = phase3.read(workspace .. "/stdlib/fs.c")
        assert.falsy(interface_definition(variant_fs_c, "fs"):find(
            "__test_fs_", 1, true))
    end)

    it("balances sync, callback, partial-write, close, and cancellation paths",
    function()
        local command = phase3.variant_app_command(
            workspace, "phase3_fs_faults") .. " " .. quote(root)
        local ok, status, output = phase3.run(command, workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
    end)

    it("repairs File state after the trusted dispatcher catch", function()
        local application = phase3.variant_app_command(
            workspace, "phase3_fs_faults") .. " " .. quote(root) ..
            " dispatcher-catch"
        local watchdog = application ..
            " & pid=$!; " ..
            "(sleep 15; kill -TERM $pid 2>/dev/null) " ..
            "</dev/null >/dev/null 2>&1 & guard=$!; " ..
            "wait $pid; status=$?; kill $guard 2>/dev/null; exit $status"
        local ok, status, output = phase3.run(
            "sh -c " .. quote(watchdog), workspace)
        assert.falsy(ok, output)
        assert.equals(1, status,
            "dispatcher catch did not terminate normally\n" .. output)
        assert.match("injected filesystem dispatcher failure",
            output, 1, true)
        assert.match("in uv.fs_dispatch", output, 1, true)
    end)

    it("closes an aborted successful open exactly once", function()
        local script = phase3.repo ..
            "/spec/fixtures/uv/phase3/fs_open_dispatch.lua"
        local application = phase3.variant_lua_command(
            workspace, script, root)
        local watchdog = application ..
            " & pid=$!; " ..
            "(sleep 15; kill -TERM $pid 2>/dev/null) " ..
            "</dev/null >/dev/null 2>&1 & guard=$!; " ..
            "wait $pid; status=$?; kill $guard 2>/dev/null; exit $status"
        local ok, status, output = phase3.run(
            "sh -c " .. quote(watchdog), workspace)
        assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
        assert.equals(0, status, output)
        assert.match("RESULT aborted successful open closed exactly once",
            output, 1, true)
    end)

    for _, case in ipairs({
        { "prepare", "contains allocation failure before native submission",
          "RESULT pre-submit filesystem failure left no owner" },
        { "partial-prepare",
          "contains allocation failure before partial-write resubmission",
          "RESULT partial-write resubmit preparation left no owner" },
        { "close", "bounds persistent close callback failures",
          "RESULT persistent close failure stopped after bounded retries" },
    }) do
        it(case[2], function()
            local script = phase3.repo ..
                "/spec/fixtures/uv/phase3/fs_terminal_faults.lua"
            local application = phase3.variant_lua_command(
                workspace, script, root, case[1])
            local watchdog = application ..
                " & pid=$!; " ..
                "(sleep 15; kill -TERM $pid 2>/dev/null) " ..
                "</dev/null >/dev/null 2>&1 & guard=$!; " ..
                "wait $pid; status=$?; kill $guard 2>/dev/null; exit $status"
            local ok, status, output = phase3.run(
                "sh -c " .. quote(watchdog), workspace)
            assert.truthy(ok, "exit " .. tostring(status) .. "\n" .. output)
            assert.equals(0, status, output)
            assert.match(case[3], output, 1, true)
        end)
    end
end)

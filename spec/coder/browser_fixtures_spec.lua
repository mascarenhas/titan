local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local support = require "spec.fixtures.browser_runtime.support"
local workspace

describe("browser coroutine GC and trace fixtures", function()
    after_each(function()
        if workspace then support.files.remove(workspace); workspace = nil end
    end)

    it("runs all five 301 categories in their native owners without an adapter", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = support.workspace()
        local ok, log = support.cli(info, workspace, { purpose = "test" }, {
            "--test", "--exe", workspace .. "/public.mjs",
            "--c-source", support.fixture .. "/close.c", "coroutine.tests", "gc.tests" })
        assert.is_true(ok, log)
        toolchain.check_imports(workspace .. "/public.mjs", { "entry" })
        local names = {
            "coroutine.tests.test_routes_nested_tagged_yield_through_suspended_outer_handler",
            "coroutine.tests.test_roots_nested_stacked_payloads_and_tags_across_gc",
            "coroutine.tests.test_unwind_runs_suspended_defers_innermost_first",
            "coroutine.tests.test_unwind_resumed_error_runs_defer_once",
            "coroutine.tests.test_unwind_browser_lua_close",
            "gc.tests.test_gc_weak_maps_preserve_metatables",
        }
        local arguments = {}
        for _, name in ipairs(names) do
            arguments[#arguments + 1] = "--filter=^" .. name:gsub("[.]", "%%.") .. "$"
        end
        for _, engine in ipairs({ "node", "chromium" }) do
            ok, log = support.image(info, workspace, engine, "public", arguments)
            assert.is_true(ok, log)
            support.count(log, 6)
            assert.truthy(log:find("category=retained_close", 1, true), log)
        end
    end)

    it("preserves trace shape pin clear bare rethrow fresh raise and coroutine append", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
        workspace = support.workspace()
        local ok, log = support.cli(info, workspace, { purpose = "test" }, {
            "--test", "--exe", workspace .. "/trace.mjs",
            "--c-source", support.fixture .. "/trace.c", "runtime_trace" })
        assert.is_true(ok, log)
        toolchain.check_imports(workspace .. "/trace.mjs", { "entry" })
        for _, engine in ipairs({ "node", "chromium" }) do
            ok, log = support.image(info, workspace, engine, "trace")
            assert.is_true(ok, log)
            support.count(log, 4)
        end
    end)
end)

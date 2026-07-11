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

    it("rehydrates all Phase 2 opaque records from binary-only stdlib DSOs",
    function()
        types.registry = {}
        driver.imported = {}
        local old = driver.TITAN_STDLIB_PATH
        local old_bin = driver.TITAN_BIN_PATH
        driver.TITAN_STDLIB_PATH = phase2.standard_dir()
        -- Coder specs may leave checkout-level DSOs behind. They are valid
        -- adversarial shadows, but this test is about binary interface
        -- rehydration, so give its ordinary search path an isolated empty root.
        driver.TITAN_BIN_PATH = workspace .. "/src"
        local source = phase2.read(
            "spec/fixtures/uv/phase2/binary_consumer.titan")
        local ast, parse_errors = parser.parse("binary_consumer.titan", source)
        assert.truthy(ast, parse_errors and parser.error_to_string(
            parse_errors, "binary_consumer.titan"))
        local deps = {}
        local modtype, errors = checker.check("binary_consumer", ast, source,
            "binary_consumer.titan", driver.defaultloader(deps))
        driver.TITAN_STDLIB_PATH = old
        driver.TITAN_BIN_PATH = old_bin

        assert.equals(0, #errors, table.concat(errors, "\n"))
        assert.equals("standard", deps.uv)
        assert.equals("standard", deps.timer)
        assert.truthy(modtype.members.task_identity)
        assert.equals(27, types.registry["uv.Task"].nfields)
        assert.equals(0, #types.registry["uv.Task"].fields)
        assert.equals(8, types.registry["uv.uv_timer_t"].nfields)
        assert.equals(0, #types.registry["uv.uv_timer_t"].fields)
        assert.equals(1, types.registry["timer.Ticker"].nfields)
        assert.equals(0, #types.registry["timer.Ticker"].fields)
        assert.equals(5, #types.registry["uv.Error"].fields)
        assert.equals(1, #types.registry["uv.Cancelled"].fields)
    end)

    it("retains the direct native callback path and statically links libuv",
    function()
        local shim = phase2.read("titan-runtime/titan_uv.c")
        assert.not_match("lua_pcall", shim, 1, true)
        assert.not_match("luaD_call", shim, 1, true)
        assert.match("dispatch%(L, M, NULL, owner, event_kind, result, size, pointer%)",
            shim)

        local uv_c = phase2.read("stdlib/uv.c")
        local dispatcher = phase2.c_function_definition(uv_c,
            "static void uv_timer_dispatch_titan(",
            "static int uv_timer_dispatch_titanentry_lua(")
        local setjmp = assert(dispatcher:find("TITAN_SETJMP", 1, true))
        local first_gc = assert(dispatcher:find("luaC_checkGC", 1, true))
        assert.is_true(setjmp < first_gc)
        assert.match("uv_stop", dispatcher, 1, true)

        local fs_dispatcher = phase2.c_function_definition(uv_c,
            "static void uv_fs_dispatch_titan(",
            "static int uv_fs_dispatch_titanentry_lua(")
        local fs_setjmp = assert(fs_dispatcher:find(
            "TITAN_SETJMP", 1, true))
        local fs_gc = assert(fs_dispatcher:find("luaC_checkGC", 1, true))
        assert.is_true(fs_setjmp < fs_gc)
        assert.match("uv_fs_req_cleanup", fs_dispatcher, 1, true)
        assert.match("uv_stop", fs_dispatcher, 1, true)

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
        local generated = phase2.read("stdlib/timer.c")
        assert.match('loadstdlib%(L, "uv%.so"%)', generated)
        assert.match('"uv_abi"', generated, 1, true)
        assert.match('"uv_init"', generated, 1, true)
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
        assert.match("timer_init", symbols, 1, true)
        assert.match("timer_abi", symbols, 1, true)
        assert.match("timer_types", symbols, 1, true)
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

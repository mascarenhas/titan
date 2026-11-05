local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local cdriver = require "c-parser.cdriver"
local csemantics = require "titan-compiler.csemantics"
local fixtures = require "spec.support.browser_fixtures"
local toolchain = require "spec.support.browser_toolchain"
local hrtime = require("titan-compiler.process").library().hrtime
local support = require "spec.fixtures.browser_runtime.support"
local workspace

local function build(info, root, assertions, name, budgets)
    local options = { purpose = "budget", assertions = assertions, optimization = "O2" }
    if budgets then options.budgets = budgets end
    local output = root .. "/objects-" .. assertions .. "-" .. name
    support.files.mkdir(output)
    local ok, log = support.cli(info, output, options, {
        "--exe", root .. "/" .. name .. ".mjs", "--c-source", support.fixture .. "/budget.c",
        "--c-source", support.fixture .. "/budget_pad.c",
        "--ldflag=-Wl,--wrap=mco_create", "budget_probe" })
    assert.is_true(ok, log)
end

local function limit_failure(status, log, mode)
    assert.are_not.equal(72, status, "budget probe timed out instead of reporting its limit\n" .. log)
    if status == 75 then
        assert.truthy(log:find("Maximum call stack size exceeded", 1, true), log)
        return "engine-call-stack"
    end
    assert.truthy(status == 70 or status == 71, "unexpected budget failure category " .. tostring(status) .. "\n" .. log)
    local lower = log:lower()
    if mode:find("shadow", 1, true) then
        assert.truthy(lower:find("stack overflow", 1, true), "unchecked shadow-stack failure\n" .. log)
        return "checked-C-stack"
    end
    assert.truthy(lower:find("stack overflow", 1, true) or lower:find("unreachable", 1, true) or
        lower:find("out of bounds", 1, true), log)
    return lower:find("stack overflow", 1, true) and "checked-C-stack" or "trap"
end

describe("browser measured delivered budget limits", function()
    after_each(function()
        if workspace then support.files.remove(workspace); workspace = nil end
    end)

    it("retains the 2 MiB native coroutine stack default and explicit browser profile budgets", function()
        local descriptor = fixtures.descriptor()
        local plan = assert(browserlink.profile(descriptor, { purpose = "program", assertions = 2 }))
        assert.same({
            stack_size = 1048576,
            initial_memory = 16777216,
            maximum_memory = 2147483648,
        }, plan.identity_inputs.budgets)

        local prefix = require("spec.support.installed_prefix").active()
        local runtime_dir = support.repository .. "/titan-runtime"
        local lua_dir = prefix .. "/src/lua-5.5.1"
        if not require("titan-compiler.io").new_sync():stat(lua_dir .. "/lua.h") then
            lua_dir = support.repository .. "/lua-5.5.1/src"
        end
        local profile = fixtures.profile()
        local native_types = assert(cdriver.process_file("titan.h", {
            compiler_include_dirs = { lua_dir, runtime_dir },
            cppflags = {},
        }))
        local native_stack = assert(csemantics.evaluate_macro_expression(
            profile, native_types.TITAN_COROUTINE_STACK_SIZE.macro_expression))
        assert.equal(2097152, tonumber(native_stack.value))

        local browser_types = assert(cdriver.process_file("titan.h", {
            compiler_include_dirs = { lua_dir, runtime_dir },
            cppflags = { table.unpack(descriptor.target_defines) },
        }))
        local browser_stack = assert(csemantics.evaluate_macro_expression(
            profile, browser_types.TITAN_COROUTINE_STACK_SIZE.macro_expression))
        assert.equal(262144, tonumber(browser_stack.value))
    end)

    for _, assertions in ipairs({ 2, 0 }) do
        it("measures all five rows at the delivered limits on Node and Chromium with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
            workspace = support.workspace()
            build(info, workspace, assertions, "budget")
            for _, engine in ipairs({ "node", "chromium" }) do
                local started = hrtime()
                local probes, positive, negative = 0, 0, 0
                local results = {}
                local function probe(image, mode, value)
                    local key = image .. ":" .. mode .. ":" .. value
                    if results[key] then return table.unpack(results[key]) end
                    local ok, log, status = support.image(info, workspace, engine, image,
                        { mode, tostring(value) }, mode == "exhaust" and 120000 or 15000)
                    probes = probes + 1
                    if ok then
                        positive = positive + 1
                        support.count(log, 1)
                        assert.truthy(log:find("coroutine_bytes=262144", 1, true), log)
                        assert.truthy(log:find("BUDGET END mode=" .. mode, 1, true), log)
                    else negative = negative + 1 end
                    results[key] = { ok, log, status }
                    return ok, log, status
                end
                local function measure(image, mode, unit, ceiling)
                    local m_started = hrtime()
                    local low, high = unit, unit * 2
                    local failure_log, failure_status
                    local ok, log = probe(image, mode, low)
                    assert.is_true(ok, log)
                    while true do
                        local status
                        ok, log, status = probe(image, mode, high)
                        if not ok then failure_log, failure_status = log, status; break end
                        low, high = high, high * 2
                        assert.truthy(high <= ceiling, "budget probe never reached its real limit: " .. mode)
                    end
                    while high - low > unit do
                        local middle = ((low + high) // (2 * unit)) * unit
                        local status
                        ok, log, status = probe(image, mode, middle)
                        if ok then low = middle
                        else high, failure_log, failure_status = middle, log, status end
                    end
                    local attribution = limit_failure(failure_status, failure_log, mode)
                    io.stdout:write(string.format("BUDGET LIMIT assertions=%d engine=%s image=%s mode=%s largest_safe=%d first_failing=%d unit=%d category=%s status=%d elapsed_ms=%.2f\n",
                        assertions, engine, image, mode, low, high, unit, attribution, failure_status, (hrtime() - m_started) / 1e6))
                    io.stdout:flush()
                    return low, high
                end

                -- Native Titan recursion is measured separately from a direct,
                -- checked, non-yielding shadow-stack overrun in each context.
                measure("budget", "main-titan", 1, 65536)
                measure("budget", "main-shadow", 16, 4194304)
                measure("budget", "fiber-titan", 1, 65536)
                measure("budget", "fiber-shadow", 16, 1048576)
                -- Live Wasm locals now belong to JSPI engine continuations;
                -- there is no separate instrumentation-data buffer or budget.
                measure("budget", "outer-wait", 1, 65536)
                measure("budget", "coroutine-wait", 1, 65536)
                measure("budget", "nested-entry", 1, 65536)

                for _, mode in ipairs({ "lua-limit", "create-failure", "exhaust" }) do
                    local mode_started = hrtime()
                    local ok, log = probe("budget", mode, 0)
                    assert.is_true(ok, log)
                    if mode == "lua-limit" then
                        assert.truthy(log:find("allocator=Lua ordinary_error=C stack overflow", 1, true), log)
                    elseif mode == "create-failure" then
                        assert.truthy(log:find("deterministic_mco_failure=1 fresh_after_failure=1", 1, true), log)
                    elseif mode == "exhaust" then
                        assert.truthy(log:find("initial_heap=16777216 exhausted_heap=2147483648 released_heap=2147483648 maximum=2147483648", 1, true), log)
                        assert.truthy(log:find("existing_canary=42 fresh_after_gc=43", 1, true), log)
                    end
                    io.stdout:write(string.format("BUDGET MODE assertions=%d engine=%s mode=%s elapsed_ms=%.2f PASS\n",
                        assertions, engine, mode, (hrtime() - mode_started) / 1e6))
                    io.stdout:flush()
                end
                io.stdout:write(string.format("BUDGET VERDICT assertions=%d engine=%s rows=5 probes=%d positive=%d reported_negative=%d wall_s=%.3f PASS\n",
                    assertions, engine, probes, positive, negative, (hrtime() - started) / 1e9))
                io.stdout:flush()
            end
        end)
    end
end)

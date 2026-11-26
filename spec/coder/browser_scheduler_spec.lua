local assert = require "luassert"
local browserlink = require "titan-compiler.browserlink"
local files = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local checks = dofile("scripts/browser_stdlib.lua")
local repository = toolchain.repository
local source = repository .. "/spec/fixtures/browser_scheduler"
local stdlib_tree = repository .. "/spec/stdlib/titan"
local fixture

-- The mini driver drives titan.browser's drive interface without async; the
-- async browser backend's own scheduler cases build on the same loader.
local function build(info)
    local output = fixture.output .. "/mini-driver"
    files.mkdir(output)
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() ..
        ";require('titan-compiler.driver').browser_link_options={purpose='program'};"
    local result = fixture:run({ info.lua, "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--no-uv-bootstrap",
        "--tree", source, "--output", output, "--exe", output .. "/mini-driver.mjs",
        "--c-source", source .. "/mini_driver.c", "mini_driver" },
        { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    toolchain.check_imports(output .. "/mini-driver.mjs", { "entry", "fixture:scheduler" })
    return output, "out/mini-driver/mini-driver.mjs"
end

-- Builds out/<name>/<name>.mjs with the frontend under coverage.
local function build_image(info, purpose, name, arguments)
    local output = fixture.output .. "/" .. name
    files.mkdir(output)
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() .. string.format(
            ";require('titan-compiler.driver').browser_link_options={purpose=%q};", purpose)
    local argv = { info.lua, "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--output", output, "--exe", output .. "/" .. name .. ".mjs" }
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    local result = fixture:run(argv, { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    -- Only the scheduler owner links a scheduler fixture helper.
    toolchain.check_imports(output .. "/" .. name .. ".mjs",
        name == "scheduler" and { "entry", "fixture:scheduler" } or { "entry" })
    return "out/" .. name .. "/" .. name .. ".mjs"
end

-- The async scheduler owner (spec/stdlib/titan/async/browser_tests) is a
-- browser-only test owner of the stdlib tree; its child states come from
-- scheduler_child.c.
local function build_scheduler(info)
    return build_image(info, "test", "scheduler", { "--no-uv-bootstrap", "--test",
        "--tree", stdlib_tree, "--c-source", source .. "/scheduler_child.c", "async.browser_tests" })
end

-- bootstrap.titan keeps the async bootstrap: its main runs as a Task.
local function build_bootstrap(info)
    return build_image(info, "program", "bootstrap", { "--tree", source, "bootstrap" })
end

-- Copies the harnesses and the fixtures' host imports beneath the root.
local function copy_sources(names)
    for _, name in ipairs(names) do
        files.copy(source .. "/" .. name, fixture.source .. "/" .. name)
    end
    files.copy(repository .. "/spec/fixtures/browser_runtime/fixture-imports.mjs",
        fixture.source .. "/fixture-imports.mjs")
end

local function execute(info, engine, argv, zone)
    local command = toolchain.runner(info, "--engine", engine,
        "--timeout", "120000", "--grace", "1500", "--root", fixture.root,
        "--imports", fixture.source .. "/fixture-imports.mjs")
    for _, item in ipairs(argv) do command[#command + 1] = item end
    return fixture:run(command, { TITAN_NODE = info.node.path, TITAN_CHROME = info.chrome.path,
        TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TZ = zone })
end

describe("browser drive interface", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    it("relinquishes, delivers, admits, disposes and exits a mini driver", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        copy_sources({ "support.mjs", "mini-driver.mjs", "mini-driver-abort.mjs", "admission.mjs" })
        local output, image = build(info)
        local inventory = assert(browserlink.image_inventory(files.read(output .. "/mini-driver.wasm")))
        local suspending = false
        for _, import in ipairs(inventory.imports) do
            if import.name == "titan_browser_relinquish" then suspending = true end
        end
        assert.is_true(suspending, "the bridge image does not import the driver's relinquish")
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, { "--js-test", fixture.source .. "/mini-driver.mjs", "--", image })
            io.stdout:write(string.format("\nMINI-DRIVER engine=%s node=%s chrome=%s\n%s\n",
                engine, info.node.version, info.chrome.version, result.output))
            io.stdout:flush()
            assert.is_true(result.ok, result.output)
            assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
            assert.truthy(result.output:find('"lastPinCloseWake":{"resumed":0,"idle":1}', 1, true),
                result.output)
            assert.truthy(result.output:find('"disposal":{"parked":[2],"cleanup":[2,2],' ..
                '"orphaned":[2,1],"shutdown":[2,2]}', 1, true), result.output)
            -- Design 4.2's admission matrix, including the synchronous C
            -- callback rows; the suite asserts every row's outcome.
            local admitted = execute(info, engine, { "--js-test", fixture.source .. "/admission.mjs", "--", image })
            io.stdout:write(string.format("\nADMISSION engine=%s\n%s\n", engine, admitted.output))
            io.stdout:flush()
            assert.is_true(admitted.ok, admitted.output)
            assert.truthy(admitted.output:find('"verdict":"PASS"', 1, true), admitted.output)
            assert.truthy(admitted.output:find('"callbacks":{"drive: from a parked wait":"ran",', 1, true),
                admitted.output)
            -- Binaryen 133's checked C-stack overflow is a plain unreachable trap.
            local aborted = execute(info, engine, { "--js-test", fixture.source .. "/mini-driver-abort.mjs",
                "--", image })
            assert.equal(71, aborted.status, aborted.output)
            assert.truthy(aborted.output:find("mini-driver-abort-complete", 1, true), aborted.output)
            assert.truthy(aborted.output:find("unreachable", 1, true), aborted.output)
            -- The runner reports an exited program with status & 255.
            for _, case in ipairs({ { "exit", 3 }, { "return", 7 }, { "exit-fail", 1 } }) do
                local ran = execute(info, engine, { fixture.root .. "/" .. image, "--", case[1] })
                assert.equal(case[2], ran.status, ran.output)
            end
        end
    end)

    it("runs the async scheduler gate, disposal, exit and ownership", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        copy_sources({ "support.mjs", "scheduler.mjs", "streams.mjs", "runner-kinds.mjs" })
        local image = build_scheduler(info)
        local kinds = build_image(info, "program", "stream-kinds",
            { "--tree", source, "stream_kinds" })
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, { "--js-test", fixture.source .. "/scheduler.mjs", "--", image })
            io.stdout:write(string.format("\nSCHEDULER engine=%s node=%s chrome=%s\n%s\n",
                engine, info.node.version, info.chrome.version, result.output))
            io.stdout:flush()
            assert.is_true(result.ok, result.output)
            assert(checks.require_evidence(checks.status_inventory, result.output,
                { ["async.browser_tests"] = true }))
            local gate_cases = 0
            for name in pairs(checks.passed_cases(result.output)) do
                if name:match("^async%.browser_tests%.") then gate_cases = gate_cases + 1 end
            end
            assert.equal(22, gate_cases, result.output)
            assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
            assert.truthy(result.output:find('"gate":22', 1, true), result.output)
            assert.truthy(result.output:find('"crowd":2000', 1, true), result.output)
            local streams = execute(info, engine, { "--js-test", fixture.source .. "/streams.mjs", "--", image })
            io.stdout:write(string.format("\nSTREAMS engine=%s\n%s\n", engine, streams.output))
            io.stdout:flush()
            assert.is_true(streams.ok, streams.output)
            assert.truthy(streams.output:find('STREAMS {"verdict":"PASS"', 1, true), streams.output)
            for _, count in ipairs({ '"endHooks":5', '"disposal":3', '"stdin":8', '"declarations":22' }) do
                assert.truthy(streams.output:find(count, 1, true), streams.output)
            end
            if engine == "chromium" then
                local undeclared = execute(info, engine, { fixture.root .. "/" .. kinds, "--",
                    "stdin", "stdout", "stderr" })
                assert.is_true(undeclared.ok, undeclared.output)
                for _, name in ipairs({ "stdin", "stdout", "stderr" }) do
                    assert.truthy(undeclared.output:find(name .. "=unknown", 1, true), undeclared.output)
                end
            end
        end
        local descriptors = fixture:run({ info.node.path, fixture.source .. "/runner-kinds.mjs",
            info.sdk_root .. "/titan-browser-run.mjs", fixture.root, fixture.root .. "/" .. kinds },
            { TITAN_NODE = info.node.path, TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" })
        io.stdout:write(string.format("\nRUNNER-KINDS\n%s\n", descriptors.output))
        io.stdout:flush()
        assert.is_true(descriptors.ok, descriptors.output)
        assert.truthy(descriptors.output:find('RUNNER-KINDS {"verdict":"PASS","cases":3}', 1, true),
            descriptors.output)
    end)

    it("checks embedding OS streams", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        copy_sources({ "support.mjs", "os-streams.mjs" })
        local image = build_image(info, "program", "os-streams",
            { "--tree", stdlib_tree, "os.browser_tests" })
        for _, engine in ipairs({ "node", "chromium" }) do
            -- A half-hour offset without daylight saving time: %z and %Z
            -- must render the host's offset, never UTC.
            local result = execute(info, engine,
                { "--js-test", fixture.source .. "/os-streams.mjs", "--", image }, "Asia/Kolkata")
            io.stdout:write(string.format("\nOS-STREAMS engine=%s\n%s\n", engine, result.output))
            io.stdout:flush()
            assert.is_true(result.ok, result.output)
            assert(checks.require_evidence(checks.status_inventory, result.output,
                { ["os.browser_tests"] = true }))
            assert.truthy(result.output:find('OS-STREAMS {"verdict":"PASS","cases":78,"dialogs":0',
                1, true), result.output)
            assert.truthy(result.output:find('"calendar-zone-titan-and-stock"', 1, true), result.output)
        end
    end)

    it("drives main as the async bootstrap Task", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        copy_sources({ "support.mjs", "bootstrap.mjs" })
        local image = build_bootstrap(info)
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, { "--js-test", fixture.source .. "/bootstrap.mjs", "--", image })
            assert.is_true(result.ok, result.output)
            assert.truthy(result.output:find('BOOTSTRAP {"verdict":"PASS"}', 1, true), result.output)
            -- The runner exits with the status of every run() result.
            for _, case in ipairs({ { "return", 3 }, { "fail", 1 }, { "cancel", 1 }, { "exit", 7 },
                    { "fail-exit", 7 } }) do
                local ran = execute(info, engine, { fixture.root .. "/" .. image, "--", case[1] })
                assert.equal(case[2], ran.status, ran.output)
            end
        end
    end)
end)

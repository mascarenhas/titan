local assert = require "luassert"
local lfs = require "lfs"
local browserlink = require "titan-compiler.browserlink"
local files = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local repository = assert(lfs.currentdir())
local source = repository .. "/spec/fixtures/browser_scheduler"
local stdlib_tree = repository .. "/spec/stdlib/titan"
local fixture

-- The mini driver drives titan.browser's drive interface without async; the
-- async browser backend's own scheduler cases build on the same loader.
local function build(info, assertions)
    local output = fixture.output .. "/assertions-" .. assertions
    files.mkdir(output)
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() .. string.format(
            ";require('titan-compiler.driver').browser_link_options={purpose='program',assertions=%d};",
            assertions)
    local result = fixture:run({ info.prefix .. "/bin/lua", "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--no-uv-bootstrap",
        "--tree", source, "--output", output, "--exe", output .. "/mini-driver.mjs",
        "--c-source", source .. "/mini_driver.c", "mini_driver" },
        { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    return output, "out/assertions-" .. assertions .. "/mini-driver.mjs"
end

-- Builds out/<name>-<assertions>/<name>.mjs with the frontend under coverage.
local function build_image(info, assertions, purpose, name, arguments)
    local output = fixture.output .. "/" .. name .. "-" .. assertions
    files.mkdir(output)
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() .. string.format(
            ";require('titan-compiler.driver').browser_link_options={purpose=%q,assertions=%d};",
            purpose, assertions)
    local argv = { info.prefix .. "/bin/lua", "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--output", output, "--exe", output .. "/" .. name .. ".mjs" }
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    local result = fixture:run(argv, { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    return "out/" .. name .. "-" .. assertions .. "/" .. name .. ".mjs"
end

-- The async scheduler owner (spec/stdlib/titan/async/browser_tests) is a
-- browser-only test owner of the stdlib tree; its child states come from
-- scheduler_child.c.
local function build_scheduler(info, assertions)
    return build_image(info, assertions, "test", "scheduler", { "--no-uv-bootstrap", "--test",
        "--tree", stdlib_tree, "--c-source", source .. "/scheduler_child.c", "async.browser_tests" })
end

-- bootstrap.titan keeps the async bootstrap: its main runs as a Task.
local function build_bootstrap(info, assertions)
    return build_image(info, assertions, "program", "bootstrap", { "--tree", source, "bootstrap" })
end

local function execute(info, engine, argv)
    local command = { info.sdk_root .. "/titan-browser-run", "--engine", engine,
        "--timeout", "120000", "--grace", "1500", "--root", fixture.root }
    for _, item in ipairs(argv) do command[#command + 1] = item end
    return fixture:run(command, { TITAN_NODE = info.node.path, TITAN_CHROME = info.chrome.path,
        TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" })
end

describe("browser drive interface", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    for _, assertions in ipairs({ 2, 0 }) do
        it("relinquishes, delivers, admits, disposes and exits a mini driver with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
            if not info then pending(why) return end
            fixture = files.new()
            for _, name in ipairs({ "support.mjs", "mini-driver.mjs", "mini-driver-abort.mjs", "admission.mjs" }) do
                files.copy(source .. "/" .. name, fixture.source .. "/" .. name)
            end
            local output, image = build(info, assertions)
            local inventory = assert(browserlink.image_inventory(files.read(output .. "/mini-driver.wasm")))
            local suspending = false
            for _, import in ipairs(inventory.imports) do
                if import.name == "titan_browser_relinquish" then suspending = true end
            end
            assert.is_true(suspending, "the bridge image does not import the driver's relinquish")
            for _, engine in ipairs({ "node", "chromium" }) do
                local result = execute(info, engine, { "--js-test", fixture.source .. "/mini-driver.mjs", "--", image })
                io.stdout:write(string.format("\nMINI-DRIVER assertions=%d engine=%s node=%s chrome=%s\n%s\n",
                    assertions, engine, info.node.version, info.chrome.version, result.output))
                io.stdout:flush()
                assert.is_true(result.ok, result.output)
                assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
                assert.truthy(result.output:find('"disposal":{"parked":[2],"cleanup":[2,2],' ..
                    '"orphaned":[2,1],"shutdown":[2,2]}', 1, true), result.output)
                -- Design 4.2's admission matrix, including the synchronous C
                -- callback rows; the suite asserts every row's outcome.
                local admitted = execute(info, engine, { "--js-test", fixture.source .. "/admission.mjs", "--", image })
                io.stdout:write(string.format("\nADMISSION assertions=%d engine=%s\n%s\n",
                    assertions, engine, admitted.output))
                io.stdout:flush()
                assert.is_true(admitted.ok, admitted.output)
                assert.truthy(admitted.output:find('"verdict":"PASS"', 1, true), admitted.output)
                assert.truthy(admitted.output:find('"callbacks":{"drive: from a parked wait":"ran",', 1, true),
                    admitted.output)
                local aborted = execute(info, engine, { "--js-test", fixture.source .. "/mini-driver-abort.mjs",
                    "--", image })
                assert.equal(70, aborted.status, aborted.output)
                assert.truthy(aborted.output:find("mini-driver-abort-complete", 1, true), aborted.output)
                assert.truthy(aborted.output:find("stack overflow", 1, true), aborted.output)
                -- The runner reports an exited program with status & 255.
                for _, case in ipairs({ { "exit", 3 }, { "return", 7 }, { "exit-fail", 1 } }) do
                    local ran = execute(info, engine, { fixture.root .. "/" .. image, "--", case[1] })
                    assert.equal(case[2], ran.status, ran.output)
                end
            end
        end)
    end

    for _, assertions in ipairs({ 2, 0 }) do
        it("runs the async scheduler gate, disposal, exit and ownership with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
            if not info then pending(why) return end
            fixture = files.new()
            for _, name in ipairs({ "support.mjs", "scheduler.mjs" }) do
                files.copy(source .. "/" .. name, fixture.source .. "/" .. name)
            end
            local image = build_scheduler(info, assertions)
            for _, engine in ipairs({ "node", "chromium" }) do
                local result = execute(info, engine, { "--js-test", fixture.source .. "/scheduler.mjs", "--", image })
                io.stdout:write(string.format("\nSCHEDULER assertions=%d engine=%s node=%s chrome=%s\n%s\n",
                    assertions, engine, info.node.version, info.chrome.version, result.output))
                io.stdout:flush()
                assert.is_true(result.ok, result.output)
                assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
                assert.truthy(result.output:find('"gate":16', 1, true), result.output)
                assert.truthy(result.output:find('"crowd":2000', 1, true), result.output)
            end
        end)
    end

    for _, assertions in ipairs({ 2, 0 }) do
        it("drives main as the async bootstrap Task with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
            if not info then pending(why) return end
            fixture = files.new()
            for _, name in ipairs({ "support.mjs", "bootstrap.mjs" }) do
                files.copy(source .. "/" .. name, fixture.source .. "/" .. name)
            end
            local image = build_bootstrap(info, assertions)
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
    end
end)

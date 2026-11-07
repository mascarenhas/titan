local assert = require "luassert"
local lfs = require "lfs"
local files = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local repository = assert(lfs.currentdir())
local fixture

local function build(info, assertions, tree, module, name, is_test, c_source)
    local output = fixture.output .. "/assertions-" .. assertions
    files.mkdir(output)
    -- The ordinary fixture collector instruments the copied compiler child;
    -- profile injection uses the existing driver option, not a new
    -- command-line/environment configuration surface.
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() .. string.format(
            ";require('titan-compiler.driver').browser_link_options={purpose=%q,assertions=%d};",
            is_test and "test" or "program", assertions)
    local image = output .. "/" .. name .. ".mjs"
    local argv = { info.prefix .. "/bin/lua", "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--no-uv-bootstrap",
        "--tree", tree, "--output", output, "--exe", image }
    if c_source then
        -- Keep this separate from the image root until its target marker exists.
        local headers = fixture.output .. "/foreign-headers-" .. assertions
        local interface = fixture:run({info.prefix .. "/bin/lua", "-E", "-e", init,
            fixture.frontend .. "/titanc", "-q", "--target", "browser", "--incremental",
            "--tree", repository, "--output", headers, "-c", "titan.browser"},
            { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
        fixture.collector:collect()
        assert.is_true(interface.ok, interface.output)
        argv[#argv + 1] = "-I"
        argv[#argv + 1] = headers
        argv[#argv + 1] = "--c-source"
        argv[#argv + 1] = c_source
        argv[#argv + 1] = "--ldflag=-Wl,--wrap=titan_browser_host_identity_live"
    end
    if is_test then argv[#argv + 1] = "--test" end
    argv[#argv + 1] = module
    local result = fixture:run(argv, { TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.map" }) do
        assert.equal("file", lfs.attributes(output .. "/" .. name .. suffix, "mode"))
    end
    return "out/assertions-" .. assertions .. "/" .. name .. ".mjs"
end

local function execute(info, engine, script, images)
    local argv = { info.sdk_root .. "/titan-browser-run", "--engine", engine,
        "--timeout", "120000", "--grace", "1500", "--root", fixture.root,
        "--js-test", fixture.source .. "/" .. script, "--" }
    for _, image in ipairs(images) do argv[#argv + 1] = image end
    return fixture:run(argv, { TITAN_NODE = info.node.path, TITAN_CHROME = info.chrome.path,
        TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" })
end

describe("persistent core JavaScript bridge", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    for _, assertions in ipairs({ 2, 0 }) do
        it("executes real native owners, queue/retirement and BrowserValue marshalling with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
            if not info then pending(why) return end
            fixture = files.new()
            for _, name in ipairs({ "bindings.mjs", "integration.mjs", "unhandled.mjs",
                    "unhandled-result.mjs", "poison-retirement.mjs" }) do
                files.copy(repository .. "/spec/fixtures/browser_bridge/" .. name, fixture.source .. "/" .. name)
            end
            local native = build(info, assertions, repository .. "/spec/stdlib/titan", "browser.tests", "bridge", true,
                repository .. "/spec/fixtures/browser_bridge/independent_states.c")
            local failure = build(info, assertions, repository .. "/spec/fixtures/browser_bridge",
                "initializer_failure", "initializer-failure", false)
            for _, engine in ipairs({ "node", "chromium" }) do
                local result = execute(info, engine, "integration.mjs", { native, failure })
                io.stdout:write(string.format("\nBRIDGE assertions=%d engine=%s node=%s chrome=%s\n%s\n",
                    assertions, engine, info.node.version, info.chrome.version, result.output))
                io.stdout:flush()
                assert.is_true(result.ok, result.output)
                assert.truthy(result.output:find('"verdict":"PASS"', 1, true), result.output)
                assert.truthy(result.output:find('"maximumInflight":1', 1, true), result.output)
                assert.truthy(result.output:find('"finalizerDrains":2', 1, true), result.output)
                for _, negative in ipairs({
                    { "unhandled.mjs", 74, "bridge unhandled opaque promise" },
                    { "unhandled-result.mjs", 74, "bridge unhandled reverse result" },
                    { "poison-retirement.mjs", 70, "poison-retirement-complete" },
                }) do
                    local failed = execute(info, engine, negative[1], { native })
                    assert.is_false(failed.ok, failed.output)
                    assert.equal(negative[2], failed.status, failed.output)
                    assert.truthy(failed.output:find(negative[3], 1, true), failed.output)
                end
            end
        end)
    end
end)

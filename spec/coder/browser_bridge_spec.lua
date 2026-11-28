local assert = require "luassert"
local lfs = require "lfs"
local files = require "spec.fixtures.target_selection.support"
local toolchain = require "spec.support.browser_toolchain"
local repository = toolchain.repository
local fixture

local function build(info, tree, module, name, is_test, c_source, wrap, cppflags)
    local output = fixture.output .. "/images"
    files.mkdir(output)
    -- The ordinary fixture collector instruments the copied compiler child;
    -- profile injection uses the existing driver option, not a new
    -- command-line/environment configuration surface.
    local init = string.format("package.path=%q..package.path; ",
        fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;") ..
        fixture.collector:init_code() .. string.format(
            ";require('titan-compiler.driver').browser_link_options={purpose=%q};",
            is_test and "test" or "program")
    local image = output .. "/" .. name .. ".mjs"
    local argv = { info.lua, "-E", "-e", init, fixture.frontend .. "/titanc",
        "-q", "--target", "browser", "--incremental", "--no-uv-bootstrap",
        "--tree", tree, "--output", output, "--exe", image }
    if c_source then
        argv[#argv + 1] = "--c-source"
        argv[#argv + 1] = c_source
    end
    if wrap then
        argv[#argv + 1] = "--ldflag=-Wl,--wrap=titan_browser_host_identity_live," ..
            "--wrap=titan_browser_host_state_closed,--wrap=malloc"
    end
    if is_test then argv[#argv + 1] = "--test" end
    argv[#argv + 1] = module
    local result = fixture:run(argv, { TITAN_EXTRA_CPPFLAGS = cppflags or "",
        TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "", TITAN_PATH_0_6 = "" })
    fixture.collector:collect()
    assert.is_true(result.ok, result.output)
    for _, suffix in ipairs({ ".mjs", ".wasm", ".wasm.map", ".wasm.trace" }) do
        assert.equal("file", lfs.attributes(output .. "/" .. name .. suffix, "mode"))
    end
    -- The independent-state helper includes the fixture controls; the click
    -- counter imports the page's click registration; the rest link no helper.
    -- The public-state owner imports titan.lua, which links the filesystem
    -- runtime (D14).
    local classes = c_source and { "entry", "fixture:controls" } or
        module == "counter" and { "entry", "fixture:click" } or { "entry" }
    if module == "browser.public_state_tests" then classes[#classes + 1] = "vfs" end
    toolchain.check_imports(image, classes)
    return "out/images/" .. name .. ".mjs"
end

-- The fixtures' host imports, beneath the root where the runner loads them.
local function copy_imports()
    files.copy(repository .. "/spec/fixtures/browser_runtime/fixture-imports.mjs",
        fixture.source .. "/fixture-imports.mjs")
end

local function execute(info, engine, script, images)
    local argv = toolchain.runner(info, "--engine", engine,
        "--timeout", "120000", "--grace", "1500", "--root", fixture.root,
        "--imports", fixture.source .. "/fixture-imports.mjs",
        "--js-test", fixture.source .. "/" .. script, "--")
    for _, image in ipairs(images) do argv[#argv + 1] = image end
    return fixture:run(argv, { TITAN_NODE = info.node.path, TITAN_CHROME = info.chrome.path,
        TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "" })
end

describe("persistent core JavaScript bridge", function()
    after_each(function()
        if fixture then fixture:close(); fixture = nil end
    end)

    it("executes real native owners, queue/retirement and BrowserValue marshalling", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        for _, name in ipairs({ "bindings.mjs", "integration.mjs", "unhandled.mjs",
                "unhandled-result.mjs", "poison-retirement.mjs", "counter.mjs", "responsive.mjs" }) do
            files.copy(repository .. "/spec/fixtures/browser_bridge/" .. name, fixture.source .. "/" .. name)
        end
        copy_imports()
        local native = build(info, repository .. "/spec/stdlib/titan", "browser.tests", "bridge", true,
            repository .. "/spec/fixtures/browser_bridge/independent_states.c", true)
        local failure = build(info, repository .. "/spec/fixtures/browser_bridge",
            "initializer_failure", "initializer-failure", false)
        local public = build(info, repository .. "/spec/stdlib/titan",
            "browser.public_state_tests", "public-states", true,
            repository .. "/spec/fixtures/browser_bridge/independent_states.c", true)
        local counter = build(info, repository .. "/spec/fixtures/browser_bridge",
            "counter", "counter", false)
        local responsive = build(info, repository .. "/spec/fixtures/browser_bridge",
            "responsive", "responsive", false)
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, "integration.mjs", { native, failure, public })
            io.stdout:write(string.format("\nBRIDGE engine=%s node=%s chrome=%s\n%s\n",
                engine, info.node.version, info.chrome.version, result.output))
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
            if engine == "chromium" then
                -- Page tests: the click counter's synchronous C callbacks and
                -- the async driver's responsiveness (titan#334) need a page.
                for _, page in ipairs({ { "counter.mjs", counter, "COUNTER" },
                                        { "responsive.mjs", responsive, "RESPONSIVE" } }) do
                    local result = execute(info, engine, page[1], { page[2] })
                    io.stdout:write(string.format("\n%s engine=%s\n%s\n", page[3], engine, result.output))
                    io.stdout:flush()
                    assert.is_true(result.ok, result.output)
                    assert.truthy(result.output:find(page[3] .. ' {"verdict":"PASS"', 1, true), result.output)
                end
            end
        end
    end)

    it("copies portable values through real browser images", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        for _, name in ipairs({ "portable.mjs", "portable-peer.mjs" }) do
            files.copy(repository .. "/spec/fixtures/browser_bridge/" .. name, fixture.source .. "/" .. name)
        end
        copy_imports()
        files.copy(info.sdk_root .. "/titan-protobuf.mjs", fixture.source .. "/titan-protobuf.mjs")
        local native = build(info, repository .. "/spec/stdlib/titan",
            "browser.portable_tests", "portable", true)
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, "portable.mjs", { native })
            io.stdout:write(string.format("\nPORTABLE engine=%s\n%s\n", engine, result.output))
            io.stdout:flush()
            assert.is_true(result.ok, result.output)
            assert.truthy(result.output:find("PASS portable bridge", 1, true), result.output)
            assert.truthy(result.output:find("[  PASSED  ] 17 tests", 1, true), result.output)
        end
    end)

    it("provides exact libc environments", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        fixture = files.new()
        files.copy(repository .. "/spec/fixtures/browser_bridge/environment.mjs",
            fixture.source .. "/environment.mjs")
        copy_imports()
        local image = build(info, repository .. "/spec/fixtures/browser_bridge",
            "environment", "environment", false, nil, nil, "-D_GNU_SOURCE")
        for _, engine in ipairs({ "node", "chromium" }) do
            local result = execute(info, engine, "environment.mjs", { image })
            io.stdout:write(string.format("\nENVIRONMENT engine=%s node=%s chrome=%s\n%s\n",
                engine, info.node.version, info.chrome.version, result.output))
            io.stdout:flush()
            assert.is_true(result.ok, result.output)
            assert.truthy(result.output:find('ENVIRONMENT {"verdict":"PASS"', 1, true), result.output)
        end
    end)
end)

local assert = require "luassert"
local lfs = require "lfs"
local process = require "titan-compiler.process"
local linux = require("luv").os_uname().sysname == "Linux"
local toolchain = require "spec.support.browser_toolchain"
local checks = dofile("scripts/browser_stdlib.lua")
local repository = assert(lfs.currentdir())
local output = repository .. "/out/browser-net"

local function execute(argv, env, log)
    local result = process.capture(argv, {cwd = repository, env = env})
    local file = assert(io.open(output .. "/" .. log .. ".log", "wb"))
    assert(file:write(result.output or result.diagnostic or ""))
    assert(file:close())
    assert.is_true(result.ok, result.output or result.diagnostic)
    return result.output
end

describe("browser HTTP and WebSocket clients", function()
    it("uses real verified network peers with streaming, messages and abort ownership", function()
        local info, why = toolchain.require({node = true, chrome = true, sdk = true})
        if not info then pending(why) return end
        local env = {TITAN_ROOT = info.prefix, TITAN_NODE = info.node.path, TITAN_CHROME = info.chrome.path}
        -- The builder creates its output tree before invoking either compiler.
        local build = process.capture({info.prefix .. "/bin/lua", "-E", "spec/browser/build-net.lua", output},
            {cwd = repository, env = env})
        assert.is_true(build.ok, build.output or build.diagnostic)
        for _, engine in ipairs({"node", "chromium"}) do
            local result = execute({info.node.path, "spec/fixtures/browser_net/run.mjs",
                "--root", output, "--engine", engine, "--sdk", info.sdk_root,
                "--runner", info.sdk_root .. "/titan-browser-run.mjs", "--repository", repository}, env, engine)
            assert.matches('BROWSER%-NET {"verdict":"PASS","cases":67,"cancellation":%["headers","settled","metadata","body"%]', result)
            assert(checks.require_evidence(checks.status_inventory, result,
                { ["http.browser_tests"] = true, ["websocket.browser_tests"] = true }))
            assert.matches('"sameOrigin":' .. (engine == "node" and "0" or "1"), result, 1, true)
            assert.matches('"engine":"' .. engine .. '"', result, 1, true)
            if engine == "node" or linux then
                assert.matches('"verified":true', result, 1, true)
            end
        end
    end)
end)

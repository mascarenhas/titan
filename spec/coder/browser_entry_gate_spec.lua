local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local sha256 = require "titan-compiler.sha256"
local repository = assert(lfs.currentdir())
local fixture = repository .. "/spec/fixtures/browser_runtime"
local workspace

local function read(filename)
    local file = assert(io.open(filename, "rb"))
    local bytes = assert(file:read("a")); assert(file:close())
    return bytes
end

local function receipt(filename, label)
    local bytes = read(filename)
    io.stdout:write(string.format("GATE artifact=%s bytes=%d sha256=%s\n",
        label, #bytes, sha256.hex(bytes)))
end

local function run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.started and result.ok, result.output or result.diagnostic or ""
end

local function build(info, assertions, module, name, is_test, c_source)
    local output = workspace .. "/assertions-" .. assertions
    files.mkdir(output)
    local code = string.format("package.path=%q..package.path; " ..
        "require('titan-compiler.driver').browser_link_options={purpose='gate',assertions=%d};",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;", assertions)
    local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PATH_0_6=", "TITAN_PROBE_CACHE_DISABLE=1", "CCACHE_DISABLE=1",
        info.prefix .. "/bin/lua", "-E", "-e", code, repository .. "/titanc",
        "--target", "browser", "-q", "--incremental", "--no-uv-bootstrap",
        "--tree", fixture, "--output", output, "--exe", output .. "/" .. name .. ".mjs",
        "--c-source", fixture .. "/" .. (c_source or "gate.c") }
    if is_test then argv[#argv + 1] = "--test" end
    argv[#argv + 1] = module
    local ok, log = run(argv)
    assert.is_true(ok, log)
    assert.equal("file", lfs.attributes(output .. "/" .. name .. ".wasm", "mode"))
    -- gate.c and entry_lifetimes.c both include the fixture controls.
    toolchain.check_imports(output .. "/" .. name .. ".wasm", { "entry", "fixture:gate", "fixture:controls" })
end

describe("browser real runtime entry gate", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)

    for _, assertions in ipairs({ 2, 0 }) do
        it("proves all nine items and both real waits with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
            io.stdout:write(string.format("\nGATE tools emcc=6.0.13 node=%s chrome=%s\n",
                info.node.version, info.chrome.version))
            workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
            files.write(workspace .. "/entry-gate.mjs", read(fixture .. "/entry-gate.mjs"))
            files.write(workspace .. "/guard-regression.mjs",
                read(repository .. "/spec/fixtures/browser_loader/guard-regression.mjs"))
            build(info, assertions, "entry_gate", "gate", true)
            build(info, assertions, "final_fiber", "final-fiber", false)
            receipt(info.sdk_root .. "/sdk-digests", "sdk-digests")
            for _, name in ipairs({ "gate.mjs", "gate.wasm", "gate.wasm.map",
                    "final-fiber.mjs", "final-fiber.wasm", "final-fiber.wasm.map" }) do
                receipt(workspace .. "/assertions-" .. assertions .. "/" .. name, name)
            end
            for _, name in ipairs({ "entry_gate.titan", "final_fiber.titan", "gate.c", "gate.h", "entry-gate.mjs" }) do
                receipt(fixture .. "/" .. name, "fixture/" .. name)
            end
            -- Node is deliberately first; the exact same image pair then runs
            -- through the installed Chromium runner, not a research adapter.
            for _, engine in ipairs({ "node", "chromium" }) do
                local runner = info.sdk_root .. "/titan-browser-run"
                local ok, log = run({ runner, "--engine", engine, "--timeout", "120000",
                    "--grace", "1500", "--root", workspace, "--js-test", workspace .. "/entry-gate.mjs", "--",
                    "assertions-" .. assertions .. "/gate.mjs",
                    "assertions-" .. assertions .. "/final-fiber.mjs" })
                -- Print the complete per-item evidence even for failed lanes.
                io.stdout:write(string.format("\nGATE assertions=%d engine=%s\n%s\n", assertions, engine, log))
                io.stdout:flush()
                assert.is_true(ok, log)
                assert.truthy(log:find('"verdict":"PASS"', 1, true), log)
                assert.truthy(log:find('"items":9', 1, true), log)
                assert.truthy(log:find('"waits":', 1, true), log)
                local guard_ok, guard_log = run({ runner, "--engine", engine, "--timeout", "30000",
                    "--grace", "1500", "--root", workspace, "--js-test", workspace .. "/guard-regression.mjs", "--",
                    "assertions-" .. assertions .. "/gate.mjs" })
                io.stdout:write(string.format("\nGUARD regression assertions=%d engine=%s\n%s\n",
                    assertions, engine, guard_log))
                io.stdout:flush()
                assert.is_true(guard_ok, guard_log)
            end
        end)
        it("preserves real Titan contexts across C entry lifetimes with ASSERTIONS=" .. assertions, function()
            local info, why = toolchain.require({ node = true, chrome = true, sdk = true }); if not info then pending(why) return end
            workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
            files.write(workspace .. "/entry-lifetimes.mjs", read(fixture .. "/entry-lifetimes.mjs"))
            build(info, assertions, "entry_lifetimes", "entry-lifetimes", false, "entry_lifetimes.c")
            for _, engine in ipairs({ "node", "chromium" }) do
                local ok, log = run({ info.sdk_root .. "/titan-browser-run", "--engine", engine,
                    "--timeout", "30000", "--grace", "1500", "--root", workspace,
                    "--js-test", workspace .. "/entry-lifetimes.mjs", "--",
                    "assertions-" .. assertions .. "/entry-lifetimes.mjs" })
                io.stdout:write(string.format("\nENTRY LIFETIMES assertions=%d engine=%s\n%s\n",
                    assertions, engine, log))
                io.stdout:flush()
                assert.is_true(ok, log)
                assert.truthy(log:find('"entries":6', 1, true), log)
                assert.truthy(log:find('"allocationCleanup":2', 1, true), log)
                assert.truthy(log:find('"earlySinks":0', 1, true), log)
            end
        end)
    end
end)

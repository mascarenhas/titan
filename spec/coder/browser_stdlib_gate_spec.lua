local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local lfs = require "lfs"
local repository = assert(lfs.currentdir())
local fixture = repository .. "/spec/fixtures/browser_stdlib"
local checks = dofile("scripts/browser_stdlib.lua")
local modules = {}
for _, root in ipairs(assert(checks.browser_roots(compiler_io.new_sync(), repository .. "/Makefile"))) do
    modules[#modules + 1] = assert(root:match("^titan%.([%w_]+)$"), root)
end
local workspace

local function run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.started and result.ok, result.output or result.diagnostic or ""
end

local function build(info, module, options)
    local setup = string.format("package.path=%q..package.path; " ..
        "require('titan-compiler.driver').browser_link_options={purpose='test',assertions=2};",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;")
    local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PATH_0_6=", "TITAN_PROBE_CACHE_DISABLE=1",
        info.prefix .. "/bin/lua", "-E", "-e", setup, repository .. "/titanc",
        "--target", "browser", "-q", "--incremental", "--test",
        "--tree", fixture .. ";" .. repository .. "/spec/stdlib/titan",
        "--output", workspace .. "/images", "--exe", workspace .. "/images/" ..
            (options and options.name or module) .. ".mjs" }
    if not (options and options.bootstrap) then argv[#argv + 1] = "--no-uv-bootstrap" end
    if options and options.fidelity then
        argv[#argv + 1] = "--c-source"
        argv[#argv + 1] = repository .. "/spec/fixtures/browser_runtime/close.c"
    end
    argv[#argv + 1] = module
    local ok, log = run(argv)
    assert.is_true(ok, log)
end

describe("browser stdlib initialization and byte fidelity gate", function()
    after_each(function()
        if workspace then files.remove(workspace); workspace = nil end
    end)
    it("initializes each delivered module alone and together, and preserves binary failures after fibers", function()
        local info, why = toolchain.require({ node = true, chrome = true, sdk = true })
        if not info then pending(why) return end
        local started = os.time()
        workspace = temporary.name(); assert(os.remove(workspace)); files.mkdir(workspace)
        files.copy(fixture .. "/gate.mjs", workspace .. "/gate.mjs")
        for _, module in ipairs(modules) do build(info, "init_" .. module) end
        build(info, "init_subset")
        build(info, "init_lua_states")
        build(info, "init_async", { bootstrap = true, name = "init_async_bootstrap" })
        build(info, "fidelity_test", { fidelity = true })
        for _, engine in ipairs({ "node", "chromium" }) do
            local argv = { info.sdk_root .. "/titan-browser-run", "--engine", engine,
                "--timeout", "120000", "--grace", "1500", "--root", workspace,
                "--js-test", workspace .. "/gate.mjs", "--",
                tostring(#modules), "images/init_subset.mjs", "images/fidelity_test.mjs",
                "images/init_lua_states.mjs", "images/init_async_bootstrap.mjs" }
            for _, module in ipairs(modules) do argv[#argv + 1] = "images/init_" .. module .. ".mjs" end
            local ok, log = run(argv)
            io.stdout:write("\nSTDLIB GATE engine=" .. engine .. "\n" .. log .. "\n")
            io.stdout:flush()
            assert.is_true(ok, log)
            assert.truthy(log:find('"verdict":"PASS"', 1, true), log)
            assert.truthy(log:find('"subsetInitializeRunDisposeCycles":3', 1, true), log)
            assert.truthy(log:find('"independentStateRoots":' .. #modules, 1, true), log)
            assert.truthy(log:find('"asyncBootstrap":"enabled"', 1, true), log)
        end
        io.stdout:write(string.format("STDLIB GATE wall-seconds=%d images=%d engines=2\n",
            os.time() - started, #modules + 4))
        io.stdout:flush()
    end)
end)

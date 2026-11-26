local assert = require "luassert"
local toolchain = require "spec.support.browser_toolchain"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local repository = toolchain.repository
local fixture = repository .. "/spec/fixtures/browser_stdlib"
local checks = dofile("scripts/browser_stdlib.lua")
local modules = {}
for _, root in ipairs(assert(checks.browser_roots(compiler_io.new_sync()))) do
    modules[#modules + 1] = assert(root:match("^titan%.([%w_]+)$"), root)
end
local workspace

local function run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.started and result.ok, result.output or result.diagnostic or ""
end

local function image(name)
    return "images/" .. name .. "/" .. name .. ".mjs"
end

local function build_command(info, module, options)
    local setup = string.format("package.path=%q..package.path; " ..
        "require('titan-compiler.driver').browser_link_options={purpose='test'};",
        repository .. "/?.lua;" .. repository .. "/?/init.lua;")
    local name = options and options.name or module
    local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PATH_0_6=", "TITAN_PROBE_CACHE_DISABLE=1", "TITAN_JOBS=1",
        info.lua, "-E", "-e", setup, repository .. "/titanc",
        "--target", "browser", "-q", "--incremental", "--test",
        "--tree", fixture .. ";" .. repository .. "/spec/stdlib/titan",
        "--output", workspace .. "/images/" .. name, "--exe", workspace .. "/" .. image(name) }
    if not (options and options.bootstrap) then argv[#argv + 1] = "--no-uv-bootstrap" end
    if options and options.fidelity then
        argv[#argv + 1] = "--c-source"
        argv[#argv + 1] = repository .. "/spec/fixtures/browser_runtime/close.c"
    end
    argv[#argv + 1] = module
    return argv
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
        files.mkdir(workspace .. "/images")
        files.copy(fixture .. "/gate.mjs", workspace .. "/gate.mjs")
        -- Each initializer must remain a separate image. Multiple --test roots
        -- would combine them into one runner, so batch independent output trees
        -- instead, with at most two single-slot compiler children.
        local commands = {}
        for _, module in ipairs(modules) do
            commands[#commands + 1] = build_command(info, "init_" .. module)
        end
        commands[#commands + 1] = build_command(info, "init_subset")
        commands[#commands + 1] = build_command(info, "init_lua_states")
        commands[#commands + 1] = build_command(info, "init_async",
            { bootstrap = true, name = "init_async_bootstrap" })
        commands[#commands + 1] = build_command(info, "fidelity_test", { fidelity = true })
        local results = compiler_io.new_sync():run_batch(commands, { jobs = 2 })
        for _, result in ipairs(results) do
            assert.is_true(result.started and result.ok, result.output or result.diagnostic)
        end
        local names = { "init_subset", "init_lua_states", "init_async_bootstrap", "fidelity_test" }
        for _, module in ipairs(modules) do names[#names + 1] = "init_" .. module end
        for _, name in ipairs(names) do toolchain.check_imports(workspace .. "/" .. image(name), { "entry" }) end
        for _, engine in ipairs({ "node", "chromium" }) do
            local argv = toolchain.runner(info, "--engine", engine,
                "--timeout", "120000", "--grace", "1500", "--root", workspace,
                "--js-test", workspace .. "/gate.mjs", "--",
                tostring(#modules), image("init_subset"), image("fidelity_test"),
                image("init_lua_states"), image("init_async_bootstrap"))
            for _, module in ipairs(modules) do argv[#argv + 1] = image("init_" .. module) end
            local ok, log = run(argv)
            io.stdout:write("\nSTDLIB GATE engine=" .. engine .. "\n" .. log .. "\n")
            io.stdout:flush()
            assert.is_true(ok, log)
            assert.truthy(log:find('"verdict":"PASS"', 1, true), log)
            assert.truthy(log:find('"subsetInitializeRunDisposeCycles":3', 1, true), log)
            assert.truthy(log:find('"independentStateRoots":' .. #modules, 1, true), log)
            assert.truthy(log:find('"bootstrapLinkedInitializer":"' .. image("init_async_bootstrap") .. '"',
                1, true), log)
        end
        io.stdout:write(string.format("STDLIB GATE wall-seconds=%d images=%d engines=2\n",
            os.time() - started, #modules + 4))
        io.stdout:flush()
    end)
end)

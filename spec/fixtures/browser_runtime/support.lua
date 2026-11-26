local assert = require "luassert"
local compiler_io = require "titan-compiler.io"
local files = require "spec.fixtures.target_selection.support"
local temporary = require "spec.support.temporary"
local toolchain = require "spec.support.browser_toolchain"
local M = {}
M.repository = toolchain.repository
M.fixture = M.repository .. "/spec/fixtures/browser_runtime"

function M.workspace()
    local root = temporary.name(); assert(os.remove(root)); files.mkdir(root)
    return root
end

function M.run(argv)
    local result = compiler_io.new_sync():run(argv, { stderr_to_stdout = true })
    return result.started and result.ok, result.output or result.diagnostic or "", result.status
end

function M.cli(info, root, options, arguments)
    local serialized = require("inspect")(options)
    local code = string.format("package.path=%q..package.path; " ..
        "require('titan-compiler.driver').browser_link_options=%s;",
        M.repository .. "/?.lua;" .. M.repository .. "/?/init.lua;", serialized)
    local argv = { "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PATH_0_6=", "TITAN_PROBE_CACHE_DISABLE=1", "CCACHE_DISABLE=1",
        info.lua, "-E", "-e", code, M.repository .. "/titanc",
        "--target", "browser", "-q", "--incremental", "--no-uv-bootstrap",
        "--tree", M.fixture .. ";" .. M.repository .. "/spec/stdlib/titan",
        "--output", root }
    for _, argument in ipairs(arguments) do argv[#argv + 1] = argument end
    return M.run(argv)
end

-- Copies the fixtures' host imports (fixture-imports.mjs) beneath `root`,
-- where the runner loads them, and returns the copy's path.
function M.fixture_imports(root)
    local copy = root .. "/fixture-imports.mjs"
    local input = assert(io.open(M.fixture .. "/fixture-imports.mjs", "rb"))
    local bytes = assert(input:read("a")); assert(input:close())
    files.write(copy, bytes)
    return copy
end

-- Runs an image directly; `imports` names the --imports module of an image
-- whose C sources import host functions.
function M.image(info, root, engine, name, arguments, timeout, imports)
    local argv = toolchain.runner(info, "--engine", engine, "--timeout", tostring(timeout or 30000),
        "--grace", "1500", "--root", root)
    if imports then
        argv[#argv + 1] = "--imports"
        argv[#argv + 1] = imports
    end
    argv[#argv + 1] = root .. "/" .. name .. ".mjs"
    argv[#argv + 1] = "--"
    for _, argument in ipairs(arguments or {}) do argv[#argv + 1] = argument end
    local ok, log, status = M.run(argv)
    io.stdout:write("\nRUNTIME engine=" .. engine .. " image=" .. name .. "\n" .. log .. "\n")
    io.stdout:flush()
    return ok, log, status
end

function M.count(log, count)
    assert.truthy(log:find("[==========] " .. count .. " test" .. (count == 1 and "" or "s") .. " ran.", 1, true), log)
    assert.truthy(log:find("[  PASSED  ] " .. count .. " test" .. (count == 1 and "" or "s") .. ".", 1, true), log)
end

M.files = files

function M.c_image(info, root, name, source, options)
    local worker = "#define main minicoro_fixture_main\n" .. source ..
        "\n#undef main\nstatic int titan_browser_worker(lua_State *L) {\n" ..
        "lua_pushinteger(L, minicoro_fixture_main()); return 1;\n}\n"
    local code = string.format([[
package.path=%q..package.path
local driver = require "titan-compiler.driver"
driver.TITAN_ROOT = %q
driver.INSTALL_PATHS = driver.installed_paths(driver.TITAN_ROOT)
driver.apply_native_inputs({compile_argv={%q},link_argv={}})
driver.browser_link_options = %s
local context = driver.new_resolver_context({target="browser",output_root=%q})
assert(driver.configure_foreign_c(context))
assert(driver.context_target_descriptor(context))
local contents = driver.browser_c_image_contents(%q, {program_name=%q})
local ok, why, status = driver.compile_browser_image(contents, %q, %q,
    {}, {}, {}, false, {context=context,profile=driver.browser_link_options})
assert(ok, tostring(why)..":"..tostring(status))
assert(driver.close_resolver_context(context))
]], M.repository .. "/?.lua;" .. M.repository .. "/?/init.lua;", info.prefix,
        "-I" .. M.repository, require("inspect")(options), root, worker, name,
        root .. "/" .. name .. ".c", root .. "/" .. name .. ".mjs")
    local script = root .. "/" .. name .. "-build.lua"
    files.write(script, code)
    return M.run({ "env", "TITAN_ROOT=" .. info.prefix, "TITAN_TARGET=",
        "TITAN_EXTRA_CPPFLAGS=", "TITAN_EXTRA_CFLAGS=", "TITAN_EXTRA_LDFLAGS=",
        "TITAN_PATH_0_6=", info.lua, "-E", script })
end
return M

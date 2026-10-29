-- Run with the checkout compiler and its Lua dependencies; emits only C/resource
-- test inputs. The resulting files are compiled and run on native Windows.
local driver = require "titan-compiler.driver"
local platform = require "titan-compiler.platform"
local util = require "titan-compiler.util"
local output = assert(arg[1], "expected an existing output directory")
local manifest = assert(arg[2], "expected an absolute native Windows manifest path")
local original = platform.windows
platform.windows = true
local default = assert(driver.windows_program_paths("fixture.launcher"))
-- An exact --exe path below bin keeps the bin/+lib/titan/0.6 layout, so both
-- the embedded provider and the launcher's dependency lookup stay on the
-- approved runtime roots while exercising an unrelated launcher name.
local override = assert(driver.windows_program_paths("fixture.launcher", "bin/custom"))
assert(default.provider == override.provider)
local function write(name, contents)
    -- Bash gates read these inputs with mapfile, so never let a text-mode
    -- handle translate newlines on Windows.
    assert(util.set_file_contents(output .. "/" .. name, contents, "wb"))
end
write("launcher.c", driver.entrypoint_contents("fixture.launcher", nil,
    { provider = default.relative_provider }))
write("custom.c", driver.entrypoint_contents("fixture.launcher", nil,
    { provider = override.relative_provider }))
write("direct.c", driver.entrypoint_contents("fixture.launcher", nil,
    { provider = default.relative_provider, no_uv_bootstrap = true }))
local definition, export_names = driver.windows_provider_exports({ "fixture.launcher" })
write("launcher.def", definition)
write("launcher.exports.txt", table.concat(export_names, "\n") .. "\n")
write("launcher.manifest", driver.windows_launcher_manifest())
write("launcher.rc", driver.windows_launcher_resource(manifest))
-- A real titanc Windows program/provider link consumes exactly
-- driver.installed_link_inputs: the installed runtime, backtrace and Lua
-- archives plus its system flag. Emit that complete list; the gate replaces
-- the installed runtime with the freshly built archive under test.
local root = platform.getenv("TITAN_ROOT")
if root == "" then root = nil end
root = root or driver.TITAN_ROOT
local installed = assert(root and root ~= "" and driver.installed_paths(root),
    "generate the launcher fixture with TITAN_ROOT naming the installation")
write("runtime-libraries.txt",
    table.concat(driver.installed_link_inputs(installed, false), "\n") .. "\n")
-- The explicit --exe path carries native separators; the gate compares plan
-- entries with '/' spellings, so normalize every entry at this boundary.
local function plan_path(value) return (value:gsub("\\", "/")) end
write("plan.txt", plan_path(default.executable) .. "\n" ..
    plan_path(override.executable) .. "\n" ..
    plan_path(default.provider) .. "\n")
platform.windows = original

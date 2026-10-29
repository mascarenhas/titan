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
local override = assert(driver.windows_program_paths("fixture.launcher", "custom"))
assert(default.provider == override.provider)
local function write(name, contents)
    -- Bash gates read these inputs with mapfile, so never let a text-mode
    -- handle translate newlines on Windows.
    assert(util.set_file_contents(output .. "/" .. name, contents, "wb"))
end
write("launcher.c", driver.entrypoint_contents("fixture.launcher", nil,
    { provider = default.relative_provider }))
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
write("plan.txt", default.executable .. "\n" .. override.executable .. "\n" ..
    default.provider .. "\n")
platform.windows = original

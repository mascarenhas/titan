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
local runtime = driver.installed_link_inputs({
    libtitan = "runtime", libbacktrace = "backtrace", liblua = "lua" })
write("system-libraries.txt", table.concat(runtime, "\n", 4) .. "\n")
write("plan.txt", default.executable .. "\n" .. override.executable .. "\n" ..
    default.provider .. "\n")
platform.windows = original

-- Build the browser records programs (spec/fixtures/browser_records) for
-- collect.mjs with the installation's titanc, in the installation's profile.
-- Run it with Emscripten active and the installation's PREFIX.
local lfs = require "lfs"
local process = require "titan-compiler.process"
local path = require "titan-compiler.path"
local repository = assert(lfs.currentdir())
local output = assert(arg[1], "usage: lua -E spec/browser/build-records.lua OUTPUT")
assert(not arg[2], "build-records.lua accepts exactly one output directory")
if not path.is_absolute(output) then output = path.join(repository, output) end
local prefix = assert(os.getenv("TITAN_ROOT") or os.getenv("PREFIX"), "TITAN_ROOT or PREFIX is required")
-- Images use only reviewed imports (scripts/browser_imports.lua).
local checks = dofile(path.join(repository, "scripts/browser_stdlib.lua"))
local strategy = require("titan-compiler.io").new_sync()

-- One program per build: each has its own main.
for _, program in ipairs({ "records", "stack" }) do
  local build = process.capture({ path.join(prefix, "bin/titanc"), "-q", "--target", "browser",
    "--tree", path.join(repository, "spec/fixtures/browser_records"), "--output", output, program },
    { cwd = repository, env = {
      TITAN_ROOT = prefix, TITAN_TARGET = "", TITAN_EXTRA_CPPFLAGS = "", TITAN_EXTRA_CFLAGS = "",
      TITAN_EXTRA_LDFLAGS = "",
    } })
  assert(build.ok, build.output or build.diagnostic)
  assert(checks.check_file_imports(strategy, path.join(output, program .. ".mjs"), { "entry" }))
end
io.stdout:write("BROWSER-RECORDS-BUILD " .. output .. "\n")

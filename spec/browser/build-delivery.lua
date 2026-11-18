-- Build the browser chapter's complete application exactly as its section
-- documents, plus the documented http-dev-server, for the hosted deployment
-- test (spec/fixtures/browser_delivery/hosted.mjs) and the Node run
-- (dod.test.mjs). Run it with Emscripten active and the installation's
-- PREFIX; the build uses the profile that the installation's browser SDK
-- recorded, whatever TITAN_BUILD_PROFILE the caller's environment holds.
-- With --built, the clean-checkout job's doc_check run has already run the
-- whole chapter in OUTPUT, and this only checks and stages what it built.
local lfs = require "lfs"
local process = require "titan-compiler.process"
local path = require "titan-compiler.path"
local repository = assert(lfs.currentdir())
local built = arg[1] == "--built"
local output = assert(arg[built and 2 or 1], "usage: lua -E spec/browser/build-delivery.lua [--built] OUTPUT")
assert(not arg[built and 3 or 2], "build-delivery.lua accepts exactly one output directory")
if not path.is_absolute(output) then output = path.join(repository, output) end
local prefix = assert(os.getenv("TITAN_ROOT") or os.getenv("PREFIX"), "TITAN_ROOT or PREFIX is required")
local doc_check = dofile(path.join(repository, "scripts/doc_check.lua"))
-- Images use only reviewed imports (scripts/browser_imports.lua).
local checks = dofile(path.join(repository, "scripts/browser_stdlib.lua"))
local strategy = require("titan-compiler.io").new_sync()

local function mkdir(directory)
  if lfs.attributes(directory, "mode") == "directory" then return end
  local parent = path.dirname(directory)
  if parent ~= directory then mkdir(parent) end
  assert(lfs.mkdir(directory))
end

local function read(file)
  local handle = assert(io.open(file, "rb"))
  local bytes = assert(handle:read("a"))
  assert(handle:close())
  return bytes
end

local function write(file, bytes)
  local handle = assert(io.open(file, "wb"))
  assert(handle:write(bytes))
  assert(handle:close())
end

local function json_string(text)
  return '"' .. text:gsub('[%c"\\]', function(character)
    return string.format("\\u%04x", character:byte())
  end) .. '"'
end

local profile = read(path.join(prefix, "lib/titan-browser/0.6/build-profile")):match("^(%a+)%s*$")
assert(profile == "production" or profile == "validation", "the SDK records no build profile")

-- The section's commands, verbatim, in the reader's shell: the installation
-- on PATH, PREFIX naming it, its profile, and no Titan overrides.
local chapter = "doc/language/browser-target.md"
local section = assert(doc_check.section(read(path.join(repository, chapter)), "A complete application"))
local plan = assert(doc_check.plan({ { name = chapter, text = section } },
  { workspace = output, source = repository }))
assert(plan.expectations.app and plan.expectations["app-errors"], chapter .. " lacks the application's expected output")
if built then
  -- The chapter's first page built the server and its own image beside the
  -- application.
  assert(lfs.attributes(path.join(output, "http-dev-server"), "mode") == "file", "no http-dev-server in " .. output)
  assert(checks.check_file_imports(strategy, path.join(output, "out/hello.mjs"), { "entry" }))
else
  mkdir(output)
  assert(doc_check.run(plan, {
    PATH = path.join(prefix, "bin") .. ":" .. assert(os.getenv("PATH")), PREFIX = prefix,
    TITAN_BUILD_PROFILE = profile,
    TITAN_ROOT = false, TITAN_TARGET = false, TITAN_PATH_0_6 = false, TITAN_PATH = false,
    TITAN_EXTRA_CPPFLAGS = false, TITAN_EXTRA_CFLAGS = false, TITAN_EXTRA_LDFLAGS = false,
  }))

  -- The documented server, built natively from the manual's source.
  local server = process.capture({ path.join(prefix, "bin/titanc"), "-q", "--incremental",
    "--tree", path.join(repository, "doc/language"), "--output", path.join(output, "native"),
    "--exe", path.join(output, "http-dev-server"), "http-dev-server" }, { cwd = repository, env = {
      TITAN_ROOT = prefix, TITAN_BUILD_PROFILE = profile, TITAN_TARGET = "", TITAN_EXTRA_CPPFLAGS = "",
      TITAN_EXTRA_CFLAGS = "", TITAN_EXTRA_LDFLAGS = "",
    } })
  assert(server.ok, server.output or server.diagnostic)
end
assert(checks.check_file_imports(strategy, path.join(output, "browser-app/out/app.mjs"), { "entry" }))

-- The Node run's module and the expectations it shares with the hosted test
-- sit at the root that titan-browser-run serves.
for _, name in ipairs({ "dod.test.mjs", "expectations.mjs" }) do
  write(path.join(output, name), read(path.join(repository, "spec/fixtures/browser_delivery", name)))
end
write(path.join(output, "delivery.json"), "{" .. table.concat({
  '"profile":' .. json_string(profile),
  '"site":' .. json_string("browser-app/site"),
  '"output":' .. json_string(plan.expectations.app),
  '"errors":' .. json_string(plan.expectations["app-errors"]),
}, ",") .. "}\n")
io.stdout:write("BROWSER-DELIVERY " .. output .. " profile=" .. profile .. "\n")

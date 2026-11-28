-- Build only: the real bridge suite is shared by Node and all page engines.
local lfs = require "lfs"
local process = require "titan-compiler.process"
local path = require "titan-compiler.path"
local repository = assert(lfs.currentdir())
local output = assert(arg[1], "usage: lua -E spec/browser/build-bridge.lua OUTPUT")
assert(not arg[2], "build-bridge.lua accepts exactly one output directory")
if not path.is_absolute(output) then output = path.join(repository, output) end
local prefix = assert(os.getenv("TITAN_ROOT") or os.getenv("PREFIX"), "TITAN_ROOT or PREFIX is required")
local fixture = path.join(repository, "spec/fixtures/browser_bridge")
local durable = path.join(repository, "spec/fixtures/browser_durable")
local profile = os.getenv("TITAN_BUILD_PROFILE") or "production"
assert(profile == "production" or profile == "validation",
  "TITAN_BUILD_PROFILE must be production or validation")
-- Each image uses only reviewed imports (scripts/browser_imports.lua) for the
-- fixtures it links.
local checks = dofile(path.join(repository, "scripts/browser_stdlib.lua"))
local strategy = require("titan-compiler.io").new_sync()

local function mkdir(directory)
  if lfs.attributes(directory, "mode") == "directory" then return end
  local parent = path.dirname(directory)
  if parent ~= directory and parent ~= "." then mkdir(parent) end
  assert(lfs.mkdir(directory))
end

local function read(file)
  local handle = assert(io.open(file, "rb"))
  local bytes = assert(handle:read("a"))
  assert(handle:close())
  return bytes
end

local function write(file, bytes)
  mkdir(path.dirname(file))
  local handle = assert(io.open(file, "wb"))
  assert(handle:write(bytes))
  assert(handle:close())
end

local root = path.join(output, "images")
mkdir(root)
local built = 0
for _, target in ipairs({
  {name="bridge", owner="browser.tests", testing=true,
    tree=path.join(repository, "spec/stdlib/titan"),
    source=path.join(fixture, "independent_states.c"), wrap=true, imports={"entry", "fixture:controls"}},
  {name="initializer-failure", owner="initializer_failure", tree=fixture, imports={"entry"}},
  -- integration.mjs's third image: public lua.new lifetimes, kept apart so the
  -- legacy bridge image stays without Lua's async owner driver. Importing
  -- titan.lua links the filesystem runtime (D14).
  {name="public-states", owner="browser.public_state_tests", testing=true,
    tree=path.join(repository, "spec/stdlib/titan"),
    source=path.join(fixture, "independent_states.c"), wrap=true, imports={"entry", "fixture:controls", "vfs"}},
  -- Page tests of their own images, which need a DOM: the click counter of
  -- synchronous callbacks and the async driver's responsiveness.
  {name="counter", owner="counter", tree=fixture, imports={"entry", "fixture:click"}},
  {name="responsive", owner="responsive", tree=fixture, imports={"entry"}},
  -- The real-browser durable storage gate (vfs-durable.test.mjs): its
  -- scenario program links the filesystem and SQLite runtime, and the
  -- stock-novfs control links none of it. Both run main in a Task.
  {name="durable", owner="durable", tree=durable, bootstrap=true, imports={"entry", "vfs", "sqlite3"}},
  {name="stock-novfs", owner="stock_novfs", tree=durable, bootstrap=true, imports={"entry"}},
}) do
  -- The installed compiler links each image with this installation's
  -- profile, exactly as the portable trace builder does. No mock runtime is
  -- linked.
  local image = path.join(root, target.name .. ".mjs")
  local argv = {prefix .. "/bin/titanc", "-q", "--incremental", "--target", "browser",
    "--tree", target.tree, "--output", path.join(root, "objects", target.name), "--exe", image}
  if not target.bootstrap then argv[#argv + 1] = "--no-uv-bootstrap" end
  if target.source then
    argv[#argv + 1] = "--c-source"
    argv[#argv + 1] = target.source
  end
  if target.wrap then
    -- The native fixture injects GC and C-heap failures and observes final
    -- state invalidation. The other images have no such helper and stay
    -- unwrapped.
    argv[#argv + 1] = "--ldflag=-Wl,--wrap=titan_browser_host_identity_live," ..
      "--wrap=titan_browser_host_state_closed,--wrap=malloc"
  end
  if target.testing then argv[#argv + 1] = "--test" end
  argv[#argv + 1] = target.owner
  local result = process.capture(argv, {env = {
    TITAN_ROOT=prefix, TITAN_TARGET="", TITAN_PATH_0_6="",
    TITAN_EXTRA_CPPFLAGS="", TITAN_EXTRA_CFLAGS="", TITAN_EXTRA_LDFLAGS="",
    CCACHE_DISABLE="1",
  }})
  io.stdout:write(result.output or result.diagnostic or ""); io.stdout:flush()
  assert(result.ok, "bridge fixture build failed: " .. image .. " (" .. tostring(result.status) .. ")")
  for _, suffix in ipairs({".mjs", ".wasm", ".wasm.map", ".wasm.trace"}) do
    local artifact = path.join(root, target.name .. suffix)
    assert(lfs.attributes(artifact, "mode") == "file", "missing built image asset " .. artifact)
  end
  assert(checks.check_file_imports(strategy, image, target.imports))
  io.stdout:write(string.format("BRIDGE-IMAGE profile=%s owner=%s image=%s imports=%s\n",
    profile, target.owner, image, table.concat(target.imports, ",")))
  built = built + 1
end

for _, name in ipairs({"bindings.mjs", "integration.mjs", "unhandled.mjs", "unhandled-result.mjs",
    "poison-retirement.mjs", "counter.mjs", "responsive.mjs"}) do
  write(path.join(output, name), read(path.join(fixture, name)))
end
-- The host imports of the fixtures' C sources, which the runner passes on.
write(path.join(output, "fixture-imports.mjs"),
  read(path.join(repository, "spec/fixtures/browser_runtime/fixture-imports.mjs")))
io.stdout:write(string.format("BRIDGE-GATE %s profile=%s images=%d\n", output, profile, built))

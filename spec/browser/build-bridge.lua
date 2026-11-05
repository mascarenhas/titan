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
local profile = os.getenv("TITAN_BUILD_PROFILE") or "production"
assert(profile == "production" or profile == "validation",
  "TITAN_BUILD_PROFILE must be production or validation")

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

for _, assertions in ipairs({2, 0}) do
  local root = path.join(output, "assertions-" .. assertions)
  mkdir(root)
  for _, target in ipairs({
    {name="bridge", owner="browser.tests", testing=true,
      tree=path.join(repository, "spec/stdlib/titan"),
      source=path.join(fixture, "independent_states.c")},
    {name="initializer-failure", owner="initializer_failure", tree=fixture},
  }) do
    -- Use the installed compiler and the existing assertion/profile controls,
    -- exactly as the portable trace builder does. No mock runtime is linked.
    local init = path.join(root, "profile-" .. target.name .. ".lua")
    write(init, string.format([[
package.path = %q .. ";" .. %q .. ";" .. package.path
require("titan-compiler.driver").browser_link_options = {purpose=%q, assertions=%d}
]], path.join(prefix, "share/lua/5.5/?.lua"), path.join(prefix, "share/lua/5.5/?/init.lua"),
      target.testing and "test" or "program", assertions))
    local image = path.join(root, target.name .. ".mjs")
    local argv = {prefix .. "/bin/titanc", "-q", "--incremental", "--target", "browser",
      "--no-uv-bootstrap", "--tree", target.tree,
      "--output", path.join(root, "objects", target.name), "--exe", image}
    if target.source then
      argv[#argv + 1] = "--c-source"
      argv[#argv + 1] = target.source
      -- The native fixture arms real publication/allocation and GC controls.
      -- Initializer-failure images have no C helper and stay unwrapped.
      argv[#argv + 1] = "--ldflag=-Wl,--wrap=luaL_ref"
      argv[#argv + 1] = "--ldflag=-Wl,--wrap=luaL_unref"
      argv[#argv + 1] = "--ldflag=-Wl,--wrap=lua_rawseti"
      argv[#argv + 1] = "--ldflag=-Wl,--wrap=lua_callk"
      argv[#argv + 1] = "--ldflag=-Wl,--wrap=luaL_checkstack"
    end
    if target.testing then argv[#argv + 1] = "--test" end
    argv[#argv + 1] = target.owner
    local result = process.capture(argv, {env = {
      TITAN_ROOT=prefix, TITAN_TARGET="", TITAN_PATH_0_6="",
      TITAN_EXTRA_CPPFLAGS="", TITAN_EXTRA_CFLAGS="", TITAN_EXTRA_LDFLAGS="",
      LUA_INIT_5_5="@" .. init, LUA_INIT="", CCACHE_DISABLE="1",
    }})
    io.stdout:write(result.output or result.diagnostic or ""); io.stdout:flush()
    assert(result.ok, "bridge fixture build failed: " .. image .. " (" .. tostring(result.status) .. ")")
    for _, suffix in ipairs({".mjs", ".wasm", ".wasm.map"}) do
      local artifact = path.join(root, target.name .. suffix)
      assert(lfs.attributes(artifact, "mode") == "file", "missing built image asset " .. artifact)
    end
    io.stdout:write(string.format("BRIDGE-IMAGE profile=%s assertions=%d owner=%s image=%s\n",
      profile, assertions, target.owner, image))
  end
end

for _, name in ipairs({"bindings.mjs", "integration.mjs", "unhandled.mjs", "unhandled-result.mjs",
    "poison-retirement.mjs"}) do
  write(path.join(output, name), read(path.join(fixture, name)))
end
io.stdout:write(string.format("BRIDGE-GATE %s profile=%s assertionModes=2 images=4\n", output, profile))

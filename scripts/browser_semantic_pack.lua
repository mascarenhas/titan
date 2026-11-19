-- Compiler-owned validation for the offline browser semantic pack producer.
-- The Python transport script verifies the exact input bytes against these
-- results before archiving them. Stdout is a fixed tab-separated receipt.
local prefix, profile, lua_commit, lua_path, lua_cpath = ...
assert(lua_cpath, "usage: browser_semantic_pack.lua PREFIX PROFILE LUA_COMMIT LUA_PATH LUA_CPATH")
package.path = lua_path
package.cpath = lua_cpath

local driver = require "titan-compiler.driver"
local target = require "titan-compiler.browsertarget"
local compiler_io = require "titan-compiler.io"
local incremental = require "titan-compiler.incremental"
local paths = require "titan-compiler.path"
local support = require "titan"
local util = require "titan-compiler.util"
local stdlib = dofile("scripts/browser_stdlib.lua")

local strategy = setmetatable({
    run = function() error("semantic pack validation must not start a subprocess", 0) end,
}, { __index = compiler_io.new_sync() })
local context = { io = strategy, cache_adapter = {
    sha256_binary = support._sha256_binary, sha256_stream = support._sha256_stream,
} }
local layout = assert(driver.installed_paths(prefix, "browser"))
local bytes = incremental.file_contents(context, paths.join(layout.titan_bin, "analysis-target"), 64 * 1024)
local semantic = assert(target.decode_analysis(context, bytes))
assert(semantic.build_profile == profile, "analysis-target: build profile does not match TITAN_BUILD_PROFILE")
assert(strategy:read_file(paths.join(layout.titan_bin, "build-profile"), 64) == profile .. "\n",
    "build-profile: missing or disagrees with analysis-target")
assert(semantic.lua.fork_revision == lua_commit, "analysis-target: Lua fork does not match the Titan gitlink")

local handle = assert(driver.browser_analysis_target(prefix, context))
local resolver = driver.new_resolver_context({ io = strategy, target = "browser", analysis_only = true,
    browser_analysis_target = handle, transient_caches = true })
local _, _, _, provider = driver.find_static_interface("", "titan.browser", resolver)
assert(provider and provider.archive == handle.provider_file, "titan.a: missing the browser module")
local roots = assert(stdlib.browser_roots(strategy))
table.sort(roots, util.bytewise_less)
assert(#roots == #provider.key_order, "titan.a: expected the full browser standard provider inventory")
for index, name in ipairs(roots) do
    assert(provider.key_order[index] == name, "titan.a: missing canonical browser provider module " .. name)
end
local absent = {}
for _, row in ipairs(stdlib.status_inventory.modules) do
    if row[2] == "absent" then absent[#absent + 1] = row[1] .. "\t" .. row.reason .. "\n" end
end
assert(incremental.file_contents(context, paths.join(layout.titan_bin, "absent-modules"), 64 * 1024) ==
    table.concat(absent), "absent-modules: does not match the canonical browser inventory")
assert(driver.close_resolver_context(resolver))

assert(incremental.load_sdk_digests(context, layout.sdk_digests))
local recorded = assert(context.incremental.sdk, "sdk-digests: missing or invalid final SDK manifest")
print(driver.TITAN_VERSION, driver.TITAN_LIBRARY_VERSION, driver.TITAN_ABI_VERSION,
    driver.LANGUAGE_SERVER_API_VERSION, semantic.emscripten_version, semantic.build_profile)
for _, asset in ipairs({ "absent-modules", "analysis-target", "titan.a" }) do
    local filename = paths.join(layout.titan_bin, asset)
    local physical = assert(strategy:realpath(filename))
    local row = assert(recorded.files[physical], "sdk-digests: missing record for " .. asset)
    local hash = asset == "titan.a" and semantic.provider_sha256 or incremental.file_digest(context, filename)
    assert(hash == row.digest, "sdk-digests: digest disagrees for " .. asset)
    print(asset, hash)
end

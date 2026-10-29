-- The Titan searcher cases whose fixtures import installed standard modules
-- (titan.async, titan.lua and titan.thread). Listed in
-- spec/support/ci_stdlib_compiler_test_files.txt, so CI runs this after the
-- full standard provider is installed; the compiler-only path and searcher
-- cases stay in multi_module_path_runtime_spec.lua, whose lane deliberately
-- builds no stdlib. Both specs share spec/support/multi_module_path.lua.
local assert = require "luassert"
local path = require "titan-compiler.path"
local platform = require "titan-compiler.platform"
local support = require "spec.support.multi_module_path"

local PREFIX = support.PREFIX
local SHARED_SUFFIX = support.SHARED_SUFFIX
local TITAN_PATH_KEY = support.TITAN_PATH_KEY
local temporary_workspace = support.temporary_workspace
local make_directory = support.make_directory
local write_file = support.write_file
local remove_tree = support.remove_tree
local assert_compiles = support.assert_compiles
local assert_runs = support.assert_runs
local item_source = support.item_source
local write_titanc_shim = support.write_titanc_shim
local probe_count = support.probe_count

describe("Titan searcher with the installed standard provider", function()
    local workspace
    -- Provider roots, each the output of one compilation.
    local exact_one, exact_two, statecheck
    local empty_sdk

    local function root(name) return support.root(workspace, name) end

    setup(function()
        workspace = temporary_workspace()
        exact_one = root("exact-one")
        exact_two = root("exact-two")
        statecheck = root("statecheck")
        empty_sdk = root("empty-sdk")
        for _, directory in ipairs({
            exact_one, exact_two, statecheck, empty_sdk,
        }) do
            make_directory(directory)
        end

        local source = root("src-one")
        write_file(path.join(source, "search/item.titan"), item_source(1))
        assert_compiles(exact_one, source, exact_one, "search.item")

        source = root("src-two")
        write_file(path.join(source, "search/item.titan"), item_source(2))
        assert_compiles(exact_two, source, exact_two, "search.item")

        source = root("src-statecheck")
        write_file(path.join(source, "statecheck.titan"), [[
local async = import "async"
local lua = import "lua"
local thread = import "thread"

local count_chunk = "return #package.searchers"

local function transferred_integer(result: async.TransferValue): integer
  case result
  when is_integer(number) then
    return number
  else
    raise "independent state did not return an integer"
  end
end

-- Searcher counts before and after loading the support module in an
-- independent state, and a Titan module that only its own path can find.
function independent(cpath: string): (integer, integer, integer)
  local state = lua.new()
  defer state:close()
  local before = transferred_integer(state:run(count_chunk))
  local after = transferred_integer(state:run(
    "package.cpath = ...; require('titan'); return #package.searchers",
    nil, async.TransferValue.is_string(cpath)))
  local origin = transferred_integer(state:run(
    "return require('search.item').origin()"))
  return before, after, origin
end

-- Run one chunk in a fresh independent state, which copies this state's
-- native preloads (with their descriptors) but no initialized module.
function in_new_state(chunk: string): integer
  local state = lua.new()
  defer state:close()
  return transferred_integer(state:run(chunk))
end

-- A thread child loads the support module without gaining a second Titan
-- searcher, then resolves a Titan module through its own Titan path.
function in_thread(cpath: string): integer
  local result = 0
  async.run<|nil, value|>(function (): nil
    local child = thread.spawn(function (): integer
      local before: value = lua.load(count_chunk)()
      lua.load("package.cpath = ...; require('titan')")(cpath)
      local after: value = lua.load(count_chunk)()
      if (before as integer) ~= (after as integer) then
        raise "loading the support module added a second Titan searcher"
      end
      local origin: value = lua.load("return require('search.item').origin()")()
      return origin as integer
    end)
    case child:join()
    when succeeded(origin) then
      result = origin
    when failed(failure) then
      failure:raise()
    else
      raise "searcher thread was cancelled"
    end
    return nil
  end)
  async.loop()
  return result
end
]])
        assert_compiles(statecheck, source, statecheck .. ";;", "statecheck")
    end)

    teardown(function()
        if workspace then remove_tree(workspace) end
    end)

    it("installs one searcher in each independent state and thread child",
       function()
        local log = root("states.log")
        local env = {}
        if not platform.windows then
            env[1] = "TITANC=" .. write_titanc_shim(root("shim-states"), log, empty_sdk)
        end
        assert_runs(workspace, {
            titan_path = statecheck .. ";" .. exact_one .. ";;", env = env,
        }, [[
local count = #package.searchers
package.loaded.titan = nil
require "titan"
assert(#package.searchers == count, #package.searchers .. " " .. count)

-- Lua's own paths name no Titan root: only the Titan searcher resolves these.
local statecheck = require "statecheck"
local before, after, origin = statecheck.independent(package.cpath)
assert(before == after, before .. " " .. after)
assert(origin == 1, origin)
assert(statecheck.in_thread(package.cpath) == 1)
]])
        assert.equal(0, probe_count(log))
    end)

    it("prefers a matching native preload and falls through without one",
       function()
        -- The host loads search.item from exact-two; each child's own Titan
        -- path names exact-one, so a file hit and a preload hit differ.
        local stored = table.concat({
            statecheck, exact_two, path.join(PREFIX, "lib/titan/0.6"),
        }, ";")
        local file_suffix = "exact-one/search/item" .. SHARED_SUFFIX
        local preload_hit = [[
local loader, data = package.searchers[#package.searchers]("search.item")
assert(data == ":preload:", tostring(data))
assert(rawequal(loader, package.preload["search.item"]))
return loader("search.item").origin()
]]
        local file_hit = string.format([[
local loader, data = package.searchers[#package.searchers]("search.item")
assert(type(loader) == "function" and not rawequal(loader, string.len))
local provider = data:gsub("\\", "/")
assert(provider:sub(-%d) == %q, data)
return 1
]], #file_suffix, file_suffix)
        assert_runs(workspace, { titan_path = exact_one }, string.format([[
debug.getregistry()[TITAN_PATH_KEY] = %q
local statecheck = require "statecheck"
assert(require("search.item").origin() == 2)
-- The copied loader and its symbol descriptor win over the file.
assert(statecheck.in_new_state(%q) == 2)
-- A replaced loader no longer matches the copied descriptor.
assert(statecheck.in_new_state(%q) == 1)
-- A loader published without a descriptor never matches.
package.preload["search.item"] = string.len
assert(statecheck.in_new_state(%q) == 1)
]], stored, preload_hit,
            'package.preload["search.item"] = string.len\n' .. file_hit,
            file_hit))
    end)
end)

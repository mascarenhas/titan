local assert = require "luassert"
local driver = require "titan-compiler.driver"
local lfs = require "lfs"
local platform = require "titan-compiler.platform"
local support = require "spec.fixtures.target_selection.support"

local cui = [[
local strings = import "string"

function box(text: string): string
  local edge = strings.rep("=", #text + 4)
  return edge .. "\n= " .. text .. " =\n" .. edge
end
]]

local demo = [[
local cui = import "cui"
local io = import "io"

function main(args: {string}): integer
  io.print(cui.box("Titan"))
  return 0
end
]]

local owner = [[
record Box
  serial: integer
  local secret: integer
end

function Box:code(): integer
  return self.serial + self.secret
end

count = 0

function next(): Box
  count = count + 1
  return Box(count, 39)
end

do
  count = 1
end
]]

local facade = [[
local owner = import "dep.owner"

type Box = owner.Box

function make(): Box
  return owner.next()
end
]]

local witness = [=[
local lua = import "lua"

do
  lua.load([[assert(package.preload["dep.owner"] == nil)
             assert(not pcall(require, "dep.owner"))
             assert(package.loaded["dep.owner"] == nil)]])()
  local child = lua.new()
  defer child:close()
  child:run([[assert(package.preload["dep.owner"] == nil)
              assert(not pcall(require, "dep.owner"))]])
end
]=]

local nominal_checks = [=[
function main(args: {string}): integer
  local first = facade.make()
  if first:code() ~= 41 or first.serial ~= 2 then return 1 end
  local second = api.next()
  if second:code() ~= 42 or second.serial ~= 3 then return 2 end
  local child = lua.new()
  defer child:close()
  child:run([[local owner = require "dep.owner"
              assert(owner.next().serial == 2)]])
  if facade.make().serial ~= 4 then return 3 end
  return 0
end
]=]

describe("linked provider composition", function()
    local fixture, stdlib

    before_each(function()
        fixture = support.new()
        stdlib = fixture.prefix .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION
    end)

    after_each(function()
        fixture:close()
    end)

    local function file(relative, contents)
        support.write(fixture.root .. "/" .. relative, contents)
    end

    local function compile(tree, output, providers, ...)
        fixture.source = fixture.root .. "/" .. tree
        fixture.output = fixture.root .. "/" .. output
        local search = providers and fixture.root .. "/" .. providers .. ";" or ""
        return fixture:compile({ ... }, { TITAN_PATH_0_6 = search .. stdlib })
    end

    local function built(tree, output, providers, ...)
        local result = compile(tree, output, providers, ...)
        assert.is_true(result.ok, result.output)
        return result.output
    end

    local function run_deployed(relative)
        local deploy = fixture.root .. "/deployment"
        support.mkdir(deploy)
        local program = deploy .. "/check"
        assert(os.rename(fixture.root .. "/" .. relative, program))
        return fixture:run({ "env", "-i", "PATH=/usr/bin:/bin", "HOME=" .. deploy,
            "TITANC=" .. deploy .. "/no-compiler", "TITAN_ROOT=" .. deploy,
            "TITAN_PATH_0_6=" .. deploy, program })
    end

    it("consumes the same stock-stdlib provider pair in native applications and tests", function()
        file("author/cui.titan", cui)
        file("app/demo.titan", demo)
        built("author", "package", nil, "cui")
        assert.equal("file", lfs.attributes(fixture.root .. "/package/cui" ..
            (platform.windows and ".dll" or ".so"), "mode"))
        built("app", "dynamic", "package", "demo")
        local executable = fixture.output .. "/demo"
        local search = fixture.root .. "/package;" .. stdlib .. ";;"
        if platform.windows then
            executable = assert(driver.windows_program_paths("demo", nil, nil,
                fixture.output)).executable
            search = fixture.output .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION
                .. ";" .. search
        end
        local result = fixture:run({ executable }, { TITAN_PATH_0_6 = search })
        assert.is_true(result.ok, result.output)
        assert.equal("=========\n= Titan =\n=========\n", result.output)
        if platform.windows then
            result = compile("app", "static", "package", "--static", "demo")
            assert.is_false(result.ok, result.output)
            assert.truthy(result.output:find("--static is not supported on Windows", 1, true),
                result.output)
            return
        end

        local archive = fixture.root .. "/package/cui.a"
        assert(os.rename(archive, archive .. ".saved"))
        file("package/cui.a", "not a regular archive\n")
        result = compile("app", "shadowed", "package", "--static", "demo")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("cannot inspect static provider", 1, true),
            result.output)
        assert(os.rename(archive .. ".saved", archive))

        file("suite/checks.titan", [[
local cui = import "cui"
local io = import "io"
local test = import "test"

function test_compiled_library(context: test.Context)
  test.assert(cui.box("Titan") == "=========\n= Titan =\n=========")
end
]])
        assert(os.remove(fixture.root .. "/package/cui.so"))
        built("app", "static", "package", "--static", "demo")
        built("suite", "suite-out", "package", "--static", "--test", "checks")
        result = run_deployed("static/demo")
        assert.is_true(result.ok, result.output)
        assert.equal("=========\n= Titan =\n=========\n", result.output)
        result = run_deployed("suite-out/checks")
        assert.is_true(result.ok, result.output)
        assert.truthy(result.output:find("checks.test_compiled_library", 1, true), result.output)
    end)

    it("shares a carried nominal owner in either import order without publishing it early", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        file("dependency/dep/api.titan", [[
local owner = import "dep.owner"

function next(): owner.Box
  return owner.next()
end
]])
        built("dependency", "package", nil, "dep.api", "dep.owner")
        file("extension/facade.titan", facade)
        built("extension", "package", "package", "facade")
        file("app/witness.titan", witness)
        for _, order in ipairs({ "facade_first", "owner_first" }) do
            local imports = { 'local facade = import "facade"\n', 'local api = import "dep.api"\n' }
            if order == "owner_first" then imports[1], imports[2] = imports[2], imports[1] end
            file("app/" .. order .. ".titan", 'local witness = import "witness"\n' ..
                'local lua = import "lua"\n' .. table.concat(imports) .. "\n" .. nominal_checks)
            built("app", order, "package", "--static", "--incremental", order)
            local output = built("app", order, "package", "--static", "--incremental", "-v", order)
            assert.truthy(output:find("Titan link hit", 1, true), output)
            local result = run_deployed(order .. "/" .. order)
            assert.is_true(result.ok, result.output)
        end

        -- The diagnostic frontend also compiles this graph in-process.
        built("app", "diagnostic", "package", "--print-ast", "--static", "facade_first")
        local diagnostic = run_deployed("diagnostic/facade_first")
        assert.is_true(diagnostic.ok, diagnostic.output)

        -- This compilation unit can recover the owner only contextually.
        -- A separate unit (the root) selects the archive that contains it.
        file("app/consume.titan", [[
local facade = import "facade"

function check(): integer
  return facade.make():code()
end
]])
        file("app/separate.titan", [[
local consume = import "consume"
local api = import "dep.api"

function main(args: {string}): integer
  if consume.check() == 41 and api.next().serial == 3 then return 0 end
  return 1
end
]])
        built("app", "separate", "package", "--static", "--incremental", "separate")
        local output = built("app", "separate", "package", "--static", "--incremental", "-v", "separate")
        assert.truthy(output:find("Titan link hit", 1, true), output)
        local result = run_deployed("separate/separate")
        assert.is_true(result.ok, result.output)

        -- A DSO-only facade still resolves its external dependency against
        -- the executable; the DSO has not claimed the owner's own protocol.
        assert(os.remove(fixture.root .. "/package/facade.a"))
        built("app", "mixed", "package", "--static", "separate")
        file("app/dep/owner.titan", owner)
        file("app/source_owner.titan", [[
local facade = import "facade"
local owner = import "dep.owner.titan"

function main(args: {string}): integer
  if facade.make():code() == 41 and owner.next().serial == 3 then return 0 end
  return 1
end
]])
        built("app", "mixed-source", "package", "source_owner")
        assert(os.remove(fixture.root .. "/package/dep.so"))
        local deploy = fixture.root .. "/deployment"
        assert(os.rename(fixture.root .. "/package/facade.so", deploy .. "/facade.so"))
        result = run_deployed("mixed/separate")
        assert.is_true(result.ok, result.output)
        result = run_deployed("mixed-source/source_owner")
        assert.is_true(result.ok, result.output)
    end)

    it("rejects incompatible physical state before binding an implicit direct owner", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        file("dependency/dep/api.titan", "const answer = 42\n")
        built("dependency", "package", nil, "dep.api", "dep.owner")
        file("extension/facade.titan", facade)
        built("extension", "package", "package", "facade")
        file("app/load_owner.titan", [[
local lua = import "lua"

do
  lua.load("require 'dep.owner'")()
end
]])
        file("app/demo.titan", [[
local load_owner = import "load_owner"
local facade = import "facade"
local api = import "dep.api"

function main(args: {string}): integer
  if facade.make():code() == 41 and api.answer == 42 then return 0 end
  return 1
end
]])
        built("app", "static", "package", "--static", "demo")
        local deploy = fixture.root .. "/deployment"
        support.mkdir(deploy)
        assert(os.rename(fixture.root .. "/package/dep.so", deploy .. "/dep.so"))
        local result = run_deployed("static/demo")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "direct owner 'dep.owner' found canonical module state from a different physical provider",
            1, true), result.output)
    end)

    it("rejects a separately linked owner that fails the used-declaration check", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        built("dependency", "package", nil, "dep.owner")
        file("extension/facade.titan", facade)
        built("extension", "package", "package", "facade")
        file("app/demo.titan", [[
local facade = import "facade"
local owner = import "dep.owner"

function main(args: {string}): integer
  if facade.make().serial ~= 2 then return 1 end
  return 0
end
]])
        built("app", "static", "package", "--static", "--incremental", "demo")
        local output = built("app", "static", "package", "--static", "--incremental", "-v", "demo")
        assert.truthy(output:find("Titan link hit", 1, true), output)
        file("dependency/dep/owner.titan", (owner:gsub("next%(%)", "next(label: string)")
            :gsub("count = 1", 'raise "incompatible owner initialized"')))
        built("dependency", "replacement", nil, "dep.owner")
        assert(os.rename(fixture.root .. "/replacement/dep/owner.a", fixture.root .. "/package/dep/owner.a"))
        output = built("app", "static", "package", "--static", "--incremental", "-v", "demo")
        assert.truthy(output:find("Titan link miss", 1, true), output)
        local result = run_deployed("static/demo")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "binary compatibility mismatch importing 'dep.owner' from 'facade': functions.next.",
            1, true), result.output)
        assert.is_nil(result.output:find("incompatible owner initialized", 1, true), result.output)
    end)

    it("keeps explicit static producer bundles self-contained and rejects their overlap", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        built("dependency", "package", nil, "dep.owner")
        file("extension/facade.titan", facade)
        built("extension", "package", "package", "--static", "facade")
        file("app/alone.titan", [[
local facade = import "facade"

function main(args: {string}): integer
  if facade.make().serial ~= 2 then return 1 end
  return 0
end
]])
        built("app", "static", "package", "--static", "alone")
        local result = run_deployed("static/alone")
        assert.is_true(result.ok, result.output)
        file("app/conflict.titan", [[
local facade = import "facade"
local owner = import "dep.owner"

function main(args: {string}): integer
  return 0
end
]])
        result = compile("app", "static", "package", "--static", "conflict")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("both contain logical module 'dep.owner'", 1, true), result.output)

        assert(os.remove(fixture.root .. "/package/facade.a"))
        result = compile("app", "mixed", "package", "--static", "conflict")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "logical owner 'dep.owner' is required both directly", 1, true), result.output)
    end)
end)

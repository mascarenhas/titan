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

    local function precompile_then_link(tree, output, name, ...)
        local options = { ... }
        options[#options + 1] = name
        built(tree, output, "package", "-c", table.unpack(options))
        assert.equal("file", lfs.attributes(fixture.output .. "/" .. name .. ".o", "mode"))
        local log = built(tree, output, "package", "-c", "--incremental", "-v", table.unpack(options))
        assert.truthy(log:find("Titan object hit " .. name .. ":", 1, true), log)
        assert.is_nil(lfs.attributes(fixture.output .. "/.titan-links", "mode"))
        assert.is_nil(lfs.attributes(fixture.output .. "/" .. name, "mode"))
        assert.is_nil(lfs.attributes(fixture.output .. "/bin/" .. name .. ".exe", "mode"))
        log = built(tree, output, "package", "--incremental", "-v", table.unpack(options))
        assert.truthy(log:find("Titan object hit " .. name .. ":", 1, true), log)
    end

    local function run_with_providers(name)
        local executable = fixture.output .. "/" .. name
        local search = fixture.root .. "/package;" .. stdlib
        if platform.windows then
            executable = assert(driver.windows_program_paths(name, nil, nil,
                fixture.output)).executable
            search = fixture.output .. "/lib/titan/" .. driver.TITAN_LIBRARY_VERSION
                .. ";" .. search
        end
        return fixture:run({ executable }, { TITAN_PATH_0_6 = search })
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

    it("shares the first compatible DSO owner across both import orders", function()
        local suffix = platform.windows and ".dll" or ".so"
        file("dependency/dep/owner.titan", owner)
        built("dependency", "package", nil, "dep.owner")
        file("extension/facade.titan", facade)
        built("extension", "package", "package", "facade")

        -- The facade retains dep/owner's filename, but the app independently
        -- selects the grouped dep provider (root-major, then shallow-first).
        file("replacement/dep/owner.titan", (owner:gsub("count = 1", "count = 10")))
        file("replacement/dep/sibling.titan", "const unused = 1\n")
        built("replacement", "package", nil, "dep.owner", "dep.sibling")
        assert.equal("file", lfs.attributes(fixture.root .. "/package/dep/owner" .. suffix, "mode"))
        assert.equal("file", lfs.attributes(fixture.root .. "/package/dep" .. suffix, "mode"))

        for _, mode in ipairs({ "facade_first", "owner_first" }) do
            local imports = { 'local facade = import "facade"', 'local owner = import "dep.owner"' }
            local first_serial = 2
            if mode == "owner_first" then
                imports[1], imports[2] = imports[2], imports[1]
                first_serial = 11
            end
            file("app/" .. mode .. ".titan", table.concat(imports, "\n") ..
                string.format([[

function main(args: {string}): integer
  local first = facade.make()
  if first.serial ~= %d or first:code() ~= %d then return 1 end
  local second = owner.next()
  if second.serial ~= %d or second:code() ~= %d then return 2 end
  return 0
end
]], first_serial, first_serial + 39, first_serial + 1, first_serial + 40))
            if mode == "facade_first" then
                precompile_then_link("app", mode, mode)
            else
                built("app", mode, "package", mode)
            end
            local result = run_with_providers(mode)
            assert.is_true(result.ok, mode .. ": " .. result.output)
        end
    end)

    it("shares a standard nominal owner in a default program and test runner", function()
        file("author/rx.titan", [[
local strings = import "string"

function digits(): strings.Regex
  return strings.compile_regex("[0-9]+")
end
]])
        file("app/check.titan", [[
local rx = import "rx"
local strings = import "string"

function main(args: {string}): integer
  local found? = rx.digits():match("ab42")
  if not found then return 1 end
  if strings.rep("42", 1) == found:whole() then return 0 end
  return 2
end
]])
        built("author", "package", nil, "rx")
        precompile_then_link("app", "dynamic", "check")
        local result = run_with_providers("check")
        assert.is_true(result.ok, result.output)

        file("suite/checks.titan", [[
local rx = import "rx"
local strings = import "string"
local test = import "test"

function test_composition(context: test.Context)
  local found = rx.digits():match("ab42")
  test.assert(found:whole() == strings.rep("42", 1))
end
]])
        precompile_then_link("suite", "suite-out", "checks", "--test")
        result = run_with_providers("checks")
        assert.is_true(result.ok, result.output)
        assert.truthy(result.output:find("checks.test_composition", 1, true), result.output)

        file("suite/partial.titan", [[
local rx = import "rx"
local strings = import "string"

function digits(): strings.Regex
  return rx.digits()
end
]])
        result = compile("suite", "partial-out", "package", "-c", "partial")
        assert.is_true(result.ok, result.output)
        built("suite", "partial-out", "package", "--incremental", "partial")
    end)

    it("consumes the same stock-stdlib provider pair in native applications and tests", function()
        file("author/cui.titan", cui)
        file("app/demo.titan", demo)
        built("author", "package", nil, "cui")
        assert.equal("file", lfs.attributes(fixture.root .. "/package/cui" ..
            (platform.windows and ".dll" or ".so"), "mode"))
        built("app", "dynamic", "package", "demo")
        local result = run_with_providers("demo")
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

    it("links a private stdlib dependency without an application import or DSO", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("author/jlib.titan", [[
local json = import "json"

function show(n: integer): string
  return json.encode(n)
end
]])
        built("author", "package", nil, "jlib")

        assert(os.remove(fixture.root .. "/package/jlib.so"))
        file("app/demo.titan", [[
local jlib = import "jlib"
local io = import "io"

function main(args: {string}): integer
  io.print(jlib.show(42))
  return 0
end
]])
        built("app", "linked", "package", "--static", "demo")
        local result = run_deployed("linked/demo")
        assert.is_true(result.ok, result.output)
        assert.equal("42\n", result.output)
    end)

    it("leaves dormant archive siblings and their missing exposed types unneeded", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        built("dependency", "package", nil, "dep.owner")
        file("bundle/bundle/live.titan", "const answer = 42\n")
        file("bundle/bundle/dormant.titan", facade)
        built("bundle", "package", "package", "bundle.live", "bundle.dormant")
        assert(os.remove(fixture.root .. "/package/dep/owner.a"))
        assert(os.remove(fixture.root .. "/package/dep/owner.so"))
        assert(os.remove(fixture.root .. "/package/bundle.so"))
        file("app/check.titan", [[
local live = import "bundle.live"

function main(args: {string}): integer
  return live.answer - 42
end
]])
        built("app", "linked", "package", "--static", "check")
        local result = run_deployed("linked/check")
        assert.is_true(result.ok, result.output)
    end)

    it("rejects cycles formed by separately updated archives", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("author/first.titan", "const answer = 42\n")
        built("author", "package", nil, "first")
        file("author/second.titan", 'local first = import "first"\nconst answer = first.answer\n')
        built("author", "package", "package", "second")
        file("author/first.titan", 'local second = import "second"\nconst answer = second.answer\n')
        built("author", "package", "package", "first")
        file("app/check.titan", [[
local first = import "first"

function main(args: {string}): integer
  return first.answer - 42
end
]])
        local result = compile("app", "linked", "package", "--static", "check")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("cyclic archive import: first -> second -> first",
            1, true), result.output)
        assert.is_nil(lfs.attributes(fixture.output .. "/check", "mode"))
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
            if order == "facade_first" then
                precompile_then_link("app", order, order, "--static")
            else
                built("app", order, "package", "--static", "--incremental", order)
            end
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

        -- Strict static mode cannot substitute a DSO-only facade.
        assert(os.remove(fixture.root .. "/package/facade.a"))
        local rejected = compile("app", "mixed", "package", "--static", "separate")
        assert.is_false(rejected.ok, rejected.output)
        assert.truthy(rejected.output:find("--static requires an archive", 1, true), rejected.output)
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

    it("refuses static library mode and preserves canonical shared-bundle ownership", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dependency/dep/owner.titan", owner)
        built("dependency", "package", nil, "dep.owner")
        file("extension/facade.titan", facade)
        local result = compile("extension", "package", "package", "--static", "facade")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("--static is valid only for standalone/test", 1, true),
            result.output)
        assert(os.rename(fixture.root .. "/package/dep/owner.so",
            fixture.root .. "/package/dep/owner.saved"))
        result = compile("extension", "package", "package", "facade")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find("install its paired shared provider", 1, true),
            result.output)
        assert(os.rename(fixture.root .. "/package/dep/owner.saved",
            fixture.root .. "/package/dep/owner.so"))

        -- The carried owner can still be imported from that same DSO. A
        -- second facade with an external edge must not defeat its claim.
        file("group/dep/owner.titan", owner)
        file("group/dep/carried.titan", facade)
        built("group", "package", nil, "dep.owner", "dep.carried")
        file("app/same_handle.titan", [[
local carried = import "dep.carried"
local owner = import "dep.owner"

function main(args: {string}): integer
  if carried.make():code() == 41 and owner.next().serial == 3 then return 0 end
  return 1
end
]])
        built("app", "same-handle", "package", "same_handle")
        result = run_with_providers("same_handle")
        assert.is_true(result.ok, result.output)

        file("other/external.titan", facade)
        built("other", "package", "package", "external")
        file("app/competing.titan", [[
local external = import "external"
local carried = import "dep.carried"
local owner = import "dep.owner"

function main(args: {string}): integer
  return 0
end
]])
        result = compile("app", "competing", "package", "competing")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "has producer-dynamic exposures from conflicting providers", 1, true),
            result.output)
    end)
end)

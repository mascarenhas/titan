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

    -- The encoded producer-proved carriers of one compiled module, probed in
    -- a separate process so no fixture DSO stays loaded here.
    local function recorded_carriers(name, filename)
        local frontend = fixture.frontend .. "/?.lua;" .. fixture.frontend .. "/?/init.lua;"
        local result = fixture:run({ fixture.prefix .. "/bin/lua" .. (platform.windows and ".exe" or ""),
            "-e", string.format([[
package.path = %q .. package.path
local driver = require "titan-compiler.driver"
local staticmetadata = require "titan-compiler.staticmetadata"
local status, value, metadata = driver.probe_compiled_interface(%q, %q)
assert(status == "valid", tostring(value))
io.write(metadata.dynamic_providers and
    assert(staticmetadata.encode_dynamic_providers(%q, metadata.dynamic_providers)) or "")
]], frontend, name, filename, name) })
        assert.is_true(result.ok, result.output)
        return result.output
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
        local symbols = fixture:run({ "nm", fixture.output .. "/demo" })
        assert.is_true(symbols.ok, symbols.output)
        assert.truthy(symbols.output:find("titan_json_init", 1, true), symbols.output)
        local result = run_deployed("linked/demo")
        assert.is_true(result.ok, result.output)
        assert.equal("42\n", result.output)
    end)

    it("loads a runtime plugin and its shared dependency in a static executable", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("dep/plugin_dep.titan", "function answer(): integer return 42 end\n")
        built("dep", "package", nil, "plugin_dep")
        file("plugin/plugin.titan", [[
local dep = import "plugin_dep"

function answer(): integer
  return dep.answer()
end
]])
        built("plugin", "package", "package", "plugin")
        local providers = fixture.root .. "/package"
        assert(os.remove(providers .. "/plugin.a"))
        assert(os.remove(providers .. "/plugin_dep.a"))

        file("app/host.titan", [=[
local lua = import "lua"

function main(args: {string}): integer
  lua.load([[assert(require("plugin").answer() == 42)]])()
  return 0
end
]=])
        built("app", "linked", "package", "--static", "host")
        local result = fixture:run({ "env", "-i", "PATH=/usr/bin:/bin",
            "TITANC=" .. fixture.root .. "/no-compiler", "TITAN_ROOT=" .. fixture.root,
            "TITAN_PATH_0_6=" .. providers, fixture.output .. "/host" })
        assert.is_true(result.ok, result.output)
    end)

    it("certifies a private archive chain and preserves the executable on a deep miss", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("author/leaf.titan", "function answer(): integer return 41 end\n")
        built("author", "package", nil, "leaf")
        file("author/bridge.titan", [[
local leaf = import "leaf"

function answer(): integer
  return leaf.answer()
end
]])
        built("author", "package", "package", "bridge")
        file("app/check.titan", [[
local bridge = import "bridge"
local io = import "io"

function main(args: {string}): integer
  io.print(bridge.answer())
  return 0
end
]])
        local function link()
            return built("app", "linked", "package", "--static", "--incremental", "-v", "check")
        end
        link()
        local output = link()
        assert.truthy(output:find("Titan link hit", 1, true), output)
        local result = run_with_providers("check")
        assert.is_true(result.ok, result.output)
        assert.equal("41\n", result.output)

        file("author/base.titan", "const answer = 42\n")
        built("author", "package", nil, "base")
        file("author/leaf.titan", [[
local base = import "base"

function answer(): integer
  return base.answer
end
]])
        built("author", "package", "package", "leaf")
        output = link()
        assert.truthy(output:find("Titan link miss", 1, true), output)
        output = link()
        assert.truthy(output:find("Titan link hit", 1, true), output)

        local program = fixture.output .. "/check"
        local bytes = support.read(program)
        assert(os.remove(fixture.root .. "/package/base.a"))
        result = compile("app", "linked", "package", "--static", "--incremental", "check")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "--static requires an archive (.a) for 'base' imported by bridge -> leaf",
            1, true), result.output)
        assert.equal(bytes, support.read(program))
        result = run_deployed("linked/check")
        assert.is_true(result.ok, result.output)
        assert.equal("42\n", result.output)

        file("app/base.titan", "const answer = 42\n")
        built("app", "source-linked", "package", "--static", "check", "base")
        result = run_with_providers("check")
        assert.is_true(result.ok, result.output)
        assert.equal("42\n", result.output)
    end)

    it("keeps default DSO fallback for a private member of another selected archive", function()
        if platform.windows then pending("Titan archive providers are not available on Windows"); return end
        file("author/bundle/leaf.titan", "function answer(): integer return 41 end\n")
        built("author", "package", nil, "bundle.leaf")
        file("extension/bridge.titan", [[
local leaf = import "bundle.leaf"

function answer(): integer
  return leaf.answer()
end
]])
        built("extension", "package", "package", "bridge")
        file("author/bundle/leaf.titan", "function answer(): integer return 42 end\n")
        file("author/bundle/live.titan", "const offset = 1\n")
        built("author", "package", nil, "bundle.leaf", "bundle.live")
        assert(os.remove(fixture.root .. "/package/bridge.so"))
        assert(os.remove(fixture.root .. "/package/bundle.so"))
        file("app/check.titan", [[
local bridge = import "bridge"
local live = import "bundle.live"
local io = import "io"

function main(args: {string}): integer
  io.print(bridge.answer() - live.offset)
  return 0
end
]])
        built("app", "default", "package", "check")
        local result = run_with_providers("check")
        assert.is_true(result.ok, result.output)
        assert.equal("40\n", result.output)
        built("app", "strict", "package", "--static", "check")
        result = run_deployed("strict/check")
        assert.is_true(result.ok, result.output)
        assert.equal("41\n", result.output)
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
        local symbols = fixture:run({ "nm", fixture.output .. "/check" })
        assert.is_true(symbols.ok, symbols.output)
        assert.is_nil(symbols.output:find("bundle_dormant_init", 1, true))
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
        -- Built before any shared bundle exists, this facade proves the
        -- standalone DSO as the carrier of the owner it re-exposes.
        built("extension", "package", "package", "facade")
        local function carriers(name)
            return recorded_carriers(name, fixture.root .. "/package/" .. name .. ".so")
        end
        assert.equal("dep.owner\tdep/owner.so", carriers("facade"))

        -- The carried owner can still be imported from that same DSO.
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

        -- A producer built against the shared bundle proves that bundle as
        -- the owner's carrier, so its external edge shares the carried owner.
        file("other/external.titan", facade)
        built("other", "package", "package", "external")
        assert.equal("dep.owner\tdep.so", carriers("external"))
        file("app/competing.titan", [[
local external = import "external"
local carried = import "dep.carried"
local owner = import "dep.owner"

function main(args: {string}): integer
  if external.make():code() ~= 41 then return 1 end
  if carried.make().serial ~= 3 or owner.next().serial ~= 4 then return 2 end
  return 0
end
]])
        built("app", "competing", "package", "competing")
        result = run_with_providers("competing")
        assert.is_true(result.ok, result.output)

        -- The same composition inside a no-main library, consumed by Titan
        -- and by a bare Lua host.
        file("wrapper/wrapped_ok.titan", [[
local external = import "external"
local carried = import "dep.carried"

function n(): integer
  return external.make():code() + carried.make().serial
end
]])
        built("wrapper", "package", "package", "wrapped_ok")
        file("app/use_wrapped.titan", [[
local wrapped_ok = import "wrapped_ok"
local owner = import "dep.owner"

function main(args: {string}): integer
  if wrapped_ok.n() == 44 and owner.next().serial == 4 then return 0 end
  return 1
end
]])
        built("app", "use-wrapped", "package", "use_wrapped")
        result = run_with_providers("use_wrapped")
        assert.is_true(result.ok, result.output)
        result = fixture:run({ fixture.prefix .. "/bin/lua", "-e", [[
require "titan"
local wrapped_ok = require "wrapped_ok"
assert(wrapped_ok.n() == 44)
assert(require("dep.owner").next().serial == 4)
]] }, { TITAN_PATH_0_6 = fixture.root .. "/package;" .. stdlib })
        assert.is_true(result.ok, result.output)

        -- The stale facade's proof names another carrier: it competes with
        -- the bundle in a program and in a no-main library alike.
        local conflict = "has producer-dynamic exposures from conflicting providers"
        file("app/competing_stale.titan", [[
local facade = import "facade"
local carried = import "dep.carried"

function main(args: {string}): integer
  return 0
end
]])
        result = compile("app", "competing-stale", "package", "competing_stale")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(conflict, 1, true), result.output)
        file("stale/stale_wrapped.titan", [[
local facade = import "facade"
local carried = import "dep.carried"

function n(): integer
  return facade.make():code() + carried.make().serial
end
]])
        result = compile("stale", "package", "package", "stale_wrapped")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(conflict, 1, true), result.output)

        -- Two distinct carrying DSOs never share one owner.
        file("override_source/dep/owner.titan", owner)
        file("override_source/dep/owner/wrap.titan", facade)
        built("override_source", "override", nil, "dep.owner", "dep.owner.wrap")
        assert.equal("file", lfs.attributes(fixture.root .. "/override/dep/owner.so", "mode"))
        file("app/multi_carrier.titan", [[
local wrap = import "dep.owner.wrap"
local carried = import "dep.carried"

function main(args: {string}): integer
  return 0
end
]])
        fixture.source = fixture.root .. "/app"
        fixture.output = fixture.root .. "/multi-carrier"
        result = fixture:compile({ "multi_carrier" }, { TITAN_PATH_0_6 = fixture.root ..
            "/override;" .. fixture.root .. "/package;" .. stdlib })
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(conflict, 1, true), result.output)
    end)

    it("shares SDK owners re-exposed by a library with module-level and direct consumers", function()
        local suffix = platform.windows and ".dll" or ".so"
        file("author/web.titan", [[
local json = import "json"

record Context
  label: string
  option: json.DecodeOption?
end

type Handler = function (Context): ()

local handlers: {Handler} = {}

function register(handler: Handler)
  handlers[#handlers + 1] = handler
end

function dispatch(label: string): string
  local ctx = Context(label, nil)
  for index = 1, #handlers do handlers[index](ctx) end
  return ctx.label
end
]])
        built("author", "package", nil, "--incremental", "web")
        local log = built("author", "package", nil, "--incremental", "-v", "web")
        assert.truthy(log:find("Titan object hit web:", 1, true), log)
        -- The library proves the SDK image as the carrier of both the owner
        -- it imports and the owner that owner's interface exposes.
        local carriers = recorded_carriers("web", fixture.root .. "/package/web" .. suffix)
        for _, owner_name in ipairs({ "titan.json", "titan.reflect" }) do
            assert.truthy(carriers:find(owner_name .. "\ttitan" .. suffix, 1, true), carriers)
        end

        file("app/app_modfn.titan", [[
local web = import "web"

local function hello(ctx: web.Context)
  ctx.label = ctx.label .. "!"
end

function main(args: {string}): integer
  web.register(hello)
  if web.dispatch("hi") == "hi!" then return 0 end
  return 1
end
]])
        file("app/app_json.titan", [[
local json = import "json"
local web = import "web"

local function hello(ctx: web.Context)
  ctx.label = ctx.label .. "!"
end

function main(args: {string}): integer
  web.register(hello)
  local decoded = json.decode("42", nil)
  if decoded == 42 and web.dispatch(json.encode("x")) == "\"x\"!" then return 0 end
  return 1
end
]])
        for _, app in ipairs({ "app_modfn", "app_json" }) do
            built("app", app, "package", "--incremental", app)
            local result = run_with_providers(app)
            assert.is_true(result.ok, app .. ": " .. result.output)
            log = built("app", app, "package", "--incremental", "-v", app)
            assert.truthy(log:find("Titan object hit " .. app .. ":", 1, true), log)
        end
    end)

    it("proves a carried owner across multi-hop facades and certifies that proof", function()
        local suffix = platform.windows and ".dll" or ".so"
        local function carriers(name)
            return recorded_carriers(name, fixture.root .. "/package/" .. name .. suffix)
        end
        -- other.api carries its authored dep.owner sibling; no pathname
        -- names dep.owner on its own.
        file("other/dep/owner.titan", owner)
        file("other/other/api.titan", facade)
        built("other", "package", nil, "other.api")
        assert.is_nil(lfs.attributes(fixture.root .. "/package/dep/owner" .. suffix, "mode"))
        assert.is_nil(lfs.attributes(fixture.root .. "/package/dep" .. suffix, "mode"))
        file("sib/sib_facade.titan", [[
local api = import "other.api"

type Box = api.Box

function make(): Box
  return api.make()
end
]])
        built("sib", "package", "package", "--incremental", "sib_facade")
        file("reexp/reexposer.titan", [[
local sib_facade = import "sib_facade"

type Box = sib_facade.Box

function make(): Box
  return sib_facade.make()
end
]])
        built("reexp", "package", "package", "--incremental", "reexposer")
        local proof = "dep.owner\tother/api" .. suffix
        assert.equal(proof .. "\nother.api\tother/api" .. suffix, carriers("sib_facade"))
        assert.equal(proof .. "\nsib_facade\tsib_facade" .. suffix, carriers("reexposer"))
        file("app/use_reexposer.titan", [[
local reexposer = import "reexposer"

function main(args: {string}): integer
  if reexposer.make():code() == 41 then return 0 end
  return 1
end
]])
        built("app", "use-reexposer", "package", "use_reexposer")
        local result = run_with_providers("use_reexposer")
        assert.is_true(result.ok, result.output)

        -- An unrelated bundle claiming the owner appears on the path: the
        -- recorded proof still names the actual carrier, so a warm rebuild
        -- hits, and a program mixing both carriers is rejected.
        file("group/dep/owner.titan", owner)
        file("group/dep/carried.titan", facade)
        built("group", "package", nil, "dep.owner", "dep.carried")
        local log = built("reexp", "package", "package", "--incremental", "-v", "reexposer")
        assert.truthy(log:find("Titan object hit reexposer:", 1, true), log)
        file("app/mixed.titan", [[
local reexposer = import "reexposer"
local carried = import "dep.carried"

function main(args: {string}): integer
  return 0
end
]])
        result = compile("app", "mixed", "package", "mixed")
        assert.is_false(result.ok, result.output)
        assert.truthy(result.output:find(
            "has producer-dynamic exposures from conflicting providers", 1, true), result.output)

        -- other.api stops carrying the owner: both recorded proofs miss and
        -- are rebuilt against the owner's new carrier.
        assert(os.remove(fixture.root .. "/other/dep/owner.titan"))
        built("other", "package", "package", "other.api")
        log = built("sib", "package", "package", "--incremental", "-v", "sib_facade")
        assert.truthy(log:find("Titan object miss sib_facade:", 1, true), log)
        log = built("reexp", "package", "package", "--incremental", "-v", "reexposer")
        assert.truthy(log:find("Titan object miss reexposer:", 1, true), log)
        local moved = "dep.owner\tdep" .. suffix
        assert.equal(moved .. "\nother.api\tother/api" .. suffix, carriers("sib_facade"))
        assert.equal(moved .. "\nsib_facade\tsib_facade" .. suffix, carriers("reexposer"))
    end)
end)

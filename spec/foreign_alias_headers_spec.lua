local driver = require "titan-compiler.driver"
local ffiheaders = require "titan-compiler.ffiheaders"
local types = require "titan-compiler.types"

describe("foreign alias header manifests", function()
    local loaders, previous_imported, previous_registry
    before_each(function()
        loaders = {}
        previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        for _, loader in ipairs(loaders) do assert(driver.close_loader(loader)) end
        driver.imported, types.registry = previous_imported, previous_registry
    end)

    local function load_module(name, source, retained)
        local filename = "/tmp/titan-foreign-alias-" .. name .. ".titan"
        local loader = driver.defaultloader({}, {
            analysis_only = true,
            source_roots = { [name] = true },
            source_overrides = { [name] = {
                kind = "generated", main = filename, files = { filename },
                contents = { [filename] = source },
            } },
            cached_source_entries = retained,
        })
        loaders[#loaders + 1] = loader
        local ok, result, errors = loader(name)
        assert.is_true(ok, result)
        assert.equal(0, #errors, table.concat(errors, "\n"))
        return driver.imported[name]
    end

    it("restores typedef declarations for a source-importing consumer", function()
        local provider = load_module("foreign_alias_cached", [[
            foreign type Word = unsigned long
            foreign type WordPointer = *Word
        ]])
        local restored = assert(driver.decode_project_entry(
            assert(driver.encode_project_entry(provider))))
        local plan = restored.ffi_header_descriptor
        assert.equal(2, #plan.typedef_declarations)
        assert.truthy(ffiheaders.validate_plan(plan))
        driver.imported, types.registry = {}, {}
        local consumer = load_module("foreign_alias_cached_consumer", [[
            local provider = import "foreign_alias_cached.titan"
            local function read(p: foreign WordPointer): integer
                return p[0] as integer
            end
        ]], { foreign_alias_cached = restored })
        local dependency = consumer.ast._ffi_header.dependencies[1]
        assert.same(plan.typedef_declarations, dependency.typedef_declarations)
        assert.equal(plan.digest, dependency.digest)
    end)

    it("rejects a persisted declaration payload that disagrees with its header", function()
        local provider = load_module("foreign_alias_tamper", [[
            foreign type Word = unsigned long
        ]])
        local restored = assert(driver.decode_project_entry(
            assert(driver.encode_project_entry(provider))))
        local plan = restored.ffi_header_descriptor
        plan.typedef_declarations[1] = "typedef int Word;"
        local ok, err = pcall(ffiheaders.validate_plan, plan)
        assert.falsy(ok)
        assert.matches("contents disagree", err, 1, true)
    end)
end)

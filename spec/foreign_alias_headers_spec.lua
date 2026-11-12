local temporary = require "spec.support.temporary"
local driver = require "titan-compiler.driver"
local ffiheaders = require "titan-compiler.ffiheaders"
local types = require "titan-compiler.types"
local _, close_contexts, resolver_options =
    require("spec.support.resolver_contexts")(driver)
after_each(close_contexts)

describe("foreign alias header manifests", function()
    local loaders, headers, previous_imported, previous_registry
    before_each(function()
        loaders = {}
        headers = {}
        previous_imported, previous_registry = driver.imported, types.registry
        driver.imported, types.registry = {}, {}
    end)
    after_each(function()
        for _, loader in ipairs(loaders) do assert(driver.close_loader(loader)) end
        for _, header in ipairs(headers) do os.remove(header) end
        driver.imported, types.registry = previous_imported, previous_registry
    end)

    local function load_module(name, source, retained)
        local filename = "/tmp/titan-foreign-alias-" .. name .. ".titan"
        local loader = driver.defaultloader({}, resolver_options({ analysis_only = true, source_roots = { [name] = true },
        source_overrides = { [name] = {
            kind = "generated", main = filename, files = { filename },
            contents = { [filename] = source },
        } },
        cached_source_entries = retained, }))
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

    it("retains raw payload scopes through restored transitive source headers", function()
        local path = temporary.name(".h")
        headers[#headers + 1] = path
        local file = assert(io.open(path, "w"))
        assert(file:write("struct restored_raw { int member; };\n"))
        assert(file:close())
        local provider = load_module("scope_origin.item", string.format([[
            foreign import %q
            foreign type Item = restored_raw
            foreign type Pointer = *restored_raw
            foreign type Array = restored_raw[]
        ]], path))
        local members = provider.ast._ffi_namespace._type.type_members
        local item_scope, raw_scope = members.Item._ffi_scope, members.restored_raw._ffi_scope
        local restored = assert(driver.decode_project_entry(assert(driver.encode_project_entry(provider))))
        driver.imported, types.registry = {}, {}
        local middle = load_module("scope_bridge.middle", [[
            local source = import "scope_origin.item.titan"
        ]], { ["scope_origin.item"] = restored })
        local restored_middle = assert(driver.decode_project_entry(assert(driver.encode_project_entry(middle))))
        driver.imported, types.registry = {}, {}
        local consumer = load_module("scope_user.consumer", [[
            local middle = import "scope_bridge.middle.titan"
            local type ItemOwner = owned *Item
            local type PointerOwner = owned Pointer
            local type ArrayOwner = owned Array
        ]], { ["scope_origin.item"] = restored, ["scope_bridge.middle"] = restored_middle })
        assert.equal(item_scope, consumer.ast[2]._type.pointee._ffi_scope)
        for index = 3, 4 do
            assert.equal(raw_scope, consumer.ast[index]._type.pointee._ffi_scope)
        end
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

    it("declares the built-in lua_State tag before an alias names it", function()
        local provider = load_module("foreign_alias_state", [[
            foreign type StateCallback = function (*lua_State): int
        ]])
        local restored = assert(driver.decode_project_entry(
            assert(driver.encode_project_entry(provider))))
        local plan = restored.ffi_header_descriptor
        -- The plan stores the typedef alone; its contents derive the tag
        -- declaration from it.
        local typedef = "typedef int (*StateCallback)(struct lua_State *);"
        assert.same({ typedef }, plan.typedef_declarations)
        assert.truthy(plan.contents:find(
            "\nstruct lua_State;\n" .. typedef .. "\n", 1, true), plan.contents)
        assert.truthy(ffiheaders.validate_plan(plan))
    end)
end)

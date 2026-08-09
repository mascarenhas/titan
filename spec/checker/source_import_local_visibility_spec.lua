local checker = require "titan-compiler.checker"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local types = require "titan-compiler.types"
local h = require "spec.support.helpers"

local function check_modules(modules, main)
    local ok, err = h.run_checker_modules(
        modules, main, { interface = "source" })
    assert.truthy(ok, err)
end

describe("source-import local visibility (checker)", function()
    after_each(function()
        types.registry = {}
        driver.imported = {}
    end)

    it("exposes a direct source module's own local declarations", function()
        check_modules({
            source_local_provider = [[
                local type Count = integer

                local function increment(n: Count): Count
                    return n + 1
                end

                local record Token
                    count: Count
                end

                local union Result
                    ready: Token
                    failed: string
                end
            ]],
            source_local_consumer = [[
                local provider = import "source_local_provider"

                function inspect(): integer
                    local token: provider.Token = provider.Token.new(40)
                    token.count = provider.increment(token.count)
                    local count: provider.Count = token.count
                    local result: provider.Result =
                        provider.Result.ready(token)
                    case result
                    when ready: found then
                        return found.count + count
                    when failed: message then
                        return #message
                    end
                end
            ]],
        }, "source_local_consumer")
    end)

    it("exposes local fields, constructors, statics, methods, and variants " ..
       "of a direct source nominal", function()
        check_modules({
            source_member_provider = [[
                record Box
                    local hidden: integer
                    shown: integer
                end

                local function Box.make(hidden: integer,
                                        shown: integer): Box
                    return Box.new(hidden, shown)
                end

                local function Box:secret(): integer
                    return self.hidden
                end

                union Choice
                    local hidden: integer
                    shown: integer
                end
            ]],
            source_member_consumer = [[
                local provider = import "source_member_provider"

                function inspect(): integer
                    local construct: (integer, integer) -> provider.Box =
                        provider.Box.new
                    local make: (integer, integer) -> provider.Box =
                        provider.Box.make
                    local box = construct(10, 20)
                    box.hidden = make(30, 40):secret()
                    local secret: () -> integer = box:secret
                    local choice = provider.Choice.hidden(secret())
                    case choice
                    when hidden: n then
                        return n + box.shown
                    when shown: n then
                        return n
                    end
                end
            ]],
        }, "source_member_consumer")
    end)

    it("reads and writes local module variables through a direct source import", function()
        check_modules({
            source_variable_provider = [[
                local secret: integer = 41

                function visible(): integer
                    return secret
                end
            ]],
            source_variable_consumer = [[
                local provider = import "source_variable_provider"

                function inspect(): integer
                    provider.secret = provider.secret + 1
                    return provider.visible()
                end
            ]],
        }, "source_variable_consumer")
    end)

    it("does not grant local nominal-member visibility transitively", function()
        local modules = {
            source_visibility_leaf = [[
                record Secret
                    local hidden: integer
                end

                local function Secret:reveal(): integer
                    return self.hidden
                end
            ]],
            source_visibility_bridge = [[
                local leaf = import "source_visibility_leaf"
                local type Borrowed = leaf.Secret

                local function borrow(): Borrowed
                    return leaf.Secret.new(42)
                end

                local function read_directly(): integer
                    return borrow():reveal()
                end
            ]],
            source_visibility_field_consumer = [[
                local bridge = import "source_visibility_bridge"

                function inspect(): integer
                    local secret: bridge.Borrowed = bridge.borrow()
                    return bridge.read_directly() + secret.hidden
                end
            ]],
        }

        local ok, err = h.run_checker_modules(
            modules, "source_visibility_field_consumer",
            { interface = "source" })
        assert.falsy(ok)
        assert.falsy(err:find("type 'Borrowed' not found", 1, true), err)
        assert.match(
            "field 'hidden' not found in record 'source_visibility_leaf%.Secret'",
            err)

        modules.source_visibility_field_consumer = nil
        modules.source_visibility_method_consumer = [[
            local bridge = import "source_visibility_bridge"

            function inspect(): integer
                local secret: bridge.Borrowed = bridge.borrow()
                return secret:reveal()
            end
        ]]
        ok, err = h.run_checker_modules(
            modules, "source_visibility_method_consumer",
            { interface = "source" })
        assert.falsy(ok)
        assert.falsy(err:find("type 'Borrowed' not found", 1, true), err)
        assert.match(
            "method 'source_visibility_leaf%.Secret:reveal' is local to " ..
                "module 'source_visibility_leaf'",
            err)

        modules.source_visibility_method_consumer = nil
        modules.source_visibility_direct_consumer = [[
            local bridge = import "source_visibility_bridge"
            local leaf = import "source_visibility_leaf"

            function inspect(): integer
                local secret: leaf.Secret = bridge.borrow()
                return bridge.read_directly()
                    + secret.hidden + secret:reveal()
            end
        ]]
        check_modules(modules, "source_visibility_direct_consumer")
    end)

    it("does not launder a wholly local nominal through a source facade",
    function()
        local modules = {
            source_local_owner = [[
                local record Secret
                    payload: integer
                end

                local function make(): Secret
                    return Secret.new(42)
                end
            ]],
            source_local_facade = [[
                local owner = import "source_local_owner"
                local type Secret = owner.Secret

                local function make(): Secret
                    return owner.make()
                end
            ]],
            source_local_facade_consumer = [[
                local facade = import "source_local_facade"

                function inspect(): integer
                    return facade.make().payload
                end
            ]],
        }
        local ok, err = h.run_checker_modules(
            modules, "source_local_facade_consumer",
            { interface = "source" })
        assert.falsy(ok)
        assert.match(
            "record type 'source_local_owner%.Secret' is local to module " ..
                "'source_local_owner'", err)

        modules.source_local_facade_consumer = [[
            local facade = import "source_local_facade"
            local owner = import "source_local_owner"

            function inspect(): integer
                return facade.make().payload + owner.make().payload
            end
        ]]
        check_modules(modules, "source_local_facade_consumer")
    end)

    it("retains the module-variable frontier for a later direct owner import",
    function()
        local modules = {
            source_frontier_owner = [[
                record Box
                end

                local function Box.secret(): integer
                    return 42
                end
            ]],
            source_frontier_facade = [[
                local owner = import "source_frontier_owner"
                type Box = owner.Box
            ]],
            source_frontier_consumer = [[
                local facade = import "source_frontier_facade"
                local before: integer = facade.Box.secret()

                local function body_declared_before_owner_import(): integer
                    return facade.Box.secret()
                end

                local owner = import "source_frontier_owner"
                local after: integer = facade.Box.secret()
            ]],
        }

        local ok, err = h.run_checker_modules(
            modules, "source_frontier_consumer",
            { interface = "source" })
        assert.falsy(ok)
        assert.match(
            "record function 'source_frontier_owner%.Box%.secret' is local " ..
                "to module 'source_frontier_owner'", err)
        local _, count = err:gsub("is local to module", "")
        assert.equal(1, count, err)
    end)

    it("keeps a complete source owner canonical across compiled facades",
    function()
        local modules = {
            source_registry_owner = [[
                record Box
                    local hidden: integer
                    shown: integer
                end

                function make(): Box
                    return Box.new(40, 2)
                end
            ]],
            source_registry_facade = [[
                local owner = import "source_registry_owner"

                function get(): owner.Box
                    return owner.make()
                end
            ]],
        }
        local imported = {}
        local source_loader = driver.tableloader(
            modules, imported, nil, { interface = "source" })
        local facade_type, facade_errors = checker.checkimport(
            "source_registry_facade", source_loader)
        assert.truthy(facade_type, table.concat(facade_errors or {}, "\n"))
        assert.equal(0, #facade_errors)
        local source_owner = imported.source_registry_owner.source_type

        local function compiled_projection(modtype, name)
            local serialized = types.serialize(modtype)
            assert.falsy(serialized:find("_source_complete", 1, true))
            local chunk = assert(load(
                "return " .. serialized, name, "t", types))
            return assert(chunk())
        end

        local compiled_owner = compiled_projection(
            source_owner, "source_registry_owner")
        local compiled_facade = compiled_projection(
            facade_type, "source_registry_facade")
        driver.close_tableloader(source_loader)

        for _, provider_kind in ipairs({ "dynamic", "static" }) do
            for _, source_first in ipairs({ true, false }) do
                types.registry = {}
                driver.imported = {}
                local imports = source_first and [[
                    local owner = import "source_registry_owner"
                    local facade = import "source_registry_facade"
                ]] or [[
                    local facade = import "source_registry_facade"
                    local owner = import "source_registry_owner"
                ]]
                local subject = imports .. [[
                    function inspect(): integer
                        return owner.make().hidden + facade.get().shown
                    end
                ]]
                local ast = assert(parser.parse(
                    "source_registry_consumer.titan", subject))
                local function mixed_loader(name, request)
                    if name == "source_registry_facade" then
                        return true, compiled_facade, {},
                            { kind = provider_kind }
                    end
                    assert.equal("source_registry_owner", name)
                    if request and
                       request.exposer == "source_registry_facade" then
                        return true, compiled_owner, {},
                            { kind = provider_kind }
                    end
                    return true, source_owner, {}, { kind = "source" }
                end
                local _, errors = checker.check(
                    "source_registry_consumer", ast, subject,
                    "source_registry_consumer.titan", mixed_loader)
                assert.equal(0, #errors, table.concat(errors, "\n"))
            end
        end
    end)

    it("defers source-qualified composite enum aliases to their use", function()
        local header = os.tmpname() .. ".h"
        local file = assert(io.open(header, "w"))
        file:write([[
            typedef enum { SOURCE_ALIAS_ZERO = 0,
                           SOURCE_ALIAS_WIDE = 0x8000000000000000ULL }
                source_alias_wide_enum;
        ]])
        file:close()
        local modules = {
            source_alias_provider = string.format([[
                local c = foreign import %q
                local type Wide = c.source_alias_wide_enum
                local type WideArray = {Wide}
                local type WideMap = {string: WideArray}
                local type WideFunction = (WideMap) -> integer
            ]], header),
            source_alias_pointer_consumer = [[
                local provider = import "source_alias_provider"
                local type Pointer = *provider.Wide
                local type Composite = provider.WideFunction?
                function inspect(): integer return 1 end
            ]],
            source_alias_value_consumer = [[
                local provider = import "source_alias_provider"
                function inspect(): integer
                    local items: provider.WideArray = {}
                    return #items
                end
            ]],
        }
        local ok, err = h.run_checker_modules(
            modules, "source_alias_pointer_consumer",
            { interface = "source" })
        assert.truthy(ok, err)
        ok, err = h.run_checker_modules(
            modules, "source_alias_value_consumer",
            { interface = "source" })
        os.remove(header)
        assert.falsy(ok)
        assert.truthy(err:find(
            "full range fits in lua_Integer", 1, true), err)
    end)

    it("keeps compiled projections public-only", function()
        local modules = {
            source_visibility_binary = [[
                local secret: integer = 9
                local function hidden(): integer return 1 end
                local type Hidden = integer

                record Box
                    local hidden: integer
                    shown: integer
                end

                local function Box:secret(): integer
                    return self.hidden
                end

                function visible(): integer return 2 end
                function make(): Box return Box.new(3, 4) end
            ]],
            source_visibility_binary_consumer = [[
                local provider = import "source_visibility_binary"
                function inspect(): integer
                    local box = provider.make()
                    return provider.visible() + box.shown
                end
            ]],
        }
        local ok, err = h.run_checker_modules(
            modules, "source_visibility_binary_consumer",
            { interface = "compiled" })
        assert.truthy(ok, err)

        local rejected = {
            "return provider.secret",
            "return provider.hidden()",
            "local item: provider.Hidden = 1; return item",
            "return provider.make().hidden",
            "return provider.make():secret()",
        }
        for _, statement in ipairs(rejected) do
            modules.source_visibility_binary_consumer = ([=[
                local provider = import "source_visibility_binary"
                function inspect(): integer
                    %s
                end
            ]=]):format(statement)
            ok, err = h.run_checker_modules(
                modules, "source_visibility_binary_consumer",
                { interface = "compiled" })
            assert.falsy(ok, err)
        end
    end)
end)

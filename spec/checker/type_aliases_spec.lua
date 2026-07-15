local checker = require "titan-compiler.checker"
local h = require "spec.support.helpers"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function find_alias(ast, name)
    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelTypeAlias" and node.name == name then
            return node
        end
    end
    error("type alias not found: " .. name)
end

describe("Titan type aliases", function()
    it("resolves aliases and alias chains to the RHS type object", function()
        local ok, err, ast = run_checker([[
            type Count = integer
            type AlsoCount = Count
            type Counter = (Count) -> AlsoCount

            function id(x: AlsoCount): Count
                return x
            end
        ]])
        assert.truthy(ok, err)

        local count = find_alias(ast, "Count")
        local also = find_alias(ast, "AlsoCount")
        local counter = find_alias(ast, "Counter")
        local id = ast[4]
        assert.is_true(count._type == also._type)
        assert.is_true(count._type == counter._type.params[1])
        assert.is_true(count._type == counter._type.rettypes[1])
        assert.is_true(count._type == id._type.params[1])
        assert.is_true(count._type == id._type.rettypes[1])
    end)

    it("supports forward aliases in signatures and record fields", function()
        local ok, err, ast = run_checker([[
            function id(x: Number): Number
                return x
            end

            record Box
                data: Number
            end

            type OtherNumber = Number
            type Number = integer
        ]])
        assert.truthy(ok, err)
        assert.is_true(find_alias(ast, "Number")._type ==
            find_alias(ast, "OtherNumber")._type)
    end)

    it("keeps the type and value namespaces separate", function()
        local ok, err, _, modtype = run_checker([[
            type Item = integer
            Item = 41

            function get(): Item
                return Item
            end
        ]])
        assert.truthy(ok, err)
        assert.same("Type.Integer", modtype.type_members.Item._tag)
        assert.same("Type.ModuleVariable", modtype.members.Item._tag)
    end)

    it("does not make a type alias available as a run-time value", function()
        local ok, err = run_checker([[
            type Count = integer

            function get(): integer
                return Count
            end
        ]])
        assert.falsy(ok)
        assert.match("variable 'Count' not declared", err)
    end)

    it("rejects duplicate aliases and aliases that collide with records", function()
        local ok, err = run_checker([[
            type Count = integer
            local type Count = string
        ]])
        assert.falsy(ok)
        assert.match("duplicate type alias for Count", err)

        ok, err = run_checker([[
            type Box = integer
            record Box end
        ]])
        assert.falsy(ok)
        assert.match("type alias 'Box' conflicts with record", err)
    end)

    it("rejects direct, mutual, and structural alias cycles", function()
        local cases = {
            [[ type A = A ]],
            [[ type A = B type B = A ]],
            [[ type A = { A } ]],
        }
        for _, source in ipairs(cases) do
            local ok, err, ast = run_checker(source)
            assert.falsy(ok)
            assert.match("cyclic type alias involving", err)
            assert.same("Type.Invalid", find_alias(ast, "A")._type._tag)
        end
    end)

    it("validates nominal types nested inside alias targets", function()
        local ok, err = run_checker([[
            type MissingList = { Missing }
        ]])
        assert.falsy(ok)
        assert.match("invalid type 'test%.Missing'", err)
    end)

    it("exports only non-local aliases in the module type", function()
        local ok, err, _, modtype = run_checker([[
            local type Hidden = integer
            type Public = Hidden
        ]])
        assert.truthy(ok, err)
        assert.is_nil(modtype.type_members.Hidden)
        assert.same("Type.Integer", modtype.type_members.Public._tag)
        assert.is_nil(modtype.members.Public)
    end)

    it("re-exports an imported record without changing its nominal identity", function()
        local ok, err = run_checker_modules({
            base = [[
                record Error
                    code: integer
                end
            ]],
            facade = [[
                local base = import "base"
                type Error = base.Error
            ]],
            consumer = [[
                local facade = import "facade"

                function code(error: facade.Error): integer
                    return error.code
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)
    end)

    it("does not turn a qualified imported alias into a run-time member", function()
        local ok, err = run_checker_modules({
            base = [[
                record Error
                    code: integer
                end
            ]],
            facade = [[
                local base = import "base"
                type Error = base.Error
            ]],
            consumer = [[
                local facade = import "facade"

                function make(): facade.Error
                    return facade.Error.new(1)
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("member 'Error' not found inside module 'facade'", err)
    end)

    it("supports aliases to later records and recursion through an alias", function()
        local ok, err = run_checker([[
            type Link = Node?

            record Node
                next: Link
            end

            function empty(): Link
                return nil
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("does not export local aliases", function()
        local ok, err = run_checker_modules({
            provider = [[ local type Secret = integer ]],
            consumer = [[
                local provider = import "provider"
                function use(secret: provider.Secret): integer return secret end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("type 'Secret' not found inside module 'provider'", err)
    end)

    it("rejects exported aliases to local records but permits local aliases", function()
        local ok, err = run_checker([[
            local record Secret
                data: integer
            end
            type Public = Secret
        ]])
        assert.falsy(ok)
        assert.match("cannot export local record type 'test%.Secret'", err)

        ok, err = run_checker([[
            local record Secret
                data: integer
            end
            local type Private = Secret

            local function make(): Private
                return Secret.new(1)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects exported aliases to C FFI types but permits local aliases", function()
        local ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"
            type Public = ffi.titan_ffi_int
        ]])
        assert.falsy(ok)
        assert.match("cannot export C FFI type 'titan_ffi_int'", err)

        ok, err = run_checker([[
            local ffi = foreign import "titan/ffi.h"
            local type Private = ffi.titan_ffi_int

            local function keep(x: Private): Private
                return x
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("recognizes an aliased standalone main signature semantically", function()
        local ok, err, ast = run_checker([[
            type Arguments = { string }
            type ExitCode = integer

            function main(args: Arguments): ExitCode
                return 0
            end
        ]])
        assert.truthy(ok, err)
        assert.truthy(checker.has_main(ast))
    end)
end)

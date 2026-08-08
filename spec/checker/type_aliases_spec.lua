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

    it("keeps a nominal alias itself out of the first-class value namespace", function()
        local ok, err = run_checker([[
            record Box
                n: integer
            end
            type Alias = Box

            function bad(): value
                return Alias
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "trying to access record type 'test%.Box' as a first%-class value",
            err)

        ok, err = run_checker_modules({
            provider = [[
                record Box
                    n: integer
                end
            ]],
            facade = [[
                local provider = import "provider"
                type Box = provider.Box
            ]],
            consumer = [[
                local facade = import "facade"

                function bad(): value
                    return facade.Box
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match(
            "trying to access record type 'provider%.Box' as a first%-class value",
            err)
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

    it("preserves nominal constructors and public statics through qualified alias chains", function()
        local ok, err = run_checker_modules({
            base = [[
                record Error
                    code: integer
                end

                function Error.from(code: integer): Error
                    return Error.new(code)
                end

                union Reason
                    simple: string
                    empty
                end

                function Reason.describe(reason: Reason): string
                    case reason
                    when simple: message then
                        return message
                    else
                        return "empty"
                    end
                end
            ]],
            facade = [[
                local base = import "base"
                type Error = base.Error
                type ErrorAgain = Error
                type Reason = base.Reason
            ]],
            consumer = [[
                local facade = import "facade"

                function make(): (facade.Error, facade.Reason, string)
                    local new_error: (integer) -> facade.Error =
                        facade.ErrorAgain.new
                    local from: (integer) -> facade.Error =
                        facade.Error.from
                    local simple: (string) -> facade.Reason =
                        facade.Reason.simple
                    local describe: (facade.Reason) -> string =
                        facade.Reason.describe
                    local reason = simple("cancelled")
                    return new_error(from(1).code), reason, describe(reason)
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)
    end)

    it("uses unqualified local and public aliases as the original nominal namespace", function()
        local ok, err = run_checker([[
            record Box
                n: integer
            end

            function Box.from(n: integer): Box
                return Box.new(n)
            end

            union Result
                success: Box
                failure: string
            end

            type PublicBox = Box
            local type PrivateBox = PublicBox
            type PublicResult = Result

            function make(n: integer): PublicResult
                local new_box: (integer) -> Box = PrivateBox.new
                local from: (integer) -> Box = PublicBox.from
                local success: (Box) -> Result = PublicResult.success
                return success(new_box(from(n).n))
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("does not expose nominal members that are local to the owner", function()
        local ok, err = run_checker_modules({
            provider = [[
                record Box
                    local hidden: integer
                end

                function Box.visible(n: integer): integer
                    return n
                end

                local function Box.secret(n: integer): integer
                    return n
                end

                union Choice
                    shown: integer
                    local hidden: integer
                end
            ]],
            facade = [[
                local provider = import "provider"
                type Box = provider.Box
                type Choice = provider.Choice
            ]],
            consumer = [[
                local facade = import "facade"

                function good_static(): integer
                    return facade.Box.visible(1)
                end

                function bad_box(): facade.Box
                    return facade.Box.new(1)
                end

                function bad_static(): integer
                    return facade.Box.secret(1)
                end

                function bad_variant(): facade.Choice
                    return facade.Choice.hidden(1)
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match(
            "record function 'provider%.Box%.new' is local to module 'provider'", err)
        assert.match(
            "record function 'provider%.Box%.secret' is local to module 'provider'", err)
        assert.match(
            "union function 'provider%.Choice%.hidden' is local to module 'provider'", err)
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

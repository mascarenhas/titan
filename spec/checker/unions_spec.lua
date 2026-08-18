local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local types = require "titan-compiler.types"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function assert_check(source)
    local ok, err, ast, modtype = run_checker(source)
    assert.truthy(ok, err)
    return ast, modtype
end

local function assert_error(pattern, source)
    local ok, err = run_checker(source)
    assert.falsy(ok)
    assert.match(pattern, err)
    return err
end

local function find_toplevel(ast, tag, name)
    for _, node in ipairs(ast) do
        if node._tag == tag and node.name == name then
            return node
        end
    end
    error(string.format("could not find %s '%s'", tag, name))
end

describe("unions (typechecker)", function()
    it("builds stable variant metadata and positional constructors", function()
        local ast, modtype = assert_check([[
            union Message
                quit
                local hidden: integer
                write: string
            end

            local quit = Message.quit()
            local write = Message.write("hello")

            function make_write(): Message
                local constructor: (string) -> Message = Message.write
                return constructor("hello")
            end
        ]])

        local declaration = find_toplevel(
            ast, "Ast.TopLevelUnion", "Message")
        local union = declaration._type
        assert.equal("Type.Union", union._tag)
        assert.equal("test.Message", union.name)
        assert.equal(3, union.nvariants)
        assert.equal(0, union.variants.quit.index)
        assert.equal(1, union.variants.hidden.index)
        assert.equal(2, union.variants.write.index)
        assert.is_false(union.variants.quit.payload)
        assert.equal("Type.Integer", union.variants.hidden.payload._tag)
        assert.equal("Type.String", union.variants.write.payload._tag)
        assert.truthy(union.variants.hidden.islocal)

        assert.same({}, union.functions.quit.params)
        assert.equal("Type.String", union.functions.write.params[1]._tag)
        assert.equal("test.Message",
            union.functions.write.rettypes[1].fqtn)
        assert.is_false(union.functions.quit.paramnames)
        assert.is_false(union.functions.write.paramnames)
        assert.truthy(union.functions.hidden.islocal)

        local exported_module = assert(load(
            "return " .. types.serialize(modtype),
            "test", "t", types))()
        local exported = exported_module.members.Message.type
        assert.equal(3, exported.nvariants)
        assert.equal(2, #exported.variants)
        assert.equal(0, exported.variants.quit.index)
        assert.equal(2, exported.variants.write.index)
        assert.is_nil(exported.variants.hidden)
        assert.is_nil(exported.functions.hidden)
    end)

    it("checks case bindings, option force, and always-return analysis",
    function()
        local ast = assert_check([[
            union Message
                quit
                write: string
            end

            function inspect(message: Message?): integer
                case message
                when write: text then
                    local read = function(): string
                        return text
                    end
                    return #read()
                when quit then
                    return 0
                end
            end
        ]])

        local inspect = find_toplevel(ast, "Ast.TopLevelFunc", "inspect")
        local statement = inspect.block.stats[1]
        assert.equal("Ast.StatCase", statement._tag)
        assert.truthy(statement._always_returns)
        assert.equal("Type.Union", statement._union._tag)
        assert.equal("Ast.ExpCast", statement.exp._tag)
        assert.equal("test.Message", statement.exp._type.fqtn)
        assert.equal(1, statement.arms[1]._variant_index)
        assert.equal("Type.String",
            statement.arms[1].binding._type._tag)
        assert.truthy(statement.arms[1].binding._used)
        assert.equal(0, statement.arms[2]._variant_index)
    end)

    it("keeps a binding visible through its arm's catch and defer",
    function()
        assert_check([[
            union Message
                write: string
            end

            function use(text: string)
            end

            function inspect(message: Message)
                case message
                when write: text then
                    defer use(text)
                    use(text)
                catch
                    use(text)
                end
            end
        ]])
    end)

    it("uses complete variant coverage or else for always-return",
    function()
        local ast = assert_check([[
            union Message
                one
                local two
            end

            type MessageAlias = Message

            function complete(message: Message): integer
                case message
                when one then
                    return 1
                when two then
                    return 2
                end
            end

            function complete_alias(message: MessageAlias): integer
                case message
                when one then
                    return 1
                when two then
                    return 2
                end
            end

            function complete_with_dead_else(message: Message): integer
                case message
                when one then
                    return 1
                when two then
                    return 2
                else
                    local unreachable = 0
                end
            end

            function fallback(message: Message): integer
                case message
                when one then
                    return 1
                else
                    return 2
                end
            end
        ]])

        local complete = find_toplevel(
            ast, "Ast.TopLevelFunc", "complete")
        assert.truthy(complete.block.stats[1]._always_returns)
        local complete_alias = find_toplevel(
            ast, "Ast.TopLevelFunc", "complete_alias")
        assert.truthy(complete_alias.block.stats[1]._always_returns)
        local complete_with_dead_else = find_toplevel(
            ast, "Ast.TopLevelFunc", "complete_with_dead_else")
        assert.truthy(
            complete_with_dead_else.block.stats[1]._always_returns)
        local fallback = find_toplevel(
            ast, "Ast.TopLevelFunc", "fallback")
        assert.truthy(fallback.block.stats[1]._always_returns)

        assert_error("function can return nil but return type is not nil", [[
            union Message
                one
                two
            end

            function incomplete(message: Message): integer
                case message
                when one then
                    return 1
                end
            end
        ]])

        assert_error("function can return nil but return type is not nil", [[
            union Message
                one
                two
            end

            function incomplete(message: Message): integer
                case message
                when one then
                    return 1
                when two then
                end
            end
        ]])
    end)

    it("does not count duplicate arms toward exhaustive coverage", function()
        local err = assert_error("duplicate case arm for variant 'one'", [[
            union Message
                one
                two
            end

            function duplicate_only(message: Message): integer
                case message
                when one then
                    return 1
                when one then
                    return 2
                end
            end
        ]])
        assert.match(
            "function can return nil but return type is not nil", err)
    end)

    it("diagnoses invalid arms without creating variant value types",
    function()
        local err = assert_error(
            "empty variant 'test%.Message%.quit' has no payload to bind", [[
                union Message
                    quit
                    write: string
                end

                function inspect(message: Message)
                    case message
                    when quit: payload then
                    when missing: missing_payload then
                        local recovered = missing_payload
                    when write then
                    when write then
                    end
                end
            ]])
        assert.match("variant 'missing' not found in union 'test%.Message'", err)
        assert.match("duplicate case arm for variant 'write'", err)
        assert.is_nil(err:match(
            "variable 'missing_payload' not declared"))

        assert_error(
            "union member 'Message%.write' is not a type; use union type "
                .. "'Message' or a case statement", [[
                union Message
                    write: string
                end

                function bad(x: value): Message
                    return x as Message.write
                end
            ]])

        assert_error(
            "union member 'Message%.write' is not a type; use union type "
                .. "'Message' or a case statement", [[
                union Message
                    write: string
                end

                function bad(x: value): boolean
                    return x is Message.write
                end
            ]])

        assert_error(
            "union member 'Message%.inspect' is not a type; use union type "
                .. "'Message' or a case statement", [[
                union Message
                    quit
                end

                function Message:inspect()
                end

                function bad(x: value): boolean
                    return x is Message.inspect
                end
            ]])
    end)

    it("rejects non-unions, union field access, and record initialization",
    function()
        assert_error("case expression must have a union type", [[
            function inspect(x: value)
                case x
                when item then
                end
            end
        ]])

        assert_error(
            "case expression must have a union type, but found 'test%.Box'", [[
                record Box
                    item: integer
                end

                function inspect(box: Box)
                    case box
                    when item then
                    end
                end
            ]])

        assert_error(
            "union type 'test%.Missing' in case expression does not exist", [[
                function inspect(item: Missing)
                    case item
                    when missing then
                    end
                end
            ]])

        assert_error(
            "union value of type 'test%.Message' has no fields; "
                .. "use a case statement", [[
            union Message
                quit
            end

            function inspect(message: Message): integer
                return message.tag
            end
        ]])

        local err = assert_error(
            "union type 'test%.Message' cannot be constructed with a record "
                .. "initializer", [[
                union Message
                    quit
                end

                function make(): Message
                    return { unexpected = missing }
                end
            ]])
        assert.match("variable 'missing' not declared", err)

        assert_error(
            "trying to access union type 'test%.Message' as a first%-class "
                .. "value", [[
                union Message
                    quit
                end

                local invalid = Message
            ]])
    end)

    it("keeps variants positional and distinguishes real constructors",
    function()
        assert_error(
            "named arguments require a direct Titan module function", [[
            union Message
                write: string
            end

            function make(): Message
                return Message.write { value = "hello" }
            end
        ]])

        assert_error("top level variable initialization must be constant", [[
            union Message
                quit
            end

            function Message.fake(): Message
                return Message.quit()
            end

            local bad = Message.fake()
        ]])

        assert_error("top level variable initialization must be constant", [[
            record Box
                item: integer
            end

            function Box.fake(n: integer): Box
                return Box.new(n)
            end

            local bad = Box.fake(1)
        ]])

        assert_check([[
            union Message
                quit
                write: string
            end

            local empty = Message.quit()
            local payload = Message.write("hello")
        ]])
    end)

    it("supports union statics, methods, and their shared namespace",
    function()
        assert_check([[
            union Message
                quit
                write: string
            end

            function Message.default(): Message
                return Message.quit()
            end

            function Message:length(): integer
                return 1
            end

            function use(): integer
                local message = Message.default()
                local bound: () -> integer = message:length
                return message:length() + bound()
            end
        ]])

        local err = assert_error(
            "redeclaration of union function 'Message%.write'", [[
                union Message
                    write: string
                end

                function Message.write(text: string): Message
                    return Message.write(text)
                end

                function Message:write()
                end
            ]])
        assert.match(
            "cannot declare method 'Message:write' as union function "
                .. "'Message%.write' exists in union 'Message'", err)

        assert_error(
            "cannot declare union function 'Message%.inspect' as method "
                .. "'Message:inspect' exists in union 'Message'", [[
                union Message
                    quit
                end

                function Message:inspect()
                end

                function Message.inspect(): Message
                    return Message.quit()
                end
            ]])

        assert_error(
            "cannot declare record function 'Box%.item' as field 'item' "
                .. "exists in record 'Box'", [[
                record Box
                    item: integer
                end

                function Box.item(): integer
                    return 0
                end
            ]])
    end)

    it("rejects duplicate variants without publishing both constructors",
    function()
        local err = assert_error(
            "redeclaration of variant 'write' in union 'Message'", [[
                union Message
                    write
                    write: string
                end
            ]])
        assert.match("redeclaration of union function 'Message%.write'", err)
    end)

    it("rehydrates public variants and hides local variants", function()
        local ok, err = run_checker_modules({
            provider = [[
                union Message
                    quit
                    write: string
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function inspect(message: provider.Message): integer
                    case message
                    when quit then
                        return 0
                    when write: text then
                        return #text
                    end
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)

        local imported
        ok, err, imported = run_checker_modules({
            provider = [[
                union Message
                    quit
                    local secret: integer
                    write: string
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function inspect(message: provider.Message): integer
                    case message
                    when quit then
                        return 0
                    when write: text then
                        return #text
                    else
                        return -1
                    end
                end

                function make(): provider.Message
                    local constructor: (string) -> provider.Message =
                        provider.Message.write
                    return constructor("hello")
                end
            ]],
        }, "consumer")
        assert.truthy(ok, err)

        local union = imported.provider.type.members.Message.type
        assert.equal(3, union.nvariants)
        assert.equal(2, #union.variants)
        assert.equal(0, union.variants.quit.index)
        assert.equal(2, union.variants.write.index)
        assert.is_nil(union.variants.secret)
        assert.is_nil(union.functions.secret)

        ok, err = run_checker_modules({
            provider = [[
                union Message
                    quit
                    local secret: integer
                    write: string
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function inspect(message: provider.Message): integer
                    case message
                    when quit then
                        return 0
                    when write: text then
                        return #text
                    end
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match(
            "function can return nil but return type is not nil", err)

        ok, err = run_checker_modules({
            provider = [[
                union Message
                    quit
                    local secret: integer
                end
            ]],
            consumer = [[
                local provider = import "provider"

                function inspect(message: provider.Message)
                    case message
                    when secret then
                    end
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match(
            "variant 'secret' not found in union 'provider%.Message'", err)
    end)

    it("matches record declaration frontiers for imported union types",
    function()
        local provider = [[
            union Message
                quit
            end
        ]]
        local ok, err = run_checker_modules({
            provider = provider,
            consumer = [[
                function inspect(message: provider.Message): integer
                    return 1
                end

                local provider = import "provider"
            ]],
        }, "consumer")
        assert.truthy(ok, err)

        ok, err = run_checker_modules({
            provider = provider,
            consumer = [[
                local message: provider.Message? = nil
                local provider = import "provider"
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("module 'provider' referenced by type not found", err)

        ok, err = run_checker_modules({
            provider = provider,
            consumer = [[
                type Message = provider.Message
                local message: Message? = nil
                local provider = import "provider"
            ]],
        }, "consumer")
        assert.truthy(ok, err)
    end)

    it("requests nominal owners nested in imported map payloads", function()
        h.reset(true)

        local box_module_name = "union_map_box"
        local box_name = box_module_name .. ".Box"
        local box_nominal = types.Nominal(box_name)
        local field = types.Field(
            box_name, "item", types.Integer(), 0, false)
        local box_constructor = types.StaticMethod(
            box_name, "new", {types.Integer()}, {box_nominal},
            false, false, {"item"})
        local box = types.Record(
            box_name, {field}, {new = box_constructor}, {}, 1)
        local box_module = types.Module(box_module_name, {
            types.ModuleMember(box_module_name, "Box", box, false),
        })

        local provider_name = "union_map_provider"
        local union_name = provider_name .. ".Payload"
        local payload = types.Map(types.String(), box_nominal)
        local variant = types.Variant(
            union_name, "values", payload, 0)
        local constructor = types.StaticMethod(
            union_name, "values", {payload}, {types.Nominal(union_name)},
            false, false, false)
        local union = types.Union(
            union_name, {variant}, {values = constructor}, {}, 1)
        local provider = types.Module(provider_name, {
            types.ModuleMember(provider_name, "Payload", union, false),
        })

        local requested_box_owner = false
        local function loader(modname, request)
            if modname == provider_name then
                return true, provider, {}
            elseif modname == box_module_name then
                if request and request.kind == "nominal-owner"
                   and request.exposer == provider_name then
                    requested_box_owner = true
                end
                return true, box_module, {}
            end
            return false, "unexpected module '" .. modname .. "'"
        end

        local imported, errors = checker.checkimport(provider_name, loader)
        assert.equal(provider, imported)
        assert.same({}, errors)
        assert.truthy(requested_box_owner)
    end)

    it("makes a local union's complete namespace private", function()
        local ast, modtype = assert_check([[
            local union Internal
                hidden
                payload: integer
            end

            function Internal.make(): Internal
                return Internal.hidden()
            end

            function Internal:inspect(): integer
                return 0
            end
        ]])
        assert.is_nil(modtype.members.Internal)
        local union = find_toplevel(ast, "Ast.TopLevelUnion", "Internal")
        assert.truthy(union._type.islocal)
        for _, node in ipairs(ast) do
            if (node._tag == "Ast.TopLevelStatic"
                or node._tag == "Ast.TopLevelMethod")
               and node.class == "Internal" then
                assert.truthy(node.islocal)
                assert.truthy(node._type.islocal)
            end
        end
    end)

    it("prevents public variants from exposing local nominals", function()
        local err = assert_error(
            "cannot export local record type 'test%.Secret'", [[
                local record Secret
                    x: integer
                end

                union Public
                    exposed: Secret
                end
            ]])
        assert.match("from Titan module 'test'", err)

        assert_check([[
            local record Secret
                x: integer
            end

            union Public
                visible: integer
                local hidden: Secret
            end
        ]])
    end)

    it("uses ordinary fixed-call adjustment for constructor payloads",
    function()
        assert_check([[
            union Message
                optional: string?
                empty
            end

            local nil_filled = Message.optional()
            local surplus = Message.empty(1, 2, 3)
        ]])

        assert_error(
            "types in argument 1 of call to function 'Message%.optional' "
                .. "do not match, expected string%? but found integer", [[
                union Message
                    optional: string?
                end

                local invalid = Message.optional(1)
            ]])
    end)
end)

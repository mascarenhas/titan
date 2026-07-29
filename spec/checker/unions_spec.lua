local h = require "spec.support.helpers"
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
                else
                    return -1
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

    it("keeps a binding visible through its arm's catch, finally, and defer",
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
                finally
                    use(text)
                end
            end
        ]])
    end)

    it("keeps case arms optional and requires else for always-return",
    function()
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
                    return 2
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
                else
                    return 0
                end
            end
        ]])
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
                    when missing then
                    when write then
                    when write then
                    end
                end
            ]])
        assert.match("variant 'missing' not found in union 'test%.Message'", err)
        assert.match("duplicate case arm for variant 'write'", err)

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
            "union value of type 'test%.Message' has no fields; "
                .. "use a case statement", [[
            union Message
                quit
            end

            function inspect(message: Message): integer
                return message.tag
            end
        ]])

        assert_error(
            "union type 'test%.Message' cannot be constructed with a record "
                .. "initializer", [[
                union Message
                    quit
                end

                function make(): Message
                    return {}
                end
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
    end)

    it("rehydrates public variants and hides local variants", function()
        local ok, err, imported = run_checker_modules({
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

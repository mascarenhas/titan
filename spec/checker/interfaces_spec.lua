local temporary = require "spec.support.temporary"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function find_toplevel(ast, tag, name)
    for _, node in ipairs(ast) do
        if node._tag == tag and node.name == name then
            return node
        end
    end
    error(string.format("could not find %s '%s'", tag, name))
end

local function find_function(ast, name)
    return find_toplevel(ast, "Ast.TopLevelFunc", name)
end

describe("interfaces (typechecker)", function()
    it("builds one ordered type-only descriptor and boundary plans", function()
        local ok, err, ast, modtype = run_checker([[
            interface Stream
                function close()
                function write(data: string, ...: integer): (integer, ...: value)
            end
        ]])
        assert.truthy(ok, err)

        local declaration = find_toplevel(
            ast, "Ast.TopLevelInterface", "Stream")
        local interface = declaration._type
        assert.equal("Type.Interface", interface._tag)
        assert.equal("test.Stream", interface.name)
        assert.equal(2, #interface.methods)
        assert.is_true(interface.methods[1] == interface.methods.close)
        assert.is_true(interface.methods[2] == interface.methods.write)
        assert.same({"data"}, interface.methods.write.paramnames)
        assert.equal("Type.Integer",
            interface.methods.write.varargtype._tag)
        assert.equal("Type.Value",
            interface.methods.write.flexrettype._tag)

        local method = declaration.methods[2]
        assert.is_true(method._type == interface.methods.write)
        assert.equal(2, #method._lua_dynamic_plans)
        assert.equal("nominal", method._lua_dynamic_plans[1].value.op)
        assert.equal("string", method._lua_dynamic_plans[2].value.op)
        assert.equal("integer", method._lua_vararg_dynamic_plan.value.op)
        assert.equal(1, #method._bound_strict_guard_plans)
        assert.equal("just", method._bound_strict_vararg_guard_plan.tag)

        assert.is_true(modtype.type_members.Stream ==
            declaration._declared_type)
        assert.not_equal(declaration._declared_type, interface)
        assert.is_true(ast._erased_registry["test.Stream"] == interface)
        assert.is_nil(modtype.members.Stream)
    end)

    it("builds independent ordered field and method slots", function()
        local ok, err, ast = run_checker([[
            interface Entry<|T|>
                first: T
                function reset()
                optional: T?
                function show(): string
            end
        ]])
        assert.truthy(ok, err)

        local declaration = find_toplevel(
            ast, "Ast.TopLevelInterface", "Entry")
        local interface = declaration._declared_type
            or declaration._type
        assert.equal(2, #interface.fields)
        assert.equal(2, #interface.methods)
        assert.equal("first", interface.fields[1].name)
        assert.equal(0, interface.fields[1].index)
        assert.is_true(interface.fields[1].isconst)
        assert.equal("optional", interface.fields[2].name)
        assert.equal(1, interface.fields[2].index)
        assert.equal("reset", interface.methods[1].name)
        assert.equal("show", interface.methods[2].name)
        assert.is_true(interface.fields.first == interface.fields[1])
        assert.is_true(interface.methods.show == interface.methods[2])
        assert.equal("Type.Parameter", interface.fields.first.type._tag)
        assert.equal("Type.Option", interface.fields.optional.type._tag)

        assert.equal("first", declaration.members[1].name)
        assert.equal("reset", declaration.members[2].name)
        assert.equal("optional", declaration.members[3].name)
        assert.equal("show", declaration.members[4].name)
    end)

    it("matches const record fields and freezes snapshot adjustments", function()
        local ok, err, ast = run_checker([[
            interface Inner
                amount: float
            end

            interface Outer
                inner: Inner
                label: string?
                function reset()
            end

            record InnerRecord
                const amount: integer
            end

            record OuterRecord
                const label: string
                const inner: InnerRecord
            end

            function OuterRecord:reset()
            end

            function wrap(item: OuterRecord): Outer
                return item
            end

            function read(view: Outer): (float, string?)
                return view.inner.amount, view.label
            end

            function implements(item: OuterRecord): boolean
                return item is Outer
            end
        ]])
        assert.truthy(ok, err)

        local conversion = find_function(ast, "wrap")
            .block.stats[1].exps[1]._interface_conversion
        assert.equal("interface_conversion", conversion.kind)
        assert.equal(2, #conversion.fields)
        assert.equal(1, #conversion.methods)
        assert.is_false(conversion.exact)

        local outer_declaration = find_toplevel(
            ast, "Ast.TopLevelInterface", "Outer")
        assert.equal("nominal",
            outer_declaration._dynamic_receiver_plan.op)
        assert.equal("nominal",
            outer_declaration.fields[1]._dynamic_plan.value.op)
        assert.equal("option",
            outer_declaration.fields[2]._dynamic_plan.value.op)

        local inner = conversion.fields[1]
        assert.equal("inner", inner.name)
        assert.equal(1, inner.source_index)
        assert.equal(0, inner.target_index)
        assert.equal("direct_coercion", inner.adjustment.kind)
        assert.equal("interface_conversion",
            inner.adjustment.interface_conversion.kind)
        assert.equal("test.InnerRecord",
            inner.adjustment.interface_conversion.concrete.name)
        assert.equal("test.Inner",
            inner.adjustment.interface_conversion.interface.name)
        local nested = inner.adjustment.coercion
        assert.equal("interface_wrapper", nested.op)
        assert.equal("interface_implementation",
            nested.implementation.kind)
        assert.equal("amount", nested.fields[1].name)
        assert.equal(0, nested.fields[1].source_index)
        assert.equal(0, nested.fields[1].target_index)
        assert.equal("direct_coercion",
            nested.fields[1].adjustment.kind)

        local label = conversion.fields[2]
        assert.equal("label", label.name)
        assert.equal(0, label.source_index)
        assert.equal(1, label.target_index)
        assert.equal("direct_coercion", label.adjustment.kind)
        assert.equal("option_wrap", label.adjustment.coercion.op)

        local read = find_function(ast, "read").block.stats[1].exps
        assert.equal("amount", read[1].var._interface_field.name)
        assert.equal(0, read[1].var._interface_field_index)
        assert.equal("label", read[2].var._interface_field.name)
        assert.equal(1, read[2].var._interface_field_index)

        local test = find_function(ast, "implements")
            .block.stats[1].exps[1]._interface_test
        assert.equal("interface_implementation_test", test.kind)
        assert.is_true(test.allocation_free)
        assert.equal(2, #test.conversion.fields)
    end)

    it("requires visible compatible const record fields", function()
        local cases = {
            {
                source = [[
                    interface View
                        item: integer
                    end
                    record Missing
                    end
                    function wrap(record_: Missing): View
                        return record_
                    end
                ]],
                message = "const field 'item' is missing",
            },
            {
                source = [[
                    interface View
                        item: integer
                    end
                    record Mutable
                        item: integer
                    end
                    function wrap(record_: Mutable): View
                        return record_
                    end
                ]],
                message = "field 'item' is mutable; a const field is required",
            },
            {
                source = [[
                    interface View
                        item: integer
                    end
                    record Wrong
                        const item: string
                    end
                    function wrap(record_: Wrong): View
                        return record_
                    end
                ]],
                message = "field 'item' has incompatible type 'string'; expected 'integer'",
            },
            {
                source = [[
                    interface View
                        item: integer
                    end
                    record Collision
                    end
                    function Collision:item(): integer
                        return 1
                    end
                    function wrap(record_: Collision): View
                        return record_
                    end
                ]],
                message = "member 'item' is not a field",
            },
            {
                source = [[
                    interface View
                        item: integer
                    end
                    union Choice
                        none()
                    end
                    function wrap(choice: Choice): View
                        return choice
                    end
                ]],
                message = "interface fields require a record implementation",
            },
        }
        for _, case in ipairs(cases) do
            local ok, err = run_checker(case.source)
            assert.falsy(ok)
            assert.match(case.message, err)
        end

        local ok, err = run_checker_modules({
            owner = [[
                interface View
                    item: integer
                end
                record Record
                    local const item: integer
                end
            ]],
            consumer = [[
                local owner = import "owner"
                function wrap(record_: owner.Record): owner.View
                    return record_
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("field 'item' is local to module 'owner'", err)
    end)

    it("lowers applied generic Interface field snapshots and reads", function()
        local ok, err, ast = run_checker([[
            interface Box<|T|>
                contents: T
            end

            record IntegerBox
                const contents: integer
            end

            function wrap(box: IntegerBox): Box<|integer|>
                return box
            end

            function read(box: Box<|integer|>): integer
                return box.contents
            end
        ]])
        assert.truthy(ok, err)

        local conversion = find_function(ast, "wrap")
            .block.stats[1].exps[1]._interface_conversion
        assert.equal("Type.Value", conversion.fields[1].target._tag)
        assert.equal("gradual_view",
            conversion.fields[1].adjustment.kind)
        assert.equal("inject", conversion.fields[1].adjustment.op)

        local returned = find_function(ast, "read")
            .block.stats[1].exps[1]
        assert.equal("Ast.ExpCast", returned._tag)
        assert.equal("Type.Integer", returned._type._tag)
        assert.equal("contents",
            returned.exp.var._interface_field.name)
        assert.equal(0, returned.exp.var._interface_field_index)

        ok, err, ast = run_checker([[
            interface Box<|T|>
                contents: T
            end

            record IntegerBox
                const contents: integer
            end

            function constrained<|T: Box<|integer|>|>(box: T): integer
                return box.contents
            end

            function apply(box: IntegerBox): integer
                return constrained(box)
            end
        ]])
        assert.truthy(ok, err)
        returned = find_function(ast, "constrained")
            .block.stats[1].exps[1]
        assert.equal("Ast.ExpCast", returned._tag)
        assert.equal("Type.Integer", returned._type._tag)
        assert.equal("contents",
            returned.exp.var._interface_field.name)
    end)

    it("freezes callable Interface field snapshot adapters", function()
        local ok, err, ast = run_checker([[
            interface CallbackView
                callback: function (integer): integer
            end

            record CallbackRecord
                const callback: function (value): value
            end

            function wrap(record_: CallbackRecord): CallbackView
                return record_
            end
        ]])
        assert.truthy(ok, err)

        local mapping = find_function(ast, "wrap")
            .block.stats[1].exps[1]
            ._interface_conversion.fields[1]
        assert.equal("callable", mapping.adjustment.kind)
        assert.equal("callable_adapter_plan",
            mapping.adjustment._callable_adapter.kind)
        assert.equal("gradual_inject",
            mapping.adjustment._callable_adapter
                .arguments[1].operation.kind)
        assert.equal("gradual_guard",
            mapping.adjustment._callable_adapter
                .results[1].operation.kind)
    end)

    it("rejects Interface field writes and cross-kind collisions", function()
        local ok, err = run_checker([[
            interface View
                item: integer
            end
            function mutate(view: View)
                view.item = 2
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot assign to const field 'item'", err)

        ok, err = run_checker([[
            interface Duplicate
                item: integer
                function item(): integer
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "member 'item' in interface 'Duplicate' is declared as both a field and a method",
            err)
    end)

    it("keeps Interface names out of the value namespace", function()
        local ok, err, _, modtype = run_checker([[
            interface Item
                function get(): integer
            end

            Item = 41

            function read(item: Item): integer
                return Item
            end
        ]])
        assert.truthy(ok, err)
        assert.equal("Type.Interface",
            modtype.type_members.Item._tag)
        assert.equal("Type.ModuleVariable",
            modtype.members.Item._tag)

        ok, err = run_checker([[
            interface Reader
                function read(): string
            end

            function bad(): value
                return Reader
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "interface 'Reader' is a type and has no runtime value", err)
    end)

    it("resolves imported Interface types but not expression members", function()
        local modules = {
            api = [[
                interface Reader
                    label: string
                    function read(): string
                end
            ]],
            consumer = [[
                local api = import "api"

                function accept(reader: api.Reader): api.Reader
                    return reader
                end

                function label(reader: api.Reader): string
                    return reader.label
                end
            ]],
        }
        local ok, err, imported =
            run_checker_modules(modules, "consumer")
        assert.truthy(ok, err)
        assert.equal("Type.Interface",
            imported.api.type.type_members.Reader._tag)

        modules.consumer = [[
            local api = import "api"

            function bad(): value
                return api.Reader
            end
        ]]
        ok, err = run_checker_modules(modules, "consumer")
        assert.falsy(ok)
        assert.match(
            "interface 'Reader' is a type and has no runtime value", err)
    end)

    it("preserves aliases and forward nominal references", function()
        local ok, err, ast = run_checker([[
            type ReaderAlias = Reader

            interface Reader
                function pair(other: Writer): Writer
            end

            interface Writer
                function pair(other: Reader): ReaderAlias
            end

            function identity(reader: ReaderAlias): Reader
                return reader
            end
        ]])
        assert.truthy(ok, err)
        local reader = find_toplevel(
            ast, "Ast.TopLevelInterface", "Reader")._type
        local writer = find_toplevel(
            ast, "Ast.TopLevelInterface", "Writer")._type
        assert.equal("test.Writer",
            reader.methods.pair.params[1].fqtn)
        assert.equal("test.Reader",
            writer.methods.pair.rettypes[1].fqtn)
        assert.equal(
            find_function(ast, "identity")._type.params[1].fqtn,
            find_function(ast, "identity")._type.rettypes[1].fqtn)
    end)

    it("annotates every implicit scalar and Option conversion", function()
        local ok, err, ast = run_checker([[
            interface Reader
                function read(index: integer): string
            end

            record Buffer
            end

            function Buffer:read(index: integer): string
                return "buffer"
            end

            function accept(reader: Reader): Reader
                return reader
            end

            function convert(
                buffer: Buffer,
                optional: Buffer?
            ): Reader
                local direct: Reader = buffer
                local wrapped: Reader? = buffer
                local forced: Reader = optional
                local mapped: Reader? = optional
                accept(buffer)
                return buffer
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(ast, "convert").block.stats
        local conversions = {
            stats[1].exps[1],
            stats[2].exps[1],
            stats[3].exps[1],
            stats[4].exps[1],
            stats[5].callexp.args.args[1],
            stats[6].exps[1],
        }
        assert.same({
            "interface_wrapper",
            "option_wrap",
            "option_force",
            "option_map",
            "interface_wrapper",
            "interface_wrapper",
        }, (function()
            local operations = {}
            for index, exp in ipairs(conversions) do
                assert.equal("Ast.ExpCast", exp._tag)
                assert.is_true(exp._implicit_coercion)
                local conversion = exp._interface_conversion
                assert.equal("interface_conversion", conversion.kind)
                assert.equal("test.Buffer", conversion.concrete.name)
                assert.equal("test.Reader", conversion.interface.name)
                assert.equal("test.Buffer",
                    conversion.concrete_type.fqtn)
                assert.equal("test.Reader",
                    conversion.interface_type.fqtn)
                assert.equal("read", conversion.methods[1].name)
                assert.is_true(conversion.exact)
                assert.is_true(
                    exp._adjustment.interface_conversion == conversion)
                operations[index] = conversion.option
            end
            return operations
        end)())
        assert.is_true(
            conversions[2]._interface_conversion.target_optional)
        assert.is_true(
            conversions[3]._interface_conversion.source_optional)
        assert.is_true(
            conversions[4]._interface_conversion.nil_propagates)
    end)

    it("threads the same conversion through the remaining typed sinks", function()
        local ok, err, ast = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end

            record Holder
                item: Item
            end

            union Box
                some(Item)
            end

            function named(item: Item)
            end

            module_item: Item = Concrete.new()

            function sinks(concrete: Concrete)
                local current: Item = concrete
                current = concrete
                local holder: Holder = Holder.new(concrete)
                local array: {Item} = { concrete }
                local map: {Item : Item} = {
                    [concrete] = concrete,
                }
                local box: Box = Box.some(concrete)
                named{ item = concrete }
            end

            function step(state: Item, control: Item): Item?
                return nil
            end

            function iterate(concrete: Concrete)
                for item: Item in step, concrete, concrete do
                end
            end
        ]])
        assert.truthy(ok, err)

        local module_item = find_toplevel(
            ast, "Ast.TopLevelVar", nil)
        local sinks = find_function(ast, "sinks").block.stats
        local expressions = {
            module_item.value,
            sinks[1].exps[1],
            sinks[2].exps[1],
            sinks[3].exps[1].args.args[1],
            sinks[4].exps[1].fields[1].exp,
            sinks[5].exps[1].fields[1].name,
            sinks[5].exps[1].fields[1].exp,
            sinks[6].exps[1].args.args[1],
            sinks[7].callexp.args.args[1],
        }
        for _, exp in ipairs(expressions) do
            assert.equal("interface_conversion",
                exp._interface_conversion.kind)
        end

        local forin = find_function(ast, "iterate")
            .block.stats[1]
        assert.equal("interface_conversion",
            forin.exps[2]._interface_conversion.kind)
        assert.equal("interface_conversion",
            forin.exps[3]._interface_conversion.kind)
    end)

    it("reports the first failed Interface method deterministically", function()
        local ok, err = run_checker([[
            interface Needs
                function first(): integer
                function second(): string
            end

            record Missing
            end

            function convert(item: Missing): Needs
                return item
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "record 'test%.Missing' does not implement interface "
                .. "'test%.Needs': method 'first' is missing",
            err)

        ok, err = run_checker([[
            interface Needs
                function first(): integer
            end

            record Collision
                first: integer
            end

            function convert(item: Collision): Needs
                return item
            end
        ]])
        assert.falsy(ok)
        assert.match("member 'first' is not a method", err)

        ok, err = run_checker([[
            interface Needs
                function first(input: integer): integer
            end

            record Wrong
            end

            function Wrong:first(input: string): integer
                return 0
            end

            function convert(item: Wrong): Needs
                return item
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "method 'first' has incompatible type", err)
        assert.match("expected", err)
    end)

    it("uses cast-site visibility for local concrete methods", function()
        local ok, err = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            local function Concrete:get(): integer
                return 1
            end

            function owner_cast(concrete: Concrete): Item
                return concrete
            end
        ]])
        assert.truthy(ok, err)

        ok, err = run_checker_modules({
            owner = [[
                interface Item
                    function get(): integer
                end

                record Concrete
                end

                local function Concrete:get(): integer
                    return 1
                end
            ]],
            consumer = [[
                local owner = import "owner"

                function external_cast(
                    concrete: owner.Concrete
                ): owner.Item
                    return concrete
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        -- The compiled facade grants no source capability even when this
        -- in-memory test has already registered the owner's rich descriptor.
        assert.match("method 'get' is local to module 'owner'", err)
    end)

    it("ignores concrete parameter names and accepts union methods", function()
        local ok, err, ast = run_checker([[
            interface Pair
                function put(x: integer, y: string)
            end

            union Either
                empty()
                number(integer)
            end

            function Either:put(y: integer, x: string)
            end

            function wrap(either: Either): Pair
                return either
            end
        ]])
        assert.truthy(ok, err)
        local conversion = find_function(ast, "wrap")
            .block.stats[1].exps[1]._interface_conversion
        assert.equal("Type.Union", conversion.concrete._tag)
        assert.same({"x", "y"},
            conversion.methods[1].required.paramnames)
        assert.same({"y", "x"},
            conversion.methods[1].concrete.paramnames)
        assert.is_true(conversion.exact)
    end)

    it("checks explicit construction, tests, and concrete downcasts", function()
        local ok, err, ast = run_checker([[
            interface Reader
                function read(): string
            end

            record Buffer
            end

            function Buffer:read(): string
                return "buffer"
            end

            record Other
            end

            function casts(
                buffer: Buffer,
                reader: Reader,
                optional: Reader?,
                dynamic: value
            ): boolean
                local built: Reader = buffer as Reader
                local concrete: Buffer = reader as Buffer
                local forced: Buffer = optional as Buffer
                local other: Other = reader as Other
                local exact: Reader = dynamic as Reader
                local is_buffer = reader is Buffer
                local optional_is_buffer = optional is Buffer
                return buffer is Reader
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(ast, "casts").block.stats
        local built = stats[1].exps[1]
        assert.equal("coercion", built._written_cast.value.op)
        assert.equal("interface_conversion",
            built._interface_conversion.kind)

        for index = 2, 3 do
            local downcast = stats[index].exps[1]
            assert.equal("interface_downcast",
                downcast._written_cast.value.op)
            assert.equal("interface_downcast",
                downcast._interface_downcast.kind)
        end
        assert.is_false(stats[2].exps[1]
            ._interface_downcast.source_optional)
        assert.is_true(stats[3].exps[1]
            ._interface_downcast.source_optional)

        local runtime_failure = stats[4].exps[1]
        assert.equal("test.Other",
            runtime_failure._interface_downcast.concrete.name)

        local exact = stats[5].exps[1]
        assert.equal("dynamic", exact._written_cast.value.op)
        assert.equal("nominal",
            exact._written_cast.value.dynamic.op)

        local scalar_is = stats[6].exps[1]
        assert.equal("interface_downcast_test",
            scalar_is._interface_test.kind)
        assert.is_false(
            scalar_is._interface_downcast.source_optional)
        local optional_is = stats[7].exps[1]
        assert.equal("interface_downcast_test",
            optional_is._interface_test.kind)
        assert.is_true(
            optional_is._interface_downcast.source_optional)

        local test = stats[8].exps[1]
        assert.equal("interface_implementation_test",
            test._interface_test.kind)
        assert.is_true(test._interface_test.allocation_free)

        ok, err = run_checker([[
            interface Reader
                function read(): string
            end

            record Empty
            end

            function invalid(item: Empty): boolean
                return item is Reader
            end
        ]])
        assert.falsy(ok)
        assert.match("method 'read' is missing", err)
    end)

    it("keeps dynamic checks exact and distinct Interfaces unrelated", function()
        local ok, err, ast = run_checker([[
            interface Left
                function get(): integer
            end

            interface Right
                function get(): integer
            end

            function dynamic(
                value_: value,
                optional: Left?
            ): boolean
                local left: Left? = value_ as Left?
                local forced: Left = optional as Left
                return value_ is Left
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(ast, "dynamic").block.stats
        assert.equal("dynamic",
            stats[1].exps[1]._written_cast.value.op)
        assert.equal("option",
            stats[1].exps[1]._written_cast.value.dynamic.op)
        assert.equal("coercion",
            stats[2].exps[1]._written_cast.value.op)
        assert.equal("dynamic",
            stats[3].exps[1]._written_cast.value.op)

        ok, err = run_checker([[
            interface Left
                function get(): integer
            end

            interface Right
                function get(): integer
            end

            function invalid(left: Left): Right
                return left as Right
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot cast 'test%.Left' to 'test%.Right'", err)
    end)

    it("uses Interface method order and names for calls and bindings", function()
        local ok, err, ast = run_checker([[
            interface Pair
                function reset()
                function put(x: integer, y: string): string
            end

            function use(pair: Pair, optional: Pair?): string
                pair:reset()
                local named: string = pair:put{
                    y = "second",
                    x = 1,
                }
                local forced: string = optional:put(2, "value")
                local bound: function (integer, string): string = pair:put
                return named
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(ast, "use").block.stats
        assert.equal(0, stats[1].callexp._interface_method_index)
        local named = stats[2].exps[1]
        assert.equal(1, named._interface_method_index)
        assert.same({2, 1}, named._named_arg_order)
        assert.equal("put", named._interface_method.name)
        assert.equal(1, stats[3].exps[1]
            ._interface_method_index)
        assert.equal("Ast.ExpCast",
            stats[3].exps[1].exp._tag)

        local bound = stats[4].exps[1]
        assert.equal("Ast.ExpMethodRef", bound._tag)
        assert.is_true(bound._interface_bound)
        assert.equal(1, bound._interface_method_index)
        assert.equal("Type.Function", bound._type._tag)

        ok, err = run_checker([[
            interface Required
                function use(input: integer)
            end

            function missing(required: Required)
                required:use{}
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "parameter 'input' of type integer cannot be omitted", err)
    end)

    it("rejects access to an undeclared Interface field", function()
        local ok, err = run_checker([[
            interface Item
                function get(): integer
            end

            function invalid(item: Item): integer
                return item.data
            end
        ]])
        assert.falsy(ok)
        assert.match(
            "field 'data' not found in interface 'test%.Item'", err)
    end)

    it("retains checked Interface conversions on open result runs", function()
        local ok, err, ast = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end

            function produce(item: Concrete): (...: Concrete)
                return item
            end

            function consume(...: Item)
            end

            function collect(item: Concrete): {Item}
                consume(produce(item))
                local values: {Item} = { produce(item) }
                return values
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(ast, "collect").block.stats
        local call = stats[1].callexp
        local call_conversion =
            call._open_args.adjustment.interface_conversion
        assert.equal("interface_conversion",
            call_conversion.kind)
        assert.equal("test.Concrete",
            call_conversion.concrete.name)

        local initializer = stats[2].exps[1]
        local positional = initializer._positional_adjustment
        assert.is_true(
            positional.open_adjustment.interface_conversion
                == positional.open_interface_conversion)
        assert.equal("interface_wrapper",
            positional.open_interface_conversion.option)
    end)

    it("keeps Interface conversion scalar instead of lifting it", function()
        local ok, err = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end

            function bad_array(values: {Concrete}): {Item}
                return values
            end
        ]])
        assert.falsy(ok)
        assert.match("types in return do not match", err)

        ok, err = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end

            function make(): Concrete
                return Concrete.new()
            end

            function bad_function()
                local producer: function (): Item = make
            end
        ]])
        assert.falsy(ok)
        assert.match("types in declaration of local variable producer do not match",
            err)

        ok, err = run_checker([[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function bad_reverse(item: Item): Concrete
                return item
            end
        ]])
        assert.falsy(ok)
        assert.match("types in return do not match", err)
    end)

    it("does not broaden the written Option cast table", function()
        local prelude = [[
            interface Item
                function get(): integer
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end
        ]]
        local rejected = {
            [[
                function cast(item: Concrete?): Item
                    return item as Item
                end
            ]],
            [[
                function cast(item: Concrete): Item?
                    return item as Item?
                end
            ]],
            [[
                function cast(item: Concrete?): Item?
                    return item as Item?
                end
            ]],
            [[
                function cast(item: Item): Concrete?
                    return item as Concrete?
                end
            ]],
            [[
                function cast(item: Item?): Concrete?
                    return item as Concrete?
                end
            ]],
        }
        for _, body in ipairs(rejected) do
            local ok, err = run_checker(prelude .. body)
            assert.falsy(ok)
            assert.match("cannot cast", err)
        end

        local ok, err = run_checker(prelude .. [[
            function accepted(
                item: Item?,
                dynamic: value
            ): Item
                local exact: Item? = dynamic as Item?
                return item as Item
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("enforces the shared type namespace and signature exports", function()
        local conflicts = {
            [[
                type Same = integer
                interface Same
                    function get()
                end
            ]],
            [[
                interface Same
                    function get()
                end
                type Same = integer
            ]],
            [[
                interface Same
                    function get()
                end
                record Same
                end
            ]],
            [[
                union Same
                    one()
                end
                interface Same
                    function get()
                end
            ]],
        }
        for _, source in ipairs(conflicts) do
            local ok, err = run_checker(source)
            assert.falsy(ok)
            assert.match("conflicts with", err)
        end

        local ok, err = run_checker([[
            interface Duplicate
                function get(input: integer, input: string)
                function get()
            end
        ]])
        assert.falsy(ok)
        assert.match("duplicate parameter 'input'", err)
        assert.match(
            "redeclaration of method 'get' in interface 'Duplicate'", err)

        ok, err = run_checker([[
            local record Hidden
            end

            interface Public
                function use(hidden: Hidden)
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot export local record type 'test%.Hidden'", err)
    end)

    it("rejects C FFI types anywhere in a public Interface signature",
    function()
        with_header("typedef int ffi_int;\n", function(header)
            local session = h.new_checker_probe_session()
            local ok, err
            local ran, failure = pcall(function()
                ok, err = h.run_checker([[
                foreign import "]] .. header .. [["

                interface Foreign
                    function use(input: foreign ffi_int): foreign ffi_int
                end
                ]], session)
            end)
            h.close_checker_probe_session(session)
            assert.is_true(ran, failure)
            assert.falsy(ok)
            assert.match("cannot export C FFI type '.-ffi_int'", err)
        end)
    end)

    it("freezes visible local C scalar views but rejects raw pointers",
    function()
        with_header("typedef int ffi_int;\n", function(header)
            local session = h.new_checker_probe_session()
            local ran, failure = pcall(function()
                local ok, err, ast = h.run_checker([[
                foreign import "]] .. header .. [["

                interface DynamicC
                    function adapt(input: value): value
                end

                record Concrete
                end

                local function Concrete:adapt(
                    input: foreign ffi_int
                ): foreign ffi_int
                    return input
                end

                function wrap(value_: Concrete): DynamicC
                    return value_
                end
                ]], session)
                assert.truthy(ok, err)
                local adapter = find_function(ast, "wrap")
                    .block.stats[1].exps[1]
                    ._interface_conversion.methods[1]
                    .interface_adapter
                assert.equal("gradual_guard",
                    adapter.arguments[1].operation.kind)
                assert.equal("c_integer",
                    adapter.arguments[1].operation.guard.op)
                assert.equal("gradual_inject",
                    adapter.results[1].operation.kind)

                ok, err = h.run_checker([[
                foreign import "]] .. header .. [["

                interface DynamicC
                    function adapt(input: value)
                end

                record Concrete
                end

                local function Concrete:adapt(
                    input: foreign *ffi_int
                )
                end

                function wrap(value_: Concrete): DynamicC
                    return value_
                end
                ]], session)
                assert.falsy(ok)
                assert.match("method 'adapt' has incompatible type", err)
            end)
            h.close_checker_probe_session(session)
            assert.is_true(ran, failure)
        end)
    end)

    it("freezes the complete callable shape matrix for adapters", function()
        local ok, err, ast = run_checker([[
            interface Matrix
                function exact(x: integer): integer
                function ignore(x: integer, extra: string)
                function fill(x: integer)
                function tailfill(x: integer, ...: value)
                function gather(x: integer, y: integer)
                function passthrough_args(...: value)
                function discardtail(x: integer, ...: string)
                function hide()
                function flex_optional(): integer?
                function flex_required(): integer
                function collect(): (integer, ...: integer)
                function stop()
                function passthrough(): (...: value)
                function empty(): (...: integer)
            end

            record Concrete
            end

            function Concrete:exact(x: integer): integer
                return x
            end

            function Concrete:ignore(x: integer)
            end

            function Concrete:fill(x: integer, missing: integer?)
            end

            function Concrete:tailfill(
                x: integer,
                missing: integer?
            )
            end

            function Concrete:gather(x: integer, ...: integer)
            end

            function Concrete:passthrough_args(...: integer)
            end

            function Concrete:discardtail(x: integer)
            end

            function Concrete:hide(): integer
                return 1
            end

            function Concrete:flex_optional(): (...: integer)
            end

            function Concrete:flex_required(): (...: integer)
            end

            function Concrete:collect(): (integer, integer)
                return 1, 2
            end

            function Concrete:stop(): (...: integer)
            end

            function Concrete:passthrough(): (...: integer)
            end

            function Concrete:empty()
            end

            function wrap(value_: Concrete): Matrix
                return value_
            end

            function implements(value_: Concrete): boolean
                return value_ is Matrix
            end
        ]])
        assert.truthy(ok, err)

        local conversion = find_function(ast, "wrap")
            .block.stats[1].exps[1]._interface_conversion
        assert.is_false(conversion.exact)

        local methods = {}
        for _, mapping in ipairs(conversion.methods) do
            methods[mapping.name] = mapping
        end

        assert.equal("exact", methods.exact.slot_kind)
        assert.is_nil(methods.exact.interface_adapter)
        assert.is_true(methods.exact.adjustment.exact)

        local function adapter(name)
            local mapping = methods[name]
            assert.equal("adapter", mapping.slot_kind)
            assert.is_false(mapping.exact)
            local plan = assert(mapping.interface_adapter)
            assert.equal("interface_method_adapter", plan.kind)
            assert.equal(mapping.index, plan.slot)
            assert.equal(mapping.required, plan.native_signature)
            assert.equal(mapping.target, plan.interface_signature)
            assert.equal(mapping.concrete, plan.concrete_method)
            assert.equal(mapping.source, plan.concrete_signature)
            assert.equal("test", plan.concrete_owner_module)
            assert.equal(
                "adapter_owner_module",
                plan.hidden_operands.concrete_owner_module.provenance)
            assert.equal("NULL",
                plan.hidden_operands.closure.concrete_call_value)
            assert.is_true(
                plan.hidden_operands.self.forwards_unchanged)
            assert.is_true(plan.relation_free)
            assert.is_true(plan.no_nested_interface_conversions)
            assert.is_true(plan.uses_base_off)
            assert.equal("after_native_call",
                plan.rebase_points[
                    #plan.rebase_points].kind)
            assert.is_false(
                plan.rooting.raw_descriptors_are_roots)
            assert.is_false(plan.rooting.raw_buffers_are_roots)
            return plan
        end

        local ignore = adapter("ignore")
        assert.same({"argument", "ignore_argument"},
            (function()
                local kinds = {}
                for _, action in ipairs(ignore.arguments) do
                    kinds[#kinds + 1] = action.kind
                end
                return kinds
            end)())
        assert.equal("evaluate_and_discard",
            ignore.arguments[2].effect)

        local fill = adapter("fill")
        assert.equal("nil_fill", fill.arguments[2].kind)
        assert.is_true(fill.arguments[2].admissible)
        assert.equal("nil_fill",
            fill.arguments[2].missing_arm.kind)

        local tailfill = adapter("tailfill")
        assert.same({
            "argument",
            "tail_or_nil_to_argument",
            "ignore_tail",
        }, (function()
            local kinds = {}
            for _, action in ipairs(tailfill.arguments) do
                kinds[#kinds + 1] = action.kind
            end
            return kinds
        end)())
        assert.equal(1,
            tailfill.arguments[2].expected_tail_offset)
        assert.equal("nil_fill",
            tailfill.arguments[2].missing_arm.kind)
        assert.equal("gradual_guard",
            tailfill.arguments[2].operation.kind)
        assert.equal("project",
            tailfill.arguments[2].operation.mode)
        assert.equal("option",
            tailfill.arguments[2].operation.guard.op)
        assert.is_false(
            tailfill.rooting.ranges.argument_source.traced)
        assert.is_false(
            tailfill.rooting.ranges.argument_source
                .raw_storage_is_root)
        assert.equal("after_action",
            tailfill.rebase_points[1].kind)
        assert.equal("argument:2",
            tailfill.rebase_points[1].action)
        assert.equal("after_native_call",
            tailfill.rebase_points[2].kind)

        local gather = adapter("gather")
        assert.equal("argument_to_tail",
            gather.arguments[2].kind)
        assert.equal("empty_tail",
            gather.arguments[3].kind)
        assert.is_nil(gather.arguments[3][1])
        assert.is_true(
            gather.rooting.ranges.argument_destination.present)
        assert.is_false(
            gather.rooting.ranges.argument_destination.traced)

        local passthrough_args = adapter("passthrough_args")
        assert.equal("tail_to_tail",
            passthrough_args.arguments[1].kind)
        assert.equal(0,
            passthrough_args.arguments[1]
                .expected_tail_consumed)
        assert.equal("gradual_guard",
            passthrough_args.arguments[1].operation.kind)

        local discardtail = adapter("discardtail")
        assert.equal("ignore_tail",
            discardtail.arguments[2].kind)
        assert.equal("evaluate_run_and_discard",
            discardtail.arguments[2].effect)

        local hide = adapter("hide")
        assert.equal("hide_result", hide.results[1].kind)
        assert.equal("discard", hide.results[1].effect)

        local optional = adapter("flex_optional")
        assert.equal("flex_to_optional_result",
            optional.results[1].kind)
        assert.is_true(optional.results[1].wrap_present)
        assert.equal("nil_fill",
            optional.results[1].missing_arm.kind)
        assert.equal("identity",
            optional.results[1].operation.kind)
        assert.equal("hide_flex",
            optional.results[2].kind)

        local required = adapter("flex_required")
        assert.equal("flex_to_result",
            required.results[1].kind)
        assert.equal("raise_missing_result",
            required.results[1].missing_arm.kind)

        local collect = adapter("collect")
        assert.same({
            "result", "result_to_flex", "end_flex",
        }, (function()
            local kinds = {}
            for _, action in ipairs(collect.results) do
                kinds[#kinds + 1] = action.kind
            end
            return kinds
        end)())
        assert.equal(1,
            collect.results[2].expected_flex_offset)

        local stop = adapter("stop")
        assert.equal("hide_flex", stop.results[1].kind)
        assert.equal("discard_run", stop.results[1].effect)

        local passthrough = adapter("passthrough")
        assert.equal("flex_to_flex",
            passthrough.results[1].kind)
        assert.equal("gradual_inject",
            passthrough.results[1].operation.kind)
        assert.is_false(
            passthrough.rooting.ranges.result_destination.traced)
        assert.equal("interface_caller_handoff",
            passthrough.rooting.ranges.result_destination
                .retain_until)

        local empty = adapter("empty")
        assert.equal("end_flex", empty.results[1].kind)
        assert.equal(0, empty.results[1].count)

        local implementation_test = find_function(ast, "implements")
            .block.stats[1].exps[1]
        assert.is_true(
            implementation_test._interface_test.allocation_free)
        assert.is_false(
            implementation_test._interface_test
                .conversion.exact)
        assert.equal("adapter",
            implementation_test._interface_test
                .conversion.methods[2].slot_kind)
        assert.is_truthy(
            implementation_test._interface_test
                .conversion.methods[2].interface_adapter)
    end)

    it("freezes gradual and delayed structural adapter operations",
    function()
        local ok, err, ast = run_checker([[
            interface Item
                function get(): integer
            end

            interface Views
                function bridge(
                    item: Item,
                    number: value,
                    array: {integer},
                    map: {string: integer},
                    callback: function (integer): integer
                ): (
                    value,
                    integer,
                    {value},
                    {value: value},
                    function (integer, integer): integer
                )
                function box(array: {integer})
                function box_optional(array: {integer}?)
            end

            record Concrete
            end

            function Concrete:get(): integer
                return 1
            end

            function one(x: integer): integer
                return x
            end

            function Concrete:bridge(
                item: value,
                number: integer,
                array: {value},
                map: {value: value},
                callback: function (integer, integer): integer
            ): (
                integer,
                value,
                {integer},
                {string: integer},
                function (integer): integer
            )
                return 1, item, {1}, {["one"] = 1}, one
            end

            function Concrete:box(array: value)
            end

            function Concrete:box_optional(array: value)
            end

            function wrap(value_: Concrete): Views
                return value_
            end
        ]])
        assert.truthy(ok, err)

        local adapter = find_function(ast, "wrap")
            .block.stats[1].exps[1]
            ._interface_conversion.methods[1]
            .interface_adapter
        assert.is_truthy(adapter)

        assert.same({
            "gradual_inject",
            "gradual_guard",
            "gradual_guard",
            "gradual_guard",
            "callable_view",
        }, (function()
            local kinds = {}
            for _, action in ipairs(adapter.arguments) do
                kinds[#kinds + 1] = action.operation.kind
            end
            return kinds
        end)())
        assert.equal("project",
            adapter.arguments[2].operation.mode)
        assert.equal("integer",
            adapter.arguments[2].operation.guard.op)
        assert.equal("delayed_observation",
            adapter.arguments[3].operation.timing)
        assert.equal("array",
            adapter.arguments[3].operation.guard.op)
        assert.equal("value",
            adapter.arguments[3].operation.guard.element.op)
        assert.equal("delayed_observation",
            adapter.arguments[4].operation.timing)
        assert.equal("map",
            adapter.arguments[4].operation.guard.op)
        assert.equal("ignore_argument",
            adapter.arguments[5].operation
                .callable.arguments[2].kind)

        assert.same({
            "gradual_inject",
            "gradual_guard",
            "gradual_guard",
            "gradual_guard",
            "callable_view",
        }, (function()
            local kinds = {}
            for _, action in ipairs(adapter.results) do
                kinds[#kinds + 1] = action.operation.kind
            end
            return kinds
        end)())
        assert.equal("project",
            adapter.results[2].operation.mode)
        assert.equal("delayed_observation",
            adapter.results[3].operation.timing)
        assert.equal("delayed_observation",
            adapter.results[4].operation.timing)
        assert.equal("ignore_argument",
            adapter.results[5].operation
                .callable.arguments[2].kind)

        assert.same({
            "after_action",
            "after_native_call",
            "after_action",
        }, (function()
            local kinds = {}
            for _, point in ipairs(adapter.rebase_points) do
                kinds[#kinds + 1] = point.kind
            end
            return kinds
        end)())
        assert.equal("argument:2",
            adapter.rebase_points[1].action)
        assert.equal("after_native_call",
            adapter.rebase_points[2].kind)
        assert.equal("result:2",
            adapter.rebase_points[3].action)
        assert.is_false(
            adapter.rooting.ranges.argument_source.present)
        assert.same({}, adapter.rooting.fixed.argument_source)
        assert.equal(1,
            #adapter.rooting.fixed.argument_destination)
        assert.is_true(
            #adapter.rooting.fixed.result_source > 0)
        assert.equal(1,
            #adapter.rooting.fixed.result_destination)

        local methods = find_function(ast, "wrap")
            .block.stats[1].exps[1]
            ._interface_conversion.methods
        local box = methods[2].interface_adapter
        assert.equal("box", methods[2].name)
        assert.equal("gradual_inject",
            box.arguments[1].operation.kind)
        assert.is_true(
            box.arguments[1].operation.may_relocate)
        assert.is_true(box.arguments[1].operation.may_raise)
        assert.equal("after_action",
            box.rebase_points[1].kind)
        assert.equal("argument:1",
            box.rebase_points[1].action)
        assert.equal("after_native_call",
            box.rebase_points[2].kind)
        assert.same({}, box.rooting.fixed.argument_source)
        assert.same({}, box.rooting.fixed.argument_destination)

        local optional_box = methods[3].interface_adapter
        assert.equal("box_optional", methods[3].name)
        assert.is_true(
            optional_box.arguments[1]
                .operation.may_relocate)
    end)

    it("rejects coercion-only Interface adapter components", function()
        local cases = {
            [[
                interface Required
                    function use(input: integer)
                end
                record Concrete
                end
                function Concrete:use(input: float)
                end
            ]],
            [[
                interface Required
                    function use(input: integer)
                end
                record Concrete
                end
                function Concrete:use(input: integer?)
                end
            ]],
            [[
                interface Item
                    function get(): integer
                end
                interface Required
                    function clone(): Item
                end
                record Concrete
                end
                function Concrete:get(): integer
                    return 1
                end
                function Concrete:clone(): Concrete
                    return self
                end
            ]],
        }
        for _, prelude in ipairs(cases) do
            local ok, err = run_checker(prelude .. [[
                function wrap(value_: Concrete): Required
                    return value_
                end
            ]])
            assert.falsy(ok)
            assert.match("method '.-' has incompatible type", err)
        end
    end)
end)

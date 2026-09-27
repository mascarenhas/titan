local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local function remove(path)
    os.remove(path)
end

local function clean_generated()
    for _, path in ipairs({
        "test.c", "test.o", "test.so", "test.a", "test",
        "test__entrypoint.c", "test__entrypoint.o",
        "generic_iteration_fixture.c", "generic_iteration_fixture.o",
        "generic_gc_fixture.c", "generic_gc_fixture.o",
        "generic_layout_provider.c", "generic_layout_provider.o",
        "generic_layout_provider.so", "generic_layout_provider.a",
        "generic_layout_consumer.c", "generic_layout_consumer.o",
        "generic_layout_consumer.so", "generic_layout_consumer.a",
    }) do
        remove(path)
    end
    os.execute("rm -rf test.dSYM generic_layout_provider.so.dSYM " ..
        "generic_layout_consumer.so.dSYM")
end

describe("generic erased core", function()
    after_each(clean_generated)

    it("preserves omitted named arguments through generic erasure", function()
        h.run_coder([[
            union Packet<|T|>
                pair(item: T, last: T?)
            end

            record Box<|T|>
                item: T
                last: T?
            end

            function missing<|T|>(item: T, last: T?): boolean
                return last == nil
            end

            function run(): boolean
                local explicit = Packet<|integer|>.pair{item = 42}
                local inferred = Packet.pair{item = 43}
                local box = Box<|integer|>.new{item = 44}
                if box.last ~= nil then return false end
                if not missing<|integer|>{item = 45} then return false end
                if not missing{item = 46} then return false end
                case explicit
                when pair{item, last} then
                    if item ~= 42 or last ~= nil then return false end
                end
                case inferred
                when pair{last, item} then
                    return item == 43 and last == nil
                end
            end
        ]], [[
            assert(test.run())
        ]])
    end)

    it("publishes declared generic nominal metadata beside erased accessors", function()
        local _, tree = h.with_extra_cflags({ "-DTITAN_COMPILER_TESTS" }, function()
            return h.compile_and_read_c([[
                record Box<|T|>
                    local hidden: T
                    item: T
                    optional: T?
                end
                union Choice<|T|>
                    local hidden(T)
                    item(T)
                end
                interface Reader<|T|>
                    function get(): T
                end
                record Holder<|T: Reader<|integer|>|>
                    item: T
                end
            ]])
        end)
        types.assert_erased(tree._type)
        local ok, err = h.call("test", [[
            local registry = debug.getregistry()
            local types = require "titan-compiler.types"
            local function descriptor(kind, name)
                local mt = registry["Titan " .. kind .. " test." .. name .. " metatable"]
                return assert(load("return " .. mt[registry.TITAN_MT_TYPE],
                    "nominal descriptor", "t", types))(), mt
            end
            local box, mt = descriptor("record", "Box")
            assert(#box.fields == 2 and box.fields[1].index == 1)
            assert(box.fields[1].type._tag == "Type.Parameter")
            assert(box.fields[1].type.erased_constraint == false)
            assert(box.fields[2].type._tag == "Type.Option")
            assert(box.fields[2].type.base._tag == "Type.Parameter")
            assert(type(mt[registry.TITAN_MT_MEMBERMAP].item) == "userdata")
            assert(mt[registry.TITAN_MT_MEMBERMAP].hidden == nil)
            local choice = descriptor("union", "Choice")
            assert(#choice.variants == 1 and choice.variants[1].index == 0)
            assert(#choice.variants[1].parts == 1)
            assert(choice.variants[1].parts[1].name == "value")
            assert(choice.variants[1].parts[1].type._tag == "Type.Parameter")
            local reader = descriptor("interface", "Reader")
            assert(reader.methods[1].rettypes[1]._tag == "Type.Parameter")
            local holder = descriptor("record", "Holder")
            local constraint = holder.fields[1].type.erased_constraint
            assert(constraint._tag == "Type.Nominal")
            assert(constraint.fqtn == "test.Reader")
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps declared schemes separate from ordinary erased identity code", function()
        local csource, tree = h.compile_and_read_c([[
            record Token
            end

            function identity<|T|>(item: T): T
                return item
            end

            function accepts<|T|>(item: T): boolean
                return item is T
            end

            function many<|T|>(item: T): (T, ...: T)
                return item, item
            end

            function number(): integer
                return identity(42)
            end

            function text(): string
                return identity("ok")
            end

            function defaulted(): integer
                local generic = identity
                local boxed: value = identity
                local from_box = boxed as function (value): value
                return generic(40) as integer
                    + (from_box(2) as integer)
            end

            function same(): boolean
                local token = Token.new()
                return identity(token) == token and accepts(token)
            end

            function open(): (integer, ...: integer)
                return many(41)
            end
        ]])

        assert.equal("Type.FunctionScheme",
            tree._declared_type.members.identity.type._tag)
        assert.equal("Type.Function", tree._type.members.identity.type._tag)
        assert.equal("Type.Value",
            tree._type.members.identity.type.params[1]._tag)
        assert.equal("Type.Value",
            tree._type.members.identity.type.rettypes[1]._tag)
        types.assert_erased(tree._type)
        types.assert_erased(types.registry["test.Token"])
        assert.is_truthy(csource:find(
            "TValue test_\\u2133_identity_titan", 1, true))

        local ok, err = h.call("test", [[
            assert(test.number() == 42)
            assert(test.text() == "ok")
            assert(test.defaulted() == 42)
            assert(test.same())
            local first, second = test.open()
            assert(first == 41 and second == 41)
        ]])
        assert.truthy(ok, err)
    end)

    it("runs calls finalized by an outer ambient inference context", function()
        h.run_coder([[
            interface I
                function marker(): integer
            end

            record Witness
                number: integer
            end
            function Witness:marker(): integer return self.number end

            function id<|T|>(item: T): T return item end
            function make_identity<|T|>(): function (T): T
                return function(item: T): T return item end
            end
            function constrained<|T: I|>(item: T): T return item end
            function take<|U: I|>(left: function (U): U, right: function (U): U):
                    function (U): U
                return left
            end

            interface View<|T|>
                function get(): T
            end
            record Box<|T|>
                item: T
            end
            function Box:get(): T return self.item end
            function Box:integer_identity(item: T): T return item end
            function pair<|U|>(left: function (U): U, right: function (U): U): function (U): U
                return right
            end

            union Maybe<|T|>
                none()
                some(T)
            end
            function consume<|T|>(left: T, right: T): T return left end
            function make<|T|>(): T return (40 as value) as T end
            function pass<|T|>(item: T): T return item end
            function make_view<|T|>(): View<|T|>
                return Box<|T|>.new((40 as value) as T) as View<|T|>
            end

            function constrained_orders(): integer
                local witness = Witness.new(7)
                local left = take(id, constrained)
                local right = take(constrained, id)
                local named_left = take { left = id, right = constrained }
                local named_right = take { right = constrained, left = id }
                return left(witness):marker() + right(witness):marker()
                    + named_left(witness):marker()
                    + named_right(witness):marker()
            end

            function bound_orders(): integer
                local box = Box.new(0)
                local left = pair(id, box:integer_identity)
                local right = pair(box:integer_identity, id)
                return left(20) + right(22)
            end

            function nested_maybe(): integer
                local first = consume(Maybe.none(), Maybe.some(42))
                local second = consume(Maybe.some(42), Maybe.none())
                local total = 0
                case first
                when none() then total = total + 1
                else total = -100
                end
                case second
                when some(item) then total = total + item
                else total = -100
                end
                return total
            end

            function nested_calls(): integer
                local direct = consume(make(), 42)
                local deep = consume(pass(make()), 42)
                return direct + deep
            end

            function dependent_ordinary_calls(): integer
                local generic_callee = consume(id(id)(41), 41)
                local ordinary_callee = consume(make_identity()(42), 42)
                local interface_receiver = consume(make_view():get(), 40)
                return generic_callee + ordinary_callee + interface_receiver
            end
        ]], [[
            assert(test.constrained_orders() == 28)
            assert(test.bound_orders() == 42)
            assert(test.nested_maybe() == 43)
            assert(test.nested_calls() == 80)
            assert(test.dependent_ordinary_calls() == 123)
        ]])
    end)

    it("runs dependent constructors once in left-to-right order", function()
        h.run_coder([[
            record Plain<|T|>
                item: T
            end
            record Pair<|T|>
                first: T
                second: T
            end
            record Nested<|T|>
                inner: Plain<|T|>
                item: T
            end

            produced: integer = 0
            order_okay: boolean = true
            local function mark(expected: integer)
                produced = produced + 1
                if produced ~= expected then order_okay = false end
            end
            function make<|T|>(expected: integer): T
                mark(expected)
                return (40 as value) as T
            end
            function key(expected: integer, spelling: string): string
                mark(expected)
                return spelling
            end
            function produced_count(): integer return produced end
            function order_preserved(): boolean return order_okay end

            function take_array_left<|T|>(left: {T}, right: T): (T, T)
                return left[1], right
            end
            function take_array_right<|T|>(left: T, right: {T}): (T, T)
                return left, right[1]
            end
            function take_array<|T|>(items: {T}): (T, T)
                return items[1], items[2]
            end
            function take_map_left<|T|>(left: {string: T}, right: T): (T, T)
                return left["item"], right
            end
            function take_map_right<|T|>(left: T, right: {string: T}): (T, T)
                return left, right["item"]
            end
            function take_map<|T|>(items: {string: T}): (T, T)
                return items["left"], items["right"]
            end
            function take_plain_left<|T|>(left: Plain<|T|>, right: T): (T, T)
                return left.item, right
            end
            function take_plain_right<|T|>(left: T, right: Plain<|T|>): (T, T)
                return left, right.item
            end
            function take_plain_pair<|T|>(left: Plain<|T|>, right: Plain<|T|>): (T, T)
                return left.item, right.item
            end
            function take_pair<|T|>(box: Pair<|T|>, item: T): (T, T, T)
                return box.first, box.second, item
            end
            function take_nested<|T|>(box: Nested<|T|>, item: T): (T, T, T)
                return box.inner.item, box.item, item
            end

            function array_left(): integer
                local left, right = take_array_left({make(1)}, 2)
                return left + right
            end
            function array_right(): integer
                local left, right = take_array_right(2, {make(2)})
                return left + right
            end
            function array_internal_left(): integer
                local left, right = take_array({make(3), 2})
                return left + right
            end
            function array_internal_right(): integer
                local left, right = take_array({2, make(4)})
                return left + right
            end
            function map_left(): integer
                local left, right = take_map_left(
                    {[key(5, "item")] = make(6)}, 2)
                return left + right
            end
            function map_right(): integer
                local left, right = take_map_right(
                    2, {[key(7, "item")] = make(8)})
                return left + right
            end
            function map_internal_left(): integer
                local left, right = take_map({
                    [key(9, "left")] = make(10), ["right"] = 2,
                })
                return left + right
            end
            function map_internal_right(): integer
                local left, right = take_map({
                    ["left"] = 2, [key(11, "right")] = make(12),
                })
                return left + right
            end
            function named_left(): integer
                local left, right = take_plain_left({item = make(13)}, 2)
                return left + right
            end
            function named_right(): integer
                local left, right = take_plain_right(2, {item = make(14)})
                return left + right
            end
            function named_pair(): integer
                local left, right =
                    take_plain_pair({item = make(15)}, {item = 2})
                return left + right
            end
            function named_fields_left(): integer
                local first, second, item = take_pair(
                    {first = make(16), second = make(17)}, 2)
                return first + second + item
            end
            function named_fields_right(): integer
                local first, second, item = take_pair(
                    {second = make(18), first = make(19)}, 2)
                return first + second + item
            end
            function named_nested_left(): integer
                local inner, outer, item = take_nested(
                    {inner = {item = make(20)}, item = make(21)}, 2)
                return inner + outer + item
            end
            function named_nested_right(): integer
                local inner, outer, item = take_nested(
                    {item = make(22), inner = {item = make(23)}}, 2)
                return inner + outer + item
            end
            function positional_left(): integer
                local left, right =
                    take_plain_left(Plain.new(make(24)), 2)
                return left + right
            end
            function positional_right(): integer
                local left, right =
                    take_plain_right(2, Plain.new(make(25)))
                return left + right
            end
        ]], [[
            local cases = {
                { "array_left", 42 }, { "array_right", 42 },
                { "array_internal_left", 42 },
                { "array_internal_right", 42 },
                { "map_left", 42 }, { "map_right", 42 },
                { "map_internal_left", 42 },
                { "map_internal_right", 42 },
                { "named_left", 42 }, { "named_right", 42 },
                { "named_pair", 42 },
                { "named_fields_left", 82 },
                { "named_fields_right", 82 },
                { "named_nested_left", 82 },
                { "named_nested_right", 82 },
                { "positional_left", 42 },
                { "positional_right", 42 },
            }
            for _, case in ipairs(cases) do
                local name = case[1]
                assert(test[name]() == case[2], name)
            end
            assert(test.produced_count() == 25)
            assert(test.order_preserved())
        ]])
    end)

    it("runs ambient derived projections exactly once in source order", function()
        h.run_coder([[
            record Box<|T|>
                item: T
            end
            function Box:id(): T return self.item end

            record Plain
                item: integer
            end

            steps: integer = 0
            order_okay: boolean = true
            local function mark(expected: integer): integer
                steps = steps + 1
                if steps ~= expected then order_okay = false end
                return 42
            end
            function count(): integer return steps end
            function ordered(): boolean return order_okay end

            function make<|T|>(expected: integer): Box<|T|>
                return Box<|T|>.new((mark(expected) as value) as T)
            end
            function make_array<|T|>(expected: integer): {T}
                return {((mark(expected) as value) as T)}
            end
            function make_map<|K, V|>(expected: integer, key: K): {K: V}
                return {[key] = ((mark(expected) as value) as V)}
            end
            function make_item<|T|>(expected: integer): T
                return (mark(expected) as value) as T
            end
            function agree<|T|>(left: T, right: T): T return left end
            function consume<|T|>(left: T?, right: T): value return right end
            function take<|T|>(left: function (): T, right: T): T return left() end
            function take_reversed<|T|>(left: T, right: function (): T): T
                return right()
            end

            function field_orders(): integer
                local left = agree(make(1).item, mark(2))
                local right = agree(mark(3), make(4).item)
                return left + right
            end
            function index_orders(): integer
                local left = consume(make_array(5)[1], mark(6))
                local right = consume(mark(7), make_array(8)[1])
                return (left as integer) + (right as integer)
            end
            function record_orders(): integer
                local left = agree(
                    {item = make_item(9)}, Plain.new(mark(10)))
                local right = agree(
                    Plain.new(mark(11)), {item = make_item(12)})
                return left.item + right.item
            end
            function bound_orders(): integer
                local left = take(make(13):id, mark(14))
                local right = take_reversed(mark(15), make(16):id)
                return left + right
            end
            function parenthesized(): integer
                return agree((make_item(17)), mark(18))
            end
            function map_index_orders(): integer
                local left = consume(
                    make_map(19, "item")["item"], mark(20))
                local right = consume(
                    mark(21), make_map(22, "item")["item"])
                return (left as integer) + (right as integer)
            end
        ]], [[
            assert(test.field_orders() == 84)
            assert(test.index_orders() == 84)
            assert(test.record_orders() == 84)
            assert(test.bound_orders() == 84)
            assert(test.parenthesized() == 42)
            assert(test.map_index_orders() == 84)
            assert(test.count() == 22)
            assert(test.ordered())
        ]])
    end)

    it("runs direct computed calls and option-backed records once in order",
    function()
        h.run_coder([[
            record FnBox<|T|>
                callback: function (): T
            end
            record Box<|T|>
                item: T
                callback_step: integer
            end
            function Box:get(): T
                mark(self.callback_step)
                return self.item
            end
            record Holder<|T|>
                box: Box<|T|>
            end
            record Plain
                item: integer
            end

            local steps: integer = 0
            local order_okay: boolean = true
            local function reset_trace()
                steps = 0
                order_okay = true
            end
            local function mark(expected: integer): integer
                steps = steps + 1
                if steps ~= expected then order_okay = false end
                return 42
            end
            function count(): integer return steps end
            function ordered(): boolean return order_okay end

            function make<|T|>(expected: integer): FnBox<|T|>
                mark(expected)
                return FnBox<|T|>.new(function(): T
                    return (mark(expected + 1) as value) as T
                end)
            end
            function make_callbacks<|T|>(expected: integer): {function (): T}
                mark(expected)
                return {function(): T
                    return (mark(expected + 1) as value) as T
                end}
            end
            function make_boxes<|T|>(expected: integer): {Box<|T|>}
                mark(expected)
                return {Box<|T|>.new((42 as value) as T, expected + 1)}
            end
            function make_holder<|T|>(expected: integer): Holder<|T|>
                mark(expected)
                return Holder<|T|>.new(Box<|T|>.new(
                    (42 as value) as T, expected + 1))
            end
            function maybe(expected: integer): Plain?
                return Plain.new(mark(expected))
            end
            function agree<|T|>(left: T, right: T): T return left end

            function computed_calls(): integer
                reset_trace()
                local field = agree(make(1).callback(), mark(3))
                local bracket = agree(make_callbacks(4)[1](), mark(6))
                local method = agree(make_holder(7).box:get(), mark(9))
                local bracket_method = agree(
                    make_boxes(10)[1]:get(), mark(12))
                return field + bracket + method + bracket_method
            end
            function option_record(): integer
                reset_trace()
                local got = agree({item = mark(1)}, maybe(2))
                return got.item
            end
        ]], [[
            assert(test.computed_calls() == 168)
            assert(test.count() == 12)
            assert(test.ordered())
            assert(test.option_record() == 42)
            assert(test.count() == 2)
            assert(test.ordered())
        ]])
    end)

    it("runs deferred option-backed contextual records once in either placement",
    function()
        h.run_coder([[
            record Plain
                item: integer
            end

            local steps: integer = 0
            local order_okay: boolean = true
            local function reset_trace()
                steps = 0
                order_okay = true
            end
            local function mark(expected: integer): integer
                steps = steps + 1
                if steps ~= expected then order_okay = false end
                return 42
            end
            function count(): integer return steps end
            function ordered(): boolean return order_okay end

            function maybe(expected: integer): Plain?
                return Plain.new(mark(expected))
            end
            function agree<|T|>(left: T, right: T): T return left end

            function inferred_left(): Plain?
                reset_trace()
                local got = agree({item = mark(1)}, maybe(2))
                return got
            end
            function inferred_right(): Plain?
                reset_trace()
                local got = agree(maybe(1), {item = mark(2)})
                return got
            end
            function result_left(): Plain?
                reset_trace()
                return agree({item = mark(1)}, maybe(2))
            end
            function result_right(): Plain?
                reset_trace()
                return agree(maybe(1), {item = mark(2)})
            end
        ]], [[
            for _, name in ipairs({
                "inferred_left", "inferred_right",
                "result_left", "result_right",
            }) do
                local got = test[name]()
                assert(got.item == 42, name)
                assert(test.count() == 2, name .. " count")
                assert(test.ordered(), name .. " order")
            end
        ]])
    end)

    it("runs ordinary later adjustments selected by first evidence",
    function()
        h.run_coder([[
            function second<|T|>(left: T, right: T): T return right end
            function value_first(item: value): value
                local got = second(item, 42)
                return got
            end
            function integer_first(item: value): integer
                local got = second(42, item)
                return got
            end
            function numeric_bad()
                local got = second(1, 2.5)
            end
            function numeric_float(): float
                local got = second(1.0, 2)
                return got
            end

            interface Marker function marker(): integer end
            record Mark number: integer end
            function Mark:marker(): integer return self.number end
            function marker(): Marker return Mark.new(41) end
            function mark(): Mark return Mark.new(99) end
            record Plain item: integer end
            function maybe(present: boolean): Plain?
                if present then return Plain.new(42) end
                return nil
            end
            function same<|T|>(left: T, right: T): T return left end
            function interface_first(): integer
                local got = same(marker(), mark())
                return got:marker()
            end
            function option_first(present: boolean): Plain?
                local got? = same(maybe(present), Plain.new(42))
                return got
            end
            function base_first(present: boolean): Plain
                local got = same(Plain.new(42), maybe(present))
                return got
            end

            record CallbackBox callback: function (integer): integer end
            function callback_box(): CallbackBox
                return CallbackBox.new(
                    function(x: integer): integer return x + 1 end)
            end
            function contextual_record(): integer
                local got = same({callback = function(x)
                    return x + 2
                end}, callback_box())
                return got.callback(40)
            end
            function string_witness(): {string} return {"witness"} end
            function contextual_open(callback: value): {string}
                local inferred = same({callback()}, string_witness())
                return inferred
            end
            record DynamicBox callback: value end
            function contextual_field(callback: value): {string}
                local box = DynamicBox.new(callback)
                local inferred = same({box.callback()}, string_witness())
                return inferred
            end
        ]], [[
            assert(test.value_first("bad") == 42)
            assert(test.integer_first(7) == 7)
            assert(not pcall(test.integer_first, "bad"))
            assert(not pcall(test.numeric_bad))
            local number = test.numeric_float()
            assert(number == 2.0 and math.type(number) == "float")
            assert(test.interface_first() == 41)
            assert(test.option_first(false) == nil)
            assert(not pcall(test.base_first, false))
            assert(test.contextual_record() == 42)
            local open = test.contextual_open(function()
                return "first", "second", "third"
            end)
            assert(#open == 3)
            assert(open[1] == "first" and open[2] == "second"
                and open[3] == "third")
            local field = test.contextual_field(function()
                return "field-first", "field-second", "field-third"
            end)
            assert(#field == 3)
            assert(field[1] == "field-first"
                and field[2] == "field-second"
                and field[3] == "field-third")
        ]])
    end)

    it("infers optional Map arguments before their ordinary presence check", function()
        h.run_coder([[
            local entered: integer = 0

            function identity<|K, V|>(items: {K: V}): {K: V}
                entered = entered + 1
                return items
            end

            function lookup<|K, V|>(items: {K: V}?, key: K): V?
                local present = identity(items)
                return present[key]
            end

            function next<|V|>(items: {string: V}, key: string?): (string?, V?)
                if key ~= nil then return nil, nil end
                return "item", items["item"]
            end

            function pairs<|V|>(items: {string: V}):
                    (function ({string: V}, string?): (string?, V?),
                     {string: V}, nil, nil)
                entered = entered + 1
                return next, items, nil, nil
            end

            function copy<|T|>(items: {string: T}?): {string: T}
                local result: {string: T} = {}
                for key, item in pairs(items) do
                    result[key] = item
                end
                return result
            end

            function entries(): integer
                return entered
            end
        ]], [[
            assert(test.lookup({[7] = "seven"}, 7) == "seven")
            assert(test.lookup({item = false}, "item") == false)
            local copied = test.copy({item = false})
            assert(copied.item == false)
            local before = test.entries()
            assert(not pcall(test.lookup, nil, "item"))
            assert(not pcall(test.copy, nil))
            assert(test.entries() == before)
        ]])
    end)

    it("runs optional Array constructors once and strictly projects generic elements",
    function()
        h.run_coder([[
            local log: integer = 0
            local function mark(item: integer): integer
                log = log * 10 + item
                return item
            end
            function first<|T|>(items: {T}?): T?
                if items == nil then return nil end
                local present: {T} = items
                return present[1]
            end
            function ordinary(items: {integer}?): integer
                if items == nil then return -1 end
                local present: {integer} = items
                return #present
            end
            function constructors(): (integer?, integer?, integer?, integer)
                log = 0
                local inferred? = first({mark(1), mark(2)})
                local explicit? = first<|integer|>({mark(3)})
                local typed: {integer} = {mark(4)}
                local from_typed? = first(typed)
                return inferred, explicit, from_typed, log
            end
            function missing(): (integer?, integer?, integer?, value,
                                 integer, integer, integer)
                return first({}), first<|integer|>({}), first<|integer|>(nil),
                    first(nil), ordinary({1}), ordinary({}), ordinary(nil)
            end
            function optional(items: {integer}?): integer?
                return first(items)
            end
            function project(items: {value}?): integer?
                return first<|integer|>(items)
            end
            function gradual(item: value): integer?
                return first<|integer|>({item})
            end
            function values(): {value}
                return {"wrong"}
            end
        ]], [[
            local inferred, explicit, typed, log = test.constructors()
            assert(inferred == 1 and explicit == 3 and typed == 4)
            assert(log == 1234)
            local empty, explicit_empty, absent, default_absent,
                one, zero, missing = test.missing()
            assert(empty == nil and explicit_empty == nil and absent == nil)
            assert(default_absent == nil and one == 1 and zero == 0 and missing == -1)
            assert(test.optional(nil) == nil and test.project(nil) == nil)
            assert(test.gradual(42) == 42)
            local ok, err = pcall(test.project, test.values())
            assert(not ok and err:find("expected integer", 1, true))
            ok, err = pcall(test.gradual, "wrong")
            assert(not ok and err:find("expected integer", 1, true))
        ]])
    end)

    it("runs a generic iterator with trailing generic tuple results", function()
        h.run_coder([[
            function step<|T|>(state: {T}, control: integer): (integer?, T?)
                local next = control + 1
                if next > #state then return nil, nil end
                return next, state[next]
            end
            function supply<|U|>(state: {U}, control: integer): ({U}, integer)
                return state, control
            end
            function iterate(): integer
                local total = 0
                for index: integer, item: string?
                        in step, supply({"one", "two"}, 0) do
                    total = total + index
                end
                return total
            end
        ]], [[
            assert(test.iterate() == 3)
        ]])
    end)

    it("forces iterator item bindings inside an erased generic body", function()
        h.run_coder([[
            function step<|T|>(state: {T}, control: integer): (integer?, T?)
                local next = control + 1
                if next > #state then return nil, nil end
                return next, state[next]
            end

            function copy<|T|>(items: {T}): {T}
                local result: {T} = {}
                for index, item in step, items, 0 do
                    result[index] = item
                end
                return result
            end

            function booleans(): {boolean}
                return copy({false, true})
            end

            function strings(): {string}
                return copy({"first", "second"})
            end
        ]], [[
            local booleans = test.booleans()
            assert(#booleans == 2)
            assert(booleans[1] == false and booleans[2] == true)
            local strings = test.strings()
            assert(#strings == 2)
            assert(strings[1] == "first" and strings[2] == "second")
        ]])
    end)

    it("erases an optional initial iterator control inside a generic body", function()
        h.run_coder([[
            function step<|T|>(state: T, control: T?): T?
                if control == nil then return state end
                return nil
            end

            function iterate<|T|>(state: T): integer
                local count = 0
                for item in step, state, nil do
                    if item ~= state then raise "wrong item" end
                    count = count + 1
                end
                return count
            end
        ]], [[
            assert(test.iterate(false) == 1)
            assert(test.iterate("item") == 1)
        ]])
    end)

    it("erases generic iterator controls and close argument adjustments", function()
        h.run_coder([[
            local calls: integer = 0
            local closes: integer = 0
            local closed_state: value = nil

            function step<|T|>(state: T, control: T): T?
                if state ~= control then raise "wrong control" end
                calls = calls + 1
                if calls > 2 then return nil end
                return state
            end

            function close<|T|>(state: T?)
                closes = closes + 1
                closed_state = state
            end

            function iterate<|T|>(state: T, mode: integer): integer
                calls = 0
                closes = 0
                closed_state = nil
                local finish: function (T?): () = close
                local count = 0
                for item in step, state, state, finish do
                    if item ~= state then raise "wrong item" end
                    count = count + 1
                    if mode == 1 then break end
                    if mode == 2 then return count end
                    if mode == 3 then raise "iteration body failed" end
                end
                return count
            end

            function status(): (integer, integer, value)
                return calls, closes, closed_state
            end
        ]], [[
            assert(test.iterate(false, 0) == 2)
            local calls, closes, state = test.status()
            assert(calls == 3 and closes == 1 and state == false)
            for mode = 1, 2 do
                assert(test.iterate("item", mode) == 1)
                calls, closes, state = test.status()
                assert(calls == 1 and closes == 1 and state == "item")
            end
            local ok, err = pcall(test.iterate, false, 3)
            assert(not ok and tostring(err):find("iteration body failed", 1, true))
            calls, closes, state = test.status()
            assert(calls == 1 and closes == 1 and state == false)
        ]])
    end)

    it("lowers discarded generic iterator setup expressions in source order", function()
        h.run_coder([[
            local order: string = ""

            function stop<|T|>(state: T, control: T): T?
                order = order .. "next;"
                return nil
            end

            function close<|T|>(state: T)
                order = order .. "close;"
            end

            function effect<|T|>(item: T): T
                order = order .. "effect;"
                return item
            end

            function iterate<|T|>(state: T): string
                order = ""
                local optional: T? = state
                for item in stop, state, state, close, effect<|T|>(optional) do
                    order = order .. "body;"
                end
                return order
            end
        ]], [[
            assert(test.iterate(false) == "effect;next;close;")
            assert(test.iterate("item") == "effect;next;close;")
        ]])
    end)

    it("runs nested fixed and open generic result projections", function()
        h.run_coder([[
            function make<|T|>(): T return (42 as value) as T end

            function duo<|T|>(): (integer, {T})
                return 1, {make()}
            end

            function spread<|T|>(): (integer, ...: {T})
                return 1, {make()}, {make()}
            end

            function consume_fixed<|T|>(first: T, second: {T}): integer
                return #second
            end

            function consume_open<|T|>(first: T, ...: {T}): integer
                local left: {T} = ...[1]
                local right: {T} = ...[2]
                return #left + #right
            end

            function fixed_projection(): integer
                return consume_fixed(duo())
            end

            function open_projection(): integer
                return consume_open(spread())
            end
        ]], [[
            assert(test.fixed_projection() == 1)
            assert(test.open_projection() == 2)
        ]])
    end)

    it("lowers generic owner fields, constructors, methods, and union cases", function()
        h.run_coder([[
            record Box<|T|>
                item: T
            end

            function Box:get(): T
                return self.item
            end

            function Box:put(item: T)
                self.item = item
            end

            function Box:project<|U|>(item: U): U
                return item
            end

            function Box.map<|U|>(item: U): Box<|U|>
                return Box<|U|>.new(item)
            end

            function same_box<|A|>(left: Box<|value|>, right: Box<|A|>): boolean
                return left == right
            end

            union Maybe<|T|>
                present(T)
                absent()
            end

            function make<|T|>(item: T): Maybe<|T|>
                return Maybe<|T|>.present(item)
            end

            function number(): integer
                local box = Box.new(41)
                box:put(box:get() + 1)
                local candidate = make(box.item)
                case candidate
                when present(item) then
                    return item
                else
                    return 0
                end
            end

            type IntBox = Box<|integer|>

            function text(): string
                return Box<|value|>.map<|string|>("ok"):get()
            end

            function alias_number(): integer
                local constructor = IntBox.new
                return constructor(42):get()
            end

            function defaulted_bound(): string
                local box = Box.new(1)
                local project = box:project
                return project("ok") as string
            end

            function distinct_owners(): boolean
                local loose = Box<|value|>.new("same contents")
                local precise = Box<|string|>.new("same contents")
                return same_box<|string|>(loose, precise)
            end
        ]], [[
            assert(test.number() == 42)
            assert(test.text() == "ok")
            assert(test.alias_number() == 42)
            assert(test.defaulted_bound() == "ok")
            assert(not test.distinct_owners())
        ]])
    end)

    it("wraps callbacks and preserves arrays, maps, and options", function()
        h.run_coder([[
            function apply<|T, U|>(callback: function (T): U, item: T): U
                return callback(item)
            end

            function first<|T|>(items: {T}): T
                return items[1]
            end

            function lookup<|K, V|>(items: {K: V}, key: K): V
                return items[key]
            end

            function optional<|T|>(item: T?): T?
                return item
            end

            function twice(item: integer): integer
                return item * 2
            end

            function answer(): integer
                local items: {integer} = {21, 20}
                local mapped: {string: integer} = { ["answer"] = 42 }
                local from_map: integer = optional<|integer|>(
                    lookup<|string, integer|>(mapped, "answer"))
                return apply(twice, first(items)) + from_map - 42
            end

            function missing(): integer?
                local item: integer? = nil
                return optional<|integer|>(item)
            end
        ]], [[
            assert(test.answer() == 42)
            assert(test.missing() == nil)
            assert(test.apply(function(item) return item + 1 end, 41) == 42)
        ]])
    end)

    it("runs missing and bare fixed-nil generic callback results", function()
        h.run_coder([[
            function invoke<|A, B|>(callback: function (): A): A
                return callback()
            end

            function missing(): nil
                return invoke<|nil, value|>(function () end)
            end

            function bare(): nil
                return invoke<|nil, value|>(function () return end)
            end

            function adjusted_zero(): nil
                return invoke<|nil, value|>(function (): () end)
            end
        ]], [[
            assert(select("#", test.missing()) == 1)
            assert(test.missing() == nil)
            assert(select("#", test.bare()) == 1)
            assert(test.bare() == nil)
            assert(select("#", test.adjusted_zero()) == 1)
            assert(test.adjusted_zero() == nil)
        ]])
    end)

    it("delays a polluted mutable field guard until its precise read", function()
        h.run_coder([[
            record Box<|T|>
                item: T
            end

            function make(): Box<|integer|>
                return Box.new(42)
            end

            function read(box: Box<|integer|>): integer
                return box.item
            end
        ]], [[
            local box = test.make()
            box.item = "bad"
            test.read(box)
        ]], "expected integer")
    end)

    it("uses an applied Interface constraint as the erased carrier", function()
        h.run_coder([[
            interface Show<|A|>
                function render(item: A): string
            end

            record IntegerShow
                prefix: string
            end
            record ValueShow
                prefix: string
            end

            function IntegerShow:render(item: integer): string
                return self.prefix
            end
            function ValueShow:render(item: value): string
                return self.prefix
            end

            function display<|A, S: Show<|A|>|>(subject: S, item: A): string
                return subject:render(item)
            end

            function identity<|A, S: Show<|A|>|>(subject: S): S
                return subject
            end

            function take<|A, S: Show<|A|>|>(callback: function (S): S): function (S): S
                return callback
            end

            function use(): string
                local callback = take(identity)
                local subject = callback(ValueShow.new("ok"))
                return subject:render(1)
            end
        ]], [[assert(test.use() == "ok")]])
    end)

    it("round-trips async-shaped generic status views without runtime arguments",
    function()
        h.run_coder([[
            union TaskStatus<|A, B|>
                succeeded(A)
                failed(B)
            end

            record Task<|A, B|>
                status: TaskStatus<|A, B|>
            end

            function Task:snapshot(): TaskStatus<|A, B|>
                local loose: TaskStatus<|value, value|>? = self.status
                return loose as TaskStatus<|A, B|>
            end

            function use(): integer
                local task = Task.new(TaskStatus<|integer, value|>.succeeded(42))
                local status = task:snapshot()
                case status
                when succeeded(item) then
                    return item
                else
                    return 0
                end
            end
        ]], [[assert(test.use() == 42)]])
    end)

    it("preserves generic owner slots through a binary interface", function()
        local ok, err = h.build_so_chain({
            {
                name = "generic_layout_provider",
                src = [[
                    record Box<|T|>
                        local hidden: integer
                        first: T
                        second: T
                        third: T
                    end

                    function make<|T|>(hidden: integer, first: T,
                                     second: T, third: T): Box<|T|>
                        return Box<|T|>.new(hidden, first, second, third)
                    end

                    function reveal<|T|>(box: Box<|T|>): integer
                        return box.hidden
                    end

                    union Maybe<|T|>
                        local hidden(integer)
                        first(T)
                        second(T)
                        absent()
                    end

                    record PublicBox<|T|>
                        item: T
                    end
                    type Crate = PublicBox
                    type IntBox = PublicBox<|integer|>

                    function hidden<|T|>(n: integer): Maybe<|T|>
                        return Maybe<|T|>.hidden(n)
                    end
                ]],
            },
            {
                name = "generic_layout_consumer",
                src = [[
                    local provider = import "generic_layout_provider"

                    function run(): boolean
                        local crate = provider.Crate<|integer|>.new(41)
                        local fixed = provider.IntBox.new(42)
                        if crate.item ~= 41 or fixed.item ~= 42 then
                            return false
                        end

                        local box = provider.make<|integer|>(7, 10, 20, 30)
                        box.first = 11
                        box.second = 22
                        box.third = 33
                        if box.first ~= 11 or box.second ~= 22 or
                           box.third ~= 33 or
                           provider.reveal<|integer|>(box) ~= 7 then
                            return false
                        end

                        local maybe = provider.Maybe<|integer|>.second(42)
                        case maybe
                        when first(item) then
                            return false
                        when second(item) then
                            if item ~= 42 then return false end
                        else
                            return false
                        end

                        case provider.hidden<|integer|>(9)
                        when first(item) then
                            return false
                        when second(item) then
                            return false
                        when absent() then
                            return false
                        else
                            return true
                        end
                    end
                ]],
            },
        })
        assert.truthy(ok, err)

        local ran, output = h.call("generic_layout_consumer", [[
            assert(generic_layout_consumer.run())
        ]])
        assert.truthy(ran, output)
    end)

    it("compiles compact imported generic iterator and callback implementations",
    function()
        local ok, err = h.generate_modules({
            generic_iteration_fixture = [[
                local function array_next<|T|>(
                    array: {T}, index: integer
                ): (integer?, T?)
                    local next_index = index + 1
                    if next_index > #array then
                        return nil, nil
                    end
                    return next_index, array[next_index]
                end

                function ipairs<|T|>(array: {T}):
                    (function ({T}, integer): (integer?, T?),
                     {T}, integer, nil)
                    return array_next, array, 0, nil
                end
            ]],
            generic_gc_fixture = [[
                function apply<|T|>(item: T, callback: function (T): ())
                    callback(item)
                end
            ]],
            test = [[
                local iteration = import "generic_iteration_fixture"
                local generic = import "generic_gc_fixture"

                function main(args: {string}): integer
                    local items: {integer} = {20, 22}
                    local total = 0
                    for _, item in iteration.ipairs(items) do
                        total = total + item
                    end

                    local observed = 0
                    local candidate: {string: integer} = {
                        ["answer"] = total,
                    }
                    generic.apply(candidate,
                        function(item: {string: integer})
                            observed = item["answer"]
                        end)
                    if total == 42 and observed == 42 then
                        return 0
                    else
                        return 1
                    end
                end
            ]],
        }, "test", true)
        assert.truthy(ok, err)

        local ran, run_error, status = h.call_app("./test")
        assert.truthy(ran, run_error)
        assert.equal(0, status)
    end)
end)

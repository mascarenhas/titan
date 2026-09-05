require "titan-compiler.coder.core"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local coder_values = require "titan-compiler.coder.values"
local coder_numerics = require "titan-compiler.coder.numerics"
local types = require "titan-compiler.types"

local run_coder = h.run_coder

local function clean()
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", "__entrypoint.c",
        "__entrypoint.o",
    }) do
        os.remove("test" .. suffix)
    end
    os.execute("rm -rf test.dSYM")
end

describe("type-relation soundness (end-to-end)", function()
    after_each(clean)

    it("uses logical truthiness without weakening strict boolean sinks", function()
        run_coder([[
            local log: integer = 0
            local function observe(mark: integer, v: value): value
                log = log * 10 + mark
                return v
            end
            local function static_truth(): string
                log = log * 10 + 3
                return ""
            end
            local function static_false(): nil
                log = log * 10 + 4
                return nil
            end
            function negate(a: value): boolean
                return not a
            end
            function direct(a: value): boolean
                if a then return true else return false end
            end
            function conjoin(a: value, b: value): boolean
                if a and b then return true else return false end
            end
            function disjoin(a: value, b: value): boolean
                if a or b then return true else return false end
            end
            function contextual(a: value, b: value): (boolean, boolean)
                local result: boolean = a and b
                return result, a or b
            end
            function nested(a: value, b: value, c: value): boolean
                return (a and b) or not c
            end
            function boolean_default(a: value): (boolean, boolean)
                local right = a or false
                local left = false or a
                return right, left
            end
            function preserve_values(a: value, b: value): (value, value)
                local disjunction = a or b
                local conjunction = a and b
                return disjunction, conjunction
            end
            function effects(a: value, b: value): (boolean, integer, boolean, integer)
                log = 0
                local conjunction: boolean = observe(1, a) and observe(2, b)
                local first = log
                log = 0
                local disjunction: boolean = observe(1, a) or observe(2, b)
                return conjunction, first, disjunction, log
            end
            function static_effects(): (boolean, boolean, integer)
                log = 0
                local truth: boolean = static_truth() and static_truth()
                local falsity = not static_false()
                return truth, falsity, log
            end
            function options(a: boolean?, b: string?): (boolean, boolean, boolean)
                return not a, a and b, a or b
            end
            local function optional<T>(a: T?): boolean
                return not a
            end
            function generic_options(): (boolean, boolean, boolean)
                return optional<string>(nil), optional<string>(""), optional<boolean>(false)
            end
            local function take_boolean(a: boolean): boolean
                return a
            end
            function strict_local(a: value): boolean
                local result: boolean = a
                return result
            end
            function strict_argument(a: value): boolean
                return take_boolean(a)
            end
            function strict_return(a: value): boolean
                return a
            end
        ]], [[
            local samples = table.pack(nil, false, true, "", "present", 0, 2.5, {}, function() end)
            for i = 1, samples.n do
                local a = samples[i]
                assert(test.direct(a) == not not a)
                assert(test.negate(a) == not a)
                local right, left = test.boolean_default(a)
                assert(right == not not a and left == not not a)
                for j = 1, samples.n do
                    local b = samples[j]
                    local conjunction, disjunction = test.contextual(a, b)
                    assert(conjunction == not not (a and b))
                    assert(disjunction == not not (a or b))
                    assert(test.conjoin(a, b) == conjunction)
                    assert(test.disjoin(a, b) == disjunction)
                    local cv, cl, dv, dl = test.effects(a, b)
                    assert(cv == conjunction and cl == (a and 12 or 1))
                    assert(dv == disjunction and dl == (a and 1 or 12))
                    for k = 1, samples.n do
                        assert(test.nested(a, b, samples[k]) == not not ((a and b) or not samples[k]))
                    end
                end
                for _, f in ipairs({test.strict_local, test.strict_argument, test.strict_return}) do
                    local ok, result = pcall(f, a)
                    assert(ok == (type(a) == "boolean"))
                    if ok then assert(result == a) end
                end
            end
            local truth, falsity, log = test.static_effects()
            assert(truth and falsity and log == 334)
            local a, b, c = test.options(false, "")
            assert(a and not b and c)
            a, b, c = test.options(nil, nil)
            assert(a and not b and not c)
            a, b, c = test.options(true, "present")
            assert(not a and b and c)
            a, b, c = test.generic_options()
            assert(a and not b and c)
            local disjunction, conjunction = test.preserve_values(false, "present")
            assert(disjunction == "present" and conjunction == nil)
            disjunction, conjunction = test.preserve_values("first", "second")
            assert(disjunction == "first" and conjunction == "second")
        ]])
    end)

    it("separates strict Titan observations from dynamic coercion", function()
        run_coder([[
            number: integer = 0
            truth: boolean = false

            record Box
                number: integer
                truth: boolean
            end

            function implicit_integer(v: value): integer
                return v
            end

            function written_integer(v: value): integer
                return v as integer
            end

            function is_integer(v: value): boolean
                return v is integer
            end

            function implicit_boolean(v: value): boolean
                return v
            end

            function written_boolean(v: value): boolean
                return v as boolean
            end

            function is_boolean(v: value): boolean
                return v is boolean
            end

            function lua_integer(v: integer): integer
                return v
            end

            function lua_boolean(v: boolean): boolean
                return v
            end

            function new_box(): Box
                return Box.new(0, false)
            end

            function new_integers(): {integer}
                return {0}
            end

            function read_integer_array(values: {integer}): integer
                return values[1]
            end

            function read_integer_map(values: {string: integer}): integer
                return values["x"]
            end

            function call_integer(f: () -> integer): integer
                return f()
            end

            function strict_array_read(): integer
                local dynamic: {value} = {2.0}
                local typed: {integer} = dynamic
                return typed[1]
            end

            function strict_map_read(): integer
                local dynamic: {string: value} = { ["x"] = 2.0 }
                local typed: {string: integer} = dynamic
                return typed["x"]
            end

            function wrong_array_mutation(): integer
                local original: {integer} = {17}
                local dynamic: {value} = original
                dynamic[1] = "wrong"
                return original[1]
            end

            function wrong_map_mutation(): integer
                local original: {string: integer} = { ["x"] = 17 }
                local dynamic: {string: value} = original
                dynamic["x"] = "wrong"
                return original["x"]
            end

            function actual_number(): value
                return 2.0
            end

            function actual_truth(): value
                return "truthy"
            end

            function strict_function_number(): integer
                local f: () -> integer = actual_number
                return f()
            end

            function strict_function_boolean(): boolean
                local f: () -> boolean = actual_truth
                return f()
            end

            function strict_option_view(dynamic: value?): integer
                local typed: integer? = dynamic
                return typed
            end
        ]], [[
            local function fails(f)
                local ok = pcall(f)
                assert(not ok)
            end

            -- Implicit value projections are strict; written casts/tests use
            -- the same broader conversion as a genuine Lua boundary.
            fails(function() return test.implicit_integer(2.0) end)
            assert(test.written_integer(2.0) == 2)
            assert(test.is_integer(2.0))
            fails(function() return test.implicit_boolean("truthy") end)
            assert(test.written_boolean("truthy") == true)
            assert(test.is_boolean("truthy"))
            assert(test.lua_integer(3.0) == 3)
            assert(test.lua_boolean("truthy") == true)

            -- Module, record, and Array Lua writes are the same dynamic sink.
            test.number = 4.0
            test.truth = "truthy"
            assert(test.number == 4 and test.truth == true)
            local box = test.new_box()
            box.number = 5.0
            box.truth = "truthy"
            assert(box.number == 5 and box.truth == true)
            local array = test.new_integers()
            array[1] = 6.0
            assert(test.read_integer_array(array) == 6)

            -- A plain Lua callable's result crosses a dynamic boundary.
            assert(test.call_integer(function() return 7.0 end) == 7)

            -- Raw Lua Map mutation has no typed write boundary; all Map reads
            -- and all Titan gradual observations remain strict.
            fails(function()
                return test.read_integer_map({ x = 8.0 })
            end)
            fails(test.strict_array_read)
            fails(test.strict_map_read)
            fails(test.wrong_array_mutation)
            fails(test.wrong_map_mutation)

            -- A branded non-exact Titan closure uses strict result guards.
            fails(test.strict_function_number)
            fails(test.strict_function_boolean)

            -- A same-representation Option view consumes its recursive strict
            -- guard before the source base type can be forgotten.
            fails(function() return test.strict_option_view(2.0) end)
            assert(test.strict_option_view(2) == 2)
        ]])
    end)

    it("keeps nominal, container, and callable boundary kinds aligned",
    function()
        run_coder([[
            record Item
                number: integer
            end

            local function increment(x: integer): integer
                return x + 1
            end

            item_slot: Item = Item.new(1)
            array_slot: {integer} = {1}
            map_slot: {string: integer} = { ["x"] = 1 }
            callback_slot: (integer) -> integer =
                function(x: integer): integer return x + 1 end

            record KindBox
                item: Item
                array: {integer}
                map: {string: integer}
                callback: (integer) -> integer
            end

            function new_item(number: integer): Item
                return Item.new(number)
            end

            function new_array(number: integer): {integer}
                return {number}
            end

            function new_float_array(number: float): {float}
                return {number}
            end

            function new_box(): KindBox
                return KindBox.new(
                    Item.new(2), {2}, { ["x"] = 2 }, increment)
            end

            function read_item_slot(): integer
                return item_slot.number
            end

            function read_array_slot(): integer
                return array_slot[1]
            end

            function read_map_slot(): integer
                return map_slot["x"]
            end

            function call_callback_slot(x: integer): integer
                return callback_slot(x)
            end

            function read_box(box: KindBox): integer
                return box.item.number + box.array[1] + box.map["x"]
                    + box.callback(1)
            end

            function item_is(v: value): boolean
                return v is Item
            end

            function item_as(v: value): integer
                return (v as Item).number
            end

            function array_is(v: value): boolean
                return v is {integer}
            end

            function array_as(v: value): integer
                return (v as {integer})[1]
            end

            function map_is(v: value): boolean
                return v is {string: integer}
            end

            function map_as(v: value): integer
                return (v as {string: integer})["x"]
            end

            function callback_is(v: value): boolean
                return v is (integer) -> integer
            end

            function callback_as(v: value): integer
                return (v as (integer) -> integer)(1)
            end

            function callback_as_only(v: value): value
                local callback = v as (integer) -> integer
                return callback
            end

            function accept_item(v: Item): integer
                return v.number
            end

            function accept_array(v: {integer}): integer
                return v[1]
            end

            function accept_map(v: {string: integer}): integer
                return v["x"]
            end

            function accept_callback(v: (integer) -> integer): integer
                return v(1)
            end

            function accept_callback_only(
                v: (integer) -> integer
            ): value
                return v
            end

            function item_result(f: () -> Item): integer
                return f().number
            end

            function array_result(f: () -> {integer}): integer
                return f()[1]
            end

            function map_result(
                f: () -> {string: integer}
            ): integer
                return f()["x"]
            end

            function callback_result(
                f: () -> (integer) -> integer
            ): integer
                return f()(1)
            end

            function callback_result_only(
                f: () -> (integer) -> integer
            ): value
                local callback = f()
                return callback
            end

            function new_item_values(): {Item}
                return {Item.new(3)}
            end

            function new_array_values(): {{integer}}
                return {{3}}
            end

            function new_map_values(): {{string: integer}}
                return {{ ["x"] = 3 }}
            end

            function new_callback_values(): {(integer) -> integer}
                return {increment}
            end

            function read_item_values(values: {Item}): integer
                return values[1].number
            end

            function read_array_values(values: {{integer}}): integer
                return values[1][1]
            end

            function read_map_values(
                values: {{string: integer}}
            ): integer
                return values[1]["x"]
            end

            function read_callback_values(
                values: {(integer) -> integer}
            ): integer
                return values[1](1)
            end
        ]], [[
            local function fails(f)
                local ok = pcall(f)
                assert(not ok)
            end

            local item = test.new_item(10)
            local array = test.new_array(20)
            local map = { x = 30 }
            local callback = function(x) return x + 40 end

            -- Written casts/tests and Lua formals share one target-directed
            -- dynamic policy. Container contents remain strict observations.
            assert(test.item_is(item) and test.item_as(item) == 10)
            assert(not test.item_is({ number = 10 }))
            assert(not test.item_is(array))
            fails(function() test.item_as({ number = 10 }) end)
            fails(function() test.item_as(array) end)
            assert(test.accept_item(item) == 10)
            fails(function() test.accept_item({ number = 10 }) end)
            fails(function() test.accept_item(array) end)

            assert(test.array_is(array) and test.array_as(array) == 20)
            assert(not test.array_is({20}))
            fails(function() test.array_as({20}) end)
            assert(test.accept_array(array) == 20)
            fails(function() test.accept_array({20}) end)
            local floats = test.new_float_array(20.0)
            assert(test.array_is(floats))
            fails(function() test.array_as(floats) end)

            assert(test.map_is(map) and test.map_as(map) == 30)
            assert(not test.map_is("map"))
            fails(function() test.map_as("map") end)
            assert(test.accept_map(map) == 30)
            fails(function() test.accept_map("map") end)
            assert(test.map_is({ x = 30.0 }))
            fails(function() test.map_as({ x = 30.0 }) end)

            assert(test.callback_is(callback), "callback is")
            local callback_cast = test.callback_as(callback)
            assert(callback_cast == 41,
                ("callback cast=%s type=%s"):format(
                    tostring(callback_cast),
                    tostring(math.type(callback_cast))))
            -- Function values deliberately remain unchecked until call time.
            assert(test.callback_is("callback"))
            assert(test.callback_as_only("callback") == "callback")
            fails(function() test.callback_as("callback") end)
            assert(test.accept_callback_only("callback") == "callback")
            assert(test.accept_callback(callback) == 41)
            fails(function() test.accept_callback("callback") end)

            -- Module and record setters apply the same kind policy and commit
            -- only after a successful conversion.
            test.item_slot = item
            test.array_slot = array
            test.map_slot = map
            test.callback_slot = callback
            assert(test.read_item_slot() == 10)
            assert(test.read_array_slot() == 20)
            assert(test.read_map_slot() == 30)
            assert(test.call_callback_slot(1) == 41)
            fails(function() test.item_slot = {} end)
            fails(function() test.array_slot = {} end)
            fails(function() test.map_slot = "map" end)
            assert(test.read_item_slot() == 10)
            assert(test.read_array_slot() == 20)
            assert(test.read_map_slot() == 30)
            test.callback_slot = "callback"
            fails(function() test.call_callback_slot(1) end)
            test.callback_slot = callback
            assert(test.call_callback_slot(1) == 41)

            local box = test.new_box()
            box.item = item
            box.array = array
            box.map = map
            box.callback = callback
            assert(test.read_box(box) == 101)
            fails(function() box.item = {} end)
            fails(function() box.array = {} end)
            fails(function() box.map = "map" end)
            box.callback = "callback"
            fails(function() test.read_box(box) end)
            box.callback = callback
            assert(test.read_box(box) == 101)

            -- Array writers use the same policy and preserve both contents and
            -- length when a non-nil conversion fails.
            local items = test.new_item_values()
            items[1] = item
            fails(function() items[2] = {} end)
            assert(#items == 1 and test.read_item_values(items) == 10)

            local arrays = test.new_array_values()
            arrays[1] = array
            fails(function() arrays[2] = {} end)
            assert(#arrays == 1 and test.read_array_values(arrays) == 20)
            arrays[1] = floats
            fails(function() test.read_array_values(arrays) end)

            local maps = test.new_map_values()
            maps[1] = map
            fails(function() maps[2] = "map" end)
            assert(#maps == 1 and test.read_map_values(maps) == 30)

            local callbacks = test.new_callback_values()
            callbacks[1] = callback
            callbacks[1] = "callback"
            assert(#callbacks == 1)
            fails(function() test.read_callback_values(callbacks) end)
            callbacks[1] = callback
            assert(test.read_callback_values(callbacks) == 41)

            -- Results from non-Titan callables use the identical dynamic plan.
            assert(test.item_result(function() return item end) == 10)
            fails(function()
                test.item_result(function() return {} end)
            end)
            assert(test.array_result(function() return array end) == 20)
            fails(function()
                test.array_result(function() return {} end)
            end)
            assert(test.map_result(function() return map end) == 30)
            fails(function()
                test.map_result(function() return "map" end)
            end)
            assert(test.callback_result(
                function() return callback end) == 41)
            assert(test.callback_result_only(
                function() return "callback" end) == "callback")
            fails(function()
                test.callback_result(function() return "callback" end)
            end)
        ]])
    end)

    it("coerces genuine-Lua record, union, and bound method entries",
    function()
        run_coder([[
            record Counter
                number: integer
            end

            function Counter:add(
                delta: integer,
                enabled: boolean
            ): integer
                if enabled then
                    self.number = self.number + delta
                end
                return self.number
            end

            function new_counter(number: integer): Counter
                return Counter.new(number)
            end

            function bind_counter(
                counter: Counter
            ): (integer, boolean) -> integer
                return counter:add
            end

            union Amount
                count: integer
            end

            function Amount:add(
                delta: integer,
                enabled: boolean
            ): integer
                case self
                when count: number then
                    if enabled then
                        return number + delta
                    end
                    return number
                else
                    return 0
                end
            end

            function new_amount(number: integer): Amount
                return Amount.count(number)
            end

            function bind_amount(
                amount: Amount
            ): (integer, boolean) -> integer
                return amount:add
            end
        ]], [[
            local counter = test.new_counter(10)
            assert(counter:add(2.0, "enabled") == 12)
            assert(counter:add(2.0, nil) == 12)
            local ok = pcall(function()
                counter:add(2.5, "enabled")
            end)
            assert(not ok and counter.number == 12)

            local bound_counter = test.bind_counter(counter)
            assert(bound_counter(3.0, "enabled") == 15)
            assert(bound_counter(3.0, nil) == 15)

            local amount = test.new_amount(20)
            assert(amount:add(2.0, "enabled") == 22)
            assert(amount:add(2.0, nil) == 20)
            local bound_amount = test.bind_amount(amount)
            assert(bound_amount(3.0, "enabled") == 23)
            assert(bound_amount(3.0, nil) == 20)
        ]])
    end)

    it("executes structural flexible-result and variadic forwarding", function()
        run_coder([[
            function produce(): (...: {value})
                return {1}
            end

            function consume(): {{integer}}
                return {produce()}
            end

            function sink(...: {{integer}})
            end

            function forward(...: {{value}})
                sink(...)
            end

            function run(): integer
                local collected = consume()
                local inner: {value} = {2}
                local outer: {{value}} = {inner}
                forward(outer)
                return collected[1][1]
            end
        ]], [[
            assert(test.run() == 1)
        ]])
    end)

    it("lowers written gradual and callable views from their stored plans",
    function()
        run_coder([[
            function actual(): integer
                return 9
            end

            function written_array(): integer
                local source: {integer} = {4}
                local viewed = source as {value}
                return viewed[1] as integer
            end

            function written_map(): integer
                local source: {string: integer} = { ["x"] = 5 }
                local viewed = source as {string: value}
                return viewed["x"] as integer
            end

            function written_callable(): integer
                local viewed = actual as () -> value
                return viewed() as integer
            end

            function written_option(v: value): integer
                local viewed = v as integer?
                return viewed
            end

            function option_is_integer(v: value): boolean
                return v is integer?
            end

            function written_nested_option(): integer
                local values: {value} = {8.0}
                local source: {value}? = values
                local viewed = source as {integer}?
                return viewed[1]
            end

            function nested_option_is_integer(): boolean
                local values: {value} = {8.0}
                local source: {value}? = values
                return source is {integer}?
            end
        ]], [[
            assert(test.written_array() == 4)
            assert(test.written_map() == 5)
            assert(test.written_callable() == 9)

            assert(test.written_option(6) == 6)
            assert(test.written_option(6.0) == 6)
            assert(test.option_is_integer(7))
            assert(test.option_is_integer(7.0))
            assert(test.option_is_integer(nil))
            assert(not pcall(test.written_nested_option))
            assert(test.nested_option_is_integer())
        ]])
    end)

    it("makes direct-coercion type tests match their written casts", function()
        run_coder([[
            function float_is_integer(v: float): boolean
                return v is integer
            end

            function optional_float_is_integer(v: float?): boolean
                return v is integer
            end

            function float_is_optional_integer(v: float): boolean
                return v is integer?
            end

            function optional_float_is_optional_integer(
                v: float?
            ): boolean
                return v is integer?
            end

            function optional_integer_is_float(v: integer?): boolean
                return v is float
            end

            function optional_integer_is_optional_float(
                v: integer?
            ): boolean
                return v is float?
            end
        ]], [[
            assert(test.float_is_integer(2.0))
            assert(not test.float_is_integer(2.5))

            assert(test.optional_float_is_integer(3.0))
            assert(not test.optional_float_is_integer(3.5))
            assert(not test.optional_float_is_integer(nil))

            assert(test.float_is_optional_integer(4.0))
            assert(not test.float_is_optional_integer(4.5))

            assert(test.optional_float_is_optional_integer(5.0))
            assert(not test.optional_float_is_optional_integer(5.5))
            assert(test.optional_float_is_optional_integer(nil))

            assert(test.optional_integer_is_float(6))
            assert(not test.optional_integer_is_float(nil))
            assert(test.optional_integer_is_optional_float(7))
            assert(test.optional_integer_is_optional_float(nil))
        ]])
    end)

    it("compares fresh asymmetric callable views in both operand orders", function()
        run_coder([[
            local function short(x: integer): integer
                return x
            end

            function compare_callable_views(): (boolean, boolean)
                local narrow: (integer) -> integer = short
                local wide: (integer, integer) -> integer = short
                return narrow == wide, wide == narrow
            end
        ]], [[
            local forward, reverse = test.compare_callable_views()
            assert(not forward)
            assert(not reverse)
        ]])
    end)

    it("compares every boolean option state with nil", function()
        run_coder([[
            function is_nil(candidate: boolean?): boolean
                return candidate == nil
            end

            function nil_is(candidate: boolean?): boolean
                return nil == candidate
            end

            function is_present(candidate: boolean?): boolean
                return candidate ~= nil
            end

            function nil_is_not(candidate: boolean?): boolean
                return nil ~= candidate
            end
        ]], [[
            assert(test.is_nil(nil))
            assert(test.nil_is(nil))
            assert(not test.is_present(nil))
            assert(not test.nil_is_not(nil))

            for _, candidate in ipairs({false, true}) do
                assert(not test.is_nil(candidate))
                assert(not test.nil_is(candidate))
                assert(test.is_present(candidate))
                assert(test.nil_is_not(candidate))
            end
        ]])
    end)

    it("reads and dynamically writes C scalar container values", function()
        run_coder([[
            local ffi =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            function read_array(): integer
                local one = 1 as ffi.titan_spec_i8
                local xs: {ffi.titan_spec_i8} = {one}
                return xs[1]
            end

            function read_map(): integer
                local one = 1 as ffi.titan_spec_i8
                local map: {string: ffi.titan_spec_i8} = {
                    ["one"] = one
                }
                return map["one"]
            end

            function new_array(): value
                local one = 1 as ffi.titan_spec_i8
                return {one}
            end

            function read_array_value(values: value): integer
                local typed =
                    values as {ffi.titan_spec_i8}
                return typed[1]
            end
        ]], [[
            assert(test.read_array() == 1)
            assert(test.read_map() == 1)

            local values = test.new_array()
            values[1] = 2.0
            assert(test.read_array_value(values) == 2)
            assert(not pcall(function()
                values[1] = 2.5
            end))
        ]])
    end)

    it("covers representative C numeric and recursive Option dynamic sinks",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            local record SmallBox
                number: c.titan_spec_i8
                optional: integer?
            end

            function new_box(): value
                return SmallBox.new(1 as c.titan_spec_i8, 1)
            end

            function read_box(v: value): (integer, integer?)
                local box = v as SmallBox
                return box.number, box.optional
            end

            function i8_as(v: value): integer
                local narrowed = v as c.titan_spec_i8
                return narrowed
            end

            function option_as(v: value): integer?
                return v as integer?
            end

            function new_values(): value
                local one = 1 as c.titan_spec_i8
                return {one}
            end

            function read_values(v: value): integer
                local values = v as {c.titan_spec_i8}
                return values[1]
            end
        ]], [[
            assert(test.i8_as(2.0) == 2)
            assert(not pcall(test.i8_as, 2.5))
            assert(test.option_as(nil) == nil)
            assert(test.option_as(3.0) == 3)

            local box = test.new_box()
            box.number = 4.0
            box.optional = nil
            local number, optional = test.read_box(box)
            assert(number == 4 and optional == nil)

            local values = test.new_values()
            values[1] = 5.0
            assert(test.read_values(values) == 5)
            assert(not pcall(function() values[2] = 5.5 end))
            assert(#values == 1)
        ]])
    end)

    it("keeps C numeric and recursive Option dynamic sinks in parity #stress",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            local record CBox
                i8: c.titan_spec_i8
                f32: c.titan_spec_float
            end

            function new_c_box(): value
                return CBox.new(
                    1 as c.titan_spec_i8,
                    1.25 as c.titan_spec_float)
            end

            function read_c_box(v: value): (integer, float)
                local box = v as CBox
                return box.i8, box.f32
            end

            function i8_is(v: value): boolean
                return v is c.titan_spec_i8
            end

            function i8_as(v: value): integer
                local narrowed = v as c.titan_spec_i8
                return narrowed
            end

            function f32_is(v: value): boolean
                return v is c.titan_spec_float
            end

            function f32_as(v: value): float
                local narrowed = v as c.titan_spec_float
                return narrowed
            end

            local function take_i8(v: c.titan_spec_i8): integer
                return v
            end

            local function take_f32(v: c.titan_spec_float): float
                return v
            end

            local function result_i8(
                f: () -> c.titan_spec_i8
            ): integer
                return f()
            end

            local function result_f32(
                f: () -> c.titan_spec_float
            ): float
                return f()
            end

            function i8_entry(): value
                return take_i8
            end

            function f32_entry(): value
                return take_f32
            end

            function i8_result_entry(): value
                return result_i8
            end

            function f32_result_entry(): value
                return result_f32
            end

            function new_i8_values(): value
                local one = 1 as c.titan_spec_i8
                return {one}
            end

            function read_i8_values(v: value): integer
                local values = v as {c.titan_spec_i8}
                return values[1]
            end

            function new_f32_values(): value
                local one = 1.25 as c.titan_spec_float
                return {one}
            end

            function read_f32_values(v: value): float
                local values = v as {c.titan_spec_float}
                return values[1]
            end

            maybe_slot: integer? = 1

            record OptionBox
                item: integer?
            end

            function new_option_box(): OptionBox
                return OptionBox.new(1)
            end

            function read_option_box(box: OptionBox): integer?
                return box.item
            end

            function option_is(v: value): boolean
                return v is integer?
            end

            function option_as(v: value): integer?
                return v as integer?
            end

            function option_formal(v: integer?): integer?
                return v
            end

            function option_result(
                f: () -> integer?
            ): integer?
                return f()
            end

            function new_option_values(): {integer?}
                return {1}
            end

            function read_option_values(
                values: {integer?}
            ): integer?
                return values[1]
            end
        ]], [[
            local function fails(f)
                local ok = pcall(f)
                assert(not ok)
            end

            -- C scalar written casts/tests, Lua formals, local-record fields,
            -- Array writers, and non-Titan results use one checked numeric
            -- policy, including target representability.
            assert(test.i8_is(2) and test.i8_is(2.0))
            assert(not test.i8_is(2.5))
            assert(test.i8_as(2.0) == 2)
            fails(function() test.i8_as(2.5) end)

            assert(test.f32_is(2) and test.f32_is(2.5))
            assert(not test.f32_is("float"))
            assert(test.f32_as(2) == 2.0)
            fails(function() test.f32_as("float") end)

            local take_i8 = test.i8_entry()
            local take_f32 = test.f32_entry()
            assert(take_i8(3.0) == 3)
            fails(function() take_i8(3.5) end)
            assert(take_f32(3) == 3.0)
            fails(function() take_f32("float") end)

            local box = test.new_c_box()
            box.i8 = 4.0
            box.f32 = 4
            local i8, f32 = test.read_c_box(box)
            assert(i8 == 4)
            assert(f32 == 4.0 and math.type(f32) == "float")
            fails(function() box.i8 = 4.5 end)
            fails(function() box.f32 = "float" end)
            i8, f32 = test.read_c_box(box)
            assert(i8 == 4 and f32 == 4.0)

            local i8_values = test.new_i8_values()
            i8_values[1] = 5.0
            fails(function() i8_values[2] = 5.5 end)
            assert(#i8_values == 1)
            assert(test.read_i8_values(i8_values) == 5)

            local f32_values = test.new_f32_values()
            f32_values[1] = 5
            fails(function() f32_values[2] = "float" end)
            assert(#f32_values == 1)
            assert(test.read_f32_values(f32_values) == 5.0)

            local result_i8 = test.i8_result_entry()
            local result_f32 = test.f32_result_entry()
            assert(result_i8(function() return 6.0 end) == 6)
            fails(function()
                result_i8(function() return 6.5 end)
            end)
            assert(result_f32(function() return 6 end) == 6.0)
            fails(function()
                result_f32(function() return "float" end)
            end)

            -- Recursive Option conversion has the same behavior at every
            -- representable public boundary; Array nil remains deletion.
            assert(test.option_is(nil) and test.option_is(7.0))
            assert(not test.option_is("option"))
            assert(test.option_as(nil) == nil)
            assert(test.option_as(7.0) == 7)
            fails(function() test.option_as("option") end)

            assert(test.option_formal(nil) == nil)
            assert(test.option_formal(8.0) == 8)
            fails(function() test.option_formal("option") end)

            test.maybe_slot = nil
            assert(test.maybe_slot == nil)
            test.maybe_slot = 9.0
            assert(test.maybe_slot == 9)
            fails(function() test.maybe_slot = "option" end)
            assert(test.maybe_slot == 9)

            local option_box = test.new_option_box()
            option_box.item = nil
            assert(test.read_option_box(option_box) == nil)
            option_box.item = 10.0
            assert(test.read_option_box(option_box) == 10)
            fails(function() option_box.item = "option" end)
            assert(test.read_option_box(option_box) == 10)

            local options = test.new_option_values()
            options[1] = nil
            assert(#options == 0)
            options[1] = 11.0
            fails(function() options[2] = "option" end)
            assert(#options == 1)
            assert(test.read_option_values(options) == 11)

            assert(test.option_result(function() return nil end) == nil)
            assert(test.option_result(function() return 12.0 end) == 12)
            fails(function()
                test.option_result(function() return "option" end)
            end)
        ]])
    end)

    it("covers representative owned C and raw TValue dynamic targets",
    function()
        run_coder([[
            local ffi =
                foreign import "spec/fixtures/c_tvalue_soundness.h"
            local type Owner = owned ffi.titan_spec_tvalue_i8[]

            local record DynamicBox
                owner: Owner
                raw: ffi.TValue
            end

            function new_owner(): value
                return ffi.titan_spec_tvalue_i8.new_array(2)
            end

            function owner_length(v: value): integer
                local owner = v as Owner
                return #owner
            end

            function raw_roundtrip(v: value): value
                local raw = v as ffi.TValue
                return raw
            end

            function new_box(): value
                local owner: Owner =
                    ffi.titan_spec_tvalue_i8.new_array(2)
                local raw: ffi.TValue = "initial"
                return DynamicBox.new(owner, raw)
            end

            function read_box(v: value): (integer, value)
                local box = v as DynamicBox
                return #box.owner, box.raw
            end
        ]], [[
            local owner = test.new_owner()
            assert(test.owner_length(owner) == 2)
            assert(not pcall(test.owner_length, "owner"))

            local table_value = {}
            assert(test.raw_roundtrip(table_value) == table_value)
            assert(test.raw_roundtrip(nil) == nil)

            local box = test.new_box()
            box.owner = owner
            box.raw = table_value
            local length, raw = test.read_box(box)
            assert(length == 2 and raw == table_value)
        ]])
    end)

    it("covers owned C and raw TValue dynamic target rows #stress", function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"
            local ffi = foreign import "titan/ffi.h"
            local type Owner = owned c.titan_spec_i8[]
            local type OtherOwner = owned c.titan_spec_u8[]

            local record DynamicBox
                owner: Owner
                raw: ffi.TValue
            end

            function new_owner(): value
                return c.titan_spec_i8.new_array(2)
            end

            function new_other_owner(): value
                return c.titan_spec_u8.new_array(2)
            end

            function owner_is(v: value): boolean
                return v is Owner
            end

            function owner_as(v: value): integer
                local owner = v as Owner
                return #owner
            end

            local function take_owner(v: Owner): integer
                return #v
            end

            local function owner_result(
                f: () -> Owner
            ): integer
                return #f()
            end

            function owner_entry(): value
                return take_owner
            end

            function owner_result_entry(): value
                return owner_result
            end

            function new_dynamic_box(): value
                local owner: Owner =
                    c.titan_spec_i8.new_array(2)
                local raw: ffi.TValue = "initial"
                return DynamicBox.new(owner, raw)
            end

            function read_dynamic_box(v: value): (integer, value)
                local box = v as DynamicBox
                return #box.owner, box.raw
            end

            function new_owner_values(): value
                local owner: Owner =
                    c.titan_spec_i8.new_array(2)
                return {owner}
            end

            function read_owner_values(v: value): integer
                local values = v as {Owner}
                return #values[1]
            end

            function raw_is(v: value): boolean
                return v is ffi.TValue
            end

            function raw_as(v: value): value
                local raw = v as ffi.TValue
                return raw
            end

            local function take_raw(v: ffi.TValue): value
                return v
            end

            local function raw_result(
                f: () -> ffi.TValue
            ): value
                return f()
            end

            function raw_entry(): value
                return take_raw
            end

            function raw_result_entry(): value
                return raw_result
            end

            function new_raw_values(): value
                local raw: ffi.TValue = "initial"
                return {raw}
            end

            function read_raw_values(v: value): value
                local values = v as {ffi.TValue}
                return values[1]
            end
        ]], [[
            local function fails(f)
                local ok = pcall(f)
                assert(not ok)
            end

            local owner = test.new_owner()
            local other_owner = test.new_other_owner()
            local raw_values = test.new_raw_values()
            assert(test.owner_is(owner))
            assert(not test.owner_is("owner"))
            assert(not test.owner_is(raw_values))
            assert(not test.owner_is(other_owner))
            assert(test.owner_as(owner) == 2)
            fails(function() test.owner_as("owner") end)
            fails(function() test.owner_as(raw_values) end)
            fails(function() test.owner_as(other_owner) end)

            local take_owner = test.owner_entry()
            local owner_result = test.owner_result_entry()
            assert(take_owner(owner) == 2)
            fails(function() take_owner("owner") end)
            fails(function() take_owner(raw_values) end)
            fails(function() take_owner(other_owner) end)
            assert(owner_result(function() return owner end) == 2)
            fails(function()
                owner_result(function() return "owner" end)
            end)
            fails(function()
                owner_result(function() return raw_values end)
            end)
            fails(function()
                owner_result(function() return other_owner end)
            end)

            local box = test.new_dynamic_box()
            box.owner = owner
            box.raw = raw_values
            local length, raw = test.read_dynamic_box(box)
            assert(length == 2 and raw == raw_values)
            fails(function() box.owner = raw_values end)
            fails(function() box.owner = other_owner end)
            length, raw = test.read_dynamic_box(box)
            assert(length == 2 and raw == raw_values)

            local owners = test.new_owner_values()
            owners[1] = owner
            fails(function() owners[2] = other_owner end)
            assert(#owners == 1)
            assert(test.read_owner_values(owners) == 2)

            -- A raw TValue is the dynamic carrier itself: every Lua value is
            -- an accepted source and identity is preserved in casts, formals,
            -- record/Array stores, and results from non-Titan callables.
            local table_value = {}
            local function function_value() end
            assert(test.raw_is(nil))
            assert(test.raw_is(table_value))
            assert(test.raw_as(nil) == nil)
            assert(test.raw_as(table_value) == table_value)

            local take_raw = test.raw_entry()
            local raw_result = test.raw_result_entry()
            assert(take_raw(table_value) == table_value)
            assert(take_raw(function_value) == function_value)
            assert(raw_result(function() return table_value end)
                == table_value)
            assert(raw_result(function() return function_value end)
                == function_value)
            raw_values[1] = owner
            assert(test.read_raw_values(raw_values) == owner)
            raw_values[1] = table_value
            assert(test.read_raw_values(raw_values) == table_value)
        ]])
    end)

    it("lowers Option inner conversions and C TValue as one checked edge",
    function()
        run_coder([[
            local ffi =
                foreign import "spec/fixtures/c_tvalue_soundness.h"

            function force_float(x: integer?): float
                return x
            end

            function force_integer(x: float?): integer
                return x
            end

            function wrap_float(x: integer): float?
                return x
            end

            function wrap_integer(x: float): integer?
                return x
            end

            function raw_option(x: integer?): value
                local raw: ffi.TValue = x
                return raw
            end

            function force_c_integer(x: value?): integer
                local raw: ffi.titan_spec_tvalue_int = x
                return raw
            end

            function force_c_float(x: value?): float
                local raw: ffi.titan_spec_tvalue_double = x
                return raw
            end
        ]], [[
            assert(test.force_float(2) == 2.0)
            assert(not pcall(test.force_float, nil))
            assert(test.force_integer(2.0) == 2)
            assert(not pcall(test.force_integer, 2.5))

            assert(test.wrap_float(3) == 3.0)
            assert(test.wrap_integer(4.0) == 4)
            assert(not pcall(test.wrap_integer, 4.5))

            assert(test.raw_option(nil) == nil)
            assert(test.raw_option(9) == 9)

            assert(test.force_c_integer(5) == 5)
            assert(not pcall(test.force_c_integer, 5.0))
            assert(not pcall(test.force_c_integer, nil))
            assert(test.force_c_float(6.0) == 6.0)
            assert(not pcall(test.force_c_float, 6))
            assert(not pcall(test.force_c_float, nil))
        ]])
    end)

    it("allocates C scalar Lua-entry temporaries in a fresh module context",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            local function first_entry(input: c.titan_spec_i8): integer
                return 0
            end

            function get_entry(): value
                return first_entry
            end
        ]], [[
            local entry = test.get_entry()
            assert(entry(2) == 0)
            assert(entry(2.0) == 0)
            assert(not pcall(entry, 128))
        ]])
    end)

    it("covers C integer range guards before boxing and mutation",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            function value_as_i8(v: value): integer
                return v as c.titan_spec_i8
            end

            function widest_to_value(): value
                return c.titan_spec_ull_max()
            end

            function checked_call(v: value): integer
                c.titan_spec_take_i8(v as c.titan_spec_i8)
                return c.titan_spec_numeric_mutation_count()
            end

            function mutation_count(): integer
                return c.titan_spec_numeric_mutation_count()
            end

            local type I8s = owned c.titan_spec_i8[]
            local values: I8s = c.titan_spec_i8.new_array(1)

            function write_owned(v: integer): integer
                values[0] = v
                return values[0]
            end
        ]], [[
            assert(test.value_as_i8(-128) == -128)
            assert(test.value_as_i8(127) == 127)
            assert(not pcall(test.value_as_i8, 128))
            assert(not pcall(test.widest_to_value))

            local before = test.mutation_count()
            assert(not pcall(test.checked_call, 128))
            assert(test.mutation_count() == before)
            assert(test.checked_call(127) == before + 1)

            assert(test.write_owned(7) == 7)
            assert(not pcall(test.write_owned, 128))
            assert(test.write_owned(7) == 7)
        ]])
    end)

    it("checks C integer bounds before casts, boxing, and mutation #stress",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            function value_is_i8(v: value): boolean
                return v is c.titan_spec_i8
            end

            function value_as_i8(v: value): integer
                local narrowed = v as c.titan_spec_i8
                return narrowed
            end

            function implicit_i8(v: value): integer
                local narrowed: c.titan_spec_i8 = v
                return narrowed
            end

            function value_is_u8(v: value): boolean
                return v is c.titan_spec_u8
            end

            function value_as_u8(v: value): integer
                local narrowed = v as c.titan_spec_u8
                return narrowed
            end

            function value_is_c_bool(v: value): boolean
                return v is c.titan_spec_bool
            end

            function value_as_c_bool(v: value): integer
                local narrowed = v as c.titan_spec_bool
                return narrowed
            end

            function option_is_i8(v: value?): boolean
                return v is c.titan_spec_i8?
            end

            function option_as_i8(v: value?): integer
                local narrowed = v as c.titan_spec_i8?
                local present: c.titan_spec_i8 = narrowed
                return present
            end

            function widest_to_integer(): integer
                return c.titan_spec_ull_max()
            end

            function widest_to_value(): value
                return c.titan_spec_ull_max()
            end

            function explicit_integer_wrap(): integer
                local wide = 300 as c.titan_spec_ull
                local narrow = wide as c.titan_spec_u8
                return narrow
            end

            function checked_call(v: value): integer
                c.titan_spec_take_i8(v as c.titan_spec_i8)
                return c.titan_spec_numeric_mutation_count()
            end

            function checked_static_call(v: integer): integer
                c.titan_spec_take_i8(v)
                return c.titan_spec_numeric_mutation_count()
            end

            function mutation_count(): integer
                return c.titan_spec_numeric_mutation_count()
            end

            local type I8s = owned c.titan_spec_i8[]
            local owned_i8s: I8s =
                c.titan_spec_i8.new_array(1)

            function write_owned_i8(v: integer): integer
                owned_i8s[0] = v
                return owned_i8s[0]
            end

            function read_owned_i8(): integer
                return owned_i8s[0]
            end

            function new_i8_array(): value
                local one = 1 as c.titan_spec_i8
                return {one}
            end

            function read_i8_array(values: value): integer
                local typed = values as {c.titan_spec_i8}
                return typed[1]
            end
        ]], [[
            local function fails(f, ...)
                local ok = pcall(f, ...)
                assert(not ok)
            end

            assert(test.value_is_i8(-128))
            assert(test.value_is_i8(127))
            assert(not test.value_is_i8(-129))
            assert(not test.value_is_i8(128))
            assert(test.value_as_i8(-128) == -128)
            assert(test.value_as_i8(127) == 127)
            fails(test.value_as_i8, -129)
            fails(test.value_as_i8, 128)

            assert(test.value_is_u8(0))
            assert(test.value_is_u8(255))
            assert(not test.value_is_u8(-1))
            assert(not test.value_is_u8(256))
            assert(test.value_as_u8(0) == 0)
            assert(test.value_as_u8(255) == 255)
            fails(test.value_as_u8, -1)
            fails(test.value_as_u8, 256)

            assert(test.value_is_c_bool(0))
            assert(test.value_is_c_bool(1))
            assert(not test.value_is_c_bool(2))
            assert(test.value_as_c_bool(0) == 0)
            assert(test.value_as_c_bool(1) == 1)
            fails(test.value_as_c_bool, 2)

            -- Written value casts use the Lua-boundary conversion, while an
            -- implicit Titan gradual observation requires the exact tag.
            assert(test.value_as_i8(12.0) == 12)
            fails(test.implicit_i8, 12.0)

            -- `value?` normalizes to `value`, so the written cast/test uses
            -- the recursive Lua-boundary Option plan, including target range.
            assert(test.option_is_i8(nil), "nil option")
            assert(test.option_is_i8(13), "integer option")
            assert(test.option_is_i8(13.0), "float option")
            assert(not test.option_is_i8(128), "wide option")
            assert(test.option_as_i8(13) == 13)
            assert(test.option_as_i8(13.0) == 13)
            fails(test.option_as_i8, 128)
            fails(test.option_as_i8, nil)

            -- Neither a Titan scalar carrier nor `value` may silently lose
            -- bits while boxing a wider C integer.
            fails(test.widest_to_integer)
            fails(test.widest_to_value)

            -- A written C-to-C integer cast deliberately retains C semantics.
            assert(test.explicit_integer_wrap() == 44)

            -- The argument guard runs before the foreign side effect.
            assert(test.mutation_count() == 0)
            fails(test.checked_call, 128)
            assert(test.mutation_count() == 0)
            fails(test.checked_static_call, 128)
            assert(test.mutation_count() == 0)
            assert(test.checked_static_call(127) == 1)

            assert(test.write_owned_i8(7) == 7)
            fails(test.write_owned_i8, 128)
            assert(test.read_owned_i8() == 7)

            -- Lua Array writes share the dynamic conversion policy, but still
            -- reject target overflow before replacing the old element.
            local values = test.new_i8_array()
            fails(function() values[1] = 128 end)
            assert(test.read_i8_array(values) == 1)
            values[1] = 2.0
            assert(test.read_i8_array(values) == 2)
        ]])
    end)

    it("covers C float narrowing and float-to-integer conversion",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            function double_as_float(): float
                return c.titan_spec_double_max()
                    as c.titan_spec_float
            end

            function double_as_i8(v: float): integer
                local source = v as c.titan_spec_double
                return source as c.titan_spec_i8
            end

            function double_infinity(): float
                return c.titan_spec_double_inf()
            end
        ]], [[
            assert(not pcall(test.double_as_float))
            assert(test.double_as_i8(3.75) == 3)
            assert(test.double_as_i8(-128.75) == -128)
            assert(not pcall(test.double_as_i8, 128.0))
            assert(not pcall(test.double_as_i8, math.huge))
            assert(test.double_infinity() == math.huge)
        ]])
    end)

    it("checks C float narrowing and float-to-integer conversion #stress",
    function()
        run_coder([[
            local c =
                foreign import "spec/fixtures/c_numeric_soundness.h"

            function double_is_float(): boolean
                return c.titan_spec_double_max()
                    is c.titan_spec_float
            end

            function double_as_float(): float
                local narrowed = c.titan_spec_double_max()
                    as c.titan_spec_float
                return narrowed
            end

            function infinity_is_float(): boolean
                return c.titan_spec_double_inf()
                    is c.titan_spec_float
            end

            function infinity_as_float(): float
                local narrowed = c.titan_spec_double_inf()
                    as c.titan_spec_float
                return narrowed
            end

            function nan_is_float(): boolean
                return c.titan_spec_double_nan()
                    is c.titan_spec_float
            end

            function nan_as_float(): float
                local narrowed = c.titan_spec_double_nan()
                    as c.titan_spec_float
                return narrowed
            end

            function double_infinity(): float
                return c.titan_spec_double_inf()
            end

            function double_nan(): float
                return c.titan_spec_double_nan()
            end

            function float_infinity(): float
                return c.titan_spec_float_inf()
            end

            function long_double_infinity(): float
                return c.titan_spec_long_double_inf()
            end

            function double_is_i8(v: float): boolean
                local source = v as c.titan_spec_double
                return source is c.titan_spec_i8
            end

            function double_as_i8(v: float): integer
                local source = v as c.titan_spec_double
                local narrowed = source as c.titan_spec_i8
                return narrowed
            end

            function c_operator_u128_to_float(): float
                return c.titan_spec_u128_max()
                    + (0.0 as c.titan_spec_float)
            end
        ]], [[
            local function fails(f, ...)
                local ok = pcall(f, ...)
                assert(not ok)
            end

            assert(not test.double_is_float())
            fails(test.double_as_float)
            assert(not test.infinity_is_float())
            fails(test.infinity_as_float)
            assert(not test.nan_is_float())
            fails(test.nan_as_float)

            -- Same-width and widening conversions preserve exceptional
            -- floating values; only narrowing rejects them.
            assert(test.double_infinity() == math.huge)
            assert(test.float_infinity() == math.huge)
            local nan = test.double_nan()
            assert(nan ~= nan)
            fails(test.long_double_infinity)

            assert(test.double_is_i8(3.75))
            assert(test.double_as_i8(3.75) == 3)
            assert(test.double_is_i8(-128.75))
            assert(test.double_as_i8(-128.75) == -128)
            assert(not test.double_is_i8(128.0))
            assert(not test.double_is_i8(math.huge))
            assert(not test.double_is_i8(0.0 / 0.0))
            fails(test.double_as_i8, 128.0)
            fails(test.double_as_i8, math.huge)
            fails(test.double_as_i8, 0.0 / 0.0)

            -- The generated C usual-arithmetic conversion is still guarded
            -- when its integer operand cannot fit the selected float type.
            fails(test.c_operator_u128_to_float)
        ]])
    end)

    it("rejects malformed stored C pointer conversion plans", function()
        local c_integer = types.CInteger("int", true, 3, 32)
        local c_float = types.CFloat("double")
        local int_pointer = types.CPointer(c_integer, {})
        local float_pointer = types.CPointer(c_float, {})
        local pointer_pointer = types.CPointer(int_pointer, {})
        local const_int_pointer = types.CPointer(c_integer, {"const"})
        local void_pointer = types.CPointer(types.CVoid(), {})
        local c_char = types.CInteger("char", true, 1, 8)
        local char_pointer = types.CPointer(c_char, {})
        local function_pointer = types.CPointer(
            types.CFunction({}, types.CVoid(), false, false), {})
        local gc_array = types.Array(types.Integer(), false)
        local counted_char = types.COwned(c_char, true)
        local counted_int = types.COwned(c_integer, true)

        for _, case in ipairs({
            {c_integer, int_pointer},
            {int_pointer, pointer_pointer},
            {const_int_pointer, types.CPointer(const_int_pointer, {})},
        }) do
            local source, target = table.unpack(case)
            local valid_address = {
                kind = "coercion",
                op = "mutable_c_address",
                source = source,
                target = target,
            }
            assert.equal(valid_address,
                coder_values._checked_coercion_plan(
                    valid_address, source, target,
                    "test mutable C address"))
        end

        local function rejects(body)
            local ok, err = pcall(body)
            assert.falsy(ok)
            assert.match("test C pointer conversion", tostring(err))
        end
        local function rejects_coercion(op, source, target)
            rejects(function()
                coder_values._checked_coercion_plan({
                    kind = "coercion",
                    op = op,
                    source = source,
                    target = target,
                }, source, target, "test C pointer conversion")
            end)
        end
        local function rejects_explicit(op, source, target)
            rejects(function()
                coder_values._checked_explicit_conversion_plan({
                    kind = "explicit_conversion",
                    op = op,
                    source = source,
                    target = target,
                }, source, target, "test C pointer conversion")
            end)
        end

        local function validates_coercion(source, target, expected_op)
            local plan = assert(types.coercion(source, target))
            assert.equal(expected_op, plan.op)
            assert.equal(plan, coder_values._checked_coercion_plan(
                plan, source, target, "test valid C pointer conversion"))
        end
        local function validates_explicit(source, target, expected_op)
            local cast = assert(types.written_cast(source, target))
            assert.equal("explicit", cast.op)
            assert.equal(expected_op, cast.conversion.op)
            assert.equal(cast.conversion,
                coder_values._checked_explicit_conversion_plan(
                    cast.conversion, source, target,
                    "test valid C pointer conversion"))
        end

        for _, case in ipairs({
            {int_pointer, const_int_pointer, "c_pointer"},
            {int_pointer, void_pointer, "c_object_to_void_pointer"},
            {void_pointer, int_pointer, "c_void_to_object_pointer"},
            {types.String(), char_pointer, "string_to_c_pointer"},
        }) do
            validates_coercion(table.unpack(case))
        end
        for _, case in ipairs({
            {function_pointer, void_pointer,
                "c_function_pointer_to_void"},
            {gc_array, void_pointer, "gc_identity_to_void_pointer"},
            {char_pointer, types.String(), "pointer_to_string"},
            {counted_char, types.String(), "counted_owner_to_string"},
            {void_pointer, char_pointer, "c_void_to_object_pointer"},
        }) do
            validates_explicit(table.unpack(case))
        end

        rejects(function()
            coder_values._checked_coercion_plan({
                kind = "coercion",
                op = "mutable_c_address",
                source = float_pointer,
                target = pointer_pointer,
            }, float_pointer, pointer_pointer,
                "test C pointer conversion")
        end)
        rejects_coercion("mutable_c_address", const_int_pointer,
            pointer_pointer)
        rejects(function()
            coder_values._checked_coercion_plan({
                kind = "coercion",
                op = "mutable_c_address",
                source = c_integer,
                target = float_pointer,
            }, c_integer, float_pointer,
                "test C pointer conversion")
        end)
        rejects(function()
            coder_values._checked_coercion_plan({
                kind = "coercion",
                op = "mutable_c_address",
                source = c_integer,
                target = const_int_pointer,
            }, c_integer, const_int_pointer,
                "test C pointer conversion")
        end)

        rejects(function()
            coder_values._checked_explicit_conversion_plan({
                kind = "explicit_conversion",
                op = "c_mutable_address",
                source = c_integer,
                target = int_pointer,
            }, c_integer, int_pointer,
                "test C pointer conversion")
        end)

        for _, op in ipairs({
            "c_pointer",
            "c_object_to_void_pointer",
            "c_void_to_object_pointer",
        }) do
            rejects_coercion(op, int_pointer, float_pointer)
        end
        for _, op in ipairs({
            "c_object_to_void_pointer",
            "c_void_to_object_pointer",
            "c_function_pointer_to_void",
        }) do
            rejects_explicit(op, int_pointer, float_pointer)
        end

        rejects_explicit(
            "gc_identity_to_void_pointer", gc_array, float_pointer)
        rejects_explicit(
            "pointer_to_string", int_pointer, types.String())
        rejects_explicit(
            "counted_owner_to_string", counted_int, types.String())
        rejects_coercion(
            "string_to_c_pointer", types.String(), float_pointer)

        local c_array = types.CArray(c_integer, 4)
        rejects(function()
            coder_values._checked_explicit_conversion_plan({
                kind = "address_then_unsafe_object_pointer",
                source = int_pointer,
                target = float_pointer,
                probe_key = "checked-array-probe",
            }, c_array, float_pointer,
                "test C pointer conversion")
        end)

        rejects(function()
            coder_values._checked_explicit_conversion_plan({
                kind = "explicit_conversion",
                op = "c_unsafe_object_pointer_candidate",
                source = int_pointer,
                target = float_pointer,
            }, int_pointer, float_pointer,
                "test C pointer conversion")
        end)

        local checked_pointer = {
            kind = "unsafe_object_pointer",
            source = int_pointer,
            target = float_pointer,
            probe_key = "checked-pointer-probe",
        }
        assert.equal(checked_pointer,
            coder_values._checked_explicit_conversion_plan(
                checked_pointer, int_pointer, float_pointer,
                "test checked C pointer conversion"))
    end)

    it("asserts missing and unknown boundary lowering plans", function()
        local integer = types.Integer()
        assert.has_error(function()
            coder_values._checked_dynamic_plan(nil, integer, "test boundary")
        end, "test boundary is missing its checker plan")
        assert.has_error(function()
            coder_values._checked_dynamic_plan({
                kind = "dynamic_coercion",
                op = "mystery",
                target = integer,
            }, integer, "test boundary")
        end, "test boundary has unknown/mismatched operation mystery")

        local pointer = types.CPointer(
            types.CInteger("int", true, 3, 32), {})
        assert.is_false(coder_values._checked_dynamic_plan(
            false, pointer, "test unavailable boundary"))

        local option = types.Option(integer)
        assert.has_error(function()
            coder_values._checked_dynamic_plan({
                kind = "dynamic_coercion",
                op = "option",
                target = option,
                inner = {
                    kind = "dynamic_coercion",
                    op = "float",
                    target = types.Float(),
                },
            }, option, "test boundary")
        end, "test boundary Option present value plan target does not match integer")
        assert.has_error(function()
            coder_values._checked_dynamic_plan({
                kind = "dynamic_coercion",
                op = "option",
                target = option,
                inner = false,
            }, option, "test boundary")
        end, "test boundary Option present value contains an unavailable recursive plan")

        assert.has_error(function()
            coder_values._checked_gradual_guard(nil, integer, "test observation")
        end, "test observation is missing its checker guard plan")
        assert.has_error(function()
            coder_values._checked_gradual_guard({
                kind = "gradual_guard",
                op = "mystery",
                target = integer,
            }, integer, "test observation")
        end, "test observation has unknown/mismatched guard operation mystery")
        assert.is_false(coder_values._checked_gradual_guard(
            false, pointer, "test unavailable observation"))

        assert.has_error(function()
            coder_values._checked_gradual_guard({
                kind = "gradual_guard",
                op = "option",
                target = option,
                inner = {
                    kind = "gradual_guard",
                    op = "float",
                    target = types.Float(),
                },
            }, option, "test observation")
        end, "test observation Option present value guard target does not match integer")
        assert.has_error(function()
            coder_values._checked_gradual_guard({
                kind = "gradual_guard",
                op = "option",
                target = option,
                inner = false,
            }, option, "test observation")
        end, "test observation Option present value contains an unavailable recursive guard")

        assert.has_error(function()
            coder_values._checked_comparison_plan(
                nil, integer, integer, "test equality")
        end, "test equality is missing its checker comparison plan")
        assert.has_error(function()
            coder_values._checked_comparison_plan({
                kind = "comparison",
                op = "mystery",
                left = integer,
                right = integer,
            }, integer, integer, "test equality")
        end, "test equality has unknown comparison operation mystery")
        assert.has_error(function()
            coder_values._checked_comparison_plan({
                kind = "comparison",
                op = "consistent",
                left = integer,
                right = types.Float(),
            }, integer, types.Float(), "test equality")
        end, "test equality has no structural consistency evidence")
        assert.has_error(function()
            coder_values._checked_comparison_plan({
                kind = "comparison",
                op = "consistent",
                left = types.Value(),
                right = integer,
                right_adjustment = {
                    kind = "gradual_view",
                    op = "inject",
                    source = types.Float(),
                    target = types.Value(),
                },
            }, types.Value(), integer, "test equality")
        end, "test equality value injection plan does not match its operand types")

        local float = types.Float()
        assert.has_error(function()
            coder_numerics._checked_numeric_coercion(
                nil, integer, float, "test numeric coercion")
        end, "test numeric coercion lacks its checker plan")
        assert.has_error(function()
            coder_numerics._checked_numeric_coercion({
                kind = "mystery",
            }, integer, float, "test numeric coercion")
        end, "test numeric coercion has unknown plan kind mystery")
        assert.has_error(function()
            coder_numerics._checked_numeric_coercion({
                kind = "coercion",
                op = "integer_to_float",
                source = integer,
                target = integer,
            }, integer, float, "test numeric coercion")
        end, "test numeric coercion plan does not match its operand types")
        assert.has_error(function()
            coder_numerics._checked_numeric_coercion({
                kind = "coercion",
                op = "mystery",
                source = integer,
                target = float,
            }, integer, float, "test numeric coercion")
        end, "test numeric coercion has unknown/mismatched operation mystery")
        assert.has_error(function()
            coder_values._checked_coercion_plan({
                kind = "coercion",
                op = "truthiness",
                source = integer,
                target = float,
            }, integer, float, "test coercion")
        end, "test coercion has a mismatched truthiness operation")

        local option_float = types.Option(float)
        assert.has_error(function()
            coder_values._checked_coercion_plan({
                kind = "coercion",
                op = "option_map",
                source = option,
                target = option_float,
                inner = {
                    kind = "identity",
                    source = integer,
                    target = integer,
                },
            }, option, option_float, "test coercion")
        end, "test coercion Option map plan does not match its operand types")

        assert.has_error(function()
            coder_values._checked_adjustment_plan({
                kind = "identity",
                source = integer,
                target = float,
            }, integer, float, "test adjustment")
        end, "test adjustment identity plan changes its operand type")

        local source_callable = types.Function(
            { float }, {}, false, false, false)
        local target_callable = types.Function(
            { integer }, {}, false, false, false)
        assert.has_error(function()
            coder_values._checked_callable_plan({
                kind = "callable",
                source = source_callable,
                target = target_callable,
                exact = false,
                arguments = {
                    {
                        kind = "argument",
                        expected_index = 1,
                        actual_index = 1,
                        adjustment = {
                            kind = "direct_coercion",
                            source = integer,
                            target = float,
                            coercion = {
                                kind = "coercion",
                                op = "integer_to_float",
                                source = integer,
                                target = float,
                            },
                        },
                    },
                },
                results = {},
            }, source_callable, target_callable, "test callable")
        end, "test callable argument 1 contains an ordinary component coercion")

        local c_integer = types.CInteger("int", true, 3, 32)
        local c_float = types.CFloat("double")
        assert.has_error(function()
            coder_numerics._checked_explicit_numeric_conversion(
                nil, c_integer, c_float, "test explicit numeric cast")
        end, "test explicit numeric cast lacks its checker plan")
        assert.has_error(function()
            coder_numerics._checked_explicit_numeric_conversion({
                kind = "explicit_conversion",
                op = "mystery",
            }, c_integer, c_float, "test explicit numeric cast")
        end, "test explicit numeric cast has unknown plan operation mystery")
        assert.has_error(function()
            coder_numerics._checked_explicit_numeric_conversion({
                kind = "explicit_conversion",
                op = "c_numeric",
                source = c_integer,
                target = c_integer,
            }, c_integer, c_float, "test explicit numeric cast")
        end, "test explicit numeric cast plan does not match its operand types")

        assert.equal(127, coder_numerics._float_integer_capacity({
            kind = "float",
            radix = 2,
            maximum_exponent = 128,
        }))
        assert.equal(196, coder_numerics._float_integer_capacity({
            kind = "float",
            radix = 16,
            maximum_exponent = 50,
        }))
        assert.has_error(function()
            coder_numerics._float_integer_capacity({
                kind = "float",
                maximum_exponent = 128,
            })
        end, "integer-to-floating lowering lacks target radix/exponent metadata")
    end)
end)

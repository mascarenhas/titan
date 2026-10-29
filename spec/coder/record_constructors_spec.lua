local h = require "spec.support.helpers"

local modules = { "test", "record_call_provider", "record_call_consumer" }

local function clean()
    for _, name in ipairs(modules) do
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a" }) do
            os.remove(name .. suffix)
        end
        os.execute("rm -rf " .. name .. ".so.dSYM")
    end
end

describe("record constructor calls (code generation)", function()
    after_each(clean)

    it("calls default constructors with positional, named, and string syntax", function()
        h.run_coder([[
            record Point
                x: integer
                y: integer
            end
            record Label
                text: string
            end
            record Empty end
            origin: Point = Point(1, 2)

            function run(): integer
                local p = Point(3, 4)
                local q = Point{y = 6, x = 5}
                local text = Label "seven"
                local empty = Empty()
                return origin.x + origin.y + p.x + p.y + q.x + q.y + #text.text
            end
        ]], [[
            assert(test.run() == 26)
            local point = test.Point(11, 12)
            assert(point.x == 11 and point.y == 12)
            assert((test.Label "hello").text == "hello")
            assert(type(test.Empty()) == "userdata")
        ]])
    end)

    it("preserves evaluation order and ordinary positional call adjustment", function()
        h.run_coder([[
            trace: integer = 0
            record Pair
                first: integer
                second: integer?
            end
            function mark(n: integer): integer
                trace = trace * 10 + n
                return n
            end
            function named(): integer
                trace = 0
                local pair = Pair{second = mark(1), first = mark(2)}
                return trace * 100 + pair.first * 10 + (pair.second or 0)
            end
            function positional(): integer
                trace = 0
                local pair = Pair(mark(1), mark(2), mark(3))
                return trace * 100 + pair.first * 10 + (pair.second or 0)
            end
            function missing(): boolean
                return Pair(1).second == nil
            end
        ]], [[
            assert(test.named() == 1221)
            assert(test.positional() == 12312)
            assert(test.missing())
            assert(test.Pair(7).second == nil)
        ]])
    end)

    it("uses an explicit new declared before its record", function()
        h.run_coder([[
            function Checked.new(input: integer): Checked
                if input < 0 then raise "negative input" end
                return {amount = input + 10}
            end
            record Checked
                local amount: integer
            end
            function Checked:get(): integer
                return self.amount
            end
            function run(): integer
                local a = Checked(1)
                local b = Checked{input = 2}
                local c = Checked.new(3)
                return a:get() + b:get() + c:get()
            end
        ]], [[
            assert(test.run() == 36)
            assert(test.Checked(4):get() == 14)
            assert(test.Checked.new(5):get() == 15)
            local ok, err = pcall(test.Checked, -1)
            assert(not ok and tostring(err):find("negative input", 1, true))
        ]])
    end)

    it("forwards arbitrary fixed results and zero results through Lua and Titan", function()
        h.run_coder([[
            count: integer = 0
            record Number end
            function Number.new(text: string): integer
                return #text
            end
            record Pair end
            function Pair.new(first: integer): (integer, string?, integer)
                return first, nil, first + 1
            end
            record Effect end
            function Effect.new(increment: integer)
                count = count + increment
            end
            function fixed(): (integer, string?, integer)
                Effect(2)
                return Pair(Number "four")
            end
        ]], [[
            local values = table.pack(test.fixed())
            assert(values.n == 3 and values[1] == 4 and values[2] == nil and values[3] == 5)
            values = table.pack(test.Pair(9))
            assert(values.n == 3 and values[1] == 9 and values[2] == nil and values[3] == 10)
            assert(test.Number "hello" == 5)
            assert(select('#', test.Effect(3)) == 0)
            assert(test.count == 5)
        ]])
    end)

    it("forwards variadic input and every flexible result", function()
        h.run_coder([[
            record Relay end
            function Relay.new(...: value): (...: value)
                return ...
            end
            function run(): (...: value)
                return Relay(1, nil, "tail")
            end
        ]], [[
            for _, invoke in ipairs({test.run, function() return test.Relay(1, nil, 'tail') end}) do
                local values = table.pack(invoke())
                assert(values.n == 3 and values[1] == 1 and values[2] == nil and values[3] == 'tail')
            end
            assert(select('#', test.Relay()) == 0)
        ]])
    end)

    it("keeps private default and explicit constructors unavailable to Lua", function()
        h.run_coder([[
            record PrivateDefault
                local value: integer
            end
            record PrivateOverride
                value: integer
            end
            local function PrivateOverride.new(value: integer): PrivateOverride
                return {value = value + 1}
            end
            function run(): integer
                local a = PrivateDefault(10)
                local b = PrivateOverride(20)
                return a.value + b.value
            end
        ]], [[
            assert(test.run() == 31)
            for _, record in ipairs({test.PrivateDefault, test.PrivateOverride}) do
                assert(record.new == nil)
                assert(getmetatable(record) == nil)
                assert(not pcall(record, 1))
            end
        ]])
    end)

    it("calls the public new member of the Lua namespace", function()
        h.run_coder([[
            record Item
                value: integer
            end
        ]], [[
            local original = test.Item.new
            test.Item.new = function(value)
                collectgarbage('collect')
                return original(value + 1), 'extra'
            end
            local item, extra = test.Item(41)
            assert(item.value == 42 and extra == 'extra')

            test.Item.new = function(value)
                local next_value = coroutine.yield(value)
                return original(next_value), nil, 'resumed'
            end
            local thread = coroutine.create(function() return test.Item(7) end)
            local ok, yielded = coroutine.resume(thread)
            assert(ok and yielded == 7 and coroutine.status(thread) == 'suspended')
            collectgarbage('collect')
            local results = table.pack(coroutine.resume(thread, 8))
            assert(results.n == 4 and results[1] and results[2].value == 8)
            assert(results[3] == nil and results[4] == 'resumed')
            assert(coroutine.status(thread) == 'dead')
        ]])
    end)

    it("preserves generic owner arguments, inference, and aliases", function()
        h.run_coder([[
            record Box<|T|>
                item: T
            end
            function Box.new(item: T): Box<|T|>
                return {item = item}
            end
            type IntegerBox = Box<|integer|>
            record GenericFactory end
            function GenericFactory.new<|T|>(item: T): T
                return item
            end
            function run(): integer
                local explicit = Box<|integer|>(10)
                local inferred = Box{item = 20}
                local alias = IntegerBox(30)
                local result: integer = GenericFactory(40)
                return explicit.item + inferred.item + alias.item + result
            end
        ]], [[
            assert(test.run() == 100)
            assert(test.Box('Lua').item == 'Lua')
            assert(test.GenericFactory(42) == 42)
        ]])
    end)

    it("does not treat an override as native record allocation", function()
        h.run_coder([[
            record Sized
                values: const {integer}
            end
            function Sized.new(values: const {integer}): integer
                return #values
            end
            function run(): integer
                return Sized({1, 2, 3})
            end
        ]], [[
            assert(test.run() == 3)
        ]])
    end)

    it("calls exported aliases and custom constructors across source modules", function()
        assert(h.generate_modules({
            record_call_provider = [[
                record Item
                    local value: integer
                end
                function Item.new(input: integer): Item
                    return {value = input + 1}
                end
                function Item:get(): integer
                    return self.value
                end
                type Alias = Item
            ]],
            record_call_consumer = [[
                local provider = import "record_call_provider"
                function run(): integer
                    local a = provider.Item(20)
                    local b = provider.Alias{input = 21}
                    return a:get() + b:get()
                end
            ]],
        }, "record_call_consumer"))
        local ok, err = h.call("record_call_consumer", [[
            assert(record_call_consumer.run() == 43)
        ]])
        assert.is_true(ok, err)
    end)
end)

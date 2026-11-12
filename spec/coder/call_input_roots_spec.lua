-- A native call's inputs stay reachable until the call returns, wherever they
-- were read from: the caller roots an input that has no stable root of its
-- own. Each function below reads an input from a home that later code clears,
-- then forces a full collection while the input is still in use. `make`
-- returns an object with a finalizer and `collected` collects and returns how
-- many were finalized, so each function reports the count it saw while it
-- still held its input. A call's result stays rooted in the calling frame,
-- so each function gets its objects inside a record or Array that a helper
-- built.
local h = require "spec.support.helpers"

local PRELUDE = [[
    local type Make = function (): value
    local type Count = function (): integer

    record Holder
        item: value
    end

    local function hold(make: Make): Holder
        return Holder.new(make())
    end

    local function consume(holder: Holder, item: value, collected: Count): integer
        holder.item = nil
        local during = collected()
        if item == nil then return -1 end
        return during
    end

    local function clear(holder: Holder, collected: Count): integer
        holder.item = nil
        return collected()
    end

    local function second(item: value, during: integer): integer
        if item == nil then return -1 end
        return during
    end
]]

local DRIVER = [[
    local finalized = 0
    local function make()
        return setmetatable({}, { __gc = function() finalized = finalized + 1 end })
    end
    local function collected()
        collectgarbage("collect")
        return finalized
    end
    local early = {}
    for _, name in ipairs({ %s }) do
        local before = collected()
        if test[name](make, collected) ~= before then early[#early + 1] = name end
    end
    assert(#early == 0, "finalized while still in use: " .. table.concat(early, ", "))
]]

-- Every public function of `source` must return before any object it made is
-- finalized.
local function holds_inputs(source, names)
    local quoted = {}
    for index, name in ipairs(names) do quoted[index] = string.format("%q", name) end
    h.run_coder(PRELUDE .. source, string.format(DRIVER, table.concat(quoted, ", ")))
end

describe("native call inputs", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".dll", ".def", ".dll.def",
                                  ".a", ".ffi.h", ".titan.h", ".priv.h", ".parts" }) do
            os.remove("test" .. suffix)
        end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("keep an argument whose home the callee clears", function()
        holds_inputs([[
            function argument_from_field(make: Make, collected: Count): integer
                local holder = hold(make)
                return consume(holder, holder.item, collected)
            end

            local current: Holder? = nil
            local function consume_current(holder: Holder, collected: Count): integer
                current = nil
                local during = collected()
                if holder.item == nil then return -1 end
                return during
            end
            local function fill(make: Make)
                current = hold(make)
            end
            function argument_from_module_variable(make: Make, collected: Count): integer
                fill(make)
                return consume_current(current, collected)
            end

            local function consume_after(item: value, reset: function (): (),
                                         collected: Count): integer
                reset()
                local during = collected()
                if item == nil then return -1 end
                return during
            end
            -- The closure moves the object into the captured local, so no
            -- temporary of this frame holds it as well.
            function argument_from_captured_local(make: Make, collected: Count): integer
                local holder = hold(make)
                local item: value = nil
                local move = function ()
                    item = holder.item
                    holder.item = nil
                end
                local reset = function () item = nil end
                move()
                return consume_after(item, reset, collected)
            end

            local function forward(holder: Holder, item: value, collected: Count): integer
                return consume(holder, item, collected)
            end
            function parameter_passed_on(make: Make, collected: Count): integer
                local holder = hold(make)
                return forward(holder, holder.item, collected)
            end

            local function consume_variadic(holder: Holder, collected: Count,
                                            ...: value): integer
                holder.item = nil
                local during = collected()
                if ...[1] == nil then return -1 end
                return during
            end
            function static_variadic_element(make: Make, collected: Count): integer
                local holder = hold(make)
                return consume_variadic(holder, collected, holder.item)
            end

            -- The cast to an Option, the choice between two operands and the
            -- injection into `value` all pass the field's object through.
            record Pair
                first: Holder
                spare: Holder
            end
            local function consume_pair(pair: Pair, holder: Holder?, boxed: value,
                                        collected: Count): integer
                pair.first = pair.spare
                local during = collected()
                if holder == nil or boxed == nil then return -1 end
                return during
            end
            local function pair_over(make: Make): Pair
                return Pair.new(hold(make), Holder.new(nil))
            end
            function argument_through_conversions(make: Make, collected: Count): integer
                local pair = pair_over(make)
                return consume_pair(pair, pair.first or pair.spare, pair.first, collected)
            end
        ]], { "argument_from_field", "argument_from_module_variable",
              "argument_from_captured_local", "parameter_passed_on",
              "static_variadic_element", "argument_through_conversions" })
    end)

    it("keep a receiver, an Interface value and a callee closure read from a field", function()
        holds_inputs([[
            record Node
                child: Node?
                item: value
            end
            local function Node:detach(parent: Node, collected: Count): integer
                parent.child = nil
                local during = collected()
                if self.item == nil then return -1 end
                return during
            end
            local function tree(make: Make): Node
                return Node.new(Node.new(nil, make()), nil)
            end
            function receiver_from_field(make: Make, collected: Count): integer
                local parent = tree(make)
                return parent.child:detach(parent, collected)
            end

            interface Stepper
                function step(owner: Owner, collected: Count): integer
            end
            record Step
                item: value
            end
            record Owner
                stepper: Stepper?
            end
            function Step:step(owner: Owner, collected: Count): integer
                owner.stepper = nil
                local during = collected()
                if self.item == nil then return -1 end
                return during
            end
            local function owner_over(make: Make): Owner
                return Owner.new(Step.new(make()))
            end
            function interface_from_field(make: Make, collected: Count): integer
                local owner = owner_over(make)
                return owner.stepper:step(owner, collected)
            end

            record Slot
                fn: function (Slot, Count): integer
            end
            local function idle(slot: Slot, collected: Count): integer
                return 0
            end
            local function slot_over(make: Make): Slot
                local item = make()
                return Slot.new(function (slot: Slot, collected: Count): integer
                    slot.fn = idle
                    local during = collected()
                    if item == nil then return -1 end
                    return during
                end)
            end
            function callee_from_field(make: Make, collected: Count): integer
                local slot = slot_over(make)
                return slot.fn(slot, collected)
            end
        ]], { "receiver_from_field", "interface_from_field", "callee_from_field" })
    end)

    it("keep an earlier argument while a later argument runs", function()
        holds_inputs([[
            function positional(make: Make, collected: Count): integer
                local holder = hold(make)
                return second(holder.item, clear(holder, collected))
            end

            function named(make: Make, collected: Count): integer
                local holder = hold(make)
                return second { item = holder.item, during = clear(holder, collected) }
            end

            function through_function_value(make: Make, collected: Count): integer
                local holder = hold(make)
                local callee: function (value, integer): integer = second
                return callee(holder.item, clear(holder, collected))
            end

            local function clear_twice(holder: Holder, collected: Count): (integer, integer)
                holder.item = nil
                return collected(), 0
            end
            local function third(item: value, during: integer, unused: integer): integer
                if item == nil then return -1 end
                return during
            end
            function adjusted_list(make: Make, collected: Count): integer
                local holder = hold(make)
                return third(holder.item, clear_twice(holder, collected))
            end

            function immediate_function(make: Make, collected: Count): integer
                local holder = hold(make)
                local item: value = nil
                local move = function ()
                    item = holder.item
                    holder.item = nil
                end
                move()
                return second(item, (function (): integer
                    item = nil
                    return collected()
                end)())
            end
        ]], { "positional", "named", "through_function_value", "adjusted_list",
              "immediate_function" })
    end)

    it("keep a spread subject and the Array elements a variadic callee receives", function()
        holds_inputs([[
            record Bag
                items: {value}
                during: integer
            end
            local function replace(bag: Bag, collected: Count): integer
                bag.items = {}
                bag.during = collected()
                return 1
            end
            local function present(...: value): boolean
                return ...[1] ~= nil
            end
            local function bag_over(make: Make): Bag
                return Bag.new({ make() }, 0)
            end
            function subject_from_field(make: Make, collected: Count): integer
                local bag = bag_over(make)
                if not present(...bag.items[1, replace(bag, collected)]) then return -1 end
                return bag.during
            end

            local function consume_spread(items: {value}, collected: Count,
                                          ...: value): integer
                items[1] = nil
                local during = collected()
                if ...[1] == nil then return -1 end
                return during
            end
            local function items_over(make: Make): {value}
                return { make() }
            end
            function array_elements(make: Make, collected: Count): integer
                local items = items_over(make)
                return consume_spread(items, collected, ...items)
            end

            function array_elements_to_function_value(make: Make, collected: Count): integer
                local items = items_over(make)
                local callee: function ({value}, Count, ...: value): integer = consume_spread
                return callee(items, collected, ...items)
            end
        ]], { "subject_from_field", "array_elements", "array_elements_to_function_value" })
    end)

    it("leave an input that already has a root where it is", function()
        holds_inputs([[
            function from_local(make: Make, collected: Count): integer
                local holder = hold(make)
                local item = holder.item
                return consume(holder, item, collected)
            end

            local function consume_element(items: {value}, item: value,
                                           collected: Count): integer
                items[1] = nil
                local during = collected()
                if item == nil then return -1 end
                return during
            end
            local function items_over(make: Make): {value}
                return { make() }
            end
            function from_array_element(make: Make, collected: Count): integer
                local items = items_over(make)
                return consume_element(items, items[1], collected)
            end

            function to_immediate_function(make: Make, collected: Count): integer
                local holder = hold(make)
                return (function (item: value): integer
                    holder.item = nil
                    local during = collected()
                    if item == nil then return -1 end
                    return during
                end)(holder.item)
            end

            function from_call_result(make: Make, collected: Count): integer
                local holder = Holder.new(nil)
                return consume(holder, make(), collected)
            end
        ]], { "from_local", "from_array_element", "to_immediate_function",
              "from_call_result" })
    end)

    it("keep a concatenation operand while a later operand runs", function()
        -- Strings have no finalizer. The later operand replaces the field,
        -- collects, and allocates strings of the first operand's size, so a
        -- freed operand shows as different bytes in the result.
        h.run_coder([[
            local type Fill = function (): string

            record Named
                name: string
            end

            function named(fill: Fill): Named
                return Named.new(fill())
            end

            local function replace(target: Named, collect: function (): (),
                                   filler: Fill): string
                target.name = "short"
                collect()
                local other = filler()
                return "!"
            end

            function concatenated(target: Named, collect: function (): (),
                                  filler: Fill): string
                return target.name .. replace(target, collect, filler)
            end
        ]], [[
            local kept = {}
            local function filler()
                for _ = 1, 400 do kept[#kept + 1] = string.rep("b", 100) end
                return kept[#kept]
            end
            local target = test.named(function() return string.rep("a", 100) end)
            local result = test.concatenated(target,
                function() collectgarbage("collect") end, filler)
            assert(result == string.rep("a", 100) .. "!", "operand bytes were replaced")
        ]])
    end)
end)

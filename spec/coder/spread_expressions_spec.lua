local temporary = require "spec.support.temporary"
-- End-to-end regressions for tail-only Array, integer-Map, and input-vararg
-- spreads.
local h = require "spec.support.helpers"

local run_coder = h.run_coder

local function with_header(contents, body)
    local path = temporary.name(".h")
    local file = assert(io.open(path, "wb"))
    assert(file:write(contents))
    assert(file:close())
    local results = table.pack(xpcall(function() return body(path) end,
        debug.traceback))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function clean()
    for _, suffix in ipairs({ ".c", ".o", ".so", ".a" }) do
        os.remove("test" .. suffix)
    end
    os.execute("rm -rf test.dSYM")
end

describe("Array, Map, and vararg spread expressions (code generator)", function()
    after_each(clean)

    it("expands whole Arrays and inclusive/default/reversed slices", function()
        run_coder([[
            function whole(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return {...items}
            end

            function through_upper(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return {...items[, 2]}
            end

            function through_lower(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return {...items[3,]}
            end

            function between(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return {...items[2, 3]}
            end

            function reversed(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return {...items[4, 2]}
            end

            function indexed_subject(): {integer}
                local rows: {{integer}} = {{1, 2}, {30, 40}}
                return {...rows[2]}
            end

            function missing_indexed_subject(): {integer}
                local rows: {{integer}} = {}
                return {...rows[1]}
            end

            function const_whole(): {integer}
                local mutable: {integer} = {50, 60}
                local frozen: const {integer} =
                    mutable as const {integer}
                return {...frozen}
            end
        ]], [[
            local function same(actual, expected)
                assert(#actual == #expected)
                for i = 1, #expected do
                    assert(actual[i] == expected[i])
                end
            end

            same(test.whole(), {10, 20, 30, 40})
            same(test.through_upper(), {10, 20})
            same(test.through_lower(), {30, 40})
            same(test.between(), {20, 30})
            same(test.reversed(), {})
            same(test.indexed_subject(), {30, 40})
            same(test.const_whole(), {50, 60})

            local ok, err = pcall(test.missing_indexed_subject)
            assert(not ok and tostring(err):match("expected .* found nil"),
                tostring(err))
        ]])
    end)

    it("expands all input-vararg slice forms with the same range rules",
    function()
        run_coder([[
            function whole(...: integer): {integer}
                return {...}
            end

            function through_upper(last: integer, ...: integer): {integer}
                return {...[, last]}
            end

            function through_lower(first: integer, ...: integer): {integer}
                return {...[first,]}
            end

            function between(
                first: integer, last: integer, ...: integer
            ): {integer}
                return {...[first, last]}
            end
        ]], [[
            local function same(actual, expected)
                assert(#actual == #expected)
                for i = 1, #expected do
                    assert(actual[i] == expected[i])
                end
            end

            same(test.whole(10, 20, 30, 40), {10, 20, 30, 40})
            same(test.through_upper(2, 10, 20, 30, 40), {10, 20})
            same(test.through_lower(3, 10, 20, 30, 40), {30, 40})
            same(test.between(2, 3, 10, 20, 30, 40), {20, 30})
            same(test.between(4, 2, 10, 20, 30, 40), {})
        ]])
    end)

    it("evaluates prefix, subject, and supplied bounds once in order",
    function()
        run_coder([[
            local trace: integer = 0

            function mark(digit: integer, result: integer): integer
                trace = trace * 10 + digit
                return result
            end

            function prefix(): integer
                return mark(1, 99)
            end

            function subject(): {integer}
                trace = trace * 10 + 2
                return {10, 20, 30}
            end

            function lower(): float
                return mark(3, 2)
            end

            function upper(): float
                return mark(4, 3)
            end

            function ordered(): integer
                trace = 0
                local items: {integer} = {
                    prefix(), ...subject()[lower(), upper()]
                }
                if #items ~= 3 or items[1] ~= 99
                   or items[2] ~= 20 or items[3] ~= 30 then
                    return -trace
                end
                return trace
            end

            function touch(): ()
                return ...subject()[lower(), upper()]
            end

            function zero_demand(): integer
                trace = 0
                touch()
                return trace
            end
        ]], [[
            assert(test.ordered() == 1234)
            -- A zero-result sink still evaluates the written carrier and both
            -- explicit bounds. There is no prefix expression in this call.
            assert(test.zero_demand() == 234)
        ]])
    end)

    it("adjusts finite spreads for declarations, assignments, calls, and returns",
    function()
        run_coder([[
            function accept(
                first: integer?, second: integer?, third: integer?
            ): boolean
                if not first or first ~= 5 then return false end
                if not second or second ~= 6 then return false end
                return not third
            end

            function declared(): (integer?, integer?, integer?)
                local items: {integer} = {4, 5, 6}
                local first: integer?, second: integer?, third: integer? =
                    ...items[2, 3]
                return first, second, third
            end

            function assigned(): (integer?, integer?, integer?)
                local items: {integer} = {4, 5, 6}
                local first: integer?, second: integer?, third: integer?
                first, second, third = ...items[2, 3]
                return first, second, third
            end

            function called(): boolean
                local items: {integer} = {4, 5, 6}
                return accept(...items[2, 3])
            end

            function returned(): (integer?, integer?, integer?)
                local items: {integer} = {4, 5, 6}
                return ...items[2, 3]
            end
        ]], [[
            local function check_triplet(fn)
                local first, second, third = fn()
                assert(first == 5 and second == 6 and third == nil)
            end

            check_triplet(test.declared)
            check_triplet(test.assigned)
            assert(test.called())
            check_triplet(test.returned)
        ]])
    end)

    it("nil-fills finite misses and raises when a missing value is strict",
    function()
        run_coder([[
            function optional_array(): (integer?, integer?, integer?)
                local items: {integer} = {7}
                return ...items[1, 3]
            end

            function required_array(): integer
                local items: {integer} = {7}
                local first: integer, second: integer = ...items[1, 3]
                return first + second
            end

            function strict_array(): {integer}
                local items: {integer} = {7}
                return {...items[1, 3]}
            end

            function optional_vararg(
                ...: integer
            ): (integer?, integer?, integer?)
                return ...[1, 3]
            end

            function strict_vararg(...: integer): {integer}
                return {...[1, 3]}
            end

            function required_vararg(...: integer): integer
                local first: integer, second: integer = ...[1, 3]
                return first + second
            end
        ]], [[
            local a, b, c = test.optional_array()
            assert(a == 7 and b == nil and c == nil)
            a, b, c = test.optional_vararg(7)
            assert(a == 7 and b == nil and c == nil)

            local ok, err = pcall(test.required_array)
            assert(not ok and tostring(err):match("integer"))
            ok, err = pcall(test.strict_array)
            assert(not ok and tostring(err):match("integer"))
            ok, err = pcall(test.strict_vararg, 7)
            assert(not ok and tostring(err):match("out of range"))
            ok, err = pcall(test.required_vararg, 7)
            assert(not ok and tostring(err):match("integer"))
        ]])
    end)

    it("feeds open Array and vararg runs to a variadic call", function()
        run_coder([[
            function collect(...: integer): {integer}
                return {...}
            end

            function from_array(): {integer}
                local items: {integer} = {10, 20, 30, 40}
                return collect(99, ...items[2, 3])
            end

            function from_vararg(first: integer, ...: integer): {integer}
                return collect(77, ...[first,])
            end
        ]], [[
            local a = test.from_array()
            assert(#a == 3 and a[1] == 99 and a[2] == 20 and a[3] == 30)

            local b = test.from_vararg(2, 10, 20, 30, 40)
            assert(#b == 4 and b[1] == 77 and b[2] == 20
                   and b[3] == 30 and b[4] == 40)
        ]])
    end)

    it("feeds open Array and vararg runs to flexible returns", function()
        run_coder([[
            function array_results(): (...: integer)
                local items: {integer} = {10, 20, 30, 40}
                return 5, ...items[2, 3]
            end

            function vararg_results(...: integer): (...: integer)
                return 6, ...[2,]
            end
        ]], [[
            local a = table.pack(test.array_results())
            assert(a.n == 3 and a[1] == 5 and a[2] == 20 and a[3] == 30)

            local b = table.pack(test.vararg_results(10, 20, 30, 40))
            assert(b.n == 4 and b[1] == 6 and b[2] == 20
                   and b[3] == 30 and b[4] == 40)
        ]])
    end)

    it("uses ordinary Map length and indexing for finite and open ranges",
    function()
        run_coder([[
            function finite(
                items: {integer: integer}
            ): (integer?, integer?, integer?)
                return ...items[2, 4]
            end

            function collect(items: {integer: integer}): {integer}
                return {99, ...items[2,]}
            end

            function reversed(items: {integer: integer}): {integer}
                return {...items[4, 2]}
            end
        ]], [[
            local lengths, reads = 0, {}
            local items = setmetatable({[2] = 20, [4] = 40}, {
                __len = function()
                    lengths = lengths + 1
                    return 4
                end,
                __index = function(_, key)
                    reads[#reads + 1] = key
                    return key * 10
                end,
            })

            local a, b, c = test.finite(items)
            assert(a == 20 and b == 30 and c == 40)
            -- The explicit upper bound does not ask for Map length.
            assert(lengths == 0 and #reads == 1 and reads[1] == 3)

            reads = {}
            local values = test.collect(items)
            assert(#values == 4 and values[1] == 99 and values[2] == 20
                   and values[3] == 30 and values[4] == 40)
            assert(lengths == 1 and #reads == 1 and reads[1] == 3)

            reads = {}
            local empty = test.reversed(items)
            assert(#empty == 0 and #reads == 0 and lengths == 1)
        ]])
    end)

    it("nil-fills finite Map holes and raises for holes in an open run",
    function()
        run_coder([[
            function optional(
                items: {integer: integer}
            ): (integer?, integer?, integer?)
                return ...items[1, 3]
            end

            function strict(items: {integer: integer}): {integer}
                return {...items[1, 3]}
            end
        ]], [[
            local sparse = {[1] = 10, [3] = 30}
            local first, second, third = test.optional(sparse)
            assert(first == 10 and second == nil and third == 30)

            local ok, err = pcall(test.strict, sparse)
            assert(not ok and tostring(err):match("integer"))
        ]])
    end)

    it("keeps each buffered Map metamethod result in its lookup stack slot",
    function()
        run_coder([[
            function consume(...: {integer: string}): string
                local a = ...[1]
                local b = ...[2]
                local c = ...[3]
                return (a[1] or "") .. (b[1] or "") .. (c[1] or "")
            end

            function through_native(
                items: {integer: {integer: string}}
            ): string
                return consume(...items)
            end

            function through_value(
                sink: function (...: {integer: string}): string,
                items: {integer: {integer: string}}
            ): string
                return sink(...items)
            end

            function through_titan_value(
                items: {integer: {integer: string}}
            ): string
                local sink: function (...: {integer: string}): string = consume
                return sink(...items)
            end

            function through_array(
                items: {integer: {integer: string}}
            ): {{integer: string}}
                return {...items}
            end

            function through_results(
                items: {integer: {integer: string}}
            ): (...: {integer: string})
                return ...items
            end
        ]], [[
            local function source(label)
                local seen = setmetatable({}, {__mode = "v"})
                local next_key = 1
                local items = setmetatable({}, {
                    __len = function() return 3 end,
                    __index = function(_, key)
                        assert(key == next_key)
                        collectgarbage("collect")
                        for i = 1, key - 1 do
                            assert(seen[i] ~= nil,
                                label ..
                                ": earlier Map spread result lost its stack root")
                        end
                        local value = {[1] = "v" .. key}
                        seen[key] = value
                        next_key = next_key + 1
                        return value
                    end,
                })
                return items, seen
            end

            local native_items, native_seen = source("native")
            assert(test.through_native(native_items) == "v1v2v3")
            native_items = nil
            collectgarbage("collect")
            assert(native_seen[1] == nil and native_seen[2] == nil
                   and native_seen[3] == nil,
                "native Map argument materialization retained post-call roots")

            local function lua_sink(a, b, c)
                collectgarbage("collect")
                return a[1] .. b[1] .. c[1]
            end
            local value_items, value_seen = source("value")
            assert(test.through_value(lua_sink, value_items) == "v1v2v3")
            value_items = nil
            collectgarbage("collect")
            assert(value_seen[1] == nil and value_seen[2] == nil
                   and value_seen[3] == nil,
                "function-value Map argument materialization retained post-call roots")

            local fast_items, fast_seen = source("value-fast")
            assert(test.through_titan_value(fast_items) == "v1v2v3")
            fast_items = nil
            collectgarbage("collect")
            assert(fast_seen[1] == nil and fast_seen[2] == nil
                   and fast_seen[3] == nil,
                "exact function-value Map materialization retained post-call roots")

            local array_items = source("array")
            local array = test.through_array(array_items)
            assert(#array == 3 and array[1][1] == "v1"
                   and array[2][1] == "v2" and array[3][1] == "v3")

            local result_items = source("results")
            local results = table.pack(test.through_results(result_items))
            assert(results.n == 3 and results[1][1] == "v1"
                   and results[2][1] == "v2" and results[3][1] == "v3")
        ]])
    end)

    it("roots Interfaces discovered while reading delayed Array views",
    function()
        run_coder([[
            interface View
                function get(): integer
            end

            record Item
                number: integer
            end

            function Item:get(): integer
                return self.number
            end

            -- Register the real static Item/View witness whose delayed Array
            -- view is discovered element-by-element below.
            local function witnessed(item: Item): View
                return item
            end

            local function make_views(): {View}
                local concrete: {Item} = {
                    Item.new(10), Item.new(20), Item.new(30)
                }
                local dynamic: {value} = concrete
                local viewed: {View} = dynamic
                return viewed
            end

            local function churn()
                local junk: {Item} = {}
                local i = 1
                while i <= 300 do
                    junk = {Item.new(i)}
                    i = i + 1
                end
                if #junk ~= 1 then raise "unreachable" end
            end

            local function fixed(
                first: View, second: View, third: View
            ): integer
                churn()
                return first:get() + second:get() + third:get()
            end

            local function open(...: View): integer
                churn()
                local total = 0
                local i = 1
                while i <= #... do
                    local item: View = ...[i]
                    total = total + item:get()
                    i = i + 1
                end
                return total
            end

            function through_fixed(): integer
                return fixed(...make_views())
            end

            function through_open(): integer
                return open(...make_views())
            end

            function finite_results(): (View, View, View)
                return ...make_views()
            end

            function flexible_results(): (...: View)
                return ...make_views()
            end

            function through_constructor(): {View}
                return {...make_views()}
            end
        ]], [[
            local function check(first, second, third)
                collectgarbage("collect")
                assert(first:get() == 10)
                assert(second:get() == 20)
                assert(third:get() == 30)
            end

            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                assert(test.through_fixed() == 60)
                assert(test.through_open() == 60)
                check(test.finite_results())
                check(test.flexible_results())
                local viewed = test.through_constructor()
                collectgarbage("collect")
                assert(#viewed == 3)
                assert(viewed[1]:get() == 10)
                assert(viewed[2]:get() == 20)
                assert(viewed[3]:get() == 30)
            end
        ]])
    end)

    it("keeps each allocating open adjustment rooted through the call",
    function()
        run_coder([[
            interface View
                function get(): integer
            end

            record Item
                number: integer
            end

            function Item:get(): integer
                return self.number
            end

            -- Register the concrete implementation for dynamic value-to-View
            -- projection in the open conversion loops below.
            local function witnessed(item: Item): View
                return item
            end

            local function churn()
                local latest: View = Item.new(0)
                for i = 1, 500 do
                    latest = Item.new(i)
                end
                if latest:get() ~= 500 then raise "unreachable" end
            end

            local function required(
                force: function (): (), ...: View
            ): integer
                force()
                churn()
                return (...[1]):get() + (...[2]):get() + (...[3]):get()
            end

            local function optional(
                force: function (): (), ...: View?
            ): integer
                force()
                churn()
                local total = 0
                local first: View? = ...[1]
                local second: View? = ...[2]
                local third: View? = ...[3]
                if first then total = total + first:get() end
                if second then total = total + second:get() end
                if third then total = total + third:get() end
                return total
            end

            function array_required(force: function (): ()): integer
                local items: {value} = {
                    Item.new(10), Item.new(20), Item.new(30)
                }
                return required(force, ...items)
            end

            function map_required(force: function (): ()): integer
                local items: {integer: value} = {
                    Item.new(10), Item.new(20), Item.new(30)
                }
                return required(force, ...items)
            end

            function array_optional(force: function (): ()): integer
                local items: {value?} = {
                    Item.new(40), nil, Item.new(60)
                }
                return optional(force, ...items)
            end
        ]], [[
            local function force_collection()
                collectgarbage("collect")
                collectgarbage("collect")
            end

            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                assert(test.array_required(force_collection) == 60)
                assert(test.map_required(force_collection) == 60)
                assert(test.array_optional(force_collection) == 100)
            end
        ]])
    end)

    it("separates Map read roots from nonallocating open adjustments",
    function()
        run_coder([[
            function sum(...: integer): integer
                local total = 0
                for i = 1, #... do
                    total = total + ...[i]
                end
                return total
            end

            function map_sum(): integer
                local items: {integer: value} = {10, 20, 30}
                return sum(...items)
            end
        ]], [[
            assert(test.map_sum() == 60)
        ]])
    end)

    it("executes nested generic Array and Map producers after inference",
    function()
        run_coder([[
            function make_array<|T|>(): {T}
                return {((42 as value) as T)}
            end

            function make_map<|T|>(): {integer: T}
                local out: {integer: T} = {((42 as value) as T)}
                return out
            end

            function make_optional_array<|T|>(present: boolean): {T}?
                if not present then return nil end
                return make_array<|T|>()
            end

            function make_optional_map<|T|>(present: boolean): {integer: T}?
                if not present then return nil end
                return make_map<|T|>()
            end

            function second<|T|>(head: T, tail: T): T
                return tail
            end

            function open_head<|T|>(head: T, ...: T): T
                return ...[1]
            end

            function array_fixed(): integer
                return second(1, ...make_array())
            end

            function array_open(): integer
                return open_head(1, ...make_array())
            end

            function map_fixed(): integer
                return second(1, ...make_map())
            end

            function map_open(): integer
                return open_head(1, ...make_map())
            end

            function optional_array_fixed(): integer
                return second(1, ...make_optional_array(true))
            end

            function optional_array_open(): integer
                return open_head(1, ...make_optional_array<|integer|>(true))
            end

            function optional_map_fixed(): integer
                return second(1, ...make_optional_map(true))
            end

            function optional_map_open(): integer
                return open_head(1, ...make_optional_map<|integer|>(true))
            end

            function missing_optional_array(): integer
                return second(1, ...make_optional_array<|integer|>(false))
            end
        ]], [[
            assert(test.array_fixed() == 42)
            assert(test.array_open() == 42)
            assert(test.map_fixed() == 42)
            assert(test.map_open() == 42)
            assert(test.optional_array_fixed() == 42)
            assert(test.optional_array_open() == 42)
            assert(test.optional_map_fixed() == 42)
            assert(test.optional_map_open() == 42)

            local ok, err = pcall(test.missing_optional_array)
            assert(not ok and tostring(err):match("found nil"), tostring(err))
        ]])
    end)

    it("supplies the four-slot generic-for setup tuple", function()
        run_coder([[
            function step(state: value, control: value): value
                local limit = state as integer
                local current = control as integer
                local next = current + 1
                if next > limit then return nil as value end
                return next as value
            end

            function setup(): {value}
                return {step as value, 3 as value, 0 as value}
            end

            function iterate(): integer
                local total = 0
                for item: integer in ...setup() do
                    total = total + item
                end
                return total
            end

            closed_state: integer = 0

            function generic_step<|T|>(state: T, control: T): T?
                return nil
            end

            function generic_setup<|U|>(
                state: U, control: U, finish: U
            ): {U}
                return {state, control, finish}
            end

            function finish(state: value)
                closed_state = state as integer
            end

            function generic_iterate(): integer
                closed_state = 0
                local state: value = 7
                local control: value = 0
                local closer: value = finish
                for item: value in
                        generic_step,
                        ...generic_setup(state, control, closer) do
                end
                return closed_state
            end
        ]], [[
            assert(test.iterate() == 6)
            assert(test.generic_iterate() == 7)
        ]])
    end)

    it("preflights sink limits and full-width range counts before reads",
    function()
        run_coder([[
            function count(...: integer): integer
                return #...
            end

            function call_count(items: {integer: integer}): integer
                return count(...items)
            end

            function prefixed_count(items: {integer: integer}): integer
                return count(0, ...items)
            end

            function flexible(
                items: {integer: integer}
            ): (...: integer)
                return ...items
            end

            function impossible_array(): {integer}
                local items: {integer} = {1}
                return {...items[
                    -9223372036854775808, 9223372036854775807
                ]}
            end

            function impossible_map(
                items: {integer: integer}
            ): {integer: integer}
                return {...items[
                    -9223372036854775808, 9223372036854775807
                ]}
            end
        ]], [[
            local reads = 0
            local function source(length)
                return setmetatable({}, {
                    __len = function() return length end,
                    __index = function(_, key)
                        reads = reads + 1
                        return key
                    end,
                })
            end

            reads = 0
            assert(test.call_count(source(200)) == 200)
            assert(reads == 200)

            reads = 0
            local ok, err = pcall(test.call_count, source(201))
            assert(not ok and tostring(err):match("too many variadic"))
            assert(reads == 0)

            reads = 0
            assert(test.prefixed_count(source(199)) == 200)
            assert(reads == 199)

            reads = 0
            ok, err = pcall(test.prefixed_count, source(200))
            assert(not ok and tostring(err):match("too many variadic"))
            assert(reads == 0)

            reads = 0
            local packed = table.pack(test.flexible(source(200)))
            assert(packed.n == 200 and reads == 200)

            reads = 0
            ok, err = pcall(test.flexible, source(201))
            assert(not ok and tostring(err):match("flexible return"))
            assert(reads == 0)

            ok, err = pcall(test.impossible_array)
            assert(not ok and tostring(err):match("array spread is too large"),
                tostring(err))

            ok, err = pcall(test.impossible_map, {})
            assert(not ok and tostring(err):match(
                "positional map spread is too large"), tostring(err))
        ]])
    end)

    it("feeds strict C calls, C pointer calls, and allocation constructors",
    function()
        with_header([[
            typedef int ffi_spread_int;
            typedef int (*ffi_spread_binary)(int, int);
            typedef struct ffi_spread_box {
                int value;
            } ffi_spread_box;

            static int ffi_spread_join(int left, int right) {
                return left * 10 + right;
            }

            static ffi_spread_binary ffi_spread_choose(void) {
                return ffi_spread_join;
            }

            static int ffi_spread_fill(
                    ffi_spread_box *box, int left, int right) {
                box->value = left * 10 + right;
                return box->value;
            }
        ]], function(header)
            run_coder([[
                foreign import "]] .. header .. [["
                local evaluations: integer = 0

                local function pair(): {integer}
                    evaluations = evaluations + 1
                    return {4, 2}
                end

                local function count(): {integer}
                    evaluations = evaluations + 1
                    return {3}
                end

                function direct(): integer
                    evaluations = 0
                    local result = ffi.ffi_spread_join(...pair()) as integer
                    return result * 10 + evaluations
                end

                function pointer(): integer
                    evaluations = 0
                    local fn: foreign ffi_spread_binary = ffi.ffi_spread_choose()
                    local result = fn(...pair()) as integer
                    return result * 10 + evaluations
                end

                function allocation(): integer
                    evaluations = 0
                    local values: owned ffi_spread_int[] =
                        foreign ffi_spread_int.new_array(...count())
                    return #values * 10 + evaluations
                end

                function mutated_automatic(): integer
                    evaluations = 0
                    local box = foreign ffi_spread_box.new()
                    do
                        ffi.ffi_spread_fill(box, ...pair())
                        raise "observe through spill"
                    catch
                        return (box.value as integer) * 10 + evaluations
                    end
                end
            ]], [[
                assert(test.direct() == 421)
                assert(test.pointer() == 421)
                assert(test.allocation() == 31)
                assert(test.mutated_automatic() == 421)
            ]])
        end)
    end)

    it("keeps spread lowering inline in the generated function", function()
        local csource = h.compile_and_read_c([[
            function audit(values: {integer}, ...: integer): {integer}
                local left: {integer} = {...values[2,]}
                local right: {integer} = {...[2,]}
                return {#left, #right}
            end
        ]])

        local _, carriers = csource:gsub(
            "lua_Unsigned _spread_count_%d+ = 0;", "")
        assert.equal(2, carriers)
        assert.match("for %(lua_Unsigned _vj = 0;", csource)
        -- Any generated callable dedicated to this feature would have
        -- "spread" in its C identifier. The per-carrier state and read loops
        -- must instead remain inside the enclosing Titan function.
        assert.not_match(
            "[_%a][_%w]*spread[_%w]*%s*%b()%s*{", csource)
    end)
end)

local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local types = require "titan-compiler.types"
local cdriver = require "c-parser.cdriver"

local function run_argv(argv)
    local words = {}
    for _, word in ipairs(argv) do
        words[#words + 1] = assert(cdriver.shell_quote(word))
    end
    local pipe = assert(io.popen(
        table.concat(words, " ") .. " 2>&1"))
    local output = pipe:read("*a")
    local ok, why, code = pipe:close()
    return ok == true, output, why, code
end

local function interface_pair_id(prefix, concrete, interface)
    local function fragment(name)
        local bytes = {}
        for index = 1, #name do
            bytes[index] = ("%02x"):format(name:byte(index))
        end
        return table.concat(bytes)
    end
    return prefix .. "interface_pair_"
        .. fragment(concrete) .. "_to_" .. fragment(interface)
end

local function normalize_c_whitespace(source)
    source = source:gsub("%s+", " ")
    return (source:gsub(
        "%s*([%(%)%[%]{},;*=/+<>!&|?:.%%%-])%s*", "%1"))
end

describe("interfaces (end-to-end)", function()
    after_each(function()
        for _, name in ipairs({
            "test", "interface_api", "interface_provider",
            "interface_consumer", "interface_bridge",
        }) do
            os.remove(name .. ".c")
            os.remove(name .. ".o")
            os.remove(name .. ".so")
            os.remove(name .. ".a")
            os.execute("rm -rf " .. name .. ".so.dSYM")
        end
    end)

    it("keys adapter-owned C identities to the emitting module", function()
        local cint = types.CInteger("int", true, 3, 32)
        local owned = types.COwned(cint, false)
        local tlcontext = {
            module = "bridge",
            owned_c_metatables = {},
            upvalue = 0,
        }
        local ctx = { tlcontext = tlcontext }
        local generated = coder._interface_adapter_identity_prelude(
            ctx, {
                concrete_owner_module = "provider",
                arguments = {{
                    operation = {
                        kind = "gradual_guard",
                        timing = "immediate",
                        target = owned,
                    },
                }},
                results = {},
            })
        local registry_name = "Titan owned C bridge "
            .. types.tostring(owned) .. " metatable"
        assert.truthy(generated:find(registry_name, 1, true), generated)
        assert.is_nil(generated:find(
            "Titan owned C provider ", 1, true))
        assert.is_truthy(
            tlcontext.owned_c_metatables[types.tostring(owned)])
    end)

    it("polls before an Interface adapter allocates callable views", function()
        local csrc = normalize_c_whitespace(h.compile_and_read_c([[
            interface Transformer
                function swap(
                    callback: (value) -> value
                ): (value) -> value
            end

            record Impl
            end

            function Impl:swap(
                callback: (integer) -> integer
            ): (integer) -> integer
                return callback
            end

            function make(): Transformer
                return Impl.new()
            end
        ]]))
        local pair = interface_pair_id(
            "test_", "test.Impl", "test.Transformer")
        local signature = "static TITAN_NOINLINE TValue "
            .. pair .. "_adapter_0"
        local declaration = assert(csrc:find(signature, 1, true))
        local start = assert(csrc:find(
            signature, declaration + 1, true))
        local stop = assert(csrc:find(
            "test_\\u2133_Impl_\\u2131_swap_titanmethod(", start, true))
        local body = csrc:sub(start, stop - 1)
        local poll = assert(body:find("luaC_checkGC(L);", 1, true))
        local reserve = assert(body:find("titan_ensure_stack", poll, true))
        local allocation = assert(body:find(
            "luaF_newCclosure", reserve, true))
        assert.is_true(poll < reserve and reserve < allocation)
    end)

    it("publishes type-only owner artifacts without a Lua module member",
    function()
        local ok, err, ast, modtype = h.run_checker([[
            interface Reader
                function read(): string?
            end

            function answer(): integer
                return 42
            end
        ]])
        assert.truthy(ok, err)

        local source_symbols = coder.external_symbols("test", ast)
        local recovered_symbols =
            coder.interface_external_symbols("test", modtype)
        local expected = {
            "test_\\u2133_Reader_\\u2131_read_interface_boundmethod",
            "test_\\u2133_Reader_\\u2131_read_titanentry_interface_boundlua",
            "test_\\u2133_Reader_\\u2131_read_titanentry_interface_boundstrict",
        }
        for _, symbol in ipairs(expected) do
            local source_found, recovered_found = false, false
            for _, entry in ipairs(source_symbols) do
                source_found = source_found or entry.symbol == symbol
            end
            for _, entry in ipairs(recovered_symbols) do
                recovered_found = recovered_found or entry.symbol == symbol
            end
            assert.is_true(source_found, symbol)
            assert.is_true(recovered_found, symbol)
        end

        h.run_coder([[
            interface Reader
                function read(): string?
            end

            function answer(): integer
                return 42
            end
        ]], [[
            assert(test.answer() == 42)
            local ok, err = pcall(function() return test.Reader end)
            assert(not ok)
            assert(tostring(err):match("does not exist"))
        ]])
    end)

    it("constructs exact wrappers and dispatches through Lua", function()
        h.run_coder([[
            interface Getter
                function get(): integer
            end

            interface Adder
                function add(x: integer): integer
            end

            interface Scorer
                function score(): integer
            end

            record Box
                item: integer
            end

            record Other
                item: integer
            end

            record Holder
                getter: Getter
            end

            union Choice
                number: integer
                empty
            end

            function Box:get(): integer
                return self.item
            end

            function Other:get(): integer
                return self.item
            end

            function Box:add(x: integer): integer
                return self.item + x
            end

            function Choice:score(): integer
                case self
                when number: n then
                    return n
                else
                    return 0
                end
            end

            function make(n: integer): Getter
                return Box.new(n)
            end

            function maybe(n: integer, present: boolean): Getter?
                if present then
                    return Box.new(n)
                end
                return nil
            end

            function is_getter(v: value): boolean
                return v is Getter
            end

            function as_getter(v: value): Getter
                return v as Getter
            end

            function call_getter(getter: Getter): integer
                return getter:get()
            end

            function bind_getter(getter: Getter): () -> integer
                return getter:get
            end

            function call_adjusted(getter: Getter): value
                local get: () -> value = getter:get
                return get()
            end

            function make_other(n: integer): Getter
                return Other.new(n)
            end

            function box_is_getter(box: Box): boolean
                return box is Getter
            end

            function wraps_box(getter: Getter): boolean
                return getter is Box
            end

            function unwrap_box(getter: Getter): Box
                return getter as Box
            end

            function optional_wraps_box(getter: Getter?): boolean
                return getter is Box
            end

            function optional_unwrap_box(getter: Getter?): Box
                return getter as Box
            end

            function make_adder(n: integer): Adder
                return Box.new(n)
            end

            function named_add(adder: Adder): integer
                return adder:add { x = 2 }
            end

            function bind_adder(adder: Adder): (integer) -> integer
                return adder:add
            end

            function strict_adjusted_add(
                adder: Adder,
                v: value
            ): integer
                local add: (value) -> integer = adder:add
                return add(v)
            end

            function make_score(n: integer): Scorer
                return Choice.number(n)
            end

            function call_score(scorer: Scorer): integer
                return scorer:score()
            end

            function unwrap_choice(scorer: Scorer): Choice
                return scorer as Choice
            end

            function maybe_box(
                n: integer,
                present: boolean
            ): Box?
                if present then
                    return Box.new(n)
                end
                return nil
            end

            function map_box(box: Box?): Getter?
                return box
            end

            function force_box(box: Box?): Getter
                return box
            end

            function make_holder(n: integer): Holder
                return Holder.new(Box.new(n))
            end

            function make_array(n: integer): {Getter}
                local getters: {Getter} = { Box.new(n) }
                getters[2] = Other.new(n + 1)
                return getters
            end

            function make_map(n: integer): {string: Getter}
                return { ["getter"] = Box.new(n) }
            end

            function accept(getter: Getter): integer
                return getter:get()
            end

            function named_sink(n: integer): integer
                return accept { getter = Box.new(n) }
            end

            function boxes(n: integer): (...: Box)
                return Box.new(n), Box.new(n + 1)
            end

            function collect_boxes(n: integer): {Getter}
                return { boxes(n) }
            end
        ]], [[
            local first = test.make(41)
            local second = test.make(41)
            assert(first:get() == 41)
            assert(first ~= second)
            assert(test.is_getter(first))
            assert(test.as_getter(first) == first)
            assert(test.maybe(42, false) == nil)
            local present = test.maybe(42, true)
            assert(present:get() == 42)
            assert(test.call_getter(present) == 42)
            local bound = test.bind_getter(present)
            assert(bound() == 42)
            assert(test.call_adjusted(present) == 42)
            assert(test.box_is_getter(test.unwrap_box(present)))
            assert(test.wraps_box(present))
            assert(not test.wraps_box(test.make_other(9)))
            assert(test.optional_wraps_box(present))
            assert(not test.optional_wraps_box(nil))
            assert(test.optional_unwrap_box(present) ==
                test.unwrap_box(present))
            local ok, err = pcall(test.unwrap_box, test.make_other(9))
            assert(not ok)
            assert(tostring(err):match("test.Box"))
            ok, err = pcall(test.optional_unwrap_box, nil)
            assert(not ok)
            assert(tostring(err):match("test.Box"))
            local adder = test.make_adder(40)
            assert(test.named_add(adder) == 42)
            assert(adder:add(2.0) == 42)
            local add = test.bind_adder(adder)
            assert(add(2.0) == 42)
            ok, err = pcall(test.strict_adjusted_add, adder, 2.0)
            assert(not ok)
            assert(tostring(err):match("integer tag"))

            local choice = test.make_score(42)
            assert(choice:score() == 42)
            assert(test.call_score(choice) == 42)
            assert(test.unwrap_choice(choice) ==
                test.unwrap_choice(choice))

            local present_box = test.maybe_box(45, true)
            local mapped = test.map_box(present_box)
            assert(mapped:get() == 45)
            assert(test.map_box(nil) == nil)
            assert(test.force_box(present_box):get() == 45)
            ok, err = pcall(test.force_box, nil)
            assert(not ok)
            assert(tostring(err):match("test.Getter"))

            local holder = test.make_holder(46)
            assert(holder.getter:get() == 46)
            local getters = test.make_array(47)
            assert(getters[1]:get() == 47)
            assert(getters[2]:get() == 48)
            assert(test.make_map(49)["getter"]:get() == 49)
            assert(test.named_sink(50) == 50)
            local collected = test.collect_boxes(51)
            assert(collected[1]:get() == 51)
            assert(collected[2]:get() == 52)

            -- Lua and written dynamic Interface sinks accept only an existing
            -- exact wrapper, never a bare implementing record/union.
            local bare = test.unwrap_box(present)
            ok, err = pcall(test.call_getter, bare)
            assert(not ok)
            assert(tostring(err):match("test.Getter"))
            assert(not test.is_getter(bare))
            ok, err = pcall(test.as_getter, bare)
            assert(not ok)
            assert(tostring(err):match("test.Getter"))
            local get = present.get
            ok, err = pcall(get, bare)
            assert(not ok)
            assert(tostring(err):match("test.Getter"))
            assert(not pcall(function() present.get = get end))
            assert(not pcall(function() return present.missing end))

            -- Only the wrapper retains its concrete self, and only this bound
            -- closure retains its wrapper. Exercise both collector modes.
            local interface_only = test.make(43)
            collectgarbage("incremental")
            collectgarbage("collect")
            assert(interface_only:get() == 43)
            local bound_only = test.bind_getter(test.make(44))
            interface_only = nil
            collectgarbage("collect")
            collectgarbage("generational")
            collectgarbage("step")
            collectgarbage("collect")
            assert(bound_only() == 44)

            collectgarbage("collect")
            collectgarbage("generational")
            collectgarbage("collect")
            assert(present:get() == 42)
            assert(bound() == 42)
        ]])
    end)

    it("executes every frozen callable-shape adapter action", function()
        h.run_coder([[
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
                function budgeted(): (...: integer)
            end

            record Concrete
                full: boolean
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
                return 99
            end

            function Concrete:flex_optional(): (...: integer)
                if self.full then
                    return 11
                end
            end

            function Concrete:flex_required(): (...: integer)
                if self.full then
                    return 12
                end
            end

            function Concrete:collect(): (integer, integer)
                return 13, 14
            end

            function Concrete:stop(): (...: integer)
                return 15, 16
            end

            function Concrete:passthrough(): (...: integer)
                return 17, 18
            end

            function Concrete:empty()
            end

            function boxed_bad_tail(): (...: value)
                return 1.5
            end

            function Concrete:budgeted(): (integer, ...: integer)
                local f: () -> (...: value) = boxed_bad_tail
                return 19, f()
            end

            function wrap(full: boolean): Matrix
                return Concrete.new(full)
            end

            function implements(value_: Concrete): boolean
                return value_ is Matrix
            end

            function direct(matrix: Matrix): integer
                matrix:ignore(1, "discarded")
                matrix:fill(2)
                matrix:tailfill(3)
                matrix:tailfill(4, 5)
                matrix:gather(6, 7)
                matrix:passthrough_args(8, 9)
                matrix:discardtail(10, "a", "b")
                matrix:hide()
                matrix:stop()
                matrix:empty()
                local optional: integer? = matrix:flex_optional()
                local head: integer, tail: integer? = matrix:collect()
                local p1: value?, p2: value? =
                    matrix:passthrough()
                local budgeted: integer = matrix:budgeted()
                return (optional as integer)
                    + head + (tail as integer)
                    + ((p1 as integer) + (p2 as integer))
                    + budgeted
            end
        ]], [[
            assert(test.implements(test.Concrete.new(true)))
            local full = test.wrap(true)
            local empty = test.wrap(false)
            assert(full:exact(42) == 42)
            full:ignore(1, "ignored")
            full:fill(2)
            full:tailfill(3)
            full:tailfill(4, 5)
            full:gather(6, 7)
            full:passthrough_args(8, 9)
            full:discardtail(10, "a", "b")
            assert(select("#", full:hide()) == 0)
            assert(full:flex_optional() == 11)
            assert(empty:flex_optional() == nil)
            assert(full:flex_required() == 12)
            local ok, err = pcall(function()
                return empty:flex_required()
            end)
            assert(not ok)
            assert(tostring(err):match("expected result 1"), tostring(err))
            local head, tail, surplus = full:collect()
            assert(head == 13 and tail == 14 and surplus == nil)
            assert(select("#", full:stop()) == 0)
            local p1, p2 = full:passthrough()
            assert(p1 == 17 and p2 == 18)
            assert(select("#", full:empty()) == 0)
            ok, err = pcall(function()
                full:tailfill(1, "wrong")
            end)
            assert(not ok)
            assert(tostring(err):match("integer"), tostring(err))
            ok, err = pcall(function()
                full:passthrough_args(1, 2.0)
            end)
            assert(not ok)
            assert(tostring(err):match("integer tag"), tostring(err))
            full:passthrough_args(3, 4)
            assert(test.direct(full) == 92)
        ]])
    end)

    it("executes gradual, delayed-container, callable, and Array views",
    function()
        h.run_coder([[
            interface Item
                function get(): integer
            end

            interface Views
                function bridge(
                    item: Item,
                    number: value,
                    array: {integer},
                    map: {string: integer},
                    callback: (integer) -> integer
                ): (
                    value,
                    integer,
                    {value},
                    {value: value},
                    (integer, integer) -> integer
                )
                function box(array: {integer})
                function box_optional(array: {integer}?)
            end

            record ItemImpl
                n: integer
            end

            function ItemImpl:get(): integer
                return self.n
            end

            record Concrete
                seen: integer
            end

            function one(x: integer): integer
                return x
            end

            function Concrete:bridge(
                item: value,
                number: integer,
                array: {value},
                map: {value: value},
                callback: (integer, integer) -> integer
            ): (
                integer,
                value,
                {integer},
                {string: integer},
                (integer) -> integer
            )
                local called = callback(3, 999)
                local boxed_number: value = number
                return number + called, boxed_number,
                    { number }, { ["x"] = 7 }, one
            end

            function Concrete:box(array: value)
                self.seen = (array as {integer})[1]
            end

            function Concrete:box_optional(array: value)
                if array ~= nil then
                    self.seen = (array as {integer})[1]
                else
                    self.seen = 0
                end
            end

            function make_item(n: integer): Item
                return ItemImpl.new(n)
            end

            function make(): Views
                return Concrete.new(0)
            end

            function make_array(n: integer): {integer}
                return { n }
            end

            function seen(views: Views): integer
                return (views as Concrete).seen
            end

            function plus_one(x: integer): integer
                return x + 1
            end

            function direct(): integer
                local views = make()
                local item = make_item(1)
                local boxed: value,
                    checked: integer,
                    array: {value},
                    map: {value: value},
                    callback: (integer, integer) -> integer =
                        views:bridge(
                            item, 40, {2}, {["x"] = 3}, plus_one)
                views:box({ 21 })
                views:box_optional(nil)
                views:box_optional({ 22 })
                return (boxed as integer) + checked
                    + (array[1] as integer)
                    + (map["x"] as integer)
                    + callback(5, 999)
                    + seen(views)
            end
        ]], [[
            assert(test.direct() == 158)
            local views = test.make()
            local item = test.make_item(1)
            local boxed, checked, array, map, callback =
                views:bridge(item, 40, test.make_array(2), {x = 3},
                    function(x) return x + 1 end)
            assert(boxed == 44 and checked == 40)
            assert(array[1] == 40 and map.x == 7)
            assert(callback(5, 999) == 5)
            views:box(test.make_array(31))
            assert(test.seen(views) == 31)
            views:box_optional(nil)
            assert(test.seen(views) == 0)
            views:box_optional(test.make_array(32))
            assert(test.seen(views) == 32)
            local ok, err = pcall(function()
                return views:bridge(
                    item, 40.0, test.make_array(2), {x = 3},
                    function(x) return x end)
            end)
            assert(not ok)
            assert(tostring(err):match("integer tag"), tostring(err))
            collectgarbage("incremental")
            collectgarbage("collect")
            views:box(test.make_array(33))
            collectgarbage("generational")
            collectgarbage("collect")
            assert(test.seen(views) == 33)
        ]])
    end)

    it("roots open Array runs across allocating adapter conversions",
    function()
        local source = [[
            interface Runs
                function consume(...: {integer})
                function produce(): (...: value)
            end

            record Concrete
            end

            function Concrete:consume(...: value)
            end

            function Concrete:produce(): (...: {integer})
                local first: {integer} = { 1 }
                local second: {integer} = { 2 }
                local third: {integer} = { 3 }
                return first, second, third
            end

            function make(): Runs
                return Concrete.new()
            end

            function make_array(n: integer): {integer}
                return { n }
            end

            function direct(runs: Runs)
                runs:consume({10}, {20}, {30})
            end
        ]]
        local csrc = normalize_c_whitespace(
            h.compile_and_read_c(source))
        assert.matches(
            "interface_adapter_vararg_cap_must_match%["
                .. "%(TITAN_VARARG_MAX==200%)%?1:%-1%]",
            csrc)
        assert.matches(
            "_ia_interface_tail_count="
                .. "%(int%)_varargs%->n_args%-_start;",
            csrc)
        assert.matches(
            "_ia_concrete_vcount>=TITAN_VARARG_MAX",
            csrc)
        assert.matches(
            "_ia_interface_fcount>=TITAN_VARARG_MAX",
            csrc)
        assert.matches(
            "titan_array_require_proxy",
            csrc)
        assert.matches(
            "restorestack%(L,_base_off%)%+%d+%)"
                .. "%+_ia_root_i",
            csrc)
        local pair = interface_pair_id(
            "test_", "test.Concrete", "test.Runs")
        local adapter_name = pair .. "_adapter_1("
        local declaration = assert(
            csrc:find(adapter_name, 1, true))
        local definition = assert(
            csrc:find(adapter_name, declaration + 1, true))
        local reserved = tonumber(assert(csrc:match(
            "titan_ensure_stack%(L,(%d+)%)", definition)))
        local rooted = tonumber(assert(csrc:match(
            "L%->top%.p%+=(%d+);", definition)))
        assert.equal(rooted + 3, reserved)
        local demand_guard = assert(
            csrc:find("_flexout==NULL", definition, true))
        local negative_guard = assert(
            csrc:find("_flexwant<0", demand_guard, true))
        local concrete_call = assert(csrc:find(
            "test_\\u2133_Concrete_\\u2131_produce_titanmethod(",
            negative_guard, true))
        assert.is_true(definition < demand_guard
            and demand_guard < negative_guard
            and negative_guard < concrete_call)

        local called, callerr = h.call("test", [[
            local runs = test.make()
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for i = 1, 40 do
                    test.direct(runs)
                    runs:consume(
                        test.make_array(i),
                        test.make_array(i + 1),
                        test.make_array(i + 2))
                    local first, second, third = runs:produce()
                    assert(first[1] == 1)
                    assert(second[1] == 2)
                    assert(third[1] == 3)
                    first, second, third = nil, nil, nil
                    if i % 5 == 0 then
                        collectgarbage("collect")
                    else
                        collectgarbage("step")
                    end
                end
            end
        ]])
        assert.truthy(called, callerr)
    end)

    it("roots only freshly allocated Interfaces in an open input run",
    function()
        local source = [[
            interface View
                function get(): integer
            end

            record Item
                n: integer
            end

            function Item:get(): integer
                return self.n
            end

            local function consume(...: View): integer
                local junk: {integer} = {}
                local k = 1
                while k <= 300 do
                    junk = { k, k + 1 }
                    k = k + 1
                end
                local total = 0
                local i = 1
                while i <= #... do
                    local view: View = ...[i]
                    total = total + view:get()
                    i = i + 1
                end
                return total
            end

            local function produce(): (...: Item)
                return Item.new(10), Item.new(20), Item.new(30)
            end

            function open_interfaces(): integer
                return consume(produce())
            end
        ]]
        local csrc = h.compile_and_read_c(source)
        local signature =
            "lua_Integer test_\\u2133_open_interfaces_titan("
        local declaration = assert(csrc:find(signature, 1, true))
        local first = assert(csrc:find(
            signature, declaration + 1, true))
        local last = assert(csrc:find(
            "static int test_\\u2133_open_interfaces_titanentry_lua",
            first, true))
        local body = csrc:sub(first, last - 1)
        local allocation = assert(body:find(
            "= luaS_newudata(", 1, true))
        local rebase = assert(body:find(
            "_base = restorestack(L, _base_off);", allocation, true))
        local root = assert(body:find(
            "setuvalue(L, s2v(", rebase, true))
        local root_line = body:sub(root, assert(body:find("\n", root)) - 1)
        assert.truthy(root_line:find("_vai", 1, true), root_line)
        assert.is_true(allocation < rebase and rebase < root)
        for line in body:gmatch("[^\n]+") do
            assert.is_false(
                line:find("_open_vargs_", 1, true) ~= nil
                and line:find("setuvalue(L, s2v(", 1, true) ~= nil,
                line)
        end

        local called, callerr = h.call("test", [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for i = 1, 30 do
                    assert(test.open_interfaces() == 60)
                    if i % 5 == 0 then
                        collectgarbage("collect")
                    else
                        collectgarbage("step")
                    end
                end
            end
        ]])
        assert.truthy(called, callerr)
    end)

    it("emits no native input roots while resolving adapter identities",
    function()
        local source = [[
            interface Item
                function get(): integer
            end

            interface Protector
                function protect(
                    keep: Item,
                    dynamic: value
                ): value
            end

            record ItemImpl
                n: integer
            end

            function ItemImpl:get(): integer
                return self.n
            end

            record ProtectorImpl
            end

            function ProtectorImpl:protect(
                keep: value,
                dynamic: Item
            ): value
                return keep
            end

            function make_item(n: integer): Item
                return ItemImpl.new(n)
            end

            function make(): Protector
                return ProtectorImpl.new()
            end

            function direct(n: integer): integer
                local protector = make()
                local dynamic: value = make_item(n + 100)
                local kept: value =
                    protector:protect(make_item(n), dynamic)
                return (kept as Item):get()
            end
        ]]
        local csrc = normalize_c_whitespace(
            h.compile_and_read_c(source))
        local pair = interface_pair_id(
            "test_", "test.ProtectorImpl", "test.Protector")
        local adapter = pair .. "_adapter_0"
        local declaration = assert(csrc:find(
            "static TITAN_NOINLINE TValue " .. adapter,
            1, true))
        local start = assert(csrc:find(
            "static TITAN_NOINLINE TValue " .. adapter,
            declaration + 1, true))
        local stop = assert(csrc:find(
            "test_\\u2133_ProtectorImpl_\\u2131_protect_titanmethod(",
            start, true))
        local body = csrc:sub(start, stop)
        local reserve = assert(csrc:find(
            "titan_ensure_stack(L,", start, true))
        local identity = assert(csrc:find(
            '"Titan interface test.Item metatable"',
            reserve, true))
        local conversion = assert(csrc:find(
            "_ia_concrete_arg_1", identity, true))
        local before_identity = csrc:sub(start, identity - 1)
        assert.falsy(before_identity:find(
            "setuvalue(L,s2v((restorestack(L,_base_off)",
            1, true), before_identity)
        assert.falsy(before_identity:find(
            "setobj2t(L,s2v((restorestack(L,_base_off)",
            1, true), before_identity)
        assert.is_true(reserve < identity
            and identity < conversion
            and conversion < stop)

        local called, callerr = h.call("test", [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for i = 1, 100 do
                    assert(test.direct(i) == i)
                    if i % 3 == 0 then
                        collectgarbage("collect")
                    else
                        collectgarbage("step")
                    end
                end
            end
        ]])
        assert.truthy(called, callerr)
    end)

    it("uses deterministic pair and adjusted-slot symbols", function()
        local csrc = normalize_c_whitespace(h.compile_and_read_c([[
            interface ZedInterface
                function exact(x: integer): integer
                function adjusted(x: value): value
            end

            interface AlphaInterface
                function exact(x: integer): integer
                function adjusted(x: value): value
            end

            record ZedRecord
            end

            record AlphaRecord
            end

            function ZedRecord:exact(x: integer): integer
                return x
            end

            function ZedRecord:adjusted(x: integer): integer
                return x
            end

            function AlphaRecord:exact(x: integer): integer
                return x
            end

            function AlphaRecord:adjusted(x: integer): integer
                return x
            end

            -- Discover Zed first on purpose; declaration order must still be
            -- the canonical concrete/interface pair-key order.
            function zed(): ZedInterface
                return ZedRecord.new()
            end

            function alpha(): AlphaInterface
                return AlphaRecord.new()
            end

            function zed_again(): ZedInterface
                return ZedRecord.new()
            end
        ]]))
        local alpha = interface_pair_id(
            "test_", "test.AlphaRecord", "test.AlphaInterface")
        local zed = interface_pair_id(
            "test_", "test.ZedRecord", "test.ZedInterface")
        local alpha_decl = assert(csrc:find(
            "static TitanInterfaceMethod " .. alpha .. "[2]",
            1, true))
        local zed_decl = assert(csrc:find(
            "static TitanInterfaceMethod " .. zed .. "[2]",
            1, true))
        assert.is_true(alpha_decl < zed_decl)
        assert.matches(alpha .. "%[0%]%s*=%s*titan_cast_func%(%s*"
            .. "TitanInterfaceMethod,%s*"
            .. "test_\\u2133_AlphaRecord_\\u2131_exact_titanmethod%)", csrc)
        assert.matches(alpha .. "%[1%]%s*=%s*titan_cast_func%(%s*"
            .. "TitanInterfaceMethod,%s*"
            .. alpha .. "_adapter_1%)", csrc)
        assert.matches(zed .. "%[0%]%s*=%s*titan_cast_func%(%s*"
            .. "TitanInterfaceMethod,%s*"
            .. "test_\\u2133_ZedRecord_\\u2131_exact_titanmethod%)", csrc)
        assert.matches(zed .. "%[1%]%s*=%s*titan_cast_func%(%s*"
            .. "TitanInterfaceMethod,%s*"
            .. zed .. "_adapter_1%)", csrc)
        assert.is_nil(csrc:find(alpha .. "_adapter_0", 1, true))
        assert.is_nil(csrc:find(zed .. "_adapter_0", 1, true))
        local _, alpha_declarations = csrc:gsub(
            "static TitanInterfaceMethod " .. alpha:gsub("(%W)", "%%%1")
                .. "%[2%];", "")
        local _, zed_declarations = csrc:gsub(
            "static TitanInterfaceMethod " .. zed:gsub("(%W)", "%%%1")
                .. "%[2%];", "")
        assert.equal(1, alpha_declarations)
        assert.equal(1, zed_declarations)
    end)

    it("keeps adjusted implementation tests allocation-free", function()
        local csrc = h.compile_and_read_c([[
            interface Dynamic
                function apply(input: value): value
            end

            record Concrete
            end

            function Concrete:apply(input: integer): integer
                return input
            end

            function implements(value_: Concrete): boolean
                return value_ is Dynamic
            end

            function run(): boolean
                return implements(Concrete.new())
            end
        ]])
        local pair = interface_pair_id(
            "test_", "test.Concrete", "test.Dynamic")
        assert.is_nil(csrc:find(pair, 1, true))
        local body = assert(csrc:match(
            "int test_\\u2133_implements_titan%b()%s*{.-\n%s*}"))
        assert.is_nil(body:find("luaS_newudata", 1, true))
        assert.is_nil(body:find("TitanInterfaceMethod", 1, true))
        local called, callerr = h.call("test", [[
            assert(test.run())
            assert(test.implements(test.Concrete.new()))
        ]])
        assert.truthy(called, callerr)
    end)

    it("keeps Interface sources in C and roots only the fresh wrapper",
    function()
        local csrc = normalize_c_whitespace(h.compile_and_read_c([[
            interface Item
                function get(): integer
            end

            record Concrete
                n: integer
            end

            function Concrete:get(): integer
                return self.n
            end

            function wrap(value_: Concrete): Item
                return value_
            end
        ]]))
        local declaration = assert(csrc:find(
            "Udata*test_\\u2133_wrap_titan(", 1, true))
        local first = assert(csrc:find(
            "Udata*test_\\u2133_wrap_titan(", declaration + 1, true))
        local last = assert(csrc:find(
            "static int test_\\u2133_wrap_titanentry_lua", first, true))
        local body = csrc:sub(first, last - 1)
        local allocation = assert(body:find("luaS_newudata(", 1, true))
        local before = body:sub(1, allocation - 1)
        assert.matches(
            "Udata%*_tmp_%d+=0;_tmp_%d+=_param_value_;",
            before)
        assert.falsy(before:find("setuvalue(L", 1, true), before)
        local rebase = assert(body:find(
            "_base=restorestack(L,_base_off);", allocation, true))
        local root = assert(body:find(
            "setuvalue(L,s2v((restorestack(L,_base_off)",
            rebase, true))
        local edge = assert(body:find("->uv[0].uv", root, true))
        assert.is_true(allocation < rebase and rebase < root and root < edge)
    end)

    it("orders exact payloads, roots construction, and preserves fast tags",
    function()
        local source = [[
            interface Callback
                function call(p: () -> integer): integer
            end

            type CallbackFn = (() -> integer) -> integer

            record Caller
                tag: integer
            end

            function Caller:call(p: () -> integer): integer
                return p() + self.tag
            end

            -- This constant initializer constructs a wrapper before the root
            -- initializer runs, so its pair must already be populated.
            local eager: Callback = Caller.new(0)
            local record_bound: CallbackFn? = nil
            local interface_bound: CallbackFn? = nil
            local lambda: CallbackFn? = nil

            function run_record(p: () -> integer): integer
                local f: CallbackFn = record_bound as CallbackFn
                return f(p)
            end

            function run_interface(p: () -> integer): integer
                local f: CallbackFn = interface_bound as CallbackFn
                return f(p)
            end

            function run_lambda(p: () -> integer): integer
                local f: CallbackFn = lambda as CallbackFn
                return f(p)
            end

            function run_slow(
                f: CallbackFn,
                p: () -> integer
            ): integer
                return f(p)
            end

            do
                record_bound = Caller.new(0):call
                interface_bound = eager:call
                lambda = function(p: () -> integer): integer
                    return p()
                end
            end
        ]]
        local csrc = normalize_c_whitespace(
            h.compile_and_read_c(source))
        local pair = interface_pair_id(
            "test_", "test.Caller", "test.Callback")
        local function locate(fragment, start)
            local position = csrc:find(fragment, start or 1, true)
            assert.truthy(position, "missing generated C fragment: "
                .. fragment)
            return position
        end

        assert.matches("static TitanInterfaceMethod "
            .. pair .. "%[1%];", csrc)

        -- The generated constructor follows the exact allocation/rooting
        -- protocol and performs no allocating/raising work after publishing
        -- the half-built wrapper and before installing both ownership edges.
        local allocation =
            locate("L,sizeof(" .. pair .. "),2);")
        local rebase =
            locate("_base=restorestack(L,_base_off);", allocation)
        local anchor =
            locate("setuvalue(L,s2v((restorestack(L,_base_off)", rebase)
        local metatable =
            locate("->metatable=_titan_interface_metatable;", anchor)
        local module_value = locate("->uv[0].uv,", metatable)
        local module_barrier =
            locate("luaC_barrierback", module_value)
        local self_value = locate("->uv[1].uv,", module_barrier)
        local self_barrier = locate("luaC_barrierback", self_value)
        local payload = locate(
            "memcpy(getudatamem(", self_barrier)
        assert.is_true(allocation < rebase
            and rebase < anchor
            and anchor < metatable
            and metatable < module_value
            and module_value < module_barrier
            and module_barrier < self_value
            and self_value < self_barrier
            and self_barrier < payload)
        local published = csrc:sub(anchor, payload)
        assert.is_nil(published:find("luaS_newudata", 1, true))
        assert.is_nil(published:find("luaL_error", 1, true))

        -- All dispatch variants use overflow-free exact payload-length checks,
        -- and every vtable call supplies a null closure operand.
        assert.matches(
            "%%sizeof%(TitanInterfaceMethod%)!=0", csrc)
        assert.matches(
            "/sizeof%(TitanInterfaceMethod%)", csrc)
        locate(",NULL,uvalue(&")

        -- Both init branches publish function tags before pair pointers. In
        -- the fresh branch, pairs precede canonical closures/trace names and
        -- the user initializer that allocates the eager wrapper.
        local fresh = locate("if(lua_isnil(L,-1))")
        local first_tag =
            locate("titan_publish_function_type_tag", fresh)
        local first_pair =
            locate(pair .. "[0]=titan_cast_func(", fresh)
        local first_closure =
            locate("TITAN_FUNCTION_CLOSURE_BRAND", first_pair)
        local names = locate("TITAN_NAMES_KEY", first_closure)
        local eager_allocation =
            locate("sizeof(" .. pair .. "),2", names)
        assert.is_true(first_tag < first_pair
            and first_pair < first_closure
            and first_closure < names
            and names < eager_allocation)

        local existing = locate("if(!_initialized)", eager_allocation)
        local second_tag =
            locate("titan_publish_function_type_tag", existing)
        local second_pair =
            locate(pair .. "[0]=titan_cast_func(",
                first_pair + 1)
        local second_names = locate("TITAN_NAMES_KEY", second_pair)
        assert.is_true(existing < second_tag
            and second_tag < second_pair
            and second_pair < second_names)
        assert.is_nil(csrc:find(
            pair .. "[0]=titan_cast_func(",
            second_pair + 1, true))

        local called, callerr = h.call("test", h.DEPTH_PROBE .. [[
            assert(test.run_record(function() return 7 end) == 7)
            assert(test.run_interface(function() return 8 end) == 8)
            assert(test.run_lambda(function() return 9 end) == 9)
            local slow = test.run_slow(slow_g, depth)
            local record = test.run_record(depth)
            local interface_calls = test.run_interface(depth)
            local lambda = test.run_lambda(depth)
            assert(slow > record,
                ("record fast=%d slow=%d"):format(record, slow))
            assert(slow > interface_calls,
                ("interface fast=%d slow=%d"):format(
                    interface_calls, slow))
            assert(slow > lambda,
                ("lambda fast=%d slow=%d"):format(lambda, slow))
        ]])
        assert.truthy(called, callerr)
    end)

    it("binds an imported Interface without importing its implementer",
    function()
        local ok, err = h.generate_modules({
            interface_api = [[
                interface Adder
                    function add(x: integer): integer
                    function adjust(x: value): value
                end
            ]],
            interface_provider = [[
                offset: integer = 2

                record Box
                    item: integer
                end

                function Box:add(x: integer): integer
                    -- Reading a module slot proves the bridge's payload call
                    -- receives this concrete owner's `_mod`, not the bridge
                    -- or Interface owner's module object.
                    return self.item + x + offset
                end

                function Box:adjust(x: integer): integer
                    return self.item + x + offset
                end
            ]],
            interface_consumer = [[
                local api = import "interface_api"

                function bind(
                    adder: api.Adder
                ): (integer) -> integer
                    return adder:add
                end

                function call(adder: api.Adder): integer
                    return adder:add(2)
                end

                function bind_adjust(
                    adder: api.Adder
                ): (value) -> value
                    return adder:adjust
                end

                function call_adjust(adder: api.Adder): integer
                    return adder:adjust(2) as integer
                end
            ]],
            interface_bridge = [[
                local api = import "interface_api"
                local provider = import "interface_provider"
                local consumer = import "interface_consumer"

                function make(): api.Adder
                    return provider.Box.new(38)
                end

                function direct(): integer
                    return consumer.call(make())
                end

                function bound(): integer
                    local add = consumer.bind(make())
                    return add(2)
                end

                function adjusted(): integer
                    return consumer.call_adjust(make())
                end

                function adjusted_bound(): integer
                    local adjust = consumer.bind_adjust(make())
                    return adjust(2) as integer
                end
            ]],
        }, "interface_bridge")
        assert.truthy(ok, err)
        local called, callerr = h.call("interface_bridge", [[
            assert(interface_bridge.direct() == 42)
            assert(interface_bridge.bound() == 42)
            assert(interface_bridge.adjusted() == 42)
            assert(interface_bridge.adjusted_bound() == 42)
        ]])
        assert.truthy(called, callerr)
    end)

    it("initializes exact pair payloads independently in two Lua states",
    function()
        h.compile_and_read_c([[
            interface Getter
                function get(): integer
                function adapt(x: value): value
            end

            offset: integer = 1

            record Box
                item: integer
            end

            function Box:get(): integer
                return self.item
            end

            function Box:adapt(x: integer): integer
                return self.item + x + offset
            end

            function make(item: integer): Getter
                return Box.new(item)
            end

            function bind(getter: Getter): () -> integer
                return getter:get
            end

            function bind_adjust(
                getter: Getter
            ): (value) -> value
                return getter:adapt
            end
        ]])

        local temporary = assert(os.tmpname())
        assert.truthy(os.remove(temporary))
        local harness = temporary .. ".c"
        local executable = temporary .. "-interfaces"
        local file = assert(io.open(harness, "wb"))
        assert.truthy(file:write([[
#include <assert.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

extern int luaopen_test(lua_State *L);

static void exercise(int mode) {
    lua_State *L = luaL_newstate();
    assert(L != NULL);
    luaL_openlibs(L);
    assert(luaopen_test(L) == 1);
    lua_setglobal(L, "test");
    lua_gc(L, mode);
    if (luaL_dostring(L,
            "local i = test.make(42);"
            "assert(i:get() == 42);"
            "assert(i:adapt(1) == 44);"
            "local f = test.bind(i);"
            "local a = test.bind_adjust(i);"
            "i = nil;"
            "collectgarbage('collect');"
            "assert(f() == 42);"
            "assert(a(1) == 44)") != LUA_OK) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        assert(0);
    }
    lua_close(L);
}

int main(void) {
    exercise(LUA_GCINC);
    exercise(LUA_GCGEN);
    return 0;
}
]]))
        assert.truthy(file:close())

        local compiler = assert(cdriver.split_shell_words(
            os.getenv("CC") or "cc"))
        for _, argument in ipairs({
            "--std=c99", "-O0", "-g", "-Wall", "-Wextra",
            "-I.", "-Ititan-runtime", "-Ilua-5.5.1/src",
            harness, "test.o", "titan-runtime/libtitan.a",
            "libbacktrace/.libs/libbacktrace.a",
            "lua-5.5.1/src/liblua.a", "-o", executable,
            "-lm", "-pthread",
        }) do
            compiler[#compiler + 1] = argument
        end
        local uname = assert(io.popen("uname -s"))
        local platform = assert(uname:read("*l"))
        assert.truthy(uname:close())
        if platform ~= "Darwin" then
            compiler[#compiler + 1] = "-ldl"
        end

        local linked, linkout, linkwhy, linkcode =
            run_argv(compiler)
        local ran, runout, runwhy, runcode = false, "", nil, nil
        if linked then
            ran, runout, runwhy, runcode = run_argv({ executable })
        end
        os.remove(harness)
        os.remove(executable)
        assert.truthy(linked, linkout .. "\n("
            .. tostring(linkwhy) .. ", " .. tostring(linkcode) .. ")")
        assert.truthy(ran, runout .. "\n("
            .. tostring(runwhy) .. ", " .. tostring(runcode) .. ")")
    end)

    it("names exact direct and bound Interface frames without C leakage",
    function()
        local output = h.compile_and_run([[
            interface Fallible
                function fail(): integer
                function adapt(input: value): integer
            end

            record Box
                item: integer
            end

            function Box:fail(): integer
                local bad: value = {}
                return bad
            end

            function Box:adapt(input: integer): integer
                return input
            end

            function make(): Fallible
                return Box.new(0)
            end

            function direct(fallible: Fallible): integer
                return fallible:fail()
            end

            function bound(fallible: Fallible): integer
                local fail: () -> integer = fallible:fail
                local res = fail()
                return res
            end

            function adjusted(
                fallible: Fallible,
                input: value
            ): integer
                local res = fallible:adapt(input)
                return res
            end
        ]], [[
            local titan = require "titan"
            local fallible = test.make()

            assert(not pcall(test.direct, fallible))
            local direct = titan.backtrace()
            assert(direct:find("in test.Box:fail", 1, true), direct)
            assert(direct:find("in test.direct", 1, true), direct)
            assert(not direct:find("in test.Fallible:fail", 1, true),
                direct)
            assert(not direct:find("_titan", 1, true), direct)

            assert(not pcall(test.bound, fallible))
            local bound = titan.backtrace()
            assert(bound:find("in test.Box:fail", 1, true), bound)
            assert(bound:find("in test.bound", 1, true), bound)
            assert(not bound:find("_titan", 1, true), bound)

            assert(not pcall(test.adjusted, fallible, 1.0))
            local adjusted = titan.backtrace()
            assert(adjusted:find(
                "in test.Fallible:adapt "
                    .. "[adapter for test.Box:adapt]",
                1, true), adjusted)
            assert(adjusted:find("in test.adjusted", 1, true), adjusted)
            assert(not adjusted:find("_adapter_", 1, true), adjusted)
            assert(not adjusted:find("_titan", 1, true), adjusted)
            print("OK")
        ]])
        assert.matches("OK", output, 1, true)
    end)
end)

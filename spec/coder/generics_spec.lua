local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local function remove(path)
    os.remove(path)
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return source
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

    it("keeps declared schemes separate from ordinary erased identity code", function()
        local csource, tree = h.compile_and_read_c([[
            record Token
            end

            function identity<T>(item: T): T
                return item
            end

            function accepts<T>(item: T): boolean
                return item is T
            end

            function many<T>(item: T): (T, ...: T)
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
                local from_box = boxed as (value) -> value
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

            function id<T>(item: T): T return item end
            function constrained<T: I>(item: T): T return item end
            function take<U: I>(left: (U) -> U, right: (U) -> U):
                    (U) -> U
                return left
            end

            record Box<T>
                item: T
            end
            function Box:integer_identity(item: T): T return item end
            function pair<U>(left: (U) -> U, right: (U) -> U): (U) -> U
                return right
            end

            union Maybe<T>
                none
                some: T
            end
            function consume<T>(left: T, right: T): T return left end
            function make<T>(): T return (40 as value) as T end
            function pass<T>(item: T): T return item end

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
                when none then total = total + 1
                else total = -100
                end
                case second
                when some: item then total = total + item
                else total = -100
                end
                return total
            end

            function nested_calls(): integer
                local direct = consume(make(), 42)
                local deep = consume(pass(make()), 42)
                return direct + deep
            end
        ]], [[
            assert(test.constrained_orders() == 28)
            assert(test.bound_orders() == 42)
            assert(test.nested_maybe() == 43)
            assert(test.nested_calls() == 80)
        ]])
    end)

    it("runs nested fixed and open generic result projections", function()
        h.run_coder([[
            function make<T>(): T return (42 as value) as T end

            function duo<T>(): (integer, {T})
                return 1, {make()}
            end

            function spread<T>(): (integer, ...: {T})
                return 1, {make()}, {make()}
            end

            function consume_fixed<T>(first: T, second: {T}): integer
                return #second
            end

            function consume_open<T>(first: T, ...: {T}): integer
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
            record Box<T>
                item: T
            end

            function Box:get(): T
                return self.item
            end

            function Box:put(item: T)
                self.item = item
            end

            function Box:project<U>(item: U): U
                return item
            end

            function Box.map<U>(item: U): Box<U>
                return Box<U>.new(item)
            end

            function same_box<A>(left: Box<value>, right: Box<A>): boolean
                return left == right
            end

            union Maybe<T>
                present: T
                absent
            end

            function make<T>(item: T): Maybe<T>
                return Maybe<T>.present(item)
            end

            function number(): integer
                local box = Box.new(41)
                box:put(box:get() + 1)
                local candidate = make(box.item)
                case candidate
                when present: item then
                    return item
                else
                    return 0
                end
            end

            type IntBox = Box<integer>

            function text(): string
                return Box<value>.map<string>("ok"):get()
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
                local loose = Box<value>.new("same contents")
                local precise = Box<string>.new("same contents")
                return same_box<string>(loose, precise)
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
            function apply<T, U>(callback: (T) -> U, item: T): U
                return callback(item)
            end

            function first<T>(items: {T}): T
                return items[1]
            end

            function lookup<K, V>(items: {K: V}, key: K): V
                return items[key]
            end

            function optional<T>(item: T?): T?
                return item
            end

            function twice(item: integer): integer
                return item * 2
            end

            function answer(): integer
                local items: {integer} = {21, 20}
                local mapped: {string: integer} = { ["answer"] = 42 }
                local from_map: integer = optional<integer>(
                    lookup<string, integer>(mapped, "answer"))
                return apply(twice, first(items)) + from_map - 42
            end

            function missing(): integer?
                local item: integer? = nil
                return optional<integer>(item)
            end
        ]], [[
            assert(test.answer() == 42)
            assert(test.missing() == nil)
            assert(test.apply(function(item) return item + 1 end, 41) == 42)
        ]])
    end)

    it("delays a polluted mutable field guard until its precise read", function()
        h.run_coder([[
            record Box<T>
                item: T
            end

            function make(): Box<integer>
                return Box.new(42)
            end

            function read(box: Box<integer>): integer
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
            interface Show<A>
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

            function display<A, S: Show<A>>(subject: S, item: A): string
                return subject:render(item)
            end

            function identity<A, S: Show<A>>(subject: S): S
                return subject
            end

            function take<A, S: Show<A>>(callback: (S) -> S): (S) -> S
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
            union TaskStatus<A, B>
                succeeded: A
                failed: B
            end

            record Task<A, B>
                status: TaskStatus<A, B>
            end

            function Task:snapshot(): TaskStatus<A, B>
                local loose: TaskStatus<value, value>? = self.status
                return loose as TaskStatus<A, B>
            end

            function use(): integer
                local task = Task.new(TaskStatus<integer, value>.succeeded(42))
                local status = task:snapshot()
                case status
                when succeeded: item then
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
                    record Box<T>
                        local hidden: integer
                        first: T
                        second: T
                        third: T
                    end

                    function make<T>(hidden: integer, first: T,
                                     second: T, third: T): Box<T>
                        return Box<T>.new(hidden, first, second, third)
                    end

                    function reveal<T>(box: Box<T>): integer
                        return box.hidden
                    end

                    union Maybe<T>
                        local hidden: integer
                        first: T
                        second: T
                        absent
                    end

                    record PublicBox<T>
                        item: T
                    end
                    type Crate = PublicBox
                    type IntBox = PublicBox<integer>

                    function hidden<T>(n: integer): Maybe<T>
                        return Maybe<T>.hidden(n)
                    end
                ]],
            },
            {
                name = "generic_layout_consumer",
                src = [[
                    local provider = import "generic_layout_provider"

                    function run(): boolean
                        local crate = provider.Crate<integer>.new(41)
                        local fixed = provider.IntBox.new(42)
                        if crate.item ~= 41 or fixed.item ~= 42 then
                            return false
                        end

                        local box = provider.make<integer>(7, 10, 20, 30)
                        box.first = 11
                        box.second = 22
                        box.third = 33
                        if box.first ~= 11 or box.second ~= 22 or
                           box.third ~= 33 or
                           provider.reveal<integer>(box) ~= 7 then
                            return false
                        end

                        local maybe = provider.Maybe<integer>.second(42)
                        case maybe
                        when first: item then
                            return false
                        when second: item then
                            if item ~= 42 then return false end
                        else
                            return false
                        end

                        case provider.hidden<integer>(9)
                        when first: item then
                            return false
                        when second: item then
                            return false
                        when absent then
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

    it("compiles the generic iteration and GC implementations from source",
    function()
        local ok, err = h.generate_modules({
            generic_iteration_fixture = read_file("titan/iteration.titan"),
            generic_gc_fixture = read_file("titan/gc.titan"),
            test = [[
                local iteration = import "generic_iteration_fixture"
                local gc = import "generic_gc_fixture"

                function main(args: {string}): integer
                    local items: {integer} = {20, 22}
                    local total = 0
                    for _, item in iteration.ipairs(items) do
                        total = total + item
                    end

                    local candidate: {string: value} = {}
                    gc.finalizable(candidate,
                        function(item: {string: value}) end)
                    gc.collect()
                    if total == 42 then return 0 else return 1 end
                end
            ]],
        }, "test", true)
        assert.truthy(ok, err)

        local ran, run_error, status = h.call_app("./test")
        assert.truthy(ran, run_error)
        assert.equal(0, status)
    end)
end)

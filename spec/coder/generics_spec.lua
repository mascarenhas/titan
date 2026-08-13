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
    }) do
        remove(path)
    end
    os.execute("rm -rf test.dSYM")
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
            assert(test.same())
            local first, second = test.open()
            assert(first == 41 and second == 41)
        ]])
        assert.truthy(ok, err)
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

            function Box.map<U>(item: U): Box<U>
                return Box.new<U>(item)
            end

            union Maybe<T>
                present: T
                absent
            end

            function make<T>(item: T): Maybe<T>
                return Maybe.present<T>(item)
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

            function text(): string
                return Box.map<value, string>("ok"):get()
            end
        ]], [[
            assert(test.number() == 42)
            assert(test.text() == "ok")
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

            function IntegerShow:render(item: integer): string
                return self.prefix
            end

            function display<A, S: Show<A>>(subject: S, item: A): string
                return subject:render(item)
            end

            function use(): string
                return display<integer, IntegerShow>(
                    IntegerShow.new("ok"), 1)
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
                local task = Task.new(TaskStatus.succeeded<integer, value>(42))
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

-- Cross-module tests for the `.so`-ONLY import path: a dependency reachable
-- only as a compiled shared library, not as `.titan` source. This path differs
-- from source linking (which the cross-module tests in coder_spec exercise):
-- the importer recovers the dependency's interface from its compiled
-- `<mangled>_types` symbol, the dependency is dlopened at run time, and its
-- native functions are reached through dlsym'd `static` pointers (rather than
-- statically-linked `extern`s). Records and function/variable slots are
-- reconstructed purely from the serialized interface, and record/function type
-- tags must be recovered from the registry the dependency's `.so` published.
--
-- Each dependency is compiled to a `.so` straight from its AST, so its
-- `.titan` source never touches the source path and the default loader is
-- forced onto the `.so` route. Dependencies are built in order, so an earlier
-- one can itself be a `.so`-only dependency of a later one (transitive case).
local h = require 'spec.support.helpers'
local lfs = require 'lfs'
local driver = require 'titan-compiler.driver'
local call = h.call
local generated_modules = {}

local function remove_tree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == "directory" then
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                remove_tree(path .. "/" .. name)
            end
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

local function build_so_chain(modules)
    for _, module in ipairs(modules) do
        generated_modules[module.name] = true
    end
    return h.build_so_chain(modules)
end

describe(".so-only cross-module imports", function()
    after_each(function ()
        for name in pairs(generated_modules) do
            remove_tree(name .. ".c")
            remove_tree(name .. ".o")
            remove_tree(name .. ".so")
            remove_tree(name .. ".a")
            remove_tree(name .. ".so.dSYM")
        end
        generated_modules = {}
    end)

    it("calls a function in a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "sfoo", src = [[
                function a(): integer return 42 end
            ]] },
            { name = "sbar", src = [[
                local foo = import "sfoo"
                function bar(): integer return foo.a() end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("sbar", "assert(sbar.bar() == 42)")
        assert.truthy(rok, out)
    end)


    it("builds consumer-local callable views over a .so-selected source",
       function()
        local ok, err = build_so_chain({
            { name = "callable_so_provider", src = [[
                function increment(value_: integer): integer
                    return value_ + 1
                end

                function source(): function (integer): integer
                    return increment
                end

                function identity(value_: value): value
                    return value_
                end
            ]] },
            { name = "callable_so_consumer", src = [[
                local provider = import "callable_so_provider"

                record Box
                    n: integer;
                end

                function direct(): integer
                    local adjusted: function (integer, value): value =
                        provider.increment
                    return adjusted(41, "ignored") as integer
                end

                function relayed(): integer
                    local adjusted: function (integer, value): value =
                        provider.increment
                    local erased: value = adjusted
                    local wider: function (integer, value, value): value = erased
                    return wider(41, "a", "b") as integer
                end

                function source(): function (integer): integer
                    return provider.source()
                end

                function view(): function (value): value
                    local adjusted: function (value): value = provider.source()
                    return adjusted
                end

                function nominal_relayed(): integer
                    local broad: function (value): value = provider.identity
                    local narrowed: function (Box): Box = broad
                    local erased: value = narrowed
                    local wider: function (Box, value): Box = erased
                    return wider(Box.new(42), "ignored").n                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("callable_so_consumer", [[
            assert(callable_so_consumer.direct() == 42)
            assert(callable_so_consumer.relayed() == 42)
            assert(callable_so_consumer.nominal_relayed() == 42)
            local source = callable_so_consumer.source()
            local first = callable_so_consumer.view()
            local second = callable_so_consumer.view()
            assert(not rawequal(first, source))
            assert(not rawequal(first, second))
            -- The target wrapper keeps the provider's coercive Lua entry.
            assert(first(41.0) == 42)
        ]])
        assert.truthy(rok, out)
    end)

    it("dispatches exact and adjusted Interfaces through four .so-only modules",
       function()
        local ok, err = build_so_chain({
            { name = "interface_api", src = [[
                interface Incrementer
                    function add(delta: integer): integer
                end

                interface Dynamic
                    function convert(input: value): value
                end
            ]] },
            { name = "interface_consumer", src = [[
                local api = import "interface_api"

                function use(value_: api.Incrementer): integer
                    local add: function (integer): integer = value_:add
                    return add(2)
                end

                function use_dynamic(
                    value_: api.Dynamic,
                    input: value
                ): value
                    local convert: function (value): value = value_:convert
                    return convert(input)
                end

                function is_incrementer(value_: value): boolean
                    return value_ is api.Incrementer
                end

                function is_dynamic(value_: value): boolean
                    return value_ is api.Dynamic
                end

                function explicit_incrementer(
                    value_: value
                ): api.Incrementer
                    return value_ as api.Incrementer
                end
            ]] },
            { name = "interface_provider", src = [[
                bias: integer = 1

                record Box
                    n: integer
                end

                function Box:add(delta: integer): integer
                    return self.n + delta + bias
                end

                function Box:convert(input: integer): integer
                    return self.n + input + bias
                end

                function bare(n: integer): value
                    return Box.new(n)
                end
            ]] },
            { name = "interface_bridge", src = [[
                local api = import "interface_api"
                local consumer = import "interface_consumer"
                local provider = import "interface_provider"

                function run(n: integer): integer
                    local incrementer: api.Incrementer =
                        provider.Box.new(n)
                    return consumer.use(incrementer)
                end

                function make_incrementer(n: integer): api.Incrementer
                    return provider.Box.new(n)
                end

                function make_dynamic(n: integer): api.Dynamic
                    return provider.Box.new(n)
                end

                function run_adjusted(n: integer): integer
                    local dynamic: api.Dynamic =
                        provider.Box.new(n)
                    local converted = consumer.use_dynamic(
                        dynamic, n as value)
                    return converted as integer
                end

                function reject_adjusted(input: value): value
                    local dynamic: api.Dynamic =
                        provider.Box.new(1)
                    return consumer.use_dynamic(dynamic, input)
                end
            ]] },
        })
        assert.truthy(ok, err)

        -- Load the Interface owner and concrete provider before the bridge so a
        -- preexisting discovery entry can be installed. Bridge initialization
        -- must retain it while publishing the unseeded adjusted pair.
        local rok, out = call("interface_api", [[
            local provider = require "interface_provider"
            local consumer = require "interface_consumer"
            local bare = provider.bare(40)
            local concrete_meta = assert(debug.getmetatable(bare))
            local registry = debug.getregistry()
            local incrementer_meta = assert(registry[
                "Titan interface interface_api.Incrementer metatable"])
            local dynamic_meta = assert(registry[
                "Titan interface interface_api.Dynamic metatable"])
            local replacement
            local sentinel_calls = 0
            local sentinel = function(candidate)
                sentinel_calls = sentinel_calls + 1
                assert(rawequal(candidate, bare))
                return replacement
            end
            rawset(concrete_meta, incrementer_meta, sentinel)

            local bridge = require "interface_bridge"
            assert(rawequal(
                rawget(concrete_meta, incrementer_meta), sentinel))
            local generated = rawget(concrete_meta, dynamic_meta)
            assert(type(generated) == "function")
            assert(not rawequal(generated, sentinel))

            replacement = bridge.make_incrementer(7)
            assert(consumer.is_incrementer(bare))
            assert(sentinel_calls == 0)
            assert(consumer.use(bare) == 10)
            assert(sentinel_calls == 1)
            local explicit = consumer.explicit_incrementer(bare)
            assert(consumer.use(explicit) == 10)
            assert(sentinel_calls == 2)

            assert(consumer.is_dynamic(bare))
            assert(consumer.use_dynamic(bare, 20) == 61)
            assert(bridge.make_dynamic(9):convert(1) == 11)

            assert(bridge.run(40) == 43)
            assert(bridge.run_adjusted(20) == 41)
            local ok, err =
                pcall(bridge.reject_adjusted, 1.0)
            assert(not ok)
            assert(tostring(err):find("expected integer", 1, true),
                tostring(err))
        ]])
        assert.truthy(rok, out)
    end)

    it("shares dense arrays through a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "arraysofoo", src = [[
                function make(): {integer}
                    return {10, 20, 30}
                end
                function set(xs: {value}, i: integer, v: value)
                    xs[i] = v
                end
                function echo(xs: {value}): {value}
                    return xs
                end
            ]] },
            { name = "arraysobar", src = [[
                local foo = import "arraysofoo"
                function roundtrip(): {value}
                    local xs = foo.make()
                    foo.set(xs, 5, 50)
                    return foo.echo(xs)
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("arraysobar", [[
            local foo = require "arraysofoo"
            local xs = arraysobar.roundtrip()
            assert(type(xs) == "userdata")
            assert(#xs == 5)
            assert(xs[1] == 10 and xs[2] == 20 and xs[3] == 30)
            assert(xs[4] == nil and xs[5] == 50)
            assert(foo.echo(xs) == xs)

            -- The construction-selected integer writer survives the complete
            -- foo -> bar -> Lua passage even though bar exposes a {value} view.
            xs[6] = 60.0
            assert(math.type(xs[6]) == "integer" and xs[6] == 60,
                ("type=%s value=%s"):format(
                    tostring(math.type(xs[6])), tostring(xs[6])))
            local write_ok, write_err =
                pcall(function() xs[7] = "wrong" end)
            assert(not write_ok, "invalid string write unexpectedly succeeded")
            assert(tostring(write_err):find(
                "expected integer", 1, true), tostring(write_err))
            assert(#xs == 6 and xs[7] == nil)
        ]])
        assert.truthy(rok, out)
    end)

    it("keeps imported-nominal Array writers module-local across .so files",
    function()
        local ok, err = build_so_chain({
            { name = "arraywriterowner", src = [[
                record Item
                    number: integer
                end

                function Item.make(number: integer): Item
                    return Item.new(number)
                end
            ]] },
            { name = "arraywritera", src = [[
                local owner = import "arraywriterowner"

                function make(): {owner.Item}
                    return {owner.Item.make(1)}
                end

                function read(items: {owner.Item}): integer
                    return items[1].number
                end
            ]] },
            { name = "arraywriterb", src = [[
                local owner = import "arraywriterowner"

                function make(): {owner.Item}
                    return {owner.Item.make(2)}
                end

                function read(items: {owner.Item}): integer
                    return items[1].number
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("arraywriterb", [[
            local owner = require "arraywriterowner"
            local module_a = require "arraywritera"
            local module_b = require "arraywriterb"
            local items_a = module_a.make()
            local items_b = module_b.make()

            local writer_a = debug.getuservalue(items_a, 2)
            local writer_b = debug.getuservalue(items_b, 2)
            assert(type(writer_a) == "function")
            assert(type(writer_b) == "function")
            assert(writer_a ~= writer_b)

            local _, captured_a = debug.getupvalue(writer_a, 1)
            local _, captured_b = debug.getupvalue(writer_b, 1)
            assert(captured_a == module_a)
            assert(captured_b == module_b)

            writer_a, writer_b, captured_a, captured_b = nil, nil, nil, nil
            collectgarbage("collect")

            local write_ok, write_err =
                pcall(function() items_a[2] = "wrong" end)
            assert(not write_ok)
            assert(tostring(write_err):find(
                "expected arraywriterowner.Item", 1, true),
                tostring(write_err))
            assert(#items_a == 1 and items_a[2] == nil)

            items_a[1] = owner.Item.make(21)
            items_b[1] = owner.Item.make(22)
            assert(module_a.read(items_a) == 21)
            assert(module_b.read(items_b) == 22)
        ]])
        assert.truthy(rok, out)
    end)

    it("lowers named calls through a .so-only interface to the positional ABI",
    function ()
        local ok, err = build_so_chain({
            { name = "namedsofoo", src = [[
                record Empty end

                record Pair
                    first: integer
                    second: integer
                end

                function Pair.make(first: integer, second: integer): Pair
                    return Pair.new(first, second)
                end

                function Pair:encode(scale: integer, offset: integer): integer
                    return self.first * scale + self.second * offset
                end

                function combine(left: integer, right: integer): integer
                    return left * 100 + right
                end

                function zero(): integer
                    return 9
                end
            ]] },
            { name = "namedsobar", src = [[
                local foo = import "namedsofoo"

                function named(): integer
                    local empty: foo.Empty = foo.Empty.new {}
                    local pair = foo.Pair.make { second = 7, first = 5 }
                    local direct = foo.Pair.new { second = 3, first = 2 }
                    return foo.combine { right = 2, left = 4 }
                        + pair:encode { offset = 1, scale = 10 }
                        + direct:encode { offset = 2, scale = 3 }
                        + foo.zero {}
                end

                function positional(): integer
                    return foo.combine(6, 7)
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("namedsobar", [[
            assert(namedsobar.named() == 402 + 57 + 12 + 9)
            assert(namedsobar.positional() == 607)
            local foo = require "namedsofoo"
            assert(foo.combine(8, 9) == 809)
        ]])
        assert.truthy(rok, out)
    end)

    it("reads and writes public variable slots independently of local state",
       function ()
        local ok, err = build_so_chain({
            { name = "vfoo", src = [[
                local hidden_first: integer = 101
                first: integer = 1
                local hidden_second: integer = 102
                second: integer = 2
                third: integer = 3

                function hidden_sum(): integer
                    return hidden_first + hidden_second
                end
            ]] },
            { name = "vbar", src = [[
                local foo = import "vfoo"
                function update(): boolean
                    foo.first = 11
                    foo.second = 22
                    foo.third = 33
                    return foo.first == 11 and foo.second == 22 and
                           foo.third == 33 and foo.hidden_sum() == 203
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("vbar", [[
            assert(vbar.update())
            local foo = require "vfoo"
            assert(foo.first == 11 and foo.second == 22 and foo.third == 33)
            assert(not pcall(function() return foo.hidden_first end))
            assert(not pcall(function() return foo.hidden_second end))
        ]])
        assert.truthy(rok, out)
    end)

    it("preserves const values through .so-only metadata and Lua", function()
        local ok, err = build_so_chain({
            { name = "const_so_owner", src = [[
                const answer = 42

                record Box
                    local hidden: integer
                    const label: string
                    count: integer
                end

                interface View
                    label: string
                    function total(): integer
                end

                function Box:total(): integer
                    return self.count
                end

                function make(): Box
                    return Box.new(99, "fixed", 3)
                end

                function view(box: Box): View
                    return box
                end

                function numbers(): const { integer }
                    return { 10, 20 }
                end
            ]] },
            { name = "const_so_consumer", src = [[
                local owner = import "const_so_owner"

                function read(): integer
                    local box = owner.make()
                    local view = owner.view(box)
                    local numbers = owner.numbers()
                    if view.label == box.label then
                        return owner.answer + view:total() + numbers[2]
                    end
                    return 0
                end

                function box(): owner.Box
                    return owner.make()
                end

                function view(): owner.View
                    return owner.view(owner.make())
                end

                function imported_view(): owner.View
                    local box = owner.make()
                    return box
                end

                function numbers(): const { integer }
                    return owner.numbers()
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("const_so_consumer", [[
            local owner = require "const_so_owner"
            assert(const_so_consumer.read() == 65)

            assert(owner.answer == 42)
            assert(not pcall(function() owner.answer = 0 end))
            assert(owner.answer == 42)

            local box = const_so_consumer.box()
            assert(box.label == "fixed" and box.count == 3)
            box.count = 4
            assert(not pcall(function() box.label = "changed" end))
            assert(box.label == "fixed" and box.count == 4)

            local view = const_so_consumer.view()
            assert(view.label == "fixed" and view:total() == 3)
            assert(not pcall(function() view.label = "changed" end))

            local imported_view = const_so_consumer.imported_view()
            assert(imported_view.label == "fixed" and
                imported_view:total() == 3)
            assert(not pcall(function() imported_view.label = "changed" end))

            local numbers = const_so_consumer.numbers()
            assert(#numbers == 2 and numbers[1] == 10)
            assert(not pcall(function() numbers[1] = 99 end))
            assert(numbers[1] == 10)
        ]])
        assert.truthy(rok, out)
    end)

    it("preserves maybe-const Arrays through .so-only metadata", function()
        local ok, err = build_so_chain({
            { name = "maybe_const_so_owner", src = [[
                record Box
                    items: const? { integer }
                end

                function identity(items: const? { integer }): const? { integer }
                    return items
                end

                function count(items: const? {integer}?): integer
                    if items == nil then return -1 end
                    return #items
                end

                function mutable(): { integer }
                    return { 10, 20 }
                end

                function immutable(): const { integer }
                    return { 30, 40 }
                end
            ]] },
            { name = "maybe_const_so_consumer", src = [[
                local owner = import "maybe_const_so_owner"

                function mutable(): const? { integer }
                    local box = owner.Box.new(owner.mutable())
                    return owner.identity(box.items)
                end

                function immutable(): const? { integer }
                    local box = owner.Box.new(owner.immutable())
                    return owner.identity(box.items)
                end

                function count(items: const? { integer }): integer
                    return owner.count(owner.identity(items))
                end

                function absent(): integer
                    return owner.count(nil)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("maybe_const_so_consumer", [[
            local consumer = maybe_const_so_consumer
            local mutable = consumer.mutable()
            local immutable = consumer.immutable()
            assert(consumer.count(mutable) == 2)
            assert(consumer.count(immutable) == 2)
            assert(consumer.absent() == -1)
            assert(mutable[1] == 10 and immutable[1] == 30)
            mutable[1] = 99
            assert(mutable[1] == 99)
            assert(not pcall(function() immutable[1] = 99 end))
            assert(immutable[1] == 30)
        ]])
        assert.truthy(rok, out)
    end)

    it("constructs and uses a record from a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "rfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
                function origin(): Point
                    return { x = 0, y = 0 }
                end
            ]] },
            { name = "rbar", src = [[
                local f = import "rfoo"
                function bar(): (float, float)
                    local p: f.Point = { x = 2, y = 3 }
                    p:move(2, 3)
                    return p.x, p.y
                end
                function viactor(): (float, float)
                    local p = f.Point.new(10, 20)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("rbar",
            "local x,y = rbar.bar(); assert(x == 4.0 and y == 6.0); " ..
            "local a,b = rbar.viactor(); assert(a == 10.0 and b == 20.0)")
        assert.truthy(rok, out)
    end)

    it("preserves public field slots for .so-only records with local members", function ()
        local ok, err = build_so_chain({
            { name = "lrfoo", src = [[
                record Box
                  local hidden: integer
                  first: integer
                  second: integer
                  third: integer
                end
                local function Box:secret(): integer
                    return self.hidden
                end
                function make(hidden: integer, first: integer,
                              second: integer, third: integer): Box
                    return Box.new(hidden, first, second, third)
                end
                function Box.make(first: integer, second: integer,
                                  third: integer): Box
                    return Box.new(first * 10, first, second, third)
                end
                local function Box.secret_box(hidden: integer): Box
                    return Box.new(hidden, 0, 0, 0)
                end
                function reveal(b: Box): integer
                    return b.hidden + b:secret()
                end
            ]] },
            { name = "lrbar", src = [[
                local f = import "lrfoo"
                function viaimport(): boolean
                    local b = f.make(11, 31, 32, 33)
                    local c = f.Box.make(7, 8, 9)
                    return b.first == 31 and b.second == 32 and b.third == 33 and
                           c.first == 7 and c.second == 8 and c.third == 9 and
                           f.reveal(b) == 22 and f.reveal(c) == 140
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("lrbar", [[
            assert(lrbar.viaimport())
            local foo = require 'lrfoo'
            local b = foo.Box.make(19, 20, 21)
            assert(b.first == 19 and b.second == 20 and b.third == 21)
            local ok_hidden = pcall(function() return b.hidden end)
            assert(not ok_hidden)
            local ok_secret = pcall(function() return b:secret() end)
            assert(not ok_secret)
            assert(foo.Box.new == nil)
            assert(foo.Box.secret_box == nil)
            assert(foo.reveal(b) == 380)
        ]])
        assert.truthy(rok, out)
    end)

    it("calls a method on a record returned from a .so-only module", function ()
        local ok, err = build_so_chain({
            { name = "qfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float): Point
                    self.x, self.y = self.x + dx, self.y + dy
                    return self
                end
                function get_point(): Point
                    return { x = 10, y = 20 }
                end
            ]] },
            { name = "qbar", src = [[
                local f = import "qfoo"
                function bar(): (float, float)
                    local p = f.get_point():move(2, 3)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("qbar",
            "local x,y = qbar.bar(); assert(x == 12.0 and y == 23.0)")
        assert.truthy(rok, out)
    end)

    it("uses a record through a transitive .so-only chain (bar -> baz -> foo)",
       function ()
        local ok, err = build_so_chain({
            { name = "tfoo", src = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]] },
            { name = "tbaz", src = [[
                local f = import "tfoo"
                function point(x: float, y: float): f.Point
                    return { x = x, y = y }
                end
            ]] },
            { name = "tbar", src = [[
                local b = import "tbaz"
                function bar(): (float, float)
                    local p = b.point(2, 3)
                    p:move(2, 3)
                    return p.x, p.y
                end
            ]] },
        })
        assert.truthy(ok, err)
        local f = assert(io.open("tbar.c", "r"))
        local generated = f:read("*a")
        f:close()
        assert.match(
            'loadlib%s*%(%s*L,%s*"tbaz%.so"%s*%)', generated)
        assert.not_match(
            'loadlib%s*%(%s*L,%s*"tfoo%.so"%s*%)', generated)
        assert.match(
            'loadglobalsym%s*%(%s*L,%s*'
                .. '"tfoo_\\u2133_Point_\\u2131_move_titanmethod"%s*%)',
            generated)
        local rok, out = call("tbar",
            "local x,y = tbar.bar(); assert(x == 4.0 and y == 6.0)")
        assert.truthy(rok, out)
    end)

    it("uses methods through a re-exported record alias without reopening its owner",
       function ()
        local ok, err = build_so_chain({
            { name = "alias_provider", src = [[
                record Foo
                    n: integer
                end

                function Foo.make(n: integer): Foo
                    return Foo.new(n)
                end

                function Foo:plus(delta: integer): integer
                    return self.n + delta
                end

                union Reason
                    simple(integer)
                    empty()
                end

                function Reason.amount(reason: Reason): integer
                    case reason
                    when simple(amount) then
                        return amount
                    else
                        return 0
                    end
                end
            ]] },
            { name = "alias_facade", src = [[
                local provider = import "alias_provider"
                type Foo = provider.Foo
                type FooAgain = Foo
                type Reason = provider.Reason
                function make(n: integer): Foo
                    return Foo.new(n)
                end
            ]] },
            { name = "alias_consumer", src = [[
                local facade = import "alias_facade"
                function run(): integer
                    local make: function (integer): facade.Foo =
                        facade.Foo.make
                    local new: function (integer): facade.Foo =
                        facade.FooAgain.new
                    local simple: function (integer): facade.Reason =
                        facade.Reason.simple
                    local amount: function (facade.Reason): integer =
                        facade.Reason.amount
                    local foo = make(40)
                    local other = new(39)
                    local plus: function (integer): integer = foo:plus
                    return foo:plus(1) + plus(2) + other.n
                        + amount(simple(3))
                        + facade.Foo.make(38).n
                        + facade.make(37).n
                end
            ]] },
        })
        assert.truthy(ok, err)

        local bf = assert(io.open("alias_facade.c", "r"))
        local facade_c = bf:read("*a")
        bf:close()
        assert.match(
            'loadlib%s*%(%s*L,%s*"alias_provider%.so"%s*%)', facade_c)
        -- A direct synthesized constructor uses the reconstructed public
        -- payload and the owner's metatable instead of loading a call entry.
        assert.not_match(
            'loadsym%s*%(%s*L,%s*alias_provider_handle,%s*'
                .. '"alias_provider_\\u2133_Foo_\\u2131_new_titanstatic"%s*%)',
            facade_c)

        assert.match(
            'luaL_getmetatable%s*%(%s*L,%s*"Titan record alias_provider%.Foo metatable"%s*%)',
            facade_c)

        local cf = assert(io.open("alias_consumer.c", "r"))
        local consumer_c = cf:read("*a")
        cf:close()
        assert.match(
            'loadlib%s*%(%s*L,%s*"alias_facade%.so"%s*%)', consumer_c)
        assert.not_match(
            'loadlib%s*%(%s*L,%s*"alias_provider%.so"%s*%)', consumer_c)
        assert.not_match("alias_provider_handle", consumer_c)
        assert.match(
            'loadglobalsym%s*%(%s*L,%s*'
                .. '"alias_provider_\\u2133_Foo_\\u2131_plus_titanmethod"%s*%)',
            consumer_c)
        assert.match(
            'loadglobalsym%s*%(%s*L,%s*'
                .. '"alias_provider_\\u2133_Foo_\\u2131_plus_boundmethod"%s*%)',
            consumer_c)
        local merged_consumer_c = consumer_c:gsub('"%s*"', '')
        for _, role in ipairs({
            "boundlua", "boundstrict",
        }) do
            assert.match(
                'loadglobalsym%s*%(%s*L,%s*"alias_provider_' ..
                    '\\u2133_Foo_\\u2131_plus_titanentry_' ..
                    role .. '"%s*%)',
                merged_consumer_c)
        end
        assert.match(
            'loadglobalsym%s*%(%s*L,%s*'
                .. '"alias_provider_\\u2133_Foo_\\u2131_make_titanstatic"%s*%)',
            consumer_c)
        assert.match(
            'lua_getfield%s*%(%s*L,%s*LUA_REGISTRYINDEX,%s*'
                .. '"Titan module alias_provider"%s*%)',
            consumer_c)

        local rok, out = call("alias_consumer",
            "assert(alias_consumer.run() == 200)")
        assert.truthy(rok, out)
    end)

    it("references, calls and passes function values across a .so boundary", function ()
        local ok, err = build_so_chain({
            { name = "fcfa", src = [[
                function inc(x: integer): integer return x + 1 end
                function twice(f: function (integer): integer, x: integer): integer
                    return f(f(x))
                end
                function getinc(): function (integer): integer
                    return inc
                end
            ]] },
            { name = "fcfb", src = [[
                local a = import "fcfa"
                function binc(x: integer): integer return x + 1 end
                function run(): integer
                    local f: function (integer): integer = a.inc  -- reference across the .so
                    local r1 = f(10)                       -- call a's value
                    local r2 = a.twice(binc, 0)            -- pass b's value into a
                    local r3 = a.twice(a.inc, 5)           -- pass a's value into a
                    local g = a.getinc()                   -- get a value back from a
                    local r4 = g(100)
                    return r1 + r2 + r3 + r4                -- 11 + 2 + 7 + 101
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("fcfb", "assert(fcfb.run() == 121)")
        assert.truthy(rok, out)
    end)

    it("takes the exact-type fast path for a function value across a .so boundary", function ()
        -- The dependency is reachable ONLY as a compiled `.so`: the closure-slot
        -- index is rebuilt from the recovered interface and the function-type tag
        -- is recovered from the registry the dependency's `.so` published when it
        -- was dlopened. `run_direct` is the native-call baseline and `run_fast`
        -- calls a's `inner` as an exact value; if the tags agree the value call
        -- also uses the native entry (no extra Lua frame). If either disagrees it
        -- falls back to a stack entry and the depth assertion fails.
        local ok, err = build_so_chain({
            { name = "fpa", src = [[
                function inner(p: function (): integer): integer return p() end
            ]] },
            { name = "fpb", src = [[
                local a = import "fpa"
                function outer(g: function (function (): integer): integer, p: function (): integer): integer
                    return g(p)
                end
                function run_direct(p: function (): integer): integer return a.inner(p) end
                function run_fast(p: function (): integer): integer return outer(a.inner, p) end
                function run_slow(p: function (): integer,
                                  g: function (function (): integer): integer): integer
                    return outer(g, p)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("fpb", h.DEPTH_PROBE .. [[
            local directd = fpb.run_direct(depth)
            local fastd = fpb.run_fast(depth)
            local slowd = fpb.run_slow(depth, slow_g)
            assert(directd == fastd,
                ('direct=')..directd..(' exact=')..fastd)
            assert(slowd > fastd, ('fast=')..fastd..(' slow=')..slowd)
        ]])
        assert.truthy(rok, out)
    end)

    it("keeps non-exact provider values strict while Lua uses their coercive entry",
    function()
        local ok, err = build_so_chain({
            { name = "entrysoa", src = [[
                function boundary(x: integer): value
                    if x == 3 then
                        return 2.0
                    end
                    return x
                end
            ]] },
            { name = "entrysob", src = [[
                local provider = import "entrysoa"

                function strict_result(): integer
                    local f: function (integer): integer = provider.boundary
                    return f(3)
                end

                function strict_argument(x: value): value
                    local f: function (value): value = provider.boundary
                    return f(x)
                end

                function boundary_function(): function (integer): value
                    return provider.boundary
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("entrysob", [[
            local provider = require "entrysoa"

            -- The accessor returns the canonical closure owned by the DSO.
            -- Lua invokes that same closure through CClosure.f: its 2.0 input
            -- is converted for the integer formal, which is visible in the
            -- provider's value result.
            local boundary = entrysob.boundary_function()
            assert(boundary == provider.boundary)
            assert(math.type(boundary(2.0)) == "integer")
            assert(boundary(2.0) == 2)

            -- The same closure viewed non-exactly by Titan is a branded Titan
            -- value, so its strict trailer rejects rather than applying the
            -- genuine-Lua numeric coercion.
            local result_ok, result_err = pcall(entrysob.strict_result)
            assert(not result_ok, tostring(result_err))
            assert(tostring(result_err):find(
                "expected integer", 1, true), tostring(result_err))

            local argument_ok, argument_err =
                pcall(entrysob.strict_argument, 2.0)
            assert(not argument_ok, tostring(argument_err))
            assert(tostring(argument_err):find(
                "expected integer", 1, true), tostring(argument_err))
        ]])
        assert.truthy(rok, out)
    end)

    it("preserves flexible string returns on direct and exact value calls across a .so", function ()
        -- `flexsoa` is available only through its compiled interface. Besides
        -- recovering the flexible result element type, `flexsob` must recover
        -- the exact function tag and native signature (including the trailing
        -- flexible-output pair) for the first-class call. A compatible view
        -- with a narrower first parameter deliberately has a different tag and
        -- provides the generic-path depth comparison.
        local ok, err = build_so_chain({
            { name = "flexsoa", src = [[
                function values(probe: value, force: function (): (),
                                prefix: string): (integer, ...: string)
                    local p: function (): integer = probe
                    local a = prefix .. "-one"
                    local b = prefix .. "-two"
                    force()
                    return p(), a, b
                end
            ]] },
            { name = "flexsob", src = [[
                local a = import "flexsoa"

                function direct(probe: function (): integer, force: function (): (),
                                prefix: string): (integer, ...: string)
                    return a.values(probe, force, prefix)
                end

                function exact(probe: function (): integer, force: function (): (),
                               prefix: string): (integer, ...: string)
                    local f: function (value, function (): (), string): (integer, ...: string) = a.values
                    return f(probe, force, prefix)
                end

                function generic(probe: function (): integer, force: function (): (),
                                 prefix: string): (integer, ...: string)
                    local v: value = a.values
                    local f: function (function (): integer, function (): (), string): (integer, ...: string) = v
                    return f(probe, force, prefix)
                end
            ]] },
        })
        assert.truthy(ok, err)

        local rok, out = call("flexsob", h.DEPTH_PROBE .. [[
            collectgarbage("generational")
            local prefix = ("fresh-"):rep(20) .. tostring({})
            local collections = 0
            local function force()
                collections = collections + 1
                local junk = {}
                for i = 1, 2000 do junk[i] = { i, tostring(i) } end
                collectgarbage("collect")
            end

            local function check(callable)
                local d, a, b = callable(depth, force, prefix)
                collectgarbage("collect")
                assert(a == prefix .. "-one", a)
                assert(b == prefix .. "-two", b)
                return d
            end

            local directd = check(flexsob.direct)
            local exactd = check(flexsob.exact)
            local genericd = check(flexsob.generic)
            assert(directd == exactd,
                ("direct=") .. directd .. (" exact=") .. exactd)
            assert(genericd > exactd,
                ("exact=") .. exactd .. (" generic=") .. genericd)
            assert(collections == 3)
        ]])
        assert.truthy(rok, out)
    end)

    -- Regression: an imported record used ONLY as a Lua-facing parameter is
    -- never constructed in the importer, so genluaentry's checkandget is the
    -- FIRST site to allocate that record's metatable slot — and it runs with the
    -- top-level tlcontext (no `.tlcontext` field). type2metatable must resolve
    -- the tlcontext either way, or codegen crashes before emitting any C.
    it("accepts an imported record used only as a Lua-facing parameter", function ()
        local ok, err = build_so_chain({
            { name = "ppfoo", src = [[
                record Point
                    x: integer
                end
                function make(n: integer): Point
                    return { x = n }
                end
            ]] },
            { name = "ppbar", src = [[
                local foo = import "ppfoo"
                function px(p: foo.Point): integer
                    return p.x
                end
            ]] },
        })
        assert.truthy(ok, err)
        -- the imported-record parameter coerces correctly at the Lua boundary...
        local rok, out = call("ppbar",
            "local foo = require 'ppfoo'; assert(ppbar.px(foo.make(7)) == 7)")
        assert.truthy(rok, out)
        -- ...and the metatable check cleanly rejects a non-record userdata
        local rok2, out2 = call("ppbar",
            "local ok, e = pcall(ppbar.px, ppbar); assert(not ok); assert(e:find('but found'))")
        assert.truthy(rok2, out2)
    end)

    it("imports a .so-only variadic function, called statically and from Lua", function ()
        -- The dependency is reachable ONLY as a compiled `.so`: the importer
        -- recovers `sum`'s `(...: integer) -> integer` interface (incl. varargtype)
        -- from `<mangled>_types`, calls it STATICALLY across the dynamic boundary
        -- (the native vararg ABI: `_varargs` + `_start` at the pinned slot), and
        -- the dependency's own Lua entry (genluaentry) handles the call FROM LUA.
        local ok, err = build_so_chain({
            { name = "vsfoo", src = [[
                function sum(...: integer): integer
                    local s = 0
                    local i = 1
                    local n = #...
                    while i <= n do s = s + ...[i]; i = i + 1 end
                    return s
                end
            ]] },
            { name = "vsbar", src = [[
                local foo = import "vsfoo"
                function viastatic(): integer
                    return foo.sum(1, 2, 3, 4)   -- static call across the .so
                end
                function empty(): integer
                    return foo.sum()             -- empty vararg across the .so
                end
                function asvalue(): integer
                    local f: function (...: integer): integer = foo.sum  -- value across .so
                    return f(10, 20)
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("vsbar", [[
            assert(vsbar.viastatic() == 10)
            assert(vsbar.empty() == 0)
            assert(vsbar.asvalue() == 30)
            -- call the .so-only variadic function directly FROM LUA (genluaentry)
            local foo = require 'vsfoo'
            assert(foo.sum(5, 6, 7) == 18)
            assert(foo.sum() == 0)
        ]])
        assert.truthy(rok, out)
    end)

    it("imports a .so-only ...: string variadic, called statically and from Lua under GC", function ()
        -- COLLECTABLE element type across the dynamic boundary. The static call
        -- builds the backing struct on the importer's C stack from fresh strings;
        -- the .so callee forces a minor collection before reading any element, so
        -- a dropped anchor across the dlsym'd native pointer is deterministic
        -- corruption under generational mode.
        local ok, err = build_so_chain({
            { name = "vstrfoo", src = [[
                function totallen(...: string): integer
                    local junk: {integer} = {}
                    local k = 1
                    while k <= 300 do junk = { k }; k = k + 1 end
                    local s = 0
                    local i = 1
                    local n = #...
                    while i <= n do s = s + #(...[i]); i = i + 1 end
                    return s
                end
            ]] },
            { name = "vstrbar", src = [[
                local foo = import "vstrfoo"
                function viastatic(a: string, b: string): integer
                    return foo.totallen(a, b, "lit3")   -- static call across the .so
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("vstrbar", [[
            collectgarbage("generational")
            local a = ("a"):rep(4) .. "!"   -- 5
            local b = ("b"):rep(6) .. "!"   -- 7
            for i = 1, 2000 do local _ = { i } end
            collectgarbage("step")
            assert(vstrbar.viastatic(a, b) == 5 + 7 + 4)
            -- and directly FROM LUA (genluaentry on the .so module)
            local foo = require 'vstrfoo'
            local c = ("c"):rep(2) .. "!"   -- 3
            assert(foo.totallen(a, b, c) == 5 + 7 + 3)
            assert(foo.totallen() == 0)
        ]])
        assert.truthy(rok, out)
    end)

    it("imports a .so-only ...: R variadic and a variadic method across the .so", function ()
        -- A RECORD element type (Udata*) and a variadic METHOD both recovered from
        -- `<mangled>_types` across the dynamic boundary, called statically and
        -- from Lua. The record's type tag is recovered from the .so's published
        -- registry; the method's varargtype survives serialization.
        local ok, err = build_so_chain({
            { name = "vrecfoo", src = [[
                record R
                    v: integer
                end
                record Acc
                    base: integer
                end
                function mk(v: integer): R
                    return { v = v }
                end
                function Acc:sumv(...: R): integer
                    local junk: {integer} = {}
                    local k = 1
                    while k <= 300 do junk = { k }; k = k + 1 end
                    local s = self.base
                    local i = 1
                    local n = #...
                    while i <= n do s = s + (...[i]).v; i = i + 1 end
                    return s
                end
            ]] },
            { name = "vrecbar", src = [[
                local foo = import "vrecfoo"
                function viastatic(a: foo.Acc, x: foo.R, y: foo.R): integer
                    return a:sumv(x, y)             -- method call across .so
                end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("vrecbar", [[
            collectgarbage("generational")
            local foo = require 'vrecfoo'
            local a = foo.Acc.new(10)
            local r1, r2, r3 = foo.mk(3), foo.mk(5), foo.mk(7)
            for i = 1, 2000 do local _ = { i } end
            collectgarbage("step")
            -- static call site across the .so boundary
            assert(vrecbar.viastatic(a, r1, r2) == 10 + 3 + 5)
            -- variadic method directly FROM LUA across the .so boundary
            assert(a:sumv(r1, r2, r3) == 10 + 3 + 5 + 7)
            assert(a:sumv() == 10)
        ]])
        assert.truthy(rok, out)
    end)

    it("aborts when the loaded .so has an incompatible used signature", function()
        local ok, err = build_so_chain({
            { name = "manifest_provider", src = [[
                function get(): integer return 42 end
            ]] },
            { name = "manifest_consumer", src = [[
                local p = import "manifest_provider"
                function run(): integer return p.get() end
            ]] },
        })
        assert.truthy(ok, err)
        local rok, out = call("manifest_consumer", [[
            assert(manifest_consumer.run() == 42)
        ]])
        assert.truthy(rok, out)

        -- Recompile provider with an incompatible type interface
        ok, err = build_so_chain({
            { name = "manifest_provider", src = [[
                function get(): string return "changed" end
            ]] },
        })
        assert.truthy(ok, err)

        -- Loading the consumer now must fail the selective compatibility check
        rok, out = call("string", [[
            local ok, err = pcall(require, "manifest_consumer")
            assert(not ok, "expected require to fail")
            assert(err:find("compatibility mismatch", 1, true), err)
        ]])
        assert.truthy(rok, out)
    end)

    it("aborts when the loaded .so is missing the compatibility symbol", function()
        local ok, err = build_so_chain({
            { name = "notype_provider", src = [[
                function answer(): integer return 1 end
            ]] },
            { name = "notype_consumer", src = [[
                local p = import "notype_provider"
                function run(): integer return p.answer() end
            ]] },
        })
        assert.truthy(ok, err)

        -- Replace provider with an ABI marker but no compatibility entry
        local f = assert(io.open("notype_provider.c", "w"))
        f:write([[
            typedef struct lua_State lua_State;
            extern const char *lua_pushstring(lua_State *L, const char *s);
            int notype_provider_abi(lua_State *L) {
                lua_pushstring(L, "2");
                return 1;
            }
        ]])
        f:close()
        local shared = driver.IS_DARWIN and "-shared -undefined dynamic_lookup"
            or "-shared"
        local cok = os.execute(table.concat({
            driver.CC, "-fPIC", shared, "-o", "notype_provider.so", "notype_provider.c"
        }, " "))
        assert.truthy(cok, "could not compile fake provider without compatibility")

        local rok, out = call("string", [[
            local ok, err = pcall(require, "notype_consumer")
            assert(not ok, "expected require to fail")
            assert(err:find("compatibility", 1, true), err)
        ]])
        assert.truthy(rok, out)
    end)
end)

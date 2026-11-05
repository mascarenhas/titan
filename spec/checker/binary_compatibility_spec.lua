local h = require "spec.support.helpers"

local function check(modules, main)
    local ok, errors, imported = h.run_checker_modules(modules, main or "consumer")
    assert.truthy(ok, errors)
    return imported[main or "consumer"].ast, imported
end

describe("binary dependency usage", function()
    it("tracks selected functions and read or write variables without unused exports", function()
        local tree = check({
            provider = [[
                read = 1
                written = 2
                unused = 3
                function called(x: integer): integer return x end
                function referenced(x: integer): integer return x end
                function ignored(): integer return 0 end
            ]],
            consumer = [[
                local p = import "provider"
                function use(): integer
                    p.written = 4
                    local f = p.referenced
                    return p.called(p.read) + f(2)
                end
            ]],
        })
        local usage = tree._binary_usage.provider
        assert.same({ called = true, referenced = true }, usage.functions)
        assert.same({ read = true, written = true }, usage.variables)
        assert.equal("provider", tree._binary_modules.provider.name)
    end)

    it("keeps each consumer's selections independent", function()
        local _, imported = check({
            provider = [[
                function left(): integer return 1 end
                function right(): integer return 2 end
            ]],
            left = [[
                local p = import "provider"
                function run(): integer return p.left() end
            ]],
            right = [[
                local p = import "provider"
                function run(): integer return p.right() end
            ]],
            consumer = [[
                local left = import "left"
                local right = import "right"
            ]],
        })
        assert.same({left = true}, imported.left.ast._binary_usage.provider.functions)
        assert.same({right = true}, imported.right.ast._binary_usage.provider.functions)
        assert.is_nil(imported.consumer.ast._binary_usage.provider)
    end)

    it("tracks inferred nominal owners, static calls, and bound methods", function()
        local tree = check({
            provider = [[
                record Item number: integer end
                record Unused end
                function Item.make(): Item return Item.new(7) end
                function Item:read(): integer return self.number end
                function Item:unused(): integer return 0 end
            ]],
            consumer = [[
                local p = import "provider"
                function use(): integer
                    local item = p.Item.make()
                    local read = item:read
                    return read() + item.number
                end
            ]],
        })
        assert.same({
            Item = { functions = {make = true}, methods = {read = true} },
        }, tree._binary_usage.provider.records)
    end)

    it("preserves alias selections and recovers their transitive canonical owners", function()
        local tree = check({
            owner = [[
                record Box<|T|> item: T end
                function Box:get(): T return self.item end
            ]],
            facade = [[
                local owner = import "owner"
                type Alias = owner.Box
            ]],
            consumer = [[
                local f = import "facade"
                function use(item: f.Alias<|integer|>): integer
                    return item:get()
                end
            ]],
        })
        assert.same({functions = {}, methods = {}},
            tree._binary_usage.facade.records.Alias)
        assert.same({functions = {}, methods = {get = true}},
            tree._binary_usage.owner.records.Box)
        assert.equal("owner", tree._binary_modules.owner.name)
    end)

    it("tracks contextual record construction independently of new calls", function()
        local tree = check({
            provider = [[record Item number: integer end]],
            consumer = [[
                local p = import "provider"
                function make(): p.Item return {number = 42} end
            ]],
        })
        assert.is_true(tree._binary_usage.provider.records.Item.literal)
        assert.same({}, tree._binary_usage.provider.records.Item.functions)
    end)

    it("keeps callback-free imported initializer calls independent of default authority", function()
        for _, initializer in ipairs({
            "item: p.Item = p.Item(42)",
            "items: {p.Item} = {p.Item.new(42)}",
            "record Wrapper item: p.Item end; item = Wrapper(p.Item{number = 42})",
        }) do
            local tree = check({
                provider = [[record Item number: integer end]],
                consumer = 'local p = import "provider"\n' .. initializer,
            })
            assert.is_nil(tree._binary_usage.provider.records.Item.literal)
            assert.same({new = true}, tree._binary_usage.provider.records.Item.functions)
        end
    end)

    local callback = "function(): integer return seed end"
    local stored_callables = {
        {"a lambda", callback},
        {"an Array", "{" .. callback .. "}"},
        {"a Map", '{["read"] = ' .. callback .. "}"},
        {"a written cast", "(" .. callback .. ") as value"},
        {"an operator", "true and " .. callback},
        {"an own bound method", "Own(1):read"},
        {"an own Interface implementation", "Own(1) as p.Reader"},
        {"a nested Interface implementation", '{["reader"] = Own(1) as p.Reader}'},
        {"an imported generated record", "p.Inner(" .. callback .. ")"},
        {"an own generated record", "LocalHolder(" .. callback .. ")"},
        {"a generated union", "Choice.Some(" .. callback .. ")"},
        {"a projected generated record", "p.Inner(" .. callback .. ").item"},
    }
    for _, case in ipairs(stored_callables) do
        it("requires non-invoking default authority when an initializer stores " ..
           case[1], function()
            local tree = check({
                provider = [[
                    interface Reader function read(): integer end
                    record Holder item: value end
                    record Inner item: value end
                ]],
                consumer = [[
                    local p = import "provider"
                    local seed: integer?
                    record Own number: integer end
                    function Own:read(): integer return seed end
                    record LocalHolder item: function(): integer end
                    union Choice Some(function(): integer) end
                    local held = p.Holder(]] .. case[2] .. [[)
                ]],
            })
            assert.is_true(tree._binary_usage.provider.records.Holder.literal)
            if case[2]:find("p.Inner", 1, true) then
                assert.is_true(tree._binary_usage.provider.records.Inner.literal)
            end
        end)
    end

    it("keeps callback-free values and imported implementations replaceable",
       function()
        for _, expression in ipairs({
            "p.external",
            "p.ForeignBox(1):read",
            "(p.ForeignBox(1) as Reader):read",
            "#{" .. callback .. "}",
        }) do
            local tree = check({
                provider = [[
                    record Holder item: value end
                    function external(): integer return 42 end
                    record ForeignBox number: integer end
                    function ForeignBox:read(): integer return self.number end
                ]],
                consumer = [[
                    local p = import "provider"
                    local seed: integer?
                    interface Reader function read(): integer end
                    local held = p.Holder(]] .. expression .. [[)
                ]],
            })
            assert.is_nil(tree._binary_usage.provider.records.Holder.literal)
        end
    end)

    it("does not require a default body for a constructor deferred inside a lambda",
       function()
        local tree = check({
            provider = [[record Holder item: function(): integer end]],
            consumer = [[
                local p = import "provider"
                local seed: integer?
                local factory = function(): p.Holder
                    return p.Holder(function(): integer return seed end)
                end
            ]],
        })
        assert.is_nil(tree._binary_usage.provider.records.Holder.literal)
    end)

    it("still requires literal authority for raw module-variable construction", function()
        local tree = check({
            provider = [[record Item number: integer end]],
            consumer = [[
                local p = import "provider"
                const item: p.Item = {number = 42}
            ]],
        })
        assert.is_true(tree._binary_usage.provider.records.Item.literal)
        assert.same({}, tree._binary_usage.provider.records.Item.functions)
    end)

    it("keeps ordinary calls independent of default construction authority", function()
        local tree = check({
            provider = [[record Item number: integer end]],
            consumer = [[
                local p = import "provider"
                factory: function(): p.Item = function(): p.Item return p.Item(1) end
                item: p.Item?
                function make(): p.Item return p.Item.new(2) end
                do item = p.Item{number = 3} end
            ]],
        })
        assert.is_nil(tree._binary_usage.provider.records.Item.literal)
        assert.same({new = true}, tree._binary_usage.provider.records.Item.functions)
    end)

    it("tracks concrete methods used only by implicit Interface conversion", function()
        local tree = check({
            provider = [[
                record Item number: integer end
                function Item:read(): integer return self.number end
                function Item:unused(): integer return 0 end
                function make(): Item return Item.new(7) end
                interface Reader function read(): integer end
            ]],
            consumer = [[
                local p = import "provider"
                function use(): p.Reader return p.make() end
            ]],
        })
        assert.same({read = true}, tree._binary_usage.provider.records.Item.methods)
        assert.same({Reader = true}, tree._binary_usage.provider.interfaces)
    end)

    it("tracks nested and open-run Interface conversions", function()
        local tree = check({
            provider = [[
                record Item number: integer end
                function Item:read(): integer return self.number end
                interface Reader function read(): integer end
                record Container const item: Item end
                interface View item: Reader end
            ]],
            consumer = [[
                local p = import "provider"
                function nested(container: p.Container): p.View
                    return container
                end
                function many(...: p.Item): (...: p.Reader)
                    return ...
                end
            ]],
        })
        assert.same({read = true}, tree._binary_usage.provider.records.Item.methods)
        assert.same({Reader = true, View = true},
            tree._binary_usage.provider.interfaces)
    end)

    it("tracks Interface methods introduced by constrained generic lowering", function()
        local tree = check({
            provider = [[
                record Item number: integer end
                function Item:read(): integer return self.number end
                interface Reader function read(): integer end
                function identity<|T: Reader|>(item: T): T return item end
            ]],
            consumer = [[
                local p = import "provider"
                function use(item: p.Item): p.Item
                    return p.identity(item)
                end
            ]],
        })
        assert.same({identity = true}, tree._binary_usage.provider.functions)
        assert.same({read = true}, tree._binary_usage.provider.records.Item.methods)
        assert.same({Reader = true}, tree._binary_usage.provider.interfaces)
    end)

    it("records closed union inventory only when it proves termination", function()
        local provider = [[union Result yes() no() end]]
        local dependent = check({ provider = provider, consumer = [[
            local p = import "provider"
            function read(result: p.Result): integer
                case result
                when yes() then return 1
                when no() then return 0
                else local ignored = 1
                end
            end
        ]] })
        assert.is_true(dependent._binary_usage.provider.unions.Result.closed)
        local independent = check({ provider = provider, consumer = [[
            local p = import "provider"
            function read(result: p.Result): integer
                case result
                when yes() then return 1
                when no() then return 0
                else return -1
                end
            end
        ]] })
        assert.is_nil(independent._binary_usage.provider.unions.Result.closed)
        local partial = check({ provider = provider, consumer = [[
            local p = import "provider"
            function inspect(result: p.Result)
                case result when yes() then local ignored = 1 end
            end
        ]] })
        assert.is_nil(partial._binary_usage.provider.unions.Result.closed)
    end)

    it("tracks generic callable declarations without collecting unused methods", function()
        local tree = check({
            provider = [[
                record Box<|T|> item: T end
                function identity<|T|>(item: T): T return item end
                function Box:unused(): T return self.item end
            ]],
            consumer = [[
                local p = import "provider"
                function use(box: p.Box<|integer|>): p.Box<|integer|>
                    return p.identity(box)
                end
            ]],
        })
        assert.same({identity = true}, tree._binary_usage.provider.functions)
        assert.same({functions = {}, methods = {}},
            tree._binary_usage.provider.records.Box)
    end)
end)

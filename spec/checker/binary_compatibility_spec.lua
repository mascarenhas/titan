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

    it("treats contextual record construction as a new reference", function()
        local tree = check({
            provider = [[record Item number: integer end]],
            consumer = [[
                local p = import "provider"
                function make(): p.Item return {number = 42} end
            ]],
        })
        assert.is_true(tree._binary_usage.provider.records.Item.functions.new)
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

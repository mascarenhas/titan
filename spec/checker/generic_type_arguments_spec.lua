local h = require "spec.support.helpers"

local function accepted(source)
    local ok, message = h.run_checker(source)
    assert.truthy(ok, message)
end

local function rejected(source)
    local ok, message = h.run_checker(source)
    assert.falsy(ok, "unexpectedly accepted source")
    assert.match("direct call", message)
end

describe("explicit type-argument expression candidates", function()
    it("rejects explicitly specialized generic function values", function()
        rejected([[
            function identity<|T|>(item: T): T return item end
            function use()
                local f: function(integer): integer = identity<|string|>
            end
        ]])
    end)

    it("rejects explicit bound-method specializations without ignoring arguments", function()
        rejected([[
            record Box item: integer end
            function Box:choose<|T|>(item: T): T return item end
            function use(box: Box)
                local f: function(integer): integer = box:choose<|string|>
            end
        ]])
    end)

    it("rejects type arguments on ordinary variables and nongeneric method values", function()
        rejected([[
            function use(n: integer): integer return n<|integer|> end
        ]])
        rejected([[
            function ordinary(n: integer): integer return n end
            function use() local f = ordinary<|integer|> end
        ]])
        rejected([[
            record Box item: integer end
            function Box:get(): integer return self.item end
            function use(box: Box) local f = box:get<|integer|> end
        ]])
    end)

    it("retains the direct-call-only rule for explicitly applied nominal statics", function()
        rejected([[
            record Box<|T|> item: T end
            function use() local f = Box<|integer|>.new end
        ]])
        rejected([[
            record Box item: integer end
            function Box.identity<|T|>(item: T): T return item end
            function use() local f = Box.identity<|integer|> end
        ]])
    end)

    it("preserves contextual inference for unapplied generic values and direct calls", function()
        accepted([[
            function identity<|T|>(item: T): T return item end
            record Box item: integer end
            function Box:choose<|T|>(item: T): T return item end
            function use(box: Box): integer
                local f: function(integer): integer = identity
                local bound: function(integer): integer = box:choose
                return f(bound(identity<|integer|>(box:choose<|integer|>(42))))
            end
        ]])
    end)

    it("preserves owner and member binder rules in bare record calls", function()
        accepted([[
            record Box<|T|> item: T end
            function Box.new<|U|>(item: T, note: U): (Box<|T|>, U)
                return { item = item }, note
            end
            type Alias = Box
            type IntegerBox = Box<|integer|>
            record Plain<|T|> item: T end
            function identity<|T|>(item: T): T return item end
            function use(): integer
                local inferred, flag = Box(1, true)
                local applied = Plain<|integer|>(2)
                local explicit, other = Box<|integer|>.new<|string|>(3, "explicit")
                local alias, alias_note = Alias { note = "alias", item = 4 }
                local fixed, fixed_note = IntegerBox(5, "fixed")
                local nested = identity(Box(6, "nested"))
                return inferred.item + applied.item + explicit.item + alias.item
                    + fixed.item + nested.item + #other + #alias_note
                    + #fixed_note
            end
        ]])
        local ok, message = h.run_checker([[
            record Box<|T|> item: T end
            function Box.new<|U|>(item: T, note: U): Box<|T|>
                return { item = item }
            end
            function use(): Box<|integer|> return Box<|integer|>(1, "note") end
        ]])
        assert.falsy(ok)
        assert.match("must provide both the owner and callable type argument lists", message)
    end)

    it("keeps explicit constructor-member arguments after the new selector", function()
        accepted([[
            record Echo ignored: integer end
            function Echo.new<|T|>(item: T): T return item end
            function use(): integer return Echo.new<|integer|>(42) end
        ]])
        local ok, message = h.run_checker([[
            record Echo ignored: integer end
            function Echo.new<|T|>(item: T): T return item end
            function use(): integer return Echo<|integer|>(42) end
        ]])
        assert.falsy(ok)
        assert.match("type argument", message)
    end)

    it("calls reexported generic record aliases through compiled and source interfaces", function()
        for _, view in ipairs({ "source", "compiled" }) do
            local ok, message = h.run_checker_modules({
                provider = [[
                    record Box<|T|> local item: T end
                    function Box.new(seed: T): Box<|T|> return { item = seed } end
                    function Box:get(): T return self.item end
                ]],
                facade = [[
                    local p = import "provider"
                    type Alias = p.Box
                    type Fixed = p.Box<|integer|>
                ]],
                consumer = [[
                    local f = import "facade"
                    function use(): integer
                        local a = f.Alias<|integer|> { seed = 1 }
                        local b = f.Fixed(2)
                        local c = f.Alias(3)
                        return a:get() + b:get() + c:get()
                    end
                ]],
            }, "consumer", { interface = view })
            assert.truthy(ok, message)
        end
    end)
end)

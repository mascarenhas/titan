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
end)

local maybe3 = require "titan-compiler.maybe3"

describe("explicit computed optional state", function()
    it("distinguishes uncomputed, absent, and present results", function()
        local unknown = maybe3.unknown()
        local absent = maybe3.none()
        local value = {}
        local present = maybe3.just(value)
        assert.same({tag = "unknown"}, unknown)
        assert.same({tag = "none"}, absent)
        assert.is_true(maybe3.validate(unknown))
        assert.is_true(maybe3.validate(absent))
        assert.has_error(function()
            maybe3.get_checked(unknown, "field lookup")
        end, "field lookup has not been computed")
        assert.is_nil(maybe3.get_checked(absent))
        assert.is_true(value == maybe3.get_checked(present))
        assert.is_false(unknown == maybe3.unknown())
        assert.is_false(absent == maybe3.none())
    end)

    it("preserves a present false and dense plan positions", function()
        local states = {
            maybe3.from_optional(nil),
            maybe3.from_optional(false),
            maybe3.from_optional("result"),
        }
        assert.equal(3, #states)
        assert.equal("none", states[1].tag)
        assert.equal("just", states[2].tag)
        assert.is_false(maybe3.get_checked(states[2]))
        assert.equal("result", maybe3.get_checked(states[3]))
    end)

    it("rejects missing payloads, extra fields, and forged state", function()
        local malformed = {
            false, true, "none", {}, {tag = "other"}, {tag = "just"},
            {tag = "none", value = false}, {tag = "unknown", value = 1},
            {tag = "just", value = 1, extra = true},
            setmetatable({tag = "none"}, {}),
        }
        for _, state in ipairs(malformed) do
            assert.is_false(maybe3.validate(state))
            assert.has_error(function()
                maybe3.get_checked(state, "field lookup")
            end, "field lookup has an invalid Maybe3 state")
        end
        assert.is_false(maybe3.validate(nil))
        assert.has_error(function() maybe3.just(nil) end,
            "Maybe3.just requires a value")
    end)
end)

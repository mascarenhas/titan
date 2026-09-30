local h = require "spec.support.helpers"

describe("optional AST metadata (typechecker)", function()
    it("finishes callable and expression analyses with explicit states", function()
        local ok, err, tree = h.run_checker([[
            local count = 0
            function f(x: value): boolean
                local converted = x as integer
                local predicate = x is integer
                local incremented = converted + 1
                return incremented == count
            end
        ]])
        assert.is_true(ok, err)
        assert.equal("just", tree[1]._lua_write_dynamic_plan.tag)
        local declaration = tree[2]
        assert.same({tag="none"}, declaration._lua_vararg_dynamic_plan)
        assert.same({tag="none"}, declaration._strict_vararg_guard_plan)
        assert.equal(1, #declaration._lua_dynamic_plans)
        assert.equal("just", declaration._lua_dynamic_plans[1].tag)
        assert.equal("value", declaration._lua_dynamic_plans[1].value.op)
        local stats = declaration.block.stats
        assert.equal("just", stats[1].exps[1]._written_cast.tag)
        assert.equal("just", stats[2].exps[1]._written_cast.tag)
        assert.same({tag="none"}, stats[3].exps[1]._comparison)
        assert.equal("just", stats[4].exps[1]._comparison.tag)
    end)

    it("keeps omitted spread bounds nil after checking", function()
        local ok, err, tree = h.run_checker([[
            function first(items: {integer}): integer?
                local unbounded: integer? = ...items
                local lower: integer? = ...items[2,]
                local upper: integer? = ...items[,2]
                return unbounded
            end
        ]])
        assert.is_true(ok, err)
        local stats = tree[1].block.stats
        local unbounded = stats[1].exps[1]
        assert.equal("Ast.ExpSpread", unbounded._tag)
        assert.is_nil(unbounded.first)
        assert.is_nil(unbounded.last)
        assert.equal("just", unbounded._spread_optional_guard.tag)
        assert.equal("just", unbounded._spread_open_guard.tag)
        local lower = stats[2].exps[1]
        assert.equal("Ast.ExpInteger", lower.first._tag)
        assert.is_nil(lower.last)
        local upper = stats[3].exps[1]
        assert.is_nil(upper.first)
        assert.equal("Ast.ExpInteger", upper.last._tag)
    end)
end)

-- Keep completed, unavailable boundary policies distinct from missing or
-- unfinished analysis. These checks generate C without compiling native code.
local assert = require "luassert"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"
local maybe3 = require "titan-compiler.maybe3"

local MODULE = "optional_metadata"

local function checked(source)
    h.reset(true)
    local tree, parse_error = h.parse(source, MODULE .. ".titan")
    assert.truthy(tree, parse_error)
    local _, errors = checker.check(
        MODULE, tree, source, MODULE .. ".titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return tree
end

local function generate(tree)
    return coder.generate(MODULE, tree, {}, driver.TITAN_ABI_VERSION)
end

local variadic = {
    name = "variadic input",
    source = [[local function accept(...: {foreign *void}) end]],
    node = function(tree) return tree[1] end,
    fields = { "_lua_vararg_dynamic_plan", "_strict_vararg_guard_plan" },
}

local flexible = {
    name = "flexible result",
    source = [[
        local function relay(
            f: function (): (...: {foreign *void})
        ): (...: {foreign *void})
            return f()
        end
    ]],
    node = function(tree) return tree[1].block.stats[1].exps[1] end,
    fields = {
        "_lua_open_result_dynamic_plan", "_strict_open_result_guard_plan",
    },
}

local spread = {
    name = "spread read",
    source = [[
        function first(values: {integer}): integer?
            local item: integer? = ...values
            return item
        end
    ]],
    node = function(tree)
        return tree[1].block.stats[1]._result_adjustment.exps[1]
    end,
    fields = { "_spread_optional_guard", "_spread_open_guard" },
}

describe("explicit optional coder metadata", function()
    after_each(function() h.reset(true) end)

    for _, fixture in ipairs {
        { kind = "record", source = [[record Item value: integer end]] },
        { kind = "union", source = [[union Choice selected(integer) end]] },
    } do
        it("rejects a missing required " .. fixture.kind .. " receiver plan",
        function()
            local tree = checked(fixture.source)
            assert.is_table(tree[1]._dynamic_receiver_plan)
            tree[1]._dynamic_receiver_plan = nil
            local ok, err = pcall(generate, tree)
            assert.is_false(ok)
            assert.matches(fixture.kind ..
                " receiver lacks its Lua boundary plan", tostring(err))
        end)
    end

    for _, fixture in ipairs { variadic, flexible } do
        it("emits unavailable boundary errors for checked-none " .. fixture.name,
        function()
            local tree = checked(fixture.source)
            local node = fixture.node(tree)
            for _, field in ipairs(fixture.fields) do
                assert.same({ tag = "none" }, node[field])
            end
            local code = generate(tree)
            assert.is_truthy(code:find(
                "dynamic coercion to %s is unavailable", 1, true))
            assert.is_truthy(code:find(
                "strict observation of %s is unavailable", 1, true))
        end)
    end

    it("retains checked spread guards and nil omitted bounds", function()
        local tree = checked(spread.source)
        local node = spread.node(tree)
        assert.equal("Ast.ExpSpread", node._tag)
        assert.is_nil(node.first)
        assert.is_nil(node.last)
        for _, field in ipairs(spread.fields) do
            assert.equal("just", node[field].tag)
        end
        assert.is_string(generate(tree))
    end)

    for _, fixture in ipairs { variadic, flexible, spread } do
        for _, field in ipairs(fixture.fields) do
            it("rejects missing and unknown " .. fixture.name .. " " .. field,
            function()
                local tree = checked(fixture.source)
                fixture.node(tree)[field] = nil
                local ok, err = pcall(generate, tree)
                assert.is_false(ok)
                assert.matches("has an invalid Maybe3 state", tostring(err))

                tree = checked(fixture.source)
                fixture.node(tree)[field] = maybe3.unknown()
                ok, err = pcall(generate, tree)
                assert.is_false(ok)
                assert.matches("has not been computed", tostring(err))
            end)
        end
    end
end)

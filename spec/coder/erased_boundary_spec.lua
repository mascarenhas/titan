local assert = require "luassert"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local staticmetadata = require "titan-compiler.staticmetadata"
local types = require "titan-compiler.types"
local h = require "spec.support.helpers"

local MODULE = "erased_boundary"
local SOURCE = [[
function id(x: value): value
    return x
end
]]

local function checked()
    h.reset(true)
    local tree, parse_error = h.parse(SOURCE, MODULE .. ".titan")
    assert.truthy(tree, parse_error)
    local _, errors = checker.check(
        MODULE, tree, SOURCE, MODULE .. ".titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return tree
end

local function generate(tree)
    return coder.generate(MODULE, tree, {}, driver.TITAN_VER)
end

local function generate_and_capture_metadata(tree)
    local original = staticmetadata.render
    local serialized
    staticmetadata.render = function(modname, abi, serialized_types)
        serialized = serialized_types
        return original(modname, abi, serialized_types)
    end
    local results = table.pack(xpcall(function()
        return generate(tree)
    end, debug.traceback))
    staticmetadata.render = original
    if not results[1] then error(results[2], 0) end
    return results[2], serialized
end

local function generic_scope(role, declaration_kind, owner)
    return types.GenericScope(
        MODULE, owner or false, role == "function" and "id" or false,
        role, declaration_kind)
end

local function assert_rejected(tree, pattern)
    local ok, err = pcall(generate, tree)
    assert.is_false(ok)
    assert.matches(pattern, tostring(err))
end

describe("erased coder boundary", function()
    after_each(function()
        h.reset(true)
    end)

    it("preserves ordinary metadata behavior and handles checked AST cycles",
    function()
        local tree = checked()
        local expected = types.serialize(tree._type)
        -- Checked declarations already point back into the tree. Keep an
        -- explicit root cycle too so this test cannot accidentally become an
        -- acyclic hand-built fixture.
        tree._boundary_cycle = tree

        local source, serialized = generate_and_capture_metadata(tree)
        assert.is_string(source)
        assert.is_true(#source > 0)
        assert.equal(expected, serialized)
    end)

    it("ignores private generic and named-argument source metadata", function()
        h.reset(true)
        local source = [[
            record Box<T>
                item: T
            end
            function choose<T>(first: T, second: T): T
                return first
            end
            function Box:get(): T return self.item end
            function run(): integer
                local box: Box<integer> = { item = 1 }
                local item = box:get()
                return choose { second = box.item, first = 2 }
            end
        ]]
        local tree, parse_error = h.parse(source, MODULE .. ".titan")
        assert.truthy(tree, parse_error)
        local _, errors = checker.check(
            MODULE, tree, source, MODULE .. ".titan")
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.truthy(tree[1]._surface_typeparams)
        assert.equal("Type.Integer",
            tree[#tree].block.stats[1].decls[1].type
                ._surface_typeargs[1]._resolved_typearg._tag)
        assert.equal("Type.Integer",
            tree[#tree].block.stats[2].exps[1].exp.args
                ._declared_method.rettypes[1]._tag)
        assert.truthy(
            tree[#tree].block.stats[3].exps[1].exp._surface_named_args)
        assert.is_string(generate(tree))
    end)

    it("serializes the detached declared graph while coding the erased one",
    function()
        local tree = checked()
        local scope = generic_scope("function", "function")
        local parameter = types.Parameter(scope, 1, "T", false)
        local declared = types.Module(MODULE, {
            types.ModuleMember(MODULE, "id",
                types.FunctionScheme(scope, {
                    types.TypeParameter("T", false),
                }, types.Function({ parameter }, { parameter },
                    false, false, false)),
                { "x" }),
        })
        local erased_serialized = types.serialize(tree._type)
        local declared_serialized = types.serialize(declared)
        assert.not_equal(erased_serialized, declared_serialized)
        assert.not_equal(tree._type, declared)
        tree._declared_type = declared

        local source, serialized = generate_and_capture_metadata(tree)
        assert.is_string(source)
        assert.equal(declared_serialized, serialized)
        assert.equal(declared_serialized,
            types.serialize(tree._declared_type))
    end)

    it("rejects generic type forms in code-facing annotations", function()
        local tree = checked()
        local scope = generic_scope("function", "function")
        tree[1].params[1]._type =
            types.Parameter(scope, 1, "T", false)
        assert_rejected(tree,
            "generic type form Type%.Parameter.-code%-facing AST")

        tree = checked()
        tree[1].params[1]._type = types.Nominal(
            MODULE .. ".Box", { types.Integer() })
        assert_rejected(tree,
            "generic type form Type%.Nominal.-code%-facing AST")
    end)

    it("rejects generic AST lists before code generation", function()
        local tree = checked()
        tree[1].typeparams = {
            { _tag = "Ast.TypeParam", name = "T", constraint = false },
        }
        assert_rejected(tree,
            "generic AST field 'typeparams'.-code%-facing AST")

        tree = checked()
        tree[1].params[1]._nominal_typeargs = {
            { _tag = "Ast.TypeInteger" },
        }
        assert_rejected(tree,
            "generic AST field '_nominal_typeargs'.-code%-facing AST")
    end)

    it("rejects checker-only inference cells", function()
        local tree = checked()
        tree[1].params[1]._type = {
            _tag = "Checker.InferenceCell",
            binding = types.Integer(),
        }
        assert_rejected(tree,
            "generic inference form Checker%.InferenceCell.-code%-facing AST")
    end)

    it("rejects generic descriptors in the active erased registry", function()
        local tree = checked()
        local owner = MODULE .. ".Box"
        local scope = generic_scope("owner", "record", owner)
        tree._erased_registry[owner] = types.Record(
            owner, {}, {}, {}, 0, scope,
            { types.TypeParameter("T", false) })
        assert_rejected(tree,
            "generic type form Type%.Record.-active type registry")
    end)
end)

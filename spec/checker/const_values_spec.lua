local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules
local check_errs = h.check_errs

local function find_function(ast, name)
    for _, node in ipairs(ast) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("function not found: " .. name)
end

local function only_return_expression(fn)
    for _, stat in ipairs(fn.block.stats) do
        if stat._tag == "Ast.StatReturn" then
            assert.equal(1, #stat.exps)
            return stat.exps[1]
        end
    end
    error("return statement not found")
end

describe("const values (typechecker)", function()
    it("nil-initializes explicitly nil-bearing mutable locals", function()
        local ok, err, ast = run_checker([[
            function read(): integer?
                local pending: integer?
                return pending
            end


            function read_many(): (integer?, string?)
                local first: integer?, second: string?
                return first, second
            end
        ]])
        assert.truthy(ok, err)

        local declstat = find_function(ast, "read").block.stats[1]
        assert.equal(1, #declstat.exps)
        assert.equal("Ast.ExpCast", declstat.exps[1]._tag)
        assert.equal("Ast.ExpNil", declstat.exps[1].exp._tag)
        assert.same(types.Option(types.Integer()),
            declstat.decls[1]._type)
        assert.same(declstat.decls[1]._type,
            declstat.exps[1]._type)

        local many = find_function(ast, "read_many").block.stats[1]
        assert.equal(2, #many.exps)
        assert.equal("Ast.ExpNil", many.exps[1].exp._tag)
        assert.equal("Ast.ExpNil", many.exps[2].exp._tag)
    end)

    it("requires an explicit genuinely nil-bearing omitted local type",
    function()
        local errs = check_errs([[
            function bad(): nil
                local inferred
                local integer_value: integer
                local boolean_value: boolean
                return nil
            end
        ]])
        assert.equal(3, #errs)
        assert.match("without an initializer requires an explicit type",
            errs[1])
        assert.match("type 'integer' does not accept nil", errs[2])
        assert.match("type 'boolean' does not accept nil", errs[3])
    end)

    it("marks every binding in a const local declaration read-only",
    function()
        local errs = check_errs([[
            function bad(): nil
                const first, second = 1, 2
                first, second = 3, 4
                return nil
            end
        ]])
        assert.equal(2, #errs)
        assert.match("cannot assign to const local 'first'", errs[1])
        assert.match("cannot assign to const local 'second'", errs[2])

        errs = check_errs([[
            function bad_capture(): nil
                const answer = 42
                local overwrite = function(): nil
                    answer = 0
                    return nil
                end
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("cannot assign to const local 'answer'", errs[1])

        local ok, err = run_checker([[
            function good(): integer
                local const answer = 42
                return answer
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("resolves const shadow initializers against the outer binding",
    function()
        local ok, err, ast = run_checker([[
            function answer(flag: boolean): integer
                local pending: integer?
                if flag then
                    pending = 42
                else
                    pending = 0
                end
                const answer = pending
                return answer
            end
        ]])
        assert.truthy(ok, err)
        local shadow = find_function(ast, "answer").block.stats[3]
        assert.is_true(shadow.decls[1].isconst)
        assert.same(types.Integer(), shadow.decls[1]._type)
        assert.equal("Ast.ExpCast",
            shadow._result_adjustment.fixed[1]._tag)
    end)

    it("rejects writes to initialized const module variables", function()
        local errs = check_errs([[
            const answer = 42

            function overwrite(): nil
                answer = 0
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("cannot assign to const module variable 'answer'",
            errs[1])

        errs = check_errs([[
            const answer = 42

            do
                answer = 0
            end
        ]])
        assert.equal(1, #errs)
        assert.match("cannot assign to const module variable 'answer'",
            errs[1])
    end)

    it("allows nil-starting const module writes only in its owner initializer",
    function()
        local ok, err = run_checker([[
            const answer: integer?

            do
                answer = 0
                if true then
                    answer = 42
                end
            end
        ]])
        assert.truthy(ok, err)

        local errs = check_errs([[
            const answer: integer?

            function late(): nil
                answer = 42
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("may only be assigned in its module initializer",
            errs[1])

        errs = check_errs([[
            const answer: integer?

            do
                local late = function(): nil
                    answer = 42
                    return nil
                end
            end
        ]])
        assert.equal(1, #errs)
        assert.match("may only be assigned in its module initializer",
            errs[1])
    end)

    it("never grants another module's initializer authority over an import",
    function()
        local ok, err = run_checker_modules({
            owner = [[
                const answer: integer?
            ]],
            consumer = [[
                local owner = import "owner"
                do
                    owner.answer = 42
                end
            ]],
        }, "consumer")
        assert.falsy(ok)
        assert.match("cannot assign to const module variable 'answer'", err)
    end)

    it("rejects replacement of const record fields after construction",
    function()
        local ok, err = run_checker([[
            record Pair
                const first: integer
                local const second?: string
            end

            function make(): Pair
                return Pair.new(1, nil)
            end
        ]])
        assert.truthy(ok, err)

        local errs = check_errs([[
            record Box
                const contents: integer
            end

            function overwrite(box: Box): nil
                box.contents = 2
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("cannot assign to const field 'contents'", errs[1])
    end)

    it("constructs const Arrays contextually and rejects element writes",
    function()
        local ok, err, tree = run_checker([[
            function make(): const { integer }
                return { 10, 20 }
            end
        ]])
        assert.truthy(ok, err)
        local constructor = only_return_expression(find_function(tree, "make"))
        assert.equal("Ast.ExpInitList", constructor._tag)
        assert.same(types.Array(types.Integer(), true), constructor._type)

        local errs = check_errs([[
            function overwrite(items: const { integer }): nil
                items[1] = 99
                return nil
            end
        ]])
        assert.equal(1, #errs)
        assert.match("cannot assign to an element of const Array", errs[1])
    end)

    it("requires the one-way mutable-to-const Array cast", function()
        local ok, err, tree = run_checker([[
            function freeze(items: { integer }): const { integer }
                return items as const { integer }
            end

            function can_freeze(items: { integer }): boolean
                return items is const { integer }
            end
        ]])
        assert.truthy(ok, err)
        local cast = only_return_expression(find_function(tree, "freeze"))
        assert.equal("array_freeze", cast._written_cast.op)
        assert.equal("copy", cast._written_cast.mode)
        local predicate = only_return_expression(
            find_function(tree, "can_freeze"))
        assert.equal("array_freeze", predicate._written_cast.op)
        assert.is_true(predicate._written_cast.allocation_free_test)

        local errs = check_errs([[
            function implicit(items: { integer }): const { integer }
                return items
            end

            function thaw(items: const { integer }): { integer }
                return items as { integer }
            end
        ]])
        assert.equal(2, #errs)
        assert.match("types in return do not match", errs[1])
        assert.match("cannot cast 'const { integer }' to '{ integer }'",
            errs[2])
    end)

    it("elides an Array copy for a proven linear builder", function()
        local ok, err, tree = run_checker([[
            local function increment(input: integer): integer
                return input + 1
            end

            local function observe(items: { integer }): integer
                return #items
            end

            function linear(): const { integer }
                local items = { 1, 2 }
                return items as const { integer }
            end

            function builder(count: integer): const { integer }
                local items: { integer } = {}
                for index = 1, count do
                    items[#items + 1] = increment(index)
                end
                if #items ~= count then
                    raise "builder length mismatch"
                end
                local tail = items[#items]
                if tail ~= count + 1 then
                    raise "builder element mismatch"
                end
                return items as const { integer }
            end

            function unrelated_closure(): const { integer }
                local items = { 1, 2 }
                local answer = function(): integer
                    return 42
                end
                local ignored = answer()
                return items as const { integer }
            end

            function escaped(): const { integer }
                local items = { 1, 2 }
                local alias = items
                return items as const { integer }
            end

            function passed(): const { integer }
                local items = { 1, 2 }
                local length = observe(items)
                return items as const { integer }
            end

            function captured(): const { integer }
                local items = { 1, 2 }
                local length = function(): integer
                    return #items
                end
                return items as const { integer }
            end

            function rebound(): const { integer }
                local items = { 1, 2 }
                items = { 3, 4 }
                return items as const { integer }
            end

            function used_after(): const { integer }
                local items = { 1, 2 }
                const frozen = items as const { integer }
                items[1] = 3
                return frozen
            end
        ]])
        assert.truthy(ok, err)
        local linear = only_return_expression(find_function(tree, "linear"))
        assert.equal("freeze", linear._written_cast.mode)
        assert.is_true(linear._linear_array_freeze)

        local builder = only_return_expression(find_function(tree, "builder"))
        assert.equal("freeze", builder._written_cast.mode)
        assert.is_true(builder._linear_array_freeze)

        local unrelated = only_return_expression(
            find_function(tree, "unrelated_closure"))
        assert.equal("freeze", unrelated._written_cast.mode)
        assert.is_true(unrelated._linear_array_freeze)

        local escaped = only_return_expression(find_function(tree, "escaped"))
        assert.equal("copy", escaped._written_cast.mode)

        local passed = only_return_expression(find_function(tree, "passed"))
        assert.equal("copy", passed._written_cast.mode)

        local captured = only_return_expression(
            find_function(tree, "captured"))
        assert.equal("copy", captured._written_cast.mode)

        local rebound = only_return_expression(find_function(tree, "rebound"))
        assert.equal("copy", rebound._written_cast.mode)

        local used_after = find_function(tree, "used_after").block.stats[2]
        assert.equal("copy", used_after.exps[1]._written_cast.mode)
    end)
end)

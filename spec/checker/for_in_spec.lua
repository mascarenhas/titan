local h = require 'spec.support.helpers'
local types = require 'titan-compiler.types'

local run_checker = h.run_checker

describe("generic for loops (typechecker)", function()
    it("accepts a one-argument iterator with omitted tuple slots", function()
        local ok, err, ast = run_checker([[
            function next_line(_: nil): string?
                return nil
            end

            function run(): nil
                for line: string in next_line do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local loop = ast[2].block.stats[1]
        assert.same("Ast.StatForIn", loop._tag)
        assert.same(types.Function({ types.Nil() },
            { types.Option(types.String()) }, false, false),
            loop._tuple_decls[1]._type)
        assert.same(types.Nil(), loop._tuple_decls[2]._type)
        assert.same(types.Nil(), loop._tuple_decls[3]._type)
        assert.same(types.Nil(), loop._tuple_decls[4]._type)
    end)

    it("accepts state, initial control, and close values", function()
        local ok, err = run_checker([[
            function step(state: string, n: integer): (integer?, string?)
                return nil, nil
            end

            function close(state: string): integer
                return #state
            end

            function run(): nil
                for n: integer, label: string? in step, "ctx", 0, close do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("accepts a trailing variadic spread in the iterator tuple", function()
        local ok, err = run_checker([[
            function step(limit: value, n: value): value
                return nil
            end

            function run(...: value): nil
                for x: value in step, ... do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects a non-function iterator", function()
        local ok, err = run_checker([[
            function run(): nil
                for x in 1 do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for iterator must be a function but found integer", err)
    end)

    it("rejects iterators with no return values", function()
        local ok, err = run_checker([[
            function step(): nil
                return nil
            end

            function run(): nil
                for x in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for iterator control result cannot be nil%-only", err)
    end)

    it("rejects non-nil-capable control results", function()
        local ok, err = run_checker([[
            function step(): integer
                return 1
            end

            function run(): nil
                for x in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for iterator control result must be optional or value but found integer", err)
    end)

    it("rejects too many iterator parameters", function()
        local ok, err = run_checker([[
            function step(a: nil, b: nil, c: nil): integer?
                return nil
            end

            function run(): nil
                for x in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for iterator expects at most 2 parameter%(s%) but found 3", err)
    end)

    it("rejects an omitted state that cannot accept nil", function()
        local ok, err = run_checker([[
            function step(s: string): integer?
                return nil
            end

            function run(): nil
                for x in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("types in generic for iterator state do not match, expected string but found nil", err)
    end)

    it("rejects mismatched visible declaration types", function()
        local ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function run(): nil
                for x: string in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("types in generic for variable x do not match, expected string but found integer", err)
    end)

    it("rejects untyped declarations for missing iterator results", function()
        local ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function run(): nil
                for x: integer, y in step do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot infer type of generic for variable 'y' from a missing iterator result", err)
    end)

    it("rejects invalid close values and signatures", function()
        local ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function run(): nil
                for x in step, nil, nil, 1 do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for close value must be nil or a function but found integer", err)

        ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function close(): nil
                return nil
            end

            function run(): nil
                for x in step, nil, nil, close do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for close function must accept exactly one state argument", err)
    end)

    it("rejects assignment to generic for variables", function()
        local ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function run(): nil
                for x in step do
                    x = 1
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("cannot assign to 'for' control variable 'x'", err)
    end)
end)

local h = require 'spec.support.helpers'
local types = require 'titan-compiler.types'

local run_checker = h.run_checker

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local f = assert(io.open(header, "w"))
    f:write(contents)
    f:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

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
        local iterator = loop._tuple_decls[1]._type
        assert.same("Type.Function", iterator._tag)
        assert.same({ types.Nil() }, iterator.params)
        assert.same({ types.Option(types.String()) }, iterator.rettypes)
        assert.is_false(iterator.vararg)
        assert.is_false(iterator.varargtype)
        assert.is_false(iterator.flexrettype)
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

    it("accepts zero-parameter close functions", function()
        local ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function close(): nil
                return nil
            end

            function run(): nil
                for n: integer in step, nil, nil, close do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("accepts computed record fields in iterator and close slots", function()
        local ok, err = run_checker([[
            record H
                iter: (value, value) -> integer?
                close: (value) -> nil
            end
            function hs(): {H} return {} end

            function run()
                for n: integer in
                        hs()[1].iter, nil, nil, hs()[1].close do
                end
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("checks computed iterator and close eligibility exactly once", function()
        local prelude = [[
            record H
                iter: (value, value) -> integer?
                close: (value) -> nil
            end
            function hs(): {H} return {} end
            function funcs(): {(value, value) -> integer?} return {} end
            function step(state: value, control: value): integer?
                return nil
            end
        ]]
        local cases = {
            {
                name = "bracket iterator",
                loop = [=[funcs()["bad"]]=],
            },
            {
                name = "field iterator",
                loop = [[hs()["bad"].iter]],
            },
            {
                name = "close",
                loop = [[step, nil, nil, hs()["bad"].close]],
            },
        }
        for _, case in ipairs(cases) do
            local source = prelude .. ([=[
                function run()
                    for n: integer in %s do end
                end
            ]=]):format(case.loop)
            local result = table.pack(pcall(h.check_errs, source))
            assert.truthy(result[1], result[2])
            local errors = result[2]
            assert.equal(1, #errors, case.name)
            assert.truthy(errors[1]:find(
                "types in array indexing do not match", 1, true),
                case.name .. ": " .. errors[1])
        end
    end)

    it("projects a flex-only iterator result for the control variable", function()
        local ok, err, tree = run_checker([[
            function step(): (...: integer)
            end

            function run(): nil
                for n: integer in step do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local loop = tree[2].block.stats[1]
        assert.same(types.Option(types.Integer()),
            loop._result_decls[1]._type)
        assert.same({}, loop._init_call._types)
        assert.same({ types.Option(types.Integer()) },
            loop._init_call._visible_types)
        assert.same(1, loop._init_call._flex_result_demand)
        assert.same("flex", loop._init_call._result_sources[1].kind)
    end)

    it("uses fixed results before finite flexible projections", function()
        local ok, err, tree = run_checker([[
            function step(): (integer?, ...: string)
                return nil
            end

            function run(): nil
                for n: integer, a: string?, b: string in step do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local loop = tree[2].block.stats[1]
        assert.same(types.Option(types.Integer()),
            loop._result_decls[1]._type)
        assert.same(types.Option(types.String()),
            loop._result_decls[2]._type)
        assert.same(types.Option(types.String()),
            loop._result_decls[3]._type)
        assert.same(2, loop._next_call._flex_result_demand)
        assert.same("fixed", loop._next_call._result_sources[1].kind)
        assert.same("flex", loop._next_call._result_sources[2].kind)
    end)

    it("truncates surplus iterator-tuple values but retains their expressions", function()
        local ok, err, tree = run_checker([[
            function step(): integer?
                return nil
            end

            function run(): nil
                for n: integer in step, nil, nil, nil, 99 do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local loop = tree[2].block.stats[1]
        assert.same(5, #loop._tuple_adjustment.exps)
        assert.same(1, #loop._tuple_adjustment.discards)
        assert.truthy(loop._tuple_adjustment.exps[5]._discard_results)
        assert.same(4, #loop.exps)
    end)

    it("discards every close-call result", function()
        local ok, err, tree = run_checker([[
            function step(): integer?
                return nil
            end

            function close(): (integer, ...: string)
                return 1
            end

            function run(): nil
                for n: integer in step, nil, nil, close do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local closecall = tree[3].block.stats[1]._close_call
        assert.same({ types.Integer() }, closecall._types)
        assert.same({}, closecall._visible_types)
        assert.same(0, closecall._flex_result_demand)
        assert.falsy(closecall._open_results)
    end)

    it("accepts 200 projected flex results and rejects 201 once", function()
        local function source(n)
            local decls = {}
            for i = 1, n do
                decls[i] = "n" .. i
            end
            return [[
                function step(): (...: integer)
                end
                function run(): nil
                    for ]] .. table.concat(decls, ", ") .. [[ in step do
                    end
                    return nil
                end
            ]]
        end

        local ok, err = run_checker(source(200))
        assert.truthy(ok, err)
        local errs = h.check_errs(source(201))
        assert.same(1, #errs)
        assert.match("finite flexible%-result demand is 201 value%(s%), maximum is 200",
            errs[1])
    end)

    it("coerces value iterator and close slots to synthesized function types", function()
        local ok, err, ast = run_checker([[
            function run(nextv: value, closev: value): nil
                for n: integer, label: string in nextv, nil, nil, closev do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local loop = ast[1].block.stats[1]
        assert.same(types.Function({},
            { types.Option(types.Integer()), types.String() }, false, false,
            false),
            loop._tuple_decls[1]._type)
        assert.same(types.Function({}, {}, false, false, false),
            loop._tuple_decls[4]._type)
        assert.is_true(loop._runtime_optional_close)
        assert.is_true(loop._has_close)
    end)

    it("contextualizes a value factory and preserves its optional close slot",
    function()
        local ok, err, ast = run_checker([[
            function run(factory: value): nil
                for n: integer, label: string? in factory(7, "ctx") do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local loop = ast[1].block.stats[1]
        local factory_call = loop._tuple_adjustment.exps[1].exp
        assert.same("Ast.ExpCall", factory_call._tag)
        assert.same(types.Function(
            { types.Integer(), types.String() },
            { types.Value(), types.Value(), types.Value(), types.Value() },
            false, false, false), factory_call._contextual_function_type)
        assert.same(types.Function({ types.Value(), types.Value() },
            { types.Option(types.Integer()), types.Option(types.String()) },
            false, false, false), loop._tuple_decls[1]._type)
        assert.same(types.Function({ types.Value() }, {}, false, false, false),
            loop._tuple_decls[4]._type)
        assert.is_true(loop._runtime_optional_close)
        assert.is_true(loop._has_close)
    end)

    it("coerces value iterators using state and initial control types", function()
        local ok, err, ast = run_checker([[
            function run(nextv: value): nil
                for n: integer in nextv, "ctx", 0 do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local loop = ast[1].block.stats[1]
        assert.same(types.Function({ types.String(), types.Integer() },
            { types.Option(types.Integer()) }, false, false, false),
            loop._tuple_decls[1]._type)
    end)

    it("accepts C function pointers and foreign functions as iterator and close values", function()
        with_header([[
            typedef int ffi_int;
            typedef ffi_int *ffi_int_ptr;
            static ffi_int_ptr ffi_next(void) { return 0; }
            static void ffi_close(void) {}
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function run(): nil
                    for p: c.ffi_int_ptr in c.ffi_next, nil, nil, c.ffi_close do
                    end
                    return nil
                end
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("accepts a trailing variadic spread in the iterator tuple", function()
        local ok, err, tree = run_checker([[
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
        local loop = tree[2].block.stats[1]
        assert.same("Ast.ExpDotsIndex", loop.exps[2]._tag)
        assert.same(1, loop.exps[2]._dots_index)
        assert.is_true(loop.exps[2]._nilfill)
        assert.same("Ast.ExpDotsIndex", loop.exps[3]._tag)
        assert.same(2, loop.exps[3]._dots_index)
        assert.is_true(loop.exps[3]._nilfill)
        assert.same("Ast.ExpNil", loop.exps[4]._tag)
    end)

    it("can project a typed close callable from a trailing spread", function()
        local ok, err, tree = run_checker([[
            function step(_: nil, n: integer): integer?
                return nil
            end

            function close(_: nil): nil
                return nil
            end

            function run(...: (nil) -> nil): nil
                for x: integer in step, nil, 0, ... do
                end
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local loop = tree[3].block.stats[1]
        assert.same("Ast.ExpDotsIndex", loop.exps[4]._tag)
        assert.is_false(loop.exps[4]._nilfill)
        assert.same("Type.Function", loop.exps[4]._type._tag)
        assert.is_truthy(loop._has_close)
        assert.is_false(loop._runtime_optional_close)
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
        assert.match("generic for iterator must be a function, value, or C function pointer but found integer", err)
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
        assert.match("generic for iterator control result must be optional, value, or a nullable C pointer but found integer", err)
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
        assert.match("generic for close value must be nil, a function, value, or C function pointer but found integer", err)

        ok, err = run_checker([[
            function step(): integer?
                return nil
            end

            function close(_: nil, _: nil): nil
                return nil
            end

            function run(): nil
                for x in step, nil, nil, close do
                end
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("generic for close function must accept zero or one state argument", err)
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

    it("bounds synthetic iterator calls at Lua's 250-result limit", function()
        local function source(n)
            local nfixed = n - 200
            local rettypes, returns, decls = {}, {}, {}
            for i = 1, nfixed do
                rettypes[i] = "integer?"
                returns[i] = "nil"
            end
            for i = 1, n do
                decls[i] = "v" .. i .. ": integer?"
            end
            return [[
                function step(): (]] .. table.concat(rettypes, ", ")
                    .. [[, ...: integer?)
                    return ]] .. table.concat(returns, ", ") .. [[
                end

                function run(): nil
                    for ]] .. table.concat(decls, ", ") .. [[ in step do
                        break
                    end
                    return nil
                end
            ]]
        end

        local ok, err = run_checker(source(250))
        assert.truthy(ok, err)

        local errs = h.check_errs(source(251))
        assert.same(1, #errs)
        assert.match("function%-value call can require 251 finite VM results",
            errs[1])
        assert.match("Lua 5%.5 supports at most 250", errs[1])
    end)
end)

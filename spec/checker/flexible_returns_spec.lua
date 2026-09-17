local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker

local function find_function(tree, name)
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("function not found: " .. name)
end

local function underlying_call(exp)
    while exp._tag == "Ast.ExpCast" do exp = exp.exp end
    assert.same("Ast.ExpCall", exp._tag)
    return exp
end

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    file:write(contents)
    file:close()
    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    table.remove(results, 1)
    return table.unpack(results)
end

describe("flexible return expression-list demand (typechecker)", function()
    it("projects a flexible tail into finite declaration slots", function()
        local ok, err, tree = run_checker([[
            function values(): (integer, ...: string)
                return 1
            end

            function use(): nil
                local n: integer, safe: string?, forced: string = values()
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local stat = tree[2].block.stats[1]
        local call = stat._result_adjustment.fixed[1]
        assert.same({ types.Integer() }, call._types)
        assert.same({ types.Integer(), types.Option(types.String()),
            types.Option(types.String()) }, call._visible_types)
        assert.same(2, call._finite_flex_prefix)
        assert.same(2, call._flex_result_demand)
        assert.same("fixed", call._result_sources[1].kind)
        assert.same("flex", call._result_sources[2].kind)
        assert.truthy(call._result_sources[2].may_absent)

        local safe = stat._result_adjustment.fixed[2]
        assert.truthy(safe._from_flex)
        assert.truthy(safe._possibly_absent)
        local forced = stat._result_adjustment.fixed[3]
        assert.same("Ast.ExpCast", forced._tag)
        assert.truthy(forced.exp._from_flex)
    end)

    it("normalizes finite value-tail projections to value", function()
        local ok, err, tree = run_checker([[
            function values(): (...: value)
            end

            function use(): nil
                local x: value = values()
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[1]
        local call = stat._result_adjustment.fixed[1]
        assert.same(types.Value(), call._visible_types[1])
        assert.same(types.Value(), call._type)
        assert.truthy(call._result_sources[1].may_absent)
    end)

    it("reports one mismatch for an incompatible finite flex projection", function()
        local errs = h.check_errs([[
            function values(): (...: string)
            end

            function use(): nil
                local x: integer? = values()
                return nil
            end
        ]])
        assert.same(1, #errs)
        assert.match("declaration of local variable x", errs[1])
        assert.match("integer%?", errs[1])
        assert.match("string%?", errs[1])
    end)

    it("truncates producer surplus while preserving declared ABI results", function()
        local ok, err, tree = run_checker([[
            function pair(): (integer, string)
                return 1, "x"
            end

            function use(): nil
                local n: integer = pair()
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local call = tree[2].block.stats[1]._result_adjustment.fixed[1]
        assert.same({ types.Integer(), types.String() }, call._types)
        assert.same({ types.Integer() }, call._visible_types)
    end)

    it("retains explicit surplus declaration expressions for effects", function()
        local ok, err, tree = run_checker([[
            function effect(): ()
            end

            function use(): nil
                local n: integer = 1, effect()
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[1]
        assert.same(2, #stat.exps)
        assert.same(1, #stat._result_adjustment.discards)
        local discarded = stat.exps[2]
        assert.same("Ast.ExpCall", discarded._tag)
        assert.truthy(discarded._discard_results)
        assert.truthy(discarded._voidok)
        assert.same({}, discarded._visible_types)
    end)

    it("uses the same finite projection for assignment", function()
        local ok, err, tree = run_checker([[
            function values(): (...: integer)
            end

            function use(): nil
                local a: integer? = nil
                local b: integer = 0
                a, b = values()
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[3]
        local call = stat._result_adjustment.fixed[1]
        assert.same({ types.Option(types.Integer()),
            types.Option(types.Integer()) }, call._visible_types)
        assert.same(2, call._flex_result_demand)
        assert.same("Ast.ExpCast", stat._result_adjustment.fixed[2]._tag)
    end)

    it("still diagnoses a finite result deficit", function()
        local ok, err = run_checker([[
            function one(): integer
                return 1
            end

            function use(): nil
                local a: integer, b: integer = one()
                return nil
            end
        ]])
        assert.falsy(ok)
        assert.match("left%-hand side expects 2 value%(s%) but the expression list produces 1", err)
    end)

    it("retains but does not pass surplus positional Titan arguments", function()
        local ok, err, tree = run_checker([[
            function take(n: integer): nil
                return nil
            end

            function use(): nil
                take(1, 2, 3)
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local call = tree[2].block.stats[1].callexp
        assert.same(3, #call.args.args)
        assert.same(1, call._npassed_args)
        assert.same(2, #call._arg_adjustment.discards)
        assert.truthy(call.args.args[2]._discard_results)
        assert.truthy(call.args.args[3]._discard_results)
    end)

    it("feeds a flexible producer into a variadic argument tail", function()
        local ok, err, tree = run_checker([[
            function values(): (integer, ...: integer)
                return 1
            end

            function take(head: integer, ...: integer): nil
                return nil
            end

            function use(): nil
                take(values())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local call = tree[3].block.stats[1].callexp
        local inner = call._arg_adjustment.fixed[1]
        assert.same("open", inner._flex_result_demand)
        assert.truthy(inner._open_results)
        assert.same(1, inner._open_results.start)
        assert.same(inner, call._arg_adjustment.open_source)
        assert.same(types.Integer(), call._arg_adjustment.open_type)
        assert.same(types.Integer(), call._arg_adjustment.open_target)
        assert.same(1, call._npassed_args)
    end)

    it("preserves scalar tail elements before the final open producer", function()
        local ok, err, tree = run_checker([[
            function values(): (integer, ...: integer)
                return 2
            end

            function take(head: boolean, ...: integer): nil
                return nil
            end

            function use(): {integer}
                take(true, 1, values())
                local xs: {integer} = { 1, values() }
                return xs
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local call_adjustment = stats[1].callexp._arg_adjustment
        local array = stats[2]._result_adjustment.fixed[1]
        local array_adjustment = array._positional_adjustment

        assert.same(1, #call_adjustment.fixed)
        assert.same(2, #call_adjustment.tail_scalars)
        assert.same(3, #call_adjustment.exps)
        assert.same(call_adjustment.tail_scalars[2],
            call_adjustment.open_source)
        assert.same(1, call_adjustment.open_start)

        assert.same(2, #array_adjustment.tail_scalars)
        assert.same(2, #array_adjustment.exps)
        assert.same(array_adjustment.tail_scalars[2],
            array_adjustment.open_source)
        assert.same(1, array_adjustment.open_start)
        assert.same("open", array_adjustment.open_source._flex_result_demand)
    end)

    it("accepts a flex-only producer in an open argument sink", function()
        local ok, err, tree = run_checker([[
            function values(): (...: integer)
            end

            function take(...: integer): nil
                return nil
            end

            function use(): nil
                take(values())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = tree[3].block.stats[1].callexp
        local inner = outer._arg_adjustment.open_source
        assert.same("Ast.ExpCall", inner._tag)
        assert.same({}, inner._visible_types)
        assert.truthy(inner._open_results)
        assert.same("open", inner._flex_result_demand)
        assert.falsy(inner._discard_results)
        assert.same(0, #outer._arg_adjustment.discards)
    end)

    it("statically narrows a fixed-only producer in an open argument sink", function()
        local ok, err, tree = run_checker([[
            function values(): (integer, string)
                return 1, "x"
            end

            function take(...: value): nil
                return nil
            end

            function use(): nil
                take(values())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = tree[3].block.stats[1].callexp
        local adjusted = outer._arg_adjustment
        local first = adjusted.tail_scalars[1]
        local inner = first._tag == "Ast.ExpCast" and first.exp or first
        assert.same("Ast.ExpCall", inner._tag)
        assert.same({ types.Integer(), types.String() }, inner._visible_types)
        assert.falsy(inner._open_results)
        assert.falsy(adjusted.open_source)
        assert.same(2, #adjusted.tail_scalars)
    end)

    it("nil-pads missing positional Titan arguments through the same demand", function()
        local ok, err, tree = run_checker([[
            function take(a: integer?, b: value): nil
                return nil
            end

            function use(): nil
                take()
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local call = tree[2].block.stats[1].callexp
        assert.same(2, call._npassed_args)
        assert.truthy(call._arg_adjustment.fixed[1]._missing_value)
        assert.truthy(call._arg_adjustment.fixed[2]._missing_value)
    end)

    it("projects a flexible producer into fixed return slots", function()
        local ok, err, tree = run_checker([[
            function values(): (...: integer)
            end

            function use(): (integer?, integer)
                return values()
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[1]
        local call = stat._result_adjustment.fixed[1]
        assert.same(2, call._finite_flex_prefix)
        assert.same(types.Option(types.Integer()), call._visible_types[1])
        assert.same("Ast.ExpCast", stat._result_adjustment.fixed[2]._tag)
    end)

    it("propagates a flexible producer into an open return tail", function()
        local ok, err, tree = run_checker([[
            function values(): (string, ...: string)
                return "first"
            end

            function use(): (boolean, ...: string)
                return true, values()
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[1]
        local call = stat._result_adjustment.tail_scalars[1]
        assert.same("open", call._flex_result_demand)
        assert.same(call, stat._result_adjustment.open_source)
        assert.same(types.String(), stat._result_adjustment.open_type)
        assert.same(types.String(), stat._result_adjustment.open_target)
        assert.same(1, stat._result_adjustment.open_start)
    end)

    it("retains surplus fixed-return expressions for effects", function()
        local ok, err, tree = run_checker([[
            function effect(): ()
            end

            function use(): integer
                return 1, effect()
            end
        ]])
        assert.truthy(ok, err)
        local stat = tree[2].block.stats[1]
        assert.same(2, #stat.exps)
        assert.same(1, #stat._result_adjustment.discards)
        assert.truthy(stat.exps[2]._voidok)
        assert.truthy(stat.exps[2]._discard_results)
    end)

    it("opens a flexible trailing call in an array constructor", function()
        local ok, err, tree = run_checker([[
            function values(): (string, ...: string)
                return "first"
            end

            function use(): {string}
                local xs: {string} = { values() }
                return xs
            end
        ]])
        assert.truthy(ok, err)
        local array = tree[2].block.stats[1]._result_adjustment.fixed[1]
        local call = array._positional_adjustment.open_source
        assert.same("Ast.ExpCall", call._tag)
        assert.same("open", call._flex_result_demand)
        assert.same(types.String(), array._positional_adjustment.open_type)
        assert.same(types.String(), array._positional_adjustment.open_target)
        assert.same(call, array._positional_adjustment.tail_scalars[1])
    end)

    it("uses finite flex projections in record, map, and named-value slots",
    function()
        local ok, err, tree = run_checker([[
            record Box
                maybe: integer?
            end

            function values(): (...: integer)
            end

            function take(maybe: integer?): nil
                return nil
            end

            function use(): nil
                local box: Box = { maybe = values() }
                local map: {string: integer} = { ["x"] = values() }
                take { maybe = values() }
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local record_init = stats[1]._result_adjustment.fixed[1]
        local map_init = stats[2]._result_adjustment.fixed[1]
        local named_call = stats[3].callexp
        local calls = {
            underlying_call(record_init.fields[1].exp),
            underlying_call(map_init.fields[1].exp),
            underlying_call(named_call.args.args[1]),
        }

        for _, call in ipairs(calls) do
            assert.same(1, call._finite_flex_prefix)
            assert.same(1, call._flex_result_demand)
            assert.same({ types.Option(types.Integer()) }, call._visible_types)
            assert.same("flex", call._result_sources[1].kind)
            assert.falsy(call._open_results)
        end
    end)

    it("keeps parenthesized calls scalar despite zero-return permission", function()
        local ok, err, tree = run_checker([[
            function one(): integer
                return 1
            end

            function use(): integer
                return (one())
            end
        ]])
        assert.truthy(ok, err)
        local adjusted = tree[2].block.stats[1].exps[1]
        assert.same("Ast.ExpAdjust", adjusted._tag)
        assert.same({ types.Integer() }, adjusted.exp._visible_types)
        assert.same(types.Integer(), adjusted._type)
    end)

    it("reports one array diagnostic for an incompatible open tail", function()
        local errs = h.check_errs([[
            function values(): (...: string)
            end

            function use(): nil
                local xs: {integer} = { values() }
                return nil
            end
        ]])
        assert.same(1, #errs)
        assert.match("open result element type string is not coerceable to array element type integer",
            errs[1])
    end)

    it("keeps explicit foreign-call arity strict", function()
        with_header("extern int ffi_add(int a, int b);\n", function(header)
            local errs = h.check_errs([[
                foreign import "]] .. header .. [["
                function use(): nil
                    ffi.ffi_add(1, 2, 3)
                    return nil
                end
            ]])
            assert.same(1, #errs)
            assert.match("called with 3 arguments but expects 2", errs[1])
        end)
    end)

    it("reports the produced C arity after a zero-result final argument", function()
        with_header("extern int ffi_add(int a, int b);\n", function(header)
            local errs = h.check_errs([[
                foreign import "]] .. header .. [["
                function zero(): ()
                end
                function use(): nil
                    ffi.ffi_add(1, zero())
                    return nil
                end
            ]])
            assert.same(2, #errs)
            assert.match("function returning no values cannot be used as a value",
                table.concat(errs, "\n"))
            assert.match("called with 1 arguments but expects 2",
                table.concat(errs, "\n"))
        end)
    end)

    it("rejects a 201-slot finite flex projection with one cap error", function()
        local function source(n)
            local decls = {}
            for i = 1, n do decls[i] = "v" .. i .. ": integer?" end
            return [[
                function values(): (...: integer)
                end
                function use(): nil
                    local ]] .. table.concat(decls, ", ") .. [[ = values()
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

    it("keeps finite generic VM requests within Lua's 250-result field", function()
        local function repeated(value, n)
            local out = {}
            for i = 1, n do out[i] = value end
            return table.concat(out, ", ")
        end

        local fixed51 = repeated("integer", 51)
        local values51 = repeated("1", 51)
        local callable = "function (): (" .. fixed51 .. ", ...: integer)"
        local finite251 = repeated("integer", 251)

        -- The same request is legal for a statically named Titan function: its
        -- native output descriptor never enters Lua's finite-result encoding.
        local ok, err = run_checker([[
            function producer(): (]] .. fixed51 .. [[, ...: integer)
                return ]] .. values51 .. [[
            end

            function direct(): (]] .. finite251 .. [[)
                return producer()
            end
        ]])
        assert.truthy(ok, err)

        local errs = h.check_errs([[
            function generic(f: ]] .. callable .. [[): (]]
                .. finite251 .. [[)
                return f()
            end
        ]])
        assert.same(1, #errs)
        assert.match("function%-value call can require 251 finite VM results",
            errs[1])
        assert.match("Lua 5%.5 supports at most 250", errs[1])
    end)

    it("does not apply the finite VM limit to an open generic call",
    function()
        local function shape(n)
            local types_out = {}
            for i = 1, n do
                types_out[i] = "integer"
            end
            return table.concat(types_out, ", ")
        end

        local fixed51 = shape(51)
        local ok, err = run_checker([[
            function relay(f: function (): (]] .. fixed51
                .. [[, ...: integer)): (]] .. fixed51 .. [[, ...: integer)
                return f()
            end
        ]])
        assert.truthy(ok, err)
    end)
end)

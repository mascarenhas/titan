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

describe("contextual calls through value (typechecker)", function()
    it("synthesizes fixed positional inputs and finite typed results", function()
        local ok, err, tree = run_checker([[
            function use(f: value): (integer, string?)
                return f(1, "label")
            end
        ]])
        assert.truthy(ok, err)
        local call = find_function(tree, "use").block.stats[1].exps[1]
        local expected = types.Function(
            { types.Integer(), types.String() },
            { types.Integer(), types.Option(types.String()) },
            false, false, false)

        assert.truthy(call._contextual_value_call)
        assert.same("Ast.ExpCast", call.exp._tag)
        assert.truthy(call.exp._contextual_value_cast)
        assert.same(expected, call.exp.target)
        assert.same(expected, call._contextual_function_type)
        assert.same(expected, call._callee_type)
        assert.same(expected.rettypes, call._types)
        assert.same(expected.rettypes, call._visible_types)
        assert.same(2, call._npassed_args)
        assert.same(2, #call._arg_adjustment.fixed)
        assert.same(0, #call._arg_adjustment.tail_scalars)
        assert.falsy(call._open_args)
    end)

    it("uses value for an unknown scalar result and no result for a statement",
    function()
        local ok, err, tree = run_checker([[
            function use(f: value): value
                local inferred = f()
                f()
                return inferred
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local inferred = stats[1]._result_adjustment.fixed[1]
        local discarded = stats[2].callexp

        assert.same(types.Value(), stats[1].decls[1]._type)
        assert.same({ types.Value() }, inferred._callee_type.rettypes)
        assert.same(types.Value(), inferred._type)
        assert.same({}, discarded._callee_type.rettypes)
        assert.falsy(discarded._callee_type.flexrettype)
        assert.same({}, discarded._visible_types)
        assert.same(types.Void(), discarded._type)
    end)

    it("synthesizes zero results in discarded argument, RHS, and return slots",
    function()
        local ok, err, tree = run_checker([[
            function take(number: integer): nil
                return nil
            end

            function use(f: value): integer
                local number: integer = 1, f()
                take(1, f())
                return 1, f()
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local calls = {
            stats[1]._result_adjustment.discards[1],
            stats[2].callexp._arg_adjustment.discards[1],
            stats[3]._result_adjustment.discards[1],
        }
        for _, call in ipairs(calls) do
            assert.same("Ast.ExpCall", call._tag)
            assert.truthy(call._contextual_value_call)
            assert.same({}, call._callee_type.rettypes)
            assert.falsy(call._callee_type.flexrettype)
            assert.same({}, call._visible_types)
            assert.truthy(call._discard_results)
            assert.truthy(call._voidok)
        end
    end)

    it("checks each synthesized positional argument exactly once", function()
        local errs = h.check_errs([[
            function use(f: value): nil
                f(missing)
                return nil
            end
        ]])
        assert.same(1, #errs)
        assert.match("variable 'missing' not declared", errs[1])
    end)

    it("synthesizes open array and flexible-return result tails", function()
        local ok, err, tree = run_checker([[
            function collect(f: value): {integer}
                local xs: {integer} = { f() }
                return xs
            end

            function forward(f: value): (boolean, ...: string)
                return f()
            end
        ]])
        assert.truthy(ok, err)

        local array = find_function(tree, "collect").block.stats[1]
            ._result_adjustment.fixed[1]
        local collect_call = array._positional_adjustment.open_source
        assert.same(types.Function({}, {}, false, false, types.Integer()),
            collect_call._callee_type)
        assert.same("open", collect_call._flex_result_demand)
        assert.same(types.Integer(), collect_call._open_results.source_type)

        local forward_call = find_function(tree, "forward").block.stats[1]
            ._result_adjustment.fixed[1]
        assert.same({ types.Boolean() }, forward_call._callee_type.rettypes)
        assert.same(types.String(), forward_call._callee_type.flexrettype)
        assert.same("open", forward_call._flex_result_demand)
        assert.same(1, forward_call._open_results.start)
    end)

    it("infers an untyped open array as value elements", function()
        local ok, err, tree = run_checker([[
            function collect(f: value): {value}
                local xs = { f() }
                return xs
            end
        ]])
        assert.truthy(ok, err)
        local stat = find_function(tree, "collect").block.stats[1]
        local array = stat._result_adjustment.fixed[1]
        local call = array._positional_adjustment.open_source
        assert.same(types.Array(types.Value()), stat.decls[1]._type)
        assert.same(types.Value(), call._callee_type.flexrettype)
        assert.same("open", call._flex_result_demand)
    end)

    it("uses a variadic outer call to constrain an inner value call", function()
        local ok, err, tree = run_checker([[
            function take(head: integer, maybe: integer?, ...: string): nil
                return nil
            end

            function use(f: value): nil
                take(f())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = find_function(tree, "use").block.stats[1].callexp
        local inner = outer._arg_adjustment.fixed[1]
        assert.same({ types.Integer(), types.Option(types.Integer()) },
            inner._callee_type.rettypes)
        assert.same(types.String(), inner._callee_type.flexrettype)
        assert.same("open", inner._flex_result_demand)
        assert.same(inner, outer._arg_adjustment.open_source)
        assert.same(types.String(), outer._open_args.target_type)
    end)

    it("defers contextual value-call shapes until ambient inference closes",
    function()
        local ok, err, tree = run_checker([[
            function agree<T>(left: T, right: T): T
                return left
            end

            function make_fixed<T>(): (T, T) -> T
                return function(left: T, right: T): T return left end
            end

            function make_open<T>(): (...: T) -> T
                return function(...: T): T return ...[1] end
            end

            record Box<T>
                item: T
            end

            function take_array<T>(items: {T}, witness: T): T
                return witness
            end

            function take_map<T>(items: {string: T}, witness: T): T
                return witness
            end

            function take_box<T>(box: Box<T>, witness: T): T
                return witness
            end

            function left(callback: value): integer
                return agree(callback(), 42)
            end

            function right(callback: value): integer
                return agree(42, callback())
            end

            function named(callback: value): integer
                return agree { left = callback(), right = 42 }
            end

            function parenthesized(callback: value): integer
                return agree((callback()), 42)
            end

            function fixed(callback: value): integer
                return agree(make_fixed()(callback()), 42)
            end

            function open(callback: value): integer
                return agree(make_open()(callback()), 42)
            end

            function array(callback: value): integer
                local got = take_array({ callback() }, 42)
                return got
            end

            function map(callback: value): integer
                local got = take_map({ ["item"] = callback() }, 42)
                return got
            end

            function boxed(callback: value): integer
                local got = take_box({ item = callback() }, 42)
                return got
            end
        ]])
        assert.truthy(ok, err)

        local source_backreference = {
            _decl = true,
            _generic_scheme = true,
            _generic_declaration = true,
            _generic_owner = true,
        }
        local function collect(value, seen, calls)
            if type(value) ~= "table" or seen[value] then return end
            seen[value] = true
            if value._tag == "Ast.ExpCall"
               and value._contextual_value_call then
                calls[#calls + 1] = value
            end
            for key, child in pairs(value) do
                if not source_backreference[key] then
                    collect(child, seen, calls)
                end
            end
        end
        local function contextual_call(name)
            local calls = {}
            collect(find_function(tree, name).block, {}, calls)
            assert.same(1, #calls)
            return calls[1]
        end
        local function find_parameter(value, path, seen)
            if type(value) ~= "table" or seen[value] then return nil end
            seen[value] = true
            if value._tag == "Type.Parameter" then return path end
            for key, child in pairs(value) do
                if not source_backreference[key] then
                    local found = find_parameter(child,
                        path .. "." .. tostring(key), seen)
                    if found then return found end
                end
            end
        end

        local scalar = types.Function({}, { types.Integer() },
            false, false, false)
        for _, name in ipairs({
            "left", "right", "named", "parenthesized", "map", "boxed",
        }) do
            local call = contextual_call(name)
            assert.same(scalar, call._callee_type)
            assert.same(scalar, call._contextual_function_type)
            assert.same(scalar, call.exp.target)
        end

        local fixed = contextual_call("fixed")
        assert.same(types.Function({},
            { types.Integer(), types.Integer() }, false, false, false),
            fixed._callee_type)
        for _, name in ipairs({ "open", "array" }) do
            local open = contextual_call(name)
            assert.same(types.Function({}, {}, false, false, types.Integer()),
                open._callee_type)
            assert.same("open", open._flex_result_demand)
            assert.same(types.Integer(), open._open_results.source_type)
        end

        for _, name in ipairs({
            "left", "right", "named", "parenthesized", "fixed", "open",
            "array", "map", "boxed",
        }) do
            local leak = find_parameter(
                find_function(tree, name).block, name, {})
            assert.falsy(leak,
                "inference parameter leaked through " .. tostring(leak))
        end
    end)

    it("carries dependent scalar and open-run demands through derived uses",
    function()
        local ok, err, tree = run_checker([[
            function agree<T>(left: T, right: T): T return left end
            function take<T>(items: {T}, witness: T): T return witness end
            function pick<T>(left: T?, right: T): T return right end
            function make_map<T>(): {T: T} return {} end
            function spread<T>(): (...: T)
                return (42 as value) as T
            end

            function parenthesized(callback: value): integer
                return take({(callback())}, 42)
            end
            function key(callback: value): string
                return pick(make_map()[callback()], "item")
            end
            function open_input(callback: value): integer
                return agree(callback(spread()), 42)
            end
        ]])
        assert.truthy(ok, err)

        local function peel(exp)
            while exp._tag == "Ast.ExpCast" do exp = exp.exp end
            return exp
        end
        local parent = peel(find_function(tree, "parenthesized")
            .block.stats[1].exps[1])
        local array = peel(parent.args.args[1])
        local paren = array._positional_adjustment.tail_scalars[1]
        assert.equal("Ast.ExpAdjust", paren._tag)
        assert.same(types.Function({}, { types.Integer() },
            false, false, false), paren.exp._callee_type)

        local keyed = peel(find_function(tree, "key")
            .block.stats[1].exps[1])
        local index = peel(keyed.args.args[1])
        local key_call = index.var.exp2
        assert.same(types.Function({}, { types.String() },
            false, false, false), key_call._callee_type)

        local open = peel(find_function(tree, "open_input")
            .block.stats[1].exps[1])
        local callback = peel(open.args.args[1])
        assert.same(types.Function({}, { types.Integer() },
            false, types.Value(), false), callback._callee_type)
        assert.is_true(callback._open_args.source ==
            callback._arg_adjustment.open_source)
        assert.same(types.Value(), callback._open_args.source_type)
        assert.same(types.Value(), callback._open_args.target_type)
        assert.same(types.Value(), callback._arg_adjustment.open_type)
        assert.same(types.Value(), callback._arg_adjustment.open_target)
        assert.equal(callback._arg_adjustment.open_start,
            callback._open_args.start)
        assert.is_true(callback._open_args.adjustment ==
            callback._arg_adjustment.open_adjustment)
        assert.equal("identity", callback._open_args.adjustment.kind)
        assert.same(types.Value(),
            callback._open_args.source._open_results.source_type)
        assert.same(types.Value(),
            callback._open_args.source._open_results.target_type)
    end)

    it("checks a dependent contextual value call exactly once", function()
        local errs = h.check_errs([[
            function agree<T>(left: T, right: T): T return left end

            function use(callback: value): integer
                return agree(callback(missing), 42)
            end
        ]])
        assert.same(1, #errs)
        assert.match("variable 'missing' not declared", errs[1])
    end)

    it("uses a fixed outer call to constrain every inner result", function()
        local ok, err, tree = run_checker([[
            function take(number: integer, label: string): nil
                return nil
            end

            function use(f: value): nil
                take(f())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = find_function(tree, "use").block.stats[1].callexp
        local inner = outer._arg_adjustment.fixed[1]
        assert.same({ types.Integer(), types.String() },
            inner._callee_type.rettypes)
        assert.falsy(inner._callee_type.flexrettype)
        assert.falsy(inner._open_results)
        assert.falsy(outer._open_args)
    end)

    it("derives fixed and variadic inputs from a trailing producer", function()
        local ok, err, tree = run_checker([[
            function pair(): (integer, string)
                return 1, "x"
            end

            function many(): (boolean, ...: integer)
                return true
            end

            function use(fixed: value, open: value): nil
                fixed(pair())
                open(many())
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local fixed = stats[1].callexp
        local open = stats[2].callexp

        assert.same({ types.Integer(), types.String() },
            fixed._callee_type.params)
        assert.falsy(fixed._callee_type.varargtype)
        assert.same(2, fixed._npassed_args)

        assert.same({ types.Boolean() }, open._callee_type.params)
        assert.same(types.Integer(), open._callee_type.varargtype)
        assert.same(1, open._npassed_args)
        assert.same(types.Integer(), open._open_args.source_type)
    end)

    it("preserves open multiple results through outer(inner())", function()
        local ok, err, tree = run_checker([[
            function use(outer: value, inner: value): integer?
                return outer(inner())
            end
        ]])
        assert.truthy(ok, err)
        local outer = find_function(tree, "use").block.stats[1].exps[1]
        local inner = outer._arg_adjustment.open_source

        assert.same(types.Function({}, {}, false, false, types.Value()),
            inner._callee_type)
        assert.same("open", inner._flex_result_demand)
        assert.same(types.Value(), outer._callee_type.varargtype)
        assert.same({ types.Option(types.Integer()) },
            outer._callee_type.rettypes)
        assert.same(inner, outer._open_args.source)
    end)

    it("keeps parenthesized value calls scalar in an open array sink", function()
        local ok, err, tree = run_checker([[
            function use(f: value): {integer}
                local xs: {integer} = { (f()) }
                return xs
            end
        ]])
        assert.truthy(ok, err)
        local array = find_function(tree, "use").block.stats[1]
            ._result_adjustment.fixed[1]
        local adjusted = array._positional_adjustment
        local paren = adjusted.tail_scalars[1]
        assert.same("Ast.ExpAdjust", paren._tag)
        assert.falsy(adjusted.open_source)
        assert.same({ types.Integer() }, paren.exp._callee_type.rettypes)
        assert.falsy(paren.exp._callee_type.flexrettype)
    end)

    it("does not reverse-infer a numeric result from an operator", function()
        local ok, err, tree = run_checker([[
            function use(f: value): integer
                return f() + 1
            end
        ]])
        assert.falsy(ok)
        assert.match("left hand side of arithmetic expression is a value instead of a number",
            err)
        local binary = find_function(tree, "use").block.stats[1].exps[1]
        assert.same({ types.Value() }, binary.lhs._callee_type.rettypes)
    end)

    it("threads a direct named parameter context into its value expression",
    function()
        local ok, err, tree = run_checker([[
            function take(number: integer): nil
                return nil
            end

            function use(f: value): nil
                take { number = f() }
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = find_function(tree, "use").block.stats[1].callexp
        local inner = outer.args.args[1]
        assert.same({ types.Integer() }, inner._callee_type.rettypes)
        assert.same({ types.Integer() }, inner._visible_types)
    end)

    it("synthesizes the exact original tag for a matching value round-trip",
    function()
        local ok, err, tree = run_checker([[
            function original(number: integer): string
                return "ok"
            end

            function use(): string
                local dynamic: value = original
                return dynamic(1)
            end
        ]])
        assert.truthy(ok, err)
        local call = find_function(tree, "use").block.stats[2].exps[1]
        local original_type = find_function(tree, "original")._type
        assert.truthy(types.equals(original_type, call._callee_type))
        assert.truthy(types.equals(original_type, call.exp.target))
        assert.truthy(call._contextual_value_call)
    end)

    it("recovers an exact tag with both input and output tails", function()
        local ok, err, tree = run_checker([[
            function strings(): (...: string)
            end

            function original(head: integer, ...: string): (integer, ...: integer)
                return head
            end

            function consume(head: integer, ...: integer): nil
                return nil
            end

            function use(): nil
                local dynamic: value = original
                consume(dynamic(1, strings()))
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local outer = find_function(tree, "use").block.stats[2].callexp
        local call = outer._arg_adjustment.fixed[1]
        local original_type = find_function(tree, "original")._type
        assert.truthy(types.equals(original_type, call._callee_type))
        assert.same(types.String(), call._callee_type.varargtype)
        assert.same(types.Integer(), call._callee_type.flexrettype)
        assert.same("open", call._flex_result_demand)
        assert.same(call, outer._arg_adjustment.open_source)
    end)

    it("does not resynthesize a known function or expose hidden fixed results",
    function()
        local ok, err, tree = run_checker([[
            function wide(): (integer, ...: string)
                return 1, "hidden"
            end

            function use(): {integer}
                local narrow: () -> integer = wide
                local xs: {integer} = { narrow() }
                return xs
            end
        ]])
        assert.truthy(ok, err)
        local array = find_function(tree, "use").block.stats[2]
            ._result_adjustment.fixed[1]
        local call = array._positional_adjustment.tail_scalars[1]
        assert.same("Ast.ExpCall", call._tag)
        assert.falsy(call._contextual_value_call)
        assert.same(types.Function({}, { types.Integer() }, false, false,
            false), call._callee_type)
        assert.same({ types.Integer() }, call._visible_types)
        assert.falsy(call._open_results)
        assert.falsy(array._positional_adjustment.open_source)
    end)

    it("rejects named syntax on value callees", function()
        local errs = h.check_errs([[
            function use(f: value): nil
                f { x = 1 }
                return nil
            end
        ]])
        assert.same(1, #errs)
        assert.match("named arguments require a direct Titan module function",
            errs[1])
    end)

    it("checks an invalid named value-call field exactly once", function()
        local errs = h.check_errs([[
            function use(f: value): nil
                f { x = missing }
                return nil
            end
        ]])
        assert.same(2, #errs)
        assert.match("named arguments require a direct Titan module function",
            errs[1])
        assert.match("variable 'missing' not declared", errs[2])
    end)

    it("rejects unsupported flexible results and their Array writer policy",
    function()
        with_header("typedef int *phase_c_iptr;\n", function(header)
            local errs = h.check_errs([[
                local c = foreign import "]] .. header .. [["

                function use(f: value): nil
                    local xs: {c.phase_c_iptr} = { f() }
                    return nil
                end
            ]])
            assert.same(2, #errs)
            assert.match("a flexible return cannot have a foreign pointer type",
                errs[1])
            assert.match("cannot construct an array with element type int %*",
                errs[2])
            assert.match("genuine Lua writes have no sound dynamic coercion",
                errs[2])
        end)
    end)

    it("keeps direct C arity strict and rejects an open value run into C varargs",
    function()
        with_header([[
            extern int phase_c_add(int left, int right);
            extern int phase_c_sum(int first, ...);
        ]], function(header)
            local errs = h.check_errs([[
                local c = foreign import "]] .. header .. [["

                function use(f: value): nil
                    c.phase_c_add(1)
                    c.phase_c_add(1, 2, 3)
                    c.phase_c_sum(1, f())
                    return nil
                end

                function valid(f: value): integer
                    return c.phase_c_add(f())
                end
            ]])
            local all = table.concat(errs, "\n")
            assert.same(3, #errs)
            assert.match("phase_c_add'.-called with 1 arguments but expects 2", all)
            assert.match("phase_c_add'.-called with 3 arguments but expects 2", all)
            assert.match("cannot pass a runtime%-open Titan result sequence to a foreign %(C%) variadic function",
                all)
        end)
    end)
end)

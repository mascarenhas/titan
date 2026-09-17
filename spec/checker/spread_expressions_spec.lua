-- Typechecker regressions for tail-only Array, integer-Map, and input-vararg
-- spreads. Parser-only syntax coverage lives in spec/parser_spec.lua; these
-- cases pin subject/bound validation plus finite/open expression-list demand.
-- End-to-end range, evaluation-order, cap, and GC behavior belongs in the
-- corresponding coder spec.
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker
local assert_type_check = h.assert_type_check
local check_errs = h.check_errs

local function find_function(tree, name)
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("function not found: " .. name)
end

local function with_header(contents, body)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(body, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function assert_error(pattern, source)
    local errors = check_errs(source)
    assert.is_true(#errors >= 1)
    for _, err in ipairs(errors) do
        if err:match(pattern) then return end
    end
    error(string.format("expected error matching %q, got:\n%s",
        pattern, table.concat(errors, "\n")), 0)
end

local function underlying_spread_index(exp)
    while exp._tag == "Ast.ExpCast" do exp = exp.exp end
    assert.same("Ast.ExpSpreadIndex", exp._tag)
    return exp
end

local function assert_no_type_parameters(value, path, seen)
    if type(value) ~= "table" then return end
    path = path or "root"
    seen = seen or {}
    if seen[value] then return end
    seen[value] = true
    if value._tag == "Type.Parameter" then
        error("generic type reached erased spread AST at " .. path, 0)
    end
    local source_backreference = {
        _decl = true,
        _declared_method = true,
        _declared_type = true,
        _generic_scheme = true,
        _generic_declaration = true,
        _generic_owner = true,
        _resolved_typearg = true,
    }
    for key, child in pairs(value) do
        if not source_backreference[key] then
            assert_no_type_parameters(child,
                path .. "." .. tostring(key), seen)
        end
    end
end

describe("Array, Map, and vararg spread expressions (typechecker)", function()
    it("accepts mutable, const, and maybe-const Array subjects", function()
        assert_type_check([[
            function use(
                mutable: {integer},
                frozen: const { integer },
                readable: const? { integer },
                upper: value
            )
                local whole: integer? = ...mutable
                local prefix: integer? = ...frozen[, upper]
                local suffix: integer? = ...readable[1.0,]
                local middle: integer? = ...mutable[2, 4]
            end
        ]])
    end)

    it("accepts exact integer-key Map subjects", function()
        assert_type_check([[
            type Index = integer
            type Items = {Index: string}

            function use(items: Items)
                local whole: string? = ...items
                local prefix: string? = ...items[, 3]
                local suffix: string? = ...items[2,]
                local middle: string? = ...items[2, 3]
            end
        ]])
    end)

    it("accepts whole and sliced input-vararg spreads", function()
        assert_type_check([[
            function use(...: integer)
                local whole: integer? = ...
                local prefix: integer? = ...[, 3]
                local suffix: integer? = ...[2,]
                local middle: integer? = ...[2, 3]
            end
        ]])
    end)

    it("accepts an indexed input-vararg container as a spread subject",
    function()
        assert_type_check([[
            function sink(...: integer)
            end

            function use(...: {integer})
                sink(... ...[1])
            end
        ]])
    end)

    it("types finite projections as options and forces a required slot",
    function()
        local ok, err, tree = run_checker([[
            function use(items: {integer})
                local optional: integer?, required: integer = ...items[2,]
            end
        ]])
        assert.truthy(ok, err)

        local stat = find_function(tree, "use").block.stats[1]
        local adjustment = stat._result_adjustment
        assert.truthy(adjustment)
        assert.falsy(adjustment.open_source)

        local optional = adjustment.fixed[1]
        assert.same("Ast.ExpSpreadIndex", optional._tag)
        assert.same(types.Option(types.Integer()), optional._type)

        local required = adjustment.fixed[2]
        assert.same("Ast.ExpCast", required._tag)
        assert.same(types.Integer(), required._type)
        assert.same(types.Option(types.Integer()),
            underlying_spread_index(required)._type)
    end)

    it("keeps a trailing spread open for a variadic call", function()
        local ok, err, tree = run_checker([[
            function sink(...: integer)
            end

            function use(items: {integer})
                sink(10, ...items[2,])
            end
        ]])
        assert.truthy(ok, err)

        local call = find_function(tree, "use").block.stats[1].callexp
        local adjustment = call._arg_adjustment
        assert.same(1, #adjustment.tail_scalars)
        assert.same("Ast.ExpSpread", adjustment.open_source._tag)
        assert.same(types.Integer(), adjustment.open_type)
        assert.same(types.Integer(), adjustment.open_target)
        assert.same(1, adjustment.open_start)
    end)

    it("links nested generic Array and Map producers to finite and open sinks",
    function()
        local ok, err, tree = run_checker([[
            function make_array<|T|>(): {T} return {} end
            function make_map<|T|>(): {integer: T} return {} end

            function fixed<|T|>(head: T, middle: T, tail: T)
            end

            function open<|T|>(head: T, ...: T)
            end

            function use()
                fixed(1, ...make_array())
                open(1, ...make_array())
                fixed(1, ...make_map())
                open(1, ...make_map())

                -- Explicit arguments are controls for the same carrier paths.
                fixed(1, ...make_array<|integer|>())
                open(1, ...make_map<|integer|>())
            end
        ]])
        assert.truthy(ok, err)
        local use = find_function(tree, "use")
        assert_no_type_parameters(use.block)

        local stats = use.block.stats
        for _, index in ipairs({ 1, 3, 5 }) do
            local adjustment = stats[index].callexp._arg_adjustment
            local carrier
            for _, exp in ipairs(adjustment.exps) do
                if exp._tag == "Ast.ExpSpread" then carrier = exp end
            end
            assert.truthy(carrier)
            local first = underlying_spread_index(adjustment.fixed[2])
            local second = underlying_spread_index(adjustment.fixed[3])
            assert.is_true(rawequal(carrier, first.spread))
            assert.is_true(rawequal(carrier, second.spread))
            assert.is_true(rawequal(first.spread, second.spread))
        end
        for _, index in ipairs({ 2, 4, 6 }) do
            local adjustment = stats[index].callexp._arg_adjustment
            local carrier
            for _, exp in ipairs(adjustment.exps) do
                if exp._tag == "Ast.ExpSpread" then carrier = exp end
            end
            assert.truthy(carrier)
            assert.is_true(rawequal(carrier, adjustment.open_source))
        end
    end)

    it("distinguishes optional finite and raw open generic spread evidence",
    function()
        local ok, err, tree = run_checker([[
            function box<|T|>(item: T?): {T}
                return {}
            end

            function gather<|T|>(...: T): {T}
                return {}
            end

            function use(items: {integer})
                local finite = box(...items[2, 2])
                local open = gather(...items)
            end
        ]])
        assert.truthy(ok, err)

        local use = find_function(tree, "use")
        for _, stat in ipairs(use.block.stats) do
            assert.is_true(types.equals(
                types.Array(types.Integer(), false), stat.decls[1]._type))
        end
        assert_no_type_parameters(use.block)
    end)

    it("refreshes generic-for spread projections in the iterator context",
    function()
        local ok, err, tree = run_checker([[
            function step<|T|>(state: T, control: T): T?
                return nil
            end

            function supply<|U|>(): {U}
                return {}
            end

            function use()
                for item: value in step, ...supply() do
                end
            end
        ]])
        assert.truthy(ok, err)

        local use = find_function(tree, "use")
        assert_no_type_parameters(use.block)
        local loop = use.block.stats[1]
        assert.same("Ast.StatForIn", loop._tag)
        assert_no_type_parameters(loop._tuple_adjustment)
    end)

    it("closes spread evidence in inferred Array and positional Map constructors",
    function()
        local ok, err, tree = run_checker([[
            function make_array<|T|>(): {T} return {} end
            function make_map<|T|>(): {integer: T} return {} end
            function make_optional_array<|T|>(): {T}? return {} end
            function make_optional_map<|T|>(): {integer: T}? return {} end

            function choose_array<|T|>(items: {T}, witness: T): {T}
                return items
            end

            function choose_map<|T|>(
                items: {integer: T}, witness: T
            ): {integer: T}
                return items
            end

            function use()
                local array = choose_array({...make_array()}, 1)
                local map = choose_map({...make_map()}, 2)
                local optional_array =
                    choose_array({...make_optional_array()}, 3)
                local optional_map =
                    choose_map({...make_optional_map()}, 4)
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(tree, "use").block.stats
        assert.is_true(types.equals(
            types.Array(types.Integer(), false),
            stats[1].decls[1]._type))
        assert.is_true(types.equals(
            types.Map(types.Integer(), types.Integer()),
            stats[2].decls[1]._type))
        assert.is_true(types.equals(
            types.Array(types.Integer(), false),
            stats[3].decls[1]._type))
        assert.is_true(types.equals(
            types.Map(types.Integer(), types.Integer()),
            stats[4].decls[1]._type))
        assert_no_type_parameters(find_function(tree, "use").block)
    end)

    it("forces Option containers returned by explicit generic producers",
    function()
        local ok, err, tree = run_checker([[
            function make_array<|T|>(): {T}? return {} end
            function make_map<|T|>(): {integer: T}? return {} end

            function use()
                local number: integer? = ...make_array<|integer|>()
                local text: string? = ...(make_map<|string|>())
            end
        ]])
        assert.truthy(ok, err)

        local use = find_function(tree, "use")
        assert.is_true(types.equals(
            types.Option(types.Integer()), use.block.stats[1].decls[1]._type))
        assert.is_true(types.equals(
            types.Option(types.String()), use.block.stats[2].decls[1]._type))
        assert_no_type_parameters(use.block)
    end)

    it("rejects Maps whose key type is not exactly integer", function()
        for _, keytype in ipairs({ "string", "float", "value" }) do
            assert_error("integer%-keyed [Mm]ap", string.format([[
                function use(items: {%s: integer})
                    local item: integer? = ...items
                end
            ]], keytype))
        end
    end)

    it("auto-unwraps Option containers but rejects value subjects",
    function()
        assert_type_check([[
            function use(
                array: {integer}?, map: {integer: string}?
            )
                local number: integer? = ...array
                local text: string? = ...map
            end
        ]])
        assert_error("spread subject", [[
            function use(items: value)
                local item: value = ...items
            end
        ]])
    end)

    it("checks unary-leading collection subjects as spread subjects",
    function()
        for _, spelling in ipairs({ "... - 1", "... ~1" }) do
            assert_error(
                "spread subject must be an Array or integer%-keyed Map",
                "function use(): integer\n  return " .. spelling .. "\nend")
        end
    end)

    it("rejects a foreign C array subject", function()
        with_header("extern int spread_values[4];\n", function(header)
            assert_error("spread subject", [[
                foreign import "]] .. header .. [["

                function use()
                    local item: value = ...ffi.spread_values
                end
            ]])
        end)
    end)

    it("adjusts nonvariadic C calls without feeding spreads to C varargs",
    function()
        with_header([[
typedef int spread_int;
spread_int spread_fixed(spread_int left, spread_int right);
spread_int spread_vararg(spread_int first, ...);
]], function(header)
            local prelude = string.format(
                "foreign import %q\n", header)
            assert_type_check(prelude .. [[
                local function finite(
                    items: {foreign spread_int}
                ): foreign spread_int
                    return ffi.spread_fixed(...items)
                end
            ]])
            assert_error("runtime%-open Titan result sequence", prelude .. [[
                function open(items: {foreign spread_int})
                    ffi.spread_vararg(0, ...items)
                end
            ]])
            assert_error("runtime%-open Titan result sequence", prelude .. [[
                function open_input(...: foreign spread_int)
                    ffi.spread_vararg(0, ...[2,])
                end
            ]])
        end)
    end)

    it("rejects noninteger-coercible lower and upper bounds", function()
        for _, slice in ipairs({ '["first", 3]', '[1, "last"]' }) do
            local errors = check_errs([[
                function use(items: {integer})
                    local item: integer? = ...items]] .. slice .. [[
                end
            ]])
            assert.same(1, #errors)
            assert.match("integer", errors[1])
            assert.match("string", errors[1])
        end
    end)

    it("rejects a sliced vararg spread outside a variadic function", function()
        assert_error("'%.%.%.' can only be used inside a variadic function",
            [[
                function use()
                    local item: integer? = ...[, 2]
                end
            ]])
    end)

    it("rejects subset suffixes outside a spread", function()
        for _, subset in ipairs({ "[, 3]", "[2,]", "[2, 3]" }) do
            assert_error("subset.*spread", [[
                function use(items: {integer})
                    local item: integer? = items]] .. subset .. [[
                end
            ]])
        end
    end)

    it("adjusts parenthesized vararg ranges to one value", function()
        assert_type_check([[
            function use(...: integer)
                local item = (...[1, 2])
            end
        ]])
    end)

    it("checks explicitly parsed non-tail spreads as placement errors",
    function()
        assert_error("spread can only be used as the last item", [[
            function sink(a: integer, b: integer, c: integer) end
            function use(items: {integer})
                sink(0, ...items, 1)
            end
        ]])
        assert_error("spread must be the last field", [[
            function use(items: {integer})
                local out = {0, ...items, 1}
            end
        ]])

        assert_error("spread can only be used as the last item", [[
            function sink(a: integer, b: integer) end
            function use(...: integer)
                sink(...[1, 2], 1)
            end
        ]])
        assert_error("spread must be the last field", [[
            function use(...: integer)
                local out = {...[1, 2], 1}
            end
        ]])
    end)

end)

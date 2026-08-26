local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local run_checker = h.run_checker
local assert_type_check = h.assert_type_check
local check_errs = h.check_errs

local function with_header(contents, fn)
    local header = os.tmpname() .. ".h"
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function find_function(tree, name)
    for _, node in ipairs(tree) do
        if node._tag == "Ast.TopLevelFunc" and node.name == name then
            return node
        end
    end
    error("function not found: " .. name)
end

local function local_initializer(stat)
    return stat._result_adjustment.fixed[1]
end

describe("dense Array and positional integer-Map checking", function()
    it("keeps Array and Map distinct and rejects direct casts", function()
        local errs = check_errs([[
            function array_to_map(a: {integer}): {integer: integer}
                return a as {integer: integer}
            end

            function map_to_array(m: {integer: integer}): {integer}
                return m as {integer}
            end
        ]])
        assert.same(2, #errs)
        assert.match("cannot cast", errs[1])
        assert.match("cannot cast", errs[2])
    end)

    it("preserves optional indexed reads and nil-capable writes", function()
        assert_type_check([[
            function use(a: {integer}, m: {integer: string}): nil
                local av: integer? = a[1]
                local mv: string? = m[1]
                a[1] = nil
                m[1] = nil
                return nil
            end
        ]])
    end)

    it("infers empty, nil-only, and computed constructors by shape", function()
        local ok, err, tree = run_checker([[
            function use(): nil
                local empty = {}
                local nils = { nil }
                local keyed = { [1] = 2 }
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local stats = find_function(tree, "use").block.stats
        assert.same(types.Array(types.Integer(), false), stats[1].decls[1]._type)
        assert.same(types.Array(types.Nil(), false), stats[2].decls[1]._type)
        assert.same(types.Map(types.Integer(), types.Integer()),
            stats[3].decls[1]._type)
        assert.truthy(local_initializer(stats[1])._positional_adjustment)
        assert.truthy(local_initializer(stats[2])._positional_adjustment)
        assert.falsy(local_initializer(stats[3])._positional_adjustment)
    end)

    it("accepts empty Maps with any key type", function()
        assert_type_check([[
            function use(): nil
                local strings: {string: integer} = {}
                local floats: {float: string} = {}
                local values: {value: boolean} = {}
                return nil
            end
        ]])
    end)

    it("accepts positional fields only for exact integer-keyed Maps", function()
        assert_type_check([[
            function use(): nil
                local m: {integer: string} = { "a", "b" }
                return nil
            end
        ]])

        for _, keytype in ipairs({ "string", "float", "value" }) do
            local errs = check_errs(string.format([[
                function use(): nil
                    local m: {%s: integer} = { 1 }
                    return nil
                end
            ]], keytype))
            assert.same(1, #errs)
            assert.match("positional fields require an integer%-keyed map",
                errs[1])
        end
    end)

    it("rejects every positional/computed/named mixture ordering cleanly",
    function()
        local cases = {
            "{ 1, [2] = 3 }",
            "{ [2] = 3, 1 }",
            "{ 1, named = 2 }",
            "{ named = 2, 1 }",
            "{ [1] = 2, named = 3 }",
            "{ named = 3, [1] = 2 }",
        }
        for _, initializer in ipairs(cases) do
            local errs = check_errs([[
                function use(): nil
                    local mixed = ]] .. initializer .. [[
                    return nil
                end
            ]])
            assert.same(1, #errs, initializer)
            assert.match("cannot mix", errs[1])
        end

        local contextual = check_errs([[
            function use(): nil
                local mixed: {integer: integer} = { [1] = 2, 3 }
                return nil
            end
        ]])
        assert.same(1, #contextual)
        assert.match("cannot mix", contextual[1])
    end)

    it("coerces and checks real computed Map keys and values", function()
        local ok, err, tree = run_checker([[
            function use(): nil
                local m: {float: float} = { [1] = 2 }
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local init = local_initializer(
            find_function(tree, "use").block.stats[1])
        assert.same("Ast.ExpCast", init.fields[1].name._tag)
        assert.same(types.Float(), init.fields[1].name._type)
        assert.same("Ast.ExpCast", init.fields[1].exp._tag)
        assert.same(types.Float(), init.fields[1].exp._type)

        local errs = check_errs([[
            function bad(): nil
                local m: {integer: integer} = { ["key"] = "value" }
                return nil
            end
        ]])
        assert.same(2, #errs)
        assert.match("map key initializer", errs[1])
        assert.match("map value initializer", errs[2])
    end)

    it("reports each bad positional scalar exactly once", function()
        local errs = check_errs([[
            function bad(): nil
                local a: {integer} = { "array" }
                local m: {integer: integer} = { "map" }
                return nil
            end
        ]])
        assert.same(2, #errs)
        assert.match("array initializer", errs[1])
        assert.match("positional map initializer", errs[2])
    end)

    it("shares fixed multiple-result adjustment between Array and Map", function()
        local ok, err, tree = run_checker([[
            function pair(): (integer, integer)
                return 2, 3
            end

            function use(): nil
                local a: {integer} = { 1, pair() }
                local m: {integer: integer} = { 1, pair() }
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local stats = find_function(tree, "use").block.stats
        local aa = local_initializer(stats[1])._positional_adjustment
        local ma = local_initializer(stats[2])._positional_adjustment
        assert.same(3, #aa.tail_scalars)
        assert.same(3, #ma.tail_scalars)
        assert.same(3, #aa.exps)
        assert.same(3, #ma.exps)
    end)

    it("shares flexible and contextual value-call tails with integer Maps",
    function()
        local ok, err, tree = run_checker([[
            function values(): (...: integer)
            end

            function flexible(): {integer: integer}
                return { 1, values() }
            end

            function contextual(f: value): {integer: integer}
                return { 1, f() }
            end
        ]])
        assert.truthy(ok, err)

        local flex = find_function(tree, "flexible").block.stats[1]
            ._result_adjustment.fixed[1]._positional_adjustment
        assert.same("Ast.ExpCall", flex.open_source._tag)
        assert.same(types.Integer(), flex.open_type)
        assert.same(types.Integer(), flex.open_target)

        local contextual = find_function(tree, "contextual").block.stats[1]
            ._result_adjustment.fixed[1]._positional_adjustment
        assert.same("Ast.ExpCall", contextual.open_source._tag)
        assert.truthy(contextual.open_source._contextual_value_call)
        assert.same(types.Integer(),
            contextual.open_source._callee_type.flexrettype)
        assert.same(types.Integer(), contextual.open_target)
    end)

    it("records coercion targets for open positional Map results", function()
        local ok, err, tree = run_checker([[
            function values(): (...: integer)
            end

            function collect(): {integer: float}
                return { 1, values() }
            end
        ]])
        assert.truthy(ok, err)

        local adjusted = find_function(tree, "collect").block.stats[1]
            ._result_adjustment.fixed[1]._positional_adjustment
        assert.same(types.Integer(), adjusted.open_type)
        assert.same(types.Float(), adjusted.open_target)
        assert.same(types.Float(),
            adjusted.open_source._open_results.target_type)
    end)

    it("accepts trailing input dots for positional integer Maps", function()
        local ok, err, tree = run_checker([[
            function collect(...: string): {integer: string}
                return { "head", ... }
            end
        ]])
        assert.truthy(ok, err)
        local init = find_function(tree, "collect").block.stats[1]
            ._result_adjustment.fixed[1]
        local adjusted = init._positional_adjustment
        assert.same("Ast.ExpDots", adjusted.open_source._tag)
        assert.same(types.String(), adjusted.open_type)
        assert.same(types.String(), adjusted.open_target)
    end)

    it("rejects non-final and duplicate input dots cleanly", function()
        local nonfinal = check_errs([[
            function collect(...: string): {integer: string}
                return { ..., "tail" }
            end
        ]])
        assert.same(1, #nonfinal)
        assert.match("must be the last field", nonfinal[1])

        local duplicate = check_errs([[
            function collect(...: string): {integer: string}
                return { ..., ... }
            end
        ]])
        assert.same(2, #duplicate)
        assert.match("must be the last field", duplicate[1])
        assert.match("can appear only once", duplicate[2])
    end)

    it("keeps earlier and parenthesized calls scalar", function()
        local ok, err, tree = run_checker([[
            function pair(): (integer, integer)
                return 1, 2
            end

            function use(): nil
                local m: {integer: integer} = { pair(), (pair()) }
                return nil
            end
        ]])
        assert.truthy(ok, err)
        local adjusted = local_initializer(
            find_function(tree, "use").block.stats[1])
            ._positional_adjustment
        assert.same(2, #adjusted.tail_scalars)
        assert.falsy(adjusted.open_source)
    end)

    it("propagates positional Map context through every expression sink",
    function()
        assert_type_check([[
            module_map: {integer: float} = { 1 }

            function take(m: {integer: float}): nil
                return nil
            end

            function returned(): {integer: float}
                return { 2 }
            end

            function use(): {integer: float}
                local m: {integer: float} = { 3 }
                m = { 4 }
                take({ 5 })
                local casted = { 6 } as {integer: float}
                return casted
            end
        ]])
    end)

    it("keeps keyed Map values scalar", function()
        assert_type_check([[
            function pair(): (integer, string)
                return 1, "discarded"
            end

            function use(): nil
                local m: {string: integer} = { ["one"] = pair() }
                return nil
            end
        ]])
    end)

    it("applies explicit nil rules to Array and positional Map values",
    function()
        assert_type_check([[
            function good(): nil
                local a: {value} = { nil }
                local m: {integer: value} = { nil }
                return nil
            end
        ]])

        local errs = check_errs([[
            function bad(): nil
                local a: {integer} = { nil }
                local m: {integer: integer} = { nil }
                return nil
            end
        ]])
        assert.same(2, #errs)
    end)

    it("accepts length only for Arrays and exact integer-keyed Maps", function()
        assert_type_check([[
            type Index = integer
            type IntMap = {Index: string}

            function lengths(a: {string}, m: IntMap): integer
                return #a + #m
            end
        ]])

        with_header("typedef int ffi_int;\n", function(header)
            local errs = check_errs([[
                local c = foreign import "]] .. header .. [["

                function noninteger_map(m: {float: string}): integer
                    return #m
                end

                local function c_integer_map(
                    m: {c.ffi_int: string}
                ): integer
                    return #m
                end
            ]])
            assert.same(2, #errs)
            assert.match("integer%-keyed map", errs[1])
            assert.match("integer%-keyed map", errs[2])
        end)
    end)

    it("accepts mutable, const, and const? Arrays for const? Array targets",
    function()
        assert_type_check([[
            function sum(xs: const? {integer}): integer
                local total = 0
                for i = 1, #xs do
                    total = total + (xs[i] or 0)
                end
                return total
            end

            function use(
                m: {integer},
                c: const {integer},
                mc: const? {integer}
            ): integer
                local a: const? {integer} = m
                local b: const? {integer} = c
                local d: const? {integer} = mc
                return sum(m) + sum(c) + sum(mc) + sum(a) + sum(b) + sum(d)
            end
        ]])
    end)

    it("propagates const? array subtyping through Option types", function()
        assert_type_check([[
            function process(opt: const? {integer}?): integer
                if not opt then
                    return 0
                end
                local arr = opt
                return #arr
            end

            function use(m: {integer}?, c: const {integer}?): integer
                local a: const? {integer}? = m
                local b: const? {integer}? = c
                return process(m) + process(c) + process(a) + process(b)
            end
        ]])
    end)

    it("typechecks generic functions accepting const? arrays", function()
        assert_type_check([[
            function map<A, B>(
                xs: const? {A},
                f: (A, integer) -> B
            ): {B}
                local res: {B} = {}
                for i = #xs, 1, -1 do
                    res[i] = f(xs[i], i)
                end
                return res
            end

            function use(
                nums: {integer},
                const_nums: const {integer}
            ): nil
                local strings = map(nums, function(x: integer, i: integer): string
                    return "item"
                end)
                local const_strings = map(const_nums, function(x: integer, i: integer): string
                    return "const_item"
                end)
                return nil
            end
        ]])
    end)

    it("rejects assigning const? arrays to mutable or const arrays without cast",
    function()
        local errs = check_errs([[
            function bad_assign(xs: const? {integer}): nil
                local m: {integer} = xs
                local c: const {integer} = xs
                return nil
            end
        ]])
        assert.same(2, #errs)
        assert.match("type error", errs[1])
        assert.match("type error", errs[2])
    end)

    it("rejects mutating elements of a const? array", function()
        local errs = check_errs([[
            function bad_write(xs: const? {integer}): nil
                xs[1] = 10
                return nil
            end
        ]])
        assert.same(1, #errs)
        assert.match("cannot assign to an element of const Array", errs[1])
    end)

    it("accepts explicit written casts to mutable or const arrays", function()
        assert_type_check([[
            function cast_it(xs: const? {integer}): ({integer}, const {integer})
                local m = xs as {integer}
                local c = xs as const {integer}
                local up = m as const? {integer}
                return m, c
            end
        ]])
    end)

    it("infers linear mutable array returns and lowers caller freeze", function()
        local ok, err, tree = run_checker([[
            function make_fresh(): {integer}
                return { 1, 2, 3 }
            end

            function make_builder(): {integer}
                local a: {integer} = {}
                a[1] = 10
                a[2] = 20
                return a
            end

            function use(): nil
                local c1: const {integer} = make_fresh()
                local c2: const {integer} = make_builder()
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local fn_fresh = find_function(tree, "make_fresh")
        local fn_builder = find_function(tree, "make_builder")
        assert.truthy(fn_fresh._signature.rettypes[1].linear)
        assert.truthy(fn_builder._signature.rettypes[1].linear)

        local use_stats = find_function(tree, "use").block.stats
        local cast1 = use_stats[1].exps[1]
        local cast2 = use_stats[2].exps[1]
        assert.same("written_cast", cast1._adjustment.kind)
        assert.same("freeze", cast1._adjustment.mode)
        assert.same("written_cast", cast2._adjustment.kind)
        assert.same("freeze", cast2._adjustment.mode)
    end)

    it("does not infer linear returns when mutable array escapes", function()
        local ok, err, tree = run_checker([[
            function escape_via_alias(sink: {{integer}}): {integer}
                local a: {integer} = {}
                sink[1] = a
                return a
            end

            function use(sink: {{integer}}): nil
                local c: const {integer} = escape_via_alias(sink) as const {integer}
                return nil
            end
        ]])
        assert.truthy(ok, err)

        local fn_esc = find_function(tree, "escape_via_alias")
        assert.falsy(fn_esc._signature.rettypes[1].linear)

        local use_stats = find_function(tree, "use").block.stats
        local cast = use_stats[1].exps[1]
        assert.same("written_cast", cast._written_cast.kind)
        assert.same("copy", cast._written_cast.mode)
    end)

    it("strips linear flag from first-class function values", function()
        local ok, err, tree = run_checker([[
            function producer(): {integer}
                return { 1, 2, 3 }
            end

            function use(): () -> {integer}
                local f = producer
                return f
            end
        ]])
        assert.truthy(ok, err)

        local fn_prod = find_function(tree, "producer")
        assert.truthy(fn_prod._signature.rettypes[1].linear)

        local fn_use = find_function(tree, "use")
        local f_decl = fn_use.block.stats[1].decls[1]
        assert.falsy(f_decl._type.rettypes[1].linear)
    end)
end)

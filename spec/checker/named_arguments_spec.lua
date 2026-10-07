local temporary = require "spec.support.temporary"
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local run_checker_modules = h.run_checker_modules

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    file:write(contents)
    file:close()

    local results = { pcall(fn, header) }
    os.remove(header)
    if not results[1] then
        error(results[2], 0)
    end
    table.remove(results, 1)
    return table.unpack(results)
end

local function find_toplevel(ast, tag, name)
    for _, node in ipairs(ast) do
        if node._tag == tag and node.name == name then
            return node
        end
    end
    error(string.format("could not find %s '%s'", tag, name))
end

local function unwrap_cast(exp)
    while exp._tag == "Ast.ExpCast" do
        exp = exp.exp
    end
    return exp
end

local function assert_checker_error(pattern, code)
    local ok, err = run_checker(code)
    assert.falsy(ok)
    assert.match(pattern, err)
    return err
end

local function assert_modules_ok(modules, main)
    local ok, err, imported = run_checker_modules(modules, main)
    assert.truthy(ok, err)
    return imported
end

describe("named arguments (typechecker)", function()
    it("recovers from duplicate declaration names without an internal error",
    function()
        local ok, err = run_checker([[
            function bad(x: integer, x: integer)
            end

            record WithMembers end

            function WithMembers.make(x: integer, x: integer)
            end

            function WithMembers:apply(x: integer, x: integer)
            end

            record DuplicateFields
                x: integer
                x: integer
            end

            function use()
                local receiver = WithMembers.new {}
                bad { x = 1 }
                WithMembers.make { x = 1 }
                receiver:apply { x = 1 }
                DuplicateFields.new { x = 1 }
            end
        ]])
        assert.falsy(ok)
        assert.match("duplicate parameter", err)
        local _, unavailable = err:gsub("named arguments are unavailable", "")
        assert.equal(4, unavailable)
    end)

    it("normalizes local and exported calls by formal while preserving source order",
    function()
        local ok, err, ast = run_checker([[
            local function local_pick(as_float: float, as_value: value,
                                      maybe: integer?, enabled: boolean): float
                return as_float
            end

            function public_pick(first: integer, second: float): float
                return second
            end

            function run(): float
                local a: float = local_pick {
                    as_value = "boxed",
                    as_float = 1,
                }
                local b: float = public_pick { second = 2, first = 1 }
                return a + b
            end
        ]])
        assert.truthy(ok, err)

        local run = find_toplevel(ast, "Ast.TopLevelFunc", "run")
        local local_call = run.block.stats[1].exps[1]
        assert.equal("Ast.ArgsFunc", local_call.args._tag)
        assert.same({ 2, 1 }, local_call._named_arg_order)
        assert.equal(4, #local_call.args.args)
        assert.equal("Type.Float", local_call.args.args[1]._type._tag)
        assert.equal("Type.Value", local_call.args.args[2]._type._tag)
        assert.equal("Type.Option", local_call.args.args[3]._type._tag)
        assert.equal("Type.Boolean", local_call.args.args[4]._type._tag)
        assert.truthy(local_call.args.args[3]._named_omitted)
        assert.truthy(local_call.args.args[4]._named_omitted)

        local public_call = run.block.stats[2].exps[1]
        assert.equal("Ast.ArgsFunc", public_call.args._tag)
        assert.same({ 2, 1 }, public_call._named_arg_order)
    end)

    it("checks source-imported functions, statics, constructors, and methods",
    function()
        assert_modules_ok({
            provider = [[
                record Empty end

                record Box
                    amount: float?
                end

                function Box.make(amount: float?): Box
                    return Box.new { amount = amount }
                end

                function Box:sum(delta: float, spare: float?): float
                    return delta
                end

                function mix(left: integer, right: float): float
                    return right
                end

                function zero(): integer
                    return 0
                end
            ]],
            consumer = [[
                local p = import "provider"

                function run(box: p.Box?): float
                    local empty: p.Empty = p.Empty.new {}
                    local empty_literal: p.Empty = {}
                    local direct: p.Box = p.Box.new {}
                    local made: p.Box = p.Box.make {}
                    return p.mix { right = 2, left = 1 }
                        + box:sum { delta = 3 }
                        + p.Box.make { amount = 1 }:sum { delta = 4 }
                        + p.zero {}
                end
            ]],
        }, "consumer")
    end)

    it("uses only the first result of a call in one named slot", function()
        local ok, err, ast = run_checker([[
            function pair(): (integer, string)
                return 7, "extra"
            end

            function take(first: integer, second: string?): integer
                return first
            end

            function run(): integer
                return take { first = pair() }
            end
        ]])
        assert.truthy(ok, err)

        local run = find_toplevel(ast, "Ast.TopLevelFunc", "run")
        local call = run.block.stats[1].exps[1]
        assert.equal(2, #call.args.args)
        assert.equal("Ast.ExpCall", call.args.args[1]._tag)
        assert.same({ 1 }, call._named_arg_order)
        assert.truthy(call.args.args[2]._named_omitted)
    end)

    it("reports required, unknown, duplicate, and mismatched named arguments",
    function()
        local prelude = [[
            function target(required: integer, optional: string?): integer
                return required
            end
        ]]

        assert_checker_error(
            "parameter 'required' of type integer cannot be omitted because it does not accept nil",
            prelude .. [[ function run(): integer return target {} end ]])

        assert_checker_error(
            "function 'target' has no parameter named 'unknown'",
            prelude .. [[
                function run(): integer
                    return target { required = 1, unknown = 2 }
                end
            ]])

        assert_checker_error(
            "named argument 'required' is supplied more than once",
            prelude .. [[
                function run(): integer
                    return target { required = 1, required = 2 }
                end
            ]])

        assert_checker_error(
            "named argument 'required'.-expected integer but found string",
            prelude .. [[
                function run(): integer
                    return target { required = "wrong" }
                end
            ]])
    end)

    it("rejects first-class, lambda, bound-method, and optional function values",
    function()
        local cases = {
            [[
                function direct(x: integer): integer return x end
                function run(): integer
                    local f: function (integer): integer = direct
                    return f { x = 1 }
                end
            ]],
            [[
                function run(): integer
                    return (function(x: integer): integer return x end) { x = 1 }
                end
            ]],
            [[
                record Box end
                function Box:add(x: integer): integer return x end
                function run(box: Box): integer
                    local f = box:add
                    return f { x = 1 }
                end
            ]],
            [[
                function direct(x: integer): integer return x end
                function run(): integer
                    local fs: {function (integer): integer} = { direct }
                    return fs[1] { x = 1 }
                end
            ]],
        }

        for _, code in ipairs(cases) do
            assert_checker_error(
                "named arguments require a direct Titan module function",
                code)
        end
    end)

    it("rejects variadic Titan functions and methods", function()
        local ok, err = run_checker([[
            record Box end

            function variadic(fixed: integer, ...: integer): integer
                return fixed
            end

            function Box:variadic(fixed: integer, ...: integer): integer
                return fixed
            end

            function bad_function(): integer
                return variadic { fixed = 1 }
            end

            function bad_method(box: Box): integer
                return box:variadic { fixed = 1 }
            end
        ]])
        assert.falsy(ok)
        assert.match("named arguments are not supported for variadic function 'variadic'", err)
        assert.match("named arguments are not supported for variadic method 'test%.Box:variadic'", err)
    end)

    describe("foreign functions", function()
        it("accepts complete names, keyword labels, void prototypes, and nullable omissions",
        function()
            with_header([[
                struct ffi_node;
                extern int ffi_reordered(int left, int right);
                extern int ffi_keyword(int repeat);
                extern int ffi_when(int when);
                extern int ffi_zero(void);
                extern int ffi_nullable(struct ffi_node *pointer, int required);
            ]], function(header)
                local ok, err = run_checker([[
                    foreign import "]] .. header .. [["

                    function run(): integer
                        local a: integer = ffi.ffi_reordered { right = 2, left = 1 }
                        local b: integer = ffi.ffi_keyword { repeat = 3 }
                        local w: integer = ffi.ffi_when { when = 5 }
                        local z: integer = ffi.ffi_zero {}
                        local n: integer = ffi.ffi_nullable { required = 4 }
                        return a + b + w + z + n
                    end
                ]])
                assert.truthy(ok, err)
            end)
        end)

        it("reports unknown, duplicate, and required scalar FFI arguments",
        function()
            with_header([[
                struct ffi_node;
                extern int ffi_named(int left, int right);
                extern int ffi_nullable(struct ffi_node *pointer, int required);
            ]], function(header)
                local prefix = "foreign import \"" .. header .. '"\n'
                local ok, err = run_checker(prefix .. [[
                    function unknown(): integer
                        return ffi.ffi_named { left = 1, unknown = 2 }
                    end
                    function duplicate(): integer
                        return ffi.ffi_named { left = 1, left = 2, right = 3 }
                    end
                    function required(): integer
                        return ffi.ffi_nullable { pointer = nil }
                    end
                ]])
                assert.falsy(ok)
                assert.match(
                    "function 'ffi%.ffi_named' has no parameter named 'unknown'",
                    err)
                assert.match("named argument 'left' is supplied more than once",
                    err)
                assert.match(
                    "parameter 'required'.-cannot be omitted because it does not accept nil",
                    err)
            end)
        end)

        it("distinguishes old-style, unnamed, partial, and conflicting metadata",
        function()
            with_header([[
                extern int ffi_old();
                extern int ffi_unnamed(int);
                extern int ffi_partial(int first, int);
                extern int ffi_duplicate(int same, int same);
                extern int ffi_conflict(int first, int second);
                extern int ffi_conflict(int left, int right);
                extern int ffi_conflict(int first, int second);
            ]], function(header)
                local names = {
                    "ffi_old", "ffi_unnamed", "ffi_partial", "ffi_duplicate",
                    "ffi_conflict",
                }
                local ok, err = run_checker(
                    "foreign import \"" .. header .. [["
                    local function run()
                        ffi.ffi_old {}
                        ffi.ffi_unnamed {}
                        ffi.ffi_partial {}
                        ffi.ffi_duplicate {}
                        ffi.ffi_conflict {}
                    end
                ]])
                assert.falsy(ok)
                local _, unavailable = err:gsub(
                    "parameter names are unavailable for foreign function",
                    "")
                assert.equal(5, unavailable)
                for _, name in ipairs(names) do
                    assert.match(
                        "parameter names are unavailable for foreign function 'ffi%."
                            .. name .. "'", err)
                end
            end)
        end)

        it("rejects C function pointers and pseudo-constructors", function()
            with_header([[
                typedef int (*ffi_callback)(int value);
                typedef int ffi_int;
            ]], function(header)
                local ok, err = run_checker(
                    "foreign import \"" .. header .. [["
                    local function callback(cb: foreign ffi_callback): integer
                        return cb { value = 1 } as integer
                    end
                    local function constructors()
                        local one = foreign ffi_int.new {}
                        local many = foreign ffi_int.new_array { count = 2 }
                    end
                ]])
                assert.falsy(ok)
                local _, rejected = err:gsub(
                    "named arguments require a direct Titan module function",
                    "")
                assert.equal(3, rejected)
            end)
        end)

        it("rejects C variadic named calls", function()
            with_header([[
                extern int ffi_variadic(int fixed, ...);
            ]], function(header)
                assert_checker_error(
                    "named arguments are not supported for variadic function 'ffi%.ffi_variadic'",
                    "foreign import \"" .. header .. [["
                    function run(): integer
                        return ffi.ffi_variadic { fixed = 1 }
                    end
                ]])
            end)
        end)

        it("keeps positional FFI calls strict", function()
            with_header([[
                extern int ffi_strict(int first, int second);
            ]], function(header)
                assert_checker_error(
                    "function 'ffi%.ffi_strict' called with 1 arguments but expects 2",
                    "foreign import \"" .. header .. [["
                    function run(): integer
                        return ffi.ffi_strict(1)
                    end
                ]])
            end)
        end)
    end)

    describe("record field omission", function()
        it("fills nil-compatible empty, partial, nested, duplicate, and pointer fields",
        function()
            with_header([[
                typedef struct ffi_node ffi_node;
            ]], function(header)
                local ok, err, ast = run_checker([[
                    foreign import "]] .. header .. [["

                    record Inner
                        note: string?
                        enabled: boolean
                    end

                    record Outer
                        child: Inner?
                        enabled: boolean
                        payload: value
                    end

                    local record PointerBox
                        pointer: foreign *ffi_node
                    end

                    local function construct(): Outer
                        local empty: Outer = {}
                        local partial: Outer = { enabled = true }
                        local nested: Outer = { child = {} }
                        local duplicate: Inner = {
                            note = "first",
                            note = "last",
                        }
                        local pointer: PointerBox = {}
                        return partial
                    end
                ]])
                assert.truthy(ok, err)

                local construct = find_toplevel(
                    ast, "Ast.TopLevelFunc", "construct")
                local duplicate = construct.block.stats[4].exps[1]
                assert.equal(3, #duplicate.fields)
                assert.equal("note", duplicate.fields[1].name)
                assert.equal("first", unwrap_cast(duplicate.fields[1].exp).value)
                assert.equal("note", duplicate.fields[2].name)
                assert.equal("last", unwrap_cast(duplicate.fields[2].exp).value)
                assert.equal("enabled", duplicate.fields[3].name)
                assert.truthy(duplicate.fields[3].exp._named_omitted)
            end)
        end)

        it("reports every required field that cannot be omitted", function()
            local err = assert_checker_error(
                "field 'first' of record 'test%.Required'.-cannot be omitted",
                [[
                    record Required
                        first: integer
                        second: string
                    end

                    function make(): Required
                        return {}
                    end
                ]])
            assert.match(
                "field 'second' of record 'test%.Required'.-cannot be omitted",
                err)
        end)

        it("fills nil-compatible local fields inside their declaring module",
        function()
            local ok, err = run_checker([[
                record Secret
                    local hidden: string?
                    shown: boolean
                end

                function make(): Secret
                    local empty: Secret = {}
                    local partial: Secret = { shown = true }
                    return partial
                end
            ]])
            assert.truthy(ok, err)
        end)

        it("rejects empty and partial external literals for records with local fields",
        function()
            local modules = {
                provider = [[
                    record Box
                        local hidden: string?
                        shown: boolean
                    end

                    function make(): Box
                        return {}
                    end
                ]],
                consumer = [[
                    local p = import "provider"

                    function empty(): p.Box
                        return {}
                    end

                    function partial(): p.Box
                        return { shown = true }
                    end
                ]],
            }
            local ok, err = run_checker_modules(modules, "consumer")
            assert.falsy(ok)
            assert.match(
                "cannot construct record type 'provider%.Box' outside module 'provider' because it has local fields",
                err)
            local _, count = err:gsub("cannot construct record type", "")
            assert.equal(2, count)

            modules.consumer = [[
                local p = import "provider"
                function bad(): p.Box
                    return p.Box.new {}
                end
            ]]
            ok, err = run_checker_modules(modules, "consumer")
            assert.falsy(ok)
            assert.match("trying to access invalid record function 'new'", err)
        end)

        it("applies omission normally to imported records without local fields",
        function()
            assert_modules_ok({
                provider = [[
                    record Public
                        label: string?
                        enabled: boolean
                        payload: value
                    end
                ]],
                consumer = [[
                    local p = import "provider"

                    function empty(): p.Public
                        return {}
                    end

                    function partial(): p.Public
                        return { label = "set" }
                    end

                    function via_new(): p.Public
                        return p.Public.new {}
                    end
                ]],
            }, "consumer")
        end)
    end)
end)

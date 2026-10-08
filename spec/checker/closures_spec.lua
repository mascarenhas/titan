local temporary = require "spec.support.temporary"
-- Checker-level coverage for anonymous functions (lambdas): capture analysis
-- flags, parameter/return type inference, and the errors around them. These run
-- the checker only; end-to-end closure behavior lives in the coder specs.
local h = require 'spec.support.helpers'

local run_checker = h.run_checker
local assert_type_check = h.assert_type_check
local assert_type_error = h.assert_type_error

local function with_header(contents, fn)
    local header = temporary.name(".h")
    local file = assert(io.open(header, "w"))
    assert(file:write(contents))
    assert(file:close())

    local results = table.pack(pcall(fn, header))
    os.remove(header)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

local function captured_lambda_source(count)
    local declarations, terms = {}, {}
    for i = 1, count do
        declarations[#declarations + 1] =
            string.format("local capture_%03d: integer = %d", i, i)
        terms[#terms + 1] = string.format("capture_%03d", i)
    end
    return string.format([[
        function make(): function (): (integer)
            %s
            return function(): integer
                return %s
            end
        end
    ]], table.concat(declarations, "\n"), table.concat(terms, " + "))
end

-- Walk the (post-checker) AST to the n-th top-level function's body statements.
local function tlfunc_stats(ast, n)
    return ast[n or 1].block.stats
end

describe("closures (capture analysis)", function()
    it("flags a captured-and-mutated local (boxed counter)", function()
        local ok, err, ast = run_checker([[
            function make(): function (): integer
                local n: integer = 0
                local inc = function(): integer
                    n = n + 1
                    return n
                end
                return inc
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(n._captured)
        assert.is_true(n._assigned)
        assert.is_true(n._used)
    end)

    it("flags a captured-immutable local (not assigned)", function()
        local ok, err, ast = run_checker([[
            function make(): function (): integer
                local n: integer = 7
                local get = function(): integer return n end
                return get
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(n._captured)
        assert.is_nil(n._assigned)
    end)

    it("does not flag a mutated-but-not-captured local", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local n: integer = 0
                n = n + 1
                return n
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(n._captured)
        assert.is_true(n._assigned)
    end)

    it("does not flag a local that is neither captured nor mutated", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local n: integer = 3
                return n
            end
        ]])
        assert.truthy(ok, err)
        local n = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(n._captured)
        assert.is_nil(n._assigned)
    end)

    it("a shadowing inner local does not capture the outer one", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local x: integer = 1
                local g = function(): integer
                    local x: integer = 2
                    return x
                end
                return x
            end
        ]])
        assert.truthy(ok, err)
        local outer = tlfunc_stats(ast)[1].decls[1]
        assert.is_nil(outer._captured)
    end)

    it("captures transitively across three function levels", function()
        local ok, err, ast = run_checker([[
            function f(): integer
                local a: integer = 1
                local b = function(): function (): integer
                    local c = function(): integer
                        return a
                    end
                    return c
                end
                return 1
            end
        ]])
        assert.truthy(ok, err)
        local a = tlfunc_stats(ast)[1].decls[1]
        assert.is_true(a._captured)
        assert.equal(1, a._funcdepth)
    end)

    it("captures a parameter of the enclosing function", function()
        local ok, err, ast = run_checker([[
            function adder(x: integer): function (): integer
                local g = function(): integer return x end
                return g
            end
        ]])
        assert.truthy(ok, err)
        local x = ast[1].params[1]
        assert.is_true(x._captured)
    end)

    it("captures `self` of an enclosing method", function()
        -- A lambda nested in a method body captures `self` like any parameter:
        -- `self` is declared at the method's own func-depth (checkfuncbody).
        local ok, err, ast = run_checker([[
            record C n: integer end
            function C:m(): function (): integer
                local g = function(): integer return self.n end
                return g
            end
        ]])
        assert.truthy(ok, err)
        local m = ast[#ast]
        assert.equal("Ast.TopLevelMethod", m._tag)
        assert.is_true(m._self._captured)
    end)

    it("a captured `for` control variable is not marked assigned", function()
        -- The implicit increment must not set `_assigned`, so a captured `for`
        -- variable stays immutable -> by-value (never boxed) -> fresh per
        -- iteration. (§3/§4.2 invariant.)
        local ok, err, ast = run_checker([[
            function f(): {function (): integer}
                local fns: {function (): integer} = {}
                for i = 1, 3 do
                    fns[i] = function(): integer return i end
                end
                return fns
            end
        ]])
        assert.truthy(ok, err)
        -- the `for` statement is the second stat of f's body; its control decl
        local forstat = tlfunc_stats(ast)[2]
        assert.equal("Ast.StatFor", forstat._tag)
        assert.is_true(forstat.decl._captured)
        assert.is_nil(forstat.decl._assigned)
    end)

    it("accepts 250 captures and rejects the first unrepresentable closure",
    function()
        local ok, err = run_checker(captured_lambda_source(250))
        assert.truthy(ok, err)

        ok, err = run_checker(captured_lambda_source(251))
        assert.falsy(ok)
        assert.match(
            "function captures too many variables %(251, max 250%)", err)
    end)
end)

describe("closures (parameter inference)", function()
    it("infers a param type from an assignment-target function type", function()
        assert_type_check([[
            function f(): integer
                local g: function (integer): integer = function(x) return x + 1 end
                return g(2)
            end
        ]])
    end)

    it("infers a param type from an argument-position function type", function()
        assert_type_check([[
            function apply(g: function (integer): integer, x: integer): integer
                return g(x)
            end
            function f(): integer
                return apply(function(y) return y + 1 end, 5)
            end
        ]])
    end)

    it("infers a param type from a return-position function type", function()
        assert_type_check([[
            function make(): function (integer): integer
                return function(x) return x * 2 end
            end
        ]])
    end)

    it("uses the annotation when a param is annotated", function()
        assert_type_check([[
            function f(): integer
                local g: function (integer): integer = function(x: integer) return x end
                return g(1)
            end
        ]])
    end)

    it("errors on an unannotated param with no usable context", function()
        assert_type_error("cannot infer type of parameter 'x'", [[
            function f(): integer
                local g = function(x) return x end
                return 1
            end
        ]])
    end)

end)

describe("closures (return inference)", function()
    it("infers a single return type from an assignment-target function type", function()
        assert_type_check([[
            function f(): integer
                local g: function (integer): integer = function(x) return x + 1 end
                return g(2)
            end
        ]])
    end)

    it("infers a multi return type from the context function type", function()
        assert_type_check([[
            function f(): integer
                local g: function (integer): (integer, integer) =
                    function(x) return x, x + 1 end
                local a: integer, b: integer = g(2)
                return a + b
            end
        ]])
    end)

    it("infers a return type from an argument-position function type", function()
        assert_type_check([[
            function apply(g: function (integer): integer, x: integer): integer
                return g(x)
            end
            function f(): integer
                return apply(function(y) return y + 1 end, 5)
            end
        ]])
    end)

    it("infers a return type from a return-position function type", function()
        assert_type_check([[
            function make(): function (integer): integer
                return function(x) return x * 2 end
            end
        ]])
    end)

    it("checks the body against the context-inferred return type", function()
        -- The body's `return` is checked/coerced against the context's return
        -- type, not used to synthesize it: an integer return coerces to float.
        assert_type_check([[
            function f(): float
                local g: function (integer): float = function(x) return x end
                return g(2)
            end
        ]])
    end)

    it("rejects a body return that mismatches the context return type", function()
        assert_type_error("types in return do not match", [[
            function f(): integer
                local g: function (integer): string = function(x) return x end
                return 1
            end
        ]])
    end)

    it("defaults to zero-return with no context and an empty body", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer) end
                g(1)
                return 1
            end
        ]])
    end)

    it("treats an explicit `: ()` as zero-return", function()
        assert_type_check([[
            function f(): integer
                local g = function(x: integer): () end
                g(1)
                return 1
            end
        ]])
    end)

    it("lets explicit `: ()` override a result-bearing context", function()
        local ok, err, ast = run_checker([[
            function f()
                local g: function (integer): value = function(x): () end
            end
        ]])
        assert.truthy(ok, err)
        local cast = tlfunc_stats(ast)[1].exps[1]
        assert.equal("Ast.ExpCast", cast._tag)
        assert.equal("callable", cast._adjustment.kind)
        assert.equal("Ast.ExpFunction", cast.exp._tag)
        assert.equal(0, #cast.exp._type.rettypes)
        assert.equal("Type.Value", cast._type.rettypes[1]._tag)
    end)

    it("zero-return is the default with no context, so body results are discarded", function()
        -- No return annotation and no usable context defaults the lambda to
        -- zero-return `()`, exactly like an unannotated top-level function, so a
        -- `return <expr>` is checked for effects and its value is ignored.
        assert_type_check([[
            function f(): integer
                local g = function(x: integer) return x + 1 end
                return 1
            end
        ]])
    end)
end)

describe("closures (immediate invocation preserves source checking)", function()
    it("does not infer an immediate literal's parameter from its argument", function()
        assert_type_error("cannot infer type of parameter 'item'", [[
            function run(): integer
                return (function (item): integer return 42 end)(1)
            end
        ]])
    end)

    it("does not infer an immediate literal's return shape from its consumer", function()
        assert_type_error("expression list produces 0", [[
            function run(): integer
                local result: integer = (function () return 42 end)()
                return result
            end
        ]])
    end)

    it("keeps enclosing varargs outside an immediate literal's function scope", function()
        assert_type_error("'%.%.%.' is not visible inside an inner function", [[
            function run(...: integer): integer
                return (function (): integer return #... end)()
            end
        ]])
    end)

    it("preserves immediate literal and capture identities for source analysis", function()
        local checker = require "titan-compiler.checker"
        local source = [[
            function run(): integer
                local outer = 7
                return (function (): integer return outer end)()
            end
        ]]
        h.reset(true)
        local ast = assert(h.parse(source, "test.titan"))
        local _, errors = checker.check("test", ast, source, "test.titan",
            nil, { analysis_only = true })
        assert.equal(0, #errors, table.concat(errors, "\n"))
        assert.is_true(ast._analysis_only)
        local stats = tlfunc_stats(ast)
        local declaration = stats[1].decls[1]
        local call = stats[2].exps[1]
        assert.equal("Ast.ExpCall", call._tag)
        local literal = call.exp
        assert.equal("Ast.ExpFunction", literal._tag)
        assert.equal(declaration, literal._captures[1])
        assert.equal(declaration, literal.block.stats[1].exps[1].var._decl)
        assert.is_true(declaration._captured)
    end)
end)

describe("closures (top-level lambda initializer is sound)", function()
    it("accepts a top-level `local f = function...end`", function()
        -- Constructing a lambda reads no module variable's value (the body runs
        -- only when the closure is later called), so it is a sound top-level
        -- initializer: a module *variable* holding a function, callable through
        -- the first-class value path and reassignable at runtime.
        assert_type_check([[
            local f = function(x: integer): integer return x + 1 end
        ]])
    end)

    it("accepts an exported top-level function-typed module variable", function()
        assert_type_check([[
            local f = function(x: integer): integer return x * 2 end
            function apply(x: integer): integer return f(x) end
            function setf(g: function (integer): integer) f = g end
        ]])
    end)

    it("still rejects a genuinely non-const top-level initializer (a = b)", function()
        -- Reading another module variable's value during init is unsound (b may
        -- not be initialized yet), so it must still be rejected.
        assert_type_error("top level variable initialization must be constant", [[
            b = 1
            a = b
        ]])
    end)

    it("rejects record constructors whose arguments read module state", function()
        assert_type_error("top level variable initialization must be constant", [[
            record R
                x: integer
            end
            source = 1
            local r = R.new(source)
        ]])
    end)

    it("accepts a parenthesized constant record constructor", function()
        assert_type_check([[
            record R
                x: integer
            end
            local r = (R.new(1))
        ]])
    end)

    it("rejects map initializers whose keys read module state", function()
        assert_type_error("top level variable initialization must be constant", [[
            key = 1
            local m = { [key] = 42 }
        ]])
    end)
end)

describe("closures (still-an-error cases)", function()
    it("rejects a self-reference inside its own anonymous initializer", function()
        -- `f` only binds after its initializer is checked, so the inner `f` is
        -- a clean 'not declared' error, not a silent miscompile (D2).
        assert_type_error("variable 'f' not declared", [[
            function g(): integer
                local f: function (integer): integer = function(n: integer): integer
                    return f(n)
                end
                return 1
            end
        ]])
    end)

    it("names a lambda generically in the duplicate-parameter error", function()
        -- A lambda has no name; the message must say "anonymous function", not
        -- "declaration of function 'nil'".
        assert_type_error("duplicate parameter 'x' in anonymous function", [[
            function g(): integer
                local f: function (integer, integer): integer =
                    function(x: integer, x: integer): integer return x end
                return 1
            end
        ]])
    end)
end)

describe("bound method references (obj:m)", function()
    it("a bound method has the method's type with self removed", function()
        local ok, err, ast = run_checker([[
            record Adder base: integer end
            function Adder:add(x: integer): integer
                return self.base + x
            end
            function use(): function (integer): integer
                local a = Adder.new(0)
                local f = a:add
                return f
            end
        ]])
        assert.truthy(ok, err)
        -- `use` is the last top-level; its body declares `f = a:add`
        local fnode = ast[#ast]
        local fdecl = fnode.block.stats[2]
        local ftype = fdecl.decls[1]._type
        assert.equal("Type.Function", ftype._tag)
        assert.equal(1, #ftype.params)
        assert.equal("Type.Integer", ftype.params[1]._tag)
        assert.equal(1, #ftype.rettypes)
        assert.equal("Type.Integer", ftype.rettypes[1]._tag)
    end)

    it("typechecks where a matching function value is expected", function()
        assert_type_check([[
            record Adder base: integer end
            function Adder:add(x: integer): integer return self.base + x end
            function use(): integer
                local a = Adder.new(1)
                local f: function (integer): integer = a:add
                return f(2)
            end
        ]])
    end)

    it("rejects a bound method bound to an incompatible function type", function()
        assert_type_error(
            "do not match, expected function %(string%): string but found function %(integer%): integer",
            [[
                record Adder base: integer end
                function Adder:add(x: integer): integer return self.base + x end
                function use()
                    local a = Adder.new(1)
                    local f: function (string): string = a:add
                end
            ]])
    end)

    it("rejects a method reference on a non-record receiver", function()
        assert_type_error("expected record in receiver of method reference", [[
            function use()
                local n = 3
                local f = n:bump
            end
        ]])
    end)

    it("rejects a reference to a non-existent method", function()
        assert_type_error("method 'nope' not found in record", [[
            record Adder base: integer end
            function use()
                local a = Adder.new(1)
                local f = a:nope
            end
        ]])
    end)

    it("rejects a foreign (C) method reference", function()
        with_header("extern double ffi_abs(double value);\n", function(header)
            assert_type_error(
                "trying to access module 'ffi' as a first%-class value", [[
                    foreign import "]] .. header .. [["
                    function use()
                        local f = ffi:ffi_abs
                    end
                ]])
        end)
    end)

    it("accepts a top-level method-ref initializer with a const receiver", function()
        -- Binding `obj:m` evaluates the receiver now to capture self; a
        -- constructor call with const args is itself a sound (const) receiver,
        -- so the whole bind is a sound top-level initializer.
        assert_type_check([[
            record Adder base: integer end
            function Adder:add(x: integer): integer return self.base + x end
            local f = Adder.new(1):add
        ]])
    end)

    it("rejects a top-level method-ref initializer with a non-const receiver", function()
        -- The receiver here reads another module variable (`a`, an ExpVar), so
        -- binding `a:add` at init time may read a not-yet-initialized variable:
        -- still unsound, still rejected.
        assert_type_error("top level variable initialization must be constant", [[
            record Adder base: integer end
            function Adder:add(x: integer): integer return self.base + x end
            a = Adder.new(1)
            local f = a:add
        ]])
    end)
end)

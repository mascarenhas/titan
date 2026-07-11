local checker = require 'titan-compiler.checker'
local types = require 'titan-compiler.types'
local coder = require 'titan-compiler.coder'
local driver = require 'titan-compiler.driver'
local util = require 'titan-compiler.util'
local h = require 'spec.support.helpers'

local parse = h.parse
local compile = h.compile
local call = h.call
local call_app = h.call_app
local compile_and_read_c = h.compile_and_read_c
local run_coder = h.run_coder
local run_coder_app = h.run_coder_app
local generate_modules = h.generate_modules

local function clean()
    os.execute("rm -rf *.o *.so *.dSYM")
    if not h.verbose then os.execute("rm -f *.c") end
end

describe("zero-return () functions (code generator)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("exported () function returns zero values across the Lua boundary", function()
        run_coder([[
            function noop(): ()
            end
            function effect(x: {integer}): ()
                x[1] = 42
            end
        ]], [[
            assert(select('#', test.noop()) == 0)
            local t = {0}
            test.effect(t)
            assert(t[1] == 42)
            assert(select('#', test.effect(t)) == 0)
        ]])
    end)

    it("internal statement-context call + bare return", function()
        run_coder([[
            local function helper(x: {integer}): ()
                x[1] = x[1] + 1
                return
            end
            function bump(x: {integer}): integer
                helper(x)
                helper(x)
                return x[1]
            end
        ]], [[
            assert(test.bump({10}) == 12)
        ]])
    end)

    it("(f()) adjusts a void call up to a single nil", function()
        run_coder([[
            local function vd(): ()
            end
            function adj(): value
                return (vd())
            end
        ]], [[
            assert(select('#', test.adj()) == 1)
            assert(test.adj() == nil)
        ]])
    end)

    it("an explicit : nil return still yields one nil value", function()
        run_coder([[
            function n(): nil
            end
        ]], [[
            assert(select('#', test.n()) == 1)
            assert(test.n() == nil)
        ]])
    end)
end)

describe("call sequencing regressions", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    it("short-circuits boolean calls with side effects", function()
        run_coder([[
            seen: integer = 0
            function yes(): boolean return true end
            function no(): boolean return false end
            function mark(): boolean
                seen = seen + 1
                return true
            end
            function run_or(): integer
                seen = 0
                if yes() or mark() then end
                return seen
            end
            function run_and(): integer
                seen = 0
                if no() and mark() then end
                return seen
            end
        ]], [[
            assert(test.run_or() == 0)
            assert(test.run_and() == 0)
        ]])
    end)

    it("evaluates static-call arguments and binary operands left-to-right", function()
        run_coder([[
            seen: integer = 0
            function bump(): integer
                seen = seen + 1
                return seen
            end
            function take(a: integer, b: integer): integer
                return a * 10 + b
            end
            function args(): integer
                seen = 0
                return take(seen, bump())
            end
            function trailing_read(): integer
                seen = 0
                return take(bump(), seen)
            end
            function two_calls(): integer
                seen = 0
                return take(bump(), bump())
            end
            function binary(): integer
                seen = 0
                return seen * 10 + bump()
            end
        ]], [[
            assert(test.args() == 1)
            assert(test.trailing_read() == 11)
            assert(test.two_calls() == 12)
            assert(test.binary() == 1)
        ]])
    end)

    it("discards a non-void static result without compiler warnings", function()
        local oldflags = driver.CFLAGS
        driver.CFLAGS = oldflags .. " -Werror"
        local ok, err = pcall(run_coder, [[
            function answer(): integer return 42 end
            function discard()
                answer()
            end
        ]], [[
            test.discard()
        ]])
        driver.CFLAGS = oldflags
        assert.truthy(ok, err)
    end)
end)

describe("Titan code generator", function()
    setup(function ()
        os.remove("titan-runtime/titan.o")
    end)

    after_each(clean)

    it("deletes array element", function()
        local code = [[
            function delete(array: {integer}, i: integer)
                array[i] = nil
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={1,2,3};titan_test.delete(arr,3);assert(#arr==2)")
        assert.truthy(ok, err)
    end)

    it("handles array indices beyond the unsigned int range", function()
        local code = [[
            function setget(xs: {integer}, i: integer, v: integer): integer
                xs[i] = v
                return xs[i]
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        -- (i - 1) truncated to 32 bits lands inside the array part, so a
        -- narrow index computation in the write path clobbers arr[1]/arr[2]
        local ok, err = call("titan_test", [[
            local arr = {10, 20, 30}
            local i = (1 << 32) + 1
            assert(titan_test.setget(arr, i, 99) == 99)
            assert(arr[1] == 10)
            assert(arr[i] == 99)
            local j = -((1 << 32) - 2)
            assert(titan_test.setget(arr, j, 55) == 55)
            assert(arr[2] == 20)
            assert(arr[j] == 55)
        ]])
        assert.truthy(ok, err)
    end)

    it("tests nil element", function()
        local code = [[
            function testset(t: {integer}, i: integer, v: integer): integer
                if t[i] then
                  return t[i]
                else
                  t[i] = v
                  return t[i]
                end
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.testset(arr,1,2)==2);assert(titan_test.testset(arr,1,3)==2)")
        assert.truthy(ok, err)
    end)

    it("tests nil element in 'while'", function()
        local code = [[
            function testfill(t: {integer}, i: integer, v: integer)
                while not t[i] and i > 0 do
                    t[i] = v
                    i = i - 1
                end
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};titan_test.testfill(arr,5,2);assert(#arr==5)")
        assert.truthy(ok, err)
    end)

    it("tests nil element in 'repeat'", function()
        local code = [[
            function testfill(t: {integer}, i: integer, v: integer)
                repeat
                    t[i] = v
                    i = i - 1
                until t[i] or i == 0
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};titan_test.testfill(arr,5,2);assert(#arr==5)")
        assert.truthy(ok, err)
    end)

    it("coerces an option-typed 'while' condition", function()
        run_coder([[
            function sum_until_nil(xs: {integer}): integer
                local sum: integer = 0
                local i: integer = 1
                while xs[i] do
                    sum = sum + xs[i]
                    i = i + 1
                end
                return sum
            end
        ]], [[
            assert(test.sum_until_nil({10, 20, 30}) == 60)
            assert(test.sum_until_nil({}) == 0)
        ]])
    end)

    it("coerces an option-typed 'repeat' condition", function()
        run_coder([[
            function first_present(xs: {integer}): integer
                local i: integer = 0
                repeat
                    i = i + 1
                until xs[i]
                return i
            end
        ]], [[
            assert(test.first_present({5, 6}) == 1)
        ]])
    end)

    it("unwraps an option-typed variable to its base type", function()
        run_coder([[
            function unwrap_present(): integer
                local x: integer? = 5
                return x
            end
        ]], [[
            assert(test.unwrap_present() == 5)
        ]])
    end)

    it("raises a typed error unwrapping a nil option", function()
        run_coder([[
            function unwrap_nil(xs: {integer}): integer
                local x: integer? = xs[10]
                return x
            end
        ]], [[
            test.unwrap_nil({1, 2, 3})
        ]], "expected integer but found nil")
    end)

    it("concatenates an option value, unwrapping it", function()
        run_coder([[
            function catopt(): string
                local x: integer? = 5
                return x .. "!"
            end
        ]], [[
            assert(test.catopt() == '5!')
        ]])
    end)

    it("unwraps an option returned directly by a call", function()
        run_coder([[
            function opt(): integer? return 9 end
            function ucall(): integer return opt() end
        ]], [[
            assert(test.ucall() == 9)
        ]])
    end)

    it("forwards a bare multiple-return call in return position", function()
        run_coder([[
            function divmod(a: integer, b: integer): (integer, integer)
                return a // b, a % b
            end
            function bare(): (integer, integer)
                return divmod(13, 2)
            end
            function mixed(): (integer, integer, integer)
                return 10, divmod(13, 2)
            end
        ]], [[
            local q, r = test.bare()
            assert(q == 6 and r == 1, 'bare=' .. q .. ',' .. r)
            local a, b, c = test.mixed()
            assert(a == 10 and b == 6 and c == 1, 'mixed=' .. a .. ',' .. b .. ',' .. c)
        ]])
    end)

    it("expands a multiple-return call in the last argument position", function()
        run_coder([[
            function divmod(a: integer, b: integer): (integer, integer)
                return a // b, a % b
            end
            function add3(a: integer, b: integer, c: integer): integer
                return a + b + c
            end
            function add2(a: integer, b: integer): integer
                return a + b
            end
            function trailing(): integer return add3(10, divmod(7, 2)) end
            function adjusted(): integer return add2(divmod(7, 2), 100) end
            function two(): (string, string) return "a", "b" end
            function cat2(x: string, y: string): string return x .. y end
            function gc(): string return cat2(two()) end
        ]], [[
            assert(test.trailing() == 14, 'trailing')
            assert(test.adjusted() == 103, 'adjusted')
            assert(test.gc() == 'ab', 'gc')
        ]])
    end)

    it("combines array-of-records and map-of-records constructors with element assignments", function()
        run_coder([[
            record P
                x: float
            end
            function boom(): float
                local arr: {P} = { { x = 1.0 }, { x = 2.0 } }
                local m: {integer: P} = { [1] = { x = 3.0 } }
                arr[1] = { x = 4.0 }
                m[2] = { x = 5.0 }
                return arr[1].x + m[2].x
            end
        ]], [[
            assert(test.boom() == 9.0)
        ]])
    end)

    it("compares strings by content and lexicographically", function()
        run_coder([[
            function eq(a: string, b: string): boolean return a == b end
            function lt(a: string, b: string): boolean return a < b end
            function ge(a: string, b: string): boolean return a >= b end
        ]], [[
            local l1 = string.rep('0123456789', 5)
            local l2 = string.rep('0123456789', 5)
            assert(test.eq(l1, l2) == true)
            assert(test.lt('Z', 'a') == true)
            assert(test.lt('abc', 'abcd') == true)
            assert(test.lt('abc', 'abc') == false)
            assert(test.ge('b', 'a') == true)
        ]])
    end)

    it("evaluates and/or for their value", function()
        run_coder([[
            function tern(a: integer, b: integer): integer
                local x: integer = (a > b) and a or b
                return x
            end
            function chain(a: integer, b: integer, c: integer): boolean
                return a == 1 and b == 2 and c == 3
            end
            function find(xs: {integer}, v: integer): integer?
                for i = 1, #xs do if xs[i] == v then return i end end
                return nil
            end
            function findor(xs: {integer}, v: integer): integer
                return find(xs, v) or 0
            end
        ]], [[
            assert(test.tern(3, 5) == 5)
            assert(test.tern(5, 3) == 5)
            assert(test.chain(1, 2, 3) == true)
            assert(test.chain(1, 2, 4) == false)
            assert(test.findor({10, 20, 30}, 20) == 2)
            assert(test.findor({10, 20, 30}, 99) == 0)
        ]])
    end)

    it("compiles a Lua-faithful numeric for (overflow-safe, copy semantics)", function()
        run_coder([[
            function up(): integer local s: integer = 0 for i = 1, 10 do s = s + i end return s end
            function down(): integer local s: integer = 0 for i = 5, 1, -1 do s = s + i end return s end
            function ov(hi: integer): integer local n: integer = 0 for i = hi - 2, hi do n = n + 1 end return n end
        ]], [[
            assert(test.up() == 55)
            assert(test.down() == 15)
            assert(test.ov(9223372036854775807) == 3)
        ]])
    end)

    it("terminates a for loop at the integer limits (issue #59)", function()
        -- Stepping past LUA_MAXINTEGER (or below LUA_MININTEGER) must not wrap
        -- around into a non-terminating loop; the unsigned trip count prevents
        -- that. The down() case also exercises the LUA_MININTEGER literal.
        run_coder([[
            function up(nth: integer): integer
                local c: integer = 0
                for i = 0x7FFFFFFFFFFFFFF8, 0x7FFFFFFFFFFFFFFF do
                    c = c + 1
                    if c == nth then return i end
                end
                return 0
            end
            function down(nth: integer): integer
                local c: integer = 0
                for i = 0x8000000000000007, 0x8000000000000000, -1 do
                    c = c + 1
                    if c == nth then return i end
                end
                return 0
            end
        ]], [[
            assert(test.up(8) == 9223372036854775807)
            assert(test.up(9) == 0)        -- must terminate, not hang
            assert(test.down(8) == -9223372036854775808)
            assert(test.down(9) == 0)      -- must terminate, not hang
        ]])
    end)

    it("raises on a zero for step like Lua", function()
        run_coder([[
            function f(): integer
                local s: integer = 0
                for i = 1, 10, 0 do s = s + 1 end
                return s
            end
        ]], [[
            test.f()
        ]], "'for' step is zero")
    end)

    it("lets the until condition see body-local variables", function()
        run_coder([[
            function f(xs: {integer}): integer
                local i: integer = 0
                repeat
                    i = i + 1
                    local v: integer = xs[i]
                until v > 5 or i >= #xs
                return i
            end
        ]], [[
            assert(test.f({1, 2, 8, 9}) == 3)
        ]])
    end)

    it("assigns a record constructor to a module variable in a function", function()
        run_coder([[
            record Point x: float y: float end
            g: Point = Point.new(0.0, 0.0)
            function setg() g = { x = 1.0, y = 2.0 } end
            function getg(): float setg() return g.x + g.y end
        ]], [[
            assert(test.getg() == 3.0)
        ]])
    end)

    it("resets the stack top on an early return", function()
        run_coder([[
            function f(): integer
                if 1 == 1 then return 1 end
                local y: string = "x"
                return #y
            end
        ]], [[
            assert(test.f() == 1)
        ]])
    end)

    it("accepts a bare return in a nil-returning function", function()
        run_coder([[
            function f(x: integer) if x > 0 then return end end
            function g(): integer f(1) f(-1) return 42 end
        ]], [[
            assert(test.g() == 42)
        ]])
    end)

    it("builds forward-referenced records", function()
        run_coder([[
            record A b: B end
            record B v: integer end
            function mk(n: integer): integer
                local a: A = { b = { v = n } }
                return a.b.v
            end
        ]], [[
            assert(test.mk(7) == 7)
        ]])
    end)

    it("converts an integral float for an integer? parameter", function()
        run_coder([[
            function f(x: integer?): integer return x end
        ]], [[
            assert(test.f(3.0) == 3)
            assert(test.f(5) == 5)
        ]])
    end)

    it("converts a cross-base option (t1? -> t2?), propagating nil", function()
        run_coder([[
            function i2f(x: integer?): float? return x end
            function f2i(x: float?): integer? return x end
        ]], [[
            assert(test.i2f(5) == 5.0)
            assert(test.i2f(nil) == nil)
            assert(test.f2i(5.0) == 5)
            assert(test.f2i(nil) == nil)
            assert(pcall(function() return test.f2i(1.5) end) == false)
        ]])
    end)

    it("keeps nil distinct from false when coercing nil to boolean?", function()
        -- regression: coercing nil to an option whose base nil is itself
        -- coerceable to (boolean) must yield nil, not the base's coercion of
        -- nil (false). classify must take the else (nil) branch, returning 0.
        run_coder([[
            function classify_init(): integer
                local b: boolean? = nil
                if b == true then return 1
                elseif b == false then return 2
                else return 0 end
            end
            function classify_assign(): integer
                local b: boolean? = true
                b = nil
                if b == true then return 1
                elseif b == false then return 2
                else return 0 end
            end
            function classify_return(): boolean?
                return nil
            end
            function classify_param(b: boolean?): integer
                if b == true then return 1
                elseif b == false then return 2
                else return 0 end
            end
        ]], [[
            assert(test.classify_init() == 0)
            assert(test.classify_assign() == 0)
            assert(test.classify_return() == nil)
            assert(test.classify_param(nil) == 0)
            -- present values still round-trip correctly
            assert(test.classify_param(true) == 1)
            assert(test.classify_param(false) == 2)
        ]])
    end)

    it("coerces nil to value? as nil, not a non-nil value", function()
        -- value is another base nil is coerceable to; nil -> value? must be nil
        run_coder([[
            function v(): value
                local x: value? = nil
                if x == nil then return 1 else return 0 end
            end
        ]], [[
            assert(test.v() == 1)
        ]])
    end)

    it("tests integer step value in 'for'", function()
        local code = [[
            function forstep(f: integer, t: integer, s: integer): integer
                local v: integer = 0
                for i = f, t, s do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep(1,10,2);assert(x==25)")
        assert.truthy(ok, err)
    end)

    it("tests integer postive literals in 'for'", function()
        local code = [[
            function forstep(): integer
                local v: integer = 0
                for i = 1, 10, 2 do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep();assert(x==25)")
        assert.truthy(ok, err)
    end)

    it("tests integer negative literals in 'for'", function()
        local code = [[
            function forstep(): integer
                local v: integer = 0
                for i = 10, 1, -2 do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep();assert(x==30)")
        assert.truthy(ok, err)
    end)

    it("tests float step value in 'for'", function()
        local code = [[
            function forstep(f: float, t: float, s: float): float
                local v: float = 0
                for i = f, t, s do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep(1.5,10.5,0.5);assert(x==114.0)")
        assert.truthy(ok, err)
    end)

    it("tests float positive literals in 'for'", function()
        local code = [[
            function forstep(): float
                local v: float = 0
                for i = 1.5, 10.5, 0.5 do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep();assert(x==114.0)")
        assert.truthy(ok, err)
    end)

    it("tests float negative literals in 'for'", function()
        local code = [[
            function forstep(): float
                local v: float = 0
                for i = 9.5, 1.5, -0.5 do
                    v = v + i
                end
                return v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "x = titan_test.forstep();assert(x==93.5)")
        assert.truthy(ok, err)
    end)

    it("tests nil element in 'not'", function()
        local code = [[
            function testset(t: {integer}, i: integer, v: integer): integer
                if not t[i] then
                  t[i] = v
                end
                return t[i]
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.testset(arr,1,2)==2);assert(titan_test.testset(arr,1,3)==2)")
        assert.truthy(ok, err)
    end)

    it("tests nil element in 'and'", function()
        local code = [[
            function testset(t: {integer}, i: integer, v: integer): integer
                if t[i] and v then
                  return t[i]
                else
                  t[i] = v
                  return t[i]
                end
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.testset(arr,1,2)==2);assert(titan_test.testset(arr,1,3)==2)")
        assert.truthy(ok, err)
    end)

    it("tests nil element in 'or'", function()
        local code = [[
            function testset(t: {integer}, i: integer, v: integer): integer
                if not t[i] or not t[i] then
                  t[i] = v
                end
                return t[i]
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.testset(arr,1,2)==2);assert(titan_test.testset(arr,1,3)==2)")
        assert.truthy(ok, err)
    end)

    it("tests 'or' pattern", function()
        local code = [[
            function getor(t: {integer}, i: integer, v: integer): integer
                return t[i] or v
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.getor(arr,1,2)==2);arr[1]=2;assert(titan_test.getor(arr,1,3)==2)")
        assert.truthy(ok, err)
    end)

    it("tests 'and' pattern", function()
        local code = [[
            function ternary(t: {integer}, i: integer, v1: integer, v2: integer): integer
                return t[i] and v1 or v2
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={};assert(titan_test.ternary(arr,1,3,2)==2);arr[1]=2;assert(titan_test.ternary(arr,1,2,3)==2)")
        assert.truthy(ok, err)
    end)

    it("pass integers when expecting floats in array", function()
        local code = [[
            function sum(array: {float}): float
                local res = 0.0
                for i = 1, #array do
                    res = res + array[i]
                end
                return res
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "arr={1,2,3};assert(6==titan_test.sum(arr))")
        assert.truthy(ok, err)
    end)

    it("pass integers when expecting floats in argument", function()
        local code = [[
            function sum(a: float, b: float, c: float): float
                return a + b + c
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(6==titan_test.sum(1,2,3))")
        assert.truthy(ok, err)
    end)

    it("generates code for returning 'if'", function()
        local code = [[
			function abs(x:integer): integer
    			if x < 0 then return -x end
    			return x
			end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("titan_test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.abs(-1) == 1);assert(titan_test.abs(0) == 0);assert(titan_test.abs(1) == 1)")
        assert.truthy(ok, err)
    end)

    it("generates code for 'elseif'", function()
        local code = [[
            function getval(a: integer): integer
                if a == 1 then
                    return 10
                elseif a == 2 then
                    return 20
                else
                    return 30
                end
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.getval(1) == 10);assert(titan_test.getval(2) == 20);assert(titan_test.getval(3) == 30)")
        assert.truthy(ok, err)
    end)

    it("generates code for 'elseif' with overlapping conditions", function()
        local code = [[
            function getval(a: integer): integer
                local b = 0
                if a > 2 then
                    b = 10
                elseif a > 1 then
                    b = 20
                else
                    b = 30
                end
                return b
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.getval(2) == 20);assert(titan_test.getval(3) == 10);assert(titan_test.getval(1) == 30)")
        assert.truthy(ok, err)
    end)

    it("generates code for integer module-local variables", function()
        local code = [[
            local a: integer = 1
            function geta(): integer
                return a
            end
            function seta(x: integer)
                a = x
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.geta() == 1);titan_test.seta(2);assert(titan_test.geta() == 2)")
        assert.truthy(ok, err)
    end)

    it("generates code for float module-local variables", function()
        local code = [[
            local a: float = 1
            function geta(): float
                return a
            end
            function seta(x: float)
                a = x
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.geta() == 1);titan_test.seta(2);assert(titan_test.geta() == 2)")
        assert.truthy(ok, err)
    end)

    it("generates code for boolean module-local variables", function()
        local code = [[
            local a: boolean = true
            function geta(): boolean
                return a
            end
            function seta(x: boolean)
                a = x
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.geta() == true);titan_test.seta(false);assert(titan_test.geta() == false)")
        assert.truthy(ok, err)
    end)

    it("generates code for array module-local variables", function()
        local code = [[
            local a: {integer} = {}
            function len(): integer
                return #a
            end
            function seta(x: {integer})
                a = x
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.len() == 0);titan_test.seta({1});assert(titan_test.len() == 1)")
        assert.truthy(ok, err)
    end)

    it("handles coercion to integer", function()
        local code = [[
            function fn(): integer
                local f: float = 1.0
                local i: integer = f
                return i
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "local x = titan_test.fn(); assert(math.type(x) == 'integer')")
        assert.truthy(ok, err)
    end)

    it("handles unused locals", function()
        local code = [[
            function fn()
                local f: float = 1.0
                local i: integer = f
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
    end)

    it("generates code for integer exported variables", function()
        local code = [[
            a: integer = 1
            function geta(): integer
                return a
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(titan_test.geta() == 1)
            assert(titan_test.a == 1)
            titan_test.a = 2
            assert(titan_test.a == 2)
            assert(titan_test.geta() == 2)
        ]])
        assert.truthy(ok, err)
    end)

    it("generates code for exported float variables", function()
        local code = [[
            a: float = 1
            function geta(): float
                return a
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.geta() == 1);titan_test.a = 2;assert(titan_test.geta() == 2)")
        assert.truthy(ok, err)
    end)

    it("generates code for exported boolean variables", function()
        local code = [[
            a: boolean = true
            function geta(): boolean
                return a
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.geta() == true);titan_test.a = false;assert(titan_test.geta() == false)")
        assert.truthy(ok, err)
    end)

    it("generates code for exported array variables", function()
        local code = [[
            a: {integer} = {}
            function len(): integer
                return #a
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.len() == 0);titan_test.a={1};assert(titan_test.len() == 1)")
        assert.truthy(ok, err)
    end)

    it("generates code for string length", function()
        local code = [[
            function len(a: string): integer
                return #a
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.len('foobar') == 6)")
        assert.truthy(ok, err)
    end)

    it("generates code for string literals", function()
        local code = [[
            function fn(): string
                local x: string = "foo\0bar\255"
                return x
            end
            function trigraphs(): string
                return "??=??/??'??(??)??!??<??>??-"
            end
            function binary_direct(): string
                return "\0\0017\255"
            end
            function empty(): string
                return ""
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            local x = titan_test.fn()
            assert(#x == 8)
            assert(x == "foo\0bar\255")
            local t = titan_test.trigraphs()
            assert(#t == 27)
            assert(t == "??=??/??'??(??)??!??<??>??-")
            local b = titan_test.binary_direct()
            assert(#b == 4)
            assert(string.byte(b, 1) == 0)
            assert(string.byte(b, 2) == 1)
            assert(string.byte(b, 3) == string.byte("7"))
            assert(string.byte(b, 4) == 255)
            assert(titan_test.empty() == "")
        ]])
        assert.truthy(ok, err)
    end)

    it("preserves every byte in a direct string literal", function()
        local escapes = {}
        for byte = 0, 255 do
            escapes[#escapes + 1] = string.format("\\%03d", byte)
        end
        local code = string.format([[
            function bytes(): string
                return "%s"
            end
        ]], table.concat(escapes))
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            local expected = {}
            for byte = 0, 255 do
                expected[#expected + 1] = string.char(byte)
            end
            assert(titan_test.bytes() == table.concat(expected))
        ]])
        assert.truthy(ok, err)
    end)

    it("generates code for string concatenation", function()
        local code = [[
            function concat(a: string): string
                return a .. "foo"
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.concat('a') == 'afoo')")
        assert.truthy(ok, err)
    end)

    it("generates code for string coercion from integer", function()
        local code = [[
            function concat(a: string): string
                return a .. 2
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.concat('a') == 'a2')")
        assert.truthy(ok, err)
    end)

    it("generates code for string coercion from float", function()
        local code = [[
            function concat(a: string): string
                return a .. 2.5
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.concat('a') == 'a2.5')")
        assert.truthy(ok, err)
    end)

    it("generates code for string concatenation of several strings", function()
        local code = [[
            function concat(a: string, b: string, c: string, d: string, e: string): string
                return a .. b .. c .. d .. e
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.concat('a','b','c','d','e') == 'abcde')")
        assert.truthy(ok, err)
    end)

    it("generates code for string concatenation resulting in long string", function()
        local code = [[
            function concat(a: string, b: string, c: string, d: string, e: string): string
                return a .. b .. c .. d .. e
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", "assert(titan_test.concat('aaaaaaaaaa','bbbbbbbbbb','cccccccccc','dddddddddd','eeeeeeeeee') == 'aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeee')")
        assert.truthy(ok, err)
    end)

    it("correctly uses module function", function ()
        local modules = {
            foo = [[
                function a(): integer
                    return 42
                end
            ]],
            bar = [[
                local foo = import "foo"
                function bar(): integer
                    return foo.a()
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "assert(bar.bar() == 42)")
        assert.truthy(ok, err)
    end)

    it("correctly uses module variable", function ()
        local modules = {
            foo = [[
                a: integer = 1
            ]],
            bar = [[
                local foo = import "foo"
                function bar(): integer
                    foo.a = 5
                    return foo.a
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "foo = require 'foo'; assert(bar.bar() == 5); assert(foo.a == 5)")
        assert.truthy(ok, err)
    end)

    it("runs a module initializer during first-time module initialization", function()
        run_coder([[
            answer: integer = 0
            local function seed(): integer
                return 41
            end
            function get(): integer
                return answer
            end
            do
                answer = seed() + 1
                return
            end
        ]], [[
            assert(test.answer == 42)
            assert(test.get() == 42)
        ]])
    end)

    local tovalue = {
        integer = 1,
        float = 1.5 ,
        boolean = true,
        string = "'foo'",
        ["nil"] = "nil",
        array = { type = "{integer}", val = "{1,2,3}", test = "x[3] == 3" }
    }

    for tag, val in pairs(tovalue) do
        it("handles coercion to value from " .. tag, function ()
            local typ = type(val) == "table" and val.type or tag
            local v = type(val) == "table" and val.val or tostring(val)
            local test = type(val) == "table" and val.test or "x == " .. tostring(val)
            local code = util.render([[
                function fn(): value
                    local x: $TYPE = $VAL
                    return x
                end
            ]], { TYPE = typ, VAL = v })
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local code = 'local x = titan_test.fn(); assert(' .. test .. ')'
            local ok, err = call("titan_test", code)
            assert.truthy(ok, err)
        end)

        it("handles coercion from value to " .. tag, function ()
            local typ = type(val) == "table" and val.type or tag
            local v = type(val) == "table" and val.val or tostring(val)
            local test = type(val) == "table" and val.test or "x == " .. tostring(val)
            local code = util.render([[
                function fn(): $TYPE
                    local x: value = $VAL
                    return x
                end
            ]], { TYPE = typ, VAL = v })
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local code = 'local x = titan_test.fn(); assert(' .. test .. ')'
            local ok, err = call("titan_test", code)
            assert.truthy(ok, err)
        end)

        it("handles coercion from value element to " .. tag, function ()
            local typ = type(val) == "table" and val.type or tag
            local v = type(val) == "table" and val.val or tostring(val)
            local test = type(val) == "table" and val.test or "x == " .. tostring(val)
            local code = util.render([[
                function fn(): $TYPE
                    local x: { value } = { $VAL }
                    return x[1]
                end
            ]], { TYPE = typ, VAL = v })
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local code = 'local x = titan_test.fn(); assert(' .. test .. ')'
            local ok, err = call("titan_test", code)
            assert.truthy(ok, err)
        end)
    end

    it("handles coercion between arrays of values and other arrays", function ()
        local code = [[
            function fn(): { value }
                local x: { integer } = { 1, 2, 3 }
                local y: { value } = x
                local z: { integer } = y
                return z
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local code = 'local x = titan_test.fn(); assert(x[3] == 3)'
        local ok, err = call("titan_test", code)
        assert.truthy(ok, err)
    end)

    local valfailures = {
        integer = "'foo'",
        float = "'foo'",
        string = 2,
        ["nil"] = 0,
        table = { type = "{integer}", val = "10" }
    }

    for tag, val in pairs(valfailures) do
        it("handles coercion failure from value to " .. tag, function ()
            local typ = type(val) == "table" and val.type or tag
            local v = type(val) == "table" and val.val or tostring(val)
            local code = util.render([[
                function fn(): $TYPE
                    local x: value = $VAL
                    return x
                end
            ]], { TYPE = typ, VAL = v })
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local code = "local ok, err = pcall(titan_test.fn); assert(not ok); assert(err:match('expected " .. tag .. "'))"
            local ok, err = call("titan_test", code)
            assert.truthy(ok, err)
        end)

        it("handles coercion failure from value element to " .. tag, function ()
            local typ = type(val) == "table" and val.type or tag
            local v = type(val) == "table" and val.val or tostring(val)
            local code = util.render([[
                function fn(): $TYPE
                    local x: {value} = {$VAL}
                    return x[1]
                end
            ]], { TYPE = typ, VAL = v })
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local code = "local ok, err = pcall(titan_test.fn); assert(not ok); assert(err:match('expected " .. tag .. "'))"
            local ok, err = call("titan_test", code)
            assert.truthy(ok, err)
        end)
    end

    it("pass value type in array index", function()
        local code = [[
            function read(array: {float}, i: value): float
                return array[i]
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            arr={1,2,3}
            assert(2==titan_test.read(arr, 2))
            assert(2==titan_test.read(arr, 2.0))
            assert(pcall(titan_test.read, arr, "foo") == false)
        ]])
        assert.truthy(ok, err)
    end)

    it("casts from integer to boolean", function()
        local code = [[
            function f (a:integer, b:integer): boolean
                return a and b
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(true==titan_test.f(2, 3))
        ]])
        assert.truthy(ok, err)
    end)

    it("loads C headers with foreign import", function ()
        local modules = {
            foo = [[
                local stdio = foreign import "stdio.h"
                function fun()
                    local fd = stdio.fopen("tmp_test_hello.txt", "w")
                    local msg = "Hello, Titan!\n"
                    local n = stdio.fwrite(msg, #msg, 1, fd)
                    local err = stdio.fclose(fd)
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            os.remove('tmp_test_hello.txt')
            foo.fun()
            local fd = io.open('tmp_test_hello.txt', 'r')
            local data = fd:read('*a')
            fd:close()
            os.remove('tmp_test_hello.txt')
            assert(data == 'Hello, Titan!\n')
        ]])
        assert.truthy(ok, err)
    end)

    it("uses quoted includes for local foreign headers", function()
        local suffix = os.tmpname():match("[^/]+$"):gsub("%W", "_")
        local header = "tmp_titan_ffi_local_header_" .. suffix .. ".h"
        local modname = "ffi_local_header_" .. suffix
        local f = assert(io.open(header, "w"))
        f:write("extern int titan_ffi_local_header_probe;\n")
        f:close()

        local modules = {
            [modname] = [[
                local h = foreign import "]] .. header .. [["
                function fun(): integer
                    return 1
                end
            ]]
        }
        local ok, err = pcall(function()
            local gok, gerr = generate_modules(modules, modname)
            assert.truthy(gok, gerr)

            local c = assert(io.open(modname .. ".c", "r"))
            local csrc = c:read("*a")
            c:close()
            assert.match('#include "' .. header .. '"', csrc, 1, true)
        end)
        os.remove(header)
        if not ok then error(err, 0) end
    end)

    it("runs TValue and void pointer FFI lowering paths", function()
        local suffix = os.tmpname():match("[^/]+$"):gsub("%W", "_")
        local header = "tmp_titan_ffi_tvalue_runtime_" .. suffix .. ".h"
        local f = assert(io.open(header, "w"))
        f:write([[
            #include "lua-5.5.0/src/lobject.h"

            typedef void *ffi_vptr;
            typedef int *ffi_iptr;

            static int ffi_box = 0;

            static inline TValue ffi_value_echo(TValue value) {
                return value;
            }

            static inline int ffi_value_seen(TValue value) {
                return !ttisnil(&value);
            }

            static inline void ffi_value_store(TValue *out, TValue value) {
                *out = value;
            }

            static inline ffi_vptr ffi_box_void(void) {
                return &ffi_box;
            }

            static inline void ffi_write_int(ffi_iptr p, int value) {
                *p = value;
            }

            static inline int ffi_read_int(ffi_iptr p) {
                return *p;
            }
        ]])
        f:close()

        local modules = {
            foo = [[
                local c = foreign import "]] .. header .. [["

                function echo(): value
                    return c.ffi_value_echo("ok")
                end

                function store(v: value): value
                    local raw: c.TValue = nil
                    c.ffi_value_store(raw, v)
                    return raw
                end

                function seen(v: value): integer
                    return c.ffi_value_seen(v)
                end

                function write_box(): integer
                    local p: c.ffi_iptr = c.ffi_box_void()
                    c.ffi_write_int(p, 77)
                    return c.ffi_read_int(c.ffi_box_void() as c.ffi_iptr)
                end
            ]]
        }
        local ok, err = pcall(function()
            local gok, gerr = generate_modules(modules, "foo")
            assert.truthy(gok, gerr)
            local cok, cerr = call("foo", [[
                assert(foo.echo() == "ok")
                local marker = {}
                assert(foo.store(marker) == marker)
                assert(foo.seen(function() end) == 1)
                assert(foo.write_box() == 77)
            ]])
            assert.truthy(cok, cerr)
        end)
        os.remove(header)
        if not ok then error(err, 0) end
    end)

    it("can cast a string to void pointer in foreign calls", function ()
        local suffix = os.tmpname():match("[^/]+$"):gsub("%W", "_")
        local header = "tmp_titan_ffi_voidptr_" .. suffix .. ".h"
        local f = assert(io.open(header, "w"))
        f:write("typedef void *ffi_vptr;\n")
        f:close()

        local modules = {
            foo = [[
                local c = foreign import "]] .. header .. [["
                local stdio = foreign import "stdio.h"
                function fun(): integer
                    local h = "Hello, cast"
                    local p = h as c.ffi_vptr
                    local fd = stdio.fopen("tmp_test_hello.txt", "w")
                    local n = stdio.fwrite(p, #h, 1, fd)
                    local err = stdio.fclose(fd)
                    return n as integer
                end
            ]]
        }
        local ok, err = pcall(function()
            local gok, gerr = generate_modules(modules, "foo")
            assert.truthy(gok, gerr)
            local cok, cerr = call("foo", [[
                os.remove('tmp_test_hello.txt')
                assert(foo.fun() == 1)
                local fd = io.open('tmp_test_hello.txt', 'r')
                local data = fd:read('*a')
                fd:close()
                os.remove('tmp_test_hello.txt')
                assert(data == 'Hello, cast')
            ]])
            assert.truthy(cok, cerr)
        end)
        os.remove(header)
        if not ok then error(err, 0) end
    end)

    it("casts a scalar foreign typedef to value", function ()
        -- `strlen` returns `size_t`, which stays a `Type.Typedef` (resolving to
        -- the underlying `integer` only at the storage layer). Explicitly casting
        -- that typedef-typed value with `as value` is the typedef cast Titan
        -- permits (a cast gates on `types.compatible`, which only crosses scalars
        -- through `value`). The coder resolves the `Type.Typedef` source to its
        -- underlying scalar at the cast site, so the wrapped slot stores the
        -- integer length; before the fix this raised `invalid type size_t` in
        -- `setslot`. The returned `value` must carry the string length back to Lua.
        local modules = {
            foo = [[
                local string_h = foreign import "string.h"
                function len(s: string): value
                    local n = string_h.strlen(s)   -- n: size_t scalar typedef
                    return n as value              -- Type.Typedef -> Type.Value cast
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            assert(foo.len("abcd") == 4)
            assert(foo.len("") == 0)
            assert(foo.len("hello, world") == 12)
            -- the value carries an integer payload usable in arithmetic
            assert(foo.len("titan") + 1 == 6)
        ]])
        assert.truthy(ok, err)
    end)

    it("casts a multi-level (chained) foreign typedef to value", function ()
        -- Regression for a macOS-only CI hang. glibc's `size_t` is a single
        -- typedef, but macOS's is chained: `size_t` -> `__darwin_size_t` ->
        -- `unsigned long`. The cast-site typedef resolver must unwrap ALL levels;
        -- a one-level unwrap kept re-wrapping the original operand and re-entered
        -- the cast-normalization arm forever on a chained typedef (CPU-spin hang).
        -- `clock_t` is chained on glibc too (`clock_t` -> `__clock_t` -> long), so
        -- this reproduces the loop on Linux.
        local modules = {
            foo = [[
                local time_h = foreign import "time.h"
                function ticks(): value
                    local c = time_h.clock()   -- c: clock_t (chained typedef)
                    return c as value
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            local t = foo.ticks()
            assert(type(t) == "number")
            assert(t >= 0)
        ]])
        assert.truthy(ok, err)
    end)

    it("can read foreign global variables", function ()
        local modules = {
            foo = [[
                local stdio = foreign import "stdio.h"
                local errno = foreign import "errno.h"
                function fun(name: string): integer
                    local f = stdio.fopen(name, "r")
                    if f ~= nil then
                        stdio.fclose(f)
                    end
                    return errno.errno
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            os.remove('file_that_doesnt_exist.txt')
            assert(foo.fun('file_that_doesnt_exist.txt') > 0)
        ]])
        assert.truthy(ok, err)
    end)

    it("uses a foreign pointer in a boolean context", function ()
        local modules = {
            foo = [[
                local stdio = foreign import "stdio.h"
                function opened(name: string): boolean
                    local f = stdio.fopen(name, "r")
                    if not f then
                        return false
                    end
                    stdio.fclose(f)
                    return true
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            os.remove('file_that_doesnt_exist.txt')
            assert(foo.opened('file_that_doesnt_exist.txt') == false)
            local p = os.tmpname()
            local fd = io.open(p, 'w'); fd:write('x'); fd:close()
            assert(foo.opened(p) == true)
            os.remove(p)
        ]])
        assert.truthy(ok, err)
    end)

    it("can use foreign defines", function ()
        local modules = {
            foo = [[
                local stdio = foreign import "stdio.h"
                local errno = foreign import "errno.h"
                function enoent(): integer
                    return errno.ENOENT
                end
                function fun(name: string, err: integer): boolean
                    local f = stdio.fopen(name, "r")
                    if f ~= nil then
                        stdio.fclose(f)
                    end
                    return errno.errno == err
                end
            ]]
        }
        local ok, err = generate_modules(modules, "foo")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            os.remove('file_that_doesnt_exist.txt')
            assert(foo.fun('file_that_doesnt_exist.txt', foo.enoent()))
        ]])
        assert.truthy(ok, err)
    end)

    it("and between two integers", function()
        local code = [[
            function f (a:integer, b:integer): integer
                return a and b
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(3==titan_test.f(2, 3))
        ]])
        assert.truthy(ok, err)
    end)

    it("or between two integers", function()
        local code = [[
            function f (a:integer, b:integer): integer
                return a or b
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(2==titan_test.f(2, 3))
        ]])
        assert.truthy(ok, err)
    end)

    it("calls function with multiple returns from Lua", function()
        local code = [[
            function f(x: integer): (integer, string)
                return x * 2, "foo"
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            local x, y = titan_test.f(2)
            assert(4 == x)
            assert('foo' == y)
            assert(pcall(titan_test.f, 2, 'foo') == false)
        ]])
        assert.truthy(ok, err)
    end)

    it("calls function with multiple returns from Titan declaration", function()
        local code = [[
            function f(x: integer): (integer, string)
                return x * 2, "foo"
            end

            function g1(): integer
                local x, _ = f(2)
                return x
            end

            function g2(): integer
                local x = (f(2))
                return x
            end

            function g3(): integer
                return (f(2))
            end

            function g4(): integer
                return (f(2))
            end

            function h(): string
                local x, y = f(2)
                return y
            end

            function cf1(x: integer, y: string): integer
                return x
            end

            function cf2(x: integer, y: string): string
                return y
            end

            function i(): integer
                return cf1(f(2))
            end

            function j(): string
                return cf2(f(2))
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(4 == titan_test.g1())
            assert(4 == titan_test.g2())
            assert(4 == titan_test.g3())
            assert(4 == titan_test.g4())
            assert('foo' == titan_test.h())
            assert(4 == titan_test.i())
            assert('foo' == titan_test.j())
        ]])
        assert.truthy(ok, err)
    end)

    it("handles multiple return values in array initialization", function ()
        local code = [[
            function f(): (integer, integer)
                return 40, 50
            end
            function g(): (integer, string)
                return 20, "foo"
            end
            function fn(): {integer}
                local arr: {integer} = { 10, g(), 30, f() }
                return arr
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            local arr = titan_test.fn()
            assert(5 == #arr)
            assert(10 == arr[1])
            assert(20 == arr[2])
            assert(30 == arr[3])
            assert(40 == arr[4])
            assert(50 == arr[5])
        ]])
        assert.truthy(ok, err)
    end)

    it("handles multiple assignment", function()
        local code = [[
            function f(x: integer): (integer, string)
                return x * 2, "foo"
            end

            function m1(): integer
                local x, y = 0, ""
                x, y = f(2)
                return x
            end

            function m2(): string
                local x, y = 0, ""
                x, y = f(2)
                return y
            end

            function m3(): integer
                local x, y = 0, ""
                x, y = 4, "foo"
                return x
            end

            function m4(): string
                local x, y = 0, ""
                x, y = 4, "foo"
                return y
            end

            function m5(): integer
                local x: {integer} = {}
                x[1], x[2] = 4, 2
                return x[1]
            end

            function m6(): integer
                local x: {integer} = {}
                x[1], x[2] = 2, 4
                return x[2]
            end

            function m7(): string
                local x: {string} = {}
                x[1], x[2] = "foo", ""
                return x[1]
            end

            function m8(): string
                local x: {string} = {}
                x[1], x[2] = "", "foo"
                return x[2]
            end

            function m9(): integer
                local x, y = 2, 4
                x, y = y, x
                return x
            end

            function m10(): string
                local x, y = "bar", "foo"
                x, y = y, x
                return x
            end
        ]]
        local ast, err = parse(code)
        assert.truthy(ast, err)
        local _, err = checker.check("test", ast, code, "test.titan")
        assert.equal(0, #err, table.concat(err, "\n"))
        local ok, err = compile("titan_test", ast)
        assert.truthy(ok, err)
        local ok, err = call("titan_test", [[
            assert(4 == titan_test.m1())
            assert(4 == titan_test.m3())
            assert(4 == titan_test.m5())
            assert(4 == titan_test.m6())
            assert(4 == titan_test.m9())
            assert('foo' == titan_test.m2())
            assert('foo' == titan_test.m4())
            assert('foo' == titan_test.m7())
            assert('foo' == titan_test.m8())
            assert('foo' == titan_test.m10())
        ]])
        assert.truthy(ok, err)
    end)

    it("correctly uses module variable in multiple assignment", function ()
        local modules = {
            foo = [[
                a: integer = 1
            ]],
            bar = [[
                local foo = import "foo"
                function bar(): integer
                    local x = 0
                    x, foo.a = 2, 5
                    return foo.a
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "foo = require 'foo';assert(bar.bar() == 5); assert(foo.a == 5)")
        assert.truthy(ok, err)
    end)

    it("initializes a record and returns a primitive field", function ()
        run_coder([[
            record Point
              x: float
              y: float
            end
            function x(): float
                local r: Point = { x = 2, y = 3 }
                return r.x
            end
            function y(): float
                local r: Point = { x = 2, y = 3 }
                return r.y
            end
        ]], [[
            assert(2.0 == test.x())
            assert(3.0 == test.y())
        ]])
    end)

    it("initializes a record and mutates field", function ()
        run_coder([[
            record Point
              x: float
              y: float
            end
            function x(): float
                local r: Point = { x = 0, y = 0 }
                r.x = 2
                return r.x
            end
            function y(): float
                local r: Point = { x = 0, y = 0 }
                r.y = 3
                return r.y
            end
        ]], [[
            assert(2.0 == test.x())
            assert(3.0 == test.y())
        ]])
    end)

    it("initializes a record and returns a gc field", function ()
        run_coder([[
            record Pair
              x: string
              y: string
            end
            function x(): string
                local r: Pair = { x = 'foo', y = 'bar' }
                return r.x
            end
            function y(): string
                local r: Pair = { x = 'foo', y = 'bar' }
                return r.y
            end
        ]], [[
            assert('foo' == test.x())
            assert('bar' == test.y())
        ]])
    end)

    it("calls method that does not access fields, from outside record", function ()
        run_coder([[
            record Rec
            end
            function Rec:m(): integer
                return 1
            end
            function f(): integer
                local r: Rec = {}
                return r:m()
            end
        ]], [[
            assert(1 == test.f())
        ]])
    end)

    it("calls method that does not access fields, from inside record", function ()
        run_coder([[
            record Rec
            end
            function Rec:m1(): integer
                return self:m2()
            end
            function Rec:m2(): integer
                return 1
            end
            function f(): integer
                local r: Rec = {}
                return r:m1()
            end
        ]], [[
            assert(1 == test.f())
        ]])
    end)

    it("calls record method that accesses fields", function ()
        run_coder([[
            record Point
               x: float
               y: float
            end
            function Point:getx(): float
                return self.x
            end
            function Point:gety(): float
                return self.y
            end
            function f(): (float, float)
                local r: Point = { x = 2, y = 3 }
                return r:getx(), r:gety()
            end
        ]], [[
            local x, y = test.f()
            assert(2.0 == x)
            assert(3.0 == y)
        ]])
    end)

    it("casts from record to value and back successfully", function ()
        run_coder([[
            record Point
              x: float
              y: float
            end
            function f(): float
                local p: Point = { x = 2, y = 0 }
                local v: value = p
                local pp: Point = v
                p.y = 3
                return pp.y
            end
        ]], [[
            assert(3.0 == test.f())
        ]])
    end)

    it("casts from record to value and back unsuccessfully", function ()
        run_coder([[
            record Rec
            end
            record Point
              x: float
              y: float
            end
            function f(): float
                local p: Point = { x = 2, y = 0 }
                local v: value = p
                local r: Rec = v
                return 0
            end
        ]], [[test.f()]], "expected test.Rec but found test.Point")
    end)

    it("casts from value to record unsuccessfully", function ()
        run_coder([[
            record Rec
            end
            function f(): float
                local v: value = 0
                local r: Rec = v
                return 0
            end
        ]], [[test.f()]], "expected test.Rec but found number")
    end)

    it("rejects a non-record full userdata where a record is expected", function ()
        -- The expected-record check must compare the udata's metatable, not read
        -- a raw tag word out of getudatamem: a full userdata with no record
        -- storage section (the module value itself, len 0) or a foreign one
        -- (io.stdout) must error cleanly, never crash / read out of bounds.
        run_coder([[
            record Rec
                x: integer
            end
            function f(r: Rec): integer
                return r.x
            end
        ]], [[
            local ok1, e1 = pcall(test.f, test)
            assert(not ok1)
            assert(e1:find("expected test%.Rec but found"))
            local ok2, e2 = pcall(test.f, io.stdout)
            assert(not ok2)
            assert(e2:find("expected test%.Rec but found"))
        ]])
    end)

    it("calls record method that mutates fields", function ()
        run_coder([[
            record Point
               x: float
               y: float
            end
            function Point:getx(): float
                return self.x
            end
            function Point:gety(): float
                return self.y
            end
            function Point:move(dx: float, dy: float)
                self.x, self.y = self.x + dx, self.y + dy
            end
            function f(): (float, float)
                local r: Point = { x = 2, y = 3 }
                r:move(2, 3)
                return r:getx(), r:gety()
            end
        ]], [[
            local x, y = test.f()
            assert(4.0 == x)
            assert(6.0 == y)
        ]])
    end)

    it("uses method of record from another module", function ()
        local modules = {
            foo = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]],
            bar = [[
                local f = import "foo"
                function bar(): (float, float)
                    local p: f.Point = { x = 2, y = 3 }
                    p:move(2, 3)
                    return p.x, p.y
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "x, y = bar.bar(); assert(x == 4.0); assert(y == 6.0)")
        assert.truthy(ok, err)
    end)

    it("calls method from a returned record", function ()
        local modules = {
            foo = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float): Point
                    self.x, self.y = self.x + dx, self.y + dy
                    return self
                end
                function get_point(): Point
                    return { x = 10, y = 20 }
                end
            ]],
            bar = [[
                local f = import "foo"
                function bar(): (float, float)
                    local p = f.get_point():move(2, 3)
                    return p.x, p.y
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "x, y = bar.bar(); assert(x == 12.0); assert(y == 23.0)")
        assert.truthy(ok, err)
    end)

    it("uses method of record from transitive module", function ()
        local modules = {
            foo = [[
                record Point
                  x: float
                  y: float
                end
                function Point:move(dx: float, dy: float)
                    self.x, self.y = self.x + dx, self.y + dy
                end
            ]],
            baz = [[
                local f = import "foo"
                function point(x: float, y: float): f.Point
                    return { x = 2, y = 3 }
                end
            ]],
            bar = [[
                local b = import "baz"
                function bar(): (float, float)
                    local p = b.point(2,3)
                    p:move(2, 3)
                    return p.x, p.y
                end
                function foo(): (float, float)
                    local p = b.point(2,3)
                    local v: value = p
                    p = v
                    return p.x, p.y
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "x, y = bar.bar(); assert(x == 4.0); assert(y == 6.0)")
        assert.truthy(ok, err)
        local ok, err = call("bar", "x, y = bar.foo(); assert(x == 2.0); assert(y == 3.0)")
        assert.truthy(ok, err)
    end)

    it("gets record from Titan and sends it back", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            function point(): Point
                return { x = 2, y = 3 }
            end
            function unpack(p: Point): (float, float)
                return p.x, p.y
            end
        ]], [[
            local p1 = test.point()
            assert(type(p1) == 'userdata')
            local x, y = test.unpack(p1)
            assert(2.0 == x)
            assert(3.0 == y)
            local p2 = test.point()
            assert(p1 ~= p2)
            assert(getmetatable(p1) == getmetatable(p2))
        ]])
    end)

    it("gets record from titan and sends it back to wrong type", function ()
        run_coder([[
            record Rec
            end
            record Point
              x: float
              y: float
            end
            function point(): Point
                return { x = 2, y = 3 }
            end
            function f(r: Rec)
            end
        ]], [[test.f(test.point())]], "expected test.Rec but found test.Point")
    end)

    it("send wrong type to titan record", function ()
        run_coder([[
            record Rec
            end
            function f(r: Rec)
            end
        ]], [[test.f(2)]], "expected test.Rec but found number")
    end)

    it("gets record from titan inside array", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            function points1(): { Point }
                return { { x = 2, y = 3 } }
            end
            function points2(): { Point }
                local ps: { Point } = {}
                ps[1] = { x = 2, y = 3 }
                return ps
            end
            function unpack(p: Point): (float, float)
                return p.x, p.y
            end
        ]], [[
            local ps = test.points1()
            assert(#ps == 1)
            assert(type(ps[1]) == 'userdata')
            local x, y = test.unpack(ps[1])
            assert(2.0 == x)
            assert(3.0 == y)
            local ps = test.points2()
            assert(#ps == 1)
            assert(type(ps[1]) == 'userdata')
            local x, y = test.unpack(ps[1])
            assert(2.0 == x)
            assert(3.0 == y)
        ]])
    end)

    it("gets record from titan through module variable", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            p: Point = { x = 2, y = 3 }
            function unpack(p: Point): (float, float)
                return p.x, p.y
            end
        ]], [[
            local p = test.p
            assert(type(p) == 'userdata')
            local x, y = test.unpack(p)
            assert(2.0 == x)
            assert(3.0 == y)
        ]])
    end)

    it("send record to titan through module variable", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            p: Point = { x = 0, y = 0 }
            function point(): Point
                return { x = 2, y = 3 }
            end
            function unpack(p: Point): (float, float)
                return p.x, p.y
            end
        ]], [[
            test.p = test.point()
            local x, y = test.unpack(test.p)
            assert(2.0 == x)
            assert(3.0 == y)
        ]])
    end)

    it("access record field from Lua", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            record Rec
                x: float
                y: string
                z: Point
            end
            r: Rec = { x = 2, y = 'foo', z = { x = 2, y = 3 } }
            function rec(): Rec
                return { x = 3, y = 'bar', z = { x = 3, y = 2 } }
            end
        ]], [[
            local r1 = test.r
            local r2 = test.rec()
            assert(2.0 == r1.x)
            assert(3.0 == r2.x)
            assert('foo' == r1.y)
            assert('bar' == r2.y)
            assert(2.0 == r1.z.x)
            assert(3.0 == r1.z.y)
            assert(3.0 == r2.z.x)
            assert(2.0 == r2.z.y)
            local ok, err = pcall(function () return r1.foo end)
            assert(not ok)
            assert(err:match('not found'))
        ]])
    end)

    it("mutate record field from Lua", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            record Rec
                x: float
                y: string
                z: Point
            end
            r: Rec = { x = 2, y = 'foo', z = { x = 2, y = 3 } }
            function rec(): Rec
                return { x = 3, y = 'bar', z = { x = 3, y = 2 } }
            end
            function getX(r: Rec): float
                return r.x
            end
            function getY(r: Rec): string
                return r.y
            end
            function getZX(r: Rec): float
                return r.z.x
            end
        ]], [[
            local r1 = test.r
            local r2 = test.rec()
            r1.x = 4
            r1.y = 'baz'
            r1.z.x = 5
            r2.x = 8
            r2.y = 'xyz'
            r2.z.x = 10
            assert(4.0 == test.getX(r1))
            assert(8.0 == test.getX(r2))
            assert('baz' == test.getY(r1))
            assert('xyz' == test.getY(r2))
            assert(5.0 == test.getZX(r1))
            assert(10.0 == test.getZX(r2))
            local ok, err = pcall(function () r1.foo = 2 end)
            assert(not ok)
            assert(err:match('not found'))
        ]])
    end)

    it("call record method from Lua", function ()
        run_coder([[
            record Point
                x: float
                y: float
            end
            function Point:move(dx: float, dy: float)
                self.x, self.y = self.x + dx, self.y + dy
            end
            function point(x: float, y: float): Point
                return { x = x, y = y }
            end
        ]], [[
            local p = test.point(2, 3)
            p:move(2, 3)
            assert(4.0 == p.x)
            assert(6.0 == p.y)
            local ok, err = pcall(function () p.move = 2 end)
            assert(not ok)
            assert(err:match('not found'))
        ]])
    end)

    it("hides local record fields and methods from Lua", function ()
        run_coder([[
            record Box
                local hidden: integer
                shown: integer
            end

            local function Box:secret(): integer
                return self.hidden
            end

            function box(): Box
                return Box.new(11, 31)
            end

            function reveal(b: Box): integer
                return b.hidden + b:secret()
            end

            function via_values(): integer
                local make = Box.new
                local b = make(13, 37)
                local secret = b:secret
                return b.shown + secret()
            end
        ]], [[
            local b = test.box()
            assert(b.shown == 31)
            assert(test.reveal(b) == 22)
            assert(test.via_values() == 37 + 13)
            local ok, err = pcall(function () return b.hidden end)
            assert(not ok)
            assert(err:match('not found'))
            ok, err = pcall(function () return b:secret() end)
            assert(not ok)
            assert(err:match("not found"))
            assert(test.Box.new == nil)
        ]])
    end)

    it("calls public and local record functions", function ()
        run_coder([[
            record Box
                local hidden: integer
                shown: integer
            end

            function Box.make(shown: integer): Box
                return Box.new(shown * 10, shown)
            end

            local function Box.secret(seed: integer): Box
                return Box.new(seed, seed + 1)
            end

            function reveal(b: Box): integer
                return b.hidden + b.shown
            end

            function via_local(): integer
                local make = Box.secret
                local b = make(41)
                return b.hidden + b.shown
            end
        ]], [[
            local b = test.Box.make(7)
            assert(test.reveal(b) == 77)
            assert(b.shown == 7)
            assert(test.via_local() == 41 + 42)
            assert(test.Box.make == test.Box.make)
            assert(test.Box.secret == nil)
            assert(test.Box.new == nil)
            local ok, err = pcall(function () return b.hidden end)
            assert(not ok)
            assert(err:match('not found'))
        ]])
    end)

    it("calls and binds functions on records with underscored names", function ()
        run_coder([[
            record native_handle
                n: integer
            end

            function native_handle.make(n: integer): native_handle
                return native_handle.new(n)
            end

            function native_handle:bump(delta: integer): integer
                self.n = self.n + delta
                return self.n
            end

            function exercise(): integer
                local handle = native_handle.make(10)
                local bound: (integer) -> integer = handle:bump
                return handle:bump(2) + bound(3)
            end
        ]], [[
            assert(test.exercise() == 12 + 15)
        ]])
    end)

    it("initializes a record using new", function ()
        run_coder([[
            record Point
              x: float
              y: float
            end
            function x(): float
                local r: Point = Point.new(2,3)
                return r.x
            end
            function y(): float
                local r: Point = Point.new(2,3)
                return r.y
            end
        ]], [[
            assert(2.0 == test.x())
            assert(3.0 == test.y())
        ]])
    end)

    it("initializes a record using new from Lua", function ()
        run_coder([[
            record Point
              x: float
              y: float
            end
            function unwrap(p: Point): (float, float)
                return p.x, p.y
            end
        ]], [[
            local p = test.Point.new(2, 3)
            local x, y = test.unwrap(p)
            assert(2.0 == x)
            assert(3.0 == y)
        ]])
    end)

    it("records created from different loaded modules", function ()
        local modules = {
            foo = [[
                record Point
                  x: float
                  y: float
                end
                function px(p: Point): float
                    return p.x
                end
            ]],
            bar = [[
                local f = import "foo"
                function point(x: float, y: float): f.Point
                    return { x = 2, y = 3 }
                end
                function px(p: f.Point): float
                    return p.x
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("foo", [[
            bar = require 'bar'
            p1 = bar.point(2,3)
            assert(foo.px(p1) == 2.0)
            p2 = foo.Point.new(2,3)
            assert(bar.px(p2) == 2.0)
            assert(debug.getmetatable(p1) == debug.getmetatable(p2))
        ]])
        assert.truthy(ok, err)
    end)

    it("constructs record from other module", function ()
        local modules = {
            foo = [[
                record Point
                  x: float
                  y: float
                end
            ]],
            baz = [[
                local f = import "foo"
                function point(x: float, y: float): f.Point
                    return f.Point.new(x, y)
                end
            ]],
            bar = [[
                local b = import "baz"
                function bar(): (float, float)
                    local p = b.point(2,3)
                    p = { x = 4, y = 6 }
                    return p.x, p.y
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        local ok, err = call("bar", "x, y = bar.bar(); assert(x == 4.0); assert(y == 6.0)")
        assert.truthy(ok, err)
    end)

    it("uses public record surface from source-linked module with local members", function ()
        local modules = {
            foo = [[
                record Box
                    local hidden: integer
                    shown: integer
                end

                local function Box:secret(): integer
                    return self.hidden
                end

                function make(hidden: integer, shown: integer): Box
                    return Box.new(hidden, shown)
                end

                function reveal(b: Box): integer
                    return b.hidden + b:secret()
                end
            ]],
            bar = [[
                local f = import "foo"

                function bar(): integer
                    local b = f.make(17, 41)
                    return b.shown + f.reveal(b)
                end
            ]]
        }
        local ok, err = generate_modules(modules, "bar")
        assert.truthy(ok, err)
        ok, err = call("bar", "assert(bar.bar() == 41 + 34)")
        assert.truthy(ok, err)
    end)

    for _, op in ipairs({"==", "~="}) do
        it("can compare values using " .. op, function()
            run_coder(util.render([[
                function fn(a1: value, a2: value): boolean
                    return a1 $OP a2
                end
            ]], { OP = op }), util.render([[
                local a = {}
                assert(a $OP a == test.fn(a, a))
            ]], { OP = op }))
        end)
    end

    it("check that backtrace is being set on error", function ()
        run_coder([[
            function wrong(): integer
                local x: value = {}
                return x
            end
        ]], [[
            local titan = require 'titan'
            local ok, err = pcall(test.wrong)
            assert(not ok)
            local bt = titan.backtrace()
            assert(type(bt) == "string" and #bt > 0)
            assert(not bt:find(err, 1, true))
            assert(not bt:find("stack traceback:", 1, true))
            assert(not bt:find("\t", 1, true))
        ]])
    end)

    it("reuses an already-installed Titan errorhandler in Lua entry wrappers", function ()
        local csrc = compile_and_read_c([[
            function id(x: integer): integer
                return x
            end
        ]])
        assert.truthy(csrc:find("titan_errfunc_is_errorhandler(L)", 1, true))
        assert.truthy(csrc:find("if (TITAN_UNLIKELY(!titan_errfunc_is_errorhandler(L)))", 1, true))
        assert.truthy(csrc:find("lua_pushcfunction(L, errorhandler)", 1, true))
        assert.falsy(csrc:find("lua_pushcclosure(L, errorhandler, 0)", 1, true))
        assert.truthy(csrc:find("if (TITAN_UNLIKELY(__installed_errfunc))", 1, true))
    end)

    describe("#maps", function()

        it("adding a value of the wrong type in Lua can trigger a runtime error later in Titan", function ()
            local code = [[
                function f(m: {string:integer}): {string:integer}
                    m["foo"] = m["foo"] + 10
                    return m
                end
            ]]
            local ast, err = parse(code)
            assert.truthy(ast, err)
            local _, err = checker.check("test", ast, code, "test.titan")
            assert.equal(0, #err, table.concat(err, "\n"))
            local ok, err = compile("titan_test", ast)
            assert.truthy(ok, err)
            local ok, err = call("titan_test", [[
                local m = { foo = 10 }
                local m2 = titan_test.f(m)
                assert(m2 == m)
                assert(m.foo == 20)
                titan_test.f(m)
                assert(m.foo == 30)
                m.foo = 'wat'
                titan_test.f(m) -- supposed to give an error here
            ]])
            assert.falsy(ok)
            assert.match("expected integer but found string", err)
        end)

        local test_types = {
            { t = "value", l1 = "'hello'", l2 = "123" },
            { t = "boolean", v1 = "true", v2 = "false" },
            { t = "integer", v1 = "1984", v2 = "2112" },
            { t = "float", v1 = "2.5", v2 = "3.14" },
            { t = "string", v1 = "'hello'", v2 = "'world'" },
            { t = "{integer}", l1 = "{10, 20}", l2 = "{}" },
            { t = "{string:integer}", l1 = "{x = 10, y = 20}", l2 = "{}"  },
            { t = "Point", l1 = "titan_test.Point.new(10, 20)", l2 = "titan_test.Point.new(30, 40)" },
        }

        for _, t1 in ipairs(test_types) do
            for _, t2 in ipairs(test_types) do
                local map = "{" .. t1.t .. " : " .. t2.t .. "}"

                it("declares a map " .. map, function()
                    local code = util.render([[
                        record Point
                            x: integer
                            y: integer
                        end
                        function new_map(k1: $TK, k2: $TK, v1: $TV, v2: $TV): $MAP
                            local m = { [$K1] = $V1, [$K2] = $V2 }
                            return m
                        end
                    ]], {
                        MAP = map,
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        TK = t1.t,
                        TV = t2.t,
                    })
                    local ast, err = parse(code)
                    assert.truthy(ast, err)
                    local _, err = checker.check("titan_test", ast, code, "test.titan")
                    assert.equal(0, #err, table.concat(err, "\n"))
                    local ok, err = compile("titan_test", ast)
                    assert.truthy(ok, err)
                    local ok, err = call("titan_test", util.render([[
                        local k1, k2, v1, v2 = $LK1, $LK2, $LV1, $LV2
                        local m = titan_test.new_map(k1, k2, v1, v2)
                        assert(m[$K1] == $V1 and m[$K2] == $V2)
                    ]], {
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        LK1 = t1.l1 or t1.v1,
                        LK2 = t1.l2 or t1.v2,
                        LV1 = t2.l1 or t2.v1,
                        LV2 = t2.l2 or t2.v2,
                    }))
                    assert.truthy(ok, err)
                end)

                it("assigns to a map " .. map, function()
                    local code = util.render([[
                        record Point
                            x: integer
                            y: integer
                        end
                        function new_map(k1: $TK, k2: $TK, v1: $TV, v2: $TV): $MAP
                            local m: $MAP = {}
                            m[$K1] = $V1
                            m[$K2] = $V2
                            return m
                        end
                    ]], {
                        MAP = map,
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        TK = t1.t,
                        TV = t2.t,
                    })
                    local ast, err = parse(code)
                    assert.truthy(ast, err)
                    local _, err = checker.check("titan_test", ast, code, "test.titan")
                    assert.equal(0, #err, table.concat(err, "\n"))
                    local ok, err = compile("titan_test", ast)
                    assert.truthy(ok, err)
                    local ok, err = call("titan_test", util.render([[
                        local k1, k2, v1, v2 = $LK1, $LK2, $LV1, $LV2
                        local m = titan_test.new_map(k1, k2, v1, v2)
                        assert(m[$K1] == $V1 and m[$K2] == $V2)
                    ]], {
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        LK1 = t1.l1 or t1.v1,
                        LK2 = t1.l2 or t1.v2,
                        LV1 = t2.l1 or t2.v1,
                        LV2 = t2.l2 or t2.v2,
                    }))
                    assert.truthy(ok, err)
                end)

                it("indexes a map " .. map, function()
                    local code = util.render([[
                        record Point
                            x: integer
                            y: integer
                        end
                        function get_map_value(k1: $TK, k2: $TK, v1: $TV, v2: $TV): $TV
                            local m: $MAP = {}
                            m[$K1] = $V1
                            m[$K2] = $V2
                            return m[$K1]
                        end
                    ]], {
                        MAP = map,
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        TK = t1.t,
                        TV = t2.t,
                    })
                    local ast, err = parse(code)
                    assert.truthy(ast, err)
                    local _, err = checker.check("titan_test", ast, code, "test.titan")
                    assert.equal(0, #err, table.concat(err, "\n"))
                    local ok, err = compile("titan_test", ast)
                    assert.truthy(ok, err)
                    call("titan_test", "v = titan_test.get_map_value(); assert(v == 1984)")
                    local ok, err = call("titan_test", util.render([[
                        local k1, k2, v1, v2 = $LK1, $LK2, $LV1, $LV2
                        local v = titan_test.get_map_value(k1, k2, v1, v2)
                        assert(v == $V1)
                    ]], {
                        K1 = t1.v1 or "k1",
                        K2 = t1.v2 or "k2",
                        V1 = t2.v1 or "v1",
                        V2 = t2.v2 or "v2",
                        LK1 = t1.l1 or t1.v1,
                        LK2 = t1.l2 or t1.v2,
                        LV1 = t2.l1 or t2.v1,
                        LV2 = t2.l2 or t2.v2,
                    }))
                    assert.truthy(ok, err)
                end)
            end
        end

        it("coerces map key", function ()
            run_coder([[
                function fn1(): string
                    local a: { float: string } = {}
                    a[1] = 'foo'
                    return a[1.0]
                end

                function fn2(): string
                    local a: { float: string } = {}
                    a[1.0] = 'foo'
                    return a[1]
                end
            ]], [[
                assert(test.fn1() == 'foo')
                assert(test.fn2() == 'foo')
            ]])
        end)

        it("compares two values with option types", function ()
            run_coder([[
                function fn(a: integer, b: integer): boolean
                  local t1 = { a }
                  local t2 = { b }
                  return t1[1] ~= t2[1]
                end
            ]], [[
                assert(test.fn(1, 2))
                assert(not test.fn(1, 1))
            ]])
        end)

        it("breaks out of a numeric for loop", function ()
            run_coder([[
                function fn(n: integer): integer
                    local s = 0
                    for i = 1, n do
                        s = s + i
                        if s > 20 then break end
                    end
                    return s
                end
            ]], [[
                assert(test.fn(10) == 21)
                assert(test.fn(3) == 6)
            ]])
        end)

        it("breaks out of a while loop", function ()
            run_coder([[
                function fn(xs: {integer}): integer
                    local r = 0
                    local i = 1
                    while i <= #xs do
                        if xs[i] > 0 then
                            r = xs[i]
                            break
                        end
                        i = i + 1
                    end
                    return r
                end
            ]], [[
                assert(test.fn({-1, -2, 7, 9}) == 7)
                assert(test.fn({-1, -2}) == 0)
            ]])
        end)

        it("breaks out of a repeat loop", function ()
            run_coder([[
                function fn(n: integer): integer
                    local i = 0
                    repeat
                        i = i + 1
                        if i == n then break end
                    until i > 100
                    return i
                end
            ]], [[
                assert(test.fn(5) == 5)
            ]])
        end)

        it("break exits only the innermost loop", function ()
            run_coder([[
                function fn(): integer
                    local c = 0
                    for i = 1, 3 do
                        for j = 1, 3 do
                            if j == 2 then break end
                            c = c + 1
                        end
                    end
                    return c
                end
            ]], [[
                assert(test.fn() == 3)
            ]])
        end)

        it("auto-unwraps an option receiver for a method call", function ()
            run_coder([[
                record Point
                    x: integer
                    y: integer
                end
                function Point:mag(): integer
                    return self.x * self.x + self.y * self.y
                end
                function fn(p: Point?): integer
                    return p:mag()
                end
                function mk(a: integer, b: integer): Point
                    return Point.new(a, b)
                end
            ]], [[
                assert(test.fn(test.mk(3, 4)) == 25)
            ]])
        end)

        it("raises when the option receiver of a method call is nil", function ()
            run_coder([[
                record Point
                    x: integer
                end
                function Point:get(): integer
                    return self.x
                end
                function fn(p: Point?): integer
                    return p:get()
                end
            ]], [[
                assert(test.fn(nil))
            ]], "but found nil")
        end)

        it("unwraps an option with an explicit 'as' cast", function ()
            run_coder([[
                function fn(xs: {integer}): integer
                    local v: integer? = xs[1]
                    return v as integer
                end
            ]], [[
                assert(test.fn({5, 6}) == 5)
            ]])
        end)

        it("raises when an 'as' cast unwraps a nil option", function ()
            run_coder([[
                function fn(xs: {integer}): integer
                    local v: integer? = xs[1]
                    return v as integer
                end
            ]], [[
                assert(test.fn({}))
            ]], "expected integer but found nil")
        end)

        it("unwraps an option array element with an 'as' cast", function ()
            run_coder([[
                function fn(xs: {integer?}): integer
                    return xs[1] as integer
                end
            ]], [[
                assert(test.fn({5, 6}) == 5)
                local ok = pcall(function () return test.fn({}) end)
                assert(not ok)
            ]])
        end)

        it("selects a field from a call result", function ()
            run_coder([[
                record Point
                    x: integer
                    y: integer
                end
                function mk(a: integer): Point
                    return Point.new(a, a + 1)
                end
                function fn(a: integer): integer
                    return mk(a).y
                end
            ]], [[
                assert(test.fn(3) == 4)
            ]])
        end)
    end)

    describe("#apps", function()
        it("compiles and runs a titan application", function ()
            run_coder_app([[
                local function fn(m: { string: integer }): integer
                    return m['foo']
                end
            ]], [[
                local m = { ['foo'] = 0 }
                return fn(m)
            ]], 0)
        end)

        it("correctly uses module function in application", function ()
            local modules = {
                foo = [[
                    function a(): integer
                        return 42
                    end
                ]],
                bar = [[
                    local foo = import "foo"
                    function bar(): integer
                        return foo.a()
                    end
                    function main(args: {string}): integer
                        if bar() == 42 then
                            return 0
                        else
                            return 1
                        end
                    end
                ]]
            }
            local ok, err = generate_modules(modules, "bar", true)
            assert.truthy(ok, err)
            local ok, err, status = call_app("./bar")
            assert.truthy(ok, err)
            assert.equal(0, status)
        end)

        it("correctly uses module local variables in application", function ()
            local modules = {
                foo = [[
                    local xs: {integer} = {}
                    function resetxs()
                        xs = {}
                    end
                ]],
                bar = [[
                    local foo = import "foo"
                    function main(args: {string}): integer
                        foo.resetxs()
                        return 42
                    end
                ]]
            }
            local ok, err = generate_modules(modules, "bar", true)
            assert.truthy(ok, err)
            local ok, err, status = call_app("./bar")
            assert.truthy(ok, err)
            assert.equal(42, status)
        end)

    end)
end)

describe("single-Udata representation (GC stress)", function()
    setup(function () os.remove("titan-runtime/titan.o") end)
    after_each(clean)

    -- 1. Record field (GC-able) mutated in a hot loop, GC forced between writes.
    -- Pins the forward->back barrier flip for record fields: a fresh GC value
    -- (a brand-new string) is stored into an existing, possibly-old record under
    -- repeated collection. A missing/back-wrong barrier corrupts the field.
    it("record field mutated in a hot loop under GC", function ()
        run_coder([[
            record Box
                s: string
            end
            function mkbox(): Box
                return { s = "init" }
            end
            function setname(b: Box, s: string): ()
                b.s = s
            end
            function getname(b: Box): string
                return b.s
            end
        ]], [[
            local b = test.mkbox()
            assert(type(b) == 'userdata')
            for i = 1, 1000 do
                test.setname(b, "v" .. i)
                collectgarbage()
            end
            assert(test.getname(b) == "v1000")
        ]])
    end)

    -- A nested GC field (an array of integers) churned the same way, to exercise
    -- a collectable field whose own contents are also fresh each iteration.
    it("record field holding an array mutated under GC", function ()
        run_coder([[
            record Bag
                xs: {integer}
            end
            function mkbag(): Bag
                return { xs = {} }
            end
            function fill(b: Bag, n: integer): ()
                local t: {integer} = {}
                local i = 1
                while i <= n do
                    t[i] = i
                    i = i + 1
                end
                b.xs = t
            end
            function sum(b: Bag): integer
                local s = 0
                local i = 1
                while i <= #b.xs do
                    s = s + b.xs[i]
                    i = i + 1
                end
                return s
            end
        ]], [[
            local b = test.mkbag()
            for i = 1, 500 do
                test.fill(b, i)
                collectgarbage()
            end
            assert(test.sum(b) == 500 * 501 / 2)
        ]])
    end)

    -- 2. A record stored into a module variable AND into an array, mutated, GC'd,
    -- read back. Exercises the back barrier across both a module-slot store and a
    -- table store, plus container reachability of the shared record.
    it("record shared by a module var and an array survives GC", function ()
        run_coder([[
            record Box
                s: string
            end
            held: Box = { s = "init" }
            store: {Box} = {}
            function reset(): ()
                held = { s = "h0" }
                store = {}
                store[1] = held
            end
            function bump(i: integer): ()
                held.s = "h" .. i
            end
            function fromvar(): string
                return held.s
            end
            function fromarr(): string
                return store[1].s
            end
        ]], [[
            test.reset()
            for i = 1, 800 do
                test.bump(i)
                collectgarbage()
            end
            -- Same record reached two ways: both must see the latest mutation.
            assert(test.fromvar() == "h800")
            assert(test.fromarr() == "h800")
            assert(test.held == test.store[1])
            assert(type(test.held) == 'userdata')
        ]])
    end)

    -- 3. Nested record (a record whose field is another record), built in Titan,
    -- returned to Lua, inner field read back after a collection. Confirms the
    -- removed back-ref hop did not break the nested unwrap.
    it("nested record round-trips through Lua under GC", function ()
        run_coder([[
            record Inner
                v: string
            end
            record Outer
                inner: Inner
                n: integer
            end
            function mk(s: string, n: integer): Outer
                return { inner = { v = s }, n = n }
            end
            function getinner(o: Outer): Inner
                return o.inner
            end
            function ival(i: Inner): string
                return i.v
            end
        ]], [[
            local o = test.mk("deep", 7)
            assert(type(o) == 'userdata')
            collectgarbage()
            collectgarbage()
            local i = test.getinner(o)
            assert(type(i) == 'userdata')
            assert(test.ival(i) == "deep")
            -- churn so the outer record is likely promoted, then re-read
            for k = 1, 300 do
                local t = test.mk("x" .. k, k)
                collectgarbage("step")
            end
            collectgarbage()
            assert(test.ival(test.getinner(o)) == "deep")
        ]])
    end)

    -- 4. Empty record: 0 fields => allocates 0+1 user values. Construct via new,
    -- return to Lua (must be userdata), and round-trip through a Titan function
    -- that takes and returns it.
    it("empty record constructs and round-trips", function ()
        run_coder([[
            record E
            end
            function mk(): E
                return E.new()
            end
            function id(e: E): E
                return e
            end
        ]], [[
            local e = test.mk()
            assert(type(e) == 'userdata')
            collectgarbage()
            local e2 = test.id(e)
            assert(e == e2)
            assert(type(e2) == 'userdata')
            -- literal construction round-trips too
            local e3 = test.E.new()
            assert(type(e3) == 'userdata')
            assert(e3 ~= e)
            assert(getmetatable(e3) == getmetatable(e))
        ]])
    end)

    -- 5. A GC-typed module variable mutated from Lua under GC stress. Pins the
    -- module-slot back barrier in __newindex / codevardec: fresh arrays assigned
    -- from Lua into the module slot must survive collection.
    it("GC-typed module var mutated from Lua under GC", function ()
        run_coder([[
            a: {integer} = {}
            function suma(): integer
                local s = 0
                local i = 1
                while i <= #a do
                    s = s + a[i]
                    i = i + 1
                end
                return s
            end
        ]], [[
            for i = 1, 600 do
                test.a = { i, i + 1, i + 2 }
                collectgarbage()
                assert(test.suma() == 3 * i + 3)
            end
        ]])
    end)

    -- Same pattern for a string-typed module variable.
    it("string module var mutated from Lua under GC", function ()
        run_coder([[
            s: string = ""
            function gets(): string
                return s
            end
        ]], [[
            for i = 1, 600 do
                test.s = "s" .. i
                collectgarbage()
                assert(test.gets() == "s" .. i)
            end
        ]])
    end)

    -- 6. Module Udata Lua-facing surface sanity: the module table is gone and
    -- `require` returns the Udata. Functions call, exported vars read/write, and
    -- record functions construct with stable identity.
    it("module Udata surface: call, var get/set, static identity", function ()
        run_coder([[
            record Rec
                x: integer
            end
            v: integer = 10
            function f(x: integer): integer
                return x + 1
            end
            function getx(r: Rec): integer
                return r.x
            end
        ]], [[
            assert(type(require('test')) == 'userdata')
            -- function is callable
            assert(test.f(41) == 42)
            -- exported variable reads and writes
            assert(test.v == 10)
            test.v = 99
            assert(test.v == 99)
            -- record function constructs and has stable identity
            local r = test.Rec.new(5)
            assert(type(r) == 'userdata')
            assert(test.getx(r) == 5)
            assert(test.Rec.new == test.Rec.new)
        ]])
    end)

    it("module Udata surface: indexing a missing member errors", function ()
        run_coder([[
            function f(): integer
                return 1
            end
        ]], [[
            local _ = test.nonexistent
        ]], "does not exist")
    end)

    it("module Udata surface: assigning to a function errors", function ()
        run_coder([[
            function f(): integer
                return 1
            end
        ]], [[
            test.f = 1
        ]], "cannot assign")
    end)
end)

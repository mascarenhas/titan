local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"

local run_coder = h.run_coder

local function generate(source)
    h.reset(true)
    local ast, perr = h.parse(source, "test.titan")
    assert.truthy(ast, perr)
    local _, errors = checker.check("test", ast, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", ast, {}, driver.TITAN_VER)
end

local function position_after(subject, needle, start)
    local pos = subject:find(needle, start or 1, true)
    assert.truthy(pos, "missing generated fragment: " .. needle)
    return pos
end

local function assert_before(subject, first, second, start)
    local a = position_after(subject, first, start)
    local b = position_after(subject, second, a + #first)
    assert.is_true(a < b, first .. " must precede " .. second)
    return b
end

describe("flexible returns through finally", function()
    after_each(function()
        if h.verbose then return end
        os.remove("test.c")
        os.remove("test.o")
        os.remove("test.so")
        os.execute("rm -rf test.dSYM")
    end)

    it("emits frame-owned backing, roots, publication ordering, and nested boundary restoration", function()
        local csrc = generate([[
            function strings(): (...: string)
                return "left", "right"
            end

            function pending(): (...: string)
                do
                    return strings()
                finally
                    local marker: string = "finally"
                end
            end

            function nested(): (...: string)
                do
                    do
                        return strings()
                    finally
                        local inner: string = "inner"
                    end
                finally
                    raise "outer"
                end
            end
        ]])

        assert.match("TString%* _pa_flexargs_1%[TITAN_VARARG_MAX%] = {0};",
            csrc)
        assert.match("volatile int _pa_flexcount_1 = 0;", csrc)
        assert.match("%(void%)_pa_flexargs_1;", csrc)
        assert.match("%(void%)_pa_flexcount_1;", csrc)

        local pending = position_after(csrc,
            "void test_pending_titan(lua_State *L")
        local reset = position_after(csrc, "_pa_flexcount_1 = 0;", pending)
        local write = position_after(csrc,
            "_pa_flexargs_1[_pa_flexcount_1] =", reset)
        local root = position_after(csrc, "setsvalue(L,", write)
        local increment = position_after(csrc, "_pa_flexcount_1++;", root)
        local publish = position_after(csrc, "_pa_1 = 1;", increment)
        assert.is_true(reset < write and write < root and root < increment
            and increment < publish)

        local copy = position_after(csrc,
            "_flexout->args[_pa_dflex_i_1] = _pa_flexargs_1[_pa_dflex_i_1];",
            publish)
        local nargs = position_after(csrc,
            "_flexout->n_args = (lu_byte)_pa_dflex_count_1;", copy)
        local top_reset = position_after(csrc, "L->top.p = _base;", nargs)
        assert.is_true(copy < nargs and nargs < top_reset)

        local nested = position_after(csrc,
            "void test_nested_titan(lua_State *L")
        local frame_copy = position_after(csrc, "_pa_copy_count_2_1", nested)
        local count_publish = position_after(csrc,
            "_pa_flexcount_1 = _pa_copy_count_2_1;", frame_copy)
        local outer_pa = position_after(csrc, "_pa_1 = 1;", count_publish)
        local restore = position_after(csrc,
            "L->errorJmp = _lj_1.previous;", outer_pa)
        local restore_nc = position_after(csrc,
            "L->nCcalls = _oldnC_1;", restore)
        local outer_goto = position_after(csrc, "goto _finally_1;", restore_nc)
        assert.is_true(count_publish < outer_pa and outer_pa < restore
            and restore < restore_nc and restore_nc < outer_goto)
    end)

    it("preserves fixed surplus effects in body and catch returns", function()
        run_coder([[
            log: integer = 0

            function reset()
                log = 0
            end

            function mark(n: integer): integer
                log = log * 10 + n
                return n
            end

            function effect(n: integer): ()
                log = log * 10 + n
            end

            function getlog(): integer
                return log
            end

            function fail(): integer
                raise "body"
                return 0
            end

            function from_body(): integer
                do
                    return mark(1), effect(2)
                finally
                    effect(3)
                end
            end

            function from_catch(): integer
                do
                    return fail()
                catch
                    return mark(4), effect(5)
                finally
                    effect(6)
                end
            end
        ]], [[
            test.reset()
            assert(test.from_body() == 1)
            assert(test.getlog() == 123)
            test.reset()
            assert(test.from_catch() == 4)
            assert(test.getlog() == 456)
        ]])
    end)

    it("publishes zero flexible results from named and lambda body, catch, and fallthrough exits", function()
        run_coder([[
            hits: integer = 0

            function note()
                hits = hits + 1
            end

            function gethits(): integer
                return hits
            end

            function named_body(): (...: integer)
                do
                    return
                finally
                    note()
                end
            end

            function named_catch(): (...: integer)
                do
                    raise "x"
                catch
                    return
                finally
                    note()
                end
            end

            function named_fallthrough(): (...: integer)
            end

            function lambda_body(): (...: integer)
                local f: () -> (...: integer) = function(): (...: integer)
                    do
                        return
                    finally
                        note()
                    end
                end
                return f()
            end

            function lambda_catch(): (...: integer)
                local f: () -> (...: integer) = function(): (...: integer)
                    do
                        raise "x"
                    catch
                        return
                    finally
                        note()
                    end
                end
                return f()
            end

            function lambda_fallthrough(): (...: integer)
                local f: () -> (...: integer) = function(): (...: integer)
                end
                return f()
            end
        ]], [[
            assert(select("#", test.named_body()) == 0)
            assert(select("#", test.named_catch()) == 0)
            assert(select("#", test.named_fallthrough()) == 0)
            assert(select("#", test.lambda_body()) == 0)
            assert(select("#", test.lambda_catch()) == 0)
            assert(select("#", test.lambda_fallthrough()) == 0)
            assert(test.gethits() == 4)
        ]])
    end)

    it("publishes one fixed nil and no flexible results from named and anonymous fallthroughs", function()
        run_coder([[
            function named_fallthrough(): (nil, ...: integer)
            end

            function make_anonymous(): () -> (nil, ...: integer)
                return function(): (nil, ...: integer)
                end
            end
        ]], [[
            local named = table.pack(test.named_fallthrough())
            assert(named.n == 1)
            assert(named[1] == nil)

            local anonymous = test.make_anonymous()
            local lambda = table.pack(anonymous())
            assert(lambda.n == 1)
            assert(lambda[1] == nil)
        ]])
    end)

    it("carries open surplus runs through allocating body, catch, and nested finally blocks", function()
        run_coder([[
            function values(prefix: string): (...: string)
                return prefix .. "1", prefix .. "2", prefix .. "3"
            end

            function body(force: () -> ()): (integer, ...: string)
                do
                    return 9, values("b")
                finally
                    force()
                end
            end

            function caught(force: () -> ()): (integer, ...: string)
                do
                    raise "body"
                catch
                    return 7, values("c")
                finally
                    force()
                end
            end

            function nested(force: () -> ()): (integer, ...: string)
                do
                    do
                        return 5, values("n")
                    finally
                        force()
                    end
                finally
                    force()
                end
            end
        ]], [[
            collectgarbage("generational")
            local calls = 0
            local function force()
                calls = calls + 1
                local function grow(n)
                    if n == 0 then
                        collectgarbage("collect")
                        return
                    end
                    return grow(n - 1)
                end
                grow(80)
            end

            local a, b, c, d = test.body(force)
            assert(a == 9 and b == "b1" and c == "b2" and d == "b3")
            a, b, c, d = test.caught(force)
            assert(a == 7 and b == "c1" and c == "c2" and d == "c3")
            a, b, c, d = test.nested(force)
            assert(a == 5 and b == "n1" and c == "n2" and d == "n3")
            assert(calls == 4)
        ]])
    end)

    it("roots generic open results before an allocating finally", function()
        run_coder([[
            function survive(f: () -> (...: value),
                             force: () -> ()): (...: value)
                do
                    return f()
                finally
                    force()
                end
            end
        ]], [[
            collectgarbage("generational")
            local seen = setmetatable({}, { __mode = "k" })
            local function produce()
                local first = { label = "first" }
                local second = { label = "second" }
                local closure = function() return "third" end
                seen[first] = "first"
                seen[second] = "second"
                seen[closure] = "closure"
                return first, second, closure
            end
            local function force()
                local function grow(n)
                    if n == 0 then
                        collectgarbage("collect")
                        return
                    end
                    return grow(n - 1)
                end
                grow(80)

                -- `seen` owns only weak keys. At this point the producer's
                -- locals are gone and the outer Lua receiver does not exist;
                -- the pending generic result run must be the sole strong root.
                local alive = {}
                for object, label in pairs(seen) do
                    alive[label] = object
                end
                assert(alive.first and alive.second and alive.closure)
            end

            local got = table.pack(test.survive(produce, force))
            assert(got.n == 3)
            assert(got[1].label == "first" and seen[got[1] ] == "first")
            assert(got[2].label == "second" and seen[got[2] ] == "second")
            assert(type(got[3]) == "function" and got[3]() == "third")
            assert(seen[got[3] ] == "closure")
        ]])
    end)

    it("lets a raising finally replace populated flexible returns from body and catch", function()
        run_coder([[
            record R
                s: string;
            end

            made: integer = 0

            function pending(prefix: string): (...: value)
                made = made + 1
                local array: {string} = { prefix .. "-array" }
                local item: R = R.new(prefix .. "-record")
                local capture: string = prefix .. "-closure"
                return prefix .. "-string", array, item,
                    function(): string return capture end
            end

            function made_count(): integer
                return made
            end

            function from_body(force: () -> ()): (...: value)
                do
                    return pending("body")
                finally
                    force()
                    raise "finally-body"
                end
            end

            function from_catch(force: () -> ()): (...: value)
                do
                    raise "body-error"
                catch
                    return pending("catch")
                finally
                    force()
                    raise "finally-catch"
                end
            end
        ]], [[
            collectgarbage("generational")
            local forced = 0
            local function force()
                forced = forced + 1
                local junk = {}
                for i = 1, 600 do
                    junk[i] = tostring(i):rep(30)
                end
                collectgarbage("collect")
                assert(#junk == 600)
            end

            local body = table.pack(pcall(test.from_body, force))
            assert(body.n == 2)
            assert(body[1] == false)
            assert(body[2] == "finally-body")

            local caught = table.pack(pcall(test.from_catch, force))
            assert(caught.n == 2)
            assert(caught[1] == false)
            assert(caught[2] == "finally-catch")

            assert(test.made_count() == 2)
            assert(forced == 2)
        ]])
    end)

    it("resets a partial conversion before a catch return and lets catch conversion failure override", function()
        run_coder([[
            finalized: integer = 0

            function bad(): (...: value)
                return 1, "not-an-integer", 3
            end

            function note()
                finalized = finalized + 1
            end

            function count_finally(): integer
                return finalized
            end

            function recovered(): (...: integer)
                do
                    return bad()
                catch
                    return 7, 8
                finally
                    note()
                end
            end

            function failed_in_catch(): (...: integer)
                do
                    raise "body"
                catch
                    return bad()
                finally
                    note()
                end
            end

            function invalid_surplus(
                f: () -> (integer, ...: integer)
            ): (...: integer)
                do
                    return f()
                finally
                    note()
                end
            end

            function implicit_tail(good: value, bad_value: value): (...: integer)
                do
                    return good, bad_value
                finally
                    note()
                end
            end

            function explicit_tail(good: value, bad_value: value): (...: integer)
                do
                    return good, (bad_value as integer)
                finally
                    note()
                end
            end
        ]], [[
            local a, b = test.recovered()
            assert(a == 7 and b == 8)
            assert(select("#", test.recovered()) == 2)

            local function bad_tail()
                return 41, "discarded-under-finite-demand"
            end
            local one = test.invalid_surplus(bad_tail)
            assert(one == 41)
            local open_ok, open_err = pcall(function()
                return test.invalid_surplus(bad_tail)
            end)
            assert(not open_ok)
            assert(tostring(open_err):find("expected integer", 1, true),
                tostring(open_err))

            local implicit_one = test.implicit_tail(51, "implicit-bad")
            assert(implicit_one == 51)
            local implicit_open, implicit_err = pcall(function()
                return test.implicit_tail(51, "implicit-bad")
            end)
            assert(not implicit_open)
            assert(tostring(implicit_err):find("expected integer", 1, true),
                tostring(implicit_err))

            local explicit_finite, explicit_err = pcall(function()
                local first = test.explicit_tail(61, "explicit-bad")
                return first
            end)
            assert(not explicit_finite)
            assert(tostring(explicit_err):find("expected integer", 1, true),
                tostring(explicit_err))

            local before = test.count_finally()
            local ok, err = pcall(test.failed_in_catch)
            assert(not ok)
            assert(tostring(err):find("expected integer", 1, true), tostring(err))
            assert(test.count_finally() == before + 1)
        ]])
    end)

    it("roots string, array, map, record, function, and value tails across forced GC and stack growth", function()
        run_coder([[
            record R
                s: string;
            end

            function make_strings(): (...: string)
                return "left" .. "-string", "right" .. "-string"
            end

            function make_arrays(): (...: {string})
                local a: {string} = { "array-left" }
                local b: {string} = { "array-right" }
                return a, b
            end

            function make_maps(): (...: {string:integer})
                local a: {string:integer} = { ["key"] = 11 }
                local b: {string:integer} = { ["key"] = 22 }
                return a, b
            end

            function make_records(): (...: R)
                return R.new("record-left"), R.new("record-right")
            end

            function make_functions(): (...: (integer) -> integer)
                local left: integer = 30
                local right: integer = 40
                return function(n: integer): integer return left + n end,
                       function(n: integer): integer return right + n end
            end

            function make_values(): (...: value)
                local r: R = R.new("value-record")
                local a: {string} = { "value-array" }
                return r, a
            end

            function strings(force: () -> ()): (...: string)
                do return make_strings() finally force() end
            end

            function arrays(force: () -> ()): (...: {string})
                do return make_arrays() finally force() end
            end

            function maps(force: () -> ()): (...: {string:integer})
                do return make_maps() finally force() end
            end

            function records(force: () -> ()): (...: R)
                do return make_records() finally force() end
            end

            function functions(force: () -> ()): (...: (integer) -> integer)
                do return make_functions() finally force() end
            end

            function values(force: () -> ()): (...: value)
                do return make_values() finally force() end
            end
        ]], [[
            collectgarbage("generational")
            local function force()
                local junk = {}
                for i = 1, 500 do junk[i] = tostring(i):rep(20) end
                local function grow(n)
                    if n == 0 then
                        collectgarbage("collect")
                        return #junk
                    end
                    return grow(n - 1)
                end
                assert(grow(80) == 500)
            end

            local s1, s2 = test.strings(force)
            assert(s1 == "left-string" and s2 == "right-string")
            local a1, a2 = test.arrays(force)
            assert(a1[1] == "array-left" and a2[1] == "array-right")
            local m1, m2 = test.maps(force)
            assert(m1.key == 11 and m2.key == 22)
            local r1, r2 = test.records(force)
            assert(r1.s == "record-left" and r2.s == "record-right")
            local f1, f2 = test.functions(force)
            assert(f1(2) == 32 and f2(2) == 42)
            local v1, v2 = test.values(force)
            assert(v1.s == "value-record" and v2[1] == "value-array")
        ]])
    end)

    it("distinguishes finite truncation from open 0, 200, and 201-result boundaries", function()
        run_coder([[
            function many(n: integer): (...: integer)
                if n <= 0 then return end
                return n, many(n - 1)
            end

            function through(n: integer): (...: integer)
                do
                    return many(n)
                finally
                    local marker: integer = n
                end
            end

            function first_two(n: integer): (integer?, integer?)
                return through(n)
            end
        ]], [[
            assert(select("#", test.through(0)) == 0)
            assert(select("#", test.through(200)) == 200)
            local a, b = test.first_two(201)
            assert(a == 201 and b == 200)
            local ok, err = pcall(function()
                return test.through(201)
            end)
            assert(not ok)
            assert(tostring(err):find("too many flexible return values", 1, true),
                tostring(err))
        ]])
    end)
end)

-- An immediately called literal keeps its source function semantics while
-- sharing its caller's generated C frame. These tests exercise the boundaries
-- that a textual body substitution or a result-type shortcut would lose.
local h = require "spec.support.helpers"
local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"

local function generate(source)
    h.reset(true)
    local ast, parse_error = h.parse(source, "test.titan")
    assert.truthy(ast, parse_error)
    local _, errors = checker.check("test", ast, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", ast, {}, driver.TITAN_ABI_VERSION).parts[1].code
end

local function native_body(csrc, name)
    -- Transfer reconstruction has its own cold allocation path. These checks
    -- concern the ordinary source call, including an inlined immediate body.
    return assert(csrc:match(
        "[^\n]*test_\\u2133_" .. name .. "_titan%b()%s*(%b{})"), name)
end

local effects = [[
    log: integer = 0
    function mark(n: integer): integer
        log = log * 10 + n
        return n
    end
    function reset()
        log = 0
    end
    function recorded(): integer
        return log
    end
]]

describe("immediately invoked anonymous functions", function()
    after_each(function()
        os.remove("test.o")
        os.remove("test.so")
        os.remove("test.a")
        os.remove("test.lua")
        os.execute("rm -rf test.dSYM test.so.dSYM")
        if not h.verbose then os.remove("test.c") end
    end)

    it("emits no closure or lambda entries for direct immediate literals", function()
        local csrc = generate([[
            function choose(flag: boolean): integer
                local result = (function (n: integer): integer
                    if flag then return n + 1 end
                    return n - 1
                end)(41)
                return result + 1
            end
        ]])
        assert.not_match("luaF_newCclosure", native_body(csrc, "choose"))
        assert.not_match("lambda_%d+", csrc)
        assert.not_match("luaD_callnoyield", csrc)
    end)

    it("uses bounded storage for a finite flexible projection", function()
        local csrc = generate([[
            function finite(full: boolean): (integer, integer?)
                local head: integer, next: integer? =
                    (function (): (integer, ...: integer)
                        if full then return 7, 8, 9 end
                        return 7
                    end)()
                return head, next
            end
        ]])
        assert.not_match("luaF_newCclosure", native_body(csrc, "finite"))
        assert.not_match("lambda_%d+", csrc)
        assert.not_match("%[TITAN_VARARG_MAX%]", csrc)
        assert.not_match("_flexdesc_", csrc)
        assert.not_match("_flexargs_", csrc)
    end)

    it("keeps allocations for nested escaping and stored function values", function()
        local csrc = generate([[
            function make(n: integer): function (): integer
                return (function (): function (): integer
                    local count = n
                    return function (): integer
                        count = count + 1
                        return count
                    end
                end)()
            end
        ]])
        local _, allocations = native_body(csrc, "make"):gsub("luaF_newCclosure", "")
        assert.equal(1, allocations)
        assert.match("lambda_%d+", csrc)
        h.run_coder([[
            function stored(): integer
                local f = function (): integer return 42 end
                return f()
            end
            function adjusted(): integer
                local f: function (): (integer, nil) =
                    function (): integer return 41 end
                local n, missing = f()
                return n + 1
            end
        ]], [[
            assert(test.stored() == 42)
            assert(test.adjusted() == 42)
        ]])
    end)

    it("preserves zero results, one nil, and explicit scalar adjustment", function()
        h.run_coder(effects .. [[
            function zero()
                return (function () return mark(1) end)()
            end
            function one_nil(): nil
                return (function (): nil end)()
            end
            function scalar_nil(): nil
                return ((function () mark(2) end)())
            end
            function statement()
                (function (): (integer, integer)
                    return mark(3), mark(4)
                end)()
            end
        ]], [[
            assert(select("#", test.zero()) == 0)
            assert(test.recorded() == 1)
            assert(select("#", test.one_nil()) == 1)
            assert(test.one_nil() == nil)
            assert(select("#", test.scalar_nil()) == 1)
            assert(test.recorded() == 12)
            test.statement()
            assert(test.recorded() == 1234)
        ]])
    end)

    it("adjusts fixed results in scalar, list, assignment, and argument contexts", function()
        h.run_coder([[
            record Box
                item: integer
            end
            function combine(a: integer, b: integer): integer
                return a * 10 + b
            end
            function named(item: integer): integer
                return item
            end
            function run(flag: boolean): (integer, integer, integer, integer)
                local a, b = (function (): (integer, integer)
                    if flag then return 2, 3 end
                    return 4, 5
                end)()
                a, b = b, (function (): (integer, integer)
                    return a, 9
                end)()
                local sum = combine((function (): (integer, integer)
                    return 6, 99
                end)(), (function (): integer return 7 end)())
                local box: Box = {item = (function (): (integer, integer)
                    return 8, 99
                end)()}
                local n = named {item = (function (): (integer, integer)
                    return box.item, 99
                end)()}
                return a, b, sum, n
            end
            function scalar(): integer
                return ((function (): (integer, integer) return 4, 99 end)()) + 1
            end
        ]], [[
            local a, b, c, d = test.run(true)
            assert(a == 3 and b == 2 and c == 67 and d == 8)
            a, b, c, d = test.run(false)
            assert(a == 5 and b == 4 and c == 67 and d == 8)
            assert(test.scalar() == 5)
        ]])
    end)

    it("projects absent flexible slots and preserves open result counts", function()
        h.run_coder([[
            function finite(full: boolean): (integer, integer?, integer?)
                return (function (): (integer, ...: integer)
                    if full then return 7, 8, 9 end
                    return 7
                end)()
            end
            function required(): integer
                local needed: integer = (function (): (...: integer) end)()
                return needed
            end
            function open(full: boolean): (...: value)
                return (function (): (...: value)
                    if full then return 1, nil, 3 end
                end)()
            end
            function count(...: value): integer
                return #...
            end
            function arguments(): integer
                return count(0, (function (): (integer, ...: value)
                    return 1, nil, 3
                end)())
            end
            function containers(): (integer, integer, integer, integer)
                local array: {integer} = {1, (function (): (...: integer)
                    return 2, 3
                end)()}
                local map: {integer: integer} = {4, (function (): (...: integer)
                    return 5, 6
                end)()}
                return #array, array[3], #map, map[3]
            end
        ]], [[
            local a, b, c = test.finite(false)
            assert(a == 7 and b == nil and c == nil)
            a, b, c = test.finite(true)
            assert(a == 7 and b == 8 and c == 9)
            assert(not pcall(test.required))
            local values = table.pack(test.open(true))
            assert(values.n == 3 and values[1] == 1 and values[2] == nil and values[3] == 3)
            assert(select("#", test.open(false)) == 0)
            assert(test.arguments() == 4)
            local a, b, c, d = test.containers()
            assert(a == 3 and b == 3 and c == 3 and d == 6)
        ]])
    end)

    it("resets fixed nil and empty flexible results at repeated call sites", function()
        h.run_coder([[
            function run(): boolean
                for iteration = 1, 2 do
                    local text: string? = (function (): string?
                        if iteration == 1 then return "first" end
                        return nil
                    end)()
                    local boxed: value = (function (): value
                        if iteration == 1 then return "first" end
                        return nil
                    end)()
                    local projected: string? = (function (): (...: string)
                        if iteration == 1 then return "first" end
                    end)()
                    local dynamic: value = (function (): (...: value)
                        if iteration == 1 then return "first" end
                    end)()
                    if iteration == 1 then
                        if text ~= "first" or boxed ~= "first"
                            or projected ~= "first" or dynamic ~= "first" then
                            return false
                        end
                    else
                        if text ~= nil or boxed ~= nil or projected ~= nil
                            or dynamic ~= nil then
                            return false
                        end
                    end
                end
                return true
            end
        ]], [[
            assert(test.run())
        ]])
    end)

    it("threads inherited finite demand through nested flexible producers", function()
        h.run_coder([[
            function relay(source: function (): (...: integer)): (...: integer)
                return (function (): (...: integer)
                    return 10, (function (): (...: integer)
                        return source()
                    end)()
                end)()
            end
            function finite(source: function (): (...: integer)): (integer?, integer?)
                return relay(source)
            end
            function forward(items: {integer}): (...: integer)
                return (function (): (...: integer)
                    return ...items
                end)()
            end
            function prefix(items: {integer}): integer?
                return forward(items)
            end
            function items(count: integer): {integer}
                local result: {integer} = {}
                for i = 1, count do result[i] = i end
                return result
            end
        ]], [[
            local a, b = test.finite(function() return 20, 30, 40 end)
            assert(a == 10 and b == 20)
            assert(select("#", test.relay(function() return 20, 30 end)) == 3)
            local full = test.items(200)
            assert(select("#", test.forward(full)) == 200)
            full[201] = 201
            assert(test.prefix(full) == 1)
            local ok, err = pcall(function() return table.pack(test.forward(full)) end)
            assert(not ok and tostring(err):match("too many"), tostring(err))
        ]])
    end)

    it("evaluates adjusted arguments once and preserves the lambda vararg scope", function()
        h.run_coder(effects .. [[
            function fixed(): (integer, integer?, integer)
                local a, b? = (function (x: integer, y: integer?): (integer, integer?)
                    mark(2)
                    return x, y
                end)(mark(1))
                local n = (function (x: integer): integer
                    mark(5)
                    return x
                end)(mark(3), mark(4))
                return a, b, n
            end
            function variadic(...: integer): (integer, integer, integer)
                return (function (first: integer, ...: integer): (integer, integer, integer)
                    return first, #..., ...[2]
                end)(7, 8, 9, 10)
            end
            function spread(items: {integer}): integer
                return (function (first: integer, ...: integer): integer
                    return first * 100 + #... * 10 + ...[2]
                end)(...items)
            end
            function sample(): {integer}
                return {1, 2, 3}
            end
        ]], [[
            local a, b, n = test.fixed()
            assert(a == 1 and b == nil and n == 3)
            assert(test.recorded() == 12345)
            a, b, n = test.variadic(100, 200)
            assert(a == 7 and b == 3 and n == 9)
            assert(test.spread(test.sample()) == 123)
        ]])
    end)

    it("preserves discarded effects and the distinct fixed and flexible coercions", function()
        h.run_coder(effects .. [[
            function fixed()
                (function (): integer return 1.5 end)()
            end
            function flexible()
                (function (): (...: integer) return 1.5 end)()
            end
            function written()
                (function (): (...: integer) return 1.5 as integer end)()
            end
            function surplus(): integer
                local n = (function (): integer
                    return mark(1), mark(2), mark(3)
                end)(), (function (): integer return mark(4) end)()
                return n
            end
            function spread_source(): {integer}
                mark(5)
                return {1, 2, 3}
            end
            function discarded_spread()
                (function () return ...spread_source()[mark(6), mark(7)] end)()
            end
        ]], [[
            assert(not pcall(test.fixed))
            assert(pcall(test.flexible))
            assert(not pcall(test.written))
            assert(test.surplus() == 1)
            assert(test.recorded() == 1234)
            test.discarded_spread()
            assert(test.recorded() == 1234567)
        ]])
    end)

    it("keeps caller conversions after all return effects and lambda cleanup", function()
        h.run_coder(effects .. [[
            function conversion(): integer
                local first: integer, second: integer = (function (): (value, integer)
                    defer mark(2)
                    do
                        return 1.5, mark(1)
                    catch
                        mark(9)
                        return 0, 0
                    end
                end)()
                return first + second
            end
            function representation(): value
                return (function (): float return 1 end)()
            end
        ]], [[
            assert(not pcall(test.conversion))
            assert(test.recorded() == 12)
            assert(math.type(test.representation()) == "float")
        ]])
    end)

    it("attributes an inline raise to its original source line", function()
        h.compile_and_read_c([[
function run()
    (function ()
        raise "inline-attribution"
    end)()
end
        ]])
        local ok, err = h.call("test", [[
            local titan = require "titan"
            local ok, err = pcall(test.run)
            assert(not ok and err == "inline-attribution")
            local trace = titan.backtrace()
            -- Inlining may use the containing function's frame/name; the
            -- raise still belongs to line 3 of the original Titan source.
            assert(trace and trace:find("test.titan:3:", 1, true), tostring(trace))
        ]])
        assert.truthy(ok, err)
    end)

    it("keeps local returns and cleanup inside their logical function", function()
        h.run_coder(effects .. [[
            function run(): integer
                defer mark(5)
                local result = (function (): integer
                    defer mark(3)
                    for i = 1, 3 do
                        defer mark(2)
                        if i == 1 then return mark(1) end
                    end
                    return 0
                end)()
                mark(4)
                return result
            end
            function overridden(): integer
                do
                    local result = (function (): integer
                        defer raise "replacement"
                        return 1
                    end)()
                    return result
                catch
                    if error == "replacement" then return 42 end
                    raise
                end
            end
            function nested(): integer
                do
                    local n = (function (): integer
                        do
                            return (function (): integer
                                raise "inner"
                            end)()
                        catch
                            return 7
                        end
                    end)()
                    raise n
                catch
                    return error as integer
                end
            end
        ]], [[
            assert(test.run() == 1)
            assert(test.recorded() == 12345)
            assert(test.overridden() == 42)
            assert(test.nested() == 7)
        ]])
    end)

    it("preserves pending results when cleanup mutates captured values", function()
        h.run_coder([[
            function fixed(): (string, integer)
                local text = "before"
                local result = (function (): string
                    defer text = "after"
                    return text
                end)()
                return result .. ":" .. text, 7
            end
            function flexible(): (...: string)
                local text = "before"
                return (function (): (...: string)
                    defer text = "after"
                    return text, text .. "!"
                end)()
            end
            function recovered(start: integer): (integer, string)
                return (function (n: integer): (integer, string)
                    local text = "before"
                    do
                        n = n + 10
                        text = text .. ":after"
                        raise "recover"
                    catch
                        return n, text
                    end
                end)(start)
            end
        ]], [[
            local text, n = test.fixed()
            assert(text == "before:after" and n == 7)
            local a, b = test.flexible()
            assert(a == "before" and b == "before!")
            n, text = test.recovered(32)
            assert(n == 42 and text == "before:after")
        ]])
    end)

    it("uses an IIFE iterator tuple and closes only the loop that it leaves", function()
        h.run_coder(effects .. [[
            function step(limit: integer, previous: integer): integer?
                if previous >= limit then return nil end
                return previous + 1
            end
            function close(limit: integer)
                mark(limit)
            end
            function run(): integer
                local total = 0
                for item: integer in (function (): (
                        function (integer, integer): integer?, integer, integer,
                        function (integer): ())
                    return step, 3, 0, close
                end)() do
                    local n = (function (): integer
                        for inner: integer in step, 2, 0, close do
                            return inner
                        end
                        return 0
                    end)()
                    total = total + item + n
                end
                return total
            end
        ]], [[
            assert(test.run() == 9)
            assert(test.recorded() == 2223)
        ]])
    end)

    it("shares captures with arguments and sibling closures", function()
        h.run_coder([[
            function run(): (integer, integer, integer)
                local n = 1
                local sibling = function (): integer
                    n = n + 10
                    return n
                end
                local first = (function (arg: integer): integer
                    n = n + arg
                    return n
                end)((function (): integer n = 5 return 2 end)())
                local second = sibling()
                local third = (function (): integer
                    local n = 100
                    return (function (): integer return n + 1 end)()
                end)()
                return first, second, third
            end
            function enclosing(seed: integer): function (): integer
                return function (): integer
                    return (function (): integer
                        seed = seed + 1
                        return seed
                    end)()
                end
            end
        ]], [[
            local a, b, c = test.run()
            assert(a == 7 and b == 17 and c == 101)
            local f = test.enclosing(40)
            assert(f() == 41 and f() == 42)
        ]])
    end)

    it("gives escaping closures fresh parameter and local cells on every invocation", function()
        h.run_coder([[
            function make(): {function (): integer}
                local result: {function (): integer} = {}
                for i = 1, 3 do
                    result[i] = (function (seed: integer): function (): integer
                        local count = seed * 10
                        return function (): integer
                            seed = seed + 1
                            count = count + seed
                            return count
                        end
                    end)(i)
                end
                return result
            end
        ]], [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                local closures = test.make()
                collectgarbage("collect")
                assert(closures[1]() == 12)
                assert(closures[2]() == 23)
                assert(closures[3]() == 34)
                collectgarbage("collect")
                assert(closures[1]() == 15)
                assert(closures[2]() == 27)
                assert(closures[3]() == 39)
            end
        ]])
    end)

    it("runs only the selected short-circuit or loop expression", function()
        h.run_coder(effects .. [[
            function run(): integer
                local no = false and (function (): boolean
                    mark(9)
                    return true
                end)()
                local yes = true or (function (): boolean
                    mark(9)
                    return false
                end)()
                local total = 0
                local i = 0
                while (function (): boolean
                    i = i + 1
                    return i <= 3
                end)() do
                    total = total + (function (): integer
                        return mark(i)
                    end)()
                end
                if no or not yes then return 0 end
                return total
            end
        ]], [[
            assert(test.run() == 6)
            assert(test.recorded() == 123)
        ]])
    end)

    it("handles protected immediate bodies in loop and if conditions", function()
        h.run_coder([[
            function run(): integer
                local n = 0
                local total = 0
                while (function (): boolean
                    n = n + 1
                    do
                        if n > 3 then raise "stop" end
                        return true
                    catch
                        return false
                    end
                end)() do
                    if (function (item: integer): boolean
                        do
                            item = item + 10
                            raise "check"
                        catch
                            return item > 11
                        end
                    end)(n) then
                        total = total + n
                    end
                end
                return total
            end
        ]], [[
            assert(test.run() == 5)
        ]])
    end)

    it("preserves a computed Map key across its inline exception", function()
        -- The key runs before the value, and its parameter changes across a
        -- real setjmp/longjmp boundary. Keep optimization enabled even in the
        -- compiler shard's otherwise unoptimized disposable fixtures.
        h.with_extra_cflags({ "-O2" }, function()
            local csrc = h.compile_and_read_c(effects .. [[
                function run(start: integer): integer
                    local values: {integer: integer} = {
                        [(function (key: integer): integer
                            do
                                key = key + 1
                                mark(1)
                                raise "key"
                            catch
                                return key
                            end
                        end)(start)] = (function (): integer
                            mark(2)
                            return 42
                        end)()
                    }
                    return values[start + 1]
                end
            ]])
            assert.match("lua_Integer%s+volatile%s+_spill_", csrc)
            local ok, err = h.call("test", [[
                assert(test.run(10) == 42)
                assert(test.recorded() == 12)
            ]])
            assert.truthy(ok, err)
        end)
    end)

    it("releases callee-only argument and local roots at the inline continuation", function()
        h.run_coder([[
            function run(watch: function (value): (), check: function (): boolean): boolean
                local outer: {string: string} = {["name"] = "outer"}
                watch(outer)
                local result = (function (argument: {string: string}): {string: string}
                    watch(argument)
                    local temporary: {string: string} = {["name"] = "temporary"}
                    watch(temporary)
                    local answer: {string: string} = {["name"] = "answer"}
                    watch(answer)
                    return answer
                end)({["name"] = "argument"})
                return check() and result["name"] == "answer" and outer["name"] == "outer"
            end
        ]], [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                local weak = setmetatable({}, {__mode = "v"})
                local function watch(item)
                    weak[item.name] = item
                end
                local function check()
                    collectgarbage("collect")
                    collectgarbage("collect")
                    return weak.argument == nil and weak.temporary == nil
                        and weak.answer ~= nil and weak.outer ~= nil
                end
                -- Observe before run returns: popping the entire caller frame
                -- would otherwise hide roots retained by the inline scope.
                assert(test.run(watch, check))
            end
        ]])
    end)

    it("releases an open flexible suffix after consuming its finite prefix", function()
        h.run_coder([[
            function consume(first: value, ...: value): integer
                return 1 + #...
            end
            function run(make: function (string): value, check: function (): boolean): boolean
                local count = consume((function (): (...: value)
                    return make("prefix"), make("middle"), make("last")
                end)())
                return count == 3 and check()
            end
        ]], [[
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                local weak = setmetatable({}, {__mode = "v"})
                local function make(name)
                    local result = {name = name}
                    weak[name] = result
                    return result
                end
                local function check()
                    collectgarbage("collect")
                    collectgarbage("collect")
                    -- The finite first argument has its own caller holder.
                    -- Both elements owned by the consumed open run are dead.
                    return weak.middle == nil and weak.last == nil
                end
                assert(test.run(make, check))
            end
        ]])
    end)

    it("roots fixed and flexible results across cleanup, stack growth, and GC", function()
        local declarations, uses = {}, {}
        for i = 1, 320 do
            declarations[#declarations + 1] = "local item" .. i .. ": string = seed"
            uses[#uses + 1] = "total = total + #item" .. i
        end
        local source = [[
            function grow(seed: string): integer
        ]] .. table.concat(declarations, "\n") .. [[
                local total = 0
        ]] .. table.concat(uses, "\n") .. [[
                return total
            end
            function fixed(seed: string, collect: function (): ()): (string, string)
                local a, b = (function (): (string, string)
                    defer do
                        grow(seed)
                        collect()
                    end
                    return seed .. ":left", seed .. ":right"
                end)()
                grow(seed)
                collect()
                return a, b
            end
            function flexible(seed: string, collect: function (): ()): (...: string)
                return (function (): (...: string)
                    defer do
                        grow(seed)
                        collect()
                    end
                    return seed .. ":left", seed .. ":right"
                end)()
            end
        ]]
        h.run_coder(source, [[
            local seed = string.rep("rooted result ", 12)
            for _, mode in ipairs({"incremental", "generational"}) do
                collectgarbage(mode)
                for _ = 1, 8 do
                    local a, b = test.fixed(seed, function() collectgarbage("collect") end)
                    assert(a == seed .. ":left" and b == seed .. ":right")
                    a, b = test.flexible(seed, function() collectgarbage("collect") end)
                    assert(a == seed .. ":left" and b == seed .. ":right")
                end
            end
        ]])
    end)

    it("keeps pending IIFE results rooted while deferred cleanup is suspended", function()
        h.run_coder([[
            function pending(seed: string, pause: function (): ()): (string, string?)
                return (function (): (string, ...: string)
                    defer pause()
                    return seed .. ":fixed", seed .. ":tail"
                end)()
            end
        ]], [[
            local coroutine = require "titan.coroutine"
            local seed = string.rep("suspended result ", 12)
            local co = coroutine.create(function(_)
                local first, second = test.pending(seed, function()
                    coroutine.yield("paused", "iife")
                end)
                return first .. "/" .. second
            end, "iife")
            assert(co:resume(nil) == "paused")
            assert(co:status() == "suspended")
            collectgarbage("collect")
            collectgarbage("collect")
            assert(co:resume(nil) == seed .. ":fixed/" .. seed .. ":tail")
            assert(co:status() == "dead")
        ]])
    end)
end)

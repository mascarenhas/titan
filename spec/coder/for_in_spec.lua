local h = require 'spec.support.helpers'

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

describe("generic for loops", function()
    setup(function()
        h.reset()
    end)

    teardown(function()
        if not h.verbose then os.execute("rm -f *.c") end
    end)

    it("runs a one-argument iterator with omitted tuple slots", function()
        h.run_coder_app([[
            i: integer = 0

            function step(_: nil): integer?
                if i >= 3 then
                    return nil
                else
                    i = i + 1
                    return i
                end
            end
        ]], [[
            local sum = 0
            for x: integer in step do
                sum = sum + x
            end
            return sum
        ]], 6)
    end)

    it("passes state and previous control to a two-argument iterator", function()
        h.run_coder_app([[
            function step(limit: integer, n: integer): integer?
                if n >= limit then
                    return nil
                else
                    return n + 1
                end
            end
        ]], [[
            local sum = 0
            for x: integer in step, 4, 0 do
                sum = sum + x
            end
            return sum
        ]], 10)
    end)

    it("stops only on nil for boolean? controls", function()
        h.run_coder_app([[
            i: integer = 0

            function step(_: nil): boolean?
                i = i + 1
                if i == 1 then
                    return false
                elseif i == 2 then
                    return true
                else
                    return nil
                end
            end
        ]], [[
            local score = 0
            for b: boolean in step do
                if b == false then
                    score = score + 1
                else
                    score = score + 10
                end
            end
            return score
        ]], 11)
    end)

    it("stops only on nil for value controls", function()
        h.run_coder_app([[
            i: integer = 0

            function step(_: nil): value
                i = i + 1
                if i == 1 then
                    return false
                elseif i == 2 then
                    return "x"
                else
                    return nil
                end
            end
        ]], [[
            local score = 0
            for v: value in step do
                if v == false then
                    score = score + 1
                else
                    score = score + 10
                end
            end
            return score
        ]], 11)
    end)

    it("runs close on normal exhaustion and break", function()
        h.run_coder_app([[
            closed: integer = 0

            function step(limit: integer, n: integer): integer?
                if n >= limit then
                    return nil
                else
                    return n + 1
                end
            end

            function close(limit: integer): nil
                closed = closed + limit
                return nil
            end
        ]], [[
            local sum = 0
            for x: integer in step, 3, 0, close do
                sum = sum + x
            end
            for x: integer in step, 4, 0, close do
                if x == 2 then break end
                sum = sum + x
            end
            return sum + closed
        ]], 14)
    end)

    it("runs zero-parameter close functions", function()
        h.run_coder_app([[
            closed: integer = 0

            function step(_: nil, n: integer): integer?
                if n >= 2 then
                    return nil
                else
                    return n + 1
                end
            end

            function close(): nil
                closed = closed + 20
                return nil
            end
        ]], [[
            local sum = 0
            for x: integer in step, nil, 0, close do
                sum = sum + x
            end
            return sum + closed
        ]], 23)
    end)

    it("runs close when the initial iterator call raises", function()
        h.run_coder_app([[
            closed: integer = 0

            function step(_: nil): integer?
                raise "boom"
            end

            function close(_: nil): nil
                closed = closed + 7
                return nil
            end
        ]], [[
            do
                for x: integer in step, nil, nil, close do
                end
            catch
                return closed
            end
            return 0
        ]], 7)
    end)

    it("runs close when an update iterator call raises", function()
        h.run_coder_app([[
            closed: integer = 0

            function step(_: nil, n: integer): integer?
                if n == 0 then
                    return 1
                else
                    raise "boom"
                end
            end

            function close(_: nil): nil
                closed = closed + 9
                return nil
            end
        ]], [[
            do
                for x: integer in step, nil, 0, close do
                end
            catch
                return closed
            end
            return 0
        ]], 9)
    end)

    it("runs close when the loop body raises", function()
        h.run_coder_app([[
            closed: integer = 0

            function step(_: nil): integer?
                return 1
            end

            function close(_: nil): nil
                closed = closed + 5
                return nil
            end
        ]], [[
            do
                for x: integer in step, nil, nil, close do
                    raise "body"
                end
            catch
                return closed
            end
            return 0
        ]], 5)
    end)

    it("lets close raise override a pending return", function()
        local status, output = h.compile_and_run_app([[
            function step(_: nil): integer?
                return 1
            end

            function close(_: nil): nil
                raise "closed"
            end

            function main(args: {string}): integer
                for x: integer in step, nil, nil, close do
                    return 3
                end
                return 0
            end
        ]])
        assert.equal(1, status)
        assert.match("closed", output)
    end)

    it("lets close raise override a pending break", function()
        local status, output = h.compile_and_run_app([[
            function step(_: nil): integer?
                return 1
            end

            function close(_: nil): nil
                raise "closed"
            end

            function main(args: {string}): integer
                for x: integer in step, nil, nil, close do
                    break
                end
                return 0
            end
        ]])
        assert.equal(1, status)
        assert.match("closed", output)
    end)

    it("captures a fresh visible variable on each iteration", function()
        h.run_coder([[
            function step(_: nil, n: integer): integer?
                if n >= 3 then
                    return nil
                else
                    return n + 1
                end
            end

            function make_closures(): {() -> integer}
                local fns: {() -> integer} = {}
                local i = 1
                for x: integer in step, nil, 0 do
                    fns[i] = function (): integer
                        return x
                    end
                    i = i + 1
                end
                return fns
            end
        ]], [[
            local fns = test.make_closures()
            assert(fns[1]() == 1)
            assert(fns[2]() == 2)
            assert(fns[3]() == 3)
        ]])
    end)

    it("calls a Lua iterator through the generic value path", function()
        h.run_coder([[
            function sum(step: (nil) -> integer?): integer
                local total = 0
                for x: integer in step do
                    total = total + x
                end
                return total
            end
        ]], [[
            local i = 0
            assert(test.sum(function(_)
                i = i + 1
                if i <= 4 then return i end
                return nil
            end) == 10)
        ]])
    end)

    it("coerces value iterator and close slots to zero-parameter callables", function()
        h.run_coder([[
            function sum(step: value, closev: value): integer
                local total = 0
                for x: integer in step, nil, nil, closev do
                    total = total + x
                end
                return total
            end
        ]], [[
            local i = 0
            local closed = 0
            local total = test.sum(function()
                i = i + 1
                if i <= 4 then return i end
                return nil
            end, function()
                closed = closed + 1
            end)
            assert(total == 10)
            assert(closed == 1)
        ]])
    end)

    it("coerces value iterators using state and initial control values", function()
        h.run_coder([[
            function sum(step: value): integer
                local total = 0
                for x: integer in step, 4, 0 do
                    total = total + x
                end
                return total
            end
        ]], [[
            assert(test.sum(function(limit, n)
                if n >= limit then return nil end
                return n + 1
            end) == 10)
        ]])
    end)

    it("calls foreign functions as iterator and close callables", function()
        with_header([[
            typedef int ffi_int;
            typedef ffi_int *ffi_int_ptr;
            static int ffi_values[3] = { 2, 4, 8 };
            static int ffi_index = 0;
            static int ffi_closed = 0;

            static ffi_int_ptr ffi_next(void) {
                if (ffi_index >= 3) return 0;
                return &ffi_values[ffi_index++];
            }

            static void ffi_close(void) {
                ffi_closed += 10;
            }
        ]], function(header)
            h.run_coder([[
                local c = foreign import "]] .. header .. [["

                function sum(): integer
                    local total = 0
                    for p: c.ffi_int_ptr in c.ffi_next, nil, nil, c.ffi_close do
                        total = total + (p[0] as integer)
                    end
                    return total + (c.ffi_closed as integer)
                end
            ]], [[
                assert(test.sum() == 24)
            ]])
        end)
    end)

    it("fills state and initial control from a trailing variadic spread", function()
        h.run_coder([[
            function step(limitv: value, nv: value): value
                local limit = limitv as integer
                local n = nv as integer
                if n >= limit then
                    return nil
                else
                    return n + 1
                end
            end

            function sum(...: value): integer
                local total = 0
                for x: value in step, ... do
                    total = total + (x as integer)
                end
                return total
            end
        ]], [[
            assert(test.sum(4, 0) == 10)
        ]])
    end)

    it("can take the close function from a trailing variadic spread", function()
        h.run_coder([[
            closed: integer = 0

            function step(_: nil, n: integer): integer?
                if n >= 3 then
                    return nil
                else
                    return n + 1
                end
            end

            function close(_: nil): nil
                closed = closed + 10
                return nil
            end

            function go(...: (nil) -> nil): integer
                local total = 0
                for x: integer in step, nil, 0, ... do
                    total = total + x
                end
                return total + closed
            end

            function run(): integer
                return go(close)
            end
        ]], [[
            assert(test.run() == 16)
        ]])
    end)

    it("keeps gc iterator results alive across loop churn", function()
        h.run_coder([[
            function step(_: nil, n: integer): (integer?, string)
                if n >= 30 then
                    return nil, ""
                else
                    n = n + 1
                    return n, "s" .. n
                end
            end

            function total(): integer
                local acc = 0
                for n: integer, label: string in step, nil, 0 do
                    local junk: {integer} = {}
                    local i = 1
                    while i <= 100 do
                        junk[i] = i
                        i = i + 1
                    end
                    acc = acc + n + #label
                end
                return acc
            end
        ]], [[
            collectgarbage("generational")
            assert(test.total() == 546)
            collectgarbage("incremental")
        ]])
    end)
end)

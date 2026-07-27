local h = require 'spec.support.helpers'

local run_checker = h.run_checker

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

describe("optional function parameters", function()
    it("adjusts short Titan calls upward with nil", function()
        local ok, err = run_checker([[
            function fill(a: integer?, b: boolean, c: value): integer
                return 1
            end

            function run(): integer
                return fill() + fill(10) + fill(10, true)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("adjusts short method calls upward with nil", function()
        local ok, err = run_checker([[
            record Box end

            function Box:score(a: integer?, b: boolean): integer
                return 1
            end

            function run(b: Box): integer
                return b:score() + b:score(10)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("adjusts short first-class function calls upward with nil", function()
        local ok, err = run_checker([[
            function fill(a: integer?, b: boolean): integer
                return 1
            end

            function run(): integer
                local f: (integer?, boolean) -> integer = fill
                return f()
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("adjusts hidden parameters of compatible function values", function()
        local ok, err = run_checker([[
            function fixed(a: integer?, b: value): integer
                return 1
            end

            function tailed(a: integer?, b: value): integer
                return 2
            end

            function run(): integer
                local noargs: () -> integer = fixed
                local integers: (...: integer) -> integer = tailed
                return noargs() + integers(10, 20)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects hidden parameters that adjustment cannot populate", function()
        local ok, err = run_checker([[
            function required(a: integer): integer
                return a
            end

            function run(): integer
                local noargs: () -> integer = required
                return noargs()
            end
        ]])
        assert.falsy(ok)
        assert.match("types in declaration of local variable noargs do not match",
            err)

        ok, err = run_checker([[
            function strings(a: string?): integer
                return 1
            end

            function run(): integer
                local integers: (...: integer) -> integer = strings
                return integers(10)
            end
        ]])
        assert.falsy(ok)
        assert.match("types in declaration of local variable integers do not match",
            err)
    end)

    it("adjusts borrowed fixed parameters when forwarding ... to a variadic callee", function()
        local ok, err = run_checker([[
            function fill(a: integer?, b: boolean, ...: integer): integer
                return 1
            end

            function run(...: integer): integer
                return fill(...)
            end
        ]])
        assert.truthy(ok, err)
    end)

    it("rejects omitted arguments that cannot accept nil", function()
        local ok, err = run_checker([[
            function fill(a: integer, b: integer?): integer
                return a
            end

            function run(): integer
                return fill()
            end
        ]])
        assert.falsy(ok)
        assert.match("types in argument 1 of call to function 'fill' do not match, expected integer but found nil", err)
    end)

    it("retains and discards surplus Titan arguments", function()
        local ok, err, tree = run_checker([[
            function fill(a: integer?, b: boolean): integer
                return 1
            end

            function run(): integer
                return fill(nil, false, nil)
            end
        ]])
        assert.truthy(ok, err)
        local call = tree[2].block.stats[1].exps[1]
        assert.same(2, call._npassed_args)
        assert.truthy(call.args.args[3]._discard_results)
    end)

    it("keeps foreign C calls strict", function()
        with_header([[
            extern int ffi_add(int a, int b);
        ]], function(header)
            local ok, err = run_checker([[
                local c = foreign import "]] .. header .. [["

                function run(): integer
                    return c.ffi_add(1)
                end
            ]])
            assert.falsy(ok)
            assert.match("function 'c.ffi_add' called with 1 arguments but expects 2", err)
        end)
    end)
end)

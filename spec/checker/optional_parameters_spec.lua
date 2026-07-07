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

    it("still rejects surplus arguments", function()
        local ok, err = run_checker([[
            function fill(a: integer?, b: boolean): integer
                return 1
            end

            function run(): integer
                return fill(nil, false, nil)
            end
        ]])
        assert.falsy(ok)
        assert.match("function 'fill' called with 3 arguments but expects 2", err)
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

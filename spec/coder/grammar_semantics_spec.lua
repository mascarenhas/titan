local h = require "spec.support.helpers"

describe("simplified grammar generated behavior", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".lua", ".ffi.h", ".titan.h" }) do
            os.remove("test" .. suffix)
        end
        os.execute("rm -rf test.so.dSYM")
    end)

    it("reads and writes current-module members and captures their callables", function()
        h.run_coder([[
            local count: integer?
            local end: integer = 7
            local function add(n: integer): integer return n + M.end end
            function exercise(): integer
                local count = 99
                local add: function(integer): integer = M.add
                M.count = (M.count or 0) + 1
                return add(M.count)
            end
        ]], [[
            assert(test.exercise() == 8)
            assert(test.exercise() == 9)
        ]])
    end)

    it("casts the module marker to its actual Udata pointer", function()
        h.run_coder([[
            foreign import "titan/ffi.h"
            function same(): boolean
                local first = M as foreign *Udata
                local second = M as foreign *Udata
                return (M is foreign *Udata) and first == second
            end
        ]], [[ assert(test.same()) ]])
    end)

    it("lowers module-marker casts in generic bodies and inline C operands", function()
        h.run_coder([[
            foreign import "titan/ffi.h"
            foreign function present(pointer: *Udata): int
                if pointer ~= nil then return 1 end
                return 0
            end
            local function pointer<|T|>(item: T): foreign *Udata
                return M as foreign *Udata
            end
            local function positive<|T|>(item: T): boolean
                return M is foreign *Udata
            end
            function direct(): boolean
                local expected = M as foreign *Udata
                return (M as foreign *Udata) == expected
                    and (present(M as foreign *Udata) as integer) == 1
            end
            function generic(): boolean
                return pointer<|integer|>(1) == (M as foreign *Udata)
                    and positive<|string|>("marker")
                    and (present(pointer<|integer|>(1)) as integer) == 1
            end
        ]], [[ assert(test.direct()); assert(test.generic()) ]])
    end)

    it("compiles raw typedef aliases and dedicated allocation expressions", function()
        h.run_coder([[
            foreign type Count = int
            function calculate(): integer
                local values = foreign Count.new_array(3)
                values[0] = 4
                values[2] = 8
                local copy: owned Count[] = values
                values[0] = 99
                return #values + copy[0] + copy[2]
            end
        ]], [[ assert(test.calculate() == 15) ]])
    end)

    it("adjusts parenthesized collection and vararg spreads to one value", function()
        h.run_coder([[
            local calls: integer = 0
            local function values(): {integer}
                calls = calls + 1
                return {17, 19}
            end
            function first(): integer
                local head? = (...values())
                return calls * 100 + head
            end
            function second(...: integer): integer?
                return (...[2,])
            end
            function tail_count(...: integer): integer
                local tail: {integer} = {...[2,]}
                return #tail + (#... - 1)
            end
        ]], [[
            assert(test.first() == 117)
            assert(test.second(2, 5, 8) == 5)
            assert(test.second(2) == nil)
            assert(test.tail_count(2, 5, 8) == 4)
        ]])
    end)

    it("preserves catch-visible locals read only by an adjusted spread", function()
        h.run_coder([[
            function recover(): integer
                local changed = 1
                do
                    changed = 23
                    raise "recover"
                catch
                    return (...{changed})
                end
            end
        ]], [[ assert(test.recover() == 23) ]])
    end)
end)

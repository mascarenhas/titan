local h = require "spec.support.helpers"

local modules = {"test", "optional_provider", "optional_consumer"}
local header

local function precise_header()
    header = os.tmpname() .. ".h"
    local out = assert(io.open(header, "w"))
    out:write([[
        #include <float.h>
        typedef unsigned long long optional_wide_t;
        static long double optional_precise(void) {
            return 1.0L + LDBL_EPSILON;
        }
    ]])
    out:close()
    return 'foreign import "' .. header .. '"\n'
end

describe("native numeric optional storage", function()
    after_each(function()
        if header then os.remove(header); header = nil end
        for _, name in ipairs(modules) do
            for _, ext in ipairs({"c", "o", "so", "a", "ffi.h", "titan.h"}) do
                if ext ~= "c" or not h.verbose then os.remove(name .. "." .. ext) end
            end
        end
    end)

    it("keeps wide Options exact across locals, functions, records, and union cases", function()
        h.run_coder([[
            foreign import "limits.h"
            record Wide
                item: (foreign unsigned long long)?
            end
            union Choice
                some((foreign unsigned long long)?)
            end
            function identity(x: (foreign unsigned long long)?): (foreign unsigned long long)?
                return x
            end
            function equal(x: (foreign unsigned long long)?, y: (foreign unsigned long long)?): boolean
                return x == y
            end
            function make(): Wide
                return Wide.new(identity(ffi.ULLONG_MAX))
            end
            function exact(w: Wide): boolean
                local x = identity(w.item)
                local y: (foreign unsigned long long)? = nil
                y = x
                if not equal(x, y) then return false end
                if not y then return false end
                local fallback: foreign unsigned long long = 0
                if (y or fallback) ~= ffi.ULLONG_MAX then return false end
                case Choice.some(y)
                when some(v) then return (v as foreign unsigned long long) == ffi.ULLONG_MAX
                end
            end
            function clear(w: Wide): boolean
                w.item = nil
                return not w.item
            end
            function replace(w: Wide): boolean
                w.item = identity(ffi.ULLONG_MAX)
                return exact(w)
            end
        ]], [[
            local w = test.make()
            assert(test.exact(w))
            assert(not pcall(function() return w.item end))
            assert(not pcall(function() w.item = 'wrong' end))
            assert(test.exact(w))
            assert(test.clear(w) and w.item == nil)
            w.item = 42
            assert(w.item == 42)
            assert(test.replace(w))
        ]])
    end)

    it("preserves long double precision and typedefs in native optional ABI", function()
        h.run_coder(precise_header() .. [[
            foreign import "limits.h"
            record Values
                local wide: (foreign optional_wide_t)?
                precise: (foreign long double)?
            end
            function identity(x: (foreign long double)?): (foreign long double)? return x end
            local function same_type(x: (foreign optional_wide_t)?): boolean
                return x is (foreign unsigned long long)?
            end
            function exercise(): boolean
                local initial = ffi.optional_precise()
                local r = Values.new(ffi.ULLONG_MAX, identity(initial))
                local wide: (foreign unsigned long long)? = r.wide
                local exact = r.precise as foreign long double
                r.precise = nil
                r.precise = identity(exact)
                return exact == initial
                    and same_type(r.wide)
                    and (r.precise as foreign long double) == initial
                    and (wide as foreign unsigned long long) == ffi.ULLONG_MAX
            end
        ]], [[assert(test.exercise())]])
    end)

    it("keeps optional adjustment exact for variadic and immediate returns", function()
        h.run_coder([[
            foreign import "limits.h"
            function echo(...: (foreign unsigned long long)?): (...: (foreign unsigned long long)?)
                return ...
            end
            function exercise(): boolean
                local a: (foreign unsigned long long)?, b: (foreign unsigned long long)? =
                    echo(ffi.ULLONG_MAX)
                local c: (foreign unsigned long long)?, d: (foreign unsigned long long)? =
                    (function(): (...: (foreign unsigned long long)?)
                        return ffi.ULLONG_MAX
                    end)()
                return (a as foreign unsigned long long) == ffi.ULLONG_MAX
                    and (c as foreign unsigned long long) == ffi.ULLONG_MAX
                    and not b and not d
            end
        ]], [[assert(test.exercise())]])
    end)

    it("roundtrips Lua Options and checks genuine boxing before destination mutation", function()
        h.run_coder([[
            foreign import "limits.h"
            record Box
                item: value
            end
            function identity(x: (foreign unsigned long long)?): (foreign unsigned long long)?
                return x
            end
            function assign(box: Box)
                local native: (foreign unsigned long long)? = ffi.ULLONG_MAX
                box.item = native
            end
            function make(): Box return Box.new("unchanged") end
        ]], [[
            assert(test.identity(nil) == nil)
            assert(test.identity(42) == 42)
            assert(not pcall(test.identity, -1))
            local box = test.make()
            assert(not pcall(test.assign, box))
            assert(box.item == 'unchanged')
        ]])
    end)

    it("checks optional numeric maps and preserves native values across catch recovery", function()
        h.run_coder([[
            foreign import "limits.h"
            function fits(x: (foreign unsigned long long)?): boolean
                return x is integer?
            end
            function widen(x: integer?): (foreign unsigned long long)?
                return x
            end
            function force(x: (foreign unsigned long long)?): foreign unsigned long long
                return x
            end
            function exercise(): boolean
                local saved: (foreign unsigned long long)? = nil
                do
                    saved = ffi.ULLONG_MAX
                    raise "recover"
                catch
                    return not fits(saved)
                        and force(saved) == ffi.ULLONG_MAX
                end
                return false
            end
        ]], [[
            assert(test.exercise())
            assert(test.fits(nil) and test.fits(42))
            assert(test.widen(nil) == nil and test.widen(42) == 42)
            assert(not pcall(test.widen, -1))
            assert(not pcall(test.force, nil))
        ]])
    end)

    it("retains exact optional function signatures across source-free providers", function()
        local ok, err = h.build_so_chain({{
            name = "optional_provider",
            src = precise_header() .. [[
                foreign import "limits.h"
                function wide(x: (foreign unsigned long long)?): (foreign unsigned long long)? return x end
                function precise(x: (foreign long double)?): (foreign long double)? return x end
                function initial(): foreign long double return ffi.optional_precise() end
            ]],
        }, {
            name = "optional_consumer",
            src = [[
                foreign import "limits.h"
                local provider = import "optional_provider"
                function exercise(): boolean
                    local wide = provider.wide(ffi.ULLONG_MAX)
                    local initial = provider.initial()
                    local precise = provider.precise(initial)
                    return (wide as foreign unsigned long long) == ffi.ULLONG_MAX
                        and (precise as foreign long double) == initial
                end
            ]],
        }})
        assert.truthy(ok, err)
        local ran, output = h.call("optional_consumer", [[assert(optional_consumer.exercise())]])
        assert.truthy(ran, output)
    end)
end)

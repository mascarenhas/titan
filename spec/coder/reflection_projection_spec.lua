local h = require "spec.support.helpers"

describe("reflected native projection generation", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".lua" }) do
            os.remove("test" .. suffix)
        end
    end)

    it("publishes typed default construction and lossless native projections", function()
        local c = h.compile_and_read_c([[
            record Message
                const bits: foreign unsigned long long
                const text: string
                const last: integer?
                const wide: foreign long double
            end

            function Message.new(bits: foreign unsigned long long): Message
                raise "custom constructor must not implement reflection"
            end

            function make(): Message
                return {bits = 7, text = "seven", last = nil, wide = 0}
            end
        ]])
        assert.truthy(c:find("lua_rawsetp(L, -2, TITAN_MT_PROJECT);", 1, true))
        assert.truthy(c:find("lua_rawsetp(L, -2, TITAN_MT_CONSTRUCT);", 1, true))
        assert.truthy(c:find("lua_rawsetp(L, -2, TITAN_MT_PUBLIC);", 1, true))
        assert.truthy(c:find("memcpy(&_integer, &_bits, sizeof(_integer))", 1, true))
        assert.truthy(c:find("titan_reflect_projection_input(L, input, 4)", 1, true))
        assert.truthy(c:find("titan_reflect_format_long_double(_text", 1, true))
        assert.truthy(c:find("titan_reflect_parse_long_double(_text", 1, true))
        assert.truthy(c:find("setuvalue(L, s2v(L->top.p), _rec); L->top.p++;", 1, true))
        assert.truthy(c:find("luaC_barrierback(L, obj2gco(_rec)", 1, true))
    end)

    it("projects embedded C structs using their typed fields", function()
        local c = h.compile_and_read_c([[
            foreign import "stdlib.h"
            local record Native
                value: foreign div_t
            end
            function make(): value
                return Native(ffi.div(17, 5))
            end
        ]])
        assert.truthy(c:find("titan_reflect_projection_array(L, 2)", 1, true))
        assert.truthy(c:find(").quot", 1, true))
        assert.truthy(c:find(").rem", 1, true))
        assert.truthy(c:find("native integer projection requires integer bits", 1, true))
    end)

    it("keeps owned foreign values in traced slots for projection and construction", function()
        local c = h.compile_and_read_c([[
            local record Native
                value: owned int[]
                optional: (owned int[])?
            end
            function make(): value
                local storage: owned int[] = foreign int.new_array(1)
                return Native(storage, storage)
            end
        ]])
        assert.truthy(c:find("lua_pushtvalue(L, _projected)", 1, true))
        assert.truthy(c:find("luaC_barrierback(L, obj2gco(_rec)", 1, true))
    end)

    it("initializes qualified pointers and adjacent bitfields before copying storage", function()
        local c = h.compile_and_read_c([[
            foreign import "spec/stdlib/titan/reflect/reflection_recursive.h"
            local record Qualified
                const pointer: foreign titan_reflect_const_pointer
                const data: foreign titan_reflect_qualified
            end
            function make(): value
                return Qualified(nil, ffi.titan_reflect_make_qualified())
            end
        ]])
        assert.truthy(c:find("_projection_scalar_0 = titan_cast_func", 1, true))
        assert.truthy(c:find(".first = _projection_bitfield_0_2, .second = _projection_bitfield_0_3, .third = _projection_bitfield_0_4", 1, true))
        assert.truthy(c:find("native bitfield projection out of range", 1, true))
        assert.falsy(c:find(").first = _projection_scalar", 1, true))
    end)
end)

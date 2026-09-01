require "titan-compiler.coder.core"
local coder_names = require "titan-compiler.coder.names"
local h = require "spec.support.helpers"
local types = require "titan-compiler.types"

local module_names = {
    "test",
    "surface_provider",
    "surface_consumer",
}

local function remove_outputs(name)
    for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".titan.h" }) do
        os.remove(name .. suffix)
    end
end

describe("surface C99 type code generation", function()
    after_each(function()
        for _, name in ipairs(module_names) do remove_outputs(name) end
    end)

    it("allocates and accesses primitive owned arrays directly", function()
        h.run_coder([[
            function exercise(): integer
                local ints: owned int[] = int.new_array(2)
                ints[0] = 37
                ints[1] = 5
                local chars: owned char[] = char.new_array(3)
                local floats: owned foreign float[] =
                    foreign float.new_array(1)
                return ints[0] as integer + ints[1] as integer
                    + #chars + #floats
            end

            function layout(): integer
                return bool.sizeof + signed char.alignof
                    + unsigned long.sizeof + long double.alignof
            end
        ]], [[
            assert(test.exercise() == 46)
            assert(test.layout() > 0)
        ]])
    end)

    it("gives portable and header-local C graphs distinct identity rules",
    function()
        local left = types.CInteger("int", true, 3, 32)
        left._ffi_scope = "header_left"
        local right = types.CInteger("int", true, 3, 32)
        right._ffi_scope = "header_right"
        local portable_left = types.Function(
            { left }, { left }, false, false, false)
        local portable_right = types.Function(
            { right }, { right }, false, false, false)
        assert.equal(
            coder_names._owned_c_metatable_key(types.COwned(left, true)),
            coder_names._owned_c_metatable_key(types.COwned(right, true)))

        local left_alias = types.CTypedef("word", left, {})
        left_alias._ffi_scope = "header_left"
        local right_alias = types.CTypedef("word", right, {})
        right_alias._ffi_scope = "header_right"
        assert.not_equal(
            coder_names._owned_c_metatable_key(
                types.COwned(left_alias, true)),
            coder_names._owned_c_metatable_key(
                types.COwned(right_alias, true)))

        local outer_const = types.CPointer(types.CPointer(
            types.CInteger("int", true, 3, 32), {}), { "const" })
        local inner_const = types.CPointer(types.CPointer(
            types.CInteger("int", true, 3, 32), { "const" }), {})
        assert.equal(types.tostring(outer_const), types.tostring(inner_const))
        assert.is_false(types.equals(outer_const, inner_const))
        assert.not_equal(
            coder_names._owned_c_metatable_key(
                types.COwned(outer_const, false)),
            coder_names._owned_c_metatable_key(
                types.COwned(inner_const, false)))
    end)

    it("shares portable callable and owner identity across modules", function()
        local ok, err = h.generate_modules({
            surface_provider = [[
                type Callback = foreign (int) -> int

                foreign function plus_one(item: int): int
                    return item + (1 as int)
                end

                callback_invocations: integer = 0

                function callback(): Callback
                    callback_invocations = callback_invocations + 1
                    return plus_one
                end

                function expose(): value
                    local identity: (int) -> int =
                        function(item: int): int return item end
                    return identity
                end

                function make(): owned int[]
                    local items: owned int[] = int.new_array(2)
                    items[0] = 41
                    return items
                end
            ]],
            surface_consumer = [[
                local provider = import "surface_provider"

                function call_foreign(): integer
                    local callback: provider.Callback = provider.callback()
                    local item: int = 41
                    return callback(item) as integer
                end

                function invoke(): integer
                    local raw: value = provider.expose()
                    local identity: (int) -> int = raw
                    local item: int = 41
                    return identity(item) as integer
                end

                function count(): integer
                    local items: owned int[] = provider.make()
                    return #items + items[0] as integer
                end
            ]],
        }, "surface_consumer", nil, { interface = "compiled" })
        assert.truthy(ok, err)

        local lua_blocked, lua_message = h.call("surface_provider", [[
            local called, call_error = pcall(surface_provider.callback)
            assert(not called)
            assert(call_error:match("no Lua/TValue representation"))
            assert(surface_provider.callback_invocations == 0)
        ]])
        assert.truthy(lua_blocked, lua_message)

        local called, message = h.call("surface_consumer", [[
            assert(surface_consumer.call_foreign() == 42)
            assert(surface_consumer.invoke() == 41)
            assert(surface_consumer.count() == 43)
        ]])
        assert.truthy(called, message)
    end)
end)

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

    it("shares portable callable and owner identity across modules", function()
        local ok, err = h.generate_modules({
            surface_provider = [[
                type Callback = foreign (int) -> int

                foreign function plus_one(item: int): int
                    return item + (1 as int)
                end

                callback_invocations: integer = 0
                stored_callback: Callback = nil

                record CallbackBox
                    callback: Callback
                end

                function callback(): Callback
                    callback_invocations = callback_invocations + 1
                    return plus_one
                end

                function invoke_boxed(raw: value): integer
                    local restored = raw as Callback
                    return restored(41 as int) as integer
                end

                function boxed_callback(): CallbackBox
                    return CallbackBox.new(plus_one)
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

                do
                    stored_callback = plus_one
                end
            ]],
            surface_consumer = [[
                local provider = import "surface_provider"

                function call_foreign(): integer
                    local callback: provider.Callback = provider.callback()
                    local item: int = 41
                    return callback(item) as integer
                end

                function call_stored(): integer
                    local box = provider.boxed_callback()
                    return box.callback(40 as int) as integer
                        + provider.stored_callback(0 as int) as integer
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

        local lua_called, lua_message = h.call("surface_provider", [[
            local callback = surface_provider.callback()
            assert(type(callback) == "userdata")
            assert(surface_provider.callback_invocations == 1)
            assert(callback == surface_provider.stored_callback)
            assert(surface_provider.boxed_callback().callback == callback)
            assert(surface_provider.invoke_boxed(callback) == 42)
            local called, call_error = pcall(surface_provider.invoke_boxed, {})
            assert(not called and call_error:match("expected C pointer"))
        ]])
        assert.truthy(lua_called, lua_message)

        local called, message = h.call("surface_consumer", [[
            assert(surface_consumer.call_foreign() == 42)
            assert(surface_consumer.call_stored() == 42)
            assert(surface_consumer.invoke() == 41)
            assert(surface_consumer.count() == 43)
        ]])
        assert.truthy(called, message)
    end)

    it("exports *lua_State across module boundaries", function()
        local ok, err = h.generate_modules({
            surface_provider = [[
                type Callback = foreign (*lua_State) -> int

                record Holder
                    state: *lua_State
                end

                function make_holder(s: *lua_State): Holder
                    return { state = s }
                end

                function extract(h: Holder): *lua_State
                    return h.state
                end
            ]],
            surface_consumer = [[
                local provider = import "surface_provider"

                function roundtrip(): boolean
                    local h = provider.make_holder(L)
                    local s: *lua_State = provider.extract(h)
                    return (s as *void) == (L as *void)
                end
            ]],
        }, "surface_consumer", nil, { interface = "compiled" })
        assert.truthy(ok, err)

        local called, message = h.call("surface_consumer", [[
            assert(surface_consumer.roundtrip())
        ]])
        assert.truthy(called, message)
    end)
end)


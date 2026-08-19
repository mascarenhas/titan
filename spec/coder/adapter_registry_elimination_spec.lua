local h = require "spec.support.helpers"

describe("adapter registry elimination and module invariants", function()
    local function cleanup(...)
        for _, name in ipairs({ ... }) do
            for _, ext in ipairs({ ".c", ".o", ".so", ".a" }) do
                os.remove(name .. ext)
            end
            os.execute("rm -rf " .. name .. ".so.dSYM")
        end
    end

    after_each(function()
        cleanup(
            "test",
            "callable_mod",
            "callable_consumer",
            "callable_bridge",
            "iface_api",
            "iface_provider",
            "iface_caster",
            "iface_consumer",
            "iface_bridge"
        )
    end)

    describe("callable adapters", function()
        it("emits upvalue[0] as _mod and fetches type tags strictly via module upvalue slots",
        function()
            local csrc = h.compile_and_read_c([[
                record Item
                    count: integer
                end

                local function item_fn(x: Item, arr: {integer}): Item
                    return Item.new(x.count + #arr)
                end

                function wrap(): (value, value) -> value
                    local f: (value, value) -> value = item_fn
                    return f
                end
            ]])

            assert.is_nil(csrc:find("titan_registry_get_string_table", 1, true),
                "callable adapter must not query Lua registry for string table")
            assert.is_nil(csrc:find("titan_array_cached_metatables", 1, true),
                "callable adapter must not query registry for array metatables")

            -- Verify callable adapter entry extracts _mod from upvalue[0]
            assert.truthy(csrc:find("Udata *_mod = uvalue(&_fn->upvalue[0]);", 1, true),
                "callable adapter entry must read _mod from upvalue[0]")

            -- Verify callable adapter allocation sets upvalue[0] to _mod
            assert.truthy(csrc:find("setuvalue(L, &_ca_wrapper->upvalue[_ca_i], _mod);", 1, true),
                "callable adapter allocation must store _mod in upvalue[0]")

            -- Verify type tag expression uses _mod->uv
            assert.truthy(csrc:find("hvalue(&_mod->uv[", 1, true),
                "type tags must be resolved directly through _mod->uv slots")
        end)

        it("executes callable adapters with cross-module coercions and module-level variables",
        function()
            local ok, err = h.generate_modules({
                callable_mod = [[
                    scale: integer = 100

                    record Rec
                        val: integer
                    end

                    local function compute(r: Rec, extra: integer): integer
                        return r.val * scale + extra
                    end

                    function get_func(): (Rec, integer) -> integer
                        return compute
                    end
                ]],
                callable_consumer = [[
                    local m = import "callable_mod"

                    function call_boxed(r: m.Rec, extra: integer): integer
                        local f: (m.Rec, value) -> value = m.get_func()
                        return f(r, extra) as integer
                    end

                    function call_fully_boxed(r: value, extra: value): integer
                        local f: (value, value) -> value = m.get_func()
                        return f(r, extra) as integer
                    end
                ]],
                callable_bridge = [[
                    local m = import "callable_mod"
                    local c = import "callable_consumer"

                    function test_boxed(): integer
                        local r = m.Rec.new(3)
                        return c.call_boxed(r, 7)
                    end

                    function test_fully_boxed(): integer
                        local r = m.Rec.new(3)
                        return c.call_fully_boxed(r, 5)
                    end
                ]]
            }, "callable_bridge")
            assert.is_true(ok, err)

            local called, callerr = h.call("callable_bridge", [[
                assert(callable_bridge.test_boxed() == 307)
                assert(callable_bridge.test_fully_boxed() == 305)
                return true
            ]])
            assert.is_true(called, callerr)
        end)
    end)

    describe("interface method adapters", function()
        it("emits interface wrapper uv[0] as _mod, passes concrete_mod, and uses _mod->uv for tags",
        function()
            local csrc = h.compile_and_read_c([[
                interface Inspector
                    function inspect(x: value): integer
                end

                record Box
                    count: integer
                end

                function Box:inspect(x: integer): integer
                    return self.count + x
                end

                function make_inspector(b: Box): Inspector
                    return b
                end
            ]])

            assert.is_nil(csrc:find("titan_registry_get_string_table", 1, true),
                "interface adapter must not query Lua registry for string table")
            assert.is_nil(csrc:find("titan_array_cached_metatables", 1, true),
                "interface adapter must not query registry for array metatables")

            -- Verify interface wrapper allocation stores _mod in uv[0]
            assert.truthy(csrc:find("->uv[0].uv, _mod);", 1, true),
                "interface wrapper allocation must store _mod in uv[0]")

            -- Verify tag resolution in adapter uses _mod->uv
            assert.truthy(csrc:find("hvalue(&_mod->uv[", 1, true),
                "interface adapter must resolve type tags via _mod->uv")
        end)

        it("dispatches interface methods across module boundaries with proper concrete module state",
        function()
            local ok, err = h.generate_modules({
                iface_api = [[
                    interface Transformer
                        function transform(x: integer): integer
                        function transform_boxed(x: value): value
                    end
                ]],
                iface_provider = [[
                    offset: integer = 42

                    record Multiplier
                        factor: integer
                    end

                    function Multiplier:transform(x: integer): integer
                        return self.factor * x + offset
                    end

                    function Multiplier:transform_boxed(x: integer): integer
                        return self.factor * x + offset
                    end

                    function new_multiplier(factor: integer): Multiplier
                        return Multiplier.new(factor)
                    end
                ]],
                iface_caster = [[
                    local api = import "iface_api"
                    local prov = import "iface_provider"

                    function cast_to_transformer(m: prov.Multiplier): api.Transformer
                        return m
                    end
                ]],
                iface_consumer = [[
                    local api = import "iface_api"

                    function apply_direct(t: api.Transformer, x: integer): integer
                        return t:transform(x)
                    end

                    function apply_boxed(t: api.Transformer, x: value): integer
                        return t:transform_boxed(x) as integer
                    end
                ]],
                iface_bridge = [[
                    local api = import "iface_api"
                    local prov = import "iface_provider"
                    local caster = import "iface_caster"
                    local consumer = import "iface_consumer"

                    function test_direct(): integer
                        local m = prov.new_multiplier(3)
                        local t = caster.cast_to_transformer(m)
                        return consumer.apply_direct(t, 10)
                    end

                    function test_boxed(): integer
                        local m = prov.new_multiplier(3)
                        local t = caster.cast_to_transformer(m)
                        return consumer.apply_boxed(t, 5)
                    end
                ]]
            }, "iface_bridge")
            assert.is_true(ok, err)

            local called, callerr = h.call("iface_bridge", [[
                -- 3 * 10 + 42 = 72
                assert(iface_bridge.test_direct() == 72)
                -- 3 * 5 + 42 = 57
                assert(iface_bridge.test_boxed() == 57)
                return true
            ]])
            assert.is_true(called, callerr)
        end)
    end)
end)

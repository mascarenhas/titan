-- Generated union payload readers exercised through the installed standard
-- provider (titan.reflect). Listed in
-- spec/support/ci_stdlib_compiler_test_files.txt, so CI runs this after the
-- standard library is installed; compiler-only union cases stay in
-- unions_spec.lua.
local h = require "spec.support.helpers"
local driver = require "titan-compiler.driver"

describe("unions with the standard provider", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".dll", ".a", ".ffi.h",
                                  ".titan.h", ".priv.h", ".parts" }) do
            os.remove("test" .. suffix)
        end
        local removed, remove_error = driver.remove_path("test.so.dSYM")
        assert.truthy(removed, remove_error)
    end)

    it("publishes a boxed payload reader including private Array variants", function()
        h.with_extra_cflags({ "-DTITAN_COMPILER_TESTS" }, function()
            local compiled, compilation_error = h.build_so_chain({ {
                name = "test", src = [[
                local reflect = import "reflect"
                union Packet
                    empty()
                    numbers({integer})
                    local hidden({integer}?)
                end

                function public_packet(): Packet
                    return Packet.numbers({20, 22})
                end

                function private_packet(): Packet
                    local numbers = { 41, 42 }
                    return Packet.hidden(numbers)
                end

                function private_nil(): Packet
                    return Packet.hidden(nil)
                end

                function inspect(packet: Packet): (integer, integer, integer?)
                    case reflect.inspect(packet)
                    when is_union(view) then
                        if view.n_parts == 0 then return view.tag, 0, nil end
                        local values: {integer}? = view:get(1)
                        if values == nil then return view.tag, view.n_parts, nil end
                        return view.tag, view.n_parts, values[1] + values[2]
                    else
                        raise "expected generated union reader"
                    end
                end
            ]],
            } })
            assert.truthy(compiled, compilation_error)
            local ok, err = h.call("test", [[
                local packet = test.private_packet()
                local tag, arity, total = test.inspect(packet)
                assert(tag == 2 and arity == 1 and total == 83)
                tag, arity, total = test.inspect(test.private_nil())
                assert(tag == 2 and arity == 1 and total == nil)
                tag, arity, total = test.inspect(test.Packet.empty())
                assert(tag == 0 and arity == 0 and total == nil)
                tag, arity, total = test.inspect(test.public_packet())
                assert(tag == 1 and arity == 1 and total == 42)
                local registry = debug.getregistry()
                local mt = debug.getmetatable(packet)
                assert(type(mt[registry.TITAN_MT_PAYLOAD]) == "userdata")
                assert(not mt[registry.TITAN_MT_TYPE]:find("hidden", 1, true))
            ]])
            assert.truthy(ok, err)
        end)
    end)

end)

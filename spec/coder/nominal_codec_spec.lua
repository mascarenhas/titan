local h = require "spec.support.helpers"

describe("generated nominal codecs", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".lua" }) do
            os.remove("test" .. suffix)
        end
    end)

    it("publishes codecs only for plain public nominal graphs", function()
        local c = h.compile_and_read_c([[
            record Point
                x: integer
                ratio: float
                flag: boolean?
                label: string?
            end
            union Shape
                dot(Point)
                none()
            end
            record Chain
                name: string
                next: Chain?
            end
            record Dynamic
                item: value
            end
            record Listed
                items: {integer}
            end
            record UsesListed
                inner: Listed
            end
            local record Hidden
                x: integer
            end
            record Private
                x: integer
                local y: integer
            end
            record Hooked
                x: integer
            end
            function Hooked:to_transfer_payload(): string
                return ""
            end
            function Hooked.from_transfer_payload(payload: string): Hooked
                return Hooked(#payload)
            end
        ]])
        local _, tables = c:gsub("static const TitanTransferCodec ", "")
        assert.equal(1, tables)
        for _, name in ipairs({ "test.Point", "test.Chain" }) do
            assert.truthy(c:find('"' .. name .. '", 0,', 1, true), name)
        end
        assert.truthy(c:find('"test.Shape", 1,', 1, true))
        for _, name in ipairs({ "test.Dynamic", "test.Listed", "test.UsesListed",
                                "test.Hidden", "test.Private", "test.Hooked" }) do
            assert.is_nil(c:find('"' .. name .. '", 0,', 1, true), name)
        end
        local _, bindings = c:gsub("lua_rawsetp%(L, %-2, TITAN_MT_CODEC%);", "")
        assert.equal(3, bindings)
        assert.truthy(c:find("titan_codec_encode_nested(L, _resources", 1, true))
        assert.truthy(c:find("titan_codec_decode_nested(L, _resources", 1, true))
        assert.is_nil(c:find("luaL_error(L, \"protobuf", 1, true))
    end)

    it("publishes an empty codec table as NULL in the module manifest", function()
        local c = h.compile_and_read_c([[
            function answer(): integer
                return 42
            end
        ]])
        assert.is_nil(c:find("static const TitanTransferCodec ", 1, true))
        assert.truthy(c:find("0, NULL", 1, true))
    end)
end)

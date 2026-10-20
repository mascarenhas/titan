local h = require "spec.support.helpers"

describe("generated nominal codecs", function()
    after_each(function()
        for _, suffix in ipairs({ ".c", ".o", ".so", ".a", ".lua" }) do
            os.remove("test" .. suffix)
        end
    end)

    it("publishes codecs for public hook-free nominals with encodable fields", function()
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
            record Mapped
                index: {string: integer}
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
        for _, name in ipairs({ "test.Point", "test.Chain", "test.Listed",
                                "test.UsesListed", "test.Dynamic" }) do
            assert.truthy(c:find('{ "' .. name .. '", 0,', 1, true), name)
        end
        assert.truthy(c:find('{ "test.Shape", 1,', 1, true))
        for _, name in ipairs({ "test.Mapped", "test.Hidden", "test.Private",
                                "test.Hooked" }) do
            assert.is_nil(c:find('{ "' .. name .. '", 0,', 1, true), name)
        end
        local _, bindings = c:gsub("lua_rawsetp%(L, %-2, TITAN_MT_CODEC%);", "")
        assert.equal(6, bindings)
        -- `value` fields dispatch on the run-time tag.
        assert.truthy(c:find("titan_codec_put_value(L, _st", 1, true))
        assert.truthy(c:find("titan_codec_get_value(L, _st", 1, true))
        -- Nested nominals dispatch at run time; Arrays use the reflective field
        -- codec through the fixed handoff entry, never a decline.
        assert.truthy(c:find("titan_codec_put_nominal(L, _st", 1, true))
        assert.truthy(c:find("titan_codec_get_nominal(L, _st", 1, true))
        assert.truthy(c:find("TITAN_CODEC_ENCODE_FIELD", 1, true))
        assert.truthy(c:find("titan_codec_decode_field(L, _st", 1, true))
        assert.is_nil(c:find("luaL_error(L, \"protobuf", 1, true))
    end)

    it("emits no codec table or binding without eligible nominals", function()
        local c = h.compile_and_read_c([[
            function answer(): integer
                return 42
            end
        ]])
        assert.is_nil(c:find("static const TitanTransferCodec ", 1, true))
        assert.is_nil(c:find("TITAN_MT_CODEC", 1, true))
    end)

    -- Eligibility is per nominal: a nested nominal without a codec is handed to
    -- the reflective field codec at run time, so recursive groups never depend
    -- on declaration order.
    -- Codec table entries only; nested-field dispatch arguments also name
    -- nominals that have no codec of their own.
    local function has_codec(c, name)
        return c:find('{ "' .. name .. '", 0,', 1, true) ~= nil
            or c:find('{ "' .. name .. '", 1,', 1, true) ~= nil
    end

    local function check_recursive_group(source, ineligible, eligible)
        local c = h.compile_and_read_c(source)
        for _, name in ipairs(ineligible) do
            assert.is_false(has_codec(c, name), name)
        end
        for _, name in ipairs(eligible) do
            assert.is_true(has_codec(c, name), name)
        end
    end

    it("resolves a recursive record group independently of declaration order", function()
        local tree = [[
            record Tree
                root: Leaf
                tags: {string}
                index: {string: integer}
            end
        ]]
        local leaf = [[
            record Leaf
                owner: Tree?
            end
        ]]
        local plain = [[
            record Plain
                next: Plain?
                label: string
            end
        ]]
        check_recursive_group(tree .. leaf .. plain,
            { "test.Tree" }, { "test.Leaf", "test.Plain" })
        check_recursive_group(leaf .. tree .. plain,
            { "test.Tree" }, { "test.Leaf", "test.Plain" })
    end)

    it("resolves a recursive union group independently of declaration order", function()
        local expr = [[
            union Expr
                lit(Literal)
                list({Expr})
            end
        ]]
        local literal = [[
            record Literal
                parent: Expr?
                text: string
                callback: (function (): ())?
            end
        ]]
        check_recursive_group(expr .. literal,
            { "test.Literal" }, { "test.Expr" })
        check_recursive_group(literal .. expr,
            { "test.Literal" }, { "test.Expr" })
    end)

    -- A generated decoder's C-stack directory is bounded: a wider record or
    -- union stays reflective.
    it("keeps nominals wider than the decoder directory budget reflective", function()
        local function fields(count, prefix)
            local lines = {}
            for index = 1, count do
                lines[index] = prefix .. index .. ": integer"
            end
            return table.concat(lines, "\n")
        end
        local function parts(count)
            local list = {}
            for index = 1, count do list[index] = "p" .. index .. ": integer" end
            return table.concat(list, ", ")
        end
        local c = h.compile_and_read_c(
            "record Fits\n" .. fields(64, "f") .. "\nend\n"
            .. "record Wider\n" .. fields(65, "f") .. "\nend\n"
            .. "union FitsUnion\n  only(" .. parts(63) .. ")\nend\n"
            .. "union WiderUnion\n  only(" .. parts(64) .. ")\nend\n")
        assert.is_true(has_codec(c, "test.Fits"))
        assert.is_true(has_codec(c, "test.FitsUnion"))
        assert.is_false(has_codec(c, "test.Wider"))
        assert.is_false(has_codec(c, "test.WiderUnion"))
    end)

    -- transfer.h calls codec_handoff's native entry directly after checking
    -- the closure's function-type tag. Both spellings there must be exactly
    -- the compiler's for `function (value, value, value, value): (value)`.
    it("pins the handoff entry to the compiler's function type and native signature", function()
        local types = require "titan-compiler.types"
        require "titan-compiler.coder"
        local core = require "titan-compiler.coder.core"
        local file = assert(io.open("titan-runtime/transfer.h"))
        local header = file:read("a")
        file:close()
        local value = types.Value()
        local ftype = types.Function({ value, value, value, value }, { value }, false,
            nil, nil)
        local tag = header:match('#define TITAN_CODEC_HANDOFF_TYPE%s*\\%s*"([^"]*)"')
        assert.equal(types.serialize_semantic(ftype), tag)
        local typedef = header:match("typedef (TValue %(%*TitanCodecHandoffEntry%)%b())")
        local function squeeze(text) return (text:gsub("%s+", "")) end
        assert.equal(squeeze(core.function_sig("TitanCodecHandoffEntry", ftype, true)),
            squeeze(assert(typedef)))
    end)
end)

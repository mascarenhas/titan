local h = require "spec.support.helpers"

local function with_header(contents, body)
    local path = os.tmpname() .. ".h"
    local file = assert(io.open(path, "w"))
    file:write(contents)
    file:close()

    local results = table.pack(pcall(body, path))
    os.remove(path)
    if not results[1] then error(results[2], 0) end
    return table.unpack(results, 2, results.n)
end

describe("type-test expressions (typechecker)", function()
    it("types an admitted test as boolean", function()
        local ok, err, tree = h.run_checker([[
            function is_integer(v: value): boolean
                return v is integer
            end
        ]])
        assert.truthy(ok, err)

        local test = tree[1].block.stats[1].exps[1]
        assert.same("Ast.ExpIs", test._tag)
        assert.same("Type.Integer", test.target._tag)
        assert.same("Type.Boolean", test._type._tag)
    end)

    it("admits exactly the ordinary value cast targets", function()
        for _, target in ipairs({
            "{integer}",
            "{integer: string}",
            "boolean",
            "float",
            "integer",
            "integer?",
            "nil",
            "string",
            "Record",
            "(integer) -> integer",
        }) do
            h.assert_type_check([[
                record Record end
                function test(v: value): boolean
                    return v is ]] .. target .. [[
                end
            ]])
        end
    end)

    it("accepts identity and exact option unwrap tests", function()
        h.assert_type_check([[
            function identities(i: integer, maybe: integer?): boolean
                return (i is integer) and (maybe is integer)
            end
        ]])
    end)

    it("does not narrow the operand in the true branch", function()
        h.assert_type_error(
            "left hand side of arithmetic expression is a value", [[
                function plus_one(v: value): integer
                    if v is integer then
                        return v + 1
                    end
                    return 0
                end
            ]])
    end)

    it("rejects the same statically inadmissible relations as 'as'", function()
        for _, case in ipairs({
            { source = "boolean", target = "integer" },
        }) do
            h.assert_type_error("cannot cast", [[
                function test(v: ]] .. case.source .. [[): boolean
                    return v is ]] .. case.target .. [[
                end
            ]])
        end
    end)

    it("admits the same written numeric coercions as 'as'", function()
        h.assert_type_check([[
            function scalar(v: float): boolean
                return v is integer
            end

            function optional(v: float?): boolean
                return v is integer?
            end
        ]])
    end)

    it("mirrors the admitted value-to-C scalar and pointer targets", function()
        h.assert_type_check([[
            local ffi = foreign import "titan/ffi.h"

            function c_integer(v: value): boolean
                return v is ffi.titan_ffi_int
            end
            function c_float(v: value): boolean
                return v is ffi.titan_ffi_double
            end
            function c_pointer(v: value): boolean
                return v is ffi.titan_ffi_void_ptr
            end
            function c_userdata(v: value): boolean
                return v is *ffi.Udata
            end
            function c_tvalue(v: value): boolean
                return v is ffi.TValue
            end
        ]])
    end)

    it("rejects value tests against C arrays and by-value aggregates", function()
        with_header([[
            typedef int test_array[2];
            typedef struct test_record { int field; } test_record;
        ]], function(header)
            h.assert_type_error("cannot cast 'value' to 'test_array'", [[
                local c = foreign import "]] .. header .. [["
                function array(v: value): boolean
                    return v is c.test_array
                end
            ]])
            h.assert_type_error("cannot cast 'value' to 'test_record'", [[
                local c = foreign import "]] .. header .. [["
                function aggregate(v: value): boolean
                    return v is c.test_record
                end
            ]])
        end)
    end)
end)

local foreigntypes = require "titan-compiler.foreigntypes"
local types = require "titan-compiler.types"

describe("foreign C type conversion", function()
    it("canonicalizes an unqualified short int", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local converted, err = foreigntypes.convert(scope, {
            type = { "short", "int" },
        })

        assert.is_nil(err)
        assert.same(types.CInteger("short", true, 2, nil), converted)
    end)

    it("keeps direct declaration names out of structural function types", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local function raw(paramname)
            return {
                type = "function",
                params = {{name = paramname, type = {"int"}}},
                paramnames = {paramname},
                paramnames_state = "complete",
                ret = {type = {"int"}},
                vararg = false,
            }
        end

        local left = assert(foreigntypes.convert(scope, raw("left")))
        local right = assert(foreigntypes.convert(scope, raw("right")))

        assert.truthy(types.equals(left, right))
        assert.equal(types.tostring(left), types.tostring(right))
        assert.is_nil(left.paramnames)
    end)

    it("keeps callback names out of structural C function types", function()
        local scope = {
            find_foreign_type = function()
                return nil
            end,
        }
        local function raw(paramname)
            return {
                type = "functionptr",
                name = "callback",
                params = {{name = paramname, type = {"int"}}},
                paramnames = {paramname},
                paramnames_state = "complete",
                ret = {type = {"void"}},
                vararg = false,
                pointer = {"*"},
            }
        end

        local left = assert(foreigntypes.convert(scope, raw("event")))
        local right = assert(foreigntypes.convert(scope, raw("value")))
        local left_function = types.resolve_c_typedef(left.pointee)

        assert.truthy(types.equals(left, right))
        assert.equal(types.tostring(left), types.tostring(right))
        assert.equal("Type.CFunction", left_function._tag)
        assert.is_nil(left_function.paramnames)
    end)
end)

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
end)

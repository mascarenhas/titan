local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"

local function sorted_keys(module)
    local keys = {}
    for key in pairs(module) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

describe("compiler module facades", function()
    it("exports only the production checker API", function()
        assert.same({
            "check",
            "checkimport",
            "configure_foreign_c",
            "has_main",
            "register_module_interface",
        }, sorted_keys(checker))
        for _, value in pairs(checker) do assert.is_function(value) end
    end)

    it("exports only the production coder API", function()
        assert.same({
            "external_symbols",
            "generate",
            "generate_foreign_header",
            "interface_external_symbols",
        }, sorted_keys(coder))
        for _, value in pairs(coder) do assert.is_function(value) end
    end)
end)

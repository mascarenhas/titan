local checker_core = require "titan-compiler.checker.core"
local coder_core = require "titan-compiler.coder.core"
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
            "foreign_external_symbols",
            "generate",
            "generate_ffi_header",
            "generate_foreign_header",
            "interface_external_symbols",
            "prepare_coverage",
        }, sorted_keys(coder))
        for _, value in pairs(coder) do assert.is_function(value) end
    end)

    it("keeps implementation helpers out of the Lua global namespace",
    function()
        for _, name in ipairs({
            "array_metatable",
            "setboxed",
            "copyboxed",
        }) do
            assert.is_function(rawget(coder_core, name), name)
            assert.is_nil(rawget(_G, name), name)
        end
        for _, name in ipairs({
            "checkandgetmixed",
            "checkandsetmixed",
        }) do
            assert.is_nil(rawget(coder_core, name), name)
            assert.is_nil(rawget(_G, name), name)
        end
    end)

    it("distributes prefixed generic helpers without a checker subtable",
    function()
        assert.is_nil(rawget(checker_core.checker, "_generic"))
        for _, name in ipairs({
            "generic_runtime_carrier",
            "generic_with_inference_operation",
            "generic_lower_erased_core",
        }) do
            assert.is_function(rawget(checker_core, name), name)
        end
    end)
end)

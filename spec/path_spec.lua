local cases = require "spec.support.path_cases"
local native = require "titan-compiler.path"

-- Exercise both grammars without adding selectors to the installed API or
-- changing the process's actual platform/configuration.
local function for_platform(separator)
    local environment = setmetatable({ package = { config = separator .. "\n;\n?\n!\n-\n" } },
        { __index = _G })
    return assert(loadfile("titan-compiler/path.lua", "t", environment))()
end

local function check_case(module, case, spelling)
    local actual = table.pack(module[case.operation](table.unpack(case.arguments)))
    local expected = case[spelling]
    assert.equal(#expected, actual.n)
    actual.n = nil
    assert.same(expected, actual)
    if case.operation == "split" then
        assert.equal(case.arguments[1], actual[1] .. actual[2])
    elseif case.operation == "normalize" then
        assert.equal(actual[1], module.normalize(actual[1]))
    end
end

describe("lexical native filesystem paths", function()
    for _, spelling in ipairs({ "posix", "windows" }) do
        local separator = spelling == "windows" and "\\" or "/"
        local module = for_platform(separator)
        describe(spelling .. " grammar", function()
            it("exports the native separator and only the frozen lexical API", function()
                assert.equal(separator, module.separator)
                local keys = {}
                for key in pairs(module) do keys[#keys + 1] = key end
                table.sort(keys)
                assert.same({ "basename", "dirname", "extension", "from_slash",
                    "is_absolute", "join", "normalize", "separator", "split",
                    "to_slash", "volume" }, keys)
            end)
            for index, case in ipairs(cases) do
                it(case.operation .. " edge " .. index, function()
                    check_case(module, case, spelling)
                end)
            end
        end)
    end

    it("uses the host grammar for the ordinary compiler module", function()
        local spelling = package.config:sub(1, 1) == "\\" and "windows" or "posix"
        assert.equal(package.config:sub(1, 1), native.separator)
        for _, case in ipairs(cases) do check_case(native, case, spelling) end
    end)
end)

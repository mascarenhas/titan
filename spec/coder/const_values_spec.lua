local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"

local function clean_module(name)
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", ".lua", "__entrypoint.c",
        "__entrypoint.o",
    }) do
        os.remove(name .. suffix)
    end
    os.execute("rm -rf " .. name .. ".dSYM")
end

local function generate(source)
    h.reset(true)
    local tree, parse_error = h.parse(source, "test.titan")
    assert.truthy(tree, parse_error)
    local _, errors = checker.check(
        "test", tree, source, "test.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION)
end

local function generated_function(c_source, marker)
    local search = 1
    while true do
        local start = assert(c_source:find(marker, search, true),
            "generated C function not found: " .. marker)
        local line_end = c_source:find("\n", start, true)
            or (#c_source + 1)
        local brace = c_source:find("{", start, true)
        if brace and brace < line_end then
            local depth = 0
            for index = brace, #c_source do
                local byte = c_source:sub(index, index)
                if byte == "{" then
                    depth = depth + 1
                elseif byte == "}" then
                    depth = depth - 1
                    if depth == 0 then
                        return c_source:sub(start, index)
                    end
                end
            end
            error("unterminated generated C function: " .. marker)
        end
        search = line_end + 1
    end
end

describe("const values (code generator)", function()
    after_each(function()
        clean_module("test")
    end)

    it("nil-initializes omitted mutable scalar and GC locals", function()
        h.run_coder([[
            function scalar(): integer?
                local pending: integer?
                return pending
            end

            function array(): { integer }?
                local pending: { integer }?
                return pending
            end

            function pair(): (integer?, { integer }?)
                local scalar_value: integer?, array_value: { integer }?
                return scalar_value, array_value
            end
        ]], [[
            assert(test.scalar() == nil)
            assert(test.array() == nil)
            local scalar_value, array_value = test.pair()
            assert(scalar_value == nil and array_value == nil)
        ]])
    end)

    it("publishes const module values but rejects Lua replacement", function()
        h.run_coder([[
            const answer = 42
            const delayed: string?

            function read(): (integer, string?)
                return answer, delayed
            end

            do
                delayed = "ready"
            end
        ]], [[
            assert(test.answer == 42)
            assert(test.delayed == "ready")
            local ok1 = pcall(function() test.answer = 0 end)
            local ok2 = pcall(function() test.delayed = nil end)
            assert(not ok1 and not ok2)
            local answer, delayed = test.read()
            assert(answer == 42 and delayed == "ready")
        ]])
    end)

    it("keeps const record fields read-only while mutable siblings work",
    function()
        h.run_coder([[
            record Box
                const label: string
                count: integer
            end

            function make(): Box
                return Box.new("fixed", 1)
            end

            function inspect(box: Box): (string, integer)
                return box.label, box.count
            end
        ]], [[
            local box = test.make()
            assert(box.label == "fixed" and box.count == 1)
            box.count = 2
            local ok = pcall(function() box.label = "changed" end)
            assert(not ok)
            local label, count = test.inspect(box)
            assert(label == "fixed" and count == 2)
        ]])
    end)

    it("exposes const Arrays through a distinct immutable Lua proxy", function()
        h.run_coder([[
            function make(): const { integer }
                return { 10, 20 }
            end

            function classify(item: value): (boolean, boolean)
                return item is const { integer }, item is { integer }
            end
        ]], [[
            local items = test.make()
            assert(#items == 2 and items[1] == 10 and items[2] == 20)
            local is_const, is_mutable = test.classify(items)
            assert(is_const and not is_mutable)
            assert(not pcall(function() items[1] = 99 end))
            assert(not pcall(function() items[1] = nil end))
            assert(not pcall(function() table.insert(items, 30) end))
            assert(#items == 2 and items[1] == 10 and items[2] == 20)
        ]])
    end)

    it("shallow-copies an escaped mutable Array before freezing", function()
        h.run_coder([[
            record Cell
                number: integer
            end

            function snapshot(): (const { Cell }, { Cell })
                local first = Cell.new(1)
                local items = { first }
                const frozen = items as const { Cell }
                items[1] = Cell.new(2)
                return frozen, items
            end
        ]], [[
            local frozen, mutable = test.snapshot()
            assert(not rawequal(frozen, mutable))
            assert(frozen[1].number == 1)
            assert(mutable[1].number == 2)
            assert(not pcall(function() frozen[1] = mutable[1] end))
        ]])
    end)

    it("emits the in-place helper only for the proven linear cast", function()
        local c_source = generate([[
            function linear(): const { integer }
                local items = { 1, 2 }
                return items as const { integer }
            end

            function copied(): const { integer }
                local items = { 1, 2 }
                local alias = items
                return items as const { integer }
            end
        ]])
        local linear = generated_function(
            c_source, "test_\\u2133_linear_titan(lua_State *L")
        local copied = generated_function(
            c_source, "test_\\u2133_copied_titan(lua_State *L")
        assert.match("titan_array_freeze", linear)
        assert.not_match("titan_array_shallow_copy", linear)
        assert.match("titan_array_shallow_copy", copied)
        assert.not_match("titan_array_freeze%(", copied)
    end)
end)

local checker = require "titan-compiler.checker"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local h = require "spec.support.helpers"

local function clean_module(name)
    for _, suffix in ipairs({
        ".c", ".o", ".so", ".a", "__entrypoint.c",
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
    return coder.generate("test", tree, {}, driver.TITAN_ABI_VERSION).parts[1].code
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
        clean_module("initializer_dep")
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

    it("executes imported initializers after the dependency and before the root block",
       function()
        local ok, err = h.generate_modules({
            initializer_dep = [[
                foreign import "titan/ffi.h"
                local ready = false
                trace = ""
                const seed = 100
                function mark(number: integer): integer
                    if not ready then raise "dependency not initialized" end
                    if ffi.lua_checkstack(L, 8192) == 0 then
                        raise "cannot grow initializer stack"
                    end
                    ffi.lua_gc(L, ffi.LUA_GCCOLLECT)
                    trace = trace .. number
                    return number
                end
                record Box number: integer end
                function Box.new(number: integer): Box
                    return {number = mark(number)}
                end
                function Box:read(): integer return self.number end
                do ready = true end
            ]],
            test = [[
                local dep = import "initializer_dep"
                const first = dep.mark(1)
                second = (dep.mark(2))
                const box = dep.Box(3)
                const method = dep.Box(4):read()
                const bound = dep.Box(5):read
                const values = {dep.mark(6), dep.mark(7)}
                const indexed: integer = ({dep.mark(8)})[1]
                const imported = dep.seed
                const delayed: integer?
                local lambda = function(): integer return first + second end
                local erased: value = function(): integer return first end
                function read(): integer return lambda() end
                function read_erased(): integer
                    local callback: function(): integer = erased
                    return callback()
                end
                function trace(): string return dep.trace end
                do delayed = dep.mark(9) end
            ]],
        }, "test")
        assert.truthy(ok, err)
        ok, err = h.call("test", [[
            assert(test.first == 1 and test.second == 2)
            assert(test.box.number == 3 and test.method == 4)
            assert(test.bound() == 5)
            assert(test.values[1] == 6 and test.values[2] == 7)
            assert(test.indexed == 8 and test.imported == 100)
            assert(test.delayed == 9 and test.trace() == "123456789")
            collectgarbage("collect")
            assert(test.read() == 3 and test.read_erased() == 1)
            assert(test.bound() == 5)
            assert(require("test") == test and test.trace() == "123456789")
            assert(not pcall(function() test.first = 10 end))
            assert(not pcall(function() test.delayed = 10 end))
            test.second = 20
            assert(test.read() == 21 and test.trace() == "123456789")
        ]])
        assert.truthy(ok, err)
    end)

    it("preserves named, surplus, multi-result, and spread evaluation during init",
       function()
        local ok, err = h.generate_modules({
            initializer_dep = [[
                trace = ""
                function mark(number: integer): integer
                    trace = trace .. number
                    return number
                end
                function pair(first: integer, second: integer): integer
                    return first * 10 + second
                end
                function zero(): integer return 0 end
                function results(): (integer, integer)
                    return mark(5), mark(6)
                end
            ]],
            test = [[
                local dep = import "initializer_dep"
                const named = dep.pair {second = dep.mark(1), first = dep.mark(2)}
                const discarded = dep.zero(dep.mark(3), dep.mark(4))
                const multiple = dep.pair(dep.results())
                const spread = dep.pair(...{dep.mark(7), dep.mark(8)})
                function trace(): string return dep.trace end
            ]],
        }, "test")
        assert.truthy(ok, err)
        ok, err = h.call("test", [[
            assert(test.named == 21 and test.discarded == 0)
            assert(test.multiple == 56 and test.spread == 78)
            assert(test.trace() == "12345678")
        ]])
        assert.truthy(ok, err)
    end)

    it("dispatches imported implementations through own Interface requirements during init",
       function()
        local ok, err = h.generate_modules({
            initializer_dep = [[
                record Box number: integer end
                function Box:read(): integer return self.number end
            ]],
            test = [[
                local dep = import "initializer_dep"
                interface Reader function read(): integer end
                const stored: Reader = dep.Box(7)
                const bound = (dep.Box(8) as Reader):read
                const dispatched = (dep.Box(9) as Reader):read()
                const called = ((dep.Box(10) as Reader):read)()
                function read_stored(): integer return stored:read() end
            ]],
        }, "test")
        assert.truthy(ok, err)
        ok, err = h.call("test", [[
            assert(test.bound() == 8)
            assert(test.dispatched == 9 and test.called == 10)
            collectgarbage("collect")
            assert(test.read_stored() == 7 and test.bound() == 8)
        ]])
        assert.truthy(ok, err)
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

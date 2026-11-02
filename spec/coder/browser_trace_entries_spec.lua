local assert = require "luassert"
local h = require "spec.support.helpers"
local coder = require "titan-compiler.coder"
local driver = require "titan-compiler.driver"
local parser = require "titan-compiler.parser"
local checker = require "titan-compiler.checker"
local sha256 = require "titan-compiler.sha256"

local SOURCE = [[
record Item
    value: integer
end
interface Reader
    function read(): integer
end
function Item:read(): integer return self.value end
local function Item:hidden(): integer return self.value end
function Item.make(n: integer): Item return Item.new(n) end
local function hidden(n: integer): integer return n end
function public(n: integer): integer return hidden(n) end
function closures(item: Item, reader: Reader): function (value): value
    local bound = item:read
    local private_bound = item:hidden
    local interface_bound = reader:read
    local lambda = function(n: integer): integer return n end
    local adjusted: function (value): value = lambda
    bound()
    private_bound()
    interface_bound()
    return adjusted
end
do
    public(1)
end
]]
local function generate(target, parts, source, line_policy)
    h.reset(true)
    local ast, err = parser.parse("entries.browser.titan", source or SOURCE)
    assert.truthy(ast, err)
    local _, errors = checker.check("entries", ast, source or SOURCE, "entries.browser.titan")
    assert.equal(0, #errors, table.concat(errors, "\n"))
    return coder.generate("entries", ast, {}, driver.TITAN_ABI_VERSION, line_policy ~= false,
        { target = target, c_parts = parts or 1, split_threshold = 1 })
end
local function code(generated)
    local out = {}
    for _, part in ipairs(generated.parts) do out[#out + 1] = part.code end
    return table.concat(out, "\n")
end
local function entries(generated)
    local out, counts = {}, {}
    for symbol in code(generated):gmatch("lua_pushcfunction%(L, ([^%)]+)%);%s*lua_pushboolean%(L, 1%);%s*lua_rawset%(L, %-3%);") do
        out[symbol] = true
        counts[symbol] = (counts[symbol] or 0) + 1
    end
    for symbol, count in pairs(counts) do assert.equal(1, count, symbol) end
    return out
end

describe("browser traceback entry generation", function()
    it("registers every actual Lua C wrapper once, including local and generated entries", function()
        local generated = generate("browser")
        local text, registered, defined = code(generated), entries(generated), {}
        for symbol in text:gmatch("int%s+([%w_\\]+)%s*%(lua_State%s*%*L%)%s*{") do
            if symbol:find("titanentry", 1, true) then defined[symbol] = true end
        end
        assert.same(defined, registered)
        assert.is_not_nil(next(registered))
        for _, family in ipairs({ "titanentry_lua", "titanentry_strict", "titanentry_luastatic",
            "titanentry_strictstatic", "titanentry_luamethod", "titanentry_boundlua", "titanentry_boundstrict",
            "titanentry_interfacelua", "titanentry_interface_boundlua", "titanentry_interface_boundstrict" }) do
            local found
            for symbol in pairs(registered) do if symbol:sub(-#family) == family then found = true end end
            assert.is_true(found, family)
        end
        local lambda, adapter, private
        for symbol in pairs(registered) do
            if symbol:find("lambda", 1, true) then lambda = true end
            if symbol:find("callable_adapter", 1, true) then adapter = true end
            if symbol:find("hidden", 1, true) then private = true end
        end
        assert.is_true(lambda); assert.is_true(adapter); assert.is_true(private)
    end)

    it("registers both first-class entries of a private top-level function", function()
        local generated = generate("browser", 1, [[
            local function private_body(n: integer): integer return n end
            function expose(): function (integer): integer return private_body end
        ]])
        local count = 0
        for symbol in pairs(entries(generated)) do
            if symbol:find("private_body_titanentry_", 1, true) then count = count + 1 end
        end
        assert.equal(2, count)
    end)

    it("retains the initializer's native sentinel and leaves genuine opener CallInfos unregistered", function()
        local generated = generate("browser")
        for symbol in pairs(entries(generated)) do
            assert.is_nil(symbol:find("module_initializer", 1, true))
            assert.is_nil(symbol:find("luaopen_", 1, true))
        end
        local text = code(generated)
        assert.truthy(text:find("void entries_\\u2119_titanentry_module_initializer(lua_State *L, Udata *_mod, CClosure *_fn)", 1, true))
        assert.truthy(text:find("entries_\\u2119_titanentry_module_initializer(L, _mod, NULL);", 1, true))
    end)

    it("publishes entries and display names before dependencies, metatables or user initialization", function()
        local text = code(generate("browser"))
        local start = assert(text:find("Udata *entries_init(lua_State *L) {", 1, true))
        local body = text:sub(start)
        local registry = assert(body:find("TITAN_ENTRIES_KEY", 1, true))
        local names = assert(body:find("TITAN_NAMES_KEY", 1, true))
        local arrays = assert(body:find("titan_array_metatables(", 1, true))
        local initializer = assert(body:find("titanentry_module_initializer(L, _mod, NULL)", 1, true))
        assert.is_true(registry < names and names < arrays and arrays < initializer)
    end)

    it("publishes one registry for split generation and never registers native function bodies", function()
        local single, split = generate("browser"), generate("browser", 4)
        assert.is_true(#split.parts > 1)
        assert.same(entries(single), entries(split))
        local publications = 0
        for _, part in ipairs(split.parts) do
            if part.code:find("TITAN_ENTRIES_KEY", 1, true) then publications = publications + 1 end
        end
        assert.equal(1, publications)
        for symbol in pairs(entries(split)) do assert.truthy(symbol:find("titanentry", 1, true)) end
    end)

    it("keeps native output byte-identical across explicit targets and browser generation", function()
        local original = generate(nil)
        generate("browser", 4)
        local native = generate("linux")
        assert.same(original, native)
        assert.is_nil(code(native):find("TITAN_ENTRIES_KEY", 1, true))
        assert.equal(sha256.hex(code(original)), sha256.hex(code(native)))
    end)

    it("registers only its own wrappers and publishes names before importing a dependency", function()
        local ok, err, imported = h.run_checker_modules({
            dependency = "function accept(n: integer): integer return n end",
            entries = [[
                local dependency = import "dependency"
                function forward(n: integer): integer return dependency.accept(n) end
                do forward(1) end
            ]],
        }, "entries")
        assert.is_true(ok, err)
        local generated = coder.generate("entries", imported.entries.ast,
            { dependency = true }, driver.TITAN_ABI_VERSION, true, { target = "browser" })
        for symbol in pairs(entries(generated)) do
            assert.is_nil(symbol:find("dependency", 1, true))
        end
        local text = code(generated)
        local start = assert(text:find("Udata *entries_init(lua_State *L) {", 1, true))
        local body = text:sub(start)
        local names = assert(body:find("TITAN_NAMES_KEY", 1, true))
        local dependency = assert(body:find("dependency_init(L)", 1, true))
        assert.is_true(names < dependency)
    end)

    it("collects wrappers from selected physical contributors into the same split registry", function()
        h.reset(true)
        local main_source = "function primary(): integer return 1 end\ndo primary() end"
        local ast = assert(parser.parse("entries.browser.titan", main_source))
        local contributor = assert(parser.parse("member.browser.titan",
            "function contributed(): integer return 2 end"))
        table.insert(ast, #ast, contributor[1])
        local _, errors = checker.check("entries", ast, main_source, "entries.browser.titan")
        assert.equal(0, #errors, table.concat(errors, "\n"))
        local generated = coder.generate("entries", ast, {},
            driver.TITAN_ABI_VERSION, true, { target = "browser", c_parts = 4, split_threshold = 1 })
        local found = 0
        for symbol in pairs(entries(generated)) do
            if symbol:find("contributed", 1, true) then found = found + 1 end
        end
        assert.equal(2, found)
        assert.truthy(code(generated):find('member.browser.titan', 1, true))
    end)

    it("changes foreign native bodies only by source line directives under the line policy", function()
        local source = [[
            foreign function body(n: int): int
                if n > 0 then return n end
                return 0
            end
        ]]
        local located = code(generate(nil, 1, source, true))
        local unlocated = code(generate(nil, 1, source, false))
        assert.truthy(located:find('#line 2 "entries.browser.titan"', 1, true))
        assert.is_nil(unlocated:find("#line", 1, true))
        local function without_directives(text)
            return (text:gsub("[ \t]*#line[^\n]*\n", ""):gsub("\n[ \t\n]*\n", "\n"))
        end
        assert.equal(without_directives(unlocated), without_directives(located))
    end)

    it("emits an empty balanced registry for a module without Lua-callable entries", function()
        local text = code(generate("browser", 1, "local state: integer = 1\n"))
        assert.same({}, entries({ parts = { { code = text } } }))
        assert.truthy(text:find("lua_pop(L, 1);", assert(text:find("TITAN_ENTRIES_KEY", 1, true)), true))
    end)
end)

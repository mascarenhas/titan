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
    -- Stable planned outputs keep checking-header temporary paths out of byte
    -- comparisons; these pure codegen cases do not write or compile the files.
    ast._ffi_header_output = "/generated/entries.ffi.h"
    ast._foreign_header_output = "/generated/entries.titan.h"
    local generated = coder.generate("entries", ast, {}, driver.TITAN_ABI_VERSION, line_policy ~= false,
        { target = target, c_parts = parts or 1, split_threshold = 1,
            source_output_stem = "/generated/entries" })
    return generated, ast
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

local DEFINITION_SOURCE = assert(require("titan-compiler.util").get_file_contents(
    "spec/fixtures/browser_images/definitions.titan"))

local function ordered_pairs(original, reverse)
    return function(t)
        local keys = {}
        for key in original(t) do
            if type(key) ~= "string" and type(key) ~= "number" then return original(t) end
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local less = type(a) == type(b) and a < b or type(a) < type(b)
            return reverse and a ~= b and not less or not reverse and less
        end)
        local index = 0
        return function()
            index = index + 1
            local key = keys[index]
            if key ~= nil then return key, t[key] end
        end
    end
end

local function definitions(text)
    local result = {}
    text = "\n" .. text
    for start, header, name in text:gmatch(
        "\n()([^\n;{}]-([%a_\\][%w_\\]*)%s*%b()%s*){") do
        if name ~= "if" and name ~= "for" and name ~= "while" and name ~= "switch" then
            result[name] = {
                stamp = text:sub(1, start - 1):match("#line ([^\n]+)\n[ \t]*$"),
                header = header,
            }
        end
    end
    return result
end
local function native_variants(target)
    local variants, original = {}, _G.pairs
    local ok, err = xpcall(function()
        for _, reverse in ipairs({ false, true }) do
            -- Both legal traversal orders cover the pre-existing unordered
            -- metatable emission without normalizing or deleting output bytes.
            _G.pairs = ordered_pairs(original, reverse)
            for _, parts in ipairs({ 1, 4 }) do
                for _, located in ipairs({ false, true }) do
                    local generated = generate(target, parts, DEFINITION_SOURCE, located)
                    local texts = {
                        generated.private_header or "", generated.foreign_header or "",
                    }
                    for _, part in ipairs(generated.parts) do texts[#texts + 1] = part.code end
                    local bytes = {}
                    for _, text in ipairs(texts) do
                        assert.is_nil(text:find("TITAN_GENERATED_C_FILE", 1, true))
                        for name, definition in pairs(definitions(text)) do
                            assert.is_nil(definition.stamp, "native definition acquired a boundary stamp: " .. name)
                        end
                        bytes[#bytes + 1] = #text .. ":" .. text
                    end
                    variants[sha256.hex(table.concat(bytes))] = true
                end
            end
        end
    end, debug.traceback)
    _G.pairs = original
    assert.is_true(ok, err)
    return variants
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
        -- Compare complete C/private-header/foreign-header bytes under the
        -- current C declaration environment. In particular, libc's anonymous
        -- div_t declaration site is not a portable cross-machine byte golden.
        local expected = native_variants(nil)
        local count = 0
        for _ in pairs(expected) do count = count + 1 end
        assert.equal(8, count, "native matrix lost a traversal, split or line-policy variant")
        generate("browser", 4)
        assert.same(expected, native_variants("linux"))
    end)

    for _, parts in ipairs({ 1, 4 }) do
        it("owns every function signature and prologue in " .. parts .. "-part browser output", function()
            local generated, ast = generate("browser", parts, DEFINITION_SOURCE)
            local all, count = {}, 0
            for _, part in ipairs(generated.parts) do
                local filename = "/generated/entries"
                    .. (part.index == 0 and "" or ".part" .. part.index) .. ".c"
                assert.truthy(part.code:find('#define TITAN_GENERATED_C_FILE "' .. filename .. '"', 1, true))
                for name, definition in pairs(definitions(part.code)) do
                    assert.is_nil(all[name], "duplicate definition " .. name)
                    all[name], count = definition, count + 1
                end
            end
            for name, definition in pairs(definitions(generated.private_header or "")) do
                all[name], count = definition, count + 1
            end
            for name, definition in pairs(definitions(generated.foreign_header)) do
                all[name] = definition
            end
            assert.is_true(count > 100, "definition-family fixture lost generated functions")
            local generated_names = {
                titan_errfunc_is_errorhandler = true, titan_registry_get_string = true,
                titan_registry_set_string = true, titan_ensure_stack = true,
                entries_module_identity = true, entries_types = true, entries_layouts = true,
                entries_abi = true, entries_abi_value = true, entries_compatibility = true,
                entries_init = true, luaopen_entries = true,
            }
            for name, definition in pairs(all) do
                local generated_only = generated_names[name]
                    or name:find("array_writer_", 1, true) or name:find("native_symbol", 1, true)
                    or name:find("preload", 1, true)
                    or name == "entries_\\u2133_meta_index" or name == "entries_\\u2133_meta_newindex"
                if generated_only then
                    assert.equal("1 TITAN_GENERATED_C_FILE", definition.stamp, name)
                else
                    assert.match('^%d+ "entries[.]browser[.]titan"$', definition.stamp, name)
                end
            end
            local checked, seen = 0, {}
            local function check_ast(node)
                if type(node) ~= "table" or seen[node] then return end
                seen[node] = true
                if node.loc then
                    for _, key in ipairs({ "_body", "_luabody", "_strictbody", "_boundbody" }) do
                        if type(node[key]) == "string" then
                            for name in pairs(definitions(node[key])) do
                                assert.equal(node.loc.line .. ' "' .. node.loc.filename .. '"',
                                    assert(all[name], name).stamp, name)
                                checked = checked + 1
                            end
                        end
                    end
                end
                for _, value in pairs(node) do check_ast(value) end
            end
            check_ast(ast)
            assert.is_true(checked > 30, "AST-owned definitions were not checked")
            local transfers = 0
            for native, id in code(generated):gmatch(
                "{%s*titan_cast_func%(void %*, ([%w_\\]+)%),%s*[%w_\\]+,%s*%d+,%s*([%w_\\]+)_project,") do
                assert.equal(assert(all[native], native).stamp, assert(all[id .. "_project"], id).stamp)
                assert.equal(all[native].stamp, assert(all[id .. "_restore"], id).stamp)
                transfers = transfers + 1
            end
            assert.is_true(transfers > 10, "transfer source and adjustment entries were not checked")
            -- Each row is an independently emitted definition family. Requiring
            -- a present match prevents a vacuous universal stamp assertion.
            for _, family in ipairs({
                "_aggregate_titan", "_aggregate_titanentry_lua", "_aggregate_titanentry_strict",
                "_copied_titan", "_outlined_titan", "_empty_titan",
                "_foreign_inline_copied", "_foreign_inline_outlined", "_foreign_inline_empty",
                "_Item_\\u2131_read_titan", "_Item_\\u2131_make_titanentry_luastatic",
                "_titanentry_boundlua", "_titanentry_boundstrict", "_boundmethod",
                "_titanentry_interfacelua", "_interface_boundmethod",
                "_titanentry_interface_boundlua", "_titanentry_interface_boundstrict",
                "lambda_0", "lambda_1", "callable_adapter_", "interface_pair_",
                "_fieldaccessor", "_payload_reader", "_codec_encode", "_codec_decode",
                "_projection", "_construction", "_meta_call", "_meta_call_finish",
                "_\\u2131_wrapper", "_\\u2131_allocate",
                "_transfer_entry_", "array_writer_", "module_initializer",
            }) do
                local found
                for name in pairs(all) do if name:find(family, 1, true) then found = true end end
                assert.is_true(found, family)
            end
        end)
    end

    it("carries the browser boundary policy through immediate and graph foreign-header plans", function()
        local native, ast = generate(nil, 1, DEFINITION_SOURCE)
        local browser = driver.plan_foreign_header("entries", ast,
            "/generated/entries.titan", false, { target = "browser" })
        local graph = assert(driver.plan_foreign_headers({ "entries" }, {
            entries = { ast = ast, filename = "/generated/entries.titan" },
        }, { target = "browser" }))
        assert.equal(browser.contents, graph[1].contents)
        for _, text in ipairs({ browser.contents, graph[1].contents }) do
            local count = 0
            for name, definition in pairs(definitions(text)) do
                count = count + 1
                assert.match('^%d+ "entries[.]browser[.]titan"$', definition.stamp, name)
            end
            assert.equal(3, count)
        end
        local planned_native = driver.plan_foreign_header("entries", ast,
            "/generated/entries.titan", false, { target = "linux" })
        assert.equal(native.foreign_header, planned_native.contents)
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
